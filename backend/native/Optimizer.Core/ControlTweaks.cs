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
        if (Address.Kind == "mitigations" && Value.TryGetProperty(MitigationControl.SnapshotField, out _)) return MitigationControl.Expand(value);
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
public sealed record ControlRelease([property: JsonRequired] ControlHeld Held, bool Fields = false);
public sealed record ControlPlan([property: JsonRequired] TweakControlRead[] Expected, [property: JsonRequired] ControlMutation[] Changes, [property: JsonRequired] ControlHeld[] Held, string[]? LeftAsChanged = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] ControlRelease[]? Released = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? SysMainGuard = null)
{
    private bool Unowned(TweakControlRead read) => !Changes.Any(change => change.Before.Id == read.Id) &&
        ((Released ?? []).Any(item => item.Held.Original.Id == read.Id) || read.Id == SysMainGuard);
    [JsonIgnore] public IEnumerable<TweakControlRead> Owned => Expected.Where(read => !Unowned(read));
    public void CheckReleased(Func<ControlAddress, TweakControlRead> read)
    {
        if (SysMainGuard is not null)
        {
            var sysMain = read(Expected.First(item => item.Id == SysMainGuard).Address);
            if (sysMain.Value.ValueKind != JsonValueKind.Number || sysMain.Value.GetUInt32() == 4) throw new InvalidDataException("Memory compression needs the SysMain service enabled. Keep SysMain enabled, or turn memory compression off first.");
        }
        foreach (var release in Released ?? [])
        {
            var item = release.Held;
            var reviewed = Expected.FirstOrDefault(entry => entry.Id == item.Original.Id);
            if (reviewed is null || item.Original.Address is { Kind: "service", Property: "running" } || Changes.Any(change => change.Before.Id == item.Original.Id)) continue;
            TweakControlRead observed;
            try { observed = read(reviewed.Address); }
            catch (Exception error) when (error is not (TimeoutException or OperationCanceledException) && (error is not IOException || error is FileNotFoundException or DirectoryNotFoundException)) { continue; }
            if (observed.Id == item.Original.Id && Retaken(observed.Value, reviewed.Value, item.Applied, item.RestoreValue ?? item.Original.Value, release.Fields))
                throw new InvalidDataException("A released Windows control returned to the tweaked value before undo finished: " + item.Original.Address.Target);
        }
    }
    private static bool Retaken(JsonElement now, JsonElement reviewed, JsonElement applied, JsonElement baseline, bool fields)
    {
        bool Took(JsonElement current, JsonElement before, JsonElement tweaked, JsonElement original) => ControlValues.Equal(current, tweaked) && !ControlValues.Equal(before, tweaked) && !ControlValues.Equal(tweaked, original);
        if (!fields || now.ValueKind != JsonValueKind.Object || reviewed.ValueKind != JsonValueKind.Object || applied.ValueKind != JsonValueKind.Object || baseline.ValueKind != JsonValueKind.Object)
            return Took(now, reviewed, applied, baseline);
        return applied.EnumerateObject().Any(property => property.Name != MitigationControl.SnapshotField && now.TryGetProperty(property.Name, out var current) &&
            Took(current, reviewed.TryGetProperty(property.Name, out var before) ? before : default, property.Value, baseline.TryGetProperty(property.Name, out var original) ? original : default));
    }
}
public sealed record ControlJournal([property: JsonRequired] TweakPlan Plan, [property: JsonRequired] string ReviewHash, [property: JsonRequired] int Attempted, string Phase = "applying", string? Boot = null);

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
    public static readonly IReadOnlySet<string> HiddenPresets = new HashSet<string>(["fsos.hyper-v.54.enabled", "fsos.vbs.76.enabled"], StringComparer.Ordinal);
    public const string HypervisorTogether = "Hyper-V features and Hypervisor at startup can't change in the same apply. Apply one, restart Windows, then apply the other.";
    public const string HypervisorOwned = "Undo the FPS preset (or set Hypervisor at startup back to No override) first, apply, restart Windows, then change Hyper-V features. Windows resets Hypervisor at startup when it finishes Hyper-V changes.";
    public const string HypervisorPending = "Restart Windows first, then change Hypervisor at startup. A Windows feature change is still waiting for restart and can reset it.";
    public static ControlPlan Plan(TweakState? state, TweakProfile[] profiles, string profileId, Func<ControlAddress, TweakControlRead> read)
    {
        var affected = (state?.Profiles.SingleOrDefault(profile => profile.Id == profileId)?.Controls ?? []).Select(claim => claim.Target.Id)
            .Concat((profiles.SingleOrDefault(profile => profile.Id == profileId)?.Controls ?? []).Select(claim => claim.Target.Id)).ToHashSet(StringComparer.Ordinal);
        var wanted = profiles.SelectMany(profile => profile.Controls ?? []).GroupBy(claim => claim.Target.Id).ToDictionary(group => group.Key, group => group.ToArray());
        foreach (var claims in wanted.Values) ControlComposition.Check(claims);
        var held = (state?.Controls ?? []).ToDictionary(item => item.Original.Id);
        var expected = new List<TweakControlRead>(); var changes = new List<ControlMutation>(); var next = new List<ControlHeld>(); var left = new List<string>(); var released = new List<ControlRelease>(); string? guard = null;
        static bool Linked(ControlAddress address) => address.Kind == "memory" || address.Kind == "service" && address.Target.Equals("SysMain", StringComparison.OrdinalIgnoreCase);
        var requestsLinked = false;
        foreach (var id in held.Keys.Concat(wanted.Keys).Distinct().Order(StringComparer.Ordinal))
        {
            held.TryGetValue(id, out var original); wanted.TryGetValue(id, out var claims);
            if (!affected.Contains(id)) { next.Add(original!); continue; }
            var before = (state?.Profiles ?? []).SelectMany(profile => profile.Controls ?? []).Where(claim => claim.Target.Id == id).ToArray();
            var asks = (claims ?? []).Any(claim => !before.Any(old => ReferenceEquals(old, claim)));
            requestsLinked |= (claims ?? []).Any(claim => Linked(claim.Target.Address) && !before.Any(old => old.SettingId == claim.SettingId && old.OptionId == claim.OptionId));
            TweakControlRead observed; (JsonElement Desired, JsonElement? Restore, string[]? LeftAsChanged, JsonElement? Applied) composed = default;
            try
            {
                observed = read((claims?.First().Target ?? original!.Original).Address); observed.Validate();
                if (!observed.RestartPending)
                {
                    if (observed.Id != id) throw new InvalidDataException("A Windows control changed outside this profile: " + observed.Address.Target);
                    if (claims is not null && claims.Any(claim => !claim.Target.Same(observed) && !held.ContainsKey(id)))
                        throw new InvalidDataException("A Windows control changed during review: " + observed.Address.Target);
                    composed = ControlComposition.Resolve(observed, original, before, claims ?? []);
                    if (observed.Address.Kind == "hibernation") { HibernationControl.Validate(observed.Value); HibernationControl.Validate(composed.Desired); }
                }
            }
            catch (Exception error) when (!asks && original is not null && error is not (TimeoutException or OperationCanceledException) && (error is not IOException || error is FileNotFoundException or DirectoryNotFoundException))
            {
                left.AddRange(before.Where(claim => claims?.Any(kept => ReferenceEquals(kept, claim)) != true).Select(claim => claim.SettingId));
                if (claims is not null) next.Add(original);
                continue;
            }
            if (observed.RestartPending) throw new InvalidDataException("Restart Windows before changing or restoring pending Windows features.");
            expected.Add(observed);
            left.AddRange(composed.LeftAsChanged ?? []);
            if (!ControlValues.Equal(observed.Value, composed.Desired) || observed.Address.Kind is "timer" or "timer-startup" or "download-blocker" && observed.LostLease && claims is null) changes.Add(new(observed, composed.Desired, before.Concat(claims ?? []).All(claim => claim.Patch) ? before.Concat(claims ?? []).SelectMany(claim => claim.Desired.EnumerateObject().Select(property => property.Name)).Distinct(StringComparer.Ordinal).ToArray() : null));
            if (claims is not null) next.Add(new(original is null ? observed : original.Original with { Address = observed.Address }, composed.Applied ?? composed.Desired, composed.Restore));
            else if (original is not null && changes.All(change => change.Before.Id != observed.Id))
                released.Add(new(original, before.Length > 0 && before.All(claim => claim.Patch) || observed.Address.Kind is "device-power" or "network-adapter" && observed.Value.ValueKind == JsonValueKind.Object));
        }
        var turnsOn = changes.Any(change => change.Before.Address.Kind == "memory" && change.After.ValueKind == JsonValueKind.True);
        var relevant = turnsOn || affected.Any(id => wanted.GetValueOrDefault(id)?.Any(claim => Linked(claim.Target.Address)) == true || held.TryGetValue(id, out var owned) && Linked(owned.Original.Address));
        if (relevant && (turnsOn || wanted.Values.Any(claims => claims[0].Target.Address.Kind == "memory" && claims[0].Desired.ValueKind == JsonValueKind.True)))
        {
            var dependency = read(new("service", "SysMain", "startup")); dependency.Validate();
            var planned = changes.FirstOrDefault(change => change.Before.Id == dependency.Id);
            if (turnsOn || planned is not null || requestsLinked)
            {
                var owners = wanted.GetValueOrDefault(dependency.Id) ?? [];
                if ((planned?.After ?? dependency.Value).GetUInt32() == 4 || owners.Any(claim => claim.Desired.GetUInt32() == 4))
                    throw new InvalidDataException("Memory compression needs the SysMain service enabled. Keep SysMain enabled, or turn memory compression off first.");
                var added = expected.All(item => item.Id != dependency.Id);
                if (added) expected.Add(dependency);
                if (planned is null && (added || released.Any(item => item.Held.Original.Id == dependency.Id))) guard = dependency.Id;
            }
        }
        var launch = new ControlAddress("boot-configuration", "current", "hypervisorlaunchtype").Key;
        var launchChanges = changes.Any(change => change.Before.Address.Key == launch);
        if (changes.Any(change => change.Before.Address.Kind == "windows-features" && WindowsFeatures.Changed(change).Any(WindowsFeatures.IsHypervisor)) &&
            (launchChanges || next.Any(item => item.Original.Address.Key == launch)))
            throw new InvalidDataException(launchChanges ? HypervisorTogether : HypervisorOwned);
        if (launchChanges)
        {
            TweakControlRead? features;
            try { features = read(new("windows-features", "system", "features")); }
            catch (FileNotFoundException) { features = null; }
            if (features?.RestartPending == true) throw new InvalidDataException(HypervisorPending);
        }
        return new(expected.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray(), changes.OrderBy(ChangeOrder).ThenBy(change => change.Before.Id, StringComparer.Ordinal).ToArray(), next.ToArray(), left.Count > 0 ? left.Distinct().Order(StringComparer.Ordinal).ToArray() : null, released.Count > 0 ? released.OrderBy(item => item.Held.Original.Id, StringComparer.Ordinal).ToArray() : null, guard);
    }
    private static int ChangeOrder(ControlMutation change) => change.Before.Address.Kind == "windows-features" ? 40 : change.Before.Address.Kind == "timer" && change.After.ValueKind == JsonValueKind.False ? 0 : change.Before.Address.Kind == "memory" ? 25 : change.Before.Address.Property switch
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
        foreach (var expected in plan.Owned)
            if (!store.Read(expected.Address).Same(expected)) throw new InvalidDataException("A Windows control changed after review: " + expected.Address.Target);
        plan.CheckReleased(store.Read);
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
                if (current.RestartPending) throw new InvalidDataException(WindowsFeatures.PendingRecovery(change, current));
                if (current.Same(change.Before) && !current.LostLease) continue;
                if (change.Fields is { Length: > 0 })
                {
                    if (current.Id != change.Before.Id || current.Binding != change.Before.Binding || current.Value.ValueKind != JsonValueKind.Object ||
                        change.Fields.Any(field => !current.Value.TryGetProperty(field, out var value) || !KnownIntermediate(value, change.Before.Value.GetProperty(field), change.After.GetProperty(field))))
                        throw new InvalidDataException("An owned policy field has a newer value or identity.");
                    var restored = ControlValues.From(current.Value.EnumerateObject().ToDictionary(property => property.Name,
                        property => change.Fields.Contains(property.Name, StringComparer.Ordinal) ? change.Before.Value.GetProperty(property.Name) : property.Value));
                    if (current.Address.Kind == "mitigations" && current.Value.TryGetProperty(MitigationControl.SnapshotField, out _))
                        restored = MitigationControl.RestoreFields(current.Value, change.Before.Value, change.Fields);
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
                if (!(change.Before.Address.Kind == "download-blocker" ? restoredRead.Id == change.Before.Id && restoredRead.Binding == change.Before.Binding && ControlValues.Equal(restoredRead.Value, change.Before.Value) && !restoredRead.LostLease : restoredRead.Same(change.Before)))
                    throw new InvalidDataException("Restoration readback differs from the original.");
            }
            catch (Exception error) { failures.Add(change.Before.Address.Target + ": " + error.Message); }
        }
        if (failures.Count > 0) throw new InvalidOperationException("Recovery still needs attention: " + string.Join("; ", failures));
    }
}
