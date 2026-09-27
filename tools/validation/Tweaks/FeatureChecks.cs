using System.Text.Json;
using RooIndustries.Optimizer;

static class FeatureChecks
{
    static readonly ControlAddress Features = new("windows-features", "system", "features");
    public static void Run(string root, TweakCatalog catalog, Action<bool, string> check)
    {
        var failures = new List<string>();
        void Scenario(string name, Action body)
        {
            try { body(); }
            catch (Exception error) { failures.Add(name + ": " + error.Message); Console.WriteLine("FAIL " + name + ": " + error.Message); }
        }
        string Refusal(Action operation)
        {
            try { operation(); } catch (Exception error) when (error is InvalidDataException or InvalidOperationException or IOException) { return error.Message; }
            return "";
        }
        JsonElement With(TweakControlRead before, string state) =>
            ControlValues.From(before.Value.EnumerateObject().ToDictionary(item => item.Name, item => item.Name == "HypervisorPlatform" ? state : item.Value.GetString()));
        ControlPlan Enable(TweakControlRead before) => new([before], [new(before, With(before, "Enabled"), ["HypervisorPlatform"])], []);

        Scenario("enable finishing with 3010 from DismCloseSession", () =>
        {
            var dism = new FakeDism { CloseAfterChange = 3010 }; var store = new FeatureStore(dism);
            var before = store.Read(Features);
            var pending = ControlExecution.Apply(Enable(before), store, _ => { });
            var after = store.Read(Features);
            check(pending && after.RestartPending && after.Value.GetProperty("HypervisorPlatform").GetString() == "Enabled", "A feature enable that DISM finishes with 3010 is applied with a restart pending");
        });
        Scenario("enable returning 3010 while DISM lists the target state", () =>
        {
            var dism = new FakeDism { ChangeResult = 3010, InfoShowsPending = false }; var store = new FeatureStore(dism);
            check(ControlExecution.Apply(Enable(store.Read(Features)), store, _ => { }), "A 3010 feature change is pending even when the DISM feature list shows only the target state");
        });
        Scenario("pending enable read by a later process", () =>
        {
            var dism = new FakeDism(); dism.Listed["HypervisorPlatform"] = 4; dism.Info["HypervisorPlatform"] = 5;
            var read = WindowsFeatures.Read(Features, dism);
            check(read.RestartPending && read.Value.GetProperty("HypervisorPlatform").GetString() == "Enabled", "A later read reports a pending enable from the feature's own state");
            dism = new FakeDism(); dism.Listed["HypervisorPlatform"] = 2; dism.Info["HypervisorPlatform"] = 1;
            read = WindowsFeatures.Read(Features, dism);
            check(read.RestartPending && read.Value.GetProperty("HypervisorPlatform").GetString() == "Disabled", "A later read reports a pending disable from the feature's own state");
            dism = new FakeDism { ReadCloseResult = 3010 };
            check(WindowsFeatures.Read(Features, dism).RestartPending, "A read that DISM closes with 3010 reports a pending restart");
            dism = new FakeDism { ReadCloseResult = unchecked((int)0x80070005) };
            check(Refusal(() => WindowsFeatures.Read(Features, dism)).Contains("0x80070005"), "Other DISM close errors still fail the read");
        });
        Scenario("disable returning 3010", () =>
        {
            var dism = new FakeDism { ChangeResult = 3010 }; dism.Listed["HypervisorPlatform"] = 4; var store = new FeatureStore(dism);
            var before = store.Read(Features);
            var pending = ControlExecution.Apply(new([before], [new(before, With(before, "Disabled"), ["HypervisorPlatform"])], []), store, _ => { });
            check(pending && store.Read(Features).Value.GetProperty("HypervisorPlatform").GetString() == "Disabled", "A feature disable that DISM finishes with 3010 is applied with a restart pending");
        });
        Scenario("rollback write returning 3010", () =>
        {
            var dism = new FakeDism(); var store = new FeatureStore(dism);
            var plan = Enable(store.Read(Features));
            check(!ControlExecution.Apply(plan, store, _ => { }), "A feature enable without a restart completes without a pending restart");
            dism.ChangeResult = 3010;
            var message = Refusal(() => ControlExecution.Rollback(plan, 1, store));
            check(message.Contains("Restart Windows to finish feature recovery") && dism.Info["HypervisorPlatform"] == 1, "A rollback that DISM finishes with 3010 reports the restart instead of closing recovery");
        });
        Scenario("later control failure after a pending enable", () =>
        {
            var dism = new FakeDism { ChangeResult = 3010 };
            var service = new ControlAddress("service", "FixtureService", "running");
            var store = new FeatureStore(dism, new TweakControlRead(service, service.Key, "fixture-service-binary", ControlValues.From(false))) { Fail = service.Key };
            var feature = store.Read(Features); var running = store.Read(service);
            var plan = new ControlPlan([feature, running], [new(feature, With(feature, "Enabled"), ["HypervisorPlatform"]), new(running, ControlValues.From(true))], []);
            var attempted = 0;
            Refusal(() => ControlExecution.Apply(plan, store, count => attempted = count));
            var message = Refusal(() => ControlExecution.Rollback(plan, attempted, store));
            check(message.Contains("pending until restart: HypervisorPlatform Enabled") && dism.Calls.SequenceEqual(["enable HypervisorPlatform"]),
                "Rollback names a pending feature enable it cannot undo and does not queue another feature change");
        });
        Scenario("feature changes run after every other control", () =>
        {
            var path = Path.Combine(root, "feature-order.json"); var store = FileTweakStore.Create(path);
            var service = new ControlAddress("service", "FixtureService", "running");
            var fixture = OperationFiles.Read<TweakFixture>(path);
            fixture.Controls.Add(Features.Key, FeatureRead(new() { ["HypervisorPlatform"] = "Disabled" }));
            fixture.Controls.Add(service.Key, new(service, service.Key, "fixture-service-binary", ControlValues.From(false)));
            OperationFiles.Write(path, fixture);
            TweakDefinition Setting(string id, ControlAddress address, object value, bool patch) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
                [new("set", "Set", [], Controls: [new(address, ControlValues.From(value), patch)])], [new("Roo Industries", "fixture", "feature ordering")]);
            var engine = new TweakEngine(new(1, "feature-order", [Setting("feature", Features, new Dictionary<string, string> { ["HypervisorPlatform"] = "Enabled" }, true), Setting("start", service, true, false)], []), store);
            var plan = engine.Preview("order", [new("feature", "set"), new("start", "set")]);
            check(plan.Controls!.Changes.Length == 2 && plan.Controls.Changes[^1].Before.Address.Kind == "windows-features", "Feature changes are written last so no later control failure can follow a pending feature change");
        });
        Scenario("Hypervisor at startup and Hyper-V features", () =>
        {
            const string platform = "windows.f9609ebfa4139feb", platformOn = "choice-2585776417baa62b", launch = "windows.f621c6877f2af1d1", launchOff = "choice-8a82bd73e2e93338";
            var path = Path.Combine(root, "feature-hypervisor.json"); var store = FileTweakStore.Create(path);
            var boot = new ControlAddress("boot-configuration", "current", "hypervisorlaunchtype");
            var fixture = OperationFiles.Read<TweakFixture>(path);
            fixture.Controls.Add(Features.Key, FeatureRead(new() { ["HypervisorPlatform"] = "Disabled", ["VirtualMachinePlatform"] = "Disabled", ["Recall"] = "Disabled" }));
            fixture.Controls.Add(boot.Key, new(boot, boot.Key, "fixture", ControlValues.From<object?>(null)));
            OperationFiles.Write(path, fixture);
            var engine = new TweakEngine(catalog, store);
            TweakState Apply(string profile, params TweakSelection[] choices)
            {
                var plan = engine.Preview(profile, choices); var file = Path.Combine(root, plan.OperationId + ".json");
                OperationFiles.Write(file, plan); return engine.Apply(file, OperationFiles.HashFile(file)).State;
            }
            check(Refusal(() => engine.Preview("both", [new(platform, platformOn), new(launch, launchOff)])) == "Hyper-V features and Hypervisor at startup can't change in the same apply. Apply one, restart Windows, then apply the other.", "One review cannot change a Hyper-V feature and Hypervisor at startup together, and says to apply them separately");
            Apply("fps", new TweakSelection(launch, launchOff));
            check(Refusal(() => engine.Preview("mine", [new(platform, platformOn)])) == "Undo the FPS preset (or set Hypervisor at startup back to No override) first, apply, restart Windows, then change Hyper-V features. Windows resets Hypervisor at startup when it finishes Hyper-V changes.", "A Hyper-V feature change is refused while a profile owns Hypervisor at startup, and says to undo the FPS preset first");
            Apply("fps");
            Apply("mine", new TweakSelection(platform, platformOn));
            var pending = OperationFiles.Read<TweakFixture>(path);
            pending.Controls[Features.Key] = pending.Controls[Features.Key] with { RestartPending = true }; OperationFiles.Write(path, pending);
            check(Refusal(() => engine.Preview("fps", [new(launch, launchOff)])) == "Restart Windows first, then change Hypervisor at startup. A Windows feature change is still waiting for restart and can reset it.", "Hypervisor at startup is refused while a feature change waits for restart, and says to restart first");
            check(Refusal(() => engine.Preview("mine", [])).Contains("Restart Windows"), "Undoing a pending feature change before restart is refused");
            var status = engine.Detect().Settings.Single(setting => setting.Id == platform);
            check(status.ConfiguredChoices.SequenceEqual([platformOn]) && status.Controls!.Any(control => control.RestartPending), "Detection shows a pending enable as on and marks it pending");
        });
        check(failures.Count == 0, "Windows feature restart handling (" + failures.Count + " failed scenarios)");
    }
    public static void Native(Action<bool, string> check)
    {
        var timer = System.Diagnostics.Stopwatch.StartNew();
        var first = new WindowsControlStore().Read(Features); var elapsed = timer.ElapsedMilliseconds;
        var second = new WindowsControlStore().Read(Features);
        Console.WriteLine("Feature read " + elapsed + " ms, pending " + first.RestartPending + ": " + string.Join(", ", first.Parents!.Keys.Order(StringComparer.Ordinal).Select(name => name + "=" + first.Value.GetProperty(name).GetString())));
        check(first.Same(second) && first.RestartPending == second.RestartPending && first.Parents.ContainsKey("HypervisorPlatform"), "Native feature reads with per-feature servicing states are stable");
    }
    static TweakControlRead FeatureRead(Dictionary<string, string> states) =>
        new(Features, Features.Key, "features", ControlValues.From(states), Parents: states.Keys.ToDictionary(name => name, _ => Array.Empty<string>()));

    sealed class FeatureStore(FakeDism dism, params TweakControlRead[] others) : IControlStore
    {
        private readonly Dictionary<string, TweakControlRead> _values = others.ToDictionary(item => item.Address.Key);
        public string? Fail { get; init; }
        public TweakControlRead Read(ControlAddress address) => address.Kind == "windows-features" ? WindowsFeatures.Read(address, dism) : _values[address.Key];
        public void Write(TweakControlRead before, JsonElement after)
        {
            if (before.Address.Kind == "windows-features") { WindowsFeatures.Write(before, after, dism); return; }
            if (before.Address.Key == Fail) throw new IOException("Controlled native failure");
            _values[before.Address.Key] = before with { Value = after };
        }
    }
    sealed class FakeDism : DismServicing
    {
        public Dictionary<string, int> Listed { get; } = new(StringComparer.Ordinal) { ["HypervisorPlatform"] = 2, ["TelnetClient"] = 2 };
        public Dictionary<string, int> Info { get; } = new(StringComparer.Ordinal);
        public List<string> Calls { get; } = [];
        public int ChangeResult { get; set; }
        public int CloseAfterChange { get; set; }
        public int ReadCloseResult { get; set; }
        public bool InfoShowsPending { get; set; } = true;
        private bool _changed;
        public override int Initialize() => 0;
        public override int OpenSession(out uint session) { session = 7; return 0; }
        public override int GetFeatures(uint session, out (string Name, int State)[] features) { features = Listed.Select(item => (item.Key, item.Value)).ToArray(); return 0; }
        public override int GetFeatureParents(uint session, string feature, out string[] parents) { parents = []; return 0; }
        public override int GetFeatureState(uint session, string feature, out int state) { state = Info.TryGetValue(feature, out var info) ? info : Listed[feature]; return 0; }
        public override int EnableFeatures(uint session, string features) => Change("enable " + features, features, 4, 5);
        public override int DisableFeatures(uint session, string features, bool removePayload) => Change("disable " + features, features, removePayload ? 3 : 2, 1);
        private int Change(string call, string features, int target, int pending)
        {
            Calls.Add(call); _changed = true;
            var restart = ChangeResult == 3010 || CloseAfterChange == 3010;
            foreach (var name in features.Split(';')) { Listed[name] = target; Info[name] = restart && InfoShowsPending ? pending : target; }
            return ChangeResult;
        }
        public override int CloseSession(uint session) => _changed ? CloseAfterChange : ReadCloseResult;
        public override int Shutdown() => 0;
    }
}
