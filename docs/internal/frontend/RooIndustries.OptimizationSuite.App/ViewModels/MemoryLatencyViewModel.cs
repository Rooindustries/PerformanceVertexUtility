using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class MemoryLatencyViewModel : PageViewModelBase
{
    [ObservableProperty] private string _memoryHeadline = "Reading memory pressure…";
    [ObservableProperty] private string _memoryDetail = string.Empty;
    [ObservableProperty] private double _memoryUsedPercent;
    [ObservableProperty] private bool _hasMemory;
    [ObservableProperty] private string _pressureState = "neutral";

    public ObservableCollection<BackgroundRow> TopMemoryRows { get; } = new();
    public ObservableCollection<StatusLine> SensorRows { get; } = new();
    public ObservableCollection<DiagnosticRow> DiagnosticRows { get; } = new();

    [ObservableProperty]
    private string _topMemoryNote = "";

    protected override async Task LoadCoreAsync()
    {
        var inventoryRead = App.Live.GetProcessInventoryResultAsync();
        var classificationRead = App.Live.GetProcessClassificationResultAsync(fresh: Fresh, allowStale: !Fresh);
        var hardwareRead = App.Live.GetDriverHardwareAsync();
        var inventoryResult = await inventoryRead;
        var inventory = inventoryResult.Value;
        var classificationResult = await classificationRead;
        var classification = classificationResult.Value;
        if (inventory is null && classification is null)
            throw new InvalidOperationException(inventoryResult.Error ?? classificationResult.Error ?? "Memory information could not be read.");
        if (classificationResult.Stale) RevalidateAfterLoad();
        TopMemoryNote = classification is null ? "Memory by process is unavailable. " + (classificationResult.Error ?? "") : "";
        var hardware = await hardwareRead;
        TelemetrySnapshot? telemetry = null;

        BuildMemory(inventory?.Summary, hardware?.Memory?.TotalPhysicalBytes);
        BuildTopUsers(classification?.Processes);
        BuildSensors(telemetry?.Providers);
        BuildDiagnostics();
        IsEmpty = false;
    }

    private void BuildMemory(ProcessInventorySummary? summary, long? totalBytes)
    {
        var percent = MemoryUsage.UsedPercent(totalBytes, summary?.AvailableMemoryBytes);
        HasMemory = percent is not null;
        if (percent is null)
        {
            MemoryHeadline = "Memory usage unavailable";
            MemoryDetail = "Physical RAM capacity or available memory could not be read.";
            MemoryUsedPercent = 0;
            PressureState = "neutral";
            return;
        }

        MemoryUsedPercent = percent.Value;
        PressureState = percent >= 85 ? "high" : percent >= 65 ? "medium" : "safe";
        MemoryHeadline = percent + "% of physical memory in use";
        MemoryDetail = Format.Bytes(summary!.AvailableMemoryBytes!.Value) + " free of " + Format.Bytes(totalBytes!.Value) + " · "
            + summary.ProcessCount + " processes · "
            + summary.BackgroundProcessCount + " in the background";
    }

    private void BuildTopUsers(List<ProcessItem>? processes)
    {
        TopMemoryRows.Clear();
        foreach (var p in (processes ?? new List<ProcessItem>())
            .Where(p => !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes)
            .Take(6))
        {
            TopMemoryRows.Add(new BackgroundRow(
                string.IsNullOrWhiteSpace(p.DisplayName) ? Naming.FriendlyName(p.Name) : p.DisplayName!,
                Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes),
                p.Protected ? "Excluded" : "Normal",
                p.Protected ? "low" : "neutral"));
        }
    }

    private void BuildSensors(IReadOnlyList<ProviderStatus>? providers)
    {
        SensorRows.Clear();
        foreach (var provider in providers ?? Array.Empty<ProviderStatus>())
        {
            SensorRows.Add(new StatusLine(provider.DisplayName, provider.DisplayState,
                provider.DisplayState == "Connected" ? "safe" : "neutral"));
        }
    }

    private void BuildDiagnostics()
    {
        DiagnosticRows.Clear();
        DiagnosticRows.Add(new("LatencyMon", "Measure driver latency and audio dropouts.", "Open tools", "neutral"));
        DiagnosticRows.Add(new("HWiNFO", "Inspect temperatures, clocks, and sensor readings.", "Open tools", "neutral"));
        DiagnosticRows.Add(new("UnparkCPU", "View and change CPU core parking.", "Open tools", "neutral"));
    }

}

public sealed record DiagnosticRow(string Title, string Detail, string StateText, string State);
