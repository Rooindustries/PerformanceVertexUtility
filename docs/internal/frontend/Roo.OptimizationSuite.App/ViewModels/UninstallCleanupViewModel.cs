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

public partial class UninstallCleanupViewModel : PageViewModelBase
{
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private int _appCount;
    [ObservableProperty] private string? _sources;
    [ObservableProperty] private int _startupHeavyCount;
    [ObservableProperty] private int _protectedCount;
    [ObservableProperty] private string? _reclaimableText;

    [ObservableProperty] private InstalledApp? _selectedApp;
    [ObservableProperty] private string? _selectedName;
    [ObservableProperty] private string? _selectedSummary;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _selectedProtected;
    [ObservableProperty] private string? _selectedProtectionState;
    [ObservableProperty] private string? _officialPreviewState;
    [ObservableProperty] private string? _officialCommand;
    [ObservableProperty] private string? _installLocation;

    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _hasSelection;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _scanBusy;
    [ObservableProperty] private string _leftoverState = "Pick an app on the left to review its uninstall and leftovers.";
    [ObservableProperty] private string? _leftoverSummary;
    [ObservableProperty] private string _cleanupPlanNote = "This builds your reviewed plan with backups. Deleting still needs your final go-ahead.";

    public bool CanScan => HasSelection && !SelectedProtected && !ScanBusy;

    private readonly List<InstalledApp> _allApps = new();
    private readonly List<UninstallCommand> _officialCommands = new();
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<LeftoverItem> Leftovers { get; } = new();
    public ObservableCollection<CleanupBackupLine> BackupLines { get; } = new();
    public ObservableCollection<GateRow> GateRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetInstalledAppsAsync() ?? await TryLoadSample(Data.GetInstalledAppsAsync);
        var classification = await App.Live.GetAppClassificationAsync() ?? await TryLoadSample(Data.GetAppClassificationAsync);
        var officialPreview = await TryLoadSample(Data.GetOfficialUninstallPreviewAsync);
        var cleanupManifest = await TryLoadSample(Data.GetCleanupManifestAsync);
        var executionPlan = await TryLoadSample(Data.GetUninstallCleanupExecutionPlanAsync);
        var apps = inventory?.Apps;
        if (apps is null || apps.Count == 0)
        {
            ErrorMessage = "We couldn't read your installed apps yet. Close and reopen to try again.";
            return;
        }

        MergeClassification(apps, classification);
        _officialCommands.Clear();
        _officialCommands.AddRange(officialPreview?.Commands ?? new List<UninstallCommand>());

        _allApps.Clear();
        _allApps.AddRange(apps
            .Where(a => a.IsListable && !Naming.IsNonActionable(a.DisplayName)
                        && !LocalDisplayFilter.Default.IsHidden(a.FriendlyName, null, a.PackageId ?? a.DisplayName))
            .OrderBy(a => a.FriendlyName, StringComparer.OrdinalIgnoreCase));
        AppCount = _allApps.Count;
        StartupHeavyCount = inventory?.Summary?.StartupHeavyCount ?? 0;
        ProtectedCount = classification?.Summary?.ProtectedCount ?? _allApps.Count(a => a.Protected);
        ReclaimableText = Format.Bytes(inventory?.Summary?.EstimatedSizeBytes ?? 0);
        Sources = inventory!.Sources is { Count: > 0 } s ? string.Join(", ", s.Select(FriendlySource)) : null;
        BuildCleanupPlan(cleanupManifest, executionPlan);

        ApplyFilter();
        IsEmpty = _allApps.Count == 0;
    }

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnSelectedAppChanged(InstalledApp? value)
    {
        Leftovers.Clear();
        LeftoverSummary = null;
        HasSelection = value is not null;

        if (value is null)
        {
            LeftoverState = "Pick an app on the left to review its uninstall and leftovers.";
            return;
        }

        SelectedName = value.FriendlyName;
        SelectedProtected = value.Protected;
        SelectedProtectionState = value.Protected ? "Protected — kept" : null;
        var bits = new List<string>();
        if (!string.IsNullOrWhiteSpace(value.SecondaryLabel)) bits.Add(value.SecondaryLabel!);
        if (value.EstimatedSizeBytes is > 0) bits.Add(Format.Bytes(value.EstimatedSizeBytes!.Value));
        SelectedSummary = string.Join("  ·  ", bits);

        InstallLocation = string.IsNullOrWhiteSpace(value.InstallLocation) ? "Not recorded" : value.InstallLocation;
        var command = _officialCommands.FirstOrDefault(c => c.AppId == value.AppId);
        OfficialCommand = command is null
            ? (string.IsNullOrWhiteSpace(value.UninstallString)
                ? "No standard uninstaller is registered for this app."
                : "Runs the app's own uninstaller")
            : "Runs the app's own uninstaller";
        OfficialPreviewState = command?.RequiresElevation == true
            ? "Needs admin"
            : "Review mode — needs your go-ahead";

        LeftoverState = value.Protected
            ? "Protected — kept"
            : "Run a leftover scan when you're ready. Nothing changes your system yet.";
    }

    [RelayCommand]
    private async Task ScanLeftoversAsync()
    {
        var app = SelectedApp;
        if (app is null || app.Protected || string.IsNullOrWhiteSpace(app.AppId))
        {
            return;
        }

        ScanBusy = true;
        Leftovers.Clear();
        LeftoverSummary = null;
        LeftoverState = "Scanning for leftovers…";
        try
        {
            var scan = await App.Live.GetLeftoverScanAsync(app.AppId!);
            if (scan is null)
            {
                var sampleScan = await TryLoadSample(Data.GetLeftoverScanAsync);
                if (sampleScan?.AppId == app.AppId)
                {
                    scan = sampleScan;
                }
            }

            var items = scan?.Items ?? new List<LeftoverItem>();
            foreach (var item in items)
            {
                Leftovers.Add(item);
            }

            if (items.Count == 0)
            {
                LeftoverState = scan is null ? "Leftover scan is not available for this app yet." : "No leftovers found for this app.";
            }
            else
            {
                LeftoverState = string.Empty;
                var recoverable = scan?.Summary?.EstimatedRecoverableBytes ?? 0;
                LeftoverSummary = items.Count + " item" + (items.Count == 1 ? "" : "s")
                    + (recoverable > 0 ? "  ·  " + Format.Bytes(recoverable) + " recoverable" : string.Empty);
            }
        }
        catch
        {
            LeftoverState = "Couldn't scan this app right now.";
        }
        finally
        {
            ScanBusy = false;
        }
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

    private static void MergeClassification(IReadOnlyList<InstalledApp> apps, AppClassificationResult? classification)
    {
        var byId = (classification?.Apps ?? new List<AppClassificationItem>())
            .Where(a => !string.IsNullOrWhiteSpace(a.AppId))
            .ToDictionary(a => a.AppId!, StringComparer.OrdinalIgnoreCase);

        foreach (var app in apps)
        {
            if (app.AppId is null || !byId.TryGetValue(app.AppId, out var classified))
            {
                continue;
            }

            app.Protected = app.Protected || classified.Protected || classified.BlockByDefault;
            if ((app.ProtectionReasons is null || app.ProtectionReasons.Count == 0) && classified.ProtectionReasons is { Count: > 0 })
            {
                app.ProtectionReasons = classified.ProtectionReasons;
            }
        }
    }

    private void BuildCleanupPlan(CleanupManifest? manifest, UninstallCleanupExecutionPlan? executionPlan)
    {
        BackupLines.Clear();
        var rollback = manifest?.Rollback;
        if (rollback?.FileBackupRequirements is { Count: > 0 })
        {
            BackupLines.Add(new CleanupBackupLine("Folder backups", "We back up every folder before removing it", "protected"));
        }

        if (rollback?.RollbackSupported == true)
        {
            BackupLines.Add(new CleanupBackupLine("Restore", "One-click restore if anything looks wrong.", "safe"));
        }

        if (rollback?.RestorePoint?.RequiredBeforeFutureApply == true)
        {
            BackupLines.Add(new CleanupBackupLine("Restore point", "A restore point is created before cleanup.", "protected"));
        }

        GateRows.Clear();
        foreach (var gate in executionPlan?.Gates?.Where(g => g.Blocking && !g.Satisfied) ?? Enumerable.Empty<ExecutionGate>())
        {
            GateRows.Add(new GateRow(GateLabel(gate.GateId), gate.Reason ?? "not done yet", "protected"));
        }
    }

    private static string GateLabel(string? gateId) => gateId switch
    {
        "backup-exports-complete" => "Backups not done yet",
        "explicit-user-confirmation" => "Your go-ahead not captured",
        "policy-confirmed-execution-enabled" => "Cleanup stays in review mode",
        _ => "not done yet",
    };

    private static bool Contains(string? haystack, string needle)
        => haystack is not null && haystack.Contains(needle, StringComparison.OrdinalIgnoreCase);

    private static string FriendlySource(string? source) => source switch
    {
        "registry" => "Installed program",
        "msi" => "Windows Installer",
        "appx" => "Store app",
        "winget" => "Winget",
        null or "" => "App",
        _ => source!,
    };

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
