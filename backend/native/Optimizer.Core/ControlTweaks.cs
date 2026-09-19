#nullable enable
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record ControlAddress([property: JsonRequired] string Kind, [property: JsonRequired] string Target, [property: JsonRequired] string Property)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Kind) || string.IsNullOrWhiteSpace(Target) || string.IsNullOrWhiteSpace(Property) ||
            Kind.Length > 80 || Target.Length > 4096 || Property.Length > 200 || (Kind + Target + Property).Contains('\0'))
            throw new InvalidDataException("An explicit Windows control identity is required.");
    }
    [JsonIgnore] public string Key => Kind.ToUpperInvariant() + "|" + Target.ToUpperInvariant() + "|" + Property.ToUpperInvariant();
}
public sealed record ControlAssignment([property: JsonRequired] ControlAddress Address, [property: JsonRequired] JsonElement Value, bool Patch = false);
public sealed record TweakControlRead([property: JsonRequired] ControlAddress Address, [property: JsonRequired] string Identity, [property: JsonRequired] string Binding, [property: JsonRequired] JsonElement Value, string? DisplayName = null, JsonElement[]? AllowedValues = null, Dictionary<string, string[]>? Parents = null, bool RestartPending = false, bool LostLease = false, string? EvidenceHash = null)
{
    public JsonElement Expand(JsonElement value, bool allowPending = false)
    {
        if (Address.Kind == "windows-features") return WindowsFeatures.Expand(this, value, allowPending);
        if (Address.Kind is "file-acl" or "file-ownership") return FileAccessControl.Expand(this, value);
        if (Address.Kind == "hosts") return HostsBlock.Expand(this, value);
        if (Address.Kind == "power-plan") return PowerPlanControl.Expand(this, value);
        if (Address.Kind is not ("network-adapter" or "device-power")) return value;
        if (Value.ValueKind != JsonValueKind.Object || !Value.EnumerateObject().Any()) throw new InvalidDataException("The selected device values are incomplete.");
        return ControlValues.From(Value.EnumerateObject().ToDictionary(property => property.Name, _ => value));
    }
    public bool Allows(JsonElement value) => (Address.Kind != "hibernation" || !value.TryGetProperty("mode", out var mode) || mode.GetString() != "Full" || Binding == "power-capabilities:s4=True") &&
        (AllowedValues is null || AllowedValues.Any(allowed => ControlValues.Equal(allowed, value)));
    [JsonIgnore] public string Id => OperationFiles.Hash(System.Text.Encoding.UTF8.GetBytes(Identity.ToUpperInvariant()));
    public bool Same(TweakControlRead other) => Id == other.Id && Binding == other.Binding && ControlValues.Equal(Value, other.Value) && EvidenceHash == other.EvidenceHash;
    public void Validate()
    {
        Address.Validate();
        if (string.IsNullOrWhiteSpace(Identity) || string.IsNullOrWhiteSpace(Binding) || Value.ValueKind == JsonValueKind.Undefined || Value.GetRawText().Length > 1048576)
            throw new InvalidDataException("The Windows control snapshot is incomplete.");
    }
}
public sealed record ControlClaim([property: JsonRequired] string SettingId, [property: JsonRequired] string OptionId, [property: JsonRequired] TweakControlRead Target, [property: JsonRequired] JsonElement Desired, bool Patch = false);
public sealed record ControlHeld([property: JsonRequired] TweakControlRead Original, [property: JsonRequired] JsonElement Applied, JsonElement? RestoreValue = null);
public sealed record ControlMutation([property: JsonRequired] TweakControlRead Before, [property: JsonRequired] JsonElement After, string[]? Fields = null);
public sealed record ControlPlan([property: JsonRequired] TweakControlRead[] Expected, [property: JsonRequired] ControlMutation[] Changes, [property: JsonRequired] ControlHeld[] Held);
public sealed record ControlJournal([property: JsonRequired] TweakPlan Plan, [property: JsonRequired] string ReviewHash, [property: JsonRequired] int Attempted, string Phase = "applying");

public static class ControlValues
{
    public static JsonElement From<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    public static bool Equal(JsonElement first, JsonElement second) => first.ValueKind != JsonValueKind.Undefined && second.ValueKind != JsonValueKind.Undefined &&
        JsonNode.DeepEquals(JsonNode.Parse(first.GetRawText()), JsonNode.Parse(second.GetRawText()));
}

public interface IControlStore
{
    TweakControlRead Read(ControlAddress address);
    void Write(TweakControlRead before, JsonElement after);
}

public static class ControlPlanning
{
    public static ControlPlan Plan(TweakState? state, TweakProfile[] profiles, string profileId, Func<ControlAddress, TweakControlRead> read)
    {
        var affected = (state?.Profiles.SingleOrDefault(profile => profile.Id == profileId)?.Controls ?? []).Select(claim => claim.Target.Id)
            .Concat((profiles.SingleOrDefault(profile => profile.Id == profileId)?.Controls ?? []).Select(claim => claim.Target.Id)).ToHashSet(StringComparer.Ordinal);
        var wanted = profiles.SelectMany(profile => profile.Controls ?? []).GroupBy(claim => claim.Target.Id).ToDictionary(group => group.Key, group => group.ToArray());
        foreach (var claims in wanted.Values) ControlComposition.Check(claims);
        var held = (state?.Controls ?? []).ToDictionary(item => item.Original.Id);
        var expected = new List<TweakControlRead>(); var changes = new List<ControlMutation>(); var next = new List<ControlHeld>();
        foreach (var id in held.Keys.Concat(wanted.Keys).Distinct().Order(StringComparer.Ordinal))
        {
            held.TryGetValue(id, out var original); wanted.TryGetValue(id, out var claims);
            if (!affected.Contains(id)) { next.Add(original!); continue; }
            var observed = read((claims?.First().Target ?? original!.Original).Address); observed.Validate();
            if (observed.RestartPending) throw new InvalidDataException("Restart Windows before changing or restoring pending Windows features.");
            if (observed.Id != id)
                throw new InvalidDataException("A Windows control changed outside this profile: " + observed.Address.Target);
            if (claims is not null && claims.Any(claim => !claim.Target.Same(observed) && !held.ContainsKey(id)))
                throw new InvalidDataException("A Windows control changed during review: " + observed.Address.Target);
            expected.Add(observed);
            var before = (state?.Profiles ?? []).SelectMany(profile => profile.Controls ?? []).Where(claim => claim.Target.Id == id).ToArray();
            var composed = ControlComposition.Resolve(observed, original, before, claims ?? []);
            if (observed.Address.Kind == "hibernation") { HibernationControl.Validate(observed.Value); HibernationControl.Validate(composed.Desired); }
            if (!ControlValues.Equal(observed.Value, composed.Desired) || observed.Address.Kind is "timer" or "timer-startup" or "download-blocker" && observed.LostLease && claims is null) changes.Add(new(observed, composed.Desired, before.Concat(claims ?? []).All(claim => claim.Patch) ? before.Concat(claims ?? []).SelectMany(claim => claim.Desired.EnumerateObject().Select(property => property.Name)).Distinct(StringComparer.Ordinal).ToArray() : null));
            if (claims is not null) next.Add(new(original is null ? observed : original.Original with { Address = observed.Address }, composed.Desired, composed.Restore));
        }
        var relevant = affected.Any(id => wanted.GetValueOrDefault(id)?.Any(claim => claim.Target.Address.Kind == "memory" || claim.Target.Address.Kind == "service" && claim.Target.Address.Target.Equals("SysMain", StringComparison.OrdinalIgnoreCase)) == true);
        if (relevant && wanted.Values.Any(claims => claims[0].Target.Address.Kind == "memory" && claims[0].Desired.ValueKind == JsonValueKind.True))
        {
            var dependency = read(new("service", "SysMain", "startup")); dependency.Validate();
            var value = wanted.TryGetValue(dependency.Id, out var owners) ? owners[0].Desired : dependency.Value;
            if (value.GetUInt32() == 4) throw new InvalidDataException("Memory compression requires SysMain startup to remain enabled.");
            if (expected.All(item => item.Id != dependency.Id)) expected.Add(dependency);
        }
        return new(expected.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray(), changes.OrderBy(ChangeOrder).ThenBy(change => change.Before.Id, StringComparer.Ordinal).ToArray(), next.ToArray());
    }
    private static int ChangeOrder(ControlMutation change) => change.Before.Address.Kind == "timer" && change.After.ValueKind == JsonValueKind.False ? 0 : change.Before.Address.Kind == "memory" ? 25 : change.Before.Address.Property switch
    {
        "running" => change.After.ValueKind == JsonValueKind.True ? 30 : 0,
        "delayed-start" => change.After.ValueKind == JsonValueKind.True ? 20 : 0,
        _ => 10,
    };
    public static void Validate(TweakState state)
    {
        var claims = state.Profiles.SelectMany(profile => profile.Controls ?? []).ToArray();
        var held = state.Controls ?? [];
        if (held.Select(item => item.Original.Id).Distinct().Count() != held.Length ||
            !claims.Select(claim => claim.Target.Id).Distinct().Order().SequenceEqual(held.Select(item => item.Original.Id).Order()) ||
            claims.Any(claim => !ControlComposition.Matches(claim, held.Single(item => item.Original.Id == claim.Target.Id).Applied)))
            throw new InvalidDataException("Windows control ownership and recovery data disagree.");
        foreach (var item in held) item.Original.Validate();
    }
}

public static class ControlExecution
{
    public static bool Apply(ControlPlan plan, IControlStore store, Action<int> saveAttempt)
    {
        var pending = false;
        foreach (var expected in plan.Expected)
            if (!store.Read(expected.Address).Same(expected)) throw new InvalidDataException("A Windows control changed after review: " + expected.Address.Target);
        for (var index = 0; index < plan.Changes.Length; index++)
        {
            var change = plan.Changes[index];
            saveAttempt(index + 1);
            var current = store.Read(change.Before.Address);
            if (!current.Same(change.Before)) throw new InvalidDataException("A Windows control changed before its write: " + current.Address.Target);
            store.Write(current, change.After);
            var after = store.Read(current.Address);
            pending |= after.RestartPending;
            if (after.Id != current.Id || after.Binding != current.Binding || !ControlValues.Equal(after.Value, change.After))
                throw new InvalidOperationException("Windows control readback differs from the reviewed value: " + current.Address.Target);
        }
        return pending;
    }
    private static bool KnownIntermediate(JsonElement current, JsonElement before, JsonElement after)
    {
        if (ControlValues.Equal(current, before) || ControlValues.Equal(current, after)) return true;
        if (current.ValueKind != JsonValueKind.Object || before.ValueKind != JsonValueKind.Object || after.ValueKind != JsonValueKind.Object) return false;
        var names = current.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray();
        if (names.Length == 0 || !names.SequenceEqual(before.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal)) ||
            !names.SequenceEqual(after.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal))) return false;
        return names.All(name => KnownIntermediate(current.GetProperty(name), before.GetProperty(name), after.GetProperty(name)));
    }
    public static void Rollback(ControlPlan plan, int attempted, IControlStore store)
    {
        var failures = new List<string>();
        foreach (var change in plan.Changes.Take(attempted).Reverse())
        {
            try
            {
                if (store is WindowsControlStore && change.Before.Address.Kind == "hosts") { HostsControl.Rollback(change); continue; }
                var current = store.Read(change.Before.Address);
                if (current.RestartPending) throw new InvalidDataException("Restart Windows before recovering pending feature changes.");
                if (current.Same(change.Before) && !current.LostLease) continue;
                if (change.Fields is { Length: > 0 })
                {
                    if (current.Id != change.Before.Id || current.Binding != change.Before.Binding || current.Value.ValueKind != JsonValueKind.Object ||
                        change.Fields.Any(field => !current.Value.TryGetProperty(field, out var value) || !KnownIntermediate(value, change.Before.Value.GetProperty(field), change.After.GetProperty(field))))
                        throw new InvalidDataException("An owned policy field has a newer value or identity.");
                    var restored = ControlValues.From(current.Value.EnumerateObject().ToDictionary(property => property.Name,
                        property => change.Fields.Contains(property.Name, StringComparer.Ordinal) ? change.Before.Value.GetProperty(property.Name) : property.Value));
                    store.Write(current, restored);
                    var verified = store.Read(current.Address);
                    if (verified.RestartPending) throw new InvalidDataException("Restart Windows to finish feature recovery, then check recovery again.");
                    if (!verified.Same(current with { Value = restored })) throw new InvalidDataException("Policy-field restoration readback differs.");
                    continue;
                }
                if (current.Id != change.Before.Id || current.Binding != change.Before.Binding || !KnownIntermediate(current.Value, change.Before.Value, change.After))
                    throw new InvalidDataException("The control has a newer value or identity.");
                store.Write(current, change.Before.Value);
                var restoredRead = store.Read(current.Address);
                if (restoredRead.RestartPending) throw new InvalidDataException("Restart Windows to finish feature recovery, then check recovery again.");
                if (!restoredRead.Same(change.Before)) throw new InvalidDataException("Restoration readback differs from the original.");
            }
            catch (Exception error) { failures.Add(change.Before.Address.Target + ": " + error.Message); }
        }
        if (failures.Count > 0) throw new InvalidOperationException("Recovery still needs attention: " + string.Join("; ", failures));
    }
}
