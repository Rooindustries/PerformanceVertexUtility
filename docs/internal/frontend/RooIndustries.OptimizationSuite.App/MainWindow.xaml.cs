using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.Views;
using Windows.UI;

namespace RooIndustries.OptimizationSuite;

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
        ["windows"] = typeof(WindowsTweaksPage),
        ["monitoring"] = typeof(MonitoringPage),
        ["tools"] = typeof(ToolsDiagnosticsPage),
        ["restore"] = typeof(RestoreLogsPage),
        ["bug"] = typeof(BugReportPage),
    };

    private string _currentTag;
    private bool _onSettings;
    private string _pendingTag;
    private bool _pendingSettings;
    private string? _ownershipPath;
    private bool _closeWhenIdle;
    private bool _askingToClose;

    public MainWindow() : this("dashboard", false)
    {
    }

    public MainWindow(string navTag, bool onSettings, string? ownershipPath = null)
    {
        InitializeComponent();
        Title = "Performance Vertex Utility Beta";
        _pendingTag = navTag;
        _pendingSettings = onSettings;
        _currentTag = navTag;
        _ownershipPath = ownershipPath;
        ConfigureTitleBar();
        LogoImage.Source = BrandAssets.TryGetLogo();
        App.Theme.ThemeChanged += OnThemeChanged;
        App.Theme.EffectsChanged += ApplyEffects;
        App.Theme.SimpleModeChanged += ApplySimpleMode;
        DataGeneration.Settled += OnDataSettled;
        App.Updates.Changed += OnUpdateChanged;
        Closed += OnWindowClosed;
        AppWindow.Closing += OnClosing;
        RunningChanges.Finished += OnChangesFinished;
        MemoryRelief.Attach(this);
        ContentFrame.Navigated += (_, _) => MemoryRelief.PageShown();
        MemoryRelief.PageShown();
        EarlierVersionConsent.Ask = AskEarlierVersionAsync;
        ApplyEffects();
        ApplySimpleMode();
        Nav.Loaded += OnNavLoaded;
        OnUpdateChanged();
    }

    private void OnUpdateChanged()
    {
        var state = App.Updates.State;
        UpdateBanner.Title = state.Banner;
        UpdateBanner.Message = state.BannerMessage;
        UpdateBanner.IsOpen = App.Updates.ShowBanner;
        UpdateBanner.Severity = state.Refused || state.BannerKind == "failed" ? InfoBarSeverity.Warning : state.BannerKind == "updated" ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        UpdateBannerInstall.Content = state.BannerKind == "failed" ? "Try again" : "Install now";
        UpdateBannerInstall.Visibility = state.Ready ? Visibility.Visible : Visibility.Collapsed;
        UpdateBannerInstall.IsEnabled = state.CanInstall;
        ContentFrame.IsEnabled = !state.Installing;
    }

    private async void UpdateInstall_Click(object sender, RoutedEventArgs args) => await App.Updates.InstallAsync(Content.XamlRoot);
    private void UpdateLater_Click(object sender, RoutedEventArgs args) => App.Updates.Later();

    private async void OnClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (!RunningChanges.Any || !ReferenceEquals(App.MainWindow, this)) return;
        args.Cancel = true;
        if (_askingToClose) return;
        _askingToClose = true;
        try
        {
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "A change is still running",
                Content = "Closing now could cut it off. Keep the app open until it finishes, or have it close by itself once it's done.",
                PrimaryButtonText = "Close when done", CloseButtonText = "Keep open", DefaultButton = ContentDialogButton.Close };
            _closeWhenIdle = await dialog.ShowAsync() == ContentDialogResult.Primary;
            if (_closeWhenIdle && !RunningChanges.Any) Close();
        }
        catch (Exception error) { AppLog.Write("close", "The running change question could not be shown: " + error.Message); }
        finally { _askingToClose = false; }
    }

    private void OnChangesFinished() => DispatcherQueue.TryEnqueue(() => { if (_closeWhenIdle && !RunningChanges.Any) Close(); });

    private Task<bool> AskEarlierVersionAsync(string text)
    {
        var answer = new TaskCompletionSource<bool>();
        if (!DispatcherQueue.TryEnqueue(async () =>
        {
            try
            {
                var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Saved by an older version", Content = text, PrimaryButtonText = "Continue", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
                answer.TrySetResult(await dialog.ShowAsync() == ContentDialogResult.Primary);
            }
            catch (Exception error) { AppLog.Write("start", "The older version question could not be shown: " + error.Message); answer.TrySetResult(false); }
        })) answer.TrySetResult(false);
        return answer.Task;
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        if (EarlierVersionConsent.Ask?.Target == (object)this) EarlierVersionConsent.Ask = null;
        MemoryRelief.Detach(this);
        App.Theme.ThemeChanged -= OnThemeChanged;
        App.Theme.EffectsChanged -= ApplyEffects;
        App.Theme.SimpleModeChanged -= ApplySimpleMode;
        DataGeneration.Settled -= OnDataSettled;
        App.Updates.Changed -= OnUpdateChanged;
        AppWindow.Closing -= OnClosing;
        RunningChanges.Finished -= OnChangesFinished;
        if (!ReferenceEquals(App.MainWindow, this)) return;
        App.Updates.Stop();
        App.Closing.Cancel();
    }

    private void OnDataSettled() => DispatcherQueue.TryEnqueue(async () =>
    {
        try { if (ContentFrame.Content is IRevalidatingPage page) await page.RevalidateAsync(); }
        catch (Exception error) { AppLog.Write("refresh", error.ToString()); }
    });

    private void ConfigureTitleBar()
    {
        var titleBar = AppWindow.TitleBar;
        var canvas = ThemeColor("RooIndustriesCanvasDeepBrush", Color.FromArgb(255, 7, 7, 7));
        var surface = ThemeColor("RooIndustriesSurfaceElevatedBrush", Color.FromArgb(255, 9, 9, 9));
        var hover = ThemeColor("RooIndustriesSurfaceBrush", Color.FromArgb(255, 13, 13, 13));
        var text = ThemeColor("RooIndustriesTextPrimaryBrush", Color.FromArgb(255, 255, 255, 255));
        var muted = ThemeColor("RooIndustriesTextMutedBrush", Color.FromArgb(255, 143, 143, 134));

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

    private void ApplySimpleMode()
    {
        var advanced = App.Theme.SimpleMode ? Visibility.Collapsed : Visibility.Visible;
        foreach (var item in new[] { NavStartup, NavTimer }) item.Visibility = advanced;
    }

    private void ApplyEffects()
    {
        RadialOverlay.Visibility = App.Theme.ReducedEffects ? Visibility.Collapsed : Visibility.Visible;
    }

    public void SelectNav(string tag)
    {
        foreach (var item in Nav.MenuItems.Concat(Nav.FooterMenuItems))
        {
            if (item is NavigationViewItem { Tag: string itemTag } navItem && itemTag == tag)
            {
                Nav.SelectedItem = navItem;
                return;
            }
        }
    }

    public void OpenOwnershipReview(string path)
    {
        if (!Nav.IsLoaded) { _pendingTag = "windows"; _pendingSettings = false; _ownershipPath = path; return; }
        SelectNav("windows");
        if (ContentFrame.Content is WindowsTweaksPage page) _ = page.ShowOwnershipAsync(path, confirm: true);
    }

    public void OpenAppGroup(string group)
    {
        SelectNav("uninstall");
        if (ContentFrame.Content is UninstallCleanupPage page) page.ShowGroup(group);
    }
    public void FindTool(string query)
    {
        SelectNav("tools");
        if (ContentFrame.Content is ToolsDiagnosticsPage page) page.ViewModel.Search = query;
    }
    public void FindWindowsSetting(string query)
    {
        SelectNav("windows");
        if (ContentFrame.Content is WindowsTweaksPage page) page.ViewModel.FindSetting(query);
    }
    public void ShowProcesses()
    {
        if (ContentFrame.Content is PerformanceProfilesPage page) page.ShowProcesses();
    }

    private void ApplyNavFocusBrushes()
    {
        if (!(Application.Current.Resources.TryGetValue("RooIndustriesFocusVisualBrush", out var value) && value is Brush primary))
        {
            return;
        }

        var secondary = new SolidColorBrush(Microsoft.UI.Colors.Transparent);

        foreach (var item in Nav.MenuItems.Concat(Nav.FooterMenuItems))
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
        if (Nav.SettingsItem is NavigationViewItem settingsItem)
            settingsItem.Icon = new ImageIcon { Source = new Microsoft.UI.Xaml.Media.Imaging.SvgImageSource(new Uri("ms-appx:///Assets/Icons/settings.svg")) };

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
        if (_ownershipPath is not null && ContentFrame.Content is WindowsTweaksPage ownershipPage) _ = ownershipPage.ShowOwnershipAsync(_ownershipPath);
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

    private void Nav_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (!args.IsSettingsInvoked && !_onSettings && args.InvokedItemContainer is NavigationViewItem { Tag: string tag } && tag == _currentTag
            && PageMap.TryGetValue(tag, out var pageType) && ContentFrame.Content?.GetType() != pageType)
            ContentFrame.Navigate(pageType);
    }

    private void OnThemeChanged()
    {
        App.ApplyAccentResourceOverrides();
        var tag = _currentTag;
        var settings = _onSettings;
        DispatcherQueue.TryEnqueue(() => App.RecreateMainWindow(tag, settings));
    }
}
