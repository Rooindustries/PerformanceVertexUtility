using System;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace RooIndustries.OptimizationSuite.Views;

public sealed class AdaptivePanel : Panel
{
    public static readonly DependencyProperty MinColumnWidthProperty = DependencyProperty.Register(
        nameof(MinColumnWidth), typeof(double), typeof(AdaptivePanel), new PropertyMetadata(280d, LayoutChanged));
    public static readonly DependencyProperty MaxColumnsProperty = DependencyProperty.Register(
        nameof(MaxColumns), typeof(int), typeof(AdaptivePanel), new PropertyMetadata(3, LayoutChanged));

    public bool Compact { get; set; }

    public double MinColumnWidth { get => (double)GetValue(MinColumnWidthProperty); set => SetValue(MinColumnWidthProperty, value); }
    public int MaxColumns { get => (int)GetValue(MaxColumnsProperty); set => SetValue(MaxColumnsProperty, value); }

    private static void LayoutChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) => ((AdaptivePanel)sender).InvalidateMeasure();

    protected override Size MeasureOverride(Size availableSize) => Layout(availableSize.Width, false);
    protected override Size ArrangeOverride(Size finalSize)
    {
        Layout(finalSize.Width, true);
        return finalSize;
    }

    private Size Layout(double availableWidth, bool arrange)
    {
        const double gap = 12;
        var width = double.IsInfinity(availableWidth) ? MinColumnWidth : Math.Max(0, availableWidth);
        var columns = Math.Max(1, Math.Min(MaxColumns, (int)((width + gap) / (Math.Max(1, MinColumnWidth) + gap))));
        var cellWidth = Math.Max(0, (width - gap * (columns - 1)) / columns);
        if (Compact) cellWidth = Math.Min(cellWidth, MinColumnWidth);
        if (!arrange)
            foreach (var child in Children) child.Measure(new Size(cellWidth, double.PositiveInfinity));
        var children = Children.Where(child => child.Visibility == Visibility.Visible).ToArray();
        var y = 0d;
        for (var start = 0; start < children.Length; start += columns)
        {
            var end = Math.Min(start + columns, children.Length);
            var height = 0d;
            for (var i = start; i < end; i++)
            {
                height = Math.Max(height, children[i].DesiredSize.Height);
            }
            for (var i = start; arrange && i < end; i++)
                children[i].Arrange(new Rect((i - start) * (cellWidth + gap), y, cellWidth, height));
            y += height + (end < children.Length ? gap : 0);
        }
        return new Size(width, y);
    }
}
