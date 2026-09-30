using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using System;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class ProcessControlsPanel : UserControl
{
    public ProcessControlsViewModel ViewModel { get; } = new();
    private bool _initialized;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };
    public ProcessControlsPanel()
    {
        InitializeComponent();
        _timer.Tick += async (_, _) => await ViewModel.ObserveAsync();
        Unloaded += (_, _) => _timer.Stop();
        Loaded += async (_, _) =>
        {
            if (!_initialized) { _initialized = true; await ViewModel.InitializeAsync(); }
            else if (ViewModel.SelectedProcess is null && ViewModel.CanEdit) await ViewModel.RefreshCommand.ExecuteAsync(null);
            _timer.Start();
        };
    }
}
