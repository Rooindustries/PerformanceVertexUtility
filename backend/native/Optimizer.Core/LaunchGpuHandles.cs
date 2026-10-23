#nullable enable
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

internal sealed record GpuHandleTransfer(OperationOwner Owner, string OperationId, RunningProcess Host, RunningProcess Watcher, RunningProcess Target, long Handle);
internal sealed record GpuHandleReady(GpuHandleTransfer Transfer, ControlRead Original, ControlRead? IoOriginal = null);

internal sealed class LaunchGpuHandles : IDisposable
{
    internal static bool Supported => LaunchProcessSnapshot.Supported;
    private readonly string _root;
    private readonly ProtectedSessionState _state;
    private readonly RunningProcess _watcher;
    private readonly ConcurrentDictionary<RunningProcess, ProcessTarget> _targets = new();
    private readonly HashSet<string> _received = new(StringComparer.OrdinalIgnoreCase);
    private readonly CancellationTokenSource _stop = new();
    private readonly ManualResetEventSlim _ready = new();
    private Thread? _capture;
    private volatile Exception? _failure;

    internal LaunchGpuHandles(string root, ProtectedSessionState state, RunningProcess watcher)
    {
        _root = Path.Combine(root, "gpu-handles"); _state = state; _watcher = watcher;
        Directory.CreateDirectory(_root);
    }

    internal void Start(ProcessJob job)
    {
        _capture = new Thread(() => Capture(job)) { IsBackground = true, Name = "GPU launch handles" };
        _capture.Start();
        if (!_ready.Wait(TimeSpan.FromSeconds(15))) throw new TimeoutException("GPU launch capture did not initialize.");
        Check();
    }

    internal void Check()
    {
        if (_failure is { } error) throw new InvalidOperationException("GPU launch capture failed: " + error.Message, error);
    }

    internal ProcessTarget? Find(RunningProcess identity)
        => _targets.TryGetValue(identity, out var target) ? target : null;

    internal bool RecoveryMatches(RunningProcess identity, ControlRead original, string field)
    {
        var path = ReadyPath(identity);
        if (!File.Exists(path)) return false;
        var ready = OperationFiles.Read<GpuHandleReady>(path);
        Validate(ready.Transfer);
        identity.Verify(ready.Transfer.Target);
        using var watcher = new ProcessTarget(_watcher.ProcessId);
        _watcher.Verify(watcher.Identity());
        var saved = field == "ioPriority" && _state.Preview.Controls.ContainsKey("gpuPriority") ? ready.IoOriginal : ready.Original;
        if (saved is null || !ProcessTarget.Equivalent(field, original.Require(), saved.Require()))
            throw new InvalidOperationException("The recovery handle observed a different original " + ProcessControlBlockedException.Label(field) + ".");
        return true;
    }

    internal void Receive()
    {
        foreach (var path in Directory.EnumerateFiles(_root, "*.transfer.json"))
        {
            if (_received.Contains(path)) continue;
            var transfer = OperationFiles.Read<GpuHandleTransfer>(path);
            Validate(transfer);
            if (!string.Equals(path, TransferPath(transfer.Target), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Retained GPU handoff path disagrees with its process identity.");
            var target = ProcessTarget.ReceiveGpu(transfer.Handle);
            try
            {
                if (!target.HasExited) transfer.Target.Verify(target.Identity());
                if (!_targets.TryAdd(transfer.Target, target)) throw new InvalidDataException("Duplicate retained GPU handoff.");
            }
            catch { target.Dispose(); throw; }
            _received.Add(path);
        }
        foreach (var pair in _targets)
        {
            var path = ReadyPath(pair.Key);
            if (File.Exists(path) || pair.Value.HasExited) continue;
            ControlRead original;
            ControlRead? io = null;
            var gpu = _state.Preview.Controls.ContainsKey("gpuPriority");
            try
            {
                original = pair.Value.Read(gpu ? "gpuPriority" : "ioPriority");
                if (gpu && _state.Preview.Controls.TryGetValue("ioPriority", out var desired) && desired.GetInt32() > LaunchPriorities.MaxIoPriority)
                    io = pair.Value.Read("ioPriority");
            }
            catch (ProcessEndedException) { continue; }
            if (Initializing(original, pair.Key)) continue;
            var transfer = OperationFiles.Read<GpuHandleTransfer>(TransferPath(pair.Key));
            Validate(transfer);
            OperationFiles.Write(path, new GpuHandleReady(transfer, original, io));
        }
    }

    internal static bool Initializing(ControlRead read, RunningProcess identity)
        => !read.Known && read.Error is { Api: "D3DKMTGetProcessSchedulingPriorityClass", CodeKind: "ntstatus", Code: 0xC000000D }
            && DateTime.UtcNow - DateTime.FromFileTimeUtc(long.Parse(identity.CreationTimeFileTimeUtc, System.Globalization.CultureInfo.InvariantCulture)) < TimeSpan.FromSeconds(90);

    private void Capture(ProcessJob job)
    {
        try
        {
            using var receiver = ProcessTarget.OpenReceiver(_watcher);
            using (var warm = ProcessTarget.CaptureGpu(Environment.ProcessId))
            {
                using var self = ProcessTarget.OpenReceiver(warm.Identity());
                using var copy = ProcessTarget.ReceiveGpu(warm.CopyTo(self));
                _ = copy.Read(_state.Preview.Controls.ContainsKey("gpuPriority") ? "gpuPriority" : "ioPriority");
            }
            using var snapshot = new LaunchProcessSnapshot(job);
            using var wake = _stop.Token.Register(snapshot.Wake);
            var image = Path.GetFileName(_state.Preview.GamePath);
            if (snapshot.Find(image).Length != 0) throw new InvalidOperationException("The game started before GPU capture was armed.");
            var seen = new HashSet<ulong>();
            _ready.Set();
            while (!_stop.IsCancellationRequested)
            {
                foreach (var process in snapshot.Find(image))
                {
                    if (!seen.Add(process.Sequence)) continue;
                    ProcessTarget? target = null;
                    try
                    {
                        try { target = ProcessTarget.CaptureGpu(process.Pid); }
                        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 5)
                        {
                            using var query = new ProcessTarget(process.Pid);
                            if (Reviewed(query.Identity())) throw;
                            continue;
                        }
                        var identity = target.Identity();
                        if (!Reviewed(identity)) continue;
                        var copy = target.CopyTo(receiver);
                        var transfer = new GpuHandleTransfer(_state.Preview.Owner, _state.Preview.OperationId, _state.Host, _watcher, identity, copy);
                        OperationFiles.Write(TransferPath(identity), transfer);
                        if (!_targets.TryAdd(identity, target)) throw new InvalidDataException("Duplicate GPU capture identity.");
                        target = null;
                    }
                    catch (ProcessEndedException) { }
                    catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { }
                    finally { target?.Dispose(); }
                }
                snapshot.WaitNext();
            }
        }
        catch (Exception error) { _failure = error; }
        finally { _ready.Set(); }
    }

    private bool Reviewed(RunningProcess identity) => string.Equals(identity.ExecutablePath, _state.Preview.GamePath, StringComparison.OrdinalIgnoreCase);

    private void Validate(GpuHandleTransfer transfer)
    {
        if (transfer.Owner is null || transfer.Target is null || transfer.Host is null || transfer.Watcher is null) throw new InvalidDataException("Incomplete GPU handle handoff.");
        transfer.Owner.Verify();
        if (transfer.Owner != _state.Preview.Owner || transfer.OperationId != _state.Preview.OperationId || transfer.Host != _state.Host || transfer.Watcher != _watcher ||
            transfer.Target.ProcessId <= 0 || !long.TryParse(transfer.Target.CreationTimeFileTimeUtc, out var created) || created <= 0 ||
            !Reviewed(transfer.Target))
            throw new InvalidDataException("GPU handle handoff belongs to a different session or process.");
    }

    private string TransferPath(RunningProcess identity) => Path.Combine(_root, identity.ProcessId + "-" + identity.CreationTimeFileTimeUtc + ".transfer.json");
    private string ReadyPath(RunningProcess identity) => Path.Combine(_root, identity.ProcessId + "-" + identity.CreationTimeFileTimeUtc + ".ready.json");

    public void Dispose()
    {
        _stop.Cancel(); _capture?.Join();
        foreach (var target in _targets.Values) target.Dispose();
        _stop.Dispose(); _ready.Dispose();
    }
}

internal sealed class LaunchProcessSnapshot : IDisposable
{
    internal static bool Supported
    {
        get
        {
            if (!OperatingSystem.IsWindows()) return false;
            var status = NtQuerySystemInformation(252, IntPtr.Zero, 0, out _);
            if (status == 0 || status == unchecked((int)0xC0000004)) return true;
            if (status == unchecked((int)0xC0000002) || status == unchecked((int)0xC0000003)) return false;
            throw new InvalidOperationException($"SystemBasicProcessInformation capability query failed with NTSTATUS 0x{status:X8}.");
        }
    }

    [StructLayout(LayoutKind.Sequential)] private struct BasicProcess
    {
        public uint Next; public IntPtr Pid, Parent; public ulong Sequence; public ushort NameLength, NameMaximum; public IntPtr Name;
    }
    private IntPtr _buffer = Marshal.AllocHGlobal(1024 * 1024);
    private uint _capacity = 1024 * 1024;
    private readonly ProcessJob _job;
    private readonly SafeWaitHandle _port;

    internal LaunchProcessSnapshot(ProcessJob job)
    {
        _job = job;
        _port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
        try
        {
            if (_port.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!Find(Path.GetFileName(Environment.ProcessPath!)).Any(process => process.Pid == Environment.ProcessId)) throw new InvalidDataException("Process enumeration did not identify the current host.");
            if (!job.Notify(_port)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        catch { Dispose(); throw; }
    }

    internal (int Pid, ulong Sequence)[] Find(string image)
    {
        int status; uint needed;
        while ((status = NtQuerySystemInformation(252, _buffer, _capacity, out needed)) == unchecked((int)0xC0000004))
        {
            if (needed > 8 * 1024 * 1024 || _capacity >= 8 * 1024 * 1024) throw new InvalidDataException("Process enumeration exceeded its size limit.");
            _capacity = Math.Max(_capacity * 2, needed); _buffer = Marshal.ReAllocHGlobal(_buffer, (IntPtr)_capacity);
        }
        if (status != 0) throw new InvalidOperationException($"SystemBasicProcessInformation requires Windows 11 build 26100.4770 or later; NTSTATUS 0x{status:X8}.");
        var found = new List<(int, ulong)>(); uint offset = 0; var size = (uint)Marshal.SizeOf<BasicProcess>();
        while (true)
        {
            if (offset > needed || needed - offset < size) throw new InvalidDataException("Incomplete process enumeration entry.");
            var entry = Marshal.PtrToStructure<BasicProcess>(IntPtr.Add(_buffer, checked((int)offset)));
            if (entry.NameLength == image.Length * 2)
            {
                var delta = entry.Name.ToInt64() - _buffer.ToInt64();
                if (delta < 0 || delta + entry.NameLength > needed) throw new InvalidDataException("Process name escaped the enumeration buffer.");
                if (string.Equals(Marshal.PtrToStringUni(entry.Name, entry.NameLength / 2), image, StringComparison.OrdinalIgnoreCase)) found.Add((checked((int)entry.Pid.ToInt64()), entry.Sequence));
            }
            if (entry.Next == 0) break;
            if (entry.Next < size) throw new InvalidDataException("Overlapping process enumeration entries.");
            offset = checked(offset + entry.Next);
        }
        return found.ToArray();
    }

    internal void WaitNext()
    {
        var deadline = Environment.TickCount64 + 1000;
        for (long left; (left = deadline - Environment.TickCount64) > 0;)
        {
            if (!GetQueuedCompletionStatus(_port, out var message, out _, out _, (uint)left))
            {
                var error = Marshal.GetLastWin32Error();
                if (error == 258) return;
                throw new Win32Exception(error);
            }
            if (message is 0 or 6) return;
        }
    }

    internal void Wake() => PostQueuedCompletionStatus(_port, 0, UIntPtr.Zero, IntPtr.Zero);

    public void Dispose() { _job.Notify(null); _port.Dispose(); if (_buffer != IntPtr.Zero) { Marshal.FreeHGlobal(_buffer); _buffer = IntPtr.Zero; } }
    [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int kind, IntPtr data, uint size, out uint needed);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeWaitHandle CreateIoCompletionPort(IntPtr file, IntPtr port, UIntPtr key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetQueuedCompletionStatus(SafeWaitHandle port, out uint message, out UIntPtr key, out IntPtr process, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool PostQueuedCompletionStatus(SafeWaitHandle port, uint message, UIntPtr key, IntPtr process);
}
