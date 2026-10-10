using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using Microsoft.Windows.Storage.Pickers;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class GameSessionPanel : UserControl
{
    public GameSessionViewModel ViewModel { get; } = new();
    private bool _initialized;
    private readonly ChangeWatch _watch;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };
    public GameSessionPanel()
    {
        InitializeComponent();
        _watch = new(work => DispatcherQueue.TryEnqueue(async () => await work()), CatchUpAsync);
        _timer.Tick += async (_, _) => { if (!MemoryRelief.Minimized) await ViewModel.ObserveAsync(); };
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ViewModel.Busy)) { if (ViewModel.Busy) _watch.OperationStarted(); else _watch.OperationEnded(); }
            if (args.PropertyName is nameof(ViewModel.SelectedLauncher) or nameof(ViewModel.SelectedSession) && ViewModel.SelectedLauncher is null && ViewModel.SelectedSession is null && _watch.Changed && IsLoaded) _watch.Run(revisit: false);
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
        if ((!revisit && !changed) || ViewModel.Busy) return;
        if (ViewModel.SelectedSession is null && ViewModel.SelectedLauncher is null) await _watch.RefreshAsync(ViewModel.TryRefreshAsync);
        else if (changed && ViewModel.SelectedSession is null) { _watch.MarkSeen(); ViewModel.NoteChanged(); }
    }

    private async void Browse_Click(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanEdit || App.MainWindow is null) return;
        try
        {
            var picker = new FileOpenPicker(App.MainWindow.AppWindow.Id); picker.FileTypeFilter.Add(".exe");
            var file = await picker.PickSingleFileAsync();
            if (file is not null && ViewModel.CanEdit) ViewModel.GamePath = file.Path;
        }
        catch (Exception error) { ViewModel.Detail = error.Message; }
    }
}
