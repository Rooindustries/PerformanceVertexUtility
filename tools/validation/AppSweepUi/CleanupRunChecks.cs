using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

static class CleanupRunChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        var live = App.Live;
        var saved = (live.CleanupApply, live.CleanupRestore, live.LeftoverScan, live.CleanupRecoveryPath, live.LastError, live.OperationError, live.CleanupRunsRoot, live.InstalledApps);
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-cleanup-run-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var failures = new List<string>();
        var only = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_SCENARIO");
        async Task Scenario(string name, Func<Task<string?>> body)
        {
            if (!string.IsNullOrEmpty(only) && !name.Contains(only, StringComparison.OrdinalIgnoreCase)) return;
            live.CleanupRecoveryPath = null; live.LastError = null; live.OperationError = null; live.CleanupRunsRoot = null;
            string? failure;
            try { failure = await body(); }
            catch (Exception error) { failure = error.GetType().Name + ": " + error.Message; }
            Console.WriteLine((failure is null ? "PASS " : "FAIL ") + name + (failure is null ? "" : " | " + failure));
            if (failure is not null) failures.Add(name);
        }
        try
        {
            var appA = new InstalledApp { AppId = "registry:fixture-editor", DisplayName = "Roo Industries Fixture Editor", SourceType = "registry" };
            var appB = new InstalledApp { AppId = "registry:fixture-player", DisplayName = "Roo Industries Fixture Player", SourceType = "registry" };
            string Rollback(string appId)
            {
                var path = Path.Combine(root, Guid.NewGuid().ToString("N"), "rollback-manifest.json");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var backup = Path.Combine(Path.GetDirectoryName(path)!, "backup.bin");
                File.WriteAllText(backup, "fixture");
                File.WriteAllText(path, JsonSerializer.Serialize(new { appId, executionStarted = true, restoreSupported = true, fileBackups = new[] { new { itemId = "editor-cache", backupPath = backup } } }));
                return path;
            }
            string Applied(string appId, string rollback, string status = "success", int deleted = 2) => JsonSerializer.Serialize(new
            {
                actionId = "apps.invokeUninstallCleanupApplyPackage",
                appId,
                dryRun = false,
                status,
                executionMode = "real",
                gates = new[] { new { gateId = "confirm-apply", required = true, satisfied = true, blocking = false } },
                errors = Array.Empty<object>(),
                rollback = new { rollbackManifestPath = rollback },
                summary = new { deletedCount = deleted, cleanupItemCount = deleted, blockingGateCount = 0, restoreReady = true },
            });
            string Restored(string rollback) => JsonSerializer.Serialize(new
            {
                actionId = "apps.restoreUninstallCleanupExecution",
                dryRun = false,
                status = "success",
                rollbackManifestPath = rollback,
                executionMode = "real-system-restore",
                gates = new[] { new { gateId = "backup-files-present", required = true, satisfied = true, blocking = false } },
                errors = Array.Empty<object>(),
                restoredItems = new[] { new { itemId = "editor-cache", restored = true } },
                summary = new { restoredCount = 1, blockingGateCount = 0 },
            });
            void Ready(UninstallCleanupViewModel model, InstalledApp app)
            {
                model.SelectedApp = app;
                model.RemovalPathReviewed = true;
                model.LeftoverScanCompleted = true;
                model.CleanupPlanReady = true;
                model.RemovalApproved = true;
                model.FinalCheckPassed = true;
            }
            string? Buttons(UninstallCleanupViewModel model, bool busy)
                => model.ScanBusy == busy && !model.CanReviewRemovalAction && !model.CanScanAction && !model.CanBuildCleanupListAction
                    && !model.CanRunFinalCheckAction && !model.CanApplyCleanupAction && !model.CanRestoreCleanupAction
                    ? null
                    : "busy=" + model.ScanBusy + " route=" + model.CanReviewRemovalAction + " scan=" + model.CanScanAction + " list=" + model.CanBuildCleanupListAction
                        + " final=" + model.CanRunFinalCheckAction + " apply=" + model.CanApplyCleanupAction + " restore=" + model.CanRestoreCleanupAction;
            string? Locked(UninstallCleanupViewModel model) => Buttons(model, busy: true);
            string? Idle(UninstallCleanupViewModel model) => Buttons(model, busy: false);
            string Listed(UninstallCleanupViewModel model) => "apps: " + string.Join(", ", model.Apps.Select(app => app.AppId + (app.Removed ? " (removed)" : "")));
            string Waiting(InstalledApp app) => "Still removing " + app.FriendlyName + ". Pick it again to see the result.";
            (UninstallCleanupViewModel Model, TaskCompletionSource<string?> Remover, List<string> Calls, Task Run) StartApply(InstalledApp app)
            {
                var remover = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                var calls = new List<string>();
                live.CleanupApply = (id, _, _, real) =>
                {
                    if (real) calls.Add(id);
                    return id == app.AppId && calls.Count == 1 ? remover.Task : Task.FromResult<string?>(Applied(id, Rollback(id)));
                };
                var model = new UninstallCleanupViewModel();
                Ready(model, app);
                return (model, remover, calls, model.ApplyCleanupCommand.ExecuteAsync(null));
            }

            await Scenario("Picking another app while a cleanup runs keeps every button locked and says which app is still running", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                var before = model.CleanupExecutionState;
                model.SelectedApp = appB;
                var failure = Locked(model) ?? (model.ApplyApprovalSummary == Waiting(appA) ? null : "summary: " + model.ApplyApprovalSummary);
                remover.SetResult(null);
                await run;
                return before == "Removing this app..." ? failure : "state at start: " + before;
            });

            await Scenario("A second cleanup can't start while one runs, for another app or for the running app picked again", async () =>
            {
                var (model, remover, calls, run) = StartApply(appA);
                model.SelectedApp = appB;
                Ready(model, appB);
                await model.ApplyCleanupCommand.ExecuteAsync(null);
                Ready(model, appA);
                await model.ApplyCleanupCommand.ExecuteAsync(null);
                var started = string.Join(", ", calls);
                remover.SetResult(null);
                await run;
                return started == appA.AppId ? null : "removers started: " + started;
            });

            await Scenario("Picking the running app again shows its cleanup still running", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                model.SelectedApp = appB;
                model.SelectedApp = appA;
                var failure = Locked(model) ?? (model.CleanupExecutionState == "Removing this app..." && model.ApplyApprovalSummary == "Still removing this app. The result shows here when it's done."
                    ? null : "state: " + model.CleanupExecutionState + " / summary: " + model.ApplyApprovalSummary);
                remover.SetResult(null);
                await run;
                return failure;
            });

            await Scenario("A cleanup that finishes while another app is picked shows its result and restore on its own app only", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                model.SelectedApp = appB;
                var stateB = model.CleanupExecutionState;
                remover.SetResult(Applied(appA.AppId!, Rollback(appA.AppId!)));
                await run;
                if (model.ScanBusy || !model.CanScanAction || model.CleanupExecutionState != stateB || model.CleanupRestoreAvailable)
                    return "picked app after finish: busy=" + model.ScanBusy + " scan=" + model.CanScanAction + " state=" + model.CleanupExecutionState + " restore=" + model.CleanupRestoreAvailable;
                model.SelectedApp = appA;
                if (model.CleanupExecutionState != "Done: 2 items removed." || model.CleanupExecutionDetail != "Restore can put them back." || !model.CanRestoreCleanupAction)
                    return "own app: " + model.CleanupExecutionState + " / " + model.CleanupExecutionDetail + " restore=" + model.CanRestoreCleanupAction;
                model.SelectedApp = appB;
                model.SelectedApp = appA;
                return model.CleanupExecutionState != "Done: 2 items removed." && model.CanRestoreCleanupAction
                    ? null : "second visit: " + model.CleanupExecutionState + " restore=" + model.CanRestoreCleanupAction;
            });

            await Scenario("A cleanup that finishes after its app was picked again shows its result right away", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                model.SelectedApp = appB;
                model.SelectedApp = appA;
                remover.SetResult(Applied(appA.AppId!, Rollback(appA.AppId!), deleted: 1));
                await run;
                return !model.ScanBusy && model.CleanupExecutionState == "Done: 1 item removed." && model.CanRestoreCleanupAction
                    ? null : "busy=" + model.ScanBusy + " state=" + model.CleanupExecutionState + " restore=" + model.CanRestoreCleanupAction;
            });

            await Scenario("A cleanup that fails while another app is picked shows its failure on its own app only", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                model.SelectedApp = appB;
                remover.SetException(new IOException("Controlled remover failure"));
                await run;
                if (model.ScanBusy || model.CleanupExecutionState == "Couldn't confirm the removal.")
                    return "picked app: busy=" + model.ScanBusy + " detail=" + model.CleanupExecutionDetail;
                model.SelectedApp = appA;
                return model.CleanupExecutionState == "Couldn't confirm the removal." && model.CleanupExecutionDetail == "If Restore is offered, use it before you try again."
                    ? null : "own app: " + model.CleanupExecutionState + " / " + model.CleanupExecutionDetail;
            });

            await Scenario("A restore that finishes while another app is picked shows its result on its own app only", async () =>
            {
                var rollback = Rollback(appA.AppId!);
                live.CleanupApply = (id, _, _, _) => Task.FromResult<string?>(Applied(id, rollback));
                var restoring = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                live.CleanupRestore = _ => restoring.Task;
                var model = new UninstallCleanupViewModel();
                Ready(model, appA);
                await model.ApplyCleanupCommand.ExecuteAsync(null);
                if (!model.CanRestoreCleanupAction) return "no restore after apply: " + model.CleanupExecutionState;
                var run = model.RestoreCleanupCommand.ExecuteAsync(null);
                model.SelectedApp = appB;
                var failure = Locked(model) ?? (model.ApplyApprovalSummary == "Still restoring " + appA.FriendlyName + ". Pick it again to see the result." ? null : "summary: " + model.ApplyApprovalSummary);
                restoring.SetResult(Restored(rollback));
                await run;
                if (failure is not null) return failure;
                if (model.ScanBusy || model.CleanupExecutionState.StartsWith("Restore complete", StringComparison.Ordinal)) return "picked app: " + model.CleanupExecutionState;
                model.SelectedApp = appA;
                return model.CleanupExecutionState == "Restore complete: 1 item put back." && !model.CleanupRestoreAvailable
                    ? null : "own app: " + model.CleanupExecutionState + " restore=" + model.CleanupRestoreAvailable;
            });

            await Scenario("Picking another app during a leftover scan keeps the buttons locked, starts no second scan and never lists the late result", async () =>
            {
                var scanA = new TaskCompletionSource<LeftoverScan?>(TaskCreationOptions.RunContinuationsAsynchronously);
                var scans = new List<string>();
                live.LeftoverScan = id => { scans.Add(id); return id == appA.AppId ? scanA.Task : Task.FromResult<LeftoverScan?>(new LeftoverScan { AppId = id, DryRun = true, Items = [], Summary = new LeftoverScanSummary() }); };
                var model = new UninstallCleanupViewModel { SelectedApp = appA };
                var run = model.ScanLeftoversCommand.ExecuteAsync(null);
                model.SelectedApp = appB;
                await model.ScanLeftoversCommand.ExecuteAsync(null);
                var failure = Locked(model) ?? (scans.Count == 1 && model.ApplyApprovalSummary == "Still checking " + appA.FriendlyName + ". Wait for it to finish."
                    ? null : "scans: " + string.Join(", ", scans) + " / summary: " + model.ApplyApprovalSummary);
                scanA.SetResult(new LeftoverScan { AppId = appA.AppId, DryRun = true, Items = [new LeftoverItem { ItemId = "editor-cache", Type = "folder", Target = @"C:\Fixture\Editor" }], Summary = new LeftoverScanSummary { ItemCount = 1 } });
                await run;
                return failure ?? (!model.ScanBusy && model.CanScanAction && model.Leftovers.Count == 0 && !model.LeftoverScanCompleted
                    ? null : "after scan: busy=" + model.ScanBusy + " leftovers=" + model.Leftovers.Count);
            });

            await Scenario("Leaving the page and coming back during a cleanup keeps it locked and shows its result on its app", async () =>
            {
                live.InstalledApps = new InstalledAppInventory { Apps = [appA, appB], Complete = true };
                var remover = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                live.CleanupApply = (_, _, _, _) => remover.Task;
                var model = new UninstallCleanupViewModel();
                await model.InitializeAsync();
                Ready(model, model.Apps.Single(app => app.AppId == appA.AppId));
                var run = model.ApplyCleanupCommand.ExecuteAsync(null);
                model.SelectedApp = null;
                await model.InitializeAsync();
                model.SelectedApp = model.Apps.Single(app => app.AppId == appB.AppId);
                var failure = Locked(model) ?? (model.IsReady && model.ApplyApprovalSummary == Waiting(appA) ? null : "ready=" + model.IsReady + " summary: " + model.ApplyApprovalSummary);
                remover.SetResult(Applied(appA.AppId!, Rollback(appA.AppId!), status: "partial", deleted: 1));
                await run;
                if (failure is not null) return failure;
                await model.InitializeAsync();
                model.SelectedApp = model.Apps.Single(app => app.AppId == appA.AppId);
                return model.CleanupExecutionState == "Removal stopped partway." && model.CanRestoreCleanupAction
                    ? null : "own app: " + model.CleanupExecutionState + " restore=" + model.CanRestoreCleanupAction;
            });

            await Scenario("A saved restore for another app shows while a cleanup runs, and Restore unlocks only when the run ends", async () =>
            {
                var runs = Path.Combine(root, "runs-" + Guid.NewGuid().ToString("N"));
                var manifest = Path.Combine(runs, "run-b", "rollback-manifest.json");
                Directory.CreateDirectory(Path.GetDirectoryName(manifest)!);
                var backup = Path.Combine(runs, "run-b", "backup.bin");
                File.WriteAllText(backup, "fixture");
                File.WriteAllText(manifest, JsonSerializer.Serialize(new { appId = appB.AppId, executionStarted = true, restoreSupported = true, fileBackups = new[] { new { itemId = "saved", backupPath = backup } } }));
                var (model, remover, _, run) = StartApply(appA);
                live.CleanupRunsRoot = runs;
                model.SelectedApp = appB;
                for (var wait = 0; wait < 100 && !model.CleanupRestoreAvailable; wait++) await Task.Delay(20);
                var failure = Locked(model) ?? (model.CleanupRestoreAvailable && model.CleanupExecutionState == "An earlier cleanup of this app can be restored."
                    ? null : "restore=" + model.CleanupRestoreAvailable + " state=" + model.CleanupExecutionState);
                remover.SetResult(null);
                await run;
                return failure ?? (model.CanRestoreCleanupAction ? null : "Restore stayed locked after the run ended");
            });

            await Scenario("A restore that finishes while another app is picked keeps its app in the reloaded list, shows the result once and offers no Restore", async () =>
            {
                var runs = Path.Combine(root, "runs-" + Guid.NewGuid().ToString("N"));
                var runA = Path.Combine(runs, "run-a");
                Directory.CreateDirectory(runA);
                var backup = Path.Combine(runA, "backup.bin");
                File.WriteAllText(backup, "fixture");
                var rollback = Path.Combine(runA, "rollback-manifest.json");
                File.WriteAllText(rollback, JsonSerializer.Serialize(new { appId = appA.AppId, displayName = appA.DisplayName, executionStarted = true, restoreSupported = true, fileBackups = new[] { new { itemId = "editor-cache", backupPath = backup } } }));
                live.CleanupRunsRoot = runs;
                live.InstalledApps = new InstalledAppInventory { Apps = [appB], Complete = true };
                var restoring = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                live.CleanupRestore = async _ => { using var change = DataGeneration.BeginChange(); return await restoring.Task; };
                var model = new UninstallCleanupViewModel();
                await model.InitializeAsync();
                var saved = model.Apps.Single(app => app.AppId == appA.AppId);
                model.SelectedApp = saved;
                if (!model.CanRestoreCleanupAction) return "saved restore not offered: " + model.CleanupExecutionState;
                var run = model.RestoreCleanupCommand.ExecuteAsync(null);
                model.SelectedApp = model.Apps.Single(app => app.AppId == appB.AppId);
                restoring.SetResult(Restored(rollback));
                await run;
                if (!File.Exists(Path.Combine(runA, "restored.json"))) return "restore was not marked finished";
                model.SelectedApp = null;
                await model.RevalidateAsync();
                var row = model.Apps.SingleOrDefault(app => app.AppId == appA.AppId);
                if (row is null || ReferenceEquals(row, saved)) return (row is null ? "after reload: " : "list did not reload: ") + Listed(model);
                if (row.SecondaryLabel != "Finished while you were away. Pick it to see the result.") return "result-only row subtitle: " + row.SecondaryLabel;
                model.SelectedApp = row;
                var failure = Idle(model) ?? (model.CleanupExecutionState == "Restore complete: 1 item put back." && !model.CleanupRestoreAvailable
                    ? null : "own app: " + model.CleanupExecutionState + " restore=" + model.CleanupRestoreAvailable);
                if (failure is not null) return failure;
                model.SelectedApp = null;
                await model.InitializeAsync();
                return model.Apps.Any(app => app.AppId == appA.AppId) ? "row stayed after its result was shown: " + Listed(model) : null;
            });

            await Scenario("An app its own remover removed while another app is picked stays in the reloaded list and shows the new-review notice once", async () =>
            {
                live.InstalledApps = new InstalledAppInventory { Apps = [appA, appB], Complete = true };
                var remover = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                live.CleanupApply = async (_, _, _, _) => { using var change = DataGeneration.BeginChange(); return await remover.Task; };
                var model = new UninstallCleanupViewModel();
                await model.InitializeAsync();
                Ready(model, model.Apps.Single(app => app.AppId == appA.AppId));
                var run = model.ApplyCleanupCommand.ExecuteAsync(null);
                model.SelectedApp = model.Apps.Single(app => app.AppId == appB.AppId);
                live.InstalledApps = new InstalledAppInventory { Apps = [appB], Complete = true };
                remover.SetResult(JsonSerializer.Serialize(new { actionId = "apps.invokeUninstallCleanupApplyPackage", appId = appA.AppId, dryRun = false, status = "cleanup-review-required", executionMode = "real", summary = new { restoreReady = false, deletedCount = 0, blockingGateCount = 0 } }));
                await run;
                model.SelectedApp = null;
                await model.RevalidateAsync();
                var row = model.Apps.SingleOrDefault(app => app.AppId == appA.AppId);
                if (row is not { Removed: true }) return (row is null ? "after reload: " : "list did not reload: ") + Listed(model);
                if (row.SecondaryLabel != "Finished while you were away. Pick it to see the result.") return "result-only row subtitle: " + row.SecondaryLabel;
                model.SelectedApp = row;
                var failure = Idle(model) ?? (model.CleanupExecutionState == "App removed. The old list wasn't used."
                    && model.CleanupExecutionDetail == "Its uninstaller may have changed things. To clean up what it left, start again from Check."
                    ? null : "own app: " + model.CleanupExecutionState + " / " + model.CleanupExecutionDetail);
                if (failure is not null) return failure;
                model.SelectedApp = null;
                await model.InitializeAsync();
                return model.Apps.Any(app => app.AppId == appA.AppId) ? "row stayed after its result was shown: " + Listed(model) : null;
            });

            string Saved(string runs, InstalledApp app)
            {
                var run = Directory.CreateDirectory(Path.Combine(runs, Guid.NewGuid().ToString("N"))).FullName;
                var backup = Path.Combine(run, "backup.bin");
                File.WriteAllText(backup, "fixture");
                var manifest = Path.Combine(run, "rollback-manifest.json");
                File.WriteAllText(manifest, JsonSerializer.Serialize(new { appId = app.AppId, displayName = app.DisplayName, executionStarted = true, restoreSupported = true, fileBackups = new[] { new { itemId = "editor-cache", backupPath = backup } } }));
                return manifest;
            }

            await Scenario("An earlier cleanup found while a cleanup of the same app runs doesn't replace that run's result", async () =>
            {
                live.CleanupRunsRoot = Path.Combine(root, "runs-" + Guid.NewGuid().ToString("N"));
                Saved(live.CleanupRunsRoot, appA);
                live.CleanupRecoveryDelay = TimeSpan.FromMilliseconds(400);
                try
                {
                    live.CleanupApply = (_, _, _, _) => Task.FromResult<string?>(null);
                    live.LastError = "The cleanup helper stopped.";
                    var model = new UninstallCleanupViewModel();
                    Ready(model, appA);
                    await model.ApplyCleanupCommand.ExecuteAsync(null);
                    var (state, detail) = (model.CleanupExecutionState, model.CleanupExecutionDetail);
                    await Task.Delay(TimeSpan.FromMilliseconds(900));
                    return model.CleanupExecutionState == state && model.CleanupExecutionDetail == detail && !model.CleanupRestoreAvailable
                        ? null : "after the run: " + state + " / " + detail + "; after the earlier cleanup was found: " + model.CleanupExecutionState + " / " + model.CleanupExecutionDetail + " restore=" + model.CleanupRestoreAvailable;
                }
                finally { live.CleanupRecoveryDelay = TimeSpan.Zero; }
            });

            await Scenario("Leftover cleanup shows plain words, keeps raw errors in the app log and asks once before it removes an app", async () =>
            {
                var logged = new List<string>();
                var observer = AppLog.Observer;
                var kept = (live.OfficialPreview, live.CleanupManifest, live.CleanupPlan);
                AppLog.Observer = (_, detail) => { if (detail is not null) lock (logged) logged.Add(detail); };
                try
                {
                    const string raw = "Invoke-UninstallCleanupApplyPackage.ps1: System.IO.IOException: Access to the path 'C:\\Fixture' is denied.";
                    var model = new UninstallCleanupViewModel { SelectedApp = appA };
                    var problems = new List<string>();
                    void Look(string step)
                    {
                        foreach (var property in typeof(UninstallCleanupViewModel).GetProperties()
                            .Where(property => property.PropertyType == typeof(string) && property.Name is not ("SearchText" or "SelectedName" or "SelectedSummary" or "InstallLocation" or "OfficialCommand" or "Sources")))
                            if (property.GetValue(model) is string text && BulkRemovalChecks.Jargon(text) is { } token) problems.Add(step + ": " + property.Name + " shows '" + token + "': " + text);
                        foreach (var item in model.Leftovers)
                            if (BulkRemovalChecks.Jargon(item.TypeLabel + " " + item.ConfidenceLabel) is { } token || item.TypeLabel == item.Type || item.ConfidenceLabel == item.Confidence)
                                problems.Add(step + ": leftover shows " + item.Type + " / " + item.Confidence + " as " + item.TypeLabel + " / " + item.ConfidenceLabel);
                    }
                    Look("start");
                    live.LastError = raw;
                    live.OfficialPreview = _ => Task.FromResult<OfficialUninstallPreview?>(null);
                    await model.PreviewRemovalCommand.ExecuteAsync(null); Look("check failed");
                    live.LastError = null;
                    live.OfficialPreview = _ => Task.FromResult<OfficialUninstallPreview?>(new OfficialUninstallPreview { DryRun = true, Commands = [] });
                    await model.PreviewRemovalCommand.ExecuteAsync(null); Look("checked");
                    live.OfficialPreview = id => Task.FromResult<OfficialUninstallPreview?>(new OfficialUninstallPreview
                    {
                        DryRun = true,
                        Commands = [new UninstallCommand { AppId = id, CommandType = "registry-uninstall-string", RawCommand = "uninstall.exe /S", CommandLine = "\"C:\\Fixture\\uninstall.exe\" /S", ExecutableSha256 = new string('a', 64), Blocked = true }],
                    });
                    await model.PreviewRemovalCommand.ExecuteAsync(null); Look("needed by Windows");
                    if (model.OfficialPreviewState != UninstallCleanupViewModel.BlockedHere) problems.Add("an app Windows or games may need doesn't say to use Remove apps: " + model.OfficialPreviewState);
                    live.OfficialPreview = _ => Task.FromResult<OfficialUninstallPreview?>(new OfficialUninstallPreview { DryRun = true, Commands = [] });
                    await model.PreviewRemovalCommand.ExecuteAsync(null);
                    live.LastError = raw;
                    live.LeftoverScan = _ => Task.FromResult<LeftoverScan?>(null);
                    await model.ScanLeftoversCommand.ExecuteAsync(null); Look("scan failed");
                    live.LastError = null;
                    live.LeftoverScan = id => Task.FromResult<LeftoverScan?>(new LeftoverScan
                    {
                        AppId = id, DryRun = true, Summary = new LeftoverScanSummary { ItemCount = 4 },
                        Items = [new() { ItemId = "a", Type = "folder", Confidence = "high", Target = @"C:\Fixture" }, new() { ItemId = "b", Type = "registryKey", Confidence = "medium", Target = @"HKCU\Software\Fixture" },
                            new() { ItemId = "c", Type = "scheduledTask", Confidence = "low", Target = @"\Fixture" }, new() { ItemId = "d", Type = "service", Target = "FixtureService" }],
                    });
                    await model.ScanLeftoversCommand.ExecuteAsync(null); Look("scanned");
                    live.LastError = raw;
                    live.CleanupManifest = _ => Task.FromResult<CleanupManifest?>(null);
                    await model.BuildCleanupListCommand.ExecuteAsync(null); Look("list failed");
                    live.LastError = null;
                    live.CleanupManifest = id => Task.FromResult<CleanupManifest?>(new CleanupManifest { AppId = id, DryRun = true, Items = [], Summary = new CleanupManifestSummary() });
                    live.CleanupPlan = _ => throw new InvalidOperationException(raw);
                    await model.BuildCleanupListCommand.ExecuteAsync(null); Look("plan failed");
                    live.CleanupPlan = id => Task.FromResult<UninstallCleanupExecutionPlan?>(new UninstallCleanupExecutionPlan
                    {
                        AppId = id, DryRun = true, Status = "review-ready", Summary = new UninstallExecutionSummary { ExecutionReady = true, DisposableFixtureExecutionReady = true },
                    });
                    await model.BuildCleanupListCommand.ExecuteAsync(null); Look("list ready");
                    if (!model.CleanupPlanReady || model.CanRunFinalCheckAction) return "the final check unlocked before the approval box, or the list never got ready: ready=" + model.CleanupPlanReady;
                    var sent = new List<(bool Route, bool List, bool Real)>();
                    live.CleanupApply = (id, route, list, real) =>
                    {
                        sent.Add((route, list, real));
                        return Task.FromResult<string?>(real ? null : JsonSerializer.Serialize(new
                        {
                            actionId = "apps.invokeUninstallCleanupApplyPackage", appId = id, dryRun = true, status = "preview", executionMode = "preview",
                            gates = new[] { new { gateId = "confirm-apply", required = true, satisfied = false, blocking = true }, new { gateId = "review-inputs", required = true, satisfied = true, blocking = false } },
                            errors = Array.Empty<object>(), summary = new { approvalReady = true, cleanupItemCount = 2, blockingGateCount = 1 },
                        }));
                    };
                    model.RemovalApproved = true;
                    await model.RunFinalCheckCommand.ExecuteAsync(null); Look("final check");
                    if (!model.FinalCheckPassed || !model.CanApplyCleanupAction) return "one approval and a passed final check didn't unlock Remove app: " + model.ApplyApprovalSummary;
                    live.LastError = raw;
                    await model.ApplyCleanupCommand.ExecuteAsync(null); Look("removal failed");
                    string Result(string id, string status, bool real) => JsonSerializer.Serialize(new
                    {
                        actionId = "apps.invokeUninstallCleanupApplyPackage", appId = id, dryRun = !real, status, executionMode = real ? "real" : "preview",
                        gates = new[] { new { gateId = "confirm-apply", required = true, satisfied = real, blocking = !real } },
                        errors = Array.Empty<object>(), summary = new { approvalReady = true, deletedCount = 1, cleanupItemCount = 1, blockingGateCount = real ? 0 : 1 },
                    });
                    live.LastError = null;
                    live.CleanupApply = (id, _, _, real) => Task.FromResult<string?>(Result(id, real ? "success" : "preview", real));
                    await model.RunFinalCheckCommand.ExecuteAsync(null);
                    await model.ApplyCleanupCommand.ExecuteAsync(null); Look("removed");
                    if (model.CleanupExecutionState != "Done: 1 item removed." || model.CanApplyCleanupAction || model.CanRunFinalCheckAction || model.CanBuildCleanupListAction)
                        problems.Add("the finished list can run again after a removal: " + model.CleanupExecutionState);
                    model.RemovalPathReviewed = true; model.LeftoverScanCompleted = true; model.CleanupPlanReady = true; model.RemovalApproved = true;
                    live.CleanupApply = (id, _, _, real) => Task.FromResult<string?>(Result(id, real ? "cleanup-review-required" : "preview", real));
                    await model.RunFinalCheckCommand.ExecuteAsync(null);
                    live.LastCleanupRollbackPath = "kept";
                    await model.ApplyCleanupCommand.ExecuteAsync(null); Look("uninstaller ran");
                    if (model.ApplyApprovalSummary != "Check the app first." || model.CanRunFinalCheckAction || model.CanBuildCleanupListAction || model.RemovalApproved)
                        problems.Add("after its uninstaller ran, the old check or list still looks ready: " + model.ApplyApprovalSummary);
                    if (live.LastCleanupRollbackPath is not null) problems.Add("the stored uninstaller check was kept after a real run");
                    model.RemovalPathReviewed = true; model.LeftoverScanCompleted = true; model.CleanupPlanReady = true; model.RemovalApproved = true;
                    live.CleanupApply = (id, _, _, real) => Task.FromResult<string?>(Result(id, "failed", real));
                    await model.RunFinalCheckCommand.ExecuteAsync(null); Look("final check failed");
                    if (model.CleanupExecutionState != "Final check failed." || model.FinalCheckPassed) problems.Add("a failed final check reads as a failed removal: " + model.CleanupExecutionState);
                    if (typeof(UninstallCleanupViewModel).GetProperties().Count(property => property.PropertyType == typeof(bool) && property.Name.EndsWith("Approved", StringComparison.Ordinal)) != 1)
                        problems.Add("more than one approval box is back");
                    if (sent.Count != 2 || !sent.All(call => call.Route && call.List) || sent[0].Real || !sent[1].Real) problems.Add("the one box didn't approve both the uninstaller and the list: " + string.Join(", ", sent));
                    if (logged.Count(line => line.Contains("Access to the path", StringComparison.Ordinal)) < 4) problems.Add("raw errors didn't reach the app log: " + logged.Count);
                    return problems.Count == 0 ? null : string.Join(" | ", problems);
                }
                finally { AppLog.Observer = observer; (live.OfficialPreview, live.CleanupManifest, live.CleanupPlan) = kept; }
            });

            foreach (var removedByRun in new[] { false, true })
                await Scenario(removedByRun
                    ? "A cleanup that removed its app while another app is picked marks the app's saved-cleanup row as waiting until its result is shown"
                    : "A cleanup that finishes while another app is picked marks its still-installed app's row as waiting until its result is shown", async () =>
                {
                    var runs = live.CleanupRunsRoot = Path.Combine(root, "runs-" + Guid.NewGuid().ToString("N"));
                    live.InstalledApps = new InstalledAppInventory { Apps = [appA, appB], Complete = true };
                    var remover = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                    live.CleanupApply = async (_, _, _, _) => { using var change = DataGeneration.BeginChange(); return await remover.Task; };
                    var model = new UninstallCleanupViewModel();
                    await model.InitializeAsync();
                    Ready(model, model.Apps.Single(app => app.AppId == appA.AppId));
                    var run = model.ApplyCleanupCommand.ExecuteAsync(null);
                    model.SelectedApp = model.Apps.Single(app => app.AppId == appB.AppId);
                    if (removedByRun) live.InstalledApps = new InstalledAppInventory { Apps = [appB], Complete = true };
                    remover.SetResult(Applied(appA.AppId!, Saved(runs, appA)));
                    await run;
                    model.SelectedApp = null;
                    await model.RevalidateAsync();
                    var row = model.Apps.SingleOrDefault(app => app.AppId == appA.AppId);
                    if (row is null || row.Removed != removedByRun || row.SecondaryLabel != "Finished while you were away. Pick it to see the result.")
                        return "row before its result was shown: " + (row is null ? Listed(model) : "removed=" + row.Removed + " / " + row.SecondaryLabel);
                    model.SelectedApp = row;
                    if (model.CleanupExecutionState != "Done: 2 items removed.") return "own app: " + model.CleanupExecutionState;
                    model.SelectedApp = null;
                    await model.RevalidateAsync();
                    row = model.Apps.SingleOrDefault(app => app.AppId == appA.AppId);
                    return row?.SecondaryLabel == "Finished while you were away. Pick it to see the result." ? "row still waiting after its result was shown" : null;
                });

            await Scenario("A cleanup result for an app that is still installed but hidden from the list doesn't come back as a removed app", async () =>
            {
                live.InstalledApps = new InstalledAppInventory { Apps = [appA, appB], Complete = true };
                var remover = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
                live.CleanupApply = async (_, _, _, _) => { using var change = DataGeneration.BeginChange(); return await remover.Task; };
                var model = new UninstallCleanupViewModel();
                await model.InitializeAsync();
                Ready(model, model.Apps.Single(app => app.AppId == appA.AppId));
                var run = model.ApplyCleanupCommand.ExecuteAsync(null);
                model.SelectedApp = model.Apps.Single(app => app.AppId == appB.AppId);
                live.InstalledApps = new InstalledAppInventory { Apps = [new InstalledApp { AppId = appA.AppId, DisplayName = null, SourceType = "registry" }, appB], Complete = true };
                remover.SetResult(Applied(appA.AppId!, Rollback(appA.AppId!)));
                await run;
                model.SelectedApp = null;
                await model.RevalidateAsync();
                return model.Apps.Any(app => app.AppId == appA.AppId && app.Removed) ? "the installed app came back as removed: " + Listed(model) : null;
            });
        }
        finally
        {
            (live.CleanupApply, live.CleanupRestore, live.LeftoverScan, live.CleanupRecoveryPath, live.LastError, live.OperationError, live.CleanupRunsRoot, live.InstalledApps) = saved;
            Directory.Delete(root, true);
        }
        check(failures.Count == 0, "Leftover cleanup run checks (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
