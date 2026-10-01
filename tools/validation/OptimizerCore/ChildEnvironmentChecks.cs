using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;
using H = DataRootHarness;

static class ChildEnvironmentChecks
{
    public static readonly string[] InProcess = ["control-helper", "restart", "hibernation", "cleanup-temp-root", "data-folder-schtasks", "leftover-temp", "data-root-profile"];

    public static async Task Run(Action<bool, string> check, string scenario, string mode, string? directory)
    {
        string Required() => directory ?? throw new ArgumentException("This scenario needs a fixture or binaries directory.");
        switch (scenario)
        {
            case "control-helper": ControlHelper(check, mode); break;
            case "restart": Restart(check, mode); break;
            case "hibernation": Hibernation(check, mode); break;
            case "cleanup-temp-root": CleanupTempRoot(check, mode); break;
            case "data-folder-schtasks": DataFolderSchtasks(check, mode); break;
            case "leftover-temp": LeftoverTemp(check, mode); break;
            case "data-root-profile": DataRootProfile(check, mode); break;
            case "registry-hook": RegistryHook(check, mode); break;
            case "firmware-provider": FirmwareProvider(check, mode, Required()); break;
            case "firmware-extractor": await FirmwareExtractor(check, mode, Required()); break;
            case "host-script": HostScript(check, mode, Required()); break;
            case "host-watcher": Watcher(check, mode, Required(), false); break;
            case "session-host-watcher": Watcher(check, mode, Required(), true); break;
            default: throw new ArgumentException("Unknown child-environment scenario " + scenario);
        }
    }

    static string Temporary(string label) => Path.Combine(Path.GetTempPath(), "roo-industries-child-env-" + label + "-" + Guid.NewGuid().ToString("N"));

    static List<string> Verify(ChildEnv env, ChildObservation seen, string? image, IEnumerable<KeyValuePair<string, string?>>? product = null, params string[] tolerated)
    {
        var failures = env.Verify(seen, product ?? [], tolerated);
        if (image is not null && ChildEnv.ImageFailure(seen, image) is { } wrong) failures.Add(wrong);
        if (seen.ProcessId == Environment.ProcessId) failures.Add("the report came from the test process itself");
        return failures;
    }

    static List<string> VerifyFromPoisonedHost(ChildEnv env, ChildObservation seen, string? image, IEnumerable<KeyValuePair<string, string?>>? product = null, params string[] tolerated)
    {
        var failures = env.Verify(seen, product ?? [], true, tolerated);
        if (image is not null && ChildEnv.ImageFailure(seen, image) is { } wrong) failures.Add(wrong);
        if (seen.ProcessId == Environment.ProcessId) failures.Add("the report came from the test process itself");
        return failures;
    }

    static void ForRelease(ProcessStartInfo start)
    {
        if (!RuntimeEnvironment.Release) return;
        foreach (var name in start.Environment.Keys.Where(name => RuntimeEnvironment.ClearPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))).ToArray()) start.Environment.Remove(name);
    }

    static void ControlHelper(Action<bool, string> check, string mode)
    {
        var address = new ControlAddress("filesystem", "ntfs", "last-access");
        var baseline = PowerShellControls.Read(address);
        var lastAccess = baseline.Value.GetInt32();
        check(lastAccess is >= 0 and <= 3, "The real file-system control reads the NTFS last-access mode without markers: " + lastAccess);
        ChildEnv.Run(check, mode, null, env =>
        {
            var real = PowerShellControls.Launcher;
            ChildObservation? seen = null;
            string? captureError = null;
            PowerShellControls.Launcher = request =>
            {
                var process = real(request);
                try { seen = ProcessEnvironmentReader.Read(process.Id); }
                catch (Exception error) when (error is Win32Exception or InvalidOperationException) { captureError = error.Message; }
                return process;
            };
            TweakControlRead? marked = null;
            string? readError = null;
            try { marked = PowerShellControls.Read(address); }
            catch (Exception error) { readError = error.Message; }
            finally { PowerShellControls.Launcher = real; }
            check(readError is null, "The real file-system control read still works while windir and SystemRoot point at a marker folder" + (readError is null ? "" : ": " + readError));
            check(seen is not null, "The live Windows control helper's environment could be read from outside" + (captureError is null ? "" : ": " + captureError));
            var request = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new { action = "read", address }, OperationFiles.Json));
            var failures = Verify(env, seen!, ChildEnv.PowerShell, [new("ROO_INDUSTRIES_CONTROL_REQUEST", request), new("ROO_INDUSTRIES_CONTROL_HELPER", null)]);
            if (seen!.Variables.TryGetValue("ROO_INDUSTRIES_CONTROL_HELPER", out var helper) && helper.Length < 1000) failures.Add("the control helper payload is only " + helper.Length + " characters");
            ChildEnv.Report(check, "Windows control helper child", env, seen, failures);
            check(marked is not null && marked.Value.GetRawText() == baseline.Value.GetRawText() && marked.Binding == baseline.Binding && marked.Identity == baseline.Identity,
                "A status read returns the same value, binding and identity with the markers set as without them (" + marked?.Value.GetRawText() + " vs " + baseline.Value.GetRawText() + ")");
        });
    }

    static void CleanupTempRoot(Action<bool, string> check, string mode)
    {
        var isProtected = typeof(FileCleanupEngine).GetMethod("IsProtectedPath", BindingFlags.NonPublic | BindingFlags.Static) ?? throw new MissingMethodException("FileCleanupEngine.IsProtectedPath");
        var userTemp = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp");
        ChildEnv.Run(check, mode, null, env =>
        {
            check(!string.Equals(Path.GetTempPath().TrimEnd('\\'), userTemp, StringComparison.OrdinalIgnoreCase), "The test process temp folder points away from the user's temp folder, as the protected temp of a Host started by the app does");
            check((bool)isProtected.Invoke(null, [userTemp])!, "The user's temp folder stays a protected cleanup root while TEMP points at another folder");
            check((bool)isProtected.Invoke(null, [Path.GetTempPath().TrimEnd('\\')])!, "The folder TEMP points at is a protected cleanup root as well");
        });
    }

    static void DataFolderSchtasks(Action<bool, string> check, string mode)
    {
        var run = typeof(DataFolder).GetMethod("Schtasks", BindingFlags.NonPublic | BindingFlags.Static, [typeof(string[])]) ?? throw new MissingMethodException("DataFolder.Schtasks");
        ChildEnv.Run(check, mode, null, env =>
        {
            using var stop = new CancellationTokenSource();
            ChildObservation? seen = null;
            var watcher = Task.Run(() => Capture(stop.Token, "schtasks", observed => seen = observed));
            var completed = 0;
            try
            {
                for (; completed < 300 && seen is null; completed++)
                    run.Invoke(null, [new[] { "/Query", "/TN", "\\RooIndustriesNoSuchTask-" + Guid.NewGuid().ToString("N") }]);
            }
            finally { stop.Cancel(); watcher.Wait(); }
            check(completed > 0, "The data folder move's schtasks launch ran to completion while the markers were set (" + completed + " launches)");
            check(seen is not null, "A live schtasks child's environment could be read from outside");
            ChildEnv.Report(check, "Data folder schtasks child", env, seen!, Verify(env, seen!, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "schtasks.exe")));
        });
    }

    static void DataRootProfile(Action<bool, string> check, string mode)
    {
        var root = BrandCompatibility.LocalDataRoot;
        var local = Path.Combine(RuntimeEnvironment.Profile, "AppData", "Local");
        var marker = Temporary("profile");
        Directory.CreateDirectory(Path.Combine(marker, "profile", "AppData", "Local"));
        try
        {
            var cases = new (string Label, Dictionary<string, string> Environment)[]
            {
                ("USERPROFILE and LOCALAPPDATA pointing at an existing folder", new() { ["USERPROFILE"] = Path.Combine(marker, "profile"), ["LOCALAPPDATA"] = Path.Combine(marker, "profile", "AppData", "Local"), ["APPDATA"] = Path.Combine(marker, "roaming") }),
                ("USERPROFILE and LOCALAPPDATA pointing at a folder that does not exist", new() { ["USERPROFILE"] = Path.Combine(marker, "missing"), ["LOCALAPPDATA"] = Path.Combine(marker, "missing", "local"), ["APPDATA"] = Path.Combine(marker, "missing", "roaming") }),
                ("USERPROFILE, LOCALAPPDATA and APPDATA empty", new() { ["USERPROFILE"] = "", ["LOCALAPPDATA"] = "", ["APPDATA"] = "" }),
            };
            foreach (var (label, variables) in cases)
                foreach (var order in new[] { "resolve-first", "pin-first" })
                {
                    var (exit, output) = H.Child(["--child-data-root", order], variables);
                    var lines = output.Split('\n', StringSplitOptions.TrimEntries);
                    check(exit == 0 && lines.Contains("ROOT " + root), "A process with " + label + " resolves the real data folder (" + order + "): " + output.Replace("\n", " | "));
                    if (order == "pin-first") check(lines.Contains("LOCAL " + local), "After the app pins the profile, the known-folder lookup agrees with the real profile (" + label + ")");
                }
        }
        finally { Directory.Delete(marker, true); }
        check(!Directory.Exists(marker), "The data root scenario leaves no folder behind");
    }

    static void LeftoverTemp(Action<bool, string> check, string mode)
    {
        var name = "roo-industries-leftover-" + Guid.NewGuid().ToString("N");
        var realTemp = Path.Combine(RuntimeEnvironment.LocalAppData, "Temp");
        var folder = Path.Combine(realTemp, name);
        var keyPath = "Software\\RooIndustriesLeftoverTemp-" + Guid.NewGuid().ToString("N");
        Directory.CreateDirectory(folder);
        try
        {
            using (var key = Registry.CurrentUser.CreateSubKey(keyPath))
            {
                key.SetValue("Referencing", "%TEMP%\\" + name + "\\program.exe", RegistryValueKind.ExpandString);
                key.SetValue("Absolute", folder + "\\data", RegistryValueKind.String);
            }
            ChildEnv.Run(check, mode, null, env =>
            {
                var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                var scope = new RegistryAddress("CurrentUser", "Registry64", keyPath, "key", null);
                foreach (var (label, install, wanted) in new[] { ("an absolute install location and a registry value that names %TEMP%", folder, "Referencing"), ("an install location that names %TEMP% and an absolute registry value", "%TEMP%\\" + name, "Absolute") })
                {
                    var app = new CleanupApplication { AppId = "leftover-temp", DisplayName = "Roo Industries Leftover Temp Fixture", Publisher = null, InstallLocation = install, PackageFamilyName = null };
                    var result = new LeftoverDiscovery(app, []).Scan(CancellationToken.None, [], [scope]);
                    var values = result.Candidates.Where(candidate => candidate.Kind == "registryValue").Select(candidate => candidate.Registry!.ValueName).ToArray();
                    check(values.Contains(wanted), "A leftover under the user's real temp folder is discovered for " + label + " (found: " + string.Join(", ", values) + ")");
                }
                var expected = string.Join("|", Path.Combine(profile, "AppData", "Roaming"), Path.Combine(profile, "AppData", "Local"), profile, env.Values["ProgramData"], realTemp, realTemp, env.Windows, env.Windows, "%UNDEFINED_ROO_INDUSTRIES_VARIABLE%");
                var expanded = RuntimeEnvironment.ExpandUserVariables("%APPDATA%|%LOCALAPPDATA%|%USERPROFILE%|%ProgramData%|%TEMP%|%TMP%|%SystemRoot%|%windir%|%UNDEFINED_ROO_INDUSTRIES_VARIABLE%");
                check(expanded == expected, "Uninstall data expands user-profile variables against the real user's folders, not the process block: " + expanded);
                check(!string.Equals(Path.GetTempPath().TrimEnd('\\'), realTemp, StringComparison.OrdinalIgnoreCase), "The process TEMP points away from the user's real temp folder, as in a Host the app started");
                var script = Path.Combine(ChildEnv.RepoRoot(), "backend", "scripts", "BrandCompatibility.Common.ps1");
                var shell = new ProcessStartInfo(ChildEnv.PowerShell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                RuntimeEnvironment.Apply(shell);
                foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", ". '" + script + "'; Expand-RooIndustriesUserVariables '%TEMP%\\x|%tmp%\\y|%LOCALAPPDATA%\\z'" }) shell.ArgumentList.Add(argument);
                using (var child = Process.Start(shell)!)
                {
                    var answer = child.StandardOutput.ReadToEnd().Trim();
                    var problem = child.StandardError.ReadToEnd().Trim();
                    child.WaitForExit();
                    check(answer == string.Join("|", Path.Combine(realTemp, "x"), Path.Combine(realTemp, "y"), Path.Combine(profile, "AppData", "Local", "z")), "A script the Host starts expands %TEMP% and %TMP% in uninstall data to the user's real temp folder, not its own protected temp: " + answer + " " + problem);
                }
            });
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(keyPath, false);
            Directory.Delete(folder, true);
        }
        check(!Directory.Exists(folder), "The leftover scenario leaves no folder behind");
    }

    static void Restart(Action<bool, string> check, string mode)
    {
        var root = Temporary("restart");
        Directory.CreateDirectory(root);
        try
        {
            var dump = Path.Combine(root, "restart-env.txt");
            ChildEnv.Run(check, mode, null, env =>
            {
                var started = DateTime.UtcNow.AddSeconds(-1);
                SystemRestart.Run(new RestartCommand(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"), ["/d", "/c", "set", ">", dump], false));
                var seen = ChildEnv.ReadDump(dump, started, "cmd.exe set output");
                ChildEnv.Report(check, "System restart command child", env, seen, Verify(env, seen, null, null, "PROMPT"));
            });
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The restart scenario leaves no files behind");
    }

    static void Hibernation(Action<bool, string> check, string mode)
    {
        var run = typeof(HibernationControl).GetMethod("Run", BindingFlags.NonPublic | BindingFlags.Static, [typeof(string[])]) ?? throw new MissingMethodException("HibernationControl.Run");
        ChildEnv.Run(check, mode, null, env =>
        {
            using var stop = new CancellationTokenSource();
            ChildObservation? seen = null;
            var watcher = Task.Run(() => Capture(stop.Token, "powercfg", observed => seen = observed));
            var completed = 0;
            try
            {
                for (; completed < 60 && seen is null; completed++)
                {
                    try { run.Invoke(null, [new[] { "/list" }]); }
                    catch (TargetInvocationException error) { throw new InvalidOperationException("powercfg did not run with the markers set: " + error.InnerException?.Message, error); }
                }
            }
            finally { stop.Cancel(); watcher.Wait(); }
            check(completed > 0, "The real powercfg launch ran to completion with exit code 0 while the markers were set (" + completed + " launches)");
            check(seen is not null, "A live powercfg child's environment could be read from outside");
            ChildEnv.Report(check, "Hibernation powercfg child", env, seen!, Verify(env, seen!, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "powercfg.exe")));
        });
    }

    static void RegistryHook(Action<bool, string> check, string mode)
    {
        var flag = Temporary("hang") + ".flag";
        File.WriteAllText(flag, "");
        var overrides = new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_FEATURE_HANG"] = flag };
        try
        {
            ChildEnv.Run(check, mode, overrides, env =>
            {
                var read = new RegistryTweakStore().ReadControlsAsync([new ControlAddress("windows-features", "NetFx3", "enabled")]);
                ChildObservation? seen = null;
                using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                Capture(stop.Token, "PING", observed => seen = observed);
                try
                {
                    check(!read.IsCompleted, "The test hook held the feature read open (build the validation project with -p:RooIndustriesTestHooks=true)");
                    check(seen is not null, "The hook's long-lived ping child's environment could be read from outside");
                    ChildEnv.Report(check, "Registry test-hook child", env, seen!, Verify(env, seen!, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "PING.EXE")));
                }
                finally
                {
                    foreach (var process in Process.GetProcessesByName("PING"))
                        using (process)
                            if (ProcessEnvironmentReader.ParentOf(process.Id) == Environment.ProcessId) process.Kill();
                }
            });
        }
        finally { File.Delete(flag); }
    }

    static void Capture(CancellationToken stop, string name, Action<ChildObservation> found)
    {
        while (!stop.IsCancellationRequested)
            foreach (var process in Process.GetProcessesByName(name))
                using (process)
                {
                    if (ProcessEnvironmentReader.ParentOf(process.Id) != Environment.ProcessId) continue;
                    try { found(ProcessEnvironmentReader.Read(process.Id)); return; }
                    catch (Exception error) when (error is Win32Exception or InvalidOperationException) { }
                }
    }

    static void FirmwareProvider(Action<bool, string> check, string mode, string fixture)
    {
        var root = Temporary("firmware");
        try
        {
            var package = ScewinProvider.Inspect(fixture);
            var directory = ScewinProvider.SetUp(fixture, package, Path.Combine(root, "packages"));
            File.WriteAllText(Path.Combine(directory, "fixture-authority.txt"), "roo-industries-firmware-cli-fixture/v1");
            var provider = new ScewinProvider(directory);
            var identity = provider.ReadIdentity();
            check(!string.IsNullOrWhiteSpace(identity.Board) && !string.IsNullOrWhiteSpace(identity.Bios), "The provider reads motherboard and BIOS identity without markers");
            var report = Path.Combine(directory, "env-report.txt");
            ChildEnv.Run(check, mode, null, env =>
            {
                var started = DateTime.UtcNow.AddSeconds(-1);
                provider.Export(directory);
                var seen = ChildEnv.ReadDump(report, started, "the SCEWIN fixture's own report");
                ChildEnv.Report(check, "SCEWIN provider child", env, seen, Verify(env, seen, Path.Combine(directory, "SCEWIN64.exe")));
                var marked = provider.ReadIdentity();
                check(marked.Board == identity.Board && marked.Bios == identity.Bios, "The provider's PowerShell identity read returns the same board and BIOS with the markers set");
            });
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The firmware provider scenario leaves no files behind");
    }

    static async Task FirmwareExtractor(Action<bool, string> check, string mode, string fixture)
    {
        var root = Temporary("extractor");
        Directory.CreateDirectory(Path.Combine(root, "tools"));
        try
        {
            var extractor = Path.Combine(root, "tools", "innoextract.exe");
            File.Copy(Path.Combine(fixture, "EnvironmentReporter.exe"), extractor);
            var installer = Path.Combine(root, "installer.exe");
            File.WriteAllText(installer, "not an installer");
            var method = typeof(ScewinSetup).GetMethod("ExtractInstallerAsync", BindingFlags.NonPublic | BindingFlags.Static) ?? throw new MissingMethodException("ScewinSetup.ExtractInstallerAsync");
            await ChildEnv.RunAsync(check, mode, null, async env =>
            {
                var started = DateTime.UtcNow.AddSeconds(-1);
                await (Task)method.Invoke(null, [extractor, installer, Path.Combine(root, "out"), "app/Lib", CancellationToken.None])!;
                var seen = ChildEnv.ReadDump(Path.Combine(root, "tools", "env-report.txt"), started, "the extractor fixture's own report");
                ChildEnv.Report(check, "SCEWIN package extractor child", env, seen, Verify(env, seen, extractor));
            });
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The extractor scenario leaves no files behind");
    }

    static void HostScript(Action<bool, string> check, string mode, string hostDirectory)
    {
        var root = Temporary("host-script");
        var fixture = Path.Combine(root, "repo");
        Directory.CreateDirectory(Path.Combine(fixture, "backend", "profiles"));
        Directory.CreateDirectory(Path.Combine(fixture, "backend", "scripts"));
        try
        {
            File.Copy(Path.Combine(ChildEnv.RepoRoot(), "backend", "profiles", "protected-processes.json"), Path.Combine(fixture, "backend", "profiles", "protected-processes.json"));
            var owner = OperationOwner.Current();
            var answer = JsonSerializer.Serialize(new CleanupAuthority { AppId = "fixture-app", ProviderIdentityHash = "fixture-hash", Owner = owner, ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true }, OperationFiles.Json);
            var script = Path.Combine(fixture, "backend", "scripts", "Get-CleanupAuthority.ps1");
            File.WriteAllText(script, "param([string]$QueueJournalPath,[string]$AppId)\n" + ChildEnv.DumpScript("(Join-Path $PSScriptRoot 'env-Get-CleanupAuthority.txt')") + "@'\n" + answer + "\n'@\n");
            var request = Path.Combine(root, "request.json");
            File.WriteAllText(request, JsonSerializer.Serialize(new { schemaVersion = 1, repoRoot = fixture, queueJournalPath = Path.Combine(root, "queue.json"), appId = "fixture-app" }));
            ChildEnv.Run(check, mode, null, env =>
            {
                var started = DateTime.UtcNow.AddSeconds(-1);
                var start = new ProcessStartInfo(ChildEnv.DotNetMuxer()) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
                ForRelease(start);
                foreach (var argument in new[] { Path.Combine(hostDirectory, "Optimizer.Host.dll"), "cleanup-authority", "-" }) start.ArgumentList.Add(argument);
                using var host = Process.Start(start)!;
                host.StandardInput.Write(File.ReadAllText(request));
                host.StandardInput.Close();
                var output = host.StandardOutput.ReadToEndAsync();
                var errors = host.StandardError.ReadToEndAsync();
                if (!host.WaitForExit(120000)) { host.Kill(true); throw new TimeoutException("The published Host did not finish."); }
                var text = output.GetAwaiter().GetResult();
                check(host.ExitCode == 0 && JsonDocument.Parse(text).RootElement.GetProperty("data").GetProperty("appId").GetString() == "fixture-app", "The real Host accepted the provider script's answer through its RunScript path: " + text.Trim() + errors.GetAwaiter().GetResult().Trim());
                var seen = ChildEnv.ReadDump(Path.Combine(fixture, "backend", "scripts", "env-Get-CleanupAuthority.txt"), started, "the provider script's own report");
                ChildEnv.Report(check, "Host RunScript child", env, seen, VerifyFromPoisonedHost(env, seen, ChildEnv.PowerShell, null, ChildEnv.PowerShellAdds));
            });
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The Host script scenario leaves no files behind");
    }

    static void Watcher(Action<bool, string> check, string mode, string binaries, bool sessionHost)
    {
        var kind = sessionHost ? "SessionHost" : "Host";
        var root = Temporary("watcher");
        var operations = Path.Combine(root, "operations");
        Process? launcher = null, runner = null;
        Directory.CreateDirectory(root);
        try
        {
            OperationsFolder.Secure(operations);
            OperationsFolder.Ensure(operations);
            var session = Path.Combine(operations, "session-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(session);
            var game = Path.Combine(root, "EnvGame.exe");
            File.Copy(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "whoami.exe"), game);
            var probe = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            probe.ArgumentList.Add("--probe");
            launcher = Process.Start(probe)!;
            var preview = new ProtectedSessions(_ => false).Preview(launcher.Id, game, new() { ["priorityBoost"] = JsonSerializer.SerializeToElement(true) }, true);
            var previewPath = Path.Combine(operations, "preview.json");
            OperationFiles.Write(previewPath, preview);
            var requestPath = Path.Combine(operations, "request.json");
            var common = new Dictionary<string, object?> { ["schemaVersion"] = 1, ["repoRoot"] = ChildEnv.RepoRoot(), ["sessionRoot"] = session, ["confirm"] = true, ["previewPath"] = previewPath, ["reviewHash"] = OperationFiles.HashFile(previewPath) };
            OperationFiles.Write(requestPath, common);
            ChildEnv.Run(check, mode, null, env =>
            {
                try
                {
                    var expectedImage = sessionHost ? Path.Combine(binaries, "RooIndustries.SessionHost.exe") : ChildEnv.DotNetMuxer();
                    var start = new ProcessStartInfo(expectedImage) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                    ForRelease(start);
                    if (!sessionHost) start.ArgumentList.Add(Path.Combine(binaries, "Optimizer.Host.dll"));
                    foreach (var argument in sessionHost ? new[] { "run", requestPath } : ["protected-session-run", requestPath]) start.ArgumentList.Add(argument);
                    runner = Process.Start(start)!;
                    var output = runner.StandardOutput.ReadToEndAsync();
                    var errors = runner.StandardError.ReadToEndAsync();
                    var watchPath = Path.Combine(session, "watch.json");
                    ProtectedWatchReady? ready = null;
                    for (var waited = Stopwatch.StartNew(); ready is null && waited.Elapsed < TimeSpan.FromSeconds(90) && !runner.HasExited; Thread.Sleep(100))
                        try { if (File.Exists(watchPath)) ready = OperationFiles.Read<ProtectedWatchReady>(watchPath); }
                        catch (Exception error) when (error is IOException or JsonException or InvalidDataException) { }
                    check(ready is not null, "The " + kind + " session started its recovery watcher" + (ready is null ? " (" + (runner.HasExited ? "the " + kind + " exited " + runner.ExitCode + ": " + output.GetAwaiter().GetResult() + errors.GetAwaiter().GetResult() : "no watch.json") + ")" : ""));
                    var own = ProcessEnvironmentReader.Read(runner.Id);
                    ChildEnv.Report(check, kind + " own environment", env, own, Verify(env, own, expectedImage));
                    var seen = ProcessEnvironmentReader.Read(ready!.Watcher.ProcessId);
                    var failures = VerifyFromPoisonedHost(env, seen, expectedImage);
                    if (!string.Equals(ready.Watcher.ExecutablePath, expectedImage, StringComparison.OrdinalIgnoreCase)) failures.Add("the watcher identity records '" + ready.Watcher.ExecutablePath + "' instead of '" + expectedImage + "'");
                    ChildEnv.Report(check, kind + " session watcher child", env, seen, failures);
                    using var watcher = Process.GetProcessById(ready.Watcher.ProcessId);
                    launcher!.Kill();
                    check(runner.WaitForExit(90000), "The " + kind + " session ended after its launcher exited");
                    check(watcher.WaitForExit(60000), "The recovery watcher exited after the " + kind + " session ended");
                }
                finally
                {
                    foreach (var process in new[] { launcher, runner })
                        if (process is not null && !process.HasExited) process.Kill(true);
                }
            });
        }
        finally
        {
            foreach (var process in new[] { launcher, runner })
                if (process is not null) { if (!process.HasExited) process.Kill(true); process.Dispose(); }
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "The " + kind + " watcher scenario leaves no session files behind");
    }
}
