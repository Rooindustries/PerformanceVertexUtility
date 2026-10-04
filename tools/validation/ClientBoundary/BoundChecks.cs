using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

static class BoundChecks
{
    static readonly TimeSpan Safety = TimeSpan.FromSeconds(25);
    static readonly TimeSpan Bound = TimeSpan.FromSeconds(8);
    static string root = "";
    static string host = "";
    static int counter;

    const string WorkerScript = """
        param([string]$Action,[string]$PolicyRoot,[switch]$ConfirmApply)
        $ErrorActionPreference='Stop'
        $state=$env:ROO_INDUSTRIES_TEST_BOUNDS_DIR
        [IO.File]::AppendAllText((Join-Path $state 'worker-calls.log'),"$PID $Action`n")
        if(Test-Path (Join-Path $state 'worker-hang')){
            $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n','400','127.0.0.1' -WindowStyle Hidden -PassThru
            [IO.File]::WriteAllText((Join-Path $state 'worker-pids.txt'),"$PID $($child.Id)")
            $child.WaitForExit()
        }
        if(Test-Path (Join-Path $state 'worker-slow')){Start-Sleep -Milliseconds ([int][IO.File]::ReadAllText((Join-Path $state 'worker-slow')))}
        '{"schemaVersion":1,"status":"completed","data":{"taskName":"fixture","registered":true,"enabled":true,"runAtLogon":true,"restartEveryMinute":true,"paused":false,"rules":1,"enabledRules":1,"secured":true,"securityProblem":null,"rulesError":null,"worker":{"state":null,"hostRunning":true,"error":null}}}'
        """;

    static string NewState(string name)
    {
        var state = Path.Combine(root, name + "-" + ++counter);
        Directory.CreateDirectory(state);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_BOUNDS_DIR", state);
        return state;
    }

    static OptimizerService Service(string state)
    {
        var storage = Path.Combine(state, "operations");
        Directory.CreateDirectory(storage);
        var service = new OptimizerService(new BackendLocator(), storage);
        var lease = (PolicyRootLease)RuntimeHelpers.GetUninitializedObject(typeof(PolicyRootLease));
        var handle = (SafeFileHandle)typeof(PolicyRootLease).GetMethod("OpenDirectory", BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, [storage])!;
        var opened = (string)typeof(PolicyRootLease).GetMethod("FinalPath", BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, [handle])!;
        typeof(PolicyRootLease).GetField("_handle", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(lease, handle);
        typeof(PolicyRootLease).GetField("_opened", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(lease, opened);
        typeof(OptimizerService).GetField("_storageLease", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(service, lease);
        foreach (var name in new[] { "GovernorTimeout", "TweakPreviewTimeout", "TweakApplyTimeout", "HostReadTimeout" })
            typeof(OptimizerService).GetProperty(name)?.SetValue(service, Bound);
        return service;
    }

    static async Task<(Exception? Error, T? Value, bool Finished)> Call<T>(Func<Task<T>> call)
    {
        var task = Task.Run(call);
        if (await Task.WhenAny(task, Task.Delay(Safety)) != task) return (null, default, false);
        try { return (null, await task, true); }
        catch (Exception error) { return (error, default, true); }
    }

    static int[] Pids(string file) => File.Exists(file) ? File.ReadAllText(file).Split(' ').Select(int.Parse).ToArray() : [];

    static bool Alive(int id)
    {
        try { using var process = Process.GetProcessById(id); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }

    static async Task<bool> TreeGone(string file)
    {
        var ids = Pids(file);
        if (ids.Length != 2) return false;
        for (var attempt = 0; attempt < 50 && ids.Any(Alive); attempt++) await Task.Delay(100);
        return !ids.Any(Alive);
    }

    static void KillTree(string file)
    {
        foreach (var id in Pids(file))
            try { using var process = Process.GetProcessById(id); process.Kill(entireProcessTree: true); } catch (Exception) { }
    }

    static bool TimedOut(Exception? error) => error is TimeoutException timeout && timeout.Message == AppLog.TimedOut;

    static TweakPlan Plan(string profile, params ControlMutation[] changes) => new()
    {
        SchemaVersion = 1, OperationId = Guid.NewGuid().ToString("N"), CreatedAtUtc = DateTime.UtcNow, Context = new(OperationOwner.Current(), "windows-registry:bounds", 26200, "Professional"),
        CatalogHash = "hash", BeforeRevision = null, AfterRevision = Guid.NewGuid().ToString("N"), ProfileId = profile, Selections = [new("setting", "option")],
        Expected = [], Changes = [], Profiles = [], Held = [], Controls = changes.Length == 0 ? null : new ControlPlan([], changes, []),
    };

    static ControlMutation Change(string kind, string target, string property, bool after)
        => new(new TweakControlRead(new ControlAddress(kind, target, property), kind + ":" + target + ":" + property, "binding", ControlValues.From(!after)), ControlValues.From(after));

    static WindowsTweakReview Review(string state, TweakPlan plan)
    {
        var path = Path.Combine(state, "review.json");
        OperationFiles.Write(path, plan);
        OperationFiles.Write(Path.Combine(state, "apply-result.json"), new TweakApplyResult(new TweakState
        {
            SchemaVersion = 1, Context = plan.Context, Revision = plan.AfterRevision, Profiles = [], Held = [], CreatedKeys = [], History = [], Notices = [],
        }, true, false));
        return new(plan, path, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))));
    }

    public static async Task Run(string repo, string? filter)
    {
        root = Path.Combine(Path.GetTempPath(), "roo-industries-bounds-" + Guid.NewGuid().ToString("N"));
        var scripts = Path.Combine(root, "backend", "scripts");
        Directory.CreateDirectory(scripts);
        Directory.CreateDirectory(Path.Combine(root, "backend", "samples"));
        var hostDirectory = Path.Combine(root, "backend", "bin", "optimizer");
        Directory.CreateDirectory(hostDirectory);
        File.WriteAllText(Path.Combine(hostDirectory, "Optimizer.Host.dll"), "fixture");
        File.WriteAllText(Path.Combine(scripts, "Invoke-ProcessPolicyWorker.ps1"), WorkerScript);
        host = Path.ChangeExtension(typeof(BoundChecks).Assembly.Location, ".exe");
        var runtime = Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
        var names = new[] { "ROO_INDUSTRIES_BACKEND_ROOT", "ROO_INDUSTRIES_DOTNET_EXE", "DOTNET_ROOT", "ROO_INDUSTRIES_TEST_BOUNDS_DIR" };
        var previous = names.ToDictionary(name => name, Environment.GetEnvironmentVariable);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", root);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_DOTNET_EXE", host);
        Environment.SetEnvironmentVariable("DOTNET_ROOT", runtime);
        var failures = new List<string>();
        var ran = 0;
        async Task Scenario(string name, Func<Task<bool>> body)
        {
            if (filter is not null && !name.Contains(filter, StringComparison.OrdinalIgnoreCase)) return;
            ran++;
            bool passed;
            try { passed = await body(); }
            catch (Exception error) { passed = false; name += " (" + error.GetType().Name + ": " + error.Message + ")"; }
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        try
        {
            await Scenario("An ordinary Host read that hangs is bounded, its process tree exits, and retry succeeds", async () =>
            {
                var state = NewState("read-timeout");
                var hang = Path.Combine(state, "host-hang");
                File.WriteAllText(hang, "");
                var service = Service(state);
                var (first, _, finished) = await Call(() => service.ReadRulesAsync());
                var gone = await TreeGone(Path.Combine(state, "host-pids.txt"));
                File.Delete(hang);
                var (second, rules, retried) = await Call(() => service.ReadRulesAsync());
                var calls = File.ReadAllLines(Path.Combine(state, "host-calls.log"));
                return finished && TimedOut(first) && gone && retried && second is null && rules is { Length: 0 } && calls.Length == 2 && !DataGeneration.Changing;
            });
            await Scenario("Governor worker call that never answers is stopped with the timed-out message, its whole process tree is gone and no change stays marked", async () =>
            {
                var state = NewState("worker-timeout");
                File.WriteAllText(Path.Combine(state, "worker-hang"), "");
                var watch = Stopwatch.StartNew();
                var (error, _, finished) = await Call(() => Service(state).PolicyWorkerAsync("Sync"));
                Console.WriteLine("worker call " + (finished ? "ended after " + watch.ElapsedMilliseconds + " ms: " + (error?.GetType().Name ?? "no error") : "was still running after " + watch.ElapsedMilliseconds + " ms"));
                var gone = await TreeGone(Path.Combine(state, "worker-pids.txt"));
                var changing = DataGeneration.Changing;
                if (!finished) KillTree(Path.Combine(state, "worker-pids.txt"));
                return finished && TimedOut(error) && gone && !changing;
            });
            await Scenario("A governor worker call after a timed-out one starts a new script and succeeds", async () =>
            {
                var state = NewState("worker-retry");
                var hang = Path.Combine(state, "worker-hang");
                File.WriteAllText(hang, "");
                var service = Service(state);
                var (first, _, finished) = await Call(() => service.PolicyWorkerAsync("Pause"));
                if (!finished) { KillTree(Path.Combine(state, "worker-pids.txt")); return false; }
                File.Delete(hang);
                var (second, registration, done) = await Call(() => service.PolicyWorkerAsync("Pause"));
                var calls = File.ReadAllLines(Path.Combine(state, "worker-calls.log"));
                return TimedOut(first) && done && second is null && registration?.Registered == true && calls.Length == 2 && calls[0].Split(' ')[0] != calls[1].Split(' ')[0] && !DataGeneration.Changing;
            });
            await Scenario("A governor worker call made while another one is hung is not blocked by it, and the hung one still times out", async () =>
            {
                var state = NewState("worker-concurrent");
                var hang = Path.Combine(state, "worker-hang");
                File.WriteAllText(hang, "");
                var service = Service(state);
                var pids = Path.Combine(state, "worker-pids.txt");
                var first = Call(() => service.PolicyWorkerAsync("Sync"));
                for (var attempt = 0; attempt < 150 && !File.Exists(pids); attempt++) await Task.Delay(100);
                if (!File.Exists(pids)) return false;
                File.Delete(hang);
                var (secondError, registration, secondDone) = await Call(() => service.PolicyWorkerAsync("Status"));
                var firstStillRunning = !first.IsCompleted;
                var (firstError, _, firstDone) = await first;
                if (!firstDone) KillTree(pids);
                return secondDone && secondError is null && registration?.Registered == true && firstStillRunning && firstDone && TimedOut(firstError) && await TreeGone(pids) && !DataGeneration.Changing;
            });
            await Scenario("A governor worker call that finishes inside the bound returns its normal result", async () =>
            {
                var state = NewState("worker-slow");
                File.WriteAllText(Path.Combine(state, "worker-slow"), "3000");
                var (error, registration, finished) = await Call(() => Service(state).PolicyWorkerAsync("Remove"));
                return finished && error is null && registration?.Enabled == true && !DataGeneration.Changing;
            });
            await Scenario("Put settings back that never answers is stopped with the timed-out message and its helper tree is gone", async () =>
            {
                var state = NewState("restore-timeout");
                File.WriteAllText(Path.Combine(state, "host-hang"), "");
                var watch = Stopwatch.StartNew();
                var (error, _, finished) = await Call(() => Service(state).RetryGovernorRestoreAsync());
                Console.WriteLine("restore call " + (finished ? "ended after " + watch.ElapsedMilliseconds + " ms: " + (error?.GetType().Name ?? "no error") : "was still running after " + watch.ElapsedMilliseconds + " ms"));
                var gone = await TreeGone(Path.Combine(state, "host-pids.txt"));
                var changing = DataGeneration.Changing;
                if (!finished) KillTree(Path.Combine(state, "host-pids.txt"));
                return finished && TimedOut(error) && gone && !changing;
            });
            await Scenario("Put settings back after a timed-out one runs a new helper and returns the restore state", async () =>
            {
                var state = NewState("restore-retry");
                var hang = Path.Combine(state, "host-hang");
                File.WriteAllText(hang, "");
                var service = Service(state);
                var (first, _, finished) = await Call(() => service.RetryGovernorRestoreAsync());
                if (!finished) { KillTree(Path.Combine(state, "host-pids.txt")); return false; }
                File.Delete(hang);
                var (second, restored, done) = await Call(() => service.RetryGovernorRestoreAsync());
                var calls = File.ReadAllLines(Path.Combine(state, "host-calls.log"));
                return TimedOut(first) && done && second is null && restored?.Status == "stopped" && calls.Length == 2 && calls[0].Split(' ')[0] != calls[1].Split(' ')[0] && !DataGeneration.Changing;
            });
            await Scenario("Windows settings review that never answers is stopped with the timed-out message, its helper tree is gone, and a second review works", async () =>
            {
                var state = NewState("preview-timeout");
                OperationFiles.Write(Path.Combine(state, "plan.json"), Plan("bounds"));
                var hang = Path.Combine(state, "host-hang");
                File.WriteAllText(hang, "");
                var service = Service(state);
                var (error, _, finished) = await Call(() => service.PreviewWindowsTweaksAsync("bounds", [new("setting", "option")]));
                var gone = await TreeGone(Path.Combine(state, "host-pids.txt"));
                if (!finished) { KillTree(Path.Combine(state, "host-pids.txt")); return false; }
                File.Delete(hang);
                var (second, review, done) = await Call(() => service.PreviewWindowsTweaksAsync("bounds", [new("setting", "option")]));
                return TimedOut(error) && gone && done && second is null && review?.Plan.ProfileId == "bounds" && !DataGeneration.Changing;
            });
            await Scenario("Applying Windows settings that only change services or tasks is stopped with the timed-out message and its helper tree is gone", async () =>
            {
                var state = NewState("apply-timeout");
                File.WriteAllText(Path.Combine(state, "host-hang"), "");
                var review = Review(state, Plan("bounds", Change("service", "Fixture", "running", false), Change("scheduled-task", "\\Fixture", "enabled", true)));
                var (error, _, finished) = await Call(() => Service(state).ApplyWindowsTweaksAsync(review));
                var gone = await TreeGone(Path.Combine(state, "host-pids.txt"));
                var changing = DataGeneration.Changing;
                if (!finished) KillTree(Path.Combine(state, "host-pids.txt"));
                return finished && TimedOut(error) && gone && !changing;
            });
            await Scenario("Applying Windows settings that change only registry values is stopped with the timed-out message", async () =>
            {
                var state = NewState("apply-registry-timeout");
                File.WriteAllText(Path.Combine(state, "host-hang"), "");
                var review = Review(state, Plan("bounds"));
                var (error, _, finished) = await Call(() => Service(state).ApplyWindowsTweaksAsync(review));
                var gone = await TreeGone(Path.Combine(state, "host-pids.txt"));
                if (!finished) KillTree(Path.Combine(state, "host-pids.txt"));
                return finished && TimedOut(error) && gone && !DataGeneration.Changing;
            });
            await Scenario("Applying Windows features is not stopped by the apply bound because killing the feature servicing is not proven recoverable", async () =>
            {
                var state = NewState("apply-features-unbounded");
                File.WriteAllText(Path.Combine(state, "host-slow"), "12000");
                var review = Review(state, Plan("bounds", Change("windows-features", "system", "features", true)));
                var (error, result, finished) = await Call(() => Service(state).ApplyWindowsTweaksAsync(review));
                return finished && error is null && result?.Changed == true && !DataGeneration.Changing;
            });
            await Scenario("Applying Windows settings that change file permissions is not stopped by the apply bound", async () =>
            {
                var state = NewState("apply-other-unbounded");
                File.WriteAllText(Path.Combine(state, "host-slow"), "12000");
                var review = Review(state, Plan("bounds", Change("service", "Fixture", "running", false), Change("file-ownership", "selected:C:\\Fixture", "permissions", true)));
                var (error, result, finished) = await Call(() => Service(state).ApplyWindowsTweaksAsync(review));
                return finished && error is null && result?.Changed == true && !DataGeneration.Changing;
            });
        }
        finally
        {
            foreach (var (name, value) in previous) Environment.SetEnvironmentVariable(name, value);
            try { Directory.Delete(root, true); } catch (Exception) { }
        }
        Console.WriteLine(ran + " bound scenarios ran, " + failures.Count + " failed.");
        if (ran == 0 || failures.Count > 0) throw new InvalidOperationException("Bound checks failed: " + string.Join("; ", failures));
    }
}
