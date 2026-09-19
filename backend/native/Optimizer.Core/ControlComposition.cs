#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class ControlComposition
{
    public static bool Matches(ControlClaim claim, JsonElement value) => !claim.Patch ? ControlValues.Equal(claim.Desired, value)
        : claim.Desired.ValueKind == JsonValueKind.Object && value.ValueKind == JsonValueKind.Object &&
          claim.Desired.EnumerateObject().All(property => value.TryGetProperty(property.Name, out var current) && ControlValues.Equal(property.Value, current));
    public static void Check(ControlClaim[] claims)
    {
        if (claims.Any(claim => claim.Patch) && claims.Any(claim => !claim.Patch)) throw new InvalidDataException("A complete Windows policy conflicts with individual policy fields.");
        if (claims.All(claim => !claim.Patch))
        {
            if (claims.Any(claim => !ControlValues.Equal(claim.Desired, claims[0].Desired))) throw new InvalidDataException("Conflicting choices for Windows control: " + claims[0].Target.Address.Target);
            return;
        }
        foreach (var group in claims.SelectMany(claim => claim.Desired.EnumerateObject()).GroupBy(property => property.Name, StringComparer.Ordinal))
            if (group.Any(property => !ControlValues.Equal(property.Value, group.First().Value))) throw new InvalidDataException("Conflicting Windows policy field: " + group.Key);
    }
    private static JsonElement Set(JsonElement value, IEnumerable<KeyValuePair<string, JsonElement>> fields)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("A complete Windows policy snapshot is required.");
        var result = value.EnumerateObject().ToDictionary(property => property.Name, property => property.Value, StringComparer.Ordinal);
        foreach (var field in fields)
        {
            if (!result.ContainsKey(field.Key)) throw new InvalidDataException("Windows does not expose policy field: " + field.Key);
            result[field.Key] = field.Value;
        }
        return ControlValues.From(result);
    }
    public static (JsonElement Desired, JsonElement? Restore) Resolve(TweakControlRead current, ControlHeld? held, ControlClaim[] before, ControlClaim[] after)
    {
        Check(after);
        var lostOwner = current.Address.Kind is "timer" or "timer-startup" or "download-blocker" && current.LostLease && current.Value.ValueKind == JsonValueKind.False;
        if (held is not null && (held.Original.Binding != current.Binding || !lostOwner && before.Any(claim => !Matches(claim, current.Value))))
            throw new InvalidDataException("A Windows control changed outside this profile: " + current.Address.Target);
        var baseline = held?.RestoreValue ?? held?.Original.Value ?? current.Value;
        var restored = held is null ? current.Value : ControlValues.Equal(current.Value, held.Applied) || before.Any(claim => !claim.Patch) ? baseline
            : Set(current.Value, before.SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => new KeyValuePair<string, JsonElement>(property.Name, baseline.GetProperty(property.Name))));
        if (after.Length == 0) return (restored, null);
        if (!after[0].Patch)
        {
            if (before.Any(claim => claim.Patch)) throw new InvalidDataException("Restore individual policy fields before replacing the complete policy.");
            return (after[0].Desired, null);
        }
        return (Set(restored, after.SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => new KeyValuePair<string, JsonElement>(property.Name, property.Value))), restored);
    }
}
