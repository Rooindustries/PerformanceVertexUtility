using System;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class SettingsPage : Page
{
    private bool _refreshingUpdates;
    public SettingsViewModel ViewModel { get; } = new();

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            App.Updates.Changed += RefreshUpdates;
            RefreshUpdates();
            ResizeContent();
            await ViewModel.InitializeAsync();
            ResizeContent();
        };
        SizeChanged += (_, _) => ResizeContent();
        Unloaded += (_, _) => App.Updates.Changed -= RefreshUpdates;
    }

    private void RefreshUpdates()
    {
        _refreshingUpdates = true;
        try
        {
            var state = App.Updates.State;
            UpdateStatusText.Text = state.Status;
            UpdateNotesText.Text = state.Notes;
            AutomaticUpdatesToggle.IsOn = App.Updates.AutomaticDownloads;
            AutomaticUpdatesToggle.IsEnabled = App.Updates.Enabled;
            UpdateCheckButton.IsEnabled = App.Updates.Enabled && !state.Busy;
            UpdateDownloadButton.Visibility = state.CanDownload ? Visibility.Visible : Visibility.Collapsed;
            UpdateDownloadButton.IsEnabled = !state.Busy;
            UpdateInstallButton.Visibility = state.Ready ? Visibility.Visible : Visibility.Collapsed;
            UpdateInstallButton.Content = state.BannerKind == "failed" ? "Try again" : "Install update";
            UpdateInstallButton.IsEnabled = state.CanInstall;
        }
        finally { _refreshingUpdates = false; }
    }

    private void AutomaticUpdates_Toggled(object sender, RoutedEventArgs args)
    {
        if (!_refreshingUpdates) App.Updates.AutomaticDownloads = AutomaticUpdatesToggle.IsOn;
    }
    private async void UpdateCheck_Click(object sender, RoutedEventArgs args) => await App.Updates.CheckAsync();
    private async void UpdateDownload_Click(object sender, RoutedEventArgs args) => await App.Updates.DownloadAsync();
    private async void UpdateInstall_Click(object sender, RoutedEventArgs args) => await App.Updates.InstallAsync(XamlRoot);

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, SettingsContent, 1100);

    private void OpenLogs_Click(object sender, RoutedEventArgs e) => Open(ViewModel.LogFolder, folder: true);

    private static void Open(string target, bool folder = false)
    {
        try
        {
            if (folder) Directory.CreateDirectory(target);
            RooIndustries.Optimizer.RuntimeEnvironment.OpenInExplorer(target);
        }
        catch (Exception error)
        {
            AppLog.Write("settings", error.ToString());
        }
    }
}
