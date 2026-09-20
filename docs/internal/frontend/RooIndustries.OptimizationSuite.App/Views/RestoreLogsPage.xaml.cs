using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class RestoreLogsPage : Page
{
    public RestoreLogsViewModel ViewModel { get; } = new();

    public RestoreLogsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    private void OpenWindowsSettings(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (App.MainWindow is MainWindow window) window.SelectNav("windows");
    }
    private void OpenProcessControl(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (App.MainWindow is MainWindow window) window.SelectNav("profiles");
    }
    private void OpenBiosBackups(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var frame = Frame;
        if (App.MainWindow is MainWindow window) window.SelectNav("tools");
        frame.Navigate(typeof(FirmwarePage));
    }
}
