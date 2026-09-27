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
    private bool _scanBusy;
    [ObservableProperty] private string _leftoverState = "Pick an app, then scan what it leaves behind.";
    [ObservableProperty] private string? _leftoverSummary;
    [ObservableProperty] private string _officialPreviewState = "Pick an app to choose the removal route.";
    [ObservableProperty] private string _cleanupPlanState = "Scan first, then build the removal list.";
    [ObservableProperty] private string _primaryRemovalButtonLabel = "Check path";
    [ObservableProperty] private string _removalPlanState = "Build the removal list to see the full run.";
    [ObservableProperty] private string? _removalPlanDetail;
    [ObservableProperty] private string _cleanupExecutionState = "Apply unlocks after the route and cleanup list are reviewed.";
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
    private bool _removerPathApproved;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    private bool _cleanupListApproved;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    private bool _realCleanupApproved;
    [ObservableProperty] private bool _canReviewRemovalAction;
    [ObservableProperty] private bool _canScanAction;
    [ObservableProperty] private bool _canBuildCleanupListAction;
    [ObservableProperty] private bool _canRunFinalCheckAction;
    [ObservableProperty] private bool _canApplyCleanupAction;
    [ObservableProperty] private bool _canRestoreCleanupAction;

    public bool CanScan => HasSelection && !ScanBusy;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ApplyApprovalSummary))]
    private bool _removalRouteBlocked;
    partial void OnRemovalRouteBlockedChanged(bool value) => RefreshActionState();
    public bool CanReviewRemoval => HasSelection && !ScanBusy && !RemovalRouteBlocked;
    public bool CanBuildCleanupList => HasSelection && !ScanBusy && RemovalPathReviewed && LeftoverScanCompleted;
    public bool CanRunFinalCheck => HasSelection && !ScanBusy && CleanupPlanReady && RemoverPathApproved && CleanupListApproved;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanApplyCleanup))]
    private bool _finalCheckPassed;
    partial void OnFinalCheckPassedChanged(bool value) => RefreshActionState();
    public bool CanApplyCleanup => CanRunFinalCheck && RealCleanupApproved && FinalCheckPassed;
    public bool CanRestoreCleanup => HasSelection && !ScanBusy && CleanupRestoreAvailable;
    public string ApplyApprovalSummary => !HasSelection
        ? "Pick an app first."
        : RemovalRouteBlocked
            ? "Roo Industries can't run this app's remover. Use Remove apps to remove it."
            : !RemovalPathReviewed
                ? "Check the removal route first."
                : !LeftoverScanCompleted
                    ? "Scan leftovers next."
                    : !CleanupPlanReady
                        ? "Build the removal list."
                        : RemoverPathApproved && CleanupListApproved && RealCleanupApproved
                            ? (FinalCheckPassed ? "Ready to apply the reviewed cleanup." : "Run the final check before applying.")
                            : RemoverPathApproved && CleanupListApproved
                                ? "Final check is ready. Tick final approval when you want files removed."
                            : "Check both review boxes to unlock apply.";
    public string RemovalPanelLabel => "ROO INDUSTRIES REMOVER";
    public string RemovalPathHeadline => SelectedHasOfficialRemover
        ? "Use the app path first"
        : "Use the Roo Industries removal route";
    public string RemovalPathHelp => SelectedHasOfficialRemover
        ? "Roo Industries checks the app's own remover, then scans what it leaves behind."
        : "Some apps do not publish a Windows removal command. Roo Industries can still build the run from traces and leftovers.";

    private readonly List<InstalledApp> _allApps = new();
    private readonly Dictionary<string, string> _cleanupRecoveryByApp = new(StringComparer.Ordinal);
    private string? _lastCleanupRollbackPath;
    private int _selectionGeneration;
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<LeftoverItem> Leftovers { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetInstalledAppsAsync();
        var apps = inventory?.Apps;
        if (apps is null || apps.Count == 0)
        {
            ErrorMessage = "We couldn't read your installed apps yet. Close and reopen to try again.";
            return;
        }

        _allApps.Clear();
        _allApps.AddRange(apps
            .Where(a => a.IsListable && !Naming.IsNonActionable(a.DisplayName)
                        && !LocalDisplayFilter.Default.IsHidden(a.FriendlyName, null, a.PackageId ?? a.DisplayName))
            .OrderBy(a => a.FriendlyName, StringComparer.OrdinalIgnoreCase));
        AppCount = _allApps.Count;
        Sources = inventory!.Sources is { Count: > 0 } s ? string.Join(", ", s.Select(FriendlySource)) : null;

        ApplyFilter();
        IsEmpty = _allApps.Count == 0;
    }

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnHasSelectionChanged(bool value) => RefreshActionState();
    partial void OnSelectedProtectedChanged(bool value) => RefreshActionState();
    partial void OnScanBusyChanged(bool value) => RefreshActionState();
    partial void OnRemovalPathReviewedChanged(bool value) => RefreshActionState();
    partial void OnLeftoverScanCompletedChanged(bool value) => RefreshActionState();
    partial void OnCleanupPlanReadyChanged(bool value) => RefreshActionState();
    partial void OnCleanupRestoreAvailableChanged(bool value) => RefreshActionState();
    partial void OnRemoverPathApprovedChanged(bool value) { FinalCheckPassed = false; RefreshActionState(); }
    partial void OnCleanupListApprovedChanged(bool value) { FinalCheckPassed = false; RefreshActionState(); }
    partial void OnRealCleanupApprovedChanged(bool value) => RefreshActionState();

    partial void OnSelectedAppChanged(InstalledApp? value)
    {
        _selectionGeneration++;
        ScanBusy = false;
        RemovalRouteBlocked = false;
        App.Live.DiscardCleanupReview();
        FinalCheckPassed = false;
        Leftovers.Clear();
        LeftoverSummary = null;
        HasSelection = value is not null;

        if (value is null)
        {
            LeftoverState = "Pick an app, then scan what it leaves behind.";
            OfficialPreviewState = "Pick an app to choose the removal route.";
            CleanupPlanState = "Scan first, then build the removal list.";
            PrimaryRemovalButtonLabel = "Check path";
            RemovalPlanState = "Build the removal list to see the full run.";
            RemovalPlanDetail = null;
            CleanupExecutionState = "Apply unlocks after the route and cleanup list are reviewed.";
            CleanupExecutionDetail = null;
            CleanupRestoreAvailable = false;
            RemovalPathReviewed = false;
            LeftoverScanCompleted = false;
            CleanupPlanReady = false;
            RemoverPathApproved = false;
            CleanupListApproved = false;
            RealCleanupApproved = false;
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
            ? "Roo Industries route. The app did not publish its own remover, so the cleanup run starts from traces and leftovers."
            : value.UninstallString;

        LeftoverState = "Run a leftover scan. Nothing is removed.";
        OfficialPreviewState = SelectedHasOfficialRemover
            ? "Ready to check the app's own remover."
            : "Roo Industries route selected. Scan leftovers next.";
        CleanupPlanState = "Scan leftovers, then build the removal list.";
        RemovalPlanState = "Build the list to see exactly what Roo Industries will ask to remove.";
        RemovalPlanDetail = null;
        CleanupExecutionState = "Apply is locked until review is done.";
        CleanupExecutionDetail = "Check the route, scan leftovers, build the list, then approve the exact run.";
        SetSelectedRecovery(value.AppId);
        RemovalPathReviewed = false;
        LeftoverScanCompleted = false;
        CleanupPlanReady = false;
        RemoverPathApproved = false;
        CleanupListApproved = false;
        RealCleanupApproved = false;
        PrimaryRemovalButtonLabel = SelectedHasOfficialRemover ? "Check path" : "Plan removal";
        RefreshActionState();
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
        ScanBusy = true;
        OfficialPreviewState = "Checking app path...";
        RemovalPathReviewed = false;
        CleanupPlanReady = false;
        RemoverPathApproved = false;
        CleanupListApproved = false;
        RealCleanupApproved = false;
        try
        {
            var result = await App.Live.GetOfficialUninstallPreviewResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var preview = result.Value;
            if (result.Error is not null || preview?.Commands is null || !preview.DryRun || HasBlockingErrors(preview.Errors))
            {
                OfficialPreviewState = "Couldn't check this path: " + (result.Error ?? FirstError(preview?.Errors) ?? "The route response was incomplete.");
                RemovalPathReviewed = false;
                return;
            }
            var command = preview.Commands.FirstOrDefault(c => c.AppId == app.AppId);
            if (command is null && preview.Commands.Count > 0)
            {
                OfficialPreviewState = "Couldn't check this path: The route response belonged to a different app.";
                RemovalPathReviewed = false;
                return;
            }
            if (command is null)
            {
                OfficialPreviewState = "Roo Industries route selected. No app remover is needed to keep building the plan.";
                SelectedHasOfficialRemover = false;
                OfficialCommand = "Roo Industries route. The cleanup run starts from app traces and leftovers.";
                PrimaryRemovalButtonLabel = "Plan removal";
                RemovalPathReviewed = true;
                return;
            }

            if (string.IsNullOrWhiteSpace(command.CommandLine) && !string.IsNullOrWhiteSpace(command.RawCommand))
            {
                SelectedHasOfficialRemover = false;
                OfficialCommand = command.RawCommand;
                OfficialPreviewState = command.CommandType == "appx-package-removal-preview"
                    ? "Use Remove apps to remove this app."
                    : "Couldn't check this path: its remover doesn't point to one exact file, so Roo Industries won't run it. Use Remove apps to remove this app.";
                BlockRemovalRoute();
                return;
            }

            if (!string.IsNullOrWhiteSpace(command.CommandLine) && string.IsNullOrWhiteSpace(command.ExecutableSha256))
            {
                SelectedHasOfficialRemover = false;
                OfficialCommand = command.CommandLine;
                OfficialPreviewState = command.ExecutableState == "missing"
                    ? "Couldn't check this path: the remover file is missing, so Roo Industries won't run it. Use Remove apps to remove this app."
                    : "Couldn't check this path: the remover file can't be read, so Roo Industries won't run it. Use Remove apps to remove this app.";
                BlockRemovalRoute();
                return;
            }

            SelectedHasOfficialRemover = IsVendorRemover(command);
            OfficialCommand = !string.IsNullOrWhiteSpace(command.CommandLine)
                ? command.CommandLine
                : "Roo Industries route. The cleanup run starts from app traces and leftovers.";
            PrimaryRemovalButtonLabel = SelectedHasOfficialRemover ? "Check path" : "Plan removal";
            OfficialPreviewState = command.Blocked
                ? "This route needs review, but it does not stop the cleanup plan."
                : SelectedHasOfficialRemover
                    ? "Path checked. Roo Industries has not run it."
                    : "Roo Industries route checked. Nothing has run.";
            RemovalPathReviewed = true;
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                OfficialPreviewState = "Couldn't check this path: " + error.Message;
                RemovalPathReviewed = false;
            }
        }
        finally
        {
            FinishOperation(generation);
        }
    }

    [RelayCommand]
    private async Task ScanLeftoversAsync()
    {
        var app = SelectedApp;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || ScanBusy)
        {
            return;
        }

        var generation = _selectionGeneration;
        ScanBusy = true;
        Leftovers.Clear();
        LeftoverSummary = null;
        LeftoverState = "Scanning for leftovers...";
        LeftoverScanCompleted = false;
        CleanupPlanReady = false;
        CleanupListApproved = false;
        RealCleanupApproved = false;
        try
        {
            var result = await App.Live.GetLeftoverScanResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var scan = result.Value;
            if (result.Error is not null || scan?.Items is null || scan.Summary is null || !scan.DryRun
                || !string.Equals(scan.AppId, app.AppId, StringComparison.Ordinal)
                || HasBlockingErrors(scan.Errors))
            {
                LeftoverState = "Couldn't scan this app: " + (result.Error ?? FirstError(scan?.Errors) ?? "The scan response was incomplete.");
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
                LeftoverState = "No leftover targets found for this app.";
            }
            else
            {
                var recoverable = scan.Summary.EstimatedRecoverableBytes;
                LeftoverSummary = items.Count + " item" + (items.Count == 1 ? "" : "s")
                    + (recoverable > 0 ? " / " + Format.Bytes(recoverable) + " recoverable" : string.Empty);
                LeftoverState = "Scan found " + LeftoverSummary + ".";
            }
            LeftoverScanCompleted = true;
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                LeftoverState = "Couldn't scan this app: " + error.Message;
                LeftoverScanCompleted = false;
            }
        }
        finally
        {
            FinishOperation(generation);
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
        ScanBusy = true;
        CleanupPlanState = "Building the removal list...";
        CleanupPlanReady = false;
        RemoverPathApproved = false;
        CleanupListApproved = false;
        try
        {
            var manifestResult = await App.Live.GetCleanupManifestResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var manifest = manifestResult.Value;
            if (manifestResult.Error is not null || manifest?.Items is null || manifest.Summary is null || !manifest.DryRun
                || !string.Equals(manifest.AppId, app.AppId, StringComparison.Ordinal)
                || HasBlockingErrors(manifest.Errors))
            {
                CleanupPlanState = "Couldn't build the removal list: " + (manifestResult.Error ?? FirstError(manifest?.Errors) ?? "The cleanup manifest was incomplete.");
                RemovalPlanState = "Removal plan unavailable.";
                RemovalPlanDetail = "Review the scan response, then try again.";
                return;
            }

            var itemCount = manifest.Summary.ItemCount;
            var excludedCount = manifest.Summary.ExcludedCount;
            CleanupPlanState = itemCount == 0
                ? "Removal list built. Nothing was selected."
                : "Removal list built: " + itemCount.ToString(CultureInfo.InvariantCulture) + " selected, " + excludedCount.ToString(CultureInfo.InvariantCulture) + " not selected. Nothing removed.";

            var planResult = await App.Live.GetUninstallCleanupExecutionPlanResultAsync(app.AppId!);
            if (!IsCurrent(app, generation)) return;
            var plan = planResult.Value;
            if (planResult.Error is not null || plan?.Summary is null || !plan.DryRun
                || !string.Equals(plan.AppId, app.AppId, StringComparison.Ordinal)
                || string.Equals(plan.Status, "failed", StringComparison.OrdinalIgnoreCase)
                || HasBlockingErrors(plan.Errors))
            {
                RemovalPlanState = "Couldn't build the run.";
                RemovalPlanDetail = planResult.Error ?? FirstError(plan?.Errors) ?? "The execution plan was incomplete.";
                return;
            }
            SummarizeExecutionPlan(plan, itemCount);
            CleanupPlanReady = true;
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                CleanupPlanState = "Couldn't build the removal list right now.";
                RemovalPlanState = "Couldn't build the run right now.";
                RemovalPlanDetail = error.Message;
                CleanupPlanReady = false;
            }
        }
        finally
        {
            FinishOperation(generation);
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
        ScanBusy = true;
        CleanupExecutionState = "Running final check...";
        CleanupExecutionDetail = "Roo Industries is checking the reviewed route and removal list. Nothing will be removed.";
        try
        {
            var result = await App.Live.RequestUninstallCleanupApplyResultAsync(app.AppId!, RemoverPathApproved, CleanupListApproved, false);
            if (!IsCurrent(app, generation)) return;
            SummarizeCleanupExecution(result.Value, app.AppId!, result.Error, false);
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                CleanupExecutionState = "Final check failed.";
                CleanupExecutionDetail = error.Message + " Nothing was removed.";
                FinalCheckPassed = false;
            }
        }
        finally
        {
            FinishOperation(generation);
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

        var generation = _selectionGeneration;
        ScanBusy = true;
        CleanupExecutionState = "Applying reviewed cleanup...";
        CleanupExecutionDetail = ApplyApprovalSummary;
        try
        {
            var result = await App.Live.RequestUninstallCleanupApplyResultAsync(app.AppId!, RemoverPathApproved, CleanupListApproved, true);
            CaptureRecovery(app.AppId!, result);
            if (!IsCurrent(app, generation)) return;
            SummarizeCleanupExecution(result.Value, app.AppId!, result.Error, true);
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                SummarizeCleanupExecution(null, app.AppId!, error.Message, true);
            }
        }
        finally
        {
            FinishOperation(generation);
        }
    }

    [RelayCommand]
    private async Task RestoreCleanupAsync()
    {
        var app = SelectedApp;
        var rollbackPath = _lastCleanupRollbackPath;
        if (app is null || string.IsNullOrWhiteSpace(app.AppId) || string.IsNullOrWhiteSpace(rollbackPath) || ScanBusy)
        {
            CleanupExecutionState = "Nothing to restore yet.";
            CleanupExecutionDetail = "Restore appears after an apply run writes rollback data.";
            CleanupRestoreAvailable = false;
            return;
        }

        var generation = _selectionGeneration;
        ScanBusy = true;
        CleanupExecutionState = "Restoring cleanup...";
        CleanupExecutionDetail = "Reading the rollback file and putting cleanup targets back.";
        try
        {
            var result = await App.Live.RestoreUninstallCleanupResultAsync(rollbackPath);
            var restored = result.Error is null && IsSuccessfulRestore(result.Value, rollbackPath);
            if (restored && _cleanupRecoveryByApp.TryGetValue(app.AppId!, out var retained)
                && string.Equals(retained, rollbackPath, StringComparison.Ordinal))
            {
                _cleanupRecoveryByApp.Remove(app.AppId!);
            }
            if (!IsCurrent(app, generation)) return;
            SummarizeCleanupRestore(result.Value, result.Error, restored);
        }
        catch (Exception error)
        {
            if (IsCurrent(app, generation))
            {
                CleanupExecutionState = "Restore failed.";
                CleanupExecutionDetail = error.Message;
            }
        }
        finally
        {
            FinishOperation(generation);
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

        Apps.Clear();
        foreach (var a in source)
        {
            Apps.Add(a);
        }
    }

    private static bool Contains(string? haystack, string needle)
        => haystack is not null && haystack.Contains(needle, StringComparison.OrdinalIgnoreCase);

    private void SummarizeExecutionPlan(UninstallCleanupExecutionPlan? plan, int manifestItemCount)
    {
        var summary = plan?.Summary;
        if (summary is null)
        {
            RemovalPlanState = "Removal plan could not be read.";
            RemovalPlanDetail = "The cleanup list was built, but the final plan summary was not returned.";
            return;
        }

        var commandCount = summary.CommandPreviewCount;
        var cleanupCount = summary.CleanupItemCount > 0 ? summary.CleanupItemCount : manifestItemCount;
        var gateCount = summary.BlockingGateCount;
        var runnerReady = summary.AllowlistedOfficialRunnerReady || summary.DisposableFixtureExecutionReady;

        RemovalPlanState = commandCount > 0
            ? "Run ready: app remover first, then " + cleanupCount.ToString(CultureInfo.InvariantCulture) + " cleanup item" + (cleanupCount == 1 ? "" : "s") + "."
            : "Run ready: Roo Industries cleanup route with " + cleanupCount.ToString(CultureInfo.InvariantCulture) + " item" + (cleanupCount == 1 ? "" : "s") + ".";

        var runnerLine = runnerReady ? "Roo Industries has a runner for this route." : "This route needs one more engine check.";
        var gateLine = gateCount > 0
            ? gateCount.ToString(CultureInfo.InvariantCulture) + " safety check" + (gateCount == 1 ? "" : "s") + " still need proof before real cleanup."
            : "No safety checks are blocking this run.";
        RemovalPlanDetail = runnerLine + " " + gateLine + " Nothing has been removed.";
    }

    private void SummarizeCleanupExecution(string? json, string expectedAppId, string? operationError, bool applied)
    {
        if (string.IsNullOrWhiteSpace(json) || operationError is not null)
        {
            CleanupExecutionState = applied ? "Cleanup result was not confirmed." : "Final check did not return a result.";
            CleanupExecutionDetail = operationError ?? (applied
                ? "Check the saved recovery record before retrying."
                : "Nothing was removed. Try the final check again.");
            FinalCheckPassed = false;
            SetSelectedRecovery(expectedAppId);
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!string.Equals(ExtractString(root, "actionId"), "apps.invokeUninstallCleanupApplyPackage", StringComparison.Ordinal))
            {
                CleanupExecutionState = applied ? "Cleanup result was not confirmed." : "Final check was not confirmed.";
                CleanupExecutionDetail = "The response identity did not match this cleanup operation.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }
            if (!string.Equals(ExtractString(root, "appId"), expectedAppId, StringComparison.Ordinal))
            {
                CleanupExecutionState = applied ? "Cleanup result was not confirmed." : "Final check did not match this app.";
                CleanupExecutionDetail = "The response belonged to a different cleanup operation.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }
            var status = ExtractString(root, "status") ?? "preview";
            var mode = ExtractString(root, "executionMode") ?? "preview";
            var hasDryRun = TryExtractBool(root, out var dryRun, "dryRun");
            var blocking = ExtractInt(root, "summary", "blockingGateCount");
            var deleted = ExtractInt(root, "summary", "deletedCount");
            var cleanupItems = ExtractInt(root, "summary", "cleanupItemCount");
            var rooIndustriesRoute = ExtractBool(root, "summary", "rooIndustriesRouteUsed");

            if (!hasDryRun
                || (!applied && (!dryRun || status is not ("preview" or "blocked" or "failed")))
                || (applied && (status == "preview" || dryRun && status is ("success" or "partial" or "cleanup-review-required"))))
            {
                CleanupExecutionState = applied ? "Cleanup result was not confirmed." : "Final check was not confirmed.";
                CleanupExecutionDetail = "The response mode did not match the requested operation.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }

            if ((status == "preview" && (mode != "preview" || !GatesPermit(root, true)))
                || (status == "success" && (mode != "real" || !GatesPermit(root, false))))
            {
                CleanupExecutionState = applied ? "Cleanup result was not confirmed." : "Final check was not confirmed.";
                CleanupExecutionDetail = "The response contains missing or conflicting completion checks.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }

            if (status == "cleanup-review-required")
            {
                CleanupExecutionState = "App removal completed. Leftover cleanup needs a new review.";
                CleanupExecutionDetail = "The old deletion list was not applied. Leftover files require a fresh scan and separate approval.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }
            if (status == "success")
            {
                SetSelectedRecovery(expectedAppId);
                CleanupExecutionState = deleted > 0
                    ? "Cleanup applied: " + deleted.ToString(CultureInfo.InvariantCulture) + " item" + (deleted == 1 ? "" : "s") + " removed."
                    : "Cleanup applied. Nothing needed removal.";
                CleanupExecutionDetail = CleanupRestoreAvailable
                    ? "Restore is ready from the backup."
                    : "No verified rollback file was returned.";
                return;
            }

            if (status == "needs-reconciliation")
            {
                CleanupExecutionState = "App removal needs checking.";
                CleanupExecutionDetail = "The app's remover was still running when the check ended. It was not stopped. Let it finish, then scan for leftovers again.";
                FinalCheckPassed = false;
                SetSelectedRecovery(expectedAppId);
                return;
            }
            if (status is "partial" or "failed")
            {
                CleanupExecutionState = status == "partial" ? "Cleanup stopped partway through." : "Cleanup failed.";
                CleanupExecutionDetail = deleted.ToString(CultureInfo.InvariantCulture) + " completed deletion(s). Check recovery details before retrying.";
                SetSelectedRecovery(expectedAppId);
                return;
            }

            if (status == "preview")
            {
                FinalCheckPassed = ExtractBool(root, "summary", "approvalReady");
                CleanupExecutionState = FinalCheckPassed ? "Final check passed." : "The reviewed inputs need attention.";
                CleanupExecutionDetail = (rooIndustriesRoute ? "Roo Industries can use its own route for this app. " : string.Empty)
                    + cleanupItems.ToString(CultureInfo.InvariantCulture) + " file/folder target" + (cleanupItems == 1 ? "" : "s") + " checked. Nothing was removed.";
                SetSelectedRecovery(expectedAppId);
                return;
            }

            CleanupExecutionState = status == "blocked"
                ? "Apply is still held."
                : "Apply check ready.";
            CleanupExecutionDetail = blocking > 0
                ? blocking.ToString(CultureInfo.InvariantCulture) + " approval check" + (blocking == 1 ? "" : "s") + " still need to clear. " + cleanupItems.ToString(CultureInfo.InvariantCulture) + " item" + (cleanupItems == 1 ? "" : "s") + " in the run. Nothing was removed."
                : "Executor mode: " + mode + ". Nothing was removed.";
            SetSelectedRecovery(expectedAppId);
        }
        catch (Exception error)
        {
            CleanupExecutionState = "Apply result could not be read.";
            CleanupExecutionDetail = operationError ?? error.Message;
            FinalCheckPassed = false;
            SetSelectedRecovery(expectedAppId);
        }
    }

    private void SummarizeCleanupRestore(string? json, string? operationError, bool restoreSucceeded)
    {
        if (string.IsNullOrWhiteSpace(json) || operationError is not null)
        {
            CleanupExecutionState = "Restore was not confirmed.";
            CleanupExecutionDetail = operationError ?? "The recovery record remains available.";
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
                CleanupExecutionDetail = "Rollback stayed inside the approved cleanup path.";
                _lastCleanupRollbackPath = null;
                CleanupRestoreAvailable = false;
            }
            else if (status == "success")
            {
                CleanupExecutionState = "Restore result was not confirmed.";
                CleanupExecutionDetail = "The restore response did not match the requested rollback operation.";
            }
            else
            {
                CleanupExecutionState = "Restore held for approval.";
                CleanupExecutionDetail = blocking.ToString(CultureInfo.InvariantCulture) + " restore approval" + (blocking == 1 ? "" : "s") + " still need to clear.";
            }
        }
        catch (Exception error)
        {
            CleanupExecutionState = "Restore result could not be read.";
            CleanupExecutionDetail = operationError ?? error.Message;
        }
    }

    private bool IsCurrent(InstalledApp app, int generation)
        => generation == _selectionGeneration
            && ReferenceEquals(SelectedApp, app)
            && string.Equals(SelectedApp?.AppId, app.AppId, StringComparison.Ordinal);

    private void FinishOperation(int generation)
    {
        if (generation != _selectionGeneration) return;
        ScanBusy = false;
        RefreshActionState();
    }

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
