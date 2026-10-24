using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class UninstallCleanupViewModel : PageViewModelBase
{
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private int _appCount;
    [ObservableProperty] private string? _sources;

    [ObservableProperty] private InstalledApp? _selectedApp;
    [ObservableProperty] private string? _selectedName;
    [ObservableProperty] private string? _selectedSummary;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanScan))]
    [NotifyPropertyChangedFor(nameof(CanReviewRemoval))]
    [NotifyPropertyChangedFor(nameof(CanBuildCleanupList))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    [NotifyPropertyChangedFor(nameof(CanRestoreCleanup))]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    [NotifyPropertyChangedFor(nameof(RemovalPanelLabel))]
    [NotifyPropertyChangedFor(nameof(RemovalPathHeadline))]
    [NotifyPropertyChangedFor(nameof(RemovalPathHelp))]
    private bool _selectedProtected;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(RemovalPanelLabel))]
    [NotifyPropertyChangedFor(nameof(RemovalPathHeadline))]
    [NotifyPropertyChangedFor(nameof(RemovalPathHelp))]
    [NotifyPropertyChangedFor(nameof(RemovalApprovalLabel))]
    private bool _selectedHasOfficialRemover;
    [ObservableProperty] private string? _officialCommand;
    [ObservableProperty] private string? _installLocation;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanScan))]
    [NotifyPropertyChangedFor(nameof(CanReviewRemoval))]
    [NotifyPropertyChangedFor(nameof(CanBuildCleanupList))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _hasSelection;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanScan))]
    [NotifyPropertyChangedFor(nameof(CanReviewRemoval))]
    [NotifyPropertyChangedFor(nameof(CanBuildCleanupList))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    [NotifyPropertyChangedFor(nameof(CanRestoreCleanup))]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _scanBusy;
    [ObservableProperty] private string _leftoverState = "Pick an app, then find what it leaves behind.";
    [ObservableProperty] private string? _leftoverSummary;
    [ObservableProperty] private string _officialPreviewState = "Pick an app to see how it uninstalls.";
    [ObservableProperty] private string _cleanupPlanState = "Find leftovers first, then make the removal list.";
    [ObservableProperty] private string _primaryRemovalButtonLabel = "Check uninstaller";
    [ObservableProperty] private string _removalPlanState = "Make the removal list to see everything that gets removed.";
    [ObservableProperty] private string? _removalPlanDetail;
    [ObservableProperty] private string _cleanupExecutionState = "Remove unlocks after you check the app and make the list.";
    [ObservableProperty] private string? _cleanupExecutionDetail;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRestoreCleanup))]
    private bool _cleanupRestoreAvailable;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanBuildCleanupList))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _removalPathReviewed;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanBuildCleanupList))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _leftoverScanCompleted;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _cleanupPlanReady;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    private bool _removalApproved;
    [ObservableProperty] private bool _canReviewRemovalAction;
    [ObservableProperty] private bool _canScanAction;
    [ObservableProperty] private bool _canBuildCleanupListAction;
    [ObservableProperty] private bool _canRunFinalCheckAction;
    [ObservableProperty] private bool _canApplyCleanupAction;
    [ObservableProperty] private bool _canRestoreCleanupAction;
    [ObservableProperty] private string _inventoryNotice = "";

    public bool CanScan => HasSelection && !ScanBusy && SelectedApp?.Removed != true;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _removalRouteBlocked;
    partial void OnRemovalRouteBlockedChanged(bool value) => RefreshActionState();
    public bool CanReviewRemoval => HasSelection && !ScanBusy && !RemovalRouteBlocked;
    public bool CanBuildCleanupList => HasSelection && !ScanBusy && RemovalPathReviewed && LeftoverScanCompleted;
    public bool CanRunFinalCheck => HasSelection && !ScanBusy && CleanupPlanReady && RemovalApproved;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    private bool _finalCheckPassed;
    partial void OnFinalCheckPassedChanged(bool value) => RefreshActionState();
    public bool CanApplyCleanup => CanRunFinalCheck && FinalCheckPassed;
    public bool CanRestoreCleanup => HasSelection && !ScanBusy && CleanupRestoreAvailable;
    public string ApplyApprovalSummary => !HasSelection
        ? "Pick an app first."
        : WaitingNotice is { } waiting
            ? waiting
        : RemovalRouteBlocked
            ? SelectedApp is { Removed: true } removedApp ? removedApp.RemovalUnconfirmed ? "Only Restore is available for this app here." : "This app is already removed. Restore puts back what its cleanup deleted." : "Can't run this app's uninstaller here. Use Remove apps to remove it."
            : !RemovalPathReviewed
                ? "Check the app first."
                : !LeftoverScanCompleted
                    ? "Find leftovers next."
                    : !CleanupPlanReady
                        ? "Make the removal list next."
                        : !RemovalApproved
                            ? "Tick the box when you're ready to remove it."
                            : FinalCheckPassed ? "Ready to remove." : "Run the final check next.";
    public string RemovalPanelLabel => "How it's removed";
    public string RemovalPathHeadline => SelectedHasOfficialRemover
        ? "With the app's own uninstaller"
        : "Without an uninstaller";
    public string RemovalPathHelp => SelectedHasOfficialRemover
        ? "Runs the app's own uninstaller. Afterwards, find leftovers again to clean up what it leaves."
        : "This app didn't come with an uninstaller. Its files can be deleted instead, and they're backed up first.";
    public string RemovalApprovalLabel => SelectedHasOfficialRemover
        ? "Run its uninstaller. This can't be undone, and games or apps that need it may stop working."
        : "Delete its files. Games or apps that need them may stop working until you restore them.";

    private readonly List<InstalledApp> _allApps = new();
    private readonly Dictionary<string, string> _cleanupRecoveryByApp = new(StringComparer.Ordinal);
    private readonly Dictionary<string, KeptResult> _keptResults = new(StringComparer.Ordinal);
    private sealed record KeptResult(InstalledApp App, Action Show);
    private sealed record CleanupRun(InstalledApp App, int Generation, string? Verb = null, string? State = null, string? Detail = null)
    {
        public string AppId => App.AppId!;
        public bool KeepsResult => State is not null;
    }
    private CleanupRun? _run;
    private int _resultRuns;
    private string? _lastCleanupRollbackPath;
    private int _selectionGeneration;
    private bool _listChanged;
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<LeftoverItem> Leftovers { get; } = new();

    protected override bool RefreshOnRevisit => SelectedApp is null;
    protected override bool HasUserWork => SelectedApp is not null;
    protected override bool IsWorking => ScanBusy;

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetInstalledAppsAsync(fresh: Fresh);
        var saved = await SavedRecoveriesAsync();
        if (Quiet && SelectedApp is not null) { KeepStale(); return; }
        var listed = inventory?.Apps is { Count: > 0 };
        var complete = listed && inventory!.Complete != false;
        var apps = inventory?.Apps ?? new List<InstalledApp>();
        InventoryNotice = !listed && saved.Count > 0 ? "We couldn't read your installed apps, so only saved cleanups you can restore are listed. Close and reopen to try again." : "";
        if (!listed && saved.Count == 0)
        {
            ErrorMessage = "We couldn't read your installed apps yet. Close and reopen to try again.";
            return;
        }

        _listChanged = false;
        _allApps.Clear();
        var installed = apps.Select(a => a.AppId).OfType<string>().ToHashSet(StringComparer.Ordinal);
        var removed = saved.Where(recovery => !installed.Contains(recovery.AppId)).ToArray();
        foreach (var recovery in removed) _cleanupRecoveryByApp.TryAdd(recovery.AppId, recovery.ManifestPath);
        var rows = apps
            .Where(a => a.IsListable && !Naming.IsNonActionable(a.DisplayName)
                        && !LocalDisplayFilter.Default.IsHidden(a.FriendlyName, null, a.PackageId ?? a.DisplayName))
            .Concat(removed.Select(recovery => new InstalledApp { AppId = recovery.AppId, DisplayName = string.IsNullOrWhiteSpace(recovery.DisplayName) ? "Removed app" : recovery.DisplayName, Removed = true, RemovalUnconfirmed = !complete }))
            .Select(row => row.AppId is { } id && _keptResults.ContainsKey(id) ? row.Waiting() : row)
            .ToList();
        var inventoried = installed.Concat(removed.Select(recovery => recovery.AppId)).ToHashSet(StringComparer.Ordinal);
        rows.AddRange(_keptResults.Values
            .Where(kept => !inventoried.Contains(kept.App.AppId!))
            .Select(kept => new InstalledApp { AppId = kept.App.AppId, DisplayName = kept.App.DisplayName, Removed = true, RemovalUnconfirmed = !complete }.Waiting()));
        _allApps.AddRange(rows.OrderBy(a => a.FriendlyName, StringComparer.OrdinalIgnoreCase));
        AppCount = _allApps.Count(a => !a.Removed);
        Sources = inventory?.Sources is { Count: > 0 } s ? string.Join(", ", s.Select(FriendlySource)) : null;

        ApplyFilter();
        IsEmpty = _allApps.Count == 0;
    }

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnHasSelectionChanged(bool value) => RefreshActionState();
    partial void OnSelectedProtectedChanged(bool value) => RefreshActionState();
    partial void OnScanBusyChanged(bool value)
    {
        RefreshActionState();
        if (value) { StartOwn(); return; }
        if (!FinishOwn()) return;
        _listChanged = true;
        if (SelectedApp is null) ReloadChangedList();
    }

    private void ReloadChangedList()
    {
        if (_listChanged) { _listChanged = false; MarkStale(); }
        _ = RefreshIfStaleAsync();
    }
    partial void OnRemovalPathReviewedChanged(bool value) => RefreshActionState();
    partial void OnLeftoverScanCompletedChanged(bool value) => RefreshActionState();
    partial void OnCleanupPlanReadyChanged(bool value) => RefreshActionState();
    partial void OnCleanupRestoreAvailableChanged(bool value) => RefreshActionState();
    partial void OnRemovalApprovedChanged(bool value) { FinalCheckPassed = false; RefreshActionState(); }

    partial void OnSelectedAppChanged(InstalledApp? value)
    {
        if (value is null) ReloadChangedList();
        _selectionGeneration++;
        RemovalRouteBlocked = false;
        App.Live.DiscardCleanupReview();
        FinalCheckPassed = false;
        Leftovers.Clear();
        LeftoverSummary = null;
        HasSelection = value is not null;

        if (value is null)
        {
            LeftoverState = "Pick an app, then find what it leaves behind.";
            OfficialPreviewState = "Pick an app to see how it uninstalls.";
            CleanupPlanState = "Find leftovers first, then make the removal list.";
            PrimaryRemovalButtonLabel = "Check uninstaller";
            RemovalPlanState = "Make the removal list to see everything that gets removed.";
            RemovalPlanDetail = null;
            CleanupExecutionState = "Remove unlocks after you check the app and make the list.";
            CleanupExecutionDetail = null;
            CleanupRestoreAvailable = false;
            RemovalPathReviewed = false;
            LeftoverScanCompleted = false;
            CleanupPlanReady = false;
            RemovalApproved = false;
            _lastCleanupRollbackPath = null;
            RefreshActionState();
            return;
        }

        SelectedName = value.FriendlyName;
        SelectedProtected = false;
        SelectedHasOfficialRemover = HasVendorRemover(value);
        var bits = new List<string>();
        if (!string.IsNullOrWhiteSpace(value.SecondaryLabel)) bits.Add(value.SecondaryLabel!);
        if (value.EstimatedSizeBytes is > 0) bits.Add(Format.Bytes(value.EstimatedSizeBytes!.Value));
        SelectedSummary = string.Join(" / ", bits);

        InstallLocation = string.IsNullOrWhiteSpace(value.InstallLocation) ? "Not recorded" : value.InstallLocation;
        OfficialCommand = string.IsNullOrWhiteSpace(value.UninstallString)
            ? NoUninstaller
            : value.UninstallString;

        LeftoverState = "Find leftovers to see what this app leaves behind. Nothing is removed.";
        OfficialPreviewState = SelectedHasOfficialRemover
            ? "Ready to check this app's uninstaller."
            : "This app has no uninstaller. Find its leftovers next.";
        CleanupPlanState = "Find leftovers, then make the removal list.";
        RemovalPlanState = "Make the list to see exactly what gets removed.";
        RemovalPlanDetail = null;
        CleanupExecutionState = "Remove is locked until the list is ready.";
        CleanupExecutionDetail = "Check the app, find leftovers and make the list first.";
        SetSelectedRecovery(value.AppId);
        RemovalPathReviewed = false;
        LeftoverScanCompleted = false;
        CleanupPlanReady = false;
        RemovalApproved = false;
        PrimaryRemovalButtonLabel = SelectedHasOfficialRemover ? "Check uninstaller" : "Check app";
        if (value.Removed)
        {
            RemovalRouteBlocked = true;
            OfficialPreviewState = value.RemovalUnconfirmed ? "The installed apps list couldn't be fully read, so only Restore is available here." : "This app is already removed.";
            LeftoverState = "Restore is the only step available for this app here.";
            CleanupExecutionState = CleanupRestoreAvailable ? "An earlier cleanup of this app can be restored." : "This cleanup can't be restored anymore.";
            CleanupExecutionDetail = "Restore puts back the files its cleanup deleted. It doesn't reinstall the app.";
        }
        var shown = ShowRunFor(value.AppId);
        OnPropertyChanged(nameof(ApplyApprovalSummary));
        RefreshActionState();
        if (!CleanupRestoreAvailable && !shown) _ = DiscoverRecoveryAsync(value, _selectionGeneration);
    }

    private void BlockRemovalRoute()
    {
        PrimaryRemovalButtonLabel = "Use Remove apps";
        RemovalPathReviewed = false;
        RemovalRouteBlocked = true;
    }

    [RelayCommand]
    private async Task PreviewRemovalAsync()
    {
        var app = SelectedApp;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || ScanBusy || RemovalRouteBlocked)
        {
            return;
        }

        var generation = _selectionGeneration;
        var run = BeginRun(app);
        OfficialPreviewState = "Checking the uninstaller...";
        RemovalPathReviewed = false;
        CleanupPlanReady = false;
        RemovalApproved = false;
        try
        {
            var result = await App.Live.GetOfficialUninstallPreviewResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var preview = result.Value;
            if (result.Error is not null || preview?.Commands is null || !preview.DryRun || HasBlockingErrors(preview.Errors))
            {
                OfficialPreviewState = Plain(CheckFailed, result.Error ?? FirstError(preview?.Errors) ?? "The route response was incomplete.");
                RemovalPathReviewed = false;
                return;
            }
            var command = preview.Commands.FirstOrDefault(c => c.AppId == app.AppId);
            if (command is null && preview.Commands.Count > 0)
            {
                OfficialPreviewState = Plain(CheckFailed, "The route response belonged to a different app.");
                RemovalPathReviewed = false;
                return;
            }
            if (command is null)
            {
                OfficialPreviewState = "This app has no uninstaller. Its files can be deleted instead.";
                SelectedHasOfficialRemover = false;
                OfficialCommand = NoUninstaller;
                PrimaryRemovalButtonLabel = "Check app";
                RemovalPathReviewed = true;
                return;
            }

            if (string.IsNullOrWhiteSpace(command.CommandLine) && !string.IsNullOrWhiteSpace(command.RawCommand))
            {
                SelectedHasOfficialRemover = false;
                OfficialCommand = command.RawCommand;
                OfficialPreviewState = command.CommandType == "appx-package-removal-preview"
                    ? "Use Remove apps to remove this app."
                    : "This app's uninstaller doesn't point to one exact file, so it won't run here. Use Remove apps to remove this app.";
                BlockRemovalRoute();
                return;
            }

            if (!string.IsNullOrWhiteSpace(command.CommandLine) && string.IsNullOrWhiteSpace(command.ExecutableSha256))
            {
                SelectedHasOfficialRemover = false;
                OfficialCommand = command.CommandLine;
                OfficialPreviewState = command.ExecutableState == "missing"
                    ? "This app's uninstaller file is missing, so it won't run here. Use Remove apps to remove this app."
                    : "This app's uninstaller file can't be read, so it won't run here. Use Remove apps to remove this app.";
                BlockRemovalRoute();
                return;
            }

            SelectedHasOfficialRemover = IsVendorRemover(command);
            OfficialCommand = !string.IsNullOrWhiteSpace(command.CommandLine)
                ? command.CommandLine
                : NoUninstaller;
            PrimaryRemovalButtonLabel = SelectedHasOfficialRemover ? "Check uninstaller" : "Check app";
            OfficialPreviewState = command.Blocked
                ? BlockedHere
                : SelectedHasOfficialRemover
                    ? "Uninstaller checked. Nothing has run yet."
                    : "Checked. Nothing has run yet.";
            RemovalPathReviewed = true;
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                OfficialPreviewState = Plain(CheckFailed, error);
                RemovalPathReviewed = false;
            }
        }
        finally
        {
            FinishOperation(run);
        }
    }

    [RelayCommand]
    private async Task ScanLeftoversAsync()
    {
        var app = SelectedApp;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || ScanBusy || app.Removed)
        {
            return;
        }

        var generation = _selectionGeneration;
        var run = BeginRun(app);
        Leftovers.Clear();
        LeftoverSummary = null;
        LeftoverState = "Looking for leftovers...";
        LeftoverScanCompleted = false;
        CleanupPlanReady = false;
        RemovalApproved = false;
        try
        {
            var result = await App.Live.GetLeftoverScanResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var scan = result.Value;
            if (result.Error is not null || scan?.Items is null || scan.Summary is null || !scan.DryRun
                || !string.Equals(scan.AppId, app.AppId, StringComparison.Ordinal)
                || HasBlockingErrors(scan.Errors))
            {
                LeftoverState = Plain(ScanFailed, result.Error ?? FirstError(scan?.Errors) ?? "The scan response was incomplete.");
                LeftoverScanCompleted = false;
                return;
            }

            var items = scan.Items;
            foreach (var item in items)
            {
                Leftovers.Add(item);
            }

            if (items.Count == 0)
            {
                LeftoverState = "No leftovers found for this app.";
            }
            else
            {
                var recoverable = scan.Summary.EstimatedRecoverableBytes;
                LeftoverSummary = items.Count + (items.Count == 1 ? " leftover" : " leftovers")
                    + (recoverable > 0 ? ", " + Format.Bytes(recoverable) : string.Empty);
                LeftoverState = "Found " + LeftoverSummary + ".";
            }
            LeftoverScanCompleted = true;
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                LeftoverState = Plain(ScanFailed, error);
                LeftoverScanCompleted = false;
            }
        }
        finally
        {
            FinishOperation(run);
        }
    }

    [RelayCommand]
    private async Task BuildCleanupListAsync()
    {
        var app = SelectedApp;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || ScanBusy || !CanBuildCleanupList)
        {
            return;
        }

        var generation = _selectionGeneration;
        var run = BeginRun(app);
        CleanupPlanState = "Making the removal list...";
        CleanupPlanReady = false;
        RemovalApproved = false;
        try
        {
            var manifestResult = await App.Live.GetCleanupManifestResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var manifest = manifestResult.Value;
            if (manifestResult.Error is not null || manifest?.Items is null || manifest.Summary is null || !manifest.DryRun
                || !string.Equals(manifest.AppId, app.AppId, StringComparison.Ordinal)
                || HasBlockingErrors(manifest.Errors))
            {
                CleanupPlanState = Plain("Couldn't make the removal list.", manifestResult.Error ?? FirstError(manifest?.Errors) ?? "The cleanup manifest was incomplete.");
                RemovalPlanState = "Couldn't make the removal list.";
                RemovalPlanDetail = "Find leftovers again, then try again.";
                return;
            }

            var itemCount = manifest.Summary.ItemCount;
            var excludedCount = manifest.Summary.ExcludedCount;
            CleanupPlanState = itemCount == 0
                ? "Removal list ready. Nothing was picked."
                : "Removal list ready: " + itemCount.ToString(CultureInfo.InvariantCulture) + " to remove, " + excludedCount.ToString(CultureInfo.InvariantCulture) + " left alone. Nothing removed yet.";

            var planResult = await App.Live.GetUninstallCleanupExecutionPlanResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var plan = planResult.Value;
            if (planResult.Error is not null || plan?.Summary is null || !plan.DryRun
                || !string.Equals(plan.AppId, app.AppId, StringComparison.Ordinal)
                || string.Equals(plan.Status, "failed", StringComparison.OrdinalIgnoreCase)
                || HasBlockingErrors(plan.Errors))
            {
                RemovalPlanState = "Couldn't plan the removal.";
                RemovalPlanDetail = Plain(PlanFailed, planResult.Error ?? FirstError(plan?.Errors) ?? "The execution plan was incomplete.");
                return;
            }
            SummarizeExecutionPlan(plan, itemCount);
            CleanupPlanReady = true;
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                CleanupPlanState = "Couldn't make the removal list.";
                RemovalPlanState = "Couldn't plan the removal.";
                RemovalPlanDetail = Plain(PlanFailed, error);
                CleanupPlanReady = false;
            }
        }
        finally
        {
            FinishOperation(run);
        }
    }

    [RelayCommand]
    private async Task RunFinalCheckAsync()
    {
        var app = SelectedApp;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || ScanBusy || !CanRunFinalCheck)
        {
            return;
        }

        var generation = _selectionGeneration;
        var run = BeginRun(app);
        CleanupExecutionState = "Running the final check...";
        CleanupExecutionDetail = "Nothing is removed during the check.";
        try
        {
            var result = await App.Live.RequestUninstallCleanupApplyResultAsync(app.AppId!, RemovalApproved, RemovalApproved, false);
            if (!IsCurrent(app, generation)) return;
            SummarizeCleanupExecution(result.Value, app.AppId!, result.Error, false);
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                CleanupExecutionState = "Final check failed.";
                CleanupExecutionDetail = Plain(RetryFinalCheck, error);
                FinalCheckPassed = false;
            }
        }
        finally
        {
            FinishOperation(run);
        }
    }

    [RelayCommand]
    private async Task ApplyCleanupAsync()
    {
        var app = SelectedApp;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || ScanBusy || !CanApplyCleanup)
        {
            return;
        }

        var run = BeginRun(app, "removing", "Removing this app...", ApplyApprovalSummary);
        try
        {
            using var running = RunningChanges.Begin();
            var result = await App.Live.RequestUninstallCleanupApplyResultAsync(app.AppId!, RemovalApproved, RemovalApproved, true);
            CaptureRecovery(app.AppId!, result);
            ShowResult(run, () => SummarizeCleanupExecution(result.Value, run.AppId, result.Error, true));
        }
        catch (InvalidOperationException error) when (error.Message == RunningChanges.Installing)
        {
            CleanupExecutionState = "Removal didn't start.";
            CleanupExecutionDetail = error.Message;
        }
        catch (Exception error)
        {
            ShowResult(run, () => SummarizeCleanupExecution(null, run.AppId, error.Message, true));
        }
        finally
        {
            FinishOperation(run);
        }
    }

    [RelayCommand]
    private async Task RestoreCleanupAsync()
    {
        var app = SelectedApp;
        var rollbackPath = _lastCleanupRollbackPath;
        if (ScanBusy) return;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || string.IsNullOrWhiteSpace(rollbackPath))
        {
            CleanupExecutionState = "Nothing to restore yet.";
            CleanupExecutionDetail = "Restore shows up after a removal deletes something.";
            CleanupRestoreAvailable = false;
            return;
        }

        var run = BeginRun(app, "restoring", "Restoring...", "Putting back what the removal deleted.");
        try
        {
            using var running = RunningChanges.Begin();
            var result = await App.Live.RestoreUninstallCleanupResultAsync(rollbackPath);
            var restored = result.Error is null && IsSuccessfulRestore(result.Value, rollbackPath);
            var markFailed = false;
            if (restored)
            {
                try { App.Live.MarkCleanupRestored(rollbackPath); }
                catch (Exception error) { AppLog.Write(nameof(UninstallCleanupViewModel), error.ToString()); markFailed = true; }
            }
            if (restored && _cleanupRecoveryByApp.TryGetValue(run.AppId, out var retained)
                && string.Equals(retained, rollbackPath, StringComparison.Ordinal))
            {
                _cleanupRecoveryByApp.Remove(run.AppId);
            }
            ShowResult(run, () =>
            {
                SummarizeCleanupRestore(result.Value, result.Error, restored);
                if (markFailed) CleanupExecutionDetail = ((CleanupExecutionDetail ?? "") + " The app couldn't save that this restore finished, so it may offer it again after you reopen the app. Restoring again is safe.").Trim();
            });
        }
        catch (Exception error)
        {
            ShowResult(run, () =>
            {
                CleanupExecutionState = "Restore failed.";
                CleanupExecutionDetail = Plain(RestoreAgain, error);
            });
        }
        finally
        {
            FinishOperation(run);
        }
    }

    private void RefreshActionState()
    {
        CanReviewRemovalAction = CanReviewRemoval;
        CanScanAction = CanScan;
        CanBuildCleanupListAction = CanBuildCleanupList;
        CanRunFinalCheckAction = CanRunFinalCheck;
        CanApplyCleanupAction = CanApplyCleanup;
        CanRestoreCleanupAction = CanRestoreCleanup;
    }

    private void ApplyFilter()
    {
        var query = SearchText?.Trim();
        IEnumerable<InstalledApp> source = _allApps;
        if (!string.IsNullOrEmpty(query))
        {
            source = source.Where(a =>
                Contains(a.FriendlyName, query) ||
                Contains(a.PublisherDisplay, query));
        }

        Apps.SyncWith(source);
    }

    private static bool Contains(string? haystack, string needle)
        => haystack is not null && haystack.Contains(needle, StringComparison.OrdinalIgnoreCase);

    private void SummarizeExecutionPlan(UninstallCleanupExecutionPlan? plan, int manifestItemCount)
    {
        var summary = plan?.Summary;
        if (summary is null)
        {
            RemovalPlanState = "Couldn't read the removal plan.";
            RemovalPlanDetail = "Make the list again.";
            return;
        }

        var commandCount = summary.CommandPreviewCount;
        var cleanupCount = summary.CleanupItemCount > 0 ? summary.CleanupItemCount : manifestItemCount;
        var gateCount = summary.BlockingGateCount;
        var runnerReady = summary.AllowlistedOfficialRunnerReady || summary.DisposableFixtureExecutionReady;

        RemovalPlanState = commandCount > 0
            ? "Ready: the app's uninstaller runs. Afterwards, find leftovers again to clean up what it leaves."
            : "Ready: " + cleanupCount.ToString(CultureInfo.InvariantCulture) + (cleanupCount == 1 ? " item gets" : " items get") + " deleted, and they're backed up first.";

        var runnerLine = runnerReady ? "" : "This removal needs one more check before it can run. ";
        var gateLine = gateCount > 0
            ? gateCount.ToString(CultureInfo.InvariantCulture) + (gateCount == 1 ? " safety check has" : " safety checks have") + " to pass before anything is removed."
            : "Nothing is blocking this removal.";
        RemovalPlanDetail = runnerLine + gateLine + " Nothing has been removed yet.";
    }

    private void SummarizeCleanupExecution(string? json, string expectedAppId, string? operationError, bool applied)
    {
        void NotConfirmed(string? detail)
        {
            CleanupExecutionState = applied ? "Couldn't confirm the removal." : "The final check didn't finish.";
            CleanupExecutionDetail = Plain(applied ? RetryRemoval : RetryFinalCheck, detail);
            FinalCheckPassed = false;
            SetSelectedRecovery(expectedAppId);
        }

        if (string.IsNullOrWhiteSpace(json) || operationError is not null)
        {
            NotConfirmed(operationError);
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!string.Equals(ExtractString(root, "actionId"), "apps.invokeUninstallCleanupApplyPackage", StringComparison.Ordinal))
            {
                NotConfirmed("The response identity did not match this cleanup operation.");
                return;
            }
            if (!string.Equals(ExtractString(root, "appId"), expectedAppId, StringComparison.Ordinal))
            {
                NotConfirmed("The response belonged to a different cleanup operation.");
                return;
            }
            var status = ExtractString(root, "status") ?? "preview";
            var mode = ExtractString(root, "executionMode") ?? "preview";
            var hasDryRun = TryExtractBool(root, out var dryRun, "dryRun");
            var blocking = ExtractInt(root, "summary", "blockingGateCount");
            var deleted = ExtractInt(root, "summary", "deletedCount");
            var cleanupItems = ExtractInt(root, "summary", "cleanupItemCount");

            if (!hasDryRun
                || (!applied && (!dryRun || status is not ("preview" or "blocked" or "failed")))
                || (applied && (status == "preview" || dryRun && status is ("success" or "partial" or "cleanup-review-required"))))
            {
                NotConfirmed("The response mode did not match the requested operation.");
                return;
            }

            if ((status == "preview" && (mode != "preview" || !GatesPermit(root, true)))
                || (status == "success" && (mode != "real" || !GatesPermit(root, false))))
            {
                NotConfirmed("The response contains missing or conflicting completion checks.");
                return;
            }

            if (status == "cleanup-review-required")
            {
                CleanupExecutionState = "App removed. Find leftovers again to clean up what it left.";
                CleanupExecutionDetail = "Its uninstaller may have changed things, so the old list wasn't used.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }
            if (status == "success")
            {
                SetSelectedRecovery(expectedAppId);
                CleanupExecutionState = deleted > 0
                    ? "Done: " + deleted.ToString(CultureInfo.InvariantCulture) + " item" + (deleted == 1 ? "" : "s") + " removed."
                    : "Done. Nothing needed removing.";
                CleanupExecutionDetail = CleanupRestoreAvailable
                    ? "Restore can put them back."
                    : "No backup was confirmed, so Restore isn't offered.";
                return;
            }

            if (status == "needs-reconciliation")
            {
                CleanupExecutionState = "Check whether the app is gone.";
                CleanupExecutionDetail = "Its uninstaller was still running, so it was left to finish. When it's done, find leftovers again.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }
            if (status is "partial" or "failed")
            {
                CleanupExecutionState = status == "partial" ? "Removal stopped partway." : "Removal failed.";
                CleanupExecutionDetail = deleted.ToString(CultureInfo.InvariantCulture) + (deleted == 1 ? " item was" : " items were") + " removed. " + RetryRemoval;
                SetSelectedRecovery(expectedAppId);
                return;
            }

            if (status == "preview")
            {
                FinalCheckPassed = ExtractBool(root, "summary", "approvalReady");
                CleanupExecutionState = FinalCheckPassed ? "Final check passed." : "Final check didn't pass.";
                CleanupExecutionDetail = FinalCheckPassed
                    ? "Checked " + cleanupItems.ToString(CultureInfo.InvariantCulture) + (cleanupItems == 1 ? " file or folder" : " files and folders") + ". Nothing was removed yet."
                    : "Nothing was removed. Make the list again, then run the final check.";
                SetSelectedRecovery(expectedAppId);
                return;
            }

            CleanupExecutionState = status == "blocked"
                ? "Not ready to remove yet."
                : "Final check done.";
            CleanupExecutionDetail = blocking > 0
                ? blocking.ToString(CultureInfo.InvariantCulture) + (blocking == 1 ? " safety check hasn't" : " safety checks haven't") + " passed. Nothing was removed."
                : "Nothing was removed.";
            SetSelectedRecovery(expectedAppId);
        }
        catch (Exception error)
        {
            CleanupExecutionState = "Couldn't read the result.";
            CleanupExecutionDetail = Plain(applied ? RetryRemoval : RetryFinalCheck, operationError ?? error.ToString());
            FinalCheckPassed = false;
            SetSelectedRecovery(expectedAppId);
        }
    }

    private void SummarizeCleanupRestore(string? json, string? operationError, bool restoreSucceeded)
    {
        if (string.IsNullOrWhiteSpace(json) || operationError is not null)
        {
            CleanupExecutionState = "Couldn't confirm the restore.";
            CleanupExecutionDetail = Plain(RestoreAgain, operationError);
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var status = ExtractString(root, "status") ?? "preview";
            var restoredCount = ExtractInt(root, "summary", "restoredCount");
            var blocking = ExtractInt(root, "summary", "blockingGateCount");
            if (status == "success" && restoreSucceeded)
            {
                CleanupExecutionState = "Restore complete: " + restoredCount.ToString(CultureInfo.InvariantCulture) + " item" + (restoredCount == 1 ? "" : "s") + " put back.";
                CleanupExecutionDetail = "Only what this removal deleted was put back.";
                _lastCleanupRollbackPath = null;
                CleanupRestoreAvailable = false;
            }
            else if (status == "success")
            {
                CleanupExecutionState = "Couldn't confirm the restore.";
                CleanupExecutionDetail = Plain(RestoreAgain, "The restore response did not match the requested rollback operation.");
            }
            else
            {
                CleanupExecutionState = "Restore didn't finish.";
                CleanupExecutionDetail = (blocking > 0 ? blocking.ToString(CultureInfo.InvariantCulture) + (blocking == 1 ? " safety check" : " safety checks") + " didn't pass. " : "") + RestoreAgain;
            }
        }
        catch (Exception error)
        {
            CleanupExecutionState = "Couldn't read the restore result.";
            CleanupExecutionDetail = Plain(RestoreAgain, operationError ?? error.ToString());
        }
    }

    private bool IsCurrent(InstalledApp app, int generation)
        => generation == _selectionGeneration
            && ReferenceEquals(SelectedApp, app)
            && string.Equals(SelectedApp?.AppId, app.AppId, StringComparison.Ordinal);

    private CleanupRun BeginRun(InstalledApp app, string? verb = null, string? state = null, string? detail = null)
    {
        var run = new CleanupRun(app, _selectionGeneration, verb, state, detail);
        _run = run;
        if (run.KeepsResult) _resultRuns++;
        ScanBusy = true;
        if (run.KeepsResult) ShowRunFor(run.AppId);
        return run;
    }

    private bool ShowRunFor(string? appId)
    {
        if (_run is { KeepsResult: true } run && run.AppId == appId)
        {
            CleanupExecutionState = run.State!;
            CleanupExecutionDetail = run.Detail;
            return true;
        }
        if (appId is null || !_keptResults.Remove(appId, out var kept)) return false;
        _listChanged = true;
        kept.Show();
        return true;
    }

    private string? WaitingNotice => _run is not { } run || run.Generation == _selectionGeneration && SelectedApp?.AppId == run.AppId
        ? null
        : !run.KeepsResult
            ? "Still checking " + run.App.FriendlyName + ". Wait for it to finish."
            : SelectedApp?.AppId == run.AppId
                ? "Still " + run.Verb + " this app. The result shows here when it's done."
                : "Still " + run.Verb + " " + run.App.FriendlyName + ". Pick it again to see the result.";

    private void ShowResult(CleanupRun run, Action show)
    {
        if (SelectedApp?.AppId == run.AppId) show();
        else _keptResults[run.AppId] = new KeptResult(run.App, show);
    }

    private void FinishOperation(CleanupRun run)
    {
        if (!ReferenceEquals(_run, run)) return;
        _run = null;
        ScanBusy = false;
        if (!CleanupRestoreAvailable && SelectedApp?.AppId is { Length: > 0 } selected && _cleanupRecoveryByApp.ContainsKey(selected)) SetSelectedRecovery(selected);
        RefreshActionState();
    }

    private const string NoUninstaller = "No uninstaller. The app's files get deleted instead, and they're backed up first.";
    public const string BlockedHere = "Windows, games or other apps may need this app, so this tab won't remove it. Use Remove apps to remove it.";
    private const string CheckFailed = "Couldn't check this app's uninstaller. Try again, or use Remove apps.";
    private const string ScanFailed = "Couldn't look for leftovers. Try again.";
    private const string PlanFailed = "Make the list again. If it keeps failing, send a bug report.";
    private const string RetryFinalCheck = "Nothing was removed. Try the final check again.";
    private const string RetryRemoval = "If Restore is offered, use it before you try again.";
    private const string RestoreAgain = "The backup is still saved, so you can try Restore again.";

    private static string Plain(string message, string? detail)
    {
        if (detail is AppLog.MissingFiles or AppLog.TimedOut or RunningChanges.Installing) return detail;
        AppLog.Write(nameof(UninstallCleanupViewModel), detail);
        return message;
    }

    private static string Plain(string message, Exception error)
        => error.Message is AppLog.MissingFiles or AppLog.TimedOut or RunningChanges.Installing ? error.Message : Plain(message, error.ToString());

    private static bool HasBlockingErrors(IEnumerable<IssueModel>? errors)
        => errors?.Any(error => error.Blocking) == true;

    private static string? FirstError(IEnumerable<IssueModel>? errors)
        => errors?.FirstOrDefault(error => error.Blocking)?.Message
            ?? errors?.FirstOrDefault()?.Message;

    private void CaptureRecovery(string appId, Services.LiveDataResult<string> result)
    {
        string? rollback = null;
        var restoreReady = false;
        var responseBound = false;
        if (!string.IsNullOrWhiteSpace(result.Value))
        {
            try
            {
                using var doc = JsonDocument.Parse(result.Value);
                var root = doc.RootElement;
                if (string.Equals(ExtractString(root, "actionId"), "apps.invokeUninstallCleanupApplyPackage", StringComparison.Ordinal)
                    && string.Equals(ExtractString(root, "appId"), appId, StringComparison.Ordinal))
                {
                    responseBound = true;
                    rollback = ExtractString(root, "rollback", "rollbackManifestPath") ?? ExtractString(root, "rollbackManifestPath");
                    restoreReady = ExtractBool(root, "summary", "restoreReady");
                }
            }
            catch
            {
            }
        }

        string? candidate;
        if (responseBound)
        {
            candidate = restoreReady
                && (string.IsNullOrWhiteSpace(result.RecoveryPath) || string.Equals(rollback, result.RecoveryPath, StringComparison.Ordinal))
                    ? rollback
                    : null;
        }
        else
        {
            candidate = result.RecoveryPath;
        }
        if (IsValidRecovery(candidate, appId))
        {
            _cleanupRecoveryByApp[appId] = candidate!;
        }
    }

    private static async Task<IReadOnlyList<CleanupRecovery>> SavedRecoveriesAsync()
    {
        try { return await App.Live.FindCleanupRecoveriesAsync(); }
        catch (Exception error) { AppLog.Write(nameof(UninstallCleanupViewModel), error.ToString()); return []; }
    }

    private async Task DiscoverRecoveryAsync(InstalledApp app, int generation)
    {
        if (string.IsNullOrWhiteSpace(app.AppId)) return;
        var runs = _resultRuns;
        string? saved;
        try { saved = await App.Live.FindCleanupRecoveryAsync(app.AppId); }
        catch (Exception error) { AppLog.Write(nameof(UninstallCleanupViewModel), error.ToString()); return; }
        if (!IsCurrent(app, generation) || runs != _resultRuns || !IsValidRecovery(saved, app.AppId)) return;
        _cleanupRecoveryByApp.TryAdd(app.AppId, saved!);
        if (_run?.AppId == app.AppId || CleanupRestoreAvailable) return;
        SetSelectedRecovery(app.AppId);
        CleanupExecutionState = "An earlier cleanup of this app can be restored.";
        CleanupExecutionDetail = "Restore puts back the files its cleanup deleted. It doesn't reinstall the app.";
    }

    private void SetSelectedRecovery(string? appId)
    {
        if (!string.IsNullOrWhiteSpace(appId)
            && _cleanupRecoveryByApp.TryGetValue(appId, out var path)
            && IsValidRecovery(path, appId))
        {
            _lastCleanupRollbackPath = path;
            CleanupRestoreAvailable = true;
            return;
        }

        if (!string.IsNullOrWhiteSpace(appId)) _cleanupRecoveryByApp.Remove(appId);
        _lastCleanupRollbackPath = null;
        CleanupRestoreAvailable = false;
    }

    private static bool IsValidRecovery(string? path, string appId)
    {
        if (string.IsNullOrWhiteSpace(path) || !System.IO.File.Exists(path)) return false;
        try
        {
            using var doc = JsonDocument.Parse(System.IO.File.ReadAllText(path));
            var root = doc.RootElement;
            return string.Equals(ExtractString(root, "appId"), appId, StringComparison.Ordinal)
                && ExtractBool(root, "executionStarted")
                && ExtractBool(root, "restoreSupported")
                && root.TryGetProperty("fileBackups", out var backups)
                && backups.ValueKind == JsonValueKind.Array
                && backups.GetArrayLength() > 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsSuccessfulRestore(string? json, string rollbackPath)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            return string.Equals(ExtractString(root, "actionId"), "apps.restoreUninstallCleanupExecution", StringComparison.Ordinal)
                && string.Equals(ExtractString(root, "status"), "success", StringComparison.OrdinalIgnoreCase)
                && string.Equals(ExtractString(root, "rollbackManifestPath"), rollbackPath, StringComparison.Ordinal)
                && TryExtractBool(root, out var dryRun, "dryRun")
                && !dryRun
                && GatesPermit(root, false)
                && ExtractString(root, "executionMode") is ("real-system-restore" or "disposable-fixture-restore")
                && root.TryGetProperty("restoredItems", out var restored) && restored.ValueKind == JsonValueKind.Array
                && restored.GetArrayLength() == ExtractInt(root, "summary", "restoredCount")
                && restored.EnumerateArray().All(item => ExtractBool(item, "restored"));
        }
        catch
        {
            return false;
        }
    }

    private static bool GatesPermit(JsonElement root, bool preview)
    {
        if (!root.TryGetProperty("gates", out var gates) || gates.ValueKind != JsonValueKind.Array || gates.GetArrayLength() == 0
            || !root.TryGetProperty("errors", out var errors) || errors.ValueKind != JsonValueKind.Array
            || errors.EnumerateArray().Any(issue => !TryExtractBool(issue, out var blocking, "blocking") || blocking)
            || !root.TryGetProperty("summary", out var summary) || !summary.TryGetProperty("blockingGateCount", out var count)
            || !count.TryGetInt32(out var reported)) return false;
        var actual = 0;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var gate in gates.EnumerateArray())
        {
            var id = ExtractString(gate, "gateId");
            if (string.IsNullOrWhiteSpace(id) || !ids.Add(id)
                || !TryExtractBool(gate, out var required, "required")
                || !TryExtractBool(gate, out var satisfied, "satisfied")
                || !TryExtractBool(gate, out var blocking, "blocking")
                || blocking != (required && !satisfied)) return false;
            if (!blocking) continue;
            actual++;
            if (!preview || id is not ("confirm-apply" or "real-mode-selected" or "explicit-user-approval" or "real-system-flag")) return false;
        }
        return actual == reported;
    }

    private static bool HasVendorRemover(InstalledApp app)
        => !string.IsNullOrWhiteSpace(app.UninstallString);

    private static bool IsVendorRemover(UninstallCommand command)
    {
        if (command.Blocked || string.IsNullOrWhiteSpace(command.RawCommand))
        {
            return false;
        }

        return command.CommandType is "msi-uninstall-string" or "registry-uninstall-string";
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

    private static int ExtractInt(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return 0;
            }
        }

        return current.ValueKind == JsonValueKind.Number && current.TryGetInt32(out var value) ? value : 0;
    }

    private static bool ExtractBool(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return false;
            }
        }

        return current.ValueKind == JsonValueKind.True || (current.ValueKind == JsonValueKind.String && bool.TryParse(current.GetString(), out var value) && value);
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

    private static string FriendlySource(string? source) => source switch
    {
        "registry" => "Installed program",
        "msi" => "Windows Installer",
        "appx" => "Store app",
        "winget" => "Winget",
        null or "" => "App",
        _ => source!,
    };
}
