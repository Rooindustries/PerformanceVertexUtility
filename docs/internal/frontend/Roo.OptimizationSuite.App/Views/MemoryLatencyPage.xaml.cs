using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class MemoryLatencyPage : Page
{
    public MemoryLatencyViewModel ViewModel { get; } = new();

    public MemoryLatencyPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
}
