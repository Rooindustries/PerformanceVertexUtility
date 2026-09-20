using System.Text;
using RooIndustries.Optimizer;

static class SelectionChecks
{
    public static void Run(string root, Action<bool, string> check, Action<Action, string> reject)
    {
        var path = Path.Combine(root, "selection.json"); var store = FileTweakStore.Create(path);
        var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\DeviceFixture", "value", "Enabled");
        var fixture = OperationFiles.Read<TweakFixture>(path);
        var prefix = @"\REGISTRY\USER\" + fixture.Context.Owner.UserSid + @"\Software\DeviceFixture";
        foreach (var name in new[] { "{ABC}", "{DEF}" })
        {
            var key = prefix + "\\" + name;
            fixture.Keys.Add(key.ToUpperInvariant(), new(key, "inherited", new() { ["ENABLED"] = new("Enabled", 4, BitConverter.GetBytes(name == "{ABC}" ? 7u : 9u)) }));
        }
        fixture.Keys.Add(prefix.ToUpperInvariant(), new(prefix, "inherited", []));
        fixture = fixture with { PrimaryInterfaces = ["ABC"], InstalledMemoryKiB = 33554432, OfficeMajor = 16 };
        OperationFiles.Write(path, fixture);
        var selected = new TweakAssignment(address, 0, Selector: new(1, "", "primary-interfaces", true));
        var resolved = store.Resolve(selected);
        check(resolved.Length == 1 && resolved[0].Address.KeyPath.EndsWith(@"\{ABC}"), "Dynamic network selection binds the identified interface and excludes other adapters");
        var primaryDevice = selected with { Selector = new(1, "", "primary-network-devices", false) };
        var deviceTargets = RegistrySelections.Resolve(primaryDevice, _ => ["0000", "Properties"], key =>
        {
            if (key.KeyPath.EndsWith("Properties", StringComparison.Ordinal)) throw new UnauthorizedAccessException("Protected class metadata is not an adapter");
            return new() { Address = key, NativeKey = prefix + "\\0000", KeyExists = true, MissingKeys = [], Value = key.ValueName == "NetCfgInstanceId" ? new("NetCfgInstanceId", 1, Encoding.Unicode.GetBytes("{ABC}\0")) : null };
        }, () => ["ABC"]);
        check(deviceTargets.Length == 1 && deviceTargets[0].Address.KeyPath.EndsWith("0000", StringComparison.Ordinal), "Primary adapter selection skips protected class metadata before attempting a registry read");
        OperationFiles.Write(path, fixture with { PrimaryInterfaces = [] });
        reject(() => store.Resolve(selected), "Missing primary-interface evidence cannot become a wildcard selection");
        OperationFiles.Write(path, fixture);
        var sources = new TweakSource[] { new("Roo Industries", "fixture", "independent device values") };
        var definition = new TweakDefinition("devices", "Devices", "Fixture", "Fixture", 10240, 26200, ["*"], "none", [new("off", "Off", [selected])], sources);
        var catalog = new TweakCatalog(1, "devices", [definition], []); var engine = new TweakEngine(catalog, store);
        var plan = engine.Preview("devices", [new("devices", "off")]); var review = Path.Combine(root, "device-preview.json"); OperationFiles.Write(review, plan);
        OperationFiles.Write(path, fixture with { PrimaryInterfaces = ["DEF"] });
        reject(() => engine.Apply(review, OperationFiles.HashFile(review)), "A changed device selection invalidates a reviewed plan");
        OperationFiles.Write(path, fixture);
        engine.Apply(review, OperationFiles.HashFile(review));
        check(BitConverter.ToUInt32(store.Read(address with { KeyPath = address.KeyPath + @"\{ABC}" }).Value!.Bytes) == 0 && BitConverter.ToUInt32(store.Read(address with { KeyPath = address.KeyPath + @"\{DEF}" }).Value!.Bytes) == 9,
            "Dynamic application changes only the reviewed adapter");
        var restore = engine.Preview("devices", []); var restorePath = Path.Combine(root, "device-restore.json"); OperationFiles.Write(restorePath, restore); engine.Apply(restorePath, OperationFiles.HashFile(restorePath));
        check(BitConverter.ToUInt32(store.Read(address with { KeyPath = address.KeyPath + @"\{ABC}" }).Value!.Bytes) == 7, "Dynamic restoration uses captured concrete targets and original values");
        var memory = new TweakAssignment(address with { ValueName = "Threshold" }, null, Formula: "installed-memory-kib");
        check(store.Resolve(memory).Single().Dword == 33554432, "Installed-memory formula uses KiB rather than committed or used memory");
        OperationFiles.Write(path, fixture with { InstalledMemoryKiB = null });
        reject(() => store.Resolve(memory), "Missing physical-memory evidence cannot produce a guessed threshold");
        var office = new RegistryAddress("CurrentUser", "Registry64", @"Software\Microsoft\Office\{office-major-version}.0\Common", "value", "Policy");
        check(store.Read(office).Address.KeyPath == @"Software\Microsoft\Office\16.0\Common", "Office target binds one verified major version before registry access");
        OperationFiles.Write(path, fixture with { OfficeMajor = null });
        reject(() => store.Read(office), "Missing Office discovery rejects literal-placeholder registry writes");
    }
}
