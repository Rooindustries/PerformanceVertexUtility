using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.ViewModels;

static class GameTuneRestoreChecks
{
    const string LeftReason = "priorityClass: Left as another program set it.";
    const string LeftDetail = "FixtureGame.exe: CPU priority is High because another program changed it after Game Tune did, so Restore left it. Close the game, then press Restore to finish.";
    const string BlockedReason = "A saved control has no valid original value. Its current value and backup were kept.";

    public static async Task LeftAsSetAsync(Action<bool, string> check)
    {
        var saved = (App.Live.GameTuneStatusText, App.Live.GameTuneRestoreText, App.Live.GameTuneStatusError, App.Live.GameTuneRestoreError, App.Live.LastError);
        var root = Path.Combine(Path.GetTempPath(), "app-sweep-left-as-set-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            App.Live.GameTuneStatusError = null;
            App.Live.GameTuneRestoreError = null;
            App.Live.LastError = null;
            var envelopes = Envelopes(root);
            var model = new PerformanceProfilesViewModel();
            async Task Refresh(string step)
            {
                App.Live.GameTuneStatusText = envelopes[step];
                await RefreshSessions(model);
            }
            async Task Restore(string step)
            {
                App.Live.GameTuneRestoreText = envelopes[step];
                await model.RestoreMatchTuneCommand.ExecuteAsync(null);
            }
            bool Left(string detail) => model.MatchTuneStatus == "Restore left a setting alone" && model.MatchTuneDetail == detail && model.MatchTuneRestoreAvailable && !model.MatchTuneDetail.Contains('→');

            await Refresh("refresh");
            check(Left("FixtureGame.exe: another program changed CPU priority after Game Tune did, so Restore left it. Close the game, then press Restore to finish."),
                "A reopened app names the game, the setting and why Restore left it before it has read the value");
            await Restore("first");
            check(Left(LeftDetail), "Restore says CPU priority is High because another program changed it and how to finish, not the refused High → Normal write");
            await Restore("second");
            check(Left(LeftDetail), "Pressing Restore again while the game runs keeps the same explanation instead of an unexplained repeat");
            await Refresh("refresh");
            check(Left(LeftDetail), "Refreshing the page keeps the setting, its value and the reason");
            await Refresh("afterExit");
            check(Left(LeftDetail), "After the game exits the status still says how to finish the kept restore");
            await Restore("manualAfterExit");
            check(model.MatchTuneStatus == "Game priorities restored" && !model.MatchTuneRestoreAvailable && !model.MatchTuneDetail.Contains("Restore left", StringComparison.Ordinal),
                "Restore after the game exits finishes the session and clears the explanation");

            var blocked = new PerformanceProfilesViewModel();
            App.Live.GameTuneStatusText = envelopes["refresh"].Replace(LeftReason, BlockedReason, StringComparison.Ordinal);
            await RefreshSessions(blocked);
            check(blocked.MatchTuneStatus == "Needs attention" && blocked.MatchTuneDetail == "FixtureGame.exe: " + BlockedReason && blocked.MatchTuneRestoreAvailable,
                "A refreshed status shows a different skip reason in its own words");
            App.Live.GameTuneRestoreText = envelopes["first"].Replace(LeftReason, BlockedReason, StringComparison.Ordinal);
            await blocked.RestoreMatchTuneCommand.ExecuteAsync(null);
            check(blocked.MatchTuneStatus == "Game restore needs attention" && blocked.MatchTuneDetail == "FixtureGame.exe: " + BlockedReason && blocked.MatchTuneRestoreAvailable,
                "A Restore result shows a different skip reason in its own words without the refused write");

            var mixed = new PerformanceProfilesViewModel();
            App.Live.GameTuneStatusText = envelopes["refresh"];
            await RefreshSessions(mixed);
            App.Live.GameTuneRestoreText = envelopes["first"].Replace(LeftReason, LeftReason + "; ioPriority: Windows could not read back I/O priority.", StringComparison.Ordinal);
            await mixed.RestoreMatchTuneCommand.ExecuteAsync(null);
            check(mixed.MatchTuneStatus == "Game restore needs attention"
                    && mixed.MatchTuneDetail == "FixtureGame.exe: CPU priority is High because another program changed it after Game Tune did, so Restore left it.\nFixtureGame.exe (I/O priority): Windows could not read back I/O priority.\nClose the game, then press Restore to finish.",
                "A Restore that left one setting and failed another names each setting with its own reason");
        }
        finally
        {
            (App.Live.GameTuneStatusText, App.Live.GameTuneRestoreText, App.Live.GameTuneStatusError, App.Live.GameTuneRestoreError, App.Live.LastError) = saved;
            Directory.Delete(root, true);
        }
    }

    static Dictionary<string, string> Envelopes(string root)
    {
        var sessionPath = Path.Combine(root, "session.json");
        var backupPath = Path.Combine(root, "backup.json");
        var text = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "game-tune-left-as-set.json"))
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
