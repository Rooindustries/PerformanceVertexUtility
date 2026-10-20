using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class AliasOwnershipChecks
{
    public static void Probe(string root, string peerPath)
    {
        var target = Path.Combine(root, "Roo Industries Example");
        var application = new CleanupApplication { AppId = "fixture:alias-owner", DisplayName = "Roo Industries Example", Publisher = "Fixture", InstallLocation = target, PackageFamilyName = null };
        var peer = application with { AppId = "fixture:peer", DisplayName = "Independent alias tool", InstallLocation = peerPath };
        var candidate = new LeftoverDiscovery(application, [peer]).Scan(CancellationToken.None, [], []).Candidates.Single(item => item.Target == target);
        var authority = new CleanupAuthority { AppId = application.AppId, ProviderIdentityHash = new string('A', 64), Owner = OperationOwner.Current(), ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true };
        var context = new CleanupContext(Path.Combine(root, "queue.json"), authority, application, [peer], true);
        var refused = false;
        try { new ApplicationCleanup(() => context, [], []).Preview(Path.Combine(root, "preview", "review.json"), [candidate.ItemId], true, true); }
        catch (InvalidDataException) { refused = true; }
        var mapping = new StringBuilder(32768);
        var mapped = QueryDosDevice(peerPath[..2], mapping, (uint)mapping.Capacity);
        Console.WriteLine(JsonSerializer.Serialize(new { Application = application, Peer = peer, RootDeviceMapping = mapped == 0 ? null : mapping.ToString(), candidate.SharedOwners, candidate.OwnershipComplete, PreviewRefused = refused, Preserved = File.ReadAllText(Path.Combine(target, "settings.txt")) == "fixture" }));
    }

    private static void CheckPeer(Action<bool, string> check, string root, string peer, string name, bool shared)
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Probe executable is unavailable.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        start.ArgumentList.Add("--alias-ownership-probe"); start.ArgumentList.Add(root); start.ArgumentList.Add(peer);
        using var child = Process.Start(start)!;
        var output = child.StandardOutput.ReadToEndAsync();
        var errors = child.StandardError.ReadToEndAsync();
        var exited = child.WaitForExit(4000);
        if (!exited) { child.Kill(true); child.WaitForExit(); }
        var text = output.GetAwaiter().GetResult();
        var error = errors.GetAwaiter().GetResult();
        check(exited && child.ExitCode == 0, name + " finishes in the disposable probe within four seconds: " + error);
        using var result = JsonDocument.Parse(text);
        var value = result.RootElement;
        Console.WriteLine("MEASURE aliasOwnership " + JsonSerializer.Serialize(new { Scenario = name, Result = value }));
        check(value.GetProperty("PreviewRefused").GetBoolean() && value.GetProperty("Preserved").GetBoolean() &&
            (shared ? value.GetProperty("SharedOwners").EnumerateArray().Any(owner => owner.GetString() == "Independent alias tool") : !value.GetProperty("OwnershipComplete").GetBoolean()),
            name + (shared ? " retains its shared owner and refuses cleanup preview" : " stays unknown and refuses cleanup preview"));
    }

    private static void Junction(string path, string target)
    {
        var start = new ProcessStartInfo("cmd.exe", "/d /c mklink /J \"" + path + "\" \"" + target + "\"") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        using var child = Process.Start(start)!;
        var output = child.StandardOutput.ReadToEndAsync(); var errors = child.StandardError.ReadToEndAsync();
        if (!child.WaitForExit(4000)) { child.Kill(true); child.WaitForExit(); throw new IOException("Junction fixture creation timed out."); }
        if (child.ExitCode != 0 || (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0) throw new IOException(output.GetAwaiter().GetResult() + errors.GetAwaiter().GetResult());
    }

    private static string Map(string target)
    {
        for (var letter = 'Z'; letter >= 'I'; letter--)
        {
            var name = letter + ":";
            if (QueryDosDevice(name, new StringBuilder(32768), 32768) != 0 || Marshal.GetLastWin32Error() != 2) continue;
            if (!DefineDosDevice(9, name, target)) throw new IOException("Could not create disposable DOS mapping.");
            return name;
        }
        throw new IOException("No unused drive letter for the disposable alias fixture.");
    }

    public static void Run(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("alias-ownership");
        var target = Path.Combine(root, "Roo Industries Example");
        Directory.CreateDirectory(target);
        File.WriteAllText(Path.Combine(target, "settings.txt"), "fixture");
        var links = new List<string>();
        var mapping = ""; var mappedTarget = "";
        try
        {
            var elsewhere = Path.Combine(root, "Elsewhere", "Leaf");
            Directory.CreateDirectory(elsewhere);
            var alias = Path.Combine(root, "alias");
            links.Add(alias); Junction(alias, elsewhere);
            CheckPeer(check, root, Path.Combine(alias, "..", "Roo Industries Example"), "dotdot-after-junction", true);

            var volume = new StringBuilder(64);
            check(GetVolumeNameForVolumeMountPoint(Path.GetPathRoot(root)!, volume, (uint)volume.Capacity), "A real local volume GUID is available for alias fixtures");
            var mount = Path.Combine(root, "mount");
            links.Add(mount); Junction(mount, volume.ToString());
            Console.WriteLine("MEASURE mountTarget " + JsonSerializer.Serialize(new { LinkTarget = new DirectoryInfo(mount).LinkTarget }));
            CheckPeer(check, root, Path.Combine(mount, target[Path.GetPathRoot(target)!.Length..]), "volume-guid-mount", false);

            mappedTarget = @"\??\" + target; mapping = Map(mappedTarget);
            CheckPeer(check, root, mapping + @"\", "subst-root", false);
            if (!DefineDosDevice(15, mapping, mappedTarget)) throw new IOException("Could not remove own DOS mapping.");
            mapping = "";

            var nas = Path.Combine(root, "nas");
            links.Add(nas); Directory.CreateSymbolicLink(nas, @"\\192.0.2.139\AliasOwnershipFixture");
            var volumeBridge = Path.Combine(root, "volume-bridge");
            links.Add(volumeBridge); Junction(volumeBridge, volume + Path.Combine(nas, "Tool")[Path.GetPathRoot(nas)!.Length..]);
            CheckPeer(check, root, volumeBridge, "volume-guid-bridge-to-unc", false);
            mappedTarget = @"\??\" + nas; mapping = Map(mappedTarget);
            CheckPeer(check, root, mapping + @"\Tool", "subst-link-to-offline-unc", false);
            if (!DefineDosDevice(15, mapping, mappedTarget)) throw new IOException("Could not remove own DOS mapping.");
            mapping = "";

            var shortName = new StringBuilder(32768);
            if (GetShortPathName(target, shortName, (uint)shortName.Capacity) != 0 && string.Equals(target, shortName.ToString(), StringComparison.OrdinalIgnoreCase))
            {
                using var shortHandle = CreateFile(target, 0x40010000, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
                check(!shortHandle.IsInvalid && SetFileShortName(shortHandle, "ROOOWN~1"), "An explicit short name is assigned only to the disposable fixture");
                shortName.Clear();
            }
            check(GetShortPathName(target, shortName, (uint)shortName.Capacity) != 0 && !string.Equals(target, shortName.ToString(), StringComparison.OrdinalIgnoreCase) && shortName.ToString().Contains('~'), "Fixture has an actual 8.3 alias");
            CheckPeer(check, root, shortName.ToString(), "actual-8dot3-alias", true);

            var locked = Path.Combine(root, "locked-peer");
            Directory.CreateDirectory(locked);
            using (var handle = CreateFile(locked, 0x80, 0, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
            {
                check(!handle.IsInvalid && (File.GetAttributes(locked) & FileAttributes.Directory) != 0, "Final-open failure fixture still permits the metadata walk");
                CheckPeer(check, root, locked, "final-open-sharing-failure", false);
            }

            var unreadable = Directory.CreateDirectory(Path.Combine(root, "unreadable-peer"));
            var hidden = Path.Combine(unreadable.FullName, "alias");
            links.Add(hidden); Junction(hidden, target);
            var security = unreadable.GetAccessControl();
            var denied = unreadable.GetAccessControl();
            denied.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.ReadAttributes | FileSystemRights.ListDirectory, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Deny));
            try
            {
                unreadable.SetAccessControl(denied);
                var refused = false;
                try { _ = File.GetAttributes(hidden); } catch (UnauthorizedAccessException) { refused = true; }
                check(refused, "Unreadable ancestor fixture actually denies metadata access");
                CheckPeer(check, root, hidden, "unreadable-ancestor", false);
            }
            finally { unreadable.SetAccessControl(security); }

            var retarget = Path.Combine(root, "retarget-peer");
            links.Add(retarget); Junction(retarget, elsewhere);
            var application = new CleanupApplication { AppId = "fixture:retarget", DisplayName = "Roo Industries Example", Publisher = "Fixture", InstallLocation = target, PackageFamilyName = null };
            var peer = application with { AppId = "fixture:retarget-peer", DisplayName = "Independent alias tool", InstallLocation = retarget };
            var authority = new CleanupAuthority { AppId = application.AppId, ProviderIdentityHash = new string('A', 64), Owner = OperationOwner.Current(), ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true };
            var context = new CleanupContext(Path.Combine(root, "queue.json"), authority, application, [peer], true);
            var engine = new ApplicationCleanup(() => context, [], []);
            var selection = engine.Scan(CancellationToken.None).Candidates.Single(item => item.Target == target);
            var reviewPath = Path.Combine(root, "retarget-review", "review.json");
            var review = engine.Preview(reviewPath, [selection.ItemId], true, true);
            Directory.Delete(retarget); Junction(retarget, target);
            var result = engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), Path.Combine(root, "retarget-review", "journal.json"));
            check(result.Status == "needsReconciliation" && File.ReadAllText(Path.Combine(target, "settings.txt")) == "fixture" && review.Files is not null && !File.Exists(review.Files.JournalPath),
                "A peer junction retargeted after preview stops apply before file dispatch even when raw inventory is unchanged");
        }
        finally
        {
            if (mapping.Length != 0 && !DefineDosDevice(15, mapping, mappedTarget)) throw new IOException("Could not remove own DOS mapping.");
            foreach (var link in links.AsEnumerable().Reverse())
                try { Directory.Delete(link); } catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { }
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Alias ownership checks remove their mappings, links, ACLs and fixtures");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint QueryDosDevice(string name, StringBuilder target, uint length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool DefineDosDevice(uint flags, string name, string target);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool GetVolumeNameForVolumeMountPoint(string mount, StringBuilder name, uint length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetShortPathName(string path, StringBuilder name, uint length);
    [DllImport("kernel32.dll", EntryPoint = "SetFileShortNameW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetFileShortName(SafeFileHandle file, string name);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
