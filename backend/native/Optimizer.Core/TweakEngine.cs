#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class TweakEngine
{
    private readonly TweakCatalog _catalog;
    private readonly ITweakStore _store;
    public TweakEngine(TweakCatalog catalog, ITweakStore store) { catalog.Validate(); _catalog = catalog; _store = store; }

    public const string FeaturesPending = "Checking Windows features\u2026";
    public const string FeaturesTimedOut = "Windows did not answer within 60 seconds. Select Refresh to check again.";
    public TimeSpan FeatureTimeout { get; init; } = TimeSpan.FromSeconds(60);
    public TimeSpan ReadTimeout { get; init; } = TimeSpan.FromSeconds(60);
    public static bool IsTransient(string error) => error == FeaturesTimedOut || error == FeaturesPending || error.Contains("timed out", StringComparison.OrdinalIgnoreCase)
        || error.Contains("control helper exited", StringComparison.Ordinal) || error.Contains("changed while being read", StringComparison.Ordinal) || error.Contains("service is transitioning", StringComparison.Ordinal);
    public static bool HasTransientErrors(TweakInspection inspection) => inspection.Settings.Any(setting => setting.Error is { } error && IsTransient(error));
    public TweakInspection Detect(Action<TweakInspection>? partial = null)
    {
        var state = State();
        var requirementErrors = _catalog.Settings.Select(definition =>
        {
            try { foreach (var requirement in definition.Requirements ?? []) _store.CheckRequirement(requirement); return null; }
            catch (Exception error) { return error; }
        }).ToArray();
        var addresses = _catalog.Settings.Where((_, index) => requirementErrors[index] is null).SelectMany(definition => definition.Options.Where(Supported)).SelectMany(option => option.Controls ?? []).Select(control => control.Address).Distinct().ToArray();
        var slow = addresses.Where(address => address.Kind is "windows-features" or "windows-feature" or "reserved-storage").ToArray();
        var fast = addresses.Except(slow).ToArray();
        var fastRead = _store.ReadControlsAsync(fast);
        var slowRead = slow.Length == 0 ? null : _store.ReadControlsAsync(slow);
        var slowDeadline = slowRead is null ? null : Task.Delay(FeatureTimeout);
        var prepared = _catalog.Settings.Select((definition, index) =>
        {
            try
            {
                var supported = Supported(definition);
                if (requirementErrors[index] is { } failed) throw failed;
                var resolvedOptions = definition.Options.Where(Supported).Select(option => option with { Changes = option.Changes.SelectMany(_store.Resolve).ToArray() }).ToArray();
                var readings = resolvedOptions.SelectMany(option => option.Changes).Select(change => change.Address).Distinct().ToDictionary(address => address, Read);
                return (Definition: definition, Supported: supported, Options: resolvedOptions, Readings: readings, Error: (Exception?)null);
            }
            catch (Exception error) { return (Definition: definition, Supported: false, Options: Array.Empty<TweakOption>(), Readings: new Dictionary<RegistryAddress, TweakRead>(), Error: error); }
        }).ToArray();
        static Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> Collect(Task<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>>? read, ControlAddress[] addresses)
        {
            var results = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
            Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>? answered = null;
            Exception? faulted = null;
            if (read is not null)
                try { answered = read.GetAwaiter().GetResult(); }
                catch (Exception error) { faulted = error; }
            foreach (var address in addresses)
                results[address] = answered is not null && answered.TryGetValue(address, out var found) ? found : (null, faulted ?? new InvalidDataException("Windows returned no answer for this setting."));
            return results;
        }
        TweakInspection Inspect(Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> prefetched)
        {
            var controlCache = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
            TweakControlRead InspectControl(ControlAddress address)
            {
                if (!controlCache.TryGetValue(address, out var cached))
                {
                    try
                    {
                        var (read, failure) = prefetched.TryGetValue(address, out var found) ? found : (null, new InvalidDataException("Windows returned no answer for this setting."));
                        if (failure is not null) throw failure;
                        read!.Validate(); cached = (read, null);
                    }
                    catch (Exception error) { cached = (null, error); }
                    controlCache.Add(address, cached);
                }
                return cached.Read ?? throw new InvalidDataException(cached.Error!.Message, cached.Error);
            }
            return new(_store.Context, _catalog.Version, state, prepared.Select(entry =>
            {
                var (definition, supported, resolvedOptions, readings, failure) = entry;
                try
                {
                    if (failure is not null) throw failure;
                    var controls = resolvedOptions.SelectMany(option => option.Controls ?? []).Select(change => change.Address).Distinct().ToDictionary(address => address, InspectControl);
                    var reads = readings.Values.DistinctBy(read => read.Id).ToArray();
                    if (readings.Values.Any(read => !read.Same(reads.Single(item => item.Id == read.Id)))) throw new InvalidDataException("A setting changed while being read.");
                    var available = resolvedOptions.Where(option => (option.Controls ?? []).All(control => controls[control.Address].Allows(control.Value))).Select(option => option.Id).ToArray();
                    var matches = resolvedOptions.Where(option => supported && available.Contains(option.Id) && option.Changes.All(change => TweakComposition.Matches(new(definition.Id, option.Id, readings[change.Address], Desired(change), change.Token, change.Bits), readings[change.Address].Value)) && (option.Controls ?? []).All(change => (change.Address.Kind != "windows-features" || controls[change.Address].Allows(change.Value)) && ControlComposition.Matches(new(definition.Id, option.Id, controls[change.Address], controls[change.Address].Expand(change.Value, allowPending: true), change.Patch), controls[change.Address].Value))).Select(option => option.Id).ToArray();
                    supported &= available.Length > 0;
                    return new TweakSettingStatus(definition.Id, definition.Name, supported, matches, reads, supported ? null : "No choice applies to this Windows version, edition or installed product.", available, controls.Values.ToArray());
                }
                catch (Exception error) { return new TweakSettingStatus(definition.Id, definition.Name, false, [], [], error.Message); }
            }).ToArray());
        }
        var fastDeadline = Task.Delay(ReadTimeout);
        Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> prefetched;
        if (Task.WhenAny(fastRead, fastDeadline).GetAwaiter().GetResult() != fastRead)
        {
            _ = fastRead.ContinueWith(task => task.Exception, TaskScheduler.Default);
            prefetched = fast.ToDictionary(address => address, address => ((TweakControlRead?)null, (Exception?)new TimeoutException(FeaturesTimedOut)));
        }
        else prefetched = Collect(fastRead, fast);
        if (partial is not null && slowRead is { IsCompleted: false } && fast.All(prefetched.ContainsKey))
        {
            var pending = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>(prefetched);
            foreach (var address in slow) pending[address] = (null, new InvalidDataException(FeaturesPending));
            partial(Inspect(pending));
        }
        if (slowRead is not null && Task.WhenAny(slowRead, slowDeadline!).GetAwaiter().GetResult() != slowRead)
        {
            _ = slowRead.ContinueWith(task => task.Exception, TaskScheduler.Default);
            foreach (var address in slow) prefetched[address] = (null, new TimeoutException(FeaturesTimedOut));
        }
        else foreach (var (address, result) in Collect(slowRead, slow)) prefetched[address] = result;
        return Inspect(prefetched);
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
            if (choices.Any(choice => available[choice.SettingId].Error == FeaturesTimedOut)) throw new TimeoutException(FeaturesTimedOut);
            choices = choices.Where(choice => available[choice.SettingId].Supported && available[choice.SettingId].AvailableChoices?.Contains(choice.OptionId) == true).ToArray();
        }
        else if (preset.OptionalSelections is { } optional)
            choices = choices.Where(choice => { if (!optional.Contains(choice)) return true; var resolved = _catalog.Resolve(choice); return Supported(resolved.Definition) && Supported(resolved.Option); }).ToArray();
        if (choices.Length == 0) throw new InvalidDataException("None of this preset's settings are available on this PC.");
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

    private void Compose<T>(List<TweakProfile> profiles, string profileId, T[] group, Func<TweakProfile, IEnumerable<T>> claims, Action<T[]> check, Func<T, string> setting)
    {
        try { check(group); }
        catch (InvalidDataException error)
        {
            bool Composes(T[] claims) { try { check(claims); return true; } catch (InvalidDataException) { return false; } }
            bool Conflicts(T first, T second) => !Composes([first, second]);
            var requested = profiles.Where(profile => profile.Id == profileId).SelectMany(claims).Where(group.Contains).ToArray();
            var blocking = profiles.Where(profile => profile.Id != profileId).SelectMany(profile => claims(profile).Where(group.Contains).Select(claim => (profile.Id, Claim: claim)))
                .Where(other => requested.Any(mine => Conflicts(mine, other.Claim))).ToArray();
            if (blocking.Length == 0 || !Composes(group.Where(claim => !blocking.Any(other => ReferenceEquals(other.Claim, claim))).ToArray())) throw;
            var others = blocking.Select(other => other.Id).Distinct(StringComparer.Ordinal).ToArray();
            var names = requested.Where(mine => blocking.Any(other => Conflicts(mine, other.Claim))).Select(setting).Distinct(StringComparer.Ordinal)
                .Select(id => _catalog.Settings.FirstOrDefault(definition => definition.Id == id)?.Name ?? id);
            throw new InvalidDataException("Your " + string.Join(" and ", others.Select(id => "\"" + id + "\"")) + (others.Length == 1 ? " profile already sets " : " profiles already set ") + string.Join(", ", names)
                + " to a different choice. Pick the same choice, or restore " + (others.Length == 1 ? "that profile" : "those profiles") + " first.", error);
        }
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
        TweakRead? attemptedRead = null;
        TweakRead Capture(RegistryAddress address)
        {
            var read = _store.Read(Local(address)); attemptedRead = read; read.Validate();
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
                foreach (var control in option.Controls ?? []) { var observed = ReadControl(control.Address); observed.Validate(); if (!observed.Allows(control.Value)) throw new InvalidDataException(observed.Address.Kind == "windows-features" ? "This Windows installation does not offer feature: " + string.Join(", ", control.Value.EnumerateObject().Select(feature => feature.Name).Where(name => !observed.Value.TryGetProperty(name, out _))) : "This Windows control does not support that value: " + control.Address.Target); controlClaims.Add(new(definition.Id, option.Id, observed, observed.Expand(control.Value), control.Patch)); }
                foreach (var change in option.Changes.SelectMany(_store.Resolve)) claims.Add(new(definition.Id, option.Id, Capture(change.Address), Desired(change), change.Token, change.Bits));
            }
            foreach (var claim in claims) affected.Add(claim.Target.Id);
            profiles.Add(new(profileId, _catalog.Digest, selections, claims.ToArray(), controlClaims.ToArray(), selections.SelectMany(selection => _catalog.Resolve(selection).Option.DataLoss ?? []).Concat(TweakDataEffects.Warnings(claims.ToArray(), controlClaims.ToArray())).Distinct().ToArray()));
        }
        var wanted = profiles.SelectMany(profile => profile.Claims).GroupBy(claim => claim.Target.Id).ToDictionary(group => group.Key, group => group.ToArray(), StringComparer.Ordinal);
        foreach (var group in wanted.Values)
        {
            foreach (var claim in group) claim.Target.Validate();
            Compose(profiles, profileId, group, profile => profile.Claims, claims => TweakComposition.Check(claims, id => _catalog.Settings.FirstOrDefault(definition => definition.Id == id)?.Name ?? id), claim => claim.SettingId);
        }
        foreach (var group in profiles.SelectMany(profile => profile.Controls ?? []).GroupBy(claim => claim.Target.Id, StringComparer.Ordinal))
            Compose(profiles, profileId, group.ToArray(), profile => profile.Controls ?? [], ControlComposition.Check, claim => claim.SettingId);
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
            TweakRead observed; TweakResolution after; var readable = false; attemptedRead = null;
            try
            {
                observed = Capture((desired?.First().Target ?? original!.Original).Address);
                readable = true;
                if (observed.Id != id) throw new InvalidDataException("A registry target now resolves to a different resource.");
                after = TweakComposition.Resolve(observed, original, oldClaims, desired ?? []);
            }
            catch (Exception error) when (!asks && original is not null && MayLeaveChanged(error, readable || ChangedUnreadable(attemptedRead, original), selections.Length == 0))
            {
                left.AddRange(oldClaims.Where(claim => desired?.Any(kept => ReferenceEquals(kept, claim)) != true).Select(claim => claim.SettingId));
                if (desired is not null) next.Add(original);
                continue;
            }
            left.AddRange(after.LeftAsChanged ?? []);
            if (!TweakRead.SameValue(observed.Value, after.Value)) changes.Add(new(observed, after.Value));
            if (desired is not null) next.Add(new(original?.Original ?? observed, after.Applied ?? after.Value, after.RestoreValue, after.Composed));
        }
        var controls = ControlPlanning.Plan(state, profiles.ToArray(), profileId, ReadControl);
        if (selections.Length > 0) CheckIncompatible(state, changes, next, profiles, controls, Capture);
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

    private void CheckIncompatible(TweakState? state, List<TweakMutation> changes, List<TweakHeldValue> held, List<TweakProfile> profiles, ControlPlan controls, Func<RegistryAddress, TweakRead> capture)
    {
        foreach (var rule in _catalog.Incompatible ?? [])
        {
            var options = rule.Selections.Select(_catalog.Resolve).ToArray();
            var halves = options.Select(item => (item.Definition, item.Option, Changes: item.Option.Changes.SelectMany(_store.Resolve).ToArray())).ToArray();
            var addresses = halves.SelectMany(half => half.Changes).Select(change => Local(change.Address)).ToHashSet();
            var controlAddresses = options.SelectMany(item => item.Option.Controls ?? []).Select(control => control.Address).ToHashSet();
            string[] Owned(IEnumerable<TweakProfile> list) => list.SelectMany(profile => profile.Claims).Where(claim => addresses.Contains(claim.Target.Address))
                .Select(claim => claim.SettingId + "/" + claim.OptionId + "/" + claim.Target.Id).Order(StringComparer.Ordinal).ToArray();
            var touched = changes.Any(change => addresses.Contains(change.Before.Address)) || controls.Changes.Any(change => controlAddresses.Contains(change.Before.Address)) ||
                !Owned(state?.Profiles ?? []).SequenceEqual(Owned(profiles));
            if (!touched) continue;
            var reads = halves.SelectMany(half => half.Changes).Select(change => capture(change.Address)).DistinctBy(read => read.Id).ToDictionary(read => read.Id, StringComparer.Ordinal);
            RegistryValueData? Baseline(string id) => (state?.Held ?? []).Concat(held).FirstOrDefault(item => item.Original.Id == id) is { } owned ? owned.Composed ? owned.RestoreValue : owned.Original.Value : reads[id].Value;
            var planned = reads.Keys.ToDictionary(id => id, id => changes.FirstOrDefault(change => change.Before.Id == id) is { } mutation ? mutation.After : reads[id].Value, StringComparer.Ordinal);
            var original = reads.Keys.ToDictionary(id => id, Baseline, StringComparer.Ordinal);
            var states = new List<Dictionary<string, RegistryValueData?>> { planned };
            foreach (var profile in profiles.Where(profile => profile.Claims.Any(claim => reads.ContainsKey(claim.Target.Id))))
                states.Add(reads.Keys.ToDictionary(id => id, id => profile.Claims.Any(claim => claim.Target.Id == id) && !profiles.Any(other => other != profile && other.Claims.Any(claim => claim.Target.Id == id)) ? original[id] : planned[id], StringComparer.Ordinal));
            bool ControlsEffective((TweakDefinition Definition, TweakOption Option, TweakAssignment[] Changes) half) => (half.Option.Controls ?? []).All(control =>
            {
                var read = ReadControl(control.Address); read.Validate();
                var value = controls.Changes.FirstOrDefault(item => item.Before.Id == read.Id) is { } mutation ? mutation.After : read.Value;
                return ControlComposition.Matches(new(half.Definition.Id, half.Option.Id, read, read.Expand(control.Value, allowPending: true), control.Patch), value);
            });
            bool Effective((TweakDefinition Definition, TweakOption Option, TweakAssignment[] Changes) half, Dictionary<string, RegistryValueData?> values) =>
                (half.Changes.Length > 0 || half.Option.Controls is { Length: > 0 }) && ControlsEffective(half) &&
                half.Changes.All(change => { var read = capture(change.Address); return TweakComposition.Matches(new(half.Definition.Id, half.Option.Id, read, Desired(change), change.Token, change.Bits), values[read.Id]); });
            bool Original(Dictionary<string, RegistryValueData?> values) => values.All(item => TweakRead.SameValue(item.Value, original[item.Key]));
            if (states.Any(values => halves.All(half => Effective(half, values)) && !Original(values)))
                throw new InvalidDataException(string.Join(" and ", options.Select(item => item.Definition.Name)) + " cannot be used together. " + rule.Reason);
        }
    }
    internal static bool MayLeaveChanged(Exception error, bool readable, bool restoring, ControlAddress? address = null) =>
        error is not (TimeoutException or OperationCanceledException) && (error is not IOException || error is FileNotFoundException or DirectoryNotFoundException) &&
        (readable || restoring && (address is not null && error is TweakResourceChangedException || error is FileNotFoundException or DirectoryNotFoundException or RegistryApiException { NativeErrorCode: 2 or 3 } ||
            address is { Kind: "service" } && error is System.ComponentModel.Win32Exception { NativeErrorCode: 1060 } ||
            address is { Kind: "file-acl" or "file-ownership" } && error is System.ComponentModel.Win32Exception { NativeErrorCode: 2 or 3 }));
    private static bool ChangedUnreadable(TweakRead? read, TweakHeldValue original)
    {
        if (read is null || read.Value is not { Recoverable: false, Bytes: not null } value || read.Id != original.Original.Id ||
            !string.Equals(value.Name, read.Address.ValueName, StringComparison.OrdinalIgnoreCase) || TweakRead.SameValue(value, original.Applied)) return false;
        try { (read with { Value = original.Applied }).Validate(); return true; }
        catch (InvalidDataException) { return false; }
    }
    public static bool SupportsWindows(TweakDefinition definition, TweakOption option, TweakContext context) =>
        WindowsRange(definition.MinimumBuild, definition.MaximumBuild, definition.Editions, context) && Unexpired(option) &&
        (option.Availability is null || option.Availability.Any(gate => WindowsRange(gate.MinimumBuild, gate.MaximumBuild, gate.Editions, context)));
    private bool Supported(TweakDefinition definition) => WindowsRange(definition.MinimumBuild, definition.MaximumBuild, definition.Editions, _store.Context);
    private bool Supported(TweakOption option) => Unexpired(option) && (option.Availability is null || option.Availability.Any(gate =>
        WindowsRange(gate.MinimumBuild, gate.MaximumBuild, gate.Editions, _store.Context) && (gate.Requirements ?? []).All(RequirementAvailable)));
    private static bool Unexpired(TweakOption option) => option.ValidUntilUtc is null || DateTime.UtcNow < option.ValidUntilUtc.Value;
    private static bool WindowsRange(int minimum, int maximum, string[] editions, TweakContext context) => context.WindowsBuild >= minimum && context.WindowsBuild <= maximum &&
        editions.Any(edition => edition.EndsWith('*') ? context.Edition.StartsWith(edition[..^1], StringComparison.OrdinalIgnoreCase) : string.Equals(edition, context.Edition, StringComparison.OrdinalIgnoreCase));
    private bool RequirementAvailable(string requirement)
    {
        try { _store.CheckRequirement(requirement); return true; }
        catch (Exception error) when (error is InvalidDataException or IOException or System.ComponentModel.Win32Exception) { return false; }
    }
    private RegistryAddress Local(RegistryAddress address) => address with { KeyPath = address.KeyPath.Replace("{user-sid}", _store.Context.Owner.UserSid, StringComparison.OrdinalIgnoreCase) };
    private TweakControlRead ReadControl(ControlAddress address)
    {
        var read = Task.Factory.StartNew(() => _store.ReadControl(address), CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        bool answered;
        try { answered = read.Wait(ReadTimeout); }
        catch (AggregateException) { answered = true; }
        if (!answered)
        {
            _ = read.ContinueWith(task => task.Exception, TaskScheduler.Default);
            throw new TimeoutException(FeaturesTimedOut);
        }
        return read.GetAwaiter().GetResult();
    }
    private TweakRead Read(RegistryAddress address) { var result = _store.Read(Local(address)); result.Validate(); return result; }
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
