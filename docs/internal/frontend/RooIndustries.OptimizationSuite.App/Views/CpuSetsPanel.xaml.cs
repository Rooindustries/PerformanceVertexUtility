using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class CpuSetsPanel : UserControl
{
    public CpuSetsViewModel ViewModel { get; } = new();
    private bool _loaded;
    public CpuSetsPanel()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            if (_loaded) { if (!ViewModel.Busy && ViewModel.SelectedProcess is null) await ViewModel.RefreshCommand.ExecuteAsync(null); return; }
            _loaded = true;
            await ViewModel.InitializeAsync();
        };
    }
}
