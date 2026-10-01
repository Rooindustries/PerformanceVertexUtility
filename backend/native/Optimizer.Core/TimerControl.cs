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
    internal sealed record Roots(string Control, string State);

    internal static bool AllowElevatedWorker
    {
        get
        {
#if GOVERNOR_TEST_HOOKS
            return Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_ALLOW_ELEVATED_TIMER_WORKER") == "1";
#else
            return false;
#endif
        }
    }

    public static string StateFolder
    {
        get
        {
#if GOVERNOR_TEST_HOOKS
            if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE") is { Length: > 0 } test) return test;
#endif
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RooIndustriesOptimizationSuite.Timer");
        }
    }

    internal static string SystemControl
    {
        get
        {
#if GOVERNOR_TEST_HOOKS
            if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_CONTROL") is { Length: > 0 } test) return Path.GetFullPath(test).TrimEnd(Path.DirectorySeparatorChar);
#endif
            return Path.Combine(OperationsFolder.DefaultRoot, OperationsFolder.TimerFolder);
        }
    }

    internal static bool IsSystemControl(string control) => string.Equals(Path.GetFullPath(control).TrimEnd(Path.DirectorySeparatorChar), SystemControl, StringComparison.OrdinalIgnoreCase);

    internal static Roots RootsFor(ControlAddress address)
    {
        if (address.Property != "half-millisecond") throw new InvalidDataException("Unknown timer request.");
        if (address.Target == "system") return new(SystemControl, StateFolder);
        if (address.Target.StartsWith("fixture:", StringComparison.Ordinal)) { var path = FileAccessControl.FixturePath(address.Target[8..]); return new(path, path); }
        throw new InvalidDataException("Unknown timer owner.");
    }
    internal static string Root(ControlAddress address) => RootsFor(address).Control;
    internal static Roots RootsOf(string control)
    {
        control = Path.GetFullPath(control).TrimEnd(Path.DirectorySeparatorChar);
        return IsSystemControl(control) ? new(control, StateFolder) : new(control, control);
    }
    private static bool Split(Roots roots) => !string.Equals(Path.GetFullPath(roots.State), Path.GetFullPath(roots.Control), StringComparison.OrdinalIgnoreCase);
    private static string StatePath(Roots roots) => Path.Combine(roots.State, "session.json");
    private static string RetiredPath(Roots roots) => Path.Combine(roots.Control, "retired.json");
    private sealed record Retired(string[] Sessions);
    private static TimerWorkerState? Parse(byte[]? bytes)
    {
        if (bytes is null) return null;
        try
        {
            var state = OperationFiles.Deserialize<TimerWorkerState>(bytes);
            state.Launch.Owner.Verify();
            return string.IsNullOrEmpty(state.Launch.SessionId) || string.IsNullOrEmpty(state.Executable) || state.ProcessId <= 0 ? null : state;
        }
        catch (Exception error) when (error is not OutOfMemoryException) { return null; }
    }
    private static TimerWorkerState? State(Roots roots)
    {
        var state = Parse(NativeFiles.ReadBounded(roots.State, "session.json", 1 << 16, out _));
        if (state is null || !string.Equals(state.Launch.Root, roots.Control, StringComparison.OrdinalIgnoreCase)) return null;
        return Retirements(roots).Contains(state.Launch.SessionId) ? null : state;
    }
    private static string[] Retirements(Roots roots)
    {
        try { return NativeFiles.ReadBounded(roots.Control, "retired.json", 1 << 16, out _) is { } bytes ? OperationFiles.Deserialize<Retired>(bytes).Sessions ?? [] : []; }
        catch (Exception error) when (error is not OutOfMemoryException) { return []; }
    }
    private static void Retire(Roots roots, string session)
        => OperationFiles.Write(RetiredPath(roots), new Retired(Retirements(roots).Append(session).TakeLast(8).ToArray()));
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
        Process process;
        try { process = Process.GetProcessById(state.ProcessId); }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException) { return null; }
        try
        {
            if (!process.HasExited && process.StartTime.ToUniversalTime().ToFileTimeUtc() == state.CreationTime && string.Equals(process.MainModule?.FileName, state.Executable, StringComparison.OrdinalIgnoreCase)) return process;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or NotSupportedException or ArgumentException) { }
        process.Dispose();
        return null;
    }
    public static TweakControlRead Read(ControlAddress address)
    {
        var roots = RootsFor(address); var state = State(roots);
        Check(NtQueryTimerResolution(out var coarsest, out var finest, out _), "NtQueryTimerResolution");
        if (finest > 5000 || coarsest < 5000) throw new InvalidDataException("This PC does not expose a 0.5 ms native timer interval.");
        using var process = state is null ? null : Running(state);
        var active = process is not null && state!.Acquired && !state.Released;
        return new(address, "timer:" + roots.Control.ToUpperInvariant(), "native-timer:" + finest + ":" + coarsest, ControlValues.From(active),
            active ? "0.5 ms timer request is active" : state?.Error is not null ? "Timer stopped: " + state.Error : "0.5 ms timer request is stopped", LostLease: state is { Acquired: true, Released: false } && process is null);
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var roots = RootsFor(before.Address);
        var system = before.Address.Target == "system";
        if (system) OperationsFolder.Ensure(Path.GetDirectoryName(roots.Control)!);
        Directory.CreateDirectory(roots.Control);
        if (system) OperationsFolder.RequireControlFolder(roots.Control);
        using var guard = OperationFiles.Lock(Path.Combine(roots.Control, "control"));
        if (!Read(before.Address).Same(before)) throw new InvalidDataException("Timer ownership changed after review.");
        if (desired.GetBoolean()) Start(roots); else Stop(roots);
    }
    private static void Start(Roots roots)
    {
        var existing = State(roots);
        using var prior = existing is null ? null : Running(existing);
        if (prior is not null) throw new InvalidOperationException("An existing timer worker has not stopped.");
        var assembly = Assembly.GetEntryAssembly()?.Location ?? throw new InvalidDataException("Timer worker packaging is unavailable.");
        var launch = new TimerLaunch(OperationOwner.Current(), Guid.NewGuid().ToString("N"), roots.Control, assembly, OperationFiles.HashFile(assembly));
        var path = Path.Combine(roots.Control, "launch.json");
        var executable = Environment.ProcessPath ?? throw new InvalidDataException("Timer host executable is unavailable.");
        var command = new StringBuilder().Append('"').Append(executable).Append('"');
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) command.Append(" \"").Append(assembly).Append('"');
        command.Append(" --timer-worker \"").Append(path).Append('"');
        var userToken = Split(roots) && PolicyRootSecurity.SplitToken() && !AllowElevatedWorker;
        OperationFiles.Write(path, launch);
        ProcessInfo created;
        try { created = LaunchWorker(executable, command, userToken); }
        catch { File.Delete(path); throw; }
        Process worker;
        try { worker = Process.GetProcessById(created.ProcessId); }
        finally { CloseHandle(created.Thread); CloseHandle(created.Process); }
        using var workerLifetime = worker;
        try
        {
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(15))
            {
                var state = State(roots);
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
            OperationFiles.Write(Path.Combine(roots.Control, "stop.json"), launch);
            if (!worker.WaitForExit(5000)) { worker.Kill(); worker.WaitForExit(); }
            throw;
        }
    }
    private static void Stop(Roots roots)
    {
        var state = State(roots);
        if (state is not null)
        {
            using var worker = Running(state);
            if (worker is not null)
            {
                OperationFiles.Write(Path.Combine(roots.Control, "stop.json"), state.Launch);
                if (!worker.WaitForExit(10000)) throw new TimeoutException("The identified timer worker has not stopped; its recovery state was retained.");
                var stopped = State(roots);
                if (stopped?.Launch.SessionId != state.Launch.SessionId || !stopped.Released || stopped.ReleaseStatus is null or < 0) throw new IOException(stopped?.Error ?? "The timer worker did not confirm release.");
            }
            Retire(roots, state.Launch.SessionId);
        }
        foreach (var name in new[] { "launch.json", "stop.json" }) File.Delete(Path.Combine(roots.Control, name));
    }
    internal static bool EndLegacyWorker(string operations, Action? found)
    {
        var folder = Path.Combine(PolicyRootSecurity.Normalize(operations), OperationsFolder.TimerFolder);
        var state = Parse(NativeFiles.ReadBounded(folder, "session.json", 1 << 16, out _));
        if (state is null || !state.Acquired || state.Released) return false;
        using var worker = Running(state);
        if (worker is null || CommandLine(worker) is not { } command || !command.Contains("--timer-worker", StringComparison.Ordinal) && !command.Contains("--timer-autostart", StringComparison.Ordinal)) return false;
        found?.Invoke();
        try { worker.Kill(); worker.WaitForExit(10000); }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception) { return false; }
        return true;
    }
    internal static void StartAfterMove(string operations)
    {
        var roots = new Roots(OperationsFolder.EnsureTimerFolder(operations), StateFolder);
        using var guard = OperationFiles.Lock(Path.Combine(roots.Control, "control"));
        Start(roots);
    }
    private static string? CommandLine(Process process)
    {
        try
        {
            NtQueryInformationProcess(process.Handle, 60, IntPtr.Zero, 0, out var size);
            if (size == 0 || size > 1 << 20) return null;
            var buffer = Marshal.AllocHGlobal((int)size + 2);
            try
            {
                if (NtQueryInformationProcess(process.Handle, 60, buffer, size, out _) < 0) return null;
                var length = (ushort)Marshal.ReadInt16(buffer);
                return Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer, IntPtr.Size), length / 2);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or NotSupportedException) { return null; }
    }
    public static void RunWorker(string launchPath)
        => RunWorker(launchPath, null);
    private static void RunWorker(string launchPath, Action? ready)
    {
        var launch = OperationFiles.Read<TimerLaunch>(launchPath); launch.Owner.Verify();
        var roots = RootsOf(launch.Root);
        var full = Path.GetFullPath(launchPath);
        if (!string.Equals(full, Path.Combine(roots.Control, "launch.json"), StringComparison.OrdinalIgnoreCase) && !string.Equals(full, Path.Combine(roots.State, "launch.json"), StringComparison.OrdinalIgnoreCase) ||
            launch.AssemblyPath != Assembly.GetEntryAssembly()?.Location || OperationFiles.HashFile(launch.AssemblyPath) != launch.AssemblyHash)
            throw new InvalidDataException("The timer worker launch identity changed.");
        if (Split(roots) && PolicyRootSecurity.SplitToken() && !AllowElevatedWorker) throw new UnauthorizedAccessException("The timer worker keeps its state where ordinary programs can write, so it only runs with your normal Windows rights, not as administrator.");
        Directory.CreateDirectory(roots.State);
        using var lease = OperationFiles.Lock(Path.Combine(roots.State, "worker"));
        using var process = Process.GetCurrentProcess();
        var state = new TimerWorkerState(launch, process.Id, process.StartTime.ToUniversalTime().ToFileTimeUtc(), Environment.ProcessPath!, false, false, 0, null, 0, null);
        OperationFiles.Write(StatePath(roots), state);
        try
        {
            var power = new TimerPower { Version = 1, ControlMask = 4, StateMask = 0 };
            SetProcessInformation(CurrentProcess(), 4, ref power, (uint)Marshal.SizeOf<TimerPower>());
            var result = NtSetTimerResolution(5000, true, out var interval);
            state = state with { AcquireStatus = result, ReturnedInterval = interval, Acquired = result >= 0 };
            OperationFiles.Write(StatePath(roots), state); Check(result, "NtSetTimerResolution(acquire)");
            var applied = Stopwatch.StartNew(); uint current;
            while (NtQueryTimerResolution(out _, out _, out current) < 0 || current > 5000)
            {
                if (applied.Elapsed > TimeSpan.FromSeconds(2)) throw new InvalidOperationException("Windows did not apply the 0.5 ms timer request (current interval " + (current / 10000.0).ToString("0.###", System.Globalization.CultureInfo.InvariantCulture) + " ms).");
                Thread.Sleep(50);
            }
            ready?.Invoke();
            while (true)
            {
                var path = Path.Combine(roots.Control, "stop.json");
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
            OperationFiles.Write(StatePath(roots), state);
        }
    }
    public static void RunAutostart(string root)
    {
        var roots = RootsOf(root); TimerStartupControl.RequireOwned(roots.Control);
        if (Split(roots) && PolicyRootSecurity.SplitToken() && !AllowElevatedWorker) throw new UnauthorizedAccessException("The timer's sign-in task must run with your normal Windows rights, not as administrator.");
        Directory.CreateDirectory(roots.State);
        using var guard = OperationFiles.Lock(Path.Combine(roots.State, "control"));
        var state = State(roots); using var running = state is null ? null : Running(state);
        if (running is not null) return;
        var assembly = Assembly.GetEntryAssembly()!.Location;
        var launch = new TimerLaunch(OperationOwner.Current(), Guid.NewGuid().ToString("N"), roots.Control, assembly, OperationFiles.HashFile(assembly));
        var path = Path.Combine(roots.State, "launch.json"); OperationFiles.Write(path, launch);
        RunWorker(path, guard.Dispose);
    }
    private static ProcessInfo LaunchWorker(string executable, StringBuilder command, bool userToken)
    {
        if (userToken) return LaunchFromShell(executable, command) ?? throw new InvalidOperationException("The timer needs Windows to start it with your normal rights, but no desktop shell of your Windows user is running. Sign in to Windows normally, then try again.");
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        if (CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x09000000, IntPtr.Zero, null, ref startup, out var created)) return created;
        var error = Marshal.GetLastWin32Error();
        if (error != 5) throw new Win32Exception(error, "CreateProcessW(timer worker) failed with Win32 " + error + ".");
        if (LaunchFromShell(executable, command) is { } shellChild) return shellChild;
        if (!IsProcessInJob(CurrentProcess(), IntPtr.Zero, out var inJob) || !inJob) throw new Win32Exception(error, "CreateProcessW(timer worker) failed with Win32 " + error + ".");
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
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr process, int kind, IntPtr information, uint length, out uint returned);
    [StructLayout(LayoutKind.Sequential)] private struct TimerPower { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll", EntryPoint = "GetCurrentProcess")] private static extern IntPtr CurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetProcessInformation(IntPtr process, int informationClass, ref TimerPower value, uint size);
    [DllImport("ntdll.dll")] private static extern int NtQueryTimerResolution(out uint coarsest, out uint finest, out uint current);
    [DllImport("ntdll.dll")] private static extern int NtSetTimerResolution(uint requested, [MarshalAs(UnmanagedType.U1)] bool acquire, out uint current);
}
