using System.Diagnostics;
using System.Text.Json;
using RooIndustries.Optimizer;

static class PolicyChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-policies-" + Guid.NewGuid().ToString("N"));
        Process? probe = null;
        Process StartProbe()
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
            start.ArgumentList.Add("--probe-ready");
            var process = Process.Start(start)!;
            try
            {
                var ready = process.StandardOutput.ReadLineAsync();
                if (ready.Wait(5000) && ready.Result == "ready") return process;
                throw new InvalidOperationException("The policy fixture did not become ready.");
            }
            catch
            {
                if (!process.HasExited) process.Kill();
                process.WaitForExit(); process.Dispose();
                throw;
            }
        }
        try
        {
            probe = StartProbe();
            using var queried = new ProcessTarget(probe.Id);
            var topology = queried.Topology();
            var cpu = topology.First(item => item.Available);
            var initial = Oracle.Memory(probe.Handle);
            var memory = initial == 2 ? 3u : 2u;
            var initialGpu = Oracle.Gpu(probe.Handle);
            var gpu = initialGpu == 1 ? 2 : 1;
            var store = new ProcessPolicyStore(root);
            var rule = new SavedProcessRule
            {
                SchemaVersion = 1, RuleId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(), Name = "Disposable process policy",
                Enabled = true, MatchMode = "path", ExecutablePath = Environment.ProcessPath!, ExecutableHash = null,
                Controls = new() { ["memoryPriority"] = JsonSerializer.SerializeToElement(memory), ["gpuPriority"] = JsonSerializer.SerializeToElement(gpu) },
                CpuSelection = new() { Kind = "logical", TopologyHash = CpuSelection.Fingerprint(topology), Processors = [new(cpu.Group, cpu.Index)] },
            };
            store.Save(rule);
            var host = new ProcessPolicyHost(store, process => !string.Equals(process.ExecutablePath, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase));
            var first = host.Tick();
            if (first.Errors.Count > 0) Console.WriteLine(string.Join("\n", first.Errors));
            check(Oracle.Memory(probe.Handle) == memory && Oracle.CpuSets(probe.Handle).SequenceEqual(new[] { cpu.Id }), "Saved policies apply memory controls and semantic CPU choices to an existing process");
            host.Tick();
            check(first.Instances.Count(instance => instance.Status == "active") == 1 && Oracle.Gpu(probe.Handle) == gpu, "Repeated policy polling retains one healthy operation with the independently observed GPU priority");
            var oldId = probe.Id;
            probe.Kill(); probe.WaitForExit(); probe.Dispose();
            probe = StartProbe();
            var relaunchedOriginal = Oracle.Memory(probe.Handle);
            var relaunchedGpu = Oracle.Gpu(probe.Handle);
            var relaunched = host.Tick();
            check(relaunched.Instances.Any(instance => instance.Process.ProcessId == oldId && instance.Status == "expired") && Oracle.Memory(probe.Handle) == memory && Oracle.CpuSets(probe.Handle).SequenceEqual(new[] { cpu.Id }), "A new process instance receives a fresh policy operation while the exited instance expires");
            host = new ProcessPolicyHost(store, _ => false);
            var recovered = host.Tick();
            check(recovered.Instances.Count(instance => instance.Process.ProcessId == probe.Id && instance.Status == "active") == 1, "A recreated host recovers the durable operation without reapplying it");
            Oracle.SetMemory(probe.Handle, 4);
            host.Tick(); host.Tick();
            check(Oracle.Memory(probe.Handle) == 4 && recovered.Instances.Any(instance => instance.Process.ProcessId == probe.Id && instance.Status == "conflict"), "A policy suspends on a foreign change instead of repeatedly overwriting it");
            store.Save(rule with { Enabled = false });
            host.Tick();
            check(Oracle.Memory(probe.Handle) == 4 && Oracle.CpuSets(probe.Handle).Length == 0 && Oracle.Gpu(probe.Handle) == relaunchedGpu, "Disabling a rule restores its CPU Sets and GPU priority while preserving a foreign memory priority");
            Oracle.SetMemory(probe.Handle, memory);
            check(host.Stop().Status == "stopped" && Oracle.Memory(probe.Handle) == relaunchedOriginal, "Policy stop resolves an available owned restoration and leaves no active controller");
            store.Save(rule with { Enabled = true });
            var overlapRejected = false;
            try { store.Save(rule with { RuleId = Guid.NewGuid().ToString("N") }); } catch (InvalidDataException) { overlapRejected = true; }
            check(overlapRejected, "Overlapping saved rules cannot fight over the same process field");
            var revision = store.ReadRules().Single().Rule.Revision;
            store.Save(rule);
            check(store.ReadRules().Single().Rule.Revision != revision, "An explicit rule resubmission has a distinct revision for conflict recovery");
        }
        finally
        {
            if (probe is not null) { if (!probe.HasExited) probe.Kill(); probe.WaitForExit(); probe.Dispose(); }
            if (Directory.Exists(root)) Directory.Delete(root, true);
            using var markers = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true);
            markers?.DeleteValue(PolicyRootSecurity.Normalize(root).ToUpperInvariant(), false);
        }
        check(!Directory.Exists(root), "Policy validation removes its process, saved rules and journals");
    }
}
