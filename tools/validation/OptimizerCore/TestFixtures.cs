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
    private const string Mark = ":roo-industries-fixture";
    private static readonly Dictionary<string, SafeFileHandle> Runs = new(StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> Owned = new(StringComparer.OrdinalIgnoreCase);

    public static string InheritingRoot(string label)
    {
        Sweep(label);
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-" + label + "-" + Guid.NewGuid().ToString("N"));
        var run = Lock(root + ".run", 1) ?? throw new IOException("The fixture lock is already held: " + root);
        lock (Runs) Runs[root] = run;
        var directory = new DirectoryInfo(Own(root));
        using (var mark = CreateFile(root + Mark, 0x40000000, 0, IntPtr.Zero, 1, 0x00200000, IntPtr.Zero))
        {
            if (mark.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), root);
            using var stream = new FileStream(mark, FileAccess.Write);
            stream.Write(Encoding.UTF8.GetBytes(Path.GetFileName(root)));
        }
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), WindowsIdentity.GetCurrent().User! })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(security);
        return root;
    }

    public static void Abandon(string root)
    {
        lock (Runs) if (Runs.Remove(root, out var run)) run.Dispose();
    }

    public static string Own(string path)
    {
        if (Path.Exists(path)) throw new IOException("A fixture folder must be new: " + path);
        Directory.CreateDirectory(path);
        using var handle = Open(path, 0, false);
        lock (Owned) Owned.Add(Name(handle, 1));
        return path;
    }

    public static (string Mount, string Name) Volume(string root, bool own = true)
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
        if (own) lock (Owned) Owned.Add(name.ToString());
        return (mount, name.ToString());
    }

    public static void Junction(string path, string target)
    {
        Before(path, target);
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
        using (var handle = CreateFile(path, 0x2, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        {
            if (handle.IsInvalid || !SetReparsePoint(handle, 0x900A4, data, (uint)data.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
                throw new IOException("Could not create the disposable junction: " + Marshal.GetLastWin32Error());
        }
        Verify(path);
    }

    public static void Symlink(string path, string target, bool file = false)
    {
        Before(path, target);
        if (file) File.CreateSymbolicLink(path, target);
        else Directory.CreateSymbolicLink(path, target);
        Verify(path);
    }

    public static string Map(string target)
    {
        var network = Land(Path.GetFullPath(target));
        for (var letter = 'Z'; letter >= 'I'; letter--)
        {
            var name = letter + ":";
            if (QueryDosDevice(name, new StringBuilder(32768), 32768) != 0 || Marshal.GetLastWin32Error() != 2) continue;
            if (!DefineDosDevice(9, name, @"\??\" + target)) throw new IOException("Could not create disposable DOS mapping.");
            try
            {
                if (!network) Through(name + "\\");
            }
            catch
            {
                Unmap(name, target);
                throw;
            }
            return name;
        }
        throw new IOException("No unused drive letter for the disposable alias fixture.");
    }

    public static void Unmap(string name, string target)
    {
        if (!DefineDosDevice(15, name, @"\??\" + target)) throw new IOException("Could not remove own DOS mapping.");
    }

    private static void Before(string link, string target)
    {
        try
        {
            string parent;
            using (var handle = Open(Path.GetDirectoryName(Path.GetFullPath(link))!, 0, false)) parent = Name(handle, 0)[4..];
            Land(Path.IsPathFullyQualified(target) ? Native(target) : Path.GetFullPath(Path.Combine(parent, target)));
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or Win32Exception or ArgumentException)
        {
            var message = "A fixture link must land inside a folder this run made or its own disposable volume, so it was not created: ";
            throw new InvalidOperationException(message + link, error);
        }
    }

    public static void Verify(string link)
    {
        try
        {
            string target;
            bool relative;
            string location;
            string self;
            using (var handle = Open(link, 0x80, true))
            {
                (target, relative) = Stored(handle);
                location = Name(handle, 0);
                self = Name(handle, 1);
            }
            if (Unroutable(target)) return;
            var full = relative ? Path.GetFullPath(Path.Combine(Path.GetDirectoryName(location[4..])!, target)) : Native(target);
            if (!Land(full, self)) Through(link);
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or Win32Exception or ArgumentException)
        {
            Unlink(link);
            var message = "A fixture link must land inside a folder this run made or its own disposable volume, so it was removed: ";
            throw new InvalidOperationException(message + link, error);
        }
    }

    private static bool Land(string path, string? self = null)
    {
        if (Unroutable(path)) return true;
        var root = Regex.Match(path, @"^(?:\\\\\?\\(?:GLOBALROOT\\Device\\[^\\]+|Volume\{[0-9A-Fa-f-]+\}|[A-Za-z]:)|[A-Za-z]:)\\").Value;
        if (root.Length == 0) throw new InvalidOperationException("A fixture link target must be a local path: " + path);
        var probe = root;
        foreach (var part in path[root.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part is "." or "..") throw new InvalidOperationException("A fixture link target must not step out of a folder: " + path);
            var next = probe.EndsWith('\\') ? probe + part : probe + "\\" + part;
            var attributes = GetFileAttributes(next);
            if (attributes == uint.MaxValue) break;
            if ((attributes & 0x400) != 0)
            {
                using (var link = Open(next, 0x80, true))
                {
                    if (self is not null && Name(link, 1) == self && Inside(self)) return true;
                    if (Unroutable(Stored(link).Target)) return true;
                }
                using var through = CreateFile(next, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
                if (through.IsInvalid || !Toward(Name(through, 1)))
                    throw new InvalidOperationException("A fixture link target passes through a link that leads away from this run's folders: " + next);
                probe = Name(through, 1);
                continue;
            }
            probe = next;
        }
        using var handle = Open(probe, 0, false);
        if (!Inside(Name(handle, 1))) throw new InvalidOperationException("A fixture link target lands outside: " + path);
        return false;
    }

    private static void Through(string path)
    {
        using var handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var code = Marshal.GetLastWin32Error();
            if (code is 2 or 3) return;
            throw new Win32Exception(code);
        }
        if (!Inside(Name(handle, 1))) throw new InvalidOperationException("Opening through the link lands outside: " + path);
    }

    private static bool Toward(string final)
    {
        final = final.TrimEnd('\\') + "\\";
        lock (Owned) return Inside(final) || Owned.Any(own => (own.TrimEnd('\\') + "\\").StartsWith(final, StringComparison.OrdinalIgnoreCase));
    }

    public static bool Alone(string path)
    {
        using var handle = Open(path, 0x80, true);
        return Alone(handle);
    }

    private static bool Alone(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var information)) throw new Win32Exception();
        return (information.Attributes & 0x400) == 0 && information.Links <= 1;
    }

    public static void HardLink(string path, string existing)
    {
        FileInformation shared;
        using (var handle = Open(existing, 0, false))
        {
            if (!Inside(Name(handle, 1)) || !GetFileInformationByHandle(handle, out shared))
                throw new InvalidOperationException("A fixture hard link must share a file this run made: " + existing);
        }
        using (var parent = Open(Path.GetDirectoryName(Path.GetFullPath(path))!, 0, false))
        {
            if (!Inside(Name(parent, 1))) throw new InvalidOperationException("A fixture hard link must be made inside a folder this run made: " + path);
        }
        if (!CreateHardLink(path, existing, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        bool same, inside;
        using (var created = Open(path, 0, true))
        {
            same = GetFileInformationByHandle(created, out var made) && (made.Volume, made.IndexHigh, made.IndexLow) == (shared.Volume, shared.IndexHigh, shared.IndexLow);
            inside = Inside(Name(created, 1));
        }
        if (same && inside) return;
        if (same) File.Delete(path);
        throw new InvalidOperationException("A fixture hard link must be made inside a folder this run made, so it was removed: " + path);
    }

    private static bool Inside(string final)
    {
        final = final.TrimEnd('\\') + "\\";
        lock (Owned) return Owned.Any(own => final.StartsWith(own.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
    }

    private static string Native(string target)
    {
        if (target.StartsWith(@"\??\UNC\", StringComparison.Ordinal)) return @"\\" + target[8..];
        return target.StartsWith(@"\??\", StringComparison.Ordinal) ? @"\\?\" + target[4..] : target;
    }

    private static bool Unroutable(string path)
    {
        path = Native(path);
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path[8..];
        if (!path.StartsWith(@"\\", StringComparison.Ordinal)) return false;
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal)) return false;
        if (!System.Net.IPAddress.TryParse(path[2..].Split('\\')[0], out var address)) return false;
        var bytes = address.GetAddressBytes();
        return bytes.Length == 4 && (bytes[0], bytes[1], bytes[2]) is (192, 0, 2) or (198, 51, 100) or (203, 0, 113);
    }

    private static (string Target, bool Relative) Stored(SafeFileHandle handle)
    {
        var data = new byte[16384];
        if (!GetReparsePoint(handle, 0x900A8, IntPtr.Zero, 0, data, (uint)data.Length, out var length, IntPtr.Zero) || length < 16)
            throw new Win32Exception();
        var tag = BitConverter.ToUInt32(data, 0);
        var start = tag switch { 0xA0000003 => 16, 0xA000000C => 20, _ => throw new InvalidOperationException("Not a junction or symbolic link.") };
        var relative = tag == 0xA000000C && (BitConverter.ToUInt32(data, 16) & 1) != 0;
        return (Encoding.Unicode.GetString(data, start + BitConverter.ToUInt16(data, 8), BitConverter.ToUInt16(data, 10)), relative);
    }

    private static SafeFileHandle Open(string path, uint access, bool reparse, uint share = 7)
    {
        var handle = CreateFile(path, access, share, IntPtr.Zero, 3, 0x02000000 | (reparse ? 0x00200000u : 0), IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        return handle;
    }

    private static string Name(SafeFileHandle handle, uint flags)
    {
        var name = new StringBuilder(32768);
        if (GetFinalPathNameByHandle(handle, name, (uint)name.Capacity, flags) == 0) throw new Win32Exception();
        return name.ToString();
    }

    private static SafeFileHandle? Lock(string path, uint disposition)
    {
        var handle = CreateFile(path, 0xC0010000, 0, IntPtr.Zero, disposition, 0x04200000, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var code = Marshal.GetLastWin32Error();
        if (code == 32) return null;
        throw new Win32Exception(code, path);
    }

    public static void Remove(string root)
    {
        SafeFileHandle? run;
        lock (Runs) Runs.Remove(root, out run);
        try
        {
            var attributes = GetFileAttributes(root);
            if (attributes != uint.MaxValue && (attributes & 0x400) != 0)
            {
                Unlink(root);
                Console.WriteLine("Removed a link named like a fixture without opening what it points to: " + root);
            }
            else if (attributes != uint.MaxValue)
            {
                var held = new List<SafeFileHandle>();
                try
                {
                    var (links, volumes) = Scan(@"\\?\" + Path.GetFullPath(root), held);
                    foreach (var link in links) Unlink(link);
                    foreach (var volume in volumes)
                    {
                        string real;
                        using (var handle = Open(volume, 0x80, true)) real = Name(handle, 0)[4..];
                        DiskPart(root, false, "select vdisk file=\"" + real + "\" noerr", "detach vdisk noerr");
                    }
                }
                finally { held.ForEach(handle => handle.Dispose()); }
                Directory.Delete(root, true);
            }
            if (Path.Exists(root)) throw new IOException("The fixture is still on disk after cleanup: " + root);
        }
        finally { run?.Dispose(); }
    }

    private static (List<string> Links, List<string> Volumes) Scan(string root, List<SafeFileHandle> held)
    {
        var links = new List<string>();
        var volumes = new List<string>();
        var top = Open(root, 0x81, true, 1);
        held.Add(top);
        var inside = Name(top, 1).TrimEnd('\\') + "\\";
        var pending = new Stack<string>([root]);
        while (pending.TryPop(out var folder))
        {
            Unlock(folder, inside);
            var handle = folder == root ? top : Open(folder, 0x81, true, 1);
            if (!(Name(handle, 1).TrimEnd('\\') + "\\").StartsWith(inside, StringComparison.OrdinalIgnoreCase))
            {
                if (handle != top) handle.Dispose();
                throw new IOException("A fixture folder is not inside the fixture it was listed in: " + folder);
            }
            if (!GetFileInformationByHandle(handle, out var information)) throw new Win32Exception();
            if ((information.Attributes & 0x400) != 0)
            {
                if (handle != top) handle.Dispose();
                links.Add(folder);
                continue;
            }
            if (handle != top) held.Add(handle);
            var listing = new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false };
            foreach (var entry in new DirectoryInfo(folder).EnumerateFileSystemInfos("*", listing))
            {
                if (entry is DirectoryInfo && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                {
                    pending.Push(entry.FullName);
                    continue;
                }
                Unlock(entry.FullName, inside);
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) links.Add(entry.FullName);
                else if (entry.Name.Equals(VolumeFile, StringComparison.OrdinalIgnoreCase))
                {
                    using var disk = Open(entry.FullName, 0x80, true);
                    if (Alone(disk)) volumes.Add(entry.FullName);
                    else Console.WriteLine("Left a fixture virtual disk attached because the file has another name: " + entry.FullName);
                }
            }
        }
        return (links, volumes);
    }

    private static void Unlock(string path, string inside)
    {
        using (var located = Open(path, 0, true))
        {
            if (!(Name(located, 1).TrimEnd('\\') + "\\").StartsWith(inside, StringComparison.OrdinalIgnoreCase))
                throw new IOException("A fixture entry is not inside the fixture folder it was listed in: " + path);
        }
        using var handle = CreateFile(path, 0x60000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) return;
        if (!(Name(handle, 1).TrimEnd('\\') + "\\").StartsWith(inside, StringComparison.OrdinalIgnoreCase))
            throw new IOException("A fixture entry is not inside the fixture folder it was listed in: " + path);
        if (!Directory.Exists(path) && !Alone(handle))
        {
            Console.WriteLine("Left the permissions of a fixture file that is a link or has another name unchanged: " + path);
            return;
        }
        GetKernelObjectSecurity(handle, 4, null, 0, out var size);
        var bytes = new byte[size];
        if (!GetKernelObjectSecurity(handle, 4, bytes, size, out _)) throw new Win32Exception();
        var descriptor = new RawSecurityDescriptor(bytes, 0);
        var user = WindowsIdentity.GetCurrent().User!;
        var acl = descriptor.DiscretionaryAcl;
        var denied = acl is null ? [] : Enumerable.Range(0, acl.Count)
            .Where(index => acl[index] is CommonAce { AceQualifier: AceQualifier.AccessDenied } ace && ace.SecurityIdentifier == user)
            .Reverse().ToArray();
        if (denied.Length > 0)
        {
            foreach (var index in denied) acl!.RemoveAce(index);
            var result = new byte[descriptor.BinaryLength];
            descriptor.GetBinaryForm(result, 0);
            if (!SetKernelObjectSecurity(handle, 4, result)) throw new Win32Exception();
        }
        using var writable = CreateFile(path, 0x180, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (writable.IsInvalid || !GetFileInformationByHandle(writable, out var information) || (information.Attributes & 1) == 0) return;
        if (!(Name(writable, 1).TrimEnd('\\') + "\\").StartsWith(inside, StringComparison.OrdinalIgnoreCase))
            throw new IOException("A fixture entry is not inside the fixture folder it was listed in: " + path);
        var basic = new byte[40];
        BitConverter.GetBytes((information.Attributes & ~1u) == 0 ? 0x80u : information.Attributes & ~1u).CopyTo(basic, 32);
        if (!SetFileInformationByHandle(writable, 0, basic, (uint)basic.Length)) throw new Win32Exception();
    }

    private static void Unlink(string link)
    {
        var plain = link.StartsWith(@"\\?\", StringComparison.Ordinal) && !link.StartsWith(@"\\?\UNC\", StringComparison.Ordinal) ? link[4..] : link;
        try
        {
            string? volume = null;
            if (Directory.Exists(link))
            {
                using var handle = Open(link, 0x80, true);
                var target = Stored(handle).Target;
                if (Regex.IsMatch(target, @"^\\\?\?\\Volume\{[0-9A-Fa-f-]+\}\\?$")) volume = @"\\?\" + target[4..].TrimEnd('\\') + "\\";
            }
            if (volume is not null && Mounted(volume, plain))
            {
                if (!DeleteVolumeMountPoint(plain.TrimEnd('\\') + "\\")) throw new Win32Exception(Marshal.GetLastWin32Error(), "The volume mount point could not be removed: " + plain);
                if (Mounted(volume, plain)) throw new IOException("The volume still lists a mount path in the fixture: " + plain);
            }
            if (Directory.Exists(link)) Directory.Delete(link);
            else File.Delete(link);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Win32Exception or InvalidOperationException)
        {
            var message = "A fixture link could not be removed, so cleanup stopped before deleting anything behind it: ";
            throw new IOException(message + link, error);
        }
        if (File.Exists(link) || Directory.Exists(link))
            throw new IOException("A fixture link is still on disk after cleanup: " + link);
    }

    private static bool Mounted(string volume, string path)
    {
        var names = new char[32768];
        if (!GetVolumePathNamesForVolumeName(volume, names, (uint)names.Length, out _))
        {
            var code = Marshal.GetLastWin32Error();
            if (code is 2 or 3 or 87 or 1168) return false;
            throw new Win32Exception(code, volume);
        }
        var wanted = path.TrimEnd('\\') + "\\";
        return new string(names).Split('\0', StringSplitOptions.RemoveEmptyEntries).Any(name => name.Equals(wanted, StringComparison.OrdinalIgnoreCase));
    }

    private static void Sweep(string label)
    {
        var name = new Regex("^roo-industries-" + Regex.Escape(label) + "-[0-9a-f]{32}$");
        foreach (var stale in Directory.GetDirectories(Path.GetTempPath(), "roo-industries-" + label + "-*"))
        {
            if (!name.IsMatch(Path.GetFileName(stale))) continue;
            if (!Marked(stale))
            {
                Console.WriteLine("Left a folder named like a fixture that this suite did not make: " + stale);
                continue;
            }
            var held = Lock(stale + ".run", 4);
            if (held is null) continue;
            lock (Runs) Runs[stale] = held;
            try { Remove(stale); }
            catch (IOException error) { Console.WriteLine("Left a stale fixture whose cleanup stopped: " + stale + ": " + error.Message); }
        }
    }

    private static bool Marked(string folder)
    {
        var attributes = GetFileAttributes(folder);
        if (attributes == uint.MaxValue || (attributes & 0x410) != 0x10) return false;
        using var mark = CreateFile(folder + Mark, 0x80000000, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (mark.IsInvalid) return false;
        using var stream = new FileStream(mark, FileAccess.Read);
        var buffer = new byte[256];
        return Encoding.UTF8.GetString(buffer, 0, stream.Read(buffer)) == Path.GetFileName(folder);
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
    [DllImport("kernel32.dll", EntryPoint = "GetVolumePathNamesForVolumeNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumePathNamesForVolumeName(string volume, char[] names, uint length, out uint returned);
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
    [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
    private static extern bool GetReparsePoint(SafeFileHandle handle, uint control, IntPtr input, uint inputLength, byte[] output, uint outputLength, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string path, string existing, IntPtr security);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[]? descriptor, uint length, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[] descriptor);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int information, byte[] value, uint length);
}

[StructLayout(LayoutKind.Sequential)]
struct FileInformation
{
    public uint Attributes, CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
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
