#nullable enable
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record TweakContext([property: JsonRequired] OperationOwner Owner, [property: JsonRequired] string StoreId, [property: JsonRequired] int WindowsBuild, [property: JsonRequired] string Edition);
public sealed record TweakSource([property: JsonRequired] string Product, [property: JsonRequired] string Reference, [property: JsonRequired] string Evidence);
public sealed record TweakAssignment([property: JsonRequired] RegistryAddress Address, [property: JsonRequired] uint? Dword);
public sealed record TweakOption([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] TweakAssignment[] Changes);
public sealed record TweakSelection([property: JsonRequired] string SettingId, [property: JsonRequired] string OptionId);
public sealed record TweakPreset([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] TweakSelection[] Selections);
public sealed record TweakDefinition([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] string Category, [property: JsonRequired] string Description, [property: JsonRequired] int MinimumBuild, [property: JsonRequired] int MaximumBuild,
    [property: JsonRequired] string[] Editions, [property: JsonRequired] string Refresh, [property: JsonRequired] TweakOption[] Options, [property: JsonRequired] TweakSource[] Sources);
public sealed record TweakCatalog([property: JsonRequired] int SchemaVersion, [property: JsonRequired] string Version, [property: JsonRequired] TweakDefinition[] Settings, [property: JsonRequired] TweakPreset[] Presets)
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
                if (string.IsNullOrWhiteSpace(option.Id) || !options.Add(option.Id) || option.Changes is not { Length: > 0 }) throw new InvalidDataException("Invalid or duplicate tweak option.");
                foreach (var change in option.Changes) TweakRead.ValidateAddress(change.Address);
            }
        }
        var presets = new HashSet<string>(StringComparer.Ordinal);
        foreach (var preset in Presets)
        {
            if (string.IsNullOrWhiteSpace(preset.Id) || !presets.Add(preset.Id) || preset.Selections is not { Length: > 0 }) throw new InvalidDataException("Invalid or duplicate preset.");
            foreach (var selection in preset.Selections) Resolve(selection);
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
        address.Validate();
        if (address.Kind != "value" || address.KeyPath.StartsWith("Software\\RooIndustriesOptimizationSuite", StringComparison.OrdinalIgnoreCase) ||
            address.KeyPath.StartsWith(BrandCompatibility.LegacyRegistryRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("A tweak must name an explicit setting outside the recovery store.");
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

public sealed record TweakClaim([property: JsonRequired] string SettingId, [property: JsonRequired] string OptionId, [property: JsonRequired] TweakRead Target, [property: JsonRequired] RegistryValueData? Desired);
public sealed record TweakProfile([property: JsonRequired] string Id, [property: JsonRequired] string CatalogHash, [property: JsonRequired] TweakSelection[] Selections, [property: JsonRequired] TweakClaim[] Claims);
public sealed record TweakHeldValue([property: JsonRequired] TweakRead Original, [property: JsonRequired] RegistryValueData? Applied);
public sealed record TweakMutation([property: JsonRequired] TweakRead Before, [property: JsonRequired] RegistryValueData? After);
public sealed record TweakCreatedKey([property: JsonRequired] RegistryAddress Address, [property: JsonRequired] string NativeKey, [property: JsonRequired] string MetadataHash);
public sealed record TweakHistory([property: JsonRequired] string OperationId, [property: JsonRequired] string ReviewHash, [property: JsonRequired] string ProfileId, [property: JsonRequired] DateTime AtUtc, [property: JsonRequired] TweakMutation[] Changes);
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
}

public sealed record TweakApplyResult(TweakState State, bool Changed, bool Replayed)
{
    public bool Restorable => State.Profiles.Length > 0;
}

public interface ITweakStore
{
    TweakContext Context { get; }
    TweakState? ReadState();
    TweakRead Read(RegistryAddress address);
    TweakState Commit(TweakPlan plan, string reviewHash);
}
