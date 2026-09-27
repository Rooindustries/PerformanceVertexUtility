#nullable enable
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ComponentModel;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed record TimerLaunch(OperationOwner Owner, string SessionId, string Root, string AssemblyPath, string AssemblyHash);
public sealed record TimerWorkerState(TimerLaunch Launch, int ProcessId, long CreationTime, string Executable, bool Acquired, bool Released, int AcquireStatus, int? ReleaseStatus, uint ReturnedInterval, string? Error);

public static class TimerControl
{
    internal static string Root(ControlAddress address)
    {
        if (address.Property != "half-millisecond") throw new InvalidDataException("Unknown timer request.");
        return address.Target == "system" ? Path.Combine(BrandCompatibility.LocalDataRoot, "operations", "windows-timer")
            : address.Target.StartsWith("fixture:", StringComparison.Ordinal) ? FileAccessControl.FixturePath(address.Target[8..])
            : throw new InvalidDataException("Unknown timer owner.");
    }
    private static string StatePath(string root) => Path.Combine(root, "session.json");
    private static TimerWorkerState? State(string root)
    {
        if (!File.Exists(StatePath(root))) return null;
        var state = ReadJson<TimerWorkerState>(StatePath(root)); state.Launch.Owner.Verify();
        if (state.Launch.Root != root) throw new InvalidDataException("Timer state belongs to a different directory.");
        return state;
    }
    private static T ReadJson<T>(string path)
    {
        for (var attempt = 0; ; attempt++)
        {
            try { return OperationFiles.Read<T>(path); }
            catch (IOException error) when (attempt < 10 && (error.HResult & 0xffff) is 32 or 33) { Thread.Sleep(20); }
        }
    }
    private static Process? Running(TimerWorkerState state)
    {
        try
        {
            var process = Process.GetProcessById(state.ProcessId);
            if (!process.HasExited && process.StartTime.ToUniversalTime().ToFileTimeUtc() == state.CreationTime && string.Equals(process.MainModule?.FileName, state.Executable, StringComparison.OrdinalIgnoreCase)) return process;
            process.Dispose(); return null;
        }
        catch (ArgumentException) { return null; }
    }
    public static TweakControlRead Read(ControlAddress address)
    {
        var root = Root(address); var state = State(root);
        Check(NtQueryTimerResolution(out var coarsest, out var finest, out _), "NtQueryTimerResolution");
        if (finest > 5000 || coarsest < 5000) throw new InvalidDataException("This PC does not expose a 0.5 ms native timer interval.");
        using var process = state is null ? null : Running(state);
        var active = process is not null && state!.Acquired && !state.Released;
        return new(address, "timer:" + root.ToUpperInvariant(), "native-timer:" + finest + ":" + coarsest, ControlValues.From(active),
            active ? "0.5 ms timer request is active" : state?.Error is not null ? "Timer stopped: " + state.Error : "0.5 ms timer request is stopped", LostLease: state is { Acquired: true, Released: false } && process is null);
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var root = Root(before.Address); Directory.CreateDirectory(root);
        using var guard = OperationFiles.Lock(Path.Combine(root, "control"));
        if (!Read(before.Address).Same(before)) throw new InvalidDataException("Timer ownership changed after review.");
        if (desired.GetBoolean()) Start(root);
        else Stop(root);
    }
    private static void Start(string root)
    {
        var existing = State(root);
        using var prior = existing is null ? null : Running(existing);
        if (prior is not null) throw new InvalidOperationException("An existing timer worker has not stopped.");
        var assembly = Assembly.GetEntryAssembly()?.Location ?? throw new InvalidDataException("Timer worker packaging is unavailable.");
        var launch = new TimerLaunch(OperationOwner.Current(), Guid.NewGuid().ToString("N"), root, assembly, OperationFiles.HashFile(assembly));
        var path = Path.Combine(root, "launch.json"); OperationFiles.Write(path, launch);
        var executable = Environment.ProcessPath ?? throw new InvalidDataException("Timer host executable is unavailable.");
        var command = new StringBuilder().Append('"').Append(executable).Append('"');
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) command.Append(" \"").Append(assembly).Append('"');
        command.Append(" --timer-worker \"").Append(path).Append('"');
        var created = LaunchWorker(executable, command);
        Process worker;
        try { worker = Process.GetProcessById(created.ProcessId); }
        finally { CloseHandle(created.Thread); CloseHandle(created.Process); }
        using var workerLifetime = worker;
        try
        {
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(15))
            {
                var state = State(root);
                if (state?.Launch.SessionId == launch.SessionId)
                {
                    if (state.Error is not null) throw new IOException(state.Error);
                    if (state.ProcessId == worker.Id && state.Acquired && !state.Released) return;
                }
                if (worker.HasExited) throw new IOException("Timer worker exited before acquisition: " + worker.ExitCode);
                Thread.Sleep(50);
            }
            throw new TimeoutException("Timer worker did not confirm acquisition.");
        }
        catch
        {
            OperationFiles.Write(Path.Combine(root, "stop.json"), launch);
            if (!worker.WaitForExit(5000)) { worker.Kill(); worker.WaitForExit(); }
            throw;
        }
    }
    private static void Stop(string root)
    {
        var state = State(root); if (state is null) return;
        using var worker = Running(state);
        if (worker is not null)
        {
            OperationFiles.Write(Path.Combine(root, "stop.json"), state.Launch);
            if (!worker.WaitForExit(10000)) throw new TimeoutException("The identified timer worker has not stopped; its recovery state was retained.");
            var stopped = State(root);
            if (stopped?.Launch.SessionId != state.Launch.SessionId || !stopped.Released || stopped.ReleaseStatus is null or < 0) throw new IOException(stopped?.Error ?? "The timer worker did not confirm release.");
        }
        foreach (var name in new[] { "launch.json", "stop.json", "session.json" }) File.Delete(Path.Combine(root, name));
    }
    public static void RunWorker(string launchPath)
        => RunWorker(launchPath, null);
    private static void RunWorker(string launchPath, Action? ready)
    {
        var launch = OperationFiles.Read<TimerLaunch>(launchPath); launch.Owner.Verify();
        if (Path.GetFullPath(launchPath) != Path.Combine(launch.Root, "launch.json") || launch.AssemblyPath != Assembly.GetEntryAssembly()?.Location || OperationFiles.HashFile(launch.AssemblyPath) != launch.AssemblyHash)
            throw new InvalidDataException("The timer worker launch identity changed.");
        using var lease = OperationFiles.Lock(Path.Combine(launch.Root, "worker"));
        using var process = Process.GetCurrentProcess();
        var state = new TimerWorkerState(launch, process.Id, process.StartTime.ToUniversalTime().ToFileTimeUtc(), Environment.ProcessPath!, false, false, 0, null, 0, null);
        OperationFiles.Write(StatePath(launch.Root), state);
        try
        {
            var result = NtSetTimerResolution(5000, true, out var interval);
            state = state with { AcquireStatus = result, ReturnedInterval = interval, Acquired = result >= 0 };
            OperationFiles.Write(StatePath(launch.Root), state); Check(result, "NtSetTimerResolution(acquire)");
            ready?.Invoke();
            while (true)
            {
                var path = Path.Combine(launch.Root, "stop.json");
                if (File.Exists(path))
                {
                    var stop = ReadJson<TimerLaunch>(path);
                    if (stop == launch) break;
                }
                Thread.Sleep(100);
            }
        }
        catch (Exception error) { state = state with { Error = error.Message }; }
        finally
        {
            if (state.Acquired)
            {
                var result = NtSetTimerResolution(5000, false, out var interval);
                state = state with { ReleaseStatus = result, ReturnedInterval = interval, Released = result >= 0, Error = result < 0 ? "NtSetTimerResolution(release) failed with NTSTATUS 0x" + result.ToString("X8") : state.Error };
            }
            OperationFiles.Write(StatePath(launch.Root), state);
        }
    }
    public static void RunAutostart(string root)
    {
        root = Path.GetFullPath(root); TimerStartupControl.RequireOwned(root);
        using var guard = OperationFiles.Lock(Path.Combine(root, "control"));
        var state = State(root); using var running = state is null ? null : Running(state);
        if (running is not null) return;
        var assembly = Assembly.GetEntryAssembly()!.Location;
        var launch = new TimerLaunch(OperationOwner.Current(), Guid.NewGuid().ToString("N"), root, assembly, OperationFiles.HashFile(assembly));
        var path = Path.Combine(root, "launch.json"); OperationFiles.Write(path, launch);
        RunWorker(path, guard.Dispose);
    }
    private static ProcessInfo LaunchWorker(string executable, StringBuilder command)
    {
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        if (CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x09000000, IntPtr.Zero, null, ref startup, out var created)) return created;
        var error = Marshal.GetLastWin32Error();
        if (error != 5) throw new Win32Exception(error, "CreateProcessW(timer worker) failed with Win32 " + error + ".");
        if (LaunchFromShell(executable, command) is { } shellChild) return shellChild;
        if (!IsProcessInJob(Process.GetCurrentProcess().Handle, IntPtr.Zero, out var inJob) || !inJob) throw new Win32Exception(error, "CreateProcessW(timer worker) failed with Win32 " + error + ".");
        if (JobEndsProcessesOnClose()) throw new InvalidOperationException("The timer can't keep running after this app closes because Windows started the app inside a job that ends its processes. Start Roo Industries from the Start menu or desktop shortcut and try again.");
        if (CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref startup, out created)) return created;
        error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, "CreateProcessW(timer worker) failed with Win32 " + error + ".");
    }
    private static ProcessInfo? LaunchFromShell(string executable, StringBuilder command)
    {
        var window = GetShellWindow();
        if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out var shellId) == 0 || shellId == 0) return null;
        var shell = OpenProcess(0x0080 | 0x0400, false, shellId);
        if (shell == IntPtr.Zero) return null;
        try
        {
            if (!OpenProcessToken(shell, 0x0008, out var token)) return null;
            try { using var identity = new WindowsIdentity(token); if (identity.User?.Value != OperationOwner.Current().UserSid) return null; }
            catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or ArgumentException) { return null; }
            finally { CloseHandle(token); }
            var size = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            var list = Marshal.AllocHGlobal(size); var parent = Marshal.AllocHGlobal(IntPtr.Size);
            try
            {
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) return null;
                try
                {
                    Marshal.WriteIntPtr(parent, shell);
                    if (!UpdateProcThreadAttribute(list, 0, 0x00020000, parent, IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) return null;
                    var startup = new StartupInfoEx { Startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>() }, Attributes = list };
                    return CreateProcessWithParent(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x08080000, IntPtr.Zero, null, ref startup, out var created) ? created : null;
                }
                finally { DeleteProcThreadAttributeList(list); }
            }
            finally { Marshal.FreeHGlobal(parent); Marshal.FreeHGlobal(list); }
        }
        finally { CloseHandle(shell); }
    }
    private static bool JobEndsProcessesOnClose()
    {
        if (!QueryInformationJobObject(IntPtr.Zero, 9, out var limits, (uint)Marshal.SizeOf<JobLimits>(), IntPtr.Zero))
        {
            var error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, "QueryInformationJobObject(timer worker job) failed with Win32 " + error + ".");
        }
        return (limits.Flags & 0x2000) != 0;
    }
    private static void Check(int status, string api) { if (status < 0) throw new InvalidOperationException(api + " failed with NTSTATUS 0x" + status.ToString("X8")); }
    [StructLayout(LayoutKind.Sequential)]
    private struct JobLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int kind, out JobLimits value, uint size, IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcessWithParent(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, IntPtr environment, string? directory, ref StartupInfoEx startup, out ProcessInfo process);
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool result);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int processId);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size; public string? Reserved, Desktop, Title;
        public uint X, Y, Width, Height, Columns, Rows, Fill, Flags;
        public ushort Show, ReservedSize; public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("ntdll.dll")] private static extern int NtQueryTimerResolution(out uint coarsest, out uint finest, out uint current);
    [DllImport("ntdll.dll")] private static extern int NtSetTimerResolution(uint requested, [MarshalAs(UnmanagedType.U1)] bool acquire, out uint current);
}
