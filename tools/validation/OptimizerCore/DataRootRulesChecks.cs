using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;
using H = DataRootHarness;

static partial class DataFolderChecks
{
    static partial void RegisterNew(List<(string Name, Action<Action<bool, string>> Run)> scenarios)
    {
        scenarios.Add(("marker-repair", MarkerRepair));
        scenarios.Add(("legacy-planted", LegacyPlanted));
        scenarios.Add(("earlier-version", EarlierVersionGate));
        scenarios.Add(("external-path", ExternalPath));
        scenarios.Add(("claims-carry", ClaimsCarry));
        scenarios.Add(("timer-split", TimerSplit));
        scenarios.Add(("timer-migration", TimerMigration));
    }

    private static bool WrittenAfter(string file)
    {
        try { PolicyRootSecurity.RequireWrittenAfterProtection(file, "earlier"); return true; }
        catch (InvalidDataException) { return false; }
    }

    private static void ForgetProtectionTime(string root)
    {
        using var key = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true)!;
        key.DeleteValue(PolicyRootSecurity.MarkerName(root) + PolicyRootSecurity.ProtectedAtSuffix, false);
    }

    private static void MarkerRepair(Action<bool, string> check)
    {
        var id = H.Name("marker");
        var root = Path.Combine(H.Local, id);
        try
        {
            PolicyRootSecurity.Secure(root, DataFolder.Kind);
            ForgetProtectionTime(root);
            check(PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root)) && PolicyRootSecurity.ProtectedAt(root) is null, "The marker of a folder protected by an intermediate build has no protection time");
            var intermediate = Path.Combine(root, "made-before-the-repair.txt");
            File.WriteAllText(intermediate, "intermediate build");
            Thread.Sleep(100);
            PolicyRootSecurity.Secure(root, DataFolder.Kind);
            var repaired = PolicyRootSecurity.ProtectedAt(root);
            check(repaired is not null && repaired > File.GetCreationTimeUtc(intermediate), "The next start gives that marker the current time as its protection time");
            Thread.Sleep(100);
            var later = Path.Combine(root, "made-after-the-repair.txt");
            File.WriteAllText(later, "after");
            check(WrittenAfter(later) && !WrittenAfter(intermediate),
                "A backup made after the repair is recognized as written after protection and one from the intermediate build is still refused");
            ForgetProtectionTime(root);
            check(H.Has(typeof(PolicyRootSecurity), "RepairMarker"), "A startup repair exists for markers without a protection time");
            if (H.Has(typeof(PolicyRootSecurity), "RepairMarker")) H.Api(typeof(PolicyRootSecurity), "RepairMarker", root);
            check(PolicyRootSecurity.ProtectedAt(root) is not null, "The startup repair gives a marker without a protection time the current time");
        }
        finally { H.Forget(root); H.Delete(root); H.Sweep(id); }
    }

    private static void LegacyPlanted(Action<bool, string> check)
    {
        var id = H.Name("legacy");
        var selection = Path.Combine(H.Local, id);
        var junctioned = Path.Combine(H.Local, id + "-junctioned");
        var target = Path.Combine(H.Local, id + "-target");
        var legacy = Path.Combine(selection, "RooOptimizationSuite");
        var current = Path.Combine(selection, "RooIndustriesOptimizationSuite");
        var linked = Path.Combine(junctioned, "RooOptimizationSuite");
        try
        {
            Directory.CreateDirectory(selection); Directory.CreateDirectory(junctioned); Directory.CreateDirectory(target);
            File.WriteAllText(Path.Combine(target, "sentinel.txt"), "outside bytes");
            var planted = H.Standard("plant", legacy, @"settings\custom-windows-settings.json|{""catalog"":""planted""}", @"tools\tool.exe|planted program", @"firmware\packages\p1\SCEWIN64.exe|planted package",
                @"operations\cpu-1\journal.json|planted journal", "cleanup-exclusions.json|planted exclusions", @"process-rules\rules\rule.json|planted rule");
            check(planted == "PLANTED", "A standard user creates the legacy-named data folder before the app ever ran: " + planted);
            check(BrandCompatibility.DataRoot(selection) == legacy, "The planted legacy-named folder becomes the data folder");
            var migrated = PolicyRootSecurity.Secure(legacy, DataFolder.Kind);
            check(migrated && PolicyRootSecurity.Problem(legacy, DataFolder.Kind) is null && PolicyRootSecurity.WriterOf(legacy) is null, "The planted folder is replaced by a protected data folder");
            check(H.Names(legacy).All(name => name == ".migrated" || name.StartsWith("logs", StringComparison.OrdinalIgnoreCase)), "Nothing a standard user created is carried into the protected data folder: " + string.Join(", ", H.Names(legacy)));
            var aside = H.Aside(legacy);
            check(aside.Length == 1 && File.Exists(Path.Combine(aside[0], "settings", "custom-windows-settings.json")) && File.Exists(Path.Combine(aside[0], "operations", "cpu-1", "journal.json")) && File.Exists(Path.Combine(aside[0], "cleanup-exclusions.json")),
                "What the standard user created is kept aside, unread");
            check(!PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(current)), "No marker is written for the current-named folder");

            var made = H.Standard("mkdir", linked);
            check(made == "CREATED", "A standard user creates the legacy-named folder on another profile path: " + made);
            var converted = H.Standard("junction", linked, target);
            check(converted == "CONVERTED" && H.IsLink(linked), "A standard user turns that empty folder into a junction to a folder outside (" + converted + ")");
            check(BrandCompatibility.DataRoot(junctioned) == linked, "The junction becomes the data folder path");
            PolicyRootSecurity.Secure(linked, DataFolder.Kind);
            check(!H.IsLink(linked) && Directory.Exists(linked) && PolicyRootSecurity.Problem(linked, DataFolder.Kind) is null, "The junction is replaced by a protected data folder");
            check(H.Read(Path.Combine(target, "sentinel.txt")) == "outside bytes" && H.Names(target).SequenceEqual(["sentinel.txt"]), "Nothing was created, changed or deleted in the folder the junction pointed to: " + string.Join(", ", H.Names(target)));
            check(H.Aside(linked).Length == 1 && H.IsLink(H.Aside(linked)[0]), "The junction itself is kept aside");
        }
        finally
        {
            H.Forget(legacy, current, linked);
            H.Delete(selection, junctioned, target); H.Sweep(id);
        }
    }

    private static void EarlierVersionGate(Action<bool, string> check)
    {
        var id = H.Name("earlier");
        var root = Path.Combine(H.Local, id);
        try
        {
            Legacy(root, (@"operations\cpu-1\journal.json", "{}"), (@"settings\process-profile-recovery.json", "{}"));
            check(PolicyRootSecurity.Secure(root, DataFolder.Kind), "A legacy data folder with undo data is migrated");
            var carried = Path.Combine(root, "operations", "cpu-1", "journal.json");
            check(H.Has(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion") && H.Has(typeof(PolicyRootSecurity), "SavedBeforeProtection"), "The confirmation gate for undo data from before protection exists");
            if (!H.Has(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion")) return;
            Exception? refusal = null;
            try { H.Api(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion", carried, false); } catch (Exception error) { refusal = error; }
            check(refusal?.GetType().Name == "EarlierVersionException" && refusal.Message.StartsWith("This backup was saved by an older version of the app, before its data folder was protected."),
                "Undo data carried from before protection is refused without confirmation, with a plain line: " + refusal?.Message);
            Exception? confirmed = null;
            try { H.Api(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion", carried, true); } catch (Exception error) { confirmed = error; }
            check(confirmed is null, "The same undo data is accepted once the user confirmed it");
            Thread.Sleep(100);
            var fresh = Path.Combine(root, "operations", "cpu-2", "journal.json");
            Directory.CreateDirectory(Path.GetDirectoryName(fresh)!); File.WriteAllText(fresh, "{}");
            Exception? unasked = null;
            try { H.Api(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion", fresh, false); } catch (Exception error) { unasked = error; }
            check(unasked is null, "Undo data written after protection needs no confirmation");
            var outside = Path.Combine(Path.GetTempPath(), "roo-df-outside-" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(outside, "{}");
            Exception? unmarked = null;
            try { H.Api(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion", outside, false); } catch (Exception error) { unmarked = error; }
            File.Delete(outside);
            check(unmarked is null, "A file outside every protected folder was not carried from before protection, so it needs no confirmation");
            var missing = Path.Combine(root, "operations", "cpu-3", "journal.json");
            Exception? absent = null;
            try { H.Api(typeof(PolicyRootSecurity), "RequireConfirmedEarlierVersion", missing, false); } catch (Exception error) { absent = error; }
            check(absent is null, "A journal that does not exist is left to the normal missing-file message");
        }
        finally { H.Forget(root, Path.Combine(root, "operations")); H.Delete(root); H.Sweep(id); }
    }

    private static void ExternalPath(Action<bool, string> check)
    {
        var present = H.Has(typeof(OperationFiles), "ExternalPathProblem");
        check(present, "A check for paths handed over by another program exists");
        if (!present) return;
        var file = Path.Combine(Path.GetTempPath(), "roo-df-external-" + Guid.NewGuid().ToString("N") + ".txt");
        var folder = Path.Combine(Path.GetTempPath(), "roo-df-external-" + Guid.NewGuid().ToString("N"));
        try
        {
            File.WriteAllText(file, "x"); Directory.CreateDirectory(folder);
            string? Problem(string? path) => (string?)H.Api(typeof(OperationFiles), "ExternalPathProblem", path ?? "");
            check(Problem(file) is null && Problem(folder) is null, "A plain full path to an existing file or folder on a local drive is accepted");
            foreach (var (label, path) in new[]
            {
                ("an empty path", ""), ("a blank path", "   "), ("a network path", @"\\server\share\file.txt"), ("an extended-length path", @"\\?\" + file), ("a device path", @"\\.\PhysicalDrive0"),
                ("a path with parent steps", Path.Combine(folder, "..", Path.GetFileName(file))), ("a path with forward slashes", file.Replace('\\', '/')), ("a relative path", "notepad.exe"),
                ("a data stream", file + ":stream"), ("a missing file", Path.Combine(folder, "missing-" + Guid.NewGuid().ToString("N"))), ("a path with a wildcard", Path.Combine(folder, "*")),
                ("a path longer than 1024 characters", Path.Combine(folder, new string('a', 1100))),
            })
                check(Problem(path) is not null, "A path handed over by another program is ignored: " + label);
        }
        finally { File.Delete(file); if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }

    private static bool Shell => H.GetShellWindow() != IntPtr.Zero;

    private static int WorkerId(string state)
    {
        try { using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(state, "session.json"))); return document.RootElement.GetProperty("processId").GetInt32(); }
        catch (Exception error) when (error is IOException or JsonException or KeyNotFoundException or UnauthorizedAccessException) { return 0; }
    }

    private static string OwnerOf(string path)
    {
        FileSystemSecurity security = Directory.Exists(path) ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        return security.GetOwner(typeof(SecurityIdentifier))?.Value ?? "";
    }

    private static void TimerSplit(Action<bool, string> check)
    {
        var id = H.Name("timer");
        var root = Path.Combine(H.Local, id);
        var operations = Path.Combine(root, "operations");
        var control = Path.Combine(operations, OperationsFolder.TimerFolder);
        var state = Path.Combine(H.Local, id + "-state");
        var victim = Path.Combine(H.Local, id + "-victim");
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User!.Value;
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_CONTROL", control);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE", state);
        if (!Shell) Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN", "1");
        try
        {
            OperationsFolder.Ensure(operations);
            var store = new WindowsControlStore();
            var address = new ControlAddress("timer", "system", "half-millisecond");
            TweakControlRead before;
            try { before = store.Read(address); }
            catch (InvalidDataException error) { Console.WriteLine("NOTE The 0.5 ms timer scenario is not meaningful on this PC: " + error.Message); return; }
            check(!Directory.Exists(state), "The per-user timer state folder does not exist until the signed-in user's own worker creates it");
            if (!Shell)
            {
                Exception? refusal = null;
                try { store.Write(before, ControlValues.From(true)); } catch (Exception error) { refusal = error; }
                check(refusal is InvalidOperationException && refusal.Message.Contains("normal rights") && !Directory.Exists(state) && File.Exists(Path.Combine(control, "launch.json")) == false,
                    "With no desktop shell of the signed-in user, the elevated app refuses to start the timer instead of running an elevated worker that writes where ordinary programs can: " + refusal?.Message);
                Console.WriteLine("NOTE Running the 0.5 ms timer end to end needs an interactive desktop session; this run had none.");
                return;
            }
            store.Write(before, ControlValues.From(true));
            var running = store.Read(address);
            check(running.Value.GetBoolean(), "The timer starts and the app reads it as active through the per-user state");
            var worker = WorkerId(state);
            check(worker > 0 && H.Elevated(worker) == false, "The timer worker runs with the signed-in user's normal rights, not elevated (pid " + worker + ")");
            check(WorkerId(control) == 0 && !File.Exists(Path.Combine(control, "session.json")), "The worker state is not kept in the data folder");
            check(Directory.Exists(state) && OwnerOf(state) == user && Directory.EnumerateFileSystemEntries(state).All(entry => OwnerOf(entry) == user),
                "Everything in the per-user state folder was created by the signed-in user, so the elevated app never wrote there: " + string.Join(", ", Directory.EnumerateFileSystemEntries(state).Select(entry => Path.GetFileName(entry) + "=" + OwnerOf(entry))));
            check(PolicyRootSecurity.WriterOf(control) is null && File.Exists(Path.Combine(control, "launch.json")) && OwnerOf(control) is "S-1-5-32-544" or "S-1-5-18", "The control folder stays administrators-only and holds the launch request");
            store.Write(running, ControlValues.From(false));
            var stopped = store.Read(address);
            check(!stopped.Value.GetBoolean(), "The timer stops again and the app reads it as stopped");
            var gone = false;
            for (var index = 0; index < 50 && !gone; index++) { try { using var process = System.Diagnostics.Process.GetProcessById(worker); gone = process.HasExited; } catch (ArgumentException) { gone = true; } if (!gone) Thread.Sleep(100); }
            check(gone, "The worker has ended");

            Directory.CreateDirectory(victim);
            File.WriteAllText(Path.Combine(victim, "session.json"), File.ReadAllText(Path.Combine(state, "session.json")));
            var renamed = H.Standard("rename", state, state + "-moved");
            check(renamed == "RENAMED", "A standard user moves the state folder away (" + renamed + ")");
            var linked = H.Standard("junction-new", state, victim);
            check(linked == "CONVERTED" && H.IsLink(state), "A standard user puts a junction to a folder outside in its place (" + linked + ")");
            var victimBytes = File.ReadAllBytes(Path.Combine(victim, "session.json"));
            var after = store.Read(address);
            check(!after.Value.GetBoolean() && !after.LostLease, "The elevated app does not follow the junction and reads the timer as stopped");
            check(File.ReadAllBytes(Path.Combine(victim, "session.json")).SequenceEqual(victimBytes) && H.Names(victim).SequenceEqual(["session.json"]), "Reading through the junction created, changed or deleted nothing outside");
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_CONTROL", null); Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE", null); Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN", null);
            var stray = WorkerId(state);
            if (stray > 0) { try { using var process = System.Diagnostics.Process.GetProcessById(stray); process.Kill(true); } catch (Exception error) when (error is ArgumentException or InvalidOperationException) { } }
            H.Forget(root, operations); H.Delete(root, state, state + "-moved", victim); H.Sweep(id);
        }
    }

    private static void TimerMigration(Action<bool, string> check)
    {
        var id = H.Name("tmig");
        var root = Path.Combine(H.Local, id);
        var operations = Path.Combine(root, "operations");
        var control = Path.Combine(operations, OperationsFolder.TimerFolder);
        var state = Path.Combine(H.Local, id + "-state");
        System.Diagnostics.Process? legacy = null;
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_CONTROL", control);
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE", state);
        if (!Shell) Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN", "1");
        try
        {
            try { new WindowsControlStore().Read(new ControlAddress("timer", "system", "half-millisecond")); }
            catch (InvalidDataException error) { Console.WriteLine("NOTE The 0.5 ms timer migration scenario is not meaningful on this PC: " + error.Message); return; }
            Directory.CreateDirectory(control);
            File.WriteAllText(Path.Combine(operations, "journal.json"), "journal bytes");
            var assembly = System.Reflection.Assembly.GetEntryAssembly()!.Location;
            var launchPath = Path.Combine(control, "launch.json");
            OperationFiles.Write(launchPath, new TimerLaunch(OperationOwner.Current(), Guid.NewGuid().ToString("N"), control, assembly, OperationFiles.HashFile(assembly)));
            legacy = H.Start(["--timer-worker", launchPath], new() { ["ROO_INDUSTRIES_TEST_TIMER_CONTROL"] = control, ["ROO_INDUSTRIES_TEST_TIMER_STATE"] = control, ["ROO_INDUSTRIES_TEST_ALLOW_ELEVATED_TIMER_WORKER"] = "1" });
            var clock = System.Diagnostics.Stopwatch.StartNew();
            while (!File.Exists(Path.Combine(control, "session.json")) && !legacy.HasExited && clock.Elapsed < TimeSpan.FromSeconds(20)) Thread.Sleep(100);
            Thread.Sleep(1500);
            check(!legacy.HasExited && File.Exists(Path.Combine(control, "session.json")), "A timer worker of the earlier layout is running with its state in the old timer folder");
            Exception? failure = null; var migrated = false;
            try { migrated = PolicyRootSecurity.Secure(root, DataFolder.Kind); } catch (Exception error) { failure = error; }
            check(failure is null && migrated && PolicyRootSecurity.Problem(root, DataFolder.Kind) is null, "The first migration completes with the earlier timer worker running: " + failure?.Message);
            check(legacy.WaitForExit(15000), "The earlier worker is ended before its folder is moved");
            check(H.Read(Path.Combine(operations, "journal.json")) == "journal bytes" && PolicyRootSecurity.WriterOf(control) is null && !File.Exists(Path.Combine(control, "session.json")), "The data is carried and the timer folder is administrators-only without the old worker state");
            var address = new ControlAddress("timer", "system", "half-millisecond");
            if (Shell)
            {
                var read = new WindowsControlStore().Read(address);
                var worker = WorkerId(state);
                check(read.Value.GetBoolean() && worker > 0 && worker != legacy.Id && H.Elevated(worker) == false, "The timer is running again under the new layout with the signed-in user's normal rights (pid " + worker + ")");
                new WindowsControlStore().Write(read, ControlValues.From(false));
                check(!new WindowsControlStore().Read(address).Value.GetBoolean(), "The restarted timer stops on request");
            }
            else
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\RooIndustries\OptimizationSuite\SuspendedForMove");
                var kept = key?.GetValue(PolicyRootSecurity.MarkerName(root)) as string;
                check(kept is not null && kept.Contains("\"timer\":true"), "With no desktop shell to restart it, the migration keeps a record that the timer was running so the next start can restart it: " + kept);
                Console.WriteLine("NOTE The restart of the timer after the migration needs an interactive desktop session; this run had none.");
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_CONTROL", null); Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_TIMER_STATE", null); Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN", null);
            if (legacy is not null && !legacy.HasExited) legacy.Kill(true);
            var stray = WorkerId(state);
            if (stray > 0) { try { using var process = System.Diagnostics.Process.GetProcessById(stray); process.Kill(true); } catch (Exception error) when (error is ArgumentException or InvalidOperationException) { } }
            Thread.Sleep(500);
            H.Forget(root, operations); H.Delete(root, state); H.Sweep(id);
        }
    }

    private static void ClaimsCarry(Action<bool, string> check)
    {
        var id = H.Name("claims");
        var selection = Path.Combine(H.Local, id);
        var legacy = Path.Combine(selection, "RooOptimizationSuite");
        var current = Path.Combine(selection, "RooIndustriesOptimizationSuite");
        try
        {
            Legacy(legacy, ("settings.json", "{}"));
            Legacy(current, (@"uninstall-claims\0123.json", "{\"queueId\":\"q\"}"));
            var planted = H.Standard("plant", current, @"uninstall-claims\user.json|planted claim");
            check(planted == "PLANTED", "A standard user adds a claim file of their own: " + planted);
            check(BrandCompatibility.DataRoot(selection) == legacy, "The legacy-named folder is the data folder while the claims sit in the current-named folder");
            check(PolicyRootSecurity.Secure(legacy, DataFolder.Kind), "The legacy-named data folder is migrated");
            check(H.Read(Path.Combine(legacy, "uninstall-claims", "0123.json")) == "{\"queueId\":\"q\"}", "A removal claim the earlier version kept in the current-named folder is carried into the protected data folder");
            check(!File.Exists(Path.Combine(legacy, "uninstall-claims", "user.json")), "A claim file that was not written with administrator rights is not carried");
            check(PolicyRootSecurity.Problem(legacy, DataFolder.Kind) is null, "The protected data folder still passes the deep check");
            check(File.Exists(Path.Combine(current, "uninstall-claims", "0123.json")), "The earlier folder is left as it was");
        }
        finally { H.Forget(legacy, current); H.Delete(selection); H.Sweep(id); }
    }
}
