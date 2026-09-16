using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;
using Roo.Optimizer;
using Windows.Storage.Pickers;

namespace Roo.OptimizationSuite.Views;

public sealed partial class FirmwarePage : Page
{
    public FirmwareViewModel ViewModel { get; } = new();
    public FirmwarePage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
    private void Back(object sender, RoutedEventArgs e) { if (!ViewModel.Busy) Frame.Navigate(typeof(ToolsDiagnosticsPage)); }
    private async void ChoosePackage(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Busy || App.MainWindow is null) return;
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
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
    private async void Review(object sender, RoutedEventArgs e) => await ViewModel.ReviewAsync();
    private void Edit(object sender, RoutedEventArgs e) => ViewModel.EditAgain();
    private async void Apply(object sender, RoutedEventArgs e) => await ViewModel.ApplyAsync();
    private async void Verify(object sender, RoutedEventArgs e) => await ViewModel.VerifyAsync();
    private async void Undo(object sender, RoutedEventArgs e) => await ViewModel.UndoAsync();
    private async void OpenHistory(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is FirmwareHistoryRow row) await ViewModel.OpenHistoryAsync(row);
    }
    private void OpenFiles(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SessionDirectory is not { } directory) return;
        try { Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true }); }
        catch (Exception ex) { ViewModel.Message = ex.Message; }
    }
    private async void Restart(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanRestart) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Restart this PC now?", Content = "Save your work first. Windows will restart immediately. Reopen this BIOS session afterward to verify the settings.", PrimaryButtonText = "Restart now", CloseButtonText = "Later", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await ViewModel.VerifyAsync();
            if (!ViewModel.CanRestart) return;
            var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "shutdown.exe")) { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add("/r"); start.ArgumentList.Add("/t"); start.ArgumentList.Add("0");
            Process.Start(start);
        }
        catch (Exception ex) { ViewModel.Message = ex.Message; }
    }
}
