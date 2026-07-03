using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class DriversProfilesPage : Page
{
    public DriversProfilesViewModel ViewModel { get; } = new();

    public DriversProfilesPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    private async void OnCheckDriverPathClick(object sender, RoutedEventArgs e)
    {
        await ViewModel.ReloadAsync();
    }

    private async void OnExportProfileClick(object sender, RoutedEventArgs e)
    {
        await ViewModel.ReloadAsync();
    }
}
