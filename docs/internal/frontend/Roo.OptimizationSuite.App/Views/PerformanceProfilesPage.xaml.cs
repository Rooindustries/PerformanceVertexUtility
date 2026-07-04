using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class PerformanceProfilesPage : Page
{
    public PerformanceProfilesViewModel ViewModel { get; } = new();

    public PerformanceProfilesPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    private async void OnCapabilitySelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ListView { SelectedItem: ProcessCapabilityItem item })
        {
            await ViewModel.SelectCapabilityAsync(item);
        }
    }
}
