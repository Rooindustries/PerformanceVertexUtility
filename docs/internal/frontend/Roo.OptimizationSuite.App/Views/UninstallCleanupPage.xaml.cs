using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class UninstallCleanupPage : Page
{
    private const double CompactThreshold = 460;
    private bool _layoutApplied;
    private bool _compact;

    public UninstallCleanupViewModel ViewModel { get; } = new();

    public UninstallCleanupPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }

    private void MasterDetail_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Width > 0 && e.NewSize.Width < CompactThreshold;
        if (_layoutApplied && compact == _compact)
        {
            return;
        }

        _layoutApplied = true;
        _compact = compact;

        if (compact)
        {
            ListColumn.Width = new GridLength(1, GridUnitType.Star);
            DetailColumn.Width = new GridLength(0);
            TopRow.Height = GridLength.Auto;
            DetailRow.Height = new GridLength(1, GridUnitType.Star);
            Grid.SetRow(DetailPane, 1);
            Grid.SetColumn(DetailPane, 0);
            ListPane.MaxHeight = 220;
        }
        else
        {
            ListColumn.Width = new GridLength(1.1, GridUnitType.Star);
            DetailColumn.Width = new GridLength(1.8, GridUnitType.Star);
            TopRow.Height = new GridLength(1, GridUnitType.Star);
            DetailRow.Height = new GridLength(0);
            Grid.SetRow(DetailPane, 0);
            Grid.SetColumn(DetailPane, 1);
            ListPane.MaxHeight = double.PositiveInfinity;
        }
    }
}
