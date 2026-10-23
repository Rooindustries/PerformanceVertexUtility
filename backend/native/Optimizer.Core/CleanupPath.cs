#nullable enable
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

internal sealed class CleanupPath
{
    private const string Breaks = "\"';:|<>*?\\x00-\\x1f";
    private readonly string? _existing;
    private readonly string[] _tail = [];
    private (Regex Named, Regex Listed, string[] Leaves)? _patterns;

    public CleanupPath(string path)
    {
        Lexical = Normalize(path);
        var tail = new List<string>();
        for (var current = Lexical; ;)
        {
            var walked = NativeFiles.ResolvedPath(current);
            if (tail.Count == 0) Walk = walked.Walk;
            if (walked.Path is not null) { _existing = walked.Path; break; }
            if (walked.Walk != NativeFiles.PathWalk.Absent || Path.GetDirectoryName(current) is not { Length: > 0 } parent) break;
            tail.Insert(0, Path.GetFileName(current));
            current = parent;
        }
        string? resolved = null;
        if (_existing is not null) { _tail = tail.ToArray(); resolved = _tail.Length == 0 ? _existing : string.Join('\\', [_existing.TrimEnd('\\'), .. _tail]); }
        Forms = new[] { Lexical, resolved }.OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public string Lexical { get; }
    public NativeFiles.PathWalk Walk { get; }
    public string[] Forms { get; }

    public bool ReferencedBy(string text) => Lexical.Length >= 4 && Search(Patterns().Named, text);
    public bool PossiblyReferencedBy(string text) => Lexical.Length >= 4 && Search(Patterns().Listed, text);
    public bool Overlaps(CleanupPath other) => Forms.Any(form => other.Forms.Any(peer => Within(form, peer) || Within(peer, form)));

    public static string Normalize(string path)
    {
        var text = RuntimeEnvironment.ExpandUserVariables(path.Trim().Trim('"').Trim()).Replace('/', '\\');
        if (text.StartsWith(@"\\?\", StringComparison.Ordinal) && !text.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) text = text[4..];
        if (!text.Contains('\0') && Path.IsPathFullyQualified(text))
            try { text = Path.GetFullPath(text); }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { }
        var root = Path.GetPathRoot(text) ?? "";
        var trimmed = text.TrimEnd('\\');
        return trimmed.Length < root.Length ? root : trimmed;
    }

    public static bool Within(string path, string root) => !string.IsNullOrWhiteSpace(root) &&
        (string.Equals(path.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));

    private bool Search(Regex pattern, string text)
    {
        text = text.Replace('/', '\\');
        return Patterns().Leaves.Any(leaf => text.Contains(leaf, StringComparison.OrdinalIgnoreCase)) && pattern.IsMatch(text);
    }

    private (Regex Named, Regex Listed, string[] Leaves) Patterns()
    {
        if (_patterns is { } built) return built;
        var spellings = new List<string[][]> { Parts(Lexical).Select(part => new[] { part }).ToArray() };
        if (_existing is not null)
        {
            var longParts = Parts(_existing);
            var shortParts = ShortName(_existing) is { } brief ? Parts(brief) : longParts;
            if (shortParts.Length != longParts.Length) shortParts = longParts;
            spellings.Add([.. longParts.Select((part, index) => new[] { part, shortParts[index] }), .. _tail.Select(part => new[] { part })]);
        }
        var any = "(?:" + string.Join("|", spellings.Select(parts => string.Join(@"\\+", parts.Select(names => "(?:" + string.Join("|", names.Distinct(StringComparer.OrdinalIgnoreCase).Select(Regex.Escape)) + ")")))) + ")";
        const RegexOptions options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
        _patterns = (new("(?<=^|[@\"'=\\s])" + any + "(?=[\\\\\"'\\s]|$)", options, TimeSpan.FromMilliseconds(50)),
            new("(?<![\\p{L}\\p{N}])" + any + "(?=$|[\\\\\\s" + Breaks + "]|,(?![^\\\\," + Breaks + "]*\\\\))", options, TimeSpan.FromMilliseconds(50)),
            spellings.SelectMany(parts => parts[^1]).Distinct(StringComparer.OrdinalIgnoreCase).ToArray());
        return _patterns.Value;
    }

    private static string[] Parts(string path) => path.TrimEnd('\\').Split('\\');

    private static string? ShortName(string path)
    {
        var buffer = new StringBuilder(1024);
        var length = GetShortPathName(NativeFiles.Extended(path), buffer, (uint)buffer.Capacity);
        if (length >= buffer.Capacity) { buffer = new StringBuilder((int)length + 1); length = GetShortPathName(NativeFiles.Extended(path), buffer, (uint)buffer.Capacity); }
        return length == 0 || length >= buffer.Capacity ? null : NativeFiles.Normalize(buffer.ToString());
    }

    [DllImport("kernel32.dll", EntryPoint = "GetShortPathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetShortPathName(string longPath, StringBuilder shortPath, uint length);
}
