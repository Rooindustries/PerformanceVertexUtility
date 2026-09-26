#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public sealed class FileLease : IDisposable
{
    private const uint ReadData = 1, ReadAttributes = 0x80, WriteAttributes = 0x100, Delete = 0x10000,
        ReadControl = 0x20000, WriteDacl = 0x40000, WriteOwner = 0x80000, Synchronize = 0x100000;
    private readonly List<SafeFileHandle> _ancestors = new();
    private readonly Dictionary<string, SafeFileHandle> _streams = new(StringComparer.OrdinalIgnoreCase);
    private readonly SafeFileHandle _handle;
    private readonly bool _writable;
    public string Path { get; }

    private FileLease(string path, bool writable, bool create, bool directory, bool restore, bool shareDelete = false, bool policy = false, bool content = false, bool owner = false)
    {
        Path = NormalizePath(path);
        _writable = writable;
        try
        {
            var root = System.IO.Path.GetPathRoot(Path)!;
            if (GetDriveType(root) == 4) throw new InvalidDataException("Network drives are outside this file recovery contract.");
            var parent = CreateFile("\\\\?\\" + root, ReadData | ReadAttributes | Synchronize, shareDelete ? 7u : 3u, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (parent.IsInvalid) { parent.Dispose(); Fail("CreateFile(root)"); }
            _ancestors.Add(parent);
            var parts = Path[root.Length..].Split('\\');
            for (var index = 0; index < parts.Length; index++)
            {
                var final = index == parts.Length - 1;
                var access = ReadData | ReadAttributes | Synchronize;
                if (final) access |= ReadControl | (writable ? Delete : 0);
                if (final && restore) access |= (create ? 2u : 0u) | WriteAttributes | WriteDacl | WriteOwner;
                if (final && policy) access = ReadAttributes | ReadControl | Synchronize | (writable ? WriteDacl : 0);
                if (final && owner) access |= WriteOwner;
                if (final && content) access = ReadData | ReadAttributes | ReadControl | Synchronize | (writable ? 2u | WriteAttributes : 0u);
                var handle = OpenRelative(parent, parts[index], access, shareDelete ? 7u : final ? 1u : 3u, final && create ? 2u : 1u,
                    0x00200020 | (policy || final && restore ? 0x4000u : 0u) | (final && create ? directory ? 1u : 0x40u : 0u));
                try { RequireOrdinary(handle); } catch { handle.Dispose(); throw; }
                if (final) { _handle = handle; return; }
                if ((Basic(handle).FileAttributes & 0x10) == 0) { handle.Dispose(); throw new InvalidDataException("A file replaced a path ancestor."); }
                _ancestors.Add(handle);
                parent = handle;
            }
            throw new InvalidDataException("A volume root cannot be a cleanup target.");
        }
        catch { foreach (var handle in _ancestors.AsEnumerable().Reverse()) handle.Dispose(); throw; }
    }

    public static FileLease Open(string path, bool writable = false) => new(path, writable, false, false, false);
    public static FileLease Create(string path, bool directory) => new(path, true, true, directory, true);
    public static FileLease OpenForRestore(string path) => new(path, true, false, false, true);
    public static FileLease OpenPolicy(string path, bool writable = false, bool owner = false) => new(path, writable, false, false, false, policy: true, owner: owner);
    public void SetOwner(byte[] sid)
    {
        if (!_writable) throw new InvalidOperationException("A detection handle cannot change ownership.");
        var pin = GCHandle.Alloc(sid, GCHandleType.Pinned);
        try
        {
            var status = SetSecurityInfo(_handle, 1, 1, pin.AddrOfPinnedObject(), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (status != 0) throw new Win32Exception((int)status, "SetSecurityInfo(owner) failed: " + status);
        }
        finally { pin.Free(); }
    }
    public static FileLease OpenContent(string path, bool writable = false) => new(path, writable, false, false, false, content: true);
    public byte[] ReadContent()
    {
        var size = Standard(_handle);
        if (size.Directory || size.EndOfFile > 262144) throw new InvalidDataException("This file control requires a regular file no larger than 256 KiB.");
        using var borrowed = new SafeFileHandle(_handle.DangerousGetHandle(), ownsHandle: false);
        using var input = new FileStream(borrowed, FileAccess.Read);
        input.Position = 0;
        var data = new byte[checked((int)size.EndOfFile)]; input.ReadExactly(data); return data;
    }
    public void WriteContent(byte[] data)
    {
        if (!_writable || data.Length > 262144) throw new InvalidDataException("A reviewed writable file of at most 256 KiB is required.");
        var attributes = Basic(_handle).FileAttributes;
        using var borrowed = new SafeFileHandle(_handle.DangerousGetHandle(), ownsHandle: false);
        using var output = new FileStream(borrowed, FileAccess.Write);
        output.Position = 0; output.Write(data); output.SetLength(data.Length); output.Flush(flushToDisk: true);
        if (Basic(_handle).FileAttributes != attributes)
        {
            var metadata = new FileBasicInfo { FileAttributes = attributes };
            if (!SetBasicInformation(_handle, 0, ref metadata, Marshal.SizeOf<FileBasicInfo>())) Fail("SetFileInformationByHandle(content attributes)");
        }
    }

    public (FileIdentity Identity, long CreationTime, byte[] Security, uint Attributes) ReadPolicy()
    {
        RequireOrdinary(_handle);
        if (!Standard(_handle).Directory && Standard(_handle).NumberOfLinks != 1) throw new InvalidDataException("Hard-linked file permissions require a separate review.");
        var basic = Basic(_handle);
        return (Identity(_handle), basic.CreationTime, ReadSecurity(_handle), basic.FileAttributes);
    }
    public void SetDacl(byte[] dacl)
    {
        if (!_writable) throw new InvalidOperationException("A detection handle cannot change permissions.");
        var pin = GCHandle.Alloc(dacl, GCHandleType.Pinned);
        try
        {
            var status = SetSecurityInfo(_handle, 1, 4, IntPtr.Zero, IntPtr.Zero, pin.AddrOfPinnedObject(), IntPtr.Zero);
            if (status != 0) throw new Win32Exception((int)status, "SetSecurityInfo(DACL) failed: " + status);
        }
        finally { pin.Free(); }
    }

    public static string ResolveExclusionPath(string path)
    {
        if (!System.IO.Path.IsPathFullyQualified(path)) throw new InvalidDataException("An exclusion needs an absolute local path.");
        var full = NormalizePath(path);
        var current = full;
        while (current.Length > 3)
        {
            try
            {
                using var lease = new FileLease(current, false, false, false, false, shareDelete: true);
                return CanonicalName(lease._handle).TrimEnd('\\') + full[current.Length..];
            }
            catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { current = System.IO.Path.GetDirectoryName(current)!; }
        }
        using var root = CreateFile("\\\\?\\" + current, ReadAttributes | Synchronize, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (root.IsInvalid) Fail("CreateFile(exclusion volume)");
        return CanonicalName(root).TrimEnd('\\') + "\\" + full[3..];
    }

    public FileSnapshot Capture()
    {
        RequireOrdinary(_handle);
        var basic = Basic(_handle);
        var standard = Standard(_handle);
        if (!standard.Directory && standard.NumberOfLinks != 1) throw new InvalidDataException("Hard-linked files require a separate ownership review.");
        var canonical = CanonicalName(_handle);
        return new()
        {
            Path = Path, CanonicalPath = canonical, Identity = Identity(_handle), Directory = standard.Directory,
            Attributes = basic.FileAttributes, Links = standard.NumberOfLinks, Length = standard.Directory ? 0 : standard.EndOfFile,
            CreationTime = basic.CreationTime, LastWriteTime = basic.LastWriteTime, LastAccessTime = basic.LastAccessTime,
            Security = ReadSecurity(_handle), SecurityCoverage = 7, Streams = ReadStreams(canonical, standard.Directory),
        };
    }

    public string[] Children()
    {
        if (!Standard(_handle).Directory) return [];
        var names = new List<string>();
        const int capacity = 65536;
        var buffer = Marshal.AllocHGlobal(capacity);
        try
        {
            var restart = true;
            while (true)
            {
                if (!GetFileInformationByHandleEx(_handle, restart ? 20 : 19, buffer, capacity))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == 18) break;
                    throw new Win32Exception(error, "Directory-handle enumeration failed: " + error);
                }
                restart = false;
                var offset = 0;
                while (true)
                {
                    if (offset < 0 || offset > capacity - 88) throw new InvalidDataException("Invalid directory record boundary.");
                    var entry = buffer + offset;
                    var next = Marshal.ReadInt32(entry);
                    var length = Marshal.ReadInt32(entry, 60);
                    if (length < 0 || length % 2 != 0 || length > capacity - offset - 88) throw new InvalidDataException("Invalid directory filename length.");
                    var name = Marshal.PtrToStringUni(entry + 88, length / 2)!;
                    if (name is not ("." or ".."))
                    {
                        RequireComponent(name);
                        names.Add(System.IO.Path.Combine(Path, name));
                        if (names.Count > 100000) throw new InvalidDataException("Directory exceeds the cleanup enumeration limit.");
                    }
                    if (next == 0) break;
                    if (next < 88) throw new InvalidDataException("Invalid directory record offset.");
                    offset = checked(offset + next);
                }
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return names.Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public void Backup(string destination)
    {
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        var bytes = new byte[65536];
        IntPtr context = IntPtr.Zero;
        try
        {
            while (true)
            {
                if (!BackupRead(_handle, bytes, (uint)bytes.Length, out var read, false, false, ref context)) Fail("BackupRead");
                if (read == 0) break;
                output.Write(bytes, 0, (int)read);
            }
            output.Flush(flushToDisk: true);
        }
        finally { if (context != IntPtr.Zero) BackupRead(_handle, null, 0, out _, true, false, ref context); }
    }

    public void RestoreData(string backup, FileSnapshot original)
    {
        if (!_writable) throw new InvalidOperationException("A detection handle cannot restore files.");
        using var input = new FileStream(backup, FileMode.Open, FileAccess.Read, FileShare.Read);
        var bytes = new byte[65536];
        IntPtr context = IntPtr.Zero;
        try
        {
            int read;
            while ((read = input.Read(bytes, 0, bytes.Length)) > 0)
            {
                if (!BackupWrite(_handle, bytes, (uint)read, out var written, false, false, ref context)) Fail("BackupWrite");
                if (written != read) throw new IOException("BackupWrite did not consume the complete backup stream.");
            }
        }
        finally { if (context != IntPtr.Zero) BackupWrite(_handle, null, 0, out _, true, false, ref context); }
        RestoreMetadata(original);
    }

    public void RestoreMetadata(FileSnapshot original)
    {
        if (!_writable || original.SecurityCoverage != 7 || original.Security is not { Length: > 0 })
            throw new InvalidDataException("File permissions were not captured for restoration.");
        try { WindowsPermissions.Restore(_handle, 1, original.Security); }
        catch (Win32Exception error) when (error.NativeErrorCode is 5 or 1307)
        {
            using (new PrivilegeScope("File ownership recovery", "SeRestorePrivilege")) WindowsPermissions.Restore(_handle, 1, original.Security);
        }
        var basic = new FileBasicInfo
        {
            CreationTime = original.CreationTime, LastAccessTime = original.LastAccessTime, LastWriteTime = original.LastWriteTime,
            FileAttributes = original.Attributes,
        };
        if (!SetBasicInformation(_handle, 0, ref basic, Marshal.SizeOf<FileBasicInfo>())) Fail("SetFileInformationByHandle(FileBasicInfo)");
    }

    public void MarkDelete()
    {
        if (!_writable) throw new InvalidOperationException("A detection handle cannot delete a file.");
        uint flags = 1 | 0x10;
        if (!SetDispositionInformation(_handle, 21, ref flags, 4)) Fail("SetFileInformationByHandle(FileDispositionInfoEx)");
        if (!Standard(_handle).DeletePending) throw new IOException("Windows did not report the reviewed object as pending deletion.");
    }

    public void RenameToSibling(string name)
    {
        if (!_writable) throw new InvalidOperationException("A detection handle cannot rename a file.");
        RequireComponent(name);
        var bytes = Encoding.Unicode.GetBytes(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!, name));
        var buffer = Marshal.AllocHGlobal(24 + bytes.Length);
        try
        {
            Marshal.Copy(new byte[24 + bytes.Length], 0, buffer, 24 + bytes.Length);
            Marshal.WriteIntPtr(buffer, 8, IntPtr.Zero);
            Marshal.WriteInt32(buffer, 16, bytes.Length);
            Marshal.Copy(bytes, 0, buffer + 20, bytes.Length);
            if (!SetRenameInformation(_handle, 3, buffer, 24 + bytes.Length)) Fail("SetFileInformationByHandle(FileRenameInfo)");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static string NormalizePath(string path)
    {
        var full = System.IO.Path.GetFullPath(path).TrimEnd('\\');
        if (full.Length < 4 || !char.IsAsciiLetter(full[0]) || full[1] != ':' || full[2] != '\\' || full[3..].Contains(':'))
            throw new InvalidDataException("Cleanup requires a local file or directory beneath an explicit drive root.");
        foreach (var part in full[3..].Split('\\')) RequireComponent(part);
        return full;
    }

    public void Dispose()
    {
        foreach (var stream in _streams.Values) stream.Dispose();
        _handle.Dispose();
        foreach (var ancestor in _ancestors.AsEnumerable().Reverse()) ancestor.Dispose();
    }

    private FileStreamDigest[] ReadStreams(string canonical, bool directory)
    {
        var result = new List<FileStreamDigest>();
        var find = FindFirstStream(canonical, 0, out var stream, 0);
        if (find == new IntPtr(-1))
        {
            if (directory && Marshal.GetLastWin32Error() == 38) return [];
            Fail("FindFirstStream");
        }
        try
        {
            do
            {
                if (!stream.Name.EndsWith(":$DATA", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsupported file stream type.");
                var name = stream.Name;
                if (name != "::$DATA" && (name.Length < 8 || name[0] != ':' || name[1..^6].IndexOfAny(['\\', '/', '\0', ':']) >= 0))
                    throw new InvalidDataException("Invalid alternate-stream name.");
                SafeFileHandle source;
                if (name == "::$DATA") source = _handle;
                else if (!_streams.TryGetValue(name, out source!))
                {
                    source = CreateFile(canonical + name, ReadData | Synchronize, 5, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
                    if (source.IsInvalid) { source.Dispose(); Fail("CreateFile(stream)"); }
                    _streams.Add(name, source);
                }
                using var borrowed = new SafeFileHandle(source.DangerousGetHandle(), ownsHandle: false);
                using var input = new FileStream(borrowed, FileAccess.Read);
                input.Position = 0;
                result.Add(new(name, stream.Length, Convert.ToHexString(SHA256.HashData(input))));
                if (result.Count > 4096) throw new InvalidDataException("File contains too many streams to review.");
            } while (FindNextStream(find, out stream));
            var error = Marshal.GetLastWin32Error();
            if (error != 38) throw new Win32Exception(error, "Stream enumeration failed: " + error);
        }
        finally { FindClose(find); }
        return result.OrderBy(stream => stream.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static SafeFileHandle OpenRelative(SafeFileHandle parent, string name, uint access, uint sharing, uint disposition, uint options)
    {
        RequireComponent(name);
        var buffer = Marshal.StringToHGlobalUni(name);
        var unicode = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
        try
        {
            Marshal.StructureToPtr(new UnicodeString { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)((name.Length + 1) * 2)), Buffer = buffer }, unicode, false);
            var attributes = new ObjectAttributes { Length = Marshal.SizeOf<ObjectAttributes>(), RootDirectory = parent.DangerousGetHandle(), ObjectName = unicode, Attributes = 0x40 };
            var status = NtCreateFile(out var handle, access, ref attributes, out _, IntPtr.Zero, 0, sharing, disposition, options, IntPtr.Zero, 0);
            if (status < 0) { handle?.Dispose(); throw new Win32Exception((int)RtlNtStatusToDosError(status), "NtCreateFile failed with NTSTATUS 0x" + unchecked((uint)status).ToString("X8")); }
            return handle;
        }
        finally { Marshal.FreeHGlobal(unicode); Marshal.FreeHGlobal(buffer); }
    }

    private static void RequireComponent(string name)
    {
        if (name is "" or "." or ".." || name.IndexOfAny(['\\', '/', ':', '\0']) >= 0 || name.EndsWith(' ') || name.EndsWith('.'))
            throw new InvalidDataException("A cleanup path contains an unsupported or ambiguous component.");
    }

    private static void RequireOrdinary(SafeFileHandle handle)
    {
        var attributes = Basic(handle).FileAttributes;
        if ((attributes & (0x400u | 0x4000u | 0x800u | 0x200u | 0x1000u)) != 0)
            throw new InvalidDataException("Reparse, encrypted, compressed, sparse or offline files require a separate recovery contract.");
    }

    private static FileBasicInfo Basic(SafeFileHandle handle)
    {
        if (!GetBasicInformation(handle, 0, out var information, Marshal.SizeOf<FileBasicInfo>())) Fail("GetFileInformationByHandleEx(FileBasicInfo)");
        return information;
    }
    private static FileStandardInfo Standard(SafeFileHandle handle)
    {
        if (!GetStandardInformation(handle, 1, out var information, Marshal.SizeOf<FileStandardInfo>())) Fail("GetFileInformationByHandleEx(FileStandardInfo)");
        return information;
    }
    private static FileIdentity Identity(SafeFileHandle handle)
    {
        var buffer = Marshal.AllocHGlobal(24);
        try
        {
            if (!GetFileInformationByHandleEx(handle, 18, buffer, 24)) Fail("GetFileInformationByHandleEx(FileIdInfo)");
            var bytes = new byte[16]; Marshal.Copy(buffer + 8, bytes, 0, 16);
            return new(unchecked((ulong)Marshal.ReadInt64(buffer)), Convert.ToHexString(bytes));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static string CanonicalName(SafeFileHandle handle)
    {
        var text = new StringBuilder(32768);
        var size = GetFinalPathNameByHandle(handle, text, (uint)text.Capacity, 1);
        if (size == 0) Fail("GetFinalPathNameByHandle");
        if (size >= text.Capacity) throw new InvalidDataException("Canonical file path exceeded the supported length.");
        return text.ToString();
    }
    private static byte[] ReadSecurity(SafeFileHandle handle)
    {
        if (GetKernelObjectSecurity(handle, 7, null, 0, out var needed) || Marshal.GetLastWin32Error() != 122) Fail("GetKernelObjectSecurity(size)");
        if (needed is 0 or > 1048576) throw new InvalidDataException("Invalid file security descriptor size.");
        var bytes = new byte[needed];
        if (!GetKernelObjectSecurity(handle, 7, bytes, needed, out _)) Fail("GetKernelObjectSecurity(data)");
        return bytes;
    }
    private static void Fail(string api)
    {
        var error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, api + " failed with Win32 " + error + ": " + new Win32Exception(error).Message);
    }

    [StructLayout(LayoutKind.Sequential)] private struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] private struct ObjectAttributes { public int Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)] private struct IoStatusBlock { public IntPtr Status, Information; }
    [StructLayout(LayoutKind.Sequential)] private struct FileBasicInfo { public long CreationTime, LastAccessTime, LastWriteTime, ChangeTime; public uint FileAttributes; }
    [StructLayout(LayoutKind.Sequential)] private struct FileStandardInfo { public long AllocationSize, EndOfFile; public uint NumberOfLinks; [MarshalAs(UnmanagedType.U1)] public bool DeletePending; [MarshalAs(UnmanagedType.U1)] public bool Directory; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct FindStreamData { public long Length; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=296)] public string Name; }
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode, SetLastError=true)] private static extern SafeFileHandle CreateFile(string path, uint access, uint sharing, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("advapi32.dll")] private static extern uint SetSecurityInfo(SafeFileHandle handle, uint kind, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("ntdll.dll")] private static extern int NtCreateFile(out SafeFileHandle handle, uint access, ref ObjectAttributes attributes, out IoStatusBlock status, IntPtr allocation, uint fileAttributes, uint sharing, uint disposition, uint options, IntPtr ea, uint eaLength);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, IntPtr data, int size);
    [DllImport("kernel32.dll", EntryPoint="GetFileInformationByHandleEx", SetLastError=true)] private static extern bool GetBasicInformation(SafeFileHandle handle, int kind, out FileBasicInfo data, int size);
    [DllImport("kernel32.dll", EntryPoint="GetFileInformationByHandleEx", SetLastError=true)] private static extern bool GetStandardInformation(SafeFileHandle handle, int kind, out FileStandardInfo data, int size);
    [DllImport("kernel32.dll", EntryPoint="SetFileInformationByHandle", SetLastError=true)] private static extern bool SetDispositionInformation(SafeFileHandle handle, int kind, ref uint data, int size);
    [DllImport("kernel32.dll", EntryPoint="SetFileInformationByHandle", SetLastError=true)] private static extern bool SetBasicInformation(SafeFileHandle handle, int kind, ref FileBasicInfo data, int size);
    [DllImport("kernel32.dll", EntryPoint="SetFileInformationByHandle", SetLastError=true)] private static extern bool SetRenameInformation(SafeFileHandle handle, int kind, IntPtr data, int size);
    [DllImport("kernel32.dll", EntryPoint="GetFinalPathNameByHandleW", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder name, uint capacity, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool BackupRead(SafeFileHandle file, [Out] byte[]? buffer, uint size, out uint read, bool abort, bool security, ref IntPtr context);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool BackupWrite(SafeFileHandle file, byte[]? buffer, uint size, out uint written, bool abort, bool security, ref IntPtr context);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information, [Out] byte[]? descriptor, uint size, out uint needed);
    [DllImport("kernel32.dll", EntryPoint="FindFirstStreamW", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr FindFirstStream(string path, int kind, out FindStreamData data, uint flags);
    [DllImport("kernel32.dll", EntryPoint="FindNextStreamW", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool FindNextStream(IntPtr find, out FindStreamData data);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool FindClose(IntPtr find);
    [DllImport("kernel32.dll", EntryPoint="GetDriveTypeW", CharSet=CharSet.Unicode)] private static extern uint GetDriveType(string path);
}
