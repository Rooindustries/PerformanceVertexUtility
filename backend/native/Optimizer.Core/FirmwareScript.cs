#nullable enable
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public sealed record FirmwareOption(string Value, string Label);
public sealed record FirmwareQuestion(string Id, string Name, string Help, string Current, string Kind,
    int Width, FirmwareOption[] Options, string Context, string Text)
{
    public string DisplayValue(string value) => Options.FirstOrDefault(o => o.Value == value)?.Label ?? value;
}

public sealed class FirmwareScript
{
    private static readonly Regex QuestionStart = new(@"(?m)^[ \t]*Setup Question[ \t]*=", RegexOptions.CultureInvariant);
    private static readonly Regex Choice = new(@"(?m)^(?<prefix>[ \t]*(?:Options[ \t]*=[ \t]*)?)(?<selected>\*)?\[(?<value>[0-9A-Fa-f]+)\](?<label>[^\r\n]*)", RegexOptions.CultureInvariant);
    private readonly Encoding _encoding;
    private readonly byte[] _preamble;
    public string Text { get; }
    public string Crc { get; }
    public IReadOnlyList<FirmwareQuestion> Questions { get; }

    public FirmwareScript(byte[] bytes)
    {
        if (bytes.Length == 0 || bytes.Length > 32 * 1024 * 1024) throw new InvalidDataException("The BIOS export is empty or too large.");
        (_encoding, _preamble) = bytes.AsSpan().StartsWith(new byte[] { 0xff, 0xfe }) ? (Encoding.Unicode, new byte[] { 0xff, 0xfe })
            : bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff }) ? (Encoding.BigEndianUnicode, new byte[] { 0xfe, 0xff })
            : bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? (Encoding.UTF8, new byte[] { 0xef, 0xbb, 0xbf })
            : (Encoding.Latin1, Array.Empty<byte>());
        Text = _encoding.GetString(bytes, _preamble.Length, bytes.Length - _preamble.Length);
        var crc = Regex.Matches(Text, @"(?mi)^[ \t]*HIICrc32[ \t]*=[ \t]*([0-9a-f]{8})[ \t]*\r*$");
        if (crc.Count != 1) throw new InvalidDataException("The export needs one HII checksum. Export again with SCEWIN's verbose option.");
        Crc = crc[0].Groups[1].Value.ToUpperInvariant();
        var starts = QuestionStart.Matches(Text);
        var questions = new List<FirmwareQuestion>();
        for (var i = 0; i < starts.Count; i++)
        {
            var begin = starts[i].Index;
            var end = i + 1 < starts.Count ? starts[i + 1].Index : Text.Length;
            var block = Text[begin..end];
            // Comments introducing the following form do not belong to this question.
            var nextContext = Regex.Match(block, @"(?m)^// (?:FORM|Subtitle|Setup Question)");
            if (nextContext.Success) block = block[..nextContext.Index];
            var context = FormContext(Text[..begin]);
            var name = Field(block, "Setup Question");
            var token = Field(block, "Token");
            var offset = Field(block, "Offset");
            var widthText = Field(block, "Width");
            if (name.Length == 0 || !Hex(token) || !Hex(offset) || !int.TryParse(widthText, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var width) || width is < 1 or > 8) continue;
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
            else continue;
            var id = OperationFiles.Hash(Encoding.UTF8.GetBytes(context + "\n" + token.ToUpperInvariant() + ":" + offset.ToUpperInvariant() + ":" + name));
            questions.Add(new(id, name, Field(block, "Help String"), current, kind, width, options, context, block));
        }
        if (questions.Count == 0) throw new InvalidDataException("No editable choices or numeric settings were found in this BIOS export.");
        if (questions.Select(q => q.Id).Distinct().Count() != questions.Count) throw new InvalidDataException("The export contains ambiguous duplicate settings. Use a board-specific SCEWIN package.");
        Questions = questions;
    }

    private static string FormContext(string prefix)
    {
        var sets = Regex.Matches(prefix, @"(?m)^// FORM SET\r?$");
        var forms = Regex.Matches(prefix, @"(?m)^// FORM\r?$");
        string Header(int start) => string.Join("\n", prefix[start..].Split('\n')
            .TakeWhile((line, index) => (index == 0 || !Regex.IsMatch(line.TrimEnd('\r'), @"^// FORM(?: SET)?$"))
                && (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith("//", StringComparison.Ordinal)))
            .Select(line => line.TrimEnd('\r'))).Trim();
        var set = sets.Count > 0 ? sets[^1].Index : -1;
        var form = forms.Count > 0 ? forms[^1].Index : -1;
        return (set >= 0 ? Header(set) : "") + (form > set ? "\n" + Header(form) : "");
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
        var output = new StringBuilder("HIICrc32 = " + Crc + "\r\n\r\n");
        foreach (var change in selections)
        {
            var question = Questions.SingleOrDefault(q => q.Id == change.Key) ?? throw new InvalidDataException("A selected setting is missing from the export.");
            var value = Validate(question, change.Value);
            if (value == Validate(question, question.Current)) throw new InvalidDataException("The review includes an unchanged setting.");
            var block = question.Text;
            if (question.Kind == "choice")
                block = Choice.Replace(block, m => m.Groups["prefix"].Value + (m.Groups["value"].Value.Equals(value, StringComparison.OrdinalIgnoreCase) ? "*" : "") + "[" + m.Groups["value"].Value + "]" + m.Groups["label"].Value);
            else
                block = Regex.Replace(block, @"(?m)^([ \t]*Value[ \t]*=[ \t]*)([^\r\n/]*)", m => m.Groups[1].Value + (question.Kind == "decimal" ? "<" + value + ">" : value) + " ");
            output.Append(question.Context).Append("\r\n").Append(block.TrimEnd()).Append("\r\n\r\n");
        }
        return _preamble.Concat(_encoding.GetBytes(output.ToString())).ToArray();
    }

    public bool SameValues(FirmwareScript other, IReadOnlyDictionary<string, string>? changes = null)
    {
        if (Crc != other.Crc || Questions.Count != other.Questions.Count) return false;
        return Questions.All(q => other.Questions.SingleOrDefault(o => o.Id == q.Id) is { } actual
            && q.Kind == actual.Kind && q.Width == actual.Width && q.Options.SequenceEqual(actual.Options)
            && Validate(q, changes is not null && changes.TryGetValue(q.Id, out var value) ? value : q.Current) == other.Validate(actual, actual.Current));
    }
}
