using System.Diagnostics;
using System.Runtime.InteropServices;
using RooIndustries.Optimizer;

static class TimerStartupChecks
{
    public static void Native(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"));
        var target = "fixture:" + Path.Combine(root, "timer");
        var startup = new ControlAddress("timer-startup", target, "enabled"); var timer = new ControlAddress("timer", target, "half-millisecond");
        var store = new WindowsControlStore(); var before = store.Read(startup);
        if (before.Value.GetBoolean() || before.LostLease) throw new InvalidDataException("The temporary startup fixture must be absent.");
        var plan = new ControlPlan([before], [new(before, ControlValues.From(true))], []);
        dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!; scheduler.Connect();
        try
        {
            ControlExecution.Apply(plan, store, _ => { });
            check(store.Read(startup).Value.GetBoolean(), "The native startup adapter creates and verifies its owned task");
            dynamic task = scheduler.GetFolder(@"\").GetTask("RooIndustriesTweakProbe_ec3d917cb672498785218eb3d0aa790f");
            try
            {
                dynamic definition = task.Definition;
                check((int)definition.Principal.RunLevel == 0 && (int)definition.Principal.LogonType == 3 && (int)definition.Triggers.Item(1).Type == 9, "Startup uses the current interactive user at sign-in without a highest-privilege principal");
                task.Run(null);
                var deadline = Stopwatch.StartNew();
                while (!store.Read(timer).Value.GetBoolean() && deadline.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(100);
                check(store.Read(timer).Value.GetBoolean(), "Running the registered startup task acquires the real timer request");
                store.Write(store.Read(timer), ControlValues.From(false));
                deadline.Restart(); while ((int)task.GetInstances(0).Count != 0 && deadline.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(100);
                check((int)task.GetInstances(0).Count == 0, "Stopping the worker lets its startup task exit");
            }
            finally { Marshal.FinalReleaseComObject(task); }
            ControlExecution.Rollback(plan, 1, store);
            check(!store.Read(startup).Value.GetBoolean() && !store.Read(startup).LostLease, "Startup restoration removes the exact owned registration and receipt");
        }
        finally
        {
            var runtime = store.Read(timer); if (runtime.Value.GetBoolean() || runtime.LostLease) store.Write(runtime, ControlValues.From(false));
            var registration = store.Read(startup); if (registration.Value.GetBoolean() || registration.LostLease) store.Write(registration, ControlValues.From(false));
            Marshal.FinalReleaseComObject(scheduler);
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Startup validation leaves no task, helper, script or fixture directory");
    }
}
