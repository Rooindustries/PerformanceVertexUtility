using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Roo.Optimizer;

if (args.Length > 0 && args[0].StartsWith("--cpu-", StringComparison.Ordinal))
{
    try { CpuContention.Run(args); }
    catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }
    return;
}
if (args is ["--probe"]) { Thread.Sleep(TimeSpan.FromMinutes(10)); return; }
if (args.Length != 3) throw new ArgumentException("Provide repository root, dotnet executable and output JSON path.");
var repo = Path.GetFullPath(args[0]);
var dotnet = Path.GetFullPath(args[1]);
var outputPath = Path.GetFullPath(args[2]);
var root = Path.Combine(Path.GetTempPath(), "roo-policy-measure-" + Guid.NewGuid().ToString("N"));
var probePath = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath)!, "RooPolicyMeasureProbe.exe");
var store = new ProcessPolicyStore(Path.Combine(root, "policies"));
var hostPath = Path.Combine(repo, "backend", "bin", "optimizer", "Optimizer.Host.dll");
var measuredBinaries = new
{
    hostSha256 = OperationFiles.HashFile(hostPath),
    coreSha256 = OperationFiles.HashFile(Path.Combine(Path.GetDirectoryName(hostPath)!, "Optimizer.Core.dll")),
    protectionCatalogSha256 = OperationFiles.HashFile(Path.Combine(repo, "backend", "profiles", "protected-processes.json")),
};
Process? worker = null;
var probes = new List<Process>();
var samples = new List<object>();
var detections = new List<double>();
var comparison = new List<object>();
string workerOutput = "", workerErrors = "";
try
{
    Directory.CreateDirectory(root);
    if (File.Exists(probePath)) throw new IOException("The measurement probe path already exists.");
    File.Copy(Environment.ProcessPath!, probePath);
    Process StartProbe()
    {
        var start = new ProcessStartInfo(probePath) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--probe");
        var process = Process.Start(start) ?? throw new InvalidOperationException("Measurement probe did not start.");
        probes.Add(process);
        return process;
    }
    void EndProbe(Process process)
    {
        if (!process.HasExited) process.Kill();
        if (!process.WaitForExit(10000)) throw new InvalidOperationException("Measurement probe did not exit.");
        probes.Remove(process);
        process.Dispose();
    }
    var baselineProbe = StartProbe();
    var baseline = MemoryOracle.Read(baselineProbe.Handle);
    var desired = baseline == 2 ? 1u : 2u;
    EndProbe(baselineProbe);
    store.Save(new SavedProcessRule
    {
        SchemaVersion = 1, RuleId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(), Name = "Disposable measurement rule",
        Enabled = true, MatchMode = "path", ExecutablePath = probePath, ExecutableHash = null, CpuSelection = null,
        Controls = new() { ["memoryPriority"] = JsonSerializer.SerializeToElement(desired) },
    });
    var requestPath = Path.Combine(root, "worker-request.json");
    OperationFiles.Write(requestPath, new { schemaVersion = 1, repoRoot = repo, policyRoot = store.Root, confirm = true });
    var startWorker = new ProcessStartInfo(dotnet)
    {
        UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
    };
    foreach (var argument in new[] { hostPath, "policy-run", requestPath }) startWorker.ArgumentList.Add(argument);
    var startup = Stopwatch.StartNew();
    worker = Process.Start(startWorker) ?? throw new InvalidOperationException("Policy worker did not start.");
    var stdout = worker.StandardOutput.ReadToEndAsync();
    var stderr = worker.StandardError.ReadToEndAsync();
    while (store.Status().HostRunning != true && startup.Elapsed < TimeSpan.FromSeconds(15))
    {
        if (worker.HasExited) throw new InvalidOperationException("Worker exited during startup.");
        Thread.Sleep(20);
    }
    if (store.Status().HostRunning != true) throw new InvalidOperationException("Worker startup was not confirmed.");
    var startupMilliseconds = startup.Elapsed.TotalMilliseconds;
    var external = Process.GetProcessesByName("ProcessGovernor").Concat(Process.GetProcessesByName("ProcessLasso")).ToArray();
    foreach (var process in external)
    {
        using (process)
        {
            try { comparison.Add(new { phase = "start", measuredAtUtc = DateTime.UtcNow, name = process.ProcessName, processId = process.Id, created = process.StartTime.ToUniversalTime(), cpuSeconds = process.TotalProcessorTime.TotalSeconds, privateBytes = process.PrivateMemorySize64, workingSetBytes = process.WorkingSet64, handles = process.HandleCount }); }
            catch (Exception error) { comparison.Add(new { processId = process.Id, error = error.Message }); }
        }
    }
    Thread.Sleep(5000);
    worker.Refresh();
    var idleCpuBefore = worker.TotalProcessorTime.TotalSeconds;
    var idle = Stopwatch.StartNew();
    for (var index = 0; index < 30; index++)
    {
        Thread.Sleep(1000);
        worker.Refresh();
        if (worker.HasExited) throw new InvalidOperationException("Worker exited during idle measurement.");
        samples.Add(new { phase = "idle", seconds = idle.Elapsed.TotalSeconds, cpuSeconds = worker.TotalProcessorTime.TotalSeconds - idleCpuBefore,
            privateBytes = worker.PrivateMemorySize64, workingSetBytes = worker.WorkingSet64, handles = worker.HandleCount, threads = worker.Threads.Count });
    }
    var idleSeconds = idle.Elapsed.TotalSeconds;
    var idleCpuSeconds = worker.TotalProcessorTime.TotalSeconds - idleCpuBefore;
    var churn = Stopwatch.StartNew();
    var churnCpuBefore = worker.TotalProcessorTime.TotalSeconds;
    for (var index = 0; index < 40; index++)
    {
        var elapsed = Stopwatch.StartNew();
        var probe = StartProbe();
        while (MemoryOracle.Read(probe.Handle) != desired && elapsed.Elapsed < TimeSpan.FromSeconds(5)) Thread.Sleep(5);
        if (MemoryOracle.Read(probe.Handle) != desired) throw new InvalidOperationException("The rule did not reach a newly launched probe.");
        detections.Add(elapsed.Elapsed.TotalMilliseconds);
        EndProbe(probe);
    }
    worker.Refresh();
    var churnSeconds = churn.Elapsed.TotalSeconds;
    var churnCpuSeconds = worker.TotalProcessorTime.TotalSeconds - churnCpuBefore;
    foreach (var process in Process.GetProcessesByName("ProcessGovernor").Concat(Process.GetProcessesByName("ProcessLasso")))
    {
        using (process)
        {
            try { comparison.Add(new { phase = "end", measuredAtUtc = DateTime.UtcNow, name = process.ProcessName, processId = process.Id, created = process.StartTime.ToUniversalTime(), cpuSeconds = process.TotalProcessorTime.TotalSeconds, privateBytes = process.PrivateMemorySize64, workingSetBytes = process.WorkingSet64, handles = process.HandleCount }); }
            catch (Exception error) { comparison.Add(new { processId = process.Id, error = error.Message }); }
        }
    }
    var persistedBytes = Directory.EnumerateFiles(store.Root, "*", SearchOption.AllDirectories).Sum(path => new FileInfo(path).Length);
    var state = store.Status();
    if (state.State?.Errors.Count > 0 || state.State?.Instances.Any(instance => instance.Status == "conflict") == true)
        throw new InvalidOperationException("A policy conflict invalidated the measurement.");
    store.RequestStop();
    if (!worker.WaitForExit(15000)) throw new InvalidOperationException("The measured worker did not stop.");
    workerOutput = stdout.GetAwaiter().GetResult();
    workerErrors = stderr.GetAwaiter().GetResult();
    if (worker.ExitCode != 0 || store.Status().HostRunning != false) throw new InvalidOperationException("Worker shutdown was not confirmed. " + workerOutput + workerErrors);
    OperationFiles.Write(outputPath, new
    {
        schemaVersion = 1, machine = Environment.MachineName, os = Environment.OSVersion.ToString(), processors = Environment.ProcessorCount,
        measuredAtUtc = DateTime.UtcNow, measuredBinaries, startupMilliseconds, idleSeconds, idleCpuSeconds, idleOneCorePercent = idleCpuSeconds / idleSeconds * 100,
        idleSystemPercent = idleCpuSeconds / idleSeconds / Environment.ProcessorCount * 100, churnSeconds, churnCpuSeconds,
        detectionMilliseconds = detections, samples, persistedBytes, externalControllerSamples = comparison,
        conditions = new[] { "The desktop app was closed.", "Only disposable matching processes were controlled.", "Existing Process Lasso processes and configuration were left unchanged; these measurements do not establish a clean Windows-only or Lasso-only performance comparison." },
        workerExitCode = worker.ExitCode,
    });
    Console.WriteLine("Measurement written to " + outputPath);
}
finally
{
    foreach (var process in probes) { if (!process.HasExited) process.Kill(); process.WaitForExit(); process.Dispose(); }
    if (worker is not null)
    {
        if (!worker.HasExited) { store.RequestStop(); if (!worker.WaitForExit(15000)) { worker.Kill(); worker.WaitForExit(); } }
        worker.Dispose();
    }
    if (File.Exists(probePath)) File.Delete(probePath);
    if (Directory.Exists(root)) Directory.Delete(root, true);
}

static class MemoryOracle
{
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr process, int informationClass, out uint value, uint size);
    public static uint Read(IntPtr process) => GetProcessInformation(process, 0, out var value, 4) ? value : throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
}
