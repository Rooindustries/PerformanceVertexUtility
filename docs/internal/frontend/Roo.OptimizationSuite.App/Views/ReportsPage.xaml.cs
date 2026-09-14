using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class ReportsPage : Page
{
    public ReportsViewModel ViewModel { get; } = new();

    public ReportsPage()
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

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, ReportsContent);

    private void OpenGameTune_Click(object sender, RoutedEventArgs e)
    {
        (App.MainWindow as MainWindow)?.SelectNav("profiles");
    }

    private void OpenCleanup_Click(object sender, RoutedEventArgs e)
    {
        (App.MainWindow as MainWindow)?.SelectNav("cleanup");
    }
}
