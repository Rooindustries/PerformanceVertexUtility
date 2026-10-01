using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using System;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class ProcessControlsPanel : UserControl
{
    public ProcessControlsViewModel ViewModel { get; } = new();
    private bool _initialized;
    private readonly ChangeWatch _watch;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };
    public ProcessControlsPanel()
    {
        InitializeComponent();
        _watch = new(DispatcherQueue, CatchUpAsync);
        _timer.Tick += async (_, _) => await ViewModel.ObserveAsync();
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ViewModel.Busy)) { if (ViewModel.Busy) _watch.OperationStarted(); else _watch.OperationEnded(); }
            if (args.PropertyName == nameof(ViewModel.SelectedProcess) && ViewModel.SelectedProcess is null && _watch.Changed && IsLoaded) _watch.Run(revisit: false);
        };
        Unloaded += (_, _) => { _timer.Stop(); _watch.Stop(); };
        Loaded += async (_, _) =>
        {
            _watch.Start();
            if (!_initialized) { _initialized = true; _watch.MarkSeen(); await ViewModel.InitializeAsync(); }
            else _watch.Run(revisit: true);
            if (IsLoaded) _timer.Start();
        };
    }
    private async System.Threading.Tasks.Task CatchUpAsync(bool revisit)
    {
        if (!IsLoaded) return;
        var changed = _watch.Changed;
        if ((!revisit && !changed) || ViewModel.Busy || !ViewModel.CanEdit) return;
        if (ViewModel.SelectedProcess is null) await _watch.RefreshAsync(() => ViewModel.RefreshCommand.ExecuteAsync(null));
        else if (changed) await _watch.RefreshAsync(() => ViewModel.RefreshRulesCommand.ExecuteAsync(null));
    }
}
