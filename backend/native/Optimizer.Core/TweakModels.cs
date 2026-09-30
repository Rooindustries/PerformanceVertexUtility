#nullable enable
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record TweakContext([property: JsonRequired] OperationOwner Owner, [property: JsonRequired] string StoreId, [property: JsonRequired] int WindowsBuild, [property: JsonRequired] string Edition);
public sealed record TweakSource([property: JsonRequired] string Product, [property: JsonRequired] string Reference, [property: JsonRequired] string Evidence);
public sealed record TweakToken([property: JsonRequired] string Name, [property: JsonRequired] string? Value);
public sealed record TweakBits([property: JsonRequired] uint Mask, [property: JsonRequired] uint Value, [property: JsonRequired] uint AbsentDefault);
public sealed record TweakAssignment([property: JsonRequired] RegistryAddress Address, [property: JsonRequired] uint? Dword, RegistryValueData? Value = null, TweakToken? Token = null, TweakBits? Bits = null, RegistrySelection? Selector = null, string? Formula = null);
public sealed record TweakAvailability([property: JsonRequired] int MinimumBuild, [property: JsonRequired] int MaximumBuild, [property: JsonRequired] string[] Editions, string[]? Requirements = null);
public sealed record TweakOption([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] TweakAssignment[] Changes, TweakAvailability[]? Availability = null, ControlAssignment[]? Controls = null, DateTime? ValidUntilUtc = null, string[]? DataLoss = null);
public sealed record TweakSelection([property: JsonRequired] string SettingId, [property: JsonRequired] string OptionId);
public sealed record TweakPreset([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] TweakSelection[] Selections, bool AvailableOnly = false);
public sealed record TweakDefinition([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] string Category, [property: JsonRequired] string Description, [property: JsonRequired] int MinimumBuild, [property: JsonRequired] int MaximumBuild,
    [property: JsonRequired] string[] Editions, [property: JsonRequired] string Refresh, [property: JsonRequired] TweakOption[] Options, [property: JsonRequired] TweakSource[] Sources, string[]? Requirements = null, bool Advanced = false, string[]? Alternatives = null);
public sealed record TweakIncompatibility([property: JsonRequired] TweakSelection[] Selections, [property: JsonRequired] string Reason);
public sealed record TweakCatalog([property: JsonRequired] int SchemaVersion, [property: JsonRequired] string Version, [property: JsonRequired] TweakDefinition[] Settings, [property: JsonRequired] TweakPreset[] Presets, TweakIncompatibility[]? Incompatible = null)
{
    [JsonIgnore] public string Digest => OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(this, OperationFiles.Json));
    public void Validate()
    {
        if (SchemaVersion != 1 || string.IsNullOrWhiteSpace(Version) || Settings is null || Presets is null || Settings.Length == 0)
            throw new InvalidDataException("The tweak catalog is incomplete.");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var setting in Settings)
        {
            if (string.IsNullOrWhiteSpace(setting.Id) || !ids.Add(setting.Id) || string.IsNullOrWhiteSpace(setting.Name) ||
                setting.MinimumBuild < 10240 || setting.MaximumBuild < setting.MinimumBuild || setting.Editions is not { Length: > 0 } ||
                setting.Options is not { Length: > 0 } || setting.Sources is not { Length: > 0 }) throw new InvalidDataException("Invalid or duplicate tweak definition.");
            var options = new HashSet<string>(StringComparer.Ordinal);
            foreach (var option in setting.Options)
            {
                if (string.IsNullOrWhiteSpace(option.Id) || !options.Add(option.Id) || option.Changes is null || option.Changes.Length == 0 && option.Controls is not { Length: > 0 }) throw new InvalidDataException("Invalid or duplicate tweak option.");
                if (option.Availability is not null && (option.Availability.Length == 0 || option.Availability.Any(gate => gate.MinimumBuild < 10240 || gate.MaximumBuild < gate.MinimumBuild || gate.Editions is not { Length: > 0 }))) throw new InvalidDataException("Invalid Windows applicability.");
                foreach (var control in option.Controls ?? []) { control.Address.Validate(); if (control.Value.ValueKind == JsonValueKind.Undefined || control.Patch && (control.Value.ValueKind != JsonValueKind.Object || !control.Value.EnumerateObject().Any())) throw new InvalidDataException("A desired control value is required."); }
                foreach (var change in option.Changes)
                {
                    TweakRead.ValidateAddress(change.Address);
                    change.Selector?.Validate();
                    if ((change.Dword is not null ? 1 : 0) + (change.Value is not null ? 1 : 0) + (change.Token is not null ? 1 : 0) + (change.Bits is not null ? 1 : 0) + (change.Formula is not null ? 1 : 0) > 1)
                        throw new InvalidDataException("A setting change has multiple value encodings.");
                    if (change.Value is { } value && (!value.Recoverable || value.Bytes.Length > 65536 || !string.Equals(value.Name, change.Address.ValueName, StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidDataException("Invalid typed setting value.");
                    if (change.Token is { } token) TweakTokens.Validate(token);
                    if (change.Bits is { } bits && (bits.Mask == 0 || (bits.Value & ~bits.Mask) != 0)) throw new InvalidDataException("Invalid setting bit field.");
                }
            }
        }
        var presets = new HashSet<string>(StringComparer.Ordinal);
        foreach (var preset in Presets)
        {
            if (string.IsNullOrWhiteSpace(preset.Id) || !presets.Add(preset.Id) || preset.Selections is not { Length: > 0 }) throw new InvalidDataException("Invalid or duplicate preset.");
            foreach (var selection in preset.Selections) Resolve(selection);
        }
        foreach (var rule in Incompatible ?? [])
        {
            if (rule?.Selections is not { Length: > 1 } || rule.Selections.Any(item => item is null) || string.IsNullOrWhiteSpace(rule.Reason) || rule.Selections.Select(item => item.SettingId).Distinct().Count() != rule.Selections.Length)
                throw new InvalidDataException("Invalid incompatible-settings rule.");
            if (rule.Selections.Any(selection => Resolve(selection).Option.Controls is { Length: > 0 })) throw new InvalidDataException("Incompatible-settings rules support registry settings only.");
            if (Presets.FirstOrDefault(preset => rule.Selections.All(preset.Selections.Contains)) is { } preset) throw new InvalidDataException("A preset combines settings that cannot be used together: " + preset.Id);
        }
    }
    public (TweakDefinition Definition, TweakOption Option) Resolve(TweakSelection selection)
    {
        var definition = Settings.SingleOrDefault(item => item.Id == selection.SettingId) ?? throw new InvalidDataException("Unknown setting: " + selection.SettingId);
        return (definition, definition.Options.SingleOrDefault(item => item.Id == selection.OptionId) ?? throw new InvalidDataException("Unknown choice for " + definition.Name));
    }
}

public sealed record TweakRead
{
    public required RegistryAddress Address { get; init; }
    public required string NativeKey { get; init; }
    public required bool KeyExists { get; init; }
    public required RegistryValueData? Value { get; init; }
    public required string[] MissingKeys { get; init; }
    [JsonIgnore] public string Id => OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new[] { NativeKey.ToUpperInvariant(), Address.ValueName!.ToUpperInvariant() }));
    public static void ValidateAddress(RegistryAddress address)
    {
        ValidateSyntax(address);
        if (address.Kind != "value" || address.KeyPath.StartsWith("Software\\RooIndustriesOptimizationSuite", StringComparison.OrdinalIgnoreCase) ||
            address.KeyPath.StartsWith(BrandCompatibility.LegacyRegistryRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("A tweak must name an explicit setting outside the recovery store.");
    }
    internal static void ValidateSyntax(RegistryAddress address)
    {
        if (address.Hive is not ("CurrentUser" or "LocalMachine" or "Users") || address.View is not ("Registry32" or "Registry64") ||
            address.Kind is not ("key" or "value") || address.Kind == "value" && address.ValueName is null || address.Kind == "key" && address.ValueName is not null ||
            string.IsNullOrWhiteSpace(address.KeyPath) || address.KeyPath.Split('\\').Any(part => part is "" or "." or "..") || address.KeyPath.Contains('/') ||
            !RegistryAddress.SerializableName(address.KeyPath) || address.ValueName is not null && !RegistryAddress.SerializableName(address.ValueName))
            throw new InvalidDataException("An explicit registry scope, view, path and value identity are required.");
        var first = address.KeyPath.Split('\\')[0];
        if (address.Hive == "Users" ? !first.Equals(".DEFAULT", StringComparison.OrdinalIgnoreCase) && !first.Equals(OperationOwner.Current().UserSid + "_Classes", StringComparison.OrdinalIgnoreCase) : !new[] { "Software", "System", "Control Panel", "Environment", "Keyboard Layout", "AppEvents" }.Contains(first, StringComparer.OrdinalIgnoreCase))
            throw new InvalidDataException("Registry root is outside the supported tweak scopes.");
    }
    public void Validate()
    {
        ValidateAddress(Address);
        if (string.IsNullOrWhiteSpace(NativeKey) || MissingKeys is null || KeyExists && MissingKeys.Length != 0 || !KeyExists && (Value is not null || MissingKeys.Length == 0) ||
            Value is not null && (!Value.Recoverable || Value.Bytes.Length > 65536 || !string.Equals(Value.Name, Address.ValueName, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("The setting snapshot is incomplete or cannot be restored exactly.");
    }
    public bool Same(TweakRead other) => Id == other.Id && KeyExists == other.KeyExists && SameValue(Value, other.Value);
    internal static bool IsInside(string path, string parent) => path.Equals(parent, StringComparison.OrdinalIgnoreCase) || path.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase);
    public static bool SameValue(RegistryValueData? first, RegistryValueData? second) => first is null ? second is null : second is not null && RegistryNative.SameValue(first, second);
}

public sealed record TweakClaim([property: JsonRequired] string SettingId, [property: JsonRequired] string OptionId, [property: JsonRequired] TweakRead Target, [property: JsonRequired] RegistryValueData? Desired, TweakToken? Token = null, TweakBits? Bits = null);
public sealed record TweakProfile([property: JsonRequired] string Id, [property: JsonRequired] string CatalogHash, [property: JsonRequired] TweakSelection[] Selections, [property: JsonRequired] TweakClaim[] Claims, ControlClaim[]? Controls = null, string[]? DataLoss = null);
public sealed record TweakHeldValue([property: JsonRequired] TweakRead Original, [property: JsonRequired] RegistryValueData? Applied, RegistryValueData? RestoreValue = null, bool Composed = false);
public sealed record TweakMutation([property: JsonRequired] TweakRead Before, [property: JsonRequired] RegistryValueData? After);
public sealed record TweakCreatedKey([property: JsonRequired] RegistryAddress Address, [property: JsonRequired] string NativeKey, [property: JsonRequired] string MetadataHash);
public sealed record TweakHistory([property: JsonRequired] string OperationId, [property: JsonRequired] string ReviewHash, [property: JsonRequired] string ProfileId, [property: JsonRequired] DateTime AtUtc, [property: JsonRequired] TweakMutation[] Changes, ControlMutation[]? Controls = null);
public sealed record TweakState
{
    public required int SchemaVersion { get; init; }
    public required TweakContext Context { get; init; }
    public required string Revision { get; init; }
    public required TweakProfile[] Profiles { get; init; }
    public required TweakHeldValue[] Held { get; init; }
    public required TweakCreatedKey[] CreatedKeys { get; set; }
    public required TweakHistory[] History { get; set; }
    public required string[] Notices { get; set; }
    public ControlHeld[]? Controls { get; init; }
}
public sealed record TweakPlan
{
    public required int SchemaVersion { get; init; }
    public required string OperationId { get; init; }
    public required DateTime CreatedAtUtc { get; init; }
    public required TweakContext Context { get; init; }
    public required string CatalogHash { get; init; }
    public required string? BeforeRevision { get; init; }
    public required string AfterRevision { get; init; }
    public required string ProfileId { get; init; }
    public required TweakSelection[] Selections { get; init; }
    public required TweakRead[] Expected { get; init; }
    public required TweakMutation[] Changes { get; init; }
    public required TweakProfile[] Profiles { get; init; }
    public required TweakHeldValue[] Held { get; init; }
    public ControlPlan? Controls { get; init; }
    public string[] DataLoss { get; init; } = [];
    public string? PresetId { get; init; }
    public string[] Skipped { get; init; } = [];
    public string[] LeftAsChanged { get; init; } = [];
}

public sealed record TweakRecovery(TweakState? State, ControlJournal? Pending, string? PendingHash);
public sealed record TweakCatalogResult(TweakCatalog Catalog, string Hash);
public sealed record TweakSettingStatus(string Id, string Name, bool Supported, string[] ConfiguredChoices, TweakRead[] Observations, string? Error, string[]? AvailableChoices = null, TweakControlRead[]? Controls = null);
public sealed record TweakInspection(TweakContext Context, string CatalogVersion, TweakState? State, TweakSettingStatus[] Settings);

public sealed record TweakApplyResult(TweakState State, bool Changed, bool Replayed)
{
    public bool Restorable => State.Profiles.Length > 0;
}

public interface ITweakStore
{
    TweakContext Context { get; }
    TweakState? ReadState();
    TweakRead Read(RegistryAddress address);
    TweakAssignment[] Resolve(TweakAssignment assignment);
    void CheckRequirement(string requirement);
    TweakControlRead ReadControl(ControlAddress address);
    Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> ReadControls(IReadOnlyCollection<ControlAddress> addresses)
    {
        var results = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
        foreach (var address in addresses.Distinct())
        {
            try { results[address] = (ReadControl(address), null); }
            catch (Exception error) { results[address] = (null, error); }
        }
        return results;
    }
    Task<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>> ReadControlsAsync(IReadOnlyCollection<ControlAddress> addresses) => Task.FromResult(ReadControls(addresses));
    TweakState Commit(TweakPlan plan, string reviewHash);
}
