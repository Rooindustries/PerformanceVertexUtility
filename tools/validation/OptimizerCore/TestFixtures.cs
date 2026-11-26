using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

static class TestFixtures
{
    public const string VolumeFile = "roo-industries-fixture.vhdx";
    private static readonly Dictionary<string, FileStream> Runs = new(StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> Volumes = new(StringComparer.OrdinalIgnoreCase);

    public static string InheritingRoot(string label)
    {
        Sweep(label);
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-" + label + "-" + Guid.NewGuid().ToString("N"));
        var lockPath = root + ".run";
        var run = new FileStream(lockPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
        lock (Runs) Runs[root] = run;
        var directory = Directory.CreateDirectory(root);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), WindowsIdentity.GetCurrent().User! })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(security);
        return root;
    }

    public static (string Mount, string Name) Volume(string root)
    {
        var mount = Directory.CreateDirectory(Path.Combine(root, "volume")).FullName;
        var file = Path.Combine(root, VolumeFile);
        DiskPart(root, true,
            "create vdisk file=\"" + file + "\" maximum=16 type=expandable",
            "select vdisk file=\"" + file + "\"",
            "attach vdisk",
            "create partition primary",
            "format fs=ntfs quick label=RooIndustries",
            "remove all noerr",
            "assign mount=\"" + mount + "\"");
        var name = new StringBuilder(64);
        if (!GetVolumeNameForVolumeMountPoint(mount + "\\", name, (uint)name.Capacity)) throw new Win32Exception();
        lock (Volumes) Volumes.Add(name.ToString());
        return (mount, name.ToString());
    }

    public static void Junction(string path, string target)
    {
        Contain(path, target);
        var substitute = Encoding.Unicode.GetBytes(@"\??\" + (target.StartsWith(@"\\?\", StringComparison.Ordinal) ? target[4..] : target));
        var print = Encoding.Unicode.GetBytes(target);
        var data = new byte[16 + substitute.Length + 2 + print.Length + 2];
        BitConverter.GetBytes(0xA0000003u).CopyTo(data, 0);
        BitConverter.GetBytes(checked((ushort)(data.Length - 8))).CopyTo(data, 4);
        BitConverter.GetBytes(checked((ushort)substitute.Length)).CopyTo(data, 10);
        BitConverter.GetBytes(checked((ushort)(substitute.Length + 2))).CopyTo(data, 12);
        BitConverter.GetBytes(checked((ushort)print.Length)).CopyTo(data, 14);
        substitute.CopyTo(data, 16);
        print.CopyTo(data, 18 + substitute.Length);
        Directory.CreateDirectory(path);
        using var handle = CreateFile(path, 0x2, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid || !SetReparsePoint(handle, 0x900A4, data, (uint)data.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
            throw new IOException("Could not create the disposable junction: " + Marshal.GetLastWin32Error());
    }

    public static void Symlink(string path, string target)
    {
        Contain(path, target);
        Directory.CreateSymbolicLink(path, target);
    }

    public static string Map(string target)
    {
        Contain(target, target);
        for (var letter = 'Z'; letter >= 'I'; letter--)
        {
            var name = letter + ":";
            if (QueryDosDevice(name, new StringBuilder(32768), 32768) != 0 || Marshal.GetLastWin32Error() != 2) continue;
            if (!DefineDosDevice(9, name, @"\??\" + target)) throw new IOException("Could not create disposable DOS mapping.");
            return name;
        }
        throw new IOException("No unused drive letter for the disposable alias fixture.");
    }

    public static void Unmap(string name, string target)
    {
        if (!DefineDosDevice(15, name, @"\??\" + target)) throw new IOException("Could not remove own DOS mapping.");
    }

    public static void Contain(string path, string target)
    {
        var full = target.StartsWith(@"\??\", StringComparison.Ordinal) ? @"\\?\" + target[4..] : target;
        if (!Path.IsPathFullyQualified(full)) full = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))!, full));
        if (Unroutable(full)) return;
        var resolved = Resolve(full);
        lock (Volumes) if (Volumes.Any(volume => resolved.StartsWith(volume, StringComparison.OrdinalIgnoreCase))) return;
        var areas = new[] { Path.GetTempPath(), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) };
        foreach (var area in areas.Select(area => Resolve(area).TrimEnd('\\') + "\\"))
        {
            if (!resolved.StartsWith(area, StringComparison.OrdinalIgnoreCase)) continue;
            var fixture = resolved[area.Length..].Split('\\')[0];
            if (fixture.StartsWith("roo-industries-", StringComparison.Ordinal)) return;
            if (fixture.StartsWith("RooIndustriesDataFix-", StringComparison.Ordinal)) return;
        }
        var message = "A fixture link must stay inside its own fixture folder or disposable volume: ";
        throw new InvalidOperationException(message + path + " -> " + target);
    }

    private static bool Unroutable(string path)
    {
        if (!path.StartsWith(@"\\", StringComparison.Ordinal)) return false;
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal)) return false;
        if (!System.Net.IPAddress.TryParse(path[2..].Split('\\')[0], out var address)) return false;
        var bytes = address.GetAddressBytes();
        return bytes.Length == 4 && (bytes[0], bytes[1], bytes[2]) is (192, 0, 2) or (198, 51, 100) or (203, 0, 113);
    }

    private static string Resolve(string path)
    {
        var root = Regex.Match(path, @"^(?:\\\\\?\\(?:GLOBALROOT\\Device\\[^\\]+|Volume\{[0-9A-Fa-f-]+\}|[A-Za-z]:)|[A-Za-z]:)\\").Value;
        if (root.Length == 0) throw new InvalidOperationException("A fixture link target must be a local path: " + path);
        var probe = root;
        foreach (var part in path[root.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part is "." or "..") throw new InvalidOperationException("A fixture link target must not step out of a folder: " + path);
            var next = probe.EndsWith('\\') ? probe + part : probe + "\\" + part;
            var attributes = GetFileAttributes(next);
            if (attributes == uint.MaxValue || (attributes & 0x400) != 0) break;
            probe = next;
        }
        using var handle = CreateFile(probe, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        var name = new StringBuilder(32768);
        if (handle.IsInvalid || GetFinalPathNameByHandle(handle, name, (uint)name.Capacity, 1) == 0) throw new Win32Exception();
        return name.ToString().TrimEnd('\\') + "\\";
    }

    public static void Remove(string root)
    {
        FileStream? run;
        lock (Runs) Runs.Remove(root, out run);
        try
        {
            if (Directory.Exists(root))
            {
                var (links, volumes) = Scan(root);
                foreach (var link in links) Unlink(link);
                foreach (var volume in volumes) DiskPart(root, false, "select vdisk file=\"" + volume + "\" noerr", "detach vdisk noerr");
                Directory.Delete(root, true);
            }
            if (Path.Exists(root)) throw new IOException("The fixture is still on disk after cleanup: " + root);
        }
        finally { run?.Dispose(); }
    }

    private static (List<string> Links, List<string> Volumes) Scan(string root)
    {
        var links = new List<string>();
        var volumes = new List<string>();
        var pending = new Stack<string>([root]);
        while (pending.TryPop(out var folder))
        {
            Unlock(folder);
            var listing = new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false };
            foreach (var entry in new DirectoryInfo(folder).EnumerateFileSystemInfos("*", listing))
            {
                if (entry is DirectoryInfo && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    pending.Push(entry.FullName);
                    continue;
                }
                Unlock(entry.FullName);
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) links.Add(entry.FullName);
                else if (entry.Name.Equals(VolumeFile, StringComparison.OrdinalIgnoreCase)) volumes.Add(entry.FullName);
            }
        }
        return (links, volumes);
    }

    private static void Unlock(string path)
    {
        using var handle = CreateFile(path, 0x60000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) return;
        GetKernelObjectSecurity(handle, 4, null, 0, out var size);
        var bytes = new byte[size];
        if (!GetKernelObjectSecurity(handle, 4, bytes, size, out _)) throw new Win32Exception();
        var descriptor = new RawSecurityDescriptor(bytes, 0);
        var user = WindowsIdentity.GetCurrent().User!;
        var acl = descriptor.DiscretionaryAcl;
        if (acl is null) return;
        var denied = Enumerable.Range(0, acl.Count)
            .Where(index => acl[index] is CommonAce { AceQualifier: AceQualifier.AccessDenied } ace && ace.SecurityIdentifier == user)
            .Reverse().ToArray();
        if (denied.Length == 0) return;
        foreach (var index in denied) acl.RemoveAce(index);
        var result = new byte[descriptor.BinaryLength];
        descriptor.GetBinaryForm(result, 0);
        if (!SetKernelObjectSecurity(handle, 4, result)) throw new Win32Exception();
    }

    private static void Unlink(string link)
    {
        try
        {
            if (!Directory.Exists(link)) File.Delete(link);
            else if (!DeleteVolumeMountPoint(link + "\\") || Directory.Exists(link)) Directory.Delete(link);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            var message = "A fixture link could not be removed, so cleanup stopped before deleting anything behind it: ";
            throw new IOException(message + link, error);
        }
        if (File.Exists(link) || Directory.Exists(link))
            throw new IOException("A fixture link is still on disk after cleanup: " + link);
    }

    private static void Sweep(string label)
    {
        var name = new Regex("^roo-industries-" + Regex.Escape(label) + "-[0-9a-f]{32}$");
        foreach (var stale in Directory.GetDirectories(Path.GetTempPath(), "roo-industries-" + label + "-*"))
        {
            if (!name.IsMatch(Path.GetFileName(stale))) continue;
            FileStream held;
            try { held = new FileStream(stale + ".run", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose); }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { continue; }
            lock (Runs) Runs[stale] = held;
            Remove(stale);
        }
    }

    private static void DiskPart(string root, bool check, params string[] commands)
    {
        var script = Path.Combine(root, "diskpart-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllLines(script, commands);
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "diskpart.exe")) { UseShellExecute = false };
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.ArgumentList.Add("/s");
        start.ArgumentList.Add(script);
        try
        {
            using var diskpart = Process.Start(start)!;
            var output = diskpart.StandardOutput.ReadToEndAsync();
            if (!diskpart.WaitForExit(120000))
            {
                diskpart.Kill();
                throw new IOException("diskpart did not finish within two minutes.");
            }
            if (check && diskpart.ExitCode != 0)
                throw new IOException("diskpart could not manage the disposable fixture volume: " + output.Result);
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 740)
        {
            var message = "The disposable fixture volume needs an administrator; run the suite elevated.";
            throw new InvalidOperationException(message, error);
        }
        finally { File.Delete(script); }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeNameForVolumeMountPoint(string mount, StringBuilder name, uint length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteVolumeMountPoint(string mount);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint QueryDosDevice(string name, StringBuilder target, uint length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DefineDosDevice(uint flags, string name, string target);
    [DllImport("kernel32.dll", EntryPoint = "GetFileAttributesW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributes(string path);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder name, uint length, uint flags);
    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    private static extern bool SetReparsePoint(SafeFileHandle handle, uint control, byte[] input, uint inputLength, IntPtr output, uint outputLength, out uint returned, IntPtr overlapped);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[]? descriptor, uint length, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[] descriptor);
}

sealed class OwnedRegistryKey : IDisposable
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyEx(SafeRegistryHandle key, string subKey, int reserved, string? className, int options, int access, IntPtr security, out IntPtr result, out int disposition);
    private readonly RegistryKey hive;
    private readonly string path;
    private readonly List<string> created = [];

    private OwnedRegistryKey(RegistryKey hive, string path) { this.hive = hive; this.path = path; }

    public static OwnedRegistryKey Create(RegistryKey hive, string path)
    {
        var owned = new OwnedRegistryKey(hive, path);
        var prefix = "";
        foreach (var part in path.Split('\\'))
        {
            prefix = prefix.Length == 0 ? part : prefix + "\\" + part;
            var status = RegCreateKeyEx(hive.Handle, prefix, 0, null, 0, 0x20019 | (int)hive.View, IntPtr.Zero, out var handle, out var disposition);
            if (status != 0) { owned.Dispose(); throw new Win32Exception(status); }
            new SafeRegistryHandle(handle, true).Dispose();
            if (disposition == 1) owned.created.Add(prefix);
        }
        if (owned.created.LastOrDefault() != path) { owned.Dispose(); throw new InvalidDataException("The fixture registry key already exists; it will not be reused: " + path); }
        return owned;
    }

    public void Dispose()
    {
        for (var index = created.Count - 1; index >= 0; index--)
        {
            if (created[index] == path) { hive.DeleteSubKeyTree(path, false); continue; }
            using (var key = hive.OpenSubKey(created[index]))
                if (key is not null && (key.SubKeyCount != 0 || key.ValueCount != 0)) break;
            hive.DeleteSubKey(created[index], false);
        }
        created.Clear();
    }
}
