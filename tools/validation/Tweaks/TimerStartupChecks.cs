using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
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
        using var process = Process.GetCurrentProcess();
        OperationFiles.Write(Path.Combine(launch.Root, "startup-worker-probe.json"), new Probe(process.Id, process.StartTime.ToUniversalTime().ToFileTimeUtc()));
        if (File.Exists(mode))
        {
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
                _ = process.SafeHandle;
                if (!process.HasExited && process.StartTime.ToUniversalTime().ToFileTimeUtc() == probe.CreationTime)
                { process.Kill(); process.WaitForExit(5000); }
            }
            catch (ArgumentException) { }
        }
        bool Finished(dynamic task, int seconds, bool requireScriptExit = true)
        {
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(seconds))
            {
                object instances = task.GetInstances(0);
                try { if ((int)((dynamic)instances).Count == 0 && (!requireScriptExit || File.Exists(Path.Combine(control, "startup-exit.txt")))) return true; }
                finally { Marshal.FinalReleaseComObject(instances); }
                Thread.Sleep(100);
            }
            return false;
        }
        void Run(dynamic task)
        {
            foreach (var name in new[] { "startup-exit.txt", "startup-launcher.log" }) File.Delete(Path.Combine(control, name));
            if (!store.Read(timer).Value.GetBoolean()) File.Delete(Path.Combine(control, "startup-worker-probe.json"));
            object instance = task.Run(null);
            Marshal.FinalReleaseComObject(instance);
        }
        try
        {
            ControlExecution.Apply(plan, store, _ => { });
            TraceStartupScript(control);
            check(store.Read(startup).Value.GetBoolean(), "The native startup adapter creates and verifies its owned task");
            registered = scheduler.GetFolder(@"\").GetTask(TaskName);
            dynamic task = registered;
            dynamic definition = task.Definition;
            check((int)definition.Principal.RunLevel == 0 && (int)definition.Principal.LogonType == 3 && (int)definition.Triggers.Item(1).Type == 9, "Startup uses the current interactive user at sign-in without a highest-privilege principal");
            Run(task);
            var deadline = Stopwatch.StartNew();
            while (!store.Read(timer).Value.GetBoolean() && deadline.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(100);
            var active = store.Read(timer).Value.GetBoolean();
            var diagnostics = StartupDiagnostics(registered, control);
            File.WriteAllText(Path.Combine(evidence, "startup.json"), diagnostics);
            check(active, "Running the registered startup task acquires the real timer request" + (active ? "" : ": " + diagnostics));
            var acquired = OperationFiles.Read<TimerWorkerState>(Path.Combine(control, "session.json"));
            var finished = Finished(task, 10);
            var residents = Residents(control);
            var scriptExit = DiagnosticText(Path.Combine(control, "startup-exit.txt")).Trim();
            OperationFiles.Write(Path.Combine(evidence, "acquired.json"), new { acquired, finished, lastTaskResult = (int)task.LastTaskResult, scriptExit, residents });
            bool exited = finished && (int)task.LastTaskResult == 0 && scriptExit == "0";
            check(exited, "The sign-in task and PowerShell script exit successfully while the timer remains acquired" + (exited ? "" : ": " + StartupDiagnostics(registered, control)));
            check(acquired.Acquired && !acquired.Released && acquired.Error is null && acquired.AcquireStatus >= 0 && acquired.ReturnedInterval <= 5000 &&
                residents is [{ ProcessId: var pid }] && pid == acquired.ProcessId && store.Read(timer).Value.GetBoolean(),
                "Only the timer host remains for this task: no PowerShell, console host or launcher");
            Run(task);
            check(Finished(task, 20) && (int)task.LastTaskResult == 0 && DiagnosticText(Path.Combine(control, "startup-exit.txt")).Trim() == "0" && OperationFiles.Read<TimerWorkerState>(Path.Combine(control, "session.json")).Launch.SessionId == acquired.Launch.SessionId,
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
                scriptExit = DiagnosticText(Path.Combine(control, "startup-exit.txt")).Trim();
                OperationFiles.Write(Path.Combine(evidence, mode + ".json"), new { completed, elapsedMs = watch.ElapsedMilliseconds, lastTaskResult = (int)task.LastTaskResult, scriptExit, probe, residents = processes, active = store.Read(timer).Value.GetBoolean(), diagnostics = StartupDiagnostics(registered, control) });
                check(completed && int.TryParse(scriptExit, out var exitCode) && exitCode != 0 && probe is not null && processes.Length == 0 && !store.Read(timer).Value.GetBoolean(),
                    "An unconfirmed worker (" + mode + ") fails the script and cleanup through its retained launch handle leaves no resident process");
                check(mode != "timeout" || watch.Elapsed >= TimeSpan.FromSeconds(15), "Unconfirmed acquisition uses the same 15-second timeout as Start");
                StopProbe();
                File.Delete(probePath); File.Delete(Path.Combine(control, "startup-worker-fixture.txt"));
            }
            ReusedWorkerId(control, store, timer, check, evidence);
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
                    TraceStartupScript(control);
                    File.WriteAllText(probeFile, "changed after registration");
                    Run(task);
                    var completed = Finished(task, 20);
                    var processes = Residents(control);
                    scriptExit = DiagnosticText(Path.Combine(control, "startup-exit.txt")).Trim();
                    OperationFiles.Write(Path.Combine(evidence, file + "-hash.json"), new { completed, lastTaskResult = (int)task.LastTaskResult, scriptExit, residents = processes });
                    check(completed && scriptExit == "1" && processes.Length == 0 && !store.Read(timer).Value.GetBoolean(),
                        "The pre-launch " + file + " hash check refuses changed bytes without starting a host");
                    File.Delete(probeFile);
                }
            }
            finally { File.WriteAllBytes(scriptPath, script); OperationFiles.Write(receiptPath, receipt); }
            Marshal.FinalReleaseComObject(registered); registered = null;
            ControlExecution.Rollback(plan, 1, store);
            check(!store.Read(startup).Value.GetBoolean() && !store.Read(startup).LostLease, "Startup restoration removes the exact owned registration and receipt");
        }
        catch (Exception error)
        {
            OperationFiles.Write(Path.Combine(evidence, "failure.json"), new { error = error.ToString(), diagnostics = registered is null ? null : StartupDiagnostics(registered, control) });
            var snapshot = Path.Combine(evidence, "failed-fixture");
            Directory.CreateDirectory(snapshot);
            foreach (var name in new[] { "startup.ps1", "startup.json", "launch.json", "session.json", "stop.json", "startup-exit.txt", "startup-launcher.log", "startup-worker-probe.json" })
                File.WriteAllText(Path.Combine(snapshot, name), DiagnosticText(Path.Combine(control, name)));
            Console.Error.WriteLine("Startup failure proof retained at " + evidence);
            throw;
        }
        finally
        {
            StopProbe();
            var runtime = store.Read(timer); if (runtime.Value.GetBoolean() || runtime.LostLease) store.Write(runtime, ControlValues.From(false));
            if (registered is not null)
            {
                ((dynamic)registered).Stop(0);
                Finished(registered, 10, requireScriptExit: false);
                Marshal.FinalReleaseComObject(registered);
            }
            var registration = store.Read(startup); if (registration.Value.GetBoolean() || registration.LostLease) store.Write(registration, ControlValues.From(false));
            Marshal.FinalReleaseComObject(scheduler);
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root) && Residents(control).Length == 0, "Startup validation leaves no task, helper, script or fixture directory");
        OperationFiles.Write(Path.Combine(evidence, "cleanup.json"), new { removed = true });
    }

    private static void ReusedWorkerId(string control, WindowsControlStore store, ControlAddress timer, Action<bool, string> check, string evidence)
    {
        var hook = typeof(TimerControl).GetProperty("WorkerStartedForTest", BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException("Timer startup checks require GovernorTestHooks=true.");
        var probeRoot = Path.Combine(control, "pid-reuse-probe");
        Directory.CreateDirectory(probeRoot);
        File.WriteAllText(Path.Combine(probeRoot, "startup-worker-fixture.txt"), "timeout");
        var assembly = Assembly.GetEntryAssembly()!.Location;
        var probeLaunch = Path.Combine(probeRoot, "launch.json");
        OperationFiles.Write(probeLaunch, new TimerLaunch(OperationOwner.Current(), Guid.NewGuid().ToString("N"), probeRoot, assembly, OperationFiles.HashFile(assembly)));
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--timer-worker"); start.ArgumentList.Add(probeLaunch);
        using var probe = Process.Start(start)!;
        try
        {
            File.WriteAllText(Path.Combine(control, "startup-worker-fixture.txt"), "exit");
            foreach (var autostart in new[] { false, true })
            {
                SafeProcessHandle? launchedHandle = null;
                var launchedPid = 0;
                hook.SetValue(null, (Func<SafeProcessHandle, int, int>)((handle, pid) =>
                {
                    launchedHandle = handle; launchedPid = pid;
                    if (WaitForSingleObject(handle, 10000) != 0) throw new TimeoutException("The disposable worker did not exit before PID substitution.");
                    return probe.Id;
                }));
                Exception? failure = null;
                try
                {
                    if (autostart) TimerControl.RunAutostart(control);
                    else store.Write(store.Read(timer), ControlValues.From(true));
                }
                catch (Exception error) when (error is IOException or TimeoutException) { failure = error; }
                var probeAlive = !probe.WaitForExit(0);
                OperationFiles.Write(Path.Combine(evidence, "pid-reuse-" + (autostart ? "autostart" : "interactive") + ".json"),
                    new { launchedPid, substitutedPid = probe.Id, probeAlive, handleClosed = launchedHandle?.IsClosed, failure = failure?.ToString() });
                check(launchedPid != 0 && launchedPid != probe.Id && failure is IOException && failure.Message == "Timer worker exited before acquisition: 0" && launchedHandle is { IsClosed: true },
                    "An exited worker is detected through its launch handle and that handle closes after " + (autostart ? "autostart" : "interactive Start") + " fails");
                check(probeAlive, "Failure cleanup leaves a live probe with the substituted worker PID untouched");
            }
        }
        finally
        {
            hook.SetValue(null, null);
            if (!probe.WaitForExit(0)) { probe.Kill(); probe.WaitForExit(); }
            File.Delete(Path.Combine(control, "startup-worker-fixture.txt"));
            File.Delete(Path.Combine(control, "startup-worker-probe.json"));
            Directory.Delete(probeRoot, true);
        }
    }

    private static void TraceStartupScript(string control)
    {
        static string Literal(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
        var path = Path.Combine(control, "startup.ps1");
        var script = File.ReadAllText(path).Replace("\nexit $LASTEXITCODE\n", "\n$script:timerExit=$LASTEXITCODE\n", StringComparison.Ordinal);
        var log = Literal(Path.Combine(control, "startup-launcher.log"));
        var traced = "$ErrorActionPreference='Stop'\n$script:timerExit=1\ntry { & {\n" + script + "} *> " + log + "\n} catch { $_ | Out-String | Add-Content -LiteralPath " + log + "\n} finally { [IO.File]::WriteAllText(" +
            Literal(Path.Combine(control, "startup-exit.txt")) + ",[string]$script:timerExit) }\nexit $script:timerExit\n";
        File.WriteAllText(path, traced, new System.Text.UTF8Encoding(false));
        var receiptPath = Path.Combine(control, "startup.json");
        var receipt = OperationFiles.Read<TimerStartupReceipt>(receiptPath);
        OperationFiles.Write(receiptPath, receipt with { ScriptHash = OperationFiles.HashFile(path) });
    }

    private static string DiagnosticText(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : "<missing>"; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return "<unreadable: " + error.Message + ">"; }
    }

    private static string StartupDiagnostics(object registered, string control)
    {
        dynamic task = registered;
        int? lastTaskResult = null; int? taskState = null; string? taskError = null;
        try { lastTaskResult = (int)task.LastTaskResult; taskState = (int)task.State; }
        catch (COMException error) { taskError = error.Message; }
        var session = DiagnosticText(Path.Combine(control, "session.json"));
        Probe? worker = null;
        int? workerPid = null; bool? workerPidAlive = null; bool? workerIdentityMatches = null; string? stateError = null;
        try
        {
            var state = OperationFiles.Deserialize<TimerWorkerState>(System.Text.Encoding.UTF8.GetBytes(session));
            worker = new(state.ProcessId, state.CreationTime);
        }
        catch (Exception error) when (error is JsonException or InvalidDataException) { stateError = error.Message; }
        if (worker is null && File.Exists(Path.Combine(control, "startup-worker-probe.json")))
        {
            try { worker = OperationFiles.Read<Probe>(Path.Combine(control, "startup-worker-probe.json")); }
            catch (Exception error) when (error is IOException or JsonException or InvalidDataException) { stateError += "; " + error.Message; }
        }
        if (worker is not null)
        {
            workerPid = worker.ProcessId; workerPidAlive = false;
            try
            {
                using var process = Process.GetProcessById(worker.ProcessId);
                _ = process.SafeHandle;
                workerPidAlive = !process.HasExited;
                workerIdentityMatches = workerPidAlive == true && process.StartTime.ToUniversalTime().ToFileTimeUtc() == worker.CreationTime;
            }
            catch (ArgumentException) { }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { workerPidAlive = null; stateError += "; " + error.Message; }
        }
        return JsonSerializer.Serialize(new { lastTaskResult, taskState, taskError,
            scriptExitCode = DiagnosticText(Path.Combine(control, "startup-exit.txt")).Trim(), session, workerPid, workerPidAlive, workerIdentityMatches, stateError,
            launcherOutput = DiagnosticText(Path.Combine(control, "startup-launcher.log")) }, OperationFiles.Json);
    }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);

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
