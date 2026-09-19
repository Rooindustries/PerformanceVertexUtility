using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class DashboardPage : Page
{
    public DashboardViewModel ViewModel { get; } = new();
    public DashboardPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.ReloadAsync();
    private void OnDashboardActionClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag }) (App.MainWindow as MainWindow)?.SelectNav(tag);
    }
    private void OnProcessesClick(object sender, RoutedEventArgs e)
    {
        (App.MainWindow as MainWindow)?.SelectNav("profiles");
        if (App.MainWindow is MainWindow window) window.ShowProcesses();
    }
}
