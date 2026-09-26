using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    private static readonly BackendLocator Locator = new();
    public static string? CatalogsDirectory => Locator.CatalogsDirectory;

    public static SampleDataService Data { get; } = new SampleDataService(Locator);
    public static LiveDataService Live { get; } = new LiveDataService(Locator);
    public static CapabilityService Capabilities { get; } = new CapabilityService(Locator);
    public static OptimizerService Operations { get; } = new(Locator);
    public static ThemeService Theme { get; } = new ThemeService(new SettingsStore());
    public static BugReportService BugReports { get; } = new(BugReportService.ReadWebhook(typeof(App).Assembly), new DiscordWebhookSender(),
        System.IO.Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "bug-reports"), AppLog.Folder, BugRedactor.Current());

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
        foreach (var name in new[] { "ROO_INDUSTRIES_BACKEND_ROOT", "ROO_INDUSTRIES_DOTNET_EXE", "ROO_INDUSTRIES_PYTHON_EXE", "ROO_INDUSTRIES_UTILITIES_ROOT", "ROO_INDUSTRIES_INITIAL_NAV" })
            _ = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue(name);
        InitializeComponent();
        UnhandledException += OnUnhandledException;
        System.AppDomain.CurrentDomain.UnhandledException += (_, e) => AppLog.Write("crash", e.ExceptionObject?.ToString());
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, e) => AppLog.Write("background", e.Exception.ToString());
        AppLog.Write("start", "Version " + VersionText + " on " + System.Environment.OSVersion.VersionString
            + (IsAdministrator() ? " as administrator" : " without administrator rights"));
    }

    public static string VersionText => (typeof(App).Assembly.GetName().Version?.ToString(3) ?? "0.1.0") + " beta";

    public static bool IsAdministrator()
    {
        try
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            return new System.Security.Principal.WindowsPrincipal(identity).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
        => AppLog.Write("crash", e.Message + System.Environment.NewLine + e.Exception);

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Theme.ApplyPersistedTheme();
        ApplyAccentResourceOverrides();

        var initialNav = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_INITIAL_NAV");
        var commandLine = System.Environment.GetCommandLineArgs();
        var ownershipPath = commandLine.Length == 3 && commandLine[1] == "--ownership-review" ? commandLine[2] : null;
        MainWindow = ownershipPath is not null ? new MainWindow("windows", false, ownershipPath) : string.IsNullOrWhiteSpace(initialNav)
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
        if (!(resources.TryGetValue("RooIndustriesAccentBrush", out var accentValue) && accentValue is Brush accent))
        {
            return;
        }

        foreach (var key in AccentKeys)
        {
            resources[key] = accent;
        }

        var paneBackground = ResolveBrush("RooIndustriesGlassMenuBrush", accent);
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

        var border = ResolveBrush("RooIndustriesControlBorderBrush", accent);
        var focus = ResolveBrush("RooIndustriesFocusVisualBrush", accent);
        var muted = ResolveBrush("RooIndustriesTextMutedBrush", border);
        var onAccent = ResolveBrush("RooIndustriesOnAccentBrush", accent);
        var elevated = ResolveBrush("RooIndustriesSurfaceElevatedBrush", border);
        var input = ResolveBrush("RooIndustriesSurfaceInputBrush", border);
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
