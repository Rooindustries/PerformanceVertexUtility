using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;
using H = DataRootHarness;

static partial class DataFolderChecks
{
    private static string Legacy(string root, params (string Path, string Text)[] files)
    {
        Directory.CreateDirectory(root);
        foreach (var (path, text) in files)
        {
            var full = Path.Combine(root, path);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, text);
        }
        return root;
    }

    private static string WorkerState(string timerFolder, int processId, long created, string executable)
        => JsonSerializer.Serialize(new TimerWorkerState(new TimerLaunch(OperationOwner.Current(), "forged-session", timerFolder, "assembly.dll", "hash"), processId, created, executable, true, false, 0, null, 5000, null), OperationFiles.Json);

    private static void TimerState(Action<bool, string> check)
    {
        using var probe = H.Start(["--probe-ready"]);
        probe.StandardOutput.ReadLine();
        using var fake = H.Start(["--timer-worker-fake"]);
        var csrss = Process.GetProcessesByName("csrss").FirstOrDefault()?.Id ?? 4;
        var cases = new List<(string Label, Func<string, string> Content, bool EndsWorker)>
        {
            ("a launch that is null", _ => "{\"launch\":null}", false),
            ("a huge file", _ => new string('x', 300_000), false),
            ("an empty object", _ => "{}", false),
            ("a duplicate property", _ => "{\"launch\":{},\"launch\":{}}", false),
            ("the process id of a protected system process", folder => WorkerState(folder, 4, 1, "System"), false),
            ("the process id of a protected service process", folder => WorkerState(folder, csrss, 1, @"C:\Windows\System32\csrss.exe"), false),
            ("the identity of an ordinary program that is not a timer worker", folder => WorkerState(folder, probe.Id, probe.StartTime.ToUniversalTime().ToFileTimeUtc(), Environment.ProcessPath!), false),
            ("the identity of a real timer worker", folder => WorkerState(folder, fake.Id, fake.StartTime.ToUniversalTime().ToFileTimeUtc(), Environment.ProcessPath!), true),
        };
        var state = Path.Combine(H.Local, H.Name("timerstate"));
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN", "1");
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE", state);
        try
        {
            foreach (var item in cases)
            {
                var id = H.Name("state");
                var root = Path.Combine(H.Local, id);
                var operations = Path.Combine(root, "operations");
                var timer = Path.Combine(operations, OperationsFolder.TimerFolder);
                try
                {
                    Legacy(root, (@"operations\journal.json", "journal bytes"), (@"operations\windows-timer\session.json", item.Content(PolicyRootSecurity.Normalize(timer))));
                    Exception? failure = null; var migrated = false;
                    try { migrated = PolicyRootSecurity.Secure(root, DataFolder.Kind); } catch (Exception error) { failure = error; }
                    check(failure is null && migrated && H.Read(Path.Combine(operations, "journal.json")) == "journal bytes", "The first migration completes when the old timer state holds " + item.Label + ": " + failure?.Message);
                    check(!probe.HasExited, "No program is ended because of " + item.Label);
                    if (item.EndsWorker) check(fake.WaitForExit(15000), "A timer worker identified by the old state, its executable and its command line is ended before its folder is moved");
                    else check(!fake.HasExited, "The timer worker of another case keeps running");
                }
                finally { H.Forget(root, operations); H.Delete(root); H.Sweep(id); }
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN", null); Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE", null);
            if (!probe.HasExited) probe.Kill(true);
            if (!fake.HasExited) fake.Kill(true);
            H.Delete(state);
        }
    }

    private static void Exits(Action<bool, string> check)
    {
        var id = H.Name("exits");
        var root = Path.Combine(H.Local, id);
        try
        {
            check(!PolicyRootSecurity.Secure(root, DataFolder.Kind), "A fresh data folder is created protected");
            File.WriteAllText(Path.Combine(root, "history.json"), "undo history");
            var renamed = root + ".secure-prank";
            var result = H.Standard("rename", root, renamed);
            check(result == "RENAMED" && !Directory.Exists(root) && Directory.Exists(renamed), "A standard user can rename the protected data folder while the app is stopped (" + result + ")");
            PolicyRootSecurity.Secure(root, DataFolder.Kind);
            check(File.Exists(Path.Combine(root, "history.json")) && H.Read(Path.Combine(root, "history.json")) == "undo history", "The next start takes the renamed folder back with its undo history instead of creating an empty one");
            var other = root + ".secure-other";
            PolicyRootSecurity.Secure(other, DataFolder.Kind);
            File.WriteAllText(Path.Combine(other, "other.json"), "other data");
            var planted = Legacy(root + ".secure-planted", ("keep.txt", "planted"));
            PolicyRootSecurity.Secure(root, DataFolder.Kind);
            check(File.Exists(Path.Combine(other, "other.json")) && File.Exists(Path.Combine(planted, "keep.txt")), "A protected folder or a planted folder that only matches a leftover name is never deleted because of its name");
        }
        finally { H.Forget(root, root + ".secure-other", root + ".secure-prank"); H.Delete(root); H.Sweep(id); }

        var hooks = typeof(DataFolder).GetMethod("ResumeInterrupted", [typeof(string)]) is not null;
        foreach (var at in hooks ? new[] { "detached", "sealed", "copied" } : new[] { "detached" })
        {
            var window = H.Name("window");
            var windowRoot = Path.Combine(H.Local, window);
            try
            {
                Legacy(windowRoot, ("A.txt", "A"), ("B.txt", "B"), (@"sub\C.txt", "C"), (@"tools\skipped.bin", "a program from before protection"));
                File.WriteAllBytes(Path.Combine(windowRoot, "big.bin"), new byte[3 << 20]);
                var env = new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"] = "20000", ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT"] = at };
                using var child = H.Start(["--child-secure-data", windowRoot], env);
                var clock = Stopwatch.StartNew();
                string[] legacyFolders = [];
                while (clock.Elapsed < TimeSpan.FromSeconds(40))
                {
                    legacyFolders = Directory.GetDirectories(H.Local, window + ".legacy-*");
                    var secure = Directory.GetDirectories(H.Local, window + ".secure-*");
                    var ready = at switch { "copied" => secure.Length == 1 && Directory.Exists(windowRoot) && File.Exists(Path.Combine(secure[0], "big.bin")), "detached" => legacyFolders.Length == 1 && !Directory.Exists(windowRoot), _ => legacyFolders.Length == 1 && !Directory.Exists(windowRoot) && secure.Length == 1 && File.Exists(Path.Combine(secure[0], ".migrated")) };
                    if (ready) break;
                    Thread.Sleep(100);
                }
                check(!child.HasExited, "The migration is paused at " + at + " (" + string.Join(", ", legacyFolders.Select(Path.GetFileName)) + ")");
                if (at == "detached") File.WriteAllText(Path.Combine(legacyFolders[0], "A.txt"), "A changed in the window");
                if (at == "copied") File.WriteAllText(Path.Combine(windowRoot, "B.txt"), "B changed before the switch");
                child.Kill(true); child.WaitForExit();
                var again = H.Child(["--child-secure-data", windowRoot]);
                check(again.Exit == 0 && PolicyRootSecurity.Problem(windowRoot, DataFolder.Kind) is null, "The next start finishes after a kill at " + at + ": " + again.Output);
                var expectA = at == "detached" ? "A changed in the window" : "A";
                var expectB = at == "copied" ? "B changed before the switch" : "B";
                check(H.Read(Path.Combine(windowRoot, "A.txt")) == expectA && H.Read(Path.Combine(windowRoot, "B.txt")) == expectB && H.Read(Path.Combine(windowRoot, "sub", "C.txt")) == "C" && H.Length(Path.Combine(windowRoot, "big.bin")) == 3 << 20,
                    "After a kill at " + at + " the data folder holds the newest data of every file");
                check(Directory.GetDirectories(H.Local, window + ".secure-*").Length == 0, "No unfinished protected copy is left beside the data folder after a kill at " + at);
                var kept = H.Aside(windowRoot);
                check(kept.Length == 1 && File.Exists(Path.Combine(kept[0], "tools", "skipped.bin")) && !File.Exists(Path.Combine(kept[0], "A.txt")) && !File.Exists(Path.Combine(kept[0], "B.txt")) &&
                    !File.Exists(Path.Combine(kept[0], "sub", "C.txt")) && !File.Exists(Path.Combine(kept[0], "big.bin")),
                    "After a kill at " + at + " the folder kept aside holds only what was skipped, not a second copy of the data: " + string.Join(", ", kept.SelectMany(H.Names)));
            }
            finally { H.Forget(windowRoot); H.Delete(windowRoot); H.Sweep(window); }
        }

        var strays = H.Name("strays");
        var strayRoot = Path.Combine(H.Local, strays);
        try
        {
            Legacy(strayRoot, ("A.txt", "A"), ("B.txt", "B"));
            var env = new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"] = "5000", ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT"] = "detached" };
            using var child = H.Start(["--child-secure-data", strayRoot], env);
            var clock = Stopwatch.StartNew();
            while (Directory.Exists(strayRoot) && clock.Elapsed < TimeSpan.FromSeconds(40)) Thread.Sleep(50);
            using var writer = H.Start(["--child-writer", strayRoot, "9000", "6"]);
            var childOutput = child.StandardOutput.ReadToEnd() + child.StandardError.ReadToEnd();
            child.WaitForExit(60000);
            var writerOutput = writer.StandardOutput.ReadToEnd();
            writer.WaitForExit(30000);
            check(child.ExitCode == 0 && childOutput.Contains("SECURED"), "A writer that recreates the data folder six times while it is being protected does not stop the migration: " + childOutput.Trim() + " / " + writerOutput.Trim());
            check(PolicyRootSecurity.Problem(strayRoot, DataFolder.Kind) is null && H.Read(Path.Combine(strayRoot, "A.txt")) == "A" && H.Read(Path.Combine(strayRoot, "B.txt")) == "B", "The protected data folder keeps the original data after the writer interfered");
            var count = int.Parse(System.Text.RegularExpressions.Regex.Match(writerOutput, @"recreated (\d+)").Groups[1].Value);
            check(count >= 4 && Enumerable.Range(0, count).All(index => File.Exists(Path.Combine(strayRoot, "writer-" + index + ".txt"))), "Everything the writer saved while the folder was missing is folded in (" + count + " files)");
        }
        finally { H.Forget(strayRoot); H.Delete(strayRoot); H.Sweep(strays); }
    }

    private static void Unreadable(Action<bool, string> check)
    {
        var id = H.Name("unreadable");
        var root = Path.Combine(H.Local, id);
        var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        try
        {
            Legacy(root, ("ok.txt", "plain data"), (@"settings\keep.json", "settings"), ("denied.txt", "secret"), ("offline.txt", "in the cloud"), ("sparse.dat", "sparse"), ("stream.txt", "main stream"), ("enc.txt", "encrypted"), ("ro.txt", "read only and hidden"));
            var denied = new FileInfo(Path.Combine(root, "denied.txt")); var rule = denied.GetAccessControl();
            rule.AddAccessRule(new FileSystemAccessRule(admins, FileSystemRights.ReadData, AccessControlType.Deny)); denied.SetAccessControl(rule);
            File.SetAttributes(Path.Combine(root, "offline.txt"), FileAttributes.Offline);
            H.Run("fsutil.exe", "sparse setflag \"" + Path.Combine(root, "sparse.dat") + "\"");
            File.WriteAllText(Path.Combine(root, "stream.txt") + ":extra", "hidden stream");
            var encrypted = true;
            try { File.Encrypt(Path.Combine(root, "enc.txt")); } catch (Exception error) when (error is IOException or PlatformNotSupportedException or UnauthorizedAccessException) { encrypted = false; }
            File.SetAttributes(Path.Combine(root, "ro.txt"), FileAttributes.ReadOnly | FileAttributes.Hidden);
            File.WriteAllText(@"\\?\" + Path.Combine(root, "NUL"), "device name");
            var deep = root; for (var level = 0; level < 3000; level++) deep = Path.Combine(deep, "d");
            Directory.CreateDirectory(H.Long(deep)); File.WriteAllText(H.Long(Path.Combine(deep, "deep.txt")), "deep data");

            var run = H.Child(["--child-secure-data", root]);
            check(run.Exit == 0 && run.Output.Contains("SECURED migrated=True"), "One unreadable entry does not fail the whole migration: " + run.Output);
            check(H.Read(Path.Combine(root, "ok.txt")) == "plain data" && H.Read(Path.Combine(root, "settings", "keep.json")) == "settings", "Readable entries are carried");
            check(H.Read(H.Long(Path.Combine(deep, "deep.txt"))) == "deep data", "A deeply nested folder with a very long path is carried");
            var attributes = File.GetAttributes(Path.Combine(root, "ro.txt"));
            check(H.Read(Path.Combine(root, "ro.txt")) == "read only and hidden" && attributes.HasFlag(FileAttributes.ReadOnly) && attributes.HasFlag(FileAttributes.Hidden), "Read-only and hidden flags are kept on carried files");
            var skipped = new List<string> { "denied.txt", "offline.txt", "sparse.dat", "stream.txt" };
            if (encrypted) skipped.Add("enc.txt");
            check(skipped.All(name => !Path.Exists(Path.Combine(root, name))), "Unreadable, cloud, sparse, encrypted and extra-stream entries are not carried as trusted: carried anyway = " + string.Join(", ", skipped.Where(name => Path.Exists(Path.Combine(root, name)))) + " (encrypted=" + encrypted + ")");
            var aside = H.Aside(root);
            check(aside.Length == 1 && skipped.All(name => Path.Exists(Path.Combine(aside[0], name))) && !File.Exists(Path.Combine(aside[0], "ok.txt")), "Those entries are kept aside and the carried ones are not duplicated there");
            check(PolicyRootSecurity.Problem(root, DataFolder.Kind) is null, "The protected folder still passes the deep check");
        }
        finally { H.Forget(root); H.Delete(root); H.Sweep(id); }
    }

    private static void SuspendResume(Action<bool, string> check)
    {
        var id = H.Name("suspend");
        var root = Path.Combine(H.Local, id);
        var prefix = "RooDfScratch.Quiesce.";
        using var identity = WindowsIdentity.GetCurrent();
        var rules = new ProcessPolicyStore(Path.Combine(root, "process-rules"));
        var suffix = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(identity.User!.Value + "|" + rules.Root.ToUpperInvariant())))[..20];
        var task = prefix + suffix;
        var xml = Path.Combine(Path.GetTempPath(), task + ".xml");
        try
        {
            Legacy(root, ("A.txt", "A"), (@"process-rules\rules\rule.json", "{}"));
            File.WriteAllText(xml, "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Description>data folder scenario</Description></RegistrationInfo><Triggers><TimeTrigger><StartBoundary>2030-12-31T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers><Principals><Principal id=\"Author\"><UserId>" + identity.User.Value + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><Enabled>true</Enabled></Settings><Actions Context=\"Author\"><Exec><Command>cmd.exe</Command><Arguments>/c exit 0</Arguments></Exec></Actions></Task>", System.Text.Encoding.Unicode);
            check(H.Run("schtasks.exe", "/Create /TN \"" + task + "\" /XML \"" + xml + "\" /F").Exit == 0 && Enabled(task), "The scenario's own governor-style task exists and is enabled");
            var env = new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_GOVERNOR_TASK_PREFIX"] = prefix, ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"] = "30000", ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT"] = "detached" };
            using var child = H.Start(["--child-secure-data", root], env);
            var clock = Stopwatch.StartNew();
            while (Directory.Exists(root) && clock.Elapsed < TimeSpan.FromSeconds(40)) Thread.Sleep(100);
            check(!Enabled(task), "The migration disables the task while it moves the folder");
            child.Kill(true); child.WaitForExit();
            check(!Enabled(task), "A killed migration leaves the task disabled until the next start");
            check(LastRunYear(task) < 2000, "The task has not run yet");
            var again = H.Child(["--child-secure-data", root, "--resume"], new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_GOVERNOR_TASK_PREFIX"] = prefix });
            check(again.Exit == 0 && PolicyRootSecurity.Problem(root, DataFolder.Kind) is null, "The next start finishes the migration: " + again.Output);
            check(Enabled(task), "The next start enables the task that the killed migration had disabled");
            check(LastRunYear(task) >= 2026, "The next start also starts that task again instead of waiting for its next trigger (last run year " + LastRunYear(task) + ")");
            var second = H.Child(["--child-secure-data", root, "--resume"], new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_GOVERNOR_TASK_PREFIX"] = prefix });
            check(second.Exit == 0 && Enabled(task), "Starting again does not change the task");
            H.Run("schtasks.exe", "/Change /TN \"" + task + "\" /DISABLE");
            var third = H.Child(["--child-secure-data", root, "--resume"], new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_GOVERNOR_TASK_PREFIX"] = prefix });
            check(third.Exit == 0 && !Enabled(task), "A task the user disabled on their own is not enabled by a later start");
        }
        finally
        {
            H.Run("schtasks.exe", "/Delete /TN \"" + task + "\" /F");
            File.Delete(xml); H.Forget(root); H.Delete(root); H.Sweep(id);
        }
    }

    private static int LastRunYear(string task)
    {
        var (_, output) = H.Run("powershell.exe", "-NoProfile -NonInteractive -Command \"(Get-ScheduledTaskInfo -TaskName '" + task + "').LastRunTime.Year\"");
        return int.TryParse(output.Trim(), out var year) ? year : -1;
    }

    private static bool Enabled(string task)
    {
        var (exit, output) = H.Run("schtasks.exe", "/Query /TN \"" + task + "\" /XML");
        return exit == 0 && !System.Text.RegularExpressions.Regex.IsMatch(output, "(?s)<Settings>.*?<Enabled>false</Enabled>.*?</Settings>");
    }

    private static void RootResolution(Action<bool, string> check)
    {
        var id = H.Name("resolve");
        var selection = Path.Combine(H.Local, id);
        var legacy = Path.Combine(selection, "RooOptimizationSuite");
        var current = Path.Combine(selection, "RooIndustriesOptimizationSuite");
        try
        {
            Legacy(legacy, ("A.txt", "A"), ("settings.json", "{}"));
            var env = new Dictionary<string, string> { ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"] = "8000", ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT"] = "detached" };
            using var first = H.Start(["--child-secure-data", legacy], env);
            var clock = Stopwatch.StartNew();
            while (Directory.Exists(legacy) && clock.Elapsed < TimeSpan.FromSeconds(40)) Thread.Sleep(50);
            check(!Directory.Exists(legacy) && !first.HasExited, "The first launch is in the middle of moving the legacy data folder");
            var resolved = H.Child(["--child-resolve", selection]);
            check(resolved.Output == "ROOT " + legacy, "A second launch during the migration still resolves the legacy data folder: " + resolved.Output);
            var second = H.Child(["--child-secure-data", resolved.Output["ROOT ".Length..]]);
            first.WaitForExit(60000);
            check(second.Exit == 0 && second.Output.Contains("SECURED migrated=False") && !Directory.Exists(current), "A second launch waits for the first and does not create a second data folder: " + second.Output);
            var plantedSelection = Path.Combine(H.Local, id + "-planted");
            var plantedLegacy = Path.Combine(plantedSelection, "RooOptimizationSuite");
            Directory.CreateDirectory(plantedSelection);
            var plant = H.Standard("plant", plantedSelection, @"RooOptimizationSuite.legacy-planted\x.txt|planted", @"RooOptimizationSuite.secure-planted\.migrating|{""id"":""x"",""source"":""" + plantedLegacy.Replace("\\", "\\\\") + @""",""started"":""2026-01-01T00:00:00Z""}");
            check(plant == "PLANTED", "A standard user plants folders named like migration leftovers: " + plant);
            check(BrandCompatibility.DataRoot(plantedSelection) == Path.Combine(plantedSelection, "RooIndustriesOptimizationSuite"), "Folders a standard user planted with leftover names do not move the data folder to the legacy name");
            H.Delete(plantedSelection);
            check(H.Read(Path.Combine(legacy, "A.txt")) == "A" && PolicyRootSecurity.Problem(legacy, DataFolder.Kind) is null, "The data folder keeps its data");
            check(PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(legacy)) && !PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(current)), "Only one data folder is marked");
        }
        finally { H.Forget(legacy, current); H.Delete(selection); }
    }
}
