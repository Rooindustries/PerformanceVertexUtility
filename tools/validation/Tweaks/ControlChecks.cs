using System.Text.Json;
using RooIndustries.Optimizer;

static class ControlChecks
{
    public static void Run(string root, Action<bool, string> check, Action<Action, string> reject)
    {
        var startup = new ControlAddress("service", "FixtureService", "startup");
        var running = startup with { Property = "running" };
        TweakDefinition Setting(string id, ControlAddress address, object desired) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(address, ControlValues.From(desired))])], [new("Roo Industries", "fixture", "controlled service values")]);
        var catalog = new TweakCatalog(1, "native-controls", [Setting("manual", startup, 3), Setting("disabled", startup, 4), Setting("stop", running, false)], []);
        var path = Path.Combine(root, "native-controls.json"); var store = FileTweakStore.Create(path);
        var fixture = OperationFiles.Read<TweakFixture>(path);
        fixture.Controls.Add(startup.Key, new(startup, startup.Key, "fixture-service-binary", ControlValues.From(2)));
        fixture.Controls.Add(running.Key, new(running, running.Key, "fixture-service-binary", ControlValues.From(true)));
        OperationFiles.Write(path, fixture); var engine = new TweakEngine(catalog, store);
        TweakState Apply(string profile, params TweakSelection[] choices)
        {
            var plan = engine.Preview(profile, choices); var review = Path.Combine(root, plan.OperationId + ".json");
            OperationFiles.Write(review, plan); return engine.Apply(review, OperationFiles.HashFile(review)).State;
        }
        Apply("one", new TweakSelection("disabled", "set"), new TweakSelection("stop", "set"));
        check(store.ReadControl(startup).Value.GetInt32() == 4 && !store.ReadControl(running).Value.GetBoolean(), "A compound profile applies service configuration and running state");
        var writes = OperationFiles.Read<TweakFixture>(path).Writes;
        Apply("two", new TweakSelection("disabled", "set")); Apply("one");
        check(store.ReadControl(startup).Value.GetInt32() == 4 && store.ReadControl(running).Value.GetBoolean(), "Native fields retain shared ownership while released fields restore");
        check(OperationFiles.Read<TweakFixture>(path).Writes == writes + 1, "Repeated native selection does not repeat a native write");
        reject(() => engine.Preview("conflict", [new("manual", "set")]), "Conflicting native startup choices fail before mutation");
        Apply("two");
        check(store.ReadControl(startup).Value.GetInt32() == 2 && store.ReadState()!.Controls!.Length == 0, "Last native owner restores the actual original startup value");
        var preview = engine.Preview("stale", [new("manual", "set")]);
        var reviewPath = Path.Combine(root, preview.OperationId + ".json"); OperationFiles.Write(reviewPath, preview);
        fixture = OperationFiles.Read<TweakFixture>(path); fixture.Controls[startup.Key] = fixture.Controls[startup.Key] with { Binding = "replacement-service-binary" }; OperationFiles.Write(path, fixture);
        reject(() => engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath)), "Replacing a service identity invalidates a reviewed native plan");
        var policyAddress = new ControlAddress("mitigations", "system", "policy");
        TweakDefinition Policy(string id, string field, string value) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(policyAddress, ControlValues.From(new Dictionary<string, object> { [field] = value, ["override"] = false }), true)])], [new("Roo Industries", "fixture", "policy fields")]);
        var policyCatalog = new TweakCatalog(1, "policies", [Policy("dep", "dep", "ON"), Policy("cfg", "cfg", "OFF"), Policy("cfg-on", "cfg", "ON")], []);
        path = Path.Combine(root, "policy-controls.json"); store = FileTweakStore.Create(path);
        fixture = OperationFiles.Read<TweakFixture>(path);
        var policyOriginal = new TweakControlRead(policyAddress, policyAddress.Key, "policy-module", ControlValues.From(new { dep = "NOTSET", cfg = "NOTSET", other = "ON", @override = false }));
        fixture.Controls.Add(policyAddress.Key, policyOriginal); OperationFiles.Write(path, fixture); engine = new(policyCatalog, store);
        Apply("dep-owner", new TweakSelection("dep", "set")); Apply("cfg-owner", new TweakSelection("cfg", "set"));
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "ON" && store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "OFF", "Shared native policy fields compose without replacing sibling settings");
        reject(() => engine.Preview("conflict", [new("cfg-on", "set")]), "Conflicting native policy fields are rejected before execution");
        Apply("dep-owner");
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "OFF", "One policy owner restores Windows default without releasing another owner's field");
        fixture = OperationFiles.Read<TweakFixture>(path);
        fixture.Controls[policyAddress.Key] = fixture.Controls[policyAddress.Key] with { Value = ControlValues.From(new { dep = "NOTSET", cfg = "OFF", other = "OFF", @override = false }) };
        OperationFiles.Write(path, fixture); Apply("cfg-owner");
        check(store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("other").GetString() == "OFF", "Policy restore preserves an external change to an unowned field");
        var fieldPlan = new ControlPlan([policyOriginal], [new(policyOriginal, ControlValues.From(new { dep = "ON", cfg = "NOTSET", other = "ON", @override = false }), ["dep"])], []);
        var policyStore = new ProbeControls(policyOriginal);
        policyStore.Values[policyAddress.Key] = policyOriginal with { Value = ControlValues.From(new { dep = "ON", cfg = "NOTSET", other = "OFF", @override = false }) };
        ControlExecution.Rollback(fieldPlan, 1, policyStore);
        check(policyStore.Read(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && policyStore.Read(policyAddress).Value.GetProperty("other").GetString() == "OFF", "Interrupted policy recovery restores owned fields and retains independent edits");
        var beforeRunning = new TweakControlRead(running, running.Key, "binary", ControlValues.From(true));
        var beforeStartup = new TweakControlRead(startup, startup.Key, "binary", ControlValues.From(2));
        var plan = new ControlPlan([beforeRunning, beforeStartup], [new(beforeRunning, ControlValues.From(false)), new(beforeStartup, ControlValues.From(4))], []);
        var native = new ProbeControls(beforeRunning, beforeStartup) { FailWrite = 2 }; var attempted = 0;
        reject(() => ControlExecution.Apply(plan, native, count => attempted = count), "A native failure interrupts a compound operation");
        ControlExecution.Rollback(plan, attempted, native);
        check(native.Read(running).Same(beforeRunning) && native.Read(startup).Same(beforeStartup), "Partial native failure restores earlier writes and preserves the failed field");
        native = new(beforeRunning, beforeStartup); attempted = 0;
        ControlExecution.Apply(plan, native, count => attempted = count);
        check(attempted == 2 && native.WriteOrder.SequenceEqual(new[] { running.Key, startup.Key }), "The journal records intent before each ordered native write");
        ControlExecution.Rollback(plan, attempted, native);
        check(native.WriteOrder.TakeLast(2).SequenceEqual(new[] { startup.Key, running.Key }), "Recovery restores startup before restarting a stopped service");
        native = new(beforeRunning, beforeStartup) { CorruptWrite = true }; attempted = 0;
        var detected = false;
        try { ControlExecution.Apply(plan, native, count => attempted = count); } catch (InvalidOperationException) { detected = true; }
        check(detected, "A deliberately wrong successful native write fails independent readback");
        native = new(beforeRunning, beforeStartup); ControlExecution.Apply(plan, native, _ => { });
        native.Values[startup.Key] = beforeStartup with { Value = ControlValues.From(3) };
        detected = false;
        try { ControlExecution.Rollback(plan, 2, native); } catch (InvalidOperationException) { detected = true; }
        check(detected && native.Read(startup).Value.GetInt32() == 3 && native.Read(running).Same(beforeRunning), "Recovery preserves an external edit and continues independent restoration");
        var featureAddress = new ControlAddress("windows-features", "system", "features");
        var featureRead = new TweakControlRead(featureAddress, featureAddress.Key, "features", ControlValues.From(new Dictionary<string, string>
        {
            ["Microsoft-Hyper-V-All"] = "Disabled", ["Microsoft-Hyper-V"] = "Disabled", ["Microsoft-Hyper-V-Services"] = "DisabledWithPayloadRemoved", ["Unrelated"] = "Enabled",
        }), Parents: new() { ["Microsoft-Hyper-V-All"] = [], ["Microsoft-Hyper-V"] = ["Microsoft-Hyper-V-All"], ["Microsoft-Hyper-V-Services"] = ["Microsoft-Hyper-V"] });
        var featureSelection = featureRead.Expand(ControlValues.From(new Dictionary<string, string> { ["Microsoft-Hyper-V-All"] = "Enabled" }));
        check(featureSelection.EnumerateObject().Count() == 3 && featureSelection.GetProperty("Microsoft-Hyper-V-Services").GetString() == "Enabled" && !featureSelection.TryGetProperty("Unrelated", out _),
            "Feature review expands the selected family and dependencies without claiming unrelated features");
        var featureDisabled = featureRead.Expand(ControlValues.From(new Dictionary<string, string> { ["Microsoft-Hyper-V-All"] = "Disabled" }));
        check(featureDisabled.GetProperty("Microsoft-Hyper-V-Services").GetString() == "DisabledWithPayloadRemoved", "Disabling an already removed feature preserves its distinct payload state");
        reject(() => (featureRead with { RestartPending = true }).Expand(featureSelection), "Pending Windows servicing blocks a new feature edit");
        var pendingStore = new ProbeControls(featureRead with { RestartPending = true });
        detected = false;
        try { ControlExecution.Rollback(new([featureRead], [new(featureRead, featureRead.Value)], []), 1, pendingStore); } catch (InvalidOperationException) { detected = true; }
        check(detected, "Matching target values do not close recovery while a feature is still pending restart");
        var groupAddress = new ControlAddress("device-power", "non-network", "enabled");
        var groupBefore = new TweakControlRead(groupAddress, groupAddress.Key, "device-one|device-two", ControlValues.From(new { one = false, two = false }));
        var groupPlan = new ControlPlan([groupBefore], [new(groupBefore, groupBefore.Expand(ControlValues.From(true)))], []);
        native = new(groupBefore);
        native.Values[groupAddress.Key] = groupBefore with { Value = ControlValues.From(new { one = true, two = false }) };
        ControlExecution.Rollback(groupPlan, 1, native);
        check(native.Read(groupAddress).Same(groupBefore), "Partial device-group changes restore each captured device value");
        native.Values[groupAddress.Key] = groupBefore with { Value = ControlValues.From(new { one = true }) };
        detected = false;
        try { ControlExecution.Rollback(groupPlan, 1, native); } catch (InvalidOperationException) { detected = true; }
        check(detected, "A missing device value cannot count as a known partial operation");
        native = new(beforeRunning, beforeStartup); attempted = 0;
        reject(() => ControlExecution.Apply(plan, native, _ => throw new IOException("Controlled journal write failure")), "A journal persistence failure prevents a native mutation");
        check(native.WriteOrder.Count == 0, "No native writes occur before durable intent can be saved");
    }
    sealed class ProbeControls(params TweakControlRead[] initial) : IControlStore
    {
        public Dictionary<string, TweakControlRead> Values { get; } = initial.ToDictionary(item => item.Address.Key);
        public List<string> WriteOrder { get; } = [];
        public int FailWrite { get; set; }
        public bool CorruptWrite { get; set; }
        private int _attempts;
        public TweakControlRead Read(ControlAddress address) => Values[address.Key];
        public void Write(TweakControlRead before, JsonElement after)
        {
            if (++_attempts == FailWrite) throw new IOException("Controlled native failure");
            WriteOrder.Add(before.Address.Key);
            Values[before.Address.Key] = before with { Value = CorruptWrite ? before.Value : after };
        }
    }
}
