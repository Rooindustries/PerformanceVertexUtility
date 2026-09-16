using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class RestoreLogsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _restoreHeadline = "Reading restore state…";
    [ObservableProperty] private string _restoreState = "neutral";

    public ObservableCollection<StatusLine> RestoreRows { get; } = new();
    public ObservableCollection<AuditRow> HistoryRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var session = await App.Live.GetGameTuneSessionStatusAsync();
        var governor = await App.Live.GetProcessGovernorSessionStatusAsync();

        BuildRestore(
            session is { DryRun: true } ? null : RecoveryAvailable(session?.Status, session?.Restorable),
            governor is { DryRun: true } ? null : RecoveryAvailable(governor?.Status, governor?.Restorable));
        BuildHistory(session, governor);
        IsEmpty = false;
    }

    private void BuildRestore(bool? gameRecovery, bool? governorRecovery)
    {
        RestoreRows.Clear();
        var restorable = gameRecovery == true || governorRecovery == true;
        var unavailable = gameRecovery is null || governorRecovery is null;

        RestoreHeadline = restorable
            ? "Saved recovery data is available. Review it in Process Control."
            : unavailable ? "Restore status could not be read. Reopen this page to retry."
                : "Nothing to restore right now. Backups appear here the moment a change is applied.";
        RestoreState = restorable ? "safe" : unavailable ? "medium" : "neutral";

        RestoreRows.Add(new StatusLine(
            "Game priority session",
            gameRecovery == true ? "Backed up · restorable" : gameRecovery == false ? "No session backup recorded" : "Status unavailable",
            gameRecovery == true ? "safe" : gameRecovery == false ? "neutral" : "medium"));
        RestoreRows.Add(new StatusLine(
            "Background restraint",
            governorRecovery == true ? "Backed up · restorable" : governorRecovery == false ? "No restraint backup recorded" : "Status unavailable",
            governorRecovery == true ? "safe" : governorRecovery == false ? "neutral" : "medium"));
        RestoreRows.Add(new StatusLine(
            "Backup before changes",
            "Always on: every apply writes a backup first",
            "low"));
    }

    private void BuildHistory(GameTuneSessionStatus? session, ProcessGovernorSessionStatus? governor)
    {
        HistoryRows.Clear();

        foreach (var item in session?.ChangedItems ?? new List<SessionChangedItem>())
        {
            HistoryRows.Add(new AuditRow("Recent", "Applied", "low", DisplayName(item),
                "CPU  " + Priority(item.OriginalPriorityClass) + " → " + Priority(item.AppliedPriorityClass),
                "Reversible", "low"));
        }

        foreach (var item in session?.RestoredItems ?? new List<SessionChangedItem>())
        {
            HistoryRows.Add(new AuditRow("Recent", "Restored", "safe", DisplayName(item),
                "CPU  " + Priority(item.AppliedPriorityClass) + " → " + Priority(item.RestoredPriorityClass),
                "Done", "safe"));
        }

        var restraints = governor?.ActiveRestraints?.Count ?? 0;
        if (restraints > 0)
        {
            HistoryRows.Add(new AuditRow("Recent", "Restrained", "medium",
                "Background · " + restraints + (restraints == 1 ? " app" : " apps"),
                "Eased while the game runs", "Reversible", "low"));
        }

        if (HistoryRows.Count == 0)
        {
            HistoryRows.Add(new AuditRow("-", "Ready", "neutral", "No history entries loaded",
                "Recorded changes appear here when session history is available", "-", "neutral"));
        }
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
