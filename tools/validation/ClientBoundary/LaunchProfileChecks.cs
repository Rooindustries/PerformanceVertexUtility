using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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
        start.Environment["DOTNET_ROOT_X64"] = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet");
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
    static object? Launch(string name)
    {
        using var key = Registry.LocalMachine.OpenSubKey(Ifeo + @"\PerfOptions");
        return key?.GetValue(name);
    }
    static bool NoLaunchPolicy() { using var key = Registry.LocalMachine.OpenSubKey(Ifeo); return key is null; }
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
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(typeof(LaunchProfileChecks).Assembly.Location);
        start.ArgumentList.Add(repo); start.ArgumentList.Add("--launch-profile-cleanup-fault");
        using var child = Process.Start(start)!;
        var output = child.StandardOutput.ReadToEndAsync(); var error = child.StandardError.ReadToEndAsync();
        await child.WaitForExitAsync();
        var stdout = await output; var stderr = await error;
        Console.WriteLine(stdout);
        if (!stderr.Contains("Deliberate profile assertion failure", StringComparison.Ordinal)) Console.WriteLine(stderr);
        Check(child.ExitCode != 0 && stderr.Contains("Deliberate profile assertion failure", StringComparison.Ordinal), "A cleanup error preserves the original failing assertion");
        var receipt = stdout.Split('\n').Single(line => line.StartsWith("Cleanup receipt: ", StringComparison.Ordinal))["Cleanup receipt: ".Length..];
        using var document = JsonDocument.Parse(receipt);
        var root = document.RootElement.GetProperty("root").GetString()!;
        using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
        Check(!Directory.Exists(root) && markers?.GetValue(PolicyRootSecurity.MarkerName(Path.Combine(root, "operations"))) is null && NoLaunchPolicy(), "A failing scenario still removes its fixture folder, marker and launch policy");
        Check(document.RootElement.GetProperty("tasks").EnumerateArray().All(task => Schtasks("/Query", "/TN", task.GetString()!).Exit != 0), "A failing scenario leaves no scheduled task behind");
    }

    public static async Task Run(string repo, bool recovery, bool cleanupFault = false)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-launch-profile-" + Guid.NewGuid().ToString("N"));
        var operations = Path.Combine(root, "operations");
        var previous = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
        var bin = Path.Combine(repo, "tools", "validation", "ProtectedSessions", "bin", "publish");
        var gamePath = Path.Combine(bin, "RooIndustriesProfileGame.exe");
        var launcherPath = Path.Combine(bin, "RooIndustriesProfileLauncher.exe");
        var launchers = new List<(Process Process, string Root)>();
        var games = new List<(Process Process, string Root)>();
        var clients = new List<OptimizerService>();
        string? unrelatedSession = null;
        OptimizerService App()
        {
            var app = new OptimizerService(new BackendLocator(), operations);
            clients.Add(app);
            return app;
        }
        Check(NoLaunchPolicy(), "The probe game starts without launch priorities");
        Directory.CreateDirectory(root);
        File.Copy(Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe"), gamePath, true);
        File.Copy(Path.Combine(bin, "RooIndustriesLaunchPolicyProbe.exe"), launcherPath, true);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", repo);

        async Task<Process> OpenLauncher()
        {
            var folder = Path.Combine(root, "launcher-" + (launchers.Count + 1)); Directory.CreateDirectory(folder);
            var process = Start(launcherPath, "--launcher", folder); launchers.Add((process, folder));
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
        async Task<Process> Game(Process? launcher)
        {
            var folder = Path.Combine(root, "game-" + (games.Count + 1)); Directory.CreateDirectory(folder);
            if (launcher is null) Start(gamePath, "--game", folder, "none").Dispose();
            else OperationFiles.Write(Path.Combine(launchers.Single(item => item.Process == launcher).Root, "launch.json"), new { root = folder, hardware = "none", exe = Path.GetFileName(gamePath) });
            await Until(() => Task.FromResult(File.Exists(Path.Combine(folder, "ready.json"))), "The game fixture did not start.");
            var game = Process.GetProcessById(OperationFiles.Read<JsonElement>(Path.Combine(folder, "ready.json")).GetProperty("pid").GetInt32()); games.Add((game, folder));
            return game;
        }
        void EndGame(Process game) { File.WriteAllText(Path.Combine(games.Single(item => item.Process == game).Root, "stop"), ""); Check(game.WaitForExit(15000), "The game fixture exits"); }
        async Task<bool> Restored(string sessionRoot) => GameSessionDisplay.Restored(await App().ReadGameSessionAsync(sessionRoot));
        async Task<(int Exit, string Output)> RemoveAll()
        {
            using var uninstall = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
            {
                ArgumentList = { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(repo, "backend", "scripts", "Invoke-ProtectedGameSession.ps1"), "-Action", "RemoveAll", "-OperationsRoot", operations, "-ConfirmApply" },
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            })!;
            var output = uninstall.StandardOutput.ReadToEndAsync();
            var error = uninstall.StandardError.ReadToEndAsync();
            await uninstall.WaitForExitAsync();
            return (uninstall.ExitCode, await output + await error);
        }

        Exception? scenarioError = null;
        try
        {
            var first = await OpenLauncher();
            var original = Affinity(first);
            var core = original & (~original + 1);
            Check(core != 0 && core != original && Io(first) == 1, "The launcher fixture starts with more than one core and its own I/O priority");
            var controls = new Dictionary<string, JsonElement> { ["cpuPriority"] = V("AboveNormal"), ["ioPriority"] = V(2), ["affinity"] = V(new AffinityState(0, "0x" + core.ToString("X"))) };

            await (recovery ? Recovery() : Profiles());
            Console.WriteLine((recovery ? "Session recovery" : "Launch profile") + " assertions: " + passed);

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
                Console.WriteLine(uninstall.Output.Trim());
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
            Clean(() =>
            {
                if (Directory.Exists(operations)) tasks.AddRange(Directory.EnumerateDirectories(operations, "game-session-*").Select(directory => TaskName(Path.Combine(directory, "session"))));
                if (unrelatedSession is not null) tasks.Add(TaskName(unrelatedSession));
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
            foreach (var (game, folder) in games) Clean(() =>
            {
                try { if (!game.HasExited) { File.WriteAllText(Path.Combine(folder, "stop"), ""); if (!game.WaitForExit(10000)) { game.Kill(); game.WaitForExit(10000); } } }
                finally { game.Dispose(); }
            });
            foreach (var (launcher, folder) in launchers) Clean(() =>
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
            if (cleanupFault) Console.WriteLine("Cleanup receipt: " + JsonSerializer.Serialize(new { root, tasks }));
            foreach (var error in errors) Console.WriteLine("Cleanup: " + error.Message);
            if (scenarioError is null && errors.Count != 0) throw new AggregateException(errors);
        }
    }

    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr process);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int information, ref int value, int length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr mask, out UIntPtr system);
}
