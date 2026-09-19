using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;
using Windows.Storage.Pickers;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class GameSessionPanel : UserControl
{
    public GameSessionViewModel ViewModel { get; } = new();
    private bool _initialized;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };
    public GameSessionPanel()
    {
        InitializeComponent();
        _timer.Tick += async (_, _) => await ViewModel.ObserveAsync();
        Unloaded += (_, _) => _timer.Stop();
        Loaded += async (_, _) =>
        {
            if (!_initialized) { _initialized = true; await ViewModel.InitializeAsync(); }
            _timer.Start();
        };
    }

    private async void Browse_Click(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanEdit || App.MainWindow is null) return;
        try
        {
            var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".exe");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
            var file = await picker.PickSingleFileAsync();
            if (file is not null && ViewModel.CanEdit) ViewModel.GamePath = file.Path;
        }
        catch (Exception error) { ViewModel.Detail = error.Message; }
    }
}
