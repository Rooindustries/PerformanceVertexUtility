using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class CpuSetsPanel : UserControl
{
    public CpuSetsViewModel ViewModel { get; } = new();
    private bool _loaded;
    public CpuSetsPanel()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            if (_loaded) return;
            _loaded = true;
            await ViewModel.InitializeAsync();
        };
    }
}
