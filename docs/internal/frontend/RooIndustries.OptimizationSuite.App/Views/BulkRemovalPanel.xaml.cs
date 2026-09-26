using System;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class BulkRemovalPanel : UserControl
{
    public BulkRemovalViewModel ViewModel { get; } = new();
    private bool _loaded;
    public BulkRemovalPanel()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            if (_loaded) return;
            _loaded = true;
            await ViewModel.InitializeAsync();
        };
    }
    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanApply) return;
        var text = "Removing apps cannot be undone. To get an app back, install it again.\n\nStore apps are removed together with their saved data"
            + (ViewModel.IncludeAllAppxUsers ? " for every Windows account on this PC." : ".")
            + "\n\nSome apps open their own uninstaller. Follow its steps to finish.";
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = ViewModel.ApplyLabel + "?",
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 550 },
            PrimaryButtonText = ViewModel.ApplyLabel, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && ViewModel.CanApply) await ViewModel.ApplyCommand.ExecuteAsync(null);
    }
    private void SelectionChanged(object sender, SelectionChangedEventArgs args)
        => ViewModel.SetSelection(ApplicationList.SelectedItems.Cast<InstalledApp>());
}
