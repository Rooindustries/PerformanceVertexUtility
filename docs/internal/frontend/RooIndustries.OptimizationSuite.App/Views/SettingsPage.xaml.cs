using System;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; } = new();

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            ResizeContent();
            await ViewModel.InitializeAsync();
            ResizeContent();
        };
        SizeChanged += (_, _) => ResizeContent();
    }

    private void ResizeContent() => ResponsiveContentSizer.Apply(this, SettingsContent, 1100);

    private void OpenLogs_Click(object sender, RoutedEventArgs e) => Open(ViewModel.LogFolder, folder: true);

    private static void Open(string target, bool folder = false)
    {
        try
        {
            if (folder) Directory.CreateDirectory(target);
            RooIndustries.Optimizer.RuntimeEnvironment.OpenInExplorer(target);
        }
        catch (Exception error)
        {
            AppLog.Write("settings", error.ToString());
        }
    }
}
