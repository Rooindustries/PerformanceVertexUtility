using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class ToolsDiagnosticsPage : Page
{
    public ToolsDiagnosticsViewModel ViewModel { get; } = new();
    public ToolsDiagnosticsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => { await ViewModel.InitializeAsync(); ResizeTools(null, null); };
    }
    private void OpenFirmware(object sender, RoutedEventArgs e) => Frame.Navigate(typeof(FirmwarePage));
    private async void Refresh(object sender, RoutedEventArgs e) => await ViewModel.ReloadAsync();
    private async void OpenTool(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ToolRow tool } button)
        {
            button.IsEnabled = false;
            try { await ViewModel.OpenAsync(tool); }
            finally { button.IsEnabled = true; }
        }
    }
    private void ResizeTools(object? sender, SizeChangedEventArgs? e)
    {
        if (ToolGrid.ItemsPanelRoot is ItemsWrapGrid panel && ToolGrid.ActualWidth > 0)
        {
            var columns = Math.Max(1, (int)(ToolGrid.ActualWidth / 330));
            panel.ItemWidth = (ToolGrid.ActualWidth - 16) / columns;
            panel.ItemHeight = 86;
        }
    }
}
