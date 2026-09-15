using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Roo.Optimizer;

try
{
    if (args is ["--foreground", var foreground]) GpuMeasurement.Work(OperationFiles.Read<WorkRequest>(foreground), true);
    else if (args is ["--background", var background]) GpuMeasurement.Work(OperationFiles.Read<WorkRequest>(background), false);
    else if (args is [var repository, var dotnet, var output, var blocksText, var secondsText, var vendorText, var deviceText])
    {
        var blocks = int.Parse(blocksText); var seconds = int.Parse(secondsText);
        if (blocks is < 1 or > 30 || seconds is < 3 or > 60) throw new ArgumentException("Invalid measurement duration or paired-block count.");
        GpuMeasurement.Run(Path.GetFullPath(repository), Path.GetFullPath(dotnet), Path.GetFullPath(output), blocks, seconds, uint.Parse(vendorText), uint.Parse(deviceText));
    }
    else throw new ArgumentException("Provide repository, dotnet, output JSON, paired blocks, seconds, vendor ID and device ID.");
}
catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }

sealed record WorkRequest(string Directory, string EventPrefix, int Seconds, uint VendorId, uint DeviceId);
sealed record Ready(RunningProcess Identity, AdapterIdentity Adapter);
sealed record GpuSample(double ScheduledMs, double SubmittedMs, double CompletedMs, double GpuMs);
sealed record WorkResult(RunningProcess Identity, AdapterIdentity Adapter, int Elements, int Iterations, long Dispatches,
    double Seconds, double GpuMilliseconds, long Polls, uint[] VerifiedValues, GpuSample[] Samples);

static class GpuMeasurement
{
    public static void Run(string repository, string dotnet, string output, int blocks, int seconds, uint vendorId, uint deviceId)
    {
        using var lease = OperationFiles.Lock(Path.Combine(Path.GetTempPath(), "roo-gpu-measure"));
        if (File.Exists(output)) throw new IOException("Choose a new output file for this experiment.");
        var root = Path.Combine(Path.GetTempPath(), "roo-gpu-measure-" + Guid.NewGuid().ToString("N"));
        var hostPath = Path.Combine(repository, "backend", "bin", "optimizer", "Optimizer.Host.dll");
        var binaries = new { benchmark = OperationFiles.HashFile(typeof(GpuMeasurement).Assembly.Location), host = OperationFiles.HashFile(hostPath),
            core = OperationFiles.HashFile(Path.Combine(Path.GetDirectoryName(hostPath)!, "Optimizer.Core.dll")),
            d3d11 = OperationFiles.HashFile(typeof(Vortice.Direct3D11.ID3D11Device).Assembly.Location) };
        var externalBefore = Controllers();
        var trials = new List<object>();
        OperationFiles.Write(output, new { status = "running", binaries, blocks, seconds, vendorId, deviceId, trials });
        Directory.CreateDirectory(root);
        try
        {
            var bin = Path.Combine(root, "bin"); Directory.CreateDirectory(bin);
            foreach (var file in Directory.GetFiles(Path.GetDirectoryName(Environment.ProcessPath)!))
                File.Copy(file, Path.Combine(bin, Path.GetFileName(file)));
            var foregroundExe = Path.Combine(bin, "RooGpuForeground.exe");
            var backgroundExe = Path.Combine(bin, "RooGpuBackground.exe");
            File.Copy(Environment.ProcessPath!, foregroundExe); File.Copy(Environment.ProcessPath!, backgroundExe);
            var random = new Random(16092026);
            for (var block = 0; block < blocks; block++)
            {
                foreach (var enabled in random.Next(2) == 0 ? new[] { false, true } : new[] { true, false })
                {
                    var directory = Path.Combine(root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
                    var request = new WorkRequest(directory, "Local\\RooGpu-" + Guid.NewGuid().ToString("N"), seconds, vendorId, deviceId);
                    var path = Path.Combine(directory, "request.json"); OperationFiles.Write(path, request);
                    using var start = new EventWaitHandle(false, EventResetMode.ManualReset, request.EventPrefix + "-start");
                    using var exit = new EventWaitHandle(false, EventResetMode.ManualReset, request.EventPrefix + "-exit");
                    var store = new ProcessPolicyStore(Path.Combine(directory, "policies"));
                    Process? foreground = null, background = null, worker = null;
                    Task<string>? workerOutput = null, workerErrors = null;
                    try
                    {
                        foreground = Start(foregroundExe, "--foreground", path);
                        background = Start(backgroundExe, "--background", path);
                        var readyClock = Stopwatch.StartNew();
                        var foregroundReadyPath = Path.Combine(directory, "foreground-ready.json");
                        var backgroundReadyPath = Path.Combine(directory, "background-ready.json");
                        while (!File.Exists(foregroundReadyPath) || !File.Exists(backgroundReadyPath))
                        {
                            Alive(foreground); Alive(background);
                            if (readyClock.Elapsed > TimeSpan.FromSeconds(30)) throw new TimeoutException("GPU fixtures did not become ready.");
                            Thread.Sleep(20);
                        }
                        var frontReady = OperationFiles.Read<Ready>(foregroundReadyPath);
                        var backReady = OperationFiles.Read<Ready>(backgroundReadyPath);
                        frontReady.Identity.Verify(Identity(foreground)); backReady.Identity.Verify(Identity(background));
                        if (frontReady.Adapter != backReady.Adapter || frontReady.Adapter.VendorId != vendorId || frontReady.Adapter.DeviceId != deviceId)
                            throw new InvalidDataException("The workloads did not select the same requested hardware adapter.");
                        GpuPriority.Set(foreground, 2); GpuPriority.Set(background, 2);
                        if (enabled)
                        {
                            store.Save(new SavedProcessRule
                            {
                                SchemaVersion = 1, RuleId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(), Name = "GPU contention measurement",
                                Enabled = true, MatchMode = "path", ExecutablePath = backgroundExe, ExecutableHash = OperationFiles.HashFile(backgroundExe), CpuSelection = null,
                                Controls = new() { ["gpuPriority"] = JsonSerializer.SerializeToElement(1) },
                            });
                            var workerRequest = Path.Combine(directory, "worker.json");
                            OperationFiles.Write(workerRequest, new { schemaVersion = 1, repoRoot = repository, policyRoot = store.Root, confirm = true });
                            worker = Start(dotnet, hostPath, "policy-run", workerRequest);
                            workerOutput = worker.StandardOutput.ReadToEndAsync(); workerErrors = worker.StandardError.ReadToEndAsync();
                            var wait = Stopwatch.StartNew();
                            while (GpuPriority.Read(background) != 1 && wait.Elapsed < TimeSpan.FromSeconds(15)) { Alive(worker); Thread.Sleep(20); }
                            if (GpuPriority.Read(background) != 1) throw new InvalidOperationException("The saved GPU-priority rule was not independently observed.");
                        }
                        var foregroundCpuBefore = foreground.TotalProcessorTime.TotalSeconds;
                        var backgroundCpuBefore = background.TotalProcessorTime.TotalSeconds;
                        start.Set();
                        var clock = Stopwatch.StartNew();
                        var foregroundResult = Path.Combine(directory, "foreground-result.json");
                        var backgroundResult = Path.Combine(directory, "background-result.json");
                        while (!File.Exists(foregroundResult) || !File.Exists(backgroundResult))
                        {
                            Alive(foreground); Alive(background);
                            foreground.Refresh(); background.Refresh();
                            if (GpuPriority.Read(foreground) != 2 || GpuPriority.Read(background) != (enabled ? 1 : 2) ||
                                foreground.PriorityClass != ProcessPriorityClass.Normal || background.PriorityClass != ProcessPriorityClass.Normal)
                                throw new InvalidOperationException("A competing control change invalidated the GPU trial.");
                            if (clock.Elapsed > TimeSpan.FromSeconds(seconds + 60)) throw new TimeoutException("GPU fixtures did not finish their measured work and verification.");
                            Thread.Sleep(50);
                        }
                        var front = OperationFiles.Read<WorkResult>(foregroundResult);
                        var back = OperationFiles.Read<WorkResult>(backgroundResult);
                        front.Identity.Verify(Identity(foreground)); back.Identity.Verify(Identity(background));
                        if (front.Adapter != frontReady.Adapter || back.Adapter != backReady.Adapter || front.Dispatches != seconds * 50 || front.Samples.Length != seconds * 50 ||
                            back.Dispatches <= 0 || front.VerifiedValues.Length != 4 || back.VerifiedValues.Length != 4 || front.GpuMilliseconds <= 0 || back.GpuMilliseconds <= 0)
                            throw new InvalidDataException("GPU work, adapter or output verification is incomplete.");
                        foreground.Refresh(); background.Refresh();
                        var foregroundCpuSeconds = foreground.TotalProcessorTime.TotalSeconds - foregroundCpuBefore;
                        var backgroundCpuSeconds = background.TotalProcessorTime.TotalSeconds - backgroundCpuBefore;
                        if (worker is not null)
                        {
                            store.RequestStop();
                            if (!worker.WaitForExit(15000)) throw new TimeoutException("GPU policy worker did not stop.");
                            if (worker.ExitCode != 0 || store.Status().State?.Status != "stopped")
                                throw new InvalidOperationException("GPU policy recovery was incomplete: " + workerOutput!.GetAwaiter().GetResult() + workerErrors!.GetAwaiter().GetResult());
                        }
                        if (GpuPriority.Read(foreground) != 2 || GpuPriority.Read(background) != 2) throw new InvalidOperationException("Original GPU priorities were not restored before exit.");
                        trials.Add(new { block, enabled, foregroundPriority = 2, backgroundPriority = enabled ? 1 : 2, restoredPriority = 2,
                            foreground = front, background = back, foregroundCpuSeconds, backgroundCpuSeconds });
                        OperationFiles.Write(output, new { status = "running", binaries, blocks, seconds, vendorId, deviceId, trials });
                        Console.WriteLine($"GPU block {block + 1}/{blocks}: {(enabled ? "Roo rule" : "normal priority")}, foreground samples {front.Samples.Length}, background dispatches {back.Dispatches}");
                    }
                    finally
                    {
                        var errors = new List<Exception>();
                        if (worker is not null && !worker.HasExited)
                            try { store.RequestStop(); } catch (Exception error) { errors.Add(error); }
                        exit.Set(); start.Set();
                        foreach (var process in new[] { worker, foreground, background })
                            try { End(process); } catch (Exception error) { errors.Add(error); }
                        if (errors.Count != 0) throw new AggregateException("GPU fixture shutdown was not clean.", errors);
                    }
                }
            }
        }
        finally { Directory.Delete(root, true); }
        OperationFiles.Write(output, new
        {
            schemaVersion = 1, status = "completed", measuredAtUtc = DateTime.UtcNow, machine = Environment.MachineName,
            binaries, blocks, seconds, vendorId, deviceId, intervalMilliseconds = 20, seed = 16092026, trials,
            externalBefore, externalAfter = Controllers(), fixturesRemoved = !Directory.Exists(root),
            conditions = new[] { "Offscreen Direct3D11 compute, with the explicitly selected hardware adapter; no software-rendering fallback.",
                "Foreground: 16384 elements and 256 integer-mix iterations every 20ms. Background: 262144 elements, 4096 iterations, four dispatches per batch.",
                "CPU scheduled-to-completion timing and GPU timestamp intervals are separate. Neither is a presented frame or input-latency measurement.",
                "Output checks use four independent CPU calculations after the timed interval. Both process CPU priorities are Normal; dynamic boosts are disabled.",
                "Existing Lasso remains active and unchanged. Only disposable processes receive the saved GPU-priority rule." },
        });
    }

    public static void Work(WorkRequest request, bool foreground)
    {
        using var process = Process.GetCurrentProcess();
        process.PriorityClass = ProcessPriorityClass.Normal; process.PriorityBoostEnabled = false;
        using var start = EventWaitHandle.OpenExisting(request.EventPrefix + "-start");
        using var exit = EventWaitHandle.OpenExisting(request.EventPrefix + "-exit");
        using var gpu = new GpuWorkload(request.VendorId, request.DeviceId, foreground ? 16384 : 262144, foreground ? 256 : 4096);
        gpu.Run(1); gpu.Run(1);
        var beforeDispatches = gpu.Dispatches; var beforePolls = gpu.Polls;
        OperationFiles.Write(Path.Combine(request.Directory, foreground ? "foreground-ready.json" : "background-ready.json"), new Ready(Identity(process), gpu.Adapter));
        if (!start.WaitOne(TimeSpan.FromSeconds(30))) throw new TimeoutException("GPU fixture start signal did not arrive.");
        if (exit.WaitOne(0)) return;
        var clock = Stopwatch.StartNew();
        var samples = new List<GpuSample>();
        double totalGpu = 0;
        if (foreground)
        {
            using var timer = CreateWaitableTimerEx(IntPtr.Zero, null, 2, 0x1f0003);
            if (timer.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            for (var index = 0; index < request.Seconds * 50; index++)
            {
                if (exit.WaitOne(0)) return;
                var scheduled = index * 20d;
                var remaining = scheduled - clock.Elapsed.TotalMilliseconds;
                if (remaining > 0)
                {
                    var due = -Math.Max(1L, (long)Math.Ceiling(remaining * 10000));
                    if (!SetWaitableTimer(timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    if (WaitForSingleObject(timer, 5000) != 0) throw new TimeoutException("GPU fixture timer did not signal.");
                }
                var submitted = clock.Elapsed.TotalMilliseconds;
                var elapsed = gpu.Run(1);
                samples.Add(new(scheduled, submitted, clock.Elapsed.TotalMilliseconds, elapsed));
                totalGpu += elapsed;
            }
        }
        else
            while (clock.Elapsed < TimeSpan.FromSeconds(request.Seconds) && !exit.WaitOne(0)) totalGpu += gpu.Run(4);
        var observedSeconds = clock.Elapsed.TotalSeconds;
        var verified = gpu.VerifyOutput();
        OperationFiles.Write(Path.Combine(request.Directory, foreground ? "foreground-result.json" : "background-result.json"),
            new WorkResult(Identity(process), gpu.Adapter, gpu.Elements, gpu.Iterations, gpu.Dispatches - beforeDispatches,
                observedSeconds, totalGpu, gpu.Polls - beforePolls, verified, samples.ToArray()));
        if (!exit.WaitOne(TimeSpan.FromMinutes(1))) throw new TimeoutException("GPU fixture exit signal did not arrive.");
    }

    static RunningProcess Identity(Process process) { using var target = new ProcessTarget(process.Id); return target.Identity(); }
    static Process Start(string executable, params string[] arguments)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new InvalidOperationException("GPU measurement process did not start.");
    }
    static void Alive(Process process) { if (process.HasExited) throw new InvalidOperationException(Path.GetFileName(process.StartInfo.FileName) + " exited early: " + process.StandardError.ReadToEnd()); }
    static void End(Process? process)
    {
        if (process is null) return;
        using (process)
        {
            if (!process.WaitForExit(15000)) { process.Kill(); process.WaitForExit(); }
            if (process.ExitCode != 0) throw new InvalidOperationException("GPU fixture exit " + process.ExitCode + ": " + process.StandardError.ReadToEnd());
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

static class GpuPriority
{
    public static int Read(Process process) { Check(D3DKMTGetProcessSchedulingPriorityClass(process.Handle, out var value), "D3DKMTGetProcessSchedulingPriorityClass"); return value; }
    public static void Set(Process process, int value) { Check(D3DKMTSetProcessSchedulingPriorityClass(process.Handle, value), "D3DKMTSetProcessSchedulingPriorityClass"); if (Read(process) != value) throw new InvalidOperationException("GPU priority normalization was not observed."); }
    static void Check(int status, string api) { if (status < 0) throw new InvalidOperationException(api + " failed with NTSTATUS 0x" + unchecked((uint)status).ToString("X8")); }
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    [DllImport("gdi32.dll")] static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr process, int value);
}
