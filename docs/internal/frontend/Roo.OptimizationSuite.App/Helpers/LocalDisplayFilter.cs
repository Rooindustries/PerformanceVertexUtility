using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Roo.OptimizationSuite.Helpers;

public sealed class LocalDisplayFilter
{
    private sealed class ExclusionData
    {
        public List<string>? DisplayNames { get; set; }
        public List<string>? ProcessNames { get; set; }
        public List<string>? PackageNames { get; set; }
    }

    private readonly HashSet<string> _displayNames;
    private readonly HashSet<string> _processNames;
    private readonly HashSet<string> _packageNames;

    public static LocalDisplayFilter Default { get; } = Load();

    private LocalDisplayFilter(HashSet<string> displayNames, HashSet<string> processNames, HashSet<string> packageNames)
    {
        _displayNames = displayNames;
        _processNames = processNames;
        _packageNames = packageNames;
    }

    public bool IsHidden(string? displayName, string? processName, string? packageName)
    {
        if (Match(_displayNames, displayName)) return true;
        if (Match(_processNames, StripExe(processName))) return true;
        if (MatchPackage(packageName)) return true;
        return false;
    }

    private static bool Match(HashSet<string> set, string? value)
        => set.Count > 0 && !string.IsNullOrWhiteSpace(value) && set.Contains(value.Trim());

    private bool MatchPackage(string? package)
    {
        if (_packageNames.Count == 0 || string.IsNullOrWhiteSpace(package)) return false;
        var family = package.Trim();
        var underscore = family.IndexOf('_');
        if (underscore > 0) family = family.Substring(0, underscore);
        if (_packageNames.Contains(family)) return true;
        foreach (var entry in _packageNames)
        {
            if (family.StartsWith(entry, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static string? StripExe(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return name;
        var trimmed = name.Trim();
        return trimmed.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? trimmed[..^4] : trimmed;
    }

    private static HashSet<string> NewSet() => new(StringComparer.OrdinalIgnoreCase);

    private static HashSet<string> ToSet(List<string>? values)
    {
        var set = NewSet();
        if (values is null) return set;
        foreach (var value in values)
        {
            if (!string.IsNullOrWhiteSpace(value)) set.Add(value.Trim());
        }
        return set;
    }

    private static LocalDisplayFilter Empty() => new(NewSet(), NewSet(), NewSet());

    private static LocalDisplayFilter Load()
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "RooOptimizationSuite", "private-display-exclusions.json");
            if (!File.Exists(path)) return Empty();

            var json = File.ReadAllText(path);
            if (string.IsNullOrWhiteSpace(json)) return Empty();

            var data = JsonSerializer.Deserialize<ExclusionData>(
                json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (data is null) return Empty();

            return new LocalDisplayFilter(ToSet(data.DisplayNames), ToSet(data.ProcessNames), ToSet(data.PackageNames));
        }
        catch
        {
            return Empty();
        }
    }
}
