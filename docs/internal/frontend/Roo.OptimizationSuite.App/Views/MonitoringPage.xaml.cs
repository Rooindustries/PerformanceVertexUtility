using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class MonitoringPage : Page
{
    public MonitoringViewModel ViewModel { get; } = new();

    public MonitoringPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    private async void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        await ViewModel.ReloadAsync();
    }
}
