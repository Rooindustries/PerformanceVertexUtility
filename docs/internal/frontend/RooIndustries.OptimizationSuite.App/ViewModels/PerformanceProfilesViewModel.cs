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

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class PerformanceProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string _gameStatus = "No game running";
    [ObservableProperty] private string _gameStatusLevel = "neutral";
    [ObservableProperty] private string _ruleSummary =
        "Review priorities for games, launchers, and background apps.";
    [ObservableProperty] private int _appsCount;
    [ObservableProperty] private int _keepCount;
    [ObservableProperty] private int _quietCount;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private string _actionTitle = "Process priorities";
    [ObservableProperty] private string _actionDetail = "Review the selected priorities, then apply them. Restore returns changed processes to their saved settings.";
    [ObservableProperty] private string _restoreHint = "No saved process settings";
    [NotifyPropertyChangedFor(nameof(CanRunProcessAction))]
    [NotifyPropertyChangedFor(nameof(CanRestoreProfile))]
    [NotifyPropertyChangedFor(nameof(CanCheckMatchTune))]
    [NotifyPropertyChangedFor(nameof(CanStartMatchTune))]
    [NotifyPropertyChangedFor(nameof(CanRestoreMatchTune))]
    [NotifyPropertyChangedFor(nameof(CanCheckGovernor))]
    [NotifyPropertyChangedFor(nameof(CanStartGovernor))]
    [NotifyPropertyChangedFor(nameof(CanRestoreGovernor))]
    [ObservableProperty] private bool _actionBusy;
    [NotifyPropertyChangedFor(nameof(CanRestoreProfile))]
    [ObservableProperty] private bool _restoreAvailable;
    [NotifyPropertyChangedFor(nameof(CanStartMatchTune))]
    [ObservableProperty] private bool _hasGameRunning;
    [ObservableProperty] private string _matchTuneStatus = "No game priorities checked yet";
    [ObservableProperty] private string _matchTuneDetail =
        "Raises the game CPU priority, leaves OBS and Discord unchanged, and lowers the priority of launchers and browser helpers.";
    [ObservableProperty] private string _governorStatus = "Background limits not checked yet";
    [ObservableProperty] private string _governorDetail =
        "Watches for background CPU spikes and lowers priority or I/O until CPU use drops.";
    [NotifyPropertyChangedFor(nameof(CanRestoreMatchTune))]
    [ObservableProperty] private bool _matchTuneRestoreAvailable;
    [NotifyPropertyChangedFor(nameof(CanRestoreGovernor))]
    [ObservableProperty] private bool _governorRestoreAvailable;

    private string? _lastBackupPath;
    private SessionRestoreEvidence? _matchTuneRestore;
    private SessionRestoreEvidence? _governorRestore;

    private sealed record SessionRestoreEvidence(
        string Kind,
        string SessionId,
        string ProfileId,
        string SessionPath,
        string BackupManifestPath);

    private readonly List<GameAppRow> _all = new();
    public ObservableCollection<GameAppRow> Rows { get; } = new();
    public bool CanRunProcessAction => !ActionBusy;
    public bool CanRestoreProfile => !ActionBusy && RestoreAvailable;
    public bool CanCheckMatchTune => !ActionBusy;
    public bool CanStartMatchTune => !ActionBusy && HasGameRunning;
    public bool CanRestoreMatchTune => !ActionBusy && MatchTuneRestoreAvailable;
    public bool CanCheckGovernor => !ActionBusy;
    public bool CanStartGovernor => !ActionBusy;
    public bool CanRestoreGovernor => !ActionBusy && GovernorRestoreAvailable;

    private static readonly string[] QuietCategories = { "browserWebView", "launcher", "vendorUtility", "backgroundApp" };

    protected override async Task LoadCoreAsync()
    {
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

        _all.Clear();
        foreach (var p in processes
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes))
        {
            var (plan, state) = PlanFor(p);
            _all.Add(new GameAppRow(
                Naming.FriendlyName(p.Name),
                Naming.CategoryLabel(p.Category),
                FriendlyPriority(p.PriorityClass),
                p.CpuPercent.ToString("0.#", CultureInfo.InvariantCulture) + "%",
                Format.Bytes(p.WorkingSetBytes),
                plan,
                state));
        }

        AppsCount = _all.Count;
        KeepCount = _all.Count(r => r.Plan == "Excluded");
        QuietCount = _all.Count(r => r.Plan == "Lower priority");
        _lastBackupPath = null;
        RestoreAvailable = false;
        RestoreHint = "Apply creates a restore point";
        await RefreshSessionStatusesAsync();

        ApplyFilter();
        IsEmpty = _all.Count == 0;
    }

    [RelayCommand]
    private async Task PreviewPlanAsync()
    {
        if (!CanRunProcessAction) return;
        ActionBusy = true;
        ActionTitle = "Checking plan";
        ActionDetail = "Reading the current process list and checking what Roo Industries can safely tune.";
        try
        {
            var response = await App.Live.PreviewProcessProfileResultAsync();
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
            ActionDetail = SummarizeProcessAction(response.Value, "Check is ready. Roo Industries found the processes it can tune without changing anything.");
        }
        finally
        {
            ActionBusy = false;
        }
    }

    [RelayCommand]
    private async Task ApplyProfileAsync()
    {
        if (!CanRunProcessAction) return;
        ActionBusy = true;
        ActionTitle = "Applying for this session";
        ActionDetail = "Roo Industries is applying reversible process controls to this session.";
        try
        {
            var response = await App.Live.ApplyProcessProfileResultAsync();
            if (response.Value is null)
            {
                ActionTitle = "Process priorities not confirmed";
                ActionDetail = response.Error ?? "The process apply returned no result.";
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
            var backup = VerifiedBackup(result);
            if (backup is not null)
            {
                _lastBackupPath = backup;
                RestoreAvailable = true;
                RestoreHint = "Restore is ready";
            }
            if (response.Error is not null || changed is null)
            {
                ActionTitle = "Process priorities not confirmed";
                ActionDetail = response.Error ?? "The process action did not report which items changed.";
                return;
            }
            if (status == "success" && changed == 0)
            {
                ActionTitle = "Process priorities unchanged";
                ActionDetail = SummarizeProcessAction(response.Value, "No process priorities needed changing.");
                return;
            }
            if (status == "success" && backup is not null)
            {
                ActionTitle = "Process priorities applied";
                ActionDetail = SummarizeProcessAction(response.Value, "Roo Industries applied the reviewed process controls.");
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
        if (string.IsNullOrWhiteSpace(backup))
        {
            ActionTitle = "Nothing to restore";
            ActionDetail = "Apply process priorities first. Restore uses the saved original values.";
            RestoreAvailable = false;
            RestoreHint = "No saved process settings";
            return;
        }

        ActionBusy = true;
        ActionTitle = "Restoring";
        ActionDetail = "Roo Industries is putting changed process controls back to their previous state.";
        try
        {
            var response = await App.Live.RestoreProcessProfileResultAsync(backup);
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
            var status = ExtractString(result, "status") ?? "unknown";
            ActionDetail = SummarizeProcessAction(response.Value, "The restore result needs review.");
            if (status == "success")
            {
                ActionTitle = "Restore complete";
                _lastBackupPath = null;
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
        MatchTuneDetail = "Roo Industries is checking the match profile without changing process priority.";
        try
        {
            var response = await App.Live.RunGameTuneSessionResultAsync(false, 3, 1);
            if (response.Value is null)
            {
                MatchTuneStatus = "Game priority check not confirmed";
                MatchTuneDetail = response.Error ?? "The game priority check returned no result.";
                return;
            }
            MatchTuneStatus = "Game priorities checked";
            MatchTuneDetail = SummarizeSessionAction(response.Value, "Roo Industries checked the game priority settings. Nothing changed.");
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
            MatchTuneDetail = "Roo Industries can check the plan anytime, but game priority only applies once a foreground game is detected.";
            return;
        }

        ActionBusy = true;
        MatchTuneStatus = "Starting game priorities";
        MatchTuneDetail = "For a short match run, Roo Industries can raise the game and leave streaming apps unchanged.";
        try
        {
            var response = await App.Live.RunGameTuneSessionResultAsync(true, 12, 2);
            if (response.Value is null)
            {
                MatchTuneStatus = "Game priorities not confirmed";
                MatchTuneDetail = response.Error ?? "The game priority session returned no result.";
                SetMatchTuneRestore(_matchTuneRestore is not null && ValidateSessionRestoreEvidence(_matchTuneRestore) ? _matchTuneRestore : null);
                return;
            }
            MatchTuneStatus = SessionStatusTitle(response.Value, "Game priorities finished");
            MatchTuneDetail = SummarizeSessionAction(response.Value, "Roo Industries ran the game priorities and wrote a restore point when anything changed.");
            SetMatchTuneRestore(ReadSessionRestoreEvidence(response.Value, "gameTune"));
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
            MatchTuneDetail = "Run game priority first. Restore appears after Roo Industries writes a session backup.";
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
        MatchTuneDetail = "Roo Industries is putting game-session process controls back.";
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
            if (response.Value is null)
            {
                GovernorStatus = "Background limit check not confirmed";
                GovernorDetail = response.Error ?? "The background limit check returned no result.";
                return;
            }
            GovernorStatus = "Background limits checked";
            GovernorDetail = SummarizeSessionAction(response.Value, "Roo Industries checked the background limit settings. Nothing changed.");
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
        GovernorDetail = "Roo Industries is watching for short CPU spikes and can restrain noisy background apps.";
        try
        {
            var response = await App.Live.RunProcessGovernorSessionResultAsync(true, 12, 2, 250);
            if (response.Value is null)
            {
                GovernorStatus = "Background limits not confirmed";
                GovernorDetail = response.Error ?? "The background limit session returned no result.";
                SetGovernorRestore(_governorRestore is not null && ValidateSessionRestoreEvidence(_governorRestore) ? _governorRestore : null);
                return;
            }
            GovernorStatus = SessionStatusTitle(response.Value, "Background limits finished");
            GovernorDetail = SummarizeSessionAction(response.Value, "Roo Industries ran the background limits and restored priorities after CPU use dropped.");
            SetGovernorRestore(ReadSessionRestoreEvidence(response.Value, "governor"));
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
            GovernorDetail = "Start background limits first. Restore appears after Roo Industries writes a session backup.";
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
        GovernorDetail = "Roo Industries is putting restrained apps back to their previous controls.";
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

    private static (string plan, string state) PlanFor(ProcessItem p)
    {
        if (p.Category == "foregroundGame") return ("Boost", "safe");
        if (p.Protection == "protected") return ("Excluded", "neutral");
        if (QuietCategories.Contains(p.Category)) return ("Lower priority", "low");
        return ("Watch", "neutral");
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

        Rows.Clear();
        foreach (var r in source)
        {
            Rows.Add(r);
        }
    }

    private async Task RefreshSessionStatusesAsync()
    {
        var game = await App.Live.GetGameTuneSessionStatusResultAsync();
        MatchTuneStatus = game.Value is null ? "Game priorities unavailable" : SessionStatusTitle(game.Value, "No active game priorities");
        MatchTuneDetail = game.Value is null
            ? game.Error ?? "The game-session status returned no result."
            : SummarizeSessionAction(game.Value, "No game priorities has changed this PC yet.");
        SetMatchTuneRestore(ReadSessionRestoreEvidence(game.Value, "gameTune"));

        var governor = await App.Live.GetProcessGovernorSessionStatusResultAsync();
        GovernorStatus = governor.Value is null ? "Background limits unavailable" : SessionStatusTitle(governor.Value, "No active background limits");
        GovernorDetail = governor.Value is null
            ? governor.Error ?? "The background-session status returned no result."
            : SummarizeSessionAction(governor.Value, "No background limits session has changed this PC yet.");
        SetGovernorRestore(ReadSessionRestoreEvidence(governor.Value, "governor"));
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

    private static string? VerifiedBackup(JsonElement result)
    {
        var path = ExtractString(result, "backup", "location");
        return ExtractBool(result, "backup", "rollbackSupported") && !string.IsNullOrWhiteSpace(path) && System.IO.File.Exists(path) ? path : null;
    }

    private static string SummarizeProcessAction(string? json, string fallback)
    {
        if (string.IsNullOrWhiteSpace(json)) return fallback;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var resultSummary = ExtractString(root, "result", "summary");
            if (!string.IsNullOrWhiteSpace(resultSummary)) return resultSummary!;

            var status = ExtractString(root, "status");
            var previewCount = root.TryGetProperty("preview", out var preview) && preview.ValueKind == JsonValueKind.Array ? preview.GetArrayLength() : 0;
            if (previewCount > 0) return (status ?? "Ready") + ": " + previewCount.ToString(CultureInfo.InvariantCulture) + " process control item" + (previewCount == 1 ? "" : "s") + " reviewed.";
        }
        catch
        {
        }

        return fallback;
    }

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
            if (!string.IsNullOrWhiteSpace(resultSummary)) return resultSummary!;

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
