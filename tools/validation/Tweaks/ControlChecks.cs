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
        string? controlConflict = null; try { engine.Preview("conflict", [new("manual", "set")]); } catch (InvalidDataException error) { controlConflict = error.Message; }
        check(controlConflict == "Your \"two\" profile already sets manual to a different choice. Pick the same choice, or restore that profile first.", "A Windows control conflict with another profile names that profile and the setting");
        Apply("two");
        check(store.ReadControl(startup).Value.GetInt32() == 2 && store.ReadState()!.Controls!.Length == 0, "Last native owner restores the actual original startup value");
        void SetStartup(uint value, string binding = "fixture-service-binary")
        {
            var current = OperationFiles.Read<TweakFixture>(path);
            current.Controls[startup.Key] = current.Controls[startup.Key] with { Value = ControlValues.From(value), Binding = binding }; OperationFiles.Write(path, current);
        }
        Apply("reset-by-windows", new TweakSelection("disabled", "set")); SetStartup(2);
        writes = OperationFiles.Read<TweakFixture>(path).Writes;
        var resetPlan = engine.Preview("reset-by-windows", []);
        check(resetPlan.Controls!.Changes.Length == 0 && resetPlan.LeftAsChanged.Length == 0, "Restore treats a service Windows put back to its original startup as already restored");
        Apply("reset-by-windows");
        check(store.ReadControl(startup).Value.GetInt32() == 2 && store.ReadState()!.Controls!.Length == 0 && OperationFiles.Read<TweakFixture>(path).Writes == writes, "Restoring a service Windows already reset writes nothing and releases it");
        Apply("changed-elsewhere", new TweakSelection("disabled", "set")); SetStartup(3);
        var reassert = engine.Preview("changed-elsewhere", [new("disabled", "set")]);
        check(reassert.Controls!.Changes.Length == 1 && reassert.LeftAsChanged.Length == 0, "Re-applying a service choice Windows changed shows the write in the review");
        var elsewherePlan = engine.Preview("changed-elsewhere", []);
        check(elsewherePlan.Controls!.Changes.Length == 0 && elsewherePlan.LeftAsChanged.SequenceEqual(new[] { "disabled" }), "Restore reports a service changed outside Roo Industries instead of overwriting it");
        Apply("changed-elsewhere");
        check(store.ReadControl(startup).Value.GetInt32() == 3 && store.ReadState()!.Controls!.Length == 0, "Restore keeps the outside service value and releases the profile");
        SetStartup(2); Apply("flipped-released", new TweakSelection("disabled", "set")); SetStartup(3);
        var flippedPlan = engine.Preview("flipped-released", []); SetStartup(2);
        check(flippedPlan.Controls!.Changes.Length == 0 && flippedPlan.Controls.Released?.Select(item => item.Held.Original.Id).SequenceEqual(new[] { store.ReadControl(startup).Id }) == true, "Planning records a service it releases without writing");
        store.Commit(flippedPlan, "flipped-released");
        check(store.ReadControl(startup).Value.GetInt32() == 2 && store.ReadState()!.Controls!.Length == 0 && store.ReadState()!.Profiles.Length == 0, "An undo commit finishes when Windows changes a service it releases without writing");
        Apply("retaken", new TweakSelection("disabled", "set")); SetStartup(3);
        var retakenPlan = engine.Preview("retaken", []); SetStartup(4);
        reject(() => store.Commit(retakenPlan, "retaken"), "An undo commit refuses a released service that went back to the tweaked value");
        SetStartup(3); Apply("retaken");
        check(store.ReadControl(startup).Value.GetInt32() == 3 && store.ReadState()!.Controls!.Length == 0, "The undo reviewed again after the refusal releases the service");
        void SetRunning(bool value) { var current = OperationFiles.Read<TweakFixture>(path); current.Controls[running.Key] = current.Controls[running.Key] with { Value = ControlValues.From(value) }; OperationFiles.Write(path, current); }
        SetRunning(true); Apply("run-flip", new TweakSelection("stop", "set")); SetRunning(true);
        var runPlan = engine.Preview("run-flip", []); SetRunning(false);
        store.Commit(runPlan, "run-flip");
        check(store.ReadState()!.Profiles.All(profile => profile.Id != "run-flip"), "An undo commit finishes when a released service stops again on its own");
        SetRunning(true);
        SetStartup(2); Apply("gone", new TweakSelection("disabled", "set")); SetStartup(3);
        var gonePlan = engine.Preview("gone", []);
        var goneFixture = OperationFiles.Read<TweakFixture>(path); var goneService = goneFixture.Controls[startup.Key]; goneFixture.Controls.Remove(startup.Key); OperationFiles.Write(path, goneFixture);
        store.Commit(gonePlan, "gone");
        check(store.ReadState()!.Profiles.All(profile => profile.Id != "gone"), "An undo commit finishes when a released service disappeared during the undo");
        goneFixture = OperationFiles.Read<TweakFixture>(path); goneFixture.Controls[startup.Key] = goneService with { Value = ControlValues.From(2) }; OperationFiles.Write(path, goneFixture);
        var doh = new ControlAddress("dns-over-https", "fixture", "entry");
        var dohFixture = OperationFiles.Read<TweakFixture>(path);
        dohFixture.Controls[doh.Key] = new(doh, doh.Key, "doh-entry", ControlValues.From(new Dictionary<string, object> { ["template"] = "t", ["autoUpgrade"] = false, ["allowFallback"] = false })); OperationFiles.Write(path, dohFixture);
        var dohEngine = new TweakEngine(new TweakCatalog(1, "doh", [Setting("doh", doh, new Dictionary<string, object> { ["template"] = "t", ["autoUpgrade"] = true, ["allowFallback"] = false })], []), store);
        var dohApply = dohEngine.Preview("doh", [new("doh", "set")]); store.Commit(dohApply, "doh");
        dohFixture = OperationFiles.Read<TweakFixture>(path); dohFixture.Controls[doh.Key] = dohFixture.Controls[doh.Key] with { Value = ControlValues.From(new Dictionary<string, object> { ["template"] = "t", ["autoUpgrade"] = true, ["allowFallback"] = true }) }; OperationFiles.Write(path, dohFixture);
        var dohUndo = dohEngine.Preview("doh", []);
        dohFixture = OperationFiles.Read<TweakFixture>(path); var dohDrifted = dohFixture.Controls[doh.Key]; dohFixture.Controls[doh.Key] = dohDrifted with { Value = ControlValues.From(new Dictionary<string, object> { ["template"] = "t", ["autoUpgrade"] = true, ["allowFallback"] = false }) }; OperationFiles.Write(path, dohFixture);
        reject(() => store.Commit(dohUndo, "doh-retake"), "An undo commit refuses when a whole-value setting went back to the tweaked value");
        dohFixture = OperationFiles.Read<TweakFixture>(path); dohFixture.Controls[doh.Key] = dohDrifted; OperationFiles.Write(path, dohFixture);
        store.Commit(dohUndo, "doh-undo");
        check(store.ReadState()!.Profiles.All(profile => profile.Id != "doh") && store.ReadState()!.Controls!.Length == 0, "Undo of a whole-value setting finishes when Windows changed a field the tweak did not set");
        dohFixture = OperationFiles.Read<TweakFixture>(path); dohFixture.Controls.Remove(doh.Key); OperationFiles.Write(path, dohFixture);
        SetStartup(2); Apply("held-a", new TweakSelection("disabled", "set")); Apply("held-b", new TweakSelection("disabled", "set"));
        var heldPlan = engine.Preview("held-a", []); SetStartup(3);
        reject(() => store.Commit(heldPlan, "held-a"), "An undo commit still refuses when a service another profile keeps changed");
        SetStartup(4); Apply("held-a"); Apply("held-b");
        check(store.ReadControl(startup).Value.GetInt32() == 2 && store.ReadState()!.Controls!.Length == 0, "Both owners restore the original after the refused undo");
        var memory = new ControlAddress("memory", "system", "compression"); var sysMain = new ControlAddress("service", "SysMain", "startup");
        var memoryFixture = OperationFiles.Read<TweakFixture>(path);
        memoryFixture.Controls[memory.Key] = new(memory, memory.Key, "memory-manager", ControlValues.From(false));
        memoryFixture.Controls[sysMain.Key] = new(sysMain, sysMain.Key, "sysmain-binary", ControlValues.From(2)); OperationFiles.Write(path, memoryFixture);
        var compressPlan = new TweakEngine(new TweakCatalog(1, "memory", [Setting("compress", memory, true)], []), store).Preview("compress", [new("compress", "set")]);
        memoryFixture = OperationFiles.Read<TweakFixture>(path); memoryFixture.Controls[sysMain.Key] = memoryFixture.Controls[sysMain.Key] with { Value = ControlValues.From(4) }; OperationFiles.Write(path, memoryFixture);
        reject(() => store.Commit(compressPlan, "compress"), "Turning on memory compression still refuses when SysMain was disabled after the review");
        var memoryEngine = new TweakEngine(new TweakCatalog(1, "memory", [Setting("compress", memory, true), Setting("compress-off", memory, false), Setting("sysmain-auto", sysMain, 2), Setting("sysmain-off", sysMain, 4)], []), store);
        void SetSysMain(uint value) { var current = OperationFiles.Read<TweakFixture>(path); current.Controls[sysMain.Key] = current.Controls[sysMain.Key] with { Value = ControlValues.From(value) }; OperationFiles.Write(path, current); }
        TweakState MemoryApply(string profile, params TweakSelection[] choices) { var plan = memoryEngine.Preview(profile, choices); var review = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(review, plan); return memoryEngine.Apply(review, OperationFiles.HashFile(review)).State; }
        SetSysMain(2); MemoryApply("memory", new TweakSelection("sysmain-auto", "set"));
        var swapPlan = memoryEngine.Preview("memory", [new("compress", "set")]);
        check(swapPlan.Controls!.SysMainGuard is not null, "A SysMain choice given up while turning on memory compression stays guarded at commit");
        SetSysMain(4);
        reject(() => store.Commit(swapPlan, "swap"), "Swapping a SysMain choice for memory compression refuses when SysMain was disabled during the undo");
        SetSysMain(3); store.Commit(swapPlan, "swap");
        check(store.ReadControl(memory).Value.GetBoolean(), "Swapping still finishes when SysMain moved to another enabled startup during the undo");
        SetSysMain(2); MemoryApply("memory");
        SetSysMain(4); MemoryApply("b", new TweakSelection("sysmain-auto", "set")); MemoryApply("a", new TweakSelection("compress", "set"));
        reject(() => memoryEngine.Preview("b", []), "Undoing a SysMain choice back to disabled is refused while another profile keeps memory compression on");
        MemoryApply("a"); MemoryApply("b");
        SetSysMain(2); MemoryApply("b", new TweakSelection("sysmain-auto", "set")); MemoryApply("a", new TweakSelection("compress", "set")); SetSysMain(4);
        MemoryApply("b");
        check(store.ReadState()!.Profiles.All(profile => profile.Id != "b"), "Undoing a SysMain choice that writes nothing is not blocked by a SysMain change made outside the app");
        SetSysMain(2); MemoryApply("a");
        void SetMemory(bool value) { var current = OperationFiles.Read<TweakFixture>(path); current.Controls[memory.Key] = current.Controls[memory.Key] with { Value = ControlValues.From(value) }; OperationFiles.Write(path, current); }
        SetMemory(true); MemoryApply("x", new TweakSelection("compress-off", "set")); MemoryApply("y", new TweakSelection("sysmain-off", "set"));
        reject(() => memoryEngine.Preview("x", []), "Undoing a compression-off choice is refused at review while SysMain is disabled");
        MemoryApply("y"); MemoryApply("x");
        check(store.ReadControl(memory).Value.GetBoolean() && store.ReadControl(sysMain).Value.GetUInt32() == 2 && store.ReadState()!.Controls!.Length == 0, "Undoing SysMain first then compression-off restores both");
        SetMemory(false); MemoryApply("owner", new TweakSelection("sysmain-auto", "set")); SetSysMain(4);
        reject(() => memoryEngine.Preview("c", [new("compress", "set")]), "Turning on compression is refused at review when SysMain is disabled even if a profile wants it enabled");
        SetSysMain(2);
        var guardPlan = memoryEngine.Preview("c", [new("compress", "set")]); SetSysMain(3);
        store.Commit(guardPlan, "guard");
        check(store.ReadControl(memory).Value.GetBoolean(), "Turning on compression finishes when another profile's SysMain moved to another enabled startup during the change");
        SetSysMain(2); MemoryApply("c"); MemoryApply("owner");
        SetMemory(true); MemoryApply("y", new TweakSelection("sysmain-off", "set"));
        reject(() => memoryEngine.Preview("c", [new("compress", "set")]), "Choosing memory compression that is already on is refused while another profile disables SysMain");
        MemoryApply("y"); SetMemory(false);
        check(store.ReadState()!.Controls!.Length == 0 && store.ReadControl(sysMain).Value.GetUInt32() == 2, "The already-on compression check leaves nothing owned");
        SetMemory(false); MemoryApply("p", new TweakSelection("compress", "set")); SetSysMain(4);
        MemoryApply("p", new TweakSelection("compress", "set"));
        check(store.ReadState()!.Profiles.Any(profile => profile.Id == "p"), "Re-applying an unchanged compression choice is not refused by a SysMain change made outside the app");
        SetSysMain(2); MemoryApply("p"); SetMemory(false);
        SetSysMain(4); MemoryApply("memory", new TweakSelection("sysmain-auto", "set"));
        reject(() => memoryEngine.Preview("memory", [new("compress", "set")]), "Memory compression is refused when the same review puts SysMain back to disabled");
        MemoryApply("memory");
        check(store.ReadControl(sysMain).Value.GetUInt32() == 4 && store.ReadState()!.Controls!.Length == 0, "The SysMain checks leave no memory ownership behind");
        memoryFixture = OperationFiles.Read<TweakFixture>(path); memoryFixture.Controls.Remove(memory.Key); memoryFixture.Controls.Remove(sysMain.Key); OperationFiles.Write(path, memoryFixture);
        SetStartup(2); Apply("shared-one", new TweakSelection("disabled", "set")); Apply("shared-two", new TweakSelection("disabled", "set")); SetStartup(3);
        Apply("shared-one"); Apply("shared-two");
        check(store.ReadControl(startup).Value.GetInt32() == 3 && store.ReadState()!.Controls!.Length == 0 && store.ReadState()!.Profiles.Length == 0, "Two owners of a service Windows changed can both be restored");
        SetStartup(2); Apply("rebound", new TweakSelection("disabled", "set")); SetStartup(4, "replacement-service-binary");
        reject(() => engine.Preview("rebound", [new("manual", "set")]), "A replaced service binary blocks writing a new choice to it");
        var rebound = engine.Preview("rebound", []);
        check(rebound.Controls!.Changes.Length == 1 && rebound.LeftAsChanged.Length == 0, "Restore still undoes an owned value on a service whose binary was replaced");
        Apply("rebound");
        check(store.ReadControl(startup).Value.GetInt32() == 2 && store.ReadState()!.Controls!.Length == 0, "Restoring a replaced service returns its original startup and leaves no ownership");
        SetStartup(2);
        Apply("removed", new TweakSelection("disabled", "set"));
        var removedFixture = OperationFiles.Read<TweakFixture>(path); var removedService = removedFixture.Controls[startup.Key]; removedFixture.Controls.Remove(startup.Key); OperationFiles.Write(path, removedFixture);
        var removedPlan = engine.Preview("removed", []);
        check(removedPlan.Controls!.Changes.Length == 0 && removedPlan.LeftAsChanged.SequenceEqual(new[] { "disabled" }), "Undo releases and reports a service Windows removed instead of getting stuck");
        Apply("removed");
        check(store.ReadState()!.Controls!.Length == 0 && store.ReadState()!.Profiles.Length == 0, "Undoing a removed service leaves no ownership behind");
        removedFixture = OperationFiles.Read<TweakFixture>(path); removedFixture.Controls[startup.Key] = removedService with { Value = ControlValues.From(2) }; OperationFiles.Write(path, removedFixture);
        Apply("share-one", new TweakSelection("disabled", "set")); Apply("share-two", new TweakSelection("disabled", "set"));
        removedFixture = OperationFiles.Read<TweakFixture>(path); removedFixture.Controls.Remove(startup.Key); OperationFiles.Write(path, removedFixture);
        check(engine.Preview("share-one", []).LeftAsChanged.SequenceEqual(new[] { "disabled" }), "Two profiles sharing a removed service do not block each other's undo");
        Apply("share-one");
        check(store.ReadState()!.Controls!.Length == 1 && store.ReadState()!.Profiles.Single().Id == "share-two", "Undoing one sharer of a removed service keeps the other's ownership intact");
        Apply("share-two");
        check(store.ReadState()!.Controls!.Length == 0 && store.ReadState()!.Profiles.Length == 0, "The last sharer of a removed service can also undo");
        removedFixture = OperationFiles.Read<TweakFixture>(path); removedFixture.Controls[startup.Key] = removedService with { Value = ControlValues.From(2) }; OperationFiles.Write(path, removedFixture);
        Apply("replaced", new TweakSelection("disabled", "set"));
        removedFixture = OperationFiles.Read<TweakFixture>(path); removedFixture.Controls[startup.Key] = removedFixture.Controls[startup.Key] with { Identity = "replaced-resource" }; OperationFiles.Write(path, removedFixture);
        var replacedPlan = engine.Preview("replaced", []);
        check(replacedPlan.Controls!.Changes.Length == 0 && replacedPlan.LeftAsChanged.SequenceEqual(new[] { "disabled" }), "Undo releases a control whose underlying resource was replaced, such as a file Windows Update swapped");
        Apply("replaced");
        check(store.ReadState()!.Controls!.Length == 0, "Undoing a replaced resource leaves no ownership behind");
        removedFixture = OperationFiles.Read<TweakFixture>(path); removedFixture.Controls[startup.Key] = removedService with { Value = ControlValues.From(2) }; OperationFiles.Write(path, removedFixture);
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
        Apply("pair", new TweakSelection("dep", "set"), new TweakSelection("cfg", "set"));
        fixture = OperationFiles.Read<TweakFixture>(path);
        fixture.Controls[policyAddress.Key] = fixture.Controls[policyAddress.Key] with { Value = ControlValues.From(new { dep = "ON", cfg = "ON", other = "OFF", @override = false }) };
        OperationFiles.Write(path, fixture);
        var pairPlan = engine.Preview("pair", []);
        check(pairPlan.LeftAsChanged.SequenceEqual(new[] { "cfg" }), "Only the policy field changed elsewhere is reported");
        Apply("pair");
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "ON" && store.ReadState()!.Controls!.Length == 0,
            "Policy restore reverts the intact field and leaves the field changed elsewhere");
        Apply("x", new TweakSelection("dep", "set")); Apply("y", new TweakSelection("dep", "set"), new TweakSelection("cfg", "set"));
        fixture = OperationFiles.Read<TweakFixture>(path);
        fixture.Controls[policyAddress.Key] = fixture.Controls[policyAddress.Key] with { Value = ControlValues.From(new { dep = "ON", cfg = "NOTSET", other = "OFF", @override = false }) };
        OperationFiles.Write(path, fixture);
        Apply("x");
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "ON" && store.ReadState()!.Profiles.Single().Id == "y", "Releasing a policy field another profile still owns keeps it applied");
        check(engine.Preview("y", []).LeftAsChanged.SequenceEqual(new[] { "cfg" }), "Control ownership stays readable after a shared policy field is released");
        Apply("y");
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "NOTSET" && store.ReadState()!.Controls!.Length == 0, "The last policy owner restores its intact field only");
        Apply("a", new TweakSelection("dep", "set")); Apply("b", new TweakSelection("cfg", "set"));
        fixture = OperationFiles.Read<TweakFixture>(path);
        var policyNow = fixture.Controls[policyAddress.Key].Value.EnumerateObject().ToDictionary(property => property.Name, property => (object)property.Value);
        policyNow["dep"] = "NOTSET"; policyNow["other"] = "ON";
        fixture.Controls[policyAddress.Key] = fixture.Controls[policyAddress.Key] with { Value = ControlValues.From(policyNow) }; OperationFiles.Write(path, fixture);
        Apply("a"); Apply("b");
        check(store.ReadControl(policyAddress).Value.GetProperty("other").GetString() == "ON" && store.ReadState()!.Controls!.Length == 0, "A later undo keeps an outside change to an unowned policy field made while another owner was released");
        Apply("gone-field", new TweakSelection("cfg", "set"));
        fixture = OperationFiles.Read<TweakFixture>(path);
        var withoutCfg = fixture.Controls[policyAddress.Key].Value.EnumerateObject().Where(property => property.Name != "cfg").ToDictionary(property => property.Name, property => (object)property.Value);
        var fullPolicy = fixture.Controls[policyAddress.Key].Value;
        fixture.Controls[policyAddress.Key] = fixture.Controls[policyAddress.Key] with { Value = ControlValues.From(withoutCfg) }; OperationFiles.Write(path, fixture);
        check(engine.Preview("gone-field", []).LeftAsChanged.SequenceEqual(new[] { "cfg" }), "Undo releases a policy field Windows removed instead of getting stuck");
        Apply("gone-field");
        check(store.ReadState()!.Controls!.Length == 0, "Undoing a removed policy field leaves no ownership behind");
        fixture = OperationFiles.Read<TweakFixture>(path); fixture.Controls[policyAddress.Key] = fixture.Controls[policyAddress.Key] with { Value = fullPolicy }; OperationFiles.Write(path, fixture);
        void SetPolicy(string field, string value)
        {
            var current = OperationFiles.Read<TweakFixture>(path);
            var fields = current.Controls[policyAddress.Key].Value.EnumerateObject().ToDictionary(property => property.Name, property => (object)property.Value);
            fields[field] = value;
            current.Controls[policyAddress.Key] = current.Controls[policyAddress.Key] with { Value = ControlValues.From(fields) }; OperationFiles.Write(path, current);
        }
        SetPolicy("dep", "NOTSET");
        Apply("e", new TweakSelection("dep", "set")); SetPolicy("dep", "OFF");
        Apply("e", new TweakSelection("cfg", "set")); SetPolicy("dep", "NOTSET");
        Apply("e");
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && store.ReadState()!.Controls!.Length == 0, "Undo does not write back a stale value for a field that drifted and later returned to its original");
        SetPolicy("dep", "NOTSET"); Apply("k", new TweakSelection("dep", "set")); SetPolicy("dep", "OFF");
        Apply("n", new TweakSelection("cfg", "set")); SetPolicy("dep", "ON"); Apply("k");
        check(store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET", "Undo returns a kept field to its true original, not an admin's temporary value");
        Apply("n");
        check(store.ReadState()!.Controls!.Length == 0, "Both policy profiles undo after the temporary admin change");
        var multiCatalog = new TweakCatalog(1, "multi-field", [new("multi", "multi", "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(policyAddress, ControlValues.From(new Dictionary<string, object> { ["dep"] = "ON", ["cfg"] = "OFF", ["other"] = "OFF" }), true)])], [new("Roo Industries", "fixture", "one choice, many fields")])], []);
        var policyEngine = engine; engine = new(multiCatalog, store);
        SetPolicy("dep", "NOTSET"); SetPolicy("cfg", "NOTSET"); SetPolicy("other", "ON");
        Apply("devices", new TweakSelection("multi", "set"));
        SetPolicy("dep", "ON"); SetPolicy("other", "ON");
        var partial = engine.Preview("devices", []);
        check(partial.LeftAsChanged.Length == 0, "A field Windows put back to its original is not reported");
        Apply("devices");
        check(store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("other").GetString() == "ON" && store.ReadState()!.Controls!.Length == 0,
            "Undo still restores every field of a multi-field choice that Windows did not touch, like device power after a reboot");
        Apply("devices", new TweakSelection("multi", "set"));
        SetPolicy("other", "NOTSET");
        check(engine.Preview("devices", []).LeftAsChanged.SequenceEqual(new[] { "multi" }), "A multi-field choice with one field changed to a new value is reported");
        Apply("devices");
        check(store.ReadControl(policyAddress).Value.GetProperty("cfg").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("dep").GetString() == "NOTSET" && store.ReadControl(policyAddress).Value.GetProperty("other").GetString() == "NOTSET" && store.ReadState()!.Controls!.Length == 0,
            "Undo restores the untouched fields and keeps the one changed elsewhere");
        SetPolicy("other", "ON"); Apply("patch-retake", new TweakSelection("multi", "set"));
        SetPolicy("dep", "NOTSET"); SetPolicy("cfg", "NOTSET"); SetPolicy("other", "ON");
        var patchPlan = engine.Preview("patch-retake", []); SetPolicy("cfg", "OFF");
        reject(() => store.Commit(patchPlan, "patch-retake"), "An undo commit refuses when one released policy field went back to the tweaked value");
        SetPolicy("cfg", "NOTSET"); Apply("patch-retake");
        check(store.ReadState()!.Controls!.Length == 0, "The policy undo reviewed again after the refusal finishes");
        SetPolicy("other", "NOTSET");
        engine = policyEngine;
        var devicePower = new ControlAddress("device-power", "non-network", "allow-off");
        var deviceCatalog = new TweakCatalog(1, "device-power", [new("devices-off", "devices-off", "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(devicePower, ControlValues.From(false))])], [new("Roo Industries", "fixture", "device power map")])], []);
        var devicesFixture = OperationFiles.Read<TweakFixture>(path);
        devicesFixture.Controls[devicePower.Key] = new TweakControlRead(devicePower, devicePower.Key, "device-map", ControlValues.From(new Dictionary<string, object> { ["hid"] = true, ["usb"] = true, ["usb4"] = true, ["wifi"] = false }));
        OperationFiles.Write(path, devicesFixture);
        var deviceEngine = new TweakEngine(deviceCatalog, store); var savedEngine = engine; engine = deviceEngine;
        Apply("power", new TweakSelection("devices-off", "set"));
        devicesFixture = OperationFiles.Read<TweakFixture>(path);
        devicesFixture.Controls[devicePower.Key] = devicesFixture.Controls[devicePower.Key] with { Value = ControlValues.From(new Dictionary<string, object> { ["hid"] = false, ["usb"] = false, ["usb4"] = true, ["wifi"] = false }) };
        OperationFiles.Write(path, devicesFixture);
        var devicePlan = engine.Preview("power", []);
        Apply("power");
        var devices = store.ReadControl(devicePower).Value;
        check(devicePlan.LeftAsChanged.Length == 0 && devices.GetProperty("hid").GetBoolean() && devices.GetProperty("usb").GetBoolean() && devices.GetProperty("usb4").GetBoolean() && !devices.GetProperty("wifi").GetBoolean() && store.ReadState()!.Controls!.Length == 0,
            "Undo after a reboot reset one device still restores every other device's power setting");
        Apply("power", new TweakSelection("devices-off", "set"));
        Apply("power2", new TweakSelection("devices-off", "set"));
        devicesFixture = OperationFiles.Read<TweakFixture>(path);
        devicesFixture.Controls[devicePower.Key] = devicesFixture.Controls[devicePower.Key] with { Value = ControlValues.From(new Dictionary<string, object> { ["hid"] = false, ["usb"] = false, ["usb4"] = true, ["wifi"] = false }) };
        OperationFiles.Write(path, devicesFixture);
        Apply("power");
        devices = store.ReadControl(devicePower).Value;
        check(!devices.GetProperty("hid").GetBoolean() && !devices.GetProperty("usb").GetBoolean() && store.ReadState()!.Controls!.Length == 1,
            "Undoing one of two profiles after a reboot reset one device keeps the other profile's device power settings");
        var secondPlan = engine.Preview("power2", []);
        Apply("power2");
        devices = store.ReadControl(devicePower).Value;
        check(secondPlan.LeftAsChanged.Length == 0 && devices.GetProperty("hid").GetBoolean() && devices.GetProperty("usb").GetBoolean() && devices.GetProperty("usb4").GetBoolean() && !devices.GetProperty("wifi").GetBoolean() && store.ReadState()!.Controls!.Length == 0,
            "Undoing the last profile then restores every device");
        Apply("power", new TweakSelection("devices-off", "set"));
        devicesFixture = OperationFiles.Read<TweakFixture>(path);
        devicesFixture.Controls[devicePower.Key] = devicesFixture.Controls[devicePower.Key] with { Value = ControlValues.From(new Dictionary<string, object> { ["hid"] = false, ["usb"] = false, ["wifi"] = false }) };
        OperationFiles.Write(path, devicesFixture);
        var unplugged = engine.Preview("power", []);
        Apply("power");
        devices = store.ReadControl(devicePower).Value;
        check(unplugged.LeftAsChanged.SequenceEqual(new[] { "devices-off" }) && devices.GetProperty("hid").GetBoolean() && devices.GetProperty("usb").GetBoolean() && store.ReadState()!.Controls!.Length == 0,
            "Undo after a device was unplugged restores the others and reports the missing one");
        void SetDevices(Dictionary<string, object> map) { var current = OperationFiles.Read<TweakFixture>(path); current.Controls[devicePower.Key] = current.Controls[devicePower.Key] with { Value = ControlValues.From(map) }; OperationFiles.Write(path, current); }
        SetDevices(new() { ["hid"] = true, ["usb"] = true, ["usb4"] = true, ["wifi"] = false });
        Apply("power", new TweakSelection("devices-off", "set"));
        SetDevices(new() { ["hid"] = true, ["usb"] = true, ["usb4"] = true, ["wifi"] = false });
        var retakePlan = engine.Preview("power", []);
        SetDevices(new() { ["hid"] = false, ["usb"] = true, ["usb4"] = true, ["wifi"] = false });
        reject(() => store.Commit(retakePlan, "power-retake"), "An undo commit refuses when one released device went back to the tweaked power setting");
        SetDevices(new() { ["hid"] = true, ["usb"] = true, ["usb4"] = true, ["wifi"] = false }); Apply("power");
        check(store.ReadState()!.Controls!.Length == 0, "The device undo reviewed again after the refusal finishes");
        engine = savedEngine;
        var mitigation = new ControlAddress("mitigations", "system", "policy");
        TweakDefinition Mitigation(string id, string field, string value) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("set", "Set", [], Controls: [new(mitigation, ControlValues.From(new Dictionary<string, object> { [field] = value }), true)])], [new("Roo Industries", "fixture", "mitigation fields")]);
        var mitigationCatalog = new TweakCatalog(1, "mitigation-drift", [Mitigation("dep", "Dep.Enable", "ON"), Mitigation("atl", "Dep.EmulateAtlThunks", "OFF"), Mitigation("bottom-up", "Aslr.BottomUp", "ON")], []);
        path = Path.Combine(root, "mitigation-drift.json"); store = FileTweakStore.Create(path);
        fixture = OperationFiles.Read<TweakFixture>(path);
        fixture.Controls.Add(mitigation.Key, new TweakControlRead(mitigation, mitigation.Key, "mitigation-registry", MitigationControl.Snapshot(null, null, null))); OperationFiles.Write(path, fixture);
        engine = new(mitigationCatalog, store);
        Apply("p2", new TweakSelection("dep", "set")); Apply("p1", new TweakSelection("atl", "set"), new TweakSelection("bottom-up", "set"));
        fixture = OperationFiles.Read<TweakFixture>(path);
        var mitigated = fixture.Controls[mitigation.Key].Value.EnumerateObject().ToDictionary(property => property.Name, property => (object)property.Value);
        mitigated["Aslr.BottomUp"] = "OFF";
        fixture.Controls[mitigation.Key] = fixture.Controls[mitigation.Key] with { Value = MitigationControl.Reconcile(ControlValues.From(mitigated)) }; OperationFiles.Write(path, fixture);
        var p1Undo = engine.Preview("p1", []);
        check(p1Undo.LeftAsChanged.SequenceEqual(new[] { "bottom-up" }), "Mitigation undo reports the field Windows Security changed");
        Apply("p1");
        check(store.ReadControl(mitigation).Value.GetProperty("Dep.Enable").GetString() == "ON" && store.ReadControl(mitigation).Value.GetProperty("Aslr.BottomUp").GetString() == "OFF" && store.ReadState()!.Profiles.Single().Id == "p2",
            "Undoing a mitigation sub-option keeps the parent setting another profile owns");
        var p2Undo = engine.Preview("p2", []);
        check(p2Undo.LeftAsChanged.Length == 0, "Mitigation ownership stays readable after a sub-option shares bits with a kept setting");
        Apply("p2");
        check(store.ReadControl(mitigation).Value.GetProperty("Dep.Enable").GetString() == "NOTSET" && store.ReadControl(mitigation).Value.GetProperty("Aslr.BottomUp").GetString() == "OFF" && store.ReadState()!.Controls!.Length == 0,
            "The last mitigation owner restores its setting and leaves the outside change");
        void SetMitigation(string field, string value)
        {
            var current = OperationFiles.Read<TweakFixture>(path);
            var fields = current.Controls[mitigation.Key].Value.EnumerateObject().ToDictionary(property => property.Name, property => (object)property.Value);
            fields[field] = value;
            current.Controls[mitigation.Key] = current.Controls[mitigation.Key] with { Value = MitigationControl.Reconcile(ControlValues.From(fields)) }; OperationFiles.Write(path, current);
        }
        string Mitigated(string field) => store.ReadControl(mitigation).Value.GetProperty(field).GetString()!;
        SetMitigation("Aslr.BottomUp", "NOTSET");
        Apply("edit", new TweakSelection("dep", "set"), new TweakSelection("bottom-up", "set"));
        SetMitigation("Aslr.BottomUp", "OFF");
        reject(() => engine.Preview("edit", [new("atl", "set"), new("bottom-up", "set")]), "Editing exploit protection choices after Windows Security changed one asks for undo first");
        Apply("edit");
        check(Mitigated("Dep.Enable") == "NOTSET" && Mitigated("Aslr.BottomUp") == "OFF" && store.ReadState()!.Controls!.Length == 0, "Undo after Windows Security changed exploit protection reverts the intact setting and keeps the changed one");
        Apply("dep-only", new TweakSelection("dep", "set"));
        SetMitigation("Dep.EmulateAtlThunks", "ON");
        var sibling = engine.Preview("dep-only", []);
        check(sibling.Controls!.Changes.Length == 0 && sibling.LeftAsChanged.SequenceEqual(new[] { "dep" }), "Undo does not flip a mitigation sub-option an admin changed in the same bits");
        Apply("dep-only");
        check(Mitigated("Dep.EmulateAtlThunks") == "ON" && Mitigated("Dep.Enable") == "ON" && store.ReadState()!.Controls!.Length == 0, "The admin's mitigation change stays after undo");
        SetMitigation("Dep.EmulateAtlThunks", "OFF"); SetMitigation("Dep.Enable", "NOTSET");
        Apply("p2", new TweakSelection("atl", "set")); Apply("p1", new TweakSelection("bottom-up", "set"));
        SetMitigation("Dep.Enable", "ON");
        Apply("p1");
        var later = engine.Preview("p2", []);
        check(later.Controls!.Changes.Length == 0, "A later undo still leaves a mitigation an admin changed while another owner was released");
        Apply("p2");
        check(Mitigated("Dep.Enable") == "ON" && store.ReadState()!.Controls!.Length == 0, "The admin's DEP change survives both undos");
        SetMitigation("Dep.Enable", "NOTSET");
        Apply("p2", new TweakSelection("atl", "set")); Apply("p1", new TweakSelection("bottom-up", "set"));
        SetMitigation("Dep.Enable", "ON");
        reject(() => engine.Preview("p1", [new("bottom-up", "set")]), "Applying exploit protection choices after Windows Security changed managed ones asks for undo first");
        reject(() => engine.Preview("p3", [new("dep", "set")]), "A new exploit protection choice on drifted bits asks for undo first");
        Apply("p2"); Apply("p1");
        check(Mitigated("Dep.Enable") == "ON" && store.ReadState()!.Controls!.Length == 0, "Undo still works after Windows Security changed managed exploit protection and keeps its change");
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
