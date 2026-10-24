using System;
using RooIndustries.Optimizer;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using System.IO;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class RestoreLogsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _restoreHeadline = "Checking what you can undo…";
    [ObservableProperty] private string _restoreState = "neutral";

    public ObservableCollection<StatusLine> RestoreRows { get; } = new();
    public ObservableCollection<AuditRow> HistoryRows { get; } = new();
    public bool HasHistory => HistoryRows.Count > 0;

    protected override async Task LoadCoreAsync()
    {
        var sessionRead = App.Live.GetGameTuneSessionStatusAsync();
        var governorRead = App.Live.GetProcessGovernorSessionStatusAsync();
        var gamesRead = App.Operations.ReadGameSessionsAsync();
        var windowsRead = ReadWindowsAsync();
        var rulesRead = ReadRulesAsync();
        var windows = await windowsRead;
        var rules = await rulesRead;
        var session = await sessionRead;
        var governor = await governorRead;
        var games = await gamesRead;

        BuildRestore(
            session?.DryRun == false || session?.Status == "notFound" ? RecoveryAvailable(session.Status, session.Restorable) : null,
            governor?.DryRun == false || governor?.Status == "notFound" ? RecoveryAvailable(governor.Status, governor.Restorable) : null, games, windows, rules);
        BuildHistory(session, governor, games, windows, rules);
        IsEmpty = false;
    }

    private static async Task<TweakRecovery?> ReadWindowsAsync()
    {
        try { return await App.Operations.ReadWindowsRecoveryAsync(); } catch (Exception) { return null; }
    }

    private static async Task<GovernorSnapshot?> ReadRulesAsync()
    {
        try { return await App.Operations.ReadGovernorAsync(); } catch (Exception) { return null; }
    }

    private void BuildRestore(bool? gameRecovery, bool? governorRecovery, GameSessionEntry[] games, TweakRecovery? windows, GovernorSnapshot? rules)
    {
        RestoreRows.Clear();
        var rulesState = rules is null ? "unknown" : GovernorDisplay.State(rules);
        var changedApps = rules is null ? 0 : GovernorDisplay.Changed(rules);
        var keptApps = rules is null ? 0 : GovernorDisplay.Kept(rules);
        var leftAsSet = rules is not null && GovernorDisplay.LeftAsSet(rules).Length > 0;
        var leftoverApps = rules is null ? 0 : GovernorDisplay.Apps(GovernorDisplay.Holding(rules));
        var retry = rules is not null && GovernorDisplay.CanRetry(rules, rulesState) ? " · press Put settings back in Games > Processes" : "";
        var restorable = windows?.State?.Profiles.Length > 0 || gameRecovery == true || governorRecovery == true || leftoverApps > 0 || games.Any(game => game.Worker.State is not null && !GameSessionDisplay.Restored(game.Worker));
        var signIn = rules is not null && rulesState == "running" ? GovernorDisplay.SignIn(rules) : "yes";
        var signInNote = signIn switch { "yes" => "", "no" => " · it won't start when you sign in · press Start governor in Games > Processes to fix that", _ => " · couldn't confirm it starts when you sign in · press Start governor in Games > Processes to fix that" };
        var unavailable = windows is null || gameRecovery is null || governorRecovery is null || rules is null || rulesState == "notResponding" || rules.Worker.HostRunning is null || rules.Summary.UnreadableRules is { Length: > 0 } || rules.Summary.RulesError is not null || rules.Summary.SecurityProblem is not (null or "missing")
            || games.Any(game => game.Worker.State is null || game.Worker.HostRunning is null);

        var restart = windows?.Pending is { Phase: "awaiting-restart" } pending && windows.State?.History.Any(item => item.OperationId == pending.Plan.OperationId) == true;
        RestoreHeadline = restart ? "A Windows feature change needs a restart. After you restart, press Review recovery in Windows tweaks to finish it." : windows?.Pending is not null ? "A Windows change didn't finish. Press Review recovery in Windows tweaks." : restorable
            ? "You've got changes you can undo. Each row tells you where."
            : unavailable ? "Couldn't check everything. Open this page again to retry."
                : Nothing + ".";
        RestoreState = windows?.Pending is not null ? "medium" : restorable && !unavailable ? "safe" : unavailable ? "medium" : "neutral";

        RestoreRows.Add(new StatusLine(
            "Game priority",
            gameRecovery == true ? "Can undo · press Restore under Game priority in Games > Background apps" : gameRecovery == false ? Nothing : CouldNotCheck,
            gameRecovery == true ? "safe" : gameRecovery == false ? "neutral" : "medium"));
        RestoreRows.Add(new StatusLine(
            "Background limits",
            governorRecovery == true ? "Can undo · press Restore under Background limits in Games > Background apps" : governorRecovery == false ? Nothing : CouldNotCheck,
            governorRecovery == true ? "safe" : governorRecovery == false ? "neutral" : "medium"));
        RestoreRows.Add(new StatusLine(
            "Governor",
            rulesState switch
            {
                "running" => "Running · " + GovernorDisplay.Count(changedApps) + " changed · press Pause governor in Games > Processes to undo" + signInNote,
                "pausing" => "Pausing · " + GovernorDisplay.StillHave(changedApps) + " rule settings · open Games > Processes",
                "paused" => keptApps > 0 ? "Paused · " + GovernorDisplay.Count(keptApps) + " kept a setting the governor couldn't put back" + retry : leftAsSet ? "Paused" : "Paused · settings put back",
                "off" => rules!.Worker.HostRunning is null ? "Off · couldn't check that every app got its old settings back" : leftoverApps > 0 ? "Off · " + GovernorDisplay.StillHave(leftoverApps) + " rule settings" + retry : rules!.Summary.Rules > 0 ? "Off · no rules are on" : "No rules",
                "stopped" => "Stopped · " + (leftoverApps > 0
                    ? GovernorDisplay.StillHave(leftoverApps) + " rule settings · " + (rules!.ScheduledTask?.Restarts == true ? "starts again by itself within a minute · " : "") + "press Pause governor in Games > Processes to undo"
                    : rules!.ScheduledTask?.Restarts == true ? "starts again by itself within a minute" : "press Start governor in Games > Processes"),
                "notResponding" => "Not responding · " + (leftoverApps > 0 ? GovernorDisplay.StillHave(leftoverApps) + " rule settings · " : "") + "open Games > Processes",
                _ => CouldNotCheck,
            } + (leftAsSet ? " · " + ProcessControlEngine.LeftAsSet : ""),
            rulesState switch { "running" => signIn == "yes" ? "safe" : "medium", "paused" or "off" when leftoverApps == 0 && rules!.Worker.HostRunning is not null => "neutral", _ => "medium" }));

        var profiles = windows?.State?.Profiles.Length ?? 0;
        RestoreRows.Add(new StatusLine("Windows tweaks", windows is null ? CouldNotCheck : windows.Pending is not null ? restart ? "Restart your PC, then press Review recovery in Windows tweaks" : "A change didn't finish · press Review recovery in Windows tweaks" :
            profiles > 0 ? profiles + (profiles == 1 ? " profile to undo" : " profiles to undo") : Nothing, windows is null || windows.Pending is not null ? "medium" : profiles > 0 ? "safe" : "neutral"));
        foreach (var profile in windows?.State?.Profiles ?? [])
            RestoreRows.Add(new StatusLine(ProfileName(profile.Id, profile.Controls?.Select(claim => claim.Target)), profile.Selections.Length + (profile.Selections.Length == 1 ? " setting · undo it in Windows tweaks" : " settings · undo them in Windows tweaks"), "safe"));
        foreach (var game in games)
            RestoreRows.Add(new StatusLine(game.Worker.State is { } state ? GameName(state) : "Game session",
                SessionText(game.Worker), GameSessionDisplay.Restored(game.Worker) ? "neutral" : "medium"));

    }

    private void BuildHistory(GameTuneSessionStatus? session, ProcessGovernorSessionStatus? governor, GameSessionEntry[] games, TweakRecovery? windows, GovernorSnapshot? rules)
    {
        HistoryRows.Clear();

        foreach (var group in (rules is null ? [] : GovernorDisplay.LeftAsSet(rules)).GroupBy(instance => (instance.RuleId, Key: GovernorDisplay.Key(instance.Process))))
        {
            var instance = group.First();
            HistoryRows.Add(new AuditRow("Recent", "Governor", "neutral", Naming.FriendlyName(Path.GetFileNameWithoutExtension(instance.Process.ExecutablePath)),
                ProcessControlEngine.LeftAsSet, Nothing, "neutral"));
        }

        var running = rules is not null && GovernorDisplay.State(rules) == "running";
        foreach (var group in (rules is null ? [] : GovernorDisplay.Holding(rules)).GroupBy(instance => (instance.RuleId, Key: GovernorDisplay.Key(instance.Process))))
        {
            var instance = group.First();
            var rule = rules!.Rules.FirstOrDefault(item => item.RuleId == instance.RuleId);
            var outcomes = group.Select(item => GovernorDisplay.Outcome(item, running && rule?.Enabled == true)).ToArray();
            HistoryRows.Add(new AuditRow("Now", "Governor", "neutral", Naming.FriendlyName(Path.GetFileNameWithoutExtension(instance.Process.ExecutablePath)),
                (rule?.Name ?? "Saved rule") + (outcomes.Contains("notPutBack") ? " · a setting couldn't be put back" : outcomes.All(item => item == "steppedBack") ? " · another app changed it, so the governor left it alone"
                    : outcomes.Contains("steppedBack") ? " · another app changed some of its settings, so the governor left those alone" : " · on for this app"), "Undo in Processes", "low"));
        }

        var tuneUndo = session is null ? CouldNotCheck : RecoveryAvailable(session.Status, session.Restorable) switch { true => "Undo in Background apps", false => Nothing, null => CouldNotCheck };
        var restored = (session?.RestoredItems ?? []).Select(item => item.ProcessId).ToHashSet();
        foreach (var item in session is { DryRun: false } ? session.ChangedItems ?? [] : [])
        {
            HistoryRows.Add(new AuditRow("Recent", "Game priority", "low", DisplayName(item),
                "CPU priority " + Priority(item.OriginalPriorityClass) + " → " + Priority(item.AppliedPriorityClass),
                restored.Contains(item.ProcessId) ? "Done" : tuneUndo, "low"));
        }

        foreach (var item in session is { DryRun: false } ? session.RestoredItems ?? [] : [])
        {
            HistoryRows.Add(new AuditRow("Recent", "Game priority", "safe", DisplayName(item),
                "CPU priority back to " + Priority(item.RestoredPriorityClass),
                "Done", "safe"));
        }

        var restraints = governor is { DryRun: false } ? governor.ActiveRestraints?.Count ?? 0 : 0;
        if (restraints > 0)
        {
            HistoryRows.Add(new AuditRow("Recent", "Background limits", "medium",
                restraints + (restraints == 1 ? " background app" : " background apps"),
                "Lower priority while your game runs", RecoveryAvailable(governor!.Status, governor.Restorable) switch { true => "Undo in Background apps", false => Nothing, null => CouldNotCheck }, "low"));
        }

        foreach (var game in games.Where(game => game.Worker.State is not null))
        {
            var state = game.Worker.State!;
            HistoryRows.Add(new AuditRow(state.UpdatedAtUtc.ToLocalTime().ToString("g"), "Game session", "neutral",
                GameName(state), SessionText(game.Worker), GameSessionDisplay.Restored(game.Worker) ? "Done" : "Undo in Games", "neutral"));
        }

        foreach (var entry in (windows?.State?.History ?? []).AsEnumerable().Reverse())
        {
            var changes = entry.Changes.Length + (entry.Controls?.Length ?? 0);
            var active = windows!.State!.Profiles.FirstOrDefault(profile => profile.Id == entry.ProfileId);
            HistoryRows.Add(new AuditRow(entry.AtUtc.ToLocalTime().ToString("g"), "Windows tweaks", "neutral", "Windows",
                ProfileName(entry.ProfileId, active?.Controls?.Select(claim => claim.Target) ?? entry.Controls?.Select(change => change.Before)) + " · " + changes + (changes == 1 ? " change" : " changes"),
                active is not null ? "Undo in Windows tweaks" : Nothing, "neutral"));
        }
        OnPropertyChanged(nameof(HasHistory));
    }

    private const string Nothing = "Nothing to undo";
    private const string CouldNotCheck = "Couldn't check";

    private static string GameName(ProtectedSessionState state) => Naming.FriendlyName(Path.GetFileNameWithoutExtension(state.Preview.GamePath));

    private static string SessionText(ProtectedSessionStatus status)
    {
        if (status.State is not { } state) return CouldNotCheck;
        if (status.HostRunning is null || status.Error is not null) return "Couldn't check this session · open Games";
        if (GameSessionDisplay.Restored(status)) return state.Games.Any(game => !game.Exited && game.Fields.Any(field => field.Status == "restartRequired"))
            ? "Settings put back · restart the game to clear its launch priorities" : "Settings put back";
        return status.HostRunning == false ? "Didn't finish putting settings back · press Recover settings in Games" : "On · press Stop and restore in Games to undo";
    }

    private static string ProfileName(string id, IEnumerable<TweakControlRead>? targets)
    {
        var file = targets?.FirstOrDefault(target => target.Address.Kind == "file-ownership")?.Address.Target;
        if (file is not null) return "File ownership: " + Path.GetFileName(file.StartsWith("selected:", StringComparison.Ordinal) ? file[9..] : file);
        if (id.StartsWith("file-permissions-", StringComparison.Ordinal)) return "File ownership";
        if (id.StartsWith("restore-point-", StringComparison.Ordinal)) return "Restore point limit";
        return id;
    }

    private static string DisplayName(SessionChangedItem item)
        => string.IsNullOrWhiteSpace(item.DisplayName) ? Naming.FriendlyName(item.ProcessName) : item.DisplayName!;

    private static string Priority(string? value) => value switch
    {
        "AboveNormal" => "Above normal",
        "BelowNormal" => "Below normal",
        "RealTime" => "Realtime",
        null or "" => "Normal",
        _ => value!,
    };

    private static bool? RecoveryAvailable(string? status, bool? restorable) => (status, restorable) switch
    {
        ("active" or "restorable" or "failed", true) => true,
        ("notFound" or "completed" or "active", false) => false,
        _ => null,
    };
}
