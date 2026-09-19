#nullable enable
using System.Text;

namespace RooIndustries.Optimizer;

public static class TweakTokens
{
    public static void Validate(TweakToken token)
    {
        if (string.IsNullOrWhiteSpace(token.Name) || token.Name.IndexOfAny([';', '=', '\0']) >= 0 || token.Value?.IndexOfAny([';', '\0']) >= 0)
            throw new InvalidDataException("Invalid setting field.");
    }
    private static string Text(RegistryValueData? value)
    {
        if (value is null) return "";
        if (value.Type != 1 || !value.Recoverable) throw new InvalidDataException("This setting requires a registry string.");
        return Encoding.Unicode.GetString(value.Bytes)[..^1];
    }
    public static string? Get(RegistryValueData? value, string name)
    {
        var matches = Text(value).Split(';').Where(piece => piece.Contains('=') && piece[..piece.IndexOf('=')].Trim().Equals(name, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (matches.Length > 1) throw new InvalidDataException("A setting field occurs more than once: " + name);
        return matches.Length == 0 ? null : matches[0][(matches[0].IndexOf('=') + 1)..];
    }
    public static RegistryValueData? Set(RegistryValueData? value, string valueName, IEnumerable<TweakToken> changes, bool allowAbsent)
    {
        var text = Text(value);
        var pieces = text.Split(';').ToList();
        foreach (var change in changes)
        {
            Validate(change); _ = Get(value, change.Name);
            var index = pieces.FindIndex(piece => piece.Contains('=') && piece[..piece.IndexOf('=')].Trim().Equals(change.Name, StringComparison.OrdinalIgnoreCase));
            if (change.Value is null) { if (index >= 0) pieces.RemoveAt(index); }
            else if (index >= 0) pieces[index] = pieces[index][..(pieces[index].IndexOf('=') + 1)] + change.Value;
            else { if (pieces.Count > 0 && pieces[^1] == "") pieces.Insert(pieces.Count - 1, change.Name + "=" + change.Value); else { pieces.Add(change.Name + "=" + change.Value); pieces.Add(""); } }
        }
        var result = string.Join(';', pieces);
        if (allowAbsent && result.Length == 0) return null;
        return new(valueName, 1, Encoding.Unicode.GetBytes(result + '\0'));
    }
}

public sealed record TweakResolution(RegistryValueData? Value, RegistryValueData? RestoreValue, bool Composed);

public static class TweakComposition
{
    private static bool Whole(TweakClaim claim) => claim.Token is null && claim.Bits is null;
    private static uint Number(RegistryValueData? value, uint absent)
    {
        if (value is null) return absent;
        if (value.Type != 4 || value.Bytes.Length != 4) throw new InvalidDataException("This setting requires a registry DWORD.");
        return BitConverter.ToUInt32(value.Bytes);
    }
    public static void Check(IEnumerable<TweakClaim> claims)
    {
        var rows = claims.ToArray();
        var whole = rows.Where(Whole).ToArray();
        if (whole.Length > 0 && rows.Length != whole.Length) throw new InvalidDataException("A whole-value setting conflicts with a field-level setting.");
        if (whole.Any(row => !TweakRead.SameValue(row.Desired, whole[0].Desired))) throw new InvalidDataException("Conflicting choices for one Windows setting: " + string.Join(", ", rows.Select(row => row.SettingId).Distinct()));
        if (rows.Any(row => row.Token is not null) && rows.Any(row => row.Bits is not null)) throw new InvalidDataException("String and DWORD fields cannot share a value.");
        foreach (var field in rows.Where(row => row.Token is not null).GroupBy(row => row.Token!.Name, StringComparer.OrdinalIgnoreCase))
            if (field.Select(row => row.Token!.Value).Distinct().Count() > 1) throw new InvalidDataException("Conflicting choices for setting field: " + field.Key);
        var bits = rows.Where(row => row.Bits is not null).Select(row => row.Bits!).ToArray();
        foreach (var first in bits)
            foreach (var second in bits)
                if (first.AbsentDefault != second.AbsentDefault || ((first.Value ^ second.Value) & first.Mask & second.Mask) != 0)
                    throw new InvalidDataException("Conflicting choices for setting bits.");
    }
    public static bool Matches(TweakClaim claim, RegistryValueData? observed) => claim.Token is { } token
        ? TweakTokens.Get(observed, token.Name) == token.Value : claim.Bits is { } bits
        ? observed is not null && (Number(observed, bits.AbsentDefault) & bits.Mask) == bits.Value : TweakRead.SameValue(claim.Desired, observed);
    private static RegistryValueData? SetFields(RegistryValueData? value, string name, TweakClaim[] claims, RegistryValueData? original, bool restore)
    {
        if (claims.Length == 0) return value;
        if (claims[0].Token is not null)
            return TweakTokens.Set(value, name, claims.Select(claim => restore ? new TweakToken(claim.Token!.Name, TweakTokens.Get(original, claim.Token.Name)) : claim.Token!).Distinct(), original is null);
        var number = Number(value, claims[0].Bits!.AbsentDefault);
        foreach (var claim in claims)
        {
            var bits = claim.Bits!;
            number = (number & ~bits.Mask) | ((restore ? Number(original, bits.AbsentDefault) : bits.Value) & bits.Mask);
        }
        return new(name, 4, BitConverter.GetBytes(number));
    }
    public static TweakResolution Resolve(TweakRead observed, TweakHeldValue? original, TweakClaim[] before, TweakClaim[] after)
    {
        Check(after);
        var baseline = original is null ? observed.Value : original.Composed ? original.RestoreValue : original.Original.Value;
        var restored = observed.Value;
        if (original is not null)
        {
            if (before.Any(claim => !Matches(claim, observed.Value))) throw new InvalidDataException("A setting was changed outside this profile: " + observed.Address.KeyPath + " / " + observed.Address.ValueName);
            restored = TweakRead.SameValue(observed.Value, original.Applied) || before.Any(Whole) ? baseline
                : SetFields(observed.Value, observed.Address.ValueName!, before, baseline, true);
        }
        if (after.Length == 0) return new(restored, null, false);
        if (after.Any(Whole))
        {
            if (before.Length > 0 && before.All(claim => !Whole(claim))) throw new InvalidDataException("Restore the field-level settings before replacing their entire value.");
            return new(after[0].Desired, null, false);
        }
        return new(SetFields(restored, observed.Address.ValueName!, after, restored, false), restored, true);
    }
}
