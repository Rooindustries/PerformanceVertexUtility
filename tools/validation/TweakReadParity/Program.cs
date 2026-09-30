using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using RooIndustries.Optimizer;

var repo = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
var mode = args.Length > 2 ? args[2] : "parity";
var delay = args.Length > 3 ? int.Parse(args[3]) : 1500;
Directory.CreateDirectory(output);
var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend", "catalogs", "windows-tweaks.json"));
catalog.Validate();
catalog = CustomTweaks.Merge(catalog);
var addresses = catalog.Settings.SelectMany(setting => setting.Options).SelectMany(option => option.Controls ?? []).Select(control => control.Address).Distinct().ToArray();
var store = new WindowsControlStore();
var failures = 0;

string Describe((TweakControlRead? Read, Exception? Error) result) =>
    result.Error is { } error ? "error " + error.GetType().Name + ": " + error.Message : JsonSerializer.Serialize(result.Read, OperationFiles.Json);
string Name(ControlAddress address) => address.Kind + "|" + address.Target + "|" + address.Property;
Dictionary<string, string> Single(Dictionary<string, long> timings)
{
    var results = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var address in addresses)
    {
        var watch = Stopwatch.StartNew();
        (TweakControlRead?, Exception?) result;
        try { result = (store.Read(address), null); } catch (Exception error) { result = (null, error); }
        timings[address.Kind] = timings.GetValueOrDefault(address.Kind) + watch.ElapsedMilliseconds;
        results[Name(address)] = Describe(result);
    }
    return results;
}
Dictionary<string, string> Batch() => store.ReadMany(addresses).ToDictionary(pair => Name(pair.Key), pair => Describe(pair.Value), StringComparer.Ordinal);
void Save(string name, object value) => File.WriteAllText(Path.Combine(output, name), JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
void Report(string check, bool passed, string detail)
{
    Console.WriteLine((passed ? "PASS " : "FAIL ") + check + " :: " + detail);
    if (!passed) failures++;
}
(Dictionary<string, string> Result, long Ms) Timed(Func<Dictionary<string, string>> read)
{
    var watch = Stopwatch.StartNew();
    var result = read();
    return (result, watch.ElapsedMilliseconds);
}
HashSet<int> PowerShells() => Process.GetProcessesByName("powershell").Select(process => process.Id).ToHashSet();

Console.WriteLine("Control addresses: " + addresses.Length + " (" + string.Join(", ", addresses.GroupBy(address => address.Kind).Select(group => group.Key + "=" + group.Count())) + ")");
switch (mode)
{
    case "parity":
    {
        var timings = new Dictionary<string, long>(StringComparer.Ordinal);
        var single1 = Timed(() => Single(timings)); var batch1 = Timed(Batch);
        var single2 = Timed(() => Single(new())); var batch2 = Timed(Batch);
        Console.WriteLine("Per-address reads ms: " + single1.Ms + ", " + single2.Ms + "; batched ms: " + batch1.Ms + ", " + batch2.Ms);
        Console.WriteLine("Per-address ms by kind: " + string.Join(", ", timings.OrderByDescending(pair => pair.Value).Select(pair => pair.Key + "=" + pair.Value)));
        var unstable = addresses.Select(Name).Where(name => single1.Result[name] != single2.Result[name] || batch1.Result[name] != batch2.Result[name]).ToArray();
        var different = addresses.Select(Name).Where(name => !unstable.Contains(name) && single1.Result[name] != batch1.Result[name]).ToArray();
        Save("parity-single-1.json", single1.Result); Save("parity-batch-1.json", batch1.Result); Save("parity-single-2.json", single2.Result); Save("parity-batch-2.json", batch2.Result);
        Report("every stable control read is identical per-address and batched", different.Length == 0, addresses.Length + " addresses, " + different.Length + " different, " + unstable.Length + " changed between rounds: " + string.Join("; ", different.Concat(unstable)));
        Report("batched reads resolve every address", batch1.Result.Count == addresses.Length && batch2.Result.Count == addresses.Length, batch1.Result.Count + "/" + addresses.Length);
        Console.WriteLine("Errors (same in both paths): " + string.Join(" | ", single1.Result.Where(pair => pair.Value.StartsWith("error ", StringComparison.Ordinal)).Select(pair => pair.Key + " => " + pair.Value)));
        break;
    }
    case "timing":
    {
        foreach (var group in addresses.GroupBy(address => address.Kind is "dns-over-https" or "firewall-blocklist" or "firewall-profile" or "network-adapter" or "boot-configuration" or "defender" or "filesystem" or "memory" or "reserved-storage" or "device-power" or "teredo" ? "powershell" : address.Kind == "windows-features" ? "dism" : "other native"))
        {
            var watch = Stopwatch.StartNew();
            store.ReadMany(group.ToArray());
            Console.WriteLine(group.Key + " (" + group.Count() + " addresses) ms=" + watch.ElapsedMilliseconds);
        }
        break;
    }
    case "chunk":
    {
        var many = Enumerable.Range(0, 400).Select(index => index % 50 == 7 ? new ControlAddress("dns-over-https", "not-an-address-" + index, "configuration") : index % 50 == 9 ? new ControlAddress("teredo", "other", "type") : new ControlAddress("dns-over-https", "10.254." + index / 250 + "." + (index % 250 + 1), "configuration")).ToArray();
        var watch = Stopwatch.StartNew();
        var batched = store.ReadMany(many);
        var batchMs = watch.ElapsedMilliseconds;
        var sample = many.Where((_, index) => index % 40 == 0 || index % 50 is 7 or 9).ToArray();
        var mismatches = sample.Where(address =>
        {
            (TweakControlRead?, Exception?) single;
            try { single = (store.Read(address), null); } catch (Exception error) { single = (null, error); }
            return Describe(single) != Describe(batched[address]);
        }).Select(Name).ToArray();
        var request = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new { action = "read-batch", addresses = many }, OperationFiles.Json)).Length;
        var failing = sample.Where(address => batched[address].Error is not null).Select(address => Name(address) + " => " + Describe(batched[address])).ToArray();
        Report("400 PowerShell-kind addresses (request " + request + " base64 chars) are split across helper runs and match per-address reads, including failing reads",
            batched.Count == many.Distinct().Count() && mismatches.Length == 0 && request > 24000 && failing.Length == 16, "batched ms=" + batchMs + ", resolved " + batched.Count + ", sample " + sample.Length + ", mismatches: " + string.Join("; ", mismatches) + "; failures: " + string.Join(" | ", failing.Take(3)));
        break;
    }
    case "phases":
    {
        var watch = Stopwatch.StartNew();
        var fresh = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend", "catalogs", "windows-tweaks.json"));
        var readMs = watch.ElapsedMilliseconds; watch.Restart();
        fresh.Validate(); fresh = CustomTweaks.Merge(fresh);
        var validateMs = watch.ElapsedMilliseconds; watch.Restart();
        var engine = new TweakEngine(fresh, new RegistryTweakStore());
        var engineMs = watch.ElapsedMilliseconds; watch.Restart();
        var inspection = engine.Detect();
        var detectMs = watch.ElapsedMilliseconds; watch.Restart();
        var indented = JsonSerializer.Serialize(new { schemaVersion = 1, status = "completed", data = inspection }, OperationFiles.Json);
        var indentedMs = watch.ElapsedMilliseconds; watch.Restart();
        var compact = JsonSerializer.Serialize(new { schemaVersion = 1, status = "completed", data = inspection }, new JsonSerializerOptions(OperationFiles.Json) { WriteIndented = false });
        var compactMs = watch.ElapsedMilliseconds;
        Console.WriteLine("catalog read ms=" + readMs + " validate+merge ms=" + validateMs + " engine ms=" + engineMs + " detect ms=" + detectMs + " serialize indented ms=" + indentedMs + " (" + indented.Length + " chars) compact ms=" + compactMs + " (" + compact.Length + " chars)");
        break;
    }
    case "dism-parallel":
    {
        var dism = DismServicing.Native;
        string[] names = ["Microsoft-Hyper-V-All", "Microsoft-Hyper-V", "Microsoft-Hyper-V-Tools-All", "Microsoft-Hyper-V-Management-PowerShell", "Microsoft-Hyper-V-Hypervisor", "Microsoft-Hyper-V-Services", "Microsoft-Hyper-V-Management-Clients", "HypervisorPlatform", "VirtualMachinePlatform", "Recall", "Containers-DisposableClientVM"];
        string Query(uint session)
        {
            var parts = new List<string>();
            foreach (var name in names)
            {
                var parentsResult = dism.GetFeatureParents(session, name, out var parents);
                var stateResult = dism.GetFeatureState(session, name, out var state);
                parts.Add(name + ":" + parentsResult + ":" + string.Join("+", parents.Order(StringComparer.Ordinal)) + ":" + stateResult + ":" + state);
            }
            return string.Join("|", parts);
        }
        for (var round = 0; round < 3; round++)
        {
            Console.WriteLine("init=" + dism.Initialize());
            dism.OpenSession(out var first); dism.OpenSession(out var second);
            var watch = Stopwatch.StartNew();
            var sequentialFeatures = dism.GetFeatures(first, out var features1); var sequential = Query(first);
            var sequentialMs = watch.ElapsedMilliseconds; watch.Restart();
            (string Name, int State)[] features2 = [];
            var enumerate = Task.Run(() => dism.GetFeatures(first, out features2));
            var parallel = Query(second);
            var parallelFeatures = enumerate.GetAwaiter().GetResult();
            var parallelMs = watch.ElapsedMilliseconds;
            dism.CloseSession(first); dism.CloseSession(second); dism.Shutdown();
            Report("round " + round + " parallel DISM sessions return identical feature data", sequentialFeatures == 0 && parallelFeatures == 0 && sequential == parallel && features1.SequenceEqual(features2),
                "sequential ms=" + sequentialMs + " parallel ms=" + parallelMs + " features " + features1.Length + "/" + features2.Length);
        }
        break;
    }
    case "dism":
    {
        var timed = new TimedDism();
        var watch = Stopwatch.StartNew();
        WindowsFeatures.Read(addresses.Single(address => address.Kind == "windows-features"), timed);
        Console.WriteLine("windows-features read ms=" + watch.ElapsedMilliseconds + " :: " + string.Join(", ", timed.Timings.GroupBy(item => item.Name).Select(group => group.Key + " x" + group.Count() + "=" + group.Sum(item => item.Ms))));
        break;
    }
    case "detect":
    {
        string Detect(ITweakStore detectStore, out long ms)
        {
            var watch = Stopwatch.StartNew();
            var text = JsonSerializer.Serialize(new TweakEngine(catalog, detectStore).Detect(), OperationFiles.Json);
            ms = watch.ElapsedMilliseconds;
            return text;
        }
        var old1 = Detect(new PerAddressStore(new RegistryTweakStore()), out var oldMs1); var new1 = Detect(new RegistryTweakStore(), out var newMs1);
        var old2 = Detect(new PerAddressStore(new RegistryTweakStore()), out var oldMs2); var new2 = Detect(new RegistryTweakStore(), out var newMs2);
        File.WriteAllText(Path.Combine(output, "detect-old-1.json"), old1); File.WriteAllText(Path.Combine(output, "detect-new-1.json"), new1);
        File.WriteAllText(Path.Combine(output, "detect-old-2.json"), old2); File.WriteAllText(Path.Combine(output, "detect-new-2.json"), new2);
        Console.WriteLine("Detect ms old: " + oldMs1 + ", " + oldMs2 + "; new: " + newMs1 + ", " + newMs2);
        Report("Detect output identical (old per-address vs new batched)", old1 == new1 && old2 == new2, "round1 " + (old1 == new1) + ", round2 " + (old2 == new2) + ", old stable " + (old1 == old2) + ", new stable " + (new1 == new2) + ", bytes " + old1.Length);
        break;
    }
    case "kill":
    case "suspend":
    {
        var reference = Single(new());
        var before = PowerShells();
        var run = Task.Run(Batch);
        Thread.Sleep(delay);
        var started = PowerShells().Except(before).ToArray();
        Report("one control helper process found", started.Length == 1, string.Join(",", started));
        foreach (var id in started)
        {
            using var target = Process.GetProcessById(id);
            if (mode == "kill") target.Kill(); else NtSuspendProcess(target.Handle);
        }
        var watch = Stopwatch.StartNew();
        var result = run.GetAwaiter().GetResult();
        Console.WriteLine("Batch finished " + watch.ElapsedMilliseconds + " ms after the injected fault.");
        var affected = result.Where(pair => pair.Value != reference[pair.Key]).ToArray();
        var expected = mode == "kill" ? "Windows control helper exited" : "timed out after 120 seconds";
        Report("exactly the in-flight address failed with the helper error; every other address matches the per-address read", affected.Length == 1 && affected[0].Value.Contains(expected, StringComparison.Ordinal) && result.Count == reference.Count,
            string.Join(" | ", affected.Select(pair => pair.Key + " => " + pair.Value)));
        break;
    }
    default: throw new ArgumentException("Unknown mode.");
}
Console.WriteLine(failures == 0 ? "ALL PASS" : failures + " FAILED");
return failures == 0 ? 0 : 1;

[DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);

sealed class TimedDism : DismServicing
{
    private readonly DismServicing _inner = Native;
    public List<(string Name, long Ms)> Timings { get; } = [];
    private T Time<T>(string name, Func<T> call) { var watch = Stopwatch.StartNew(); var result = call(); Timings.Add((name, watch.ElapsedMilliseconds)); return result; }
    public override int Initialize() => Time("Initialize", _inner.Initialize);
    public override int OpenSession(out uint session) { uint opened = 0; var result = Time("OpenSession", () => _inner.OpenSession(out opened)); session = opened; return result; }
    public override int GetFeatures(uint session, out (string Name, int State)[] features) { (string, int)[] found = []; var result = Time("GetFeatures", () => _inner.GetFeatures(session, out found)); features = found; return result; }
    public override int GetFeatureParents(uint session, string feature, out string[] parents) { string[] found = []; var result = Time("GetFeatureParents", () => _inner.GetFeatureParents(session, feature, out found)); parents = found; return result; }
    public override int GetFeatureState(uint session, string feature, out int state) { var found = 0; var result = Time("GetFeatureState", () => _inner.GetFeatureState(session, feature, out found)); state = found; return result; }
    public override int EnableFeatures(uint session, string features) => throw new InvalidOperationException("Read-only.");
    public override int DisableFeatures(uint session, string features, bool removePayload) => throw new InvalidOperationException("Read-only.");
    public override int CloseSession(uint session) => Time("CloseSession", () => _inner.CloseSession(session));
    public override int Shutdown() => Time("Shutdown", _inner.Shutdown);
}

sealed class PerAddressStore(ITweakStore inner) : ITweakStore
{
    public TweakContext Context => inner.Context;
    public TweakState? ReadState() => inner.ReadState();
    public TweakRead Read(RegistryAddress address) => inner.Read(address);
    public TweakAssignment[] Resolve(TweakAssignment assignment) => inner.Resolve(assignment);
    public void CheckRequirement(string requirement) => inner.CheckRequirement(requirement);
    public TweakControlRead ReadControl(ControlAddress address) => inner.ReadControl(address);
    public TweakState Commit(TweakPlan plan, string reviewHash) => throw new InvalidOperationException("Read-only parity store.");
}
