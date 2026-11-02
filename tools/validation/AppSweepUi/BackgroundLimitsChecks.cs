using System.Reflection;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.ViewModels;

static class BackgroundLimitsChecks
{
    private sealed record Run(string SessionId, string SessionPath, string BackupPath);

    public static async Task RunAsync(Action<bool, string> check)
    {
        var root = Directory.CreateTempSubdirectory("background-limits-").FullName;
        var saved = typeof(RooIndustries.OptimizationSuite.Services.FakeLiveDataService).GetProperties(BindingFlags.Instance | BindingFlags.Public)
            .Where(property => property.CanWrite).Select(property => (Property: property, Value: property.GetValue(App.Live))).ToArray();
        var failures = new List<string>();
        void Case(bool passed, string name)
        {
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        try
        {
            App.Live.LastError = App.Live.GovernorResultError = App.Live.GovernorRestoreError = App.Live.GovernorStatusError = App.Live.GovernorRestoreText = null;
            App.Live.Classification = new ProcessClassification { Processes = [new ProcessItem { Name = "Fixture.exe", Category = "backgroundApp" }] };
            var first = Write(root, "first");
            var second = Write(root, "second");

            var model = new PerformanceProfilesViewModel();
            Case(model.GovernorDetail.StartsWith("Watches background apps for a minute", StringComparison.Ordinal),
                "The Background limits card says it watches for a minute: " + model.GovernorDetail);

            App.Live.GovernorStatusText = Status(null);
            App.Live.GovernorText = Started(first);
            await model.StartGovernorCommand.ExecuteAsync(null);
            Case(model.GovernorRestoreAvailable, "A run that leaves an app lowered offers Restore");
            Case(App.Live.LastGovernorDuration == 60, "The app watches long enough for the shipped pressure and minimum restraint windows");
            Case(RooIndustries.OptimizationSuite.Services.BackendScriptPolicy.Timeout("Start-ProcessGovernorSession.ps1") >= TimeSpan.FromSeconds(120 + App.Live.LastGovernorDuration + 30)
                && RooIndustries.OptimizationSuite.Services.BackendScriptPolicy.Timeout("Get-BugReportSpecs.ps1") == TimeSpan.FromSeconds(45),
                "The governor watch can finish before its deadline while other backend deadlines stay unchanged");

            var watched = new PerformanceProfilesViewModel();
            App.Live.GovernorText = Watched(first);
            await watched.StartGovernorCommand.ExecuteAsync(null);
            var shown = watched.GovernorDetail.Split('\n');
            Case(shown.Contains("Fixture.exe: Sustained background CPU pressure candidate. Sustained for 60 second(s).")
                    && shown.Contains("Fixture.exe: GPU scheduling priority is unavailable for this process.")
                    && shown.Count(line => line.StartsWith("Fixture.exe: ", StringComparison.Ordinal)) == 2
                    && shown.Count(line => line.StartsWith("Suite.exe: ", StringComparison.Ordinal)) == 1,
                "A one-minute watch lists each skipped app once per reason from its latest check: " + watched.GovernorDetail);

            var dormantStart = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(null);
            App.Live.GovernorText = Started(first).Replace("\"activeRestraints\":[{\"processId\":123,\"processName\":\"Fixture.exe\"}]", "\"activeRestraints\":[]", StringComparison.Ordinal);
            await dormantStart.StartGovernorCommand.ExecuteAsync(null);
            Case(!dormantStart.GovernorRestoreAvailable,
                "A run that holds no app after its watch, but keeps a backup for a value something else set, offers Restore only once status says it holds one");

            App.Live.GovernorText = Busy();
            App.Live.GovernorStatusText = Status(first);
            await model.StartGovernorCommand.ExecuteAsync(null);
            Case(model.GovernorRestoreAvailable && model.GovernorDetail == BusyMessage,
                "Start while another run is still going keeps Restore and says so in plain words: " + model.GovernorDetail);
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                App.Live.GovernorStatusText = Status(null);
                return new(Restored(first), null);
            };
            await model.RestoreGovernorCommand.ExecuteAsync(null);
            App.Live.GovernorRestoreHandler = null;
            Case(App.Live.LastGovernorRestoreRequest?.SessionId == first.SessionId, "Restore after the busy Start targets the run that holds an app");

            var restarted = new PerformanceProfilesViewModel();
            App.Live.GovernorText = Busy();
            App.Live.GovernorStatusText = Status(first);
            await restarted.StartGovernorCommand.ExecuteAsync(null);
            Case(restarted.GovernorRestoreAvailable, "A busy Start offers Restore for the run that holds an app even when the page had none yet");

            var older = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(null);
            App.Live.GovernorText = Started(first);
            await older.StartGovernorCommand.ExecuteAsync(null);
            App.Live.GovernorText = Finished();
            App.Live.GovernorStatusText = Status(first);
            await older.StartGovernorCommand.ExecuteAsync(null);
            Case(older.GovernorRestoreAvailable, "A later run that lowered nothing keeps Restore for the run that still holds an app");

            var failedStatus = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(null);
            App.Live.GovernorText = Started(first);
            await failedStatus.StartGovernorCommand.ExecuteAsync(null);
            App.Live.GovernorText = Busy();
            App.Live.GovernorStatusError = "Status read failed.";
            await failedStatus.StartGovernorCommand.ExecuteAsync(null);
            Case(failedStatus.GovernorRestoreAvailable, "A busy Start keeps the page's Restore when the status read fails");
            var blindRestores = 0;
            App.Live.GovernorRestoreHandler = (id, path, backup) => { blindRestores++; return new(Restored(first), null); };
            await failedStatus.RestoreGovernorCommand.ExecuteAsync(null);
            App.Live.GovernorRestoreHandler = null;
            App.Live.GovernorStatusError = null;
            Case(blindRestores == 0 && failedStatus.GovernorRestoreAvailable && failedStatus.GovernorStatus == "Background restore needs attention",
                "Restore writes nothing while it cannot read which run is newest, and keeps Restore");

            var revisit = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(first);
            await revisit.InitializeAsync();
            App.Live.GovernorText = Busy();
            await revisit.StartGovernorCommand.ExecuteAsync(null);
            await revisit.InitializeAsync();
            Case(revisit.GovernorRestoreAvailable && revisit.GovernorDetail == BusyMessage,
                "A quiet page refresh after a busy Start keeps the busy message and Restore: " + revisit.GovernorDetail);
            App.Live.GovernorStatusText = Status(null);
            await revisit.InitializeAsync();
            Case(!revisit.GovernorRestoreAvailable && revisit.GovernorDetail == "No active session or restore point yet.",
                "A quiet page refresh shows the new state once the restore point is gone: " + revisit.GovernorDetail);

            var interrupted = new PerformanceProfilesViewModel();
            App.Live.GovernorText = null;
            App.Live.GovernorResultError = "Timed out.";
            App.Live.GovernorStatusText = Status(first);
            await interrupted.StartGovernorCommand.ExecuteAsync(null);
            App.Live.GovernorResultError = null;
            Case(interrupted.GovernorRestoreAvailable, "A Start that timed out or crashed offers Restore for the run it left holding an app");

            var stacked = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(second);
            await stacked.ReloadAsync();
            Case(stacked.GovernorRestoreAvailable, "Opening the page offers Restore for the newest run that still holds an app");
            var requests = new List<string>();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                var run = id == second.SessionId ? second : first;
                App.Live.GovernorStatusText = Status(id == second.SessionId ? first : null);
                return new(Restored(run), null);
            };
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.SequenceEqual(new[] { second.SessionId, first.SessionId }) && !stacked.GovernorRestoreAvailable,
                "One Restore puts every holding run back, newest first");

            var stale = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(null);
            App.Live.GovernorText = Started(first);
            await stale.StartGovernorCommand.ExecuteAsync(null);
            App.Live.GovernorStatusText = Status(second);
            requests.Clear();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                App.Live.GovernorStatusText = Status(id == second.SessionId ? first : null);
                return new(id == second.SessionId ? KeptOnly(second) : Restored(first), null);
            };
            await stale.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.SequenceEqual(new[] { second.SessionId, first.SessionId }) && !stale.GovernorRestoreAvailable,
                "Restore starts from the newest holding run even when the page remembered an older one, and a run that only kept another program's values lets the walk continue");

            requests.Clear();
            App.Live.GovernorStatusText = Status(second);
            await stacked.ReloadAsync();
            var interruptedRestore = true;
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                if (id == first.SessionId && interruptedRestore) return new(null, "Restore interrupted.");
                App.Live.GovernorStatusText = Status(id == second.SessionId ? first : null);
                return new(Restored(id == second.SessionId ? second : first), null);
            };
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(stacked.GovernorRestoreAvailable && stacked.GovernorStatus == "Background restore not confirmed",
                "An interrupted older restore keeps its recovery target");
            interruptedRestore = false;
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.SequenceEqual(new[] { second.SessionId, first.SessionId, first.SessionId }) && !stacked.GovernorRestoreAvailable,
                "Retry resumes the unfinished older run without replaying the newer restore");

            requests.Clear();
            App.Live.GovernorStatusText = Status(first);
            await stacked.ReloadAsync();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                return new(Restored(first), null);
            };
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.Count == 1 && stacked.GovernorRestoreAvailable && stacked.GovernorStatus == "Background restore needs attention",
                "A repeated held status stops the chain without writing the same restore twice");

            foreach (var invalidStatus in new[] { "{}", "{\"actionId\":\"performance.governor.sessionStatus\",\"status\":\"failed\",\"restorable\":false}",
                "{\"actionId\":\"performance.governor.sessionStatus\",\"status\":\"restorable\",\"restorable\":true}" })
            {
                App.Live.GovernorStatusText = Status(first);
                await stacked.ReloadAsync();
                App.Live.GovernorRestoreHandler = (id, path, backup) =>
                {
                    App.Live.GovernorStatusText = invalidStatus;
                    return new(Restored(first), null);
                };
                await stacked.RestoreGovernorCommand.ExecuteAsync(null);
                Case(stacked.GovernorRestoreAvailable && stacked.GovernorStatus == "Background restore needs attention",
                    "An invalid or failed next-status response cannot claim every run was restored: " + invalidStatus);
            }

            const string emptyFailed = "{\"actionId\":\"performance.governor.sessionStatus\",\"status\":\"failed\",\"sessionStatus\":\"failed\",\"dryRun\":false,\"restorable\":false}";
            App.Live.GovernorStatusText = Status(first);
            await stacked.ReloadAsync();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                App.Live.GovernorStatusText = emptyFailed;
                return new(Restored(first), null);
            };
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(!stacked.GovernorRestoreAvailable && stacked.GovernorStatus == "Background limits restored",
                "A valid status whose newest run failed without holding anything ends the walk as restored");

            var closedRun = new PerformanceProfilesViewModel();
            App.Live.GovernorStatusText = Status(first);
            await closedRun.ReloadAsync();
            App.Live.GovernorStatusText = emptyFailed;
            requests.Clear();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                return new(Restored(first), null);
            };
            await closedRun.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.Count == 0 && !closedRun.GovernorRestoreAvailable && closedRun.GovernorDetail == "No saved background limits remain to restore.",
                "Restore on a page that remembered a run whose apps have since closed ends cleanly when nothing holds an app: " + closedRun.GovernorDetail);

            App.Live.GovernorStatusText = Status(second);
            await stacked.ReloadAsync();
            requests.Clear();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                App.Live.GovernorStatusText = Status(first);
                return new(Restored(second).Replace("\"status\":\"completed\"", "\"status\":\"partial\"", StringComparison.Ordinal), null);
            };
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.SequenceEqual(new[] { second.SessionId }) && stacked.GovernorRestoreAvailable && stacked.GovernorStatus == "Background restore needs attention",
                "A restore that only partly finished cannot start restoring an older run");

            App.Live.GovernorStatusText = Status(second);
            await stacked.ReloadAsync();
            requests.Clear();
            App.Live.GovernorRestoreHandler = (id, path, backup) =>
            {
                requests.Add(id);
                if (id == second.SessionId)
                {
                    File.WriteAllText(second.SessionPath, File.ReadAllText(second.SessionPath).Replace("\"restorable\":true", "\"restorable\":false", StringComparison.Ordinal));
                    App.Live.GovernorStatusText = Status(first);
                    App.Live.GovernorStatusError = "Status read interrupted.";
                }
                else App.Live.GovernorStatusText = Status(null);
                return new(Restored(id == second.SessionId ? second : first), null);
            };
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(stacked.GovernorRestoreAvailable && stacked.GovernorStatus == "Background restore needs attention",
                "A failed status read after a persisted restore keeps the remaining recovery reachable");
            App.Live.GovernorStatusError = null;
            await stacked.RestoreGovernorCommand.ExecuteAsync(null);
            Case(requests.SequenceEqual(new[] { second.SessionId, first.SessionId }) && !stacked.GovernorRestoreAvailable,
                "Retry after a failed status read finds the older run without replaying the closed newer run");
        }
        finally
        {
            foreach (var (property, value) in saved) property.SetValue(App.Live, value);
            Directory.Delete(root, true);
        }
        check(failures.Count == 0, "Background limits keeps Restore for every run that still holds an app"
            + (failures.Count == 0 ? "" : " | failed: " + string.Join("; ", failures)));
        check(!Directory.Exists(root), "The Background limits check removes its own fixture folder");
    }

    private static Run Write(string root, string name)
    {
        var directory = Directory.CreateDirectory(Path.Combine(root, name)).FullName;
        var run = new Run("process-governor-" + name, Path.Combine(directory, "session.json"), Path.Combine(directory, "backup.json"));
        File.WriteAllText(run.BackupPath, JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false, sessionId = run.SessionId,
            profileId = "probalance-governor", backupId = run.SessionId + "-backup", snapshots = new[] { new { processId = 123 } } }));
        File.WriteAllText(run.SessionPath, JsonSerializer.Serialize(new { sessionId = run.SessionId, profileId = "probalance-governor", dryRun = false, restorable = true,
            backupManifestPath = run.BackupPath }));
        return run;
    }

    private static string Started(Run run) => JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false, status = "completed",
        sessionId = run.SessionId, profileId = "probalance-governor", sessionPath = run.SessionPath, backupManifestPath = run.BackupPath, restorable = true,
        activeRestraints = new[] { new { processId = 123, processName = "Fixture.exe" } },
        result = new { summary = "Process governor completed after 6 poll(s) with 1 restraint(s), 0 restore(s), 0 skip(s), and 1 active restraint(s)." } });

    private static string Watched(Run run) => JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false, status = "completed",
        sessionId = run.SessionId, profileId = "probalance-governor", sessionPath = run.SessionPath, backupManifestPath = run.BackupPath, restorable = true,
        result = new { summary = "Process governor completed after 15 poll(s) with 1 restraint(s), 0 restore(s), 30 skip(s), and 1 active restraint(s).",
            skippedItems = Enumerable.Range(1, 15).SelectMany(poll => new object[]
            {
                new { processId = 77, processName = "Suite.exe", reason = "Foreground process is excluded from governor restraint.", pollIndex = poll },
                new { processId = 123, processName = "Fixture.exe", reason = "Sustained background CPU pressure candidate. Sustained for " + poll * 4 + " second(s).", pollIndex = poll },
            }).Append(new { processId = 123, processName = "Fixture.exe", reason = "GPU scheduling priority is unavailable for this process.", pollIndex = 15 }).ToArray() } });

    private static string Finished() => JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false, status = "completed",
        sessionId = "process-governor-later", profileId = "probalance-governor", restorable = false,
        result = new { summary = "Process governor completed after 6 poll(s) with 0 restraint(s), 0 restore(s), 1 skip(s), and 0 active restraint(s)." } });

    private const string BusyMessage = "Another Background limits run is still going, so this one did not start and nothing changed. Try again once it finishes.";

    private static string Busy() => JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", schemaVersion = 1, dryRun = false, status = "failed",
        sessionStatus = "failed", sessionId = (string?)null, profileId = (string?)null, restorable = false, pollCount = 0, result = (object?)null,
        activeRestraints = Array.Empty<object>(), changedItems = Array.Empty<object>(), skippedItems = Array.Empty<object>(), restoredItems = Array.Empty<object>(),
        errors = new[] { new { code = "PROCESS_GOVERNOR_RUN_BUSY", message = BusyMessage, severity = "warning", source = "performance.governor", blocking = true } } });

    private static string KeptOnly(Run run) => JsonSerializer.Serialize(new { actionId = "performance.governor.stopSession", dryRun = false, status = "completed",
        sessionId = run.SessionId, sessionPath = run.SessionPath, backupManifestPath = run.BackupPath, restorable = true,
        result = new { status = "rolledBack", summary = "Process governor restore completed with 0 restored item(s) and 0 skipped item(s). Left as another program set it: Fixture.exe CPU priority (AboveNormal).",
            leftAsSetItems = new[] { new { processId = 123, processName = "Fixture.exe", control = "priorityClass", currentValue = "AboveNormal", appliedValue = "BelowNormal", originalValue = "Normal", outcome = "leftAsSet" } } } });

    private static string Restored(Run run) => JsonSerializer.Serialize(new { actionId = "performance.governor.stopSession", dryRun = false, status = "completed",
        sessionId = run.SessionId, sessionPath = run.SessionPath, backupManifestPath = run.BackupPath, restorable = false,
        result = new { status = "rolledBack", summary = "Process governor restore completed with 1 restored item(s) and 0 skipped item(s)." } });

    private static string Status(Run? run) => run is null
        ? JsonSerializer.Serialize(new { actionId = "performance.governor.sessionStatus", status = "notFound", sessionStatus = "notFound", restorable = false })
        : JsonSerializer.Serialize(new { actionId = "performance.governor.sessionStatus", dryRun = false, status = "restorable", sessionStatus = "restorable",
            sessionId = run.SessionId, profileId = "probalance-governor", sessionPath = run.SessionPath, backupManifestPath = run.BackupPath, restorable = true,
            summary = new { changedItemCount = 1, restoredItemCount = 0, skippedItemCount = 0, activeRestraintCount = 1, pollCount = 6 } });
}
