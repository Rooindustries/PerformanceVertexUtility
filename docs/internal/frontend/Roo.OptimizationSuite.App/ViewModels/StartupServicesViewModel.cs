using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class StartupServicesViewModel : PageViewModelBase
{
    [ObservableProperty] private int _backgroundCount;
    [ObservableProperty] private int _launcherCount;
    [ObservableProperty] private int _protectedCount;
    [ObservableProperty] private string _loadSummary = "Reading background load…";

    public ObservableCollection<BackgroundRow> BackgroundRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var classification = await App.Live.GetProcessClassificationAsync()
            ?? await TrySample(Data.GetProcessClassificationAsync);
        var processes = classification?.Processes ?? new List<ProcessItem>();

        var background = processes
            .Where(p => p.Category is "backgroundApp" or "launcher" or "vendorUtility" or "browserWebView")
            .Where(p => !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .ToList();

        BackgroundCount = background.Count;
        LauncherCount = background.Count(p => p.Category is "launcher" or "vendorUtility");
        ProtectedCount = processes.Count(p => p.Protected || p.Protection == "protected");
        LoadSummary = background.Count == 0
            ? "No background load recorded yet — connect the local engine for a live view."
            : background.Count + " background apps and helpers are running that don't need to load with Windows.";

        BackgroundRows.Clear();
        foreach (var p in background.OrderByDescending(p => p.WorkingSetBytes).Take(8))
        {
            BackgroundRows.Add(new BackgroundRow(
                string.IsNullOrWhiteSpace(p.DisplayName) ? Naming.FriendlyName(p.Name) : p.DisplayName!,
                Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes),
                p.Protected ? "Protected" : "Reviewable",
                p.Protected ? "protected" : "neutral"));
        }

        IsEmpty = false;
    }

    private static async Task<T?> TrySample<T>(Func<Task<T>> load) where T : class
    {
        try { return await load(); } catch { return null; }
    }
}

public sealed record BackgroundRow(string Name, string Role, string Ram, string StateText, string State);
