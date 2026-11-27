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
        File.WriteAllText(Path.Combine(TestFixtures.Own(canary), "kept.txt"), "held");
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
            var scenarios = new (string Name, Action<Action<bool, string>, string, string> Run)[]
            {
                (nameof(Guarded), Guarded), (nameof(Disguised), Disguised), (nameof(Unmarked), Unmarked), (nameof(Hardlinked), Hardlinked), (nameof(SharedDisk), SharedDisk),
                (nameof(Unremovable), Unremovable), (nameof(Killed), Killed), (nameof(Shared), Shared), (nameof(Jammed), Jammed), (nameof(Walks), Walks),
            };
            foreach (var scenario in scenarios)
            {
                try { scenario.Run(check, canary, before); }
                catch (Exception error)
                {
                    check(false, scenario.Name + " fixture scenario stopped: " + error.Message);
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
        var lookalike = Path.Combine(Path.GetTempPath(), "roo-industries-lookalike-" + Guid.NewGuid().ToString("N"));
        try
        {
            var device = new System.Text.StringBuilder(32768);
            if (QueryDosDevice(root[..2], device, (uint)device.Capacity) == 0) throw new Win32Exception();
            var deep = Directory.CreateDirectory(Path.Combine(root, "a", "b", "c", "d", "e", "f", "g")).FullName;
            var up = Path.Combine(deep, "up");
            TestFixtures.Junction(up, root);
            var behind = Directory.CreateDirectory(Path.Combine(lookalike, "behind")).FullName;
            Directory.CreateSymbolicLink(Path.Combine(lookalike, "mount"), behind);
            var unowned = TestFixtures.Volume(lookalike, own: false);
            var nested = TestFixtures.Own(Path.Combine(lookalike, "nested"));
            var temp = Path.GetFileName(Path.GetTempPath().TrimEnd('\\'));
            (string Link, string Target, bool Junction)[] refused =
            [
                (Path.Combine(root, "volume-root"), unowned.Name, true),
                (Path.Combine(root, "plain"), lookalike, true),
                (Path.Combine(root, "device"), @"\\?\GLOBALROOT" + device + lookalike[2..], true),
                (Path.Combine(nested, "parent"), lookalike, true),
                (Path.Combine(root, "loopback"), @"\\localhost\" + lookalike[0] + "$" + lookalike[2..], false),
                (Path.Combine(up, "escape"), @"..\" + Path.GetFileName(lookalike), false),
                (Path.Combine(up, "climb"), @"..\..\" + temp + @"\" + Path.GetFileName(lookalike), false),
                (Path.Combine(root, "via-lookalike"), Path.Combine(lookalike, "mount"), true),
            ];
            var kept = refused.Where(item =>
            {
                try
                {
                    if (item.Junction) TestFixtures.Junction(item.Link, item.Target);
                    else TestFixtures.Symlink(item.Link, item.Target);
                }
                catch (InvalidOperationException) { }
                return Path.Exists(item.Link);
            }).Select(item => item.Link).ToArray();
            check(kept.Length == 0, "A link to a volume this run did not make, a folder it did not make by path, device path, loopback share or as a parent, "
                + "out of the fixture through a junction, or through a folder only named like a fixture is refused: " + string.Join(", ", kept));
            var via = Path.Combine(root, "via-link");
            Directory.CreateSymbolicLink(via, lookalike);
            var shared = Path.Combine(root, "shared.txt");
            File.WriteAllText(shared, "kept");
            try { TestFixtures.HardLink(Path.Combine(via, "escaped.txt"), shared); }
            catch (InvalidOperationException) { }
            check(!File.Exists(Path.Combine(lookalike, "escaped.txt")), "A hard link whose folder leads out of this run's folders is refused before it is made");
            TestFixtures.Junction(Path.Combine(root, "self"), root);
            TestFixtures.Symlink(Path.Combine(root, "missing"), "inside");
            TestFixtures.Symlink(Path.Combine(root, "canary-file"), Path.Combine(canary, "kept.txt"), file: true);
            TestFixtures.Symlink(Path.Combine(root, "share"), @"\\192.0.2.139\Share");
            check(new[] { "self", "missing", "canary-file", "share" }.All(name => Path.Exists(Path.Combine(root, name))),
                "A link into this run's own fixture, to a missing child, or to an unroutable share is kept");
            Directory.CreateDirectory(Path.Combine(root, "spaced"));
            Directory.CreateSymbolicLink(@"\\?\" + Path.Combine(root, "spaced "), lookalike);
            var spaced = Path.Combine(root, "through-space");
            try { TestFixtures.Symlink(spaced, "spaced "); }
            catch (InvalidOperationException) { }
            check(!Path.Exists(spaced), "A link whose spelled target is inside but which Windows opens outside, through a name ending in a space, is removed and refused");
        }
        finally
        {
            TestFixtures.Remove(root);
            TestFixtures.Remove(lookalike);
        }
    }

    private static void Hardlinked(Action<bool, string> check, string canary, string before)
    {
        var holder = TestFixtures.InheritingRoot("hardlink-target");
        var stale = TestFixtures.InheritingRoot("hardlinked-fixture");
        TestFixtures.Abandon(stale);
        try
        {
            var shared = new FileInfo(Path.Combine(holder, "shared.txt"));
            File.WriteAllText(shared.FullName, "kept");
            var security = shared.GetAccessControl();
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.WriteData, AccessControlType.Deny));
            shared.SetAccessControl(security);
            TestFixtures.HardLink(Path.Combine(stale, "shared.txt"), shared.FullName);
            SweepFor("hardlinked-fixture");
            var deny = shared.GetAccessControl().GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .Any(rule => rule.AccessControlType == AccessControlType.Deny);
            check(!Path.Exists(stale) && File.ReadAllText(shared.FullName) == "kept" && deny,
                "A run start removes a dead fixture's hard link without changing the permissions of the file it shares");
        }
        finally
        {
            TestFixtures.Remove(stale);
            TestFixtures.Remove(holder);
        }
    }

    private static void Disguised(Action<bool, string> check, string canary, string before)
    {
        var holder = TestFixtures.InheritingRoot("disguise-target");
        var stale = Path.Combine(Path.GetTempPath(), "roo-industries-disguised-fixture-" + Guid.NewGuid().ToString("N"));
        try
        {
            var victim = Directory.CreateDirectory(Path.Combine(holder, "victim")).FullName;
            var inner = Path.Combine(victim, "inner");
            TestFixtures.Junction(inner, Directory.CreateDirectory(Path.Combine(holder, "behind")).FullName);
            var mount = Path.Combine(victim, "mnt");
            TestFixtures.Junction(mount, TestFixtures.Volume(holder).Name);
            var denied = new FileInfo(Path.Combine(victim, "denied.txt"));
            File.WriteAllText(denied.FullName, "kept");
            var security = denied.GetAccessControl();
            security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.WriteData, AccessControlType.Deny));
            denied.SetAccessControl(security);
            var precious = Path.Combine(holder, "precious.txt");
            File.WriteAllText(precious, "precious");
            TestFixtures.Junction(stale, victim);
            TestFixtures.Symlink(stale + ".run", precious, file: true);
            var output = Sweep("disguised-fixture");
            static bool Linked(string path) => Path.Exists(path) && File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint);
            var deny = denied.GetAccessControl().GetAccessRules(true, false, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .Any(rule => rule.AccessControlType == AccessControlType.Deny);
            check(Linked(stale) && Linked(inner) && Linked(mount) && deny && output.Contains(stale, StringComparison.OrdinalIgnoreCase),
                "A run start leaves a fixture-named junction it did not make in place, names it, and changes nothing behind it");
            check(File.Exists(precious) && Linked(stale + ".run"), "A run start leaves the lock link of a junction it did not make and what it points to");
        }
        finally
        {
            TestFixtures.Remove(stale);
            if (Path.Exists(stale + ".run")) File.Delete(stale + ".run");
            TestFixtures.Remove(holder);
        }
    }

    private static void Unmarked(Action<bool, string> check, string canary, string before)
    {
        var lookalike = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "roo-industries-lookalike-fixture-" + Guid.NewGuid().ToString("N"))).FullName;
        try
        {
            File.WriteAllText(Path.Combine(lookalike, "canary.txt"), "another program's folder");
            var output = Sweep("lookalike-fixture");
            check(File.ReadAllText(Path.Combine(lookalike, "canary.txt")) == "another program's folder" && output.Contains(lookalike, StringComparison.OrdinalIgnoreCase),
                "A run start leaves a folder only named like a fixture, with no proof this suite made it, and names it");
        }
        finally { TestFixtures.Remove(lookalike); }
    }

    private static void SharedDisk(Action<bool, string> check, string canary, string before)
    {
        var holder = TestFixtures.InheritingRoot("disk-owner");
        var stale = TestFixtures.InheritingRoot("shared-disk");
        TestFixtures.Abandon(stale);
        var second = Path.Combine(stale, TestFixtures.VolumeFile);
        try
        {
            var volume = TestFixtures.Volume(holder);
            File.WriteAllText(Path.Combine(volume.Mount, "kept.txt"), "attached");
            TestFixtures.HardLink(second, Path.Combine(holder, TestFixtures.VolumeFile));
            var output = Sweep("shared-disk");
            check(File.ReadAllText(Path.Combine(volume.Mount, "kept.txt")) == "attached" && output.Contains(second, StringComparison.OrdinalIgnoreCase),
                "A run start leaves a virtual disk attached when the disk file in a dead fixture has another name, and names it");
        }
        finally
        {
            if (File.Exists(second)) File.Delete(second);
            TestFixtures.Remove(holder);
            TestFixtures.Remove(stale);
        }
    }

    private static string Sweep(string label)
    {
        using var child = Process.Start(Child("--fixture-sweep", label))!;
        var output = child.StandardOutput.ReadToEnd();
        if (!child.WaitForExit(120000) || child.ExitCode != 0) throw new InvalidOperationException("The sweep child did not finish: " + output);
        return output;
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
        var garbage = TestFixtures.InheritingRoot("jammed-fixture");
        File.WriteAllBytes(Path.Combine(garbage, TestFixtures.VolumeFile), new byte[65536]);
        var locked = TestFixtures.InheritingRoot("jammed-fixture");
        TestFixtures.Abandon(garbage);
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
        TestFixtures.Abandon(locked);
        PrivilegeChecks.WithoutPrivileges(() => SweepFor("jammed-fixture"), "SeBackupPrivilege", "SeRestorePrivilege");
        check(!Path.Exists(garbage) && !Path.Exists(locked) && Canary(canary) == before,
            "The next run start clears a half-written volume file and a fixture a dead run left unreadable, with its volume");
    }

    private static void Killed(Action<bool, string> check, string canary, string before)
    {
        string? root;
        var held = canary + "-held";
        using (var child = Process.Start(Child("--fixture-hold", held))!)
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
        check(Canary(canary) == before && File.ReadAllText(Path.Combine(held, "kept.txt")) == "held",
            "Removing the killed run's fixture leaves the canaries outside it unchanged");
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
            var started = new List<string>();
            try { started.AddRange(LocalTree.Entries(Path.Combine(root, "junction")).Select(entry => entry.FullName)); }
            catch (IOException) { started = null; }
            check(started is null, "A walk that starts at a link refuses instead of listing what it points to");
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
