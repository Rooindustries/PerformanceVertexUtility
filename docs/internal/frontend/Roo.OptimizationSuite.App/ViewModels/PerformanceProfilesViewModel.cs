using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class PerformanceProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string _gameStatus = "No game running";
    [ObservableProperty] private string _gameStatusLevel = "neutral";
    [ObservableProperty] private string _ruleSummary =
        "The game gets the room. Companions stay protected. Launchers and browser helpers get quieted.";
    [ObservableProperty] private int _appsCount;
    [ObservableProperty] private int _keepCount;
    [ObservableProperty] private int _quietCount;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanUndoTune))][NotifyCanExecuteChangedFor(nameof(UndoTuneCommand))]
    private bool _sessionActive;
    [ObservableProperty] private string _sessionSummary = "Preview first. Nothing changes until you confirm.";
    [ObservableProperty] private string _primaryActionLabel = "Tune My PC";
    [ObservableProperty] private bool _primaryActionEnabled;
    [ObservableProperty] private bool _keepQuietingDuringMatch;
    [ObservableProperty] private string? _governorCaption;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanUndoTune))][NotifyCanExecuteChangedFor(nameof(UndoTuneCommand))]
    private string? _restoreActionId;

    private readonly List<GameAppRow> _all = new();
    public ObservableCollection<GameAppRow> Rows { get; } = new();
    public ObservableCollection<GameAppRow> BoostRows { get; } = new();
    public ObservableCollection<GameAppRow> ProtectedRows { get; } = new();
    public ObservableCollection<GameAppRow> QuietRows { get; } = new();

    public bool CanUndoTune => SessionActive && !string.IsNullOrWhiteSpace(RestoreActionId);

    private static readonly string[] QuietCategories = { "browserWebView", "launcher", "vendorUtility", "backgroundApp" };

    protected override async Task LoadCoreAsync()
    {
        var classification = await App.Live.GetProcessClassificationAsync() ?? await TryLoadSample(Data.GetProcessClassificationAsync);
        var preview = await App.Live.GetProcessProfilePreviewAsync() ?? await TryLoadSample(Data.GetProcessProfilePreviewAsync);
        var session = await App.Live.GetGameTuneSessionStatusAsync() ?? await TryLoadSample(Data.GetGameTuneSessionStatusAsync);
        var restorePreview = await TryLoadSample(Data.GetGameTuneRestorePreviewAsync);
        var governor = await App.Live.GetProcessGovernorSessionStatusAsync() ?? await TryLoadSample(Data.GetProcessGovernorSessionStatusAsync);
        var processes = classification?.Processes;
        if (processes is null || processes.Count == 0)
        {
            ErrorMessage = "We couldn't read your processes yet. Close and reopen to try again.";
            return;
        }

        var game = processes.FirstOrDefault(p => p.Category == "foregroundGame");
        if (game is not null)
        {
            GameStatus = Naming.FriendlyName(game.Name) + " running";
            GameStatusLevel = "safe";
        }
        else
        {
            GameStatus = "No game running";
            GameStatusLevel = "neutral";
        }

        _all.Clear();
        var previewByProcess = (preview?.Preview ?? new List<ProcessPreviewRow>())
            .GroupBy(p => (p.ProcessName ?? string.Empty).ToLowerInvariant())
            .ToDictionary(g => g.Key, g => g.First());
        foreach (var p in processes
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes))
        {
            var previewRow = previewByProcess.TryGetValue((p.Name ?? string.Empty).ToLowerInvariant(), out var row) ? row : null;
            var (plan, state) = PlanFor(p);
            _all.Add(new GameAppRow(
                DisplayName(p),
                Naming.CategoryLabel(p.Category),
                PriorityText(p.PriorityClass, previewRow?.ProposedPriorityClass),
                p.CpuPercent.ToString("0.#", CultureInfo.InvariantCulture) + "%",
                Format.Bytes(p.WorkingSetBytes),
                plan,
                state));
        }

        AppsCount = _all.Count;
        KeepCount = _all.Count(r => r.Plan == "Keep");
        QuietCount = _all.Count(r => r.Plan == "Quiet");

        BuildSessionState(session, restorePreview);
        BuildGovernorCaption(governor);
        ApplyFilter();
        IsEmpty = _all.Count == 0;
    }

    private static (string plan, string state) PlanFor(ProcessItem p)
    {
        if (p.Classification == "gameTarget" || p.Category == "foregroundGame") return ("Boost", "safe");
        if (p.Protected || p.Protection == "protected" || p.Classification is "protected" or "protectedCompanion") return ("Keep", "protected");
        if (p.Classification == "demotionCandidate" || QuietCategories.Contains(p.Category ?? string.Empty)) return ("Quiet", "low");
        return ("Watch", "neutral");
    }

    private void BuildSessionState(GameTuneSessionStatus? session, GameTuneRestorePreview? restorePreview)
    {
        RestoreActionId = restorePreview?.ActionId;
        SessionActive = session is { DryRun: false, Restorable: true } && session.SessionStatus == "restorable";
        if (SessionActive)
        {
            PrimaryActionLabel = "Undo Tune";
            PrimaryActionEnabled = true;
            var game = session?.ChangedItems?.FirstOrDefault(i => !string.IsNullOrWhiteSpace(i.ProcessName));
            var gameName = game is null ? "game" : Naming.FriendlyName(game.ProcessName);
            SessionSummary = "Tune active — " + gameName + " boosted, launchers quieted. Reversible.";
            return;
        }

        PrimaryActionLabel = "Tune My PC";
        PrimaryActionEnabled = _all.Count > 0;
        SessionSummary = "Preview first. Nothing changes until you confirm.";
    }

    private void BuildGovernorCaption(ProcessGovernorSessionStatus? governor)
    {
        var evidence = governor?.RuntimeEvidence;
        GovernorCaption = evidence is { BoundedSession: true, RestoreContractAvailable: true }
            ? "Runs only for the match and restores from backup when you stop."
            : "Ready — needs your go-ahead";
    }

    private static string FriendlyPriority(string? priorityClass) => priorityClass switch
    {
        "AboveNormal" => "Above",
        "BelowNormal" => "Below",
        "RealTime" => "Realtime",
        "High" => "High",
        "Idle" => "Idle",
        null or "" => "Normal",
        _ => priorityClass!,
    };

    private static string PriorityText(string? currentPriority, string? proposedPriority)
    {
        var current = FriendlyPriority(currentPriority);
        if (string.IsNullOrWhiteSpace(proposedPriority))
        {
            return current;
        }

        var proposed = FriendlyPriority(proposedPriority);
        return current == proposed ? current : current + " -> " + proposed;
    }

    private static string DisplayName(ProcessItem process)
        => string.IsNullOrWhiteSpace(process.DisplayName) ? Naming.FriendlyName(process.Name) : process.DisplayName!;

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    private void ApplyFilter()
    {
        var query = SearchText?.Trim();
        IEnumerable<GameAppRow> source = _all;
        if (!string.IsNullOrEmpty(query))
        {
            source = source.Where(r =>
                r.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Role.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Plan.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        Rows.Clear();
        BoostRows.Clear();
        ProtectedRows.Clear();
        QuietRows.Clear();
        foreach (var r in source)
        {
            Rows.Add(r);
            if (r.Plan == "Boost") BoostRows.Add(r);
            else if (r.Plan == "Keep") ProtectedRows.Add(r);
            else if (r.Plan == "Quiet") QuietRows.Add(r);
        }
    }

    [RelayCommand(CanExecute = nameof(CanUndoTune))]
    private void UndoTune()
    {
        SessionSummary = "Tune active — reversible.";
    }

    private static async Task<T?> TryLoadSample<T>(System.Func<Task<T>> load) where T : class
    {
        try
        {
            return await load().ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }
}
