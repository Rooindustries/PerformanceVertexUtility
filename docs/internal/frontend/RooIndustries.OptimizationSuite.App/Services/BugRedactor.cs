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
        text = ProfileSegment.Replace(text, match => Profile(match, text));
        foreach (var (pattern, replacement) in _rules) text = pattern.Replace(text, replacement);
        return text.Replace(User, "<user>").Replace(PcName, "<pc-name>").Replace(Sid, "<sid>");
    }

    private string Profile(Match match, string input)
    {
        var root = match.Groups["root"].Value;
        var run = match.Groups["run"].Value;
        if (run[0] == '\\' && root[^1] == '\\')
        {
            var slashes = 0;
            while (run[slashes] == '\\') slashes++;
            var total = slashes + 1;
            var escape = total & -total;
            if (escape == total) escape /= 2;
            var prefix = slashes - escape;
            root += run[..prefix]; run = run[prefix..];
        }
        var decoded = new StringBuilder();
        var ends = new List<int>();
        for (var index = 0; index < run.Length;)
        {
            char c; int next;
            if (run[index] == '\\')
            {
                var escape = index;
                while (run[escape] == '\\') escape++;
                c = (char)Convert.ToInt32(run.Substring(escape + 1, 4), 16); next = escape + 5;
            }
            else { c = run[index]; next = index + 1; }
            if (c is '\\' or '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' || c < ' ') break;
            decoded.Append(c); index = next; ends.Add(index);
        }
        var text = decoded.ToString();
        if (text.Length == 0 || SharedProfiles.Contains(text)) return match.Value;
        var rootIndex = match.Groups["root"].Index;
        var escapedRoot = rootIndex > 0 && input[rootIndex - 1] == '\\'
            || rootIndex >= 5 && input[rootIndex - 5] == '\\' && (input[rootIndex - 4] == 'u' || input[rootIndex - 4] == 'U')
                && Uri.IsHexDigit(input[rootIndex - 3]) && Uri.IsHexDigit(input[rootIndex - 2]) && Uri.IsHexDigit(input[rootIndex - 1]);
        if (!escapedRoot && text.Equals(_own, StringComparison.OrdinalIgnoreCase) && NormalizeRoot(root) == _ownRoot)
            return "%USERPROFILE%" + run[ends[^1]..];
        var length = text.Length;
        while (length > 0 && text[length - 1] is ' ' or '.' or ',' or ';' or '!' or ')' or ']' or '}' or '\'') length--;
        if (length == 0) length = text.Length;
        return root + User + run[ends[length - 1]..];
    }

    private static string NormalizeRoot(string path) => Regex.Replace(path.Replace('/', '\\'), @"\\+", "\\").TrimEnd('\\').ToUpperInvariant();

    private const string User = "\u0001", PcName = "\u0002", Sid = "\u0003";
    private static readonly HashSet<string> SharedProfiles = new(["Public", "Default", "Default User", "All Users"], StringComparer.OrdinalIgnoreCase);
    private static readonly Regex ProfileSegment = new(@"(?<root>[A-Za-z]:(?:\\+|/+)Users(?:\\+?|/+))(?<run>(?:\\+u[0-9A-Fa-f]{4}|(?![A-Za-z]:[\\/])[^\\/""\r\n:<>|?*\u0001-\u0003])+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static Regex Word(string value)
        => new(@"(?<![\p{L}\p{N}_])" + Regex.Escape(value) + @"(?![\p{L}\p{N}_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}
