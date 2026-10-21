using System.ComponentModel;
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
        if (peerPath == "parent-handle-rename") { ParentRenameProbe(root); return; }
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
        using var result = JsonDocument.Parse(ProbeOutput(check, root, peer, name));
        var value = result.RootElement;
        Console.WriteLine("MEASURE aliasOwnership " + JsonSerializer.Serialize(new { Scenario = name, Result = value }));
        check(value.GetProperty("PreviewRefused").GetBoolean() && value.GetProperty("Preserved").GetBoolean() &&
            (shared ? value.GetProperty("SharedOwners").EnumerateArray().Any(owner => owner.GetString() == "Independent alias tool") : !value.GetProperty("OwnershipComplete").GetBoolean()),
            name + (shared ? " retains its shared owner and refuses cleanup preview" : " stays unknown and refuses cleanup preview"));
    }

    private static string ProbeOutput(Action<bool, string> check, string root, string peer, string name)
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
        return text;
    }

    private static void ParentRenameProbe(string root)
    {
        var parent = Path.Combine(root, "moving-parent");
        var moved = Path.Combine(root, "moved-parent");
        Directory.CreateDirectory(Path.Combine(parent, "leaf"));
        var renamed = false; var linked = false;
        try
        {
            using var handle = CreateFile(parent, 0x100081, 7, IntPtr.Zero, 3, 0x02300000, IntPtr.Zero);
            if (handle.IsInvalid) throw new IOException("Could not open the disposable parent.");
            Directory.Move(parent, moved); renamed = true;
            Directory.CreateSymbolicLink(parent, @"\\192.0.2.139\AliasOwnershipFixture"); linked = true;
            var method = typeof(FileLease).GetMethod("OpenMetadataChild", BindingFlags.Static | BindingFlags.NonPublic)!;
            using var child = (SafeFileHandle)method.Invoke(null, [handle, "leaf"])!;
            var name = new StringBuilder(32768);
            var length = GetFinalPathNameByHandle(child, name, (uint)name.Capacity, 0);
            var enumerate = typeof(FileLease).GetMethod("DirectoryEntries", BindingFlags.Static | BindingFlags.NonPublic)!;
            var entries = ((ValueTuple<string, FileAttributes>[])enumerate.Invoke(null, [handle])!);
            Console.WriteLine(JsonSerializer.Serialize(new { Preserved = length > 0 && length < name.Capacity && string.Equals(name.ToString(), @"\\?\" + Path.Combine(moved, "leaf"), StringComparison.OrdinalIgnoreCase) && entries.Any(entry => entry.Item1 == "leaf" && entry.Item2.HasFlag(FileAttributes.Directory)) }));
        }
        finally
        {
            if (linked) Directory.Delete(parent);
            else if (!renamed) Directory.Delete(parent, true);
            if (renamed) Directory.Delete(moved, true);
        }
    }

    private static void CaptureReparse(string path)
    {
        using var handle = CreateFile(path, 0x100080, 7, IntPtr.Zero, 3, 0x02300000, IntPtr.Zero);
        var bytes = new byte[16384];
        if (handle.IsInvalid || !DeviceIoControl(handle, 0x900A8, IntPtr.Zero, 0, bytes, (uint)bytes.Length, out var length, IntPtr.Zero) || length < 16) throw new IOException("Could not capture the disposable reparse response.");
        Console.WriteLine("MEASURE reparseResponse " + JsonSerializer.Serialize(new { ReparseTag = BitConverter.ToUInt32(bytes), ReparseDataLength = BitConverter.ToUInt16(bytes, 4), Reserved = BitConverter.ToUInt16(bytes, 6), SubstituteNameOffset = BitConverter.ToUInt16(bytes, 8), SubstituteNameLength = BitConverter.ToUInt16(bytes, 10), PrintNameOffset = BitConverter.ToUInt16(bytes, 12), PrintNameLength = BitConverter.ToUInt16(bytes, 14), Flags = BitConverter.ToUInt32(bytes) == 0xA000000C ? (uint?)BitConverter.ToUInt32(bytes, 16) : null, RawBase64 = Convert.ToBase64String(bytes, 0, (int)length) }));
    }

    internal static void Junction(string path, string target)
    {
        var substitute = Encoding.Unicode.GetBytes(@"\??\" + (target.StartsWith(@"\\?\", StringComparison.Ordinal) ? target[4..] : target));
        var print = Encoding.Unicode.GetBytes(target);
        var data = new byte[16 + substitute.Length + 2 + print.Length + 2];
        BitConverter.GetBytes(0xA0000003u).CopyTo(data, 0);
        BitConverter.GetBytes(checked((ushort)(data.Length - 8))).CopyTo(data, 4);
        BitConverter.GetBytes(checked((ushort)substitute.Length)).CopyTo(data, 10);
        BitConverter.GetBytes(checked((ushort)(substitute.Length + 2))).CopyTo(data, 12);
        BitConverter.GetBytes(checked((ushort)print.Length)).CopyTo(data, 14);
        substitute.CopyTo(data, 16); print.CopyTo(data, 18 + substitute.Length);
        Directory.CreateDirectory(path);
        using var handle = CreateFile(path, 0x2, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid || !SetReparsePoint(handle, 0x900A4, data, (uint)data.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
            throw new IOException("Could not create the disposable junction: " + Marshal.GetLastWin32Error());
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

            var scanAlias = Path.Combine(root, "scan-alias");
            links.Add(scanAlias); Junction(scanAlias, root);
            var scanned = new CleanupApplication { AppId = "fixture:scan-alias", DisplayName = "Roo Industries Example", Publisher = "Fixture", InstallLocation = Path.Combine(scanAlias, "Roo Industries Example"), PackageFamilyName = null };
            var scan = new LeftoverDiscovery(scanned, []).Scan(CancellationToken.None, [scanAlias], []);
            check(scan.Complete && scan.Candidates.Length == 1 && scan.Candidates[0].Target == scanned.InstallLocation,
                "A junctioned scan root preserves lexical candidate identity and avoids duplicate rows");

            var relative = Path.Combine(root, "relative-alias");
            links.Add(relative); Directory.CreateSymbolicLink(relative, Path.GetRelativePath(root, target));
            CaptureReparse(relative);
            CheckPeer(check, root, relative, "relative-symlink-alias", true);
            CheckPeer(check, root, Path.Combine(relative, "missing-child"), "missing-folder-through-alias", false);
            using (var renamed = JsonDocument.Parse(ProbeOutput(check, root, "parent-handle-rename", "renamed-parent-open")))
                check(renamed.RootElement.GetProperty("Preserved").GetBoolean(), "An opened parent keeps child lookup and directory enumeration local after its old path becomes an offline network link");

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
            var device = new StringBuilder(32768);
            check(QueryDosDevice(root[..2], device, (uint)device.Capacity) != 0, "Local fixture volume has a native DOS-device mapping");
            var namespaced = Path.Combine(root, "namespace-alias");
            links.Add(namespaced); Junction(namespaced, @"\\?\GLOBALROOT" + device + target[2..]);
            CaptureReparse(namespaced);
            check(File.ReadAllText(Path.Combine(namespaced, "settings.txt")) == "fixture", "A GLOBALROOT alias actually reaches the disposable shared folder");
            CheckPeer(check, root, namespaced, "non-dos-namespace-alias", false);
            CheckPeer(check, root, @"\\localhost\" + root[0] + "$" + target[2..], "uninspected-loopback-share", false);
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

            var opaque = Directory.CreateDirectory(Path.Combine(root, "opaque-peer"));
            var unreadable = Directory.CreateDirectory(Path.Combine(opaque.FullName, "unreadable-peer"));
            var hidden = Path.Combine(unreadable.FullName, "alias");
            links.Add(hidden); Junction(hidden, target);
            var opaqueSecurity = opaque.GetAccessControl();
            var opaqueDenied = opaque.GetAccessControl();
            opaqueDenied.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.ListDirectory | FileSystemRights.Traverse, AccessControlType.Deny));
            var security = unreadable.GetAccessControl();
            var denied = unreadable.GetAccessControl();
            denied.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.ReadAttributes | FileSystemRights.ListDirectory, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Deny));
            using var opaqueHandle = CreateFile(opaque.FullName, 0x100080, 7, IntPtr.Zero, 3, 0x02300000, IntPtr.Zero);
            check(!opaqueHandle.IsInvalid, "Permission fixture retains its disposable parent metadata handle");
            try
            {
                unreadable.SetAccessControl(denied);
                opaque.SetAccessControl(opaqueDenied);
                PrivilegeChecks.WithoutPrivileges(() =>
                {
                    var method = typeof(FileLease).GetMethod("OpenMetadataChild", BindingFlags.Static | BindingFlags.NonPublic)!;
                    var deniedOpen = false;
                    try { using var opened = (SafeFileHandle)method.Invoke(null, [opaqueHandle, unreadable.Name])!; }
                    catch (TargetInvocationException error) when (error.InnerException is Win32Exception { NativeErrorCode: 5 }) { deniedOpen = true; }
                    check(deniedOpen, "The resolver's actual parent-relative metadata open refuses the unreadable ancestor");
                    CheckPeer(check, root, hidden, "unreadable-ancestor", false);
                }, "SeBackupPrivilege", "SeRestorePrivilege");
            }
            finally { opaque.SetAccessControl(opaqueSecurity); unreadable.SetAccessControl(security); }

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
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder name, uint length, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DeviceIoControl(SafeFileHandle handle, uint control, IntPtr input, uint inputLength, byte[] output, uint outputLength, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)] private static extern bool SetReparsePoint(SafeFileHandle handle, uint control, byte[] input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);
}
