using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class PerformanceProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string _gameStatus = "No game running";
    [ObservableProperty] private string _gameStatusLevel = "neutral";
    [ObservableProperty] private string _ruleSummary =
        "The game gets the room. Companions stay protected. Launchers and browser helpers get quieted.";
    [ObservableProperty] private int _appsCount;
    [ObservableProperty] private int _keepCount;
    [ObservableProperty] private int _quietCount;
    [ObservableProperty] private string _searchText = string.Empty;

    private readonly List<GameAppRow> _all = new();
    public ObservableCollection<GameAppRow> Rows { get; } = new();

    private static readonly string[] QuietCategories = { "browserWebView", "launcher", "vendorUtility", "backgroundApp" };

    protected override async Task LoadCoreAsync()
    {
        var classification = await App.Live.GetProcessClassificationAsync();
        var processes = classification?.Processes;
        if (processes is null || processes.Count == 0)
        {
            ErrorMessage = "We couldn't read your processes yet. Close and reopen to try again.";
            return;
        }

        var game = processes.FirstOrDefault(p => p.Category == "foregroundGame");
        if (game is not null)
        {
            GameStatus = Naming.FriendlyName(game.Name) + " running";
            GameStatusLevel = "safe";
        }
        else
        {
            GameStatus = "No game running";
            GameStatusLevel = "neutral";
        }

        _all.Clear();
        foreach (var p in processes
            .Where(p => p.Category != "windowsCore" && !Naming.IsNonActionable(p.Name)
                        && !LocalDisplayFilter.Default.IsHidden(Naming.FriendlyName(p.Name), p.Name, null))
            .OrderByDescending(p => p.WorkingSetBytes))
        {
            var (plan, state) = PlanFor(p);
            _all.Add(new GameAppRow(
                Naming.FriendlyName(p.Name),
                Naming.CategoryLabel(p.Category),
                FriendlyPriority(p.PriorityClass),
                p.CpuPercent.ToString("0.#", CultureInfo.InvariantCulture) + "%",
                Format.Bytes(p.WorkingSetBytes),
                plan,
                state));
        }

        AppsCount = _all.Count;
        KeepCount = _all.Count(r => r.Plan == "Keep");
        QuietCount = _all.Count(r => r.Plan == "Quiet");

        ApplyFilter();
        IsEmpty = _all.Count == 0;
    }

    private static (string plan, string state) PlanFor(ProcessItem p)
    {
        if (p.Category == "foregroundGame") return ("Boost", "safe");
        if (p.Protection == "protected") return ("Keep", "protected");
        if (QuietCategories.Contains(p.Category)) return ("Quiet", "low");
        return ("Watch", "neutral");
    }

    private static string FriendlyPriority(string? priorityClass) => priorityClass switch
    {
        "AboveNormal" => "Above",
        "BelowNormal" => "Below",
        "RealTime" => "Realtime",
        "High" => "High",
        "Idle" => "Idle",
        null or "" => "Normal",
        _ => priorityClass!,
    };

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    private void ApplyFilter()
    {
        var query = SearchText?.Trim();
        IEnumerable<GameAppRow> source = _all;
        if (!string.IsNullOrEmpty(query))
        {
            source = source.Where(r =>
                r.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Role.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Plan.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        Rows.Clear();
        foreach (var r in source)
        {
            Rows.Add(r);
        }
    }
}
