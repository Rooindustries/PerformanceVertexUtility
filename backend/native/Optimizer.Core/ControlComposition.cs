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
        var mapKind = current.Address.Kind is "device-power" or "network-adapter";
        bool P(ControlClaim claim) => claim.Patch || mapKind && claim.Desired.ValueKind == JsonValueKind.Object;
        string[] F(IEnumerable<ControlClaim> claims) => claims.Where(P).SelectMany(claim => claim.Desired.EnumerateObject()).Select(property => property.Name).Distinct().ToArray();
        var snapshot = current.Value.ValueKind == JsonValueKind.Object && current.Value.TryGetProperty(MitigationControl.SnapshotField, out _);
        bool Intact(ControlClaim claim) => Matches(claim, current.Value) && (!snapshot || !P(claim) || held is null ||
            MitigationControl.Linked(F([claim])).All(field => current.Value.TryGetProperty(field, out var now) && held.Applied.TryGetProperty(field, out var owned) && ControlValues.Equal(now, owned)));
        if (held is not null && !lostOwner && before.Any(claim => !Intact(claim)))
        {
            var released = before.Where(claim => !after.Any(kept => ReferenceEquals(kept, claim))).ToArray();
            var requested = after.Where(claim => !before.Any(old => ReferenceEquals(old, claim))).ToArray();
            var kept = after.Where(claim => before.Any(old => ReferenceEquals(old, claim))).ToArray();
            var lost = before.Where(claim => !Intact(claim)).ToArray();
            string[] Drifted(ControlClaim claim) => claim.Desired.EnumerateObject().Where(property => !current.Value.TryGetProperty(property.Name, out var now) || !ControlValues.Equal(now, property.Value)).Select(property => property.Name).ToArray();
            var busy = snapshot ? F(lost) : lost.Where(claim => P(claim)).SelectMany(Drifted).Concat(F(kept.Where(claim => !Intact(claim)))).Distinct().ToArray();
            var reverting = Free(current.Value, F(before), busy);
            bool Differs(ControlClaim claim, IEnumerable<string> fields) => !P(claim) ? !ControlValues.Equal(current.Value, baseline)
                : fields.Any(field => !current.Value.TryGetProperty(field, out var now) || !baseline.TryGetProperty(field, out var original) || !ControlValues.Equal(now, original));
            var written = Free(current.Value, F(requested), []);
            var left = released.Where(claim => Intact(claim) ? P(claim) && Differs(claim, F([claim]).Except(reverting)) : Differs(claim, snapshot || !P(claim) ? F([claim]) : Drifted(claim)))
                .Where(claim => !requested.Any(item => !P(item) || item.SettingId == claim.SettingId) && (!P(claim) || Free(current.Value, F([claim]), written).Length > 0))
                .Select(claim => claim.SettingId).Distinct().Order(StringComparer.Ordinal).ToArray();
            if (before.All(claim => !P(claim)) && after.All(claim => !P(claim)))
                return requested.Length > 0 ? (after[0].Desired, null, left, null) : (current.Value, held.RestoreValue, left, held.Applied);
            if (requested.Any(claim => !P(claim))) throw new InvalidDataException("Restore individual policy fields before replacing the complete policy.");
            if (snapshot && requested.Length > 0) throw new InvalidDataException("Windows Security changed exploit protection settings that this app manages. Use Undo on those settings first, then apply again.");
            var cleared = Revert(current.Value, baseline, reverting);
            var value = Assign(cleared, kept.Where(Intact).Concat(requested));
            if (requested.Length == 0) return (value, held.RestoreValue, left, Revert(held.Applied, baseline, Free(held.Applied, F(released), F(after))));
            var rewritten = F(lost.Where(claim => released.Contains(claim, ReferenceEqualityComparer.Instance) && F([claim]).Intersect(F(requested)).Any()));
            var restore = Revert(cleared, baseline, Free(cleared, F(after).Intersect(F(before)), rewritten));
            var applied = Assign(Revert(value, baseline, Free(value, F(released.Where(Intact)), F(after))), after);
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
