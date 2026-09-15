using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using Roo.Optimizer;

try
{
    if (args is not [var repository, var dotnet, var diskspd, var output, var blocksText, var secondsText, var priorityText])
        throw new ArgumentException("Provide repository, dotnet, DiskSpd, output JSON, paired blocks, trial seconds and background I/O priority.");
    var blocks = int.Parse(blocksText);
    var seconds = int.Parse(secondsText);
    var priority = int.Parse(priorityText);
    if (blocks is < 1 or > 30 || seconds is < 3 or > 60 || priority is < 0 or > 1) throw new ArgumentException("Invalid measurement limits.");
    StorageMeasurement.Run(Path.GetFullPath(repository), Path.GetFullPath(dotnet), Path.GetFullPath(diskspd), Path.GetFullPath(output), blocks, seconds, priority);
}
catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }

static class StorageMeasurement
{
    const string DiskSpdHash = "DD4E57E1E8CCAF5D6437938F8AAB7F17E9A1E6D8FBA8A093006B7CADF16FAEA2";
    const long FileBytes = 512L * 1024 * 1024;
    const int Warmup = 2;

    public static void Run(string repository, string dotnet, string diskspd, string output, int blocks, int seconds, int priority)
    {
        if (OperationFiles.HashFile(diskspd) != DiskSpdHash) throw new InvalidDataException("Use the verified DiskSpd 2.3 amd64 release binary.");
        using var lease = OperationFiles.Lock(Path.Combine(Path.GetTempPath(), "roo-storage-measure"));
        if (new DriveInfo(Path.GetPathRoot(Path.GetTempPath())!).AvailableFreeSpace < FileBytes * 3) throw new IOException("Insufficient free space for the disposable measurement files.");
        var root = Path.Combine(Path.GetTempPath(), "roo-storage-measure-" + Guid.NewGuid().ToString("N"));
        var evidence = Path.Combine(Path.GetDirectoryName(output)!, Path.GetFileNameWithoutExtension(output) + "-xml");
        if (File.Exists(output) || Directory.Exists(evidence)) throw new IOException("Choose a new output path for this experiment.");
        var hostPath = Path.Combine(repository, "backend", "bin", "optimizer", "Optimizer.Host.dll");
        var binaries = new { diskSpd = DiskSpdHash, benchmark = OperationFiles.HashFile(typeof(StorageMeasurement).Assembly.Location),
            host = OperationFiles.HashFile(hostPath), core = OperationFiles.HashFile(Path.Combine(Path.GetDirectoryName(hostPath)!, "Optimizer.Core.dll")) };
        var externalBefore = Controllers();
        var trials = new List<object>();
        OperationFiles.Write(output, new { status = "running", binaries, blocks, seconds, priority, trials });
        Directory.CreateDirectory(root); Directory.CreateDirectory(evidence);
        try
        {
            var foregroundExe = Path.Combine(root, "RooIoForeground.exe");
            var backgroundExe = Path.Combine(root, "RooIoBackground.exe");
            File.Copy(diskspd, foregroundExe); File.Copy(diskspd, backgroundExe);
            var foregroundFile = Path.Combine(root, "foreground.bin");
            var backgroundFile = Path.Combine(root, "background.bin");
            CreateData(foregroundFile); CreateData(backgroundFile);
            var hashes = new[] { OperationFiles.HashFile(foregroundFile), OperationFiles.HashFile(backgroundFile) };
            var random = new Random(16092026);
            for (var block = 0; block < blocks; block++)
            {
                foreach (var enabled in random.Next(2) == 0 ? new[] { false, true } : new[] { true, false })
                {
                    var prefix = "Local\\RooStorage-" + Guid.NewGuid().ToString("N");
                    using var start = new EventWaitHandle(false, EventResetMode.ManualReset, prefix + "-start");
                    using var stop = new EventWaitHandle(false, EventResetMode.ManualReset, prefix + "-stop");
                    var trialDirectory = Path.Combine(root, Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(trialDirectory);
                    var store = new ProcessPolicyStore(Path.Combine(trialDirectory, "policies"));
                    var foregroundArgs = Arguments(foregroundFile, prefix, true, seconds);
                    var backgroundArgs = Arguments(backgroundFile, prefix, false, seconds);
                    using var foreground = new CapturedProcess(foregroundExe, foregroundArgs);
                    using var background = new CapturedProcess(backgroundExe, backgroundArgs);
                    CapturedProcess? worker = null;
                    var label = $"block-{block + 1:D2}-{(enabled ? "rule" : "normal")}";
                    var foregroundXml = Path.Combine(evidence, label + "-foreground.xml");
                    var backgroundXml = Path.Combine(evidence, label + "-background.xml");
                    try
                    {
                        foreground.Process.PriorityClass = ProcessPriorityClass.Normal;
                        background.Process.PriorityClass = ProcessPriorityClass.Normal;
                        IoPriority.Set(foreground.Process, 2); IoPriority.Set(background.Process, 2);
                        if (enabled)
                        {
                            store.Save(new SavedProcessRule
                            {
                                SchemaVersion = 1, RuleId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(), Name = "Storage contention measurement",
                                Enabled = true, MatchMode = "path", ExecutablePath = backgroundExe, ExecutableHash = DiskSpdHash, CpuSelection = null,
                                Controls = new() { ["ioPriority"] = JsonSerializer.SerializeToElement(priority) },
                            });
                            var request = Path.Combine(trialDirectory, "worker.json");
                            OperationFiles.Write(request, new { schemaVersion = 1, repoRoot = repository, policyRoot = store.Root, confirm = true });
                            worker = new CapturedProcess(dotnet, [hostPath, "policy-run", request]);
                            var wait = Stopwatch.StartNew();
                            while (IoPriority.Read(background.Process) != priority && wait.Elapsed < TimeSpan.FromSeconds(15))
                            {
                                worker.RequireAlive(); Thread.Sleep(20);
                            }
                            if (IoPriority.Read(background.Process) != priority) throw new InvalidOperationException("The I/O rule was not independently observed.");
                            store.RequestStop(); worker.Finish(8000); worker.Dispose(); worker = null;
                            if (IoPriority.Read(background.Process) != 2 || store.Status().State?.Status != "stopped")
                                throw new InvalidOperationException("The live I/O fixture did not restore its original priority.");
                            worker = new CapturedProcess(dotnet, [hostPath, "policy-run", request]);
                            wait.Restart();
                            while (IoPriority.Read(background.Process) != priority && wait.Elapsed < TimeSpan.FromSeconds(15))
                            {
                                worker.RequireAlive(); Thread.Sleep(20);
                            }
                            if (IoPriority.Read(background.Process) != priority) throw new InvalidOperationException("The I/O rule did not resume on the live fixture.");
                        }
                        var foregroundIdentity = Identity(foreground.Process);
                        var backgroundIdentity = Identity(background.Process);
                        var clock = Stopwatch.StartNew();
                        start.Set();
                        while (clock.Elapsed < TimeSpan.FromSeconds(Warmup + seconds))
                        {
                            foreground.RequireAlive(); background.RequireAlive();
                            if (IoPriority.Read(foreground.Process) != 2 || IoPriority.Read(background.Process) != (enabled ? priority : 2))
                                throw new InvalidOperationException("A competing I/O-priority change invalidated the trial.");
                            foreground.Process.Refresh(); background.Process.Refresh();
                            if (foreground.Process.PriorityClass != ProcessPriorityClass.Normal || background.Process.PriorityClass != ProcessPriorityClass.Normal)
                                throw new InvalidOperationException("CPU priority changed during the storage trial.");
                            Thread.Sleep(10);
                        }
                        foregroundIdentity.Verify(Identity(foreground.Process)); backgroundIdentity.Verify(Identity(background.Process));
                        stop.Set();
                        foreground.Finish(10000); background.Finish(10000);
                        if (worker is not null)
                        {
                            store.RequestStop(); worker.Finish(8000);
                            var state = store.Status().State;
                            if (state?.Status != "stopped" || state.Instances.Any(instance => instance.Status is not ("restored" or "expired")))
                                throw new InvalidOperationException("The I/O worker did not reconcile its exited fixture.");
                        }
                        File.WriteAllText(foregroundXml, foreground.Output); File.WriteAllText(backgroundXml, background.Output);
                        var front = ReadMetrics(foreground.Output, foregroundFile, 4096, 1, seconds);
                        var back = ReadMetrics(background.Output, backgroundFile, 131072, 32, seconds);
                        if (Math.Abs(front.Seconds - back.Seconds) > .05) throw new InvalidDataException("The synchronized I/O measurement durations disagree.");
                        trials.Add(new { block, enabled, requestedIoPriority = enabled ? priority : 2, liveRestoreVerified = enabled, exitedFixtureReconciled = true,
                            foregroundIdentity, backgroundIdentity, foreground = front, background = back,
                            foregroundXml, backgroundXml, foregroundArgs, backgroundArgs });
                        OperationFiles.Write(output, new { status = "running", binaries, blocks, seconds, priority, trials });
                        Console.WriteLine($"Storage block {block + 1}/{blocks}: {(enabled ? "Roo rule" : "normal priority")}, foreground p99 {front.P99Milliseconds:F3} ms, background {back.BytesPerSecond / 1048576:F1} MiB/s");
                    }
                    finally
                    {
                        stop.Set(); start.Set();
                        if (worker is not null)
                        {
                            try { if (!worker.Process.HasExited) store.RequestStop(); }
                            finally { worker.Dispose(); }
                        }
                        if (!File.Exists(foregroundXml) && foreground.Process.WaitForExit(5000)) File.WriteAllText(foregroundXml, foreground.Output);
                        if (!File.Exists(backgroundXml) && background.Process.WaitForExit(5000)) File.WriteAllText(backgroundXml, background.Output);
                    }
                }
            }
            if (OperationFiles.HashFile(foregroundFile) != hashes[0] || OperationFiles.HashFile(backgroundFile) != hashes[1])
                throw new InvalidDataException("A read-only workload changed its disposable file contents.");
        }
        finally { Directory.Delete(root, true); }
        OperationFiles.Write(output, new
        {
            schemaVersion = 1, status = "completed", measuredAtUtc = DateTime.UtcNow, machine = Environment.MachineName,
            binaries, blocks, seconds, priority, fileBytes = FileBytes, warmup = Warmup, seed = 16092026,
            trials, externalBefore, externalAfter = Controllers(), fixturesRemoved = !Directory.Exists(root),
            conditions = new[] { "Only new disposable files were read; no raw disk or partition target was used.",
                "DiskSpd default file-I/O priority was retained; the treatment changes process I/O priority through the real saved-rule host.",
                "Foreground: 4 KiB random reads, queue depth 1. Background: 128 KiB sequential reads, queue depth 32. One thread each; software caching disabled.",
                "Default DiskSpd CPU affinity is disabled. Both process CPU priorities remain Normal. No power plan or driver configuration is changed.",
                "Existing Lasso and other software remain active; this is not an isolated comparison against Lasso or a gaming benchmark." },
        });
    }

    static string[] Arguments(string target, string prefix, bool foreground, int seconds) =>
        ["-d" + (seconds + 30), "-W" + Warmup, "-C0", "-t1", foreground ? "-o1" : "-o32", foreground ? "-b4k" : "-b128k",
            foreground ? "-r" : "-s", "-Su", "-n", "-L", "-Rxml", "-w0", "-z16092026", "-yr" + prefix + "-start", "-yp" + prefix + "-stop",
            target];

    static void CreateData(string path)
    {
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        if ((File.GetAttributes(path) & (FileAttributes.Compressed | FileAttributes.Encrypted | FileAttributes.SparseFile)) != 0)
            throw new InvalidDataException("The test needs ordinary uncompressed, unencrypted files.");
        var buffer = new byte[1024 * 1024]; RandomNumberGenerator.Fill(buffer);
        for (long position = 0; position < FileBytes; position += buffer.Length) file.Write(buffer);
        file.Flush(true);
    }
    static RunningProcess Identity(Process process) { using var target = new ProcessTarget(process.Id); return target.Identity(); }
    internal sealed record Metrics(double Seconds, long ReadCount, long ReadBytes, double P50Milliseconds, double P95Milliseconds, double P99Milliseconds, double AverageMilliseconds, string PowerScheme)
    { public double BytesPerSecond => ReadBytes / Seconds; }
    internal static Metrics ReadMetrics(string text, string path, int blockBytes, int queue, int seconds)
    {
        var root = XDocument.Parse(text).Root ?? throw new InvalidDataException("DiskSpd returned no XML root.");
        var profile = root.Element("Profile")!.Element("TimeSpans")!.Elements("TimeSpan").Single();
        var target = profile.Element("Targets")!.Elements("Target").Single();
        if (target.Element("Path")!.Value != path || Number(target, "BlockSize") != blockBytes || Number(target, "RequestCount") != queue ||
            Number(target, "WriteRatio") != 0 || Number(target, "IOPriority") != 3 || target.Element("DisableOSCache")!.Value != "true" ||
            profile.Element("DisableAffinity")!.Value != "true" || Number(profile, "Duration") != seconds + 30 || Number(profile, "Warmup") != Warmup)
            throw new InvalidDataException("The actual DiskSpd profile differs from the reviewed read workload.");
        var run = root.Elements("TimeSpan").Single();
        var elapsed = Number(run, "TestTimeSeconds");
        var result = run.Elements("Thread").Single().Elements("Target").Single();
        var reads = checked((long)Number(result, "ReadCount"));
        var bytes = checked((long)Number(result, "ReadBytes"));
        if (Math.Abs(elapsed - seconds) > .25 || reads <= 0 || bytes != reads * blockBytes || Number(result, "WriteCount") != 0 ||
            Number(result, "WriteBytes") != 0 || result.Element("Path")!.Value != path || Number(result, "FileSize") != FileBytes)
            throw new InvalidDataException("DiskSpd did not complete the expected read-only workload.");
        var latency = run.Element("Latency") ?? throw new InvalidDataException("Latency measurement is missing.");
        double Percentile(double value) => Number(latency.Elements("Bucket").Single(item => Number(item, "Percentile") == value), "ReadMilliseconds");
        return new(elapsed, reads, bytes, Percentile(50), Percentile(95), Percentile(99), Number(latency, "AverageReadMilliseconds"),
            root.Element("System")!.Element("PowerScheme")!.Attribute("Guid")!.Value);
    }
    static double Number(XElement element, string name)
    {
        var value = double.Parse(element.Element(name)?.Value ?? throw new InvalidDataException("Missing DiskSpd field: " + name), CultureInfo.InvariantCulture);
        return double.IsFinite(value) && value >= 0 ? value : throw new InvalidDataException("Invalid DiskSpd field: " + name);
    }
    static object[] Controllers() => Process.GetProcessesByName("ProcessGovernor").Concat(Process.GetProcessesByName("ProcessLasso")).Select(process =>
    {
        using (process) return (object)new { name = process.ProcessName, processId = process.Id, createdAtUtc = process.StartTime.ToUniversalTime(), binarySha256 = OperationFiles.HashFile(process.MainModule!.FileName) };
    }).ToArray();
}

sealed class CapturedProcess : IDisposable
{
    public Process Process { get; }
    readonly Task<string> _output, _errors;
    public string Output => _output.GetAwaiter().GetResult();
    public CapturedProcess(string executable, string[] arguments)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        Process = Process.Start(start) ?? throw new InvalidOperationException("Measurement process did not start.");
        _output = Process.StandardOutput.ReadToEndAsync(); _errors = Process.StandardError.ReadToEndAsync();
    }
    public void RequireAlive() { if (Process.HasExited) throw new InvalidOperationException(Path.GetFileName(Process.StartInfo.FileName) + " exited early with code " + Process.ExitCode + ": " + _errors.GetAwaiter().GetResult()); }
    public void Finish(int milliseconds)
    {
        if (!Process.WaitForExit(milliseconds)) throw new TimeoutException("Measurement process did not exit in time.");
        if (Process.ExitCode != 0) throw new InvalidOperationException("Measurement process exit " + Process.ExitCode + ": " + _errors.GetAwaiter().GetResult());
    }
    public void Dispose()
    {
        try
        {
            if (!Process.HasExited && !Process.WaitForExit(10000)) { Process.Kill(); if (!Process.WaitForExit(10000)) throw new TimeoutException("Owned measurement process did not terminate."); }
        }
        finally { Process.Dispose(); }
    }
}

static class IoPriority
{
    public static int Read(Process process)
    {
        var value = 0; Check(NtQueryInformationProcess(process.Handle, 33, ref value, 4, IntPtr.Zero), "NtQueryInformationProcess(ProcessIoPriority)"); return value;
    }
    public static void Set(Process process, int value) { Check(NtSetInformationProcess(process.Handle, 33, ref value, 4), "NtSetInformationProcess(ProcessIoPriority)"); if (Read(process) != value) throw new InvalidOperationException("I/O-priority normalization was not observed."); }
    static void Check(int status, string api) { if (status < 0) throw new InvalidOperationException(api + " failed with NTSTATUS 0x" + unchecked((uint)status).ToString("X8")); }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref int value, int length, IntPtr returned);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int value, int length);
}
