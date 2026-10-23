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
                model.RemoverPathApproved = true;
                model.CleanupListApproved = true;
                model.RealCleanupApproved = true;
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
            string Waiting(InstalledApp app) => "Still cleaning up " + app.FriendlyName + ". Pick it again to see the result.";
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
                return before == "Applying reviewed cleanup..." ? failure : "state at start: " + before;
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
                var failure = Locked(model) ?? (model.CleanupExecutionState == "Applying reviewed cleanup..." && model.ApplyApprovalSummary == "Still cleaning up this app. The result shows here when it's done."
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
                if (model.CleanupExecutionState != "Cleanup applied: 2 items removed." || model.CleanupExecutionDetail != "Restore is ready from the backup." || !model.CanRestoreCleanupAction)
                    return "own app: " + model.CleanupExecutionState + " / " + model.CleanupExecutionDetail + " restore=" + model.CanRestoreCleanupAction;
                model.SelectedApp = appB;
                model.SelectedApp = appA;
                return model.CleanupExecutionState != "Cleanup applied: 2 items removed." && model.CanRestoreCleanupAction
                    ? null : "second visit: " + model.CleanupExecutionState + " restore=" + model.CanRestoreCleanupAction;
            });

            await Scenario("A cleanup that finishes after its app was picked again shows its result right away", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                model.SelectedApp = appB;
                model.SelectedApp = appA;
                remover.SetResult(Applied(appA.AppId!, Rollback(appA.AppId!), deleted: 1));
                await run;
                return !model.ScanBusy && model.CleanupExecutionState == "Cleanup applied: 1 item removed." && model.CanRestoreCleanupAction
                    ? null : "busy=" + model.ScanBusy + " state=" + model.CleanupExecutionState + " restore=" + model.CanRestoreCleanupAction;
            });

            await Scenario("A cleanup that fails while another app is picked shows its failure on its own app only", async () =>
            {
                var (model, remover, _, run) = StartApply(appA);
                model.SelectedApp = appB;
                remover.SetException(new IOException("Controlled remover failure"));
                await run;
                if (model.ScanBusy || model.CleanupExecutionDetail?.Contains("Controlled remover failure", StringComparison.Ordinal) == true)
                    return "picked app: busy=" + model.ScanBusy + " detail=" + model.CleanupExecutionDetail;
                model.SelectedApp = appA;
                return model.CleanupExecutionState == "Cleanup result was not confirmed." && model.CleanupExecutionDetail == "Controlled remover failure"
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
                return model.CleanupExecutionState == "Cleanup stopped partway through." && model.CanRestoreCleanupAction
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
                var row = model.Apps.SingleOrDefault(app => app.AppId == appA.AppId);
                if (row is null || ReferenceEquals(row, saved)) return (row is null ? "after reload: " : "list did not reload: ") + Listed(model);
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
                var row = model.Apps.SingleOrDefault(app => app.AppId == appA.AppId);
                if (row is not { Removed: true }) return (row is null ? "after reload: " : "list did not reload: ") + Listed(model);
                model.SelectedApp = row;
                var failure = Idle(model) ?? (model.CleanupExecutionState == "App removal completed. Leftover cleanup needs a new review."
                    && model.CleanupExecutionDetail == "The old deletion list was not applied. Leftover files require a fresh scan and separate approval."
                    ? null : "own app: " + model.CleanupExecutionState + " / " + model.CleanupExecutionDetail);
                if (failure is not null) return failure;
                model.SelectedApp = null;
                await model.InitializeAsync();
                return model.Apps.Any(app => app.AppId == appA.AppId) ? "row stayed after its result was shown: " + Listed(model) : null;
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
