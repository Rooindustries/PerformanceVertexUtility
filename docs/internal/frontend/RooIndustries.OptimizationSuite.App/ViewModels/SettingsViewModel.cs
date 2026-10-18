using System.Collections.Generic;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class SettingsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _selectedThemeId;
    [ObservableProperty] private bool _reducedEffects;
    [ObservableProperty] private bool _simpleMode;
    [ObservableProperty] private string? _productName = "Performance Vertex Utility";
    [ObservableProperty] private string? _versionText = "Version " + App.VersionText;

    public IReadOnlyList<ThemeOption> Themes => App.Theme.Options;
    public string LogFolder => AppLog.Folder;

    public SettingsViewModel()
    {
        _selectedThemeId = App.Theme.CurrentThemeId;
        _reducedEffects = App.Theme.ReducedEffects;
        _simpleMode = App.Theme.SimpleMode;
    }

    protected override Task LoadCoreAsync() => Task.CompletedTask;

    partial void OnSelectedThemeIdChanged(string value) => App.Theme.SetTheme(value);

    partial void OnReducedEffectsChanged(bool value) => App.Theme.SetReducedEffects(value);

    partial void OnSimpleModeChanged(bool value) => App.Theme.SetSimpleMode(value);
}
