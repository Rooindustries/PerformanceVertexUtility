using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace Roo.OptimizationSuite.Views;

internal static class ResponsiveContentSizer
{
    private const double PageHorizontalPadding = 56;
    private const double DesktopSafetyGutter = 32;

    public static void Apply(Page page, FrameworkElement element, double maxWidth = 1180)
    {
        var rootWidth = page.XamlRoot?.Size.Width ?? 0;
        var parentWidth = element.Parent is FrameworkElement parent && parent.ActualWidth > 0
            ? parent.ActualWidth
            : 0;
        var pageWidth = page.ActualWidth > 0 ? page.ActualWidth : 0;
        var pageLeft = GetPageLeft(page);
        var visibleWidth = rootWidth > pageLeft + PageHorizontalPadding
            ? rootWidth - pageLeft - PageHorizontalPadding
            : 0;
        var paddedPageWidth = pageWidth > PageHorizontalPadding ? pageWidth - PageHorizontalPadding : pageWidth;
        var paddedParentWidth = parentWidth > PageHorizontalPadding ? parentWidth - PageHorizontalPadding : parentWidth;
        var available = SmallestPositive(visibleWidth, paddedPageWidth, paddedParentWidth);
        if (double.IsNaN(available) || double.IsInfinity(available) || available <= 0)
        {
            return;
        }

        var viewport = Math.Max(320, available);
        if (viewport > 900)
        {
            viewport -= DesktopSafetyGutter;
        }

        var width = Math.Max(320, Math.Min(maxWidth, viewport));
        element.HorizontalAlignment = HorizontalAlignment.Center;
        element.Margin = new Thickness(0);
        element.MaxWidth = maxWidth;
        element.Width = width;
    }

    private static double SmallestPositive(params double[] values)
    {
        var result = 0d;
        foreach (var value in values)
        {
            if (double.IsNaN(value) || double.IsInfinity(value) || value <= 0)
            {
                continue;
            }

            result = result <= 0 ? value : Math.Min(result, value);
        }

        return result;
    }

    private static double GetPageLeft(Page page)
    {
        try
        {
            return page.TransformToVisual(null).TransformPoint(new Point(0, 0)).X;
        }
        catch
        {
            return 0;
        }
    }
}
