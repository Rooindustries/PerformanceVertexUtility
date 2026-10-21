using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class BugRedactor
{
    private readonly (Regex Pattern, string Replacement)[] _rules;
    private readonly string _own;
    private readonly string? _ownRoot;

    public BugRedactor(string? profilePath, string? userName, string? machineName)
    {
        var rules = new List<(Regex, string)>();
        var profile = profilePath?.TrimEnd('\\', '/');
        _own = profile?.Split('\\', '/')[^1] ?? "";
        _ownRoot = string.IsNullOrEmpty(profile) || profile.Length == _own.Length ? null : NormalizeRoot(profile[..^_own.Length]);
        if (!string.IsNullOrWhiteSpace(profile))
        {
            foreach (var form in new[] { profile, profile.Replace("\\", "\\\\"), profile.Replace('\\', '/') }.Distinct())
                rules.Add((new Regex(Regex.Escape(form), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "%USERPROFILE%"));
        }
        foreach (var (value, replacement) in new[] { (machineName?.Trim(), PcName), (userName?.Trim(), User) })
        {
            if (value is not { Length: >= 2 }) continue;
            rules.Add((Word(value), replacement));
            var escaped = JsonEncodedText.Encode(value).ToString();
            if (escaped != value) rules.Add((Word(escaped), replacement));
        }
        rules.Add((new Regex(@"S-1-5-21(-\d+){3,4}", RegexOptions.CultureInvariant), Sid));
        _rules = rules.ToArray();
    }

    public static BugRedactor Current()
        => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.UserName, Environment.MachineName);

    public string Redact(string text)
    {
        text = text.Replace(User, @"\u0001").Replace(PcName, @"\u0002").Replace(Sid, @"\u0003");
        text = text.Replace("<user>", User, StringComparison.OrdinalIgnoreCase).Replace("<pc-name>", PcName, StringComparison.OrdinalIgnoreCase).Replace("<sid>", Sid, StringComparison.OrdinalIgnoreCase);
        var changes = new List<(int Start, int End, string Value)>();
        foreach (Match match in ProfileSegment.Matches(text))
            if (Profile(match, text) is { } change) changes.Add(change);
        changes.Sort((left, right) => left.Start != right.Start ? left.Start.CompareTo(right.Start) : left.End.CompareTo(right.End));
        var merged = new List<(int Start, int End, string Value)>();
        foreach (var change in changes)
        {
            if (merged.Count > 0 && change.Start < merged[^1].End)
                merged[^1] = (merged[^1].Start, Math.Max(merged[^1].End, change.End), User);
            else merged.Add(change);
        }
        if (merged.Count > 0)
        {
            var output = new StringBuilder(text.Length);
            var offset = 0;
            foreach (var change in merged)
            {
                output.Append(text, offset, change.Start - offset);
                output.Append(change.Value);
                offset = change.End;
            }
            output.Append(text, offset, text.Length - offset);
            text = output.ToString();
        }
        foreach (var (pattern, replacement) in _rules) text = pattern.Replace(text, replacement);
        return text.Replace(User, "<user>").Replace(PcName, "<pc-name>").Replace(Sid, "<sid>");
    }

    private (int Start, int End, string Value)? Profile(Match match, string input)
    {
        var root = match.Groups["root"].Value;
        var run = match.Groups["run"].Value;
        var runStart = match.Groups["run"].Index;
        var matchEnd = runStart + run.Length;
        var joinedDrive = matchEnd + 2 < input.Length && char.IsAsciiLetter(input[matchEnd]) && input[matchEnd + 1] == ':' && input[matchEnd + 2] is '\\' or '/';
        if (run.Length == 0) return joinedDrive ? (runStart, runStart, User) : null;
        var slashes = root.Length - root.TrimEnd('\\').Length;
        if (slashes > 0 && (slashes & (slashes - 1)) != 0)
        {
            if (run[0] is 'n' or 'r' or 't' or 'b' or 'f') return null;
            if (run.Length >= 5 && (run[0] is 'u' or 'U') && run.Skip(1).Take(4).All(Uri.IsHexDigit))
            {
                var escape = slashes & -slashes;
                root = root[..^escape];
                runStart -= escape;
                run = new string('\\', escape) + run;
            }
        }
        var decoded = new StringBuilder();
        var ends = new List<int>();
        var placeholderSeen = false;
        for (var index = 0; index < run.Length;)
        {
            if (placeholderSeen && run.AsSpan(index).StartsWith("%USERPROFILE%", StringComparison.OrdinalIgnoreCase))
            {
                var markerEnd = index;
                while (run.AsSpan(markerEnd).StartsWith("%USERPROFILE%", StringComparison.OrdinalIgnoreCase)) markerEnd += 13;
                if (markerEnd == run.Length) break;
                if (run[markerEnd] == '\\')
                {
                    var hex = markerEnd;
                    while (run[hex] == '\\') hex++;
                    if ((char)Convert.ToInt32(run.Substring(hex + 1, 4), 16) is '\\' or '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' or < ' ') break;
                }
                decoded.Append(run, index, markerEnd - index);
                for (var cursor = index; cursor < markerEnd; cursor++) ends.Add(cursor + 1);
                index = markerEnd;
                continue;
            }
            char c; int next;
            if (run[index] == '\\')
            {
                var escape = index;
                while (run[escape] == '\\') escape++;
                c = (char)Convert.ToInt32(run.Substring(escape + 1, 4), 16); next = escape + 5;
            }
            else { c = run[index]; next = index + 1; }
            if (c is '\\' or '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' || c < ' ' && !(next == index + 1 && c is '\u0001' or '\u0002' or '\u0003')) break;
            if (next == index + 1 && c is '\u0001' or '\u0002' or '\u0003') placeholderSeen = true;
            decoded.Append(c); index = next; ends.Add(index);
        }
        var text = decoded.ToString();
        matchEnd = runStart + (ends.Count == 0 ? 0 : ends[^1]);
        joinedDrive = matchEnd + 2 < input.Length && char.IsAsciiLetter(input[matchEnd]) && input[matchEnd + 1] == ':' && input[matchEnd + 2] is '\\' or '/';
        if (text.Length == 0 || SharedProfiles.Contains(text) && !joinedDrive && !run[..ends[^1]].Contains('\\')) return null;
        if (text.TrimEnd(' ', '.', ',', ';', '!', ')', ']', '}', '\'') is { Length: 1 } placeholder && placeholder[0] is '\u0001' or '\u0002' or '\u0003') return null;
        var rootIndex = match.Groups["root"].Index;
        var escapedRoot = rootIndex > 0 && input[rootIndex - 1] == '\\'
            || rootIndex >= 5 && input[rootIndex - 5] == '\\' && (input[rootIndex - 4] == 'u' || input[rootIndex - 4] == 'U')
                && Uri.IsHexDigit(input[rootIndex - 3]) && Uri.IsHexDigit(input[rootIndex - 2]) && Uri.IsHexDigit(input[rootIndex - 1]);
        if (!escapedRoot && text.Equals(_own, StringComparison.OrdinalIgnoreCase) && NormalizeRoot(root) == _ownRoot)
            return (rootIndex, runStart + ends[^1], "%USERPROFILE%");
        var length = text.Length;
        while (length > 0 && text[length - 1] is ' ' or '.' or ',' or ';' or '!' or ')' or ']' or '}' or '\'') length--;
        if (length == 0) length = text.Length;
        return (runStart, runStart + ends[length - 1], User);
    }

    private static string NormalizeRoot(string path) => Regex.Replace(path.Replace('/', '\\'), @"\\+", "\\").TrimEnd('\\').ToUpperInvariant();

    private const string User = "\u0001", PcName = "\u0002", Sid = "\u0003";
    private static readonly HashSet<string> SharedProfiles = new(["Public", "Default", "Default User", "All Users"], StringComparer.OrdinalIgnoreCase);
    private static readonly Regex ProfileSegment = new(@"(?=(?<root>[A-Za-z]:(?:\\+|/+)Users(?<sep>(?>\\+|/+)))(?<run>(?>(?:(?!\k<sep>)\\+u[0-9A-Fa-f]{4}|(?![A-Za-z]:[\\/])[^\\/""\x00-\x1F:<>|?*])*)(?>[\u0001-\u0003](?:(?!\k<sep>)\\+u[0-9A-Fa-f]{4}|(?![A-Za-z]:[\\/])[^\\/""\x00-\x1F:<>|?*])*)*))", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static Regex Word(string value)
        => new(@"(?<![\p{L}\p{N}_])" + Regex.Escape(value) + @"(?![\p{L}\p{N}_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}
