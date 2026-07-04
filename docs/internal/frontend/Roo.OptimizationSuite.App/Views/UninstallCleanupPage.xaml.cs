using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class UninstallCleanupPage : Page
{
    public UninstallCleanupViewModel ViewModel { get; } = new();

    public UninstallCleanupPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    private async void OnCapabilitySelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ListView { SelectedItem: CleanupCapabilityItem item })
        {
            await ViewModel.SelectCapabilityAsync(item);
        }
    }
}
