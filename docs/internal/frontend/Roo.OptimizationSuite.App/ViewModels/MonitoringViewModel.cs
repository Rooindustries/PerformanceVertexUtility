using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class MonitoringViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle =
        "System optimization capabilities, readiness, rollback state, admin gates, and next steps from the router.";
    [ObservableProperty] private int _capabilityCount;
    [ObservableProperty] private int _availableCapabilityCount;
    [ObservableProperty] private int _notAvailableCapabilityCount;
    [ObservableProperty] private bool _hasLiveSnapshot;
    [ObservableProperty] private string? _liveSnapshotLine;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelectedCapability))]
    private CapabilityRow? _selectedCapability;

    [ObservableProperty] private string? _selectedCapabilityLabel;
    [ObservableProperty] private string? _selectedCapabilityId;
    [ObservableProperty] private string? _selectedCapabilityState = "neutral";
    [ObservableProperty] private string? _selectedFamilyPage;
    [ObservableProperty] private string? _selectedMachineAvailability;
    [ObservableProperty] private string? _selectedApplyStatus;
    [ObservableProperty] private string? _selectedApproval;
    [ObservableProperty] private string? _selectedRestore;
    [ObservableProperty] private string? _selectedReasonOrNextStep;
    [ObservableProperty] private string? _selectedExplainStatus;
    [ObservableProperty] private string? _selectedRouterNextStep;
    [ObservableProperty] private string? _selectedGates;
    [ObservableProperty] private string? _selectedErrors;
    [ObservableProperty] private bool _isExplaining;

    private int _explainVersion;

    public ObservableCollection<CapabilityRow> Capabilities { get; } = new();
    public ObservableCollection<MetricTile> LiveTiles { get; } = new();

    public bool HasSelectedCapability => SelectedCapability is not null;

    public string CapabilityCountLine =>
        CapabilityCount.ToString(CultureInfo.InvariantCulture) + " capabilities";

    protected override async Task LoadCoreAsync()
    {
        await LoadCapabilitiesAsync();
        await LoadLiveSnapshotAsync();
        IsEmpty = Capabilities.Count == 0;
    }

    private async Task LoadCapabilitiesAsync()
    {
        var all = await App.Capabilities.GetCapabilitiesAsync();
        var rows = App.Capabilities.ForPage("System Tweaks", all);

        SelectedCapability = null;
        Capabilities.Clear();
        foreach (var row in rows)
        {
            Capabilities.Add(row);
        }

        CapabilityCount = Capabilities.Count;
        AvailableCapabilityCount = Capabilities.Count(row => row.MachineAvailable);
        NotAvailableCapabilityCount = Capabilities.Count(row => !row.MachineAvailable);
        OnPropertyChanged(nameof(CapabilityCountLine));

        SelectedCapability = Capabilities.FirstOrDefault();
    }

    private async Task LoadLiveSnapshotAsync()
    {
        LiveTiles.Clear();

        var inventory = await App.Live.GetProcessInventoryAsync();
        var hardware = await App.Live.GetDriverHardwareAsync();
        var summary = inventory?.Summary;
        if (summary is null)
        {
            HasLiveSnapshot = false;
            LiveSnapshotLine = "Live process inventory is not available right now.";
            return;
        }

        var total = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var used = total > summary.AvailableMemoryBytes ? total - summary.AvailableMemoryBytes : 0;
        var usedPct = total > 0
            ? ((int)System.Math.Round((double)used / total * 100)).ToString(CultureInfo.InvariantCulture) + "% of memory"
            : "in use";

        LiveTiles.Add(new MetricTile("Apps Running", summary.ProcessCount.ToString(CultureInfo.InvariantCulture),
            summary.BackgroundProcessCount.ToString(CultureInfo.InvariantCulture) + " background"));
        LiveTiles.Add(new MetricTile("RAM Free", Format.Bytes(summary.AvailableMemoryBytes), "available now"));
        LiveTiles.Add(new MetricTile("RAM In Use", Format.Bytes(used), usedPct));
        LiveTiles.Add(new MetricTile("Windows Memory", Format.Bytes(summary.CommitUsedBytes), "commit charge"));

        HasLiveSnapshot = true;
        LiveSnapshotLine = "Live process inventory from this PC.";
    }

    partial void OnSelectedCapabilityChanged(CapabilityRow? value)
    {
        var version = ++_explainVersion;
        _ = UpdateCapabilityDetailAsync(value, version);
    }

    private async Task UpdateCapabilityDetailAsync(CapabilityRow? row, int version)
    {
        if (row is null)
        {
            ClearSelectedDetail();
            return;
        }

        SelectedCapabilityLabel = row.Label;
        SelectedCapabilityId = row.CapabilityId;
        SelectedCapabilityState = row.DotState;
        SelectedFamilyPage = row.Family + " / " + row.Page;
        SelectedMachineAvailability = row.MachineAvailable ? "Available on this PC" : "Not available here";
        SelectedApplyStatus = row.ApplyStatusText;
        SelectedApproval = row.ApprovalText;
        SelectedRestore = row.RestoreText;
        SelectedReasonOrNextStep = row.ReasonOrNextStep;
        SelectedExplainStatus = "Reading router explain...";
        SelectedRouterNextStep = null;
        SelectedGates = null;
        SelectedErrors = null;
        IsExplaining = true;

        try
        {
            var explain = await App.Capabilities.ExplainAsync(row.CapabilityId);
            if (version != _explainVersion)
            {
                return;
            }

            if (explain is null)
            {
                SelectedExplainStatus = "Router explain did not return a live response.";
                return;
            }

            SelectedExplainStatus = RouterStatusLine(explain);
            SelectedRouterNextStep = Clean(explain.NextRequiredStep);
            SelectedGates = ExtractGates(explain.Evidence);
            SelectedErrors = FormatErrors(explain);
        }
        finally
        {
            if (version == _explainVersion)
            {
                IsExplaining = false;
            }
        }
    }

    private void ClearSelectedDetail()
    {
        SelectedCapabilityLabel = null;
        SelectedCapabilityId = null;
        SelectedCapabilityState = "neutral";
        SelectedFamilyPage = null;
        SelectedMachineAvailability = null;
        SelectedApplyStatus = null;
        SelectedApproval = null;
        SelectedRestore = null;
        SelectedReasonOrNextStep = null;
        SelectedExplainStatus = null;
        SelectedRouterNextStep = null;
        SelectedGates = null;
        SelectedErrors = null;
        IsExplaining = false;
    }

    private static string RouterStatusLine(CapabilityRouterResponse response)
    {
        var status = FirstNonBlank(response.Status, "responded");
        var availability = response.MachineAvailable ? "available on this PC" : "not available here";
        var change = response.WouldChange ? "would change only after approval" : "no changes dispatched";
        return "Router " + status.Replace('-', ' ') + " | " + availability + " | " + change;
    }

    private static string? ExtractGates(JsonElement evidence)
    {
        if (evidence.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        if (!evidence.TryGetProperty("capability", out var capability)
            || !capability.TryGetProperty("gates", out var gates)
            || gates.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var values = gates.EnumerateArray()
            .Select(gate => gate.ValueKind == JsonValueKind.String ? gate.GetString() : null)
            .Where(gate => !string.IsNullOrWhiteSpace(gate))
            .Select(gate => gate!.Replace('-', ' '))
            .ToList();

        return values.Count == 0 ? null : string.Join(", ", values);
    }

    private static string? FormatErrors(CapabilityRouterResponse response)
    {
        var errors = response.Errors?
            .Where(error => !string.IsNullOrWhiteSpace(error.Message) || !string.IsNullOrWhiteSpace(error.Code))
            .Select(error => FirstNonBlank(error.Code, "error") + ": " + FirstNonBlank(error.Message, "reported by router"))
            .ToList();

        return errors is { Count: > 0 } ? string.Join("; ", errors) : null;
    }

    private static string FirstNonBlank(params string?[] values)
    {
        foreach (var value in values)
        {
            var clean = Clean(value);
            if (clean is not null)
            {
                return clean;
            }
        }

        return string.Empty;
    }

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrWhiteSpace(clean) ? null : clean;
    }
}
