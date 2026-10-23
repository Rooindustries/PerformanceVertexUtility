using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class RegistryTweakChecks
{
    public const string Root = @"Software\RooIndustriesTweakTests\ec3d917cb672498785218eb3d0aa790f";
    public static void Run(string files, Action<bool, string> check, Action<Action, string> reject)
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using (var existing = hive.OpenSubKey(Root)) if (existing is not null) throw new InvalidDataException("The native fixture already exists; it will not be reused.");
        var parentExisted = false;
        using (var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        var address = new RegistryAddress("CurrentUser", "Registry64", Root + @"\Settings", "value", "Enabled");
        var other = address with { ValueName = "Other" };
        var recovery = address with { KeyPath = Root + @"\Recovery", ValueName = "State" };
        TweakDefinition Definition(string id, RegistryAddress target) => new(id, id, "Fixture", "Disposable registry setting", 10240, 26200, ["*"], "none",
            [new("zero", "Zero", [new(target, 0)]), new("one", "One", [new(target, 1)])], [new("Roo Industries", "native fixture", "disposable registry execution")]);
        var catalog = new TweakCatalog(1, "fixture", [Definition("first", address), Definition("alias", address with { View = "Registry32", ValueName = "ENABLED" }), Definition("other", other)], []);
        var store = new RegistryTweakStore(recovery); var engine = new TweakEngine(catalog, store);
        (string Path, string Hash, TweakPlan Plan) Preview(string id, TweakSelection[] selected)
        {
            var plan = engine.Preview(id, selected); var path = Path.Combine(files, plan.OperationId + ".json");
            OperationFiles.Write(path, plan); return (path, OperationFiles.HashFile(path), plan);
        }
        TweakState Apply(string id, TweakSelection[] selected) { var plan = Preview(id, selected); return engine.Apply(plan.Path, plan.Hash).State; }
        object? Value(string name) { using var key = hive.OpenSubKey(address.KeyPath); return key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames); }
        byte[]? State() { using var key = hive.OpenSubKey(recovery.KeyPath); return key?.GetValue("State") as byte[]; }
        try
        {
            var initial = Preview("a", [new("first", "zero"), new("alias", "zero")]);
            check(initial.Plan.Changes.Length == 1, "Native key identity merges shared 32/64-bit aliases and case variants");
            engine.Apply(initial.Path, initial.Hash);
            using (var key = hive.OpenSubKey(address.KeyPath)) check(key?.GetValueKind("Enabled") == RegistryValueKind.DWord && Equals(key.GetValue("Enabled"), 0), "Independent registry API reads the requested type and value");
            var shared = Apply("b", [new("first", "zero")]);
            check(shared.History[^1].Changes.Length == 0, "Second native profile claims an existing value without a duplicate write");
            Apply("a", []); check(Equals(Value("Enabled"), 0), "Native shared value remains while another profile requires it");
            Apply("b", []);
            using (var key = hive.OpenSubKey(address.KeyPath)) check(key is null, "Native last-owner restore removes only the created empty setting keys");
            new TweakEngine(catalog, new RegistryTweakStore(recovery)).Apply(initial.Path, initial.Hash);
            check(Value("Enabled") is null, "Native committed receipt prevents an old retry from reapplying restored settings");

            using (var key = hive.CreateSubKey(address.KeyPath)) key.SetValue("Enabled", "original", RegistryValueKind.String);
            Apply("typed", [new("first", "zero")]); Apply("typed", []);
            using (var key = hive.OpenSubKey(address.KeyPath)) check(key?.GetValueKind("Enabled") == RegistryValueKind.String && Equals(key.GetValue("Enabled"), "original"), "Native restore reproduces a different original registry type");

            var stale = Preview("drift", [new("first", "one")]);
            using (var key = hive.OpenSubKey(address.KeyPath, true)) key!.SetValue("Enabled", 91, RegistryValueKind.DWord);
            reject(() => engine.Apply(stale.Path, stale.Hash), "Native external writer invalidates a reviewed plan");
            check(Equals(Value("Enabled"), 91), "Native external value survives review rejection");

            var fault = Preview("atomic", [new("first", "one"), new("other", "one")]);
            var stateBefore = State()!;
            var broken = fault.Plan with { Changes = fault.Plan.Changes.Select((change, index) => index == 1 ? change with { After = new(change.Before.Address.ValueName!, 4, [1]) } : change).ToArray() };
            reject(() => store.Commit(broken, fault.Hash), "Native failure during a multi-value transaction aborts the commit");
            check(Equals(Value("Enabled"), 91) && Value("Other") is null && State()!.SequenceEqual(stateBefore), "Native transaction rolls back its earlier write and its recovery state together");

            Apply("atomic", [new("first", "one"), new("other", "one")]);
            Apply("atomic", []);
            check(Equals(Value("Enabled"), 91) && Value("Other") is null, "Native full apply and restore preserve an original value and an absent value together");

            var restart = Preview("restart", [new("other", "one")]); engine.Apply(restart.Path, restart.Hash);
            var boot = RegistryTweakStore.CurrentBoot();
            check(boot is not null && RegistryTweakStore.SameBoot(boot), "Windows exposes a boot identifier for restart checks");
            void AwaitRestart(string bootId)
            {
                using var key = hive.CreateSubKey(recovery.KeyPath);
                key.SetValue("Pending", System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new ControlJournal(restart.Plan with { Controls = new([], [], []) }, restart.Hash, 0, "awaiting-restart", bootId), OperationFiles.Json), RegistryValueKind.Binary);
            }
            AwaitRestart(boot!);
            var sameBoot = "";
            try { store.Recover(store.Recovery().PendingHash!); } catch (InvalidDataException error) { sameBoot = error.Message; }
            check(sameBoot == RegistryTweakStore.RestartAgain && sameBoot.Contains("not Shut down", StringComparison.Ordinal),
                "A restart check with the same boot marker, as after a Fast Startup shutdown, keeps the pending feature record and says to choose Restart: " + sameBoot);
            check(store.Recovery().Pending is not null, "The pending feature record survives a same-boot restart check");
            AwaitRestart("boot:" + Guid.NewGuid().ToString("N"));
            check(store.Recover(store.Recovery().PendingHash!) && store.Recovery().Pending is null, "A restart check after a new boot closes the pending feature record");
            Apply("restart", []);
        }
        finally { Remove(hive, parentExisted, check); }
    }
    public static void WindowsDefaults(string files, string repo, TweakCatalog catalog, Action<bool, string> check, Action<Action, string> reject)
    {
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using (var existing = hive.OpenSubKey(Root)) if (existing is not null) throw new InvalidDataException("The native fixture already exists; it will not be reused.");
        var parentExisted = false;
        using (var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        var recovery = new RegistryAddress("CurrentUser", "Registry64", Root + @"\Recovery", "value", "State");
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(repo, "backend", "catalogs", "windows-default-values.json")));
        byte[]? State() { using var key = hive.OpenSubKey(recovery.KeyPath); return key?.GetValue("State") as byte[]; }
        try
        {
            foreach (var stock in document.RootElement.GetProperty("values").EnumerateArray())
            {
                var (hiveName, path, name, kept) = (stock.GetProperty("hive").GetString(), stock.GetProperty("keyPath").GetString()!, stock.GetProperty("valueName").GetString()!, stock.GetProperty("dword").GetUInt32());
                bool Kept(RegistryAddress address) => address.Hive == hiveName && address.KeyPath.Equals(path, StringComparison.OrdinalIgnoreCase) && string.Equals(address.ValueName, name, StringComparison.OrdinalIgnoreCase);
                var (fixture, missing) = (Root + @"\Stock\" + path, Root + @"\Missing\" + path);
                var definition = catalog.Settings.Single(setting => setting.Options.Any(option => option.Changes.Any(change => Kept(change.Address))));
                TweakDefinition Remap(string target)
                {
                    var moved = definition with { Options = definition.Options.Select(option => option with { Changes = option.Changes.Select(change => Kept(change.Address) ? change with { Address = change.Address with { Hive = "CurrentUser", KeyPath = target } } : change).ToArray() }).ToArray() };
                    if (moved.Options.Any(option => option.Controls is { Length: > 0 } || option.Changes.Any(change => change.Address.Hive != "CurrentUser" || !change.Address.KeyPath.StartsWith(Root + @"\", StringComparison.Ordinal))))
                        throw new InvalidDataException(definition.Name + " also changes a target outside the fixture; it will not be applied.");
                    return moved;
                }
                var row = Remap(fixture);
                var reset = row.Options.Single(option => option.Name is "Windows default" or "Remove this override");
                var other = row.Options.First(option => option.Id != reset.Id);
                var on = other.Changes.Single().Dword!.Value;
                var legacy = row with { Options = row.Options.Select(option => option.Id == reset.Id ? option with { Name = "Remove this override", Changes = option.Changes.Select(change => change with { Dword = null }).ToArray() } : option).ToArray() };
                TweakEngine Engine(TweakDefinition setting) => new(catalog with { Settings = [setting], Presets = [], Incompatible = null }, new RegistryTweakStore(recovery));
                var engine = Engine(row);
                (string Path, string Hash, TweakPlan Plan) Preview(TweakEngine with, string id, TweakSelection[] selected)
                {
                    var plan = with.Preview(id, selected); var file = Path.Combine(files, plan.OperationId + ".json");
                    OperationFiles.Write(file, plan); return (file, OperationFiles.HashFile(file), plan);
                }
                void Apply(TweakEngine with, string id, TweakSelection[] selected) { var plan = Preview(with, id, selected); with.Apply(plan.Path, plan.Hash); }
                TweakSelection[] Pick(TweakOption option) => [new(row.Id, option.Id)];
                uint? Dword() { using var key = hive.OpenSubKey(fixture); return key?.GetValue(name) is int data && key.GetValueKind(name) == RegistryValueKind.DWord ? unchecked((uint)data) : null; }
                bool Present() { using var key = hive.OpenSubKey(fixture); return key?.GetValue(name) is not null; }
                bool Siblings() { using var key = hive.OpenSubKey(fixture); return Equals(key?.GetValue("Behavior"), 73760) && Equals(key?.GetValue("policytype"), 4); }
                void Set(uint? value) { using var key = hive.CreateSubKey(fixture); if (value is { } data) key.SetValue(name, unchecked((int)data), RegistryValueKind.DWord); else key.DeleteValue(name, false); }
                using (var key = hive.CreateSubKey(fixture)) { key.SetValue("Behavior", 73760, RegistryValueKind.DWord); key.SetValue("policytype", 4, RegistryValueKind.DWord); }
                Set(kept);

                var untouched = Preview(engine, "stock", Pick(reset));
                check(untouched.Plan.Changes.Length == 0, definition.Name + ": Windows default on stock Windows changes nothing");
                engine.Apply(untouched.Path, untouched.Hash);
                check(Dword() == kept && Siblings(), definition.Name + ": Windows default keeps Windows' REG_DWORD " + kept + " and the policy's other values");
                Apply(engine, "stock", []);
                check(Dword() == kept && Siblings(), definition.Name + ": Undo after Windows default on stock Windows leaves Windows' value");

                Apply(engine, "on", Pick(other));
                check(Dword() == on && Siblings(), definition.Name + ": " + other.Name + " writes REG_DWORD " + on);
                Apply(engine, "on", []);
                check(Dword() == kept && Siblings(), definition.Name + ": Undo after " + other.Name + " puts Windows' REG_DWORD " + kept + " back");

                Set(on);
                Apply(engine, "reset", Pick(reset));
                check(Dword() == kept && Siblings(), definition.Name + ": Windows default turns an earlier " + on + " back into Windows' " + kept);
                Apply(engine, "reset", []);
                check(Dword() == on && Siblings(), definition.Name + ": Undo after Windows default restores the exact earlier REG_DWORD " + on);

                Set(null);
                Apply(engine, "absent", Pick(reset));
                check(Dword() == kept && Siblings(), definition.Name + ": Windows default puts Windows' value back after something deleted it");
                Apply(engine, "absent", []);
                check(!Present() && Siblings(), definition.Name + ": Undo after that removes only the value it wrote and keeps the policy key and its other values");
                Apply(Engine(Remap(missing)), "missing", Pick(reset));
                using (var key = hive.OpenSubKey(missing)) check(key?.GetValueKind(name) == RegistryValueKind.DWord && Equals(key.GetValue(name), unchecked((int)kept)), definition.Name + ": Windows default writes Windows' value where the policy key is missing");
                Apply(Engine(Remap(missing)), "missing", []);
                using (var key = hive.OpenSubKey(Root + @"\Missing")) check(key is null, definition.Name + ": Undo there removes the policy keys it created");

                Set(kept);
                Apply(Engine(legacy), "legacy", Pick(reset));
                check(!Present() && Siblings(), definition.Name + ": the older catalog's Remove this override deleted Windows' value");
                reject(() => Engine(row).Preview("other", Pick(reset)), definition.Name + ": another profile can't pick Windows default while the older app's profile still holds the removal");
                check(!Present() && Siblings(), definition.Name + ": that refused review writes nothing");
                Apply(Engine(row), "legacy", []);
                check(Dword() == kept && Siblings(), definition.Name + ": after an update and restart, Undo of a profile the older app applied puts Windows' REG_DWORD " + kept + " back");
                Apply(Engine(legacy), "saved", Pick(reset));
                Apply(Engine(row), "saved", Pick(reset));
                check(Dword() == kept && Siblings(), definition.Name + ": reviewing the older app's saved choice again after an update writes Windows' value back");
                Apply(Engine(row), "saved", []);
                check(Dword() == kept && Siblings() && engine.Detect().State?.Profiles.Length is null or 0, definition.Name + ": Undo of that profile leaves Windows' value and no profile behind");

                Set(on);
                var fault = Preview(engine, "fault", Pick(reset));
                var before = State();
                reject(() => new RegistryTweakStore(recovery).Commit(fault.Plan with { Changes = [.. fault.Plan.Changes, fault.Plan.Changes.Single() with { After = new(name, 4, [1]) }] }, fault.Hash),
                    definition.Name + ": a Windows default write followed by a failing write in the same transaction is rejected");
                check(Dword() == on && Siblings() && (State() ?? []).SequenceEqual(before ?? []), definition.Name + ": the rolled-back write leaves the earlier value and the recovery record unchanged");
            }
        }
        finally { Remove(hive, parentExisted, check); }
    }
    private static void Remove(RegistryKey hive, bool parentExisted, Action<bool, string> check)
    {
        using (var key = hive.OpenSubKey(Root))
        {
            if (key is not null && key.Name != @"HKEY_CURRENT_USER\" + Root) throw new InvalidDataException("Unexpected registry fixture identity.");
        }
        hive.DeleteSubKeyTree(Root, false);
        if (!parentExisted)
        {
            using var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests");
            if (parent is { SubKeyCount: 0, ValueCount: 0 }) { parent.Dispose(); hive.DeleteSubKey(@"Software\RooIndustriesTweakTests", false); }
        }
        using var remaining = hive.OpenSubKey(Root);
        check(remaining is null, "Native registry fixture and recovery receipt are removed");
    }
}
