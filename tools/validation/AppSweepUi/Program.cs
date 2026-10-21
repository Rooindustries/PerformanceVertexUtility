using System.Reflection;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

var count = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    count++;
    Console.WriteLine("PASS " + message);
}

if (args is ["bug-report-folder"]) { await BugReportChecks.OpenFolderAsync(Check); Console.WriteLine($"Completed {count} bug report folder checks."); return; }

if (args is ["governor-actions"])
{
    await GovernorChecks.Scheduled(Check);
    Console.WriteLine($"Completed {count} governor action checks.");
    return;
}

if (args is ["governor-left-as-set"])
{
    await GovernorChecks.LeftAsSetAsync(Check);
    Console.WriteLine($"Completed {count} governor ownership restore checks.");
    return;
}

if (args is ["revisit"])
{
    await RevisitChecks.RunAsync(Check);
    Console.WriteLine($"Completed {count} app sweep UI checks.");
    return;
}

if (args is [] or ["restore-summary"] or ["restore-summary", _])
{
    var output = args.Length > 1 ? Path.GetFullPath(args[1]) : Path.Combine(Path.GetTempPath(), "restore-summary-" + Guid.NewGuid().ToString("N"));
    var fixtures = Path.Combine(output, "fixtures-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(fixtures);
    var saved = App.Live.GetType().GetProperties(BindingFlags.Instance | BindingFlags.Public)
        .Where(property => property.CanWrite).Select(property => (Property: property, Value: property.GetValue(App.Live))).ToArray();
    var failures = new List<string>();
    var observations = new List<object>();
    void Verify(bool condition, string message)
    {
        if (condition) Check(true, message);
        else { failures.Add(message); Console.WriteLine("FAIL " + message); }
    }
    void Capture(string name, string receipt, PerformanceProfilesViewModel model)
        => observations.Add(new { name, receipt = JsonSerializer.Deserialize<JsonElement>(receipt), model.ActionTitle, model.ActionDetail,
            model.RestoreAvailable, model.MatchTuneStatus, model.MatchTuneDetail, model.MatchTuneRestoreAvailable, model.GovernorDetail,
            recoveryPath = App.Live.ProcessProfileRecovery?.Path, App.Live.LastProcessRestorePath, App.Live.LastGameRestoreRequest });
    var preview = new[] { new { processName = "Target", controlChanges = Array.Empty<object>(),
        leftAsSet = new[] { new { control = "priorityClass", currentValue = "BelowNormal" } } } };
    var restored = new[] { new { processName = "Peer", restoredControls = new[] {
        new { control = "priorityClass", currentValue = "AboveNormal", proposedValue = "Normal", outcome = "applied" } } } };
    var applied = new[] { new { processName = "Peer", appliedControls = new[] {
        new { control = "priorityClass", currentValue = "AboveNormal", proposedValue = "Normal", outcome = "applied" } },
        controlChanges = new[] { new { control = "gpuPriority", currentValue = "Normal", proposedValue = "Realtime", outcome = "failed" } } } };
    var kept = new[] { new { processName = "Target", control = "priorityClass", currentValue = "Idle" } };
    const string reason = "priorityClass: Undo could not confirm another program still holds it. Run Undo again.";
    var skipped = new[] { new { processName = "Target", reason } };
    try
    {
        App.Live.LastError = App.Live.OperationError = App.Live.GameTuneResultError = App.Live.GameTuneRestoreError = null;
        App.Live.ProcessProfileRecovery = null;
        var backup = Path.Combine(fixtures, "process.json");
        File.WriteAllText(backup, JsonSerializer.Serialize(new { actionId = "performance.applyProfile", backupId = "summary-backup", profileId = "summary-profile",
            dryRun = false, snapshots = new[] { new { processId = 123 } } }));
        var profile = new PerformanceProfilesViewModel();
        App.Live.ProcessPreviewText = JsonSerializer.Serialize(new { actionId = "performance.previewProfile", dryRun = true, status = "preview", preview,
            result = new { summary = "Restore preview." } });
        await profile.PreviewPlanCommand.ExecuteAsync(null);
        Capture("profile-preview", App.Live.ProcessPreviewText, profile);
        Verify(profile.ActionDetail.Contains("CPU BelowNormal (left as another program set it)", StringComparison.Ordinal), "Profile preview names the proposed kept value");
        App.Live.ProcessApplyText = JsonSerializer.Serialize(new { actionId = "performance.applyProfile", dryRun = false, status = "success",
            backup = new { backupId = "summary-backup", location = backup, rollbackSupported = true },
            result = new { status = "success", summary = "Applied controls.", changedItems = applied } });
        await profile.ApplyProfileCommand.ExecuteAsync(null);
        Verify(profile.RestoreAvailable, "Summary profile apply binds the exact recovery artifact");
        Verify(profile.ActionDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal), "Confirmed apply details use applied controls");
        App.Live.ProcessRestoreText = JsonSerializer.Serialize(new { actionId = "performance.rollbackProfile", dryRun = false, status = "partial", preview,
            backup = new { backupId = "summary-backup", location = backup },
            result = new { status = "partial", summary = "Partial restore.", changedItems = restored, leftAsSetItems = Array.Empty<object>(), skippedItems = skipped, restorePendingCount = 1 } });
        await profile.RestoreProfileCommand.ExecuteAsync(null);
        Capture("profile-partial", App.Live.ProcessRestoreText, profile);
        Verify(profile.RestoreAvailable && profile.CanRestoreProfile && App.Live.ProcessProfileRecovery?.Path == backup && App.Live.LastProcessRestorePath == backup,
            "Partial profile restore retains and requests its exact recovery artifact");
        Verify(profile.ActionDetail.StartsWith("Partial restore.", StringComparison.Ordinal) && profile.ActionDetail.Contains(reason, StringComparison.Ordinal)
            && !profile.ActionDetail.Contains("BelowNormal", StringComparison.Ordinal), "Partial profile details report the failed confirmation without a stale kept value");
        Verify(profile.ActionDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal), "Partial profile details retain unrelated restored controls");
        var backendReason = "Restore finished for 1 app(s). 1 app(s) still need attention: Target (PID 123): " + reason + ".";
        foreach (var identity in new[] { "matched", "shared", "missing-id", "string-id" })
        {
            object[] actualSkipped = identity switch
            {
                "shared" => [new { processName = "Target", processId = 123, reason }, new { processName = "Other", processId = 124, reason }],
                "missing-id" => [new { processName = "Target", reason }],
                "string-id" => [new { processName = "Target", processId = "123", reason }],
                _ => [new { processName = "Target", processId = 123, reason }],
            };
            App.Live.ProcessRestoreText = JsonSerializer.Serialize(new { actionId = "performance.rollbackProfile", dryRun = false, status = "partial", preview,
                backup = new { backupId = "summary-backup", location = backup },
                result = new { status = "partial", summary = backendReason, changedItems = restored, leftAsSetItems = Array.Empty<object>(), skippedItems = actualSkipped, restorePendingCount = 1 } });
            await profile.RestoreProfileCommand.ExecuteAsync(null);
            Capture("profile-summary-skipped-" + identity, App.Live.ProcessRestoreText, profile);
            Verify(profile.ActionDetail.Split(reason, StringSplitOptions.None).Length - 1 == (identity == "matched" ? 1 : 2)
                && (identity != "shared" || profile.ActionDetail.Contains("Other: " + reason, StringComparison.Ordinal)),
                "Skipped summary deduplication requires the exact numeric process identity: " + identity);
        }
        foreach (var completeList in new[] { true, false })
        {
            object[] actualKept = completeList ? kept : [kept[0], new { processName = "Other", control = "priorityClass", currentValue = "Idle" }];
            App.Live.ProcessRestoreText = JsonSerializer.Serialize(new { actionId = "performance.rollbackProfile", dryRun = false, status = "partial", preview,
                backup = new { backupId = "summary-backup", location = backup },
                result = new { status = "partial", summary = "Restore completed. Left as another program set it: Target CPU priority (Idle).", changedItems = restored,
                    leftAsSetItems = actualKept, skippedItems = Array.Empty<object>(), restorePendingCount = 1 } });
            await profile.RestoreProfileCommand.ExecuteAsync(null);
            Capture("profile-summary-kept-" + completeList, App.Live.ProcessRestoreText, profile);
            Verify(profile.ActionDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal) && (completeList
                ? profile.ActionDetail.Split("Idle", StringSplitOptions.None).Length - 1 == 1
                : profile.ActionDetail.Contains("Other: CPU Idle (left as another program set it)", StringComparison.Ordinal)
                    && profile.ActionDetail.Contains("Target: CPU Idle (left as another program set it)", StringComparison.Ordinal)),
                "Kept summary deduplication requires the complete actual list: " + completeList);
        }
        App.Live.ProcessRestoreText = JsonSerializer.Serialize(new { actionId = "performance.rollbackProfile", dryRun = false, status = "success", preview,
            backup = new { backupId = "summary-backup", location = backup },
            result = new { status = "success", summary = "Restore completed.", changedItems = applied, leftAsSetItems = kept, skippedItems = Array.Empty<object>(), restorePendingCount = 0 } });
        await profile.RestoreProfileCommand.ExecuteAsync(null);
        Capture("profile-success", App.Live.ProcessRestoreText, profile);
        Verify(!profile.RestoreAvailable && App.Live.ProcessProfileRecovery is null, "Successful profile restore clears only its exact recovery artifact");
        Verify(profile.ActionDetail.Contains("Target: CPU Idle (left as another program set it)", StringComparison.Ordinal)
            && !profile.ActionDetail.Contains("BelowNormal", StringComparison.Ordinal), "Confirmed profile details certify the fresh Idle value only");
        Verify(profile.ActionDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal) && !profile.ActionDetail.Contains("Realtime", StringComparison.Ordinal),
            "Confirmed profile details prefer applied controls over stale control changes");

        var sessionPath = Path.Combine(fixtures, "session.json");
        var sessionBackup = Path.Combine(fixtures, "game.json");
        File.WriteAllText(sessionBackup, JsonSerializer.Serialize(new { actionId = "performance.gameTune.startSession", backupId = "summary-game-backup",
            sessionId = "summary-session", profileId = "summary-game", dryRun = false, snapshots = new[] { new { processId = 123 } } }));
        File.WriteAllText(sessionPath, JsonSerializer.Serialize(new { sessionId = "summary-session", profileId = "summary-game", dryRun = false,
            restorable = true, backupManifestPath = sessionBackup }));
        var game = new PerformanceProfilesViewModel { HasGameRunning = true };
        App.Live.GameTuneText = JsonSerializer.Serialize(new { actionId = "performance.gameTune.startSession", dryRun = true, status = "preview", preview,
            result = new { summary = "Game restore preview." } });
        await game.CheckMatchTuneCommand.ExecuteAsync(null);
        Capture("game-preview", App.Live.GameTuneText, game);
        Verify(game.MatchTuneDetail.Contains("CPU BelowNormal (left as another program set it)", StringComparison.Ordinal), "Game preview names the proposed kept value");
        App.Live.GameTuneText = JsonSerializer.Serialize(new { actionId = "performance.gameTune.startSession", dryRun = false, status = "active",
            sessionId = "summary-session", profileId = "summary-game", sessionPath, backupManifestPath = sessionBackup, restorable = true,
            summary = new { changedItemCount = 1 }, changedItems = applied });
        await game.StartMatchTuneCommand.ExecuteAsync(null);
        Verify(game.MatchTuneRestoreAvailable, "Summary game start binds the exact session recovery artifact");
        App.Live.GameTuneRestoreText = JsonSerializer.Serialize(new { actionId = "performance.gameTune.stopSession", dryRun = false, status = "completed",
            sessionId = "summary-session", profileId = "summary-game", sessionPath, backupManifestPath = sessionBackup, restorable = true, preview,
            result = new { status = "partial", summary = "Partial game restore.", restoredItems = restored, leftAsSetItems = Array.Empty<object>(), skippedItems = skipped } });
        await game.RestoreMatchTuneCommand.ExecuteAsync(null);
        Capture("game-partial", App.Live.GameTuneRestoreText, game);
        Verify(game.MatchTuneRestoreAvailable && game.CanRestoreMatchTune && App.Live.LastGameRestoreRequest == ("summary-session", sessionPath, sessionBackup),
            "Partial game restore retains and requests its exact session artifact");
        Verify(game.MatchTuneDetail.StartsWith("Partial game restore.", StringComparison.Ordinal) && game.MatchTuneDetail.Contains(reason, StringComparison.Ordinal)
            && !game.MatchTuneDetail.Contains("BelowNormal", StringComparison.Ordinal), "Partial game details report the failed confirmation without a stale kept value");
        Verify(game.MatchTuneDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal), "Confirmed game details use restored-item evidence when changed items are absent");
        var mixed = new object?[] { null, new { processName = "Peer", controlChanges = new object?[] { null,
            new { control = "priorityClass", currentValue = "AboveNormal", proposedValue = "Normal", outcome = "applied" },
            new { control = "gpuPriority", currentValue = "Normal", proposedValue = "Realtime", outcome = "failed" } } } };
        App.Live.GameTuneRestoreText = JsonSerializer.Serialize(new { actionId = "performance.gameTune.stopSession", dryRun = false, status = "completed",
            sessionId = "summary-session", profileId = "summary-game", sessionPath, backupManifestPath = sessionBackup, restorable = false, preview,
            result = new { status = "rolledBack", summary = "Game restore completed.", restoredItems = mixed, leftAsSetItems = kept, skippedItems = Array.Empty<object>() } });
        await game.RestoreMatchTuneCommand.ExecuteAsync(null);
        Capture("game-success", App.Live.GameTuneRestoreText, game);
        Verify(!game.MatchTuneRestoreAvailable, "Successful game restore finishes its exact session recovery");
        Verify(game.MatchTuneDetail.Contains("Target: CPU Idle (left as another program set it)", StringComparison.Ordinal)
            && !game.MatchTuneDetail.Contains("BelowNormal", StringComparison.Ordinal), "Confirmed game details certify the fresh Idle value only");
        Verify(game.MatchTuneDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal) && !game.MatchTuneDetail.Contains("Realtime", StringComparison.Ordinal),
            "Confirmed game details ignore malformed entries and explicitly failed controls without hiding the restored peer");
        App.Live.Classification = new ProcessClassification { Processes = [new ProcessItem { Name = "Target", Category = "foregroundGame" }] };
        App.Live.GameTuneStatusError = App.Live.GovernorStatusError = null;
        foreach (var retained in new[] { false, true })
        {
            File.WriteAllText(sessionPath, JsonSerializer.Serialize(new { sessionId = "summary-session", profileId = "summary-game", dryRun = false,
                restorable = retained, backupManifestPath = sessionBackup }));
            App.Live.GameTuneStatusText = JsonSerializer.Serialize(new { actionId = "performance.gameTune.sessionStatus", dryRun = false,
                status = retained ? "restorable" : "completed", sessionId = "summary-session", profileId = "summary-game", sessionPath,
                backupManifestPath = sessionBackup, restorable = retained, active = false, completed = !retained, failed = false,
                summary = new { changedItemCount = 1, restoredItemCount = 1, skippedItemCount = retained ? 1 : 0, pollCount = 1 },
                changedItems = new[] { new { processName = "StaleApply", appliedControls = new[] {
                    new { control = "priorityClass", currentValue = "Normal", proposedValue = "AboveNormal", outcome = "applied" } } } },
                restoredItems = restored, leftAsSetItems = kept, skippedItems = retained ? skipped : [], latestLogs = Array.Empty<object>(), preview });
            var reopened = new PerformanceProfilesViewModel();
            await reopened.ReloadAsync();
            Capture("game-reopen-" + retained, App.Live.GameTuneStatusText, reopened);
            Verify(reopened.MatchTuneDetail.Contains("Target: CPU Idle (left as another program set it)", StringComparison.Ordinal)
                && reopened.MatchTuneDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal)
                && !reopened.MatchTuneDetail.Contains("StaleApply", StringComparison.Ordinal) && !reopened.MatchTuneDetail.Contains("BelowNormal", StringComparison.Ordinal),
                "Reopened game status renders persisted kept and restored controls only: " + retained);
            Verify(reopened.MatchTuneRestoreAvailable == retained && (!retained || reopened.MatchTuneDetail.Contains(reason, StringComparison.Ordinal)),
                "Reopened game status retains exact recovery and per-control failure: " + retained);
            await reopened.ReloadAsync();
            Verify(reopened.MatchTuneDetail.Contains("CPU Idle (left as another program set it)", StringComparison.Ordinal),
                "Repeated public Reload keeps the certified external value: " + retained);
        }
        App.Live.GameTuneStatusText = JsonSerializer.Serialize(new { actionId = "performance.gameTune.sessionStatus", dryRun = false, status = "completed",
            sessionId = "summary-session", profileId = "summary-game", sessionPath, backupManifestPath = sessionBackup, restorable = false,
            summary = new { changedItemCount = 0, restoredItemCount = 0, skippedItemCount = 0, pollCount = 0 },
            leftAsSetItems = kept, restoredItems = Array.Empty<object>(), latestLogs = Array.Empty<object>() });
        var keptOnly = new PerformanceProfilesViewModel();
        await keptOnly.ReloadAsync();
        Capture("game-reopen-kept-only", App.Live.GameTuneStatusText, keptOnly);
        Verify(keptOnly.MatchTuneDetail.Contains("Target: CPU Idle (left as another program set it)", StringComparison.Ordinal) && !keptOnly.MatchTuneRestoreAvailable,
            "Kept-only legacy session status names its persisted result without logs or counts");
        foreach (var phase in new[] { "before", "after", "legacy", "legacy-finished" })
        foreach (var status in phase switch { "before" => new[] { "active", "restorable", "failed" }, "after" => new[] { "completed", "failed", "partial" },
            "legacy" => new[] { "active", "restorable" }, _ => new[] { "completed", "failed" } })
        foreach (var variant in phase switch { "before" => new[] { "empty", "missing", "null", "scalar" }, "legacy" => new[] { "empty", "kept" }, _ => new[] { "empty" } })
        {
            var retained = status != "completed";
            File.WriteAllText(sessionPath, JsonSerializer.Serialize(new { sessionId = "summary-session", profileId = "summary-game", dryRun = false,
                restorable = retained, backupManifestPath = sessionBackup }));
            var showApplied = phase == "before" && status != "failed" || phase == "legacy" && variant != "kept";
            var showKept = variant == "kept" || phase == "after" && status != "completed";
            var receipt = new Dictionary<string, object?> { ["actionId"] = "performance.gameTune.sessionStatus", ["dryRun"] = false,
                ["status"] = status, ["sessionId"] = "summary-session", ["profileId"] = "summary-game", ["sessionPath"] = sessionPath,
                ["backupManifestPath"] = sessionBackup, ["restorable"] = retained, ["changedItems"] = applied,
                ["leftAsSetItems"] = showKept ? kept : Array.Empty<object>(), ["skippedItems"] = phase == "after" && retained ? skipped : Array.Empty<object>(),
                ["summary"] = new { changedItemCount = 1, restoredItemCount = 0, skippedItemCount = phase == "after" && retained ? 1 : 0, pollCount = 1 } };
            if (phase is "before" or "after") receipt["restoreAttempted"] = phase == "after";
            if (variant != "missing") receipt["restoredItems"] = variant switch { "null" => null, "scalar" => "unavailable", _ => Array.Empty<object>() };
            App.Live.GameTuneStatusText = JsonSerializer.Serialize(receipt);
            var reloaded = new PerformanceProfilesViewModel();
            await reloaded.ReloadAsync();
            Capture("game-status-phase-" + phase + "-" + status + "-" + variant, App.Live.GameTuneStatusText, reloaded);
            Verify(reloaded.MatchTuneDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal) == showApplied
                && !reloaded.MatchTuneDetail.Contains("Realtime", StringComparison.Ordinal)
                && (!showKept || reloaded.MatchTuneDetail.Contains("Target: CPU Idle (left as another program set it)", StringComparison.Ordinal))
                && (phase != "after" || !retained || reloaded.MatchTuneDetail.Contains(reason, StringComparison.Ordinal))
                && reloaded.MatchTuneRestoreAvailable == retained,
                "Public Reload distinguishes applied controls from completed Undo evidence: " + phase + "/" + status + "/" + variant);
        }
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_RESTORE_OPERATION_ARTIFACTS") is { Length: > 0 } operationArtifacts)
        {
            foreach (var receiptPath in new[] { "opus/status.json", "legacy-completed/status.json", "legacy-failed/status.json" })
            {
                App.Live.GameTuneStatusText = File.ReadAllText(Path.Combine(operationArtifacts, receiptPath));
                var reloaded = new PerformanceProfilesViewModel();
                await reloaded.ReloadAsync();
                Capture("game-raw-legacy-" + receiptPath, App.Live.GameTuneStatusText, reloaded);
                using var rawStatus = JsonDocument.Parse(App.Live.GameTuneStatusText);
                Verify(rawStatus.RootElement.GetProperty("restoreAttempted").ValueKind == JsonValueKind.False
                    && !reloaded.MatchTuneDetail.Contains("CPU Normal → AboveNormal", StringComparison.Ordinal)
                    && reloaded.MatchTuneDetail.Contains("skipped", StringComparison.Ordinal)
                    && reloaded.MatchTuneRestoreAvailable == rawStatus.RootElement.GetProperty("restorable").GetBoolean(),
                    "Public Reload hides stale apply from a real explicit-false legacy zero-write GetStatus: " + receiptPath);
            }
            App.Live.GovernorStatusText = File.ReadAllText(Path.Combine(operationArtifacts, "opus/gov-status.json"));
            var governorReloaded = new PerformanceProfilesViewModel();
            await governorReloaded.ReloadAsync();
            Capture("governor-raw-restored-status", App.Live.GovernorStatusText, governorReloaded);
            Verify(governorReloaded.GovernorDetail == "Finished: 1 changed, 1 restored, 0 skipped across 4 checks.",
                "Public Reload renders the real restored governor status as counts without stale apply detail");
        }
        foreach (var status in new[] { "completed", "failed", "partial", "unknown", "active", "restorable" })
        foreach (var flag in new[] { "false", "true", "null", "malformed", "missing" })
        {
            var retained = status != "completed";
            File.WriteAllText(sessionPath, JsonSerializer.Serialize(new { sessionId = "summary-session", profileId = "summary-game", dryRun = false,
                restorable = retained, backupManifestPath = sessionBackup }));
            var receipt = new Dictionary<string, object?> { ["actionId"] = "performance.gameTune.sessionStatus", ["dryRun"] = false,
                ["status"] = status, ["sessionId"] = "summary-session", ["profileId"] = "summary-game", ["sessionPath"] = sessionPath,
                ["backupManifestPath"] = sessionBackup, ["restorable"] = retained, ["changedItems"] = applied,
                ["restoredItems"] = Array.Empty<object>(), ["leftAsSetItems"] = Array.Empty<object>(), ["skippedItems"] = skipped,
                ["summary"] = new { changedItemCount = 1, restoredItemCount = 0, skippedItemCount = 1, pollCount = 1 } };
            if (flag != "missing") receipt["restoreAttempted"] = flag switch { "false" => false, "true" => true, "null" => null, _ => "false" };
            App.Live.GameTuneStatusText = JsonSerializer.Serialize(receipt);
            var reloaded = new PerformanceProfilesViewModel();
            await reloaded.ReloadAsync();
            Capture("game-status-final-phase-" + status + "-" + flag, App.Live.GameTuneStatusText, reloaded);
            var showApplied = status is "active" or "restorable" && flag is "false" or "missing";
            Verify(reloaded.MatchTuneDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal) == showApplied
                && reloaded.MatchTuneDetail.Contains(reason, StringComparison.Ordinal) && reloaded.MatchTuneRestoreAvailable == retained,
                "Public Reload limits historical apply details to active/restorable without known Undo: " + status + "/" + flag);
        }
        foreach (var governorState in new[] { "active", "restorable", "failed", "completed" })
        {
            App.Live.GovernorStatusText = JsonSerializer.Serialize(new { actionId = "performance.governor.sessionStatus", dryRun = false,
                status = governorState, restorable = false, changedItems = applied, restoredItems = restored,
                summary = new { changedItemCount = 1, restoredItemCount = 1, skippedItemCount = 0, pollCount = 2 } });
            var reloaded = new PerformanceProfilesViewModel();
            await reloaded.ReloadAsync();
            Capture("governor-status-counts-" + governorState, App.Live.GovernorStatusText, reloaded);
            Verify(reloaded.GovernorDetail.Contains("1 changed, 1 restored, 0 skipped across 2 checks.", StringComparison.Ordinal)
                && !reloaded.GovernorDetail.Contains("CPU", StringComparison.Ordinal),
                "Governor status keeps counts without historical control rows: " + governorState);
        }
        App.Live.GovernorResultError = App.Live.GovernorRestoreError = null;
        App.Live.GovernorText = JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = true, status = "preview", preview,
            result = new { summary = "Governor preview." } });
        var governorActions = new PerformanceProfilesViewModel();
        await governorActions.CheckGovernorCommand.ExecuteAsync(null);
        Capture("governor-action-preview", App.Live.GovernorText, governorActions);
        Verify(governorActions.GovernorDetail.Contains("Target: CPU BelowNormal (left as another program set it)", StringComparison.Ordinal),
            "Governor preview action retains its preview control rows");
        App.Live.GovernorText = JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false, status = "completed", restorable = false,
            result = new { summary = "Governor apply.", changedItems = applied } });
        await governorActions.StartGovernorCommand.ExecuteAsync(null);
        Capture("governor-action-apply", App.Live.GovernorText, governorActions);
        Verify(governorActions.GovernorDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal),
            "Governor confirmed action retains actual applied control rows");
        var governorSession = Path.Combine(fixtures, "governor-session.json");
        var governorBackup = Path.Combine(fixtures, "governor-backup.json");
        File.WriteAllText(governorBackup, JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false,
            sessionId = "summary-governor", profileId = "governor-profile", backupId = "governor-backup", snapshots = new[] { new { processId = 123 } } }));
        File.WriteAllText(governorSession, JsonSerializer.Serialize(new { sessionId = "summary-governor", profileId = "governor-profile",
            dryRun = false, restorable = true, backupManifestPath = governorBackup }));
        App.Live.GovernorText = JsonSerializer.Serialize(new { actionId = "performance.governor.startSession", dryRun = false, status = "restorable",
            sessionId = "summary-governor", profileId = "governor-profile", sessionPath = governorSession, backupManifestPath = governorBackup, restorable = true });
        await governorActions.StartGovernorCommand.ExecuteAsync(null);
        App.Live.GovernorRestoreText = JsonSerializer.Serialize(new { actionId = "performance.governor.stopSession", dryRun = false, status = "completed",
            sessionId = "summary-governor", sessionPath = governorSession, backupManifestPath = governorBackup, restorable = false,
            result = new { status = "rolledBack", summary = "Governor restored.", restoredItems = restored } });
        await governorActions.RestoreGovernorCommand.ExecuteAsync(null);
        Capture("governor-action-restore", App.Live.GovernorRestoreText, governorActions);
        Verify(governorActions.GovernorDetail.Contains("Peer: CPU AboveNormal → Normal", StringComparison.Ordinal) && !governorActions.GovernorRestoreAvailable,
            "Governor confirmed restore retains actual restored control rows and closes its exact recovery");
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_RESTORE_BACKEND_ARTIFACTS") is { Length: > 0 } backendArtifacts)
        {
        foreach (var afterUndo in new[] { false, true })
        {
            var scenario = "game-pending-BelowNormal-BelowNormal";
            App.Live.GameTuneStatusText = File.ReadAllText(Path.Combine(backendArtifacts, scenario, afterUndo ? "status-first.json" : "status-before.json"));
            var recordedSession = Path.Combine(backendArtifacts, scenario, "session.json");
            var afterRetry = File.ReadAllText(recordedSession);
            try
            {
                File.WriteAllText(recordedSession, File.ReadAllText(Path.Combine(backendArtifacts, scenario, afterUndo ? "session-first.json" : "session-before.json")));
                var reloaded = new PerformanceProfilesViewModel();
                await reloaded.ReloadAsync();
                Capture("game-real-status-phase-" + afterUndo, App.Live.GameTuneStatusText, reloaded);
                using var statusDocument = JsonDocument.Parse(App.Live.GameTuneStatusText);
                var phaseKnown = statusDocument.RootElement.TryGetProperty("restoreAttempted", out var attempted)
                    && attempted.ValueKind == (afterUndo ? JsonValueKind.True : JsonValueKind.False);
                Verify(phaseKnown && (afterUndo
                    ? !reloaded.MatchTuneRestoreAvailable && reloaded.MatchTuneDetail.Contains("Target: CPU BelowNormal (left as another program set it)", StringComparison.Ordinal)
                        && !reloaded.MatchTuneDetail.Contains("OldApply", StringComparison.Ordinal)
                    : reloaded.MatchTuneRestoreAvailable && reloaded.MatchTuneDetail.Contains("OldApply: CPU Normal → AboveNormal", StringComparison.Ordinal)),
                    "Public Reload consumes the actual GetStatus Undo phase without rewriting its envelope: " + afterUndo);
            }
            finally { File.WriteAllText(recordedSession, afterRetry); }
        }
        foreach (var partial in new[] { false, true })
        {
            var scenario = partial ? "game-applied-AboveNormal-AboveNormal-gpu" : "game-pending-BelowNormal-BelowNormal";
            App.Live.GameTuneStatusText = File.ReadAllText(Path.Combine(backendArtifacts, scenario, "status-first.json"));
            var recordedSession = Path.Combine(backendArtifacts, scenario, "session.json");
            var afterRetry = File.ReadAllText(recordedSession);
            try
            {
                File.WriteAllText(recordedSession, File.ReadAllText(Path.Combine(backendArtifacts, scenario, "session-first.json")));
                var reopened = new PerformanceProfilesViewModel();
                await reopened.ReloadAsync();
                Capture("game-real-backend-status-" + partial, App.Live.GameTuneStatusText, reopened);
                Verify(partial
                    ? reopened.MatchTuneRestoreAvailable && reopened.MatchTuneDetail.Contains("Target: CPU AboveNormal → Normal", StringComparison.Ordinal)
                        && reopened.MatchTuneDetail.Contains("GPU", StringComparison.Ordinal) && !reopened.MatchTuneDetail.Contains("GPU High → Normal", StringComparison.Ordinal)
                    : !reopened.MatchTuneRestoreAvailable && reopened.MatchTuneDetail.Contains("Target: CPU BelowNormal (left as another program set it)", StringComparison.Ordinal),
                    "Public Reload consumes the unmodified real backend status with simulated process I/O: " + partial);
            }
            finally { File.WriteAllText(recordedSession, afterRetry); }
        }
        }
    }
    finally
    {
        foreach (var entry in saved) entry.Property.SetValue(App.Live, entry.Value);
        Directory.Delete(fixtures, true);
        File.WriteAllText(Path.Combine(output, "receipts.json"), JsonSerializer.Serialize(observations, new JsonSerializerOptions { WriteIndented = true }));
    }
    if (failures.Count > 0) throw new InvalidOperationException(string.Join("\n", failures));
    if (args.Length > 0) { Console.WriteLine($"Completed {count} restore summary UI checks."); return; }
}

ControlRead Read<T>(T value) => ControlRead.From(value);
var error = new ApiError("fixture", "win32", 5, "read", "Controlled affinity read failure");
Dictionary<string, ControlRead> Controls(ControlRead cpuSets, ControlRead affinity) => new()
{
    ["cpuPriority"] = Read("Normal"),
    ["ioPriority"] = Read(2),
    ["gpuPriority"] = Read(2),
    ["memoryPriority"] = Read(5),
    ["executionQoS"] = Read(new PowerThrottling(0, 0)),
    ["priorityBoost"] = Read(true),
    ["cpuSets"] = cpuSets,
    ["affinity"] = affinity,
};
ProcessControlSnapshot Snapshot(ControlRead cpuSets, ControlRead affinity) => new(
    new RunningProcess(123, "1", @"C:\Fixture.exe"), Read(0xfffffffeu),
    [new LogicalCpu(103, 0, 0, 0, 0, 0, 0, false, false, false), new LogicalCpu(104, 0, 1, 1, 0, 0, 0, false, false, false)],
    Controls(cpuSets, affinity));
async Task ReadProcess(ProcessControlsViewModel model)
{
    var method = typeof(ProcessControlsViewModel).GetMethod("ReadProcessAsync", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException("ReadProcessAsync is missing.");
    await ((Task?)method.Invoke(model, [new CpuProcessChoice(123, "Fixture"), 0])
        ?? throw new InvalidOperationException("ReadProcessAsync did not return a task."));
}
InstalledApp AppItem(string id, string name) => new() { AppId = id, DisplayName = name, SourceType = "registry" };
OfficialUninstallPreview EmptyOfficial() => new() { DryRun = true, Commands = [] };
LeftoverScan EmptyScan(string id) => new() { AppId = id, DryRun = true, Items = [], Summary = new LeftoverScanSummary() };
CleanupManifest EmptyManifest(string id) => new() { AppId = id, DryRun = true, Items = [], Summary = new CleanupManifestSummary() };
UninstallCleanupExecutionPlan EmptyPlan(string id) => new()
{
    AppId = id,
    DryRun = true,
    Status = "review-ready",
    Summary = new UninstallExecutionSummary { ExecutionReady = true, DisposableFixtureExecutionReady = true },
};
void ReadyCleanup(UninstallCleanupViewModel model, InstalledApp app)
{
    model.SelectedApp = app;
    model.RemovalPathReviewed = true;
    model.LeftoverScanCompleted = true;
    model.CleanupPlanReady = true;
    model.RemoverPathApproved = true;
    model.CleanupListApproved = true;
}

if (args is ["governor-task", var taskRoot, var taskName, var registered, var enabled, var repeats, var installRoot])
{
    var task = RooIndustries.OptimizationSuite.Services.GovernorProbe.ReadTask(taskRoot, installRoot);
    Console.WriteLine("Read " + JsonSerializer.Serialize(task));
    Check(registered == "Unknown" ? task is null : task is not null && task.Name == taskName && task.Registered == bool.Parse(registered) && task.Enabled == bool.Parse(enabled) && task.RestartsEveryMinute == bool.Parse(repeats),
        "Real scheduled task " + taskName + " reads registered=" + registered + " enabled=" + enabled + " oneMinuteRepeat=" + repeats);
    return;
}

if (args is [] or ["governor"]) await GovernorChecks.RunAsync(Check);
if (args is ["governor"]) { Console.WriteLine($"Completed {count} governor status checks."); return; }

if (args is [] or ["process"])
{
    App.Operations.ProcessSnapshot = Snapshot(Read(Array.Empty<uint>()), ControlRead.Failed(error));
    var process = new ProcessControlsViewModel();
    await ReadProcess(process);
    Check(process.Status == "Controls for Fixture" && process.Controls.Count == 6 && process.Controls.All(row => row.Available),
        "A failed affinity read preserves neighboring process controls");
    Check(process.Detail.Contains("Hard affinity: unavailable", StringComparison.OrdinalIgnoreCase),
        "Process detail identifies only the failed affinity read as unavailable");
    process.Controls[0].Selected = process.Controls[0].Options[1];
    Check(process.CanPreview, "A readable process control remains reviewable beside a failed affinity read");
    process.Controls[0].Selected = process.Controls[0].Options[0];
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "all");
    Check(process.CanPreview, "A legitimate empty CPU-set read remains available for a new CPU selection");
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "unchanged");
    process.SetHardAffinity = true;
    Check(!process.CanPreview, "An unavailable affinity read cannot be requested for review");

    App.Operations.ProcessSnapshot = Snapshot(new ControlRead(true, null, null), Read(new AffinityState(0, "0x3")));
    process = new ProcessControlsViewModel();
    await ReadProcess(process);
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "all");
    Check(process.Status == "Controls for Fixture" && process.Detail.Contains("Preferred CPUs: unavailable", StringComparison.OrdinalIgnoreCase),
        "A missing CPU-set value preserves the readable affinity result");
    Check(!process.CanPreview, "An unavailable CPU-set read cannot be requested for review");

    var affinityValue = Read(new AffinityState(0, "0x3"));
    App.Operations.ProcessSnapshot = Snapshot(Read(Array.Empty<uint>()), new ControlRead(false, affinityValue.Value, null));
    process = new ProcessControlsViewModel();
    await ReadProcess(process);
    process.SetHardAffinity = true;
    Check(!process.CanPreview && process.Detail.Contains("Hard affinity: unavailable", StringComparison.OrdinalIgnoreCase),
        "Known false blocks affinity even when a value is present");

    var cpuSetValue = Read(Array.Empty<uint>());
    App.Operations.ProcessSnapshot = Snapshot(new ControlRead(true, cpuSetValue.Value, error), Read(new AffinityState(0, "0x3")));
    process = new ProcessControlsViewModel();
    await ReadProcess(process);
    process.SelectedCpuMode = process.CpuModes.Single(mode => mode.Kind == "all");
    Check(!process.CanPreview && process.Detail.Contains("Preferred CPUs: unavailable", StringComparison.OrdinalIgnoreCase),
        "An attached error blocks CPU selection even when known and value are favorable");
}

if (args is [] or ["startup"])
{
    App.Live.Classification = null;
    App.Live.LastError = "Controlled classification failure";
    var startup = new StartupServicesViewModel();
    await startup.InitializeAsync();
    Check(!startup.IsReady && startup.ErrorMessage == "Controlled classification failure",
        "A null process classification remains unavailable with the backend error");
    Check(typeof(StartupServicesViewModel).GetProperty("RetryCommand") is not null,
        "The unavailable startup state exposes a retry command");

    App.Live.Classification = new ProcessClassification { Processes = [] };
    App.Live.LastError = null;
    await startup.ReloadAsync();
    Check(startup.IsReady && startup.BackgroundCount == 0 && startup.LoadSummary == "No background processes reported.",
        "A successful empty classification is distinct from an unavailable read");

    App.Live.Classification = new ProcessClassification
    {
        Processes =
        [
            new ProcessItem { Pid = 10, Name = "fixture-launcher", Category = "launcher", WorkingSetBytes = 1024 },
            new ProcessItem { Pid = 11, Name = "fixture-background", Category = "backgroundApp", WorkingSetBytes = 2048, Protected = true },
        ],
    };
    await startup.ReloadAsync();
    Check(startup.IsReady && startup.BackgroundCount == 2 && startup.LauncherCount == 1 && startup.ProtectedCount == 1 && startup.BackgroundRows.Count == 2,
        "A populated classification projects its independent startup counts");
}

if (args is [] or ["sessions"])
{
    async Task RefreshSessions(PerformanceProfilesViewModel model)
    {
        var method = typeof(PerformanceProfilesViewModel).GetMethod("RefreshSessionStatusesAsync", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("RefreshSessionStatusesAsync is missing.");
        await ((Task?)method.Invoke(model, null) ?? throw new InvalidOperationException("RefreshSessionStatusesAsync did not return a task."));
    }

    (string Root, string SessionPath, string BackupPath) SessionFiles(
        string kind,
        string sessionId,
        string profileId,
        bool restorable = true,
        string? backupSessionId = null)
    {
        var root = Path.Combine(Path.GetTempPath(), "app-sweep-session-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var sessionPath = Path.Combine(root, "session.json");
        var backupPath = Path.Combine(root, "backup.json");
        var actionId = kind == "gameTune" ? "performance.gameTune.startSession" : "performance.governor.startSession";
        File.WriteAllText(backupPath, JsonSerializer.Serialize(new
        {
            actionId,
            backupId = kind + "-backup",
            sessionId = backupSessionId ?? sessionId,
            profileId,
            dryRun = false,
            snapshots = new[] { new { processId = 10, processName = "fixture" } },
        }));
        File.WriteAllText(sessionPath, JsonSerializer.Serialize(new
        {
            sessionId,
            profileId,
            dryRun = false,
            restorable,
            backupManifestPath = backupPath,
        }));
        return (root, sessionPath, backupPath);
    }

    string SessionResponse(
        string kind,
        string action,
        string sessionId,
        string profileId,
        string? sessionPath,
        string? backupPath,
        bool dryRun,
        bool restorable,
        string status)
        => JsonSerializer.Serialize(new
        {
            actionId = "performance." + (kind == "gameTune" ? "gameTune" : "governor") + "." + action,
            dryRun,
            status,
            sessionStatus = status,
            sessionId,
            profileId,
            sessionPath,
            backupManifestPath = backupPath,
            restorable,
            summary = new { changedItemCount = 1 },
            changedItems = new[] { new { processId = 10 } },
        });

    var sessions = new PerformanceProfilesViewModel { HasGameRunning = true };
    App.Live.GameTuneText = JsonSerializer.Serialize(new
    {
        actionId = "performance.gameTune.startSession",
        dryRun = false,
        status = "completed",
    });
    await sessions.CheckMatchTuneCommand.ExecuteAsync(null);
    Check(sessions.MatchTuneStatus == "Game priority check not confirmed",
        "A non-dry response cannot be presented as a game priority check");
    App.Live.GameTuneText = JsonSerializer.Serialize(new
    {
        actionId = "performance.gameTune.startSession",
        dryRun = true,
        status = "preview",
    });
    App.Live.GameTuneResultError = "Preview script exited with an error";
    await sessions.CheckMatchTuneCommand.ExecuteAsync(null);
    Check(sessions.MatchTuneStatus == "Game priority check not confirmed" && sessions.MatchTuneDetail.Contains("Preview script exited with an error", StringComparison.Ordinal),
        "A game preview value paired with an operation error cannot claim completion");
    App.Live.GameTuneResultError = null;
    await sessions.CheckMatchTuneCommand.ExecuteAsync(null);
    Check(sessions.MatchTuneStatus == "Game priorities checked", "An identity-bound dry-run game preview is reported as checked");

    App.Live.GovernorText = JsonSerializer.Serialize(new
    {
        actionId = "performance.governor.startSession",
        dryRun = true,
        status = "preview",
    });
    App.Live.GovernorResultError = "Governor preview script exited with an error";
    await sessions.CheckGovernorCommand.ExecuteAsync(null);
    Check(sessions.GovernorStatus == "Background limit check not confirmed",
        "A governor preview value paired with an operation error cannot claim completion");
    App.Live.GovernorResultError = null;

    App.Live.GameTuneText = JsonSerializer.Serialize(new
    {
        actionId = "performance.gameTune.startSession",
        dryRun = false,
        status = "active",
        sessionStatus = "active",
        sessionId = "game-session-without-backup",
        restorable = false,
        summary = new { changedItemCount = 1 },
        changedItems = new[] { new { processId = 10 } },
    });
    await sessions.StartMatchTuneCommand.ExecuteAsync(null);
    Check(!sessions.MatchTuneRestoreAvailable,
        "An active game session with changed items but no restore evidence stays unavailable");

    var game = SessionFiles("gameTune", "game-session", "game-profile");
    var governor = SessionFiles("governor", "governor-session", "governor-profile");
    var wrongBackup = SessionFiles("gameTune", "wrong-response-session", "game-profile", backupSessionId: "different-session");
    try
    {
        App.Live.GameTuneText = SessionResponse("gameTune", "startSession", "game-session", "game-profile", game.SessionPath, game.BackupPath, true, true, "completed");
        await sessions.StartMatchTuneCommand.ExecuteAsync(null);
        Check(!sessions.MatchTuneRestoreAvailable, "A dry-run game session cannot expose restore even with favorable files");

        App.Live.GameTuneText = SessionResponse("gameTune", "startSession", "game-session", "game-profile", game.SessionPath, game.BackupPath, false, false, "active");
        await sessions.StartMatchTuneCommand.ExecuteAsync(null);
        Check(!sessions.MatchTuneRestoreAvailable, "Changed items and active status cannot override restorable false");

        App.Live.GameTuneText = SessionResponse("gameTune", "startSession", "game-session", "game-profile", game.SessionPath, null, false, true, "failed");
        await sessions.StartMatchTuneCommand.ExecuteAsync(null);
        Check(!sessions.MatchTuneRestoreAvailable, "Restorable true without an explicit backup path remains unavailable");

        App.Live.GameTuneText = SessionResponse("gameTune", "startSession", "wrong-response-session", "game-profile", wrongBackup.SessionPath, wrongBackup.BackupPath, false, true, "failed");
        await sessions.StartMatchTuneCommand.ExecuteAsync(null);
        Check(!sessions.MatchTuneRestoreAvailable, "A backup for a different session cannot enable game restore");

        App.Live.GameTuneText = SessionResponse("gameTune", "startSession", "game-session", "game-profile", game.SessionPath, game.BackupPath, false, true, "failed");
        App.Live.GameTuneResultError = "Session script reported a partial failure";
        await sessions.StartMatchTuneCommand.ExecuteAsync(null);
        Check(sessions.MatchTuneRestoreAvailable, "A failed game session retains restore when explicit current backup evidence is valid");

        App.Live.GameTuneText = null;
        App.Live.GameTuneResultError = null;
        App.Live.LastError = "Controlled replacement session failure";
        await sessions.StartMatchTuneCommand.ExecuteAsync(null);
        Check(sessions.MatchTuneRestoreAvailable,
            "A lost replacement-session response preserves the previously verified recovery artifact");

        App.Live.GameTuneRestoreText = null;
        App.Live.LastError = "Controlled game restore failure";
        await sessions.RestoreMatchTuneCommand.ExecuteAsync(null);
        Check(sessions.MatchTuneRestoreAvailable
                && sessions.MatchTuneStatus == "Game restore not confirmed"
                && App.Live.LastGameRestoreRequest == ("game-session", game.SessionPath, game.BackupPath),
            "A missing game restore response preserves and requests the exact verified session artifact");

        App.Live.GameTuneRestoreText = JsonSerializer.Serialize(new
        {
            actionId = "performance.gameTune.stopSession",
            sessionId = "game-session",
            sessionPath = game.SessionPath,
            backupManifestPath = game.BackupPath,
            dryRun = false,
            status = "completed",
            result = new { status = "rolledBack", restoredItems = new[] { new { processId = 10 } } },
        });
        App.Live.LastError = null;
        App.Live.GameTuneRestoreError = "Restore script exited with an error";
        await sessions.RestoreMatchTuneCommand.ExecuteAsync(null);
        Check(sessions.MatchTuneRestoreAvailable && sessions.MatchTuneStatus == "Game restore needs attention",
            "A restore response paired with an operation error cannot clear the current artifact");
        App.Live.GameTuneRestoreError = null;
        await sessions.RestoreMatchTuneCommand.ExecuteAsync(null);
        Check(!sessions.MatchTuneRestoreAvailable && sessions.MatchTuneStatus == "Game priorities restored",
            "An identity-bound confirmed game restore clears only its current artifact");

        App.Live.GovernorText = SessionResponse("governor", "startSession", "governor-session", "governor-profile", governor.SessionPath, governor.BackupPath, false, false, "active");
        await sessions.StartGovernorCommand.ExecuteAsync(null);
        Check(!sessions.GovernorRestoreAvailable, "An active governor session alone cannot enable restore");

        App.Live.GovernorText = SessionResponse("governor", "startSession", "governor-session", "governor-profile", governor.SessionPath, governor.BackupPath, false, true, "active");
        await sessions.StartGovernorCommand.ExecuteAsync(null);
        Check(sessions.GovernorRestoreAvailable, "An active governor session with explicit verified recovery evidence can restore");

        App.Live.GovernorRestoreText = null;
        App.Live.LastError = "Controlled governor restore failure";
        await sessions.RestoreGovernorCommand.ExecuteAsync(null);
        Check(sessions.GovernorRestoreAvailable
                && App.Live.LastGovernorRestoreRequest == ("governor-session", governor.SessionPath, governor.BackupPath),
            "A missing governor restore response preserves and requests its exact verified artifact");

        App.Live.GameTuneStatusText = SessionResponse("gameTune", "sessionStatus", "game-session", "game-profile", game.SessionPath, game.BackupPath, false, true, "failed");
        App.Live.GovernorStatusText = SessionResponse("governor", "sessionStatus", "governor-session", "governor-profile", governor.SessionPath, governor.BackupPath, false, true, "restorable");
        var loaded = new PerformanceProfilesViewModel();
        await RefreshSessions(loaded);
        Check(loaded.MatchTuneRestoreAvailable && loaded.GovernorRestoreAvailable,
            "Loaded session status restores availability from each exact verified artifact");

        App.Live.GameTuneStatusError = "Controlled game status failure";
        App.Live.LastError = "Controlled game status failure";
        await RefreshSessions(loaded);
        Check(loaded.MatchTuneRestoreAvailable && loaded.MatchTuneStatus == "Game priorities unavailable"
                && loaded.MatchTuneDetail.Contains("Controlled game status failure", StringComparison.Ordinal),
            "A failed status query preserves previously verified recovery and surfaces its operation error");

        App.Live.GameTuneStatusText = null;
        App.Live.GameTuneStatusError = null;
        App.Live.GovernorStatusText = null;
        App.Live.LastError = "Controlled fresh status failure";
        var fresh = new PerformanceProfilesViewModel();
        await RefreshSessions(fresh);
        Check(!fresh.MatchTuneRestoreAvailable && !fresh.GovernorRestoreAvailable,
            "A fresh missing status query cannot invent session recovery");
    }
    finally
    {
        Directory.Delete(game.Root, true);
        Directory.Delete(governor.Root, true);
        Directory.Delete(wrongBackup.Root, true);
    }
}

if (args is [] or ["history"])
{
    var changed = new SessionChangedItem
    {
        ProcessId = 10,
        ProcessName = "fixture-game",
        OriginalPriorityClass = "Normal",
        AppliedPriorityClass = "AboveNormal",
        RestoredPriorityClass = "Normal",
    };
    App.Live.GameStatusModel = new GameTuneSessionStatus
    {
        DryRun = true,
        Status = "preview",
        ChangedItems = [changed],
        RestoredItems = [changed],
    };
    App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus
    {
        DryRun = true,
        Status = "preview",
        ActiveRestraints = [new ActiveRestraint { ProcessId = 11, ProcessName = "fixture-background", RuleId = "fixture" }],
    };
    var history = new RestoreLogsViewModel();
    await history.InitializeAsync();
    Check(!history.HasHistory && history.HistoryRows.Count == 0,
        "Dry-run changed, restored, and restraint arrays do not become applied history");

    App.Live.GameStatusModel = new GameTuneSessionStatus
    {
        Status = "active",
        Restorable = true,
        ChangedItems = [changed],
        RestoredItems = [changed],
    };
    App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus
    {
        Status = "active",
        Restorable = true,
        ActiveRestraints = [new ActiveRestraint { ProcessId = 11, ProcessName = "fixture-background", RuleId = "fixture" }],
    };
    history = new RestoreLogsViewModel();
    await history.InitializeAsync();
    Check(!history.HasHistory && history.RestoreRows.Take(2).All(row => row.Value == "Status unavailable"),
        "Missing dry-run flags keep populated session history and recovery status unknown");

    App.Live.GameStatusModel.DryRun = false;
    App.Live.GameStatusModel.Status = "completed";
    App.Live.GovernorStatusModel.DryRun = false;
    App.Live.GovernorStatusModel.Status = "active";
    history = new RestoreLogsViewModel();
    await history.InitializeAsync();
    Check(history.HistoryRows.Select(row => row.Action).SequenceEqual(new[] { "Applied", "Restored", "Restrained" }),
        "Confirmed non-dry session evidence retains applied, restored, and restraint history");

    App.Live.GameStatusModel.DryRun = true;
    history = new RestoreLogsViewModel();
    await history.InitializeAsync();
    Check(history.HistoryRows.Count == 1 && history.HistoryRows.Single().Action == "Restrained",
        "Dry-run filtering is independent for game and governor session history");

    App.Live.GameStatusModel = new GameTuneSessionStatus { Status = "notFound", Restorable = false };
    App.Live.GovernorStatusModel = new ProcessGovernorSessionStatus { Status = "notFound", Restorable = false };
    history = new RestoreLogsViewModel();
    await history.InitializeAsync();
    Check(history.RestoreRows.Take(2).Select(row => row.Value).SequenceEqual(new[] { "No session backup recorded", "No restraint backup recorded" }),
        "A PC that never ran a session shows no backup instead of unavailable recovery status");
}

if (args is [] or ["responses"] or ["cleanup"] or ["race"])
{
    if (args is not (["cleanup"] or ["race"]))
    {
    var oldBackup = Path.Combine(Path.GetTempPath(), "old-process-backup.json");
    File.WriteAllText(oldBackup, "{}");
    App.Live.LatestProcessBackup = oldBackup;
    App.Live.ProcessPreviewText = null;
    App.Live.LastError = "Controlled process preview failure";
    var profiles = new PerformanceProfilesViewModel();
    await profiles.PreviewPlanCommand.ExecuteAsync(null);
    Check(profiles.ActionTitle == "Plan not confirmed" && profiles.ActionDetail.Contains("Controlled process preview failure", StringComparison.Ordinal),
        "A missing process preview response cannot claim a ready plan");
    App.Live.ProcessPreviewText = JsonSerializer.Serialize(new { actionId = "performance.previewProfile", status = "preview", preview = Array.Empty<object>() });
    App.Live.LastError = null;
    await profiles.PreviewPlanCommand.ExecuteAsync(null);
    Check(profiles.ActionTitle == "Plan not confirmed", "A process preview without explicit dry-run evidence remains unknown");
    App.Live.ProcessPreviewText = JsonSerializer.Serialize(new { actionId = "performance.previewProfile", dryRun = true, status = "preview", preview = Array.Empty<object>() });
    await profiles.PreviewPlanCommand.ExecuteAsync(null);
    Check(profiles.ActionTitle == "Plan ready", "An identity-bound dry-run process preview is accepted");

    App.Live.ProcessApplyText = null;
    App.Live.LastError = "Controlled process apply failure";
    await profiles.ApplyProfileCommand.ExecuteAsync(null);
    Check(!profiles.RestoreAvailable && profiles.ActionTitle == "Process priorities not confirmed" && profiles.ActionDetail.Contains("Controlled process apply failure", StringComparison.Ordinal),
        "A missing process apply response cannot claim success or bind an unrelated backup");

    App.Live.ProcessApplyText = JsonSerializer.Serialize(new
    {
        actionId = "performance.applyProfile",
        dryRun = false,
        status = "success",
        backup = (object?)null,
        result = new { status = "success", summary = "No changes were needed.", changedItems = Array.Empty<object>() },
    });
    App.Live.LastError = null;
    await profiles.ApplyProfileCommand.ExecuteAsync(null);
    Check(!profiles.RestoreAvailable && profiles.ActionTitle == "Process priorities unchanged",
        "A valid no-op process apply remains successful without inventing restore evidence");

    App.Live.OperationError = "Controlled command exit failure";
    await profiles.ApplyProfileCommand.ExecuteAsync(null);
    Check(profiles.ActionTitle == "Process priorities not confirmed", "Successful-looking process output cannot override a command failure");
    App.Live.OperationError = null;
    App.Live.ProcessApplyText = JsonSerializer.Serialize(new { actionId = "performance.applyProfile", dryRun = false, status = "success" });
    await profiles.ApplyProfileCommand.ExecuteAsync(null);
    Check(profiles.ActionTitle == "Process priorities not confirmed", "Missing changed-item evidence cannot become a successful no-op");

    App.Live.ProcessApplyText = JsonSerializer.Serialize(new
    {
        actionId = "performance.applyProfile",
        status = "success",
        result = new { changedItems = Array.Empty<object>() },
    });
    await profiles.ApplyProfileCommand.ExecuteAsync(null);
    Check(!profiles.RestoreAvailable && profiles.ActionTitle == "Process priorities not confirmed",
        "A process apply without explicit dry-run evidence remains unknown");

    App.Live.ProcessApplyText = JsonSerializer.Serialize(new
    {
        actionId = "performance.applyProfile",
        dryRun = true,
        status = "success",
        result = new { changedItems = new[] { new { name = "fixture" } } },
    });
    await profiles.ApplyProfileCommand.ExecuteAsync(null);
    Check(!profiles.RestoreAvailable && profiles.ActionTitle == "Process priorities not confirmed",
        "A dry-run process response cannot claim a real apply");

    var currentBackup = Path.Combine(Path.GetTempPath(), "current-process-backup-" + Guid.NewGuid().ToString("N") + ".json");
    File.WriteAllText(currentBackup, JsonSerializer.Serialize(new { actionId = "performance.applyProfile", backupId = "current", profileId = "fixture-profile", dryRun = false, snapshots = new[] { new { processId = 123, processStartTimeUtc = "2026-09-20T00:00:00Z" } } }));
    try
    {
        App.Live.ProcessApplyText = JsonSerializer.Serialize(new
        {
            actionId = "performance.applyProfile",
            dryRun = false,
            status = "success",
            backup = new { backupId = "current", location = currentBackup, rollbackSupported = true },
            result = new { status = "success", summary = "One change applied.", changedItems = new[] { new { name = "fixture" } } },
        });
        await profiles.ApplyProfileCommand.ExecuteAsync(null);
        Check(profiles.RestoreAvailable && profiles.ActionTitle == "Process priorities applied",
            "A process apply enables restore only from its explicit current backup");
        App.Live.Classification = new ProcessClassification { Processes = [new ProcessItem { Name = "Fixture", Category = "backgroundApp" }] };
        var reopenedProfiles = new PerformanceProfilesViewModel();
        await reopenedProfiles.ReloadAsync();
        Check(reopenedProfiles.RestoreAvailable, "Reopening process profiles preserves the operation-bound recovery artifact");
        var validBackup = File.ReadAllText(currentBackup);
        File.WriteAllText(currentBackup, "{}");
        var invalidBackupModel = new PerformanceProfilesViewModel();
        await invalidBackupModel.ApplyProfileCommand.ExecuteAsync(null);
        Check(!invalidBackupModel.RestoreAvailable, "An empty file cannot serve as a process recovery artifact");
        File.WriteAllText(currentBackup, validBackup.Replace("current", "unrelated", StringComparison.Ordinal));
        await invalidBackupModel.ApplyProfileCommand.ExecuteAsync(null);
        Check(!invalidBackupModel.RestoreAvailable, "An unrelated process backup ID cannot enable restore");
        File.WriteAllText(currentBackup, validBackup);
        App.Live.ProcessRestoreText = JsonSerializer.Serialize(new { actionId = "performance.rollbackProfile", dryRun = false, status = "success", backup = new { location = oldBackup, backupId = "other" }, result = new { status = "success", changedItems = Array.Empty<object>() } });
        await profiles.RestoreProfileCommand.ExecuteAsync(null);
        Check(profiles.RestoreAvailable && profiles.ActionTitle != "Restore complete", "A restore receipt for another artifact cannot clear recovery");
        App.Live.ProcessRestoreText = null;
        App.Live.LastError = "Controlled process restore failure";
        await profiles.RestoreProfileCommand.ExecuteAsync(null);
        Check(profiles.RestoreAvailable && profiles.ActionTitle == "Restore not confirmed" && App.Live.LastProcessRestorePath == currentBackup,
            "A missing restore response preserves the exact current backup without claiming completion");
    }
    finally { File.Delete(currentBackup); }
    File.Delete(oldBackup);

    App.Live.LastError = "Controlled NVIDIA response failure";
    var drivers = new DriversProfilesViewModel { HasNvidia = true, HasNvidiaProfiles = true };
    await drivers.CheckNvidiaToolCommand.ExecuteAsync(null);
    Check(drivers.NvidiaActionTitle == "Tool check not confirmed" && drivers.NvidiaActionDetail.Contains("Controlled NVIDIA response failure", StringComparison.Ordinal),
        "A missing NVIDIA probe response cannot claim the tool check finished");
    await drivers.PreviewNvidiaProfileCommand.ExecuteAsync(null);
    Check(drivers.NvidiaActionTitle == "Profile plan not confirmed",
        "A missing NVIDIA preview response cannot claim a ready plan");
    drivers.NvidiaExportReviewed = true;
    drivers.NvidiaProfileApproved = true;
    drivers.NvidiaBenchmarkReady = true;
    await drivers.ApplyNvidiaProfileCommand.ExecuteAsync(null);
    Check(drivers.NvidiaActionTitle == "Apply not confirmed" && !drivers.CanRestoreNvidiaProfile,
        "A missing NVIDIA apply response cannot claim completion or invent restore evidence");
    await drivers.RestoreNvidiaProfileCommand.ExecuteAsync(null);
    Check(App.Live.LastNvidiaRestoreRecovery is null,
        "NVIDIA restore cannot dispatch before an exact apply artifact is retained");

    var nvidiaRoot = Path.Combine(Path.GetTempPath(), "nvidia-recovery-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(nvidiaRoot);
    var nvidiaManifest = Path.Combine(nvidiaRoot, "rollback.json");
    var nvidiaExport = Path.Combine(nvidiaRoot, "before.nip");
    File.WriteAllText(nvidiaManifest, "{}");
    File.WriteAllText(nvidiaExport, "fixture export");
    try
    {
        var recovery = new RooIndustries.OptimizationSuite.Services.NvidiaProfileRecovery("framesync", nvidiaManifest, nvidiaExport);
        App.Live.NvidiaRecovery = recovery;
        App.Live.NvidiaApplyText = JsonSerializer.Serialize(new
        {
            actionId = "drivers.nvidiaNip.executor",
            operation = "Apply",
            profileId = "framesync",
            dryRun = false,
            status = "failed",
            summary = new { exportCompleted = true, importAttempted = true, importCompleted = false },
        });
        App.Live.NvidiaApplyError = "Controlled NVIDIA import failure";
        await drivers.ApplyNvidiaProfileCommand.ExecuteAsync(null);
        Check(drivers.NvidiaActionTitle == "Apply not confirmed" && drivers.CanRestoreNvidiaProfile,
            "A failed NVIDIA import retains its exact verified pre-import export without claiming apply success");

        App.Live.NvidiaRestoreText = null;
        App.Live.NvidiaRestoreError = null;
        App.Live.LastError = "Controlled NVIDIA restore failure";
        await drivers.RestoreNvidiaProfileCommand.ExecuteAsync(null);
        Check(drivers.NvidiaActionTitle == "Restore not confirmed" && drivers.CanRestoreNvidiaProfile
                && App.Live.LastNvidiaRestoreRecovery == recovery,
            "A missing NVIDIA restore response preserves and requests the exact retained artifact");

        App.Live.NvidiaRestoreText = JsonSerializer.Serialize(new
        {
            actionId = "drivers.nvidiaNip.executor",
            operation = "Restore",
            profileId = "framesync",
            dryRun = false,
            status = "success",
            rollbackManifestPath = nvidiaManifest,
            gates = new[] { new { gateId = "contradiction", blocking = true } },
            errors = Array.Empty<object>(),
            summary = new { blockingGateCount = 1, exportAttempted = false, importAttempted = true, importCompleted = true },
        });
        await drivers.RestoreNvidiaProfileCommand.ExecuteAsync(null);
        Check(drivers.NvidiaActionTitle == "Restore not confirmed" && drivers.CanRestoreNvidiaProfile,
            "A nominal NVIDIA restore success with a blocking gate cannot clear recovery");

        App.Live.NvidiaRestoreText = JsonSerializer.Serialize(new
        {
            actionId = "drivers.nvidiaNip.executor",
            operation = "Restore",
            profileId = "framesync",
            dryRun = false,
            status = "success",
            rollbackManifestPath = nvidiaManifest,
            gates = Array.Empty<object>(),
            errors = Array.Empty<object>(),
            summary = new { blockingGateCount = 0, exportAttempted = false, importAttempted = true, importCompleted = true },
        });
        App.Live.ClearNvidiaRecoveryOnRestore = true;
        App.Live.LastError = null;
        await drivers.RestoreNvidiaProfileCommand.ExecuteAsync(null);
        Check(drivers.NvidiaActionTitle == "Profile restored" && !drivers.CanRestoreNvidiaProfile,
            "A confirmed identity-bound NVIDIA restore clears the retained artifact");
    }
    finally { Directory.Delete(nvidiaRoot, true); }

    App.Live.LastError = "Controlled stutter response failure";
    var monitoring = new MonitoringViewModel();
    await monitoring.CheckStutterPlanCommand.ExecuteAsync(null);
    Check(monitoring.StutterActionTitle == "Settings review not confirmed" && monitoring.StutterActionDetail.Contains("Controlled stutter response failure", StringComparison.Ordinal),
        "A missing timer and cache preview cannot claim settings were reviewed");
    monitoring.LatencySessionApproved = true;
    await monitoring.RunTimerSessionCommand.ExecuteAsync(null);
    Check(monitoring.StutterActionTitle == "Latency session not confirmed",
        "A missing timer response cannot claim the latency session finished");
    monitoring.ShaderCacheApproved = true;
    await monitoring.PrepareShaderCacheCommand.ExecuteAsync(null);
    Check(monitoring.StutterActionTitle == "Cache cleanup not confirmed" && !monitoring.ShaderRestoreAvailable,
        "A missing cache response cannot claim a cleanup check or create restore evidence");

    App.Live.OperationError = "Controlled command exit failure";
    App.Live.NvidiaProbeText = "{}";
    await drivers.CheckNvidiaToolCommand.ExecuteAsync(null);
    Check(drivers.NvidiaActionTitle == "Tool check not confirmed", "NVIDIA output cannot override a command failure");
    App.Live.TimerText = "{}";
    await monitoring.RunTimerSessionCommand.ExecuteAsync(null);
    Check(monitoring.StutterActionTitle == "Latency session not confirmed", "Timer output cannot override a command failure");
    App.Live.ShaderText = "{}";
    await monitoring.PrepareShaderCacheCommand.ExecuteAsync(null);
    Check(monitoring.StutterActionTitle == "Cache cleanup not confirmed", "Cache output cannot override a command failure");
    App.Live.OperationError = null;

    var shaderRollback = Path.Combine(Path.GetTempPath(), "shader-rollback-" + Guid.NewGuid().ToString("N") + ".json");
    var shaderBackup = shaderRollback + ".cache";
    File.WriteAllText(shaderBackup, "fixture cache bytes");
    var validShaderBackup = JsonSerializer.Serialize(new { manifestId = "shader-fixture", actionId = "performance.stutterOptimization.restoreShaderCacheFixture", optimizationId = "shader-cache-cleanup", restoreSupported = true, fileBackups = new[] { new { source = shaderRollback + ".original", backupPath = shaderBackup } } });
    File.WriteAllText(shaderRollback, validShaderBackup);
    try
    {
        App.Live.LastError = null;
        App.Live.ShaderText = JsonSerializer.Serialize(new
        {
            actionId = "performance.stutterOptimization.realExecutor",
            optimizationId = "shader-cache-cleanup",
            status = "success",
            rollback = new { rollbackManifestPath = shaderRollback },
        });
        File.WriteAllText(shaderRollback, "{}");
        await monitoring.PrepareShaderCacheCommand.ExecuteAsync(null);
        Check(!monitoring.ShaderRestoreAvailable, "An empty shader rollback file cannot enable restore");
        File.WriteAllText(shaderRollback, validShaderBackup);
        await monitoring.PrepareShaderCacheCommand.ExecuteAsync(null);
        Check(monitoring.ShaderRestoreAvailable, "An explicit current shader rollback enables restore");
        App.Live.ShaderRestoreText = null;
        App.Live.LastError = "Controlled shader restore failure";
        await monitoring.RestoreShaderCacheCommand.ExecuteAsync(null);
        Check(monitoring.ShaderRestoreAvailable && monitoring.StutterActionTitle == "Cache restore not confirmed",
            "A missing shader restore response preserves the current rollback without claiming completion");
    }
    finally { File.Delete(shaderRollback); File.Delete(shaderBackup); }
    }

    var appA = AppItem("app-a", "App A");
    var appB = AppItem("app-b", "App B");
    var cleanup = new UninstallCleanupViewModel { SelectedApp = appA };
    if (args is not ["race"])
    {
    App.Live.LastError = "Controlled route failure";
    App.Live.OfficialPreview = _ => Task.FromResult<OfficialUninstallPreview?>(null);
    await cleanup.PreviewRemovalCommand.ExecuteAsync(null);
    Check(!cleanup.RemovalPathReviewed && cleanup.OfficialPreviewState.Contains("Controlled route failure", StringComparison.Ordinal),
        "A null removal-route response remains unavailable with its operation error");

    const string reviewedLine = "\"C:\\Windows\\system32\\msiexec.exe\" /x {11111111-2222-3333-4444-555555555555} /norestart";
    App.Live.OfficialPreview = id => Task.FromResult<OfficialUninstallPreview?>(new OfficialUninstallPreview
    {
        DryRun = true,
        Commands = [new UninstallCommand { AppId = id, CommandType = "msi-uninstall-string", RawCommand = "MsiExec.exe /X{11111111-2222-3333-4444-555555555555}", CommandLine = reviewedLine, ExecutableSha256 = new string('a', 64) }],
    });
    await cleanup.PreviewRemovalCommand.ExecuteAsync(null);
    Check(cleanup.RemovalPathReviewed && cleanup.OfficialCommand == reviewedLine, "The removal review shows the exact command that runs, not the published uninstall string");
    async Task CheckRoute(UninstallCommand command)
    {
        App.Live.OfficialPreview = _ => Task.FromResult<OfficialUninstallPreview?>(new OfficialUninstallPreview { DryRun = true, Commands = [command] });
        cleanup.SelectedApp = appB;
        cleanup.SelectedApp = appA;
        command.AppId = appA.AppId;
        await cleanup.PreviewRemovalCommand.ExecuteAsync(null);
    }
    bool RouteBlocked() => !cleanup.RemovalPathReviewed && !cleanup.CanReviewRemovalAction && cleanup.PrimaryRemovalButtonLabel == "Use Remove apps"
        && cleanup.ApplyApprovalSummary == "Can't run this app's remover. Use Remove apps to remove it.";
    const string goneLine = "\"C:\\Program Files\\Gone\\uninstall.exe\" /S";
    await CheckRoute(new UninstallCommand { CommandType = "registry-uninstall-string", RawCommand = goneLine, CommandLine = goneLine, ExecutableSha256 = null, ExecutableState = "missing" });
    Check(RouteBlocked() && cleanup.OfficialPreviewState.Contains("remover file is missing", StringComparison.Ordinal), "A remover whose file is missing is blocked and says the file is missing");
    var routeCalls = 0;
    App.Live.OfficialPreview = _ => { routeCalls++; return Task.FromResult<OfficialUninstallPreview?>(EmptyOfficial()); };
    await cleanup.PreviewRemovalCommand.ExecuteAsync(null);
    Check(routeCalls == 0 && RouteBlocked(), "A blocked route cannot be re-run from the same button");
    await CheckRoute(new UninstallCommand { CommandType = "registry-uninstall-string", RawCommand = goneLine, CommandLine = goneLine, ExecutableSha256 = null, ExecutableState = "unreadable" });
    Check(RouteBlocked() && cleanup.OfficialPreviewState.Contains("remover file can't be read", StringComparison.Ordinal), "A remover file that exists but can't be read says so instead of calling it missing");
    await CheckRoute(new UninstallCommand { CommandType = "registry-uninstall-string", RawCommand = "uninstall.exe /S", CommandLine = null });
    Check(RouteBlocked() && cleanup.OfficialPreviewState.Contains("doesn't point to one exact file", StringComparison.Ordinal), "A vendor remover that cannot be resolved to one file is blocked and says why");
    await CheckRoute(new UninstallCommand { CommandType = "appx-package-removal-preview", RawCommand = "Remove-AppxPackage -User 'S-1-5-21-1' -Package 'Vendor.App_1.0.0.0_x64__abc' -ErrorAction Stop", CommandLine = null });
    Check(RouteBlocked() && cleanup.OfficialPreviewState == "Use Remove apps to remove this app.", "A Store app in Leftover cleanup points to Remove apps instead of offering a removal that cannot run");
    cleanup.SelectedApp = appB;
    cleanup.SelectedApp = appA;
    Check(cleanup.CanReviewRemovalAction && !cleanup.RemovalRouteBlocked, "Picking the app again unlocks the route check");

    App.Live.OfficialPreview = _ => Task.FromResult<OfficialUninstallPreview?>(EmptyOfficial());
    await cleanup.PreviewRemovalCommand.ExecuteAsync(null);
    Check(cleanup.RemovalPathReviewed, "A successful empty removal route remains a valid Roo Industries route");
    App.Live.LastError = "Controlled leftover failure";
    App.Live.LeftoverScan = _ => Task.FromResult<LeftoverScan?>(null);
    await cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    Check(!cleanup.LeftoverScanCompleted && cleanup.LeftoverState.Contains("Controlled leftover failure", StringComparison.Ordinal),
        "A null leftover scan cannot become a successful empty scan");
    App.Live.LeftoverScan = id => Task.FromResult<LeftoverScan?>(EmptyScan(id));
    await cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    Check(cleanup.LeftoverScanCompleted && cleanup.Leftovers.Count == 0 && cleanup.LeftoverState.Contains("No leftover targets", StringComparison.Ordinal),
        "A successful empty leftover scan remains distinct from no response");
    App.Live.OperationError = "Controlled scan exit failure";
    await cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    Check(!cleanup.LeftoverScanCompleted, "Successful-looking empty scan cannot override a command failure");
    App.Live.OperationError = null;


    App.Live.LeftoverScan = id => Task.FromResult<LeftoverScan?>(new LeftoverScan
    {
        AppId = id,
        DryRun = true,
        Items = [new LeftoverItem { ItemId = "candidate", Type = "folder", Target = @"C:\Fixture" }],
        Summary = new LeftoverScanSummary { ItemCount = 1 },
        Errors = [new IssueModel { Message = "Non-blocking scan note", Blocking = false }],
    });
    await cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    Check(cleanup.LeftoverScanCompleted && cleanup.Leftovers.Single().ItemId == "candidate",
        "A populated partial scan with only non-blocking issues remains reviewable");

    App.Live.LeftoverScan = id => Task.FromResult<LeftoverScan?>(new LeftoverScan
    {
        AppId = id,
        DryRun = true,
        Items = [new LeftoverItem { ItemId = "untrusted", Type = "folder", Target = @"C:\Wrong" }],
        Summary = new LeftoverScanSummary { ItemCount = 1 },
        Errors = [new IssueModel { Message = "Controlled blocking scan error", Blocking = true }],
    });
    await cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    Check(!cleanup.LeftoverScanCompleted && cleanup.Leftovers.Count == 0 && cleanup.LeftoverState.Contains("Controlled blocking scan error", StringComparison.Ordinal),
        "A favorable scan payload cannot override its blocking error");

    App.Live.LeftoverScan = id => Task.FromResult<LeftoverScan?>(EmptyScan(id));
    await cleanup.ScanLeftoversCommand.ExecuteAsync(null);

    App.Live.LastError = "Controlled manifest failure";
    App.Live.CleanupManifest = _ => Task.FromResult<CleanupManifest?>(null);
    await cleanup.BuildCleanupListCommand.ExecuteAsync(null);
    Check(!cleanup.CleanupPlanReady && cleanup.CleanupPlanState.Contains("Controlled manifest failure", StringComparison.Ordinal),
        "A null cleanup manifest cannot unlock the cleanup plan");
    App.Live.CleanupManifest = id => Task.FromResult<CleanupManifest?>(new CleanupManifest
    {
        AppId = id,
        DryRun = true,
        Items = [],
        Summary = new CleanupManifestSummary(),
        Errors = [new IssueModel { Message = "Controlled blocking manifest error", Blocking = true }],
    });
    App.Live.LastError = null;
    await cleanup.BuildCleanupListCommand.ExecuteAsync(null);
    Check(!cleanup.CleanupPlanReady && cleanup.CleanupPlanState.Contains("Controlled blocking manifest error", StringComparison.Ordinal),
        "A favorable cleanup manifest cannot override its blocking error");
    App.Live.CleanupManifest = id => Task.FromResult<CleanupManifest?>(EmptyManifest(id));
    App.Live.LastError = "Controlled plan failure";
    App.Live.CleanupPlan = _ => Task.FromResult<UninstallCleanupExecutionPlan?>(null);
    await cleanup.BuildCleanupListCommand.ExecuteAsync(null);
    Check(!cleanup.CleanupPlanReady && cleanup.RemovalPlanDetail?.Contains("Controlled plan failure", StringComparison.Ordinal) == true,
        "A null execution plan cannot mark an empty manifest ready");
    App.Live.CleanupPlan = id => Task.FromResult<UninstallCleanupExecutionPlan?>(new UninstallCleanupExecutionPlan
    {
        AppId = id,
        DryRun = true,
        Status = "failed",
        Summary = new UninstallExecutionSummary { ExecutionReady = true },
    });
    App.Live.LastError = null;
    await cleanup.BuildCleanupListCommand.ExecuteAsync(null);
    Check(!cleanup.CleanupPlanReady, "A failed execution plan cannot unlock cleanup even with a favorable summary");
    App.Live.CleanupPlan = id => Task.FromResult<UninstallCleanupExecutionPlan?>(EmptyPlan(id));
    App.Live.LastError = null;
    await cleanup.BuildCleanupListCommand.ExecuteAsync(null);
    Check(cleanup.CleanupPlanReady, "A successful empty manifest and execution plan can complete review");
    cleanup.RemoverPathApproved = true;
    cleanup.CleanupListApproved = true;
    App.Live.CleanupApply = (_, _, _, _) => Task.FromResult<string?>(null);
    App.Live.LastError = "Controlled final check failure";
    await cleanup.RunFinalCheckCommand.ExecuteAsync(null);
    Check(!cleanup.FinalCheckPassed && cleanup.CleanupExecutionDetail?.Contains("Controlled final check failure", StringComparison.Ordinal) == true,
        "A missing final-check response remains unapproved with its operation error");
    App.Live.CleanupApply = (id, _, _, _) => Task.FromResult<string?>(JsonSerializer.Serialize(new
    {
        actionId = "apps.invokeUninstallCleanupApplyPackage",
        appId = id,
        dryRun = true,
        status = "preview",
        executionMode = "preview",
        gates = new[] { new { gateId = "confirm-apply", required = true, satisfied = false, blocking = true }, new { gateId = "review-inputs", required = true, satisfied = true, blocking = false } },
        errors = Array.Empty<object>(),
        summary = new { approvalReady = true, cleanupItemCount = 0, blockingGateCount = 1 },
    }));
    App.Live.LastError = null;
    await cleanup.RunFinalCheckCommand.ExecuteAsync(null);
    Check(cleanup.FinalCheckPassed, "An identity-bound dry-run final check can approve the reviewed cleanup");
    var validFinalResponse = App.Live.CleanupApply;
    App.Live.CleanupApply = async (id, a, b, c) => (await validFinalResponse(id, a, b, c))!.Replace("confirm-apply", "backup-path", StringComparison.Ordinal);
    await cleanup.RunFinalCheckCommand.ExecuteAsync(null);
    Check(!cleanup.FinalCheckPassed, "Favorable approval summary cannot override a blocking backup gate");
    App.Live.CleanupApply = async (id, a, b, c) => (await validFinalResponse(id, a, b, c))!.Replace("\"blockingGateCount\":1", "\"blockingGateCount\":0", StringComparison.Ordinal);
    await cleanup.RunFinalCheckCommand.ExecuteAsync(null);
    Check(!cleanup.FinalCheckPassed, "Conflicting gate totals cannot approve cleanup");
    App.Live.CleanupApply = validFinalResponse;

    }

    var routeA = new TaskCompletionSource<OfficialUninstallPreview?>(TaskCreationOptions.RunContinuationsAsynchronously);
    cleanup = new UninstallCleanupViewModel { SelectedApp = appA };
    App.Live.OfficialPreview = id => id == appA.AppId ? routeA.Task : Task.FromResult<OfficialUninstallPreview?>(EmptyOfficial());
    var oldRoute = cleanup.PreviewRemovalCommand.ExecuteAsync(null);
    cleanup.SelectedApp = appB;
    routeA.SetResult(new OfficialUninstallPreview
    {
        Commands = [new UninstallCommand { AppId = appA.AppId, RawCommand = "A.exe /remove", CommandType = "registry-uninstall-string" }],
    });
    await oldRoute;
    Check(cleanup.SelectedApp == appB && !cleanup.RemovalPathReviewed && !cleanup.ScanBusy && cleanup.OfficialCommand != "A.exe /remove",
        "A late removal-route result cannot attach to a newly selected app");

    var scanA1 = new TaskCompletionSource<LeftoverScan?>(TaskCreationOptions.RunContinuationsAsynchronously);
    var scanB = new TaskCompletionSource<LeftoverScan?>(TaskCreationOptions.RunContinuationsAsynchronously);
    var scanA2 = new TaskCompletionSource<LeftoverScan?>(TaskCreationOptions.RunContinuationsAsynchronously);
    var aCalls = 0;
    App.Live.LeftoverScan = id => id == appB.AppId ? scanB.Task : ++aCalls == 1 ? scanA1.Task : scanA2.Task;
    cleanup.SelectedApp = appA;
    var firstA = cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    cleanup.SelectedApp = appB;
    var currentB = cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    cleanup.SelectedApp = appA;
    var currentA = cleanup.ScanLeftoversCommand.ExecuteAsync(null);
    scanA1.SetResult(EmptyScan(appA.AppId!));
    await firstA;
    scanB.SetResult(EmptyScan(appB.AppId!));
    await currentB;
    Check(cleanup.ScanBusy, "Old A and B completions cannot clear the newer A busy state");
    scanA2.SetResult(new LeftoverScan
    {
        AppId = appA.AppId,
        DryRun = true,
        Items = [new LeftoverItem { ItemId = "current-a", Type = "folder", Target = @"C:\FixtureA" }],
        Summary = new LeftoverScanSummary { ItemCount = 1 },
    });
    await currentA;
    Check(!cleanup.ScanBusy && cleanup.SelectedApp == appA && cleanup.Leftovers.Single().ItemId == "current-a",
        "A to B to A scan epochs retain only the newest A response");

    var planA = new TaskCompletionSource<CleanupManifest?>(TaskCreationOptions.RunContinuationsAsynchronously);
    ReadyCleanup(cleanup, appA);
    App.Live.CleanupManifest = _ => planA.Task;
    var oldPlan = cleanup.BuildCleanupListCommand.ExecuteAsync(null);
    cleanup.SelectedApp = appB;
    planA.SetResult(EmptyManifest(appA.AppId!));
    await oldPlan;
    Check(!cleanup.CleanupPlanReady && cleanup.SelectedApp == appB, "A late cleanup-plan input cannot unlock another app");

    var finalA = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
    ReadyCleanup(cleanup, appA);
    App.Live.CleanupApply = (_, _, _, _) => finalA.Task;
    var oldFinal = cleanup.RunFinalCheckCommand.ExecuteAsync(null);
    cleanup.SelectedApp = appB;
    finalA.SetResult(JsonSerializer.Serialize(new { appId = appA.AppId, status = "preview", summary = new { approvalReady = true, cleanupItemCount = 0 } }));
    await oldFinal;
    Check(!cleanup.FinalCheckPassed && cleanup.SelectedApp == appB, "A late final-check response cannot approve another app");

    var rollbackRoot = Path.Combine(Path.GetTempPath(), "roo-industries-cleanup-rollback-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(rollbackRoot);
    var rollback = Path.Combine(rollbackRoot, "rollback-manifest.json");
    File.WriteAllText(rollback, JsonSerializer.Serialize(new
    {
        appId = appA.AppId,
        executionStarted = true,
        restoreSupported = true,
        fileBackups = new[] { new { itemId = "current-a", backupPath = @"C:\FixtureBackup" } },
    }));
    try
    {
        var applyA = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        ReadyCleanup(cleanup, appA);
        cleanup.FinalCheckPassed = true;
        cleanup.RealCleanupApproved = true;
        App.Live.CleanupApply = (_, _, _, _) => applyA.Task;
        var oldApply = cleanup.ApplyCleanupCommand.ExecuteAsync(null);
        cleanup.SelectedApp = appB;
        applyA.SetResult(JsonSerializer.Serialize(new
        {
            actionId = "apps.invokeUninstallCleanupApplyPackage",
            appId = appA.AppId,
            status = "partial",
            rollbackManifestPath = rollback,
            summary = new { deletedCount = 1, restoreReady = true },
        }));
        await oldApply;
        Check(!cleanup.CleanupRestoreAvailable && cleanup.SelectedApp == appB, "A late partial apply cannot expose A recovery on B");
        cleanup.SelectedApp = appA;
        Check(cleanup.CleanupRestoreAvailable, "A late partial apply preserves its exact recovery artifact for A");

        var restoreA = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        App.Live.CleanupRestore = _ => restoreA.Task;
        var oldRestore = cleanup.RestoreCleanupCommand.ExecuteAsync(null);
        cleanup.SelectedApp = appB;
        restoreA.SetResult(JsonSerializer.Serialize(new
        {
            actionId = "apps.restoreUninstallCleanupExecution",
            dryRun = false,
            status = "success",
            rollbackManifestPath = rollback,
            executionMode = "real-system-restore",
            gates = new[] { new { gateId = "backup-files-present", required = true, satisfied = true, blocking = false } },
            errors = Array.Empty<object>(),
            restoredItems = new[] { new { itemId = "current-a", restored = true } },
            summary = new { restoredCount = 1, blockingGateCount = 0 },
        }));
        await oldRestore;
        Check(cleanup.SelectedApp == appB && !cleanup.CleanupExecutionState.StartsWith("Restore complete", StringComparison.Ordinal),
            "A late restore response cannot report completion on another app");
        cleanup.SelectedApp = appA;
        Check(!cleanup.CleanupRestoreAvailable, "A completed stale restore clears only its initiating app recovery");

        var runsRoot = Path.Combine(Path.GetTempPath(), "roo-industries-cleanup-runs-" + Guid.NewGuid().ToString("N"));
        try
        {
            string SavedRun(string name, string appId, string? displayName = null)
            {
                var manifest = Path.Combine(runsRoot, name, "rollback-manifest.json");
                Directory.CreateDirectory(Path.GetDirectoryName(manifest)!);
                var backup = Path.Combine(runsRoot, name, "backup.bin");
                File.WriteAllText(backup, "fixture");
                File.WriteAllText(manifest, JsonSerializer.Serialize(new { appId, displayName, executionStarted = true, restoreSupported = true, fileBackups = new[] { new { itemId = "saved", backupPath = backup } } }));
                return manifest;
            }
            var savedA = SavedRun("run-a", appA.AppId!);
            File.SetLastWriteTimeUtc(savedA, DateTime.UtcNow.AddMinutes(-5));
            SavedRun("run-b", appB.AppId!);
            Directory.CreateDirectory(Path.Combine(runsRoot, "run-broken"));
            File.WriteAllText(Path.Combine(runsRoot, "run-broken", "rollback-manifest.json"), "{not json");
            Directory.CreateDirectory(Path.Combine(runsRoot, "run-noop"));
            File.WriteAllText(Path.Combine(runsRoot, "run-noop", "rollback-manifest.json"), JsonSerializer.Serialize(new { appId = appA.AppId, executionStarted = false, restoreSupported = true, fileBackups = Array.Empty<object>() }));
            App.Live.CleanupRunsRoot = runsRoot;
            var reopened = new UninstallCleanupViewModel { SelectedApp = appA };
            for (var wait = 0; wait < 100 && !reopened.CleanupRestoreAvailable; wait++) await Task.Delay(20);
            Check(reopened.CleanupRestoreAvailable && reopened.CanRestoreCleanup && reopened.CleanupExecutionState.StartsWith("An earlier cleanup", StringComparison.Ordinal),
                "A saved cleanup can still be restored after the app is closed and reopened, even when a newer run had nothing to restore");

            var scanGate = new TaskCompletionSource<LeftoverScan?>(TaskCreationOptions.RunContinuationsAsynchronously);
            var savedScan = App.Live.LeftoverScan;
            App.Live.LeftoverScan = _ => scanGate.Task;
            App.Live.CleanupRecoveryDelay = TimeSpan.FromMilliseconds(150);
            try
            {
                var busy = new UninstallCleanupViewModel { SelectedApp = appA };
                var scanning = busy.ScanLeftoversCommand.ExecuteAsync(null);
                await Task.Delay(400);
                scanGate.SetResult(EmptyScan(appA.AppId!));
                await scanning;
                Check(busy.CleanupRestoreAvailable && busy.CanRestoreCleanup, "A saved cleanup found while a leftover scan runs can be restored once the scan finishes");
            }
            finally { App.Live.CleanupRecoveryDelay = TimeSpan.Zero; App.Live.LeftoverScan = savedScan; }
            App.Live.CleanupRestore = path => Task.FromResult<string?>(JsonSerializer.Serialize(new
            {
                actionId = "apps.restoreUninstallCleanupExecution",
                dryRun = false,
                status = "success",
                rollbackManifestPath = path,
                executionMode = "real-system-restore",
                gates = new[] { new { gateId = "backup-files-present", required = true, satisfied = true, blocking = false } },
                errors = Array.Empty<object>(),
                restoredItems = new[] { new { itemId = "saved", restored = true } },
                summary = new { restoredCount = 1, blockingGateCount = 0 },
            }));
            await reopened.RestoreCleanupCommand.ExecuteAsync(null);
            var again = new UninstallCleanupViewModel { SelectedApp = appA };
            await Task.Delay(200);
            Check(File.Exists(Path.Combine(runsRoot, "run-a", "restored.json")) && !again.CleanupRestoreAvailable,
                "A restored cleanup is not offered again after reopening");
            var other = new UninstallCleanupViewModel { SelectedApp = appB };
            for (var wait = 0; wait < 100 && !other.CleanupRestoreAvailable; wait++) await Task.Delay(20);
            Check(other.CleanupRestoreAvailable, "Another app keeps its own saved cleanup restore");
            Directory.CreateDirectory(Path.Combine(runsRoot, "run-b", "restored.json"));
            await other.RestoreCleanupCommand.ExecuteAsync(null);
            Check(other.CleanupExecutionDetail?.Contains("couldn't save that this restore finished", StringComparison.Ordinal) == true,
                "A restore whose finished mark can't be saved says it may be offered again" + " | got: " + other.CleanupExecutionDetail);

            SavedRun("run-gone", "app-gone", "Gone App");
            var savedInventory = App.Live.InstalledApps;
            App.Live.InstalledApps = new InstalledAppInventory { Apps = [appA, appB] };
            try
            {
                var page = new UninstallCleanupViewModel();
                await page.InitializeAsync();
                var gone = page.Apps.FirstOrDefault(item => item.AppId == "app-gone");
                Check(gone is { Removed: true, FriendlyName: "Gone App", SecondaryLabel: "Removed. Its cleanup can be restored." } && page.Apps.Count(item => item.Removed) == 1,
                    "An app that cleanup removed stays in the list with its saved restore after reopening, and installed apps never show as removed");
                page.SelectedApp = gone;
                Check(page.CanRestoreCleanup && !page.CanReviewRemoval && !page.CanScan && page.ApplyApprovalSummary.StartsWith("This app is already removed", StringComparison.Ordinal),
                    "A removed app offers only Restore from its saved cleanup" + " | got: " + page.ApplyApprovalSummary);
                await page.RestoreCleanupCommand.ExecuteAsync(null);
                Check(page.CleanupExecutionState.StartsWith("Restore complete", StringComparison.Ordinal) && !page.CanRestoreCleanup,
                    "Restore works for an app that is no longer installed" + " | got: " + page.CleanupExecutionState);
                page.SelectedApp = null;
                await page.ReloadAsync();
                Check(page.Apps.All(item => item.AppId != "app-gone"), "A removed app leaves the list once its cleanup is restored");

                App.Live.InstalledApps = null;
                var unread = new UninstallCleanupViewModel();
                await unread.InitializeAsync();
                var savedB = unread.Apps.FirstOrDefault(item => item.AppId == appB.AppId);
                Check(unread.IsReady && unread.InventoryNotice.StartsWith("We couldn't read your installed apps", StringComparison.Ordinal) && unread.StaleNotice.Length == 0
                        && savedB is { Removed: true, RemovalUnconfirmed: true, SecondaryLabel: "Its saved cleanup can be restored." },
                    "A saved cleanup can still be restored when the installed apps list can't be read, and the page says the list is missing" + " | got: " + unread.ErrorMessage + " " + unread.InventoryNotice);
                unread.SelectedApp = savedB;
                var scanCalls = 0;
                var liveScan = App.Live.LeftoverScan;
                App.Live.LeftoverScan = id => { scanCalls++; return Task.FromResult<LeftoverScan?>(EmptyScan(id)); };
                try { await unread.ScanLeftoversCommand.ExecuteAsync(null); }
                finally { App.Live.LeftoverScan = liveScan; }
                Check(unread.CanRestoreCleanup && !unread.CanScan && scanCalls == 0 && !unread.OfficialPreviewState.Contains("already removed", StringComparison.Ordinal),
                    "An app listed only for its saved cleanup never scans and never claims it was removed when the list couldn't be read" + " | got: " + unread.OfficialPreviewState);
                await unread.RestoreCleanupCommand.ExecuteAsync(null);
                await Task.Delay(200);
                Check(unread.StaleNotice.Length == 0 && unread.InventoryNotice.StartsWith("We couldn't read your installed apps", StringComparison.Ordinal),
                    "Restoring while the installed apps list can't be read keeps the page's explanation instead of a changed-elsewhere notice" + " | got: " + unread.StaleNotice);
                App.Live.InstalledApps = new InstalledAppInventory { Apps = [appA], Complete = false };
                var partial = new UninstallCleanupViewModel();
                await partial.InitializeAsync();
                Check(partial.IsReady && partial.Apps.FirstOrDefault(item => item.AppId == appB.AppId) is { Removed: true, RemovalUnconfirmed: true, SecondaryLabel: "Its saved cleanup can be restored." },
                    "An app missing from a partly read installed apps list is never shown as removed");
                App.Live.InstalledApps = null;
                App.Live.CleanupRunsRoot = null;
                var failed = new UninstallCleanupViewModel();
                await failed.InitializeAsync();
                Check(!failed.IsReady && failed.ErrorMessage is { Length: > 0 }, "With no installed apps list and no saved cleanup, the page still reports that the list couldn't be read");
                App.Live.CleanupRunsRoot = runsRoot;
                var olderValid = SavedRun("run-old", "app-old");
                File.SetLastWriteTimeUtc(olderValid, DateTime.UtcNow.AddMinutes(-10));
                SavedRun("run-new", "app-old");
                File.Delete(Path.Combine(runsRoot, "run-new", "backup.bin"));
                Check(CleanupRecoveries.Find(runsRoot, "app-old") == olderValid, "A saved cleanup whose backup files are gone is not offered and does not hide an older one that can be restored");
                Check(CleanupRecoveries.Find(runsRoot, "app-old", path => path != olderValid) is null, "A saved cleanup the restore would refuse is not offered");
            }
            finally { App.Live.InstalledApps = savedInventory; }
        }
        finally
        {
            App.Live.CleanupRunsRoot = null;
            if (Directory.Exists(runsRoot)) Directory.Delete(runsRoot, true);
        }
    }
    finally { Directory.Delete(rollbackRoot, true); }
}

Check(RooIndustries.OptimizationSuite.Services.BackendScriptPolicy.Timeout(@"C:\Program Files\Roo Industries\Optimization Suite\backend\scripts\Invoke-UninstallCleanupApplyPackage.ps1") is null
    && !RooIndustries.OptimizationSuite.Services.BackendScriptPolicy.StopWholeTree(@"C:\Program Files\Roo Industries\Optimization Suite\backend\scripts\invoke-uninstallcleanupapplypackage.ps1"),
    "The Leftover cleanup remover script has no app-side time limit and a cancel never kills the uninstaller it started");
Check(RooIndustries.OptimizationSuite.Services.BackendScriptPolicy.Timeout(@"C:\x\backend\scripts\Get-BugReportSpecs.ps1") == TimeSpan.FromSeconds(45) && RooIndustries.OptimizationSuite.Services.BackendScriptPolicy.StopWholeTree(@"C:\x\backend\scripts\Get-BugReportSpecs.ps1"),
    "Other backend scripts keep the 45 second limit and stop their whole process tree");
await BulkRemovalChecks.RunAsync(Check);
await RevisitChecks.RunAsync(Check);
await BugReportChecks.RunAsync(Check);

Console.WriteLine($"Completed {count} app sweep UI checks.");
