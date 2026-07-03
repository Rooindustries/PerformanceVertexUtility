using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class ReportsPage : Page
{
    public ReportsViewModel ViewModel { get; } = new();

    public ReportsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    private void OnNextActionClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (sender is Button { Tag: string route } && !string.IsNullOrWhiteSpace(route))
        {
            (App.MainWindow as MainWindow)?.SelectNav(route);
        }
    }
}
