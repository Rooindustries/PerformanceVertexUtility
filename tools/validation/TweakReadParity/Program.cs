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
Dictionary<string, string> Single()
{
    var results = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var address in addresses)
    {
        (TweakControlRead?, Exception?) result;
        try { result = (store.Read(address), null); } catch (Exception error) { result = (null, error); }
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
HashSet<int> PowerShells() => Process.GetProcessesByName("powershell").Select(process => { using (process) return (process.Id, Parent: ParentOf(process)); }).Where(item => item.Parent == Environment.ProcessId).Select(item => item.Id).ToHashSet();
string WithoutValue(string described)
{
    if (described.StartsWith("error ", StringComparison.Ordinal)) return described;
    var node = System.Text.Json.Nodes.JsonNode.Parse(described)!.AsObject();
    node.Remove("value");
    return node.ToJsonString();
}

Console.WriteLine("Control addresses: " + addresses.Length + " (" + string.Join(", ", addresses.GroupBy(address => address.Kind).Select(group => group.Key + "=" + group.Count())) + ")");
switch (mode)
{
    case "parity":
    {
        (string Kind, string Property, string Reason)[] volatileFields =
        [
            ("service", "running", "a trigger-start service can start or stop on its own between two reads"),
        ];
        string SingleNow(ControlAddress address)
        {
            try { return Describe((store.Read(address), null)); } catch (Exception error) { return Describe((null, error)); }
        }
        var mismatches = new List<string>(); var allowed = new List<string>(); var retried = 0; var compared = 0;
        for (var round = 1; round <= 3; round++)
        {
            var watch = Stopwatch.StartNew();
            var batch = store.ReadMany(addresses);
            var batchMs = watch.ElapsedMilliseconds;
            Save("parity-batch-" + round + ".json", batch.ToDictionary(pair => Name(pair.Key), pair => Describe(pair.Value)));
            var singles = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var address in addresses)
            {
                compared++;
                var batched = batch.TryGetValue(address, out var found) ? Describe(found) : "missing from batch";
                var single = SingleNow(address);
                for (var attempt = 2; attempt <= 3 && single != batched; attempt++) { retried++; single = SingleNow(address); }
                singles[Name(address)] = single;
                if (single == batched) continue;
                var rule = volatileFields.FirstOrDefault(field => field.Kind == address.Kind && field.Property == address.Property);
                var bothRead = !batched.StartsWith("error ", StringComparison.Ordinal) && !single.StartsWith("error ", StringComparison.Ordinal) && batched != "missing from batch";
                if (rule.Reason is not null && bothRead && WithoutValue(batched) == WithoutValue(single)) { allowed.Add("round " + round + " " + Name(address) + " (" + rule.Reason + "): batch=" + batched + " single=" + single); continue; }
                mismatches.Add("round " + round + " " + Name(address) + ": batch=" + batched + " single=" + single);
            }
            Save("parity-single-" + round + ".json", singles);
            Console.WriteLine("round " + round + ": batch " + batchMs + " ms, " + addresses.Length + " addresses compared with per-address reads taken right after");
        }
        foreach (var line in allowed) Console.WriteLine("ALLOWED " + line);
        foreach (var line in mismatches) Console.WriteLine("MISMATCH " + line);
        Report("every batched read equals a per-address read of the same address taken right after it (3 rounds, per-address retried up to 2 times; only listed volatile fields may differ)", mismatches.Count == 0,
            compared + " comparisons, " + retried + " per-address retries, " + allowed.Count + " allowed volatile differences, " + mismatches.Count + " mismatches");
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
    case "partial":
    {
        for (var round = 1; round <= 3; round++)
        {
            var watch = Stopwatch.StartNew();
            long partialMs = -1;
            TweakInspection? early = null;
            var full = new TweakEngine(catalog, new RegistryTweakStore()).Detect(inspection => { partialMs = watch.ElapsedMilliseconds; early = inspection; });
            var fullMs = watch.ElapsedMilliseconds;
            var pending = early?.Settings.Count(setting => setting.Error == TweakEngine.FeaturesPending) ?? -1;
            var differ = early is null ? -1 : early.Settings.Zip(full.Settings).Count(pair => pair.First.Error != TweakEngine.FeaturesPending && JsonSerializer.Serialize(pair.First, OperationFiles.Json) != JsonSerializer.Serialize(pair.Second, OperationFiles.Json));
            var expected = JsonSerializer.Serialize(new TweakEngine(catalog, new PerAddressStore(new RegistryTweakStore())).Detect(), OperationFiles.Json);
            Report("round " + round + " partial at " + partialMs + " ms, full at " + fullMs + " ms; partial rows equal the full read except " + pending + " pending; full read equals the per-address read",
                differ == 0 && pending > 0 && JsonSerializer.Serialize(full, OperationFiles.Json) == expected, "differ=" + differ);
        }
        break;
    }
    case "which":
    {
        for (var round = 1; round <= 4; round++)
        {
            var watch = Stopwatch.StartNew();
            var registry = new RegistryTweakStore();
            var slow = addresses.Where(address => address.Kind is "windows-features" or "windows-feature" or "reserved-storage").ToArray();
            var slowRead = registry.ReadControlsAsync(slow);
            var kinds = addresses.Except(slow).Where(address => address.Kind is "dns-over-https" or "firewall-blocklist" or "firewall-profile" or "network-adapter" or "boot-configuration" or "defender" or "filesystem" or "memory" or "device-power" or "teredo")
                .GroupBy(address => address.Kind).Select(group => Task.Run(() => { foreach (var address in group) { try { store.Read(address); } catch (Exception) { } } return group.Key + "=" + watch.ElapsedMilliseconds; })).ToArray();
            Console.WriteLine("round " + round + ": " + string.Join(", ", Task.WhenAll(kinds).GetAwaiter().GetResult()) + " dism=" + (slowRead.ContinueWith(_ => watch.ElapsedMilliseconds).GetAwaiter().GetResult()));
            Thread.Sleep(15000);
        }
        break;
    }
    case "split":
    {
        string[] scripted = ["dns-over-https", "firewall-blocklist", "firewall-profile", "network-adapter", "boot-configuration", "defender", "filesystem", "memory", "device-power", "teredo"];
        for (var round = 1; round <= 8; round++)
        {
            var watch = Stopwatch.StartNew();
            var registry = new RegistryTweakStore();
            var slow = addresses.Where(address => address.Kind is "windows-features" or "windows-feature" or "reserved-storage").ToArray();
            var slowFirst = round % 2 == 1;
            Task<long> Slow() => registry.ReadControlsAsync(slow).ContinueWith(_ => watch.ElapsedMilliseconds);
            var slowRead = slowFirst ? Slow() : null;
            if (slowFirst) Thread.Sleep(delay);
            var psRead = registry.ReadControlsAsync(addresses.Except(slow).Where(address => scripted.Contains(address.Kind)).ToArray()).ContinueWith(_ => watch.ElapsedMilliseconds);
            var nativeRead = registry.ReadControlsAsync(addresses.Except(slow).Where(address => !scripted.Contains(address.Kind)).ToArray()).ContinueWith(_ => watch.ElapsedMilliseconds);
            if (!slowFirst) { Thread.Sleep(delay); slowRead = Slow(); }
            Console.WriteLine("round " + round + (slowFirst ? " dism first" : " powershell first") + ": powershell done " + psRead.GetAwaiter().GetResult() + " ms, native done " + nativeRead.GetAwaiter().GetResult() + " ms, dism done " + slowRead!.GetAwaiter().GetResult() + " ms");
            Thread.Sleep(15000);
        }
        break;
    }
    case "concurrent":
    {
        var watch = Stopwatch.StartNew();
        var groups = addresses.GroupBy(address => address.Kind switch
        {
            "network-adapter" or "teredo" or "device-power" => "ps: adapter, teredo, device power",
            "firewall-profile" or "firewall-blocklist" or "defender" => "ps: firewall, defender",
            "windows-features" => "dism features",
            "reserved-storage" => "ps: reserved storage",
            "dns-over-https" or "boot-configuration" or "memory" or "filesystem" => "ps: dns, boot, memory, filesystem",
            _ => "native",
        }).ToArray();
        var runs = groups.OrderBy(group => group.Key == "dism features" ? 0 : 1).Select(group => { if (group.Key != "dism features") Thread.Sleep(delay / 6); return Task.Run(() => { var started = watch.ElapsedMilliseconds; store.ReadMany(group.ToArray()); return group.Key + " started " + started + " done at " + watch.ElapsedMilliseconds + " ms"; }); }).ToArray();
        foreach (var line in Task.WhenAll(runs).GetAwaiter().GetResult()) Console.WriteLine(line);
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
        var reference = Single();
        Save("kill-or-suspend-reference.json", reference);
        var before = PowerShells();
        var run = Task.Run(Batch);
        Thread.Sleep(delay);
        var started = PowerShells().Except(before).ToArray();
        Report("control helper processes found", started.Length >= 1, string.Join(",", started));
        Dictionary<string, string> result;
        var watch = Stopwatch.StartNew();
        var inFlight = !run.IsCompleted;
        try
        {
            foreach (var id in started.Take(1))
            {
                using var target = Process.GetProcessById(id);
                if (mode == "kill") target.Kill(); else NtSuspendProcess(target.Handle);
            }
            result = run.GetAwaiter().GetResult();
        }
        finally
        {
            foreach (var id in started.Take(1))
            {
                try { using var target = Process.GetProcessById(id); NtResumeProcess(target.Handle); target.Kill(); } catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
        }
        Console.WriteLine("Batch finished " + watch.ElapsedMilliseconds + " ms after the injected fault.");
        var affected = result.Where(pair => pair.Value != reference[pair.Key]).ToArray();
        var detail = string.Join(" | ", affected.Select(pair => pair.Key + " => " + pair.Value));
        Report("the batch had not finished when the fault was injected", inFlight, "run completed before the fault: " + !inFlight);
        if (mode == "kill") Report("a killed batch helper changes no result: the in-flight address is read again per address and every address equals the per-address read", inFlight && affected.Length == 0 && result.Count == reference.Count, detail);
        else Report("exactly the in-flight address failed with the helper error; every other address matches the per-address read", inFlight && affected.Length == 1 && affected[0].Value.Contains("timed out after 120 seconds", StringComparison.Ordinal) && result.Count == reference.Count, detail);
        break;
    }
    default: throw new ArgumentException("Unknown mode.");
}
Console.WriteLine(failures == 0 ? "ALL PASS" : failures + " FAILED");
return failures == 0 ? 0 : 1;

[DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);
[DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr process);
[DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref ProcessBasicInformation information, int length, IntPtr returned);
static int ParentOf(Process process)
{
    try
    {
        var information = new ProcessBasicInformation();
        return NtQueryInformationProcess(process.Handle, 0, ref information, Marshal.SizeOf<ProcessBasicInformation>(), IntPtr.Zero) == 0 ? (int)information.InheritedFromUniqueProcessId : -1;
    }
    catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { return -1; }
}
[StructLayout(LayoutKind.Sequential)] struct ProcessBasicInformation { public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId; }

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
