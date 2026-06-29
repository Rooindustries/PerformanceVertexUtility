using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Roo.OptimizationSuite.Services;
using Roo.OptimizationSuite.Views;
using Windows.UI;

namespace Roo.OptimizationSuite;

public sealed partial class MainWindow : Window
{
    private static readonly Dictionary<string, Type> PageMap = new()
    {
        ["dashboard"] = typeof(DashboardPage),
        ["profiles"] = typeof(PerformanceProfilesPage),
        ["uninstall"] = typeof(UninstallCleanupPage),
        ["drivers"] = typeof(DriversProfilesPage),
        ["monitoring"] = typeof(MonitoringPage),
        ["reports"] = typeof(ReportsPage),
    };

    private string _currentTag = "dashboard";
    private bool _onSettings;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Roo Industries Optimization Suite";
        ConfigureTitleBar();
        LogoImage.Source = BrandAssets.TryGetLogo();
        App.Theme.ThemeChanged += OnThemeChanged;
        App.Theme.EffectsChanged += ApplyEffects;
        ApplyEffects();
        ContentFrame.Navigate(typeof(DashboardPage));
    }

    private void ConfigureTitleBar()
    {
        var titleBar = AppWindow.TitleBar;
        var canvas = Color.FromArgb(255, 0, 0, 64);
        var surface = Color.FromArgb(255, 6, 18, 38);
        var hover = Color.FromArgb(255, 7, 22, 45);
        var text = Color.FromArgb(255, 255, 255, 255);
        var muted = Color.FromArgb(255, 140, 150, 170);

        titleBar.BackgroundColor = canvas;
        titleBar.InactiveBackgroundColor = surface;
        titleBar.ForegroundColor = text;
        titleBar.InactiveForegroundColor = muted;
        titleBar.ButtonBackgroundColor = canvas;
        titleBar.ButtonInactiveBackgroundColor = surface;
        titleBar.ButtonForegroundColor = text;
        titleBar.ButtonInactiveForegroundColor = muted;
        titleBar.ButtonHoverBackgroundColor = hover;
        titleBar.ButtonHoverForegroundColor = text;
        titleBar.ButtonPressedBackgroundColor = surface;
        titleBar.ButtonPressedForegroundColor = text;
    }

    private void ApplyEffects()
    {
        RadialOverlay.Visibility = App.Theme.ReducedEffects ? Visibility.Collapsed : Visibility.Visible;
    }

    public void SelectNav(string tag)
    {
        foreach (var item in Nav.MenuItems)
        {
            if (item is NavigationViewItem { Tag: string itemTag } navItem && itemTag == tag)
            {
                Nav.SelectedItem = navItem;
                return;
            }
        }
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            _onSettings = true;
            ContentFrame.Navigate(typeof(SettingsPage));
            return;
        }

        if (args.SelectedItem is NavigationViewItem { Tag: string tag } && PageMap.TryGetValue(tag, out var pageType))
        {
            _onSettings = false;
            _currentTag = tag;
            ContentFrame.Navigate(pageType);
        }
    }

    private void OnThemeChanged()
    {
        if (Application.Current.Resources.TryGetValue("RooCanvasDeepBrush", out var canvas) && canvas is Brush brush)
        {
            RootGrid.Background = brush;
        }

        if (Application.Current.Resources.TryGetValue("RooAppRadialBrush", out var radial) && radial is Brush radialBrush)
        {
            RadialOverlay.Fill = radialBrush;
        }

        var target = _onSettings ? typeof(SettingsPage)
            : PageMap.TryGetValue(_currentTag, out var pageType) ? pageType : typeof(DashboardPage);
        ContentFrame.Navigate(target);
    }
}
