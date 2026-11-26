using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class FixtureWalkChecks
{
    public static void Hold(string canary)
    {
        var root = TestFixtures.InheritingRoot("held-fixture");
        Plant(root, canary);
        Console.WriteLine(root);
        Thread.Sleep(Timeout.Infinite);
    }

    public static void Run(Action<bool, string> check)
    {
        var outside = TestFixtures.InheritingRoot("walk-canary");
        try
        {
            var canary = Directory.CreateDirectory(Path.Combine(outside, "canary")).FullName;
            File.WriteAllText(Path.Combine(canary, "kept.txt"), "canary");
            var before = Canary(canary);
            var scenarios = new Action<Action<bool, string>, string, string>[] { Guarded, Unremovable, Killed, Shared, Jammed, Walks };
            foreach (var scenario in scenarios)
            {
                try { scenario(check, canary, before); }
                catch (Exception error)
                {
                    check(false, scenario.Method.Name + " fixture scenario stopped: " + error.Message);
                }
            }
            check(Canary(canary) == before, "The canary outside every fixture keeps its content, owner and ACL");
        }
        finally { TestFixtures.Remove(outside); }
    }

    private static (string Mount, string Name) Plant(string root, string canary)
    {
        var volume = TestFixtures.Volume(root);
        File.WriteAllText(Path.Combine(volume.Mount, "kept.txt"), "volume canary");
        TestFixtures.Junction(Path.Combine(root, "junction"), canary);
        TestFixtures.Symlink(Path.Combine(root, "symlink"), canary);
        TestFixtures.Junction(Path.Combine(root, "mount"), volume.Name);
        Directory.CreateDirectory(Path.Combine(root, "plain"));
        File.WriteAllText(Path.Combine(root, "plain", "owned.txt"), "fixture");
        return volume;
    }

    private static string Canary(string folder) => string.Join("\n", new[] { folder, Path.Combine(folder, "kept.txt") }.Select(path =>
    {
        FileSystemSecurity security = Directory.Exists(path)
            ? new DirectoryInfo(path).GetAccessControl()
            : new FileInfo(path).GetAccessControl();
        var content = File.Exists(path) ? File.ReadAllText(path) : "folder";
        var sddl = security.GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Access);
        return path + "|" + content + "|" + sddl;
    }));

    public static void SweepFor(string label) => TestFixtures.Remove(TestFixtures.InheritingRoot(label));

    private static ProcessStartInfo Child(params string[] arguments)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The suite executable is unavailable.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        start.RedirectStandardOutput = true;
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return start;
    }

    private static void Guarded(Action<bool, string> check, string canary, string before)
    {
        var root = TestFixtures.InheritingRoot("link-guard");
        try
        {
            var link = Path.Combine(root, "link");
            var device = new System.Text.StringBuilder(32768);
            if (QueryDosDevice(root[..2], device, (uint)device.Capacity) == 0) throw new Win32Exception();
            string[] refused =
            [
                Path.GetPathRoot(root)!, @"\\?\GLOBALROOT" + device + @"\", Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                Path.GetTempPath(), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RooIndustriesOptimizationSuite"),
                @"\\localhost\" + root[0] + "$", @"..\..\..", Path.Combine(root, "..", "..", ".."),
            ];
            var passed = refused.Where(target =>
            {
                try { TestFixtures.Contain(link, target); return true; }
                catch (InvalidOperationException) { return false; }
            }).ToArray();
            check(passed.Length == 0, "A fixture link to a drive root, a device root, Windows, Temp, the app's data folder "
                + "or a loopback share is refused: " + string.Join(", ", passed));
            TestFixtures.Contain(link, root);
            TestFixtures.Contain(link, "inside");
            TestFixtures.Contain(link, Path.Combine(canary, "kept.txt"));
            TestFixtures.Contain(link, @"\\192.0.2.139\Share");
            check(!Path.Exists(link),
                "A fixture link inside its own fixture or to an unroutable share is allowed, and checking creates nothing");
        }
        finally { TestFixtures.Remove(root); }
    }

    private static void Shared(Action<bool, string> check, string canary, string before)
    {
        var live = TestFixtures.InheritingRoot("live-fixture");
        try
        {
            using var child = Process.Start(Child("--fixture-sweep", "live-fixture"))!;
            child.StandardOutput.ReadToEnd();
            var finished = child.WaitForExit(120000) && child.ExitCode == 0;
            check(finished && Directory.Exists(live), "Another run's start leaves a live run's fixture in place");
        }
        finally { TestFixtures.Remove(live); }
    }

    private static void Jammed(Action<bool, string> check, string canary, string before)
    {
        string Stale() => Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "roo-industries-jammed-fixture-" + Guid.NewGuid().ToString("N")))
            .FullName;
        var garbage = Stale();
        File.WriteAllBytes(Path.Combine(garbage, TestFixtures.VolumeFile), new byte[65536]);
        var locked = Stale();
        TestFixtures.Volume(locked);
        var opaque = Directory.CreateDirectory(Path.Combine(locked, "opaque-peer"));
        var unreadable = Directory.CreateDirectory(Path.Combine(opaque.FullName, "unreadable-peer"));
        TestFixtures.Junction(Path.Combine(unreadable.FullName, "alias"), locked);
        var user = WindowsIdentity.GetCurrent().User!;
        var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        var denied = unreadable.GetAccessControl();
        var hidden = FileSystemRights.ReadAttributes | FileSystemRights.ListDirectory;
        denied.AddAccessRule(new FileSystemAccessRule(user, hidden, inherit, PropagationFlags.None, AccessControlType.Deny));
        unreadable.SetAccessControl(denied);
        var opaqueDenied = opaque.GetAccessControl();
        var closed = FileSystemRights.ListDirectory | FileSystemRights.Traverse;
        opaqueDenied.AddAccessRule(new FileSystemAccessRule(user, closed, AccessControlType.Deny));
        opaque.SetAccessControl(opaqueDenied);
        PrivilegeChecks.WithoutPrivileges(() => SweepFor("jammed-fixture"), "SeBackupPrivilege", "SeRestorePrivilege");
        check(!Path.Exists(garbage) && !Path.Exists(locked) && Canary(canary) == before,
            "The next run start clears a half-written volume file and a fixture a dead run left unreadable, with its volume");
    }

    private static void Killed(Action<bool, string> check, string canary, string before)
    {
        string? root;
        using (var child = Process.Start(Child("--fixture-hold", canary))!)
        {
            var line = child.StandardOutput.ReadLineAsync();
            root = line.Wait(TimeSpan.FromMinutes(2)) ? line.Result : null;
            child.Kill(true);
            child.WaitForExit();
        }
        var left = root is not null && Directory.Exists(Path.Combine(root, "mount"));
        check(left && File.Exists(Path.Combine(root!, TestFixtures.VolumeFile)),
            "A run killed mid-test leaves its fixture, links, mount point and attached volume behind");
        TestFixtures.Remove(TestFixtures.InheritingRoot("held-fixture"));
        check(!Path.Exists(root!) && !File.Exists(root + ".run"),
            "The next run start unmounts, detaches and removes the killed run's fixture");
        check(Canary(canary) == before, "Removing the killed run's fixture leaves the canary outside it unchanged");
    }

    private static void Unremovable(Action<bool, string> check, string canary, string before)
    {
        var root = TestFixtures.InheritingRoot("mount-cleanup");
        Plant(root, canary);
        var mount = Path.Combine(root, "mount");
        string? refusal = null;
        using (var held = CreateFile(mount, 0x81, 0, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        {
            check(!held.IsInvalid, "The fixture holds its mount point open so cleanup cannot remove it");
            try { TestFixtures.Remove(root); }
            catch (IOException error) { refusal = error.Message; }
        }
        var named = refusal is not null && refusal.Contains(mount, StringComparison.OrdinalIgnoreCase);
        var kept = File.Exists(Path.Combine(root, "plain", "owned.txt"));
        kept &= File.Exists(Path.Combine(root, TestFixtures.VolumeFile));
        check(named && kept,
            "A mount point cleanup cannot remove stops cleanup loudly, names it, and deletes nothing behind it");
        TestFixtures.Remove(root);
        check(!Path.Exists(root) && Canary(canary) == before,
            "Cleanup removes a fixture with a junction, a link and a mount point, which Directory.Delete stops at, "
            + "and the canary keeps its content, owner and ACL");
    }

    private static void Walks(Action<bool, string> check, string canary, string before)
    {
        var root = TestFixtures.InheritingRoot("walk-fixture");
        var copy = Directory.CreateDirectory(Path.Combine(Path.GetDirectoryName(canary)!, "copy")).FullName;
        try
        {
            var volume = Plant(root, canary);
            var volumeBefore = Canary(volume.Mount);
            var user = WindowsIdentity.GetCurrent().User!;
            foreach (var entry in LocalTree.Entries(root))
            {
                var folder = entry as DirectoryInfo;
                var inherit = folder is null
                    ? InheritanceFlags.None
                    : InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
                FileSystemSecurity security = folder is null ? new FileSecurity() : new DirectorySecurity();
                security.SetOwner(user);
                security.SetAccessRuleProtection(true, false);
                var rights = FileSystemRights.FullControl;
                security.AddAccessRule(new FileSystemAccessRule(user, rights, inherit, PropagationFlags.None, AccessControlType.Allow));
                if (folder is not null) folder.SetAccessControl((DirectorySecurity)security);
                else ((FileInfo)entry).SetAccessControl((FileSecurity)security);
            }
            foreach (var file in LocalTree.Entries(root).OfType<FileInfo>())
            {
                var name = Path.GetRelativePath(root, file.FullName).Replace(Path.DirectorySeparatorChar, '_');
                file.CopyTo(Path.Combine(copy, name));
            }
            check(Canary(canary) == before && Canary(volume.Mount) == volumeBefore,
                "An owner and permission walk over a fixture changes nothing behind its junction, link or mount point");
            var copied = Directory.GetFiles(copy).Select(Path.GetFileName).Order(StringComparer.Ordinal);
            check(copied.SequenceEqual(["plain_owned.txt", TestFixtures.VolumeFile]),
                "A copy walk over a fixture copies only the fixture's own files: " + string.Join(", ", copied));
        }
        finally
        {
            TestFixtures.Remove(root);
            Directory.Delete(copy, true);
        }
        check(Canary(canary) == before, "The canary outside the walked fixture keeps its content, owner and ACL");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint QueryDosDevice(string name, System.Text.StringBuilder target, uint length);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
