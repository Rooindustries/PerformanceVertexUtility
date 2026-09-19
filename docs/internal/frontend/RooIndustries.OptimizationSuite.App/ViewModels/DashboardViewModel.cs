using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class DashboardViewModel : PageViewModelBase
{
    [ObservableProperty] private int _memoryUsedPercent;
    [ObservableProperty] private string _memoryValue = "Unavailable";
    [ObservableProperty] private bool _hasMemory;
    [ObservableProperty] private string _memoryPressureLine = "";
    [ObservableProperty] private int _processCount;
    [ObservableProperty] private string _backgroundSummary = "";
    [ObservableProperty] private string _gameName = "None detected";

    public ObservableCollection<UsageLine> TopMemoryUsers { get; } = new();
    public ObservableCollection<StatusLine> DriverLines { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetProcessInventoryAsync();
        var hardware = await App.Live.GetDriverHardwareAsync();
        if (inventory?.Summary is not { } summary)
        {
            ErrorMessage = App.Live.LastError ?? "Couldn't read running apps. Select Refresh to try again.";
            return;
        }

        var processes = inventory.Processes ?? new List<ProcessItem>();
        ProcessCount = summary.ProcessCount;
        BackgroundSummary = summary.BackgroundProcessCount + " in the background";
        var game = processes.FirstOrDefault(process => process.Category == "foregroundGame");
        GameName = game is null ? "None detected" : Naming.FriendlyName(game.Name);

        var total = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var percent = MemoryUsage.UsedPercent(total, summary.AvailableMemoryBytes);
        HasMemory = percent is not null;
        MemoryUsedPercent = percent ?? 0;
        MemoryValue = HasMemory ? MemoryUsedPercent + "% in use" : "Unavailable";
        MemoryPressureLine = HasMemory ? Format.Bytes(summary.AvailableMemoryBytes!.Value) + " free of " + Format.Bytes(total) : "Memory capacity could not be read.";

        TopMemoryUsers.Clear();
        foreach (var process in processes.Where(process => process.Category != "windowsCore" && !Naming.IsNonActionable(process.Name)
            && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(process.Name), process.Name, null))
            .OrderByDescending(process => process.WorkingSetBytes).Take(5))
            TopMemoryUsers.Add(new(Naming.FriendlyName(process.Name), Naming.CategoryLabel(process.Category), Format.Bytes(process.WorkingSetBytes)));

        DriverLines.Clear();
        if (hardware?.Machine is { } machine)
        {
            var system = string.Join(" ", new[] { machine.Manufacturer, machine.Model }.Where(value => !string.IsNullOrWhiteSpace(value)));
            DriverLines.Add(new("System", string.IsNullOrWhiteSpace(system) ? "Unavailable" : system, "neutral"));
            DriverLines.Add(new("Windows", machine.OsCaption ?? "Unavailable", "neutral"));
        }
        DriverLines.Add(new("Processor", CleanDevice(hardware?.Cpu?.Name), "neutral"));
        var gpu = hardware?.Gpus?.FirstOrDefault();
        DriverLines.Add(new("Graphics", CleanDevice(gpu?.Name), "neutral"));
        DriverLines.Add(new("GPU driver", gpu?.DriverVersion ?? "Unavailable", "neutral"));
    }

    private static string CleanDevice(string? name) => string.IsNullOrWhiteSpace(name) ? "Unavailable"
        : name.Replace("(R)", "").Replace("(TM)", "").Replace("(C)", "").Replace("  ", " ").Trim();
}
