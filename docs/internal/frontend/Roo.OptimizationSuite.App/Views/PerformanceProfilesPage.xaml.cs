using Microsoft.UI.Xaml;
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

    private void OnScrollerSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Constrain the scrolling content to the viewport width so proportional
        // (star) columns resolve against a bounded width instead of collapsing.
        var width = PcScroller.ViewportWidth;
        if (width <= 0)
        {
            width = e.NewSize.Width - 16;
        }

        if (width > 0)
        {
            PcContent.Width = width;
        }
    }
}
