using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

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
}
