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
    [ObservableProperty] private string _restoreHeadline = "Reading restore state…";
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
        var rulesState = rules is null ? "unknown" : GovernorDisplay.State(rules.Summary, rules.Worker);
        var ruleInstances = rules?.Worker.State?.Instances.Count(instance => instance.Status is "active" or "applying") ?? 0;
        var steppedBack = rules?.Worker.State?.Instances.Count(instance => instance.Status == "conflict") ?? 0;
        var restorable = windows?.State?.Profiles.Length > 0 || gameRecovery == true || governorRecovery == true || ruleInstances + steppedBack > 0 || games.Any(game => game.Worker.State is not null && !GameSessionDisplay.Restored(game.Worker));
        var unavailable = windows is null || gameRecovery is null || governorRecovery is null || rules is null || games.Any(game => game.Worker.State is null || game.Worker.HostRunning is null);

        var restart = windows?.Pending is { Phase: "awaiting-restart" } pending && windows.State?.History.Any(item => item.OperationId == pending.Plan.OperationId) == true;
        RestoreHeadline = restart ? "Windows feature changes are waiting for restart verification." : windows?.Pending is not null ? "A Windows settings change needs recovery. Open Windows tweaks to review it." : restorable
            ? "Saved settings are available. Open the matching section to restore them."
            : unavailable ? "Some recovery state could not be read. Reopen this page to retry."
                : "No Windows or process settings to restore.";
        RestoreState = windows?.Pending is not null ? "medium" : restorable ? "safe" : unavailable ? "medium" : "neutral";

        RestoreRows.Add(new StatusLine(
            "Game priority session",
            gameRecovery == true ? "Backed up · restorable" : gameRecovery == false ? "No session backup recorded" : "Status unavailable",
            gameRecovery == true ? "safe" : gameRecovery == false ? "neutral" : "medium"));
        RestoreRows.Add(new StatusLine(
            "Background restraint",
            governorRecovery == true ? "Backed up · restorable" : governorRecovery == false ? "No restraint backup recorded" : "Status unavailable",
            governorRecovery == true ? "safe" : governorRecovery == false ? "neutral" : "medium"));
        RestoreRows.Add(new StatusLine(
            "Roo Industries Governor",
            rulesState switch
            {
                "running" => "Running · " + (ruleInstances == 1 ? "1 app" : ruleInstances + " apps") + " changed · pause it in Games > Processes to put settings back",
                "paused" => steppedBack > 0 ? "Paused · " + steppedBack + " apps kept a setting the governor could not put back" : "Paused · settings put back",
                "off" => ruleInstances + steppedBack > 0 ? "Off · " + (ruleInstances + steppedBack) + " apps still have saved settings" : "No rules",
                "notResponding" => "Not responding · " + (ruleInstances > 0 ? ruleInstances + " apps have saved settings · " : "") + "open Games > Processes",
                _ => "Status unavailable",
            },
            rulesState switch { "running" => "safe", "paused" or "off" when ruleInstances + steppedBack == 0 => "neutral", _ => "medium" }));

        RestoreRows.Add(new StatusLine("Windows settings", windows is null ? "Status unavailable" : windows.Pending is not null ? restart ? "Check restart completion" : "Interrupted change · review recovery" :
            windows.State?.Profiles.Length > 0 ? windows.State.Profiles.Length + " saved profiles" : "No saved profiles", windows is null || windows.Pending is not null ? "medium" : windows.State?.Profiles.Length > 0 ? "safe" : "neutral"));
        foreach (var profile in windows?.State?.Profiles ?? []) RestoreRows.Add(new StatusLine(profile.Id, profile.Selections.Length + " selected settings · restorable", "safe"));
        foreach (var game in games)
            RestoreRows.Add(new StatusLine(game.Worker.State is { } state ? Path.GetFileNameWithoutExtension(state.Preview.GamePath) : "Game session",
                GameSessionDisplay.Title(game.Worker), GameSessionDisplay.Restored(game.Worker) ? "neutral" : "medium"));

    }

    private void BuildHistory(GameTuneSessionStatus? session, ProcessGovernorSessionStatus? governor, GameSessionEntry[] games, TweakRecovery? windows, GovernorSnapshot? rules)
    {
        HistoryRows.Clear();

        foreach (var instance in rules?.Worker.State?.Instances.Where(instance => instance.Status is "active" or "applying" or "conflict") ?? [])
        {
            var rule = rules!.Rules.FirstOrDefault(item => item.RuleId == instance.RuleId);
            HistoryRows.Add(new AuditRow("Now", "Governor", "neutral", Path.GetFileNameWithoutExtension(instance.Process.ExecutablePath),
                (rule?.Name ?? "Saved rule") + (instance.Status == "conflict" ? " · stepped back for this app" : " · settings kept by the governor"), "Reversible", "low"));
        }

        foreach (var item in session is { DryRun: false } ? session.ChangedItems ?? [] : [])
        {
            HistoryRows.Add(new AuditRow("Recent", "Applied", "low", DisplayName(item),
                "CPU  " + Priority(item.OriginalPriorityClass) + " → " + Priority(item.AppliedPriorityClass),
                "Reversible", "low"));
        }

        foreach (var item in session is { DryRun: false } ? session.RestoredItems ?? [] : [])
        {
            HistoryRows.Add(new AuditRow("Recent", "Restored", "safe", DisplayName(item),
                "CPU  " + Priority(item.AppliedPriorityClass) + " → " + Priority(item.RestoredPriorityClass),
                "Done", "safe"));
        }

        var restraints = governor is { DryRun: false } ? governor.ActiveRestraints?.Count ?? 0 : 0;
        if (restraints > 0)
        {
            HistoryRows.Add(new AuditRow("Recent", "Restrained", "medium",
                "Background · " + restraints + (restraints == 1 ? " app" : " apps"),
                "Eased while the game runs", "Reversible", "low"));
        }

        foreach (var game in games.Where(game => game.Worker.State is not null))
        {
            var state = game.Worker.State!;
            HistoryRows.Add(new AuditRow(state.UpdatedAtUtc.ToLocalTime().ToString("g"), "Game session", "neutral",
                Path.GetFileNameWithoutExtension(state.Preview.GamePath), GameSessionDisplay.Title(game.Worker), GameSessionDisplay.Restored(game.Worker) ? "Done" : "Review", "neutral"));
        }

        foreach (var entry in (windows?.State?.History ?? []).Reverse())
            HistoryRows.Add(new AuditRow(entry.AtUtc.ToLocalTime().ToString("g"), "Windows settings", "neutral", entry.ProfileId,
                (entry.Changes.Length + (entry.Controls?.Length ?? 0)) + " value changes", windows!.State!.Profiles.Any(profile => profile.Id == entry.ProfileId) ? "Review profile" : "No active profile", "neutral"));
        OnPropertyChanged(nameof(HasHistory));
    }

    private static string DisplayName(SessionChangedItem item)
        => string.IsNullOrWhiteSpace(item.DisplayName) ? Naming.FriendlyName(item.ProcessName) : item.DisplayName!;

    private static string Priority(string? value) => value switch
    {
        "AboveNormal" => "Above",
        "BelowNormal" => "Below",
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
