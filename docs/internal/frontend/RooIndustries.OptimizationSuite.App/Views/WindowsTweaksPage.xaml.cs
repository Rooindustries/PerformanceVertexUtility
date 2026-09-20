using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Windows.Storage.Pickers;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class WindowsTweaksPage : Page
{
    public WindowsTweaksViewModel ViewModel { get; } = new();
    private WindowsRestorePointReview? _pendingRestorePoint;
    public WindowsTweaksPage()
    {
        ViewModel.SelectedSection = ViewModel.Sections.Single(section => section.Id == "network");
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.RefreshCommand.ExecuteAsync(null);
    }
    private void SettingRowSizeChanged(object sender, SizeChangedEventArgs args)
    {
        var row = (Grid)sender;
        var compact = args.NewSize.Width < 720;
        var title = row.Children.OfType<FrameworkElement>().Single(child => child.Name == "RowName");
        var current = (StackPanel)row.Children.OfType<FrameworkElement>().Single(child => child.Name == "RowCurrent");
        var actions = (StackPanel)row.Children.OfType<FrameworkElement>().Single(child => child.Name == "RowActions");
        Grid.SetColumnSpan(title, compact ? 3 : 1);
        Grid.SetRow(current, compact ? 1 : 0); Grid.SetColumn(current, compact ? 1 : 2);
        Grid.SetRow(actions, compact ? 1 : 0); Grid.SetColumn(actions, compact ? 2 : 3); Grid.SetColumnSpan(actions, compact ? 2 : 1);
        current.VerticalAlignment = actions.VerticalAlignment = compact ? VerticalAlignment.Top : VerticalAlignment.Center;
        current.Children[0].Visibility = actions.Children[0].Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        row.RowSpacing = compact ? 8 : 0;
        ColumnLabels.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }
    private void PresetTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) ViewModel.FilterPresets(sender.Text);
    }
    private void PresetChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is TweakChoice choice) ViewModel.SelectedPreset = choice;
    }
    private void OpenAppGroup(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string group } && App.MainWindow is MainWindow window) window.OpenAppGroup(group);
    }
    private async void OpenWindowsTool(object sender, RoutedEventArgs args)
    {
        try
        {
            if (sender is not MenuFlyoutItem { Tag: string action }) return;
            if (action == "oosu") { if (App.MainWindow is MainWindow window) window.FindTool("ShutUp"); return; }
            if (action == "recall")
            {
                if (!await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:privacy"))) throw new InvalidOperationException("Windows Privacy settings could not be opened.");
                ViewModel.Status = "Use Recall & snapshots in Windows settings";
                ViewModel.Detail = "Open Recall & snapshots, expand Delete snapshots, then choose Delete all. Windows asks for Windows Hello where required. Deleted snapshots cannot be restored.";
                return;
            }
            var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var start = action switch
            {
                "protection" => new ProcessStartInfo(Path.Combine(system, "SystemPropertiesProtection.exe")),
                "bitlocker" => new ProcessStartInfo(Path.Combine(system, "control.exe"), "/name Microsoft.BitLockerDriveEncryption"),
                "cleanup" => new ProcessStartInfo(Path.Combine(system, "cleanmgr.exe")),
                "folders" => new ProcessStartInfo(Path.Combine(system, "control.exe"), "folders"),
                _ => throw new InvalidOperationException("Unknown Windows tool."),
            };
            start.UseShellExecute = true;
            using var process = Process.Start(start);
        }
        catch (Exception error) { ViewModel.Status = "Couldn't open this Windows tool."; ViewModel.Detail = error.Message; }
    }
    private async void ImportSettings(object sender, RoutedEventArgs args)
    {
        if (!ViewModel.CanEdit) return;
        try
        {
            var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".json");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
            var file = await picker.PickSingleFileAsync(); if (file is null) return;
            ViewModel.Busy = true; await App.Operations.ImportWindowsSettingsAsync(file.Path); ViewModel.Busy = false;
            await ViewModel.RefreshCommand.ExecuteAsync(null); ViewModel.SelectedSection = ViewModel.Sections[0]; ViewModel.ShowAdvanced = true; ViewModel.Source = "Custom settings";
            ViewModel.Status = "Custom switches imported"; ViewModel.Detail = "Choose an imported preset or setting, then review before applying. Importing does not change Windows settings.";
        }
        catch (Exception error) { ViewModel.Status = "Couldn't import these switches."; ViewModel.Detail = error.Message; }
        finally { ViewModel.Busy = false; }
    }
    public async Task ShowOwnershipAsync(string path)
    {
        while (!IsLoaded || ViewModel.Busy) await Task.Delay(50);
        await ViewModel.ReviewOwnershipAsync(path);
    }
    private async void ReviewFileOwnership(object sender, RoutedEventArgs args)
    {
        var path = new TextBox { Header = "File or folder", PlaceholderText = @"C:\Path\Item", MinWidth = 440 };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Review file ownership", Content = path, PrimaryButtonText = "Review", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await ShowOwnershipAsync(path.Text);
    }
    private async void CreateRestorePoint(object sender, RoutedEventArgs args)
    {
        var pending = _pendingRestorePoint is not null;
        var fresh = new CheckBox { Content = "Allow a new point even if Windows created one recently", Visibility = pending ? Visibility.Collapsed : Visibility.Visible };
        var text = new TextBlock { Text = pending ? "Checks the previously requested restore point without starting another backup." : "Creates a Windows system restore point. If selected, the app temporarily changes the creation-frequency setting and restores it afterward.", TextWrapping = TextWrapping.Wrap, MaxWidth = 500 };
        var content = new StackPanel { Spacing = 12 }; content.Children.Add(text); content.Children.Add(fresh);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = pending ? "Check the requested restore point" : "Create a Windows restore point", Content = content, PrimaryButtonText = pending ? "Check restore point" : "Create restore point", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        ViewModel.Busy = true; ViewModel.Status = "Creating Windows restore point…";
        try
        {
            _pendingRestorePoint ??= await App.Operations.PreviewRestorePointAsync(fresh.IsChecked == true);
            var result = await App.Operations.CreateRestorePointAsync(_pendingRestorePoint);
            if (!result.Pending) _pendingRestorePoint = null;
            ViewModel.Status = result.Created && result.AvailableNow ? "Windows restore point verified" : result.Pending ? "Windows is still preparing the restore point" : "No new restore point was confirmed";
            ViewModel.Detail = result.Message;
        }
        catch (Exception error) { ViewModel.Status = "Couldn't confirm the restore point."; ViewModel.Detail = error.Message + " Check System Protection and saved Windows settings for recovery."; }
        finally { ViewModel.Busy = false; }
    }
}
