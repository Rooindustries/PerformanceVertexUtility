using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
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
        var restore = await TrySample(Data.GetGameTuneRestorePreviewAsync);
        var governor = await App.Live.GetProcessGovernorSessionStatusAsync();

        BuildRestore(session, restore, governor);
        BuildHistory(session, governor);
        IsEmpty = false;
    }

    private void BuildRestore(GameTuneSessionStatus? session, GameTuneRestorePreview? restore, ProcessGovernorSessionStatus? governor)
    {
        RestoreRows.Clear();
        var restorable = session is { Restorable: true } || restore is { Restorable: true };

        RestoreHeadline = restorable
            ? "A restorable session is saved. One click puts everything back."
            : "Nothing to restore right now. Backups appear here the moment a change is applied.";
        RestoreState = restorable ? "safe" : "neutral";

        RestoreRows.Add(new StatusLine(
            "Game priority session",
            session is { Restorable: true } ? "Backed up · restorable" : "No session backup recorded",
            session is { Restorable: true } ? "safe" : "neutral"));
        RestoreRows.Add(new StatusLine(
            "Background restraint",
            governor is { Restorable: true } ? "Backed up · restorable" : "No restraint backup recorded",
            governor is { Restorable: true } ? "safe" : "neutral"));
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
            HistoryRows.Add(new AuditRow("-", "Ready", "neutral", "No changes recorded yet",
                "History appears after you apply your first change", "-", "neutral"));
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

    private static async Task<T?> TrySample<T>(Func<Task<T>> load) where T : class
    {
        try { return await load(); } catch { return null; }
    }
}
