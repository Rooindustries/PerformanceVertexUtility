using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class DriversProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle =
        "Driver packages, NVIDIA profile tools, and diagnostics are shown exactly as the router reports them for this PC.";
    [ObservableProperty] private int _capabilityCount;
    [ObservableProperty] private int _availableCapabilityCount;
    [ObservableProperty] private int _notAvailableCapabilityCount;
    [ObservableProperty] private bool _hasHardwareSummary;
    [ObservableProperty] private string? _machineModel;
    [ObservableProperty] private string? _machineOsCaption;
    [ObservableProperty] private string? _cpuName;
    [ObservableProperty] private string? _cpuCoreSummary;
    [ObservableProperty] private string? _primaryGpuName;
    [ObservableProperty] private string? _primaryGpuDriverSummary;

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

    public bool HasSelectedCapability => SelectedCapability is not null;

    public string CapabilityCountLine =>
        CapabilityCount.ToString(System.Globalization.CultureInfo.InvariantCulture) + " capabilities";

    protected override async Task LoadCoreAsync()
    {
        await LoadCapabilitiesAsync();
        await LoadHardwareSummaryAsync();
        IsEmpty = Capabilities.Count == 0;
    }

    private async Task LoadCapabilitiesAsync()
    {
        var all = await App.Capabilities.GetCapabilitiesAsync();
        var rows = App.Capabilities.ForPage("Drivers & NVIDIA", all);

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

    private async Task LoadHardwareSummaryAsync()
    {
        var hardware = await App.Live.GetDriverHardwareAsync();
        if (hardware?.Machine is null)
        {
            HasHardwareSummary = false;
            return;
        }

        HasHardwareSummary = true;
        MachineModel = FirstNonBlank(
            string.Join(" ", new[] { hardware.Machine.Manufacturer, hardware.Machine.Model }
                .Where(value => !string.IsNullOrWhiteSpace(value))),
            "This PC");
        MachineOsCaption = FirstNonBlank(hardware.Machine.OsCaption, "Windows");
        CpuName = Clean(hardware.Cpu?.Name);
        CpuCoreSummary = hardware.Cpu is null
            ? "CPU details not reported"
            : hardware.Cpu.Cores.ToString(System.Globalization.CultureInfo.InvariantCulture)
              + " cores / "
              + hardware.Cpu.LogicalProcessors.ToString(System.Globalization.CultureInfo.InvariantCulture)
              + " threads";

        var primary = (hardware.Gpus ?? new List<GpuInfo>())
            .FirstOrDefault(g => IsNvidia(g))
            ?? (hardware.Gpus ?? new List<GpuInfo>()).FirstOrDefault();
        PrimaryGpuName = Clean(primary?.Name) ?? "Graphics hardware not reported";
        PrimaryGpuDriverSummary = DriverSummary(primary);
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

    private static string DriverSummary(GpuInfo? gpu)
    {
        if (gpu is null)
        {
            return "Driver details not reported";
        }

        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(gpu.DriverVersion))
        {
            parts.Add("Driver " + gpu.DriverVersion);
        }

        if (!string.IsNullOrWhiteSpace(gpu.DriverDate))
        {
            parts.Add(gpu.DriverDate!);
        }

        return parts.Count == 0 ? "Driver details not reported" : string.Join(" | ", parts);
    }

    private static bool IsNvidia(GpuInfo g)
        => (g.Vendor?.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) ?? false)
           || (g.Name?.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) ?? false);

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
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return value
            .Replace("(R)", string.Empty, StringComparison.Ordinal)
            .Replace("(TM)", string.Empty, StringComparison.Ordinal)
            .Replace("  ", " ", StringComparison.Ordinal)
            .Trim();
    }
}
