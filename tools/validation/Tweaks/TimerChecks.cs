using System.Diagnostics;
using System.Runtime.InteropServices;
using RooIndustries.Optimizer;

static class TimerChecks
{
    public static void DetachedStart(string root)
    {
        if (Directory.Exists(root)) throw new InvalidDataException("Detached timer fixture directory already exists.");
        var address = new ControlAddress("timer", "fixture:" + Path.Combine(root, "timer"), "half-millisecond");
        var store = new WindowsControlStore(); var before = store.Read(address);
        store.Write(before, ControlValues.From(true));
        using var process = Process.GetCurrentProcess();
        OperationFiles.Write(Path.Combine(root, "parent.json"), new { process.Id, Created = process.StartTime.ToUniversalTime().ToFileTimeUtc() });
        Console.WriteLine("PASS detached fixture started; verify from a new session after this process exits");
    }
    public static void DetachedStop(string root)
    {
        var address = new ControlAddress("timer", "fixture:" + Path.Combine(root, "timer"), "half-millisecond");
        var store = new WindowsControlStore();
        try
        {
            var parent = OperationFiles.Read<System.Text.Json.JsonElement>(Path.Combine(root, "parent.json"));
            var parentRunning = false;
            try
            {
                using var process = Process.GetProcessById(parent.GetProperty("id").GetInt32());
                parentRunning = !process.HasExited && process.StartTime.ToUniversalTime().ToFileTimeUtc() == parent.GetProperty("created").GetInt64();
            }
            catch (ArgumentException) { }
            if (parentRunning || !store.Read(address).Value.GetBoolean()) throw new InvalidDataException("Timer did not survive the exited parent process.");
            Console.WriteLine("PASS worker survives the exited parent process and SSH session");
        }
        finally
        {
            var current = store.Read(address);
            if (current.Value.GetBoolean() || current.LostLease) store.Write(current, ControlValues.From(false));
            Directory.Delete(root, true);
        }
        Console.WriteLine("PASS detached worker released and fixture removed");
    }
    public static void JobStart(string root, bool endsOnClose)
    {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject");
        var limits = new JobLimits { Flags = endsOnClose ? 0x2000u : 0 };
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject");
        if (!AssignProcessToJobObject(job, GetCurrentProcess())) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject");
        DetachedStart(root);
    }
    public static void Job(Action<bool, string> check)
    {
        foreach (var endsOnClose in new[] { false, true })
        {
            var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"));
            var address = new ControlAddress("timer", "fixture:" + Path.Combine(root, "timer"), "half-millisecond");
            try
            {
                var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (var argument in new[] { "--timer-job-start", root, endsOnClose ? "ends-on-close" : "keeps-processes" }) start.ArgumentList.Add(argument);
                using var child = Process.Start(start)!;
                var output = child.StandardOutput.ReadToEndAsync(); var error = child.StandardError.ReadToEndAsync();
                if (!child.WaitForExit(60000)) { child.Kill(true); throw new TimeoutException("The job-restricted timer start did not finish."); }
                Thread.Sleep(1500);
                var store = new WindowsControlStore(); var read = store.Read(address);
                check(child.ExitCode == 0 && read.Value.GetBoolean() && !read.LostLease,
                    "A timer started inside a job that forbids breakaway" + (endsOnClose ? " and ends its processes on close" : "") + " keeps running after that job's process exits: " + output.Result.Trim() + error.Result.Trim());
            }
            finally
            {
                var store = new WindowsControlStore(); var current = store.Read(address);
                if (current.Value.GetBoolean() || current.LostLease) store.Write(current, ControlValues.From(false));
                if (Directory.Exists(root)) Directory.Delete(root, true);
            }
        }
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
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
    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref JobLimits value, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    public static void Native(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"));
        var address = new ControlAddress("timer", "fixture:" + Path.Combine(root, "timer"), "half-millisecond");
        var store = new WindowsControlStore(); var before = store.Read(address);
        if (before.Value.GetBoolean()) throw new InvalidDataException("A disposable timer fixture must start inactive.");
        var plan = new ControlPlan([before], [new(before, ControlValues.From(true))], []);
        try
        {
            ControlExecution.Apply(plan, store, _ => { });
            var state = OperationFiles.Read<TimerWorkerState>(Path.Combine(root, "timer", "session.json"));
            check(state.Acquired && state.AcquireStatus >= 0 && state.ReturnedInterval <= 5000, "Native timer worker confirms its 0.5 ms request and returned interval");
            Thread.Sleep(1500);
            check(store.Read(address).Value.GetBoolean(), "Timer remains active after the start call returns");
            ControlExecution.Rollback(plan, 1, store);
            check(!store.Read(address).Value.GetBoolean() && !File.Exists(Path.Combine(root, "timer", "session.json")), "Stopping releases the identified worker request and removes its session record");
            ControlExecution.Apply(plan, store, _ => { });
            state = OperationFiles.Read<TimerWorkerState>(Path.Combine(root, "timer", "session.json"));
            using (var process = Process.GetProcessById(state.ProcessId)) { process.Kill(); process.WaitForExit(); }
            var lost = store.Read(address);
            check(!lost.Value.GetBoolean() && lost.LostLease, "An exited timer worker is detected as a lost request instead of reporting active");
            store.Write(lost, ControlValues.From(false));
            check(!File.Exists(Path.Combine(root, "timer", "session.json")), "A dead worker's owned session can be cleaned without targeting a reused process ID");
        }
        finally
        {
            var current = store.Read(address);
            if (current.Value.GetBoolean() || current.LostLease) store.Write(current, ControlValues.From(false));
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Native timer validation leaves no helper or fixture directory");
    }
}
