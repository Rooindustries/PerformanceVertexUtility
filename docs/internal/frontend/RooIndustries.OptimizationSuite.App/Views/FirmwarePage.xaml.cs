using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;
using Microsoft.Windows.Storage.Pickers;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class FirmwarePage : Page
{
    public FirmwareViewModel ViewModel { get; } = new();
    public FirmwarePage()
    {
        FirmwareViewModel.WriteTestsPath = App.CatalogsDirectory is { } catalogs ? Path.Combine(catalogs, "firmware-write-tests.json") : null;
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    private void Back(object sender, RoutedEventArgs e) { if (!ViewModel.Busy) Frame.Navigate(typeof(ToolsDiagnosticsPage)); }
    private async void ChoosePackage(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Busy || App.MainWindow is null) return;
        try
        {
            var picker = new FolderPicker(App.MainWindow.AppWindow.Id);
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;
            var package = await Task.Run(() => ScewinProvider.Inspect(folder.Path));
            var details = "Version: " + package.Version + "\nPublisher: " + package.Publisher + "\nSignature: " + package.Signature
                + "\n\nFiles: " + string.Join(", ", package.Files.Select(f => f.Name))
                + "\n\nUse the original package supplied for this motherboard. Its helper files will be copied into the app. No BIOS setting is changed during setup."
                + (package.Signature == "NotSigned" ? "\n\nThis executable is unsigned. Continue only if you trust the source of this exact package." : "");
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Use this SCEWIN package?", Content = new TextBlock { Text = details, TextWrapping = TextWrapping.Wrap, MaxWidth = 550 }, PrimaryButtonText = "Use this package", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) await ViewModel.SetUpAsync(folder.Path, package);
        }
        catch (Exception ex) { ViewModel.Message = ex.Message; }
    }
    private async void LoadSettings(object sender, RoutedEventArgs e) => await ViewModel.LoadAsync();
    private void CancelSetup(object sender, RoutedEventArgs e) => ViewModel.CancelSetup();
    private async void Review(object sender, RoutedEventArgs e) => await ViewModel.ReviewAsync();
    private void Edit(object sender, RoutedEventArgs e) => ViewModel.EditAgain();
    private async void Apply(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanApply) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Write these BIOS settings?",
            Content = new TextBlock { Text = "A wrong BIOS setting can stop this PC from starting. If that happens, reset the BIOS to its defaults.\n\nIf this PC uses BitLocker or Device Encryption, find your recovery key before you restart. Windows can ask for it after a BIOS change.", TextWrapping = TextWrapping.Wrap, MaxWidth = 550 },
            PrimaryButtonText = ViewModel.ApplyLabel, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && ViewModel.CanApply) await ViewModel.ApplyAsync();
    }
    private async void Verify(object sender, RoutedEventArgs e) => await ViewModel.VerifyAsync();
    private async void Undo(object sender, RoutedEventArgs e) => await ViewModel.UndoAsync();
    private async void OpenSettings(object sender, RoutedEventArgs e) => await ViewModel.OpenSettingsAsync();
    private async void OpenHistory(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is FirmwareHistoryRow row) await ViewModel.OpenHistoryAsync(row);
    }
    private void OpenFiles(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SessionDirectory is not { } directory) return;
        try { RuntimeEnvironment.OpenInExplorer(directory); }
        catch (Exception ex) { ViewModel.Message = ex.Message; }
    }
    private bool _restarting;
    private async void Restart(object sender, RoutedEventArgs e)
    {
        if (_restarting || !ViewModel.CanRestart) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Restart this PC now?", Content = "Save your work first. Windows will restart immediately. Reopen this BIOS session afterward to verify the settings.", PrimaryButtonText = "Restart now", CloseButtonText = "Later", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await ViewModel.VerifyAsync();
            if (_restarting || !ViewModel.CanRestart) return;
            _restarting = true;
            await Task.Run(() => SystemRestart.Restart((command, error) => AppLog.Write("firmware-restart", Path.GetFileName(command.FileName) + " boot target skipped: " + error.Message)));
        }
        catch (Exception ex) { _restarting = false; ViewModel.Message = ex.Message; }
    }
}
