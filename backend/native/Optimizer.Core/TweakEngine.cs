#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class TweakEngine
{
    private readonly TweakCatalog _catalog;
    private readonly ITweakStore _store;
    public TweakEngine(TweakCatalog catalog, ITweakStore store) { catalog.Validate(); _catalog = catalog; _store = store; }

    public object Detect()
    {
        var state = State();
        return new { context = _store.Context, catalogVersion = _catalog.Version, state, settings = _catalog.Settings.Select(definition =>
        {
            try
            {
                var supported = Supported(definition);
                var readings = definition.Options.SelectMany(option => option.Changes).Select(change => change.Address).Distinct().ToDictionary(address => address, Read);
                var reads = readings.Values.DistinctBy(read => read.Id).ToArray();
                if (readings.Values.Any(read => !read.Same(reads.Single(item => item.Id == read.Id)))) throw new InvalidDataException("A setting changed while being read.");
                var matches = definition.Options.Where(option => option.Changes.All(change => TweakRead.SameValue(readings[change.Address].Value, Desired(change)))).Select(option => option.Id).ToArray();
                return (object)new { id = definition.Id, definition.Name, supported, configuredChoices = matches, observations = reads, error = (string?)null };
            }
            catch (Exception error) { return new { id = definition.Id, definition.Name, supported = false, configuredChoices = Array.Empty<string>(), observations = Array.Empty<TweakRead>(), error = error.Message }; }
        }).ToArray() };
    }

    public TweakPlan Preview(string profileId, TweakSelection[] selections)
        => Plan(profileId, selections, Guid.NewGuid().ToString("N"), DateTime.UtcNow, Guid.NewGuid().ToString("N"));

    public TweakApplyResult Apply(string previewPath, string reviewHash)
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
        if (plan.Selections.Length > 0 && _catalog.Digest != plan.CatalogHash) throw new InvalidDataException("The setting definitions changed since review.");
        var current = Plan(plan.ProfileId, plan.Selections, plan.OperationId, plan.CreatedAtUtc, plan.AfterRevision) with { CatalogHash = plan.CatalogHash };
        if (JsonSerializer.Serialize(current, OperationFiles.Json) != JsonSerializer.Serialize(plan, OperationFiles.Json))
            throw new InvalidDataException("The reviewed settings or their current values changed. Review again.");
        return new(_store.Commit(plan, reviewHash), plan.Changes.Length != 0, false);
    }

    private TweakPlan Plan(string profileId, TweakSelection[] selections, string operationId, DateTime created, string revision)
    {
        if (string.IsNullOrWhiteSpace(profileId) || profileId.Length > 100 || selections is null || selections.Length > 1000)
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
            foreach (var selection in selections)
            {
                var (definition, option) = _catalog.Resolve(selection);
                if (!Supported(definition)) throw new InvalidDataException(definition.Name + " is not supported on this Windows build or edition.");
                foreach (var change in option.Changes) claims.Add(new(definition.Id, option.Id, Capture(change.Address), Desired(change)));
            }
            foreach (var claim in claims) affected.Add(claim.Target.Id);
            profiles.Add(new(profileId, _catalog.Digest, selections, claims.ToArray()));
        }
        var wanted = new Dictionary<string, TweakClaim>(StringComparer.Ordinal);
        foreach (var claim in profiles.SelectMany(profile => profile.Claims))
        {
            claim.Target.Validate();
            if (wanted.TryGetValue(claim.Target.Id, out var previous) && !TweakRead.SameValue(previous.Desired, claim.Desired))
                throw new InvalidDataException("Conflicting choices for one Windows setting: " + previous.SettingId + " and " + claim.SettingId);
            wanted[claim.Target.Id] = claim;
        }
        var held = (state?.Held ?? []).ToDictionary(item => item.Original.Id, StringComparer.Ordinal);
        var next = new List<TweakHeldValue>();
        var changes = new List<TweakMutation>();
        foreach (var id in held.Keys.Concat(wanted.Keys).Distinct().Order(StringComparer.Ordinal))
        {
            held.TryGetValue(id, out var original);
            wanted.TryGetValue(id, out var desired);
            if (!affected.Contains(id)) { next.Add(original!); continue; }
            var observed = Capture((desired?.Target ?? original!.Original).Address);
            if (observed.Id != id) throw new InvalidDataException("A registry target now resolves to a different resource.");
            if (original is not null && !TweakRead.SameValue(observed.Value, original.Applied))
                throw new InvalidDataException("A setting was changed outside this profile: " + observed.Address.KeyPath + " / " + observed.Address.ValueName);
            var after = desired is null ? original!.Original.Value : desired.Desired;
            if (!TweakRead.SameValue(observed.Value, after)) changes.Add(new(observed, after));
            if (desired is not null) next.Add(new(original?.Original ?? observed, after));
        }
        return new()
        {
            SchemaVersion = 1, OperationId = operationId, CreatedAtUtc = created, Context = _store.Context, CatalogHash = _catalog.Digest,
            BeforeRevision = state?.Revision, AfterRevision = revision, ProfileId = profileId, Selections = selections,
            Expected = reads.Values.OrderBy(read => read.Id, StringComparer.Ordinal).ToArray(), Changes = changes.ToArray(),
            Profiles = profiles.OrderBy(profile => profile.Id, StringComparer.Ordinal).ToArray(), Held = next.ToArray(),
        };
    }

    private bool Supported(TweakDefinition definition) => _store.Context.WindowsBuild >= definition.MinimumBuild && _store.Context.WindowsBuild <= definition.MaximumBuild &&
        (definition.Editions.Contains("*") || definition.Editions.Contains(_store.Context.Edition, StringComparer.OrdinalIgnoreCase));
    private TweakRead Read(RegistryAddress address) { var result = _store.Read(address); result.Validate(); return result; }
    private static RegistryValueData? Desired(TweakAssignment change) => change.Dword is { } value ? new(change.Address.ValueName!, 4, BitConverter.GetBytes(value)) : null;
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
        foreach (var held in state.Held) held.Original.Validate();
        var claims = state.Profiles.SelectMany(profile => profile.Claims).ToArray();
        if (!claims.Select(claim => claim.Target.Id).Distinct().Order().SequenceEqual(state.Held.Select(item => item.Original.Id).Order()) ||
            claims.Any(claim => !TweakRead.SameValue(claim.Desired, state.Held.Single(item => item.Original.Id == claim.Target.Id).Applied)))
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
        CreatedKeys = previous?.CreatedKeys ?? [], Notices = [],
        History = [.. (previous?.History.TakeLast(127) ?? []), new(plan.OperationId, reviewHash, plan.ProfileId, DateTime.UtcNow, plan.Changes)],
    };
}
