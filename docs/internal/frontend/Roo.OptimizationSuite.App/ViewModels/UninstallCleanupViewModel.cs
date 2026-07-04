using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class UninstallCleanupViewModel : PageViewModelBase
{
    private const string PageName = "Clean Junk";

    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private int _capabilityCount;
    [ObservableProperty] private int _availableCapabilityCount;
    [ObservableProperty] private int _approvalCapabilityCount;
    [ObservableProperty] private int _appCount;
    [ObservableProperty] private string? _sources;
    [ObservableProperty] private string? _inventoryMessage;
    [ObservableProperty] private int _startupHeavyCount;
    [ObservableProperty] private int _protectedCount;
    [ObservableProperty] private string? _reclaimableText;

    [ObservableProperty] private InstalledApp? _selectedApp;
    [ObservableProperty] private string? _selectedName;
    [ObservableProperty] private string? _selectedSummary;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _selectedProtected;
    [ObservableProperty] private string? _selectedProtectionState;
    [ObservableProperty] private string _officialPreviewState = "protected";
    [ObservableProperty] private string? _officialPreviewText;
    [ObservableProperty] private string? _officialCommand;
    [ObservableProperty] private string? _installLocation;

    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _hasSelection;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _scanBusy;
    [ObservableProperty] private string _leftoverState = "Pick an app to review its uninstall command and leftover preview.";
    [ObservableProperty] private string? _leftoverSummary;
    [ObservableProperty] private string _cleanupPlanNote =
        "Cleanup plan and rollback readiness are reported by the capability rows above. This app review does not dispatch deletion.";

    [ObservableProperty][NotifyPropertyChangedFor(nameof(HasSelectedCapability))]
    private CleanupCapabilityItem? _selectedCapability;

    [ObservableProperty] private bool _explainBusy;
    [ObservableProperty] private string _selectedCapabilityLabel = "Select a capability";
    [ObservableProperty] private string _selectedCapabilityFamily = string.Empty;
    [ObservableProperty] private string _selectedCapabilityAvailability = string.Empty;
    [ObservableProperty] private string _selectedCapabilityApply = string.Empty;
    [ObservableProperty] private string _selectedCapabilityApproval = string.Empty;
    [ObservableProperty] private string _selectedCapabilityRestore = string.Empty;
    [ObservableProperty] private string _selectedCapabilityReason = string.Empty;
    [ObservableProperty] private string _selectedCapabilityNextStep = "Select a capability to read its explain details.";
    [ObservableProperty] private string _selectedCapabilityStatus = string.Empty;
    [ObservableProperty] private string _selectedCapabilityDotState = "neutral";
    [ObservableProperty] private string? _selectedCapabilityErrors;

    public bool CanScan => HasSelection && !SelectedProtected && !ScanBusy;
    public bool HasSelectedCapability => SelectedCapability is not null;

    private readonly List<InstalledApp> _allApps = new();
    private readonly List<UninstallCommand> _officialCommands = new();
    private int _explainRequestId;

    public ObservableCollection<CleanupCapabilityItem> Capabilities { get; } = new();
    public ObservableCollection<CleanupCapabilityGateLine> SelectedGateRows { get; } = new();
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<LeftoverItem> Leftovers { get; } = new();
    public ObservableCollection<CleanupBackupLine> BackupLines { get; } = new();
    public ObservableCollection<GateRow> GateRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        await LoadCapabilitiesAsync();
        await LoadInventoryContextAsync();
        IsEmpty = Capabilities.Count == 0;
    }

    public async Task SelectCapabilityAsync(CleanupCapabilityItem? item)
    {
        if (item is null)
        {
            return;
        }

        var requestId = ++_explainRequestId;
        SelectedCapability = item;
        ApplyRegistryDetail(item.Row);
        ExplainBusy = true;
        SelectedCapabilityErrors = null;

        try
        {
            var response = await App.Capabilities.ExplainAsync(item.Row.CapabilityId);
            if (requestId != _explainRequestId)
            {
                return;
            }

            ApplyExplainDetail(item.Row, response);
        }
        catch (Exception ex)
        {
            if (requestId == _explainRequestId)
            {
                SelectedCapabilityErrors = ex.Message;
                SelectedCapabilityStatus = "Explain failed";
            }
        }
        finally
        {
            if (requestId == _explainRequestId)
            {
                ExplainBusy = false;
            }
        }
    }

    private async Task LoadCapabilitiesAsync()
    {
        var all = await App.Capabilities.GetCapabilitiesAsync();
        var rows = App.Capabilities.ForPage(PageName, all);

        Capabilities.Clear();
        foreach (var row in rows)
        {
            Capabilities.Add(new CleanupCapabilityItem(row));
        }

        CapabilityCount = rows.Count;
        AvailableCapabilityCount = rows.Count(row => row.MachineAvailable);
        ApprovalCapabilityCount = rows.Count(row => row.ApprovalText.Contains("go-ahead", StringComparison.OrdinalIgnoreCase));
    }

    private async Task LoadInventoryContextAsync()
    {
        var inventory = await App.Live.GetInstalledAppsAsync()
            ?? await TryLoadSample(Data.GetInstalledAppsAsync);
        var classification = await App.Live.GetAppClassificationAsync()
            ?? await TryLoadSample(Data.GetAppClassificationAsync);
        var officialPreview = await TryLoadSample(Data.GetOfficialUninstallPreviewAsync);
        var cleanupManifest = await TryLoadSample(Data.GetCleanupManifestAsync);
        var executionPlan = await TryLoadSample(Data.GetUninstallCleanupExecutionPlanAsync);
        var apps = inventory?.Apps;

        _allApps.Clear();
        _officialCommands.Clear();
        Apps.Clear();
        Leftovers.Clear();
        BackupLines.Clear();
        GateRows.Clear();

        _officialCommands.AddRange(officialPreview?.Commands ?? new List<UninstallCommand>());

        if (apps is null || apps.Count == 0)
        {
            InventoryMessage = "Installed app inventory was not returned. Capability status is still available from the registry.";
            AppCount = 0;
            StartupHeavyCount = 0;
            ProtectedCount = 0;
            ReclaimableText = Format.Bytes(0);
            Sources = null;
            BuildCleanupPlan(cleanupManifest, executionPlan);
            return;
        }

        InventoryMessage = null;
        MergeClassification(apps, classification);

        _allApps.AddRange(apps
            .Where(a => a.IsListable && !Naming.IsNonActionable(a.DisplayName)
                        && !LocalDisplayFilter.Default.IsHidden(a.FriendlyName, null, a.PackageId ?? a.DisplayName))
            .OrderBy(a => a.FriendlyName, StringComparer.OrdinalIgnoreCase));

        AppCount = _allApps.Count;
        StartupHeavyCount = inventory?.Summary?.StartupHeavyCount ?? 0;
        ProtectedCount = classification?.Summary?.ProtectedCount ?? _allApps.Count(a => a.Protected);
        ReclaimableText = Format.Bytes(inventory?.Summary?.EstimatedSizeBytes ?? 0);
        Sources = inventory?.Sources is { Count: > 0 } sources
            ? string.Join(", ", sources.Select(FriendlySource))
            : null;
        BuildCleanupPlan(cleanupManifest, executionPlan);
        ApplyFilter();
    }

    private void ApplyRegistryDetail(CapabilityRow row)
    {
        SelectedCapabilityLabel = row.Label;
        SelectedCapabilityFamily = CleanupCapabilityText.FamilyText(row);
        SelectedCapabilityAvailability = CleanupCapabilityText.AvailabilityText(row);
        SelectedCapabilityApply = row.ApplyStatusText;
        SelectedCapabilityApproval = row.ApprovalText;
        SelectedCapabilityRestore = row.RestoreText;
        SelectedCapabilityReason = string.IsNullOrWhiteSpace(row.ReasonOrNextStep)
            ? "No registry reason reported."
            : row.ReasonOrNextStep;
        SelectedCapabilityNextStep = string.IsNullOrWhiteSpace(row.ReasonOrNextStep)
            ? "Live explain has not returned a next step yet."
            : row.ReasonOrNextStep;
        SelectedCapabilityStatus = "Reading explain details";
        SelectedCapabilityDotState = row.DotState;
        SelectedGateRows.Clear();
        SelectedGateRows.Add(new CleanupCapabilityGateLine("Reading gates from explain", "neutral"));
    }

    private void ApplyExplainDetail(CapabilityRow row, CapabilityRouterResponse? response)
    {
        SelectedCapabilityStatus = CleanupCapabilityText.StatusText(response);
        SelectedCapabilityNextStep = CleanupCapabilityText.NextStepText(row, response);
        SelectedCapabilityErrors = CleanupCapabilityText.ErrorText(response);

        SelectedGateRows.Clear();
        foreach (var gate in CleanupCapabilityText.GateLines(response))
        {
            SelectedGateRows.Add(gate);
        }
    }

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnSelectedAppChanged(InstalledApp? value)
    {
        Leftovers.Clear();
        LeftoverSummary = null;
        HasSelection = value is not null;

        if (value is null)
        {
            SelectedName = null;
            SelectedSummary = null;
            SelectedProtected = false;
            SelectedProtectionState = null;
            OfficialCommand = null;
            OfficialPreviewText = null;
            InstallLocation = null;
            LeftoverState = "Pick an app to review its uninstall command and leftover preview.";
            return;
        }

        SelectedName = value.FriendlyName;
        SelectedProtected = value.Protected;
        SelectedProtectionState = value.Protected ? "Protected - kept" : null;
        var bits = new List<string>();
        if (!string.IsNullOrWhiteSpace(value.SecondaryLabel)) bits.Add(value.SecondaryLabel!);
        if (value.EstimatedSizeBytes is > 0) bits.Add(Format.Bytes(value.EstimatedSizeBytes!.Value));
        SelectedSummary = bits.Count == 0 ? "Inventory details are limited for this app." : string.Join(" - ", bits);

        InstallLocation = string.IsNullOrWhiteSpace(value.InstallLocation) ? "Not recorded" : value.InstallLocation;
        var command = _officialCommands.FirstOrDefault(c => c.AppId == value.AppId);
        OfficialCommand = command is null
            ? (string.IsNullOrWhiteSpace(value.UninstallString)
                ? "No standard uninstaller is registered for this app."
                : "The app has a registered uninstaller; this view does not launch it.")
            : "The official uninstall capability uses the app's own uninstaller through the allowlist shim.";
        OfficialPreviewState = command?.RequiresElevation == true ? "protected" : "go-ahead";
        OfficialPreviewText = command?.RequiresElevation == true
            ? "Needs an administrator token before the official uninstaller can run."
            : "Review mode - needs your go-ahead before any official uninstall can run.";

        LeftoverState = value.Protected
            ? "Protected - kept. Leftover preview is disabled for this app."
            : "Run a leftover preview when you are ready. Nothing changes your system from this panel.";
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
        LeftoverState = "Reading leftover preview...";
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
                LeftoverState = scan is null ? "Leftover preview is not available for this app yet." : "No leftovers found for this app.";
            }
            else
            {
                LeftoverState = string.Empty;
                var recoverable = scan?.Summary?.EstimatedRecoverableBytes ?? 0;
                LeftoverSummary = items.Count + " item" + (items.Count == 1 ? "" : "s")
                    + (recoverable > 0 ? " - " + Format.Bytes(recoverable) + " recoverable" : string.Empty);
            }
        }
        catch
        {
            LeftoverState = "Could not read leftover preview for this app.";
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
        foreach (var app in source)
        {
            Apps.Add(app);
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
            BackupLines.Add(new CleanupBackupLine("Folder backups", "Every folder in a deletion plan needs a backup before removal.", "protected"));
        }

        if (rollback?.RollbackSupported == true)
        {
            BackupLines.Add(new CleanupBackupLine("Restore", "Rollback metadata is present for reviewed cleanup plans.", "safe"));
        }

        if (rollback?.RestorePoint?.RequiredBeforeFutureApply == true)
        {
            BackupLines.Add(new CleanupBackupLine("Restore point", "A restore point is required before cleanup can apply.", "protected"));
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
        "explicit-user-confirmation" => "Your go-ahead is not captured",
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

    private static async Task<T?> TryLoadSample<T>(Func<Task<T>> load) where T : class
    {
        try
        {
            return await load();
        }
        catch
        {
            return null;
        }
    }
}

public sealed record CleanupCapabilityItem(CapabilityRow Row)
{
    public string MetaText => CleanupCapabilityText.MetaText(Row);
}

public sealed record CleanupCapabilityGateLine(string Label, string State);

internal static class CleanupCapabilityText
{
    public static string MetaText(CapabilityRow row)
        => FamilyText(row) + " - " + AvailabilityText(row);

    public static string FamilyText(CapabilityRow row)
        => row.Page + " / " + row.Family;

    public static string AvailabilityText(CapabilityRow row)
        => row.MachineAvailable ? "Available on this PC" : "Not available here";

    public static string StatusText(CapabilityRouterResponse? response)
    {
        if (response is null)
        {
            return "Registry status only";
        }

        var status = Clean(response.Status) ?? "completed";
        var action = Clean(response.Action) ?? "explain";
        return action + " - " + status;
    }

    public static string NextStepText(CapabilityRow row, CapabilityRouterResponse? response)
    {
        var next = Clean(response?.NextRequiredStep);
        if (next is not null)
        {
            return next;
        }

        if (!row.MachineAvailable && !string.IsNullOrWhiteSpace(row.ReasonOrNextStep))
        {
            return row.ReasonOrNextStep;
        }

        if (response is null)
        {
            return string.IsNullOrWhiteSpace(row.ReasonOrNextStep)
                ? "Live explain did not return a router envelope; registry status is shown."
                : row.ReasonOrNextStep;
        }

        return "No additional next step reported by explain.";
    }

    public static string? ErrorText(CapabilityRouterResponse? response)
    {
        var errors = response?.Errors?
            .Where(error => !string.IsNullOrWhiteSpace(error.Code) || !string.IsNullOrWhiteSpace(error.Message))
            .Select(error =>
            {
                var code = Clean(error.Code);
                var message = Clean(error.Message);
                if (code is null)
                {
                    return message;
                }

                return message is null ? code : code + ": " + message;
            })
            .Where(text => !string.IsNullOrWhiteSpace(text))
            .ToList();

        return errors is { Count: > 0 } ? string.Join("; ", errors) : null;
    }

    public static IReadOnlyList<CleanupCapabilityGateLine> GateLines(CapabilityRouterResponse? response)
    {
        if (response is null)
        {
            return new[] { new CleanupCapabilityGateLine("Live explain gates not available", "neutral") };
        }

        var gates = ExtractGates(response.Evidence).ToList();
        if (gates.Count == 0)
        {
            return new[] { new CleanupCapabilityGateLine("No gates reported by explain", "safe") };
        }

        return gates.Select(gate => new CleanupCapabilityGateLine(HumanizeGate(gate), "protected")).ToList();
    }

    private static IEnumerable<string> ExtractGates(JsonElement evidence)
    {
        if (evidence.ValueKind != JsonValueKind.Object)
        {
            yield break;
        }

        if (!evidence.TryGetProperty("capability", out var capability) ||
            capability.ValueKind != JsonValueKind.Object ||
            !capability.TryGetProperty("gates", out var gates) ||
            gates.ValueKind != JsonValueKind.Array)
        {
            yield break;
        }

        foreach (var gate in gates.EnumerateArray())
        {
            if (gate.ValueKind == JsonValueKind.String)
            {
                var value = Clean(gate.GetString());
                if (value is not null)
                {
                    yield return value;
                }
            }
        }
    }

    private static string HumanizeGate(string gate)
        => gate.Replace('-', ' ');

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrWhiteSpace(clean) ? null : clean;
    }
}
