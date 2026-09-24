#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class TweakEngine
{
    private readonly TweakCatalog _catalog;
    private readonly ITweakStore _store;
    public TweakEngine(TweakCatalog catalog, ITweakStore store) { catalog.Validate(); _catalog = catalog; _store = store; }

    public TweakInspection Detect()
    {
        var state = State();
        var controlCache = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
        TweakControlRead InspectControl(ControlAddress address)
        {
            if (!controlCache.TryGetValue(address, out var cached))
            {
                try { var read = _store.ReadControl(address); read.Validate(); cached = (read, null); }
                catch (Exception error) { cached = (null, error); }
                controlCache.Add(address, cached);
            }
            return cached.Read ?? throw new InvalidDataException(cached.Error!.Message, cached.Error);
        }
        return new(_store.Context, _catalog.Version, state, _catalog.Settings.Select(definition =>
        {
            try
            {
                var supported = Supported(definition);
                foreach (var requirement in definition.Requirements ?? []) _store.CheckRequirement(requirement);
                var resolvedOptions = definition.Options.Select(option => option with { Changes = option.Changes.SelectMany(_store.Resolve).ToArray() }).ToArray();
                var readings = resolvedOptions.SelectMany(option => option.Changes).Select(change => change.Address).Distinct().ToDictionary(address => address, Read);
                var controls = definition.Options.SelectMany(option => option.Controls ?? []).Select(change => change.Address).Distinct().ToDictionary(address => address, InspectControl);
                var reads = readings.Values.DistinctBy(read => read.Id).ToArray();
                if (readings.Values.Any(read => !read.Same(reads.Single(item => item.Id == read.Id)))) throw new InvalidDataException("A setting changed while being read.");
                var matches = resolvedOptions.Where(option => option.Changes.All(change => TweakComposition.Matches(new(definition.Id, option.Id, readings[change.Address], Desired(change), change.Token, change.Bits), readings[change.Address].Value)) && (option.Controls ?? []).All(change => ControlComposition.Matches(new(definition.Id, option.Id, controls[change.Address], controls[change.Address].Expand(change.Value, allowPending: true), change.Patch), controls[change.Address].Value))).Select(option => option.Id).ToArray();
                var available = definition.Options.Where(option => Supported(option) && (option.Controls ?? []).All(control => controls[control.Address].Allows(control.Value))).Select(option => option.Id).ToArray();
                supported &= available.Length > 0;
                return new TweakSettingStatus(definition.Id, definition.Name, supported, matches, reads, supported ? null : "No choice applies to this Windows version, edition or installed product.", available, controls.Values.ToArray());
            }
            catch (Exception error) { return new TweakSettingStatus(definition.Id, definition.Name, false, [], [], error.Message); }
        }).ToArray());
    }

    public TweakPlan Preview(string profileId, TweakSelection[] selections)
        => Plan(profileId, selections, Guid.NewGuid().ToString("N"), DateTime.UtcNow, Guid.NewGuid().ToString("N"));
    public TweakPlan PreviewPreset(string profileId, string presetId)
        => PlanPreset(profileId, presetId, Guid.NewGuid().ToString("N"), DateTime.UtcNow, Guid.NewGuid().ToString("N"));
    private TweakPlan PlanPreset(string profileId, string presetId, string operationId, DateTime created, string revision)
    {
        var preset = _catalog.Presets.SingleOrDefault(item => item.Id == presetId) ?? throw new InvalidDataException("Unknown setting preset.");
        var choices = preset.Selections;
        if (preset.AvailableOnly)
        {
            var available = Detect().Settings.ToDictionary(setting => setting.Id);
            choices = choices.Where(choice => available[choice.SettingId].Supported && available[choice.SettingId].AvailableChoices?.Contains(choice.OptionId) == true).ToArray();
            if (choices.Length == 0) throw new InvalidDataException("None of this preset's settings are available on this PC.");
        }
        return Plan(profileId, choices, operationId, created, revision) with { PresetId = presetId, Skipped = preset.Selections.Except(choices).Select(choice => _catalog.Resolve(choice).Definition.Name).Distinct().ToArray() };
    }

    public TweakApplyResult Apply(string previewPath, string reviewHash, bool acceptDataLoss = false)
    {
        var plan = OperationFiles.Read<TweakPlan>(previewPath, reviewHash);
        ValidatePlan(plan);
        var state = State();
        var receipt = state?.History.SingleOrDefault(item => item.OperationId == plan.OperationId);
        if (receipt is not null)
        {
            if (!string.Equals(receipt.ReviewHash, reviewHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("This operation ID was already used for a different review.");
            return new(state!, false, true);
        }
        if (state?.Revision != plan.BeforeRevision) throw new InvalidDataException("Settings changed since review. Create a new preview.");
        if (plan.DataLoss.Length > 0 && !acceptDataLoss) throw new InvalidDataException("This review includes irreversible data effects. Explicitly acknowledge the listed data loss before applying.");
        if (plan.Selections.Length > 0 && _catalog.Digest != plan.CatalogHash) throw new InvalidDataException("The setting definitions changed since review.");
        var current = (plan.PresetId is null ? Plan(plan.ProfileId, plan.Selections, plan.OperationId, plan.CreatedAtUtc, plan.AfterRevision)
            : PlanPreset(plan.ProfileId, plan.PresetId, plan.OperationId, plan.CreatedAtUtc, plan.AfterRevision)) with { CatalogHash = plan.CatalogHash };
        if (JsonSerializer.Serialize(current, OperationFiles.Json) != JsonSerializer.Serialize(plan, OperationFiles.Json))
            throw new InvalidDataException("The reviewed settings or their current values changed. Review again.");
        return new(_store.Commit(plan, reviewHash), plan.Changes.Length != 0 || plan.Controls?.Changes.Length > 0, false);
    }

    private TweakPlan Plan(string profileId, TweakSelection[] selections, string operationId, DateTime created, string revision)
    {
        if (string.IsNullOrWhiteSpace(profileId) || profileId.Length > 100 || selections is null || selections.Length > 4096)
            throw new InvalidDataException("A profile ID and explicit selections are required.");
        selections = selections.Distinct().OrderBy(item => item.SettingId, StringComparer.Ordinal).ThenBy(item => item.OptionId, StringComparer.Ordinal).ToArray();
        if (selections.GroupBy(item => item.SettingId).Any(group => group.Count() > 1)) throw new InvalidDataException("A setting has conflicting choices.");
        var state = State();
        var profiles = (state?.Profiles ?? []).Where(profile => profile.Id != profileId).ToList();
        var affected = (state?.Profiles.SingleOrDefault(profile => profile.Id == profileId)?.Claims ?? []).Select(claim => claim.Target.Id).ToHashSet(StringComparer.Ordinal);
        var reads = new Dictionary<string, TweakRead>(StringComparer.Ordinal);
        TweakRead Capture(RegistryAddress address)
        {
            var read = Read(address);
            if (reads.TryGetValue(read.Id, out var previous) && !previous.Same(read)) throw new InvalidDataException("A setting changed while preparing the plan.");
            reads[read.Id] = read;
            return read;
        }
        if (selections.Length > 0)
        {
            var claims = new List<TweakClaim>();
            var controlClaims = new List<ControlClaim>();
            foreach (var selection in selections)
            {
                var (definition, option) = _catalog.Resolve(selection);
                if (!Supported(definition) || !Supported(option)) throw new InvalidDataException(definition.Name + " is not supported on this Windows build or edition.");
                foreach (var requirement in definition.Requirements ?? []) _store.CheckRequirement(requirement);
                foreach (var control in option.Controls ?? []) { var observed = _store.ReadControl(control.Address); observed.Validate(); if (!observed.Allows(control.Value)) throw new InvalidDataException("This Windows control does not support that value: " + control.Address.Target); controlClaims.Add(new(definition.Id, option.Id, observed, observed.Expand(control.Value), control.Patch)); }
                foreach (var change in option.Changes.SelectMany(_store.Resolve)) claims.Add(new(definition.Id, option.Id, Capture(change.Address), Desired(change), change.Token, change.Bits));
            }
            foreach (var claim in claims) affected.Add(claim.Target.Id);
            profiles.Add(new(profileId, _catalog.Digest, selections, claims.ToArray(), controlClaims.ToArray(), selections.SelectMany(selection => _catalog.Resolve(selection).Option.DataLoss ?? []).Concat(TweakDataEffects.Warnings(claims.ToArray(), controlClaims.ToArray())).Distinct().ToArray()));
        }
        var wanted = profiles.SelectMany(profile => profile.Claims).GroupBy(claim => claim.Target.Id).ToDictionary(group => group.Key, group => group.ToArray(), StringComparer.Ordinal);
        foreach (var group in wanted.Values)
        {
            foreach (var claim in group) claim.Target.Validate();
            TweakComposition.Check(group);
        }
        var held = (state?.Held ?? []).ToDictionary(item => item.Original.Id, StringComparer.Ordinal);
        var next = new List<TweakHeldValue>();
        var changes = new List<TweakMutation>();
        var left = new List<string>();
        foreach (var id in held.Keys.Concat(wanted.Keys).Distinct().Order(StringComparer.Ordinal))
        {
            held.TryGetValue(id, out var original);
            wanted.TryGetValue(id, out var desired);
            if (!affected.Contains(id)) { next.Add(original!); continue; }
            var oldClaims = (state?.Profiles ?? []).SelectMany(profile => profile.Claims).Where(claim => claim.Target.Id == id).ToArray();
            var asks = (desired ?? []).Any(claim => !oldClaims.Any(old => ReferenceEquals(old, claim)));
            TweakRead observed; TweakResolution after;
            try
            {
                observed = Capture((desired?.First().Target ?? original!.Original).Address);
                if (observed.Id != id) throw new InvalidDataException("A registry target now resolves to a different resource.");
                after = TweakComposition.Resolve(observed, original, oldClaims, desired ?? []);
            }
            catch (Exception error) when (!asks && original is not null && error is not (TimeoutException or OperationCanceledException) && (error is not IOException || error is FileNotFoundException or DirectoryNotFoundException))
            {
                left.AddRange(oldClaims.Where(claim => desired?.Any(kept => ReferenceEquals(kept, claim)) != true).Select(claim => claim.SettingId));
                if (desired is not null) next.Add(original);
                continue;
            }
            left.AddRange(after.LeftAsChanged ?? []);
            if (!TweakRead.SameValue(observed.Value, after.Value)) changes.Add(new(observed, after.Value));
            if (desired is not null) next.Add(new(original?.Original ?? observed, after.Applied ?? after.Value, after.RestoreValue, after.Composed));
        }
        var controls = ControlPlanning.Plan(state, profiles.ToArray(), profileId, _store.ReadControl);
        return new()
        {
            SchemaVersion = 1, OperationId = operationId, CreatedAtUtc = created, Context = _store.Context, CatalogHash = _catalog.Digest,
            BeforeRevision = state?.Revision, AfterRevision = revision, ProfileId = profileId, Selections = selections,
            Expected = reads.Values.OrderBy(read => read.Id, StringComparer.Ordinal).ToArray(), Changes = changes.ToArray(),
            Profiles = profiles.OrderBy(profile => profile.Id, StringComparer.Ordinal).ToArray(), Held = next.ToArray(), Controls = controls,
            LeftAsChanged = left.Concat(controls.LeftAsChanged ?? []).Distinct().Order(StringComparer.Ordinal).ToArray(),
            DataLoss = selections.Length > 0 ? profiles.Single(profile => profile.Id == profileId).DataLoss ?? []
                : state?.Profiles.SingleOrDefault(profile => profile.Id == profileId)?.DataLoss is { Length: > 0 } ? ["Restore returns the saved settings. Data deleted by the earlier changes cannot be restored."] : [],
        };
    }

    private bool Supported(TweakDefinition definition) => _store.Context.WindowsBuild >= definition.MinimumBuild && _store.Context.WindowsBuild <= definition.MaximumBuild &&
        (definition.Editions.Contains("*") || definition.Editions.Contains(_store.Context.Edition, StringComparer.OrdinalIgnoreCase));
    private bool Supported(TweakOption option) => (option.ValidUntilUtc is null || DateTime.UtcNow < option.ValidUntilUtc.Value) && (option.Availability is null || option.Availability.Any(gate =>
        _store.Context.WindowsBuild >= gate.MinimumBuild && _store.Context.WindowsBuild <= gate.MaximumBuild &&
        (gate.Editions.Contains("*") || gate.Editions.Contains(_store.Context.Edition, StringComparer.OrdinalIgnoreCase)) && (gate.Requirements ?? []).All(RequirementAvailable)));
    private bool RequirementAvailable(string requirement)
    {
        try { _store.CheckRequirement(requirement); return true; }
        catch (Exception error) when (error is InvalidDataException or IOException or System.ComponentModel.Win32Exception) { return false; }
    }
    private TweakRead Read(RegistryAddress address) { address = address with { KeyPath = address.KeyPath.Replace("{user-sid}", _store.Context.Owner.UserSid, StringComparison.OrdinalIgnoreCase) }; var result = _store.Read(address); result.Validate(); return result; }
    private static RegistryValueData? Desired(TweakAssignment change) => change.Dword is { } value ? new(change.Address.ValueName!, 4, BitConverter.GetBytes(value)) : change.Value;
    private TweakState? State()
    {
        var state = _store.ReadState();
        if (state is null) return null;
        ValidateState(state, _store.Context);
        return state;
    }
    private void ValidatePlan(TweakPlan plan)
    {
        if (plan.SchemaVersion != 1 || plan.Context != _store.Context || !Guid.TryParseExact(plan.OperationId, "N", out _) || !Guid.TryParseExact(plan.AfterRevision, "N", out _) ||
            plan.Selections is null || plan.Expected is null || plan.Changes is null || plan.Profiles is null || plan.Held is null || string.IsNullOrWhiteSpace(plan.CatalogHash))
            throw new InvalidDataException("The review is incomplete or belongs to another Windows user, machine, or store.");
        foreach (var read in plan.Expected) read.Validate();
    }
    public static void ValidateState(TweakState state, TweakContext context)
    {
        if (state.SchemaVersion != 1 || (state.Context?.Owner != context.Owner || state.Context.StoreId != context.StoreId) || string.IsNullOrWhiteSpace(state.Revision) || state.Profiles is null || state.Held is null ||
            state.CreatedKeys is null || state.History is null || state.Notices is null || state.Profiles.Any(profile => profile is null || string.IsNullOrWhiteSpace(profile.Id) || profile.Claims is null || profile.Selections is null || string.IsNullOrWhiteSpace(profile.CatalogHash)) ||
            state.Profiles.Select(profile => profile.Id).Distinct().Count() != state.Profiles.Length ||
            state.Held.Select(item => item.Original.Id).Distinct().Count() != state.Held.Length || state.History.Select(item => item.OperationId).Distinct().Count() != state.History.Length)
            throw new InvalidDataException("The saved tweak state is incomplete or belongs to another Windows user, machine, or store.");
        ControlPlanning.Validate(state);
        foreach (var held in state.Held) held.Original.Validate();
        var claims = state.Profiles.SelectMany(profile => profile.Claims).ToArray();
        if (!claims.Select(claim => claim.Target.Id).Distinct().Order().SequenceEqual(state.Held.Select(item => item.Original.Id).Order()) ||
            claims.Any(claim => !TweakComposition.Matches(claim, state.Held.Single(item => item.Original.Id == claim.Target.Id).Applied)))
            throw new InvalidDataException("Profile ownership and saved values disagree.");
    }
    public static byte[] SerializeState(TweakState state)
    {
        while (true)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(state, OperationFiles.Json);
            if (bytes.Length <= 8 * 1024 * 1024) return bytes;
            if (state.History.Length <= 1) throw new InvalidDataException("Active recovery data exceeds the state size limit. No changes were committed.");
            state.History = state.History.Skip(Math.Max(1, state.History.Length / 2)).ToArray();
        }
    }
    public static TweakState NextState(TweakPlan plan, string reviewHash, TweakState? previous) => new()
    {
        SchemaVersion = 1, Context = plan.Context, Revision = plan.AfterRevision, Profiles = plan.Profiles, Held = plan.Held,
        CreatedKeys = previous?.CreatedKeys ?? [], Notices = [], Controls = plan.Controls?.Held ?? [],
        History = [.. (previous?.History.TakeLast(127) ?? []), new(plan.OperationId, reviewHash, plan.ProfileId, DateTime.UtcNow, plan.Changes, plan.Controls?.Changes)],
    };
}
