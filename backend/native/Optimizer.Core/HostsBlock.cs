#nullable enable
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public static class HostsBlock
{
    private const string Begin = "# BEGIN Roo Industries Adobe hosts v1 ";
    private const string End = "# END Roo Industries Adobe hosts v1\r\n";
    private static readonly byte[] Bom = [0xef, 0xbb, 0xbf];
    private static readonly Lazy<string[]> Domains = new(() =>
    {
        using var input = typeof(HostsBlock).Assembly.GetManifestResourceStream("Optimizer.Core.AdobeHosts.txt") ?? throw new InvalidDataException("The reviewed hosts list is missing.");
        using var reader = new StreamReader(input, new UTF8Encoding(false, true));
        var text = reader.ReadToEnd();
        if (OperationFiles.Hash(Encoding.UTF8.GetBytes(text)) != "CDD0B8A98EF32BBA48E0C76C37028C5770049E2401DF316E6CD7C25F85C906D5") throw new InvalidDataException("The reviewed hosts payload changed.");
        return text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1]).ToArray();
    });
    public static JsonElement Read(byte[] bytes)
    {
        if (bytes.Length > 262144 || bytes.Contains((byte)0)) throw new InvalidDataException("Hosts requires a non-NUL file no larger than 256 KiB.");
        var text = Encoding.Latin1.GetString(bytes);
        var start = text.IndexOf(Begin, StringComparison.Ordinal);
        var marker = text.IndexOf("# BEGIN Roo Industries Adobe hosts", StringComparison.Ordinal);
        if (marker != start || marker >= 0 && text.IndexOf("# BEGIN Roo Industries Adobe hosts", marker + 1, StringComparison.Ordinal) >= 0) throw new InvalidDataException("The hosts block version or opening marker changed.");
        string? block = null;
        if (start >= 0)
        {
            if (start != 0 && !(start == 3 && bytes.AsSpan(0, 3).SequenceEqual(Bom)) && text[start - 1] is not ('\r' or '\n')) throw new InvalidDataException("The owned hosts marker is not at a line boundary.");
            var finish = text.IndexOf(End, start, StringComparison.Ordinal);
            if (finish < 0 || text.IndexOf(Begin, start + Begin.Length, StringComparison.Ordinal) >= 0 || text.IndexOf(End, finish + End.Length, StringComparison.Ordinal) >= 0) throw new InvalidDataException("The owned hosts block is incomplete or duplicated.");
            var headerEnd = text.IndexOf("\r\n", start, StringComparison.Ordinal);
            if (headerEnd < 0 || headerEnd >= finish) throw new InvalidDataException("The hosts block header is incomplete.");
            var body = bytes[(headerEnd + 2)..finish];
            if (!string.Equals(text[(start + Begin.Length)..headerEnd], OperationFiles.Hash(body), StringComparison.Ordinal)) throw new InvalidDataException("The owned hosts block was edited.");
            block = Convert.ToBase64String(bytes[start..(finish + End.Length)]);
            bytes = [.. bytes[..start], .. bytes[(finish + End.Length)..]];
        }
        else if (text.Contains("# END Roo Industries Adobe hosts", StringComparison.Ordinal)) throw new InvalidDataException("The hosts block has no opening marker.");
        return ControlValues.From(new { block, outside = Convert.ToBase64String(bytes) });
    }
    public static JsonElement Expand(TweakControlRead before, JsonElement requested)
    {
        if (!requested.GetProperty("enabled").GetBoolean()) return ControlValues.From(new { block = (string?)null });
        if (before.Value.GetProperty("block").ValueKind != JsonValueKind.Null) return ControlValues.From(new { block = before.Value.GetProperty("block").GetString() });
        var outside = Convert.FromBase64String(before.Value.GetProperty("outside").GetString()!);
        var existing = Mappings(outside);
        var names = new List<string>();
        foreach (var domain in Domains.Value)
        {
            if (existing.TryGetValue(domain, out var addresses))
            {
                if (addresses.Any(address => address != "0.0.0.0")) throw new InvalidDataException("An existing hosts mapping conflicts with this block list: " + domain);
                continue;
            }
            names.Add(domain);
        }
        if (names.Count == 0) return ControlValues.From(new { block = (string?)null });
        var body = Encoding.ASCII.GetBytes(string.Concat(names.Select(name => "0.0.0.0 " + name + "\r\n")));
        var block = Encoding.ASCII.GetBytes(Begin + OperationFiles.Hash(body) + "\r\n").Concat(body).Concat(Encoding.ASCII.GetBytes(End)).ToArray();
        if (outside.Length + block.Length > 262144) throw new InvalidDataException("The reviewed hosts result exceeds 256 KiB.");
        return ControlValues.From(new { block = Convert.ToBase64String(block) });
    }
    private static Dictionary<string, HashSet<string>> Mappings(byte[] data)
    {
        var offset = data.AsSpan().StartsWith(Bom) ? 3 : 0;
        var result = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in Encoding.Latin1.GetString(data[offset..]).Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n'))
        {
            var active = line.Split('#')[0].Trim();
            if (active.Length == 0) continue;
            var parts = Regex.Split(active, "[ \\t]+");
            if (parts.Length < 2 || !IPAddress.TryParse(parts[0], out var address)) throw new InvalidDataException("An existing hosts line has unsupported syntax.");
            foreach (var name in parts.Skip(1))
            {
                if (!Regex.IsMatch(name, "^[A-Za-z0-9_.-]+$", RegexOptions.CultureInvariant)) throw new InvalidDataException("An existing hosts name has unsupported syntax.");
                if (!result.TryGetValue(name, out var values)) result.Add(name, values = []);
                values.Add(address.ToString());
            }
        }
        return result;
    }
    public static byte[] Bytes(JsonElement value)
    {
        var outside = Convert.FromBase64String(value.GetProperty("outside").GetString()!);
        var block = value.GetProperty("block").ValueKind == JsonValueKind.Null ? [] : Convert.FromBase64String(value.GetProperty("block").GetString()!);
        var offset = outside.AsSpan().StartsWith(Bom) ? 3 : 0;
        return [.. outside[..offset], .. block, .. outside[offset..]];
    }
    public static bool KnownPartial(byte[] current, byte[] before, byte[] after)
    {
        if (current.SequenceEqual(before) || current.SequenceEqual(after)) return true;
        if (current.Length < before.Length || current.Length > Math.Max(before.Length, after.Length)) return false;
        var prefix = 0;
        while (prefix < Math.Min(current.Length, after.Length) && current[prefix] == after[prefix]) prefix++;
        var suffix = current.Length;
        while (suffix > 0 && suffix <= before.Length && current[suffix - 1] == before[suffix - 1]) suffix--;
        return suffix <= prefix;
    }
}
