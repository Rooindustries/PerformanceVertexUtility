using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.ViewModels;

static class GameTuneRestoreChecks
{
    const string BlockedReason = "A saved control has no valid original value. Its current value and backup were kept.";
    const string UnconfirmedReason = "priorityClass: Undo couldn't confirm another program still holds it, so it was left alone. Run Undo again.";
    const string UnprovenReason = "priorityClass: Undo couldn't confirm it set this value, so it was left alone. It resets when that app restarts.";
    const string ManagedReason = "affinityMask: Another saved change still uses this control. Undo that change first, then try again.";
    const string IoReason = "ioPriority: Windows could not read back I/O priority.";
    const string UnprovenHeldReason = "priorityClass: Undo couldn't confirm it set this value, so it was left alone. It resets when that app restarts.; gpuPriority: Undo couldn't confirm it set this value, so it was left alone. It resets when that app restarts.";
    const string RecoveryForeignReason = "priorityClass: Another program changed it, so recovery left it alone and kept the backup. Restore keeps that program's value and finishes.";
    const string RecoveryUnreadableReason = "gpuPriority: Windows couldn't read it, so recovery left it alone and kept the backup. Restore stays available; try it again later.";
    const string GovernorReason = "priorityClass: Managed by the governor";
    const string GovernorShown = "FixtureGame.exe (CPU priority): A Governor rule controls it. Turn that rule off on the Processes tab, then Restore again.";

    public static async Task SkipReasonsAsync(Action<bool, string> check)
    {
        var saved = (App.Live.GameTuneStatusText, App.Live.GameTuneRestoreText, App.Live.GameTuneStatusError, App.Live.GameTuneRestoreError, App.Live.LastError);
        var root = Path.Combine(Path.GetTempPath(), "app-sweep-restore-skips-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            App.Live.GameTuneStatusError = null;
            App.Live.GameTuneRestoreError = null;
            App.Live.LastError = null;
            var envelopes = Envelopes(root);

            var blocked = new PerformanceProfilesViewModel();
            App.Live.GameTuneStatusText = Reason(envelopes["refresh"], BlockedReason);
            await RefreshSessions(blocked);
            check(blocked.MatchTuneStatus == "Needs attention" && blocked.MatchTuneDetail == "FixtureGame.exe: " + BlockedReason && blocked.MatchTuneRestoreAvailable,
                "A refreshed status shows a skip reason in its own words");
            App.Live.GameTuneRestoreText = Reason(envelopes["first"], BlockedReason);
            await blocked.RestoreMatchTuneCommand.ExecuteAsync(null);
            check(blocked.MatchTuneStatus == "Game restore needs attention" && blocked.MatchTuneDetail == "FixtureGame.exe: " + BlockedReason && blocked.MatchTuneRestoreAvailable,
                "A Restore result shows a skip reason in its own words without the refused write");

            var mixed = new PerformanceProfilesViewModel();
            App.Live.GameTuneStatusText = Reason(envelopes["refresh"], UnconfirmedReason);
            await RefreshSessions(mixed);
            App.Live.GameTuneRestoreText = Reason(envelopes["first"], UnconfirmedReason + "; " + IoReason);
            await mixed.RestoreMatchTuneCommand.ExecuteAsync(null);
            check(mixed.MatchTuneStatus == "Game restore needs attention"
                    && mixed.MatchTuneDetail == "FixtureGame.exe (CPU priority): Restore couldn't confirm another program still holds it, so it was left alone. Restore again once that app closes.\nFixtureGame.exe (I/O priority): Windows could not read back I/O priority.",
                "A Restore that kept two settings names each setting with its own reason");

            foreach (var (name, reason, shown) in new[]
            {
                ("another program", UnconfirmedReason, "FixtureGame.exe (CPU priority): Restore couldn't confirm another program still holds it, so it was left alone. Restore again once that app closes."),
                ("unproven write", UnprovenReason + "; " + IoReason, "FixtureGame.exe (CPU priority): Restore couldn't confirm it set this value, so it was left alone. It resets when that app restarts; then Restore again.\nFixtureGame.exe (I/O priority): Windows could not read back I/O priority."),
                ("another saved change", ManagedReason, "FixtureGame.exe (CPU affinity): Another saved change still uses this control. Restore that change first, then try again."),
                ("a Governor rule", GovernorReason, GovernorShown),
            })
            {
                var card = new PerformanceProfilesViewModel();
                App.Live.GameTuneStatusText = Reason(envelopes["refresh"], reason);
                await RefreshSessions(card);
                check(card.MatchTuneStatus == "Needs attention" && card.MatchTuneDetail == shown && card.MatchTuneRestoreAvailable,
                    "A refreshed Game Tune card uses this page's Restore wording: " + name);
                App.Live.GameTuneRestoreText = Reason(envelopes["first"], reason);
                await card.RestoreMatchTuneCommand.ExecuteAsync(null);
                check(card.MatchTuneStatus == "Game restore needs attention" && card.MatchTuneDetail == shown && card.MatchTuneRestoreAvailable,
                    "A Game Tune Restore card uses this page's Restore wording: " + name);
            }

            foreach (var (name, reason, shown) in new[]
            {
                ("an unconfirmed write", UnprovenHeldReason, "FixtureGame.exe (CPU priority): Restore couldn't confirm it set this value, so it was left alone. It resets when that app restarts; then Restore again.\nFixtureGame.exe (GPU priority): Restore couldn't confirm it set this value, so it was left alone. It resets when that app restarts; then Restore again."),
                ("a confirmed write", RecoveryForeignReason, "FixtureGame.exe (CPU priority): Another program changed it, so recovery left it alone and kept the backup. Restore keeps that program's value and finishes."),
                ("an unreadable setting", RecoveryUnreadableReason, "FixtureGame.exe (GPU priority): Windows couldn't read it, so recovery left it alone and kept the backup. Restore stays available; try it again later."),
                ("a Governor rule", GovernorReason, GovernorShown),
            })
            {
                var card = new PerformanceProfilesViewModel();
                App.Live.GameTuneStatusText = Recovery(envelopes["refresh"], reason);
                await RefreshSessions(card);
                check(card.MatchTuneStatus == "Needs attention" && card.MatchTuneDetail == shown && card.MatchTuneRestoreAvailable,
                    "A refused recovery names each setting another program holds after " + name);
            }
        }
        finally
        {
            (App.Live.GameTuneStatusText, App.Live.GameTuneRestoreText, App.Live.GameTuneStatusError, App.Live.GameTuneRestoreError, App.Live.LastError) = saved;
            Directory.Delete(root, true);
        }
    }

    static string Reason(string envelope, string reason) => envelope.Replace("{reason}", JsonEncodedText.Encode(reason).ToString(), StringComparison.Ordinal);

    static string Recovery(string envelope, string reason)
    {
        var status = JsonNode.Parse(Reason(envelope, reason))!.AsObject();
        status["summary"]!["changedItemCount"] = 1;
        status["errors"] = new JsonArray(new JsonObject
        {
            ["code"] = "GAME_TUNE_RECOVERY_NEEDS_ATTENTION",
            ["message"] = "CPU priority for FixtureGame.exe: held by another program.",
            ["severity"] = "error",
        });
        return status.ToJsonString();
    }

    static Dictionary<string, string> Envelopes(string root)
    {
        var sessionPath = Path.Combine(root, "session.json");
        var backupPath = Path.Combine(root, "backup.json");
        var text = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "game-tune-restore-skips.json"))
            .Replace("{sessionPath}", JsonEncodedText.Encode(sessionPath).ToString(), StringComparison.Ordinal)
            .Replace("{backupPath}", JsonEncodedText.Encode(backupPath).ToString(), StringComparison.Ordinal)
            .Replace("{stateRoot}", JsonEncodedText.Encode(root).ToString(), StringComparison.Ordinal);
        var fixture = JsonNode.Parse(text)!.AsObject();
        File.WriteAllText(sessionPath, fixture["session"]!.ToJsonString());
        File.WriteAllText(backupPath, fixture["backup"]!.ToJsonString());
        return fixture.Where(entry => entry.Key is not ("session" or "backup")).ToDictionary(entry => entry.Key, entry => entry.Value!.ToJsonString());
    }

    static async Task RefreshSessions(PerformanceProfilesViewModel model)
    {
        var method = typeof(PerformanceProfilesViewModel).GetMethod("RefreshSessionStatusesAsync", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("RefreshSessionStatusesAsync is missing.");
        await ((Task?)method.Invoke(model, null) ?? throw new InvalidOperationException("RefreshSessionStatusesAsync did not return a task."));
    }
}
