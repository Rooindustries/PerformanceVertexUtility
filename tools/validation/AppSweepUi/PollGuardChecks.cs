using System.Reflection;
using Microsoft.UI.Xaml;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.OptimizationSuite.Views;
using RooIndustries.Optimizer;

static class PollGuardChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        ControlRead Read<T>(T value) => ControlRead.From(value);
        var snapshot = new ProcessControlSnapshot(new RunningProcess(123, "1", @"C:\Fixture.exe"), Read(0xfffffffeu),
            [new LogicalCpu(103, 0, 0, 0, 0, 0, 0, false, false, false)],
            new Dictionary<string, ControlRead>
            {
                ["cpuPriority"] = Read("Normal"), ["ioPriority"] = Read(2), ["gpuPriority"] = Read(2), ["memoryPriority"] = Read(5),
                ["executionQoS"] = Read(new PowerThrottling(0, 0)), ["priorityBoost"] = Read(true), ["cpuSets"] = Read(Array.Empty<uint>()), ["affinity"] = Read(new AffinityState(0, "0x1")),
            });
        App.Operations.ProcessSnapshot = snapshot;
        var model = new ProcessControlsViewModel();
        await (Task)typeof(ProcessControlsViewModel).GetMethod("ReadProcessAsync", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(model, [new CpuProcessChoice(123, "Fixture"), 0])!;
        var governor = new TaskCompletionSource<GovernorSnapshot>();
        int governorReads = 0, processReads = 0;
        var reads = new List<Task>();
        App.Operations.GovernorRead = () => { governorReads++; return governor.Task; };
        App.Operations.ProcessReads = _ => { processReads++; return snapshot; };
        var window = new Window();
        MemoryRelief.Attach(window);
        var poll = new ForegroundPoll(token => { var read = model.ObserveAsync(token); reads.Add(read); return read; });
        var timer = (DispatcherTimer)typeof(ForegroundPoll).GetField("_timer", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(poll)!;
        var failures = new List<string>();
        void Case(bool passed, string name)
        {
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        async Task<int?> Tick(Action during)
        {
            governor = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var (governorsBefore, processesBefore) = (governorReads, processReads);
            timer.Fire();
            var started = governorReads == governorsBefore + 1 && processReads == processesBefore;
            during();
            governor.SetResult(App.Operations.Governor);
            await Task.WhenAll(reads);
            return started ? processReads - processesBefore : null;
        }
        try
        {
            poll.Start();
            window.Raise(WindowActivationState.CodeActivated);
            Case(await Tick(() => { }) == 1, "A poll in front reads the governor and then the selected process");
            Case(await Tick(() => window.Raise(WindowActivationState.Deactivated)) == 0 && !timer.IsEnabled && model.HasProcess,
                "Switching to another window while the governor read runs starts no process-status read afterwards");
            window.Raise(WindowActivationState.CodeActivated);
            Case(await Tick(() => window.AppWindow.Minimize(true)) == 0 && !timer.IsEnabled,
                "Minimizing while the governor read runs starts no process-status read afterwards");
            window.AppWindow.Minimize(false);
            Case(await Tick(() => poll.Stop()) == 0 && !timer.IsEnabled,
                "Leaving the Processes tab while the governor read runs starts no process-status read afterwards");
            poll.Start();
            Case(await Tick(() => { }) == 1, "Returning to the Processes tab polls the process again after a stopped read");
            Case(await Tick(() => { window.Raise(WindowActivationState.Deactivated); window.Raise(WindowActivationState.CodeActivated); }) == 0,
                "A read started before a switch away and back starts no process-status read when it finishes");
            Case(await Tick(() => { }) == 1, "The next poll after coming back reads the process again");
            window.Raise(WindowActivationState.Deactivated);
            var before = processReads;
            await model.ObserveAsync();
            Case(processReads == before + 1, "A read without a poll token still reads the selected process");
        }
        finally
        {
            poll.Stop();
            MemoryRelief.Detach(window);
            App.Operations.GovernorRead = null;
            App.Operations.ProcessReads = null;
        }
        check(failures.Count == 0, "Processes tab polling stops before the next helper read once the app leaves the front"
            + (failures.Count == 0 ? "" : " | failed: " + string.Join("; ", failures)));
    }
}
