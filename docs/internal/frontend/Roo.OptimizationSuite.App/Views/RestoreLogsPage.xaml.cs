using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class RestoreLogsPage : Page
{
    public RestoreLogsViewModel ViewModel { get; } = new();

    public RestoreLogsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await ViewModel.InitializeAsync();
    }
}
