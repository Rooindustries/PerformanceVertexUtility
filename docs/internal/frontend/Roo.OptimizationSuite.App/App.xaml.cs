using Microsoft.UI.Xaml;
using Roo.OptimizationSuite.Services;

namespace Roo.OptimizationSuite;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    private static readonly BackendLocator Locator = new();

    public static SampleDataService Data { get; } = new SampleDataService(Locator);
    public static LiveDataService Live { get; } = new LiveDataService(Locator);
    public static ThemeService Theme { get; } = new ThemeService(new SettingsStore());

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
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
