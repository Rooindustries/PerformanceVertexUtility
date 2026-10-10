using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class UninstallCleanupPage : Page, IRevalidatingPage
{
    public System.Threading.Tasks.Task RevalidateAsync() => ViewModel.RevalidateAsync();
    private const double CompactThreshold = 1000;
    private bool _layoutApplied;
    private bool _compact;

    public UninstallCleanupViewModel ViewModel { get; } = new();

    public UninstallCleanupPage()
    {
        InitializeComponent();
        NavigationCacheMode = Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += async (_, _) =>
        {
            LeftoversTab.Visibility = App.Theme.SimpleMode ? Visibility.Collapsed : Visibility.Visible;
            if (App.Theme.SimpleMode && ReferenceEquals(CleanupTabs.SelectedItem, LeftoversTab)) CleanupTabs.SelectedIndex = 0;
            ResizeContent();
            await ViewModel.InitializeAsync();
            ResizeContent();
        };
        SizeChanged += (_, _) => ResizeContent();
    }

    public void ShowGroup(string group) { CleanupTabs.SelectedIndex = 0; BulkRemoval.ViewModel.ShowGroup(group); }
    private void ResizeContent() => ResponsiveContentSizer.Apply(this, CleanupContent);

    private void AppsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is InstalledApp app)
        {
            ViewModel.SelectedApp = app;
        }
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
            DetailColumn.Width = new GridLength(1.2, GridUnitType.Star);
            TopRow.Height = new GridLength(1, GridUnitType.Star);
            DetailRow.Height = new GridLength(0);
            Grid.SetRow(DetailPane, 0);
            Grid.SetColumn(DetailPane, 1);
            ListPane.MaxHeight = double.PositiveInfinity;
        }
    }
}
