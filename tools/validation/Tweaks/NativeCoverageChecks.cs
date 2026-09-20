using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Net;
using System.Net.NetworkInformation;
using System.Diagnostics;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class NativeCoverageChecks
{
    public sealed record Request(OperationOwner Owner, Guid WifiInterface, string EvidenceDirectory, string StartAt = "");
    public static void RestoreMemory(string requestPath)
    {
        var request = OperationFiles.Read<Request>(requestPath); request.Owner.Verify();
        var plan = OperationFiles.Read<ControlPlan>(Path.Combine(request.EvidenceDirectory, "sysmain-before.json"));
        var memory = OperationFiles.Read<TweakControlRead>(Path.Combine(request.EvidenceDirectory, "memory-before-service.json"));
        if (plan.Expected.Length != 2 || plan.Expected.Any(item => item.Address.Kind != "service" || item.Address.Target != "SysMain" || item.Address.Property is not ("startup" or "running")) ||
            memory.Address != new ControlAddress("memory", "system", "compression") || memory.Value.GetBoolean()) throw new InvalidDataException("Recovery is outside the approved SysMain/memory fixture.");
        var store = new WindowsControlStore();
        var currentMemory = store.Read(memory.Address);
        if (currentMemory.Binding != memory.Binding) throw new InvalidDataException("Memory identity changed.");
        if (!currentMemory.Same(memory)) store.Write(currentMemory, memory.Value);
        foreach (var before in plan.Expected.OrderBy(item => item.Address.Property == "running" ? 0 : 1))
        {
            var current = store.Read(before.Address);
            if (current.Id != before.Id || current.Binding != before.Binding) throw new InvalidDataException("SysMain identity changed; retained recovery evidence.");
            if (!current.Same(before)) store.Write(current, before.Value);
            if (!store.Read(before.Address).Same(before)) throw new InvalidDataException("SysMain recovery readback differs.");
        }
        if (!store.Read(memory.Address).Same(memory)) throw new InvalidDataException("Memory recovery readback differs.");
        OperationFiles.Write(Path.Combine(request.EvidenceDirectory, "memory-recovered.json"), new { owner = request.Owner, restored = true, atUtc = DateTime.UtcNow });
        Console.WriteLine("PASS original SysMain startup/running state and memory compression independently restored");
    }
    public static void Run(string requestPath, Action<bool, string> check)
    {
        var request = OperationFiles.Read<Request>(requestPath); request.Owner.Verify();
        if (request.StartAt is not ("" or "memory" or "mitigations")) throw new InvalidDataException("Unknown native fixture phase.");
        var root = Path.GetFullPath(request.EvidenceDirectory); Directory.CreateDirectory(root);
        OperationFiles.Write(Path.Combine(root, "scope.json"), request);
        var wifi = "interfaces:" + request.WifiInterface.ToString("D");
        void CheckInterface()
        {
            var adapters = NetworkInterface.GetAllNetworkInterfaces().Where(adapter => Guid.TryParse(adapter.Id.Trim('{', '}'), out var id) && id == request.WifiInterface).ToArray();
            if (adapters.Length != 1 || adapters[0].NetworkInterfaceType != NetworkInterfaceType.Wireless80211 || adapters[0].OperationalStatus != OperationalStatus.Down ||
                adapters[0].GetIPProperties().GatewayAddresses.Any(gateway => !gateway.Address.Equals(IPAddress.Any) && !gateway.Address.Equals(IPAddress.IPv6Any)))
                throw new InvalidDataException("The reviewed Wi-Fi adapter must remain disconnected without a gateway.");
        }
        CheckInterface();
        var store = new WindowsControlStore();
        void Roundtrip(ControlAddress address, Func<TweakControlRead, JsonElement> desired)
        {
            var before = store.Read(address); var after = desired(before);
            CheckInterface();
            ValidateBaseline(before);
            var fields = address.Kind == "mitigations" ? after.EnumerateObject().Where(item => item.Name != MitigationControl.SnapshotField && !ControlValues.Equal(item.Value, before.Value.GetProperty(item.Name))).Select(item => item.Name).ToArray() : null;
            var plan = new ControlPlan([before], [new(before, after, fields)], []);
            var directory = Path.Combine(root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
            OperationFiles.Write(Path.Combine(directory, "review.json"), plan); var attempted = 0;
            try
            {
                ControlExecution.Apply(plan, store, count => { attempted = count; OperationFiles.Write(Path.Combine(directory, "attempt.json"), new { attempted }); });
                check(store.Read(address).Same(before with { Value = after }), "Native " + address.Kind + "/" + address.Property + " reads back the requested configuration");
                if (address.Kind == "mitigations")
                {
                    var words = new ulong[3]; var status = RtlQueryImageMitigationPolicy(null, 1, 0, words, 24);
                    check(status == 0 && words[1] == 1, "Windows independently reports ASLR BottomUp ON with its override unchanged");
                }
            }
            finally
            {
                ControlExecution.Rollback(plan, attempted, store);
                check(store.Read(address).Same(before), "Native " + address.Kind + "/" + address.Property + " restores its captured configuration");
                if (address.Kind == "mitigations") check(RtlQueryImageMitigationPolicy(null, 1, 0, new ulong[3], 24) == unchecked((int)0xc0000034), "Windows independently confirms the original ASLR policy absence after restore");
                Directory.Delete(directory, true);
            }
        }
        if (request.StartAt == "")
        {
            foreach (var ip in new[] { "203.0.113.253", "2001:db8::53" })
            {
                var address = new ControlAddress("dns-over-https", ip, "configuration");
                if (store.Read(address).Value.ValueKind != JsonValueKind.Null) throw new InvalidDataException("The documentation-address DoH fixture already exists.");
                Roundtrip(address, _ => ControlValues.From(new { template = "https://roo-industries-test.invalid/dns-query", allowFallback = false, autoUpgrade = true }));
            }
            Roundtrip(new("network-adapter", wifi, "rsc"), before => before.Expand(ControlValues.From(new { ipv4 = false, ipv6 = false })));
            Roundtrip(new("network-adapter", wifi, "ipv6-binding"), before => before.Expand(ControlValues.From(false)));
            DnsRegistry(root, request.WifiInterface, check);
            Roundtrip(new("boot-configuration", "current", "disabledynamictick"), before => ControlValues.From(before.Value.ValueKind == JsonValueKind.True ? false : true));
            Roundtrip(new("boot-configuration", "current", "hypervisorlaunchtype"), before => ControlValues.From(before.Value.ValueKind == JsonValueKind.Number && before.Value.GetUInt64() == 0 ? 1ul : 0ul));
            Roundtrip(new("filesystem", "ntfs", "last-access"), before => ControlValues.From(before.Value.GetInt32() == 3 ? 2 : 3));
            Roundtrip(new("teredo", "system", "type"), before => ControlValues.From(before.Value.GetString() == "Disabled" ? "Default" : "Disabled"));
            Roundtrip(new("reserved-storage", "system", "enabled"), before => ControlValues.From(!before.Value.GetBoolean()));
            Roundtrip(new("firewall-profile", "Domain", "enabled"), before => ControlValues.From(before.Value.GetString() == "True" ? "False" : "True"));
        }
        if (request.StartAt != "mitigations")
        {
        var memoryBeforeService = store.Read(new("memory", "system", "compression"));
        if (memoryBeforeService.Value.GetBoolean()) throw new InvalidDataException("Memory compression no longer matches the approved pre-service baseline.");
        OperationFiles.Write(Path.Combine(root, "memory-before-service.json"), memoryBeforeService);
        var startup = store.Read(new("service", "SysMain", "startup")); var running = store.Read(new("service", "SysMain", "running"));
        if (startup.Value.GetInt32() != 4 || running.Value.GetBoolean()) throw new InvalidDataException("SysMain no longer matches the approved disabled/stopped baseline.");
        var servicePlan = new ControlPlan([startup, running], [new(startup, ControlValues.From(3)), new(running, ControlValues.From(true))], []); var serviceAttempt = 0;
        OperationFiles.Write(Path.Combine(root, "sysmain-before.json"), servicePlan);
        try
        {
            ControlExecution.Apply(servicePlan, store, attempted => { serviceAttempt = attempted; OperationFiles.Write(Path.Combine(root, "sysmain-attempt.json"), new { attempted }); });
            Roundtrip(new("memory", "system", "compression"), before => ControlValues.From(!before.Value.GetBoolean()));
        }
        finally
        {
            ControlExecution.Rollback(servicePlan, serviceAttempt, store);
            check(store.Read(startup.Address).Same(startup) && store.Read(running.Address).Same(running), "SysMain returns to its captured startup and running states");
            check(store.Read(memoryBeforeService.Address).Same(memoryBeforeService), "Memory compression returns to its original state after the service dependency is restored");
        }
        }
        Roundtrip(new("mitigations", "system", "policy"), before =>
        {
            var fields = before.Value.EnumerateObject().ToDictionary(item => item.Name, item => item.Value);
            if (!fields.ContainsKey("Aslr.BottomUp") || !fields.ContainsKey("Aslr.OverrideBottomUp")) throw new InvalidDataException("The system does not expose the reviewed ASLR fields.");
            fields["Aslr.BottomUp"] = ControlValues.From("ON"); fields["Aslr.OverrideBottomUp"] = ControlValues.From(false);
            return MitigationControl.Reconcile(ControlValues.From(fields));
        });
        Roundtrip(new("windows-features", "system", "features"), before =>
        {
            if (before.RestartPending || before.Value.GetProperty("TelnetClient").GetString() != "Disabled") throw new InvalidDataException("Telnet must start disabled with its payload available and no pending feature restart.");
            var fields = before.Value.EnumerateObject().ToDictionary(item => item.Name, item => item.Value); fields["TelnetClient"] = ControlValues.From("Enabled"); return ControlValues.From(fields);
        });
        CheckInterface();
    }
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)] private static extern int RtlQueryImageMitigationPolicy(string? image, int policy, uint flags, [Out] ulong[] buffer, uint size);
    private static void ValidateBaseline(TweakControlRead before)
    {
        var value = before.Value;
        var valid = before.Address.Kind switch
        {
            "boot-configuration" or "dns-over-https" => value.ValueKind == JsonValueKind.Null,
            "filesystem" => value.GetInt32() == 1,
            "teredo" => value.GetString() == "Default",
            "reserved-storage" => value.GetBoolean(),
            "memory" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
            "firewall-profile" => value.GetString() == "True",
            "network-adapter" => value.EnumerateObject().All(item => before.Address.Property == "ipv6-binding" ? item.Value.GetBoolean() : item.Value.EnumerateObject().All(field => field.Value.GetBoolean())),
            "mitigations" => value.GetProperty(MitigationControl.SnapshotField).EnumerateObject().All(item => item.Value.ValueKind == JsonValueKind.Null),
            _ => true,
        };
        if (!valid) throw new InvalidDataException("The native fixture baseline changed for " + before.Address.Kind + "/" + before.Address.Property);
        if (before.Address.Kind != "firewall-profile") return;
        var script = "$ErrorActionPreference='Stop';$pc=@(Get-CimInstance Win32_ComputerSystem);if($pc.Count -ne 1 -or $pc[0].PartOfDomain -isnot [bool]){throw 'Domain membership is unknown'};if($pc[0].PartOfDomain -or @(Get-NetConnectionProfile|Where-Object {$_.NetworkCategory -eq 2}).Count){throw 'The Domain firewall profile may be active'}";
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Could not inspect Domain firewall applicability.");
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(15000)) { process.Kill(); process.WaitForExit(); throw new TimeoutException("Domain profile inspection did not finish."); }
        Task.WaitAll(output, errors);
        if (process.ExitCode != 0) throw new InvalidDataException("Domain profile test refused: " + errors.Result + output.Result);
    }
    private static void DnsRegistry(string root, Guid wifi, Action<bool, string> check)
    {
        var key = @"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\" + wifi.ToString("B").ToUpperInvariant();
        var address = new RegistryAddress("LocalMachine", "Registry64", key, "value", "NameServer");
        var recovery = new RegistryAddress("CurrentUser", "Registry64", RegistryTweakChecks.Root + @"\Recovery", "value", "State");
        using var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        bool parentExisted; using (var parent = user.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        using (var exists = user.OpenSubKey(RegistryTweakChecks.Root)) if (exists is not null) throw new InvalidDataException("The approved recovery fixture root must be absent.");
        var store = new RegistryTweakStore(recovery); var before = store.Read(address);
        var option = new TweakOption("test", "Temporary DNS", [new(address, null, new("NameServer", 1, Encoding.Unicode.GetBytes("203.0.113.253\0")))]);
        var catalog = new TweakCatalog(1, "dns-fixture", [new("dns", "Disconnected Wi-Fi DNS", "Fixture", "Fixture", 10240, 26200, ["*"], "none", [option], [new("Roo Industries", "fixture", "captured interface")])], []);
        var engine = new TweakEngine(catalog, store);
        void Apply(TweakSelection[] choices)
        {
            var plan = engine.Preview("dns", choices); var path = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(path, plan); engine.Apply(path, OperationFiles.HashFile(path));
        }
        try
        {
            Apply([new("dns", "test")]);
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64); using var observed = machine.OpenSubKey(key);
            check((string?)observed?.GetValue("NameServer") == "203.0.113.253", "Disconnected Wi-Fi DNS writes through the shared registry transaction and independent Windows reader");
        }
        finally
        {
            if (store.ReadState()?.Profiles.Length > 0) Apply([]);
            check(store.Read(address).Same(before), "Wi-Fi DNS restores the exact original value type, bytes and absence");
            user.DeleteSubKeyTree(RegistryTweakChecks.Root, false);
            if (!parentExisted)
            {
                using var parent = user.OpenSubKey(@"Software\RooIndustriesTweakTests");
                if (parent is { SubKeyCount: 0, ValueCount: 0 }) { parent.Dispose(); user.DeleteSubKey(@"Software\RooIndustriesTweakTests", false); }
            }
        }
    }
}
