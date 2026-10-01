using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class CpuSetsPanel : UserControl
{
    public CpuSetsViewModel ViewModel { get; } = new();
    private bool _loaded;
    private readonly ChangeWatch _watch;
    public CpuSetsPanel()
    {
        InitializeComponent();
        _watch = new(work => DispatcherQueue.TryEnqueue(async () => await work()), CatchUpAsync);
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ViewModel.Busy)) { if (ViewModel.Busy) _watch.OperationStarted(); else _watch.OperationEnded(); }
            if (args.PropertyName == nameof(ViewModel.SelectedProcess) && ViewModel.SelectedProcess is null && _watch.Changed && IsLoaded) _watch.Run(revisit: false);
        };
        Unloaded += (_, _) => _watch.Stop();
        Loaded += async (_, _) =>
        {
            _watch.Start();
            if (_loaded) { _watch.Run(revisit: true); return; }
            _loaded = true; _watch.MarkSeen();
            await ViewModel.InitializeAsync();
        };
    }
    private async System.Threading.Tasks.Task CatchUpAsync(bool revisit)
    {
        if (!IsLoaded) return;
        var changed = _watch.Changed;
        if ((!revisit && !changed) || ViewModel.Busy) return;
        if (ViewModel.SelectedProcess is null) await _watch.RefreshAsync(() => ViewModel.RefreshCommand.ExecuteAsync(null));
        else if (changed) { _watch.MarkSeen(); ViewModel.NoteChanged(); }
    }
}
