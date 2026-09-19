using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class MonitoringPage : Page
{
    public MonitoringViewModel ViewModel { get; } = new();

    public MonitoringPage()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            ResizeContent();
            await ViewModel.InitializeAsync();
            ResizeContent();
        };
        SizeChanged += (_, _) => ResizeContent();
    }

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, MonitoringContent);
    private void OpenTimerSettings(object sender, Microsoft.UI.Xaml.RoutedEventArgs args)
    {
        if (App.MainWindow is MainWindow window) window.FindWindowsSetting("timer");
    }
}
