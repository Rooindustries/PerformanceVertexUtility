using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using RooIndustries.Optimizer;

static class TimerStartupChecks
{
    private const string TaskName = "RooIndustriesTweakProbe_ec3d917cb672498785218eb3d0aa790f";
    private sealed record Probe(int ProcessId, long CreationTime);
    private sealed record Resident(int ProcessId, int ParentProcessId, string Name, string CommandLine);

    public static void Worker(string launchPath)
    {
        var launch = OperationFiles.Read<TimerLaunch>(launchPath);
        var mode = Path.Combine(launch.Root, "startup-worker-fixture.txt");
        if (File.Exists(mode))
        {
            using var process = Process.GetCurrentProcess();
            OperationFiles.Write(Path.Combine(launch.Root, "startup-worker-probe.json"), new Probe(process.Id, process.StartTime.ToUniversalTime().ToFileTimeUtc()));
            if (File.ReadAllText(mode) == "timeout") Thread.Sleep(Timeout.Infinite);
            return;
        }
        TimerControl.RunWorker(launchPath);
    }

    public static void Native(Action<bool, string> check, string? evidence = null)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"));
        var control = Path.Combine(root, "timer");
        evidence ??= Path.Combine(Path.GetTempPath(), "roo-industries-timer-startup-proof-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(evidence);
        Console.WriteLine("Startup evidence: " + evidence);
        var target = "fixture:" + control;
        var startup = new ControlAddress("timer-startup", target, "enabled"); var timer = new ControlAddress("timer", target, "half-millisecond");
        var store = new WindowsControlStore(); var before = store.Read(startup);
        if (before.Value.GetBoolean() || before.LostLease) throw new InvalidDataException("The temporary startup fixture must be absent.");
        var plan = new ControlPlan([before], [new(before, ControlValues.From(true))], []);
        dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!; scheduler.Connect();
        object? registered = null;
        void StopProbe()
        {
            var path = Path.Combine(control, "startup-worker-probe.json");
            if (!File.Exists(path)) return;
            var probe = OperationFiles.Read<Probe>(path);
            try
            {
                using var process = Process.GetProcessById(probe.ProcessId);
                if (!process.HasExited && process.StartTime.ToUniversalTime().ToFileTimeUtc() == probe.CreationTime)
                { process.Kill(); process.WaitForExit(5000); }
            }
            catch (ArgumentException) { }
        }
        bool Finished(dynamic task, int seconds)
        {
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(seconds))
            {
                object instances = task.GetInstances(0);
                try { if ((int)((dynamic)instances).Count == 0) return true; }
                finally { Marshal.FinalReleaseComObject(instances); }
                Thread.Sleep(100);
            }
            return false;
        }
        void Run(dynamic task)
        {
            object instance = task.Run(null);
            Marshal.FinalReleaseComObject(instance);
        }
        try
        {
            ControlExecution.Apply(plan, store, _ => { });
            check(store.Read(startup).Value.GetBoolean(), "The native startup adapter creates and verifies its owned task");
            registered = scheduler.GetFolder(@"\").GetTask(TaskName);
            dynamic task = registered;
            dynamic definition = task.Definition;
            check((int)definition.Principal.RunLevel == 0 && (int)definition.Principal.LogonType == 3 && (int)definition.Triggers.Item(1).Type == 9, "Startup uses the current interactive user at sign-in without a highest-privilege principal");
            Run(task);
            var deadline = Stopwatch.StartNew();
            while (!store.Read(timer).Value.GetBoolean() && deadline.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(100);
            check(store.Read(timer).Value.GetBoolean(), "Running the registered startup task acquires the real timer request");
            var acquired = OperationFiles.Read<TimerWorkerState>(Path.Combine(control, "session.json"));
            var finished = Finished(task, 10);
            var residents = Residents(control);
            OperationFiles.Write(Path.Combine(evidence, "acquired.json"), new { acquired, finished, lastTaskResult = (int)task.LastTaskResult, residents });
            check(finished && (int)task.LastTaskResult == 0, "The sign-in task exits successfully while the timer remains acquired");
            check(acquired.Acquired && !acquired.Released && acquired.Error is null && acquired.AcquireStatus >= 0 && acquired.ReturnedInterval <= 5000 &&
                residents is [{ ProcessId: var pid }] && pid == acquired.ProcessId && store.Read(timer).Value.GetBoolean(),
                "Only the timer host remains for this task: no PowerShell, console host or launcher");
            Run(task);
            check(Finished(task, 20) && (int)task.LastTaskResult == 0 && OperationFiles.Read<TimerWorkerState>(Path.Combine(control, "session.json")).Launch.SessionId == acquired.Launch.SessionId,
                "A repeated sign-in task preserves the already acquired session without another resident helper");
            check(Residents(control) is [{ ProcessId: var repeated }] && repeated == acquired.ProcessId, "A repeated task leaves exactly the original timer host");
            store.Write(store.Read(timer), ControlValues.From(false));
            check(!store.Read(timer).Value.GetBoolean() && Residents(control).Length == 0, "Stopping the detached startup worker releases the timer and leaves no resident process");
            foreach (var mode in new[] { "timeout", "exit" })
            {
                File.WriteAllText(Path.Combine(control, "startup-worker-fixture.txt"), mode);
                var watch = Stopwatch.StartNew();
                Run(task);
                var completed = Finished(task, 25);
                var processes = Residents(control);
                var probePath = Path.Combine(control, "startup-worker-probe.json");
                var probe = File.Exists(probePath) ? OperationFiles.Read<Probe>(probePath) : null;
                OperationFiles.Write(Path.Combine(evidence, mode + ".json"), new { completed, elapsedMs = watch.ElapsedMilliseconds, lastTaskResult = (int)task.LastTaskResult, probe, residents = processes, active = store.Read(timer).Value.GetBoolean() });
                check(completed && (int)task.LastTaskResult != 0 && probe is not null && processes.Length == 0 && !store.Read(timer).Value.GetBoolean(),
                    "A worker that does not confirm acquisition (" + mode + ") fails the task and leaves no resident process");
                check(mode != "timeout" || watch.Elapsed >= TimeSpan.FromSeconds(15), "Unconfirmed acquisition uses the same 15-second timeout as Start");
                StopProbe();
                File.Delete(probePath); File.Delete(Path.Combine(control, "startup-worker-fixture.txt"));
            }
            var scriptPath = Path.Combine(control, "startup.ps1");
            var script = File.ReadAllBytes(scriptPath);
            var receiptPath = Path.Combine(control, "startup.json");
            var receipt = OperationFiles.Read<TimerStartupReceipt>(receiptPath);
            try
            {
                foreach (var file in new[] { "assembly", "launcher" })
                {
                    var probeFile = Path.Combine(control, file + ".fixture");
                    File.WriteAllText(probeFile, "reviewed bytes");
                    var generate = typeof(TimerStartupControl).GetMethod("StartupScript", BindingFlags.NonPublic | BindingFlags.Static)!;
                    var generated = (string)generate.Invoke(null, [file == "assembly" ? probeFile : Assembly.GetEntryAssembly()!.Location,
                        file == "launcher" ? probeFile : Environment.ProcessPath!, true, control])!;
                    File.WriteAllText(scriptPath, generated, new System.Text.UTF8Encoding(false));
                    OperationFiles.Write(receiptPath, receipt with { ScriptHash = OperationFiles.HashFile(scriptPath) });
                    File.WriteAllText(probeFile, "changed after registration");
                    Run(task);
                    var completed = Finished(task, 20);
                    var processes = Residents(control);
                    OperationFiles.Write(Path.Combine(evidence, file + "-hash.json"), new { completed, lastTaskResult = (int)task.LastTaskResult, residents = processes });
                    check(completed && (int)task.LastTaskResult != 0 && processes.Length == 0 && !store.Read(timer).Value.GetBoolean(),
                        "The pre-launch " + file + " hash check refuses changed bytes without starting a host");
                    File.Delete(probeFile);
                }
            }
            finally { File.WriteAllBytes(scriptPath, script); OperationFiles.Write(receiptPath, receipt); }
            Marshal.FinalReleaseComObject(registered); registered = null;
            ControlExecution.Rollback(plan, 1, store);
            check(!store.Read(startup).Value.GetBoolean() && !store.Read(startup).LostLease, "Startup restoration removes the exact owned registration and receipt");
        }
        finally
        {
            StopProbe();
            var runtime = store.Read(timer); if (runtime.Value.GetBoolean() || runtime.LostLease) store.Write(runtime, ControlValues.From(false));
            if (registered is not null)
            {
                ((dynamic)registered).Stop(0);
                Finished(registered, 10);
                Marshal.FinalReleaseComObject(registered);
            }
            var registration = store.Read(startup); if (registration.Value.GetBoolean() || registration.LostLease) store.Write(registration, ControlValues.From(false));
            Marshal.FinalReleaseComObject(scheduler);
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root) && Residents(control).Length == 0, "Startup validation leaves no task, helper, script or fixture directory");
        OperationFiles.Write(Path.Combine(evidence, "cleanup.json"), new { removed = true });
    }

    private static Resident[] Residents(string root)
    {
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var start = new ProcessStartInfo(powershell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        var command = "$ErrorActionPreference='Stop'; $root='" + root.Replace("'", "''", StringComparison.Ordinal) + "'; $all=@(Get-CimInstance Win32_Process -ErrorAction Stop); " +
            "$owned=@($all | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -ge 0 }); " +
            "do { $ids=@($owned.ProcessId); $children=@($all | Where-Object { $_.ProcessId -ne $PID -and $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids }); $owned+= $children } while($children.Count); " +
            "@($owned | Select-Object ProcessId,ParentProcessId,Name,CommandLine) | ConvertTo-Json -Compress";
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command", command }) start.ArgumentList.Add(argument);
        using var reader = Process.Start(start)!;
        var output = reader.StandardOutput.ReadToEndAsync(); var error = reader.StandardError.ReadToEndAsync();
        if (!reader.WaitForExit(15000)) { reader.Kill(); reader.WaitForExit(); throw new TimeoutException("The fixture process inventory did not finish."); }
        if (reader.ExitCode != 0) throw new IOException(error.Result);
        var json = output.Result.Trim();
        if (json.Length == 0) return [];
        return JsonSerializer.Deserialize<Resident[]>(json.StartsWith('[') ? json : "[" + json + "]", new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
    }
}
