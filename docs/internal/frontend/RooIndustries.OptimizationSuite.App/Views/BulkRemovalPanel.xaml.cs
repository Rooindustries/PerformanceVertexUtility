using System;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class BulkRemovalPanel : UserControl
{
    public BulkRemovalViewModel ViewModel { get; } = new();
    private bool _loaded;
    private readonly ChangeWatch _watch;
    public BulkRemovalPanel()
    {
        InitializeComponent();
        _watch = new(work => DispatcherQueue.TryEnqueue(async () => await work()), CatchUpAsync);
        ViewModel.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(ViewModel.Busy)) { if (ViewModel.Busy) _watch.OperationStarted(); else _watch.OperationEnded(); } };
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
        if (ViewModel.HasUserWork) { if (changed) { _watch.MarkSeen(); ViewModel.NoteChanged(); } return; }
        await _watch.RefreshAsync(() => ViewModel.RefreshIfIdleAsync(changed));
    }
    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (!ViewModel.CanApply) return;
        var text = "Removing apps can't be undone. To get an app back, install it again.\n\nStore apps are removed together with their saved data"
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
