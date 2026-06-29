using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class DashboardViewModel : PageViewModelBase
{
    [ObservableProperty] private string _verdictHeadline = "Reading this PC";
    [ObservableProperty] private string _verdictLevel = "medium";
    [ObservableProperty] private string? _verdictSummary;
    [ObservableProperty] private string? _driverNote;
    [ObservableProperty] private int _memoryUsedPercent;
    [ObservableProperty] private string _memoryPressureLabel = "Reading";
    [ObservableProperty] private string? _memoryPressureLine;

    public ObservableCollection<StatusLine> SessionLines { get; } = new();
    public ObservableCollection<MetricTile> MemoryStats { get; } = new();
    public ObservableCollection<UsageLine> TopMemoryUsers { get; } = new();
    public ObservableCollection<MetricTile> BackgroundStats { get; } = new();
    public ObservableCollection<UsageLine> BackgroundOffenders { get; } = new();
    public ObservableCollection<StatusLine> ProtectedApps { get; } = new();
    public ObservableCollection<StatusLine> DriverLines { get; } = new();
    public ObservableCollection<StatusLine> SensorLines { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetProcessInventoryAsync();
        var hardware = await App.Live.GetDriverHardwareAsync();

        if (inventory?.Summary is null)
        {
            WriteDiag(inventory);
            ErrorMessage = "We couldn't read this PC yet. Close and reopen to try again.";
            return;
        }

        var summary = inventory.Summary;
        var processes = inventory.Processes ?? new List<ProcessItem>();

        var totalRam = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var ramGb = totalRam > 0 ? (int)System.Math.Round(totalRam / 1073741824d) : 0;
        var freeRam = summary.AvailableMemoryBytes;
        var usedRam = totalRam > freeRam ? totalRam - freeRam : 0;
        double? freeRatio = totalRam > 0 ? (double)freeRam / totalRam : null;

        BuildVerdict(freeRatio, summary, hardware, ramGb);
        BuildSession(processes);
        BuildMemory(summary, usedRam, totalRam, ramGb, hardware);
        BuildTopUsers(processes);
        BuildBackground(summary, processes);
        BuildProtected(processes);
        BuildDriver(hardware);
        BuildSensors();
    }

    private void BuildVerdict(double? freeRatio, ProcessInventorySummary summary, DriverHardwareSummary? hw, int ramGb)
    {
        (VerdictHeadline, VerdictLevel) = freeRatio switch
        {
            >= 0.30 => ("Your PC has memory to spare.", "safe"),
            >= 0.15 => ("Memory is getting tight. A tune will free up room.", "medium"),
            < 0.15 and >= 0 => ("Memory is under pressure. Clear room before you play.", "high"),
            _ => ("Checking memory pressure on this PC.", "medium"),
        };

        var gpu = CleanDevice(hw?.Gpus?.FirstOrDefault()?.Name);
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(gpu)) parts.Add(gpu);
        if (ramGb > 0) parts.Add(ramGb + " GB RAM");
        parts.Add(summary.ProcessCount + " apps open, " + summary.BackgroundProcessCount + " in the background");
        VerdictSummary = string.Join("  ·  ", parts);
    }

    private void BuildSession(IReadOnlyList<ProcessItem> processes)
    {
        SessionLines.Clear();

        var game = processes.FirstOrDefault(p => p.Category == "foregroundGame");
        SessionLines.Add(game is not null
            ? new StatusLine("Game", Naming.FriendlyName(game.Name), "safe")
            : new StatusLine("Game", "No game detected", "neutral"));

        var companions = processes
            .Where(p => p.Protection == "protected" && (p.Category is "voiceChat" or "captureStreaming"))
            .Select(p => Naming.FriendlyName(p.Name))
            .Distinct()
            .ToList();
        SessionLines.Add(companions.Count > 0
            ? new StatusLine("Companion apps", string.Join(" + ", companions) + " protected", "safe")
            : new StatusLine("Companion apps", "None running", "neutral"));

        SessionLines.Add(new StatusLine("Refresh target", "Not set", "neutral"));
    }

    private void BuildMemory(ProcessInventorySummary s, long usedRam, long totalRam, int ramGb, DriverHardwareSummary? hw)
    {
        MemoryUsedPercent = totalRam > 0 ? (int)System.Math.Round((double)usedRam / totalRam * 100) : 0;
        MemoryPressureLabel = MemoryUsedPercent switch
        {
            >= 85 => "Heavy",
            >= 70 => "Moderate",
            _ => "Light",
        };

        var totalText = ramGb > 0 ? ramGb + " GB" : Format.Bytes(totalRam);
        MemoryPressureLine = Format.Bytes(s.AvailableMemoryBytes) + " free of " + totalText
            + "  ·  Windows memory " + Format.Bytes(s.CommitUsedBytes);
    }

    private void BuildTopUsers(IReadOnlyList<ProcessItem> processes)
    {
        TopMemoryUsers.Clear();
        var rows = processes
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes)
            .Take(5);

        foreach (var p in rows)
        {
            TopMemoryUsers.Add(new UsageLine(Naming.FriendlyName(p.Name), Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes)));
        }
    }

    private void BuildBackground(ProcessInventorySummary s, IReadOnlyList<ProcessItem> processes)
    {
        BackgroundStats.Clear();
        BackgroundStats.Add(new MetricTile("Apps Running", s.ProcessCount.ToString(CultureInfo.InvariantCulture), "total processes"));
        BackgroundStats.Add(new MetricTile("Background", s.BackgroundProcessCount.ToString(CultureInfo.InvariantCulture), "not in focus"));
        BackgroundStats.Add(new MetricTile("Browser / Web", s.BrowserWebViewProcessCount.ToString(CultureInfo.InvariantCulture), "tabs and helpers"));

        BackgroundOffenders.Clear();
        var rows = processes
            .Where(p => p.Protection != "protected" && p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes)
            .Take(6);

        foreach (var p in rows)
        {
            BackgroundOffenders.Add(new UsageLine(Naming.FriendlyName(p.Name), Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes)));
        }
    }

    private void BuildProtected(IReadOnlyList<ProcessItem> processes)
    {
        ProtectedApps.Clear();
        var present = processes.Where(p => p.Protection == "protected").Select(p => p.Category).ToHashSet();

        foreach (var category in new[] { "voiceChat", "captureStreaming", "audioInput", "network", "security" })
        {
            if (present.Contains(category))
            {
                ProtectedApps.Add(new StatusLine(Naming.CategoryLabel(category), "Kept safe", "protected"));
            }
        }

        if (ProtectedApps.Count == 0)
        {
            ProtectedApps.Add(new StatusLine("Voice, audio, network, security", "Kept safe", "protected"));
        }
    }

    private void BuildDriver(DriverHardwareSummary? hw)
    {
        DriverLines.Clear();
        var machine = hw?.Machine;
        if (machine is not null)
        {
            var system = string.Join(" ", new[] { machine.Manufacturer, machine.Model }.Where(x => !string.IsNullOrWhiteSpace(x)));
            DriverLines.Add(new StatusLine("System", string.IsNullOrWhiteSpace(system) ? "Unknown" : system, "neutral"));
            if (!string.IsNullOrWhiteSpace(machine.OsCaption))
            {
                DriverLines.Add(new StatusLine("Windows", machine.OsCaption!, "neutral"));
            }
        }

        var cpu = CleanDevice(hw?.Cpu?.Name);
        if (!string.IsNullOrWhiteSpace(cpu))
        {
            DriverLines.Add(new StatusLine("Processor", cpu!, "neutral"));
        }

        var gpu = hw?.Gpus?.FirstOrDefault();
        if (gpu is not null)
        {
            var gpuText = CleanDevice(gpu.Name);
            if (!string.IsNullOrWhiteSpace(gpu.DriverVersion))
            {
                gpuText += "  ·  Driver " + gpu.DriverVersion;
            }
            DriverLines.Add(new StatusLine("Graphics", gpuText ?? "Unknown", "neutral"));
        }

        DriverNote = "Driver and GPU changes stay manual. Nothing installs until you approve it.";
    }

    private void BuildSensors()
    {
        SensorLines.Clear();
        SensorLines.Add(new StatusLine("Windows Sensors", "Connected", "safe"));
        SensorLines.Add(new StatusLine("HWiNFO64 Sensors", "Not connected", "neutral"));
        SensorLines.Add(new StatusLine("FPS & 1% Lows", "Not measured yet", "neutral"));
    }

    private static void WriteDiag(ProcessInventory? inventory)
    {
        try
        {
            var dir = System.IO.Path.Combine(
                System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
                "RooOptimizationSuite");
            System.IO.Directory.CreateDirectory(dir);
            var text =
                "repoRoot=" + (App.Live.RepoRoot ?? "null") + System.Environment.NewLine +
                "scriptsDir=" + (App.Live.ScriptsDirectory ?? "null") + System.Environment.NewLine +
                "scriptsAvailable=" + App.Live.ScriptsAvailable + System.Environment.NewLine +
                "inventoryNull=" + (inventory is null) + System.Environment.NewLine +
                "baseDir=" + System.AppContext.BaseDirectory + System.Environment.NewLine +
                "lastError=" + (App.Live.LastError ?? "none");
            System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "live-diag.log"), text);
        }
        catch
        {
        }
    }

    private static string? CleanDevice(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("(C)", string.Empty)
            .Replace("  ", " ").Trim();
    }
}
