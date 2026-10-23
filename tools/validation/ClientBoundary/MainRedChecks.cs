using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

static class MainRedChecks
{
    const string Ifeo = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProfileGame.exe";
    static readonly List<string> failures = [];
    static void Expect(bool value, string message) { Console.WriteLine((value ? "PASS " : "FAIL ") + message); if (!value) failures.Add(message); }
    static async Task Until(Func<Task<bool>> ready, int seconds) { var until = DateTime.UtcNow.AddSeconds(seconds); while (!await ready() && DateTime.UtcNow < until) await Task.Delay(250); }
    static JsonElement V<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    static Process Start(string path, params string[] arguments)
    {
        var start = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["DOTNET_ROOT_X64"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet");
        return Process.Start(start)!;
    }
    static ulong Affinity(Process process) { GetProcessAffinityMask(process.Handle, out var value, out _); return value.ToUInt64(); }
    static object? Launch(string name) { using var key = Registry.LocalMachine.OpenSubKey(Ifeo + @"\PerfOptions"); return key?.GetValue(name); }
    static bool NoLaunchPolicy() { using var key = Registry.LocalMachine.OpenSubKey(Ifeo); return key is null; }
    static string TaskName(string root) => "Roo Industries Protected Session " + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToLowerInvariant())))[..16];
    static (int Exit, string Output) Run(string file, params string[] arguments)
    {
        var start = new ProcessStartInfo(file) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd(); process.WaitForExit();
        return (process.ExitCode, output);
    }

    public static async Task Run(string repo)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-main-red-" + Guid.NewGuid().ToString("N"));
        var operations = Path.Combine(root, "operations");
        var bin = Path.Combine(repo, "tools", "validation", "ProtectedSessions", "bin", "publish");
        var gamePath = Path.Combine(bin, "RooIndustriesProfileGame.exe");
        var launcherPath = Path.Combine(bin, "RooIndustriesProfileLauncher.exe");
        var owned = new List<(Process Process, string Root)>();
        OptimizerService App() => new(new BackendLocator(), operations);
        if (!NoLaunchPolicy()) throw new InvalidOperationException("The probe game already has launch priorities.");
        Directory.CreateDirectory(root);
        File.Copy(Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe"), gamePath, true);
        File.Copy(Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe"), launcherPath, true);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", repo);
        async Task<Process> Open()
        {
            var folder = Path.Combine(root, "launcher-" + owned.Count); Directory.CreateDirectory(folder);
            var process = Start(launcherPath, "--launcher", folder); owned.Add((process, folder));
            await Until(() => Task.FromResult(File.Exists(Path.Combine(folder, "launcher-ready.json"))), 30);
            return process;
        }
        async Task Close(Process launcher)
        {
            File.WriteAllText(Path.Combine(owned.Single(item => item.Process == launcher).Root, "stop-launcher"), "");
            if (!launcher.WaitForExit(15000)) launcher.Kill();
            await Task.Delay(500);
        }
        void PowerLoss(string session)
        {
            var worker = Process.GetProcessById(OperationFiles.Read<ProtectedSessionState>(Path.Combine(session, "session.json")).Host.ProcessId);
            var watcher = Process.GetProcessById(OperationFiles.Read<ProtectedWatchReady>(Path.Combine(session, "watch.json")).Watcher.ProcessId);
            NtSuspendProcess(worker.Handle); NtSuspendProcess(watcher.Handle); worker.Kill(); watcher.Kill(); worker.WaitForExit(10000); watcher.WaitForExit(10000);
        }
        Dictionary<string, JsonElement>? controls = null;
        async Task<GameSessionReview> Arm(Process launcher)
        {
            var review = await App().PreviewGameSessionAsync(launcher.Id, gamePath, controls!, true);
            await App().StartGameSessionAsync(review);
            return review;
        }
        async Task Recover(string session) { try { await App().RecoverGameSessionAsync(session); } catch (Exception error) { Console.WriteLine("cleanup: " + error.Message); } }
        try
        {
            var first = await Open();
            var original = Affinity(first); var core = original & (~original + 1);
            controls = new() { ["cpuPriority"] = V("AboveNormal"), ["ioPriority"] = V(2), ["affinity"] = V(new AffinityState(0, "0x" + core.ToString("X"))) };

            var armed = await Arm(first);
            await Close(first);
            var second = await Open();
            await Task.Delay(30000);
            var sessions = await App().ReadGameSessionsAsync();
            Expect(sessions.Any(entry => entry.Worker.HostRunning == true && entry.Worker.State?.Preview.Launcher.ProcessId == second.Id) && Affinity(second) == core,
                "ROO-30: a restarted launcher is set up again with the same settings while the app runs (main: no session for the new launcher run, its cores 0x" + Affinity(second).ToString("X") + ")");
            await Close(second);

            var signIn = await Arm(await Open());
            var xml = Run(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Query", "/TN", TaskName(signIn.SessionRoot), "/XML").Output;
            PowerLoss(signIn.SessionRoot); await Close(owned[^1].Process);
            Expect(xml.Contains("<LogonTrigger>", StringComparison.Ordinal), "ROO-665: a session's task starts at sign-in (main: no sign-in trigger)");
            Run(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Run", "/TN", TaskName(signIn.SessionRoot));
            await Until(async () => GameSessionDisplay.Restored(await App().ReadGameSessionAsync(signIn.SessionRoot)), 30);
            Expect(GameSessionDisplay.Restored(await App().ReadGameSessionAsync(signIn.SessionRoot)) && NoLaunchPolicy(),
                "ROO-665: sign-in restores a session cut off by a power loss (main: launch priority still " + Launch("CpuPriorityClass") + ")");
            await Recover(signIn.SessionRoot);

            var update = await Arm(await Open());
            PowerLoss(update.SessionRoot); await Close(owned[^1].Process);
            string? blocked = null;
            var gate = await App().ReadGameSessionsAsync();
            if (gate.Any(entry => entry.Worker.HostRunning is null || entry.Worker.Error is not null)) blocked = "Couldn't confirm that all game sessions have stopped. Check Games and Undo changes first.";
            Expect(blocked is null, "ROO-665: a recoverable session doesn't block an app update (main: " + blocked + ")");
            Expect(GameSessionDisplay.Restored(await App().ReadGameSessionAsync(update.SessionRoot)), "ROO-665: opening the app restores a session cut off by a crash (main: it stays stopped with its settings applied)");
            await Recover(update.SessionRoot);

            var reboot = await Arm(await Open());
            PowerLoss(reboot.SessionRoot); await Close(owned[^1].Process);
            var gameRoot = Path.Combine(root, "game"); Directory.CreateDirectory(gameRoot);
            Start(gamePath, "--game", gameRoot, "none").Dispose();
            await Until(() => Task.FromResult(File.Exists(Path.Combine(gameRoot, "ready.json"))), 30);
            var recovered = await App().RecoverGameSessionAsync(reboot.SessionRoot);
            Expect(GameSessionDisplay.Restored(recovered), "ROO-665: Recover works after a restart while the game runs again (main: " + string.Join("; ", recovered.State?.Errors ?? []) + ")");
            File.WriteAllText(Path.Combine(gameRoot, "stop"), "");
            await Task.Delay(2000);
            await Recover(reboot.SessionRoot);

            var live = await Arm(await Open());
            var uninstall = Run(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                Path.Combine(repo, "backend", "scripts", "Invoke-ProtectedGameSession.ps1"), "-Action", "RemoveAll", "-OperationsRoot", operations, "-ConfirmApply");
            Expect(uninstall.Exit == 0, "ROO-665: uninstall cleanup restores every session (main: " + uninstall.Output.Split('\n').FirstOrDefault(line => line.Contains("Action", StringComparison.Ordinal))?.Trim() + ")");
            await App().StopGameSessionAsync(live.SessionRoot);
        }
        finally
        {
            var cleanup = App();
            foreach (var entry in await cleanup.ReadGameSessionsAsync())
                try { if (entry.Worker.HostRunning == true) await cleanup.StopGameSessionAsync(entry.SessionRoot); else if (entry.Worker.State is not null) await cleanup.RecoverGameSessionAsync(entry.SessionRoot); }
                catch (Exception error) { Console.WriteLine("cleanup: " + error.Message); }
            foreach (var (process, folder) in owned) { if (!process.HasExited) { File.WriteAllText(Path.Combine(folder, "stop-launcher"), ""); if (!process.WaitForExit(15000)) process.Kill(); } }
            var ready = Path.Combine(root, "game", "ready.json");
            if (File.Exists(ready)) { File.WriteAllText(Path.Combine(root, "game", "stop"), ""); try { using var game = Process.GetProcessById(OperationFiles.Read<JsonElement>(ready).GetProperty("pid").GetInt32()); if (!game.WaitForExit(10000)) game.Kill(); } catch (ArgumentException) { } }
            if (Registry.LocalMachine.OpenSubKey(Ifeo) is { } leftover) { leftover.Dispose(); Registry.LocalMachine.DeleteSubKeyTree(Ifeo); }
            foreach (var session in Directory.Exists(operations) ? Directory.EnumerateDirectories(operations, "game-session-*") : [])
                Run(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Delete", "/TN", TaskName(Path.Combine(session, "session")), "/F");
            File.Delete(gamePath); File.Delete(launcherPath);
            Directory.Delete(root, true);
        }
        Console.WriteLine("Main red checks: " + failures.Count + " of 7 failed");
        Environment.ExitCode = failures.Count == 0 ? 0 : 1;
    }

    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr mask, out UIntPtr system);
}
