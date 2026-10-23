using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.AppLifecycle;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    private static readonly BackendLocator Locator = new();
    private static readonly bool DataReady = DataFolderGate.Open(Locator);
    public static string? CatalogsDirectory => Locator.CatalogsDirectory;

    public static SampleDataService Data { get; } = new SampleDataService(Locator);
    public static LiveDataService Live { get; } = new LiveDataService(Locator);
    public static OptimizerService Operations { get; } = new(Locator);
    public static ThemeService Theme { get; } = new ThemeService(new SettingsStore());
    public static UpdateService Updates { get; } = new();
    public static System.Threading.CancellationTokenSource Closing { get; } = new();
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
        if (!DataReady) return;
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

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        AppInstance? primary = null;
        try { primary = AppInstance.FindOrRegisterForKey("RooIndustries.OptimizationSuite.Main"); }
        catch (Exception error) { AppLog.Write("start", "Single-window check unavailable: " + error.Message); }
        if (primary is { IsCurrent: false })
        {
            if (await HandOverAsync(primary)) { await System.Threading.Tasks.Task.Delay(500); Exit(); return; }
            AppLog.Write("start", "The open window did not take this launch; opening another window.");
        }
        else if (primary is not null) primary.Activated += OnRedirected;
#if ROO_INDUSTRIES_TEST_HOOKS
        AppLog.Write("test", "test hooks enabled");
#endif
        Theme.ApplyPersistedTheme();
        ApplyAccentResourceOverrides();

        var initialNav = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_INITIAL_NAV");
        var commandLine = System.Environment.GetCommandLineArgs();
        var ownershipPath = commandLine.Length == 3 && commandLine[1] == "--ownership-review" ? ExternalOwnershipPath(commandLine[2]) : null;
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
        string?[] waiting;
        lock (RedirectGate) { _windowReady = true; waiting = PendingRedirects.ToArray(); PendingRedirects.Clear(); }
        foreach (var path in waiting) ShowRedirect(path);
        Updates.Start(MainWindow.DispatcherQueue);
        Operations.WatchGameSessions(Closing.Token);
    }

    private static readonly object RedirectGate = new();
    private static readonly System.Collections.Generic.List<string?> PendingRedirects = new();
    private static bool _windowReady;

    private static async System.Threading.Tasks.Task<bool> HandOverAsync(AppInstance primary)
    {
        try
        {
            AllowSetForegroundWindow(primary.ProcessId);
            var redirect = primary.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()).AsTask();
            if (await System.Threading.Tasks.Task.WhenAny(redirect, System.Threading.Tasks.Task.Delay(TimeSpan.FromSeconds(10))) != redirect) return false;
            await redirect;
            return true;
        }
        catch (Exception error)
        {
            AppLog.Write("start", "Could not hand this launch to the open window: " + error.Message);
            return false;
        }
    }

    private static void OnRedirected(object? sender, AppActivationArguments activation)
    {
        string? ownershipPath = null;
        try
        {
            var arguments = Split((activation.Data as Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs)?.Arguments ?? "");
            var marker = Array.IndexOf(arguments, "--ownership-review");
            ownershipPath = marker >= 0 && marker + 1 < arguments.Length ? ExternalOwnershipPath(arguments[marker + 1]) : null;
        }
        catch (Exception error) { AppLog.Write("start", "Could not read the second launch's arguments: " + error.Message); }
        lock (RedirectGate)
        {
            if (!_windowReady) { PendingRedirects.Add(ownershipPath); return; }
        }
        ShowRedirect(ownershipPath);
    }

    private static void ShowRedirect(string? ownershipPath) => MainWindow?.DispatcherQueue.TryEnqueue(() =>
    {
        try
        {
            if (MainWindow is not { } window) return;
            if (window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized } presenter) presenter.Restore();
            window.Activate();
            SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(window));
            if (!string.IsNullOrWhiteSpace(ownershipPath) && window is RooIndustries.OptimizationSuite.MainWindow main) main.OpenOwnershipReview(ownershipPath);
        }
        catch (Exception error) { AppLog.Write("start", "Could not bring the open window forward: " + error.Message); }
    });

    private static string? ExternalOwnershipPath(string path)
    {
        var problem = RooIndustries.Optimizer.OperationFiles.ExternalPathProblem(path);
        if (problem is null) return path;
        AppLog.Write("start", "Ignored a file ownership review request: " + problem + ".");
        return null;
    }

    private static string[] Split(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine)) return [];
        var pointer = CommandLineToArgvW(commandLine, out var count);
        if (pointer == IntPtr.Zero) return [];
        try
        {
            var result = new string[count];
            for (var index = 0; index < count; index++) result[index] = System.Runtime.InteropServices.Marshal.PtrToStringUni(System.Runtime.InteropServices.Marshal.ReadIntPtr(pointer, index * IntPtr.Size)) ?? "";
            return result;
        }
        finally { LocalFree(pointer); }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(uint processId);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);

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
