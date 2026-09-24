#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class MitigationControl
{
    public const string SnapshotField = "$registry";
    private const string Kernel = @"SYSTEM\CurrentControlSet\Control\Session Manager\kernel";
    private static readonly string[] Names = ["MitigationOptions", "MitigationAuditOptions", "EAFModules"];
    private sealed record Field(string Name, int Bit, string Override, bool Audit = false, string? Parent = null, bool HasOption = false);
    private static readonly Field[] Fields =
    [
        new("Dep.Enable", 0, "Dep.OverrideDEP", HasOption: true), new("Dep.EmulateAtlThunks", 0, "Dep.OverrideDEP", Parent: "Dep.Enable"),
        new("Sehop.Enable", 4, "Sehop.OverrideSEHOP", HasOption: true),
        new("Aslr.ForceRelocateImages", 8, "Aslr.OverrideForceRelocateImages", HasOption: true), new("Aslr.RequireInfo", 8, "Aslr.OverrideForceRelocateImages", Parent: "Aslr.ForceRelocateImages"),
        new("Aslr.BottomUp", 16, "Aslr.OverrideBottomUp"), new("Aslr.HighEntropy", 20, "Aslr.OverrideHighEntropy"),
        new("StrictHandle.Enable", 24, "StrictHandle.OverrideStrictHandle"),
        new("Cfg.Enable", 40, "Cfg.OverrideCFG", HasOption: true), new("Cfg.SuppressExports", 40, "Cfg.OverrideCFG", Parent: "Cfg.Enable"),
        new("ExtensionPoint.DisableExtensionPoints", 32, "ExtensionPoint.OverrideExtensionPoint"),
        new("DynamicCode.BlockDynamicCode", 36, "DynamicCode.OverrideDynamicCode", HasOption: true), new("DynamicCode.Audit", 36, "DynamicCode.OverrideDynamicCode", true, HasOption: true),
        new("FontDisable.Audit", 48, "FontDisable.OverrideFontDisable", true, HasOption: true),
        new("ImageLoad.BlockRemoteImageLoads", 52, "ImageLoad.OverrideBlockRemoteImageLoads"), new("ImageLoad.AuditRemoteImageLoads", 52, "ImageLoad.OverrideBlockRemoteImageLoads", true),
    ];
    public static string[] Linked(IEnumerable<string> names)
    {
        var units = names.SelectMany(Units).ToHashSet(StringComparer.Ordinal);
        return Fields.SelectMany(field => new[] { field.Name, field.Override }).Distinct().Where(name => Units(name).Any(units.Contains)).ToArray();
    }
    public static string[] Units(string name) => Fields.Where(field => field.Name == name).Select(field => ValueName(field) + ":" + field.Bit)
        .Concat(Fields.Where(field => field.Override == name).Select(field => "override:" + field.Bit)).DefaultIfEmpty(name).Distinct().ToArray();
    private static RegistryAddress Address(string name) => new("LocalMachine", "Registry64", Kernel, "value", name);
    private static string ValueName(Field field) => field.Audit ? Names[1] : Names[0];
    private static int Slot(RegistryValueData? value, int bit) => value is null || value.Bytes.Length <= bit / 8 ? 0 : value.Bytes[bit / 8] >> (bit % 8) & 15;
    private static Dictionary<string, RegistryValueData?> Raw(JsonElement value)
    {
        var raw = value.GetProperty(SnapshotField).Deserialize<Dictionary<string, RegistryValueData?>>(OperationFiles.Json)
            ?? throw new InvalidDataException("The mitigation registry snapshot is missing.");
        if (raw.Count != Names.Length || Names.Any(name => !raw.ContainsKey(name)) || raw.Any(item => item.Value is { } data &&
            (data.Name != item.Key || !data.Recoverable || data.Bytes.Length > 1048576 || item.Key != Names[2] && data.Type != 3)))
            throw new InvalidDataException("The mitigation registry snapshot is incomplete or has an unsupported value type.");
        return raw;
    }
    public static JsonElement Snapshot(RegistryValueData? options, RegistryValueData? audit, RegistryValueData? eaf)
    {
        var raw = new Dictionary<string, RegistryValueData?> { [Names[0]] = options, [Names[1]] = audit, [Names[2]] = eaf };
        var result = new Dictionary<string, object?> { [SnapshotField] = raw };
        foreach (var field in Fields)
        {
            var state = Slot(raw[ValueName(field)], field.Bit) & 3;
            result[field.Name] = field.Parent is not null ? state == 3 ? "ON" : "OFF" : state switch { 1 => "ON", 2 => "OFF", 3 when field.HasOption => "ON", _ => "NOTSET" };
            result[field.Override] = (Slot(options, field.Bit) & 4) != 0;
        }
        var value = ControlValues.From(result); _ = Raw(value); return value;
    }
    public static TweakControlRead Read(ControlAddress address)
    {
        if (address.Target != "system" || address.Property != "policy") throw new InvalidDataException("Unknown mitigation policy target.");
        using var transaction = RegistryTransaction.Begin();
        var reads = Names.Select(name => RegistryNative.ReadTweak(Address(name), transaction)).ToArray();
        if (reads.Any(read => !read.KeyExists)) throw new InvalidDataException("The system mitigation registry key is missing.");
        return new(address, "mitigations:system:policy", "system-mitigations:registry-v1:" + reads[0].NativeKey,
            Snapshot(reads[0].Value, reads[1].Value, reads[2].Value));
    }
    public static JsonElement Expand(JsonElement patch)
    {
        var values = patch.EnumerateObject().ToDictionary(item => item.Name, item => item.Value);
        foreach (var field in Fields.Where(field => field.Parent is not null && values.TryGetValue(field.Parent, out var parent) && parent.GetString() is "OFF" or "NOTSET"))
        {
            if (values.TryGetValue(field.Name, out var child) && child.GetString() == "ON") throw new InvalidDataException(field.Name + " requires " + field.Parent + " to be enabled.");
            values[field.Name] = ControlValues.From("OFF");
        }
        foreach (var field in Fields.Where(field => field.Parent is not null && values.TryGetValue(field.Name, out var state) && state.GetString() == "ON"))
        {
            if (values.TryGetValue(field.Parent!, out var parent) && parent.GetString() != "ON") throw new InvalidDataException(field.Name + " requires " + field.Parent + " to be enabled.");
            values[field.Parent!] = ControlValues.From("ON");
        }
        return ControlValues.From(values);
    }
    public static JsonElement Reconcile(JsonElement desired)
    {
        if (!desired.TryGetProperty(SnapshotField, out _)) return desired;
        var raw = Raw(desired);
        var observed = Snapshot(raw[Names[0]], raw[Names[1]], raw[Names[2]]);
        void Set(string name, int bit, int mask, int value)
        {
            if ((Slot(raw[name], bit) & mask) == value) return;
            var bytes = raw[name]?.Bytes.ToArray() ?? new byte[24];
            if (bytes.Length <= bit / 8) Array.Resize(ref bytes, Math.Max(24, bit / 8 + 1));
            bytes[bit / 8] = (byte)((bytes[bit / 8] & ~(mask << (bit % 8))) | value << (bit % 8));
            raw[name] = new(name, 3, bytes);
        }
        foreach (var field in Fields.Where(field => field.Parent is null))
        {
            var state = desired.GetProperty(field.Name).GetString();
            var code = state switch { "NOTSET" => 0, "ON" => 1, "OFF" => 2, _ => throw new InvalidDataException("Unknown mitigation state: " + state) };
            if (state == observed.GetProperty(field.Name).GetString()) continue;
            Set(ValueName(field), field.Bit, 3, code);
        }
        foreach (var field in Fields.Where(field => field.Parent is not null))
        {
            var state = desired.GetProperty(field.Name).GetString();
            if (state is not ("ON" or "OFF")) throw new InvalidDataException("A subordinate mitigation must be on or off: " + field.Name);
            var current = Slot(raw[Names[0]], field.Bit) & 3;
            if (state == "ON" && current is not (1 or 3)) throw new InvalidDataException(field.Name + " requires " + field.Parent + " to be enabled.");
            if (state == "ON") Set(Names[0], field.Bit, 3, 3);
            else if (current == 3) Set(Names[0], field.Bit, 3, 1);
        }
        foreach (var field in Fields.DistinctBy(field => field.Override)) Set(Names[0], field.Bit, 4, desired.GetProperty(field.Override).GetBoolean() ? 4 : 0);
        return Snapshot(raw[Names[0]], raw[Names[1]], raw[Names[2]]);
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var original = Raw(before.Value); var after = Raw(desired);
        if (!ControlValues.Equal(Reconcile(desired), desired) || !TweakRead.SameValue(original[Names[2]], after[Names[2]]))
            throw new InvalidDataException("The mitigation request must match its reviewed fields and preserve EAFModules.");
        foreach (var name in Names.Take(2))
        {
            var first = original[name]?.Bytes ?? []; var second = after[name]?.Bytes ?? [];
            for (var index = 0; index < Math.Max(first.Length, second.Length); index++)
            {
                var mask = Fields.Aggregate(0, (value, field) => value | (field.Bit / 8 != index ? 0 :
                    ((ValueName(field) == name ? 3 : 0) | (name == Names[0] ? 4 : 0)) << (field.Bit % 8)));
                if ((((index < first.Length ? first[index] : 0) ^ (index < second.Length ? second[index] : 0)) & ~mask) != 0)
                    throw new InvalidDataException("An unselected mitigation field must remain unchanged.");
            }
        }
        using var transaction = RegistryTransaction.Begin();
        var reads = Names.Select(name => RegistryNative.ReadTweak(Address(name), transaction)).ToArray();
        foreach (var read in reads)
            if (!TweakRead.SameValue(read.Value, original[read.Address.ValueName!])) throw new InvalidDataException("A mitigation registry value changed after review.");
        foreach (var read in reads.Take(2))
            if (!TweakRead.SameValue(read.Value, after[read.Address.ValueName!])) RegistryNative.SetTweak(read.Address, read.NativeKey, after[read.Address.ValueName!], transaction);
        transaction.Commit();
        var observed = PowerShellControls.Read(before.Address).Value;
        foreach (var field in Fields)
        {
            var actual = observed.GetProperty(field.Name).GetString();
            if (field.Parent is not null && actual == "NOTSET") actual = "OFF";
            if (actual != desired.GetProperty(field.Name).GetString() || observed.GetProperty(field.Override).GetBoolean() != desired.GetProperty(field.Override).GetBoolean())
                throw new InvalidOperationException("Windows mitigation readback differs from the reviewed field: " + field.Name);
        }
    }
    public static JsonElement RestoreFields(JsonElement current, JsonElement original, string[] fields)
    {
        var originalRaw = Raw(original); var restoredRaw = Raw(current);
        foreach (var name in Names.Take(2))
        {
            var expected = originalRaw[name]?.Bytes ?? [];
            var actual = restoredRaw[name]?.Bytes.ToArray() ?? [];
            for (var index = 0; index < Math.Max(actual.Length, expected.Length); index++)
            {
                var mask = Fields.Aggregate(0, (value, field) => value | (field.Bit / 8 != index ? 0 :
                    ((ValueName(field) == name && fields.Contains(field.Name, StringComparer.Ordinal) ? 3 : 0) |
                    (name == Names[0] && fields.Contains(field.Override, StringComparer.Ordinal) ? 4 : 0)) << (field.Bit % 8)));
                var value = ((index < actual.Length ? actual[index] : 0) & ~mask) | ((index < expected.Length ? expected[index] : 0) & mask);
                if (index >= actual.Length && value != 0) Array.Resize(ref actual, Math.Max(24, index + 1));
                if (index < actual.Length) actual[index] = (byte)value;
            }
            if (actual.Length > 0) restoredRaw[name] = new(name, 3, actual);
            if (actual.Take(expected.Length).SequenceEqual(expected) && actual.Skip(expected.Length).All(item => item == 0)) restoredRaw[name] = originalRaw[name];
        }
        return Snapshot(restoredRaw[Names[0]], restoredRaw[Names[1]], restoredRaw[Names[2]]);
    }
}
