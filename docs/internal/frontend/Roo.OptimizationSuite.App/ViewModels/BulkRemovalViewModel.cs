using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class RemovalRow : ObservableObject
{
    public BulkRemovalEntry Entry { get; }
    [ObservableProperty] private string _state = "Ready for review";
    public RemovalRow(BulkRemovalEntry entry) { Entry = entry; }
}

public partial class LeftoverChoice : ObservableObject
{
    public LeftoverItem Item { get; }
    [ObservableProperty] private bool _selected;
    public bool CanSelect => !Item.Protected && Item.Type is "file" or "folder";
    public LeftoverChoice(LeftoverItem item) { Item = item; }
}

public sealed record RemovedAppChoice(string Id, string Name, string JournalPath)
{
    public override string ToString() => Name;
}

public partial class BulkRemovalViewModel : ObservableObject
{
    private readonly List<InstalledApp> _all = new();
    private readonly List<InstalledApp> _selected = new();
    private BulkRemovalReview? _review;
    private string _phase = "selection";
    private bool _journalObserved;
    private bool _removalRunning;
    private RemovalCleanupReview? _fileReview;
    private RemovalCleanupReview? _restoreReview;
    private int _fileSelectionVersion;
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<RemovalRow> ReviewRows { get; } = new();
    public ObservableCollection<RemovedAppChoice> RemovedApps { get; } = new();
    public ObservableCollection<LeftoverChoice> Leftovers { get; } = new();
    [ObservableProperty] private RemovedAppChoice? _selectedRemovedApp;
    [ObservableProperty] private bool _hasRemovedApps;
    [ObservableProperty] private bool _fileReviewReady;
    [ObservableProperty] private bool _filesReviewed;
    [ObservableProperty] private bool _fileRestoreAvailable;
    [ObservableProperty] private string _fileStatus = "Scan an app after its removal has completed.";
    [ObservableProperty] private string _fileSummary = "";
    [ObservableProperty] private string _searchText = "";
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _dependenciesReviewed;
    [ObservableProperty] private bool _requiresDependencyReview;
    [ObservableProperty] private bool _hasProtectedSelection;
    [ObservableProperty] private string _selectionSummary = "Select applications to remove.";
    [ObservableProperty] private string _status = "Nothing selected.";
    [ObservableProperty] private string _detail = "Preview the exact removal commands before running them.";
    [ObservableProperty] private string _applyLabel = "Remove selected apps";
    public bool CanSelect => !Busy && _phase is not ("running" or "canceled" or "needs-reconciliation" or "reboot-required" or "ready");
    public bool NoMatches => !Busy && Apps.Count == 0;
    public bool CanPreview => CanSelect && _selected.Count > 0;
    public bool CanApply => !Busy && _review is not null && (_phase is "preview" or "canceled" or "ready") && !HasProtectedSelection && (!RequiresDependencyReview || DependenciesReviewed);
    public bool CanCancel => _removalRunning && _journalObserved;
    public bool CanReconcile => !Busy && _review is not null && (_phase is "running" or "needs-reconciliation" or "reboot-required");
    public bool CanScanFiles => !Busy && SelectedRemovedApp is not null;
    public bool CanPreviewFiles => CanScanFiles && Leftovers.Any(item => item.Selected && item.CanSelect);
    public bool CanApplyFiles => !Busy && FileReviewReady && FilesReviewed;
    public bool CanRestoreFiles => !Busy && FileRestoreAvailable;
    partial void OnBusyChanged(bool value) => RefreshCommands();
    partial void OnDependenciesReviewedChanged(bool value) => RefreshCommands();
    partial void OnSearchTextChanged(string value) => Filter();
    partial void OnSelectedRemovedAppChanged(RemovedAppChoice? value) { _fileSelectionVersion++; Leftovers.Clear(); _fileReview = null; FileReviewReady = false; FilesReviewed = false; FileStatus = "Scan this application's current leftovers."; FileSummary = ""; RefreshCommands(); }
    partial void OnFilesReviewedChanged(bool value) => RefreshCommands();
    partial void OnFileReviewReadyChanged(bool value) => RefreshCommands();
    partial void OnFileRestoreAvailableChanged(bool value) => RefreshCommands();

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
            _restoreReview = await App.Operations.ReadLastFileCleanupAsync();
            FileRestoreAvailable = _restoreReview is not null && System.IO.File.Exists(_restoreReview.Plan.RollbackPath);
            if (FileRestoreAvailable) { FileStatus = "File recovery is available for " + _restoreReview!.Plan.DisplayName; FileSummary = "Restore last cleanup recovers the saved files; it does not reinstall the app."; }
        }
        catch (Exception error) { Status = "Couldn't read saved removal state."; Detail = error.Message; }
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (Busy) return;
        if (CanSelect) SetSelection(Array.Empty<InstalledApp>());
        Busy = true;
        try
        {
            var inventory = await App.Live.GetInstalledAppsAsync();
            if (inventory?.Apps is null) throw new InvalidOperationException(App.Live.LastError ?? "Installed applications could not be read.");
            _all.Clear();
            _all.AddRange(inventory.Apps.Where(app => app.IsListable).OrderBy(app => app.FriendlyName, StringComparer.OrdinalIgnoreCase));
            Filter();
        }
        catch (Exception error) { Status = "Couldn't refresh installed apps."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private void Filter()
    {
        Apps.Clear();
        foreach (var app in _all.Where(app => string.IsNullOrWhiteSpace(SearchText) || app.FriendlyName.Contains(SearchText, StringComparison.OrdinalIgnoreCase))) Apps.Add(app);
        OnPropertyChanged(nameof(NoMatches));
    }

    public void SetSelection(IEnumerable<InstalledApp> selected)
    {
        if (!CanSelect) return;
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
            _review = await App.Operations.PreviewRemovalAsync(_selected.Select(app => app.AppId!).ToArray());
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
        _journalObserved = false; _removalRunning = true; Busy = true; Status = "Starting removal.";
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
            "cleanup-review-required" => ("Selected removals completed.", "The selected registrations are gone. Review leftovers before deleting any files."),
            "canceled" => ("Queue stopped.", "Resume runs only applications that were never attempted."),
            "needs-reconciliation" => ("Removal needs checking.", "An earlier result is uncertain. Check its state before continuing; it will not be repeated automatically."),
            "reboot-required" => ("Windows restart required.", "Check this queue again after restarting Windows."),
            "ready" => ("Ready to resume.", "Confirmed removals stay completed. Only untouched entries will run."),
            "running" when !_removalRunning => ("A previous removal is unfinished.", "Check its state before continuing. An attempted removal will not run again automatically."),
            _ => ("Removing selected apps.", "Applications run one at a time. You can stop the remaining queue."),
        };
        if (state.Status is "canceled" or "ready") ApplyLabel = "Resume remaining";
        if (state.Status == "cleanup-review-required") { _selected.Clear(); ApplyLabel = "Removal completed"; }
        foreach (var entry in state.Entries.Where(entry => entry.RegistrationAbsent && entry.State is "removed" or "already-absent"))
        {
            var plan = state.Plan.Entries.FirstOrDefault(app => app.AppId == entry.AppId);
            if (plan is not null && RemovedApps.All(app => app.Id != plan.AppId || app.JournalPath != _review.JournalPath)) RemovedApps.Add(new RemovedAppChoice(plan.AppId, plan.DisplayName, _review.JournalPath));
        }
        HasRemovedApps = RemovedApps.Count > 0;
        RefreshCommands();
    }

    [RelayCommand]
    private async Task ScanFilesAsync()
    {
        if (!CanScanFiles) return;
        Busy = true; Leftovers.Clear(); _fileReview = null; FileReviewReady = false; FilesReviewed = false;
        var version = _fileSelectionVersion;
        try
        {
            var scan = await App.Operations.ScanRemovedAppAsync(SelectedRemovedApp!.JournalPath, SelectedRemovedApp.Id);
            if (version != _fileSelectionVersion) return;
            Leftovers.Clear();
            foreach (var item in scan.Data?.Items ?? new List<LeftoverItem>())
            {
                var choice = new LeftoverChoice(item);
                choice.PropertyChanged += FileSelectionChanged;
                Leftovers.Add(choice);
            }
            FileStatus = Leftovers.Count == 0 ? "No leftovers found." : "Select the file or folder targets to review.";
            FileSummary = "Shared or protected targets remain excluded. Nothing has been deleted.";
        }
        catch (Exception error) { FileStatus = "Couldn't scan leftovers."; FileSummary = error.Message; }
        finally { Busy = false; }
    }

    private void FileSelectionChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName != nameof(LeftoverChoice.Selected)) return;
        _fileReview = null; FileReviewReady = false; FilesReviewed = false; RefreshCommands();
    }

    [RelayCommand]
    private async Task PreviewFilesAsync()
    {
        if (!CanPreviewFiles) return;
        Busy = true; _fileReview = null; FileReviewReady = false; FilesReviewed = false;
        try
        {
            _fileReview = await App.Operations.PreviewRemovedFilesAsync(SelectedRemovedApp!.JournalPath, SelectedRemovedApp.Id, Leftovers.Where(item => item.Selected && item.CanSelect).Select(item => item.Item.ItemId!).ToArray());
            FileSummary = string.Join(Environment.NewLine, _fileReview.Plan.Items.Select(item => item.Target));
            var count = _fileReview.Plan.Items.Count;
            FileStatus = $"Review {count} " + (count == 1 ? "target" : "targets") + " before deletion.";
            FileReviewReady = true; FilesReviewed = false;
        }
        catch (Exception error) { FileStatus = "Couldn't preview cleanup."; FileSummary = error.Message; }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task ApplyFilesAsync()
    {
        if (!CanApplyFiles || _fileReview is null) return;
        Busy = true;
        try
        {
            _restoreReview = _fileReview;
            var result = await App.Operations.ApplyRemovedFilesAsync(_fileReview, FilesReviewed);
            FileRestoreAvailable = result.Data?.Summary.RestoreReady == true;
            FileStatus = result.Status == "success" ? "Cleanup completed." : "Cleanup stopped before all targets were removed.";
            var count = result.Data?.Summary.DeletedCount ?? 0;
            FileSummary = count + (count == 1 ? " target removed." : " targets removed.") + " File restoration uses the saved backup.";
            FileReviewReady = false;
        }
        catch (Exception error) { FileStatus = "Cleanup needs checking."; FileSummary = error.Message; FileRestoreAvailable = System.IO.File.Exists(_fileReview.Plan.RollbackPath); }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RestoreFilesAsync()
    {
        if (!CanRestoreFiles || _restoreReview is null) return;
        Busy = true;
        try
        {
            var result = await App.Operations.RestoreRemovedFilesAsync(_restoreReview);
            FileStatus = result.Status == "success" ? "Backed-up files restored." : "Some files could not be restored.";
            FileSummary = "File restoration does not reinstall the application.";
            FileRestoreAvailable = result.Status != "success";
        }
        catch (Exception error) { FileStatus = "Couldn't restore files."; FileSummary = error.Message; }
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
        foreach (var property in new[] { nameof(CanSelect), nameof(NoMatches), nameof(CanPreview), nameof(CanApply), nameof(CanCancel), nameof(CanReconcile), nameof(CanScanFiles), nameof(CanPreviewFiles), nameof(CanApplyFiles), nameof(CanRestoreFiles) }) OnPropertyChanged(property);
    }
}
