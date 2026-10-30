using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

static class GameSessionChecks
{
    static int passed;
    static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
        passed++; Console.WriteLine("PASS " + message);
    }
    static async Task Until(Func<Task<bool>> ready, string message)
    {
        var until = DateTime.UtcNow.AddSeconds(40);
        while (!await ready()) { if (DateTime.UtcNow > until) throw new TimeoutException(message); await Task.Delay(150); }
    }
    static T Copy<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(value, OperationFiles.Json), OperationFiles.Json)!;
    static JsonElement V<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    static Process Start(string path, params string[] arguments)
    {
        var start = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["DOTNET_ROOT_X64"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet");
        return Process.Start(start) ?? throw new InvalidOperationException("Owned fixture did not start.");
    }
    static uint Gpu(Process process)
    {
        var status = D3DKMTGetProcessSchedulingPriorityClass(process.Handle, out var value);
        if (status != 0) throw new InvalidOperationException("Independent GPU getter: 0x" + status.ToString("X8"));
        return value;
    }
    static ulong Affinity(Process process)
    {
        if (!GetProcessAffinityMask(process.Handle, out var value, out _)) throw new InvalidOperationException("Independent affinity getter failed.");
        return value.ToUInt64();
    }

    public static void Display()
    {
        var game = new RunningProcess(4242, "133000000000000000", @"C:\Games\Fixture\game.exe");
        ProtectedSessionStatus Ended(string status, string fieldStatus, params string[] errors) => new(new ProtectedSessionState
        {
            SchemaVersion = 1, PreviewPath = "", ReviewHash = "", Host = game, Status = status, RegistryStatus = "restored", JobStatus = "cleared",
            Preview = new ProtectedSessionPreview
            {
                SchemaVersion = 1, OperationId = "display", Owner = new OperationOwner("PC", "S-1-5-21-0"), Launcher = game, LauncherHash = "", GamePath = game.ExecutablePath,
                GameHash = "", GameLength = 0, GameModifiedAtUtc = DateTime.UtcNow, TopologyHash = "", OriginalAffinity = new AffinityState(0, "0xF"),
                Controls = new() { ["gpuPriority"] = V(3) }, OriginalLaunchSettings = new LaunchPrioritySnapshot { ImageKeyExisted = false, OptionsKeyExisted = false, Values = new() },
                LauncherChanges = null, AcceptLauncherScope = true,
            },
            DesiredAffinity = new AffinityState(0, "0xF"), LauncherJournal = null, Errors = errors.ToList(), UpdatedAtUtc = DateTime.UtcNow,
            Games = [new ProtectedGameState { Identity = game, Fields = [new ProtectedFieldState { Name = "gpuPriority", Route = "native", Status = fieldStatus, JournalPath = @"C:\Fixture\journal.json" }] }],
        }, false, null);
        Check(GameSessionDisplay.Restored(Ended("stopped", "restored")), "A cleanly stopped session counts as restored");
        var history = Ended("stoppedWithErrors", "restored", "Native restoration needs reconciliation: gpuPriority");
        Check(GameSessionDisplay.Restored(history) && GameSessionDisplay.Title(history) == "Stopped · original settings restored", "A session recovered after an earlier error counts as restored, so a new session can start");
        Check(!GameSessionDisplay.Restored(Ended("recoveryRequired", "restored", "Native restoration needs reconciliation: gpuPriority")), "A session that still needs recovery stays outstanding");
        Check(!GameSessionDisplay.Restored(Ended("stoppedWithErrors", "conflict", "Native restoration needs reconciliation: gpuPriority")), "A field that was not put back keeps the session outstanding");
        ProtectedSessionStatus Armed(List<int>? refused) { var state = Ended("armed", "pending").State!; state.RegistryStatus = "applied"; state.JobStatus = "applied"; state.Games.Clear(); state.Refused = refused; state.UpdatedAtUtc = DateTime.UtcNow; return new(state, true, null); }
        Check(GameSessionDisplay.Title(Armed(null)) == "Ready · launch the game normally", "An armed session with no game says it's ready");
        Check(GameSessionDisplay.Title(Armed([4242])) == "Partly applied · check each setting below", "A game in the launcher that won't let the app check it shows the session as partly applied, not ready" + " | " + GameSessionDisplay.Title(Armed([4242])));
        var inherited = Ended("stopped", "leftAsIs");
        Check(GameSessionDisplay.Restored(inherited) && ProtectedSessions.IsRestored(inherited.State!), "A field the game already had when it started, left as is, doesn't keep the session outstanding");
        var starting = new ProtectedSessionStatus(null, true, null);
        Check(!GameSessionDisplay.Restored(starting) && GameSessionDisplay.Title(starting) == "Preparing the session", "A start whose worker hasn't saved anything yet shows as preparing, never as finished");
        var gaveUp = new ProtectedSessionStatus(null, false, null);
        Check(GameSessionDisplay.Restored(gaveUp), "A start that ended before saving anything counts as nothing to put back");
        Check(GameSessionDisplay.Title(gaveUp) == "Didn't start · nothing was changed" && new GameSessionEntry(Path.Combine("operations", "game-session-1", "session"), gaveUp).ToString() == "game-session-1 · didn't start",
            "A start that ended before saving anything says it didn't start and changed nothing, not that its state is unavailable");
        Check(new GameSessionEntry(Path.Combine("operations", "game-session-2", "session"), starting).ToString() == "game-session-2 · preparing" && new GameSessionEntry(Path.Combine("operations", "game-session-3", "session"), new(null, null, "x")).ToString() == "game-session-3 · state unavailable",
            "Previous sessions say a start is preparing, and keep state unavailable for a session that couldn't be read");
        Console.WriteLine("Game session display assertions: " + passed);
    }

    public static async Task Run(string repo)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-game-session-client-" + Guid.NewGuid().ToString("N"));
        var previous = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
        var bin = Path.Combine(repo, "tools", "validation", "ProtectedSessions", "bin", "publish");
        var gamePath = Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe");
        var launcherPath = Path.Combine(bin, "RooIndustriesUiSessionLauncher.exe");
        const string registryPath = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesLaunchPolicyProbe.exe";
        Directory.CreateDirectory(root);
        File.Copy(gamePath, launcherPath, false);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", repo);
        var service = new OptimizerService(new BackendLocator(), Path.Combine(root, "operations"));
        Process? launcher = null, game = null;
        GameSessionReview? review = null;
        try
        {
            using (var key = Registry.LocalMachine.OpenSubKey(registryPath)) Check(key is null, "Fixture starts without an IFEO policy");
            launcher = Start(launcherPath, "--retained-launcher", root);
            await Until(() => Task.FromResult(File.Exists(Path.Combine(root, "launcher-ready"))), "Launcher not ready.");
            var originalMask = Affinity(launcher);
            var first = originalMask & (~originalMask + 1);
            var remaining = originalMask & ~first;
            var second = remaining & (~remaining + 1);
            Check(first != 0 && second != 0, "Two available cores permit a real affinity transition");
            var desired = new Dictionary<string, JsonElement> { ["gpuPriority"] = V(3), ["affinity"] = V(new AffinityState(0, "0x" + first.ToString("X"))) };
            Check((await service.ReadGameSessionsAsync()).Length == 0, "Empty recovery storage reports no game sessions");
            review = await service.PreviewGameSessionAsync(launcher.Id, gamePath, desired, true);
            Check((await service.ReadGameSessionsAsync()).Length == 0, "A preview alone does not claim an active session or backup");
            var bytes = File.ReadAllBytes(review.PreviewPath);
            File.AppendAllText(review.PreviewPath, " ");
            var rejected = false;
            try { await service.StartGameSessionAsync(review); } catch (InvalidDataException) { rejected = true; }
            Check(rejected && !Directory.Exists(review.SessionRoot), "Changed preview bytes cannot start a session");
            File.WriteAllBytes(review.PreviewPath, bytes);
            var armed = await service.StartGameSessionAsync(review);
            Check(armed.State?.Preview.OperationId == review.Plan.OperationId && GameSessionDisplay.Title(armed).StartsWith("Ready"), "Client arms the exact reviewed session through its scheduled worker");
            using (var key = Registry.LocalMachine.OpenSubKey(registryPath)) Check(key is null, "GPU and affinity integration creates no registry policy");
            var reopened = new OptimizerService(new BackendLocator(), Path.Combine(root, "operations"));
            var history = await reopened.ReadGameSessionsAsync();
            Check(history.Length == 1 && history[0].SessionRoot == review.SessionRoot && history[0].Worker.HostRunning == true, "A new app client rediscovers the running session");
            var gameRoot = Path.Combine(root, "game"); Directory.CreateDirectory(gameRoot);
            OperationFiles.Write(Path.Combine(root, "launch.json"), new { root = gameRoot, session = review.SessionRoot });
            await Until(() => Task.FromResult(File.Exists(Path.Combine(gameRoot, "born.json"))), "Game fixture not born.");
            var born = OperationFiles.Read<JsonElement>(Path.Combine(gameRoot, "born.json"));
            game = Process.GetProcessById(born.GetProperty("pid").GetInt32()); _ = game.Handle;
            File.WriteAllText(Path.Combine(gameRoot, "oracle-ready"), "");
            await Until(async () => (await service.ReadGameSessionAsync(review.SessionRoot)).State?.Status == "active", "Session did not become active.");
            var active = await service.ReadGameSessionAsync(review.SessionRoot);
            Check(active.State!.Games.Single().Identity.CreationTimeFileTimeUtc == game.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(), "Observed game state is bound to the independent process identity");
            Check(File.Exists(Path.Combine(gameRoot, "locked.json")) && Gpu(game) == 3 && Affinity(game) == first, "Independent oracle verifies actual GPU class and affinity after new handles are restricted");
            Check(GameSessionDisplay.Title(active).StartsWith("Active"), "Live matching observations produce the active UI state");
            CheckPresentation(active);
            var activeRecoveryRejected = false;
            try { await service.RecoverGameSessionAsync(review.SessionRoot); }
            catch (Exception error) when (error is InvalidOperationException or JsonException) { activeRecoveryRejected = true; }
            Check(activeRecoveryRejected && Gpu(game) == 3, "Recovery cannot take over a live worker or change its game");
            Check(!GameSessionDisplay.CoresMatch(active, "0x" + second.ToString("X")) && GameSessionDisplay.Title(active, "0x" + second.ToString("X")).StartsWith("Switching cores"), "A queued core change cannot reuse the old active confirmation");
            for (var i = 0; i < 8; i++) { var observed = Gpu(game); Check(observed == 3, "GPU class stays Above Normal between client polls (observed " + observed + ")"); await Task.Delay(300); }
            await service.SwitchGameCoresAsync(review.SessionRoot, "0x" + second.ToString("X"));
            await Until(() => Task.FromResult(Affinity(game) == second), "Live core switch was not applied.");
            Check(Affinity(game) == second && Gpu(game) == 3, "Client switches cores while preserving actual GPU priority");
            await Until(async () => GameSessionDisplay.CoresMatch(await service.ReadGameSessionAsync(review.SessionRoot), "0x" + second.ToString("X")), "The new core mask was not independently confirmed by status.");
            Check(GameSessionDisplay.CoresMatch(await service.ReadGameSessionAsync(review.SessionRoot), "0x" + second.ToString("X")), "Only matching live observations confirm the requested core change");
            var stopped = await service.StopGameSessionAsync(review.SessionRoot);
            Check(GameSessionDisplay.Restored(stopped) && Gpu(game) == 2 && !game.HasExited && Affinity(launcher) == originalMask, "Stop restores GPU class while the game lives and releases launcher affinity");
            Check(GameSessionDisplay.Restored(await service.RecoverGameSessionAsync(review.SessionRoot)) && Gpu(game) == 2, "Repeated client recovery preserves the restored GPU class");
            var inconsistent = Copy(stopped);
            inconsistent.State!.Games.Single().Fields.Single(field => field.Name == "gpuPriority").Status = "conflict";
            Check(!GameSessionDisplay.Restored(inconsistent), "A stopped label cannot hide an unresolved native restoration");
            var launchField = new ProtectedFieldState { Name = "cpuPriority", Route = "launch", Status = "restartRequired" };
            var restart = Copy(stopped); restart.State!.Games.Single().Fields.Add(launchField);
            Check(GameSessionDisplay.Title(restart).Contains("restart"), "Launch priorities that remain in a living game require an explicit restart message");
            history = await reopened.ReadGameSessionsAsync();
            Check(history.Length == 1 && GameSessionDisplay.Restored(history[0].Worker), "Stopped recovery history survives app recreation");
            File.WriteAllText(Path.Combine(gameRoot, "stop"), "");
            Check(game.WaitForExit(15000) && game.ExitCode == 0, "Owned GPU workload exits cleanly");
            var rendered = OperationFiles.Read<JsonElement>(Path.Combine(gameRoot, "gpu-result.json"));
            Check(rendered.GetProperty("adapter").GetProperty("vendorId").GetUInt32() == 0x1002 && rendered.GetProperty("adapter").GetProperty("deviceId").GetUInt32() == 0x7550 && rendered.GetProperty("dispatches").GetInt64() > 0 && rendered.GetProperty("verified").GetArrayLength() == 4, "The integration exercised verified RX9070XT compute output");
            using (var key = Registry.LocalMachine.OpenSubKey(registryPath)) Check(key is null, "Integration finishes without an IFEO policy");
            Console.WriteLine("Game-session client assertions: " + passed);
        }
        catch
        {
            if (review is not null && Directory.Exists(review.SessionRoot))
            {
                var evidence = Path.Combine(repo, "artifacts", "validation", "game-session-client-failure");
                Directory.CreateDirectory(evidence);
                foreach (var file in Directory.EnumerateFiles(review.SessionRoot, "*.json")) File.Copy(file, Path.Combine(evidence, Path.GetFileName(file)), true);
            }
            throw;
        }
        finally
        {
            try
            {
                if (review is not null && Directory.Exists(review.SessionRoot))
                {
                    var status = await service.ReadGameSessionAsync(review.SessionRoot);
                    if (status.HostRunning == true) await service.StopGameSessionAsync(review.SessionRoot);
                    else if (status.State is not null && !GameSessionDisplay.Restored(status)) await service.RecoverGameSessionAsync(review.SessionRoot);
                }
            }
            finally
            {
                if (game is not null && !game.HasExited) { game.Kill(); game.WaitForExit(10000); }
                if (launcher is not null && !launcher.HasExited) { File.WriteAllText(Path.Combine(root, "stop-launcher"), ""); if (!launcher.WaitForExit(15000)) { launcher.Kill(); launcher.WaitForExit(10000); } }
                game?.Dispose(); launcher?.Dispose();
                Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", previous);
                File.Delete(launcherPath);
            }
            if (review is not null && Directory.Exists(review.SessionRoot))
            {
                var watchPath = Path.Combine(review.SessionRoot, "watch.json");
                if (File.Exists(watchPath))
                {
                    var watch = OperationFiles.Read<ProtectedWatchReady>(watchPath);
                    try { using var watcher = Process.GetProcessById(watch.Watcher.ProcessId); if (watcher.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() == watch.Watcher.CreationTimeFileTimeUtc && !watcher.WaitForExit(15000)) throw new InvalidOperationException("Recovery watcher remains active."); }
                    catch (ArgumentException) { }
                }
            }
            Directory.Delete(root, true);
        }
    }

    static void CheckPresentation(ProtectedSessionStatus active)
    {
        void Reject(Action<ProtectedSessionState> change, string message)
        {
            var copy = Copy(active); change(copy.State!);
            Check(!GameSessionDisplay.Title(copy).StartsWith("Active"), message);
        }
        Check(!GameSessionDisplay.Title(active with { HostRunning = false }).StartsWith("Active"), "A dead worker cannot display an active session");
        Check(!GameSessionDisplay.Title(active with { HostRunning = null }).StartsWith("Active"), "An unknown worker cannot display an active session");
        Check(!GameSessionDisplay.Title(active with { Error = "Readback unavailable" }).StartsWith("Active"), "A failed status read overrides a stored active label");
        Reject(state => state.UpdatedAtUtc = DateTime.UtcNow.AddMinutes(-1), "A stale heartbeat cannot display an active session");
        Reject(state => state.RegistryStatus = "conflict", "A launch-policy conflict overrides applied game fields");
        Reject(state => state.JobStatus = "cleared", "Missing affinity enforcement overrides applied game fields");
        Reject(state => state.Games.Single().Fields.Clear(), "Missing requested fields cannot pass the active-state check");
        Reject(state => state.Games.Single().Fields[0].Status = "unavailable", "An unavailable control remains partial");
        Reject(state => state.Games.Single().Fields.Single(field => field.Name == "gpuPriority").Observed = ControlRead.From(V(2)), "A mismatching real GPU class cannot be shown as applied");
        Reject(state => state.Games.Single().Fields.Single(field => field.Name == "gpuPriority").Observed = null, "An absent GPU observation cannot be shown as applied");
        Reject(state => state.Games.Single().Fields.Single(field => field.Name == "gpuPriority").Observed = new(false, V(3), null), "An unknown GPU read cannot use its leftover value as proof");
        Reject(state => state.Games.Single().Fields.Single(field => field.Name == "gpuPriority").Observed = new(true, V(3), new("D3DKMTGetProcessSchedulingPriorityClass", "ntstatus", 0xC0000022, "0x200", "Access denied")), "An access error overrides a favorable GPU value");
    }

    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out uint priority);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr mask, out UIntPtr system);
}
