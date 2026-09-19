using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.ViewModels;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class MemoryLatencyPage : Page
{
    public MemoryLatencyViewModel ViewModel { get; } = new();

    public MemoryLatencyPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
}
