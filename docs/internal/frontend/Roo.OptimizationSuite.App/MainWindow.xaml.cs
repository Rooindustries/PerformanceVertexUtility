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
        ["startup"] = typeof(StartupServicesPage),
        ["drivers"] = typeof(DriversProfilesPage),
        ["memory"] = typeof(MemoryLatencyPage),
        ["monitoring"] = typeof(MonitoringPage),
        ["tools"] = typeof(ToolsDiagnosticsPage),
        ["restore"] = typeof(RestoreLogsPage),
    };

    private string _currentTag;
    private bool _onSettings;
    private readonly string _pendingTag;
    private readonly bool _pendingSettings;

    public MainWindow() : this("dashboard", false)
    {
    }

    public MainWindow(string navTag, bool onSettings)
    {
        InitializeComponent();
        Title = "Roo Industries Optimization Suite";
        _pendingTag = navTag;
        _pendingSettings = onSettings;
        _currentTag = navTag;
        ConfigureTitleBar();
        LogoImage.Source = BrandAssets.TryGetLogo();
        App.Theme.ThemeChanged += OnThemeChanged;
        App.Theme.EffectsChanged += ApplyEffects;
        Closed += OnWindowClosed;
        ApplyEffects();
        Nav.Loaded += OnNavLoaded;
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        App.Theme.ThemeChanged -= OnThemeChanged;
        App.Theme.EffectsChanged -= ApplyEffects;
    }

    private void ConfigureTitleBar()
    {
        var titleBar = AppWindow.TitleBar;
        var canvas = ThemeColor("RooCanvasDeepBrush", Color.FromArgb(255, 7, 7, 7));
        var surface = ThemeColor("RooSurfaceElevatedBrush", Color.FromArgb(255, 9, 9, 9));
        var hover = ThemeColor("RooSurfaceBrush", Color.FromArgb(255, 13, 13, 13));
        var text = ThemeColor("RooTextPrimaryBrush", Color.FromArgb(255, 255, 255, 255));
        var muted = ThemeColor("RooTextMutedBrush", Color.FromArgb(255, 143, 143, 134));

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

    private static Color ThemeColor(string key, Color fallback)
    {
        if (Application.Current.Resources.TryGetValue(key, out var value))
        {
            if (value is SolidColorBrush solid)
            {
                return solid.Color;
            }

            if (value is LinearGradientBrush gradient && gradient.GradientStops.Count > 0)
            {
                return gradient.GradientStops[gradient.GradientStops.Count - 1].Color;
            }
        }

        return fallback;
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

    private void ApplyNavFocusBrushes()
    {
        if (!(Application.Current.Resources.TryGetValue("RooFocusVisualBrush", out var value) && value is Brush primary))
        {
            return;
        }

        var secondary = new SolidColorBrush(Microsoft.UI.Colors.Transparent);

        foreach (var item in Nav.MenuItems)
        {
            if (item is NavigationViewItem navItem)
            {
                navItem.FocusVisualPrimaryBrush = primary;
                navItem.FocusVisualSecondaryBrush = secondary;
            }
        }

        if (Nav.SettingsItem is NavigationViewItem settingsItem)
        {
            settingsItem.FocusVisualPrimaryBrush = primary;
            settingsItem.FocusVisualSecondaryBrush = secondary;
        }
    }

    private void OnNavLoaded(object sender, RoutedEventArgs e)
    {
        ApplyNavFocusBrushes();

        if (_pendingSettings)
        {
            _onSettings = true;
            Nav.SelectedItem = Nav.SettingsItem;
            if (ContentFrame.Content is not SettingsPage)
            {
                ContentFrame.Navigate(typeof(SettingsPage));
            }

            return;
        }

        _onSettings = false;
        _currentTag = _pendingTag;
        SelectNav(_pendingTag);
        if (PageMap.TryGetValue(_pendingTag, out var pageType) &&
            (ContentFrame.Content is null || ContentFrame.Content.GetType() != pageType))
        {
            ContentFrame.Navigate(pageType);
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
        App.ApplyAccentResourceOverrides();
        var tag = _currentTag;
        var settings = _onSettings;
        DispatcherQueue.TryEnqueue(() => App.RecreateMainWindow(tag, settings));
    }
}
