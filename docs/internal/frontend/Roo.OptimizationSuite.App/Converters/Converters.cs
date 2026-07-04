using System;
using System.Collections;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace Roo.OptimizationSuite.Converters;

public sealed class RiskToBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var prefix = (value as string ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "safe" or "available" or "complete" or "completed" or "restorable" or "boosted"
                or "recommended" or "connected" => "RiskSafe",
            "low" or "info" or "demoted" or "candidate" or "preview-ready" or "ready-for-preview"
                or "fixture-apply-ready" or "tested" or "tested on a safe copy" => "RiskLow",
            "medium" or "watch" or "warning" or "needs-local-benchmark" or "seed-profile" or "advanced" => "RiskMedium",
            "high" or "critical" => "RiskHigh",
            "protected" or "protected companion" or "manual" or "manual gated" or "manual install"
                or "preview-only" or "review mode" or "guarded-fixture-ready" or "pending" or "ready"
                or "go-ahead" or "ready needs your go-ahead" or "ready — needs your go-ahead"
                or "helper packaging pending" or "not done yet" or "blocked" => "RiskProtected",
            "sample" or "sample capture" or "optional-not-detected" or "not connected" => "RiskNeutral",
            _ => "RiskNeutral",
        };

        var suffix = (parameter as string ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "soft" => "SoftBrush",
            "border" => "BorderBrush",
            _ => "Brush",
        };

        if (Application.Current.Resources.TryGetValue(prefix + suffix, out var resource) && resource is Brush brush)
        {
            return brush;
        }

        return new SolidColorBrush(Microsoft.UI.Colors.Gray);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class RiskToDisplayConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => (value as string ?? string.Empty).Trim().ToUpperInvariant();

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class BytesToReadableConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        double bytes = value switch
        {
            long l => l,
            int i => i,
            double d => d,
            _ => 0,
        };

        return Helpers.Format.Bytes(bytes);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility.Visible;
}

public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility.Collapsed;
}

public sealed class StringToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => string.IsNullOrWhiteSpace(value as string) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed class CountToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => GetCount(value) > 0 ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();

    internal static int GetCount(object value) => value switch
    {
        int i => i,
        ICollection c => c.Count,
        _ => 0,
    };
}

public sealed class CountToInverseVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => CountToVisibilityConverter.GetCount(value) == 0 ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}
