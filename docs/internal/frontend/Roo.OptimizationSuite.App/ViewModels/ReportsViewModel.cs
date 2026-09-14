using System.Collections.ObjectModel;
using System.Globalization;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.ViewModels;

public partial class ReportsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle = "Proof for what changed on this PC.";
    [ObservableProperty] private string _emptyNote =
        "No saved apply or restore run yet. Run Game Tune, ProBalance guard, or Apps & Cleanup, then this page can show what changed against this baseline.";
    [ObservableProperty] private string _baselineStatus = "Reading the current baseline.";

    public ObservableCollection<MetricTile> Baseline { get; } = new();

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

        Baseline.Clear();
        Baseline.Add(new MetricTile("Apps Running", summary.ProcessCount.ToString(CultureInfo.InvariantCulture),
            summary.BackgroundProcessCount + " background"));
        Baseline.Add(new MetricTile("RAM Free", Format.Bytes(summary.AvailableMemoryBytes), "available now"));
        Baseline.Add(new MetricTile("RAM In Use", Format.Bytes(used), "in use now"));
        BaselineStatus = "Baseline refreshed from live Windows counters.";
    }

    [RelayCommand]
    private Task RefreshBaselineAsync() => ReloadAsync();
}
