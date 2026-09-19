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
        }
        finally
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
}
