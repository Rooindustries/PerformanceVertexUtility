#nullable enable
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public sealed record FirmwareOption(string Value, string Label);
public sealed record FirmwareQuestion(string Id, string Name, string Help, string Current, string Kind,
    int Width, FirmwareOption[] Options, string Context, string Text, string StorageGuid = "", string StorageName = "")
{
    public string DisplayValue(string value) => Options.FirstOrDefault(o => o.Value == value)?.Label ?? value;
}

public sealed record FirmwareExcludedQuestion(string Name, string Help, string Reason);

public sealed class FirmwareScript
{
    private static readonly Regex QuestionStart = new(@"(?m)^[ \t]*Setup Question[ \t]*=", RegexOptions.CultureInvariant);
    private static readonly Regex LayoutName = new(@"^(?<prefix>[ \t]*(?://[ \t]*)?Setup Question[ \t]*=)(?<name>.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex LayoutValue = new(@"^(?<prefix>[ \t]*(?://[ \t]*)?Value[ \t]*=)", RegexOptions.CultureInvariant);
    private static readonly Regex LayoutSelection = new(@"\*(?=\[[0-9A-Fa-f]+\])", RegexOptions.CultureInvariant);
    private static readonly Regex Choice = new(@"(?m)^(?<prefix>[ \t]*(?:Options[ \t]*=[ \t]*)?)(?<selected>\*)?\[(?<value>[0-9A-Fa-f]+)\](?<label>[^\r\n]*)", RegexOptions.CultureInvariant);
    private readonly Encoding _encoding;
    private readonly byte[] _preamble;
    private readonly string _header;
    private readonly Dictionary<string, QuestionSource> _sources = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _positions = new(StringComparer.Ordinal);
    private readonly string _layout;
    private readonly string _names;
    public string Text { get; }
    public string Crc { get; }
    public IReadOnlyList<FirmwareQuestion> Questions { get; }
    public IReadOnlyList<FirmwareExcludedQuestion> ExcludedQuestions { get; }

    public FirmwareScript(byte[] bytes)
    {
        if (bytes.Length == 0 || bytes.Length > 32 * 1024 * 1024) throw new InvalidDataException("The BIOS export is empty or too large.");
        (_encoding, _preamble) = bytes.AsSpan().StartsWith(new byte[] { 0xff, 0xfe }) ? (Encoding.Unicode, new byte[] { 0xff, 0xfe })
            : bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff }) ? (Encoding.BigEndianUnicode, new byte[] { 0xfe, 0xff })
            : bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? (Encoding.UTF8, new byte[] { 0xef, 0xbb, 0xbf })
            : (Encoding.Latin1, Array.Empty<byte>());
        Text = _encoding.GetString(bytes, _preamble.Length, bytes.Length - _preamble.Length);
        var crc = Regex.Matches(Text, @"(?mi)^[ \t]*HIICrc32[ \t]*=[ \t]*([0-9a-f]{1,8})[ \t]*\r*$");
        if (crc.Count != 1) throw new InvalidDataException("The export needs one HII checksum. Export again with SCEWIN's verbose option.");
        Crc = crc[0].Groups[1].Value.PadLeft(8, '0').ToUpperInvariant();
        var lines = SplitLines(Text);
        var starts = QuestionStart.Matches(Text);
        var questionLines = new HashSet<int>(starts.Select(match => LineFor(lines, match.Index)));
        var contexts = BuildContexts(Text, lines, questionLines);
        var headerLine = lines.FindIndex(line => IsContextStart(line.Body));
        var firstQuestion = starts.Count == 0 ? Text.Length : starts[0].Index;
        var bodyStart = headerLine >= 0 ? lines[headerLine].Start : firstQuestion;
        _header = NativeHeader(Text[..bodyStart], NewLine(Text));
        (_layout, _names) = Layout(Text[bodyStart..]);
        var questions = new List<FirmwareQuestion>();
        var excluded = new List<FirmwareExcludedQuestion>();
        for (var i = 0; i < starts.Count; i++)
        {
            var begin = starts[i].Index;
            var lineIndex = LineFor(lines, begin);
            var end = FindBlockEnd(Text, lines, lineIndex, questionLines);
            var block = Text[begin..end];
            var nativeBlock = NormalizeLineEndings(block, NewLine(Text));
            var context = contexts[lineIndex];
            var storage = StorageMetadata(context.Import);
            var name = Field(block, "Setup Question");
            var token = Field(block, "Token");
            var offset = Field(block, "Offset");
            var widthText = Field(block, "Width");
            if (name.Length == 0 || !Hex(token) || !Hex(offset) || !int.TryParse(widthText, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var width) || width is < 1 or > 8)
            {
                if (name.Length > 0) excluded.Add(new(name, Field(block, "Help String"), "This is text or a data block, not a single value SCEWIN can write."));
                continue;
            }
            var choices = Choice.Matches(block);
            var options = choices.Select(m => new FirmwareOption(m.Groups["value"].Value.ToUpperInvariant(), Clean(m.Groups["label"].Value))).ToArray();
            var selected = choices.Where(m => m.Groups["selected"].Success).ToArray();
            string kind, current;
            if (options.Length > 1 && selected.Length == 1 && options.Select(o => o.Value).Distinct().Count() == options.Length)
            { kind = "choice"; current = selected[0].Groups["value"].Value.ToUpperInvariant(); }
            else if (choices.Count == 0 && Regex.IsMatch(Field(block, "Value"), @"^<[0-9]+>$"))
            { kind = "decimal"; current = Field(block, "Value").Trim('<', '>'); }
            else if (choices.Count == 0 && Hex(Field(block, "Value")))
            { kind = "hex"; current = Field(block, "Value").ToUpperInvariant(); }
            else
            {
                excluded.Add(new(name, Field(block, "Help String"), options.Length > 1 && selected.Length != 1 ? "The export does not show one selected value for this setting."
                    : options.Length > 1 ? "Two of this setting's choices share the same value, so a choice cannot be written reliably."
                    : "The export does not give this setting a value SCEWIN can write."));
                continue;
            }
            var id = OperationFiles.Hash(Encoding.UTF8.GetBytes(context.Public + "\n" + token.ToUpperInvariant() + ":" + offset.ToUpperInvariant() + ":" + name));
            questions.Add(new(id, name, Field(block, "Help String"), current, kind, width, options, context.Public, nativeBlock, storage.Guid, storage.Name));
            var location = string.Join("\n", context.Public, token.ToUpperInvariant(), offset.ToUpperInvariant(), width.ToString(CultureInfo.InvariantCulture), storage.Guid, storage.Name);
            if (!_sources.TryAdd(id, new QuestionSource(NormalizeLineEndings(context.Import, NewLine(Text)), nativeBlock, location)))
                throw new InvalidDataException("The export contains ambiguous duplicate settings. Use a board-specific SCEWIN package.");
            _positions[id] = questions.Count - 1;
        }
        if (questions.Count == 0) throw new InvalidDataException("No editable choices or numeric settings were found in this BIOS export.");
        if (questions.Select(q => q.Id).Distinct().Count() != questions.Count) throw new InvalidDataException("The export contains ambiguous duplicate settings. Use a board-specific SCEWIN package.");
        Questions = questions;
        ExcludedQuestions = excluded;
    }

    private static Dictionary<int, ContextSnapshot> BuildContexts(string text, IReadOnlyList<SourceLine> lines, HashSet<int> questionLines)
    {
        var contexts = new Dictionary<int, ContextSnapshot>();
        var setHeader = new List<int>();
        var formHeader = new List<int>();
        var setOpen = false;
        var formOpen = false;
        for (var i = 0; i < lines.Count; i++)
        {
            var body = lines[i].Body;
            if (body == "// FORM SET")
            {
                setHeader = [i];
                formHeader = [];
                setOpen = true;
                formOpen = false;
                continue;
            }
            if (body == "// FORM")
            {
                formHeader = [i];
                setOpen = false;
                formOpen = true;
                continue;
            }
            if (questionLines.Contains(i))
            {
                var publicSet = ContextText(lines, setHeader);
                var publicForm = ContextText(lines, formHeader);
                contexts[i] = new ContextSnapshot(publicSet + (publicSet.Length > 0 && publicForm.Length > 0 ? "\n" : "") + publicForm,
                    ImportContext(text, lines, setHeader, formHeader, i));
                setOpen = false;
                formOpen = false;
                continue;
            }
            if (!IsCommentOrBlank(body)) continue;
            if (setOpen) setHeader.Add(i);
            if (formOpen) formHeader.Add(i);
        }
        return contexts;
    }

    private static string ImportContext(string text, IReadOnlyList<SourceLine> lines, IReadOnlyList<int> setHeader,
        IReadOnlyList<int> formHeader, int questionLine)
    {
        var output = new StringBuilder();
        if (setHeader.Count > 0) output.Append(Source(text, lines, TrimTrailingBlankLines(lines, setHeader)));
        if (formHeader.Count > 0)
        {
            var variableStart = VariableStart(lines, formHeader);
            var baseForm = variableStart >= 0 ? formHeader.Take(variableStart).ToArray() : formHeader;
            output.Append(Source(text, lines, baseForm));
        }
        var variable = VariableContext(text, lines, questionLine);
        if (variable.Length > 0)
        {
            if (output.Length > 0 && !EndsWithLineBreak(output)) output.Append(NewLine(text));
            output.Append(variable);
        }
        return NormalizeLineEndings(output.ToString(), NewLine(text));
    }

    private static int VariableStart(IReadOnlyList<SourceLine> lines, IReadOnlyList<int> formHeader)
    {
        for (var i = formHeader.Count - 2; i >= 0; i--)
        {
            if (!IsGuid(lines[formHeader[i]].Body)) continue;
            if (formHeader.Skip(i + 1).Any(item => IsVariable(lines[item].Body))) return i;
        }
        return -1;
    }

    private static string VariableContext(string text, IReadOnlyList<SourceLine> lines, int questionLine)
    {
        var variable = -1;
        var guid = -1;
        for (var i = questionLine - 1; i >= 0; i--)
        {
            if (!IsCommentOrBlank(lines[i].Body)) break;
            if (variable < 0 && IsVariable(lines[i].Body)) variable = i;
            else if (variable >= 0 && IsGuid(lines[i].Body)) { guid = i; break; }
        }
        return guid >= 0 ? text[lines[guid].Start..lines[questionLine].Start] : "";
    }

    private static (string Guid, string Name) StorageMetadata(string context)
    {
        var guid = Regex.Matches(context, @"(?m)^[ \t]*//[ \t]*GUID[ \t]*=[ \t]*([^\r\n]*)").Cast<Match>().LastOrDefault()?.Groups[1].Value.Trim() ?? "";
        var name = Regex.Matches(context, @"(?m)^[ \t]*//[ \t]*Variable[ \t]*=[ \t]*([^\r\n]*)").Cast<Match>().LastOrDefault()?.Groups[1].Value.Trim() ?? "";
        return (guid, name);
    }

    private static string ContextText(IReadOnlyList<SourceLine> lines, IReadOnlyList<int> indexes)
        => string.Join("\n", indexes.Select(index => lines[index].Body)).Trim();

    private static int FindBlockEnd(string text, IReadOnlyList<SourceLine> lines, int questionLine, HashSet<int> questionLines)
    {
        for (var i = questionLine + 1; i < lines.Count; i++)
            if (questionLines.Contains(i) || IsQuestionBoundary(lines[i].Body)) return lines[i].Start;
        return text.Length;
    }

    private static bool IsQuestionBoundary(string body)
    {
        var value = body.TrimStart();
        return value.StartsWith("// FORM", StringComparison.Ordinal) || value.StartsWith("// SUBTITLE", StringComparison.Ordinal)
            || value.StartsWith("// GUID", StringComparison.Ordinal) || value.StartsWith("// Variable", StringComparison.Ordinal)
            || value.StartsWith("// Setup Question", StringComparison.Ordinal) || value.StartsWith("// Help String", StringComparison.Ordinal)
            || value.StartsWith("// Token", StringComparison.Ordinal) || value.StartsWith("// Offset", StringComparison.Ordinal)
            || value.StartsWith("// Width", StringComparison.Ordinal) || value.StartsWith("// BIOS Default", StringComparison.Ordinal)
            || value.StartsWith("// Options", StringComparison.Ordinal) || value.StartsWith("// Value", StringComparison.Ordinal);
    }

    private static bool IsContextStart(string body)
        => body is "// FORM SET" or "// FORM" || IsGuid(body) || body.TrimStart().StartsWith("// SUBTITLE", StringComparison.Ordinal);

    private static bool IsGuid(string body) => body.TrimStart().StartsWith("// GUID", StringComparison.Ordinal);
    private static bool IsVariable(string body) => body.TrimStart().StartsWith("// Variable", StringComparison.Ordinal);
    private static bool IsCommentOrBlank(string body) => string.IsNullOrWhiteSpace(body) || body.TrimStart().StartsWith("//", StringComparison.Ordinal);

    private static List<int> TrimTrailingBlankLines(IReadOnlyList<SourceLine> lines, IReadOnlyList<int> indexes)
    {
        var last = indexes.Count;
        while (last > 0 && string.IsNullOrWhiteSpace(lines[indexes[last - 1]].Body)) last--;
        return indexes.Take(last).ToList();
    }

    private static string Source(string text, IReadOnlyList<SourceLine> lines, IReadOnlyList<int> indexes)
        => indexes.Count == 0 ? "" : text[lines[indexes[0]].Start..lines[indexes[^1]].End];

    private static bool EndsWithLineBreak(StringBuilder value)
        => value.Length > 0 && (value[^1] == '\n' || value[^1] == '\r');

    private static string NewLine(string text)
    {
        var index = text.IndexOf('\n');
        return index > 0 && text[index - 1] == '\r' ? "\r\n" : "\n";
    }

    private static string NormalizeLineEndings(string value, string newline)
        => value.Replace("\r\r\n", "\r\n", StringComparison.Ordinal).Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Replace("\n", newline, StringComparison.Ordinal);

    private static string NativeHeader(string value, string newline)
    {
        var normalized = NormalizeLineEndings(value, newline);
        var crc = Regex.Match(normalized, @"(?mi)^[ \t]*HIICrc32[ \t]*=[^\r\n]*");
        if (!crc.Success) return normalized;
        var lineStart = normalized.LastIndexOf('\n', crc.Index) + 1;
        var lineEnd = normalized.IndexOf('\n', crc.Index);
        if (lineEnd < 0) lineEnd = normalized.Length;
        var prefix = normalized[..lineStart].TrimEnd('\r', '\n');
        var line = normalized[crc.Index..lineEnd].TrimEnd('\r');
        return prefix + newline + newline + line + newline + newline;
    }

    private static List<SourceLine> SplitLines(string text)
    {
        var lines = new List<SourceLine>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\r' && text[i] != '\n') continue;
            var bodyEnd = i;
            var end = i + 1;
            if (text[i] == '\r' && end < text.Length && text[end] == '\n') end++;
            lines.Add(new SourceLine(start, end, text[start..bodyEnd]));
            start = end;
            i = end - 1;
        }
        if (start < text.Length) lines.Add(new SourceLine(start, text.Length, text[start..]));
        return lines;
    }

    private static int LineFor(IReadOnlyList<SourceLine> lines, int index)
    {
        var low = 0;
        var high = lines.Count - 1;
        while (low <= high)
        {
            var middle = low + ((high - low) / 2);
            if (index < lines[middle].Start) high = middle - 1;
            else if (index >= lines[middle].End) low = middle + 1;
            else return middle;
        }
        throw new InvalidDataException("The BIOS export contains an invalid line boundary.");
    }

    private static bool Hex(string value) => Regex.IsMatch(value, "^[0-9A-Fa-f]+$");
    private static string Clean(string text) => text.Split("//", 2)[0].Trim();
    private static string Field(string block, string name) => Clean(Regex.Match(block, @"(?m)^[ \t]*" + Regex.Escape(name) + @"[ \t]*=[ \t]*([^\r\n]*)").Groups[1].Value);

    public string Validate(FirmwareQuestion question, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new InvalidDataException(question.Name + ": choose or enter a value.");
        value = value.Trim();
        if (question.Kind == "choice")
        {
            value = value.ToUpperInvariant();
            if (!question.Options.Any(o => o.Value == value)) throw new InvalidDataException(question.Name + ": select one of the exported options.");
            return value;
        }
        var style = question.Kind == "decimal" ? NumberStyles.None : NumberStyles.AllowHexSpecifier;
        if (!ulong.TryParse(value, style, CultureInfo.InvariantCulture, out var number)
            || (question.Width < 8 && number >= (1ul << (question.Width * 8))))
            throw new InvalidDataException(question.Name + ": enter a valid " + (question.Kind == "decimal" ? "decimal" : "hexadecimal") + " value fitting " + question.Width + " byte(s).");
        return number.ToString(question.Kind == "decimal" ? "D" : "X", CultureInfo.InvariantCulture);
    }

    public byte[] Changes(IReadOnlyDictionary<string, string> selections)
    {
        if (selections.Count == 0) throw new InvalidDataException("Choose at least one changed setting.");
        var output = new StringBuilder(_header);
        foreach (var change in selections)
        {
            var question = Questions.SingleOrDefault(q => q.Id == change.Key) ?? throw new InvalidDataException("A selected setting is missing from the export.");
            var value = Validate(question, change.Value);
            if (value == Validate(question, question.Current)) throw new InvalidDataException("The review includes an unchanged setting.");
            var source = _sources[question.Id];
            var block = source.Block;
            if (question.Kind == "choice")
                block = Choice.Replace(block, m => m.Groups["prefix"].Value + (m.Groups["value"].Value.Equals(value, StringComparison.OrdinalIgnoreCase) ? "*" : "") + "[" + m.Groups["value"].Value + "]" + m.Groups["label"].Value);
            else
                block = Regex.Replace(block, @"(?m)^([ \t]*Value[ \t]*=[ \t]*)([^\r\n/]*)", m => m.Groups[1].Value + (question.Kind == "decimal" ? "<" + value + ">" : value) + " ");
            output.Append(source.Context).Append(block);
            if (!EndsWithLineBreak(output)) output.Append(NewLine(Text));
        }
        return _preamble.Concat(_encoding.GetBytes(output.ToString())).ToArray();
    }

    public bool SameValues(FirmwareScript other, IReadOnlyDictionary<string, string>? changes = null)
    {
        if (!SameLayout(other) || Questions.Count != other.Questions.Count) return false;
        return Questions.All(q => Counterpart(q, other) is { } actual
            && q.Kind == actual.Kind && q.Width == actual.Width && q.Options.SequenceEqual(actual.Options)
            && Validate(q, changes is not null && changes.TryGetValue(q.Id, out var value) ? value : q.Current) == other.Validate(actual, actual.Current));
    }

    public bool SameLayout(FirmwareScript other)
        => Crc == other.Crc || (_layout == other._layout && _names != other._names);

    public FirmwareQuestion? Counterpart(FirmwareQuestion question, FirmwareScript other)
    {
        if (!_positions.TryGetValue(question.Id, out var index)) return null;
        var candidate = Crc != other.Crc && SameLayout(other) ? (index < other.Questions.Count ? other.Questions[index] : null)
            : other._positions.TryGetValue(question.Id, out var same) ? other.Questions[same] : null;
        return candidate is not null && _sources[question.Id].Location == other._sources[candidate.Id].Location
            && MaskNumbers(question.Name) == MaskNumbers(candidate.Name) && question.Kind == candidate.Kind
            && question.Options.SequenceEqual(candidate.Options) ? candidate : null;
    }

    private static (string Layout, string Names) Layout(string body)
    {
        var layout = new StringBuilder();
        var names = new StringBuilder();
        foreach (var line in SplitLines(body))
        {
            var name = LayoutName.Match(line.Body);
            if (name.Success)
            {
                names.Append(name.Groups["name"].Value).Append('\n');
                layout.Append(name.Groups["prefix"].Value).Append(MaskNumbers(name.Groups["name"].Value)).Append('\n');
                continue;
            }
            var value = LayoutValue.Match(line.Body);
            layout.Append(value.Success ? value.Groups["prefix"].Value : LayoutSelection.Replace(line.Body, "")).Append('\n');
        }
        return (OperationFiles.Hash(Encoding.UTF8.GetBytes(layout.ToString())), OperationFiles.Hash(Encoding.UTF8.GetBytes(names.ToString())));
    }

    public static string NamePattern(string name) => MaskNumbers(name.Trim());

    private static string MaskNumbers(string value) => Regex.Replace(value, @"[+-]?[0-9]+(?:\.[0-9]+)?", "#");

    private sealed record SourceLine(int Start, int End, string Body);
    private sealed record ContextSnapshot(string Public, string Import);
    private sealed record QuestionSource(string Context, string Block, string Location);
}
