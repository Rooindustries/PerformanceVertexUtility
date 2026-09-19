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
        "Give the game room first. Leave stream apps steady. Push launchers and browser helpers back.";
    [ObservableProperty] private int _appsCount;
    [ObservableProperty] private int _keepCount;
    [ObservableProperty] private int _quietCount;
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private string _actionTitle = "Ready to tune";
    [ObservableProperty] private string _actionDetail = "Check shows the live plan. Apply changes the current session. Restore puts changed processes back.";
    [ObservableProperty] private string _restoreHint = "No restore point yet";
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
    [ObservableProperty] private string _matchTuneStatus = "No match tune checked yet";
    [ObservableProperty] private string _matchTuneDetail =
        "Raises the game CPU priority, leaves OBS and Discord steady, and pushes launchers or browser helpers back.";
    [ObservableProperty] private string _governorStatus = "Background guard not checked yet";
    [ObservableProperty] private string _governorDetail =
        "Watches for background CPU spikes and lowers priority or I/O until the app calms down.";
    [NotifyPropertyChangedFor(nameof(CanRestoreMatchTune))]
    [ObservableProperty] private bool _matchTuneRestoreAvailable;
    [NotifyPropertyChangedFor(nameof(CanRestoreGovernor))]
    [ObservableProperty] private bool _governorRestoreAvailable;

    private string? _lastBackupPath;

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
        KeepCount = _all.Count(r => r.Plan == "Keep steady");
        QuietCount = _all.Count(r => r.Plan == "Quiet");
        RestoreAvailable = App.Live.FindLatestProcessProfileBackup() is not null;
        RestoreHint = RestoreAvailable ? "Restore is available from the latest apply" : "Apply creates a restore point";
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
            var json = await App.Live.PreviewProcessProfileTextAsync();
            ActionTitle = "Plan ready";
            ActionDetail = SummarizeProcessAction(json, "Check is ready. Roo Industries found the processes it can tune without changing anything.");
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
            var json = await App.Live.ApplyProcessProfileTextAsync();
            _lastBackupPath = ExtractString(json, "backup", "location") ?? App.Live.FindLatestProcessProfileBackup();
            RestoreAvailable = _lastBackupPath is not null || App.Live.FindLatestProcessProfileBackup() is not null;
            RestoreHint = RestoreAvailable ? "Restore is ready" : "No process needed a restore point";
            ActionTitle = "Session tune applied";
            ActionDetail = SummarizeProcessAction(json, "Roo Industries applied the process controls it could safely change.");
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
        var backup = _lastBackupPath ?? App.Live.FindLatestProcessProfileBackup();
        if (string.IsNullOrWhiteSpace(backup))
        {
            ActionTitle = "Nothing to restore";
            ActionDetail = "Apply a session tune first. Roo Industries restores from the backup it writes before changing process controls.";
            RestoreAvailable = false;
            RestoreHint = "No restore point yet";
            return;
        }

        ActionBusy = true;
        ActionTitle = "Restoring";
        ActionDetail = "Roo Industries is putting changed process controls back to their previous state.";
        try
        {
            var json = await App.Live.RestoreProcessProfileTextAsync(backup);
            ActionTitle = "Restore complete";
            ActionDetail = SummarizeProcessAction(json, "Roo Industries restored the live process controls from the latest backup.");
            RestoreAvailable = App.Live.FindLatestProcessProfileBackup() is not null;
            RestoreHint = RestoreAvailable ? "Latest backup remains available" : "No restore point yet";
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
        MatchTuneStatus = "Checking match tune";
        MatchTuneDetail = "Roo Industries is checking the match profile without changing process priority.";
        try
        {
            var json = await App.Live.RunGameTuneSessionTextAsync(false, 3, 1);
            MatchTuneStatus = "Match tune checked";
            MatchTuneDetail = SummarizeSessionAction(json, "Roo Industries checked the match tune path. Nothing changed.");
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
        MatchTuneStatus = "Starting match tune";
        MatchTuneDetail = "For a short match run, Roo Industries can raise the game and keep stream apps steady.";
        try
        {
            var json = await App.Live.RunGameTuneSessionTextAsync(true, 12, 2);
            MatchTuneStatus = "Match tune finished";
            MatchTuneDetail = SummarizeSessionAction(json, "Roo Industries ran the match tune and wrote a restore point when anything changed.");
            MatchTuneRestoreAvailable = SessionCanRestore(json);
            RestoreHint = "Session restore is available if Roo Industries changed anything";
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

        ActionBusy = true;
        MatchTuneStatus = "Restoring match tune";
        MatchTuneDetail = "Roo Industries is putting game-session process controls back.";
        try
        {
            var json = await App.Live.RestoreGameTuneSessionTextAsync();
            MatchTuneStatus = "Match tune restore checked";
            MatchTuneDetail = SummarizeSessionAction(json, "Roo Industries checked the match-tune restore path.");
            MatchTuneRestoreAvailable = SessionCanRestore(json);
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
        GovernorStatus = "Checking background guard";
        GovernorDetail = "Roo Industries is checking the ProBalance guard without restraining anything.";
        try
        {
            var json = await App.Live.RunProcessGovernorSessionTextAsync(false, 3, 1, 250);
            GovernorStatus = "Background guard checked";
            GovernorDetail = SummarizeSessionAction(json, "Roo Industries checked the background guard path. Nothing changed.");
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
            var json = await App.Live.RunProcessGovernorSessionTextAsync(true, 12, 2, 250);
            GovernorStatus = "Background guard finished";
            GovernorDetail = SummarizeSessionAction(json, "Roo Industries ran the background guard and restored calm apps when needed.");
            GovernorRestoreAvailable = SessionCanRestore(json);
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
            GovernorDetail = "Run the ProBalance guard first. Restore appears after Roo Industries writes a session backup.";
            GovernorRestoreAvailable = false;
            return;
        }

        ActionBusy = true;
        GovernorStatus = "Restoring background guard";
        GovernorDetail = "Roo Industries is putting restrained apps back to their previous controls.";
        try
        {
            var json = await App.Live.RestoreProcessGovernorSessionTextAsync();
            GovernorStatus = "Background guard restore checked";
            GovernorDetail = SummarizeSessionAction(json, "Roo Industries checked the background-guard restore path.");
            GovernorRestoreAvailable = SessionCanRestore(json);
        }
        finally
        {
            ActionBusy = false;
        }
    }

    private static (string plan, string state) PlanFor(ProcessItem p)
    {
        if (p.Category == "foregroundGame") return ("Boost", "safe");
        if (p.Protection == "protected") return ("Keep steady", "neutral");
        if (QuietCategories.Contains(p.Category)) return ("Quiet", "low");
        return ("Watch", "neutral");
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
        var game = await App.Live.GetGameTuneSessionStatusTextAsync();
        MatchTuneStatus = SessionStatusTitle(game, "No active match tune");
        MatchTuneDetail = SummarizeSessionAction(game, "No match tune has changed this PC yet.");
        MatchTuneRestoreAvailable = SessionCanRestore(game);

        var governor = await App.Live.GetProcessGovernorSessionStatusTextAsync();
        GovernorStatus = SessionStatusTitle(governor, "No active background guard");
        GovernorDetail = SummarizeSessionAction(governor, "No background guard session has changed this PC yet.");
        GovernorRestoreAvailable = SessionCanRestore(governor);
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

    private static bool SessionCanRestore(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var status = ExtractString(root, "status") ?? ExtractString(root, "sessionStatus");
            if (status is "restorable" or "active" or "running") return true;
            if (ExtractInt(root, "summary", "changedItemCount") is > 0) return true;
            if (CountArray(root, "changedItems") is > 0) return true;
            if (CountArray(root, "result", "changedItems") is > 0) return true;
            return !string.IsNullOrWhiteSpace(ExtractString(root, "backup", "location")) ||
                   !string.IsNullOrWhiteSpace(ExtractString(root, "backupPath")) ||
                   !string.IsNullOrWhiteSpace(ExtractString(root, "rollback", "rollbackManifestPath"));
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
