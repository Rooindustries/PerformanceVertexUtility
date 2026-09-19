using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class MemoryLatencyPage : Page
{
    public MemoryLatencyViewModel ViewModel { get; } = new();

    public MemoryLatencyPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    private void OpenTools(object sender, RoutedEventArgs e)
    {
        (App.MainWindow as MainWindow)?.SelectNav("tools");
    }
}
