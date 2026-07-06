using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class ToolsDiagnosticsPage : Page
{
    public ToolsDiagnosticsViewModel ViewModel { get; } = new();

    public ToolsDiagnosticsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
}
