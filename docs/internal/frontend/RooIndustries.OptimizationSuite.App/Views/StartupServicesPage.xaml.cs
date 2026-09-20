using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class StartupServicesPage : Page
{
    public StartupServicesViewModel ViewModel { get; } = new();

    public StartupServicesPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    private void OpenAutoruns(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (App.MainWindow is MainWindow window) window.FindTool("Autoruns");
    }
}
