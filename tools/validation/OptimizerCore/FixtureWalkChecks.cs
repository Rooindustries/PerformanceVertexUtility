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
            foreach (var scenario in new Action<Action<bool, string>, string, string>[] { Unremovable, Killed, Walks })
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
        AliasOwnershipChecks.Junction(Path.Combine(root, "junction"), canary);
        Directory.CreateSymbolicLink(Path.Combine(root, "symlink"), canary);
        AliasOwnershipChecks.Junction(Path.Combine(root, "mount"), volume.Name);
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

    private static void Killed(Action<bool, string> check, string canary, string before)
    {
        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The suite executable is unavailable.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        start.RedirectStandardOutput = true;
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        start.ArgumentList.Add("--fixture-hold");
        start.ArgumentList.Add(canary);
        string? root;
        using (var child = Process.Start(start)!)
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

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
