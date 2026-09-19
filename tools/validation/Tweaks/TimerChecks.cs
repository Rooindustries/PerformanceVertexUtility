using System.Diagnostics;
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
