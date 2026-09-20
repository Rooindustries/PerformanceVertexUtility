using System.Collections.Generic;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class SettingsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _selectedThemeId;
    [ObservableProperty] private bool _reducedEffects;
    [ObservableProperty] private string? _productName;
    [ObservableProperty] private string? _versionText;

    public IReadOnlyList<ThemeOption> Themes => App.Theme.Options;

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
    }

    partial void OnSelectedThemeIdChanged(string value) => App.Theme.SetTheme(value);

    partial void OnReducedEffectsChanged(bool value) => App.Theme.SetReducedEffects(value);
}
