using System.Linq;
using Microsoft.UI.Xaml.Controls;
using Roo.OptimizationSuite.Models;
using Roo.OptimizationSuite.ViewModels;

namespace Roo.OptimizationSuite.Views;

public sealed partial class BulkRemovalPanel : UserControl
{
    public BulkRemovalViewModel ViewModel { get; } = new();
    private bool _loaded;
    public BulkRemovalPanel()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            if (_loaded) return;
            _loaded = true;
            await ViewModel.InitializeAsync();
        };
    }
    private void SelectionChanged(object sender, SelectionChangedEventArgs args)
        => ViewModel.SetSelection(ApplicationList.SelectedItems.Cast<InstalledApp>());
}
