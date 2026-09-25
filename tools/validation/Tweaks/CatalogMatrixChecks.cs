using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using RooIndustries.Optimizer;

static class CatalogMatrixChecks
{
    private const string Interface = "12345678-1234-1234-1234-123456789ABC";
    private sealed record Context(int Build, string Edition, int? Edge, int Profile);
    public static void Run(string root, TweakCatalog catalog, string output)
    {
        var results = new List<object>(); var failed = 0; var total = 0;
        foreach (var definition in catalog.Settings)
        foreach (var option in definition.Options)
        {
            total++;
            var directory = Path.Combine(root, "matrix-" + total); Directory.CreateDirectory(directory);
            try
            {
                var subset = catalog with { Settings = [definition], Presets = [], Incompatible = null };
                Exercise(directory, subset, [new(definition.Id, option.Id)]);
                results.Add(new { setting = definition.Id, option = option.Id, result = "passed" });
            }
            catch (Exception error) { failed++; results.Add(new { setting = definition.Id, option = option.Id, result = "failed", error = error.Message }); }
            finally { Directory.Delete(directory, true); }
            if (total % 100 == 0) Console.WriteLine($"Catalog choices checked: {total}; failures: {failed}");
        }
        OperationFiles.Write(output, new { settings = catalog.Settings.Length, choices = total, passed = total - failed, failed, results });
        if (total != catalog.Settings.Sum(setting => setting.Options.Length) || failed != 0) throw new InvalidOperationException($"Catalog matrix failed {failed} of {total} choices. See {output}");
        Console.WriteLine($"PASS all {total} catalog choices apply, share ownership, replay and restore in isolated file fixtures");
    }
    public static void Presets(string root, TweakCatalog catalog, string output)
    {
        var results = new List<object>(); var failed = 0; var total = 0;
        foreach (var preset in catalog.Presets)
        {
            total++;
            var directory = Path.Combine(root, "preset-" + total); Directory.CreateDirectory(directory);
            try
            {
                var definitions = preset.Selections.Select(selection => catalog.Resolve(selection).Definition).DistinctBy(item => item.Id).ToArray();
                var subset = catalog with { Settings = definitions, Presets = [preset], Incompatible = null };
                Exercise(directory, subset, preset.Selections, preset);
                results.Add(new { preset = preset.Id, choices = preset.Selections.Length, result = "passed" });
            }
            catch (Exception error) { failed++; results.Add(new { preset = preset.Id, result = "failed", error = error.Message }); }
            finally { Directory.Delete(directory, true); }
            if (total % 100 == 0) Console.WriteLine($"Catalog presets checked: {total}; failures: {failed}");
        }
        OperationFiles.Write(output, new { presets = total, passed = total - failed, failed, results });
        if (total != catalog.Presets.Length || failed != 0) throw new InvalidOperationException($"Preset matrix failed {failed} of {total} presets. See {output}");
        Console.WriteLine($"PASS all {total} presets apply, share ownership, replay and restore in isolated file fixtures");
    }
    private static bool Supported(TweakDefinition definition, TweakOption option, Context context)
    {
        bool Requirement(string text)
        {
            if (text == "legacy-edge") return context.Edge is null;
            if (!text.StartsWith("edge:", StringComparison.Ordinal) && !text.StartsWith("edge-profile:", StringComparison.Ordinal)) return text is "office" or "office16" or "local-session";
            var parts = text.Split(':'); var version = parts[0] == "edge" ? context.Edge : context.Profile;
            return version >= int.Parse(parts[1]) && version <= int.Parse(parts[2]);
        }
        bool Gate(int minimum, int maximum, string[] editions, string[]? requirements) => context.Build >= minimum && context.Build <= maximum &&
            (editions.Contains("*") || editions.Contains(context.Edition)) && (requirements ?? []).All(Requirement);
        return Gate(definition.MinimumBuild, definition.MaximumBuild, definition.Editions, definition.Requirements) &&
            (option.Availability is null || option.Availability.Any(gate => Gate(gate.MinimumBuild, gate.MaximumBuild, gate.Editions, gate.Requirements))) &&
            (option.ValidUntilUtc is null || option.ValidUntilUtc > DateTime.UtcNow);
    }
    private static Context ContextFor(TweakCatalog catalog, TweakSelection[] selections, bool partial)
    {
        var options = selections.Select(catalog.Resolve).ToArray();
        var gates = options.SelectMany(item => item.Option.Availability ?? []).ToArray();
        var builds = options.Select(item => item.Definition.MinimumBuild).Concat(gates.Select(gate => gate.MinimumBuild)).Append(26200).Distinct().OrderDescending();
        var editions = gates.SelectMany(gate => gate.Editions).Concat(options.SelectMany(item => item.Definition.Editions)).Where(edition => edition != "*").Prepend("Professional").Append("Enterprise").Distinct();
        var requirements = gates.SelectMany(gate => gate.Requirements ?? []).Concat(options.SelectMany(item => item.Definition.Requirements ?? []));
        var edge = requirements.Where(text => text.StartsWith("edge:", StringComparison.Ordinal) || text.StartsWith("edge-profile:", StringComparison.Ordinal)).Select(text => (int?)int.Parse(text.Split(':')[1])).Append(150).Append(null).Distinct().ToArray();
        var contexts = from build in builds from edition in editions from version in edge select new Context(build, edition, version, version ?? 150);
        return contexts.OrderByDescending(context => options.Count(item => Supported(item.Definition, item.Option, context))).FirstOrDefault(context => partial || options.All(item => Supported(item.Definition, item.Option, context)))
            ?? throw new InvalidDataException("The preset has no common Windows, edition and product context.");
    }
    private static void Exercise(string directory, TweakCatalog catalog, TweakSelection[] selections, TweakPreset? preset = null)
    {
        var context = ContextFor(catalog, selections, preset?.AvailableOnly == true);
        var expectedSelections = selections.Where(selection => { var item = catalog.Resolve(selection); return Supported(item.Definition, item.Option, context); }).Distinct().ToArray();
        var path = Path.Combine(directory, "fixture.json");
        var store = FileTweakStore.Create(path, context.Build, context.Edition);
        var fixture = OperationFiles.Read<TweakFixture>(path) with
        {
            InstalledMemoryKiB = 33554432, OfficeMajor = 16, EdgeMajor = context.Edge, EdgeProfileMajor = context.Profile,
            PrimaryInterfaces = [Interface], MenuExecutable = @"C:\Program Files\Roo Industries\app.exe",
        };
        foreach (var change in catalog.Settings.SelectMany(definition => definition.Options).SelectMany(item => item.Changes)) SeedRegistry(fixture, change);
        foreach (var control in catalog.Settings.SelectMany(definition => definition.Options).SelectMany(item => item.Controls ?? []).DistinctBy(item => item.Address.Key))
            fixture.Controls[control.Address.Key] = SeedControl(control, catalog);
        var sysMain = new ControlAddress("service", "SysMain", "startup");
        fixture.Controls.TryAdd(sysMain.Key, new(sysMain, sysMain.Key, "fixture", ControlValues.From(3)));
        OperationFiles.Write(path, fixture);
        var originalKeys = ControlValues.From(fixture.Keys);
        var originalControls = fixture.Controls.ToDictionary(item => item.Key, item => item.Value);
        var engine = new TweakEngine(catalog, store);
        TweakApplyResult Apply(string profile, TweakSelection[] choices)
        {
            var review = preset is not null && choices.Length > 0 ? engine.PreviewPreset(profile, preset.Id) : engine.Preview(profile, choices);
            if (choices.Length > 0) Require(review.Selections.OrderBy(item => item.SettingId).SequenceEqual(expectedSelections.OrderBy(item => item.SettingId)), "Preset applicability differs from the independently selected context");
            var file = Path.Combine(directory, review.OperationId + ".json");
            OperationFiles.Write(file, review); var result = engine.Apply(file, OperationFiles.HashFile(file), acceptDataLoss: true);
            var writes = OperationFiles.Read<TweakFixture>(path).Writes;
            var replay = engine.Apply(file, OperationFiles.HashFile(file), acceptDataLoss: true);
            Require(replay.Replayed && OperationFiles.Read<TweakFixture>(path).Writes == writes, "Replay wrote a setting again");
            return result;
        }
        Apply("first", selections);
        foreach (var change in expectedSelections.SelectMany(selection => catalog.Resolve(selection).Option.Changes).SelectMany(store.Resolve)) AssertRegistry(store.Read(change.Address with { KeyPath = change.Address.KeyPath.Replace("{user-sid}", fixture.Context.Owner.UserSid, StringComparison.Ordinal) }).Value, change);
        var applied = OperationFiles.Read<TweakFixture>(path);
        Apply("second", selections);
        Require(OperationFiles.Read<TweakFixture>(path).Writes == applied.Writes, "A shared owner wrote the same value again");
        Apply("first", []);
        Require(OperationFiles.Read<TweakFixture>(path).Writes == applied.Writes, "Removing one owner reverted a shared value");
        Apply("second", []);
        var restored = OperationFiles.Read<TweakFixture>(path);
        Require(restored.State?.Profiles.Length == 0 && restored.State.Held.Length == 0 && restored.State.Controls?.Length == 0, "Restored profiles retained ownership");
        Require(ControlValues.Equal(ControlValues.From(restored.Keys), originalKeys), "Registry restore differs from independently seeded bytes, types or keys");
        Require(originalControls.All(item => restored.Controls.TryGetValue(item.Key, out var actual) && actual.Same(item.Value)), "Native-control fixture restore differs from original state");
    }
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static string Native(TweakFixture fixture, RegistryAddress address, string path) =>
        (address.Hive == "CurrentUser" ? @"\REGISTRY\USER\" + fixture.Context.Owner.UserSid : address.Hive == "Users" ? @"\REGISTRY\USER" : @"\REGISTRY\MACHINE") + "\\" +
        (address.View == "Registry32" && address.Hive == "LocalMachine" ? path.Replace("Software\\", "Software\\WOW6432Node\\", StringComparison.OrdinalIgnoreCase) : path);
    private static void Put(TweakFixture fixture, RegistryAddress address, RegistryValueData? value)
    {
        address = address with { KeyPath = address.KeyPath.Replace("{office-major-version}", "16", StringComparison.Ordinal).Replace("{user-sid}", fixture.Context.Owner.UserSid, StringComparison.Ordinal) };
        var parts = address.KeyPath.Split('\\');
        for (var count = 1; count <= parts.Length; count++)
        {
            var key = Native(fixture, address, string.Join('\\', parts.Take(count)));
            fixture.Keys.TryAdd(key.ToUpperInvariant(), new(key, "original-metadata", []));
        }
        if (value is not null) fixture.Keys[Native(fixture, address, address.KeyPath).ToUpperInvariant()].Values[value.Name.ToUpperInvariant()] = value;
    }
    private static void SeedRegistry(TweakFixture fixture, TweakAssignment change)
    {
        var address = change.Address;
        if (change.Selector is { } selector)
        {
            var path = address.KeyPath;
            for (var depth = 0; depth < selector.Depth; depth++) path += "\\" + (selector.Filter == "primary-interfaces" ? "{" + Interface + "}" : "0000");
            Put(fixture, address with { KeyPath = path }, null);
            Put(fixture, address with { KeyPath = path }, new("NetCfgInstanceId", 1, Encoding.Unicode.GetBytes("{" + Interface + "}\0")));
            Put(fixture, address with { KeyPath = path }, new("DriverDesc", 1, Encoding.Unicode.GetBytes("Physical Ethernet device\0")));
            address = address with { KeyPath = (selector.TargetRoot is null ? path : selector.TargetRoot + "\\" + path.Split('\\')[^1]) + (selector.Suffix.Length == 0 ? "" : "\\" + selector.Suffix) };
        }
        var value = change.Token is { } token ? new RegistryValueData(address.ValueName!, 1, Encoding.Unicode.GetBytes("Unrelated=kept;" + token.Name + "=original\0"))
            : new RegistryValueData(address.ValueName!, 4, BitConverter.GetBytes(0xa5a55a5au));
        Put(fixture, address, value);
    }
    private static void AssertRegistry(RegistryValueData? actual, TweakAssignment change)
    {
        if (change.Token is { } token)
        {
            var text = actual is { Type: 1 } ? Encoding.Unicode.GetString(actual.Bytes).TrimEnd('\0') : "";
            var parts = text.Split(';', StringSplitOptions.RemoveEmptyEntries);
            Require(parts.Contains("Unrelated=kept") && (token.Value is null ? !parts.Any(part => part.StartsWith(token.Name + "=", StringComparison.Ordinal)) : parts.Contains(token.Name + "=" + token.Value)), "Token selection changed unrelated data or did not match its requested field");
        }
        else if (change.Bits is { } bits) Require(actual is { Type: 4, Bytes.Length: 4 } && (BitConverter.ToUInt32(actual.Bytes) & bits.Mask) == bits.Value && (BitConverter.ToUInt32(actual.Bytes) & ~bits.Mask) == (0xa5a55a5au & ~bits.Mask), "Bit selection changed unrelated flags");
        else
        {
            var expected = change.Dword is { } dword ? new RegistryValueData(change.Address.ValueName!, 4, BitConverter.GetBytes(dword)) : change.Value;
            Require(expected is null ? actual is null : actual is not null && actual.Type == expected.Type && actual.Bytes.SequenceEqual(expected.Bytes), "Applied registry type or bytes differ from the requested catalog value");
        }
    }
    private static TweakControlRead SeedControl(ControlAssignment control, TweakCatalog catalog)
    {
        var address = control.Address; var binding = "fixture"; object? value;
        Dictionary<string, string[]>? parents = null;
        switch (address.Kind)
        {
            case "hosts": value = HostsBlock.Read(Encoding.UTF8.GetBytes("127.0.0.1 localhost\r\n# retain this line\n")); break;
            case "file-acl":
                var acl = new RawAcl(2, 1); acl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x1f01ff, new SecurityIdentifier("S-1-5-32-544"), false, null));
                var bytes = new byte[acl.BinaryLength]; acl.GetBinaryForm(bytes, 0);
                value = new { owner = "S-1-5-32-544", group = "S-1-5-18", flags = 4, dacl = Convert.ToBase64String(bytes) }; break;
            case "power-plan": binding = "98472f39-9146-5073-8c16-73ea66ded98f"; value = new { active = "381b4222-f694-41f0-9685-ff5bb260df2e", original = "381b4222-f694-41f0-9685-ff5bb260df2e", plan = (string?)null, template = new string('A', 64) }; break;
            case "hibernation": binding = "power-capabilities:s4=True"; value = new { mode = "Off", sizePercent = (uint?)null, configuredType = (uint?)null, enabled = 0, defaultEnabled = 1, fastStartup = 1 }; break;
            case "mitigations": return new(address, address.Key, binding, MitigationControl.Snapshot(null, null, null));
            case "windows-features":
                var fields = catalog.Settings.SelectMany(setting => setting.Options).SelectMany(option => option.Controls ?? []).Where(item => item.Address == address).SelectMany(item => item.Value.EnumerateObject()).DistinctBy(item => item.Name);
                value = fields.ToDictionary(item => item.Name, item => item.Value.ValueKind is JsonValueKind.True or JsonValueKind.False ? (object)false : address.Kind == "windows-features" ? "Disabled" : "NOTSET");
                if (address.Kind == "windows-features") parents = ((Dictionary<string, object>)value).Keys.ToDictionary(name => name, _ => Array.Empty<string>());
                break;
            case "network-adapter": case "device-power":
                value = new Dictionary<string, object> { [Interface] = address.Property switch { "lso" => new { ipv4v1 = true, ipv4 = true, ipv6 = true }, "rsc" => new { ipv4 = true, ipv6 = true }, _ => true } }; break;
            case "service": value = address.Property == "startup" ? (object)3 : false; break;
            case "dns-over-https": case "firewall-blocklist": case "boot-configuration": value = null; break;
            case "teredo": value = "Default"; break;
            case "filesystem": value = 2; break;
            case "defender": value = 1; break;
            case "firewall-profile": value = "NotConfigured"; break;
            case "memory": case "reserved-storage": case "timer": case "timer-startup": case "scheduled-task": case "download-blocker": value = false; break;
            default: throw new InvalidOperationException("No independently specified control fixture for " + address.Kind);
        }
        return new(address, address.Key, binding, ControlValues.From(value), Parents: parents);
    }
}
