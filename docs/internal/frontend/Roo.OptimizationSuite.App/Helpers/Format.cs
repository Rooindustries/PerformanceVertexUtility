using System.Globalization;

namespace Roo.OptimizationSuite.Helpers;

public static class Format
{
    public static string Bytes(double bytes)
    {
        if (bytes <= 0)
        {
            return "-";
        }

        string[] units = { "B", "KB", "MB", "GB", "TB" };
        var order = 0;
        while (bytes >= 1024 && order < units.Length - 1)
        {
            bytes /= 1024;
            order++;
        }

        var format = order >= 3 ? "0.0" : "0";
        return string.Format(CultureInfo.InvariantCulture, "{0:" + format + "} {1}", bytes, units[order]);
    }

    public static string Fps(double value) => value.ToString("0.0", CultureInfo.InvariantCulture);

    public static string Percent(double value) => value.ToString("0.0", CultureInfo.InvariantCulture) + "%";
}
