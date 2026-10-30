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
        var commandLine = System.Environment.GetCommandLineArgs();
        var savedSettings = commandLine.Length == 2 && commandLine[1] == OptimizerService.SavedSettingsArgument;
        AppInstance? primary = null;
        try { primary = AppInstance.FindOrRegisterForKey("RooIndustries.OptimizationSuite.Main"); }
        catch (Exception error) { AppLog.Write("start", "Single-window check unavailable: " + error.Message); }
        if (primary is { IsCurrent: false })
        {
            // An open copy with administrator rights already turns saved launch settings on, so a sign-in start has nothing to add.
            // One without them can't, so the sign-in start keeps going and takes the single-window key once that copy closes.
            if (savedSettings && ElevatedProcess(primary.ProcessId)) { Exit(); return; }
            if (!savedSettings)
            {
                if (await HandOverAsync(primary)) { await System.Threading.Tasks.Task.Delay(500); Exit(); return; }
                AppLog.Write("start", "The open window did not take this launch; opening another window.");
            }
        }
        else if (primary is not null) primary.Activated += OnRedirected;
#if ROO_INDUSTRIES_TEST_HOOKS
        AppLog.Write("test", "test hooks enabled");
        if (RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_TEST_HOLD_CHANGE") is { Length: > 0 } hold) _ = HoldChangeAsync(hold);
#endif
        // Closing the window doesn't end the app while saved launch settings are on (WindowClosed decides).
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        Theme.ApplyPersistedTheme();
        ApplyAccentResourceOverrides();

        if (savedSettings)
        {
            AppLog.Write("start", "Started at sign-in for saved launch settings, without a window.");
            if (!IsAdministrator()) { Exit(); return; }
            if (primary is { IsCurrent: false }) TakeKeyWhenFree();
            if (!Operations.HasSavedLaunchSettings())
            {
                await KeepSignInStartAsync();
                Exit();
                return;
            }
        }
        else
        {
            var initialNav = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_INITIAL_NAV");
            var ownershipPath = commandLine.Length == 3 && commandLine[1] == "--ownership-review" ? ExternalOwnershipPath(commandLine[2]) : null;
            OpenWindow(ownershipPath is not null ? new MainWindow("windows", ownershipPath) : string.IsNullOrWhiteSpace(initialNav)
                ? new MainWindow()
                : new MainWindow(initialNav.Trim()));
        }
        string?[] waiting;
        lock (RedirectGate) { _ready = true; waiting = PendingRedirects.ToArray(); PendingRedirects.Clear(); }
        foreach (var path in waiting) ShowRedirect(path);
        Operations.WatchGameSessions(Closing.Token);
        if (!savedSettings && IsAdministrator() && Operations.HasSavedLaunchSettings()) _ = KeepSignInStartAsync();
    }

    // A sign-in start that found a copy without administrator rights open takes the single-window key once that copy closes,
    // so later launches hand over to it. If a copy with those rights got the key first, this one ends.
    private static void TakeKeyWhenFree()
    {
        var timer = _keyTimer = _ui!.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(5);
        timer.Tick += (_, _) =>
        {
            try
            {
                var key = AppInstance.FindOrRegisterForKey("RooIndustries.OptimizationSuite.Main");
                if (key.IsCurrent) { timer.Stop(); key.Activated += OnRedirected; AppLog.Write("start", "The saved launch settings copy now takes new launches."); }
                else if (ElevatedProcess(key.ProcessId)) { timer.Stop(); Closing.Cancel(); Current.Exit(); }
            }
            catch (Exception error) { AppLog.Write("start", "Single-window check unavailable: " + error.Message); }
        };
        timer.Start();
    }

    // Unknown counts as not elevated: the sign-in start then keeps saved settings on, and the shared lock keeps two copies apart.
    private static bool ElevatedProcess(uint processId)
    {
        var process = OpenProcess(0x1000, false, processId);
        if (process == IntPtr.Zero) return false;
        try
        {
            if (!OpenProcessToken(process, 0x0008, out var token)) return false;
            try { return GetTokenInformation(token, 20, out var elevated, sizeof(int), out _) && elevated != 0; }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }

    // Saved launch settings start this app at sign-in, without a window, so they turn on after a restart too.
    private static async System.Threading.Tasks.Task KeepSignInStartAsync()
    {
        try { await Operations.KeepSavedSettingsAtSignInAsync(); }
        catch (Exception error) { AppLog.Write("profiles", "The sign-in start for saved launch settings couldn't be updated: " + error.Message); }
    }

    private static void OpenWindow(MainWindow window)
    {
        MainWindow = window;
        window.Activate();
        if (window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            try
            {
                presenter.Maximize();
            }
            catch
            {
            }
        }
        Updates.Start(window.DispatcherQueue);
    }

    public static void WindowClosed(Window window)
    {
        if (!ReferenceEquals(MainWindow, window)) return;
        MainWindow = null;
        // Only a copy with administrator rights can turn saved settings on, so only that one stays without a window.
        if (IsAdministrator() && Operations.HasSavedLaunchSettings())
        {
            AppLog.Write("close", "The window closed; saved launch settings stay on in the background.");
            return;
        }
        Updates.Stop();
        Closing.Cancel();
        Current.Exit();
    }

#if ROO_INDUSTRIES_TEST_HOOKS
    private static async System.Threading.Tasks.Task HoldChangeAsync(string flag)
    {
        while (true)
        {
            while (!System.IO.File.Exists(flag)) await System.Threading.Tasks.Task.Delay(250);
            using (DataGeneration.BeginChange())
                while (System.IO.File.Exists(flag)) await System.Threading.Tasks.Task.Delay(250);
        }
    }
#endif

    private static readonly object RedirectGate = new();
    private static readonly System.Collections.Generic.List<string?> PendingRedirects = new();
    private static bool _ready;
    private static Microsoft.UI.Dispatching.DispatcherQueue? _ui;
    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _keyTimer;

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
            if (!_ready) { PendingRedirects.Add(ownershipPath); return; }
        }
        ShowRedirect(ownershipPath);
    }

    private static void ShowRedirect(string? ownershipPath) => _ui?.TryEnqueue(() =>
    {
        try
        {
            if (MainWindow is not { } window)
            {
                OpenWindow(ownershipPath is not null ? new MainWindow("windows", ownershipPath) : new MainWindow());
                return;
            }
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
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [System.Runtime.InteropServices.DllImport("advapi32.dll")] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [System.Runtime.InteropServices.DllImport("advapi32.dll")] private static extern bool GetTokenInformation(IntPtr token, int kind, out int value, int length, out int returned);

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
