using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class BugRedactor
{
    private readonly (Regex Pattern, string Replacement)[] _rules;
    private readonly string[] _profiles;
    private readonly string _own;
    private readonly string? _ownRoot;

    public BugRedactor(string? profilePath, string? userName, string? machineName, IEnumerable<string>? otherProfiles = null)
    {
        var rules = new List<(Regex, string)>();
        var profile = profilePath?.TrimEnd('\\', '/');
        _own = profile?.Split('\\', '/')[^1] ?? "";
        _ownRoot = string.IsNullOrEmpty(profile) || profile.Length == _own.Length ? null : Root(profile[..^_own.Length]);
        _profiles = (otherProfiles ?? []).Where(name => !string.IsNullOrWhiteSpace(name) && !SharedProfiles.Contains(name)).Append(_own)
            .Where(name => name.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).OrderByDescending(name => name.Length).ToArray();
        if (!string.IsNullOrWhiteSpace(profile))
        {
            foreach (var form in new[] { profile, profile.Replace("\\", "\\\\"), profile.Replace('\\', '/') }.Distinct())
                rules.Add((new Regex(Regex.Escape(form), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "%USERPROFILE%"));
        }
        foreach (var (value, replacement) in new[] { (machineName?.Trim(), "<pc-name>"), (userName?.Trim(), "<user>") })
        {
            if (value is not { Length: >= 2 }) continue;
            rules.Add((Word(value), replacement));
            var escaped = JsonEncodedText.Encode(value).ToString();
            if (escaped != value) rules.Add((Word(escaped), replacement));
        }
        rules.Add((new Regex(@"S-1-5-21(-\d+){3,4}", RegexOptions.CultureInvariant), "<sid>"));
        _rules = rules.ToArray();
    }

    public static BugRedactor Current()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new(profile, Environment.UserName, Environment.MachineName, ProfileNames(Path.GetDirectoryName(profile.TrimEnd('\\', '/'))));
    }

    public string Redact(string text)
    {
        text = ProfileSegment.Replace(text, Profile);
        foreach (var (pattern, replacement) in _rules) text = pattern.Replace(text, replacement);
        return text;
    }

    private string Profile(Match match)
    {
        var root = match.Groups["root"].Value;
        var run = match.Groups["run"].Value;
        var decoded = new StringBuilder();
        var ends = new List<int>();
        for (var index = 0; index < run.Length;)
        {
            if (run[index] == '\\') { decoded.Append((char)Convert.ToInt32(run.Substring(index + 2, 4), 16)); index += 6; }
            else { decoded.Append(run[index]); index++; }
            ends.Add(index);
        }
        var text = decoded.ToString();
        bool Starts(string name) => text.Length >= name.Length && string.Compare(text, 0, name, 0, name.Length, StringComparison.OrdinalIgnoreCase) == 0
            && (text.Length == name.Length || !(char.IsLetterOrDigit(text[name.Length]) || text[name.Length] == '_'));
        if (_profiles.FirstOrDefault(Starts) is { } known)
        {
            var rest = run[ends[known.Length - 1]..];
            return (known.Equals(_own, StringComparison.OrdinalIgnoreCase) && Root(root) == _ownRoot ? "%USERPROFILE%" : root + "<user>") + rest;
        }
        if (SharedProfiles.Any(Starts)) return match.Value;
        var length = 0;
        while (length < text.Length && !char.IsWhiteSpace(text[length]) && text[length] is not ('\'' or '"' or '\\' or '/')) length++;
        return length == 0 ? match.Value : root + "<user>" + run[ends[length - 1]..];
    }

    private static string Root(string path) => path.Replace("\\\\", "\\").Replace('/', '\\').TrimEnd('\\').ToUpperInvariant();

    private static string[] ProfileNames(string? root)
    {
        try { return string.IsNullOrEmpty(root) ? [] : Directory.GetDirectories(root).Select(Path.GetFileName).OfType<string>().ToArray(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
    }

    private static readonly HashSet<string> SharedProfiles = new(["Public", "Default", "Default User", "All Users"], StringComparer.OrdinalIgnoreCase);
    private static readonly Regex ProfileSegment = new(@"(?<root>\b[A-Za-z]:(?:\\{1,2}|/)Users(?:\\{1,2}|/))(?<run>(?:\\u[0-9A-Fa-f]{4}|(?![A-Za-z]:)[^\\/""\r\n:<>|?*])+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static Regex Word(string value)
        => new(@"(?<![\p{L}\p{N}_])" + Regex.Escape(value) + @"(?![\p{L}\p{N}_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}
