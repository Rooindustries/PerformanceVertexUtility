using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class FeatureRestartChecks
{
    static readonly ControlAddress Features = new("windows-features", "system", "features");
    static readonly ControlAddress Service = new("service", "RooIndustriesRestartFixture", "startup");
    const string Parent = @"Software\RooIndustriesTweakTests";
    public static void Run(string files, Action<bool, string> check)
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        bool parentExisted;
        using (var parent = hive.OpenSubKey(Parent)) parentExisted = parent is not null;
        var roots = new List<string>(); var failures = new List<string>();
        void Scenario(string name, Action<Fixture> body)
        {
            var root = Parent + @"\" + Guid.NewGuid().ToString("N"); roots.Add(root);
            using (var existing = hive.OpenSubKey(root)) if (existing is not null) throw new InvalidDataException("The feature restart fixture already exists; it will not be reused.");
            try { body(new Fixture(root, files, hive)); }
            catch (Exception error) { failures.Add(name + ": " + error.Message); Console.WriteLine("FAIL " + name + ": " + error.Message); }
        }
        var unlocked = "Recover the incomplete Windows settings operation first.";
        try
        {
            Scenario("Windows undid an enable at restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 2)); f.Dism.ChangeResult = 3010;
                var applied = f.Apply("mine", ("platform", "on"));
                check(applied.State.Notices.Contains(RegistryTweakStore.RestartNotice) && f.Store.Recovery().Pending is { Phase: "awaiting-restart" }, "An enable Windows finishes at restart waits for the restart check");
                var stale = f.Preview("other", ("flag", "one"));
                check(f.Refusal(() => f.Commit(stale)) == unlocked, "While the feature change waits for restart, other Windows settings changes wait too");
                check(f.Refusal(() => f.Recover()) == RegistryTweakStore.RestartAgain && f.Store.Recovery().Pending is not null, "Checking before a restart keeps the feature change pending");
                var revision = f.Store.ReadState()!.Revision;
                f.Restart(); f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null, "After Windows undid the enable at restart, the restart check finishes and closes the pending record");
                var state = f.Store.ReadState()!;
                check(state.Profiles.All(profile => profile.Id != "mine") && state.Controls is { Length: 0 } && state.Revision != revision, "The profile no longer owns the feature Windows undid");
                check(state.Notices.SequenceEqual([RegistryTweakStore.FeaturesUndone + "HypervisorPlatform Disabled."]), "One notice says Windows undid the HypervisorPlatform change: " + string.Join(" | ", state.Notices));
                check(f.Configured("platform").SequenceEqual(["off"]), "The row reads the feature as off");
                check(f.Refusal(() => f.Commit(stale)) == "Settings changed since review. Create a new preview.", "A review made before the restart check can't bring back the released ownership");
                f.Apply("other", ("flag", "one")); check(f.Flag() == 1, "Apply works again after the restart check");
                f.Apply("other"); check(f.Flag() is null, "Restore works again after the restart check");
                f.Apply("mine"); check(f.Dism.Calls.Count == 0 && f.Dism.Listed["HypervisorPlatform"] == 2, "Undo of the released profile writes no Windows feature");
            });
            Scenario("Windows undid a disable at restart", f =>
            {
                f.Boot(("HypervisorPlatform", 4)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "off"));
                f.Restart(); f.Boot(("HypervisorPlatform", 4));
                check(f.Recover() && f.Store.Recovery().Pending is null, "After Windows undid the disable at restart, the restart check closes the pending record");
                var state = f.Store.ReadState()!;
                check(state.Profiles.Length == 0 && state.Controls is { Length: 0 } && state.Notices.SequenceEqual([RegistryTweakStore.FeaturesUndone + "HypervisorPlatform Enabled."]), "The undone disable releases ownership and says the feature is back to Enabled");
                check(f.Configured("platform").SequenceEqual(["on"]), "The row reads the feature as on");
                f.Apply("other", ("flag", "one")); f.Apply("other"); check(f.Flag() is null, "Apply and restore work again after the undone disable");
            });
            Scenario("Windows undid one of two feature changes at restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 4)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"), ("machine", "off"));
                f.Restart(); f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null, "A partly undone feature apply closes the pending record");
                var state = f.Store.ReadState()!; var mine = state.Profiles.Single(profile => profile.Id == "mine");
                check(mine.Selections.SequenceEqual([new TweakSelection("machine", "off")]) && ControlValues.Equal(mine.Controls!.Single().Desired, ControlValues.From(new Dictionary<string, string> { ["VirtualMachinePlatform"] = "Disabled" })),
                    "The profile keeps the change Windows finished and drops the one it undid");
                check(state.Notices.SequenceEqual([RegistryTweakStore.FeaturesUndone + "HypervisorPlatform Disabled."]), "The notice names only the undone feature: " + string.Join(" | ", state.Notices));
                check(f.Configured("platform").SequenceEqual(["off"]) && f.Configured("machine").SequenceEqual(["off"]), "Both rows read the real feature states");
                f.Apply("mine");
                check(f.Dism.Calls.SequenceEqual(["enable VirtualMachinePlatform"]) && f.Dism.Listed["VirtualMachinePlatform"] == 4 && f.Dism.Listed["HypervisorPlatform"] == 2 && f.Store.ReadState()!.Profiles.Length == 0,
                    "Undo restores the finished change and leaves the undone feature alone: " + string.Join(", ", f.Dism.Calls));
            });
            Scenario("Windows undid part of one choice at restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("TelnetClient", 4)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("pair", "swap"));
                f.Restart(); f.Boot(("HypervisorPlatform", 2), ("TelnetClient", 2));
                check(f.Recover(), "A choice Windows partly undid closes the pending record");
                var mine = f.Store.ReadState()!.Profiles.Single(profile => profile.Id == "mine");
                check(mine.Selections.Length == 0 && ControlValues.Equal(mine.Controls!.Single().Desired, ControlValues.From(new Dictionary<string, string> { ["TelnetClient"] = "Disabled" })), "The choice is no longer selected but its finished part keeps its undo");
                check(f.Configured("pair").Length == 0, "The row doesn't read the partly undone choice as on");
                f.Apply("mine");
                check(f.Dism.Calls.SequenceEqual(["enable TelnetClient"]) && f.Dism.Listed["TelnetClient"] == 4 && f.Dism.Listed["HypervisorPlatform"] == 2, "Undo restores only the part Windows finished: " + string.Join(", ", f.Dism.Calls));
            });
            Scenario("A feature change still pending after the restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                var before = f.Raw("State");
                f.Restart(); f.Boot(("HypervisorPlatform", 4)); f.Dism.Info["HypervisorPlatform"] = 5;
                check(f.Refusal(() => f.Recover()) == RegistryTweakStore.RestartAgain && f.Store.Recovery().Pending is not null && f.Raw("State")!.SequenceEqual(before!),
                    "A feature Windows still lists as pending keeps the record and asks for another restart");
                check(f.Refusal(() => f.Apply("other", ("flag", "one"))) == unlocked, "Other changes still wait while the feature is pending");
            });
            Scenario("Windows finished the feature change at restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                var revision = f.Store.ReadState()!.Revision;
                f.Restart(); f.Boot(("HypervisorPlatform", 4));
                check(f.Recover() && f.Store.Recovery().Pending is null, "A finished feature change closes the pending record");
                var state = f.Store.ReadState()!;
                check(state.Profiles.Single().Selections.SequenceEqual([new TweakSelection("platform", "on")]) && state.Notices.Length == 0 && state.Revision == revision, "A finished change keeps its ownership and drops the restart notice");
                check(f.Configured("platform").SequenceEqual(["on"]), "The row reads the finished feature as on");
                f.Apply("mine");
                check(f.Dism.Calls.SequenceEqual(["disable HypervisorPlatform"]) && f.Dism.Listed["HypervisorPlatform"] == 2, "Undo of the finished change restores the original state");
            });
            Scenario("A changed feature is partially installed after restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 4)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"), ("machine", "off"));
                var state = f.Raw("State");
                f.Restart(); var pending = f.Raw("Pending");
                f.Boot(("HypervisorPlatform", 7), ("VirtualMachinePlatform", 7)); f.Dism.InfoResult = unchecked((int)0x80070005);
                check(f.Refusal(() => f.Recover()).Contains("DismGetFeatureInfo(HypervisorPlatform) failed with HRESULT 0x80070005") &&
                    f.Raw("Pending")!.SequenceEqual(pending!) && f.Raw("State")!.SequenceEqual(state!), "An exact-state query failure preserves the journal and every claim");
                f.Boot(("HypervisorPlatform", 7), ("VirtualMachinePlatform", 4));
                var refusal = f.Refusal(() => f.Recover());
                check(refusal == "Windows hasn't finished changing these features: HypervisorPlatform. Restart Windows or finish them in Turn Windows features on or off, then check restart completion again.",
                    "A partially installed changed feature refuses recovery with instructions: " + refusal);
                check(f.Raw("Pending")!.SequenceEqual(pending!) && f.Raw("State")!.SequenceEqual(state!) && f.Store.ReadState()!.Profiles.Single().Controls!.Length == 2,
                    "Unfinished servicing keeps the exact journal, saved originals and every claim, including the other reverted feature");
                check(f.Refusal(() => f.Apply("other", ("flag", "one"))) == unlocked, "Other changes wait while the changed feature is partially installed");
                f.Boot(("HypervisorPlatform", 4), ("VirtualMachinePlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null && f.Store.ReadState()!.Profiles.Single().Controls!.Length == 2,
                    "Once servicing finishes, recovery closes the journal and keeps both completed changes owned");
                f.Apply("mine");
                check(f.Dism.Calls.SequenceEqual(["disable HypervisorPlatform", "enable VirtualMachinePlatform"]) && f.Dism.Listed["HypervisorPlatform"] == 2 && f.Dism.Listed["VirtualMachinePlatform"] == 4,
                    "Undo still restores both exact original feature values after partial installation finishes");
            });
            Scenario("An unrelated feature is partially installed", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("UnrelatedFeature", 7));
                var read = f.Store.ReadControl(Features);
                check(!read.RestartPending && !read.Value.TryGetProperty("UnrelatedFeature", out _) && f.Configured("platform").SequenceEqual(["off"]),
                    "An unrelated partially installed feature does not block normal discovery");
                f.Apply("mine", ("platform", "on"));
                check(f.Store.Recovery().Pending is null && f.Dism.Listed["HypervisorPlatform"] == 4 && f.Dism.Listed["UnrelatedFeature"] == 7,
                    "A normal apply changes only the selected feature while unrelated partial servicing stays untouched");
                f.Apply("mine");
                check(f.Dism.Listed["HypervisorPlatform"] == 2 && f.Dism.Listed["UnrelatedFeature"] == 7, "Undo also works with unrelated partial servicing");
            });
            Scenario("Two restarts: still pending after the first, undone after the second", f =>
            {
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                f.Restart(); f.Boot(("HypervisorPlatform", 4)); f.Dism.Info["HypervisorPlatform"] = 5;
                check(f.Refusal(() => f.Recover()) == RegistryTweakStore.RestartAgain, "After the first restart Windows still lists the change as pending");
                f.Restart(); f.Boot(("HypervisorPlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null && f.Store.ReadState()!.Notices.SequenceEqual([RegistryTweakStore.FeaturesUndone + "HypervisorPlatform Disabled."]),
                    "After the second restart the undone change closes the record with the undone notice");
            });
            Scenario("Windows removed the feature during the restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                f.Restart(); f.Boot(("VirtualMachinePlatform", 2));
                f.Dism.Info["HypervisorPlatform"] = 0;
                check(f.Recover() && f.Store.Recovery().Pending is null, "A feature Windows no longer lists closes the pending record");
                var state = f.Store.ReadState()!;
                check(state.Profiles.Length == 0 && state.Controls is { Length: 0 } && state.Notices.SequenceEqual([RegistryTweakStore.FeaturesRemoved + "HypervisorPlatform."]), "The removed feature is released with a notice: " + string.Join(" | ", state.Notices));
                var row = f.Engine.Detect().Settings.Single(setting => setting.Id == "platform");
                check(!row.Supported && row.Error is { } error && error.StartsWith("No choice applies", StringComparison.Ordinal), "The row shows the removed feature as not available here");
            });
            Scenario("Windows removed one feature while another stays owned", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"), ("machine", "on"));
                f.Restart(); f.Boot(("VirtualMachinePlatform", 4));
                f.Dism.Info["HypervisorPlatform"] = 6;
                check(f.Recover() && f.Store.Recovery().Pending is null, "A missing feature closes recovery while the completed feature remains owned");
                var state = f.Store.ReadState()!; var held = state.Controls!.Single();
                check(held.Original.Binding == f.Store.ReadControl(Features).Binding && held.Original.Value.GetProperty("VirtualMachinePlatform").GetString() == "Disabled",
                    "The retained feature uses the current availability snapshot and keeps its original value");
                f.Apply("other", ("machine", "on")); f.Apply("mine");
                check(f.Dism.Calls.Count == 0 && f.Dism.Listed["VirtualMachinePlatform"] == 4, "New feature choices remain available and shared ownership keeps the completed change");
                f.Apply("other");
                check(f.Dism.Calls.SequenceEqual(["disable VirtualMachinePlatform"]) && f.Dism.Listed["VirtualMachinePlatform"] == 2, "The last owner restores the retained feature's original after another feature disappeared");
            });
            Scenario("The available feature map changes without removing an owned feature", f =>
            {
                f.Boot(("HypervisorPlatform", 2), ("VirtualMachinePlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                f.Restart(); f.Boot(("HypervisorPlatform", 4));
                check(f.Recover() && f.Store.ReadState()!.Controls!.Single().Original.Binding == f.Store.ReadControl(Features).Binding,
                    "A completed change refreshes the availability snapshot when an unrelated feature disappears");
                f.Apply("other", ("platform", "on")); f.Apply("mine"); f.Apply("other");
                check(f.Dism.Calls.SequenceEqual(["disable HypervisorPlatform"]) && f.Dism.Listed["HypervisorPlatform"] == 2, "Feature choices and Undo work after an unrelated availability change");
            });
            Scenario("A feature in a state this app didn't set keeps its record", f =>
            {
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                var before = f.Raw("State");
                f.Restart(); f.Boot(("HypervisorPlatform", 3));
                var refusal = f.Refusal(() => f.Recover());
                check(refusal == "Windows left these features in a state this app didn't set: HypervisorPlatform is DisabledWithPayloadRemoved; set it to Enabled or Disabled. Change them in Turn Windows features on or off, restart Windows, then check restart completion again.",
                    "An unexpected feature state names the feature and the states that close the record: " + refusal);
                check(f.Store.Recovery().Pending is not null && f.Raw("State")!.SequenceEqual(before!) && f.Refusal(() => f.Apply("other", ("flag", "one"))) == unlocked, "The record and saved state stay unchanged");
                f.Restart(); f.Boot(("HypervisorPlatform", 4));
                check(f.Recover() && f.Store.ReadState()!.Profiles.Single().Selections.SequenceEqual([new TweakSelection("platform", "on")]), "Setting the feature to this app's choice and restarting closes the record");
            });
            Scenario("Windows undid a restore at restart", f =>
            {
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                f.Restart(); f.Boot(("HypervisorPlatform", 4)); f.Recover();
                f.Dism.ChangeResult = 3010; f.Apply("mine");
                check(f.Store.Recovery().Pending is { Phase: "awaiting-restart" } && f.Store.ReadState()!.Profiles.Length == 0, "The restore waits for restart");
                f.Restart(); f.Boot(("HypervisorPlatform", 4));
                var refusal = f.Refusal(() => f.Recover());
                check(refusal == "Windows undid the restore of these features when it restarted: HypervisorPlatform is Enabled again (originally Disabled). Set them back to their original in Turn Windows features on or off, restart Windows, then check restart completion again.",
                    "An undone restore keeps the record that holds the original and says how to finish: " + refusal);
                check(f.Store.Recovery().Pending is not null, "The undone restore keeps its record");
                f.Restart(); f.Boot(("HypervisorPlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null && f.Store.ReadState()!.Profiles.Length == 0, "Setting the original back and restarting closes the record");
            });
            Scenario("Windows undid a replacement while the original is still different", f =>
            {
                f.Boot(("HypervisorPlatform", 2));
                f.Apply("mine", ("platform", "on"));
                f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "off"));
                var state = f.Raw("State");
                f.Restart(); var pending = f.Raw("Pending"); f.Boot(("HypervisorPlatform", 4));
                var refusal = f.Refusal(() => f.Recover());
                check(refusal == "Windows left these features in a state this app didn't set: HypervisorPlatform is Enabled; set it to Disabled. Change them in Turn Windows features on or off, restart Windows, then check restart completion again.",
                    "The replacement instructions name only Disabled, the value that can finish recovery: " + refusal);
                check(f.Raw("Pending")!.SequenceEqual(pending!) && f.Raw("State")!.SequenceEqual(state!),
                    "An undone replacement retains the journal and original while the feature differs from that original");
                check(f.Refusal(() => f.Apply("other", ("flag", "one"))) == unlocked, "Other changes wait while the original still needs recovery");
                f.Restart(); f.Boot(("HypervisorPlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null, "Returning the replacement to its accepted original closes recovery");
                f.Apply("mine");
                check(f.Dism.Calls.Count == 0 && f.Dism.Listed["HypervisorPlatform"] == 2, "Undo preserves the original after the replacement finishes");
            });
            Scenario("A restart check cut off midway", f =>
            {
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"));
                f.Restart();
                var state = f.Raw("State"); var pending = f.Raw("Pending");
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ReadCloseResult = unchecked((int)0x80070005);
                check(f.Refusal(() => f.Recover()).Contains("0x80070005") && f.Raw("State")!.SequenceEqual(state!) && f.Raw("Pending")!.SequenceEqual(pending!), "A restart check that fails reading features changes nothing");
                f.Boot(("HypervisorPlatform", 2));
                check(f.Recover() && f.Store.Recovery().Pending is null && f.Store.ReadState()!.Profiles.Length == 0, "The next restart check finishes from the same record");
                state = f.Raw("State");
                check(!f.Recover() && f.Raw("State")!.SequenceEqual(state!), "Repeating a completed recovery after a lost reply changes nothing");
            });
            Scenario("The app stopped before the accepted state was committed", f =>
            {
                f.Boot(("HypervisorPlatform", 2));
                f.Apply("other", ("flag", "one")); var state = f.Raw("State");
                f.Dism.ChangeResult = 3010; f.Apply("mine", ("platform", "on"));
                f.InterruptCommit(state!);
                f.Boot(("HypervisorPlatform", 4));
                check(f.Recover() && f.Store.Recovery().Pending is null && f.Raw("State")!.SequenceEqual(state!),
                    "Recovery before an accepted state commit preserves the prior saved state and closes the interrupted journal");
                check(f.Dism.Calls.SequenceEqual(["disable HypervisorPlatform"]) && f.Dism.Listed["HypervisorPlatform"] == 2 && f.Flag() == 1,
                    "Recovery restores the interrupted feature and preserves the unrelated committed setting");
                f.Apply("other"); check(f.Flag() is null, "Undo of the prior committed setting still works after interrupted apply recovery");
            });
            Scenario("Another program changed a non-feature setting from the same apply", f =>
            {
                f.Others = [new(Service, Service.Key, "fixture-service-binary", ControlValues.From(3))];
                f.Boot(("HypervisorPlatform", 2)); f.Dism.ChangeResult = 3010;
                f.Apply("mine", ("platform", "on"), ("service", "set"));
                f.Restart();
                f.Others = [new(Service, Service.Key, "fixture-service-binary", ControlValues.From(4))];
                f.Boot(("HypervisorPlatform", 4));
                check(f.Recover() && f.Store.ReadState()!.Profiles.Single().Selections.Length == 2, "A setting changed by another program doesn't block the restart check");
                var undo = f.Preview("mine");
                f.Commit(undo);
                check(undo.Plan.LeftAsChanged.SequenceEqual(["service"]) && f.Store.ReadControl(Service).Value.GetInt32() == 4 && f.Dism.Calls.SequenceEqual(["disable HypervisorPlatform"]),
                    "Undo restores the feature and leaves the other program's value");
            });
        }
        finally
        {
            foreach (var root in roots)
            {
                using (var key = hive.OpenSubKey(root))
                    if (key is not null && key.Name != @"HKEY_CURRENT_USER\" + root) throw new InvalidDataException("Unexpected registry fixture identity.");
                hive.DeleteSubKeyTree(root, false);
            }
            if (!parentExisted)
            {
                using var parent = hive.OpenSubKey(Parent);
                if (parent is { SubKeyCount: 0, ValueCount: 0 }) { parent.Dispose(); hive.DeleteSubKey(Parent, false); }
            }
        }
        check(roots.All(root => { using var key = hive.OpenSubKey(root); return key is null; }), "Feature restart fixture keys are removed");
        check(failures.Count == 0, "Windows feature restart check (" + failures.Count + " failed scenarios)");
    }

    public static void Seed(TweakCatalog catalog, string files, string key, string statesPath)
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using (var existing = hive.OpenSubKey(key)) if (existing is not null) throw new InvalidDataException("The seeded recovery key already exists; it will not be reused.");
        var dism = new FeatureChecks.FakeDism { ChangeResult = 3010 }; dism.Listed.Clear();
        foreach (var (name, state) in OperationFiles.Read<Dictionary<string, int>>(statesPath)) dism.Listed[name] = state;
        var engine = new TweakEngine(catalog, new RegistryTweakStore(new("CurrentUser", "Registry64", key, "value", "State"), new FeatureChecks.FeatureStore(dism)));
        var plan = engine.Preview("my-settings", [new("windows.f9609ebfa4139feb", "choice-2585776417baa62b")]);
        var path = Path.Combine(files, plan.OperationId + ".json"); OperationFiles.Write(path, plan);
        engine.Apply(path, OperationFiles.HashFile(path));
        NewBoot(hive, key);
        Console.WriteLine("ROO_INDUSTRIES_FEATURE_SEED " + plan.OperationId + " " + string.Join(", ", dism.Calls));
    }
    static void NewBoot(RegistryKey hive, string keyPath)
    {
        using var key = hive.OpenSubKey(keyPath, true)!;
        var journal = OperationFiles.Deserialize<ControlJournal>((byte[])key.GetValue("Pending")!);
        key.SetValue("Pending", JsonSerializer.SerializeToUtf8Bytes(journal with { Boot = "boot:" + Guid.NewGuid().ToString("N") }, OperationFiles.Json), RegistryValueKind.Binary);
    }

    sealed class Fixture
    {
        private readonly RegistryAddress _recovery;
        private readonly RegistryAddress _flag;
        private readonly string _files;
        private readonly RegistryKey _hive;
        private readonly TweakCatalog _catalog;
        public FeatureChecks.FakeDism Dism { get; private set; } = null!;
        public RegistryTweakStore Store { get; private set; } = null!;
        public TweakEngine Engine { get; private set; } = null!;
        public TweakControlRead[] Others { get; set; } = [];
        public Fixture(string root, string files, RegistryKey hive)
        {
            _recovery = new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State");
            _flag = new("CurrentUser", "Registry64", root + @"\Settings", "value", "Flag");
            _files = files; _hive = hive;
            static Dictionary<string, string> Map(params string[] pairs) => pairs.Select(pair => pair.Split('=')).ToDictionary(pair => pair[0], pair => pair[1]);
            static TweakDefinition Setting(string id, params (string Id, ControlAddress Address, object Value, bool Patch)[] options) => new(id, id, "Fixture", "Disposable feature restart setting", 10240, 26200, ["*"], "none",
                options.Select(option => new TweakOption(option.Id, option.Id, [], Controls: [new(option.Address, ControlValues.From(option.Value), option.Patch)])).ToArray(), [new("Roo Industries", "feature restart fixture", "simulated Windows servicing")]);
            _catalog = new(1, "feature-restart", [
                Setting("platform", ("on", Features, Map("HypervisorPlatform=Enabled"), true), ("off", Features, Map("HypervisorPlatform=Disabled"), true)),
                Setting("machine", ("on", Features, Map("VirtualMachinePlatform=Enabled"), true), ("off", Features, Map("VirtualMachinePlatform=Disabled"), true)),
                Setting("pair", ("swap", Features, Map("HypervisorPlatform=Enabled", "TelnetClient=Disabled"), true)),
                Setting("service", ("set", Service, 2, false)),
                new("flag", "flag", "Fixture", "Disposable registry setting", 10240, 26200, ["*"], "none", [new("one", "One", [new(_flag, 1)])], [new("Roo Industries", "feature restart fixture", "disposable registry value")])], []);
        }
        public void Boot(params (string Name, int State)[] features)
        {
            Dism = new FeatureChecks.FakeDism(); Dism.Listed.Clear();
            foreach (var (name, state) in features) Dism.Listed[name] = state;
            Store = new(_recovery, new FeatureChecks.FeatureStore(Dism, Others), Dism); Engine = new(_catalog, Store);
        }
        public (string Path, string Hash, TweakPlan Plan) Preview(string profile, params (string Setting, string Option)[] picks)
        {
            var plan = Engine.Preview(profile, picks.Select(pick => new TweakSelection(pick.Setting, pick.Option)).ToArray()); var path = Path.Combine(_files, plan.OperationId + ".json");
            OperationFiles.Write(path, plan); return (path, OperationFiles.HashFile(path), plan);
        }
        public TweakApplyResult Commit((string Path, string Hash, TweakPlan Plan) review) => Engine.Apply(review.Path, review.Hash);
        public TweakApplyResult Apply(string profile, params (string Setting, string Option)[] picks) => Commit(Preview(profile, picks));
        public bool Recover() => Store.Recover(Store.Recovery().PendingHash!);
        public void Restart() => NewBoot(_hive, _recovery.KeyPath);
        public void InterruptCommit(byte[] previous)
        {
            using var key = _hive.OpenSubKey(_recovery.KeyPath, true)!;
            key.SetValue("State", previous, RegistryValueKind.Binary);
        }
        public byte[]? Raw(string name) { using var key = _hive.OpenSubKey(_recovery.KeyPath); return key?.GetValue(name) as byte[]; }
        public int? Flag() { using var key = _hive.OpenSubKey(_flag.KeyPath); return key?.GetValue("Flag") as int?; }
        public string[] Configured(string setting) => Engine.Detect().Settings.Single(item => item.Id == setting).ConfiguredChoices;
        public string Refusal(Action action)
        {
            try { action(); } catch (Exception error) when (error is InvalidDataException or InvalidOperationException or IOException) { return error.Message; }
            return "";
        }
    }
}
