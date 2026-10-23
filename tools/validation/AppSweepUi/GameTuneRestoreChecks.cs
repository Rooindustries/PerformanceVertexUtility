using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.ViewModels;

static class GameTuneRestoreChecks
{
    const string BlockedReason = "A saved control has no valid original value. Its current value and backup were kept.";
    const string UnconfirmedReason = "priorityClass: Undo couldn't confirm another program still holds it, so it was left alone. Run Undo again.";

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
            App.Live.GameTuneRestoreText = Reason(envelopes["first"], UnconfirmedReason + "; ioPriority: Windows could not read back I/O priority.");
            await mixed.RestoreMatchTuneCommand.ExecuteAsync(null);
            check(mixed.MatchTuneStatus == "Game restore needs attention"
                    && mixed.MatchTuneDetail == "FixtureGame.exe (CPU priority): Undo couldn't confirm another program still holds it, so it was left alone. Run Undo again.\nFixtureGame.exe (I/O priority): Windows could not read back I/O priority.",
                "A Restore that kept two settings names each setting with its own reason");
        }
        finally
        {
            (App.Live.GameTuneStatusText, App.Live.GameTuneRestoreText, App.Live.GameTuneStatusError, App.Live.GameTuneRestoreError, App.Live.LastError) = saved;
            Directory.Delete(root, true);
        }
    }

    static string Reason(string envelope, string reason) => envelope.Replace("{reason}", JsonEncodedText.Encode(reason).ToString(), StringComparison.Ordinal);

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
