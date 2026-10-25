using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml.Linq;
using Microsoft.Win32;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.Optimizer;

static class LaunchProfileChecks
{
    const string Ifeo = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProfileGame.exe";
    static int passed;
    static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
        passed++; Console.WriteLine("PASS " + message);
    }
    static async Task Until(Func<Task<bool>> ready, string message, int seconds = 60)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (!await ready()) { if (DateTime.UtcNow > until) throw new TimeoutException(message); await Task.Delay(250); }
    }
    static JsonElement V<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    static Process Start(string path, params string[] arguments)
    {
        var start = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new InvalidOperationException("Owned fixture did not start.");
    }
    static ulong Affinity(Process process)
    {
        if (!GetProcessAffinityMask(process.Handle, out var value, out _)) throw new InvalidOperationException("Independent affinity getter failed.");
        return value.ToUInt64();
    }
    static int Io(Process process)
    {
        var value = 0;
        if (NtQueryInformationProcess(process.Handle, 33, ref value, 4, IntPtr.Zero) < 0) throw new InvalidOperationException("Independent I/O priority getter failed.");
        return value;
    }
    static int Gpu(Process process)
    {
        if (D3DKMTGetProcessSchedulingPriorityClass(process.Handle, out var value) < 0) throw new InvalidOperationException("Independent GPU priority getter failed.");
        return value;
    }
    static object? Launch(string name)
    {
        using var key = Registry.LocalMachine.OpenSubKey(Ifeo + @"\PerfOptions");
        return key?.GetValue(name);
    }
    static bool NoLaunchPolicy() { using var key = Registry.LocalMachine.OpenSubKey(Ifeo); return key is null; }
    sealed record PresetReading(string Cpu, int Io, uint Memory, int Gpu, uint PowerControl, uint PowerState, bool Boost, ulong Cores);
    [StructLayout(LayoutKind.Sequential)] struct NativePower { public uint Version, ControlMask, StateMask; }
    static PresetReading ReadPreset(Process process)
    {
        process.Refresh();
        var power = new NativePower { Version = 1 };
        if (!GetProcessInformation(process.Handle, 0, out var memory, 4) || !GetPowerInformation(process.Handle, 4, ref power, 12) || power.Version != 1)
            throw new InvalidOperationException("Independent memory/power getters failed.");
        return new(process.PriorityClass.ToString(), Io(process), memory, Gpu(process), power.ControlMask, power.StateMask, process.PriorityBoostEnabled, Affinity(process));
    }

    public static async Task Presets(string repo)
    {
        foreach (var preset in LaunchPresetCatalog.Read(Path.Combine(repo, "backend", "catalogs", "launch-presets.json")).Presets)
            await Run(repo, false, preset: preset);
        Console.WriteLine("Launch preset session assertions: " + passed);
    }
    static string TaskName(string sessionRoot) => "Roo Industries Protected Session " + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(sessionRoot).ToLowerInvariant())))[..16];
    static (int Exit, string Output) Schtasks(params string[] arguments)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var schtasks = Process.Start(start)!;
        var output = schtasks.StandardOutput.ReadToEnd(); schtasks.StandardError.ReadToEnd(); schtasks.WaitForExit();
        return (schtasks.ExitCode, output);
    }
    static bool TaskExists(string sessionRoot) => Schtasks("/Query", "/TN", TaskName(sessionRoot)).Exit == 0;
    static string TaskXml(string sessionRoot) => Schtasks("/Query", "/TN", TaskName(sessionRoot), "/XML").Output;

    public static async Task CleanupFailure(string repo)
    {
        foreach (var (mode, expected) in new[] { ("--launch-profile-cleanup-fault", "Deliberate profile assertion failure"), ("--launch-profile-setup-fault", "System.IO.FileNotFoundException"), ("--launch-profile-readiness-fault", "Deliberate standalone readiness failure") })
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(LaunchProfileChecks).Assembly.Location);
            start.ArgumentList.Add(repo); start.ArgumentList.Add(mode);
            using var child = Process.Start(start)!;
            var output = child.StandardOutput.ReadToEndAsync(); var error = child.StandardError.ReadToEndAsync();
            await child.WaitForExitAsync();
            var stdout = await output; var stderr = await error;
            Console.WriteLine(stdout);
            if (!stderr.Contains(expected, StringComparison.Ordinal)) Console.WriteLine(stderr);
            Check(child.ExitCode != 0 && stderr.Contains(expected, StringComparison.Ordinal), mode + " preserves the original failure");
            var receipt = stdout.Split('\n').Single(line => line.StartsWith("Cleanup receipt: ", StringComparison.Ordinal))["Cleanup receipt: ".Length..];
            using var document = JsonDocument.Parse(receipt);
            var root = document.RootElement.GetProperty("root").GetString()!;
            using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
            var bin = Path.Combine(repo, "tools", "validation", "ProtectedSessions", "bin", "publish");
            Check(!Directory.Exists(root) && markers?.GetValue(PolicyRootSecurity.MarkerName(Path.Combine(root, "operations"))) is null && NoLaunchPolicy() &&
                !File.Exists(Path.Combine(bin, "RooIndustriesProfileGame.exe")) && !File.Exists(Path.Combine(bin, "RooIndustriesProfileLauncher.exe")), "A failing scenario still removes its fixture copies, folder, marker and launch policy");
            Check(document.RootElement.GetProperty("tasks").EnumerateArray().All(task => Schtasks("/Query", "/TN", task.GetString()!).Exit != 0), "A failing scenario leaves no scheduled task behind");
            Check(document.RootElement.GetProperty("processes").EnumerateArray().All(entry =>
            {
                try { using var process = Process.GetProcessById(entry.GetProperty("id").GetInt32()); return process.HasExited || process.StartTime.ToUniversalTime().ToFileTimeUtc() != entry.GetProperty("created").GetInt64(); }
                catch (ArgumentException) { return true; }
            }), "A failing scenario leaves no owned probe process behind");
        }
    }

    public static async Task Run(string repo, bool recovery, bool cleanupFault = false, bool completion = false, string? harnessFault = null, bool sameName = false, LaunchPreset? preset = null)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-launch-profile-" + Guid.NewGuid().ToString("N"));
        var operations = Path.Combine(root, "operations");
        var previous = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
        var bin = Path.Combine(repo, "tools", "validation", "ProtectedSessions", "bin", "publish");
        var gamePath = Path.Combine(bin, "RooIndustriesProfileGame.exe");
        var launcherPath = Path.Combine(bin, "RooIndustriesProfileLauncher.exe");
        var launchers = new List<(Process Process, string Root, long Created)>();
        var games = new List<(Process Process, string Root, long Created)>();
        var clients = new List<OptimizerService>();
        string? unrelatedSession = null;
        OptimizerService App()
        {
            var app = new OptimizerService(new BackendLocator(), operations);
            clients.Add(app);
            return app;
        }
        Check(NoLaunchPolicy(), "The probe game starts without launch priorities");

        async Task<Process> OpenLauncher()
        {
            var folder = Path.Combine(root, "launcher-" + (launchers.Count + 1)); Directory.CreateDirectory(folder);
            var process = Start(launcherPath, "--launcher", folder); launchers.Add((process, folder, process.StartTime.ToUniversalTime().ToFileTimeUtc()));
            await Until(() => Task.FromResult(File.Exists(Path.Combine(folder, "launcher-ready.json"))), "Launcher fixture did not start.");
            return process;
        }
        async Task CloseLauncher(Process launcher)
        {
            File.WriteAllText(Path.Combine(launchers.Single(item => item.Process == launcher).Root, "stop-launcher"), "");
            if (!launcher.WaitForExit(15000)) { launcher.Kill(); launcher.WaitForExit(10000); }
            await Task.Delay(500);
        }
        async Task<GameSessionEntry[]> Sessions() => await App().ReadGameSessionsAsync();
        async Task<GameSessionEntry> ArmedFor(OptimizerService app, Process launcher)
        {
            GameSessionEntry? armed = null;
            await Until(async () =>
            {
                await app.RearmLaunchProfilesAsync();
                armed = (await app.ReadGameSessionsAsync()).FirstOrDefault(entry => entry.Worker.HostRunning == true && entry.Worker.State?.Preview.Launcher.ProcessId == launcher.Id);
                return armed is not null && GameSessionDisplay.Title(armed.Worker).StartsWith("Ready", StringComparison.Ordinal);
            }, "The restarted launcher was not set up again with the saved settings.", 90);
            return armed!;
        }
        async Task<LaunchProfileEntry> Profile() => (await App().ReadLaunchProfilesAsync()).Single();
        async Task Ticks(OptimizerService app, int count) { for (var i = 0; i < count; i++) { await app.RearmLaunchProfilesAsync(); await Task.Delay(300); } }

        async Task<GameSessionReview> Arm(Process launcher, Dictionary<string, JsonElement> controls)
        {
            var review = await App().PreviewGameSessionAsync(launcher.Id, gamePath, controls, true);
            await App().StartGameSessionAsync(review);
            return review;
        }
        void PowerLoss(string sessionRoot)
        {
            var worker = Process.GetProcessById(OperationFiles.Read<ProtectedSessionState>(Path.Combine(sessionRoot, "session.json")).Host.ProcessId);
            var watcher = Process.GetProcessById(OperationFiles.Read<ProtectedWatchReady>(Path.Combine(sessionRoot, "watch.json")).Watcher.ProcessId);
            Check(NtSuspendProcess(worker.Handle) == 0 && NtSuspendProcess(watcher.Handle) == 0, "The session worker and its watcher are frozen together, like a power loss");
            worker.Kill(); watcher.Kill(); worker.WaitForExit(10000); watcher.WaitForExit(10000);
        }
        async Task<Process> Game(Process? launcher, bool failReadiness = false)
        {
            var folder = Path.Combine(root, "game-" + (games.Count + 1)); Directory.CreateDirectory(folder);
            Process? game = null;
            if (launcher is null)
            {
                game = failReadiness ? Start(gamePath, "--hold-lock", Path.Combine(folder, "held"), Path.Combine(folder, "holder-ready.json"), Path.Combine(folder, "stop")) : Start(gamePath, "--game", folder, "none");
                games.Add((game, folder, game.StartTime.ToUniversalTime().ToFileTimeUtc()));
            }
            else OperationFiles.Write(Path.Combine(launchers.Single(item => item.Process == launcher).Root, "launch.json"), new { root = folder, hardware = "none", exe = Path.GetFileName(gamePath) });
            await Until(() => Task.FromResult(File.Exists(Path.Combine(folder, "ready.json"))), failReadiness ? "Deliberate standalone readiness failure" : "The game fixture did not start.", failReadiness ? 2 : 60);
            if (game is null) { game = Process.GetProcessById(OperationFiles.Read<JsonElement>(Path.Combine(folder, "ready.json")).GetProperty("pid").GetInt32()); games.Add((game, folder, game.StartTime.ToUniversalTime().ToFileTimeUtc())); }
            return game;
        }
        void EndGame(Process game) { File.WriteAllText(Path.Combine(games.Single(item => item.Process == game).Root, "stop"), ""); Check(game.WaitForExit(15000), "The game fixture exits"); }
        async Task<bool> Restored(string sessionRoot) => GameSessionDisplay.Restored(await App().ReadGameSessionAsync(sessionRoot));
        async Task<(int Exit, string Output, string Error)> RemoveAll(string? operationsRoot = null, bool failTaskDiscovery = false)
        {
            var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
            {
                ArgumentList = { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass" },
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            };
            var script = Path.Combine(repo, "backend", "scripts", "Invoke-ProtectedGameSession.ps1");
            if (failTaskDiscovery)
            {
                var command = "function Get-ScheduledTask { [CmdletBinding()] param([string[]]$TaskName) Write-Error 'Deliberate task discovery failure' -Category ResourceUnavailable }; & '" + script.Replace("'", "''") + "' -Action RemoveAll -OperationsRoot '" + (operationsRoot ?? operations).Replace("'", "''") + "' -ConfirmApply";
                start.ArgumentList.Add("-EncodedCommand"); start.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
            }
            else
                foreach (var argument in new[] { "-File", script, "-Action", "RemoveAll", "-OperationsRoot", operationsRoot ?? operations, "-ConfirmApply" }) start.ArgumentList.Add(argument);
            using var uninstall = Process.Start(start)!;
            var output = uninstall.StandardOutput.ReadToEndAsync();
            var error = uninstall.StandardError.ReadToEndAsync();
            await uninstall.WaitForExitAsync();
            return (uninstall.ExitCode, await output, await error);
        }

        Exception? scenarioError = null;
        try
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", repo);
            Directory.CreateDirectory(root);
            File.Copy(Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe"), gamePath, true);
            File.Copy(harnessFault == "setup" ? Path.Combine(root, "missing-fixture.exe") : Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe"), launcherPath, true);
            if (Environment.GetEnvironmentVariable("DOTNET_ROOT_X64") is { Length: > 0 } runtime)
            {
                var receipt = Path.Combine(root, "runtime.txt");
                using var probe = Start(gamePath, "--runtime-root", receipt);
                if (!probe.WaitForExit(15000)) { probe.Kill(); probe.WaitForExit(10000); throw new TimeoutException("The runtime probe did not finish."); }
                Check(probe.ExitCode == 0 && File.ReadAllText(receipt).StartsWith(Path.GetFullPath(runtime).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase), "The fixture apphost loads the runtime selected by the caller");
            }
            if (harnessFault == "readiness") { await Game(null, true); return; }
            var first = await OpenLauncher();
            var original = Affinity(first);
            var core = original & (~original + 1);
            Check(core != 0 && core != original && Io(first) == 1, "The launcher fixture starts with more than one core and its own I/O priority");
            var controls = new Dictionary<string, JsonElement> { ["cpuPriority"] = V("AboveNormal"), ["ioPriority"] = V(2), ["affinity"] = V(new AffinityState(0, "0x" + core.ToString("X"))) };

            if (preset is not null) await PresetCycle();
            else if (completion) await Completion();
            else if (sameName) await SameName();
            else await (recovery ? Recovery() : Profiles());
            Console.WriteLine((recovery ? "Session recovery" : "Launch profile") + " assertions: " + passed);

            async Task PresetCycle()
            {
                var choice = preset!;
                var app = App();
                var observations = new List<object>();
                PresetReading Observe(Process process, string stage)
                {
                    var observed = ReadPreset(process);
                    var observation = new { stage, values = observed };
                    observations.Add(observation);
                    Console.WriteLine("PRESET " + JsonSerializer.Serialize(new { preset = choice.Id, observation }));
                    return observed;
                }
                var launcherOriginal = ReadPreset(first);
                var baselineGame = await Game(first);
                var baseline = Observe(baselineGame, "Original");
                EndGame(baselineGame);
                var selected = choice.Controls();
                selected["affinity"] = V(new AffinityState(0, "0x" + core.ToString("X")));
                var expected = baseline with { Cores = core };
                foreach (var (name, value) in choice.Settings)
                    expected = name switch
                    {
                        "cpuPriority" => expected with { Cpu = value.GetString()! },
                        "ioPriority" => expected with { Io = value.GetInt32() },
                        "memoryPriority" => expected with { Memory = value.GetUInt32() },
                        "gpuPriority" => expected with { Gpu = value.GetInt32() },
                        "priorityBoost" => expected with { Boost = value.GetBoolean() },
                        "executionQoS" => expected with
                        {
                            PowerControl = value.GetString() == "systemManaged" ? baseline.PowerControl & ~1u : baseline.PowerControl | 1u,
                            PowerState = value.GetString() == "eco" ? baseline.PowerState | 1u : baseline.PowerState & ~1u,
                        },
                        _ => throw new InvalidDataException("The preset proof needs an independent reader for " + name),
                    };
                async Task<GameSessionReview> Review()
                {
                    var result = await app.PreviewGameSessionAsync(first.Id, gamePath, selected, true);
                    Check(choice.Matches(result.Plan.Controls), choice.Name + " Preview keeps exactly the catalog priorities");
                    return result;
                }
                async Task<Process> Applied(OptimizerService client, GameSessionEntry entry, Process launcher, string stage)
                {
                    var game = await Game(launcher);
                    await Until(async () => (await client.ReadGameSessionAsync(entry.SessionRoot)).State?.Status == "active", "The preset game did not become active.");
                    var observed = Observe(game, stage);
                    Check(observed == expected, choice.Name + " " + stage + " independently confirms every chosen value and preserves unnamed settings");
                    return game;
                }
                void LiveRestored(Process game, string stage)
                {
                    var observed = Observe(game, stage);
                    Check(observed == baseline with { Cpu = expected.Cpu }, choice.Name + " restores exact live originals; CPU launch priority clears on the next game start");
                }
                var review = await Review();
                Check(ReadPreset(first) == launcherOriginal && NoLaunchPolicy(), choice.Name + " Preview changes no launcher value or launch policy");
                var started = await app.StartGameSessionAsync(review);
                var game = await Applied(app, new GameSessionEntry(review.SessionRoot, started), first, "Start");
                var stopped = await app.StopGameSessionAsync(review.SessionRoot);
                Check(GameSessionDisplay.Restored(stopped) && NoLaunchPolicy() && ReadPreset(first) == launcherOriginal &&
                    stopped.State!.Games.Single(entry => entry.Identity.ProcessId == game.Id).Fields.Single(field => field.Name == "cpuPriority").Status == "restartRequired",
                    choice.Name + " Stop restores the launcher and launch policy and reports the game's CPU restart requirement");
                LiveRestored(game, "Stop"); EndGame(game);
                var fresh = await Game(first);
                Check(Observe(fresh, "Fresh after Stop") == baseline, choice.Name + " a fresh game has every original value after Stop"); EndGame(fresh);

                review = await Review();
                app.RequireNoLaunchProfile(review.Plan);
                await app.StartGameSessionAsync(review);
                var saved = await app.SaveLaunchProfileAsync(review);
                Check(File.ReadAllBytes(Path.Combine(saved.Root, "reviewed-preview.json")).SequenceEqual(File.ReadAllBytes(review.PreviewPath)) && choice.Matches(saved.Saved.Controls),
                    choice.Name + " Save for next time keeps the exact reviewed bytes and values");
                game = await Applied(app, (await app.ReadGameSessionsAsync()).Single(entry => entry.SessionRoot == review.SessionRoot), first, "Save");
                EndGame(game);
                await CloseLauncher(first);
                await Until(async () => await Restored(review.SessionRoot), "Closing the launcher did not restore the preset session.");
                Check(NoLaunchPolicy(), choice.Name + " closing the launcher removes its game launch policy");
                var reopened = App();
                var second = await OpenLauncher();
                var secondOriginal = ReadPreset(second);
                var rearmed = await ArmedFor(reopened, second);
                Check(ProtectedSessions.ProfileMismatch(saved.Saved, rearmed.Worker.State!.Preview) is null && choice.Matches(rearmed.Worker.State.Preview.Controls),
                    choice.Name + " reopening the launcher rearms the exact saved controls");
                game = await Applied(reopened, rearmed, second, "Rearm");
                Check(await reopened.DisableLaunchProfileAsync(saved.Root) is null && NoLaunchPolicy() && ReadPreset(second) == secondOriginal,
                    choice.Name + " Turn off removes the saved profile and restores the launcher's original values");
                LiveRestored(game, "Turn off"); EndGame(game);
                fresh = await Game(second);
                Check(Observe(fresh, "Fresh after Turn off") == baseline, choice.Name + " a fresh game has every original value after Turn off"); EndGame(fresh);
                await CloseLauncher(second);
                await OpenLauncher(); await Ticks(reopened, 3);
                Check((await reopened.ReadLaunchProfilesAsync()).Length == 0 && (await Sessions()).All(entry => GameSessionDisplay.Restored(entry.Worker)) && NoLaunchPolicy(),
                    choice.Name + " stays off when the launcher opens again");
                var evidence = Path.Combine(repo, "artifacts", "validation", "launch-preset-" + choice.Id + "-" + Guid.NewGuid().ToString("N") + ".json");
                OperationFiles.Write(evidence, new { preset = choice.Id, original = baseline, requested = expected, observations });
                Console.WriteLine("Preset readback receipt: " + evidence);
            }

            async Task Profiles()
            {
                var app = App();
                var review = await app.PreviewGameSessionAsync(first.Id, gamePath, controls, true);
                app.RequireNoLaunchProfile(review.Plan);
                await app.StartGameSessionAsync(review);
                var saved = await app.SaveLaunchProfileAsync(review);
                if (cleanupFault)
                {
                    var broken = Path.Combine(operations, "game-session-" + Guid.NewGuid().ToString("N"), "session");
                    Directory.CreateDirectory(broken);
                    File.WriteAllText(Path.Combine(broken, "session.json"), "{}");
                    throw new InvalidOperationException("Deliberate profile assertion failure");
                }
                var reviewedBytes = File.ReadAllBytes(review.PreviewPath);
                Check(saved.Profile.Enabled && File.ReadAllBytes(Path.Combine(saved.Root, "reviewed-preview.json")).SequenceEqual(reviewedBytes), "Saving keeps the exact reviewed preview as the approval");
                Check(Equals(Launch("CpuPriorityClass"), 6) && Equals(Launch("IoPriority"), 2) && Affinity(first) == core && Io(first) == 2, "Saved settings are armed on the running launcher");
                Check(OptimizerService.DescribeLaunchProfile(await Profile()).StartsWith("Ready", StringComparison.Ordinal), "The saved settings row says Ready while the launcher runs");
                var duplicate = false;
                try { app.RequireNoLaunchProfile(review.Plan); } catch (InvalidOperationException) { duplicate = true; }
                Check(duplicate, "A second saved profile for the same launcher or game is refused");
                await Ticks(app, 3);
                Check((await Sessions()).Count(entry => !GameSessionDisplay.Restored(entry.Worker)) == 1, "Repeated checks don't arm the same launcher run twice");

                await CloseLauncher(first);
                await Until(async () => GameSessionDisplay.Restored((await Sessions()).Single().Worker), "Closing the launcher did not end the first session.");
                Check(NoLaunchPolicy(), "Closing the launcher ends the session and removes the game's launch priorities");
                var reopened = App();
                Check(!await reopened.RearmLaunchProfilesAsync(), "A reopened app arms nothing while the launcher is closed");

                var second = await OpenLauncher();
                var rearmed = await ArmedFor(reopened, second);
                var plan = rearmed.Worker.State!.Preview;
                Check(rearmed.ProfileId == saved.Profile.ProfileId && ProtectedSessions.ProfileMismatch(saved.Saved, plan) is null, "A restarted launcher is set up again with exactly the saved settings");
                Check(File.Exists(Path.Combine(rearmed.SessionRoot, "reviewed-preview.json")) && !plan.OriginalLaunchSettings.ImageKeyExisted && rearmed.Worker.State.RegistryStatus == "applied", "The new session saved the original values before changing anything");
                Check(Equals(Launch("CpuPriorityClass"), 6) && Affinity(second) == core && Io(second) == 2, "The restarted launcher has the saved cores and I/O default again");
                var game = await Game(second);
                await Until(async () => (await reopened.ReadGameSessionAsync(rearmed.SessionRoot)).State?.Status == "active", "The game under the re-armed session was not verified.");
                Check(Affinity(game) == core && game.PriorityClass == ProcessPriorityClass.AboveNormal && Io(game) == 2, "A game started from the restarted launcher gets the saved cores and priorities");
                EndGame(game);
                await Ticks(reopened, 3);
                Check((await Sessions()).Count(entry => !GameSessionDisplay.Restored(entry.Worker)) == 1, "A game exiting doesn't arm a second session");

                PowerLoss(rearmed.SessionRoot);
                await CloseLauncher(second);
                var stale = await App().ReadGameSessionAsync(rearmed.SessionRoot);
                Check(stale.HostRunning == false && !GameSessionDisplay.Restored(stale) && Equals(Launch("CpuPriorityClass"), 6), "The crash leaves the old session's launch priorities behind");

                var afterCrash = App();
                var third = await OpenLauncher();
                var recovered = await ArmedFor(afterCrash, third);
                var history = await Sessions();
                Check(GameSessionDisplay.Restored(history.Single(entry => entry.SessionRoot == rearmed.SessionRoot).Worker) && !TaskExists(rearmed.SessionRoot), "The stale session is recovered and its task removed before arming again");
                Check(history.Count(entry => !GameSessionDisplay.Restored(entry.Worker)) == 1 && !recovered.Worker.State!.Preview.OriginalLaunchSettings.ImageKeyExisted, "Only one session is armed and it saved the true originals, not the leftover values");
                Check(Equals(Launch("CpuPriorityClass"), 6) && Affinity(third) == core, "The launcher after the crash has the saved settings again");

                Check(GameSessionDisplay.Restored(await afterCrash.StopGameSessionAsync(recovered.SessionRoot)) && NoLaunchPolicy() && Affinity(third) == original, "Stop and restore on a saved session puts everything back");
                await Ticks(afterCrash, 4);
                Check((await Sessions()).All(entry => GameSessionDisplay.Restored(entry.Worker)), "Stop and restore isn't undone while the same launcher keeps running");

                using (var foreign = Registry.LocalMachine.CreateSubKey(Ifeo + @"\PerfOptions")) foreign.SetValue("CpuPriorityClass", 2, RegistryValueKind.DWord);
                await CloseLauncher(third);
                var fourth = await OpenLauncher();
                var changed = App();
                await Until(async () => { await changed.RearmLaunchProfilesAsync(); return (await Profile()).State is { Status: "changed" } state && state.Launcher.ProcessId == fourth.Id; }, "Changed launch priorities were not reported.");
                Check((await Sessions()).All(entry => GameSessionDisplay.Restored(entry.Worker)) && Equals(Launch("CpuPriorityClass"), 2) && Affinity(fourth) == original,
                    "Launch priorities another program changed block the re-arm and stay untouched");
                Check(OptimizerService.DescribeLaunchProfile(await Profile()).Contains("Another program changed", StringComparison.Ordinal), "The row says why the settings weren't set up");
                Registry.LocalMachine.DeleteSubKeyTree(Ifeo);

                var stamp = File.GetLastWriteTimeUtc(gamePath);
                File.SetLastWriteTimeUtc(gamePath, stamp.AddMinutes(1));
                await CloseLauncher(fourth);
                var fifth = await OpenLauncher();
                await Until(async () => { await changed.RearmLaunchProfilesAsync(); return (await Profile()).State is { Status: "changed" } state && state.Launcher.ProcessId == fifth.Id; }, "A changed game file was not reported.");
                Check((await Profile()).State!.Message!.Contains("game changed", StringComparison.Ordinal) && NoLaunchPolicy() && Affinity(fifth) == original, "An updated game file is not set up with the old approval");
                File.SetLastWriteTimeUtc(gamePath, stamp);
                await CloseLauncher(fifth);

                var sixth = await OpenLauncher();
                var latest = await ArmedFor(App(), sixth);
                var kept = (await Sessions()).Where(entry => entry.ProfileId == saved.Profile.ProfileId).ToArray();
                Check(kept.Length == 3 && kept.Any(entry => entry.SessionRoot == latest.SessionRoot) && !Directory.Exists(Path.GetDirectoryName(review.SessionRoot)) && !TaskExists(review.SessionRoot),
                    "Old restored sessions of saved settings are pruned to the latest three, tasks included");

                var idle = App();
                var clock = Stopwatch.StartNew(); var cpu = Process.GetCurrentProcess().TotalProcessorTime;
                var changes = 0;
                for (var i = 0; i < 20; i++) if (await idle.RearmLaunchProfilesAsync()) changes++;
                Check(changes == 0, "Twenty checks while the launcher stays armed change nothing");
                var spent = (Process.GetCurrentProcess().TotalProcessorTime - cpu).TotalMilliseconds / 20;
                Console.WriteLine("Idle check: " + (clock.Elapsed.TotalMilliseconds / 20).ToString("0.0") + " ms elapsed, " + spent.ToString("0.0") + " ms CPU each");
                Check(spent < 50, "An idle check costs under 50 ms of CPU");

                var off = App();
                Check(await off.DisableLaunchProfileAsync((await Profile()).Root) is null, "Turning the saved settings off reports no problems");
                Check((await Sessions()).All(entry => GameSessionDisplay.Restored(entry.Worker)) && NoLaunchPolicy() && Affinity(sixth) == original && Io(sixth) == 1 && (await off.ReadLaunchProfilesAsync()).Length == 0,
                    "Turning them off stops the session, restores the launcher and game settings and removes the profile");
                await Ticks(off, 4);
                Check((await Sessions()).All(entry => GameSessionDisplay.Restored(entry.Worker)) && NoLaunchPolicy(), "Nothing is set up again after the settings are turned off");
                await CloseLauncher(sixth);
            }

            async Task SameName()
            {
                var app = App();
                var review = await app.PreviewGameSessionAsync(first.Id, gamePath, new(controls) { ["gpuPriority"] = V(3) }, true);
                await app.StartGameSessionAsync(review);
                var saved = await app.SaveLaunchProfileAsync(review);
                await CloseLauncher(first);
                await Until(async () => GameSessionDisplay.Restored((await Sessions()).Single().Worker), "Closing the launcher did not end the first session.");
                var second = await OpenLauncher();
                var rearmed = await ArmedFor(App(), second);
                Check(rearmed.ProfileId == saved.Profile.ProfileId && rearmed.Worker.State!.Preview.Controls.ContainsKey("gpuPriority"), "A restarted launcher is set up again with the saved GPU priority");
                var other = Directory.CreateDirectory(Path.Combine(root, "same-name")).FullName;
                foreach (var file in Directory.GetFiles(bin, "*.dll").Concat(Directory.GetFiles(bin, "*.json"))) File.Copy(file, Path.Combine(other, Path.GetFileName(file)));
                File.Copy(gamePath, Path.Combine(other, Path.GetFileName(gamePath)));
                var folder = Path.Combine(root, "game-" + (games.Count + 1)); Directory.CreateDirectory(folder);
                var copy = Start(Path.Combine(other, Path.GetFileName(gamePath)), "--game", folder, "none"); games.Add((copy, folder, copy.StartTime.ToUniversalTime().ToFileTimeUtc()));
                await Until(() => Task.FromResult(File.Exists(Path.Combine(folder, "ready.json"))), "The same-name program did not start.");
                string? ended = null; var clock = Stopwatch.StartNew();
                while (ended is null && clock.Elapsed.TotalSeconds < 6)
                {
                    var live = await App().ReadGameSessionAsync(rearmed.SessionRoot);
                    if (live.HostRunning != true || live.State?.Status != "armed" || live.State.Errors.Count != 0) ended = live.State?.Status + ": " + string.Join("; ", live.State?.Errors ?? []);
                    await Task.Delay(250);
                }
                Check(ended is null, "A program with the game's file name from another folder leaves the re-armed session running" + (ended is null ? "" : " (" + ended + ")"));
                var game = await Game(second);
                await Until(async () => (await App().ReadGameSessionAsync(rearmed.SessionRoot)).State?.Status == "active", "The game under the re-armed session was not verified.");
                Check(Gpu(game) == 3 && Affinity(game) == core && game.PriorityClass == ProcessPriorityClass.AboveNormal, "The game started next still gets the saved GPU priority, cores and priority");
                EndGame(game); EndGame(copy);
                Check(await App().DisableLaunchProfileAsync((await Profile()).Root) is null && (await Sessions()).All(entry => GameSessionDisplay.Restored(entry.Worker)) && NoLaunchPolicy() && Affinity(second) == original,
                    "Turning the saved settings off restores the launcher and game settings");
                await CloseLauncher(second);
            }

            async Task Completion()
            {
                var empty = Directory.CreateDirectory(Path.Combine(root, "empty-operations")).FullName;
                Check((await RemoveAll(empty)).Exit == 0, "Cleanup succeeds when the selected folder has no sessions or matching tasks");
                var discovery = await RemoveAll(empty, true);
                using var discoveryResult = JsonDocument.Parse(discovery.Output);
                var discoveryFailed = discovery.Exit != 0 && discoveryResult.RootElement.GetProperty("status").GetString() == "failed" && discovery.Output.Contains("Deliberate task discovery failure", StringComparison.Ordinal);

                var native = await Arm(first, new() { ["priorityBoost"] = V(false) });
                var game = await Game(first);
                await Until(async () => (await App().ReadGameSessionAsync(native.SessionRoot)).State?.Status == "active", "The native probe control did not apply.");
                PowerLoss(native.SessionRoot); first.Kill(); first.WaitForExit(10000);
                Check(!game.HasExited, "The native game probe survives the lost launcher");
                var statePath = Path.Combine(native.SessionRoot, "session.json");
                var checkpoint = File.ReadAllBytes(statePath);
                var state = OperationFiles.Read<ProtectedSessionState>(statePath);
                var journal = state.Games.Single().Fields.Single().JournalPath!;
                var retained = journal + ".retained";
                var originalBoost = OperationFiles.Read<ProcessControlJournal>(journal).Preview.Original["priorityBoost"].Require().GetBoolean();
                File.Move(journal, retained);
                bool signInSafe;
                bool updateBlocked = false;
                bool retryRestored = false;
                try
                {
                    Check(originalBoost && !game.PriorityBoostEnabled, "The native probe's priority boost changed from its saved enabled value to disabled");
                    using var retry = Start(Path.Combine(repo, "backend", "bin", "optimizer", "session", "RooIndustries.SessionHost.exe"), "run", Path.Combine(native.SessionRoot, "worker-request.json"));
                    if (!retry.WaitForExit(30000)) { retry.Kill(); retry.WaitForExit(10000); throw new TimeoutException("Sign-in recovery did not finish."); }
                    var result = OperationFiles.Read<ProtectedSessionState>(Path.Combine(native.SessionRoot, "recovery-result.json"));
                    game.Refresh();
                    signInSafe = retry.ExitCode != 0 && result.Status == "recoveryRequired" && TaskExists(native.SessionRoot) && !game.PriorityBoostEnabled;
                    result.Status = "stoppedWithErrors";
                    OperationFiles.Write(statePath, result);
                    using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true)!;
                    var marker = PolicyRootSecurity.MarkerName(operations) + PolicyRootSecurity.ProtectedAtSuffix;
                    var protectedAt = markers.GetValue(marker)!;
                    try
                    {
                        markers.SetValue(marker, DateTime.UtcNow.AddMinutes(1).ToFileTimeUtc(), RegistryValueKind.QWord);
                        try { updateBlocked = await App().GameSessionsBlockUpdateAsync(); }
                        catch (InvalidDataException) { updateBlocked = true; }
                    }
                    finally { markers.SetValue(marker, protectedAt, RegistryValueKind.QWord); }
                }
                finally
                {
                    File.Move(retained, journal);
                    var recovered = await App().RecoverGameSessionAsync(native.SessionRoot);
                    game.Refresh();
                    retryRestored = GameSessionDisplay.Restored(recovered) && !TaskExists(native.SessionRoot) && game.PriorityBoostEnabled == originalBoost;
                    if (!retryRestored)
                    {
                        File.WriteAllBytes(statePath, checkpoint);
                        await App().RecoverGameSessionAsync(native.SessionRoot);
                    }
                }
                Console.WriteLine(JsonSerializer.Serialize(new { discoveryFailed, signInSafe, updateBlocked }));
                if (!discoveryFailed) Console.WriteLine(discovery.Error);
                Check(discoveryFailed, "A task discovery error makes cleanup fail instead of reporting success");
                Check(signInSafe, "Sign-in recovery keeps its task and fails while a native backup is missing");
                Check(updateBlocked, "An older stoppedWithErrors session with an unresolved native field blocks an update");
                Check(retryRestored,
                    "Returning the backup restores the original native value and removes the recovery task");
                EndGame(game);

                var expiredLauncher = await OpenLauncher();
                var expired = await Arm(expiredLauncher, new() { ["priorityBoost"] = V(false) });
                var expiredGame = await Game(expiredLauncher);
                await Until(async () => (await App().ReadGameSessionAsync(expired.SessionRoot)).State?.Status == "active", "The expiring native probe did not apply.");
                PowerLoss(expired.SessionRoot); expiredLauncher.Kill(); expiredLauncher.WaitForExit(10000);
                Check(!expiredGame.HasExited, "The legacy native probe survives the lost launcher");
                var expiredState = OperationFiles.Read<ProtectedSessionState>(Path.Combine(expired.SessionRoot, "session.json"));
                var expiredField = expiredState.Games.Single().Fields.Single();
                var missing = expiredField.JournalPath!;
                var expiredOriginal = OperationFiles.Read<ProcessControlJournal>(missing).Preview.Original["priorityBoost"].Require().GetBoolean();
                expiredGame.PriorityBoostEnabled = expiredOriginal;
                expiredField.Status = "conflict"; expiredField.PreviewHash = null; expiredState.Status = "recoveryRequired";
                OperationFiles.Write(Path.Combine(expired.SessionRoot, "session.json"), expiredState);
                File.Move(missing, missing + ".retained");
                try
                {
                    Check(!GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(expired.SessionRoot)) && TaskExists(expired.SessionRoot),
                        "An older missing-journal record without retained preview authority stays outstanding while its game lives");
                    EndGame(expiredGame);
                    var recovered = await App().RecoverGameSessionAsync(expired.SessionRoot);
                    Check(GameSessionDisplay.Restored(recovered) && recovered.State!.Games.Single().Exited && recovered.State.Games.Single().Fields.Single().Status == "expired" && !TaskExists(expired.SessionRoot) && !File.Exists(missing),
                        "After the original game exits, recovery expires its missing native backup and removes the task");
                    Check(!await App().GameSessionsBlockUpdateAsync() && NoLaunchPolicy(), "An expired native control no longer blocks an update");
                }
                finally
                {
                    File.Move(missing + ".retained", missing);
                    await App().RecoverGameSessionAsync(expired.SessionRoot);
                }

                var unchangedLauncher = await OpenLauncher();
                var unchanged = await Arm(unchangedLauncher, new() { ["priorityBoost"] = V(false) });
                var unchangedGame = await Game(unchangedLauncher);
                await Until(async () => (await App().ReadGameSessionAsync(unchanged.SessionRoot)).State?.Status == "active", "The unchanged native probe did not apply.");
                PowerLoss(unchanged.SessionRoot); unchangedLauncher.Kill(); unchangedLauncher.WaitForExit(10000);
                Check(!unchangedGame.HasExited, "The unchanged-value probe survives the lost launcher");
                var unchangedPath = Path.Combine(unchanged.SessionRoot, "session.json");
                var unchangedState = OperationFiles.Read<ProtectedSessionState>(unchangedPath);
                var unchangedField = unchangedState.Games.Single().Fields.Single();
                var absent = unchangedField.JournalPath!;
                var baseline = OperationFiles.Read<ProcessControlJournal>(absent).Preview.Original["priorityBoost"].Require().GetBoolean();
                unchangedField.Status = "conflict"; unchangedField.Observed = ControlRead.From(V(false)); unchangedState.Status = "recoveryRequired";
                OperationFiles.Write(unchangedPath, unchangedState);
                File.Move(absent, absent + ".retained");
                try
                {
                    Check(!GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(unchanged.SessionRoot)) && TaskExists(unchanged.SessionRoot),
                        "A value matching the latest observation but differing from the retained original cannot retire recovery");
                    unchangedGame.PriorityBoostEnabled = baseline;
                    var nativePreview = Path.Combine(Path.GetDirectoryName(absent)!, "preview.json");
                    var bytes = File.ReadAllBytes(nativePreview);
                    try
                    {
                        File.AppendAllText(nativePreview, " ");
                        Check(!GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(unchanged.SessionRoot)) && TaskExists(unchanged.SessionRoot),
                            "Changed native preview bytes cannot certify that a missing-journal control is unchanged");
                    }
                    finally { File.WriteAllBytes(nativePreview, bytes); }
                    var recovered = await App().RecoverGameSessionAsync(unchanged.SessionRoot);
                    unchangedGame.Refresh();
                    Check(GameSessionDisplay.Restored(recovered) && recovered.State!.Games.Single().Fields.Single().Status == "restored" &&
                        !unchangedGame.HasExited && unchangedGame.PriorityBoostEnabled == baseline && !TaskExists(unchanged.SessionRoot) && !File.Exists(absent),
                        "A verified original native value completes recovery without a journal while its game remains alive");
                }
                finally
                {
                    File.Move(absent + ".retained", absent);
                    await App().RecoverGameSessionAsync(unchanged.SessionRoot);
                }
                EndGame(unchangedGame);
            }

            async Task Recovery()
            {
                var signIn = await Arm(first, controls);
                var taskXml = TaskXml(signIn.SessionRoot);
                Check(taskXml.Contains("<LogonTrigger>", StringComparison.Ordinal) && taskXml.Contains(System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value, StringComparison.Ordinal),
                    "A new session's task also starts at this user's sign-in");
                unrelatedSession = Path.Combine(root, "other-operations", "game-session-" + Guid.NewGuid().ToString("N"), "session");
                var document = XDocument.Parse(taskXml.Replace(signIn.SessionRoot, unrelatedSession, StringComparison.Ordinal));
                var ns = document.Root!.Name.Namespace;
                document.Root.Element(ns + "Triggers")!.RemoveNodes();
                document.Root.Element(ns + "Actions")!.ReplaceNodes(new XElement(ns + "Exec",
                    new XElement(ns + "Command", Path.Combine(Environment.SystemDirectory, "cmd.exe")), new XElement(ns + "Arguments", "/c exit 0")));
                var taskFile = Path.Combine(root, "unrelated-task.xml");
                document.Save(taskFile);
                Check(Schtasks("/Create", "/TN", TaskName(unrelatedSession), "/XML", taskFile).Exit == 0, "An unrelated recovery folder has its own inert task");
                PowerLoss(signIn.SessionRoot);
                await CloseLauncher(first);
                Check(!await Restored(signIn.SessionRoot) && Equals(Launch("CpuPriorityClass"), 6), "A power loss leaves the game's launch priorities behind");
                Schtasks("/Run", "/TN", TaskName(signIn.SessionRoot));
                await Until(async () => await Restored(signIn.SessionRoot) && NoLaunchPolicy() && !TaskExists(signIn.SessionRoot), "Sign-in did not restore the interrupted session.");
                Check(await Restored(signIn.SessionRoot) && NoLaunchPolicy() && !TaskExists(signIn.SessionRoot), "At sign-in the session's own task restores the launch priorities and removes itself, with the app closed");

                var update = await Arm(await OpenLauncher(), controls);
                PowerLoss(update.SessionRoot); await CloseLauncher(launchers[^1].Process);
                Check((await App().ReadGameSessionAsync(update.SessionRoot)).Error is not null, "The interrupted session reports an error, which used to block app updates");
                Check(!await App().GameSessionsBlockUpdateAsync() && await Restored(update.SessionRoot) && NoLaunchPolicy(), "The update check restores a recoverable session and lets the update install");

                var startup = await Arm(await OpenLauncher(), controls);
                PowerLoss(startup.SessionRoot); await CloseLauncher(launchers[^1].Process);
                await App().RecoverStaleGameSessionsAsync();
                Check(await Restored(startup.SessionRoot) && NoLaunchPolicy() && !TaskExists(startup.SessionRoot), "Opening the app restores a session interrupted by a crash");

                var launcher = await OpenLauncher();
                var reboot = await Arm(launcher, controls);
                var orphan = await Game(launcher);
                await Until(async () => (await App().ReadGameSessionAsync(reboot.SessionRoot)).State?.Status == "active", "The game under the session was not verified.");
                PowerLoss(reboot.SessionRoot); launcher.Kill(); launcher.WaitForExit(10000);
                var refused = await App().RecoverGameSessionAsync(reboot.SessionRoot);
                Check(!GameSessionDisplay.Restored(refused) && Affinity(orphan) == core && refused.State!.Errors.Any(error => error.Contains("job is unavailable", StringComparison.Ordinal)),
                    "Recover still refuses while a game left from the crashed session keeps its core limit");
                Check(TaskExists(reboot.SessionRoot), "Blocked recovery keeps its sign-in recovery task");
                var blocked = await RemoveAll();
                Check(blocked.Exit != 0 && TaskExists(reboot.SessionRoot) && !await Restored(reboot.SessionRoot) && Affinity(orphan) == core,
                    "Uninstall cleanup reports blocked recovery and keeps its journal and task");
                EndGame(orphan);
                var fresh = await Game(null);
                Check(Affinity(fresh) == original && GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(reboot.SessionRoot)) && NoLaunchPolicy(), "Recover works while a new copy of the game runs, as after a restart");
                EndGame(fresh);

                var ended = await Arm(await OpenLauncher(), controls);
                await CloseLauncher(launchers[^1].Process);
                await Until(async () => await Restored(ended.SessionRoot), "Closing the launcher did not end the session.");
                Check(TaskExists(ended.SessionRoot), "A session that ended with its launcher still has its task");
                var live = await OpenLauncher();
                await Arm(live, controls);
                var uninstall = await RemoveAll();
                Console.WriteLine((uninstall.Output + uninstall.Error).Trim());
                var sessions = await Sessions();
                Check(uninstall.Exit == 0 && sessions.Length == 6 && sessions.All(entry => GameSessionDisplay.Restored(entry.Worker) && !TaskExists(entry.SessionRoot)) && NoLaunchPolicy() && Affinity(live) == original && Io(live) == 1,
                    "Uninstall cleanup stops the running session, restores everything and removes every session task");
                Check(TaskExists(unrelatedSession), "Uninstall cleanup leaves tasks from another recovery folder alone");

                var legacyLauncher = await OpenLauncher();
                var legacy = await Arm(legacyLauncher, controls);
                PowerLoss(legacy.SessionRoot); await CloseLauncher(legacyLauncher);
                using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true)!;
                var marker = PolicyRootSecurity.MarkerName(operations) + PolicyRootSecurity.ProtectedAtSuffix;
                var protectedAt = markers.GetValue(marker)!;
                try
                {
                    markers.SetValue(marker, DateTime.UtcNow.AddMinutes(1).ToFileTimeUtc(), RegistryValueKind.QWord);
                    Check(PolicyRootSecurity.SavedBeforeProtection(Path.Combine(legacy.SessionRoot, "session.json")), "The fixture journals now predate protection, like an upgraded data folder");
                    var older = await RemoveAll();
                    using var result = JsonDocument.Parse(older.Output);
                    var failures = result.RootElement.GetProperty("data").GetProperty("sessions").EnumerateArray().Where(session => session.GetProperty("status").GetString() == "failed").ToArray();
                    Check(older.Exit != 0 && failures.Length == 1 && failures[0].GetProperty("sessionRoot").GetString() == legacy.SessionRoot && TaskExists(legacy.SessionRoot) && Equals(Launch("CpuPriorityClass"), 6),
                        "Earlier restored journals do not block cleanup, while an earlier unrestored journal still requires approval");
                }
                finally { markers.SetValue(marker, protectedAt, RegistryValueKind.QWord); }
                Check((await RemoveAll()).Exit == 0 && await Restored(legacy.SessionRoot) && NoLaunchPolicy(), "After the fixture protection time is restored, cleanup recovers the last session");

                var boosted = new Dictionary<string, JsonElement>(controls) { ["priorityBoost"] = V(true) };
                var keptLauncher = await OpenLauncher();
                var kept = await Arm(keptLauncher, boosted);
                var keptGame = await Game(keptLauncher);
                await Until(async () => (await App().ReadGameSessionAsync(kept.SessionRoot)).State?.Status == "active", "The game with its own priority boost was not verified.");
                var stopped = await App().StopGameSessionAsync(kept.SessionRoot);
                var leftAsIs = stopped.State!.Games.SelectMany(game => game.Fields).Count(field => field.Name == "priorityBoost" && field.Status == "leftAsIs");
                var stopKeptTask = TaskExists(kept.SessionRoot);
                var keptCores = Affinity(keptGame);
                EndGame(keptGame);
                var removing = await Arm(keptLauncher, boosted);
                var removingGame = await Game(keptLauncher);
                await Until(async () => (await App().ReadGameSessionAsync(removing.SessionRoot)).State?.Status == "active", "The second game with its own priority boost was not verified.");
                var removal = await RemoveAll();
                Console.WriteLine(JsonSerializer.Serialize(new { leftAsIs, stopKeptTask, removalExit = removal.Exit, removalOutput = removal.Output.Trim() }));
                Check(GameSessionDisplay.Restored(stopped) && leftAsIs == 1 && !stopKeptTask && keptCores == original,
                    "Stop finishes a session whose game already had the requested priority boost, leaves the boost as is and removes the sign-in task");
                Check(removal.Exit == 0 && await Restored(kept.SessionRoot) && await Restored(removing.SessionRoot) && !TaskExists(kept.SessionRoot) && !TaskExists(removing.SessionRoot) &&
                    NoLaunchPolicy() && Affinity(removingGame) == original, "Uninstall cleanup finishes when a game kept a setting it already had, and removes every session task");
                EndGame(removingGame);

                var restartLauncher = await OpenLauncher();
                var restart = await Arm(restartLauncher, controls);
                PowerLoss(restart.SessionRoot); await CloseLauncher(restartLauncher);
                var pinned = await Game(null);
                pinned.ProcessorAffinity = (nint)core;
                Check(!GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(restart.SessionRoot)) && Affinity(pinned) == core && TaskExists(restart.SessionRoot),
                    "Without a restart, a game copy on the session's cores could still be inside its core limit, so Recover still waits");
                var statePath = Path.Combine(restart.SessionRoot, "session.json");
                var bootPath = Path.Combine(restart.SessionRoot, "boot.json");
                var startedIn = File.Exists(bootPath) ? JsonNode.Parse(File.ReadAllText(bootPath))!["bootId"]!.GetValue<string>() : null;
                using (var prefetch = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters"))
                    Check(prefetch?.GetValue("BootId")?.ToString() is { } registryBoot && registryBoot == ProcessPolicyHost.BootId(), "The start number the session reads matches the one Windows records for this start");
                Check(startedIn is not null && startedIn == ProcessPolicyHost.BootId() && !JsonNode.Parse(File.ReadAllText(statePath))!.AsObject().ContainsKey("bootId"),
                    "The session records which Windows start it ran in beside its state, so older versions can still read the state");
                string SetWorkerStart(string created)
                {
                    var saved = JsonNode.Parse(File.ReadAllText(statePath))!.AsObject();
                    var before = saved["host"]!["creationTimeFileTimeUtc"]!.GetValue<string>();
                    saved["host"]!["creationTimeFileTimeUtc"] = created;
                    OperationFiles.Write(statePath, saved);
                    return before;
                }
                var beforeBoot = (DateTime.UtcNow - TimeSpan.FromMilliseconds(Environment.TickCount64)).AddMinutes(-10).ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture);
                var workerStart = SetWorkerStart(beforeBoot);
                Check(!GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(restart.SessionRoot)) && Affinity(pinned) == core && TaskExists(restart.SessionRoot),
                    "A worker start time before this Windows start alone, as a clock change could show, doesn't let Recover skip the core-limit check");
                OperationFiles.Write(bootPath, new { bootId = (long.Parse(startedIn!) - 1).ToString(System.Globalization.CultureInfo.InvariantCulture) });
                SetWorkerStart(workerStart);
                Check(!GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(restart.SessionRoot)) && Affinity(pinned) == core && TaskExists(restart.SessionRoot),
                    "A different start number alone, as a resume from hibernation could show, doesn't let Recover skip the core-limit check while the worker started in this Windows start");
                SetWorkerStart(beforeBoot);
                Check(GameSessionDisplay.Restored(await App().RecoverGameSessionAsync(restart.SessionRoot)) && NoLaunchPolicy() && !TaskExists(restart.SessionRoot) && Affinity(pinned) == core,
                    "After a restart, Recover finishes while a copy of the game pinned to the session's cores runs, and leaves that copy's cores alone");
                EndGame(pinned);
            }
        }
        catch (Exception error)
        {
            scenarioError = error;
            try
            {
                var evidence = Path.Combine(repo, "artifacts", "validation", "launch-profile-failure");
                Directory.CreateDirectory(evidence);
                if (Directory.Exists(operations))
                    foreach (var file in Directory.EnumerateFiles(operations, "*.json", SearchOption.AllDirectories))
                        File.Copy(file, Path.Combine(evidence, Path.GetRelativePath(operations, file).Replace(Path.DirectorySeparatorChar, '_')), true);
            }
            catch (Exception captureError) { Console.WriteLine("Evidence: " + captureError.Message); }
            throw;
        }
        finally
        {
            var errors = new List<Exception>();
            void Clean(Action action)
            {
                try { action(); }
                catch (Exception error) { errors.Add(error); }
            }
            async Task CleanAsync(Func<Task> action)
            {
                try { await action(); }
                catch (Exception error) { errors.Add(error); }
            }
            var tasks = new List<string>();
            var processes = new List<object>();
            Clean(() =>
            {
                if (Directory.Exists(operations)) tasks.AddRange(Directory.EnumerateDirectories(operations, "game-session-*").Select(directory => TaskName(Path.Combine(directory, "session"))));
                if (unrelatedSession is not null) tasks.Add(TaskName(unrelatedSession));
                processes.AddRange(games.Concat(launchers).Select(entry => new { id = entry.Process.Id, created = entry.Created }));
            });
            await CleanAsync(async () =>
            {
                var cleanup = App();
                foreach (var profile in await cleanup.ReadLaunchProfilesAsync()) await CleanAsync(async () =>
                {
                    if (await cleanup.DisableLaunchProfileAsync(profile.Root) is { } problem) throw new InvalidOperationException(problem);
                });
                foreach (var entry in await cleanup.ReadGameSessionsAsync())
                    await CleanAsync(async () =>
                    {
                        if (entry.Worker.HostRunning == true) await cleanup.StopGameSessionAsync(entry.SessionRoot);
                        else if (entry.Worker.State is not null) await cleanup.RecoverGameSessionAsync(entry.SessionRoot);
                    });
            });
            foreach (var (game, folder, _) in games) Clean(() =>
            {
                try { if (!game.HasExited) { File.WriteAllText(Path.Combine(folder, "stop"), ""); if (!game.WaitForExit(10000)) { game.Kill(); game.WaitForExit(10000); } } }
                finally { game.Dispose(); }
            });
            foreach (var (launcher, folder, _) in launchers) Clean(() =>
            {
                try { if (!launcher.HasExited) { File.WriteAllText(Path.Combine(folder, "stop-launcher"), ""); if (!launcher.WaitForExit(15000)) { launcher.Kill(); launcher.WaitForExit(10000); } } }
                finally { launcher.Dispose(); }
            });
            await Task.Delay(1000);
            await CleanAsync(async () =>
            {
                foreach (var entry in await App().ReadGameSessionsAsync()) await CleanAsync(async () =>
                {
                    var app = App();
                    var restored = entry.Worker.HostRunning == true ? await app.StopGameSessionAsync(entry.SessionRoot) : await app.RecoverGameSessionAsync(entry.SessionRoot);
                    if (!GameSessionDisplay.Restored(restored) || TaskExists(entry.SessionRoot)) throw new InvalidOperationException("A test session still needs recovery.");
                });
            });
            Clean(() => { if (Registry.LocalMachine.OpenSubKey(Ifeo) is { } leftover) { leftover.Dispose(); Registry.LocalMachine.DeleteSubKeyTree(Ifeo); } });
            Clean(() => Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", previous));
            foreach (var client in clients)
                Clean(() => (typeof(OptimizerService).GetField("_storageLease", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(client) as IDisposable)?.Dispose());
            foreach (var task in tasks) Clean(() => { if (Schtasks("/Query", "/TN", task).Exit == 0 && Schtasks("/Delete", "/TN", task, "/F").Exit != 0) throw new IOException("A fixture task could not be removed."); });
            Clean(() => File.Delete(gamePath)); Clean(() => File.Delete(launcherPath));
            Clean(() => Directory.Delete(root, true));
            Clean(() =>
            {
                if (Directory.Exists(root)) return;
                using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true);
                markers?.DeleteValue(PolicyRootSecurity.MarkerName(operations), false);
                markers?.DeleteValue(PolicyRootSecurity.MarkerName(operations) + PolicyRootSecurity.ProtectedAtSuffix, false);
            });
            if (cleanupFault || harnessFault is not null) Console.WriteLine("Cleanup receipt: " + JsonSerializer.Serialize(new { root, tasks, processes }));
            foreach (var error in errors) Console.WriteLine("Cleanup: " + error.Message);
            if (scenarioError is null && errors.Count != 0) throw new AggregateException(errors);
        }
    }

    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int information, ref int value, int length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr mask, out UIntPtr system);
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr process, int information, out uint value, uint length);
    [DllImport("kernel32.dll", EntryPoint = "GetProcessInformation", SetLastError = true)] static extern bool GetPowerInformation(IntPtr process, int information, ref NativePower value, uint length);
}
