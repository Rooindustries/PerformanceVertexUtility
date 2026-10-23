using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class BugRedactor
{
    private readonly (Regex Pattern, string Replacement)[] _rules;
    private readonly Regex _segment;
    private readonly string _own;
    private readonly string? _ownRoot;

    public BugRedactor(string? profilePath, string? userName, string? machineName, IEnumerable<string>? profiles = null)
    {
        var rules = new List<(Regex, string)>();
        var profile = profilePath?.TrimEnd('\\', '/');
        _own = profile?.Split('\\', '/')[^1] ?? "";
        _ownRoot = string.IsNullOrEmpty(profile) || profile.Length == _own.Length ? null : NormalizeRoot(profile[..^_own.Length]);
        _segment = Segment(string.IsNullOrWhiteSpace(profile) ? profiles ?? [] : (profiles ?? []).Append(profile));
        if (!string.IsNullOrWhiteSpace(profile))
        {
            foreach (var form in new[] { profile, profile.Replace("\\", "\\\\"), profile.Replace('\\', '/') }.Distinct())
                rules.Add((new Regex(Regex.Escape(form) + ComponentEnd, Options), "%USERPROFILE%"));
        }
        var machine = machineName?.Trim();
        var user = userName?.Trim();
        foreach (var (value, replacement) in new[] { (machine, PcName), (user, User) })
        {
            if (value is not { Length: >= 2 }) continue;
            rules.Add((Word(value), replacement));
            var escaped = JsonEncodedText.Encode(value).ToString();
            if (escaped != value) rules.Add((Word(escaped), replacement));
        }
        var userForm = user is { Length: 1 } ? Regex.Escape(user) : user is { Length: > 1 } ? User : null;
        if (machine is { Length: 1 })
        {
            var name = Regex.Escape(machine);
            rules.Add((new Regex(@"(?<=(?<![\\/])(?:(?:\\\\)+|//))" + name + @"(?=[\\/])", Options), PcName));
            if (userForm is not null)
                rules.Add((new Regex(@"(?<![\p{L}\p{N}_.\\/-])" + name + @"(?=\\+(?:" + userForm + @")(?![\p{L}\p{N}_]))", Options), PcName));
        }
        if (user is { Length: 1 })
        {
            var separator = "bfnrtu".Contains(char.ToLowerInvariant(user[0])) ? @"(?:\\\\)+" : @"\\+";
            rules.Add((new Regex(@"(?<=(?<![\p{L}\p{N}_.-])(?:" + PcName + "|AzureAD)" + separator + ")" + Regex.Escape(user) + @"(?![\p{L}\p{N}_])", Options), User));
        }
        rules.Add((AccountSid, Sid));
        _rules = rules.ToArray();
    }

    public static BugRedactor Current()
        => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.UserName, Environment.MachineName, RegisteredProfiles());

    public static IReadOnlyList<string> RegisteredProfiles()
    {
        if (!OperatingSystem.IsWindows()) return [];
        try
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var list = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList");
            return RegisteredProfiles(list);
        }
        catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException)
        {
            return [];
        }
    }

    public static IReadOnlyList<string> RegisteredProfiles(RegistryKey? list)
    {
        var paths = new List<string>();
        if (list is null) return paths;
        void Add(RegistryKey key, string name)
        {
            if (key.GetValue(name) is string { Length: > 0 } value) paths.Add(value.Trim());
        }
        try
        {
            Add(list, "Default");
            Add(list, "Public");
            foreach (var sid in list.GetSubKeyNames().Where(name => AccountProfile.IsMatch(name)))
            {
                try
                {
                    using var account = list.OpenSubKey(sid);
                    if (account is null) continue;
                    Add(account, "ProfileImagePath");
                    Add(account, "CentralProfile");
                }
                catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException)
                {
                }
            }
        }
        catch (Exception error) when (error is System.Security.SecurityException or UnauthorizedAccessException or System.IO.IOException)
        {
        }
        return paths;
    }

    public string Redact(string text)
    {
        text = text.Replace(User, @"\u0001").Replace(PcName, @"\u0002").Replace(Sid, @"\u0003");
        text = text.Replace("<user>", User, StringComparison.OrdinalIgnoreCase).Replace("<pc-name>", PcName, StringComparison.OrdinalIgnoreCase).Replace("<sid>", Sid, StringComparison.OrdinalIgnoreCase);
        text = EncodedPaths(text);
        var changes = new List<(int Start, int End, string Value)>();
        string? previousSeparator = null;
        var previousBoundary = -1;
        var previousPrivate = false;
        var covered = new List<(int Start, int End)>();
        foreach (var match in Profiles(text))
        {
            covered.Add((match.Groups["root"].Index, match.Groups["run"].Index + match.Groups["run"].Length));
            var found = Profile(match, text, out var boundary, out var root, out var placeholder);
            if (found is null && !placeholder) continue;
            var separator = root[(match.Groups["sep"].Index - match.Groups["root"].Index)..];
            if (found is { } change && change.Value == "%USERPROFILE%" && previousPrivate && previousBoundary == change.Start && previousSeparator != separator)
                found = (change.Start, change.End, root + User);
            if (found is { } add) changes.Add(add);
            previousPrivate = placeholder || found is not { } kept || kept.Value.EndsWith(User, StringComparison.Ordinal) || previousPrivate && kept.Value == "%USERPROFILE%" && previousBoundary == kept.Start;
            previousSeparator = separator;
            previousBoundary = boundary;
        }
        var next = 0;
        var coveredEnd = -1;
        foreach (Match macro in Macro.Matches(text))
        {
            while (next < covered.Count && covered[next].Start <= macro.Index) coveredEnd = Math.Max(coveredEnd, covered[next++].End);
            if (macro.Index < coveredEnd) continue;
            var suffix = macro.Index + macro.Length;
            if (MacroSuffix(text, suffix) is { } end) changes.Add((macro.Index, end, User));
        }
        text = Replace(text, changes);
        foreach (var (pattern, replacement) in _rules) text = pattern.Replace(text, replacement);
        return text.Replace(User, "<user>").Replace(PcName, "<pc-name>").Replace(Sid, "<sid>");
    }

    private string EncodedPaths(string text)
    {
        if (!EncodedRootCharacter.IsMatch(text)) return text;
        var decoded = new StringBuilder(text.Length);
        var ends = new List<int>(text.Length);
        void Add(char value, int end)
        {
            decoded.Append(value);
            ends.Add(end);
        }
        for (var index = 0; index < text.Length;)
        {
            var slashes = Backslashes(text, index);
            var hex = index + slashes;
            if (slashes > 0 && Escaped(text, hex))
            {
                var unit = slashes & -slashes;
                for (var prefix = 0; prefix < slashes - unit; prefix++, index++) Add('\\', index + 1);
                var end = hex + 5;
                var value = (char)Convert.ToInt32(text.Substring(hex + 1, 4), 16);
                if (value == '<' && EncodedMarker(text, index, end, out var kind) is var markerEnd and >= 0)
                {
                    value = kind;
                    end = markerEnd;
                }
                if (value >= ' ' || value is '\u0001' or '\u0002' or '\u0003' && end > hex + 5)
                    Add(value, end);
                else
                    for (var cursor = index; cursor < end; cursor++) Add(text[cursor], cursor + 1);
                index = end;
            }
            else
            {
                var end = index + Math.Max(1, slashes);
                for (; index < end; index++) Add(text[index], index + 1);
            }
        }
        var view = decoded.ToString();
        var changes = new List<(int Start, int End, string Value)>();
        foreach (var match in Profiles(view))
        {
            var root = match.Groups["root"];
            var start = root.Index == 0 ? 0 : ends[root.Index - 1];
            if (ends[root.Index + root.Length - 1] - start == root.Length) continue;
            if (Profile(match, view, out _, out _, out _) is { } change && change.End > change.Start)
                changes.Add((change.Start == 0 ? 0 : ends[change.Start - 1], ends[change.End - 1], change.Value));
        }
        foreach (Match match in AccountSid.Matches(view))
        {
            var start = match.Index == 0 ? 0 : ends[match.Index - 1];
            var end = ends[match.Index + match.Length - 1];
            if (end - start > match.Length) changes.Add((start, end, Sid));
        }
        return Replace(text, changes);
    }

    private IEnumerable<Match> Profiles(string text)
    {
        using var urls = HttpUrls.Matches(text).Cast<Match>().GetEnumerator();
        var hasUrl = urls.MoveNext();
        var previousAccount = -1;
        foreach (Match match in _segment.Matches(text))
        {
            if (match.Groups["run"].Index == previousAccount) continue;
            while (hasUrl && urls.Current.Index + urls.Current.Length <= match.Index) hasUrl = urls.MoveNext();
            if (!match.Groups["network"].Success || !hasUrl || match.Index < urls.Current.Index)
            {
                previousAccount = match.Groups["run"].Index;
                yield return match;
            }
        }
    }

    private static string Replace(string text, List<(int Start, int End, string Value)> changes)
    {
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
        return text;
    }

    private (int Start, int End, string Value)? Profile(Match match, string input, out int boundaryEnd, out string root, out bool placeholderOnly)
    {
        root = match.Groups["root"].Value;
        placeholderOnly = false;
        var run = match.Groups["run"].Value;
        var runStart = match.Groups["run"].Index;
        var matchEnd = runStart + run.Length;
        boundaryEnd = matchEnd;
        var joinedDrive = matchEnd + 2 < input.Length && char.IsAsciiLetter(input[matchEnd]) && input[matchEnd + 1] == ':' && input[matchEnd + 2] is '\\' or '/';
        if (run.Length == 0) return joinedDrive ? (runStart, runStart, User) : null;
        var slashes = root.Length - root.TrimEnd('\\').Length;
        var control = 0;
        if (slashes > 0 && (slashes & (slashes - 1)) != 0)
        {
            var escape = slashes & -slashes;
            if (run[0] is 'n' or 'r' or 't' or 'b' or 'f')
            {
                if (run.Length == 1 || !Separates(input, matchEnd, 2 * escape)) return null;
                control = escape;
            }
            if (control > 0 || run.Length >= 5 && (run[0] is 'u' or 'U') && run.Skip(1).Take(4).All(Uri.IsHexDigit))
            {
                root = root[..^escape];
                runStart -= escape;
                run = new string('\\', escape) + run;
            }
        }
        var separator = root[(match.Groups["sep"].Index - match.Groups["root"].Index)..];
        if (separator[0] == '\\')
            for (int index = 0, count = 0; index < run.Length; index++)
            {
                count = run[index] == '\\' ? count + 1 : 0;
                if (count == separator.Length) { run = run[..(index - count + 1)]; break; }
            }
        var decoded = new StringBuilder();
        var ends = new List<int>();
        var placeholderSeen = false;
        var macroTail = 0;
        if (control > 0)
        {
            decoded.Append(run[control]);
            ends.Add(control + 1);
        }
        for (var index = control > 0 ? control + 1 : 0; index < run.Length;)
        {
            if (placeholderSeen && run.AsSpan(index).StartsWith("%USERPROFILE%", StringComparison.OrdinalIgnoreCase))
            {
                var markerEnd = index;
                while (run.AsSpan(markerEnd).StartsWith("%USERPROFILE%", StringComparison.OrdinalIgnoreCase)) markerEnd += 13;
                if (markerEnd == run.Length) { macroTail = markerEnd; break; }
                if (run[markerEnd] == '\\')
                {
                    var hex = markerEnd;
                    while (run[hex] == '\\') hex++;
                    var after = (char)Convert.ToInt32(run.Substring(hex + 1, 4), 16);
                    if (after is '\\' or '/' or '"' or ':' or '>' or '|' or '?' or '*' or < ' '
                        || after == '<' && EncodedMarker(run, markerEnd, hex + 5, out _) < 0) break;
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
            var encodedMarker = false;
            if (c == '<' && next > index + 1 && EncodedMarker(run, index, next, out var kind) is var markerNext and >= 0)
            {
                c = kind; next = markerNext; encodedMarker = true;
            }
            if (c is '\\' or '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' || c < ' ' && !((next == index + 1 || encodedMarker) && c is '\u0001' or '\u0002' or '\u0003')) break;
            if ((next == index + 1 || encodedMarker) && c is '\u0001' or '\u0002' or '\u0003') placeholderSeen = true;
            decoded.Append(c); index = next; ends.Add(index);
        }
        var text = decoded.ToString();
        matchEnd = runStart + (ends.Count == 0 ? 0 : ends[^1]);
        boundaryEnd = macroTail > 0 ? runStart + macroTail : matchEnd;
        joinedDrive = matchEnd + 2 < input.Length && char.IsAsciiLetter(input[matchEnd]) && input[matchEnd + 1] == ':' && input[matchEnd + 2] is '\\' or '/';
        if (text.Length == 0 || text is "." or ".." || SharedProfiles.Contains(text) && !joinedDrive && !run[..ends[^1]].Contains('\\')) return null;
        if (text.TrimEnd(' ', '.', ',', ';', '!', ')', ']', '}', '\'') is { Length: 1 } placeholder && placeholder[0] is '\u0001' or '\u0002' or '\u0003') { placeholderOnly = true; return (runStart, runStart + ends[0], placeholder); }
        var rootIndex = match.Groups["root"].Index;
        var device = rootIndex;
        while (device > 0 && input[device - 1] == '\\') device--;
        var escapedRoot = rootIndex > 0 && input[rootIndex - 1] == '\\' && !(device > 1 && input[device - 1] is '?' or '.' && input[device - 2] is '\\' or '?')
            || rootIndex >= 5 && input[rootIndex - 5] == '\\' && (input[rootIndex - 4] == 'u' || input[rootIndex - 4] == 'U')
                && Uri.IsHexDigit(input[rootIndex - 3]) && Uri.IsHexDigit(input[rootIndex - 2]) && Uri.IsHexDigit(input[rootIndex - 1]);
        if (!escapedRoot && text.Equals(_own, StringComparison.OrdinalIgnoreCase) && NormalizeRoot(root) == _ownRoot)
            return (rootIndex, runStart + ends[^1], "%USERPROFILE%");
        var length = text.Length;
        while (length > 0 && text[length - 1] is ' ' or '.' or ',' or ';' or '!' or ')' or ']' or '}' or '\'') length--;
        if (length == 0) length = text.Length;
        return (runStart, runStart + ends[length - 1], User);
    }

    private static int EncodedMarker(string run, int index, int next, out char kind)
    {
        var prefix = next - index - 5;
        var name = new StringBuilder();
        var cursor = next;
        kind = '\0';
        while (kind == '\0' && cursor < run.Length)
        {
            if (run[cursor] != '\\') name.Append(char.ToLowerInvariant(run[cursor++]));
            else
            {
                var hex = cursor + Backslashes(run, cursor);
                if (hex - cursor != prefix || !Escaped(run, hex)) return -1;
                name.Append(char.ToLowerInvariant((char)Convert.ToInt32(run.Substring(hex + 1, 4), 16)));
                cursor = hex + 5;
            }
            var value = name.ToString();
            kind = value == "user" ? User[0] : value == "pc-name" ? PcName[0] : value == "sid" ? Sid[0] : '\0';
            if (kind == '\0' && !"user".StartsWith(value, StringComparison.Ordinal) && !"pc-name".StartsWith(value, StringComparison.Ordinal) && !"sid".StartsWith(value, StringComparison.Ordinal)) return -1;
        }
        if (kind == '\0') return -1;
        var end = cursor + Backslashes(run, cursor);
        return end - cursor == prefix && end + 5 <= run.Length
            && run.AsSpan(end, 5).Equals("u003e", StringComparison.OrdinalIgnoreCase) ? end + 5 : -1;
    }

    private static bool Separates(string input, int index, int unit)
    {
        if (index >= input.Length) return false;
        if (input[index] == '/') return true;
        var count = Backslashes(input, index);
        if (count == 0) return false;
        if (count >= unit || index + count == input.Length) return true;
        var next = input[index + count];
        return !(next is 'b' or 'f' or 'n' or 'r' or 't' or 'u' && (count & (count - 1)) == 0 || next == '"' && (count & (count + 1)) == 0);
    }

    private static int? MacroSuffix(string text, int start)
    {
        if (start >= text.Length || text[start] is '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' || text[start] < ' ') return null;
        var lead = Backslashes(text, start);
        if (lead > 0 && !Escaped(text, start + lead)) return null;
        var end = start;
        var named = -1;
        while (end < text.Length)
        {
            var slashes = Backslashes(text, end);
            if (slashes > 0)
            {
                if (!Escaped(text, end + slashes) || lead > 0 && slashes != lead
                    || (char)Convert.ToInt32(text.Substring(end + slashes + 1, 4), 16) is '\\' or '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' or < ' ') break;
                end += slashes + 5;
                named = end;
                continue;
            }
            var c = text[end];
            if (c is '/' or '"' or ':' or '<' or '>' or '|' or '?' or '*' || c < ' '
                || end + 2 < text.Length && char.IsAsciiLetter(c) && text[end + 1] == ':' && text[end + 2] is '\\' or '/'
                || end > start && text.AsSpan(end).StartsWith("%USERPROFILE%", StringComparison.OrdinalIgnoreCase)) break;
            end++;
            if (c is not (' ' or '.' or ',' or ';' or '!' or ')' or ']' or '}' or '\'')) named = end;
        }
        if (named < 0) return null;
        var slash = Backslashes(text, end);
        if (lead > 0) return slash >= 2 * lead ? named : null;
        var first = text[start];
        var glued = !char.IsWhiteSpace(first) && first is not (',' or ';' or '!' or ')' or ']' or '}' or '\'')
            && (first != '.' || start + 1 < text.Length && char.IsLetterOrDigit(text[start + 1]));
        var separated = end < text.Length && (text[end] == '/' || slash > 0 && (end + slash == text.Length || text[end + slash] != '"'));
        return glued || separated ? named : null;
    }

    private static int Backslashes(string text, int index)
    {
        var end = index;
        while (end < text.Length && text[end] == '\\') end++;
        return end - index;
    }

    private static bool Escaped(string text, int index)
        => index + 5 <= text.Length && text[index] is 'u' or 'U' && text.AsSpan(index + 1, 4).ToString().All(Uri.IsHexDigit);

    private static Regex Segment(IEnumerable<string> profiles)
    {
        var roots = new HashSet<string>(StringComparer.Ordinal);
        var exact = new HashSet<string>(StringComparer.Ordinal);
        foreach (var path in profiles)
        {
            var trimmed = path.Trim();
            var parts = trimmed.Split('\\', '/');
            var named = parts.Where(part => part.Length > 0).ToArray();
            string head;
            var drive = parts.Length > 1 && parts[0].Length == 2 && char.IsAsciiLetter(parts[0][0]) && parts[0][1] == ':';
            if (drive) head = Regex.Escape(parts[0]);
            else if (trimmed.StartsWith(@"\\", StringComparison.Ordinal) && named.Length > 0 && named[0] is not ("?" or "."))
            {
                head = @"(?<network>(?<![\\/:])(?:\\{2,}(?:[?.]\\+UNC[\\/]+)?|\\+\?\?\\+UNC[\\/]+|/{2,}|(?:\\+/){2,}))" + Regex.Escape(named[0]);
            }
            else continue;
            if (named.Length < 2 || named.Skip(1).Any(part => part is "." or "..")) continue;
            var parent = named[1..^1];
            var pattern = head + string.Concat(parent.Select(part => @"(?>[\\/]+)" + Regex.Escape(part)));
            if (drive && parent.Length == 1 && ProfileFolders.IsMatch(parent[0])) continue;
            if (parent.Length == 0)
                exact.Add("(?<root>" + pattern + SegmentSeparator + ")(?=" + Regex.Escape(named[^1]) + ComponentEnd + ")");
            else roots.Add(pattern);
        }
        if (roots.Count == 0 && exact.Count == 0) return ProfileSegment;
        var alternatives = roots.OrderByDescending(root => root.Length).Append(StandardRoots);
        return new("(?=(?:(?<root>(?:" + string.Join("|", alternatives) + ")" + SegmentSeparator + ")" + string.Concat(exact.Select(item => "|" + item)) + ")" + SegmentRun + ")", Options);
    }

    private static string NormalizeRoot(string path)
        => Regex.Replace(Regex.Replace(path.Replace('/', '\\'), @"\\+", "\\"), @"\\\.(?=\\|$)", "").TrimEnd('\\').ToUpperInvariant();

    private const string User = "\u0001", PcName = "\u0002", Sid = "\u0003";
    private const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private const string ComponentEnd = @"(?=[\\/""\x00-\x1F:<>|?*]|$)";
    private const string StandardRoots = @"[A-Za-z]:(?>[\\/]+)(?:Users|Documents and Settings)|(?<network>(?<![\\/]|[A-Za-z]:)(?>[\\/]+)(?:Users|Documents and Settings))";
    private const string SegmentSeparator = @"(?>(?:\\+(?=/)|/+(?=(?>\\+)(?!u[0-9A-Fa-f]{4}))|[\\/]+\.(?=[\\/]))*)(?<sep>(?>\\+|/+))";
    private const string SegmentRun = @"(?<run>(?>(?:(?!\k<sep>)\\+u[0-9A-Fa-f]{4}|(?![A-Za-z]:[\\/])[^\\/""\x00-\x1F:<>|?*])*)(?>[\u0001-\u0003](?:(?!\k<sep>)\\+u[0-9A-Fa-f]{4}|(?![A-Za-z]:[\\/])[^\\/""\x00-\x1F:<>|?*])*)*)";
    private static readonly HashSet<string> SharedProfiles = new(["Public", "Default", "Default User", "All Users"], StringComparer.OrdinalIgnoreCase);
    private static readonly Regex ProfileFolders = new(@"\A(?:Users|Documents and Settings)\z", Options);
    private static readonly Regex AccountProfile = new(@"\AS-1-(?:5-21|12-1)(?:-\d+)+(?:\.bak)?\z", Options);
    private static readonly Regex AccountSid = new(@"S-1-(?:5-21(?:-\d+){3,4}|12-1(?:-\d+){1,4})", Options);
    private static readonly Regex EncodedRootCharacter = new(@"\\u(?!003[ce]|0022)[0-9A-Fa-f]{4}", Options);
    private static readonly Regex HttpUrls = new(@"https?:(?:\\*/){2}(?:\\+/|[^\s\\""'<>])*", Options);
    private static readonly Regex Macro = new("(?:%USERPROFILE%)+", Options);
    private static readonly Regex ProfileSegment = new("(?=(?<root>(?:" + StandardRoots + ")" + SegmentSeparator + ")" + SegmentRun + ")", Options);

    private static Regex Word(string value)
        => new(@"(?<![\p{L}\p{N}_])" + Regex.Escape(value) + @"(?![\p{L}\p{N}_])", Options);
}
