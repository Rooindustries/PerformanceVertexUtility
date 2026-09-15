using System.Diagnostics;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Roo.Optimizer;

static class CpuContention
{
    sealed record Request(string Directory, string EventPrefix, ulong Affinity, int DurationSeconds, int Iterations);
    sealed record Sample(double ScheduledMs, double WakeMs, double FinishedMs);
    sealed record WorkResult(int ProcessId, string CreationTime, long Operations, uint Checksum, double Seconds, Sample[] Samples);

    public static void Run(string[] args)
    {
        if (args is ["--cpu-foreground", var foreground]) { Work(OperationFiles.Read<Request>(foreground), true); return; }
        if (args is ["--cpu-background", var background]) { Work(OperationFiles.Read<Request>(background), false); return; }
        if (args is not ["--cpu-measure", var repository, var dotnet, var output, var blocksText, var durationText])
            throw new ArgumentException("CPU measurement needs repository, dotnet, output, paired-block count and trial seconds.");
        var blocks = int.Parse(blocksText);
        var seconds = int.Parse(durationText);
        if (blocks is < 1 or > 30 || seconds is < 3 or > 60) throw new ArgumentException("Use 1–30 paired blocks and 3–60 seconds per trial.");
        Measure(Path.GetFullPath(repository), Path.GetFullPath(dotnet), Path.GetFullPath(output), blocks, seconds);
    }

    static void Measure(string repository, string dotnet, string output, int blocks, int seconds)
    {
        using var self = new ProcessTarget(Environment.ProcessId);
        var topology = self.Topology();
        var cpu = topology.Where(cpu => cpu.Available && cpu.Group == 0).OrderByDescending(cpu => cpu.Efficiency).ThenBy(cpu => cpu.Index).First();
        var root = Path.Combine(Path.GetTempPath(), "roo-cpu-measure-" + Guid.NewGuid().ToString("N"));
        var foregroundExe = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath)!, "RooCpuForeground.exe");
        var backgroundExe = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath)!, "RooCpuBackground.exe");
        var hostPath = Path.Combine(repository, "backend", "bin", "optimizer", "Optimizer.Host.dll");
        using var fixtureLease = OperationFiles.Lock(Path.Combine(Path.GetDirectoryName(foregroundExe)!, "cpu-measure"));
        if (File.Exists(foregroundExe) || File.Exists(backgroundExe)) throw new IOException("A CPU measurement executable already exists.");
        var foregroundCreated = false;
        var backgroundCreated = false;
        var trials = new List<object>();
        var random = new Random(16092026);
        var binaries = new { benchmark = OperationFiles.HashFile(Environment.ProcessPath!), assembly = OperationFiles.HashFile(typeof(CpuContention).Assembly.Location),
            host = OperationFiles.HashFile(hostPath), core = OperationFiles.HashFile(Path.Combine(Path.GetDirectoryName(hostPath)!, "Optimizer.Core.dll")) };
        var externalBefore = Controllers();
        OperationFiles.Write(output, new { status = "running", startedAtUtc = DateTime.UtcNow, binaries, blocks, seconds, trials });
        try
        {
            Directory.CreateDirectory(root);
            File.Copy(Environment.ProcessPath!, foregroundExe);
            foregroundCreated = true;
            File.Copy(Environment.ProcessPath!, backgroundExe);
            backgroundCreated = true;
            for (var block = 0; block < blocks; block++)
            {
                var order = random.Next(2) == 0 ? new[] { false, true } : new[] { true, false };
                foreach (var enabled in order)
                {
                    var trial = Path.Combine(root, "trial-" + Guid.NewGuid().ToString("N"));
                    Directory.CreateDirectory(trial);
                    var request = new Request(trial, "Local\\RooCpuMeasure-" + Guid.NewGuid().ToString("N"), 1ul << cpu.Index, seconds, 500000);
                    using var startEvent = new EventWaitHandle(false, EventResetMode.ManualReset, request.EventPrefix + "-start");
                    using var exitEvent = new EventWaitHandle(false, EventResetMode.ManualReset, request.EventPrefix + "-exit");
                    var path = Path.Combine(trial, "request.json");
                    OperationFiles.Write(path, request);
                    var store = new ProcessPolicyStore(Path.Combine(trial, "policies"));
                    Process? worker = null, foreground = null, background = null;
                    Task<string>? workerOutput = null, workerErrors = null;
                    try
                    {
                        foreground = Start(foregroundExe, "--cpu-foreground", path);
                        background = Start(backgroundExe, "--cpu-background", path);
                        WaitReady(trial, foreground, background);
                        var original = Priority(background);
                        if (original != ProcessPriorityClass.Normal || Priority(foreground) != ProcessPriorityClass.Normal)
                            throw new InvalidOperationException("Another controller changed the normalized fixture priority before measurement.");
                        if (enabled)
                        {
                            store.Save(new SavedProcessRule
                            {
                                SchemaVersion = 1, RuleId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(), Name = "CPU contention measurement",
                                Enabled = true, MatchMode = "path", ExecutablePath = backgroundExe, ExecutableHash = OperationFiles.HashFile(backgroundExe), CpuSelection = null,
                                Controls = new() { ["cpuPriority"] = JsonSerializer.SerializeToElement("BelowNormal") },
                            });
                            var workerRequest = Path.Combine(trial, "worker-request.json");
                            OperationFiles.Write(workerRequest, new { schemaVersion = 1, repoRoot = repository, policyRoot = store.Root, confirm = true });
                            worker = Start(dotnet, hostPath, "policy-run", workerRequest);
                            workerOutput = worker.StandardOutput.ReadToEndAsync();
                            workerErrors = worker.StandardError.ReadToEndAsync();
                            var deadline = Stopwatch.StartNew();
                            while (Priority(background) != ProcessPriorityClass.BelowNormal && deadline.Elapsed < TimeSpan.FromSeconds(15))
                            {
                                if (worker.HasExited) throw new InvalidOperationException("The policy worker exited before applying the fixture rule.");
                                Thread.Sleep(20);
                            }
                            if (Priority(background) != ProcessPriorityClass.BelowNormal) throw new InvalidOperationException("The fixture rule was not independently observed.");
                        }
                        var backgroundPriority = Priority(background);
                        var foregroundPriority = Priority(foreground);
                        VerifyPlacement(foreground, request.Affinity); VerifyPlacement(background, request.Affinity);
                        var foregroundCpuBefore = foreground.TotalProcessorTime.TotalSeconds;
                        var backgroundCpuBefore = background.TotalProcessorTime.TotalSeconds;
                        startEvent.Set();
                        var timer = Stopwatch.StartNew();
                        var foregroundPath = Path.Combine(trial, "foreground-result.json");
                        var backgroundPath = Path.Combine(trial, "background-result.json");
                        while ((!File.Exists(foregroundPath) || !File.Exists(backgroundPath)) && timer.Elapsed < TimeSpan.FromSeconds(seconds + 30))
                        {
                            if (foreground.HasExited || background.HasExited) throw new InvalidOperationException("A fixture exited before reporting its workload result.");
                            if (Priority(background) != backgroundPriority || Priority(foreground) != foregroundPriority)
                                throw new InvalidOperationException("A competing priority change invalidated the trial.");
                            VerifyPlacement(foreground, request.Affinity); VerifyPlacement(background, request.Affinity);
                            Thread.Sleep(100);
                        }
                        var front = OperationFiles.Read<WorkResult>(foregroundPath);
                        var back = OperationFiles.Read<WorkResult>(backgroundPath);
                        VerifyResult(front, foreground); VerifyResult(back, background);
                        if (front.Samples.Length != seconds * 50 || front.Operations != (long)front.Samples.Length * request.Iterations || back.Operations <= 0)
                            throw new InvalidOperationException("A workload did not complete its independently specified work.");
                        if (Priority(background) != backgroundPriority || Priority(foreground) != foregroundPriority)
                            throw new InvalidOperationException("A competing priority change invalidated the trial.");
                        VerifyPlacement(foreground, request.Affinity); VerifyPlacement(background, request.Affinity);
                        var foregroundCpuSeconds = foreground.TotalProcessorTime.TotalSeconds - foregroundCpuBefore;
                        var backgroundCpuSeconds = background.TotalProcessorTime.TotalSeconds - backgroundCpuBefore;
                        if (backgroundCpuSeconds < seconds * .5 || foregroundCpuSeconds < seconds * .01)
                            throw new InvalidOperationException("Independent process CPU time does not establish the intended contention workload.");
                        double? workerCpuSeconds = null;
                        if (worker is not null)
                        {
                            worker.Refresh(); workerCpuSeconds = worker.TotalProcessorTime.TotalSeconds;
                            store.RequestStop();
                            if (!worker.WaitForExit(15000)) throw new InvalidOperationException("The worker did not stop and restore its fixture.");
                            if (worker.ExitCode != 0 || store.Status().State?.Status != "stopped")
                                throw new InvalidOperationException("Worker recovery was incomplete: " + workerOutput!.GetAwaiter().GetResult() + workerErrors!.GetAwaiter().GetResult());
                        }
                        if (Priority(background) != original || Priority(foreground) != ProcessPriorityClass.Normal)
                            throw new InvalidOperationException("The original fixture priorities were not restored.");
                        trials.Add(new { block, enabled, backgroundPriority = backgroundPriority.ToString(), foregroundPriority = foregroundPriority.ToString(),
                            restoredPriority = original.ToString(), foreground = front, background = back, foregroundCpuSeconds, backgroundCpuSeconds, workerCpuSeconds });
                        OperationFiles.Write(output, new { status = "running", binaries, blocks, seconds, trials });
                        Console.WriteLine($"CPU block {block + 1}/{blocks}: {(enabled ? "Roo rule" : "normal priority")}, background operations {back.Operations}, foreground samples {front.Samples.Length}");
                    }
                    finally
                    {
                        var failures = new List<Exception>();
                        if (worker is not null && !worker.HasExited)
                        {
                            try { store.RequestStop(); }
                            catch (Exception error) { failures.Add(error); }
                        }
                        exitEvent.Set();
                        startEvent.Set();
                        foreach (var process in new[] { worker, foreground, background })
                            try { End(process); } catch (Exception error) { failures.Add(error); }
                        if (failures.Count != 0) throw new AggregateException("Fixture shutdown was not clean.", failures);
                    }
                }
            }
            OperationFiles.Write(output, new
            {
                schemaVersion = 1, status = "completed", measuredAtUtc = DateTime.UtcNow, machine = Environment.MachineName, os = Environment.OSVersion.ToString(),
                cpu, topologyHash = CpuSelection.Fingerprint(topology), logicalProcessors = Environment.ProcessorCount, binaries,
                blocks, seconds, intervalMilliseconds = 20, iterationsPerBurst = 500000, backgroundThreads = 2, seed = 16092026,
                trials, externalBefore, externalAfter = Controllers(),
                conditions = new[] { "The desktop app remained closed; only owned disposable processes were controlled.",
                    "Both workloads use one logical CPU; this does not reserve that CPU against other software.",
                    "Dynamic priority boosts are disabled on both fixture processes. No power plan or system timer resolution is changed.",
                    "Samples measure scheduled wake-to-work completion, not input latency, CPU ready time or frame time.",
                    "The normal-priority condition has no Roo worker; the rule condition includes its worker and recovery.",
                    "Existing Lasso configuration and processes remain unchanged; this is not an isolated Windows-only or Lasso-only comparison." },
            });
        }
        finally
        {
            if (foregroundCreated) File.Delete(foregroundExe);
            if (backgroundCreated) File.Delete(backgroundExe);
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    static void Work(Request request, bool foreground)
    {
        using var process = Process.GetCurrentProcess();
        process.ProcessorAffinity = (IntPtr)unchecked((long)request.Affinity);
        process.PriorityClass = ProcessPriorityClass.Normal;
        process.PriorityBoostEnabled = false;
        using var start = EventWaitHandle.OpenExisting(request.EventPrefix + "-start");
        using var exit = EventWaitHandle.OpenExisting(request.EventPrefix + "-exit");
        uint checksum = 1;
        var warmup = Stopwatch.StartNew();
        while (warmup.Elapsed < TimeSpan.FromSeconds(1)) checksum = Mix(checksum, request.Iterations);
        File.WriteAllText(Path.Combine(request.Directory, foreground ? "foreground-ready" : "background-ready"), process.Id.ToString());
        if (!start.WaitOne(TimeSpan.FromSeconds(30))) throw new TimeoutException("The measurement start signal did not arrive.");
        if (exit.WaitOne(0)) return;
        checksum = 1;
        var clock = Stopwatch.StartNew();
        long operations = 0;
        var samples = new List<Sample>();
        if (foreground)
        {
            using var timer = CreateWaitableTimerEx(IntPtr.Zero, null, 2, 0x1f0003);
            if (timer.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            for (var index = 0; index < request.DurationSeconds * 50; index++)
            {
                if (exit.WaitOne(0)) return;
                var scheduled = index * 20d;
                var remaining = scheduled - clock.Elapsed.TotalMilliseconds;
                if (remaining > 0)
                {
                    var due = -Math.Max(1L, (long)Math.Ceiling(remaining * 10000));
                    if (!SetWaitableTimer(timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    if (WaitForSingleObject(timer, 5000) != 0) throw new TimeoutException("The fixture timer did not signal.");
                }
                var woke = clock.Elapsed.TotalMilliseconds;
                checksum = Mix(checksum, request.Iterations);
                samples.Add(new(scheduled, woke, clock.Elapsed.TotalMilliseconds));
                operations += request.Iterations;
            }
        }
        else
        {
            var counters = new long[2];
            var checksums = new uint[2];
            var threads = Enumerable.Range(0, 2).Select(index => new Thread(() =>
            {
                uint value = (uint)(index + 1);
                while (clock.Elapsed < TimeSpan.FromSeconds(request.DurationSeconds) && !exit.WaitOne(0))
                {
                    value = Mix(value, 65536);
                    counters[index] += 65536;
                }
                checksums[index] = value;
            })).ToArray();
            foreach (var thread in threads) thread.Start();
            foreach (var thread in threads) thread.Join();
            operations = counters.Sum(); checksum = checksums[0] ^ checksums[1];
        }
        var result = new WorkResult(process.Id, process.StartTime.ToUniversalTime().ToString("o"), operations, checksum, clock.Elapsed.TotalSeconds, samples.ToArray());
        OperationFiles.Write(Path.Combine(request.Directory, foreground ? "foreground-result.json" : "background-result.json"), result);
        if (!exit.WaitOne(TimeSpan.FromMinutes(1))) throw new TimeoutException("The fixture exit signal did not arrive.");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static uint Mix(uint value, int iterations)
    {
        for (var index = 0; index < iterations; index++) value = unchecked(BitOperations.RotateLeft(value ^ 0x9e3779b9u, 7) * 16777619u + (uint)index);
        return value;
    }
    static Process Start(string executable, params string[] arguments)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new InvalidOperationException("Measurement process did not start.");
    }
    static void WaitReady(string directory, Process foreground, Process background)
    {
        var clock = Stopwatch.StartNew();
        while ((!File.Exists(Path.Combine(directory, "foreground-ready")) || !File.Exists(Path.Combine(directory, "background-ready"))) && clock.Elapsed < TimeSpan.FromSeconds(15))
        {
            if (foreground.HasExited || background.HasExited) throw new InvalidOperationException("A CPU fixture exited during startup: " + (foreground.HasExited ? foreground.StandardError.ReadToEnd() : background.StandardError.ReadToEnd()));
            Thread.Sleep(20);
        }
        if (clock.Elapsed >= TimeSpan.FromSeconds(15)) throw new TimeoutException("CPU fixtures did not become ready.");
    }
    static ProcessPriorityClass Priority(Process process) { process.Refresh(); return process.PriorityClass; }
    static void VerifyPlacement(Process process, ulong affinity)
    {
        process.Refresh();
        if (unchecked((ulong)process.ProcessorAffinity.ToInt64()) != affinity || process.PriorityBoostEnabled)
            throw new InvalidOperationException("Fixture CPU placement or dynamic-boost state changed during the trial.");
    }
    static void VerifyResult(WorkResult result, Process process)
    {
        if (result.ProcessId != process.Id || result.CreationTime != process.StartTime.ToUniversalTime().ToString("o")) throw new InvalidDataException("A result belongs to another fixture instance.");
    }
    static void End(Process? process)
    {
        if (process is null) return;
        using (process)
        {
            if (!process.WaitForExit(3000)) { process.Kill(); process.WaitForExit(); }
            if (process.ExitCode != 0) throw new InvalidOperationException("Fixture exit " + process.ExitCode + ": " + process.StandardError.ReadToEnd());
        }
    }
    static object[] Controllers() => Process.GetProcessesByName("ProcessGovernor").Concat(Process.GetProcessesByName("ProcessLasso")).Select(process =>
    {
        using (process) return (object)new { name = process.ProcessName, processId = process.Id, createdAtUtc = process.StartTime.ToUniversalTime(), binarySha256 = OperationFiles.HashFile(process.MainModule!.FileName) };
    }).ToArray();
    [DllImport("kernel32.dll", EntryPoint = "CreateWaitableTimerExW", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeWaitHandle CreateWaitableTimerEx(IntPtr attributes, string? name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long due, int period, IntPtr completion, IntPtr argument, bool resume);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(SafeWaitHandle handle, uint timeout);
}
