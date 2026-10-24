using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class MemoryLatencyViewModel : PageViewModelBase
{
    [ObservableProperty] private string _memoryHeadline = "Checking your RAM";
    [ObservableProperty] private string _memoryDetail = string.Empty;
    [ObservableProperty] private double _memoryUsedPercent;
    [ObservableProperty] private bool _hasMemory;
    [ObservableProperty] private string _pressureState = "neutral";

    public ObservableCollection<BackgroundRow> TopMemoryRows { get; } = new();
    public ObservableCollection<StatusLine> SensorRows { get; } = new();
    public ObservableCollection<DiagnosticRow> DiagnosticRows { get; } = new();

    [ObservableProperty]
    private string _topMemoryNote = "";

    private const string ReadFailed = "Click Retry. If it keeps failing, use Report a bug to send us the details.";
    private const string TopUnavailable = "Couldn't see which apps use the most RAM right now.";

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
        {
            AppLog.Write(nameof(MemoryLatencyViewModel), "Memory read failed: " + (inventoryResult.Error ?? "no inventory") + " | " + (classificationResult.Error ?? "no classification"));
            throw new InvalidOperationException(inventoryResult.Error == AppLog.MissingFiles || classificationResult.Error == AppLog.MissingFiles ? AppLog.MissingFiles : ReadFailed);
        }
        if (classificationResult.Stale) RevalidateAfterLoad();
        if (classification is null) AppLog.Write(nameof(MemoryLatencyViewModel), "App memory list failed: " + (classificationResult.Error ?? "no classification"));
        TopMemoryNote = classification is null ? TopUnavailable : "";
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
            MemoryHeadline = "Couldn't check your RAM use";
            MemoryDetail = "Windows didn't say how much RAM you have free. Come back to this page in a moment to check again.";
            MemoryUsedPercent = 0;
            PressureState = "neutral";
            return;
        }

        MemoryUsedPercent = percent.Value;
        PressureState = percent >= 85 ? "high" : percent >= 65 ? "medium" : "safe";
        MemoryHeadline = percent + "% of your RAM in use";
        MemoryDetail = Format.Bytes(summary!.AvailableMemoryBytes!.Value) + " free of " + Format.Bytes(totalBytes!.Value) + " · "
            + summary.ProcessCount + " tasks running · "
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
                p.Protected ? "Left alone" : "",
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
        DiagnosticRows.Add(new("LatencyMon", "Find drivers that cause stutter and crackling audio.", "Go to Tools", "neutral"));
        DiagnosticRows.Add(new("HWiNFO", "See temperatures, clock speeds and fan speeds.", "Go to Tools", "neutral"));
        DiagnosticRows.Add(new("UnparkCPU", "See which CPU cores Windows puts to sleep, and wake them up.", "Go to Tools", "neutral"));
    }

}

public sealed record DiagnosticRow(string Title, string Detail, string StateText, string State)
{
    public string ToolsButtonName => StateText + " for " + Title;
}
