using RooIndustries.Optimizer;

static class PowerCompositionChecks
{
    public static void Run(string root, Action<bool, string> check, Action<Action, string> reject)
    {
        var address = new ControlAddress("hibernation", "system", "configuration");
        TweakDefinition Setting(string id, object fields) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(address, ControlValues.From(fields), true)])], [new("Roo Industries", "fixture", "power field ownership")]);
        var catalog = new TweakCatalog(1, "power-fields", [Setting("full", new { mode = "Full", enabled = 1, configuredType = 2 }), Setting("fast-startup", new { fastStartup = 0 }), Setting("invalid-size", new { mode = "Full", sizePercent = 20 })], []);
        var path = Path.Combine(root, "power-fields.json"); var store = FileTweakStore.Create(path);
        var fixture = OperationFiles.Read<TweakFixture>(path);
        var original = new TweakControlRead(address, address.Key, "power-capabilities:s4=True", ControlValues.From(new { mode = "Off", sizePercent = (uint?)null, configuredType = (uint?)null, enabled = 0, defaultEnabled = 1, fastStartup = 1 }));
        fixture.Controls.Add(address.Key, original); OperationFiles.Write(path, fixture);
        check(!(original with { Binding = "power-capabilities:s4=False" }).Allows(ControlValues.From(new { mode = "Full" })), "Full hibernation is unavailable when Windows reports no S4 support");
        var engine = new TweakEngine(catalog, store);
        void Apply(string profile, params TweakSelection[] choices)
        {
            var plan = engine.Preview(profile, choices); var review = Path.Combine(root, plan.OperationId + ".json");
            OperationFiles.Write(review, plan); engine.Apply(review, OperationFiles.HashFile(review));
        }
        reject(() => engine.Preview("invalid", [new("invalid-size", "set")]), "An unreproducible hibernation size fails review before any power mutation");
        check(OperationFiles.Read<TweakFixture>(path).Writes == 0 && store.ReadState() is null, "Invalid hibernation review leaves configuration and ownership unchanged");
        Apply("hibernate", new TweakSelection("full", "set")); Apply("startup", new TweakSelection("fast-startup", "set"));
        check(store.ReadControl(address).Value.GetProperty("mode").GetString() == "Full" && store.ReadControl(address).Value.GetProperty("fastStartup").GetInt32() == 0, "Hibernation and Fast Startup compose as fields of one power resource");
        Apply("hibernate");
        check(store.ReadControl(address).Value.GetProperty("mode").GetString() == "Off" && store.ReadControl(address).Value.GetProperty("fastStartup").GetInt32() == 0, "Restoring hibernation preserves another profile's Fast Startup selection");
        Apply("startup");
        check(store.ReadControl(address).Same(original), "Last power owner restores the original mode and every captured field");
    }
}
