using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using RooIndustries.Optimizer;

try
{
if (args is ["--probe"] or ["--probe-ready"]) { if (args[0] == "--probe-ready") Console.WriteLine("ready"); Thread.Sleep(TimeSpan.FromMinutes(3)); return; }
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    Console.WriteLine("PASS " + message);
}
if (args is ["--firmware-provider", var firmwareFixture]) { FirmwareProviderChecks.Run(Check, firmwareFixture); return; }
if (args is ["--firmware-setup", var setupFixture]) { await ScewinSetupChecks.Run(Check, setupFixture); return; }
if (args is ["--firmware-download", var downloadDirectory])
{
    var directory = await new ScewinSetup().InstallAsync(downloadDirectory, new Progress<string>(Console.WriteLine));
    Console.WriteLine(JsonSerializer.Serialize(new { packageDirectory = directory, package = OperationFiles.Read<FirmwarePackage>(Path.Combine(directory, "package.json")) }, OperationFiles.Json));
    return;
}
if (args is ["--firmware"]) { FirmwareChecks.Run(Check); return; }
if (args is ["--firmware-native", var evidenceRoot]) { FirmwareScriptNativeChecks.Run(Check, evidenceRoot); return; }
if (args is ["--firmware-verification"]) { FirmwareVerificationChecks.Run(Check); return; }
if (args is ["--firmware-authority"]) { FirmwareEvidenceAuthorityChecks.Run(Check); return; }
if (args is ["--operation-files"]) { OperationFileChecks.Run(Check); return; }
if (args is ["--branding"]) { BrandCompatibilityChecks.Run(Check); return; }
if (args is ["--files"]) { FileChecks.Run(Check); FileConflictChecks.Run(Check); return; }
if (args is ["--registry"]) { RegistryChecks.Run(Check); RegistryConflictChecks.Run(Check); return; }
if (args is ["--policies"]) { ProcessIdentityChecks.Run(Check); PolicyChecks.Run(Check); return; }
if (args is ["--discovery"]) { DiscoveryChecks.Run(Check); return; }
if (args is ["--cleanup"]) { ApplicationCleanupChecks.Run(Check); ExclusionChecks.Run(Check); return; }
if (args is ["--batch"]) { CleanupBatchChecks.Run(Check); return; }
if (args is ["--batch-state"]) { CleanupBatchStateChecks.Run(Check); return; }
if (args.Length != 0) throw new ArgumentException("Unknown validation area.");
BrandCompatibilityChecks.Run(Check);
using (var self = Process.GetCurrentProcess())
{
    for (var index = 0; index < 64; index++) OperationOwner.Current();
    GC.Collect();
    GC.WaitForPendingFinalizers();
    GC.Collect();
    uint before, after;
    if (!GC.TryStartNoGCRegion(32 * 1024 * 1024)) throw new InvalidOperationException("Could not isolate ownership handle accounting from finalization.");
    try
    {
        before = Oracle.Handles(self.Handle);
        for (var index = 0; index < 1000; index++) OperationOwner.Current();
        after = Oracle.Handles(self.Handle);
    }
    finally { GC.EndNoGCRegion(); }
    Check(after <= before + 8, $"Repeated ownership queries release native handles without waiting for GC ({before} to {after})");
}
void Reject(Action operation, string message)
{
    var rejected = false;
    try { operation(); } catch (InvalidDataException) { rejected = true; }
    Check(rejected, message);
}
JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
LogicalCpu[] topology = [
    new(901, 0, 0, 0, 0, 0, 9, false, false, false),
    new(902, 0, 1, 0, 0, 0, 9, true, false, false),
    new(903, 0, 2, 2, 1, 0, 3, false, false, false),
    new(904, 1, 0, 0, 0, 0, 9, false, false, false),
];
var hash = CpuSelection.Fingerprint(topology);
var selection = new CpuSelection { Kind = "logical", TopologyHash = hash, Processors = [new(1, 0)] };
Check(selection.Resolve(topology).SequenceEqual(new uint[] { 904 }), "Logical CPU selection retains its processor group");
var newIds = topology.Select(cpu => cpu with { Id = cpu.Id + 1000 }).ToArray();
Check(selection.Resolve(newIds).SequenceEqual(new uint[] { 1904 }), "Saved coordinates resolve fresh opaque CPU Set IDs");
Check((selection with { Kind = "performance", Processors = null, OneThreadPerCore = true }).Resolve(topology).SequenceEqual(new uint[] { 901, 904 }), "Performance/core selectors use efficiency classes and group-local SMT identity");
Reject(() => selection.Resolve(topology.Select(cpu => cpu with { Core = (byte)(cpu.Core + 1) }).ToArray()), "Changed topology requires review");
Reject(() => selection.Resolve(topology.Select(cpu => cpu.Group == 1 ? cpu with { Allocated = true } : cpu).ToArray()), "A reserved selected CPU cannot silently fall back");
Reject(() => (selection with { Processors = [] }).Resolve(topology), "Empty explicit selection cannot become Windows default");
Reject(() => (selection with { TopologyHash = null }).Resolve(topology), "Missing topology binding is unknown rather than approved");
Check(new CpuSelection { Kind = "windowsDefault" }.Resolve(topology).Length == 0, "Windows default is an explicit distinct selection");
Check(new PowerThrottling(0, 1).ExecutionMode == "systemManaged", "An uncontrolled execution-speed bit stays system-managed even if its state bit is set");
Check(new PowerThrottling(4, 4).WithExecutionMode("eco") == new PowerThrottling(5, 5), "EcoQoS preserves an independent timer-resolution control");
Check(new PowerThrottling(5, 5).WithExecutionMode("high") == new PowerThrottling(5, 4), "Explicit HighQoS remains distinct from system-managed QoS");
Check(new PowerThrottling(5, 5).WithExecutionMode("systemManaged") == new PowerThrottling(4, 4), "Returning execution speed to Windows preserves unrelated masks");
Reject(() => new ControlRead(false, Value(2), null).Require(), "A favorable value cannot override an unknown-read signal");
Reject(() => new ControlRead(true, Value(2), new("fixture", "win32", 5, "0x1000", "denied")).Require(), "An error independently blocks a favorable known/value pair");
foreach (var missing in new[] { "{\"stateMask\":1}", "{\"controlMask\":0}", "{}" })
{
    var rejected = false;
    try { JsonSerializer.Deserialize<PowerThrottling>(missing, OperationFiles.Json); } catch (JsonException) { rejected = true; }
    Check(rejected, "Missing power-mask detail cannot be filled with system-managed defaults");
}

var root = Path.Combine(Path.GetTempPath(), "roo-industries-core-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
Process? probe = null;
try
{
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
    start.ArgumentList.Add("--probe");
    probe = Process.Start(start) ?? throw new InvalidOperationException("Fixture did not start.");
    using var target = new ProcessTarget(probe.Id);
    var snapshot = target.Snapshot();
    foreach (var field in snapshot.Controls.Where(field => !field.Value.Known)) Console.WriteLine("UNAVAILABLE " + field.Key + ": " + JsonSerializer.Serialize(field.Value.Error));
    Check(snapshot.Controls["memoryPriority"].Require().GetUInt32() == Oracle.Memory(probe.Handle), "Process memory-priority detection agrees with an independent Windows query");
    var memoryBefore = Oracle.Memory(probe.Handle);
    var boostBefore = Oracle.Boost(probe.Handle);
    var desiredMemory = memoryBefore == 2 ? 3u : 2u;
    var engine = new ProcessControlEngine(identity => identity.ExecutablePath != Environment.ProcessPath);
    var preview = engine.Preview(probe.Id, new() { ["memoryPriority"] = Value(desiredMemory), ["priorityBoost"] = Value(!boostBefore) });
    var previewPath = Path.Combine(root, "review.json");
    var journalPath = Path.Combine(root, "journal.json");
    OperationFiles.Write(previewPath, preview);
    var reviewHash = OperationFiles.HashFile(previewPath);
    var applied = engine.Apply(previewPath, reviewHash, journalPath);
    Check(applied.Status == "applied" && Oracle.Memory(probe.Handle) == desiredMemory && Oracle.Boost(probe.Handle) != boostBefore, "Reviewed memory and priority-boost changes reach Windows");
    var repeat = engine.Apply(previewPath, reviewHash, journalPath);
    Check(repeat.Status == "applied", "Duplicate apply observes the existing assignment without a second dispatch");
    Oracle.SetMemory(probe.Handle, desiredMemory == 4 ? 1u : 4u);
    var conflict = engine.Restore(journalPath);
    Check(conflict.Status == "needsReconciliation" && Oracle.Memory(probe.Handle) == 4 && Oracle.Boost(probe.Handle) == boostBefore, "Restore preserves a foreign field while restoring independently owned fields");
    Oracle.SetMemory(probe.Handle, desiredMemory);
    var restored = engine.Restore(journalPath);
    Check(restored.Status == "restored" && Oracle.Memory(probe.Handle) == memoryBefore, "A reconciled field restores its original memory priority");
    var postRestore = engine.Apply(previewPath, reviewHash, journalPath);
    Check(postRestore.Status == "restored" && Oracle.Memory(probe.Handle) == memoryBefore, "A restored review cannot be reapplied");

    var powerBefore = Oracle.Power(probe.Handle);
    Oracle.SetPower(probe.Handle, new PowerThrottling(4, 4));
    var powerPreview = engine.Preview(probe.Id, new() { ["executionQoS"] = Value(new PowerThrottling(5, 5)) });
    var powerPath = Path.Combine(root, "power-review.json");
    var powerJournal = Path.Combine(root, "power-journal.json");
    OperationFiles.Write(powerPath, powerPreview);
    Check(engine.Apply(powerPath, OperationFiles.HashFile(powerPath), powerJournal).Status == "applied" && Oracle.Power(probe.Handle) == new PowerThrottling(5, 5), "Native EcoQoS apply preserves the separately configured timer-resolution bit");
    Oracle.SetPower(probe.Handle, new PowerThrottling(5, 1));
    Check(engine.Restore(powerJournal).Status == "restored" && Oracle.Power(probe.Handle) == new PowerThrottling(4, 0), "Native QoS restore returns execution speed to Windows while preserving a later independent timer setting");
    Oracle.SetPower(probe.Handle, powerBefore);

    var priorityBefore = probe.PriorityClass;
    var affinityBefore = probe.ProcessorAffinity;
    var ioBefore = Oracle.Io(probe.Handle);
    var gpuBefore = Oracle.Gpu(probe.Handle);
    var affinity = snapshot.Controls["affinity"].Require().Deserialize<AffinityState>(OperationFiles.Json)!;
    var controlsPreview = engine.Preview(probe.Id, new()
    {
        ["cpuPriority"] = Value(priorityBefore == ProcessPriorityClass.BelowNormal ? "Normal" : "BelowNormal"),
        ["affinity"] = Value(new AffinityState(affinity.Group, "0x1")),
        ["ioPriority"] = Value(ioBefore == 1 ? 0 : 1),
        ["gpuPriority"] = Value(gpuBefore == 1 ? 2 : 1),
        ["cpuSets"] = Value(new[] { snapshot.Topology.First(cpu => cpu.Available).Id }),
    });
    var controlsPath = Path.Combine(root, "controls-review.json");
    var controlsJournal = Path.Combine(root, "controls-journal.json");
    OperationFiles.Write(controlsPath, controlsPreview);
    var controlsApplied = engine.Apply(controlsPath, OperationFiles.HashFile(controlsPath), controlsJournal);
    if (controlsApplied.Status != "applied") Console.WriteLine(JsonSerializer.Serialize(controlsApplied, OperationFiles.Json));
    probe.Refresh();
    Check(controlsApplied.Status == "applied" && probe.PriorityClass != priorityBefore && probe.ProcessorAffinity == (IntPtr)1 && Oracle.Io(probe.Handle) != ioBefore && Oracle.Gpu(probe.Handle) != gpuBefore && Oracle.CpuSets(probe.Handle).Length == 1, "CPU priority, affinity, CPU Sets, I/O and GPU priority changes are independently visible");
    Check(engine.Apply(controlsPath, OperationFiles.HashFile(controlsPath), controlsJournal).Status == "applied" && Oracle.Gpu(probe.Handle) != gpuBefore && Oracle.Io(probe.Handle) != ioBefore, "Repeated combined-control application keeps independently observed GPU and I/O assignments healthy");
    Check(engine.Restore(controlsJournal).Status == "restored", "Combined process controls restore through the owned recovery path");
    probe.Refresh();
    Check(probe.PriorityClass == priorityBefore && probe.ProcessorAffinity == affinityBefore && Oracle.Io(probe.Handle) == ioBefore && Oracle.Gpu(probe.Handle) == gpuBefore && Oracle.CpuSets(probe.Handle).Length == 0, "Independent readback verifies all original combined controls");
    var highPreview = engine.Preview(probe.Id, new() { ["ioPriority"] = Value(3) });
    var highPath = Path.Combine(root, "high-io-review.json");
    var highJournal = Path.Combine(root, "high-io-journal.json");
    OperationFiles.Write(highPath, highPreview);
    Check(engine.Apply(highPath, OperationFiles.HashFile(highPath), highJournal).Status == "applied" && Oracle.Io(probe.Handle) == 3, "The current Windows token can apply and independently read High I/O priority");
    Check(engine.Restore(highJournal).Status == "restored" && Oracle.Io(probe.Handle) == ioBefore, "High I/O priority restores through the same native control path");
    foreach (var (name, value, label) in new[] { ("cpuPriority", Value("Realtime"), "Realtime CPU priority"), ("gpuPriority", Value(5), "Realtime GPU priority") })
    {
        var realtimePath = Path.Combine(root, name + "-realtime-review.json");
        var realtimeJournal = Path.Combine(root, name + "-realtime-journal.json");
        OperationFiles.Write(realtimePath, engine.Preview(probe.Id, new() { [name] = value }));
        var realtime = engine.Apply(realtimePath, OperationFiles.HashFile(realtimePath), realtimeJournal);
        probe.Refresh();
        var observed = name == "cpuPriority" ? probe.PriorityClass == ProcessPriorityClass.RealTime : Oracle.Gpu(probe.Handle) == 5;
        if (realtime.Status != "applied") Console.WriteLine(JsonSerializer.Serialize(realtime, OperationFiles.Json));
        Check(realtime.Status == "applied" && observed, "The current Windows token can apply and independently read " + label);
        var realtimeRestore = engine.Restore(realtimeJournal);
        probe.Refresh();
        Check(realtimeRestore.Status == "restored" && probe.PriorityClass == priorityBefore && Oracle.Gpu(probe.Handle) == gpuBefore, label + " restores through the same native control path");
        probe.Refresh();
    }
    var sameBefore = probe.PriorityClass;
    var samePath = Path.Combine(root, "same-review.json");
    var sameJournal = Path.Combine(root, "same-journal.json");
    OperationFiles.Write(samePath, engine.Preview(probe.Id, new() { ["cpuPriority"] = Value(sameBefore.ToString()) }));
    var same = engine.Apply(samePath, OperationFiles.HashFile(samePath), sameJournal);
    Check(same.Status == "applied" && same.Changes.Single().Status == "unchanged", "A process already at its target value is recorded as unchanged");
    probe.PriorityClass = sameBefore == ProcessPriorityClass.High ? ProcessPriorityClass.AboveNormal : ProcessPriorityClass.High;
    var foreign = probe.PriorityClass;
    engine.Restore(sameJournal);
    probe.Refresh();
    Check(probe.PriorityClass == foreign, "Restoring an unchanged field leaves a later outside value alone");
    probe.PriorityClass = sameBefore;
    var malformed = Path.Combine(root, "duplicate.json");
    File.WriteAllText(malformed, "{\"kind\":\"windowsDefault\",\"kind\":\"logical\"}");
    Reject(() => OperationFiles.Read<CpuSelection>(malformed), "Duplicate JSON fields are rejected at the saved-operation boundary");
}
finally
{
    if (probe is not null) { if (!probe.HasExited) probe.Kill(); if (!probe.WaitForExit(10000)) throw new InvalidOperationException("Fixture did not exit."); probe.Dispose(); }
    Directory.Delete(root, true);
}
Check(!Directory.Exists(root), "Core validation removes its process and operation files");
OperationFileChecks.Run(Check);
RegistryChecks.Run(Check);
RegistryConflictChecks.Run(Check);
FileChecks.Run(Check);
FileConflictChecks.Run(Check);
ProcessIdentityChecks.Run(Check);
PolicyChecks.Run(Check);
DiscoveryChecks.Run(Check);
ApplicationCleanupChecks.Run(Check);
ExclusionChecks.Run(Check);
CleanupBatchChecks.Run(Check);
FirmwareChecks.Run(Check);
PrivilegeChecks.Run(Check);

}
catch (Exception error)
{
    Console.Error.WriteLine(error);
    Environment.ExitCode = 1;
}

static class Oracle
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessHandleCount(IntPtr process, out uint count);
    public static uint Handles(IntPtr process) => GetProcessHandleCount(process, out var count) ? count : throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    [StructLayout(LayoutKind.Sequential)] struct PowerInfo { public uint Version, Control, State; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr process, int informationClass, out uint value, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetProcessInformation(IntPtr process, int informationClass, ref uint value, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessPriorityBoost(IntPtr process, [MarshalAs(UnmanagedType.Bool)] out bool disabled);
    [DllImport("kernel32.dll", EntryPoint="GetProcessInformation", SetLastError=true)] static extern bool GetPower(IntPtr process, int informationClass, ref PowerInfo value, uint length);
    [DllImport("kernel32.dll", EntryPoint="SetProcessInformation", SetLastError=true)] static extern bool SetPowerInfo(IntPtr process, int informationClass, ref PowerInfo value, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process, [Out] uint[] ids, uint capacity, out uint required);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int informationClass, out int value, int length, IntPtr returned);
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    public static uint Memory(IntPtr process) => GetProcessInformation(process, 0, out var value, 4) ? value : throw new InvalidOperationException("Oracle memory query failed: " + Marshal.GetLastWin32Error());
    public static bool Boost(IntPtr process) => GetProcessPriorityBoost(process, out var disabled) ? !disabled : throw new InvalidOperationException("Oracle boost query failed");
    public static void SetMemory(IntPtr process, uint value) { if (!SetProcessInformation(process, 0, ref value, 4)) throw new InvalidOperationException("Oracle memory write failed"); }
    public static PowerThrottling Power(IntPtr process)
    {
        var data = new PowerInfo { Version = 1 };
        if (!GetPower(process, 4, ref data, 12)) throw new InvalidOperationException("Oracle power query failed: " + Marshal.GetLastWin32Error());
        return new(data.Control, data.State);
    }
    public static void SetPower(IntPtr process, PowerThrottling value)
    {
        var data = new PowerInfo { Version = 1, Control = value.ControlMask, State = value.StateMask };
        if (!SetPowerInfo(process, 4, ref data, 12)) throw new InvalidOperationException("Oracle power write failed: " + Marshal.GetLastWin32Error());
    }
    public static int Io(IntPtr process) => NtQueryInformationProcess(process, 33, out var value, 4, IntPtr.Zero) == 0 ? value : throw new InvalidOperationException("Oracle I/O query failed");
    public static int Gpu(IntPtr process)
    {
        var status = D3DKMTGetProcessSchedulingPriorityClass(process, out var value);
        return status == 0 ? value : throw new InvalidOperationException($"Oracle GPU query failed: NTSTATUS 0x{status:X8}");
    }
    public static uint[] CpuSets(IntPtr process)
    {
        var values = new uint[1024];
        if (!GetProcessDefaultCpuSets(process, values, (uint)values.Length, out var count)) throw new InvalidOperationException("Oracle CPU Set query failed");
        Array.Resize(ref values, (int)count); return values;
    }
}
