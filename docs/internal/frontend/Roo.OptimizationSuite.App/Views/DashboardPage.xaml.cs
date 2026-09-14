using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class DashboardPage : Page
{
    public DashboardViewModel ViewModel { get; } = new();

    public DashboardPage()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            ResizeContent();
            await ViewModel.InitializeAsync();
            ResizeContent();
            DispatcherQueue.TryEnqueue(ResizeContent);
        };
        SizeChanged += (_, _) => ResizeContent();
    }

    private void OnReviewProcessPlanClick(object sender, RoutedEventArgs e)
    {
        (App.MainWindow as MainWindow)?.SelectNav("profiles");
    }

    private void OnDashboardActionClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag })
        {
            (App.MainWindow as MainWindow)?.SelectNav(tag);
        }
    }

    private void ResizeContent()
    {
        ResponsiveContentSizer.Apply(this, DashContent);
        TuneActionHost.Width = double.NaN;
        CleanupActionHost.Width = double.NaN;
        DriverActionHost.Width = double.NaN;
    }
}
