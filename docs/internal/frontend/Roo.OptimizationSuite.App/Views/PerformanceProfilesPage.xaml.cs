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
}
