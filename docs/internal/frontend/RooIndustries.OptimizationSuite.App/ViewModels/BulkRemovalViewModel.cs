using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;
using System.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class RemovalRow : ObservableObject
{
    public BulkRemovalEntry Entry { get; }
    [ObservableProperty] private string _state = "Ready for review";
    public RemovalRow(BulkRemovalEntry entry) { Entry = entry; }
}

public partial class LeftoverChoice : ObservableObject
{
    public LeftoverCandidate Item { get; }
    public RemovedAppChoice Application { get; }
    [ObservableProperty] private bool _selected;
    public bool CanSelect => !Item.Protected && Item.Exists == true && Item.OwnershipComplete && Item.SharedOwners.Count == 0 && Item.Error is null;
    public string Evidence => Application.Name + " · " + Item.Kind + (Item.Registry is null ? "" : " · " + Item.Registry.View) + "\n" +
        string.Join("; ", Item.Evidence) + (Item.SharedOwners.Count == 0 ? "" : "\nShared with: " + string.Join(", ", Item.SharedOwners)) +
        (Item.OwnershipComplete ? "" : "\nSubtree ownership could not be fully inspected.") + (Item.Protected ? "\nProtected location." : "");
    public LeftoverChoice(LeftoverCandidate item, RemovedAppChoice application) { Item = item; Application = application; }
}

public sealed record RemovedAppChoice(string Id, string Name, string JournalPath)
{
    public override string ToString() => Name;
}

public sealed record CleanupHistoryChoice(CleanupBatchSession Session)
{
    public bool CanRestore => CleanupBatch.HasRestorableEntries(Session.State);
    public override string ToString() => Session.State.UpdatedAtUtc.ToLocalTime().ToString("g") + " · " + Session.Review.Plan.Parts.Length + " apps · " + StatusLabel(Session.State.Status);
    public static string StatusLabel(string status) => status switch
    {
        "applied" => "Cleaned", "restored" => "Restored", "pending" => "Not started", "running" or "applying" => "Cleaning",
        "restoring" => "Restoring", "stopped" => "Stopped", "prepared" => "Reviewed", "needsReconciliation" => "Needs review", _ => "Unknown state",
    };
}

public partial class BulkRemovalViewModel : ObservableObject
{
    private string? _suggestedGroup;
    public bool HasGroupFilter => _suggestedGroup is not null;
    public string GroupFilterLabel => _suggestedGroup switch { "widgets" => "Windows Widgets", "copilot" => "Copilot and Office Hub", "edge" => "Microsoft Edge", "onedrive" => "Microsoft OneDrive", _ => "" };
    private readonly List<InstalledApp> _all = new();
    private readonly List<InstalledApp> _selected = new();
    private BulkRemovalReview? _review;
    private string _phase = "selection";
    private bool _journalObserved;
    private bool _removalRunning;
    private bool _cancelRequested;
    private bool _refreshingRemovedApps;
    private CleanupBatchReview? _fileReview;
    private RemovalCleanupReview? _restoreReview;
    private CleanupBatchJournal? _batchState;
    private bool _cleanupRunning;
    private bool _cleanupObserved;
    private CancellationTokenSource? _scanCancellation;
    private int _fileSelectionVersion;
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<RemovalRow> ReviewRows { get; } = new();
    public ObservableCollection<RemovedAppChoice> RemovedApps { get; } = new();
    public ObservableCollection<LeftoverChoice> Leftovers { get; } = new();
    public ObservableCollection<CleanupHistoryChoice> CleanupHistory { get; } = new();
    [ObservableProperty] private CleanupHistoryChoice? _selectedCleanupHistory;
    [ObservableProperty] private bool _scanAllApps;
    [ObservableProperty] private bool _acceptKeyRecreation;
    [ObservableProperty] private string _cleanupApplyLabel = "Delete reviewed leftovers";
    [ObservableProperty] private RemovedAppChoice? _selectedRemovedApp;
    [ObservableProperty] private bool _hasRemovedApps;
    [ObservableProperty] private bool _fileReviewReady;
    [ObservableProperty] private bool _filesReviewed;
    [ObservableProperty] private bool _fileRestoreAvailable;
    [ObservableProperty] private string _fileStatus = "Scan an app after its removal has completed.";
    [ObservableProperty] private string _fileSummary = "";
    [ObservableProperty] private string _searchText = "";
    [ObservableProperty] private int _installedAppCount;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _dependenciesReviewed;
    [ObservableProperty] private bool _requiresDependencyReview;
    [ObservableProperty] private bool _hasProtectedSelection;
    [ObservableProperty] private string _selectionSummary = "Select applications to remove.";
    [ObservableProperty] private string _status = "Nothing selected.";
    [ObservableProperty] private bool _includeAllAppxUsers;
    [ObservableProperty] private string _detail = "Preview the exact removal commands before running them.";
    [ObservableProperty] private string _applyLabel = "Remove selected apps";
    public bool CanSelect => !Busy && _phase is not ("running" or "canceled" or "needs-reconciliation" or "reboot-required" or "ready");
    public bool NoMatches => !Busy && Apps.Count == 0;
    public bool CanPreview => CanSelect && _selected.Count > 0;
    public bool CanApply => !Busy && _review is not null && (_phase is "preview" or "canceled" or "ready") && !HasProtectedSelection && (!RequiresDependencyReview || DependenciesReviewed);
    public bool CanCancel => _removalRunning && _journalObserved;
    public bool CanReconcile => !Busy && _review is not null && (_phase is "running" or "needs-reconciliation" or "reboot-required");
    public bool CanStartOver => !Busy && !_removalRunning && _review is not null && (_phase is "running" or "canceled" or "needs-reconciliation" or "reboot-required" or "ready");
    public bool CanScanFiles => !Busy && (ScanAllApps ? RemovedApps.Count > 0 : SelectedRemovedApp is not null);
    public bool CanPreviewFiles => !Busy && Leftovers.Any(item => item.Selected && item.CanSelect) && (!HasSelectedKeys || AcceptKeyRecreation);
    public bool CanApplyFiles => !Busy && FileReviewReady && FilesReviewed;
    public bool CanRestoreFiles => !Busy && SelectedCleanupHistory?.CanRestore == true;
    public bool CanRestoreLegacyFiles => !Busy && FileRestoreAvailable;
    public bool CanCancelCleanup => _cleanupRunning && _cleanupObserved;
    public bool CanCancelScan => _scanCancellation is not null;
    public bool HasSelectedKeys => Leftovers.Any(item => item.Selected && item.Item.Kind == "registryKey");
    public bool HasCleanupHistory => CleanupHistory.Count > 0;
    partial void OnBusyChanged(bool value) => RefreshCommands();
    partial void OnDependenciesReviewedChanged(bool value) => RefreshCommands();
    partial void OnSearchTextChanged(string value) { _suggestedGroup = null; Filter(); }
    partial void OnIncludeAllAppxUsersChanged(bool value) { if (!Busy) _ = RefreshAsync(); }
    partial void OnSelectedRemovedAppChanged(RemovedAppChoice? value) { _fileSelectionVersion++; Leftovers.Clear(); _fileReview = null; FileReviewReady = false; FilesReviewed = false; FileStatus = "Scan this application's current leftovers."; FileSummary = ""; RefreshCommands(); }
    partial void OnFilesReviewedChanged(bool value) => RefreshCommands();
    partial void OnFileReviewReadyChanged(bool value) => RefreshCommands();
    partial void OnFileRestoreAvailableChanged(bool value) => RefreshCommands();
    partial void OnScanAllAppsChanged(bool value) { _fileSelectionVersion++; Leftovers.Clear(); InvalidateCleanup(); RefreshCommands(); }
    partial void OnAcceptKeyRecreationChanged(bool value) { InvalidateCleanup(); RefreshCommands(); }
    partial void OnSelectedCleanupHistoryChanged(CleanupHistoryChoice? value)
    {
        if (value is not null && !_cleanupRunning)
        {
            _fileReview = value.Session.Review;
            UpdateCleanupProgress(value.Session.State);
            FilesReviewed = false;
        }
        RefreshCommands();
    }

    public async Task InitializeAsync()
    {
        await RefreshAsync();
        try
        {
            var saved = await App.Operations.ReadLastRemovalAsync();
            if (saved is not null)
            {
                _review = saved.Review;
                SetReview(saved.Review);
                UpdateProgress(saved.State);
            }
            foreach (var history in await App.Operations.ReadRemovalHistoryAsync()) RememberRemovedApps(history.State, history.Path);
            await RefreshCleanupHistoryAsync();
            _restoreReview = await App.Operations.ReadLastFileCleanupAsync();
            FileRestoreAvailable = _restoreReview is not null && System.IO.File.Exists(_restoreReview.Plan.RollbackPath);
            if (FileRestoreAvailable && !HasCleanupHistory) { FileStatus = "File recovery is available for " + _restoreReview!.Plan.DisplayName; FileSummary = "Restore earlier file backup recovers the saved files; it does not reinstall the app."; }
        }
        catch (Exception error) { Status = "Couldn't read saved removal state."; Detail = error.Message; }
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (Busy) return;
        if (CanSelect) SetSelection(Array.Empty<InstalledApp>());
        Busy = true;
        try { await LoadAppsAsync(); }
        catch (Exception error) { Status = "Couldn't refresh installed apps."; Detail = error.Message; }
        finally { Busy = false; }
    }
    public async Task RefreshIfIdleAsync()
    {
        if (Busy || _selected.Count > 0 || _review is not null || !CanSelect || Environment.TickCount64 - _appsLoadedTicks < 30000) return;
        Busy = true;
        try { await LoadAppsAsync(); }
        catch (Exception error) { Status = "Couldn't refresh installed apps."; Detail = error.Message; }
        finally { Busy = false; }
    }
    private bool _appsLoaded;
    private long _appsLoadedTicks;
    private async Task LoadAppsAsync()
    {
        var inventory = await App.Live.GetInstalledAppsAsync(includeAllAppxUsers: IncludeAllAppxUsers, fresh: _appsLoaded);
        _appsLoaded = true; _appsLoadedTicks = Environment.TickCount64;
        if (inventory?.Apps is null) throw new InvalidOperationException(App.Live.LastError ?? "Installed applications could not be read.");
        _all.Clear();
        _all.AddRange(inventory.Apps.Where(app => app.IsListable || app.SourceType == "appx" && !app.Protected).OrderBy(app => app.FriendlyName, StringComparer.OrdinalIgnoreCase));
        InstalledAppCount = _all.Count;
        Filter();
        if (inventory.Complete == false) { Status = "Some app registrations could not be read."; Detail = string.Join("\n", inventory.Errors ?? new()); }
    }

    public void ShowGroup(string group)
    {
        SearchText = ""; _suggestedGroup = group; Filter();
        Status = group switch { "widgets" => "Windows Widgets packages", "copilot" => "Copilot and Office Hub apps", "edge" => "Microsoft Edge", "onedrive" => "Microsoft OneDrive", _ => "Choose installed apps" };
        Detail = "Type in Search to show other apps. Review removal and leftover files separately. Protected Windows packages remain protected.";
    }
    private bool MatchesGroup(InstalledApp app)
    {
        var package = app.PackageId ?? app.DisplayName ?? "";
        if (_suggestedGroup == "copilot" && app.FriendlyName.StartsWith("Copilot CLI", StringComparison.OrdinalIgnoreCase)) return false;
        return _suggestedGroup switch
        {
            "widgets" => package.StartsWith("Microsoft.WidgetsPlatformRuntime", StringComparison.OrdinalIgnoreCase) || package.StartsWith("MicrosoftWindows.Client.WebExperience", StringComparison.OrdinalIgnoreCase),
            "copilot" => package.StartsWith("Microsoft.Copilot", StringComparison.OrdinalIgnoreCase) || package.StartsWith("Microsoft.Windows.Ai.Copilot", StringComparison.OrdinalIgnoreCase) || package.StartsWith("MicrosoftWindows.Client.CoreAI", StringComparison.OrdinalIgnoreCase) || package.StartsWith("Microsoft.MicrosoftOfficeHub", StringComparison.OrdinalIgnoreCase) || app.FriendlyName.Equals("Microsoft Copilot", StringComparison.OrdinalIgnoreCase),
            "edge" => app.FriendlyName.Equals("Microsoft Edge", StringComparison.OrdinalIgnoreCase),
            "onedrive" => app.FriendlyName.Equals("Microsoft OneDrive", StringComparison.OrdinalIgnoreCase),
            _ => true,
        };
    }
    private void Filter()
    {
        Apps.Clear();
        foreach (var app in _all.Where(app => MatchesGroup(app) && (string.IsNullOrWhiteSpace(SearchText) || app.FriendlyName.Contains(SearchText, StringComparison.OrdinalIgnoreCase)))) Apps.Add(app);
        OnPropertyChanged(nameof(NoMatches));
        OnPropertyChanged(nameof(HasGroupFilter));
        OnPropertyChanged(nameof(GroupFilterLabel));
    }
    [RelayCommand]
    private void ClearGroupFilter() { _suggestedGroup = null; Filter(); }

    public void SetSelection(IEnumerable<InstalledApp> selected)
    {
        if (!CanSelect || _refreshingRemovedApps) return;
        _selected.Clear(); _selected.AddRange(selected);
        _review = null; _phase = "selection"; ReviewRows.Clear(); DependenciesReviewed = false; RequiresDependencyReview = false; HasProtectedSelection = false;
        SelectionSummary = _selected.Count == 0 ? "Select applications to remove." : $"{_selected.Count} selected";
        Status = _selected.Count == 0 ? "Nothing selected." : "Ready to preview removal.";
        Detail = "The app's own remover runs first. Leftover deletion requires a separate review.";
        RefreshCommands();
    }

    [RelayCommand]
    private async Task PreviewAsync()
    {
        if (!CanPreview) return;
        Busy = true;
        try
        {
            _review = await App.Operations.PreviewRemovalAsync(_selected.Select(app => app.AppId!).ToArray(), IncludeAllAppxUsers);
            SetReview(_review); _phase = "preview";
            Status = HasProtectedSelection ? "A protected application is selected." : "Review the selected removals.";
            Detail = HasProtectedSelection ? "Remove protected entries from the selection before continuing." : "Check each application and its command. Vendor removal cannot be undone by restoring leftover files.";
        }
        catch (Exception error) { Status = "Couldn't build the removal plan."; Detail = error.Message; _review = null; }
        finally { Busy = false; }
    }

    private void SetReview(BulkRemovalReview review)
    {
        ReviewRows.Clear(); foreach (var entry in review.Plan.Entries) ReviewRows.Add(new RemovalRow(entry));
        RequiresDependencyReview = review.Plan.Entries.Any(entry => entry.ReviewRequired);
        HasProtectedSelection = review.Plan.Entries.Any(entry => entry.Protected);
        var count = review.Plan.Entries.Count;
        SelectionSummary = count + (count == 1 ? " application in this plan" : " applications in this plan");
        ApplyLabel = "Remove " + count + (count == 1 ? " app" : " apps");
        RefreshCommands();
    }

    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (!CanApply || _review is null) return;
        _journalObserved = false; _removalRunning = true; _cancelRequested = false; Busy = true; Status = "Starting removal.";
        try
        {
            var progress = new Progress<BulkRemovalJournal>(state => { if (_removalRunning) UpdateProgress(state); });
            var result = await App.Operations.ApplyRemovalAsync(_review, DependenciesReviewed, progress);
            _removalRunning = false;
            if (result.Data is not null) UpdateProgress(result.Data);
        }
        catch (Exception error) { _phase = "needs-reconciliation"; Status = "Removal needs checking."; Detail = error.Message; }
        finally { _removalRunning = false; Busy = false; }
    }

    [RelayCommand]
    private async Task CancelAsync()
    {
        if (!CanCancel || _review is null) return;
        try
        {
            await App.Operations.CancelRemovalAsync(_review.JournalPath);
            _cancelRequested = true;
            Status = "Stopping after the current app.";
            Detail = "The active remover is allowed to finish. No further application will start.";
        }
        catch (Exception error) { Status = "Couldn't request cancellation."; Detail = error.Message; }
    }

    [RelayCommand]
    private async Task ReconcileAsync()
    {
        if (!CanReconcile || _review is null) return;
        Busy = true;
        try
        {
            var result = await App.Operations.ReconcileRemovalAsync(_review.JournalPath);
            if (result.Data is not null) UpdateProgress(result.Data);
        }
        catch (Exception error) { Status = "Couldn't check removal state."; Detail = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task StartOverAsync()
    {
        if (!CanStartOver || _review is null) return;
        Busy = true;
        try
        {
            var dismissed = await App.Operations.DismissRemovalAsync(_review.JournalPath);
            var interrupted = dismissed.Data?.Entries.Any(entry => !entry.RegistrationAbsent && (entry.State == "dispatching" || entry.LaunchUnconfirmed)) == true;
            _review = null; _phase = "selection"; _journalObserved = false; _cancelRequested = false; _selected.Clear(); ReviewRows.Clear();
            DependenciesReviewed = false; RequiresDependencyReview = false; HasProtectedSelection = false;
            SelectionSummary = "Select applications to remove."; ApplyLabel = "Remove selected apps";
            Status = "Pick the apps to remove.";
            Detail = interrupted
                ? "The last list was cleared. One removal stopped while its remover was starting, so Roo Industries can't tell whether it ran. Check that app before removing it again."
                : "The last list was cleared. Apps already removed stay removed. Pick any app again to try once more.";
            await LoadAppsAsync();
        }
        catch (Exception error) when (_review is not null) { Status = "Couldn't clear this list yet."; Detail = error.Message; }
        catch (Exception error) { Status = "Couldn't refresh installed apps."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private void UpdateProgress(BulkRemovalJournal state)
    {
        if (_review is null || state.Plan.QueueId != _review.Plan.QueueId) return;
        _journalObserved = true; _phase = state.Status;
        foreach (var row in ReviewRows)
        {
            var current = state.Entries.FirstOrDefault(entry => entry.AppId == row.Entry.AppId);
            if (current is not null) row.State = StateLabel(current.State) + (string.IsNullOrWhiteSpace(current.Error) ? "" : ": " + current.Error);
        }
        (Status, Detail) = state.Status switch
        {
            "cleanup-review-required" => ("Selected removals completed.", "The selected registrations are gone. Review leftover files and registry data before cleanup."),
            "canceled" => ("Queue stopped.", "Resume runs only applications that were never attempted. Start over clears this list."),
            "needs-reconciliation" => ("Removal needs checking.", "An earlier result is uncertain. Check state to look again, or Start over to clear this list and pick apps again."),
            "reboot-required" => ("Windows restart required.", "Restart Windows, then check this list again or start over."),
            "ready" => ("Ready to resume.", "Confirmed removals stay completed. Only untouched entries will run. Start over clears this list."),
            "running" when !_removalRunning => ("A previous removal is unfinished.", "Check state to look again, or Start over to clear this list. An attempted removal will not run again automatically."),
            "running" when _cancelRequested => ("Stopping after the current app.", "The current remover is allowed to finish. No further application will start."),
            _ => ("Removing selected apps.", "Applications run one at a time. You can stop the remaining queue."),
        };
        if (state.Status is "canceled" or "ready") ApplyLabel = "Resume remaining";
        if (state.Status == "cleanup-review-required") { _selected.Clear(); ApplyLabel = "Removal completed"; }
        RememberRemovedApps(state, _review.JournalPath);
        if (state.Status == "cleanup-review-required")
        {
            var removed = state.Entries.Where(entry => entry.RegistrationAbsent).Select(entry => entry.AppId).ToHashSet();
            _all.RemoveAll(app => app.AppId is not null && removed.Contains(app.AppId));
            InstalledAppCount = _all.Count;
            _refreshingRemovedApps = true;
            try { Filter(); }
            finally { _refreshingRemovedApps = false; }
        }
        RefreshCommands();
    }

    private void RememberRemovedApps(BulkRemovalJournal state, string journalPath)
    {
        foreach (var entry in state.Entries.Where(entry => entry.RegistrationAbsent && entry.State is "removed" or "already-absent"))
        {
            var plan = state.Plan.Entries.FirstOrDefault(app => app.AppId == entry.AppId);
            if (plan is not null && RemovedApps.All(app => app.Id != plan.AppId)) RemovedApps.Add(new RemovedAppChoice(plan.AppId, plan.DisplayName, journalPath));
        }
        HasRemovedApps = RemovedApps.Count > 0;
        RefreshCommands();
    }

    [RelayCommand]
    private async Task ScanFilesAsync()
    {
        if (!CanScanFiles) return;
        Busy = true; Leftovers.Clear(); InvalidateCleanup();
        _scanCancellation = new();
        RefreshCommands();
        var version = _fileSelectionVersion;
        try
        {
            var applications = ScanAllApps ? RemovedApps.ToArray() : new[] { SelectedRemovedApp! };
            var incomplete = new List<string>();
            foreach (var app in applications)
            {
                FileStatus = "Scanning " + app.Name + "…";
                var scan = await App.Operations.DiscoverLeftoversAsync(app.JournalPath, app.Id, _scanCancellation.Token);
                if (version != _fileSelectionVersion) return;
                foreach (var item in scan.Candidates)
                {
                    var choice = new LeftoverChoice(item, app);
                    choice.PropertyChanged += FileSelectionChanged;
                    Leftovers.Add(choice);
                }
                if (!scan.Complete) incomplete.Add(app.Name + ": " + string.Join("; ", scan.Errors.Take(3)) + (scan.Errors.Length > 3 ? " (additional scopes were also incomplete)" : ""));
            }
            FileStatus = Leftovers.Count == 0 ? "No leftovers found in the inspected locations." : "Select file, folder, registry-key or registry-value targets to review.";
            FileSummary = incomplete.Count == 0 ? "Each item includes its matching evidence. Shared and protected items stay excluded." : "Some locations could not be completely inspected.\n" + string.Join("\n", incomplete);
        }
        catch (OperationCanceledException) { FileStatus = "Scan stopped. Results from completed applications remain available."; }
        catch (Exception error) { FileStatus = "Couldn't complete the leftover scan."; FileSummary = error.Message; }
        finally { _scanCancellation.Dispose(); _scanCancellation = null; Busy = false; }
    }

    [RelayCommand]
    private void CancelScan() => _scanCancellation?.Cancel();

    private void InvalidateCleanup() { _fileReview = null; _batchState = null; FileReviewReady = false; FilesReviewed = false; CleanupApplyLabel = "Delete reviewed leftovers"; }
    private void FileSelectionChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName != nameof(LeftoverChoice.Selected)) return;
        InvalidateCleanup(); RefreshCommands();
    }

    [RelayCommand]
    private async Task PreviewFilesAsync()
    {
        if (!CanPreviewFiles) return;
        Busy = true; InvalidateCleanup();
        try
        {
            var reviews = new List<CleanupPart>();
            foreach (var group in Leftovers.Where(item => item.Selected && item.CanSelect).GroupBy(item => item.Application))
                reviews.Add(await App.Operations.PreviewDeepCleanupAsync(group.Key.JournalPath, group.Key.Id, group.Select(item => item.Item.ItemId).ToArray(), AcceptKeyRecreation));
            _fileReview = await App.Operations.PreviewCleanupBatchAsync(reviews.ToArray());
            FileSummary = string.Join("\n\n", _fileReview.Plan.Parts.Select(part => part.Preview.DisplayName + "\n" + string.Join("\n", part.Preview.Selection.Select(item => item.Target))));
            FileStatus = "Review " + _fileReview.Plan.Parts.Sum(part => part.Preview.Selection.Length) + " targets across " + _fileReview.Plan.Parts.Length + " applications.";
            FileReviewReady = true;
        }
        catch (Exception error) { FileStatus = "Couldn't preview cleanup."; FileSummary = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task ApplyFilesAsync()
    {
        if (!CanApplyFiles || _fileReview is null) return;
        Busy = true; _cleanupRunning = true; _cleanupObserved = false;
        try
        {
            var progress = new Progress<CleanupBatchJournal>(state => { if (_cleanupRunning) UpdateCleanupProgress(state); });
            var result = await App.Operations.ApplyCleanupBatchAsync(_fileReview, _batchState?.CancellationId, progress);
            _cleanupRunning = false;
            UpdateCleanupProgress(result);
            await RefreshCleanupHistoryAsync(_fileReview.JournalPath);
        }
        catch (Exception error) { FileStatus = "Cleanup needs checking."; FileSummary = error.Message; }
        finally { _cleanupRunning = false; Busy = false; }
    }

    [RelayCommand]
    private async Task CancelCleanupAsync()
    {
        if (!CanCancelCleanup || _fileReview is null) return;
        try
        {
            await App.Operations.CancelCleanupBatchAsync(_fileReview.JournalPath);
            FileStatus = "Stopping after the current application.";
        }
        catch (Exception error) { FileStatus = "Couldn't request a stop."; FileSummary = error.Message; }
    }

    private void UpdateCleanupProgress(CleanupBatchJournal state)
    {
        _batchState = state;
        _cleanupObserved = true;
        FileReviewReady = !state.RestoreStarted && !_cleanupRunning && state.Status is "stopped" or "needsReconciliation" or "running" or "prepared";
        CleanupApplyLabel = FileReviewReady ? "Resume reviewed cleanup" : "Delete reviewed leftovers";
        FileStatus = state.Status switch
        {
            "applied" => "Reviewed cleanup completed.", "stopped" => "Cleanup stopped before the remaining applications.",
            "restored" => "Cleanup recovery completed.", "restoring" => "Restoring cleanup backups…",
            "prepared" => "Saved cleanup is ready to review.",
            "running" when !_cleanupRunning => "Saved cleanup needs checking before resuming.",
            "needsReconciliation" => "Cleanup needs recovery or a fresh review.", _ => "Cleaning reviewed leftovers…",
        };
        FileSummary = string.Join("\n", state.Entries.Select(entry => state.Preview.Parts.Single(part => part.Preview.OperationId == entry.OperationId).Preview.DisplayName + ": " +
            CleanupHistoryChoice.StatusLabel(entry.Status) + (entry.Error is null ? "" : " · " + entry.Error)));
        if (FileReviewReady)
            FileSummary += "\n\nReviewed targets:\n" + string.Join("\n\n", state.Preview.Parts.Select(part => part.Preview.DisplayName + "\n" + string.Join("\n", part.Preview.Selection.Select(item => item.Target))));
        RefreshCommands();
    }

    private async Task RefreshCleanupHistoryAsync(string? journalPath = null)
    {
        journalPath ??= SelectedCleanupHistory?.Session.Review.JournalPath;
        CleanupHistory.Clear();
        foreach (var session in await App.Operations.ReadCleanupHistoryAsync()) CleanupHistory.Add(new(session));
        SelectedCleanupHistory = CleanupHistory.FirstOrDefault(item => item.Session.Review.JournalPath == journalPath) ?? CleanupHistory.FirstOrDefault();
        RefreshCommands();
    }

    [RelayCommand]
    private async Task RestoreFilesAsync()
    {
        if (!CanRestoreFiles) return;
        Busy = true;
        try
        {
            var path = SelectedCleanupHistory!.Session.Review.JournalPath;
            UpdateCleanupProgress(await App.Operations.RestoreCleanupBatchAsync(path));
            await RefreshCleanupHistoryAsync(path);
            FilesReviewed = false;
        }
        catch (Exception error) { FileStatus = "Couldn't restore cleanup data."; FileSummary = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RestoreLegacyFilesAsync()
    {
        if (!CanRestoreLegacyFiles || _restoreReview is null) return;
        Busy = true;
        try
        {
            var result = await App.Operations.RestoreRemovedFilesAsync(_restoreReview);
            FileStatus = result.Status == "success" ? "Earlier file backup restored." : "Some earlier files could not be restored.";
            FileSummary = "File recovery does not reinstall the application.";
            FileRestoreAvailable = result.Status != "success";
        }
        catch (Exception error) { FileStatus = "Couldn't restore earlier files."; FileSummary = error.Message; }
        finally { Busy = false; }
    }

    private static string StateLabel(string state) => state switch
    {
        "pending" => "Waiting", "dispatching" or "running" => "Removing", "removed" => "Removed", "already-absent" => "Already absent",
        "reboot-required" or "restart-initiated" => "Restart required", "needs-reconciliation" => "Needs checking", "installer-busy" => "Installer busy",
        "canceled" => "Canceled", "failed-before-start" => "Not started", _ => "Removal failed",
    };
    private void RefreshCommands()
    {
        foreach (var property in new[] { nameof(CanSelect), nameof(NoMatches), nameof(CanPreview), nameof(CanApply), nameof(CanCancel), nameof(CanReconcile), nameof(CanStartOver), nameof(CanScanFiles), nameof(CanPreviewFiles), nameof(CanApplyFiles), nameof(CanRestoreFiles), nameof(CanRestoreLegacyFiles), nameof(CanCancelCleanup), nameof(CanCancelScan), nameof(HasSelectedKeys), nameof(HasCleanupHistory) }) OnPropertyChanged(property);
    }
}
