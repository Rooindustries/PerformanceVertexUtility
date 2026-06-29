using System.Collections.Generic;
using System.Collections.ObjectModel;
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

    public string Tagline => "Precision Performance Engineering";
    public IReadOnlyList<ThemeOption> Themes => App.Theme.Options;
    public ObservableCollection<SafetyRow> SafetyRows { get; } = new();

    public SettingsViewModel()
    {
        _selectedThemeId = App.Theme.CurrentThemeId;
        _reducedEffects = App.Theme.ReducedEffects;
    }

    protected override async Task LoadCoreAsync()
    {
        var product = await Data.GetProductStatusAsync();
        ProductName = string.IsNullOrWhiteSpace(product.ProductName) ? "Roo Industries Optimization Suite" : product.ProductName;
        VersionText = "Version " + (product.BackendPackageVersion?.Replace("-contracts", string.Empty) ?? "0.1.0");
        BuildSafetyRows(product.Safety);
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
        SafetyRows.Add(new SafetyRow("One-click undo", safety.RollbackVisible ? "On" : "Off", safety.RollbackVisible ? "safe" : "medium"));
        SafetyRows.Add(new SafetyRow("Remote scripts", safety.RemoteScriptExecutionAllowed ? "Allowed" : "Blocked", safety.RemoteScriptExecutionAllowed ? "high" : "safe"));
        SafetyRows.Add(new SafetyRow("Automatic driver changes", safety.DriverAutomationAllowed ? "Allowed" : "Blocked", safety.DriverAutomationAllowed ? "high" : "safe"));
        SafetyRows.Add(new SafetyRow("Leftover removal", safety.LeftoverDeletionAllowedByDefault ? "On" : "Off by default", safety.LeftoverDeletionAllowedByDefault ? "high" : "safe"));
    }

    partial void OnSelectedThemeIdChanged(string value) => App.Theme.SetTheme(value);

    partial void OnReducedEffectsChanged(bool value) => App.Theme.SetReducedEffects(value);
}
