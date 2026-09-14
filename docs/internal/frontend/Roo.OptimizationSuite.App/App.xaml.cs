using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Roo.OptimizationSuite.Services;

namespace Roo.OptimizationSuite;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    private static readonly BackendLocator Locator = new();

    public static SampleDataService Data { get; } = new SampleDataService(Locator);
    public static LiveDataService Live { get; } = new LiveDataService(Locator);
    public static CapabilityService Capabilities { get; } = new CapabilityService(Locator);
    public static ThemeService Theme { get; } = new ThemeService(new SettingsStore());

    private static readonly string[] AccentKeys =
    {
        "NavigationViewSelectionIndicatorForeground",
        "ToggleSwitchFillOn",
        "ToggleSwitchFillOnPointerOver",
        "ToggleSwitchFillOnPressed",
        "ToggleSwitchStrokeOn",
        "ProgressBarForeground",
        "ProgressRingForeground",
        "AccentButtonBackground",
        "AccentButtonBackgroundPointerOver",
        "AccentButtonBackgroundPressed",
    };

    private static readonly string[] BlackoutControlKeys =
    {
        "TextControlBorderBrush",
        "TextControlBorderBrushPointerOver",
        "TextControlBorderBrushFocused",
        "TextControlButtonBorderBrush",
        "ComboBoxBorderBrush",
        "ComboBoxBorderBrushPointerOver",
        "ComboBoxBorderBrushPressed",
        "ComboBoxBorderBrushDisabled",
        "ComboBoxBorderBrushFocused",
        "ComboBoxDropDownBorderBrush",
        "ComboBoxDropDownBackground",
        "ButtonBorderBrush",
        "ButtonBorderBrushPointerOver",
        "ButtonBorderBrushPressed",
        "ButtonBorderBrushDisabled",
        "ToggleSwitchStrokeOff",
        "ToggleSwitchStrokeOffPointerOver",
        "ToggleSwitchStrokeOffPressed",
        "ToggleSwitchKnobFillOff",
        "ToggleSwitchKnobFillOffPointerOver",
        "ToggleSwitchKnobFillOffPressed",
        "ToggleSwitchKnobFillOn",
        "ToggleSwitchKnobFillOnPointerOver",
        "ToggleSwitchKnobFillOnPressed",
        "ProgressBarBackground",
        "ProgressBarBorderBrush",
        "FocusVisualPrimaryBrush",
        "FocusVisualSecondaryBrush",
    };

    public App()
    {
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        try
        {
            var dir = System.IO.Path.Combine(
                System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData),
                "RooOptimizationSuite");
            System.IO.Directory.CreateDirectory(dir);
            System.IO.File.WriteAllText(System.IO.Path.Combine(dir, "last-crash.log"),
                e.Message + System.Environment.NewLine + e.Exception);
        }
        catch
        {
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Theme.ApplyPersistedTheme();
        ApplyAccentResourceOverrides();

        var initialNav = System.Environment.GetEnvironmentVariable("ROO_INITIAL_NAV");
        MainWindow = string.IsNullOrWhiteSpace(initialNav)
            ? new MainWindow()
            : new MainWindow(initialNav.Trim(), false);
        MainWindow.Activate();
        if (MainWindow.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            try
            {
                presenter.Maximize();
            }
            catch
            {
            }
        }
    }

    public static void RecreateMainWindow(string navTag, bool onSettings)
    {
        var previous = MainWindow;

        var wasMaximized = false;
        var wasMinimized = false;
        if (previous?.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter previousPresenter)
        {
            wasMaximized = previousPresenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Maximized;
            wasMinimized = previousPresenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized;
        }

        var next = new MainWindow(navTag, onSettings);
        MainWindow = next;

        if (previous is not null && !wasMaximized && !wasMinimized)
        {
            try
            {
                var pos = previous.AppWindow.Position;
                var size = previous.AppWindow.Size;
                next.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(pos.X, pos.Y, size.Width, size.Height));
            }
            catch
            {
            }
        }

        next.Activate();

        if (wasMaximized && next.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter nextPresenter)
        {
            try
            {
                nextPresenter.Maximize();
            }
            catch
            {
            }
        }

        previous?.Close();
    }

    public static void ApplyAccentResourceOverrides()
    {
        var resources = Current.Resources;
        if (!(resources.TryGetValue("RooAccentBrush", out var accentValue) && accentValue is Brush accent))
        {
            return;
        }

        foreach (var key in AccentKeys)
        {
            resources[key] = accent;
        }

        var paneBackground = ResolveBrush("RooGlassMenuBrush", accent);
        resources["NavigationViewDefaultPaneBackground"] = paneBackground;
        resources["NavigationViewExpandedPaneBackground"] = paneBackground;

        if (Theme.CurrentThemeId != ThemeService.BlackoutGold.Id)
        {
            foreach (var key in BlackoutControlKeys)
            {
                resources.Remove(key);
            }

            return;
        }

        var border = ResolveBrush("RooControlBorderBrush", accent);
        var focus = ResolveBrush("RooFocusVisualBrush", accent);
        var muted = ResolveBrush("RooTextMutedBrush", border);
        var onAccent = ResolveBrush("RooOnAccentBrush", accent);
        var elevated = ResolveBrush("RooSurfaceElevatedBrush", border);
        var input = ResolveBrush("RooSurfaceInputBrush", border);
        var transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);

        string[] borderKeys =
        {
            "TextControlBorderBrush",
            "TextControlBorderBrushPointerOver",
            "ComboBoxBorderBrush",
            "ComboBoxBorderBrushPointerOver",
            "ComboBoxBorderBrushPressed",
            "ComboBoxBorderBrushDisabled",
            "ComboBoxDropDownBorderBrush",
            "ButtonBorderBrush",
            "ButtonBorderBrushPointerOver",
            "ButtonBorderBrushPressed",
            "ButtonBorderBrushDisabled",
            "TextControlButtonBorderBrush",
            "ToggleSwitchStrokeOff",
            "ToggleSwitchStrokeOffPointerOver",
            "ToggleSwitchStrokeOffPressed",
        };
        foreach (var key in borderKeys)
        {
            resources[key] = border;
        }

        string[] mutedKnobKeys =
        {
            "ToggleSwitchKnobFillOff",
            "ToggleSwitchKnobFillOffPointerOver",
            "ToggleSwitchKnobFillOffPressed",
        };
        foreach (var key in mutedKnobKeys)
        {
            resources[key] = muted;
        }

        string[] onKnobKeys =
        {
            "ToggleSwitchKnobFillOn",
            "ToggleSwitchKnobFillOnPointerOver",
            "ToggleSwitchKnobFillOnPressed",
        };
        foreach (var key in onKnobKeys)
        {
            resources[key] = onAccent;
        }

        resources["TextControlBorderBrushFocused"] = accent;
        resources["ComboBoxBorderBrushFocused"] = accent;
        resources["ComboBoxDropDownBackground"] = elevated;
        resources["ProgressBarBackground"] = input;
        resources["ProgressBarBorderBrush"] = border;
        resources["FocusVisualPrimaryBrush"] = focus;
        resources["FocusVisualSecondaryBrush"] = transparent;
    }

    private static Brush ResolveBrush(string key, Brush fallback)
        => Current.Resources.TryGetValue(key, out var value) && value is Brush brush ? brush : fallback;
}
