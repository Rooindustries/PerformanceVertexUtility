using System.Text;
using RooIndustries.Optimizer;

static class CompositionChecks
{
    public static void Run(string root, Action<bool, string> check, Action<Action, string> reject)
    {
        var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\FieldFixture", "value", "Preferences");
        RegistryValueData Text(string value) => new("Preferences", 1, Encoding.Unicode.GetBytes(value + '\0'));
        var sources = new TweakSource[] { new("Roo Industries", "fixture", "controlled values") };
        TweakDefinition Field(string id, string name) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("on", "On", [new(address, null, Token: new(name, "1"))]), new("off", "Off", [new(address, null, Token: new(name, "0"))])], sources);
        var catalog = new TweakCatalog(1, "fields", [Field("vrr", "VRR"), Field("windowed", "Windowed"),
            new("whole", "Whole", "Fixture", "Fixture", 10240, 26200, ["*"], "none", [new("set", "Set", [new(address, null, Text("Whole=1;"))])], sources)], []);
        var path = Path.Combine(root, "fields.json"); var store = FileTweakStore.Create(path); var engine = new TweakEngine(catalog, store);
        void Apply(string profile, params TweakSelection[] selections)
        {
            var plan = engine.Preview(profile, selections);
            var review = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(review, plan);
            engine.Apply(review, OperationFiles.HashFile(review));
        }
        void External(RegistryValueData value)
        {
            var fixture = OperationFiles.Read<TweakFixture>(path);
            fixture.Keys[store.Read(address).NativeKey.ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = value;
            OperationFiles.Write(path, fixture);
        }
        string? Read(string name) => TweakTokens.Get(store.Read(address).Value, name);
        Apply("first", new TweakSelection("vrr", "on")); Apply("second", new TweakSelection("windowed", "off"));
        check(Read("VRR") == "1" && Read("Windowed") == "0", "Independent string fields compose into one registry value");
        Apply("first");
        check(Read("VRR") is null && Read("Windowed") == "0", "Releasing one string field preserves the other profile");
        Apply("second");
        check(store.Read(address).Value is null && !store.Read(address).KeyExists, "Final field release restores an originally absent string and keys");
        Apply("first", new TweakSelection("vrr", "on")); External(Text("VRR=1;Foreign=keep;"));
        Apply("first");
        check(Read("VRR") is null && Read("Foreign") == "keep", "Restore preserves unowned fields changed by another application");
        var raw = Text("Foreign =keep;;VRR=0;Windowed=9;"); External(raw);
        Apply("first", new TweakSelection("vrr", "on")); Apply("first");
        check(TweakRead.SameValue(store.Read(address).Value, raw), "Unchanged field restore preserves original string bytes exactly");
        Apply("first", new TweakSelection("vrr", "on")); External(Text("Foreign =new;;VRR=1;Windowed=7;"));
        Apply("second", new TweakSelection("windowed", "off")); Apply("first"); Apply("second");
        check(Read("Windowed") == "7" && Read("Foreign") == "new" && Read("VRR") == "0", "A later owner captures its field at acquisition and retains unrelated intervening changes");
        Apply("first", new TweakSelection("vrr", "on"));
        reject(() => engine.Preview("whole", [new("whole", "set")]), "Whole-string replacement conflicts with active field ownership");
        reject(() => engine.Preview("other", [new("vrr", "off")]), "Opposite choices for the same string field conflict");
        External(Text("VRR=0;"));
        reject(() => engine.Preview("first", []), "Owned string field drift requires a new decision before restore");
        External(Text("VRR=1;VRR=1;"));
        reject(() => engine.Preview("first", []), "Ambiguous duplicate string fields cannot be silently overwritten");
        var bitsAddress = address with { ValueName = "Flags" };
        TweakDefinition Bit(string id, uint mask) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("clear", "Clear", [new(bitsAddress, null, Bits: new(mask, 0, 255))])], sources);
        catalog = new(1, "bits", [Bit("a", 1), Bit("b", 64)], []);
        path = Path.Combine(root, "bits.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        uint Number() => BitConverter.ToUInt32(store.Read(bitsAddress).Value!.Bytes);
        Apply("first", new TweakSelection("a", "clear")); Apply("second", new TweakSelection("b", "clear"));
        check(Number() == 190, "Independent bit fields compose while preserving other bits");
        Apply("first"); check(Number() == 191, "Bit release restores only its original bit");
        Apply("second"); check(store.Read(bitsAddress).Value is null, "Last bit owner restores an absent original value");
        var typedAddress = new RegistryAddress("Users", "Registry64", @".DEFAULT\Control Panel\Keyboard", "value", "InitialKeyboardIndicators");
        var typed = new TweakCatalog(1, "typed", [new("typed", "Num Lock", "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("on", "On", [new(typedAddress, null, new("InitialKeyboardIndicators", 1, Encoding.Unicode.GetBytes("2\0")))])], sources)], []);
        path = Path.Combine(root, "typed.json"); store = FileTweakStore.Create(path); engine = new(typed, store);
        Apply("typed", new TweakSelection("typed", "on"));
        check(store.Read(typedAddress).NativeKey.StartsWith(@"\REGISTRY\USER\.DEFAULT\") && store.Read(typedAddress).Value!.Type == 1, "Typed strings and the default-user hive retain their explicit scope");
        Apply("typed"); check(!store.Read(typedAddress).KeyExists, "Typed default-user fixture restores value and key absence");
    }
}
