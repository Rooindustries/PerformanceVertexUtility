using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using RooIndustries.Optimizer;
using H = DataRootHarness;

static partial class DataFolderChecks
{
    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string link, string existing, IntPtr security);

    public static void Run(Action<bool, string> check, string[] names)
    {
        if (!PolicyRootSecurity.Elevated()) throw new InvalidOperationException("The data folder scenarios need an administrator session.");
        var scenarios = new List<(string Name, Action<Action<bool, string>> Run)>
        {
            ("core-migration", CoreMigration), ("junction-timer", JunctionTimer), ("timer-conversion", TimerConversion), ("timer-state", TimerState), ("exits", Exits), ("unreadable", Unreadable), ("suspend-resume", SuspendResume), ("root-resolution", RootResolution),
        };
        RegisterNew(scenarios);
        foreach (var name in names) if (!scenarios.Any(item => item.Name == name)) throw new ArgumentException("Unknown data folder scenario: " + name + ". Known: " + string.Join(", ", scenarios.Select(item => item.Name)));
        foreach (var scenario in scenarios.Where(item => names.Length == 0 || names.Contains(item.Name)))
        {
            Console.WriteLine("SCENARIO " + scenario.Name);
            try { scenario.Run(check); }
            catch (Exception error) when (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_SCENARIO_CONTINUE") == "1") { check(false, "The scenario stopped with " + error.GetType().Name + ": " + error.Message); }
        }
    }

    static partial void RegisterNew(List<(string Name, Action<Action<bool, string>> Run)> scenarios);

    private static void CoreMigration(Action<bool, string> check)
    {
        var id = H.Name("core");
        var root = Path.Combine(H.Local, id);
        var outside = Path.Combine(H.Local, id + "-outside");
        var selection = Path.Combine(H.Local, id + "-select");
        var operations = Path.Combine(root, "operations");
        var rules = Path.Combine(root, "process-rules");
        var timer = Path.Combine(operations, OperationsFolder.TimerFolder);
        var current = Path.Combine(selection, "RooIndustriesOptimizationSuite");
        var legacy = Path.Combine(selection, BrandCompatibility.LegacyDataFolder);
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User!;
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "settings"));
            File.WriteAllText(Path.Combine(root, "settings", "custom.json"), "settings bytes");
            File.WriteAllText(Path.Combine(root, "settings", "custom-windows-settings.json"), "{\"catalog\":\"from before protection\"}");
            Directory.CreateDirectory(Path.Combine(root, "tool-cache", "unpacked")); File.WriteAllText(Path.Combine(root, "tool-cache", "unpacked", "tool.exe"), "tool bytes");
            Directory.CreateDirectory(Path.Combine(root, "firmware", "packages", "p1")); File.WriteAllText(Path.Combine(root, "firmware", "packages", "p1", "SCEWIN64.exe"), "package bytes");
            File.WriteAllText(Path.Combine(root, "firmware", "workspace.json"), "{\"packageDirectory\":\"x\"}");
            Directory.CreateDirectory(Path.Combine(root, "firmware", "sessions", "s1")); File.WriteAllText(Path.Combine(root, "firmware", "sessions", "s1", "original.txt"), "bios export");
            Directory.CreateDirectory(Path.Combine(root, "temp")); File.WriteAllText(Path.Combine(root, "temp", "scratch.bin"), "scratch");
            OperationsFolder.Secure(operations);
            File.WriteAllText(Path.Combine(operations, "journal.json"), "journal bytes");
            Directory.CreateDirectory(timer); File.WriteAllText(Path.Combine(timer, "startup.json"), "startup receipt");
            PolicyRootSecurity.Secure(rules);
            Directory.CreateDirectory(Path.Combine(rules, "rules"));
            File.WriteAllText(Path.Combine(rules, "rules", "rule.json"), "rule bytes");
            var untrusted = Path.Combine(root, "untrusted.json");
            File.WriteAllText(untrusted, "planted bytes");
            var owner = new FileSecurity(); owner.SetOwner(user); new FileInfo(untrusted).SetAccessControl(owner);
            TestFixtures.Own(outside);
            File.WriteAllText(Path.Combine(outside, "secret.txt"), "outside bytes");
            check(CreateHardLink(Path.Combine(root, "linked.txt"), Path.Combine(outside, "secret.txt"), IntPtr.Zero), "The fixture hard link to a file outside the data folder exists");
            TestFixtures.Symlink(Path.Combine(root, "link"), outside);
            var oldManifest = Path.Combine(Directory.CreateDirectory(Path.Combine(root, "cleanup-runs", "old")).FullName, "rollback-manifest.json");
            File.WriteAllText(oldManifest, "manifest from before protection");
            var planted = Directory.CreateDirectory(root + ".legacy-planted").FullName;
            File.WriteAllText(Path.Combine(planted, "keep.txt"), "planted leftover");
            check(PolicyRootSecurity.Problem(root, DataFolder.Kind) is not null && PolicyRootSecurity.Problem(operations, OperationsFolder.Kind) is null && PolicyRootSecurity.Problem(rules) is null,
                "Before migration the data folder is open while its recovery and rules folders are already protected");

            var created = new DateTime(2005, 6, 7, 8, 9, 10, DateTimeKind.Utc);
            var dateFiles = new[] { Path.Combine(root, "settings", "custom.json"), Path.Combine(operations, "journal.json") };
            var dateFolders = new[] { Path.Combine(root, "settings"), operations };
            foreach (var path in dateFiles) File.SetCreationTimeUtc(path, created);
            foreach (var path in dateFolders) Directory.SetCreationTimeUtc(path, created);
            var fileDates = dateFiles.ToDictionary(path => path, File.GetCreationTimeUtc);
            var folderDates = dateFolders.ToDictionary(path => path, Directory.GetCreationTimeUtc);

            check(PolicyRootSecurity.Secure(root, DataFolder.Kind), "An open data folder is migrated into a protected one");
            check(fileDates.All(item => File.GetCreationTimeUtc(item.Key) == item.Value), "Migration preserves Date created for carried files");
            check(folderDates.All(item => Directory.GetCreationTimeUtc(item.Key) == item.Value), "Migration preserves Date created for carried directories");
            check(PolicyRootSecurity.Problem(root, DataFolder.Kind) is null && PolicyRootSecurity.Problem(root, DataFolder.Kind, deep: false) is null && PolicyRootSecurity.WriterOf(root) is null,
                "The migrated data folder passes the deep and startup checks and no other account can change it");
            check(PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root)) && !PolicyRootSecurity.Secure(root, DataFolder.Kind), "The migrated data folder is marked and is not migrated again");
            check(PolicyRootSecurity.Problem(operations, OperationsFolder.Kind) is null && OperationsFolder.Ensure(operations) == PolicyRootSecurity.Normalize(operations),
                "The nested recovery folder keeps its own protection and marker after the data folder moved");
            check(PolicyRootSecurity.Problem(rules) is null && H.Read(Path.Combine(rules, "rules", "rule.json")) == "rule bytes", "The nested rules folder keeps its protection and its saved rule");
            check(PolicyRootSecurity.WriterOf(timer) is null && H.Read(Path.Combine(timer, "startup.json")) == "startup receipt",
                "The timer control folder is administrators-only after migration and keeps its startup receipt");
            check(H.Read(Path.Combine(root, "settings", "custom.json")) == "settings bytes" && H.Read(Path.Combine(operations, "journal.json")) == "journal bytes" &&
                H.Read(Path.Combine(root, "firmware", "sessions", "s1", "original.txt")) == "bios export",
                "Settings, recovery journals and saved BIOS sessions written with administrator rights are kept");
            check(!File.Exists(untrusted) && !File.Exists(Path.Combine(root, "linked.txt")) && !Directory.Exists(Path.Combine(root, "link")),
                "Files with another owner, hard links and links are not carried into the protected folder");
            check(!Directory.Exists(Path.Combine(root, "tool-cache")) && !Directory.Exists(Path.Combine(root, "firmware", "packages")) && !File.Exists(Path.Combine(root, "firmware", "workspace.json")) &&
                !File.Exists(Path.Combine(root, "settings", "custom-windows-settings.json")),
                "Programs and packages unpacked before protection and the custom Windows settings file are not carried as trusted");
            check(!Directory.Exists(Path.Combine(root, "temp")), "Temporary files from before protection are not carried");
            var aside = H.Aside(root);
            check(aside.Length == 1 && H.Read(Path.Combine(aside[0], "untrusted.json")) == "planted bytes" && File.Exists(Path.Combine(aside[0], "linked.txt")) &&
                H.Read(Path.Combine(aside[0], "tool-cache", "unpacked", "tool.exe")) == "tool bytes" && H.Read(Path.Combine(aside[0], "firmware", "packages", "p1", "SCEWIN64.exe")) == "package bytes" &&
                File.Exists(Path.Combine(aside[0], "settings", "custom-windows-settings.json")),
                "Skipped entries are kept aside, unread, instead of deleted");
            check(!File.Exists(Path.Combine(aside[0], "operations", "journal.json")) && !File.Exists(Path.Combine(aside[0], "settings", "custom.json")) && !File.Exists(Path.Combine(aside[0], "firmware", "sessions", "s1", "original.txt")) &&
                !File.Exists(Path.Combine(aside[0], "temp", "scratch.bin")),
                "The kept-aside folder holds only what was skipped, not a second copy of everything that was migrated: " + string.Join(", ", H.Names(aside[0])));
            check(H.Read(Path.Combine(outside, "secret.txt")) == "outside bytes", "Migration did not follow the link into the folder outside");
            check(Directory.GetDirectories(H.Local, id + ".secure-*").Length == 0 && Directory.GetDirectories(H.Local, id + ".legacy-*").Single() == planted,
                "Migration leaves no temporary copies next to the data folder");
            check(H.Read(Path.Combine(planted, "keep.txt")) == "planted leftover", "A leftover-named folder in the user-writable parent is not deleted with administrator rights");

            var earlier = false;
            try { PolicyRootSecurity.RequireWrittenAfterProtection(oldManifest, "earlier"); } catch (InvalidDataException) { earlier = true; }
            var carriedJournal = Path.Combine(operations, "journal.json");
            var journalRefused = true;
            try { PolicyRootSecurity.RequireWrittenAfterProtection(carriedJournal, "earlier"); journalRefused = false; } catch (InvalidDataException) { }
            Thread.Sleep(50);
            var newManifest = Path.Combine(Directory.CreateDirectory(Path.Combine(root, "cleanup-runs", "new")).FullName, "rollback-manifest.json");
            File.WriteAllText(newManifest, "manifest written after protection");
            PolicyRootSecurity.RequireWrittenAfterProtection(newManifest, "new");
            check(earlier && H.Read(oldManifest) == "manifest from before protection", "A backup written before the data folder was protected is refused and kept, and one written after is accepted");
            check(journalRefused, "A journal carried from before protection is refused as earlier even though the recovery folder was protected before the data folder was");
            var refused = false;
            try { using var lease = OperationsFolder.LeaseContaining(Path.Combine(H.Local, id + "-outside", "session")); }
            catch (UnauthorizedAccessException) { refused = true; }
            check(refused, "A session folder outside any protected recovery folder is refused");
            var open = Directory.CreateDirectory(Path.Combine(root, "unprotected-operations", OperationsFolder.TimerFolder));
            var openSecurity = open.GetAccessControl();
            openSecurity.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.Modify, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            open.SetAccessControl(openSecurity);
            refused = false;
            try { using var lease = OperationsFolder.LeaseContaining(Path.Combine(open.FullName, "session")); }
            catch (UnauthorizedAccessException) { refused = true; }
            check(refused, "A user-writable folder below an unprotected recovery folder is refused even when only the data folder above it is protected");
            Directory.CreateDirectory(Path.Combine(operations, "game-session-check", "session"));
            using (var lease = OperationsFolder.LeaseContaining(Path.Combine(operations, "game-session-check", "session"))) check(!lease.Moved, "A session folder inside the protected recovery folder is accepted");

            Directory.CreateDirectory(legacy);
            check(BrandCompatibility.DataRoot(selection) == legacy, "An existing legacy folder is used while the current folder is not protected");
            PolicyRootSecurity.Secure(current, DataFolder.Kind);
            check(BrandCompatibility.DataRoot(selection) == current, "A legacy folder made later cannot pull the app away from its protected data folder");
        }
        finally
        {
            H.Forget(root, operations, rules, current, legacy);
            H.Delete(root, selection, outside); H.Sweep(id);
        }
        check(!Directory.Exists(root) && !Directory.Exists(outside) && !Directory.Exists(selection), "Data folder validation removes its folders and markers");
    }

    private static void JunctionTimer(Action<bool, string> check)
    {
        var id = H.Name("junction");
        var temp = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N"));
        var target = Path.Combine(Path.GetTempPath(), "roo-industries-df-target-" + id);
        var timerPath = Path.Combine(temp, "timer");
        var root = Path.Combine(H.Local, id);
        var operations = Path.Combine(root, "operations");
        var linkedTarget = Path.Combine(H.Local, id + "-target");
        try
        {
            Directory.CreateDirectory(temp); TestFixtures.Own(target);
            File.WriteAllText(Path.Combine(target, "control.lock"), "sentinel"); File.WriteAllText(Path.Combine(target, "startup.lock"), "sentinel two");
            H.Junction(timerPath, target);
            var store = new WindowsControlStore();
            var address = new ControlAddress("timer", "fixture:" + timerPath, "half-millisecond");
            var before = store.Read(address);
            Exception? failure = null;
            try { store.Write(before, ControlValues.From(true)); } catch (Exception error) { failure = error; }
            check(failure is UnauthorizedAccessException && failure.Message.Contains("link"), "A timer folder replaced by a junction is refused with a message that names the link: " + failure?.Message);
            check(H.Read(Path.Combine(target, "control.lock")) == "sentinel", "The lock-named file inside the junction target is untouched");
            check(H.Names(target).SequenceEqual(["control.lock", "startup.lock"]), "Nothing was created in the junction target by the timer paths");
            var startupBefore = store.Read(new ControlAddress("timer-startup", "fixture:" + timerPath, "enabled"));
            failure = null;
            try { store.Write(startupBefore, ControlValues.From(true)); } catch (Exception error) { failure = error; }
            check(failure is UnauthorizedAccessException && H.Read(Path.Combine(target, "startup.lock")) == "sentinel two" && H.Names(target).SequenceEqual(["control.lock", "startup.lock"]),
                "The startup paths refuse a junction too and leave the target as it was: " + failure?.Message);

            Directory.CreateDirectory(Path.Combine(operations, "journal-1"));
            File.WriteAllText(Path.Combine(operations, "journal-1", "journal.json"), "journal bytes");
            TestFixtures.Own(linkedTarget);
            File.WriteAllText(Path.Combine(linkedTarget, "control.lock"), "sentinel"); File.WriteAllText(Path.Combine(linkedTarget, "session.json"), "{\"launch\":null}");
            H.Junction(Path.Combine(operations, OperationsFolder.TimerFolder), linkedTarget);
            Exception? migrationFailure = null; var migrated = false;
            try { migrated = PolicyRootSecurity.Secure(root, DataFolder.Kind); } catch (Exception error) { migrationFailure = error; }
            check(H.Read(Path.Combine(linkedTarget, "control.lock")) == "sentinel" && H.Read(Path.Combine(linkedTarget, "session.json")) == "{\"launch\":null}" && H.Names(linkedTarget).SequenceEqual(["control.lock", "session.json"]),
                "The first migration leaves a junction target that replaced the old timer folder as it was: " + migrationFailure?.Message);
            check(migrationFailure is null && migrated && H.Read(Path.Combine(operations, "journal-1", "journal.json")) == "journal bytes", "A link in place of the old timer folder does not block the migration and the journals are kept: " + migrationFailure?.Message);
            check(!H.IsLink(Path.Combine(operations, OperationsFolder.TimerFolder)) && H.Aside(root).Length == 1, "The link is not carried into the protected folder and is kept aside");

        }
        finally
        {
            H.Forget(root, operations);
            H.Delete(root, temp, target, linkedTarget); H.Sweep(id);
        }
    }

    private static void TimerConversion(Action<bool, string> check)
    {
        var id = H.Name("conversion");
        var root = Path.Combine(H.Local, id);
        var operations = Path.Combine(root, "operations");
        var conversionTarget = Path.Combine(H.Local, id + "-conversion");
        try
        {
            TestFixtures.Own(conversionTarget);
            File.WriteAllText(Path.Combine(conversionTarget, "control.lock"), "sentinel");
            var identity = H.Standard("whoami");
            check(identity.Contains("admin-group=False"), "The helper really runs with a standard token: " + identity);
            var assembly = System.Reflection.Assembly.GetEntryAssembly()!.Location;
            check(identity.EndsWith("assembly=" + assembly, StringComparison.OrdinalIgnoreCase), "The standard-token subprocess uses the actual running assembly: " + assembly);
            OperationsFolder.Ensure(operations);
            var timer = Path.Combine(operations, OperationsFolder.TimerFolder);
            check(Directory.Exists(timer), "The timer folder exists after the recovery folder is ensured");
            var conversion = H.Standard("junction", timer, conversionTarget);
            check(!H.IsLink(timer) && Directory.Exists(timer), "A standard token cannot turn the empty timer control folder into a link (" + conversion + ")");
            var write = H.Standard("write", Path.Combine(timer, "launch.json"), "{}");
            check(write.StartsWith("DENIED") && !File.Exists(Path.Combine(timer, "launch.json")), "A standard token cannot write into the timer control folder (" + write + ")");
        }
        finally { H.Forget(root, operations); H.Delete(root, conversionTarget); H.Sweep(id); }
    }
}
