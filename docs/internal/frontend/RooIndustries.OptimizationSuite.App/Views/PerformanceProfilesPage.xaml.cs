using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class PerformanceProfilesPage : Page
{
    public PerformanceProfilesViewModel ViewModel { get; } = new();

    public PerformanceProfilesPage()
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

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, ProcessContent);
}
