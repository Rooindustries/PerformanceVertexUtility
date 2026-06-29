using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Roo.OptimizationSuite.Helpers;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class UninstallCleanupViewModel : PageViewModelBase
{
    [ObservableProperty] private string _searchText = string.Empty;
    [ObservableProperty] private int _appCount;
    [ObservableProperty] private string? _sources;

    [ObservableProperty] private InstalledApp? _selectedApp;
    [ObservableProperty] private string? _selectedName;
    [ObservableProperty] private string? _selectedSummary;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _selectedProtected;
    [ObservableProperty] private string? _officialCommand;
    [ObservableProperty] private string? _installLocation;

    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _hasSelection;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(CanScan))] private bool _scanBusy;
    [ObservableProperty] private string _leftoverState = "Pick an app on the left to review its uninstall and leftovers.";
    [ObservableProperty] private string? _leftoverSummary;

    public bool CanScan => HasSelection && !SelectedProtected && !ScanBusy;

    private readonly List<InstalledApp> _allApps = new();
    public ObservableCollection<InstalledApp> Apps { get; } = new();
    public ObservableCollection<LeftoverItem> Leftovers { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetInstalledAppsAsync();
        var apps = inventory?.Apps;
        if (apps is null || apps.Count == 0)
        {
            ErrorMessage = "We couldn't read your installed apps yet. Close and reopen to try again.";
            return;
        }

        _allApps.Clear();
        _allApps.AddRange(apps
            .Where(a => a.IsListable && !Naming.IsNonActionable(a.DisplayName)
                        && !LocalDisplayFilter.Default.IsHidden(a.FriendlyName, null, a.PackageId ?? a.DisplayName))
            .OrderBy(a => a.FriendlyName, StringComparer.OrdinalIgnoreCase));
        AppCount = _allApps.Count;
        Sources = inventory!.Sources is { Count: > 0 } s ? string.Join(", ", s.Select(FriendlySource)) : null;

        ApplyFilter();
        IsEmpty = _allApps.Count == 0;
    }

    partial void OnSearchTextChanged(string value) => ApplyFilter();

    partial void OnSelectedAppChanged(InstalledApp? value)
    {
        Leftovers.Clear();
        LeftoverSummary = null;
        HasSelection = value is not null;

        if (value is null)
        {
            LeftoverState = "Pick an app on the left to review its uninstall and leftovers.";
            return;
        }

        SelectedName = value.FriendlyName;
        SelectedProtected = value.Protected;
        var bits = new List<string>();
        if (!string.IsNullOrWhiteSpace(value.SecondaryLabel)) bits.Add(value.SecondaryLabel!);
        if (value.EstimatedSizeBytes is > 0) bits.Add(Format.Bytes(value.EstimatedSizeBytes!.Value));
        SelectedSummary = string.Join("  ·  ", bits);

        InstallLocation = string.IsNullOrWhiteSpace(value.InstallLocation) ? "Not recorded" : value.InstallLocation;
        OfficialCommand = string.IsNullOrWhiteSpace(value.UninstallString)
            ? "No standard uninstaller is registered for this app."
            : value.UninstallString;

        LeftoverState = value.Protected
            ? "This is a protected component. It stays out of cleanup."
            : "Run a leftover scan when you're ready. Nothing is removed.";
    }

    [RelayCommand]
    private async Task ScanLeftoversAsync()
    {
        var app = SelectedApp;
        if (app is null || app.Protected || string.IsNullOrWhiteSpace(app.AppId))
        {
            return;
        }

        ScanBusy = true;
        Leftovers.Clear();
        LeftoverSummary = null;
        LeftoverState = "Scanning for leftovers…";
        try
        {
            var scan = await App.Live.GetLeftoverScanAsync(app.AppId!);
            var items = scan?.Items ?? new List<LeftoverItem>();
            foreach (var item in items)
            {
                Leftovers.Add(item);
            }

            if (items.Count == 0)
            {
                LeftoverState = "No leftovers found for this app.";
            }
            else
            {
                LeftoverState = string.Empty;
                var recoverable = scan?.Summary?.EstimatedRecoverableBytes ?? 0;
                LeftoverSummary = items.Count + " item" + (items.Count == 1 ? "" : "s")
                    + (recoverable > 0 ? "  ·  " + Format.Bytes(recoverable) + " recoverable" : string.Empty);
            }
        }
        catch
        {
            LeftoverState = "Couldn't scan this app right now.";
        }
        finally
        {
            ScanBusy = false;
        }
    }

    private void ApplyFilter()
    {
        var query = SearchText?.Trim();
        IEnumerable<InstalledApp> source = _allApps;
        if (!string.IsNullOrEmpty(query))
        {
            source = source.Where(a =>
                Contains(a.FriendlyName, query) ||
                Contains(a.PublisherDisplay, query));
        }

        Apps.Clear();
        foreach (var a in source)
        {
            Apps.Add(a);
        }
    }

    private static bool Contains(string? haystack, string needle)
        => haystack is not null && haystack.Contains(needle, StringComparison.OrdinalIgnoreCase);

    private static string FriendlySource(string? source) => source switch
    {
        "registry" => "Installed program",
        "msi" => "Windows Installer",
        "appx" => "Store app",
        "winget" => "Winget",
        null or "" => "App",
        _ => source!,
    };
}
