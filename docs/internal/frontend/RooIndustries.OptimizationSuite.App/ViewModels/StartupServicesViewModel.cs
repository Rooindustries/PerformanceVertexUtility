using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class StartupServicesViewModel : PageViewModelBase
{
    [ObservableProperty] private int _backgroundCount;
    [ObservableProperty] private int _launcherCount;
    [ObservableProperty] private int _protectedCount;
    [ObservableProperty] private string _loadSummary = "Reading background load...";

    public ObservableCollection<BackgroundRow> BackgroundRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var classification = await App.Live.GetProcessClassificationAsync();
        if (classification?.Processes is null) throw new InvalidOperationException(App.Live.LastError ?? "The background process list is unavailable.");
        var processes = classification.Processes;

        var background = processes
            .Where(p => p.Category is "backgroundApp" or "launcher" or "vendorUtility" or "browserWebView")
            .Where(p => !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .ToList();

        BackgroundCount = background.Count;
        LauncherCount = background.Count(p => p.Category is "launcher" or "vendorUtility");
        ProtectedCount = processes.Count(p => p.Protected || p.Protection == "protected");
        LoadSummary = background.Count == 0
            ? "No background processes reported."
            : background.Count + " background processes are running.";

        BackgroundRows.Clear();
        foreach (var p in background.OrderByDescending(p => p.WorkingSetBytes).Take(8))
        {
            BackgroundRows.Add(new BackgroundRow(
                string.IsNullOrWhiteSpace(p.DisplayName) ? Naming.FriendlyName(p.Name) : p.DisplayName!,
                Naming.CategoryLabel(p.Category),
                Format.Bytes(p.WorkingSetBytes),
                p.Protected ? "Excluded" : "Normal",
                p.Protected ? "low" : "neutral"));
        }

        IsEmpty = false;
    }

    [RelayCommand]
    private Task RetryAsync() => ReloadAsync();

}

public sealed record BackgroundRow(string Name, string Role, string Ram, string StateText, string State);
