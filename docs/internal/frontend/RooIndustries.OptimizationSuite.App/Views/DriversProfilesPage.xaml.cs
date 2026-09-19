using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class DriversProfilesPage : Page
{
    public DriversProfilesViewModel ViewModel { get; } = new();

    public DriversProfilesPage()
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

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, DriversContent);
}
