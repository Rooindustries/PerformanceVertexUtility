using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class PerformanceProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string _gameStatus = "No game running";
    [ObservableProperty] private string _gameStatusLevel = "neutral";
    [ObservableProperty] private string _ruleSummary =
        "Review priorities for games and background apps. Game launchers are left unchanged.";
    [ObservableProperty] private int _appsCount;
    [ObservableProperty] private int _keepCount;
    [ObservableProperty] private int _quietCount;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private string _actionTitle = "Process priorities";
    [ObservableProperty] private string _actionDetail = "Review the selected priorities, then apply them. Restore returns changed processes to their saved settings.";
    [ObservableProperty] private string _restoreHint = "No saved process settings";
    [NotifyPropertyChangedFor(nameof(CanRunProcessAction))]
    [NotifyPropertyChangedFor(nameof(CanApplyProcessProfile))]
    [ObservableProperty] private int _processPresetIndex;
    [ObservableProperty] private string _placementLabel = "Background apps on E-cores or CCD1, normal priority";
    [NotifyPropertyChangedFor(nameof(CanRunProcessAction))]
    [NotifyPropertyChangedFor(nameof(CanApplyProcessProfile))]
    [ObservableProperty] private bool _placementAvailable;
    [ObservableProperty] private string _placementReason = "Reading CPU topology…";
    [NotifyPropertyChangedFor(nameof(CanRunProcessAction))]
    [NotifyPropertyChangedFor(nameof(CanApplyProcessProfile))]
    [NotifyPropertyChangedFor(nameof(CanSelectPreset))]
    [NotifyPropertyChangedFor(nameof(CanRestoreProfile))]
    [NotifyPropertyChangedFor(nameof(CanCheckMatchTune))]
    [NotifyPropertyChangedFor(nameof(CanStartMatchTune))]
    [NotifyPropertyChangedFor(nameof(CanRestoreMatchTune))]
    [NotifyPropertyChangedFor(nameof(CanCheckGovernor))]
    [NotifyPropertyChangedFor(nameof(CanStartGovernor))]
    [NotifyPropertyChangedFor(nameof(CanRestoreGovernor))]
    [ObservableProperty] private bool _actionBusy;
    [NotifyPropertyChangedFor(nameof(CanRestoreProfile))]
    [NotifyPropertyChangedFor(nameof(CanApplyProcessProfile))]
    [ObservableProperty] private bool _restoreAvailable;
    [NotifyPropertyChangedFor(nameof(CanStartMatchTune))]
    [ObservableProperty] private bool _hasGameRunning;
    [ObservableProperty] private string _matchTuneStatus = "No game priorities checked yet";
    [ObservableProperty] private string _matchTuneDetail =
        "Raises the game CPU priority with normal memory priority, leaves OBS and Discord unchanged, and lowers CPU and memory priority for updaters and browser helpers. Game launchers are left unchanged.";
    [ObservableProperty] private string _governorStatus = "Background limits not checked yet";
    [ObservableProperty] private string _governorDetail =
        "Watches for background CPU spikes and lowers CPU, I/O and memory priority until CPU use drops.";
    [NotifyPropertyChangedFor(nameof(CanRestoreMatchTune))]
    [ObservableProperty] private bool _matchTuneRestoreAvailable;
    [NotifyPropertyChangedFor(nameof(CanRestoreGovernor))]
    [ObservableProperty] private bool _governorRestoreAvailable;

    private string? _lastBackupPath;
    private string? _lastBackupId;
    private string? _lastBackupGeneration;
    private SessionRestoreEvidence? _matchTuneRestore;
    private SessionRestoreEvidence? _governorRestore;

    private sealed record SessionRestoreEvidence(
        string Kind,
        string SessionId,
        string ProfileId,
        string SessionPath,
        string BackupManifestPath);

    private readonly List<GameAppRow> _all = new();
    private List<ProcessItem> _loadedProcesses = new();
    private string ProcessPreset => ProcessPresetIndex == 1 ? "placement" : "lower";
    public ObservableCollection<GameAppRow> Rows { get; } = new();
    [ObservableProperty] private bool recoverySetAside;
    public bool CanSelectPreset => !ActionBusy;
    public bool CanRunProcessAction => !ActionBusy && (ProcessPresetIndex == 0 || PlacementAvailable);
    public bool CanApplyProcessProfile => CanRunProcessAction && !RestoreAvailable && !App.Live.ProcessProfileRestorePending;
    public bool CanRestoreProfile => !ActionBusy && RestoreAvailable;
    public bool CanCheckMatchTune => !ActionBusy;
    public bool CanStartMatchTune => !ActionBusy && HasGameRunning;
    public bool CanRestoreMatchTune => !ActionBusy && MatchTuneRestoreAvailable;
    public bool CanCheckGovernor => !ActionBusy;
    public bool CanStartGovernor => !ActionBusy;
    public bool CanRestoreGovernor => !ActionBusy && GovernorRestoreAvailable;

    protected override async Task LoadCoreAsync()
    {
        var placement = await App.Live.GetBackgroundPlacementResultAsync();
        if (!string.IsNullOrWhiteSpace(placement.Value))
        {
            using var placementDocument = JsonDocument.Parse(placement.Value);
            var value = placementDocument.RootElement;
            PlacementAvailable = value.TryGetProperty("available", out var available) && available.ValueKind == JsonValueKind.True;
            PlacementLabel = ExtractString(value, "label") ?? PlacementLabel;
            PlacementReason = ExtractString(value, "reason") ?? "CPU placement is unavailable.";
        }
        else
        {
            PlacementAvailable = false;
            PlacementReason = placement.Error ?? "CPU topology could not be read.";
        }
        var classification = await App.Live.GetProcessClassificationAsync();
        var processes = classification?.Processes;
        if (processes is null || processes.Count == 0)
        {
            ErrorMessage = "We couldn't read your processes yet. Close and reopen to try again.";
            return;
        }

        var game = processes.FirstOrDefault(p => p.Category == "foregroundGame");
        if (game is not null)
        {
            HasGameRunning = true;
            GameStatus = Naming.FriendlyName(game.Name) + " running";
            GameStatusLevel = "safe";
        }
        else
        {
            HasGameRunning = false;
            GameStatus = "No game running";
            GameStatusLevel = "neutral";
        }

        _loadedProcesses = processes;
        BuildRows();
        var savedRecovery = App.Live.ProcessProfileRecovery;
        _lastBackupPath = savedRecovery?.Path;
        _lastBackupId = savedRecovery?.Id;
        _lastBackupGeneration = savedRecovery?.Generation;
        var wasAvailable = RestoreAvailable;
        RestoreAvailable = _lastBackupPath is not null;
        OnPropertyChanged(nameof(CanApplyProcessProfile));
        if (!App.Live.ProcessProfileRestorePending && App.Live.TakeProcessRecoverySetAsideNotice()) RecoverySetAside = true;
        if (App.Live.TakeProcessApplyRecoveredNotice() && RestoreAvailable && !ActionBusy)
        {
            ActionTitle = "Last apply didn't finish";
            ActionDetail = "Some apps may still have the changes it made. Restore puts them back.";
        }
        if (!Quiet || wasAvailable != RestoreAvailable)
            RestoreHint = App.Live.ProcessProfileApplyFinishing ? "The last apply is still finishing"
                : App.Live.ProcessProfileRestorePending ? "Restore the last change first" : "Apply creates a restore point";
        await RefreshSessionStatusesAsync();

        ApplyFilter();
        IsEmpty = _all.Count == 0;
    }

    private void BuildRows()
    {
        _all.Clear();
        foreach (var p in _loadedProcesses
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes))
        {
            var (plan, state) = PlanFor(p);
            _all.Add(new GameAppRow(
                Naming.FriendlyName(p.Name),
                Naming.CategoryLabel(p.Category),
                FriendlyPriority(p.PriorityClass) + " · Memory " + (p.MemoryPriorityAvailable ? FriendlyMemoryPriority(p.MemoryPriority) : "unavailable"),
                p.CpuPercent.ToString("0.#", CultureInfo.InvariantCulture) + "%",
                Format.Bytes(p.WorkingSetBytes),
                plan,
                state));
        }

        AppsCount = _all.Count;
        KeepCount = _all.Count(r => r.Plan == "Excluded");
        QuietCount = _all.Count(r => r.PlanState == "low");
        ApplyFilter();
    }

    [RelayCommand]
    private async Task PreviewPlanAsync()
    {
        if (!CanRunProcessAction) return;
        ActionBusy = true;
        ActionTitle = "Checking plan";
        ActionDetail = "Reading the current process list and checking what the app can safely tune.";
        try
        {
            var response = await App.Live.PreviewProcessProfileResultAsync(preset: ProcessPreset);
            if (response.Value is null || response.Error is not null)
            {
                ActionTitle = "Plan not confirmed";
                ActionDetail = response.Error ?? "The process plan returned no result.";
                return;
            }
            if (!TryProcessPreview(response.Value, out var error))
            {
                ActionTitle = "Plan not confirmed";
                ActionDetail = error;
                return;
            }
            ActionTitle = "Plan ready";
            ActionDetail = SummarizeProcessAction(response.Value, "Check is ready. Found the processes the app can tune without changing anything.");
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task ApplyProfileAsync()
    {
        if (!CanApplyProcessProfile) return;
        ActionBusy = true;
        ActionTitle = "Applying for this session";
        ActionDetail = "Applying reversible process controls to this session.";
        try
        {
            var response = await App.Live.ApplyProcessProfileResultAsync(preset: ProcessPreset);
            var recovery = response.RecoveryPath is null ? null : App.Live.ProcessProfileRecovery;
            if (recovery is not null && PathsEqual(response.RecoveryPath, recovery.Path))
            {
                _lastBackupPath = recovery.Path;
                _lastBackupId = recovery.Id;
                _lastBackupGeneration = recovery.Generation;
                RestoreAvailable = true;
                RestoreHint = "Restore the last change first";
            }
            else recovery = null;
            if (response.Value is null)
            {
                ActionTitle = "Process priorities not confirmed";
                ActionDetail = (response.Error ?? "The process apply returned no result.")
                    + (recovery is null ? string.Empty : "\nRestore puts back the apps it already changed.");
                return;
            }
            if (!TryProcessAction(response.Value, "performance.applyProfile", out var result, out var error))
            {
                ActionTitle = "Process priorities not confirmed";
                ActionDetail = error;
                return;
            }
            var changed = CountArray(result, "result", "changedItems");
            var status = ExtractString(result, "status") ?? "unknown";
            if (response.Error is not null || changed is null || ProcessOutcomeBlocked(result))
            {
                ActionTitle = "Process priorities not confirmed";
                ActionDetail = response.Error ?? ExtractIssue(result, "errors") ?? "The process action did not return consistent change evidence.";
                return;
            }
            if (status == "success" && changed == 0)
            {
                ActionTitle = "Process priorities unchanged";
                ActionDetail = SummarizeProcessAction(response.Value, "No process priorities needed changing.");
                return;
            }
            if (status == "success" && recovery is not null)
            {
                ActionTitle = "Process priorities applied";
                ActionDetail = SummarizeProcessAction(response.Value, "Applied the reviewed process controls.");
                return;
            }
            ActionTitle = "Process priorities need attention";
            ActionDetail = SummarizeProcessAction(response.Value, "The process apply was not fully confirmed.");
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task RestoreProfileAsync()
    {
        if (ActionBusy) return;
        var backup = _lastBackupPath;
        var recovery = string.IsNullOrWhiteSpace(backup) || string.IsNullOrWhiteSpace(_lastBackupId)
            ? null
            : new ProcessProfileRecovery(backup, _lastBackupId, _lastBackupGeneration);
        if (recovery is null || !recovery.Valid())
        {
            ActionTitle = "Nothing to restore";
            ActionDetail = "Apply process priorities first. Restore uses the saved original values.";
            RestoreAvailable = false;
            RestoreHint = "No saved process settings";
            return;
        }

        ActionBusy = true;
        ActionTitle = "Restoring";
        ActionDetail = "Putting changed process controls back to their previous state.";
        try
        {
            var response = await App.Live.RestoreProcessProfileResultAsync(recovery);
            if (PathsEqual(response.RecoveryPath, recovery.Path) && !string.IsNullOrWhiteSpace(response.RecoveryGeneration))
            {
                _lastBackupGeneration = response.RecoveryGeneration;
                recovery = recovery with { Generation = response.RecoveryGeneration };
            }
            if (response.Value is null || response.Error is not null)
            {
                ActionTitle = "Restore not confirmed";
                ActionDetail = response.Error ?? "The restore returned no result.";
                return;
            }
            if (!TryProcessAction(response.Value, "performance.rollbackProfile", out var result, out var error))
            {
                ActionTitle = "Restore not confirmed";
                ActionDetail = error;
                return;
            }
            ActionDetail = SummarizeProcessAction(response.Value, "The restore result needs review.");
            if (recovery.RestoreCompleted(response.Value) && response.RecoveryPath is null)
            {
                ActionTitle = "Restore complete";
                _lastBackupPath = null;
                _lastBackupId = null;
                _lastBackupGeneration = null;
                RestoreAvailable = false;
                RestoreHint = "No saved process settings";
            }
            else
            {
                ActionTitle = "Restore needs attention";
                RestoreAvailable = true;
                RestoreHint = "The reviewed backup remains available";
            }
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task CheckMatchTuneAsync()
    {
        if (ActionBusy) return;
        ActionBusy = true;
        MatchTuneStatus = "Checking game priorities";
        MatchTuneDetail = "Checking the match profile without changing process priority.";
        try
        {
            var response = await App.Live.RunGameTuneSessionResultAsync(false, 3, 1);
            if (response.Value is null || response.Error is not null
                || !SessionEnvelopeMatches(response.Value, "performance.gameTune.startSession", true))
            {
                MatchTuneStatus = "Game priority check not confirmed";
                MatchTuneDetail = response.Error ?? "The game priority check returned invalid preview evidence.";
                return;
            }
            MatchTuneStatus = "Game priorities checked";
            MatchTuneDetail = SummarizeSessionAction(response.Value, "Checked the game priority settings. Nothing changed.");
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task StartMatchTuneAsync()
    {
        if (!CanStartMatchTune)
        {
            MatchTuneStatus = "Start a game first";
            MatchTuneDetail = "The app can check the plan anytime, but game priority only applies once a foreground game is detected.";
            return;
        }

        ActionBusy = true;
        MatchTuneStatus = "Starting game priorities";
        MatchTuneDetail = "For a short match run, the app can raise the game and leave streaming apps unchanged.";
        try
        {
            var response = await App.Live.RunGameTuneSessionResultAsync(true, 12, 2);
            var observedRecovery = ReadSessionRestoreEvidence(response.Value, "gameTune");
            if (response.Value is null || response.Error is not null
                || !SessionEnvelopeMatches(response.Value, "performance.gameTune.startSession", false))
            {
                MatchTuneStatus = "Game priorities not confirmed";
                MatchTuneDetail = response.Error ?? "The game priority session returned invalid operation evidence.";
                SetMatchTuneRestore(observedRecovery ?? (_matchTuneRestore is not null && ValidateSessionRestoreEvidence(_matchTuneRestore) ? _matchTuneRestore : null));
                return;
            }
            MatchTuneStatus = SessionStatusTitle(response.Value, "Game priorities finished");
            MatchTuneDetail = SummarizeSessionAction(response.Value, "Ran the game priorities and wrote a restore point when anything changed.");
            SetMatchTuneRestore(observedRecovery);
            RestoreHint = MatchTuneRestoreAvailable ? "Session restore is available" : "No verified game-session backup";
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task RestoreMatchTuneAsync()
    {
        if (!CanRestoreMatchTune)
        {
            MatchTuneStatus = "Nothing to restore";
            MatchTuneDetail = "Run game priority first. Restore appears after the app writes a session backup.";
            MatchTuneRestoreAvailable = false;
            return;
        }

        var evidence = _matchTuneRestore;
        if (evidence is null || !ValidateSessionRestoreEvidence(evidence))
        {
            MatchTuneStatus = "Game restore unavailable";
            MatchTuneDetail = "The saved game-session backup could not be verified.";
            SetMatchTuneRestore(null);
            return;
        }

        ActionBusy = true;
        MatchTuneStatus = "Restoring game priorities";
        MatchTuneDetail = "Putting game-session process controls back.";
        try
        {
            var response = await App.Live.RestoreGameTuneSessionResultAsync(evidence.SessionId, evidence.SessionPath, evidence.BackupManifestPath);
            if (response.Value is null)
            {
                MatchTuneStatus = "Game restore not confirmed";
                MatchTuneDetail = response.Error ?? "The game restore returned no result.";
                SetMatchTuneRestore(ValidateSessionRestoreEvidence(evidence) ? evidence : null);
                return;
            }
            MatchTuneDetail = SummarizeSessionAction(response.Value, "The game restore result needs review.");
            if (response.Error is null && SessionRestoreCompleted(response.Value, evidence, "performance.gameTune.stopSession"))
            {
                MatchTuneStatus = "Game priorities restored";
                SetMatchTuneRestore(null);
            }
            else
            {
                MatchTuneStatus = "Game restore needs attention";
                SetMatchTuneRestore(ValidateSessionRestoreEvidence(evidence) ? evidence : null);
            }
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task CheckGovernorAsync()
    {
        if (!CanCheckGovernor) return;
        ActionBusy = true;
        GovernorStatus = "Checking background limits";
        GovernorDetail = "Checking background limits. No settings are being changed.";
        try
        {
            var response = await App.Live.RunProcessGovernorSessionResultAsync(false, 3, 1, 250);
            if (response.Value is null || response.Error is not null
                || !SessionEnvelopeMatches(response.Value, "performance.governor.startSession", true))
            {
                GovernorStatus = "Background limit check not confirmed";
                GovernorDetail = response.Error ?? "The background limit check returned invalid preview evidence.";
                return;
            }
            GovernorStatus = "Background limits checked";
            GovernorDetail = SummarizeSessionAction(response.Value, "Checked the background limit settings. Nothing changed.");
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task StartGovernorAsync()
    {
        if (!CanStartGovernor) return;
        ActionBusy = true;
        GovernorStatus = "Watching background load";
        GovernorDetail = "The app is watching for short CPU spikes and can restrain noisy background apps.";
        try
        {
            var response = await App.Live.RunProcessGovernorSessionResultAsync(true, 12, 2, 250);
            var observedRecovery = ReadSessionRestoreEvidence(response.Value, "governor");
            if (response.Value is null || response.Error is not null
                || !SessionEnvelopeMatches(response.Value, "performance.governor.startSession", false))
            {
                GovernorStatus = "Background limits not confirmed";
                GovernorDetail = response.Error ?? "The background limit session returned invalid operation evidence.";
                SetGovernorRestore(observedRecovery ?? (_governorRestore is not null && ValidateSessionRestoreEvidence(_governorRestore) ? _governorRestore : null));
                return;
            }
            GovernorStatus = SessionStatusTitle(response.Value, "Background limits finished");
            GovernorDetail = SummarizeSessionAction(response.Value, "Ran the background limits and restored priorities after CPU use dropped.");
            SetGovernorRestore(observedRecovery);
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task RestoreGovernorAsync()
    {
        if (!CanRestoreGovernor)
        {
            GovernorStatus = "Nothing to restore";
            GovernorDetail = "Start background limits first. Restore appears after the app writes a session backup.";
            GovernorRestoreAvailable = false;
            return;
        }

        var evidence = _governorRestore;
        if (evidence is null || !ValidateSessionRestoreEvidence(evidence))
        {
            GovernorStatus = "Background restore unavailable";
            GovernorDetail = "The saved background-session backup could not be verified.";
            SetGovernorRestore(null);
            return;
        }

        ActionBusy = true;
        GovernorStatus = "Restoring background limits";
        GovernorDetail = "Putting restrained apps back to their previous controls.";
        try
        {
            var response = await App.Live.RestoreProcessGovernorSessionResultAsync(evidence.SessionId, evidence.SessionPath, evidence.BackupManifestPath);
            if (response.Value is null)
            {
                GovernorStatus = "Background restore not confirmed";
                GovernorDetail = response.Error ?? "The background restore returned no result.";
                SetGovernorRestore(ValidateSessionRestoreEvidence(evidence) ? evidence : null);
                return;
            }
            GovernorDetail = SummarizeSessionAction(response.Value, "The background restore result needs review.");
            if (response.Error is null && SessionRestoreCompleted(response.Value, evidence, "performance.governor.stopSession"))
            {
                GovernorStatus = "Background limits restored";
                SetGovernorRestore(null);
            }
            else
            {
                GovernorStatus = "Background restore needs attention";
                SetGovernorRestore(ValidateSessionRestoreEvidence(evidence) ? evidence : null);
            }
        }
        finally
        {
            ActionBusy = false;
        }
    }

    private (string plan, string state) PlanFor(ProcessItem p)
    {
        if (p.Protected || p.Blocked || p.Protection == "protected") return ("Excluded", "neutral");
        if (ProcessPresetIndex == 1)
            return p.BackgroundPlacementEligible && PlacementAvailable ? ("Normal CPU + memory; background CPUs", "low") : ("Excluded", "neutral");
        if (p.Classification == "gameTarget") return ("Boost CPU · Memory Normal", "safe");
        if (p.Classification == "demotionCandidate") return ("Lower CPU · Memory Low", "low");
        return ("Watch", "neutral");
    }

    private static string FriendlyMemoryPriority(int? priority) => priority switch
    {
        1 => "Very low", 2 => "Low", 3 => "Medium", 4 => "Below normal", 5 => "Normal", _ => "unavailable"
    };

    partial void OnProcessPresetIndexChanged(int value)
    {
        ActionTitle = "Process priorities";
        ActionDetail = value == 1 ? "Review normal CPU, I/O and memory priorities with placement on the background CPUs. Saved rules, games and protected apps are excluded." : "Review lower CPU and memory priorities for background apps. Restore returns the saved originals.";
        BuildRows();
    }

    private static string FriendlyPriority(string? priorityClass) => priorityClass switch
    {
        "AboveNormal" => "Above normal",
        "BelowNormal" => "Below",
        "RealTime" => "Realtime",
        "High" => "High",
        "Idle" => "Idle",
        null or "" => "Normal",
        _ => priorityClass!,
    };

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

        Rows.SyncWith(source);
    }

    private async Task RefreshSessionStatusesAsync()
    {
        var game = await App.Live.GetGameTuneSessionStatusResultAsync();
        var gameValid = game.Value is not null && game.Error is null
            && SessionEnvelopeMatches(game.Value, "performance.gameTune.sessionStatus", null);
        MatchTuneStatus = gameValid ? SessionStatusTitle(game.Value, "No active game priorities") : "Game priorities unavailable";
        MatchTuneDetail = gameValid
            ? SummarizeSessionAction(game.Value, "No game priorities has changed this PC yet.")
            : game.Error ?? "The game-session status returned invalid evidence.";
        var gameRecovery = ReadSessionRestoreEvidence(game.Value, "gameTune");
        SetMatchTuneRestore(gameRecovery ?? (!gameValid && _matchTuneRestore is not null && ValidateSessionRestoreEvidence(_matchTuneRestore) ? _matchTuneRestore : null));

        var governor = await App.Live.GetProcessGovernorSessionStatusResultAsync();
        var governorValid = governor.Value is not null && governor.Error is null
            && SessionEnvelopeMatches(governor.Value, "performance.governor.sessionStatus", null);
        GovernorStatus = governorValid ? SessionStatusTitle(governor.Value, "No active background limits") : "Background limits unavailable";
        GovernorDetail = governorValid
            ? SummarizeSessionAction(governor.Value, "No background limits session has changed this PC yet.")
            : governor.Error ?? "The background-session status returned invalid evidence.";
        var governorRecovery = ReadSessionRestoreEvidence(governor.Value, "governor");
        SetGovernorRestore(governorRecovery ?? (!governorValid && _governorRestore is not null && ValidateSessionRestoreEvidence(_governorRestore) ? _governorRestore : null));
    }

    private static bool TryProcessAction(string json, string expectedAction, out JsonElement result, out string error)
    {
        result = default;
        error = "The process action response could not be read.";
        try
        {
            using var document = JsonDocument.Parse(json);
            result = document.RootElement.Clone();
            if (ExtractString(result, "actionId") != expectedAction) { error = "The process action identity did not match this request."; return false; }
            if (!TryExtractBool(result, out var dryRun, "dryRun") || dryRun)
            {
                error = "The process action did not return explicit confirmed-change evidence.";
                return false;
            }
            return true;
        }
        catch (Exception exception)
        {
            error = exception.Message;
            return false;
        }
    }

    private static bool TryProcessPreview(string json, out string error)
    {
        error = "The process plan response could not be read.";
        try
        {
            using var document = JsonDocument.Parse(json);
            var result = document.RootElement;
            if (ExtractString(result, "actionId") != "performance.previewProfile")
            {
                error = "The process plan identity did not match this request.";
                return false;
            }
            if (!TryExtractBool(result, out var dryRun, "dryRun") || !dryRun)
            {
                error = "The process plan did not return explicit preview evidence.";
                return false;
            }
            if (string.Equals(ExtractString(result, "status"), "failed", StringComparison.OrdinalIgnoreCase))
            {
                error = ExtractIssue(result, "errors") ?? "The process plan failed.";
                return false;
            }
            return true;
        }
        catch (Exception exception)
        {
            error = exception.Message;
            return false;
        }
    }

    private static bool ProcessOutcomeBlocked(JsonElement root)
    {
        var status = ExtractString(root, "status");
        if (ExtractString(root, "result", "status") != status) return true;
        return root.TryGetProperty("errors", out var errors) &&
            (errors.ValueKind != JsonValueKind.Array || errors.EnumerateArray().Any(issue => ExtractBool(issue, "blocking")));
    }

    private static string SummarizeProcessAction(string? json, string fallback)
    {
        if (string.IsNullOrWhiteSpace(json)) return fallback;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var resultSummary = ExtractString(root, "result", "summary");
            if (!string.IsNullOrWhiteSpace(resultSummary)) return resultSummary! + SummarizeControls(root);

            var status = ExtractString(root, "status");
            var previewCount = root.TryGetProperty("preview", out var preview) && preview.ValueKind == JsonValueKind.Array ? preview.GetArrayLength() : 0;
            if (previewCount > 0) return (status ?? "Ready") + ": " + previewCount.ToString(CultureInfo.InvariantCulture) + " process control item" + (previewCount == 1 ? "" : "s") + " reviewed." + SummarizeControls(root);
        }
        catch
        {
        }

        return fallback;
    }

    private static string SummarizeControls(JsonElement root)
    {
        if ((!root.TryGetProperty("preview", out var preview) || preview.ValueKind != JsonValueKind.Array) &&
            (!root.TryGetProperty("skippedItems", out preview) || preview.ValueKind != JsonValueKind.Array)) return string.Empty;
        var lines = new List<string>();
        foreach (var item in preview.EnumerateArray())
        {
            var fields = new List<string>();
            if (item.TryGetProperty("controlChanges", out var changes) && changes.ValueKind == JsonValueKind.Array)
            foreach (var change in changes.EnumerateArray())
            {
                var control = ExtractString(change, "control");
                var label = control switch { "priorityClass" => "CPU", "memoryPriority" => "Memory", "ioPriority" => "I/O", "affinityMask" => "CPUs", "gpuPriority" => "GPU", _ => control ?? "Control" };
                var current = change.TryGetProperty("currentValue", out var from) ? ControlValue(control, from) : "unavailable";
                var proposed = change.TryGetProperty("proposedValue", out var to) ? ControlValue(control, to) : "unavailable";
                var blocked = change.TryGetProperty("blocked", out var block) && block.ValueKind == JsonValueKind.True;
                fields.Add(label + " " + current + " → " + proposed + (blocked ? " (skipped: " + ExtractString(change, "blockedReason") + ")" : string.Empty));
            }
            if (fields.Count > 0) lines.Add((ExtractString(item, "processName") ?? "App") + ": " + string.Join("; ", fields));
            else if ((ExtractString(item, "classification") == "protectedCompanion" ||
                item.TryGetProperty("reasonCodes", out var codes) && codes.ValueKind == JsonValueKind.Array && codes.EnumerateArray().Any(code => code.ValueKind == JsonValueKind.String && code.GetString() == "GAME_LAUNCHER_PROTECTED")) &&
                ExtractString(item, "reason") is { Length: > 0 } reason)
                lines.Add((ExtractString(item, "processName") ?? "App") + ": " + reason);
        }
        return lines.Count == 0 ? string.Empty : "\n" + string.Join("\n", lines.Take(20)) + (lines.Count > 20 ? "\n" + (lines.Count - 20) + " more apps; see the list below." : string.Empty);
    }

    private static string ControlValue(string? control, JsonElement value)
        => control == "memoryPriority" && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var memory) ? FriendlyMemoryPriority(memory) : value.ToString();

    private static string SessionStatusTitle(string? json, string fallback)
    {
        if (string.IsNullOrWhiteSpace(json)) return fallback;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var status = ExtractString(doc.RootElement, "status") ?? ExtractString(doc.RootElement, "sessionStatus");
            return status switch
            {
                "active" or "running" => "Running now",
                "restorable" => "Restore point ready",
                "completed" => "Last run finished",
                "failed" => "Needs attention",
                "notFound" => fallback,
                "preview" => "Plan ready",
                "rolledBack" or "restored" => "Restored",
                null or "" => fallback,
                _ => status!,
            };
        }
        catch
        {
            return fallback;
        }
    }

    private static string SummarizeSessionAction(string? json, string fallback)
    {
        if (string.IsNullOrWhiteSpace(json)) return fallback;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var resultSummary = ExtractString(root, "result", "summary");
            if (!string.IsNullOrWhiteSpace(resultSummary)) return resultSummary! + SummarizeControls(root);

            var issue = ExtractIssue(root, "errors") ?? ExtractIssue(root, "warnings");
            var status = ExtractString(root, "status") ?? ExtractString(root, "sessionStatus") ?? "ready";
            if (status == "notFound")
            {
                return "No active session or restore point yet.";
            }

            var changed = ExtractInt(root, "summary", "changedItemCount") ?? CountArray(root, "changedItems") ?? CountArray(root, "result", "changedItems") ?? 0;
            var restored = ExtractInt(root, "summary", "restoredItemCount") ?? CountArray(root, "restoredItems") ?? CountArray(root, "result", "restoredItems") ?? 0;
            var skipped = ExtractInt(root, "summary", "skippedItemCount") ?? CountArray(root, "skippedItems") ?? CountArray(root, "result", "skippedItems") ?? 0;
            var polls = ExtractInt(root, "summary", "pollCount") ?? CountArray(root, "polls") ?? 0;
            if (changed > 0 || restored > 0 || skipped > 0 || polls > 0)
            {
                var label = status switch
                {
                    "preview" => "Preview",
                    "completed" => "Finished",
                    "restorable" => "Restore ready",
                    "rolledBack" or "restored" => "Restored",
                    "partial" => "Partly applied",
                    _ => char.ToUpperInvariant(status[0]) + status[1..],
                };
                return label + ": " +
                    changed.ToString(CultureInfo.InvariantCulture) + " changed, " +
                    restored.ToString(CultureInfo.InvariantCulture) + " restored, " +
                    skipped.ToString(CultureInfo.InvariantCulture) + " skipped across " +
                    polls.ToString(CultureInfo.InvariantCulture) + " checks.";
            }

            if (!string.IsNullOrWhiteSpace(issue)) return issue!;
        }
        catch
        {
        }

        return fallback;
    }

    private static string? ExtractIssue(JsonElement root, string property)
    {
        if (!root.TryGetProperty(property, out var issues) || issues.ValueKind != JsonValueKind.Array || issues.GetArrayLength() == 0)
        {
            return null;
        }

        var first = issues[0];
        return ExtractString(first, "message") ?? ExtractString(first, "nextAction") ?? first.ToString();
    }

    private void SetMatchTuneRestore(SessionRestoreEvidence? evidence)
    {
        _matchTuneRestore = evidence;
        MatchTuneRestoreAvailable = evidence is not null;
    }

    private void SetGovernorRestore(SessionRestoreEvidence? evidence)
    {
        _governorRestore = evidence;
        GovernorRestoreAvailable = evidence is not null;
    }

    private static bool SessionEnvelopeMatches(string json, string expectedAction, bool? expectedDryRun)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (ExtractString(root, "actionId") != expectedAction) return false;
            var status = ExtractString(root, "status") ?? ExtractString(root, "sessionStatus");
            if (string.IsNullOrWhiteSpace(status)) return false;
            if (status == "notFound" && expectedDryRun is null) return true;
            return TryExtractBool(root, out var dryRun, "dryRun")
                && (expectedDryRun is null || dryRun == expectedDryRun.Value);
        }
        catch
        {
            return false;
        }
    }

    private static SessionRestoreEvidence? ReadSessionRestoreEvidence(string? json, string kind)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var actionId = ExtractString(root, "actionId");
            var startAction = kind == "gameTune" ? "performance.gameTune.startSession" : "performance.governor.startSession";
            var statusAction = kind == "gameTune" ? "performance.gameTune.sessionStatus" : "performance.governor.sessionStatus";
            if (actionId != startAction && actionId != statusAction) return null;
            if (!TryExtractBool(root, out var dryRun, "dryRun") || dryRun) return null;
            if (!TryExtractBool(root, out var restorable, "restorable") || !restorable) return null;
            var sessionId = ExtractString(root, "sessionId");
            var profileId = ExtractString(root, "profileId");
            var sessionPath = ExtractString(root, "sessionPath");
            var backupPath = ExtractString(root, "backupManifestPath") ?? ExtractString(root, "backup", "location");
            if (string.IsNullOrWhiteSpace(sessionId)
                || string.IsNullOrWhiteSpace(profileId)
                || string.IsNullOrWhiteSpace(sessionPath)
                || string.IsNullOrWhiteSpace(backupPath)) return null;

            var evidence = new SessionRestoreEvidence(kind, sessionId, profileId, sessionPath, backupPath);
            return ValidateSessionRestoreEvidence(evidence) ? evidence : null;
        }
        catch
        {
            return null;
        }
    }

    private static bool ValidateSessionRestoreEvidence(SessionRestoreEvidence evidence)
    {
        if (!System.IO.File.Exists(evidence.SessionPath) || !System.IO.File.Exists(evidence.BackupManifestPath)) return false;
        try
        {
            using var sessionDoc = JsonDocument.Parse(System.IO.File.ReadAllText(evidence.SessionPath));
            var session = sessionDoc.RootElement;
            if (ExtractString(session, "sessionId") != evidence.SessionId
                || ExtractString(session, "profileId") != evidence.ProfileId
                || !TryExtractBool(session, out var sessionDryRun, "dryRun") || sessionDryRun
                || !TryExtractBool(session, out var restorable, "restorable") || !restorable
                || !PathsEqual(ExtractString(session, "backupManifestPath"), evidence.BackupManifestPath)) return false;

            using var backupDoc = JsonDocument.Parse(System.IO.File.ReadAllText(evidence.BackupManifestPath));
            var backup = backupDoc.RootElement;
            var expectedAction = evidence.Kind == "gameTune"
                ? "performance.gameTune.startSession"
                : "performance.governor.startSession";
            return ExtractString(backup, "actionId") == expectedAction
                && ExtractString(backup, "sessionId") == evidence.SessionId
                && ExtractString(backup, "profileId") == evidence.ProfileId
                && !string.IsNullOrWhiteSpace(ExtractString(backup, "backupId"))
                && TryExtractBool(backup, out var backupDryRun, "dryRun")
                && !backupDryRun
                && CountArray(backup, "snapshots") is > 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool SessionRestoreCompleted(string json, SessionRestoreEvidence evidence, string expectedAction)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var resultStatus = ExtractString(root, "result", "status") ?? ExtractString(root, "status");
            return ExtractString(root, "actionId") == expectedAction
                && ExtractString(root, "sessionId") == evidence.SessionId
                && PathsEqual(ExtractString(root, "sessionPath"), evidence.SessionPath)
                && PathsEqual(ExtractString(root, "backupManifestPath"), evidence.BackupManifestPath)
                && TryExtractBool(root, out var dryRun, "dryRun")
                && !dryRun
                && resultStatus is "rolledBack" or "restored";
        }
        catch
        {
            return false;
        }
    }

    private static bool PathsEqual(string? left, string right)
    {
        if (string.IsNullOrWhiteSpace(left)) return false;
        try
        {
            return string.Equals(System.IO.Path.GetFullPath(left), System.IO.Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static int? ExtractInt(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return null;
            }
        }

        if (current.ValueKind == JsonValueKind.Number && current.TryGetInt32(out var value)) return value;
        if (current.ValueKind == JsonValueKind.String && int.TryParse(current.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value)) return value;
        return null;
    }

    private static int? CountArray(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return null;
            }
        }

        return current.ValueKind == JsonValueKind.Array ? current.GetArrayLength() : null;
    }

    private static bool ExtractBool(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current)) return false;
        }
        return current.ValueKind == JsonValueKind.True || current.ValueKind == JsonValueKind.String && bool.TryParse(current.GetString(), out var value) && value;
    }

    private static bool TryExtractBool(JsonElement root, out bool value, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                value = false;
                return false;
            }
        }

        if (current.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            value = current.GetBoolean();
            return true;
        }
        if (current.ValueKind == JsonValueKind.String && bool.TryParse(current.GetString(), out value)) return true;
        value = false;
        return false;
    }

    private static string? ExtractString(string? json, params string[] path)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            return ExtractString(doc.RootElement, path);
        }
        catch
        {
            return null;
        }
    }

    private static string? ExtractString(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return null;
            }
        }

        return current.ValueKind == JsonValueKind.String ? current.GetString() : current.ToString();
    }
}
