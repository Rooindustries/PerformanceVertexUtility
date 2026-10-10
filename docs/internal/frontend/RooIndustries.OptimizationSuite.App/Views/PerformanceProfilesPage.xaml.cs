using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class PerformanceProfilesPage : Page, IRevalidatingPage
{
    public System.Threading.Tasks.Task RevalidateAsync() => ViewModel.RevalidateAsync();
    public PerformanceProfilesViewModel ViewModel { get; } = new();
    public PerformanceProfilesPage()
    {
        InitializeComponent();
        NavigationCacheMode = Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    public void ShowProcesses() => ProcessTabs.SelectedIndex = 1;
}
