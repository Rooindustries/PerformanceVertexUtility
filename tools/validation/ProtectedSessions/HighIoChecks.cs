using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class HighIoChecks
{
    static readonly string Bin = Path.GetDirectoryName(typeof(HighIoChecks).Assembly.Location)!;
    static readonly string GamePath = Path.Combine(Bin, "RooIndustriesLaunchPolicyProbe.exe");
    static readonly string LauncherPath = Path.Combine(Bin, "RooIndustriesHighIoLauncher.exe");
    static readonly string StubPath = Path.Combine(Bin, "RooIndustriesHighIoStub.exe");
    const string ImageKey = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesLaunchPolicyProbe.exe";
    static void Until(Func<bool> condition, string message, int seconds = 30)
    {
        var clock = Stopwatch.StartNew();
        while (!condition()) { if (clock.Elapsed.TotalSeconds > seconds) throw new TimeoutException(message); Thread.Sleep(50); }
    }
    static Process Start(string executable, params string[] args)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return Process.Start(info) ?? throw new InvalidOperationException("Fixture did not start.");
    }

    internal static void Run(string repo, string dotnet, int inspectSeconds)
    {
        Environment.SetEnvironmentVariable("DOTNET_ROOT_X64", Path.GetDirectoryName(dotnet));
        var captureAvailable = Oracle.BasicProcessesAvailable();
        Console.WriteLine("MEASURE native launch capture available: " + captureAvailable);
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-high-io-check-" + Guid.NewGuid().ToString("N"));
        var evidence = Path.Combine(repo, "artifacts", "validation", "high-io-cleanup-" + Guid.NewGuid().ToString("N"));
        var fixture = new FixtureScope(root, evidence); var launcherCopy = new FixtureCopy(GamePath, LauncherPath); var stubCopy = new FixtureCopy(GamePath, StubPath);
        var identities = new Dictionary<Process, FixtureProcess>(); var gameRoots = new Dictionary<Process, string>(); Process? launcher = null;
        var engine = new ProtectedSessions(_ => false);
        var states = new List<string>(); var workers = new List<Process>(); var proof = new List<object>(); var passed = 0; var games = 0;
        void Check(bool result, string message) { if (!result) throw new InvalidOperationException(message); Console.WriteLine("PASS " + message); passed++; }
        ProtectedSessionState State(string path) => engine.Status(path).State ?? throw new InvalidDataException("Missing state.");
        ProtectedFieldState Io(string path, Process game) => State(path).Games.Single(item => item.Identity.ProcessId == game.Id).Fields.Single(field => field.Name == "ioPriority");
        void Snapshot(string phase, string session, Process process) => proof.Add(new { phase, process.Id, io = Oracle.Io(process), affinity = "0x" + Oracle.Affinity(process).ToString("X"), state = State(session) });
        void Inspect(Process process, string phase, int expectedIo, ulong expectedAffinity)
        {
            if (inspectSeconds == 0) return;
            Console.WriteLine("INSPECT " + phase + ": game PID " + process.Id + " for " + inspectSeconds + " s; expected I/O " + expectedIo + ", affinity 0x" + expectedAffinity.ToString("X"));
            var hold = Stopwatch.StartNew();
            while (hold.Elapsed.TotalSeconds < inspectSeconds)
            {
                if (Oracle.Io(process) != expectedIo || Oracle.Affinity(process) != expectedAffinity) throw new InvalidOperationException("Independent readback changed during manual inspection.");
                Thread.Sleep(1000);
            }
        }
        try
        {
            using (var existing = Registry.LocalMachine.OpenSubKey(ImageKey)) { if (existing is not null) throw new InvalidOperationException("Fixture registry key already exists; do not overwrite it."); }
            fixture.Secure(); launcherCopy.Create(); stubCopy.Create();
            launcher = Start(LauncherPath, "--high-io-launcher", root); identities.Add(launcher, FixtureProcess.Started(launcher, evidence));
            Until(() => File.Exists(Path.Combine(root, "launcher-ready")), "Fixture launcher not ready.");
            var original = Oracle.Affinity(launcher); var launcherIo = Oracle.Io(launcher);
            List<LogicalCpu> topology;
            using (var target = new ProcessTarget(launcher.Id)) topology = target.Topology().ToList();
            var groups = topology.Where(cpu => cpu.Group == 0 && cpu.Available && (original & (1UL << cpu.Index)) != 0).GroupBy(cpu => cpu.Cache)
                .Select(group => group.Aggregate(0UL, (mask, cpu) => mask | (1UL << cpu.Index))).Where(mask => mask != 0).ToArray();
            var lower = Enumerable.Range(0, 64).Where(bit => (original & (1UL << bit)) != 0).ToArray();
            var first = groups.Length > 1 ? groups[0] : lower.Take(Math.Max(1, lower.Length / 2)).Aggregate(0UL, (mask, bit) => mask | (1UL << bit));
            Console.WriteLine("MEASURE launcher CPUs 0x" + original.ToString("X") + ", cache groups " + string.Join(", ", groups.Select(mask => "0x" + mask.ToString("X"))) + ", game limited to 0x" + first.ToString("X"));
            if (first == original) throw new InvalidOperationException("At least two allowed logical processors are required.");
            if (groups.Length > 1) Check(first == groups[0], "On a CPU with two cache groups, like the 9950X3D's two CCDs, the game is limited to the first one");

            Process ReadGame(string gameRoot, string sessionRoot)
            {
                Until(() => File.Exists(Path.Combine(gameRoot, "ready.json")), "The game did not report its identity.");
                var child = Process.GetProcessById(OperationFiles.Read<JsonElement>(Path.Combine(gameRoot, "ready.json")).GetProperty("pid").GetInt32()); _ = child.Handle;
                var identity = FixtureProcess.Ready(Path.Combine(gameRoot, "ready.json"), GamePath, ["--high-io-game", gameRoot], true, evidence); identities.Add(child, identity);
                if (FixtureProcess.Created(child) != identity.Creation) throw new InvalidDataException("Fixture game handle identity mismatch.");
                gameRoots.Add(child, gameRoot);
                if (sessionRoot.Length != 0) Until(() => State(sessionRoot).Games.Any(item => item.Identity.ProcessId == child.Id && item.Identity.CreationTimeFileTimeUtc == identity.Creation.ToString(System.Globalization.CultureInfo.InvariantCulture) && !item.Exited && item.Fields.All(field => field.Status == "applied")), "The session did not apply every control to this game instance.");
                return child;
            }
            Process Launch(string sessionRoot)
            {
                var gameRoot = Path.Combine(root, "game-" + ++games); Directory.CreateDirectory(gameRoot);
                OperationFiles.Write(Path.Combine(root, "launch.json"), new { root = gameRoot });
                Until(() => File.Exists(Path.Combine(gameRoot, "stub-exited")), "The launcher's helper did not start the game and exit.");
                return ReadGame(gameRoot, sessionRoot);
            }
            Process Restart(Process predecessor, string sessionRoot)
            {
                var nextRoot = Path.Combine(root, "game-" + ++games); Directory.CreateDirectory(nextRoot);
                var previousRoot = gameRoots[predecessor];
                OperationFiles.Write(Path.Combine(previousRoot, "restart.json"), new { root = nextRoot });
                var successor = ReadGame(nextRoot, sessionRoot);
                Until(() => File.Exists(Path.Combine(previousRoot, "restart-started.json")), "The original game did not record its replacement.");
                var receipt = OperationFiles.Read<JsonElement>(Path.Combine(previousRoot, "restart-started.json"));
                Check(receipt.GetProperty("parent").GetInt32() == predecessor.Id && receipt.GetProperty("child").GetInt32() == successor.Id &&
                    receipt.GetProperty("creation").GetString() == identities[successor].Creation.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    "The running game itself starts its replacement before exiting");
                File.WriteAllText(Path.Combine(previousRoot, "restart-ack"), "");
                Check(predecessor.WaitForExit(15000) && predecessor.ExitCode == 0, "The original game exits after its replacement is tracked");
                Until(() => State(sessionRoot).Games.Single(item => item.Identity.ProcessId == predecessor.Id).Exited, "The session did not observe the original game's exit.");
                return successor;
            }
            void Close(Process game)
            {
                File.WriteAllText(Path.Combine(gameRoots[game], "stop"), "");
                Check(game.WaitForExit(15000) && game.ExitCode == 0, "The owned game fixture exits successfully");
            }
            string Arm(string name)
            {
                var previewPath = Path.Combine(root, name + ".preview.json");
                var reviewed = engine.Preview(launcher.Id, GamePath, new() { ["cpuPriority"] = JsonSerializer.SerializeToElement("AboveNormal"), ["ioPriority"] = JsonSerializer.SerializeToElement(3), ["affinity"] = JsonSerializer.SerializeToElement(new AffinityState(0, "0x" + first.ToString("X")), OperationFiles.Json) }, true);
                OperationFiles.Write(previewPath, reviewed);
                var folder = Path.Combine(root, name); states.Add(folder); Directory.CreateDirectory(folder);
                var request = Path.Combine(folder, "request.json");
                OperationFiles.Write(request, new { schemaVersion = 1, repoRoot = Path.GetFullPath(repo), sessionRoot = folder, previewPath, reviewHash = OperationFiles.HashFile(previewPath), confirm = true });
                var worker = Start(Path.Combine(repo, "backend", "bin", "optimizer", "session", "RooIndustries.SessionHost.exe"), "run", request); workers.Add(worker); identities.Add(worker, FixtureProcess.Started(worker, evidence));
                Until(() => File.Exists(Path.Combine(folder, "session.json")) && State(folder).Status == "armed", "The High I/O session did not arm.");
                return folder;
            }
            int JournalOriginal(string session, Process game) => OperationFiles.Read<ProcessControlJournal>(Io(session, game).JournalPath!).Changes.Single().Original.GetInt32();

            var control = Launch("");
            var baselineIo = Oracle.Io(control); var baselineAffinity = Oracle.Affinity(control);
            Check(baselineIo != 3 && baselineAffinity == original, "Without a session the handed-off game starts below High I/O priority on all the launcher's CPUs");
            var direct = new ProcessControlEngine(_ => false);
            var directPath = Path.Combine(root, "direct-preview.json"); var directJournal = Path.Combine(root, "direct-journal.json");
            OperationFiles.Write(directPath, direct.Preview(control.Id, new() { ["ioPriority"] = JsonSerializer.SerializeToElement(3), ["affinity"] = JsonSerializer.SerializeToElement(new AffinityState(0, "0x" + first.ToString("X")), OperationFiles.Json) }));
            Check(direct.Apply(directPath, OperationFiles.HashFile(directPath), directJournal).Status == "applied" && Oracle.Io(control) == 3 && Oracle.Affinity(control) == first,
                "The Processes apply path sets High I/O and the selected CPU restriction on the running probe");
            Check(direct.Restore(directJournal).Status == "restored" && Oracle.Io(control) == baselineIo && Oracle.Affinity(control) == baselineAffinity,
                "Processes Undo restores the probe's exact original I/O and CPU affinity");
            Close(control);

            var plan = engine.Preview(launcher.Id, GamePath, new() { ["ioPriority"] = JsonSerializer.SerializeToElement(3) }, true);
            Check(plan.LauncherChanges is null && plan.OriginalLaunchSettings.Values.Count == 0, "High I/O priority is never written to the launcher or to the game's launch settings in the registry");

            var session = Arm("session1");
            using (var options = Registry.LocalMachine.OpenSubKey(ImageKey + @"\PerfOptions"))
                Check(options?.GetValue("CpuPriorityClass") is 6 && options.GetValue("IoPriority") is null, "While armed, only the CPU priority is set as a launch setting; I/O priority is not");
            Check(Oracle.Io(launcher) == launcherIo, "The launcher keeps its own I/O priority");
            var game = Launch(session);
            Check(Oracle.Io(game) == 3 && Oracle.Affinity(game) == first && game.PriorityClass == ProcessPriorityClass.AboveNormal,
                "After the launcher's helper hands off and exits, the game runs with High I/O priority, Above normal CPU priority and only the chosen CPUs");
            Check(JournalOriginal(session, game) == baselineIo, "The session saved the game's original I/O priority before it set High");
            Snapshot("first launch", session, game);
            if (inspectSeconds > 0) Console.WriteLine("INSPECT game PID " + game.Id + " for " + inspectSeconds + " s: Task Manager > Details > Set affinity shows only mask 0x" + first.ToString("X") + "; Process Explorer's I/O Priority column shows High.");
            var hold = Stopwatch.StartNew();
            while (hold.Elapsed.TotalSeconds < Math.Max(12, inspectSeconds))
            {
                if (Oracle.Io(game) != 3 || Oracle.Affinity(game) != first) throw new InvalidOperationException("High I/O priority or the CPU limit drifted during the hold.");
                Thread.Sleep(1000);
            }
            Check(true, "Independent readback shows High I/O priority and the CPU limit held for the whole hold");
            void Lock(Process process)
            {
                if (!captureAvailable) return;
                File.WriteAllText(Path.Combine(gameRoots[process], "lock"), "");
                Until(() => File.Exists(Path.Combine(gameRoots[process], "locked")), "The fixture did not deny later control handles.");
                var denied = false;
                try { using var fresh = new ProcessTarget(process.Id, ["ioPriority"]); }
                catch (RooIndustries.Optimization.CpuSets.NativeFailure failure) when (failure.NativeErrorCode == 5) { denied = true; }
                Check(denied, "The disposable game now denies fresh I/O setter handles");
            }
            Lock(game);
            Oracle.SetIo(game, baselineIo);
            Until(() => Oracle.Io(game) == 3 && Io(session, game).Reapplications > 0, "A reset to the original I/O priority was not put back.");
            Check(true, "When something resets the game to its original I/O priority, the session puts High back");
            Snapshot("reapplied after new setter handles denied", session, game);
            Close(game);
            Until(() => State(session).Status == "armed", "The session did not wait for the next game start.");
            var again = Launch(session);
            Check(Oracle.Io(again) == 3 && Oracle.Affinity(again) == first && State(session).Games.Count == 2, "A new copy of the game started after the first one closed also gets High I/O priority and the chosen CPUs");
            Snapshot("relaunch", session, again);
            Inspect(again, "relaunch", 3, first);
            Lock(again);
            engine.Command(session, "stop");
            Check(workers.Last().WaitForExit(20000), "The session stops when asked");
            Until(() => File.Exists(Path.Combine(session, "recovery-result.json")), "The recovery watcher did not finish.");
            Check(State(session).Status == "stopped" && Io(session, again).Status == "restored", "Stop reports the game's I/O priority as restored");
            Check(Oracle.Io(again) == baselineIo && Oracle.Affinity(again) == original, "Stop puts the game's exact original I/O priority and all the launcher's CPUs back");
            Snapshot("Stop restored while game stays alive", session, again);
            Inspect(again, "Stop restored", baselineIo, original);
            using (var key = Registry.LocalMachine.OpenSubKey(ImageKey)) Check(key is null, "Stop removes the game's launch settings from the registry");
            Close(again);

            session = Arm("session-self-restart");
            game = Launch(session);
            var replacement = Restart(game, session);
            Check(State(session).Games.Count == 2 && Io(session, game).JournalPath != Io(session, replacement).JournalPath && Oracle.Io(replacement) == 3 && Oracle.Affinity(replacement) == first,
                "A game that restarts itself gets a distinct journal and the selected High I/O and CPUs on its replacement");
            var replacementOriginalIo = JournalOriginal(session, replacement);
            Snapshot("game restarted itself", session, replacement);
            engine.Command(session, "stop");
            Check(workers.Last().WaitForExit(20000), "The self-restart session stops");
            Until(() => File.Exists(Path.Combine(session, "recovery-result.json")), "The self-restart recovery watcher did not finish.");
            Check(State(session).Status == "stopped" && Oracle.Io(replacement) == replacementOriginalIo && Oracle.Affinity(replacement) == original,
                "Stop restores the replacement's own captured I/O original, including an inherited High value, and clears the session CPU limit");
            Snapshot("self-restarted game restored", session, replacement);
            Close(replacement);

            session = Arm("session2");
            game = Launch(session);
            Check(Oracle.Io(game) == 3, "A new session sets High I/O priority");
            Lock(game);
            identities[workers.Last()].Stop();
            Check(workers.Last().WaitForExit(10000), "Only the disposable session worker is ended for the crash case");
            Until(() => File.Exists(Path.Combine(session, "recovery-result.json")), "The recovery watcher did not finish after the worker ended.");
            Check(State(session).Status == "stopped" && Oracle.Io(game) == baselineIo && Oracle.Affinity(game) == original, "When the session worker is killed, the recovery watcher puts the original I/O priority and CPUs back");
            Snapshot("worker death restored", session, game);
            Close(game);

            session = Arm("session3");
            game = Launch(session);
            var foreign = baselineIo == 1 ? 0 : 1;
            Oracle.SetIo(game, foreign);
            Until(() => Io(session, game).Status == "conflict", "Another program's I/O priority was not reported.");
            Check(Oracle.Io(game) == foreign, "The session leaves a different I/O priority another program set");
            engine.Command(session, "stop");
            Check(workers.Last().WaitForExit(20000), "The session stops without overwriting another program's value");
            Until(() => File.Exists(Path.Combine(session, "recovery-result.json")), "The recovery watcher did not finish after the conflict.");
            Check(State(session).Status == "recoveryRequired" && Oracle.Io(game) == foreign && Oracle.Affinity(game) == original, "Stop keeps the other program's I/O priority, says it needs attention and still releases the CPU limit");
            Snapshot("foreign value preserved", session, game);
            Oracle.SetIo(game, 3);
            var reconciled = engine.Recover(session, State(session).Preview.OperationId);
            Check(ProtectedSessions.IsRestored(reconciled) && Oracle.Io(game) == baselineIo, "Once the value is back to High, recovery restores the saved original");
            Snapshot("manual reconciliation restored", session, game);
            Close(game);
        }
        finally
        {
            bool finished = true;
            void Step(Action action) { try { action(); } catch { finished = false; throw; } }
            FixtureScope.Finish(
                () => Step(() => { foreach (var worker in workers) { identities[worker].Stop(); worker.Dispose(); } }),
                () => Step(() => { foreach (var session in states) { if (File.Exists(Path.Combine(session, "session.json"))) { FixtureScope.AwaitRecovery(session, evidence); engine.Recover(session, State(session).Preview.OperationId); } } }),
                () => Step(() => { if (launcher is not null) { File.WriteAllText(Path.Combine(root, "stop-launcher"), ""); if (!launcher.WaitForExit(15000)) identities[launcher].Stop(); launcher.Dispose(); } }),
                () => Step(() => { foreach (var identity in identities.Values) identity.Stop(); }),
                () => { fixture.Cleanup(finished); },
                () => { launcherCopy.Remove(); },
                () => { stubCopy.Remove(); },
                () => { foreach (var identity in identities.Values) identity.Dispose(); });
        }
        Check(!Directory.Exists(root), "Fixture cleanup removes its folder");
        OperationFiles.Write(Path.Combine(repo, "artifacts", "validation", "high-io-result.json"), new { passed, proof });
        Console.WriteLine("High I/O session assertions: " + passed);
    }

    internal static void Launcher(string root)
    {
        var children = new List<Process>(); Directory.CreateDirectory(Path.Combine(root, "process-receipts")); File.WriteAllText(Path.Combine(root, "launcher-ready"), "");
        try
        {
            var until = DateTime.UtcNow.AddMinutes(15);
            while (!File.Exists(Path.Combine(root, "stop-launcher")) && DateTime.UtcNow < until)
            {
                var path = Path.Combine(root, "launch.json");
                if (File.Exists(path))
                {
                    var request = OperationFiles.Read<JsonElement>(path); File.Delete(path);
                    var stub = Start(StubPath, "--high-io-stub", request.GetProperty("root").GetString()!); _ = stub.Handle; children.Add(stub);
                    if (stub.WaitForExit(15000)) File.WriteAllText(Path.Combine(request.GetProperty("root").GetString()!, "stub-exited"), "");
                }
                Thread.Sleep(20);
            }
        }
        finally { foreach (var child in children) { if (!child.HasExited) { using var owned = FixtureProcess.Started(child, Path.Combine(root, "process-receipts")); owned.Stop(); child.WaitForExit(10000); } child.Dispose(); } }
    }

    internal static void Stub(string root)
    {
        using var game = Start(GamePath, "--high-io-game", root);
    }

    internal static void Game(string root)
    {
        using var self = Process.GetCurrentProcess(); _ = self.Handle;
        OperationFiles.Write(Path.Combine(root, "ready.json"), new { pid = self.Id, creationTimeFileTimeUtc = FixtureProcess.Created(self).ToString(), administrator = true });
        var until = DateTime.UtcNow.AddMinutes(8);
        while (!File.Exists(Path.Combine(root, "stop")) && DateTime.UtcNow < until)
        {
            var restart = Path.Combine(root, "restart.json");
            if (File.Exists(restart))
            {
                var nextRoot = OperationFiles.Read<JsonElement>(restart).GetProperty("root").GetString()!;
                using var replacement = Start(GamePath, "--high-io-game", nextRoot);
                using var owned = FixtureProcess.Started(replacement, Path.Combine(root, "process-receipts"));
                try
                {
                    OperationFiles.Write(Path.Combine(root, "restart-started.json"), new { parent = self.Id, child = replacement.Id, creation = owned.Creation.ToString(System.Globalization.CultureInfo.InvariantCulture) });
                    Until(() => File.Exists(Path.Combine(root, "restart-ack")), "The runner did not adopt the restarted game.");
                }
                catch { owned.Stop(); throw; }
                return;
            }
            if (File.Exists(Path.Combine(root, "lock")) && !File.Exists(Path.Combine(root, "locked")))
            {
                RetainedGpuChecks.DenyNewGpuHandles(self);
                File.WriteAllText(Path.Combine(root, "locked"), "");
            }
            Thread.Sleep(10);
        }
    }
}
