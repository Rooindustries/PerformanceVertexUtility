using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Models;
using Roo.OptimizationSuite.Services;

namespace Roo.OptimizationSuite.ViewModels;

public partial class SettingsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _selectedThemeId;
    [ObservableProperty] private bool _reducedEffects;
    [ObservableProperty] private string? _productName;
    [ObservableProperty] private string? _versionText;
    [ObservableProperty] private string? _engineStatus;
    [ObservableProperty] private string? _dataSourceStatus;
    [ObservableProperty] private string _dataSourceState = "protected";
    [ObservableProperty] private string? _capabilitySourceStatus;
    [ObservableProperty] private string _capabilitySourceState = "protected";

    public string Tagline => "Precision Performance Engineering";
    public IReadOnlyList<ThemeOption> Themes => App.Theme.Options;
    public ObservableCollection<SafetyRow> SafetyRows { get; } = new();
    public ObservableCollection<StatusLine> EngineRows { get; } = new();
    public ObservableCollection<StatusLine> SensorRows { get; } = new();

    public SettingsViewModel()
    {
        _selectedThemeId = App.Theme.CurrentThemeId;
        _reducedEffects = App.Theme.ReducedEffects;
    }

    protected override async Task LoadCoreAsync()
    {
        var product = await Data.GetProductStatusAsync();
        var dashboard = await Data.GetDashboardAsync();
        var telemetry = await Data.GetTelemetryAsync();
        var capabilities = await TryLoadCapabilitiesAsync();

        ProductName = string.IsNullOrWhiteSpace(product.ProductName) ? "Roo Industries Optimization Suite" : product.ProductName;
        VersionText = "Build " + ContractVersion(product.BackendPackageVersion);
        EngineStatus = "Roo checks what this PC supports before showing an action. Review, approval, and restore state stay visible before anything changes.";
        DataSourceStatus = App.Live.ScriptsAvailable ? "Live scripts available on this PC" : "Bundled sample data because backend scripts were not found";
        DataSourceState = App.Live.ScriptsAvailable ? "safe" : "protected";

        SetCapabilitySourceStatus(capabilities?.Count);
        BuildSafetyRows(product.Safety);
        BuildProviderRows(dashboard.ProviderStatus, telemetry.Providers);
    }

    private void BuildProviderRows(IReadOnlyList<ProviderStatus>? dashboardProviders, IReadOnlyList<ProviderStatus>? telemetryProviders)
    {
        EngineRows.Clear();
        SensorRows.Clear();
        EngineRows.Add(new StatusLine("Optimization catalog", CapabilitySourceStatus ?? "Optimization catalog not loaded", CapabilitySourceState));
        EngineRows.Add(new StatusLine("Action names", "Plain-language names for every optimization", "protected"));
        EngineRows.Add(new StatusLine("Live data", DataSourceStatus ?? "Bundled sample data because backend scripts were not found", DataSourceState));

        var providers = new List<ProviderStatus>();
        if (dashboardProviders is not null)
        {
            providers.AddRange(dashboardProviders);
        }

        if (telemetryProviders is not null)
        {
            foreach (var provider in telemetryProviders.Where(p => providers.All(existing => existing.ProviderId != p.ProviderId)))
            {
                providers.Add(provider);
            }
        }

        foreach (var provider in providers)
        {
            var row = new StatusLine(provider.DisplayName, ProviderState(provider.State), ProviderRisk(provider.State));
            EngineRows.Add(row);
            SensorRows.Add(row);
        }
    }

    private void BuildSafetyRows(SafetyStatus? safety)
    {
        SafetyRows.Clear();
        if (safety is null)
        {
            return;
        }

        SafetyRows.Add(new SafetyRow("Default mode", "Review first", "protected"));
        SafetyRows.Add(new SafetyRow("Ask before changes", safety.RequiresExplicitConfirmation ? "On" : "Off", safety.RequiresExplicitConfirmation ? "protected" : "high"));
        SafetyRows.Add(new SafetyRow("Back up before changes", safety.BackupRequiredBeforeApply ? "On" : "Off", safety.BackupRequiredBeforeApply ? "protected" : "high"));
        SafetyRows.Add(new SafetyRow("Restore shown per capability", safety.RollbackVisible ? "On" : "Off", safety.RollbackVisible ? "safe" : "medium"));
        SafetyRows.Add(new SafetyRow("Remote actions", safety.RemoteScriptExecutionAllowed ? "Allowed" : "Off", safety.RemoteScriptExecutionAllowed ? "high" : "safe"));
        SafetyRows.Add(new SafetyRow("Driver changes", safety.DriverAutomationAllowed ? "Automatic" : "Manual", safety.DriverAutomationAllowed ? "high" : "protected"));
        SafetyRows.Add(new SafetyRow("Leftover removal", safety.LeftoverDeletionAllowedByDefault ? "On" : "Off by default", safety.LeftoverDeletionAllowedByDefault ? "high" : "safe"));
    }

    private void SetCapabilitySourceStatus(int? capabilityCount)
    {
        var countText = capabilityCount.HasValue
            ? capabilityCount.Value.ToString(CultureInfo.InvariantCulture) + " capabilities"
            : "registry not loaded";

        if (App.Live.ScriptsAvailable && string.IsNullOrWhiteSpace(App.Capabilities.LastError))
        {
            CapabilitySourceStatus = "Live from this PC - " + countText;
            CapabilitySourceState = capabilityCount.HasValue ? "safe" : "high";
            return;
        }

        if (App.Live.ScriptsAvailable)
        {
            CapabilitySourceStatus = "Bundled sample data - live registry unavailable";
            CapabilitySourceState = capabilityCount.HasValue ? "protected" : "high";
            return;
        }

        CapabilitySourceStatus = "Bundled sample data - " + countText;
        CapabilitySourceState = capabilityCount.HasValue ? "protected" : "high";
    }

    private static string ProviderState(string? state) => (state ?? string.Empty).ToLowerInvariant() switch
    {
        "available" => "Connected",
        "sample" => "Sample capture",
        "optional-not-detected" or "missing" => "Not connected",
        _ => string.IsNullOrWhiteSpace(state) ? "Unknown" : state!.Replace('-', ' '),
    };

    private static string ProviderRisk(string? state) => (state ?? string.Empty).ToLowerInvariant() switch
    {
        "available" => "safe",
        "sample" => "neutral",
        "optional-not-detected" or "missing" => "neutral",
        _ => "neutral",
    };

    private static string ContractVersion(string? version)
        => string.IsNullOrWhiteSpace(version) ? "0.1.0" : version!.Replace("-contracts", string.Empty);

    private static async Task<IReadOnlyList<CapabilityRow>?> TryLoadCapabilitiesAsync()
    {
        try
        {
            return await App.Capabilities.GetCapabilitiesAsync();
        }
        catch
        {
            return null;
        }
    }

    partial void OnSelectedThemeIdChanged(string value) => App.Theme.SetTheme(value);

    partial void OnReducedEffectsChanged(bool value) => App.Theme.SetReducedEffects(value);
}
