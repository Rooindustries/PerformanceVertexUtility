using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;
using Roo.Optimizer;

static class RetainedGpuChecks
{
    sealed class CleanupSignal : Exception { }
    static readonly string Bin = Path.GetDirectoryName(typeof(RetainedGpuChecks).Assembly.Location)!;
    static readonly string GamePath = Path.Combine(Bin, "RooLaunchPolicyProbe.exe");
    static void Until(Func<bool> condition, string message, int seconds = 30)
    {
        var clock = Stopwatch.StartNew();
        while (!condition()) { if (clock.Elapsed.TotalSeconds > seconds) throw new TimeoutException(message); Thread.Sleep(20); }
    }
    static Process Start(string executable, params string[] args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("Fixture did not start.");
    }

    internal static void Run(string repo, string dotnet)
    {
        Environment.SetEnvironmentVariable("DOTNET_ROOT_X64", Path.GetDirectoryName(dotnet));
        var root = Path.Combine(Path.GetTempPath(), "roo-retained-gpu-check-" + Guid.NewGuid().ToString("N"));
        var launcherPath = Path.Combine(Bin, "RooRetainedLauncher.exe");
        Directory.CreateDirectory(root); File.Copy(GamePath, launcherPath, false);
        var engine = new ProtectedSessions(_ => false);
        var states = new List<string>(); var workers = new List<Process>();
        var proof = new List<object>(); var passed = 0;
        void Check(bool result, string message) { if (!result) throw new InvalidOperationException(message); Console.WriteLine("PASS " + message); passed++; }
        var classifier = typeof(ProtectedSessions).Assembly.GetType("Roo.Optimizer.LaunchGpuHandles")!
            .GetMethod("Initializing", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic)!
            .CreateDelegate<Func<ControlRead, RunningProcess, bool>>();
        ControlRead Failure(long code, string api = "D3DKMTGetProcessSchedulingPriorityClass", string kind = "ntstatus")
            => ControlRead.Failed(new(api, kind, code, "0x101200", "fixture"));
        RunningProcess Age(int seconds) => new(1, DateTime.UtcNow.AddSeconds(-seconds).ToFileTimeUtc().ToString(), GamePath);
        Check(classifier(Failure(0xC000000D), Age(10)), "A recent invalid-parameter GPU result may wait for initialization");
        Check(!classifier(Failure(0xC000000D), Age(100)), "The same GPU result after the initialization window cannot keep waiting");
        Check(!classifier(Failure(0xC0000022), Age(10)), "Access denied is never reclassified as pending initialization");
        Check(!classifier(new ControlRead(false, null, null), Age(10)), "Missing error evidence does not imply initialization");
        Check(!classifier(ControlRead.From(2), Age(10)), "A known original is not an initialization failure");
        Check(!classifier(Failure(0xC000000D, "OpenProcess"), Age(10)), "An error from a different API cannot authorize initialization waiting");
        Check(!classifier(Failure(0xC000000D, kind: "win32"), Age(10)), "An error from a different status namespace cannot authorize initialization waiting");
        ProtectedSessionState State(string path) => engine.Status(path).State ?? throw new InvalidDataException("Missing state.");
        using var launcher = Start(launcherPath, "--retained-launcher", root);
        try
        {
            Until(() => File.Exists(Path.Combine(root, "launcher-ready")), "Fixture launcher not ready.");
            for (var trial = 0; trial < 8; trial++)
            {
                var session = Path.Combine(root, "session-" + trial); states.Add(session);
                var previewPath = Path.Combine(root, "preview-" + trial + ".json");
                OperationFiles.Write(previewPath, engine.Preview(launcher.Id, GamePath, new() { ["gpuPriority"] = JsonSerializer.SerializeToElement(3) }, true));
                var request = Path.Combine(session, "request.json");
                OperationFiles.Write(request, new { schemaVersion = 1, repoRoot = Path.GetFullPath(repo), sessionRoot = session, previewPath, reviewHash = OperationFiles.HashFile(previewPath), confirm = true });
                var worker = Start(Path.Combine(repo, "backend", "bin", "optimizer", "session", "Roo.SessionHost.exe"), "run", request); workers.Add(worker);
                Until(() => File.Exists(Path.Combine(session, "session.json")) && State(session).Status == "armed", "GPU session did not arm.");
                var gameRoot = Path.Combine(root, "game-" + trial); Directory.CreateDirectory(gameRoot);
                OperationFiles.Write(Path.Combine(root, "launch.json"), new { root = gameRoot, session });
                Until(() => File.Exists(Path.Combine(gameRoot, "born.json")), "GPU fixture not born.");
                var born = OperationFiles.Read<JsonElement>(Path.Combine(gameRoot, "born.json"));
                using var game = Process.GetProcessById(born.GetProperty("pid").GetInt32());
                _ = game.Handle;
                File.WriteAllText(Path.Combine(gameRoot, "oracle-ready"), "");
                Until(() => File.Exists(Path.Combine(gameRoot, "locked.json")), "GPU fixture did not restrict later handles.");
                var locked = OperationFiles.Read<JsonElement>(Path.Combine(gameRoot, "locked.json")).GetProperty("atUtc").GetDateTime();
                bool denied = false;
                try { using var fresh = new ProcessTarget(game.Id, readControls: ["gpuPriority"]); denied = !fresh.Read("gpuPriority").Known; }
                catch (Roo.Optimization.CpuSets.NativeFailure failure) when (failure.NativeErrorCode == 5) { denied = true; }
                Check(denied, "A fresh GPU control handle is denied on the disposable fixture");
                if (trial is >= 4 and < 7)
                {
                    Until(() => Directory.GetFiles(Path.Combine(session, "gpu-handles"), "*.ready.json").Length == 1, "Recovery readback missing.");
                    var readyPath = Directory.GetFiles(Path.Combine(session, "gpu-handles"), "*.ready.json").Single();
                    Check(State(session).Games.All(item => item.Fields.All(value => value.JournalPath is null)), "Negative fixture changes recovery evidence before any apply");
                    var changed = JsonNode.Parse(File.ReadAllText(readyPath))!;
                    if (trial == 4) { changed["original"]!["known"] = false; changed["original"]!["value"] = 3; }
                    if (trial == 5) changed["original"]!["value"] = 1;
                    if (trial == 6) changed["transfer"]!["operationId"] = Guid.NewGuid().ToString("N");
                    OperationFiles.Write(readyPath, changed);
                    Until(() => State(session).Games.Any(item => item.Fields.Any(value => value.Status == "conflict")), "Contradictory recovery evidence was accepted.");
                    Check(Oracle.Gpu(game) == 2 && State(session).Games.Single().Fields.Single().JournalPath is null, "Unknown, conflicting or stale recovery evidence cannot authorize a GPU change");
                    engine.Command(session, "stop");
                    Check(worker.WaitForExit(20000), "Rejected session stops");
                    Until(() => File.Exists(Path.Combine(session, "recovery-result.json")), "Rejected session watcher did not finish.");
                    Check(Oracle.Gpu(game) == 2, "Rejected recovery evidence leaves original GPU class unchanged");
                    proof.Add(new { trial, game.Id, actual = Oracle.Gpu(game), state = State(session) });
                    File.WriteAllText(Path.Combine(gameRoot, "stop"), "");
                    Check(game.WaitForExit(15000) && game.ExitCode == 0, "Rejected fixture exits successfully");
                    continue;
                }
                Until(() => State(session).Status == "active", "Retained GPU session did not apply.");
                var field = State(session).Games.Single().Fields.Single();
                var journal = OperationFiles.Read<ProcessControlJournal>(field.JournalPath!);
                Check(journal.UpdatedAtUtc >= locked && Oracle.Gpu(game) == 3, "The actual GPU class changes after fresh access is denied");
                var ready = Directory.GetFiles(Path.Combine(session, "gpu-handles"), "*.ready.json").Single();
                var ack = OperationFiles.Read<JsonElement>(ready);
                Check(ack.GetProperty("original").GetProperty("known").GetBoolean() && ack.GetProperty("original").GetProperty("value").GetInt32() == 2, "The separate watcher independently captured original class 2");
                if (trial == 7) throw new CleanupSignal();
                if (trial == 0)
                {
                    for (var tick = 0; tick < 12; tick++) { Check(Oracle.Gpu(game) == 3, "Independent sustained GPU class readback is 3"); Thread.Sleep(1000); }
                    Oracle.SetGpu(game, 2);
                    Until(() => Oracle.Gpu(game) == 3 && State(session).Games.Single().Fields.Single().Reapplications > 0, "Original-value reset was not reapplied.");
                    Check(true, "Retained handle reapplies a reset to its captured original");
                    engine.Command(session, "stop");
                }
                else if (trial == 1) worker.Kill();
                else if (trial == 2)
                {
                    Oracle.SetGpu(game, 1);
                    Until(() => State(session).Games.Single().Fields.Single().Status == "conflict", "Foreign class was not reported.");
                    engine.Command(session, "stop");
                }
                else
                {
                    var watch = OperationFiles.Read<ProtectedWatchReady>(Path.Combine(session, "watch.json"));
                    using var watcher = Process.GetProcessById(watch.Watcher.ProcessId);
                    Check(watcher.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() == watch.Watcher.CreationTimeFileTimeUtc, "Crash test binds to the owned watcher identity");
                    watcher.Kill(); watcher.WaitForExit(10000);
                }
                Check(worker.WaitForExit(20000), "The owned controller exits");
                if (trial != 3) Until(() => File.Exists(Path.Combine(session, "recovery-result.json")), "Recovery watcher did not finish.");
                var actual = Oracle.Gpu(game);
                Check(actual == (trial == 2 ? 1 : 2), trial == 2 ? "A foreign GPU class is preserved during stop and recovery" : "Actual GPU class restores through a retained handle");
                Check(State(session).Status == (trial == 2 ? "recoveryRequired" : trial == 3 ? "stoppedWithErrors" : "stopped"), "Session outcome matches independent recovery evidence");
                proof.Add(new { trial, game.Id, actual, locked, journal.UpdatedAtUtc, state = State(session) });
                File.WriteAllText(Path.Combine(gameRoot, "stop"), "");
                Check(game.WaitForExit(15000) && game.ExitCode == 0, "Owned GPU workload exits successfully");
                var gpu = OperationFiles.Read<JsonElement>(Path.Combine(gameRoot, "gpu-result.json"));
                Check(gpu.GetProperty("adapter").GetProperty("vendorId").GetUInt32() == 0x1002 && gpu.GetProperty("adapter").GetProperty("deviceId").GetUInt32() == 0x7550 && gpu.GetProperty("dispatches").GetInt64() > 0 && gpu.GetProperty("verified").GetArrayLength() == 4, "RX9070XT GPU output is independently verified");
            }
        }
        catch (CleanupSignal) { Check(true, "A controlled failure while GPU class 3 is active exercises fixture cleanup"); }
        finally
        {
            foreach (var worker in workers) { if (!worker.HasExited) { worker.Kill(); worker.WaitForExit(10000); } worker.Dispose(); }
            File.WriteAllText(Path.Combine(root, "stop-launcher"), "");
            if (!launcher.WaitForExit(15000)) { launcher.Kill(); launcher.WaitForExit(10000); }
            foreach (var session in states)
            {
                var watchPath = Path.Combine(session, "watch.json");
                if (File.Exists(watchPath))
                {
                    var identity = OperationFiles.Read<ProtectedWatchReady>(watchPath).Watcher;
                    try
                    {
                        using var watcher = Process.GetProcessById(identity.ProcessId);
                        _ = watcher.SafeHandle;
                        if (watcher.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() != identity.CreationTimeFileTimeUtc) throw new InvalidDataException("Fixture watcher identity changed.");
                        if (!watcher.WaitForExit(20000)) throw new TimeoutException("Fixture watcher did not finish before cleanup.");
                    }
                    catch (ArgumentException) { }
                }
                if (File.Exists(Path.Combine(session, "session.json"))) engine.Recover(session, State(session).Preview.OperationId);
            }
            File.Delete(launcherPath); Directory.Delete(root, true);
        }
        Check(!Directory.Exists(root), "Fixture cleanup waits for the recovery watcher and removes its directory");
        OperationFiles.Write(Path.Combine(repo, "artifacts", "validation", "retained-gpu-result.json"), new { passed, proof });
        Console.WriteLine("Retained GPU assertions: " + passed);
    }

    internal static void Launcher(string root)
    {
        var children = new List<Process>(); File.WriteAllText(Path.Combine(root, "launcher-ready"), "");
        try
        {
            var until = DateTime.UtcNow.AddMinutes(8);
            while (!File.Exists(Path.Combine(root, "stop-launcher")) && DateTime.UtcNow < until)
            {
                var path = Path.Combine(root, "launch.json");
                if (File.Exists(path))
                {
                    var request = OperationFiles.Read<JsonElement>(path); File.Delete(path);
                    children.Add(Start(GamePath, "--retained-game", request.GetProperty("root").GetString()!, request.GetProperty("session").GetString()!));
                }
                Thread.Sleep(20);
            }
        }
        finally { foreach (var child in children) { if (!child.HasExited) { child.Kill(); child.WaitForExit(10000); } child.Dispose(); } }
    }

    internal static void Game(string root, string session)
    {
        using var self = Process.GetCurrentProcess(); _ = self.Handle;
        OperationFiles.Write(Path.Combine(root, "born.json"), new { pid = self.Id });
        var transfer = Path.Combine(session, "gpu-handles", self.Id + "-" + self.StartTime.ToUniversalTime().ToFileTimeUtc() + ".transfer.json");
        Until(() => File.Exists(transfer) && File.Exists(Path.Combine(root, "oracle-ready")), "Handles were not captured before fixture restriction.");
        DenyNewGpuHandles(self);
        OperationFiles.Write(Path.Combine(root, "locked.json"), new { atUtc = DateTime.UtcNow });
        using var gpu = new GpuWorkload(0x1002, 0x7550, 16384, 256);
        var until = DateTime.UtcNow.AddMinutes(5);
        while (!File.Exists(Path.Combine(root, "stop")) && DateTime.UtcNow < until) { gpu.Run(1); Thread.Sleep(10); }
        OperationFiles.Write(Path.Combine(root, "gpu-result.json"), new { gpu.Adapter, gpu.Dispatches, verified = gpu.VerifyOutput() });
    }

    static void DenyNewGpuHandles(Process self)
    {
        GetKernelObjectSecurity(self.Handle, 4, null, 0, out var needed);
        var bytes = new byte[needed];
        if (!GetKernelObjectSecurity(self.Handle, 4, bytes, needed, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var security = new RawSecurityDescriptor(bytes, 0);
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User ?? throw new InvalidOperationException("Fixture SID missing.");
        if (security.DiscretionaryAcl is null) throw new InvalidOperationException("Fixture DACL missing.");
        security.DiscretionaryAcl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied, 0x200, sid, false, null));
        bytes = new byte[security.BinaryLength]; security.GetBinaryForm(bytes, 0);
        if (!SetKernelObjectSecurity(self.Handle, 4, bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetKernelObjectSecurity(IntPtr handle, uint information, byte[]? descriptor, uint length, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetKernelObjectSecurity(IntPtr handle, uint information, byte[] descriptor);
}
