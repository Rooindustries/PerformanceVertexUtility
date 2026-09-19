using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.Optimizer;

if (args is ["--service-probe"]) { ServiceProbe.Start(); return; }
if (args is ["--timer-worker", var timerLaunch]) { TimerControl.RunWorker(timerLaunch); return; }
if (args is ["--timer-autostart", var timerRoot]) { TimerControl.RunAutostart(timerRoot); return; }
if (args is ["--timer-detached-start", var detachedRoot]) { TimerChecks.DetachedStart(detachedRoot); return; }
if (args is ["--timer-detached-stop", var stopRoot]) { TimerChecks.DetachedStop(stopRoot); return; }
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
    if (args is [_, "--power-fixture"]) { PowerChecks.Run(root, Check); Console.WriteLine($"Completed {count} native power checks."); return; }
    if (args is [_, "--file-controls-fixture"]) { NativeFileControlChecks.Run(Check, Reject); Console.WriteLine($"Completed {count} native file-control checks."); return; }
    if (args is [_, "--hosts-fixture"]) { HostsChecks.Native(Check, Reject); Console.WriteLine($"Completed {count} native hosts checks."); return; }
    if (args is [_, "--timer-fixture"]) { TimerChecks.Native(Check); Console.WriteLine($"Completed {count} native timer checks."); return; }
    if (args is [_, "--power-plan-fixture"]) { PowerPlanChecks.Native(Check, Reject); Console.WriteLine($"Completed {count} native power-plan checks."); return; }
    if (args is [_, "--timer-startup-fixture"]) { TimerStartupChecks.Native(Check); Console.WriteLine($"Completed {count} native startup checks."); return; }
    if (args is [_, "--download-blocker-fixture"]) { DownloadBlockerChecks.Native(Check); Console.WriteLine($"Completed {count} native download blocker checks."); return; }
    if (args is [_, "--catalog-integration"]) { CatalogIntegrationChecks.Run(root, catalog, Check, Reject); Console.WriteLine($"Completed {count} catalog integration checks."); return; }
    if (args is [_, "--recover-controls-fixture"]) { NativeControlChecks.RecoverFixture(); return; }
    if (args is [_, "--controls-fixture"]) { NativeControlChecks.Run(root, Check, Reject); Console.WriteLine($"Completed {count} native control checks."); return; }
    if (args is [_, "--registry-fixture"]) { RegistryTweakChecks.Run(root, Check, Reject); Console.WriteLine($"Completed {count} native registry checks."); return; }
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
    Reject(() => engine.Preview("one", []), "Restore detects external drift instead of overwriting it");
    Check(Dword(store, extension) == 9 && store.ReadState()!.Profiles.Length == 1, "Drift retains recovery ownership for later reconciliation");

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
    SelectionChecks.Run(root, Check, Reject);
    PowerCompositionChecks.Run(root, Check, Reject);
    HostsChecks.Run(root, Check, Reject);
    CatalogIntegrationChecks.Run(root, catalog, Check, Reject);
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
