using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class ProcessControlsPanel : UserControl
{
    public ProcessControlsViewModel ViewModel { get; } = new();
    private bool _initialized;
    private readonly ChangeWatch _watch;
    private readonly ForegroundPoll _poll;
    public ProcessControlsPanel()
    {
        InitializeComponent();
        _watch = new(work => DispatcherQueue.TryEnqueue(async () => await work()), CatchUpAsync);
        _poll = new(ViewModel.ObserveAsync);
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ViewModel.Busy)) { if (ViewModel.Busy) _watch.OperationStarted(); else _watch.OperationEnded(); }
            if (args.PropertyName == nameof(ViewModel.SelectedProcess) && ViewModel.SelectedProcess is null && _watch.Changed && IsLoaded) _watch.Run(revisit: false);
        };
        Unloaded += (_, _) => { _poll.Stop(); _watch.Stop(); };
        Loaded += async (_, _) =>
        {
            _watch.Start();
            if (!_initialized) { _initialized = true; _watch.MarkSeen(); await ViewModel.InitializeAsync(); }
            else _watch.Run(revisit: true);
            if (IsLoaded) _poll.Start();
        };
    }
    private async System.Threading.Tasks.Task CatchUpAsync(bool revisit)
    {
        if (!IsLoaded) return;
        var changed = _watch.Changed;
        if ((!revisit && !changed) || ViewModel.Busy || !ViewModel.CanEdit) return;
        if (ViewModel.SelectedProcess is null) await _watch.RefreshAsync(ViewModel.TryRefreshAsync);
        else if (changed) await _watch.RefreshAsync(ViewModel.TryRefreshRulesAsync);
    }
}
