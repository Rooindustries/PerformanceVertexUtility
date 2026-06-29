using System.Collections.ObjectModel;
using System.Globalization;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class MonitoringViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle = "What this PC is doing right now.";

    public ObservableCollection<MetricTile> LiveTiles { get; } = new();
    public ObservableCollection<MetricTile> PendingTiles { get; } = new();
    public ObservableCollection<StatusLine> Sensors { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetProcessInventoryAsync();
        var hardware = await App.Live.GetDriverHardwareAsync();
        var summary = inventory?.Summary;
        if (summary is null)
        {
            ErrorMessage = "We couldn't read this PC yet. Close and reopen to try again.";
            return;
        }

        var total = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var used = total > summary.AvailableMemoryBytes ? total - summary.AvailableMemoryBytes : 0;
        var usedPct = total > 0 ? ((int)System.Math.Round((double)used / total * 100)) + "% of memory" : "in use";
        var gpu = hardware?.Gpus?.Count > 0 ? hardware.Gpus[0].Name : "graphics";

        LiveTiles.Clear();
        LiveTiles.Add(new MetricTile("Apps Running", summary.ProcessCount.ToString(CultureInfo.InvariantCulture),
            summary.BackgroundProcessCount + " background"));
        LiveTiles.Add(new MetricTile("RAM Free", Format.Bytes(summary.AvailableMemoryBytes), "available now"));
        LiveTiles.Add(new MetricTile("RAM In Use", Format.Bytes(used), usedPct));
        LiveTiles.Add(new MetricTile("Windows Memory", Format.Bytes(summary.CommitUsedBytes), "commit charge"));

        PendingTiles.Clear();
        PendingTiles.Add(new MetricTile("Average FPS", "Not measured yet", "needs a capture tool"));
        PendingTiles.Add(new MetricTile("1% Low", "Not measured yet", "needs a capture tool"));
        PendingTiles.Add(new MetricTile("Frametime", "Not measured yet", "needs a capture tool"));
        PendingTiles.Add(new MetricTile("GPU Load", "Not measured yet", CleanDevice(gpu)));

        Sensors.Clear();
        Sensors.Add(new StatusLine("Windows counters", "Connected", "safe"));
        Sensors.Add(new StatusLine("Frame capture (PresentMon)", "Not connected", "neutral"));
        Sensors.Add(new StatusLine("HWiNFO64 sensors", "Not connected", "neutral"));
    }

    private static string CleanDevice(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "graphics";
        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("  ", " ").Trim();
    }
}
