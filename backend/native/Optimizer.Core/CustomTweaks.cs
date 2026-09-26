#nullable enable
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record CustomTweakFile([property: JsonRequired] int SchemaVersion, [property: JsonRequired] OperationOwner Owner, [property: JsonRequired] TweakDefinition[] Entries);

public static class CustomTweaks
{
    private static string Store => Path.Combine(BrandCompatibility.LocalDataRoot, "settings", "custom-windows-settings.json");
    private static CustomTweakFile Read()
    {
        if (!OperationFiles.Exists(Store)) return new(1, OperationOwner.Current(), []);
        if (new FileInfo(Store).Length > 2097152) throw new InvalidDataException("Custom settings exceed 2 MiB.");
        var file = OperationFiles.Read<CustomTweakFile>(Store); file.Owner.Verify();
        if (file.SchemaVersion != 1 || file.Entries.Length > 200) throw new InvalidDataException("Custom settings format or count is invalid.");
        return file;
    }
    public static TweakCatalog Merge(TweakCatalog catalog) => Merge(catalog, Read().Entries);
    public static TweakCatalog Merge(TweakCatalog catalog, TweakDefinition[] entries)
    {
        var settings = catalog.Settings.ToList(); var presets = catalog.Presets.ToList();
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < settings.Count; i++)
        {
            var keys = settings[i].Options.SelectMany(Parts).Select(part => part.Key).Distinct().ToArray();
            if (keys.Length == 1) index.TryAdd(keys[0], i);
        }
        foreach (var entry in entries.OrderBy(entry => entry.Id, StringComparer.Ordinal))
        {
            new TweakCatalog(1, "custom-validation", [entry], []).Validate();
            foreach (var option in entry.Options)
            {
                var selections = new List<TweakSelection>();
                foreach (var part in Parts(option))
                {
                    if (!index.TryGetValue(part.Key, out var at))
                    {
                        at = settings.Count; index.Add(part.Key, at);
                        settings.Add(entry with { Id = "custom." + OperationFiles.Hash(Encoding.UTF8.GetBytes(part.Key))[..16].ToLowerInvariant(), Options = [], Advanced = true });
                    }
                    var setting = settings[at];
                    var matched = setting.Options.FirstOrDefault(candidate => Parts(candidate).Count() == 1 && Parts(candidate).Single().Desired == part.Desired);
                    if (matched is null)
                    {
                        matched = option with { Id = "choice-" + OperationFiles.Hash(Encoding.UTF8.GetBytes(part.Desired))[..16].ToLowerInvariant(), Changes = part.Change is null ? [] : [part.Change], Controls = part.Control is null ? null : [part.Control] };
                        setting = setting with { Options = [.. setting.Options, matched], Sources = setting.Sources.Concat(entry.Sources).Distinct().ToArray() }; settings[at] = setting;
                    }
                    selections.Add(new(setting.Id, matched.Id));
                }
                if (selections.GroupBy(selection => selection.SettingId).Any(group => group.Select(selection => selection.OptionId).Distinct().Count() != 1)) throw new InvalidDataException("A custom switch assigns contradictory values to one resource.");
                presets.Add(new("custom." + entry.Id + "." + option.Id, entry.Name + " · " + option.Name, selections.Distinct().ToArray()));
            }
        }
        var result = catalog with { Settings = settings.ToArray(), Presets = presets.ToArray() }; result.Validate(); return result;
    }
    private sealed record Part(string Key, string Desired, TweakAssignment? Change, ControlAssignment? Control);
    private static IEnumerable<Part> Parts(TweakOption option)
    {
        foreach (var change in option.Changes)
        {
            var key = JsonSerializer.Serialize(new { change.Address, Field = change.Token?.Name, Mask = change.Bits?.Mask, change.Selector }, OperationFiles.Json).ToUpperInvariant();
            yield return new(key, JsonSerializer.Serialize(new { change.Dword, change.Value, change.Token, change.Bits, change.Formula }, OperationFiles.Json), change, null);
        }
        foreach (var control in option.Controls ?? [])
        {
            var fields = control.Patch ? string.Join('|', control.Value.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal)) : "";
            yield return new(control.Address.Key + "|" + fields, JsonSerializer.Serialize(new { control.Value, control.Patch }, OperationFiles.Json), null, control);
        }
    }
    public static TweakCatalog Import(TweakCatalog catalog, string path)
    {
        if (new FileInfo(path).Length > 2097152) throw new InvalidDataException("The custom settings file exceeds 2 MiB.");
        var document = OperationFiles.Read<JsonElement>(path);
        var entries = ParseConstructor(document);
        using var guard = OperationFiles.Lock(Store);
        var current = Read(); var updated = current with { Entries = current.Entries.Where(entry => !entries.Any(incoming => incoming.Id == entry.Id)).Concat(entries).ToArray() };
        if (updated.Entries.Length > 200) throw new InvalidDataException("At most 200 custom switches can be imported.");
        var merged = Merge(catalog, updated.Entries);
        if (OperationFiles.Exists(Store)) OperationFiles.Write(Store + ".previous.json", current);
        OperationFiles.Write(Store, updated); return merged;
    }
    public static TweakCatalog AddOwnership(TweakCatalog catalog, string path)
    {
        var address = new ControlAddress("file-ownership", "selected:" + FileLease.NormalizePath(path), "permissions");
        var read = FileAccessControl.Read(address);
        var definition = new TweakDefinition("ownership." + read.Id[..16].ToLowerInvariant(), "File ownership: " + Path.GetFileName(path), "File permissions",
            "Set this item's owner to the current Windows user and add a non-inheriting Full Control entry. Existing deny entries still apply. Child items stay unchanged.", 10240, 26200, ["*"], "none",
            [new("take", "Take ownership", [], Controls: [new(address, ControlValues.From(new { takeOwnership = true }))])], [new("Roo Industries", "selected file", read.Identity)], Advanced: true);
        using var guard = OperationFiles.Lock(Store); var current = Read();
        var updated = current with { Entries = current.Entries.Where(entry => entry.Id != definition.Id).Append(definition).ToArray() };
        if (updated.Entries.Length > 200) throw new InvalidDataException("Restore unused file-permission profiles before adding another ownership entry.");
        var merged = Merge(catalog, updated.Entries); OperationFiles.Write(Store, updated); return merged;
    }
    public static void PruneOwnership(TweakState state)
    {
        if (!OperationFiles.Exists(Store)) return;
        using var guard = OperationFiles.Lock(Store); var current = Read();
        var held = state.Profiles.SelectMany(profile => profile.Controls ?? []).Select(claim => "ownership." + claim.Target.Id[..16].ToLowerInvariant()).ToHashSet(StringComparer.Ordinal);
        var entries = current.Entries.Where(entry => !entry.Id.StartsWith("ownership.", StringComparison.Ordinal) || held.Contains(entry.Id)).ToArray();
        if (entries.Length != current.Entries.Length) OperationFiles.Write(Store, current with { Entries = entries });
    }
    public static TweakDefinition[] ParseConstructor(JsonElement document)
    {
        if (document.ValueKind != JsonValueKind.Object || document.EnumerateObject().Any(property => property.Name != "switches") || !document.TryGetProperty("switches", out var switches) || switches.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Import a constructor JSON object containing named switches.");
        var entries = new List<TweakDefinition>();
        foreach (var item in switches.EnumerateObject())
        {
            var value = item.Value;
            if (value.EnumerateObject().Any(property => property.Name is not ("Type" or "Header" or "Description" or "Params"))) throw new InvalidDataException("The custom switch contains an unsupported field.");
            var kind = value.GetProperty("Type").GetString(); var parameters = value.GetProperty("Params");
            string Required(string name) => parameters.GetProperty(name).GetString() ?? throw new InvalidDataException("A custom switch parameter is missing: " + name);
            var name = value.TryGetProperty("Header", out var header) ? header.GetString()! : Required("Name");
            var description = value.TryGetProperty("Description", out var detail) ? detail.GetString()! : "Imported Windows setting. Review its exact target before applying.";
            var changesOn = new List<TweakAssignment>(); var changesOff = new List<TweakAssignment>(); var controlsOn = new List<ControlAssignment>(); var controlsOff = new List<ControlAssignment>();
            string[] allowed;
            switch (kind)
            {
                case "Gp": case "Registry":
                    allowed = ["Section", "Path", "Name", "ValueOn", "ValueOff", "ValueKind"];
                    var hive = Required("Section") switch { "Machine" => "LocalMachine", "User" => "CurrentUser", _ => throw new InvalidDataException("Custom registry scope must be Machine or User.") };
                    var address = new RegistryAddress(hive, "Registry64", Required("Path"), "value", Required("Name"));
                    var type = parameters.TryGetProperty("ValueKind", out var valueKind) ? valueKind.GetString()! : "DWord";
                    TweakAssignment Assignment(string field)
                    {
                        if (!parameters.TryGetProperty(field, out var raw)) return new(address, null);
                        var text = raw.GetString() ?? throw new InvalidDataException("Constructor values must use strings.");
                        return type switch
                        {
                            "DWord" when uint.TryParse(text, out var number) => new(address, number),
                            "String" => new(address, null, new(address.ValueName!, 1, Encoding.Unicode.GetBytes(text + "\0"))),
                            "ExpandString" => new(address, null, new(address.ValueName!, 2, Encoding.Unicode.GetBytes(text + "\0"))),
                            _ => throw new InvalidDataException("Custom registry values currently support DWord, String and ExpandString."),
                        };
                    }
                    if (!parameters.TryGetProperty("ValueOff", out _)) throw new InvalidDataException("A constructor switch requires ValueOff; omission is not an instruction to delete.");
                    if (kind == "Registry" && !parameters.TryGetProperty("ValueOn", out _)) throw new InvalidDataException("A registry constructor switch requires ValueOn.");
                    changesOn.Add(Assignment("ValueOn")); changesOff.Add(Assignment("ValueOff")); break;
                case "Service":
                    allowed = ["Name", "DefaultStartup", "DefaultRun"];
                    if (!uint.TryParse(Required("DefaultStartup"), out var startup) || startup is < 2 or > 4 || !bool.TryParse(Required("DefaultRun"), out var running)) throw new InvalidDataException("Service constructor requires explicit startup 2, 3 or 4 and a Boolean DefaultRun.");
                    controlsOn.Add(new(new("service", Required("Name"), "startup"), ControlValues.From(startup))); controlsOn.Add(new(new("service", Required("Name"), "running"), ControlValues.From(running)));
                    controlsOff.Add(new(new("service", Required("Name"), "startup"), ControlValues.From(4))); controlsOff.Add(new(new("service", Required("Name"), "running"), ControlValues.From(false))); break;
                case "Scheduler":
                    allowed = ["Path", "Name"];
                    var target = "\\" + Required("Path").Trim('\\') + "\\" + Required("Name");
                    controlsOn.Add(new(new("scheduled-task", target, "enabled"), ControlValues.From(true))); controlsOff.Add(new(new("scheduled-task", target, "enabled"), ControlValues.From(false))); break;
                default: throw new InvalidDataException("Supported constructor types are Gp, Registry, Service and Scheduler.");
            }
            if (parameters.EnumerateObject().Any(property => !allowed.Contains(property.Name))) throw new InvalidDataException("The constructor includes unsupported parameters; they were not ignored.");
            entries.Add(new("constructor." + OperationFiles.Hash(Encoding.UTF8.GetBytes(item.Name + "|" + kind + "|" + name))[..16].ToLowerInvariant(), name, "Custom settings", description, 10240, 26200, ["*"], "sign-out",
                [new("on", "On", changesOn.ToArray(), Controls: controlsOn.ToArray()), new("off", "Off", changesOff.ToArray(), Controls: controlsOff.ToArray())], [new("Custom settings", "constructor import", "Explicit user-provided targets and values")], Advanced: true));
        }
        if (entries.Count is 0 or > 200) throw new InvalidDataException("Import between one and 200 switches.");
        return entries.ToArray();
    }
}
