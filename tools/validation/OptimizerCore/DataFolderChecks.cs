using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using RooIndustries.Optimizer;

static class DataFolderChecks
{
    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string link, string existing, IntPtr security);

    public static void Run(Action<bool, string> check)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var id = Guid.NewGuid().ToString("N");
        var root = Path.Combine(local, "RooIndustriesDataCheck-" + id);
        var outside = Path.Combine(local, "RooIndustriesDataCheckOutside-" + id);
        var selection = Path.Combine(local, "RooIndustriesDataCheckLocal-" + id);
        var operations = Path.Combine(root, "operations");
        var rules = Path.Combine(root, "process-rules");
        var timer = Path.Combine(operations, OperationsFolder.TimerFolder);
        var current = Path.Combine(selection, "RooIndustriesOptimizationSuite");
        var legacy = Path.Combine(selection, "RooOptimizationSuite");
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User!;
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "settings"));
            File.WriteAllText(Path.Combine(root, "settings", "custom.json"), "settings bytes");
            OperationsFolder.Secure(operations);
            File.WriteAllText(Path.Combine(operations, "journal.json"), "journal bytes");
            File.WriteAllText(Path.Combine(timer, "session.json"), "timer bytes");
            PolicyRootSecurity.Secure(rules);
            Directory.CreateDirectory(Path.Combine(rules, "rules"));
            File.WriteAllText(Path.Combine(rules, "rules", "rule.json"), "rule bytes");
            var untrusted = Path.Combine(root, "untrusted.json");
            File.WriteAllText(untrusted, "planted bytes");
            var owner = new FileSecurity(); owner.SetOwner(user); new FileInfo(untrusted).SetAccessControl(owner);
            Directory.CreateDirectory(outside);
            File.WriteAllText(Path.Combine(outside, "secret.txt"), "outside bytes");
            check(CreateHardLink(Path.Combine(root, "linked.txt"), Path.Combine(outside, "secret.txt"), IntPtr.Zero), "The fixture hard link to a file outside the data folder exists");
            Directory.CreateSymbolicLink(Path.Combine(root, "link"), outside);
            check(PolicyRootSecurity.Problem(root, DataFolder.Kind) is not null && PolicyRootSecurity.Problem(operations, OperationsFolder.Kind) is null && PolicyRootSecurity.Problem(rules) is null,
                "Before migration the data folder is open while its recovery and rules folders are already protected");

            check(PolicyRootSecurity.Secure(root, DataFolder.Kind), "An open data folder is migrated into a protected one");
            check(PolicyRootSecurity.Problem(root, DataFolder.Kind) is null && PolicyRootSecurity.Problem(root, DataFolder.Kind, deep: false) is null && PolicyRootSecurity.WriterOf(root) is null,
                "The migrated data folder passes the deep and startup checks and no other account can change it");
            check(PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(root)) && !PolicyRootSecurity.Secure(root, DataFolder.Kind), "The migrated data folder is marked and is not migrated again");
            check(PolicyRootSecurity.Problem(operations, OperationsFolder.Kind) is null && OperationsFolder.Ensure(operations) == PolicyRootSecurity.Normalize(operations),
                "The nested recovery folder keeps its own protection and marker after the data folder moved");
            check(PolicyRootSecurity.Problem(rules) is null && File.ReadAllText(Path.Combine(rules, "rules", "rule.json")) == "rule bytes", "The nested rules folder keeps its protection and its saved rule");
            check(PolicyRootSecurity.WriterOf(timer) == user.Value && File.ReadAllText(Path.Combine(timer, "session.json")) == "timer bytes",
                "The sign-in timer folder stays writable for the Windows user with its state");
            check(File.ReadAllText(Path.Combine(root, "settings", "custom.json")) == "settings bytes" && File.ReadAllText(Path.Combine(operations, "journal.json")) == "journal bytes",
                "Settings and recovery journals written with administrator rights are kept");
            check(!File.Exists(untrusted) && !File.Exists(Path.Combine(root, "linked.txt")) && !Directory.Exists(Path.Combine(root, "link")),
                "Files with another owner, hard links and links are not carried into the protected folder");
            var aside = Directory.GetDirectories(local, Path.GetFileName(root) + ".untrusted-*");
            check(aside.Length == 1 && File.ReadAllText(Path.Combine(aside[0], "untrusted.json")) == "planted bytes" && File.Exists(Path.Combine(aside[0], "linked.txt")),
                "Untrusted entries are kept aside, unread, instead of deleted");
            check(File.ReadAllText(Path.Combine(outside, "secret.txt")) == "outside bytes", "Migration did not follow the link into the folder outside");
            check(Directory.GetDirectories(local, Path.GetFileName(root) + ".secure-*").Length == 0 && Directory.GetDirectories(local, Path.GetFileName(root) + ".legacy-*").Length == 0,
                "Migration leaves no temporary copies next to the data folder");

            var refused = false;
            try { using var lease = OperationsFolder.LeaseContaining(Path.Combine(timer, "session", "nested")); }
            catch (UnauthorizedAccessException) { refused = true; }
            check(refused, "A session folder inside the user-writable timer folder is refused even though the data folder above it is protected");
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
            using (var markers = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true))
                foreach (var path in new[] { root, operations, rules, current, legacy }) markers?.DeleteValue(PolicyRootSecurity.MarkerName(path), false);
            foreach (var path in new[] { root, selection, outside }.Concat(Directory.GetDirectories(local, Path.GetFileName(root) + ".*")))
                if (Directory.Exists(path)) Directory.Delete(path, true);
        }
        check(!Directory.Exists(root) && !Directory.Exists(outside) && !Directory.Exists(selection), "Data folder validation removes its folders and markers");
    }
}
