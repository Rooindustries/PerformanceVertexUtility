using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class DriversProfilesPage : Page, IRevalidatingPage
{
    public System.Threading.Tasks.Task RevalidateAsync() => ViewModel.RevalidateAsync();
    public DriversProfilesViewModel ViewModel { get; } = new() { Tools = () => new ToolLauncherService(App.Live.RepoRoot ?? throw new InvalidOperationException(AppLog.MissingFiles)) };

    public DriversProfilesPage()
    {
        InitializeComponent();
        NavigationCacheMode = Microsoft.UI.Xaml.Navigation.NavigationCacheMode.Required;
        Loaded += async (_, _) =>
        {
            ResizeContent();
            await ViewModel.InitializeAsync();
            ResizeContent();
        };
        SizeChanged += (_, _) => ResizeContent();
    }

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, DriversContent);
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.ReloadAsync();
}
