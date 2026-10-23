using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class MitigationCommandChecks
{
    const string Parent = @"Software\RooIndustriesTweakTests";
    const string Kernel = @"SYSTEM\ControlSet001\Control\Session Manager\kernel";
    const string LiveKernel = @"SYSTEM\CurrentControlSet\Control\Session Manager\kernel";
    static readonly string[] Names = ["MitigationOptions", "MitigationAuditOptions", "EAFModules"];
    static readonly ControlAddress Address = new("mitigations", "system", "policy");
    static string Live()
    {
        using var key = Registry.LocalMachine.OpenSubKey(LiveKernel);
        return string.Join("|", Names.Select(name => key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) switch { null => "absent", byte[] bytes => key.GetValueKind(name) + ":" + Convert.ToHexString(bytes), var other => key.GetValueKind(name) + ":" + other }));
    }

    static (string Name, Func<object, Process> Launcher)[] Modules(string folder) =>
    [
        ("missing", MissingCommandChecks.Launcher("", "", Path.Combine(folder, "no-modules"))),
        ("broken", MissingCommandChecks.Launcher("", "", MissingCommandChecks.BrokenModule(folder, "BrokenMitigations", "The mitigation provider dependency could not be loaded.", "Get-ProcessMitigation"))),
    ];
    static string Review(TweakEngine engine, string folder, TweakSelection[] choices)
    {
        var plan = engine.Preview("mitigation-fixture", choices);
        var path = Path.Combine(folder, plan.OperationId + ".json"); OperationFiles.Write(path, plan); return path;
    }
    static JsonElement Snapshot() => MitigationControl.Snapshot(
        RegistryNative.ReadTweak(new("LocalMachine", "Registry64", LiveKernel, "value", Names[0])).Value,
        RegistryNative.ReadTweak(new("LocalMachine", "Registry64", LiveKernel, "value", Names[1])).Value,
        RegistryNative.ReadTweak(new("LocalMachine", "Registry64", LiveKernel, "value", Names[2])).Value);
    static void Apply(TweakEngine engine, string path) => engine.Apply(path, OperationFiles.HashFile(path));

    public static void Run(Action<bool, string> check, string folder)
    {
        var root = Parent + "\\" + Guid.NewGuid().ToString("N");
        using var owned = OwnedRegistryKey.Create(Registry.CurrentUser, root);
        using var machine = Registry.CurrentUser.CreateSubKey(root + @"\Machine");
        using (var select = machine.CreateSubKey(@"SYSTEM\Select")) select.SetValue("Current", 1, RegistryValueKind.DWord);
        using var kernel = machine.CreateSubKey(Kernel);
        var desired = ControlValues.From(new Dictionary<string, object> { ["Aslr.BottomUp"] = "ON", ["Aslr.OverrideBottomUp"] = false });
        var setting = new TweakDefinition("mitigations", "Exploit protection", "Security", "Fixture", 10240, int.MaxValue, ["*"], "none",
            [new("set", "Set", [], Controls: [new(Address, desired, true)])], [new("Roo Industries", "fixture", "mitigation store")]);
        var store = new RegistryTweakStore(new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State"));
        var engine = new TweakEngine(new TweakCatalog(1, "mitigation-commands", [setting], []), store);
        var originalLauncher = PowerShellControls.Launcher;
        var live = Live();
        RegistryNative.MachineRoot = () => Registry.CurrentUser.OpenSubKey(root + @"\Machine", true)!.Handle;
        var marker = "isolation-" + Guid.NewGuid().ToString("N");
        kernel.SetValue(Names[2], marker, RegistryValueKind.String);
        var seen = RegistryNative.ReadTweak(new("LocalMachine", "Registry64", LiveKernel, "value", Names[2])).Value;
        if (seen is not { Type: 1 } text || Encoding.Unicode.GetString(text.Bytes).TrimEnd('\0') != marker || Live() != live)
        {
            RegistryNative.MachineRoot = null;
            throw new InvalidOperationException("The mitigation fixture does not isolate this PC's own policy, so it refuses to write.");
        }
        kernel.DeleteValue(Names[2]);
        try
        {
            foreach (var (modules, launcher) in Modules(folder))
            foreach (var seeded in new[] { false, true })
            {
                foreach (var name in Names) kernel.DeleteValue(name, false);
                var bytes = new byte[32]; bytes[0] = 0x83; bytes[2] = 0x82; bytes[9] = 0x52; bytes[31] = 0xc1;
                if (seeded)
                {
                    kernel.SetValue(Names[0], bytes, RegistryValueKind.Binary);
                    kernel.SetValue(Names[1], new byte[] { 0x80, 0x52 }, RegistryValueKind.Binary);
                    kernel.SetValue(Names[2], "fixture.dll", RegistryValueKind.String);
                }
                var before = Snapshot();
                PowerShellControls.Launcher = launcher;
                var read = engine.Detect().Settings.Single();
                check(read.Error is null && read.Controls is [{ } control] && ControlValues.Equal(control.Value, before),
                    "Exploit protection reads the native store with its module " + modules + " and policy " + (seeded ? "present" : "absent") + ": " + read.Error);
                var review = Review(engine, folder, [new("mitigations", "set")]);
                check(ControlValues.Equal(Snapshot(), before) && (store.ReadState()?.Profiles.Length is null or 0) && store.Recovery().Pending is null, "Mitigation review writes no policy or recovery state");
                Apply(engine, review);
                var expected = seeded ? bytes.ToArray() : new byte[24]; expected[2] = (byte)((expected[2] & ~7) | 1);
                check(((byte[])kernel.GetValue(Names[0])!).SequenceEqual(expected) && store.Recovery().Pending is null,
                    "Mitigation apply changes only the reviewed bits with its module " + modules);
                PowerShellControls.Launcher = Modules(folder).First(item => item.Name != modules).Launcher;
                Apply(engine, Review(engine, folder, []));
                check(ControlValues.Equal(Snapshot(), before) && store.ReadState()?.Profiles.Length == 0 && store.Recovery().Pending is null,
                    "Mitigation Undo restores original bytes, types, absence, audit and EAF after its module state changes");
                review = Review(engine, folder, [new("mitigations", "set")]);
                var drift = bytes.ToArray(); drift[2] = 2; kernel.SetValue(Names[0], drift, RegistryValueKind.Binary);
                var rejected = false;
                try { Apply(engine, review); } catch (InvalidDataException) { rejected = true; }
                check(rejected && ((byte[])kernel.GetValue(Names[0])!).SequenceEqual(drift) && store.Recovery().Pending is null,
                    "Mitigation drift after review is preserved before any journal or write");
            }
            kernel.SetValue(Names[0], "wrong type", RegistryValueKind.String);
            check(engine.Detect().Settings.Single().Error is not null && store.Recovery().Pending is null,
                "An unsupported mitigation store type stays a read error without writing");
        }
        finally
        {
            PowerShellControls.Launcher = originalLauncher;
            RegistryNative.MachineRoot = null;
        }
        check(Live() == live, "The mitigation fixture leaves this PC's own exploit protection policy exactly as it was");
    }

    static JsonElement Independent() => JsonDocument.Parse(MissingCommandChecks.WindowsPowerShell("$policy=Get-ProcessMitigation -System -WarningAction Stop; $values=@{}; foreach($group in $policy.PSObject.Properties){foreach($field in $group.Value.PSObject.Properties){if($field.Value -is [bool]){$values[$group.Name+'.'+$field.Name]=[bool]$field.Value}elseif([string]$field.Value -cin @('ON','OFF','NOTSET')){$values[$group.Name+'.'+$field.Name]=[string]$field.Value}}}; $values|ConvertTo-Json -Compress")).RootElement;
    static bool Matches(JsonElement read, JsonElement expected) => expected.EnumerateObject().Where(field => field.Name != MitigationControl.SnapshotField).All(field =>
        read.TryGetProperty(field.Name, out var actual) && (ControlValues.Equal(actual, field.Value) ||
        field.Name is "Dep.EmulateAtlThunks" or "Aslr.RequireInfo" or "Cfg.SuppressExports" && actual.ValueKind == JsonValueKind.String && actual.GetString() == "NOTSET" && field.Value.GetString() == "OFF"));

    public static void RunReal(Action<bool, string> check, string repo, string evidence)
    {
        var folder = Directory.CreateTempSubdirectory("roo-industries-mitigation-rows-");
        var root = Parent + "\\" + Guid.NewGuid().ToString("N");
        var owned = OwnedRegistryKey.Create(Registry.CurrentUser, root);
        var originalLauncher = PowerShellControls.Launcher;
        var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend", "catalogs", "windows-tweaks.json"));
        var rows = catalog.Settings.Where(row => row.Options.Any(option => option.Controls?.Any(control => control.Address == Address) == true)).ToArray();
        var baseline = Snapshot(); var results = new List<object>(); var restored = false;
        RegistryTweakStore? activeStore = null;
        try
        {
            check(rows.Length == 15, "The real mitigation gate includes all 15 catalog rows");
            foreach (var (modules, launcher) in Modules(folder.FullName))
            foreach (var row in rows)
            foreach (var choice in row.Options)
            {
                var store = activeStore = new RegistryTweakStore(new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State"));
                var engine = new TweakEngine(catalog with { Settings = [row], Presets = [], Incompatible = null }, store);
                PowerShellControls.Launcher = launcher;
                var before = Snapshot();
                JsonElement applied = default, observed = default;
                try
                {
                    var detected = engine.Detect().Settings.Single();
                    check(detected.Error is null && detected.Controls is [{ } read] && ControlValues.Equal(read.Value, before) && Matches(Independent(), before),
                        row.Name + " reads the independent Windows policy with its module " + modules + ": " + detected.Error);
                    Apply(engine, Review(engine, folder.FullName, [new(row.Id, choice.Id)]));
                    applied = Snapshot(); observed = Independent();
                    check(Matches(observed, applied) && choice.Controls!.All(control => Matches(observed, control.Value)),
                        row.Name + " applies " + choice.Name + " with its module " + modules + ": independent Get-ProcessMitigation agrees");
                }
                finally
                {
                    if (store.Recovery() is { Pending: not null, PendingHash: { } hash }) store.Recover(hash);
                    if (store.ReadState()?.Profiles.Length > 0) Apply(engine, Review(engine, folder.FullName, []));
                    check(ControlValues.Equal(Snapshot(), before) && Matches(Independent(), before) && (store.ReadState()?.Profiles.Length is null or 0) && store.Recovery().Pending is null,
                        row.Name + " Undo restores original policy bytes, types, absence and independent Windows readings");
                }
                results.Add(new { modules, row = row.Id, choice = choice.Id, before, applied, observed, restored = Snapshot() });
            }
            restored = ControlValues.Equal(Snapshot(), baseline);
            check(restored, "Every mitigation row and choice restores the original Windows policy with its module missing and broken");
        }
        finally
        {
            PowerShellControls.Launcher = originalLauncher;
            restored = false;
            try
            {
                var final = Snapshot();
                var recovery = activeStore?.Recovery();
                restored = ControlValues.Equal(final, baseline) && recovery?.Pending is null && (recovery?.State?.Profiles.Length is null or 0);
                OperationFiles.Write(evidence, new { baseline, final, restored, results });
            }
            finally
            {
                if (restored) { owned.Dispose(); folder.Delete(true); }
                else Console.Error.WriteLine("Retained mitigation recovery at " + root + " and the Windows temp folder " + folder.Name);
            }
        }
    }
}
