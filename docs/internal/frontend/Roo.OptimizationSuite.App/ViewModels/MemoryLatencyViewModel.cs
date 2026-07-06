using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class MemoryLatencyViewModel : PageViewModelBase
{
    [ObservableProperty] private string _memoryHeadline = "Reading memory pressureâ€¦";
    [ObservableProperty] private string _memoryDetail = string.Empty;
    [ObservableProperty] private double _memoryUsedPercent;
    [ObservableProperty] private string _pressureState = "neutral";

    public ObservableCollection<BackgroundRow> TopMemoryRows { get; } = new();
    public ObservableCollection<StatusLine> SensorRows { get; } = new();
    public ObservableCollection<DiagnosticRow> DiagnosticRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetProcessInventoryAsync();
        var classification = await App.Live.GetProcessClassificationAsync();
        
        BuildMemory(inventory?.Summary);
        BuildTopUsers(classification?.Processes);
        BuildSensors(null);
        BuildDiagnostics();
        IsEmpty = false;
    }

    private void BuildMemory(ProcessInventorySummary? summary)
    {
        if (summary is null || summary.AvailableMemoryBytes <= 0)
        {
            MemoryHeadline = "Memory pressure not measured yet";
            MemoryDetail = "Connect the local engine to see live RAM pressure.";
            MemoryUsedPercent = 0;
            PressureState = "neutral";
            return;
        }

        var used = summary.CommitUsedBytes > 0 ? summary.CommitUsedBytes : summary.WorkingSetBytes;
        var total = used + summary.AvailableMemoryBytes;
        var percent = total > 0 ? Math.Round(100.0 * used / total) : 0;
        MemoryUsedPercent = percent;
        PressureState = percent >= 85 ? "high" : percent >= 65 ? "medium" : "safe";
        MemoryHeadline = percent + "% of memory in use â€” " + (percent >= 85 ? "heavy" : percent >= 65 ? "moderate" : "light") + " pressure";
        MemoryDetail = Format.Bytes(summary.AvailableMemoryBytes) + " free Â· "
            + summary.ProcessCount + " processes Â· "
            + summary.BackgroundProcessCount + " in the background";
    }

    private void BuildTopUsers(List<ProcessItem>? processes)
    {
        TopMemoryRows.Clear();
        foreach (var p in (processes ?? new List<ProcessItem>())
            .Where(p => !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes)
            .Take(4))
        {
            TopMemoryRows.Add(new BackgroundRow(
                string.IsNullOrWhiteSpace(p.DisplayName) ? Naming.FriendlyName(p.Name) : p.DisplayName!,
                Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes),
                p.Protected ? "Protected" : "Normal",
                p.Protected ? "protected" : "neutral"));
        }
    }

    private void BuildSensors(IReadOnlyList<ProviderStatus>? providers)
    {
        SensorRows.Clear();
        if (providers is null || providers.Count == 0)
        {
            SensorRows.Add(new StatusLine("Sensors", "Not connected", "neutral"));
            return;
        }
        foreach (var provider in providers ?? Array.Empty<ProviderStatus>())
        {
            SensorRows.Add(new StatusLine(provider.DisplayName, provider.DisplayState,
                provider.DisplayState == "Connected" ? "safe" : "neutral"));
        }
    }

    private void BuildDiagnostics()
    {
        DiagnosticRows.Clear();
        DiagnosticRows.Add(new DiagnosticRow(
            "DPC and driver latency",
            "LatencyMon-class diagnostics find the drivers behind stutter and audio dropouts. Read-only â€” it measures, it doesn't change anything.",
            "Read-only", "low"));
        DiagnosticRows.Add(new DiagnosticRow(
            "Core parking",
            "Roo handles core parking through native power-plan controls with full restore, so no third-party unpark tool is needed.",
            "Native", "safe"));
        DiagnosticRows.Add(new DiagnosticRow(
            "Standby memory and caches",
            "Standby-list and shader-cache actions arrive preview-gated: see exactly what clears before anything does.",
            "Preview-gated", "protected"));
    }

    private static async Task<T?> TrySample<T>(Func<Task<T>> load) where T : class
    {
        try { return await load(); } catch { return null; }
    }
}

public sealed record DiagnosticRow(string Title, string Detail, string StateText, string State);
