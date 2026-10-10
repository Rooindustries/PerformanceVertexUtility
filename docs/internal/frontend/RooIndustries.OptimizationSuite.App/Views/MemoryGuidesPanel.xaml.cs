using Microsoft.UI.Xaml.Controls;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.Views;

public sealed partial class MemoryGuidesPanel : UserControl
{
    public MemoryGuideSet Guides { get; } = MemoryGuideSet.Current;
    public MemoryGuidesPanel() => InitializeComponent();
}
