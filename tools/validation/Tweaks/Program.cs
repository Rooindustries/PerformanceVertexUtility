using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.Optimizer;

if (args is ["--service-probe"]) { ServiceProbe.Start(); return; }
if (args is ["--service-probe-slow-start", var probeName, var probeDelay]) { ServiceProbe.Start(probeName, int.Parse(probeDelay)); return; }
if (args is ["--kill-apply-child", var killFiles]) { KillApplyChecks.Child(killFiles); return; }
if (args is ["--timer-worker", var timerLaunch]) { TimerStartupChecks.Worker(timerLaunch); return; }
if (args is ["--timer-autostart", var timerRoot]) { TimerControl.RunAutostart(timerRoot); return; }
if (args is ["--timer-detached-start", var detachedRoot]) { TimerChecks.DetachedStart(detachedRoot); return; }
if (args is ["--timer-detached-stop", var stopRoot]) { TimerChecks.DetachedStop(stopRoot); return; }
if (args is ["--timer-job-start", var jobRoot, var jobMode]) { TimerChecks.JobStart(jobRoot, jobMode == "ends-on-close"); return; }
var repo = Path.GetFullPath(args[0]);
var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend/catalogs/windows-tweaks.json"));
var root = Path.Combine(Path.GetTempPath(), "roo-industries-tweak-checks-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
Console.WriteLine("Fixture directory: " + root);
var count = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException(name);
    count++; Console.WriteLine("PASS " + name);
}
void Reject(Action operation, string name)
{
    var rejected = false;
    try { operation(); } catch (Exception error) when (error is InvalidDataException or JsonException or IOException) { rejected = true; }
    Check(rejected, name);
}
var extension = new RegistryAddress("CurrentUser", "Registry64", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "value", "HideFileExt");
TweakSelection[] Show() => [new("explorer.file-extensions", "show")];
FileTweakStore Fresh(string name) => FileTweakStore.Create(Path.Combine(root, name + ".json"));
(string Path, string Hash, TweakPlan Plan) Preview(TweakEngine engine, string profile, TweakSelection[] choices)
{
    var plan = engine.Preview(profile, choices);
    var path = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(path, plan);
    return (path, OperationFiles.HashFile(path), plan);
}
TweakState Apply(TweakEngine engine, string profile, TweakSelection[] choices)
{
    var preview = Preview(engine, profile, choices); return engine.Apply(preview.Path, preview.Hash).State;
}
TweakFixture Fixture(string name) => OperationFiles.Read<TweakFixture>(Path.Combine(root, name + ".json"));
uint? Dword(FileTweakStore store, RegistryAddress address) => store.Read(address).Value is { Type: 4 } data ? BitConverter.ToUInt32(data.Bytes) : null;
void Put(string name, RegistryAddress address, RegistryValueData data)
{
    var fixture = Fixture(name);
    var prefix = "\\REGISTRY\\USER\\" + fixture.Context.Owner.UserSid + "\\";
    var parts = address.KeyPath.Split('\\');
    for (var length = 2; length <= parts.Length; length++)
    {
        var key = prefix + string.Join('\\', parts.Take(length));
        if (!fixture.Keys.ContainsKey(key.ToUpperInvariant())) fixture.Keys.Add(key.ToUpperInvariant(), new(key, "inherited", []));
    }
    fixture.Keys[(prefix + address.KeyPath).ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = data;
    OperationFiles.Write(Path.Combine(root, name + ".json"), fixture);
}
try
{
    if (args is [_, "--release-checks"])
    {
        CompositionChecks.Run(root, Check, Reject); ControlChecks.Run(root, Check, Reject);
        Console.WriteLine($"Completed {count} release planning checks."); return;
    }
    if (args is [_, "--mitigation-catalog", var mitigationOutput])
    {
        MitigationChecks.Run(Check, Reject);
        var mitigations = catalog.Settings.Where(row => row.Options.Any(option => option.Controls?.Any(control => control.Address.Kind == "mitigations") == true)).ToArray();
        Check(mitigations.Length == 15, "The mitigation catalog gate includes all 15 rows");
        CatalogMatrixChecks.Run(root, catalog with { Settings = mitigations, Presets = [], Incompatible = null }, mitigationOutput); return;
    }
    if (args is [_, "--catalog-matrix", var matrixOutput]) { CatalogMatrixChecks.Run(root, catalog, matrixOutput); return; }
    if (args is [_, "--preset-matrix", var presetOutput]) { CatalogMatrixChecks.Presets(root, catalog, presetOutput); return; }
    if (args is [_, "--restore-point-fixture", var restoreEvidence]) { RestorePointChecks.Native(restoreEvidence, Check); Console.WriteLine($"Completed {count} native restore-point checks."); return; }
    if (args is [_, "--extended-native-fixture", var nativeRequest]) { NativeCoverageChecks.Run(nativeRequest, Check); Console.WriteLine($"Completed {count} extended native checks."); return; }
    if (args is [_, "--restore-extended-memory", var memoryRequest]) { NativeCoverageChecks.RestoreMemory(memoryRequest); return; }
    if (args is [_, "--power-fixture"]) { PowerChecks.Run(root, Check); Console.WriteLine($"Completed {count} native power checks."); return; }
    if (args is [_, "--file-controls-fixture"]) { NativeFileControlChecks.Run(Check, Reject); Console.WriteLine($"Completed {count} native file-control checks."); return; }
    if (args is [_, "--hosts-fixture"]) { HostsChecks.Native(Check, Reject); Console.WriteLine($"Completed {count} native hosts checks."); return; }
    if (args is [_, "--windows-types-fixture"]) { RegistryTypeChecks.Run(root, repo, catalog, Check, Reject); Console.WriteLine($"Completed {count} Windows type checks."); return; }
    if (args is [_, "--timer-fixture"]) { TimerChecks.Native(Check); TimerChecks.Job(Check); Console.WriteLine($"Completed {count} native timer checks."); return; }
    if (args is [_, "--power-plan-fixture"]) { PowerPlanChecks.Native(Check, Reject); Console.WriteLine($"Completed {count} native power-plan checks."); return; }
    if (args is [_, "--timer-startup-fixture"] or [_, "--timer-startup-fixture", _])
    {
        try { TimerStartupChecks.Native(Check, args.Length == 3 ? args[2] : null); Console.WriteLine($"Completed {count} native startup checks."); }
        catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }
        return;
    }
    if (args is [_, "--download-blocker-fixture"]) { DownloadBlockerChecks.Native(Check); Console.WriteLine($"Completed {count} native download blocker checks."); return; }
    if (args is [_, "--catalog-integration"]) { CatalogIntegrationChecks.Run(root, catalog, Check, Reject); Console.WriteLine($"Completed {count} catalog integration checks."); return; }
    if (args is [_, "--recover-controls-fixture"]) { NativeControlChecks.RecoverFixture(); return; }
    if (args is [_, "--controls-recovery-fixture"]) { NativeControlChecks.RecoveryChecks(Check); Console.WriteLine($"Completed {count} native control recovery checks."); return; }
    if (args is [_, "--controls-fixture"]) { NativeControlChecks.Run(root, Check, Reject); Console.WriteLine($"Completed {count} native control checks."); return; }
    if (args is [_, "--feature-read"]) { FeatureChecks.Native(Check); return; }
    if (args is [_, "--service-names"])
    {
        var services = catalog.Settings.SelectMany(setting => setting.Options.SelectMany(option => option.Controls ?? [])).Select(control => control.Address).Where(address => address.Kind == "service").Distinct().ToArray();
        var names = new List<string>(); var unreadable = new List<string>();
        foreach (var address in services)
        {
            try { var read = new WindowsControlStore().Read(address); names.Add(address.Target + " => " + read.DisplayName); if (read.DisplayName is not { } display || display.Length == 0 || !char.IsLetterOrDigit(display[0])) unreadable.Add(address.Target + " => '" + read.DisplayName + "'"); }
            catch (Exception error) when (error is InvalidDataException or System.ComponentModel.Win32Exception or IOException) { }
        }
        foreach (var name in names.Where(name => name.Contains("UsoSvc", StringComparison.Ordinal) || name.Contains(" => :", StringComparison.Ordinal)).Take(10)) Console.WriteLine("SERVICE " + name);
        var inconsistent = names.GroupBy(name => name.Split(" => ")[0]).Where(group => group.Select(name => name.Split(" => ")[1].Split(": ")[0]).Distinct().Count() > 1).Select(group => string.Join(" | ", group)).ToArray();
        Check(inconsistent.Length == 0, "Each service shows the same name for every property it controls: " + string.Join("; ", inconsistent.Take(4)));
        Check(names.Count > 0 && unreadable.Count == 0, "Every installed catalog service shows a readable name (" + names.Count + " read): " + string.Join("; ", unreadable.Take(8)));
        Console.WriteLine($"Completed {count} service name checks."); return;
    }
    if (args is [_, "--boot-clock-shift"]) { FeatureChecks.ClockShift(Check); Console.WriteLine($"Completed {count} boot clock checks."); return; }
    if (args is [_, "--boot-identity"]) { Console.WriteLine("BOOT " + RegistryTweakStore.CurrentBoot()); return; }
    if (args is [_, "--kill-apply-fixture"]) { KillApplyChecks.Run(root, Check); Console.WriteLine($"Completed {count} kill-apply checks."); return; }
    if (args is [_, "--detect-checks"]) { DetectChecks.Run(root, Check); Console.WriteLine($"Completed {count} detection checks."); return; }
    if (args is [_, "--feature-checks"]) { FeatureChecks.Run(root, catalog, Check); Console.WriteLine($"Completed {count} feature checks."); return; }
    if (args is [_, "--seed-feature-restart", var seedKey, var seedStates]) { FeatureRestartChecks.Seed(catalog, root, seedKey, seedStates); return; }
    if (args is [_, "--feature-restart-fixture"]) { FeatureRestartChecks.Run(root, Check); Console.WriteLine($"Completed {count} feature restart checks."); return; }
    if (args is [_, "--registry-fixture"]) { RegistryTweakChecks.Run(root, Check, Reject); Console.WriteLine($"Completed {count} native registry checks."); return; }
    if (args is [_, "--windows-default-fixture"]) { RegistryTweakChecks.WindowsDefaults(root, repo, catalog, Check, Reject); Console.WriteLine($"Completed {count} Windows default checks."); return; }
    catalog.Validate();
    Check(catalog.Settings.Select(item => item.Id).Distinct().Count() == catalog.Settings.Length, "Catalog setting identities are unique");
    var store = Fresh("shared"); var engine = new TweakEngine(catalog, store);
    var first = Preview(engine, "first", [.. Show(), .. Show()]);
    Check(first.Plan.Changes.Length == 1 && first.Plan.Selections.Length == 1, "Duplicate source selections become one Windows value change");
    engine.Apply(first.Path, first.Hash);
    Check(Dword(store, extension) == 0 && Fixture("shared").Writes == 1, "Apply writes the requested DWORD once");
    Apply(engine, "second", Show());
    Check(Fixture("shared").Writes == 1 && store.ReadState()!.Profiles.Length == 2, "A second preset shares the setting without replacing its original snapshot");
    Apply(engine, "first", []);
    Check(Dword(store, extension) == 0 && Fixture("shared").Writes == 1, "Restoring one preset preserves a setting still needed by another");
    Apply(engine, "second", []);
    Check(!store.Read(extension).KeyExists && Fixture("shared").Keys.Count == 0 && Fixture("shared").Writes == 2, "Last owner restores an absent value and its originally absent keys");
    engine.Apply(first.Path, first.Hash);
    Check(Fixture("shared").Writes == 2 && store.ReadState()!.Profiles.Length == 0, "Retrying an old committed apply cannot resurrect a restored profile");

    var aliasDefinition = new TweakDefinition("explorer.alias", "File extensions alias", "Fixture", "Same target through another source", 10240, 26200, ["*"], "none",
        [new("show", "Show", [new(extension with { KeyPath = extension.KeyPath.ToUpperInvariant(), ValueName = "hidefileext", View = "Registry32" }, 0)])], [new("Roo Industries", "fixture", "exact target")]);
    var aliasCatalog = catalog with { Settings = [.. catalog.Settings, aliasDefinition] };
    store = Fresh("aliases"); engine = new(aliasCatalog, store);
    var aliases = Preview(engine, "one", [.. Show(), new("explorer.alias", "show")]);
    Check(aliases.Plan.Changes.Length == 1 && aliases.Plan.Profiles[0].Claims.Length == 2, "Distinct source controls share one canonical registry resource");
    engine.Apply(aliases.Path, aliases.Hash);
    Check(Fixture("aliases").Writes == 1 && Dword(store, extension) == 0, "Cross-source aliases produce one actual fixture write");

    store = Fresh("conflict"); engine = new(catalog, store);
    Apply(engine, "one", Show());
    var before = OperationFiles.HashFile(Path.Combine(root, "conflict.json"));
    Reject(() => engine.Preview("two", [new("explorer.file-extensions", "hide")]), "Conflicting presets are rejected before any write");
    string? conflictMessage = null; try { engine.Preview("two", [new("explorer.file-extensions", "hide")]); } catch (InvalidDataException error) { conflictMessage = error.Message; }
    Check(conflictMessage == "Your \"one\" profile already sets " + catalog.Settings.Single(setting => setting.Id == "explorer.file-extensions").Name + " to a different choice. Pick the same choice, or restore that profile first.", "A conflict with another profile names that profile and the setting");
    Check(OperationFiles.HashFile(Path.Combine(root, "conflict.json")) == before, "Conflict leaves data and recovery state unchanged");
    Reject(() => engine.Preview("one", [.. Show(), new("explorer.file-extensions", "hide")]), "Contradictory choices inside one request are rejected");
    Reject(() => engine.Preview("one", [new("unknown", "show")]), "Unknown setting IDs cannot inject registry targets");
    Apply(engine, "one", [new("explorer.file-extensions", "hide")]);
    Check(Dword(store, extension) == 1, "Replacing one profile can change its own choice");
    Apply(engine, "one", []);
    Check(!store.Read(extension).KeyExists, "Replacing choices retains the first original snapshot");

    store = Fresh("types"); engine = new(catalog, store);
    var original = new RegistryValueData("HideFileExt", 1, Encoding.Unicode.GetBytes("original\0"));
    Put("types", extension, original);
    Apply(engine, "one", Show()); Apply(engine, "one", []);
    Check(store.Read(extension).KeyExists && RegistryNative.SameValue(store.Read(extension).Value!, original), "Restore preserves exact prior type and raw bytes, not a preset default");
    Put("types", extension, new("HideFileExt", 4, BitConverter.GetBytes(0u)));
    var writes = Fixture("types").Writes;
    Apply(engine, "same", Show()); Apply(engine, "same", []);
    Check(Fixture("types").Writes == writes, "An already configured setting is not written again on apply or restore");

    store = Fresh("drift"); engine = new(catalog, store);
    var reviewed = Preview(engine, "one", Show());
    Put("drift", extension, new("HideFileExt", 4, BitConverter.GetBytes(7u)));
    Reject(() => engine.Apply(reviewed.Path, reviewed.Hash), "A changed current value invalidates the review");
    Check(Dword(store, extension) == 7 && store.ReadState() is null, "Review rejection preserves the intervening external value");
    Apply(engine, "one", Show());
    Put("drift", extension, new("HideFileExt", 4, BitConverter.GetBytes(9u)));
    var released = Preview(engine, "one", []);
    Check(released.Plan.Changes.Length == 0 && released.Plan.LeftAsChanged.SequenceEqual(new[] { "explorer.file-extensions" }), "Restore reports a setting changed outside Roo Industries instead of overwriting it");
    engine.Apply(released.Path, released.Hash);
    Check(Dword(store, extension) == 9 && store.ReadState()!.Profiles.Length == 0 && store.ReadState()!.Held.Length == 0, "Restore leaves the outside value and releases the profile instead of blocking it forever");

    void Drop(string name, RegistryAddress address)
    {
        var fixture = Fixture(name);
        fixture.Keys.Remove(("\\REGISTRY\\USER\\" + fixture.Context.Owner.UserSid + "\\" + address.KeyPath).ToUpperInvariant());
        OperationFiles.Write(Path.Combine(root, name + ".json"), fixture);
    }
    store = Fresh("windows-removed"); engine = new(catalog, store);
    Apply(engine, "one", Show()); Apply(engine, "other", [new("explorer.hidden-files", "show")]);
    Drop("windows-removed", extension);
    writes = Fixture("windows-removed").Writes;
    var removed = Preview(engine, "one", []);
    Check(removed.Plan.Changes.Length == 0 && removed.Plan.LeftAsChanged.Length == 0, "Restore treats a key Windows deleted back to its original absence as already restored");
    engine.Apply(removed.Path, removed.Hash);
    Check(!store.Read(extension).KeyExists && store.ReadState()!.Profiles.Single().Id == "other" && Fixture("windows-removed").Writes == writes, "Restoring after Windows removed the key writes nothing and releases only that profile");

    store = Fresh("windows-reset"); engine = new(catalog, store);
    Put("windows-reset", extension, new("HideFileExt", 4, BitConverter.GetBytes(1u)));
    Apply(engine, "one", Show()); Apply(engine, "same", Show());
    Put("windows-reset", extension, new("HideFileExt", 4, BitConverter.GetBytes(1u)));
    writes = Fixture("windows-reset").Writes;
    Apply(engine, "one", []);
    Check(Dword(store, extension) == 1 && store.ReadState()!.Profiles.Single().Id == "same" && Fixture("windows-reset").Writes == writes, "Restoring one owner of a setting Windows reset writes nothing and keeps the other owner");
    var sameRestore = Preview(engine, "same", []);
    Check(sameRestore.Plan.Changes.Length == 0 && sameRestore.Plan.LeftAsChanged.Length == 0, "A setting Windows put back to its original is not reported as changed");
    engine.Apply(sameRestore.Path, sameRestore.Hash);
    Check(Dword(store, extension) == 1 && store.ReadState()!.Profiles.Length == 0 && Fixture("windows-reset").Writes == writes, "The last owner of a setting Windows reset releases it without writing");

    store = Fresh("shared-drift"); engine = new(catalog, store);
    Apply(engine, "one", Show()); Apply(engine, "two", Show());
    Put("shared-drift", extension, new("HideFileExt", 4, BitConverter.GetBytes(9u)));
    var firstShared = Preview(engine, "one", []);
    Check(firstShared.Plan.Changes.Length == 0 && firstShared.Plan.LeftAsChanged.SequenceEqual(new[] { "explorer.file-extensions" }), "Two owners of a drifted setting do not block each other's restore");
    engine.Apply(firstShared.Path, firstShared.Hash);
    Apply(engine, "two", []);
    Check(Dword(store, extension) == 9 && store.ReadState()!.Profiles.Length == 0 && store.ReadState()!.Held.Length == 0, "Both owners of a drifted setting can be restored and the outside value stays");

    store = Fresh("reapply"); engine = new(catalog, store);
    Apply(engine, "one", Show());
    Put("reapply", extension, new("HideFileExt", 4, BitConverter.GetBytes(9u)));
    var again = Preview(engine, "one", Show());
    Check(again.Plan.Changes.Length == 1 && again.Plan.LeftAsChanged.Length == 0, "Re-applying a setting Windows changed shows the write in the review");
    engine.Apply(again.Path, again.Hash);
    Check(Dword(store, extension) == 0, "Re-applying a setting Windows changed writes the chosen value again");
    Put("reapply", extension, new("HideFileExt", 4, BitConverter.GetBytes(9u)));
    Apply(engine, "one", [new("explorer.file-extensions", "hide")]);
    Check(Dword(store, extension) == 1, "Switching a setting Windows changed to another choice writes that choice");
    Apply(engine, "one", []);
    Check(!store.Read(extension).KeyExists && store.ReadState()!.Profiles.Length == 0, "Restore after re-applying returns the true original");

    void RejectPair(Action operation, string name)
    {
        var refused = false;
        try { operation(); } catch (InvalidDataException error) when (error.Message.Contains("cannot be used together", StringComparison.Ordinal)) { refused = true; }
        Check(refused, name);
    }
    var overlays = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesIncompatibleFixture", "value", "DisableOverlays");
    var testMode = overlays with { ValueName = "OverlayTestMode" };
    TweakDefinition Pairing(string id, RegistryAddress address, uint value) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
        [new("set", "Set", [new(address, value)]), new("reset", "Remove", [new(address, null, (RegistryValueData?)null)])], [new("Fixture", "fixture", "incompatible pair")]);
    var pairSettings = new[] { Pairing("overlays", overlays, 1), Pairing("test-mode", testMode, 5), Pairing("other", overlays with { ValueName = "Other" }, 1) };
    var rule = new TweakIncompatibility([new("overlays", "set"), new("test-mode", "set")], "Together they crash games.");
    var paired = new TweakCatalog(1, "pairs", pairSettings, [], [rule]);
    store = Fresh("pairs"); engine = new(paired, store);
    RejectPair(() => engine.Preview("both", [new("overlays", "set"), new("test-mode", "set")]), "One request cannot apply two settings that are not allowed together");
    Apply(engine, "first", [new("overlays", "set")]);
    RejectPair(() => engine.Preview("second", [new("test-mode", "set")]), "A second profile cannot complete a combination that is not allowed");
    Check(store.ReadState()!.Profiles.Single().Id == "first" && Dword(store, testMode) is null, "A refused combination changes nothing");
    Apply(engine, "first", []);
    Put("pairs", testMode, new("OverlayTestMode", 4, BitConverter.GetBytes(5u)));
    RejectPair(() => engine.Preview("first", [new("overlays", "set")]), "A setting is refused when Windows already has the other half of a combination that is not allowed");
    Put("pairs", testMode, new("OverlayTestMode", 4, BitConverter.GetBytes(0u)));
    Apply(engine, "first", [new("overlays", "set")]);
    Check(Dword(store, overlays) == 1, "Either half alone still applies");
    Apply(engine, "first", []);
    store = Fresh("pairs-legacy"); engine = new(new TweakCatalog(1, "pairs", pairSettings, []), store);
    Apply(engine, "old-a", [new("overlays", "set")]); Apply(engine, "old-b", [new("test-mode", "set")]);
    engine = new(new TweakCatalog(1, "pairs", pairSettings, [], [rule]), store);
    Apply(engine, "unrelated", [new("other", "set")]);
    Apply(engine, "old-a", []);
    Check(Dword(store, overlays) is null && Dword(store, testMode) == 5 && store.ReadState()!.Profiles.Select(profile => profile.Id).Order().SequenceEqual(new[] { "old-b", "unrelated" }),
        "A combination applied by an older version never blocks undo or unrelated changes");
    Reject(() => new TweakCatalog(1, "pairs", pairSettings, [new("bad", "Bad", [new("overlays", "set"), new("test-mode", "set")])], [rule]).Validate(), "A preset cannot combine settings that are not allowed together");
    store = Fresh("pairs-held"); engine = new(paired, store);
    Put("pairs-held", testMode, new("OverlayTestMode", 4, BitConverter.GetBytes(5u)));
    Apply(engine, "a", [new("test-mode", "reset")]);
    RejectPair(() => engine.Preview("a", [new("overlays", "set")]), "Swapping a profile's choice is refused when the swap would put back the other half of a combination that is not allowed");
    RejectPair(() => engine.Preview("b", [new("overlays", "set")]), "A second profile is refused when undoing the first would bring back the other half of the combination");
    Check(Dword(store, testMode) is null && Dword(store, overlays) is null, "Refused combinations leave both values untouched");
    store = Fresh("pairs-compat"); engine = new(paired, store);
    Put("pairs-compat", overlays, new("DisableOverlays", 4, BitConverter.GetBytes(1u)));
    Apply(engine, "compat", [new("test-mode", "set"), new("overlays", "reset")]);
    Check(Dword(store, testMode) == 5 && Dword(store, overlays) is null, "A choice set that removes one half of a combination is allowed even when that half is already set");
    store = Fresh("pairs-resend"); engine = new(paired, store);
    Apply(engine, "mine", [new("overlays", "set")]);
    Put("pairs-resend", testMode, new("OverlayTestMode", 4, BitConverter.GetBytes(5u)));
    Apply(engine, "mine", [new("overlays", "set"), new("other", "set")]);
    Check(Dword(store, overlays with { ValueName = "Other" }) == 1 && store.ReadState()!.Profiles.Single().Selections.Length == 2, "Re-sending a held choice does not block unrelated changes after another tool set the other half");
    store = Fresh("pairs-shared"); engine = new(paired, store);
    Put("pairs-shared", overlays, new("DisableOverlays", 4, BitConverter.GetBytes(1u)));
    Apply(engine, "a", [new("test-mode", "set"), new("overlays", "reset")]);
    RejectPair(() => engine.Preview("b", [new("test-mode", "set")]), "A second profile cannot share one half when undoing the first would bring back the other half");
    Apply(engine, "a", []);
    Check(Dword(store, overlays) == 1 && Dword(store, testMode) is null && store.ReadState() is { Profiles.Length: 0 }, "Undoing the compatibility choice returns the PC to its original values");
    store = Fresh("pairs-preexisting"); engine = new(paired, store);
    Put("pairs-preexisting", overlays, new("DisableOverlays", 4, BitConverter.GetBytes(1u)));
    Put("pairs-preexisting", testMode, new("OverlayTestMode", 4, BitConverter.GetBytes(5u)));
    Apply(engine, "fix", [new("overlays", "reset")]);
    Check(Dword(store, overlays) is null && Dword(store, testMode) == 5, "A PC that already had both halves can remove one of them");
    Apply(engine, "fix", []);
    Check(Dword(store, overlays) == 1 && Dword(store, testMode) == 5, "Undo returns a PC that already had both halves to exactly what it had");
    var choices = new TweakChoiceStore(Path.Combine(root, "pair-choices.json"));
    RejectPair(() => choices.Save(paired, "saved", [new("overlays", "set"), new("test-mode", "set")], null), "Saved choices cannot hold a combination that is not allowed");
    var mpo = catalog.Incompatible?.SingleOrDefault(item => item.Selections.Select(selection => selection.SettingId).Order().SequenceEqual(new[] { "windows.afc9a1a923dc6c65", "windows.b3ed2a21f895b89b" }));
    Check(mpo is not null && catalog.Presets.All(preset => !mpo.Selections.All(preset.Selections.Contains)), "The shipped catalog refuses the MPO combination that crashed CS2 and no preset applies it");

    store = Fresh("independent"); engine = new(catalog, store);
    Apply(engine, "a", Show()); Apply(engine, "b", [new("explorer.hidden-files", "show")]);
    Put("independent", extension, new("HideFileExt", 4, BitConverter.GetBytes(9u)));
    Apply(engine, "b", []);
    Check(Dword(store, extension) == 9 && store.Read(extension with { ValueName = "Hidden" }).Value is null && store.ReadState()!.Profiles.Single().Id == "a",
        "An unrelated drifted setting cannot prevent restoring another profile");

    store = Fresh("stale"); engine = new(catalog, store);
    var a = Preview(engine, "a", Show()); var b = Preview(engine, "b", Show());
    engine.Apply(a.Path, a.Hash);
    Reject(() => engine.Apply(b.Path, b.Hash), "Stale state revision cannot overwrite another profile change");
    var altered = Preview(engine, "c", Show());
    File.AppendAllText(altered.Path, " ");
    Reject(() => engine.Apply(altered.Path, altered.Hash), "Review hash binds the exact preview bytes");
    var foreign = Fresh("foreign");
    Reject(() => new TweakEngine(catalog, foreign).Apply(a.Path, a.Hash), "A fixture review cannot cross store identity boundaries");

    store = Fresh("catalog"); engine = new(catalog, store);
    var old = Preview(engine, "one", Show());
    var changed = catalog with { Version = "changed" };
    Reject(() => new TweakEngine(changed, store).Apply(old.Path, old.Hash), "Changed catalog definitions require a new review");
    engine.Apply(old.Path, old.Hash);
    var without = catalog with { Settings = catalog.Settings.Where(item => item.Id != "explorer.file-extensions").ToArray(), Presets = [] };
    Apply(new(without, store), "one", []);
    Check(!store.Read(extension).KeyExists, "Stored claims allow restoration after a setting leaves the current catalog");

    store = Fresh("other-data"); engine = new(catalog, store);
    Apply(engine, "one", Show());
    Put("other-data", extension with { ValueName = "OtherValue" }, new("OtherValue", 4, BitConverter.GetBytes(88u)));
    var restored = Apply(engine, "one", []);
    Check(store.Read(extension).Value is null && Dword(store, extension with { ValueName = "OtherValue" }) == 88 && restored.Notices.Length > 0,
        "Key cleanup preserves unrelated values added after application");

    store = Fresh("metadata"); engine = new(catalog, store); Apply(engine, "one", Show());
    var file = Fixture("metadata"); var native = store.Read(extension).NativeKey.ToUpperInvariant();
    file.Keys[native] = file.Keys[native] with { Metadata = "changed permissions" }; OperationFiles.Write(Path.Combine(root, "metadata.json"), file);
    restored = Apply(engine, "one", []);
    Check(store.Read(extension).KeyExists && store.Read(extension).Value is null && restored.Notices.Length > 0, "Key cleanup preserves changed permissions");

    var injectedPath = Path.Combine(root, "failure.json"); FileTweakStore.Create(injectedPath);
    var failing = new FailingStore(injectedPath); engine = new(catalog, failing);
    var fault = Preview(engine, "one", [.. Show(), new("explorer.hidden-files", "show")]);
    before = OperationFiles.HashFile(injectedPath);
    Reject(() => engine.Apply(fault.Path, fault.Hash), "Failure after preparing multiple writes aborts the whole commit");
    Check(OperationFiles.HashFile(injectedPath) == before, "Failed commit changes neither data nor recovery state");
    failing.Fail = false; engine.Apply(fault.Path, fault.Hash);
    Check(Fixture("failure").Writes == 2, "Retry after aborted commit applies the complete plan");
    var lostPath = Path.Combine(root, "lost-ack.json"); FileTweakStore.Create(lostPath);
    var lost = new LostReplyStore(lostPath); engine = new(catalog, lost); var retry = Preview(engine, "one", Show());
    Reject(() => engine.Apply(retry.Path, retry.Hash), "An acknowledgement can fail after a committed transaction");
    new TweakEngine(catalog, new FileTweakStore(lostPath)).Apply(retry.Path, retry.Hash);
    Check(Fixture("lost-ack").Writes == 1, "Restart after lost acknowledgement reads the receipt without repeating writes");

    var oldWindows = FileTweakStore.Create(Path.Combine(root, "old-windows.json"), 19045);
    Reject(() => new TweakEngine(catalog, oldWindows).Preview("one", [new("explorer.taskbar-alignment", "left")]), "Windows 11-only setting rejects Windows 10");
    var home = FileTweakStore.Create(Path.Combine(root, "home.json"), 26200, "Core");
    Reject(() => new TweakEngine(catalog, home).Preview("one", [new("privacy.advertising-id-policy", "blocked")]), "Unsupported policy edition does not appear executable");
    var future = FileTweakStore.Create(Path.Combine(root, "future.json"), 99999);
    Reject(() => new TweakEngine(catalog, future).Preview("one", Show()), "An unreviewed future Windows build requires catalog verification");

    foreach (var property in new[] { "context", "expected", "held", "selections", "beforeRevision" })
    {
        var json = JsonNode.Parse(File.ReadAllText(a.Path))!.AsObject(); json.Remove(property);
        var path = Path.Combine(root, "missing-" + property + ".json"); File.WriteAllText(path, json.ToJsonString());
        Reject(() => new TweakEngine(catalog, new FileTweakStore(Path.Combine(root, "stale.json"))).Apply(path, OperationFiles.HashFile(path)), "Missing " + property + " stays unknown rather than inheriting approval");
    }
    var incomplete = JsonNode.Parse(JsonSerializer.Serialize(catalog, OperationFiles.Json))!;
    incomplete["settings"]![0]!["options"]![0]!["changes"]![0]!.AsObject().Remove("dword");
    Reject(() => JsonSerializer.Deserialize<TweakCatalog>(incomplete.ToJsonString(), OperationFiles.Json), "Missing nullable desired value cannot silently become a deletion");
    store = Fresh("upgrade"); engine = new(catalog, store); Apply(engine, "one", Show());
    var upgrade = Fixture("upgrade");
    OperationFiles.Write(Path.Combine(root, "upgrade.json"), upgrade with { Context = upgrade.Context with { WindowsBuild = 99999 } });
    var upgraded = new FileTweakStore(Path.Combine(root, "upgrade.json"));
    Apply(new(catalog, upgraded), "one", []);
    Check(upgraded.Read(extension).Value is null, "Restoration survives a Windows build change even when new tweaks are unsupported");

    bool ConcurrentApply(Func<TweakApplyResult> apply)
    {
        try { return !apply().Replayed; }
        catch (IOException) { return false; }
        catch (InvalidDataException error) when (error.Message is "The fixture changed after review." or "The reviewed settings or their current values changed. Review again.") { return false; }
    }
    store = Fresh("parallel"); engine = new(catalog, store);
    var parallel = Preview(engine, "one", Show());
    using (var barrier = new Barrier(2))
    {
        var outcomes = Enumerable.Range(0, 2).Select(_ => Task.Run(() =>
        {
            barrier.SignalAndWait();
            return ConcurrentApply(() => new TweakEngine(catalog, new FileTweakStore(Path.Combine(root, "parallel.json"))).Apply(parallel.Path, parallel.Hash));
        })).ToArray();
        Task.WaitAll(outcomes);
        Check(outcomes.Count(task => task.Result) == 1 && Fixture("parallel").Writes == 1, "Concurrent requests cannot apply the same reviewed operation twice");
    }
    Check(!ConcurrentApply(() => new(store.Commit(parallel.Plan, parallel.Hash), true, false)) && Fixture("parallel").Writes == 1, "A losing commit after the winner releases its lock is an expected stale rejection");
    Reject(() => ConcurrentApply(() => throw new InvalidDataException("Unexpected review failure")), "Unexpected invalid review errors cannot be mistaken for concurrent stale rejection");
    engine.Apply(parallel.Path, parallel.Hash);
    Check(Fixture("parallel").Writes == 1, "Retry after concurrent contention retains one commit and one original snapshot");
    var bounded = new TweakEngine(catalog, store).Preview("bounded", Show());
    var invalidRead = bounded.Expected[0] with { KeyExists = false, MissingKeys = [extension.KeyPath] };
    if (invalidRead.Value is null) invalidRead = invalidRead with { Value = new("HideFileExt", 4, BitConverter.GetBytes(0u)) };
    Reject(invalidRead.Validate, "A favorable value cannot override a missing-key signal");
    var oversized = bounded.Expected[0] with { KeyExists = true, MissingKeys = [], Value = new("HideFileExt", 3, new byte[65537]) };
    Reject(oversized.Validate, "Oversized originals cannot make the recovery receipt unreadable");
    var duplicate = Encoding.UTF8.GetBytes("{\"schemaVersion\":1,\"schemaVersion\":1}");
    Reject(() => OperationFiles.Deserialize<TweakState>(duplicate), "Duplicate properties are rejected in registry-backed recovery data");
    CompositionChecks.Run(root, Check, Reject);
    ControlChecks.Run(root, Check, Reject);
    FeatureChecks.Run(root, catalog, Check);
    DetectChecks.Run(root, Check);
    SelectionChecks.Run(root, Check, Reject);
    PowerCompositionChecks.Run(root, Check, Reject);
    HostsChecks.Run(root, Check, Reject);
    CatalogIntegrationChecks.Run(root, catalog, Check, Reject);
    SavedChoiceChecks.Run(root, catalog, Check, Reject);
    MitigationChecks.Run(Check, Reject);
    RestorePointChecks.Layout(Check);
    Console.WriteLine($"Completed {count} tweak checks.");
}
finally { Directory.Delete(root, true); }

sealed class FailingStore(string path) : FileTweakStore(path)
{
    public bool Fail { get; set; } = true;
    protected override void BeforeCommit(TweakFixture fixture) { if (Fail) throw new IOException("Controlled pre-commit failure."); }
}
sealed class LostReplyStore(string path) : FileTweakStore(path)
{
    protected override void AfterCommit() => throw new IOException("Controlled lost acknowledgement.");
}
