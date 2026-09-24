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
        var desired = ControlValues.From(result);
        return desired.TryGetProperty(MitigationControl.SnapshotField, out _) ? MitigationControl.Reconcile(desired) : desired;
    }
    private static string[] Fields(IEnumerable<ControlClaim> claims) => claims.Where(claim => claim.Patch).SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => property.Name).Distinct().ToArray();
    private static JsonElement Revert(JsonElement value, JsonElement baseline, string[] fields) => fields.Length == 0 ? value
        : value.TryGetProperty(MitigationControl.SnapshotField, out _) ? MitigationControl.RestoreFields(value, baseline, fields)
        : Set(value, fields.Select(field => new KeyValuePair<string, JsonElement>(field, baseline.GetProperty(field))));
    private static string[] Free(JsonElement value, IEnumerable<string> fields, IEnumerable<string> busy)
    {
        string[] Units(string field) => value.TryGetProperty(MitigationControl.SnapshotField, out _) ? MitigationControl.Units(field) : [field];
        var taken = busy.SelectMany(Units).ToHashSet(StringComparer.Ordinal);
        return fields.Where(field => !Units(field).Any(taken.Contains)).Distinct().ToArray();
    }
    private static JsonElement Assign(JsonElement value, IEnumerable<ControlClaim> claims) => Set(value, claims.SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => new KeyValuePair<string, JsonElement>(property.Name, property.Value)));
    public static (JsonElement Desired, JsonElement? Restore, string[]? LeftAsChanged, JsonElement? Applied) Resolve(TweakControlRead current, ControlHeld? held, ControlClaim[] before, ControlClaim[] after)
    {
        Check(after);
        var lostOwner = current.Address.Kind is "timer" or "timer-startup" or "download-blocker" && current.LostLease && current.Value.ValueKind == JsonValueKind.False;
        if (held is not null && held.Original.Binding != current.Binding && after.Any(claim => !before.Any(old => ReferenceEquals(old, claim))))
            throw new InvalidDataException("A Windows control was replaced outside this profile. Undo the profile that owns it, then choose it again: " + current.Address.Target);
        var baseline = held?.RestoreValue ?? held?.Original.Value ?? current.Value;
        var snapshot = current.Value.ValueKind == JsonValueKind.Object && current.Value.TryGetProperty(MitigationControl.SnapshotField, out _);
        bool Intact(ControlClaim claim) => Matches(claim, current.Value) && (!snapshot || !claim.Patch || held is null ||
            MitigationControl.Linked(Fields([claim])).All(field => current.Value.TryGetProperty(field, out var now) && held.Applied.TryGetProperty(field, out var owned) && ControlValues.Equal(now, owned)));
        if (held is not null && !lostOwner && before.Any(claim => !Intact(claim)))
        {
            var released = before.Where(claim => !after.Any(kept => ReferenceEquals(kept, claim))).ToArray();
            var requested = after.Where(claim => !before.Any(old => ReferenceEquals(old, claim))).ToArray();
            var kept = after.Where(claim => before.Any(old => ReferenceEquals(old, claim))).ToArray();
            var lost = before.Where(claim => !Intact(claim)).ToArray();
            var busy = Fields(lost);
            var reverting = Free(current.Value, Fields(before), busy);
            bool Differs(ControlClaim claim, IEnumerable<string> fields) => !claim.Patch ? !ControlValues.Equal(current.Value, baseline)
                : fields.Any(field => !current.Value.TryGetProperty(field, out var now) || !baseline.TryGetProperty(field, out var original) || !ControlValues.Equal(now, original));
            var written = Free(current.Value, Fields(requested), []);
            var left = released.Where(claim => Intact(claim) ? claim.Patch && Differs(claim, Fields([claim]).Except(reverting)) : Differs(claim, Fields([claim])))
                .Where(claim => !requested.Any(item => !item.Patch || item.SettingId == claim.SettingId) && (!claim.Patch || Free(current.Value, Fields([claim]), written).Length > 0))
                .Select(claim => claim.SettingId).Distinct().Order(StringComparer.Ordinal).ToArray();
            if (before.All(claim => !claim.Patch) && after.All(claim => !claim.Patch))
                return requested.Length > 0 ? (after[0].Desired, null, left, null) : (current.Value, held.RestoreValue, left, held.Applied);
            if (requested.Any(claim => !claim.Patch)) throw new InvalidDataException("Restore individual policy fields before replacing the complete policy.");
            if (snapshot && requested.Length > 0) throw new InvalidDataException("Windows Security changed exploit protection settings that Roo Industries manages. Use Undo on those settings first, then apply again.");
            var cleared = Revert(current.Value, baseline, reverting);
            var value = Assign(cleared, kept.Where(Intact).Concat(requested));
            if (requested.Length == 0) return (value, held.RestoreValue, left, Revert(held.Applied, baseline, Free(held.Applied, Fields(released), Fields(after))));
            var rewritten = Fields(lost.Where(claim => released.Contains(claim, ReferenceEqualityComparer.Instance) && Fields([claim]).Intersect(Fields(requested)).Any()));
            var restore = Revert(cleared, baseline, Free(cleared, Fields(after).Intersect(Fields(before)), rewritten));
            var applied = Assign(Revert(value, baseline, Free(value, Fields(released.Where(Intact)), Fields(after))), after);
            return (value, restore, left, applied);
        }
        var restored = held is null ? current.Value : ControlValues.Equal(current.Value, held.Applied) || before.Any(claim => !claim.Patch) ? baseline
            : Set(current.Value, before.SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => new KeyValuePair<string, JsonElement>(property.Name, baseline.GetProperty(property.Name))));
        if (held is not null && current.Address.Kind == "mitigations" && current.Value.TryGetProperty(MitigationControl.SnapshotField, out _) && before.All(claim => claim.Patch))
            restored = MitigationControl.RestoreFields(current.Value, baseline, before.SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => property.Name).Distinct().ToArray());
        if (after.Length == 0) return (restored, null, null, null);
        if (!after[0].Patch)
        {
            if (before.Any(claim => claim.Patch)) throw new InvalidDataException("Restore individual policy fields before replacing the complete policy.");
            return (after[0].Desired, null, null, null);
        }
        return (Set(restored, after.SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => new KeyValuePair<string, JsonElement>(property.Name, property.Value))), restored, null, null);
    }
}
