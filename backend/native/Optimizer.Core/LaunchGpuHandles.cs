#nullable enable
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

internal sealed record GpuHandleTransfer(OperationOwner Owner, string OperationId, RunningProcess Host, RunningProcess Watcher, RunningProcess Target, long Handle);
internal sealed record GpuHandleReady(GpuHandleTransfer Transfer, ControlRead Original);

internal sealed class LaunchGpuHandles : IDisposable
{
    internal static bool Supported => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100, 4770);
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

    internal void Start()
    {
        _capture = new Thread(Capture) { IsBackground = true, Name = "GPU launch handles" };
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

    internal bool RecoveryMatches(RunningProcess identity, ControlRead original)
    {
        var path = ReadyPath(identity);
        if (!File.Exists(path)) return false;
        var ready = OperationFiles.Read<GpuHandleReady>(path);
        Validate(ready.Transfer);
        identity.Verify(ready.Transfer.Target);
        using var watcher = new ProcessTarget(_watcher.ProcessId);
        _watcher.Verify(watcher.Identity());
        if (!ProcessTarget.Equivalent("gpuPriority", original.Require(), ready.Original.Require()))
            throw new InvalidOperationException("The recovery handle observed a different original GPU class.");
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
            try { original = pair.Value.Read("gpuPriority"); }
            catch (ProcessEndedException) { continue; }
            if (Initializing(original, pair.Key)) continue;
            var transfer = OperationFiles.Read<GpuHandleTransfer>(TransferPath(pair.Key));
            Validate(transfer);
            OperationFiles.Write(path, new GpuHandleReady(transfer, original));
        }
    }

    internal static bool Initializing(ControlRead read, RunningProcess identity)
        => !read.Known && read.Error is { Api: "D3DKMTGetProcessSchedulingPriorityClass", CodeKind: "ntstatus", Code: 0xC000000D }
            && DateTime.UtcNow - DateTime.FromFileTimeUtc(long.Parse(identity.CreationTimeFileTimeUtc, System.Globalization.CultureInfo.InvariantCulture)) < TimeSpan.FromSeconds(90);

    private void Capture()
    {
        try
        {
            using var receiver = ProcessTarget.OpenReceiver(_watcher);
            using (var warm = ProcessTarget.CaptureGpu(Environment.ProcessId))
            {
                using var self = ProcessTarget.OpenReceiver(warm.Identity());
                using var copy = ProcessTarget.ReceiveGpu(warm.CopyTo(self));
                _ = copy.Read("gpuPriority");
            }
            using var snapshot = new LaunchProcessSnapshot();
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
                        target = ProcessTarget.CaptureGpu(process.Pid);
                        var copy = target.CopyTo(receiver);
                        var identity = target.Identity();
                        if (!string.Equals(identity.ExecutablePath, _state.Preview.GamePath, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("A launch matched the name but not the reviewed executable.");
                        var transfer = new GpuHandleTransfer(_state.Preview.Owner, _state.Preview.OperationId, _state.Host, _watcher, identity, copy);
                        OperationFiles.Write(TransferPath(identity), transfer);
                        if (!_targets.TryAdd(identity, target)) throw new InvalidDataException("Duplicate GPU capture identity.");
                        target = null;
                    }
                    catch (ProcessEndedException) { }
                    catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { }
                    finally { target?.Dispose(); }
                }
                if (_targets.Values.Any(target => !target.HasExited)) _stop.Token.WaitHandle.WaitOne(50);
                else snapshot.WaitNext();
            }
        }
        catch (Exception error) { _failure = error; }
        finally { _ready.Set(); }
    }

    private void Validate(GpuHandleTransfer transfer)
    {
        if (transfer.Owner is null || transfer.Target is null || transfer.Host is null || transfer.Watcher is null) throw new InvalidDataException("Incomplete GPU handle handoff.");
        transfer.Owner.Verify();
        if (transfer.Owner != _state.Preview.Owner || transfer.OperationId != _state.Preview.OperationId || transfer.Host != _state.Host || transfer.Watcher != _watcher ||
            transfer.Target.ProcessId <= 0 || !long.TryParse(transfer.Target.CreationTimeFileTimeUtc, out var created) || created <= 0 ||
            !string.Equals(transfer.Target.ExecutablePath, _state.Preview.GamePath, StringComparison.OrdinalIgnoreCase))
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
    [StructLayout(LayoutKind.Sequential)] private struct BasicProcess
    {
        public uint Next; public IntPtr Pid, Parent; public ulong Sequence; public ushort NameLength, NameMaximum; public IntPtr Name;
    }
    private IntPtr _buffer = Marshal.AllocHGlobal(1024 * 1024);
    private uint _capacity = 1024 * 1024;
    private readonly SafeWaitHandle _timer;

    internal LaunchProcessSnapshot()
    {
        _timer = CreateWaitableTimerEx(IntPtr.Zero, null, 2, 0x100002);
        try
        {
            if (_timer.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!Find(Path.GetFileName(Environment.ProcessPath!)).Any(process => process.Pid == Environment.ProcessId)) throw new InvalidDataException("Process enumeration did not identify the current host.");
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
        long due = -10000;
        if (!SetWaitableTimer(_timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (WaitForSingleObject(_timer, 1000) != 0) throw new InvalidOperationException("GPU launch capture timer failed.");
    }

    public void Dispose() { _timer.Dispose(); if (_buffer != IntPtr.Zero) { Marshal.FreeHGlobal(_buffer); _buffer = IntPtr.Zero; } }
    [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int kind, IntPtr data, uint size, out uint needed);
    [DllImport("kernel32.dll", EntryPoint = "CreateWaitableTimerExW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeWaitHandle CreateWaitableTimerEx(IntPtr attributes, string? name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long due, int period, IntPtr callback, IntPtr context, bool resume);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(SafeWaitHandle handle, uint milliseconds);
}
