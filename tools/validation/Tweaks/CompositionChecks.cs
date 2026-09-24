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
        var drifted = engine.Preview("first", []);
        check(drifted.Changes.Length == 0 && drifted.LeftAsChanged.Length == 0, "An owned field Windows put back to its original is released without a report");
        Apply("first", new TweakSelection("vrr", "on"));
        External(Text("VRR=1;VRR=1;"));
        var unreadable = engine.Preview("first", []);
        check(unreadable.Changes.Length == 0 && unreadable.LeftAsChanged.SequenceEqual(new[] { "vrr" }), "A value rewritten into an unreadable form is released and reported instead of blocking restore");
        reject(() => engine.Preview("first", [new("vrr", "on")]), "Writing a choice into an unreadable value is rejected");
        Apply("first");
        check(Text("VRR=1;VRR=1;").Bytes.SequenceEqual(store.Read(address).Value!.Bytes) && store.ReadState()!.Profiles.Length == 0, "Releasing an unreadable value leaves it untouched");
        path = Path.Combine(root, "field-drift.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("both", new TweakSelection("vrr", "on"), new TweakSelection("windowed", "off"));
        External(Text("VRR=5;Windowed=0;"));
        var partial = engine.Preview("both", []);
        check(partial.LeftAsChanged.SequenceEqual(new[] { "vrr" }), "Only the field changed elsewhere is reported");
        Apply("both");
        check(Read("VRR") == "5" && Read("Windowed") is null && store.ReadState()!.Profiles.Length == 0, "Restore still reverts the fields in the same value that nobody changed");
        path = Path.Combine(root, "neighbour-drift.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("vrr-owner", new TweakSelection("vrr", "on")); Apply("windowed-owner", new TweakSelection("windowed", "off"));
        External(Text("VRR=1;Windowed=7;"));
        var neighbour = engine.Preview("vrr-owner", []);
        check(neighbour.LeftAsChanged.Length == 0, "A neighbouring field changed elsewhere is not blamed on this profile");
        Apply("vrr-owner");
        check(Read("VRR") is null && Read("Windowed") == "7" && store.ReadState()!.Profiles.Single().Id == "windowed-owner", "A profile whose own field is intact restores it even when a neighbouring field drifted");
        var last = engine.Preview("windowed-owner", []);
        check(last.LeftAsChanged.SequenceEqual(new[] { "windowed" }), "The owner of the drifted neighbouring field gets the report");
        Apply("windowed-owner");
        check(Read("Windowed") == "7" && store.ReadState()!.Profiles.Length == 0, "The drifted neighbouring field keeps its outside value");
        path = Path.Combine(root, "unowned-drift.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("vrr-owner", new TweakSelection("vrr", "on"));
        External(Text("Foreign=new;"));
        var unowned = engine.Preview("vrr-owner", []);
        check(unowned.Changes.Length == 0 && unowned.LeftAsChanged.Length == 0, "An owned field back at its original is not reported when an unowned field changed");
        path = Path.Combine(root, "shared-field-drift.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("a", new TweakSelection("vrr", "on")); Apply("b", new TweakSelection("vrr", "on"), new TweakSelection("windowed", "off"));
        External(Text("VRR=1;Windowed=7;"));
        Apply("a");
        check(Read("VRR") == "1" && Read("Windowed") == "7" && store.ReadState()!.Profiles.Single().Id == "b", "Releasing a field another profile still owns keeps it applied");
        var sharedLast = engine.Preview("b", []);
        check(sharedLast.LeftAsChanged.SequenceEqual(new[] { "windowed" }), "The saved state stays readable after a shared field is released");
        Apply("b");
        check(Read("VRR") is null && Read("Windowed") == "7" && store.ReadState()!.Profiles.Length == 0, "The last owner of a shared field restores it and leaves the drifted neighbour");
        path = Path.Combine(root, "applied-shortcut.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("vrr-owner", new TweakSelection("vrr", "on")); Apply("windowed-owner", new TweakSelection("windowed", "off"));
        External(Text("Windowed=0;"));
        Apply("vrr-owner");
        External(Text("VRR=1;Windowed=0;"));
        Apply("windowed-owner");
        check(Read("VRR") == "1" && Read("Windowed") is null, "A later full restore does not wipe a field the user set again after its owner was released");
        path = Path.Combine(root, "resend-drift.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("vrr-owner", new TweakSelection("vrr", "on")); Apply("windowed-owner", new TweakSelection("windowed", "off"));
        External(Text("VRR=1;Windowed=7;"));
        var resend = engine.Preview("vrr-owner", [new("vrr", "on")]);
        check(resend.Changes.Length == 0, "Re-sending a profile does not rewrite another profile's field that Windows changed");
        Apply("vrr-owner", new TweakSelection("vrr", "on"));
        check(Read("Windowed") == "7" && engine.Preview("windowed-owner", []).LeftAsChanged.SequenceEqual(new[] { "windowed" }), "The other profile's changed field stays and is reported on its own restore");
        path = Path.Combine(root, "new-field-drift.json"); store = FileTweakStore.Create(path); engine = new(catalog, store);
        Apply("vrr-owner", new TweakSelection("vrr", "on"));
        External(Text("VRR=0;Windowed=7;"));
        Apply("windowed-owner", new TweakSelection("windowed", "off"));
        check(Read("Windowed") == "0" && Read("VRR") == "0", "A new field on a drifted value is written without touching the drifted field");
        Apply("windowed-owner");
        check(Read("Windowed") == "7" && Read("VRR") == "0" && store.ReadState()!.Profiles.Single().Id == "vrr-owner", "A field first claimed on a drifted value restores to the value it had when claimed");
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
        Apply("both", new TweakSelection("a", "clear"), new TweakSelection("b", "clear"));
        var bitsFixture = OperationFiles.Read<TweakFixture>(path);
        bitsFixture.Keys[store.Read(bitsAddress).NativeKey.ToUpperInvariant()].Values["FLAGS"] = new("Flags", 4, BitConverter.GetBytes(191u)); OperationFiles.Write(path, bitsFixture);
        var bitPlan = engine.Preview("both", []);
        check(bitPlan.LeftAsChanged.Length == 0, "A bit Windows put back to its original is not reported");
        Apply("both");
        check(store.Read(bitsAddress).Value is null, "Releasing drifted bits back to all-default removes a value that was originally absent");
        Apply("both", new TweakSelection("a", "clear"), new TweakSelection("b", "clear"));
        bitsFixture = OperationFiles.Read<TweakFixture>(path);
        bitsFixture.Keys[store.Read(bitsAddress).NativeKey.ToUpperInvariant()].Values["FLAGS"] = new("Flags", 1, Encoding.Unicode.GetBytes("rewritten\0")); OperationFiles.Write(path, bitsFixture);
        var retyped = engine.Preview("both", []);
        check(retyped.Changes.Length == 0 && retyped.LeftAsChanged.SequenceEqual(new[] { "a", "b" }), "Bits rewritten as another value type are released and reported instead of blocking undo");
        Apply("both");
        check(store.Read(bitsAddress).Value!.Type == 1 && store.ReadState()!.Profiles.Length == 0, "Undo leaves a value another app rewrote with a different type");
        bitsFixture = OperationFiles.Read<TweakFixture>(path); bitsFixture.Keys[store.Read(bitsAddress).NativeKey.ToUpperInvariant()].Values.Remove("FLAGS"); OperationFiles.Write(path, bitsFixture);
        Apply("both", new TweakSelection("a", "clear"), new TweakSelection("b", "clear"));
        bitsFixture = OperationFiles.Read<TweakFixture>(path);
        bitsFixture.Keys[store.Read(bitsAddress).NativeKey.ToUpperInvariant()].Values["FLAGS"] = new("Flags", 4, new byte[3]); OperationFiles.Write(path, bitsFixture);
        var broken = engine.Preview("both", []);
        check(broken.Changes.Length == 0 && broken.LeftAsChanged.SequenceEqual(new[] { "a", "b" }), "Undo releases a value rewritten into a form that cannot be restored exactly");
        Apply("both");
        check(store.ReadState()!.Profiles.Length == 0, "Undo of an unrestorable value leaves no ownership behind");
        var typedAddress = new RegistryAddress("Users", "Registry64", @".DEFAULT\Control Panel\Keyboard", "value", "InitialKeyboardIndicators");
        var typed = new TweakCatalog(1, "typed", [new("typed", "Num Lock", "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("on", "On", [new(typedAddress, null, new("InitialKeyboardIndicators", 1, Encoding.Unicode.GetBytes("2\0")))])], sources)], []);
        path = Path.Combine(root, "typed.json"); store = FileTweakStore.Create(path); engine = new(typed, store);
        Apply("typed", new TweakSelection("typed", "on"));
        check(store.Read(typedAddress).NativeKey.StartsWith(@"\REGISTRY\USER\.DEFAULT\") && store.Read(typedAddress).Value!.Type == 1, "Typed strings and the default-user hive retain their explicit scope");
        Apply("typed"); check(!store.Read(typedAddress).KeyExists, "Typed default-user fixture restores value and key absence");
    }
}
