using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace RooIndustries.OptimizationSuite.Views;

internal static class ResponsiveContentSizer
{
    public static void Apply(Page page, FrameworkElement element, double maxWidth = 1600)
    {
        if (page.ActualWidth <= 0) return;
        element.HorizontalAlignment = HorizontalAlignment.Stretch;
        element.Margin = new Thickness(0);
        element.MaxWidth = maxWidth;
        element.Width = Math.Max(0, Math.Min(maxWidth, page.ActualWidth - 48));
    }
}
