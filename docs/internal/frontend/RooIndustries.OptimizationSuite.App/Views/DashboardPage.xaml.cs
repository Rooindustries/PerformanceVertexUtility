using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class DashboardPage : Page, IRevalidatingPage
{
    public System.Threading.Tasks.Task RevalidateAsync() => ViewModel.RevalidateAsync();
    public DashboardViewModel ViewModel { get; } = new();
    private static bool _prefetched;
    public DashboardPage()
    {
        InitializeComponent();
        NavigationCacheMode = Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += async (_, _) =>
        {
            TimerTile.Visibility = App.Theme.SimpleMode ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;
            await ViewModel.InitializeAsync();
            if (!_prefetched)
            {
                _prefetched = true;
                App.Operations.PrefetchWindowsTweaks();
                _ = App.Live.GetInstalledAppsAsync(background: true);
                _ = App.Live.GetProcessClassificationResultAsync(allowStale: true, background: true);
            }
        };
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.ReloadAsync();
    private void OnDashboardActionClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag }) (App.MainWindow as MainWindow)?.SelectNav(tag);
    }
    private void OnProcessesClick(object sender, RoutedEventArgs e)
    {
        (App.MainWindow as MainWindow)?.SelectNav("profiles");
        if (App.MainWindow is MainWindow window) window.ShowProcesses();
    }
}
