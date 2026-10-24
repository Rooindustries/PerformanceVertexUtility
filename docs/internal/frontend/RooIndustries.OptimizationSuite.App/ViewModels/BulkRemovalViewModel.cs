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
    [ObservableProperty] private string _state = "Ready";
    public RemovalRow(BulkRemovalEntry entry) { Entry = entry; }
}

public partial class LeftoverChoice : ObservableObject
{
    public LeftoverCandidate Item { get; }
    public RemovedAppChoice Application { get; }
    [ObservableProperty] private bool _selected;
    public bool CanSelect => !Item.Protected && Item.Exists == true && Item.OwnershipComplete && Item.SharedOwners.Count == 0 && Item.Error is null;
    public string Evidence => Application.Name + " · " + KindLabel(Item.Kind) + (Item.Registry is null ? "" : Item.Registry.View == "Registry32" ? " · 32-bit" : " · 64-bit") + "\n" +
        string.Join("; ", Item.Evidence.Select(Reason).Distinct()) + (Item.SharedOwners.Count == 0 ? "" : "\nAlso used by " + string.Join(", ", Item.SharedOwners)) +
        (Item.OwnershipComplete ? "" : "\nCouldn't check everything inside it, so it stays.") + (Item.Error is null ? "" : "\nCouldn't check this one, so it stays.") + (Item.Protected ? "\nWindows needs this, so it stays." : "");
    private const string UnprovedOwner = "Ownership could not be checked for installed app: ";
    private static string KindLabel(string kind) => kind switch { "file" => "File", "folder" => "Folder", "registryKey" => "Registry key", "registryValue" => "Registry value", _ => "Leftover" };
    private static string Reason(string evidence) => evidence switch
    {
        "Published installation location" => "The app's install folder",
        "Exact package-family data directory" => "The app's data folder",
        "Directory name matches the selected product" => "Folder name matches the app",
        "Key name matches the selected product; review its subtree ownership" => "Key name matches the app",
        "Value references the selected installation path" => "Points to the app's install folder",
        _ when evidence.StartsWith(UnprovedOwner, StringComparison.Ordinal) => "Couldn't check whether " + evidence[UnprovedOwner.Length..] + " uses it",
        _ when evidence.StartsWith("Excluded ", StringComparison.Ordinal) => "Windows or another app needs it",
        _ => "Matches this app",
    };
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
        "restoring" => "Restoring", "stopped" => "Stopped", "prepared" => "Ready", "needsReconciliation" => "Stopped partway", _ => "Unknown",
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
    [ObservableProperty] private string _cleanupApplyLabel = "Delete leftovers";
    [ObservableProperty] private RemovedAppChoice? _selectedRemovedApp;
    [ObservableProperty] private bool _hasRemovedApps;
    [ObservableProperty] private bool _fileReviewReady;
    [ObservableProperty] private bool _fileRestoreAvailable;
    [ObservableProperty] private string _fileStatus = "Pick a removed app to find what it left behind.";
    [ObservableProperty] private string _fileSummary = "";
    [ObservableProperty] private string _searchText = "";
    [ObservableProperty] private int _installedAppCount;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _dependenciesReviewed;
    [ObservableProperty] private bool _requiresDependencyReview;
    [ObservableProperty] private bool _hasProtectedSelection;
    [ObservableProperty] private string _selectionSummary = "Pick the apps to remove.";
    [ObservableProperty] private string _status = "Nothing selected.";
    [ObservableProperty] private bool _includeAllAppxUsers;
    [ObservableProperty] private string _detail = "Pick apps, then preview what gets removed.";
    [ObservableProperty] private string _applyLabel = "Remove selected apps";
    public bool CanSelect => !Busy && _phase is not ("running" or "canceled" or "needs-reconciliation" or "reboot-required" or "ready");
    public bool NoMatches => !Busy && Apps.Count == 0;
    public bool CanPreview => CanSelect && _selected.Count > 0;
    public bool CanApply => !Busy && _review is not null && (_phase is "preview" or "canceled" or "ready") && !HasProtectedSelection && (!RequiresDependencyReview || DependenciesReviewed);
    public bool CanCancel => _removalRunning && _journalObserved;
    public bool CanReconcile => !Busy && _review is not null && (_phase is "running" or "needs-reconciliation" or "reboot-required");
    public bool CanStartOver => !Busy && !_removalRunning && _review is not null && (_phase is "running" or "canceled" or "needs-reconciliation" or "reboot-required" or "ready");
    public bool CanScanFiles => !Busy && (ScanAllApps ? RemovedApps.Count > 0 : SelectedRemovedApp is not null);
    public bool CanPreviewFiles => !Busy && Leftovers.Any(item => item.Selected && item.CanSelect);
    public bool CanApplyFiles => !Busy && FileReviewReady;
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
    partial void OnSelectedRemovedAppChanged(RemovedAppChoice? value) { _fileSelectionVersion++; Leftovers.Clear(); _fileReview = null; FileReviewReady = false; FileStatus = "Find this app's leftovers."; FileSummary = ""; RefreshCommands(); }
    partial void OnFileReviewReadyChanged(bool value) => RefreshCommands();
    partial void OnFileRestoreAvailableChanged(bool value) => RefreshCommands();
    partial void OnScanAllAppsChanged(bool value) { _fileSelectionVersion++; Leftovers.Clear(); InvalidateCleanup(); RefreshCommands(); }
    partial void OnSelectedCleanupHistoryChanged(CleanupHistoryChoice? value)
    {
        if (value is not null && !_cleanupRunning)
        {
            _fileReview = value.Session.Review;
            UpdateCleanupProgress(value.Session.State);
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
            if (FileRestoreAvailable && !HasCleanupHistory) { FileStatus = _restoreReview!.Plan.DisplayName + "'s earlier cleanup can be restored."; FileSummary = "Restore earlier cleanup puts its files back. It doesn't reinstall the app."; }
        }
        catch (Exception error) { Log(error); Status = "Couldn't load your last removal."; Detail = "Close and reopen the app to try again."; }
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (Busy) return;
        if (CanSelect) SetSelection(Array.Empty<InstalledApp>());
        Busy = true;
        try { await LoadAppsAsync(); }
        catch (Exception error) { Log(error); Status = "Couldn't refresh your apps."; Detail = "Press Refresh to try again."; }
        finally { Busy = false; }
    }
    public bool HasUserWork => _selected.Count > 0 || _review is not null;
    public void NoteChanged()
    {
        Status = "Settings changed elsewhere";
        Detail = "Your picks are kept. Start over or finish this removal to see the current app list.";
    }
    public async Task<bool> RefreshIfIdleAsync(bool changed = false)
    {
        if (Busy || _selected.Count > 0 || _review is not null || !CanSelect || !changed && Environment.TickCount64 - _appsLoadedTicks < 30000) return false;
        Busy = true;
        try { await LoadAppsAsync(); return true; }
        catch (Exception error) { Log(error); Status = "Couldn't refresh your apps."; Detail = "Press Refresh to try again."; return false; }
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
        if (inventory.Complete == false) { Log(string.Join("\n", inventory.Errors ?? new())); Status = "Some apps couldn't be read, so they may be missing from this list."; Detail = "Press Refresh to try again."; }
    }

    public void ShowGroup(string group)
    {
        SearchText = ""; _suggestedGroup = group; Filter();
        Status = group switch { "widgets" => "Windows Widgets packages", "copilot" => "Copilot and Office Hub apps", "edge" => "Microsoft Edge", "onedrive" => "Microsoft OneDrive", _ => "Choose installed apps" };
        Detail = "Search to see other apps. Anything Windows needs stays protected.";
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
        SelectionSummary = _selected.Count == 0 ? "Pick the apps to remove." : $"{_selected.Count} selected";
        Status = _selected.Count == 0 ? "Nothing selected." : "Ready to preview removal.";
        Detail = "Each app's own uninstaller runs. You can clean up what it leaves behind after.";
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
            Status = HasProtectedSelection ? "One of these is part of Windows and can't be removed." : "Check the list, then remove.";
            Detail = HasProtectedSelection ? "Unpick it to continue." : "Removing an app can't be undone. To get it back, install it again.";
        }
        catch (Exception error) { Log(error); Status = "Couldn't get the removal ready."; Detail = "Press Preview removal to try again."; _review = null; }
        finally { Busy = false; }
    }

    private void SetReview(BulkRemovalReview review)
    {
        ReviewRows.Clear(); foreach (var entry in review.Plan.Entries) ReviewRows.Add(new RemovalRow(entry));
        RequiresDependencyReview = review.Plan.Entries.Any(entry => entry.ReviewRequired);
        HasProtectedSelection = review.Plan.Entries.Any(entry => entry.Protected);
        var count = review.Plan.Entries.Count;
        SelectionSummary = count + (count == 1 ? " app to remove" : " apps to remove");
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
            using var running = RunningChanges.Begin();
            var progress = new Progress<BulkRemovalJournal>(state => { if (_removalRunning) UpdateProgress(state); });
            var result = await App.Operations.ApplyRemovalAsync(_review, DependenciesReviewed, progress);
            _removalRunning = false;
            if (result.Data is not null) UpdateProgress(result.Data);
        }
        catch (InvalidOperationException error) when (error.Message == RunningChanges.Installing) { Status = "Removal didn't start."; Detail = error.Message; }
        catch (Exception error) { Log(error); _phase = "needs-reconciliation"; Status = "Removal needs checking."; Detail = "Press Check again to see where it got to."; }
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
            Status = "Stopping after this app.";
            Detail = "Its uninstaller gets to finish. No other app starts.";
        }
        catch (Exception error) { Log(error); Status = "Couldn't stop the list."; Detail = "Press Stop to try again."; }
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
        catch (Exception error) { Log(error); Status = "Couldn't check the list."; Detail = "Press Check again in a moment."; }
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
            SelectionSummary = "Pick the apps to remove."; ApplyLabel = "Remove selected apps";
            Status = "Pick the apps to remove.";
            Detail = interrupted
                ? "The list was cleared. One app's uninstaller was starting when it stopped, so the app can't tell whether it ran. Check that app before you remove it again."
                : "The list was cleared. Apps already removed stay removed. Pick any app to try again.";
            await LoadAppsAsync();
        }
        catch (Exception error) when (_review is not null) { Log(error); Status = "Couldn't clear this list yet."; Detail = "An uninstaller may still be running, or Windows needs a restart. Let it finish or restart, then try again."; }
        catch (Exception error) { Log(error); Status = "Couldn't refresh your apps."; Detail = "Press Refresh to try again."; }
        finally { Busy = false; }
    }

    private void UpdateProgress(BulkRemovalJournal state)
    {
        if (_review is null || state.Plan.QueueId != _review.Plan.QueueId) return;
        _journalObserved = true; _phase = state.Status;
        foreach (var row in ReviewRows)
        {
            var current = state.Entries.FirstOrDefault(entry => entry.AppId == row.Entry.AppId);
            if (current is null) continue;
            row.State = StateLabel(current.State);
            if (!string.IsNullOrWhiteSpace(current.Error)) Log(row.Entry.DisplayName + ": " + current.Error);
        }
        (Status, Detail) = state.Status switch
        {
            "cleanup-review-required" => ("Apps removed.", "Clean up what they left behind below."),
            "canceled" => ("Stopped.", "Resume removes the apps that haven't started. Start over clears the list."),
            "needs-reconciliation" => ("Removal needs checking.", "Couldn't tell whether the last uninstaller finished. Press Check again to look, or Start over to clear the list."),
            "reboot-required" => ("Restart Windows to finish.", "Then press Check again, or Start over."),
            "ready" => ("Ready to resume.", "Apps already removed stay removed. Resume removes the rest. Start over clears the list."),
            "running" when !_removalRunning => ("The last removal didn't finish.", "Press Check again to look, or Start over to clear the list. An app that already started won't run again on its own."),
            "running" when _cancelRequested => ("Stopping after this app.", "Its uninstaller gets to finish. No other app starts."),
            _ => ("Removing apps…", "One at a time. Stop skips the ones that haven't started."),
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
                FileStatus = "Checking " + app.Name + "…";
                var scan = await App.Operations.DiscoverLeftoversAsync(app.JournalPath, app.Id, _scanCancellation.Token);
                if (version != _fileSelectionVersion) return;
                foreach (var item in scan.Candidates)
                {
                    if (item.Error is not null) Log(app.Name + ": " + item.Target + ": " + item.Error);
                    var choice = new LeftoverChoice(item, app);
                    choice.PropertyChanged += FileSelectionChanged;
                    Leftovers.Add(choice);
                }
                if (!scan.Complete) incomplete.Add(app.Name + ": " + string.Join("; ", scan.Errors));
            }
            Log(string.Join("\n", incomplete));
            FileStatus = Leftovers.Count == 0 ? "No leftovers found." : "Pick the leftovers to delete.";
            FileSummary = incomplete.Count > 0 ? "Some places couldn't be fully checked, so a few leftovers may be missing."
                : Leftovers.Count == 0 ? "" : "Each one says why it belongs to the app. Anything Windows or another app needs can't be picked.";
        }
        catch (OperationCanceledException) { FileStatus = "Stopped. Leftovers found so far are still listed."; }
        catch (Exception error) { Log(error); FileStatus = "Couldn't finish looking for leftovers."; FileSummary = "Press Find leftovers to try again."; }
        finally { _scanCancellation.Dispose(); _scanCancellation = null; Busy = false; }
    }

    [RelayCommand]
    private void CancelScan() => _scanCancellation?.Cancel();

    private void InvalidateCleanup() { _fileReview = null; _batchState = null; FileReviewReady = false; CleanupApplyLabel = "Delete leftovers"; }
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
                reviews.Add(await App.Operations.PreviewDeepCleanupAsync(group.Key.JournalPath, group.Key.Id, group.Select(item => item.Item.ItemId).ToArray(), true));
            _fileReview = await App.Operations.PreviewCleanupBatchAsync(reviews.ToArray());
            FileSummary = string.Join("\n\n", _fileReview.Plan.Parts.Select(part => part.Preview.DisplayName + "\n" + string.Join("\n", part.Preview.Selection.Select(item => item.Target))));
            var targets = _fileReview.Plan.Parts.Sum(part => part.Preview.Selection.Length);
            var apps = _fileReview.Plan.Parts.Length;
            FileStatus = "Ready to delete " + targets + (targets == 1 ? " leftover" : " leftovers") + " from " + apps + (apps == 1 ? " app" : " apps") + ". Everything is backed up first.";
            FileReviewReady = true;
        }
        catch (Exception error) { Log(error); FileStatus = "Couldn't get the cleanup ready."; FileSummary = "Pick the leftovers again, then press Preview cleanup."; }
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
        catch (Exception error) { Log(error); FileStatus = "Couldn't confirm the cleanup."; FileSummary = "Close and reopen Remove apps to see where it got to."; }
        finally { _cleanupRunning = false; Busy = false; }
    }

    [RelayCommand]
    private async Task CancelCleanupAsync()
    {
        if (!CanCancelCleanup || _fileReview is null) return;
        try
        {
            await App.Operations.CancelCleanupBatchAsync(_fileReview.JournalPath);
            FileStatus = "Stopping after this app.";
        }
        catch (Exception error) { Log(error); FileStatus = "Couldn't stop the cleanup."; FileSummary = "Press Stop after this app to try again."; }
    }

    private void UpdateCleanupProgress(CleanupBatchJournal state)
    {
        _batchState = state;
        _cleanupObserved = true;
        FileReviewReady = !state.RestoreStarted && !_cleanupRunning && state.Status is "stopped" or "needsReconciliation" or "running" or "prepared";
        CleanupApplyLabel = FileReviewReady ? "Resume cleanup" : "Delete leftovers";
        FileStatus = state.Status switch
        {
            "applied" => "Cleanup done.", "stopped" => "Cleanup stopped before the other apps.",
            "restored" => "Restore done.", "restoring" => "Restoring…",
            "prepared" => "A saved cleanup is ready.",
            "running" when !_cleanupRunning => "A saved cleanup stopped partway. Resume it, or restore it.",
            "needsReconciliation" => "This cleanup stopped partway. Restore it, or find leftovers again.", _ => "Deleting leftovers…",
        };
        string Name(CleanupBatchEntry entry) => state.Preview.Parts.Single(part => part.Preview.OperationId == entry.OperationId).Preview.DisplayName;
        foreach (var entry in state.Entries.Where(entry => entry.Error is not null)) Log(Name(entry) + ": " + entry.Error);
        FileSummary = string.Join("\n", state.Entries.Select(entry => Name(entry) + ": " + CleanupHistoryChoice.StatusLabel(entry.Status)));
        if (FileReviewReady)
            FileSummary += "\n\nOn the list:\n" + string.Join("\n\n", state.Preview.Parts.Select(part => part.Preview.DisplayName + "\n" + string.Join("\n", part.Preview.Selection.Select(item => item.Target))));
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
        }
        catch (Exception error) { Log(error); FileStatus = "Couldn't restore this cleanup."; FileSummary = "Press Restore this cleanup to try again."; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RestoreLegacyFilesAsync()
    {
        if (!CanRestoreLegacyFiles || _restoreReview is null) return;
        Busy = true;
        try
        {
            using var running = RunningChanges.Begin();
            var result = await App.Operations.RestoreRemovedFilesAsync(_restoreReview);
            FileStatus = result.Status == "success" ? "Earlier cleanup restored." : "Some files from the earlier cleanup couldn't be put back.";
            FileSummary = "Restore doesn't reinstall the app.";
            FileRestoreAvailable = result.Status != "success";
        }
        catch (Exception error) { Log(error); FileStatus = "Couldn't restore the earlier cleanup."; FileSummary = "Press Restore earlier cleanup to try again."; }
        finally { Busy = false; }
    }

    private static string StateLabel(string state) => state switch
    {
        "pending" => "Waiting", "dispatching" or "running" => "Removing…", "removed" => "Removed", "already-absent" => "Already gone",
        "reboot-required" or "restart-initiated" => "Restart Windows to finish", "needs-reconciliation" => "Needs checking. Press Check again.",
        "installer-busy" => "Another install is running. Try again when it's done.", "canceled" => "Stopped", "failed-before-start" => "Didn't start. Try again.",
        _ => "Couldn't remove it. Try again, or uninstall it from Windows Settings.",
    };
    private readonly HashSet<string> _logged = new(StringComparer.Ordinal);
    private static void Log(Exception error) => AppLog.Write(nameof(BulkRemovalViewModel), error.ToString());
    private void Log(string detail) { if (!string.IsNullOrWhiteSpace(detail) && _logged.Add(detail)) AppLog.Write(nameof(BulkRemovalViewModel), detail); }
    private void RefreshCommands()
    {
        foreach (var property in new[] { nameof(CanSelect), nameof(NoMatches), nameof(CanPreview), nameof(CanApply), nameof(CanCancel), nameof(CanReconcile), nameof(CanStartOver), nameof(CanScanFiles), nameof(CanPreviewFiles), nameof(CanApplyFiles), nameof(CanRestoreFiles), nameof(CanRestoreLegacyFiles), nameof(CanCancelCleanup), nameof(CanCancelScan), nameof(HasSelectedKeys), nameof(HasCleanupHistory) }) OnPropertyChanged(property);
    }
}
