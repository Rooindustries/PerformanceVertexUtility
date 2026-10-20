#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

internal readonly record struct HandleInfo(FileAttributes Attributes, long Length, long LastWriteTicks, uint Links, long CreationTicks)
{
    public bool IsLink => Attributes.HasFlag(FileAttributes.ReparsePoint);
    public bool IsDirectory => Attributes.HasFlag(FileAttributes.Directory);
}

internal static class NativeFiles
{
    private const uint ReadData = 0x1, ReadAttributes = 0x80, WriteAttributes = 0x100, Delete = 0x10000, ReadControl = 0x20000, Synchronize = 0x100000, GenericRead = 0x80000000;
    private const uint ShareAll = 0x7, OpenExisting = 3;
    private const uint BackupSemantics = 0x02000000, OpenReparsePoint = 0x00200000, NoRecallAnonymous = 0x00100000;
    public const FileAttributes Placeholder = (FileAttributes)(0x1000 | 0x40000 | 0x400000);
    public const FileAttributes Preserved = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System | FileAttributes.NotContentIndexed | FileAttributes.Archive;

    public static string Extended(string path)
    {
        if (path.Length < 240 || path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
        var full = Path.GetFullPath(path);
        return full.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + full[2..] : @"\\?\" + full;
    }

    private static SafeFileHandle Open(string path, uint access, uint share, uint flags)
    {
        var handle = CreateFile(Extended(path), access, share, IntPtr.Zero, OpenExisting, flags, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw Fail(error, path);
    }

    private static Exception Fail(int error, string path) => error switch
    {
        2 => new FileNotFoundException(new Win32Exception(error).Message, path),
        3 => new DirectoryNotFoundException(new Win32Exception(error).Message),
        5 => new UnauthorizedAccessException(new Win32Exception(error).Message),
        206 => new PathTooLongException(new Win32Exception(error).Message),
        _ => new IOException(new Win32Exception(error).Message, unchecked((int)(0x80070000 | (uint)error))),
    };

    public static SafeFileHandle OpenDirectory(string path, bool forDelete = false)
        => Open(path, ReadAttributes | ReadControl | Synchronize | 0x1 | (forDelete ? Delete | WriteAttributes : 0), ShareAll, BackupSemantics | OpenReparsePoint);

    public static SafeFileHandle OpenFile(string path, bool forDelete = false)
        => Open(path, ReadData | ReadAttributes | ReadControl | Synchronize | (forDelete ? Delete | WriteAttributes : 0), ShareAll, OpenReparsePoint | NoRecallAnonymous);

    public static SafeFileHandle OpenEntry(string path, bool forDelete)
        => Open(path, ReadAttributes | ReadControl | Synchronize | (forDelete ? Delete | WriteAttributes : 0), ShareAll, BackupSemantics | OpenReparsePoint | NoRecallAnonymous);

    public static HandleInfo Info(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out var information)) throw Fail(Marshal.GetLastWin32Error(), "");
        return new((FileAttributes)information.Attributes, ((long)information.SizeHigh << 32) | information.SizeLow, information.Write, information.Links, information.Creation);
    }

    public static string? FinalPath(SafeFileHandle handle, uint flags = 0)
    {
        var buffer = new StringBuilder(1024);
        var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, flags);
        if (length >= buffer.Capacity) { buffer = new StringBuilder((int)length + 1); length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, flags); }
        return length == 0 || length >= buffer.Capacity ? null : buffer.ToString();
    }

    public static bool Inside(string? path, string folder)
        => path is not null && path.Length > folder.Length + 1 && path.StartsWith(folder, StringComparison.OrdinalIgnoreCase) && path[folder.Length] == Path.DirectorySeparatorChar;

    public static bool SameFinalPath(string? left, string? right)
        => left is not null && right is not null && string.Equals(left.TrimEnd(Path.DirectorySeparatorChar), right.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);

    public static SecurityIdentifier? Owner(SafeFileHandle handle)
    {
        if (GetSecurityInfo(handle, 1, 1, out var owner, out _, out _, out _, out var descriptor) != 0) return null;
        try { return owner == IntPtr.Zero ? null : new SecurityIdentifier(owner); }
        finally { LocalFree(descriptor); }
    }

    public static byte[]? SecurityDescriptor(SafeFileHandle handle)
    {
        GetKernelObjectSecurity(handle, 7, null, 0, out var needed);
        if (needed == 0 || needed > 1 << 20) return null;
        var buffer = new byte[needed];
        return GetKernelObjectSecurity(handle, 7, buffer, needed, out _) ? buffer : null;
    }

    public static bool HasExtraStreams(SafeFileHandle handle)
    {
        var size = 4096;
        while (true)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetFileInformationByHandleEx(handle, 7, buffer, (uint)size))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == 234) { size *= 4; if (size > 1 << 24) return true; continue; }
                    if (error == 38) return false;
                    throw Fail(error, "");
                }
                var offset = 0; var count = 0;
                while (true)
                {
                    var next = Marshal.ReadInt32(buffer, offset);
                    var nameLength = Marshal.ReadInt32(buffer, offset + 4);
                    var name = Marshal.PtrToStringUni(buffer + offset + 24, nameLength / 2);
                    if (!string.Equals(name, "::$DATA", StringComparison.OrdinalIgnoreCase)) count++;
                    if (next == 0) break;
                    offset += next;
                }
                return count > 0;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    public static bool HasExtendedAttributes(SafeFileHandle handle)
    {
        var buffer = Marshal.AllocHGlobal(4);
        try
        {
            Marshal.WriteInt32(buffer, 0);
            var status = NtQueryInformationFile(handle, out _, buffer, 4, 7);
            return status >= 0 && Marshal.ReadInt32(buffer) != 0;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static bool DeleteHandle(SafeFileHandle handle)
    {
        var flags = 0x11u;
        if (SetFileInformationByHandle(handle, 21, ref flags, 4)) return true;
        var info = new BasicInformation { Attributes = (uint)FileAttributes.Normal };
        SetFileInformationByHandle(handle, 0, ref info, (uint)Marshal.SizeOf<BasicInformation>());
        var disposition = 1u;
        return SetFileInformationByHandle(handle, 4, ref disposition, 4);
    }

    public static FileStream OpenLock(string path)
    {
        using var directory = OpenDirectory(Path.GetDirectoryName(path)!);
        var directoryInfo = Info(directory);
        if (directoryInfo.IsLink || !directoryInfo.IsDirectory) throw new UnauthorizedAccessException("The folder for " + Path.GetFileName(path) + " is a link, so it is not trusted.");
        var directoryFinal = FinalPath(directory);
        var handle = CreateFile(Extended(path), GenericRead | 0x40000000 | Delete, 0, IntPtr.Zero, 4, OpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw Fail(error, path); }
        try
        {
            var info = Info(handle);
            var final = FinalPath(handle);
            if (info.IsLink || info.IsDirectory || info.Links != 1 || final is null || !SameFinalPath(Path.GetDirectoryName(final), directoryFinal) || !string.Equals(Path.GetFileName(final), Path.GetFileName(path), StringComparison.OrdinalIgnoreCase))
                throw new UnauthorizedAccessException(Path.GetFileName(path) + " is not a plain file inside its folder, so it is not trusted.");
            return new LockStream(handle);
        }
        catch { handle.Dispose(); throw; }
    }

    private sealed class LockStream : FileStream
    {
        private readonly SafeFileHandle _handle;
        public LockStream(SafeFileHandle handle) : base(handle, FileAccess.ReadWrite, 4096) { _handle = handle; }
        protected override void Dispose(bool disposing)
        {
            if (disposing && !_handle.IsClosed) DeleteHandle(_handle);
            base.Dispose(disposing);
        }
    }

    public static string Normalize(string path) => path.StartsWith(@"\\?\", StringComparison.Ordinal) && !path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase) ? path[4..] : path;

    internal enum PathWalk { Local, Absent, OffComputer, Unknown }

    public static (PathWalk Walk, string? Path, FileAttributes Attributes) ResolvedPath(string path)
    {
        var links = 0;
        try
        {
            var (walk, handle) = Walk(path, ref links);
            using (handle)
                return handle is null ? (walk == PathWalk.Absent && links != 0 ? PathWalk.Unknown : walk, null, 0) : FinalPath(handle) is { } final ? (PathWalk.Local, Normalize(final), Info(handle).Attributes | (links == 0 ? 0 : FileAttributes.ReparsePoint)) : (PathWalk.Unknown, null, 0);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or Win32Exception) { return (PathWalk.Unknown, null, 0); }
    }

    public static (string Name, FileAttributes Attributes)[] ReadDirectory(string path)
    {
        var links = 0;
        var (walk, handle) = Walk(path, ref links, true);
        using (handle)
        {
            if (handle is not null && Info(handle).IsDirectory) return FileLease.DirectoryEntries(handle);
            if (walk == PathWalk.Absent && links == 0) return [];
            throw new InvalidDataException("This directory could not be opened safely on a local fixed drive.");
        }
    }

    private static (PathWalk Walk, SafeFileHandle? Handle) Walk(string path, ref int links, bool directory = false)
    {
        path = path.Replace('/', '\\');
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\??\", StringComparison.Ordinal)) path = path[4..];
        if (path.Contains('\0')) return (PathWalk.Unknown, null);
        var (state, root) = LocalRoot(path);
        if (root is null) return (state, null);
        path = Path.GetFullPath(path);
        return WalkLocal(root, path[3..], ref links, directory);
    }

    private static (PathWalk Walk, SafeFileHandle? Handle) WalkLocal(string root, string relative, ref int links, bool directory)
    {
        SafeFileHandle? current = Open(root, ReadAttributes | Synchronize | (directory ? ReadData : 0), ShareAll, BackupSemantics | OpenReparsePoint | NoRecallAnonymous);
        try
        {
            foreach (var part in relative.Split('\\', StringSplitOptions.RemoveEmptyEntries))
            {
                SafeFileHandle? child;
                try { child = directory ? FileLease.OpenDirectoryChild(current, part) : FileLease.OpenMetadataChild(current, part); }
                catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { return (PathWalk.Absent, null); }
                try
                {
                    if (Info(child).IsLink)
                    {
                        if (++links > 16 || LinkTarget(child) is not { } link) return (PathWalk.Unknown, null);
                        var resolved = link.Relative ? WalkRelative(current, link.Target, ref links, directory) : Walk(link.Target, ref links, directory);
                        if (resolved.Handle is null) return resolved;
                        child.Dispose(); child = resolved.Handle;
                    }
                    current.Dispose(); current = child; child = null;
                }
                finally { child?.Dispose(); }
            }
            var result = current; current = null;
            return (PathWalk.Local, result);
        }
        finally { current?.Dispose(); }
    }

    private static (PathWalk Walk, SafeFileHandle? Handle) WalkRelative(SafeFileHandle parent, string target, ref int links, bool directory)
    {
        if (Path.IsPathRooted(target)) return (PathWalk.Unknown, null);
        var native = FinalPath(parent, 2);
        const string prefix = @"\Device\HarddiskVolume";
        if (native is null || !native.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return (PathWalk.Unknown, null);
        var separator = native.IndexOf('\\', prefix.Length);
        if (separator <= prefix.Length || !native[prefix.Length..separator].All(char.IsAsciiDigit)) return (PathWalk.Unknown, null);
        var relative = Path.GetFullPath(@"C:\" + native[(separator + 1)..] + "\\" + target)[3..];
        return WalkLocal(@"\\?\GLOBALROOT" + native[..(separator + 1)], relative, ref links, directory);
    }

    private static (string Target, bool Relative)? LinkTarget(SafeFileHandle handle)
    {
        var data = new byte[16384];
        if (!DeviceIoControl(handle, 0x900A8, IntPtr.Zero, 0, data, (uint)data.Length, out var length, IntPtr.Zero) || length < 16) return null;
        var tag = BitConverter.ToUInt32(data, 0);
        var start = tag == 0xA0000003 ? 16 : tag == 0xA000000C ? 20 : 0;
        var size = BitConverter.ToUInt16(data, 4) + 8;
        if (start == 0 || size < start || size > length) return null;
        var offset = BitConverter.ToUInt16(data, 8);
        var count = BitConverter.ToUInt16(data, 10);
        var flags = tag == 0xA000000C ? BitConverter.ToUInt32(data, 16) : 0;
        if ((offset & 1) != 0 || count == 0 || (count & 1) != 0 || start + offset + count > size || flags > 1) return null;
        return (new string(MemoryMarshal.Cast<byte, char>(data.AsSpan(start + offset, count))), flags == 1);
    }

    private static (PathWalk Walk, string? Root) LocalRoot(string path)
    {
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith(@"UNC\", StringComparison.OrdinalIgnoreCase)) return (PathWalk.OffComputer, null);
        if (path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\') return (PathWalk.Unknown, null);
        var device = new StringBuilder(32768);
        if (QueryDosDevice(path[..2], device, (uint)device.Capacity) == 0) return (PathWalk.Unknown, null);
        var mapping = device.ToString();
        const string local = @"\Device\HarddiskVolume";
        if (!mapping.StartsWith(local, StringComparison.OrdinalIgnoreCase) || mapping.Length == local.Length || !mapping[local.Length..].All(char.IsAsciiDigit)) return (PathWalk.Unknown, null);
        var root = @"\\?\GLOBALROOT" + mapping + "\\";
        try
        {
            return GetDriveType(root) switch
            {
                3 => (PathWalk.Local, root),
                2 or 4 or 5 or 6 => (PathWalk.OffComputer, null),
                _ => (PathWalk.Unknown, null),
            };
        }
        catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException) { return (PathWalk.Unknown, null); }
    }

    public static byte[]? ReadBounded(string folder, string name, int limit, out string? refusal)
    {
        refusal = null;
        folder = PolicyRootSecurity.Normalize(folder);
        SafeFileHandle directory;
        try { directory = OpenDirectory(folder); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { refusal = error is DirectoryNotFoundException or FileNotFoundException ? null : error.Message; return null; }
        using (directory)
        {
            var directoryInfo = Info(directory);
            if (directoryInfo.IsLink || !directoryInfo.IsDirectory) { refusal = "The folder is a link, so it is not trusted."; return null; }
            var final = FinalPath(directory);
            if (final is null || !SameFinalPath(Normalize(final), PolicyRootSecurity.CanonicalPath(folder))) { refusal = "The folder resolves somewhere else, so it is not trusted."; return null; }
            SafeFileHandle file;
            try { file = OpenFile(Path.Combine(folder, name)); }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return null; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { refusal = error.Message; return null; }
            using (file)
            {
                var info = Info(file);
                var path = FinalPath(file);
                if (info.IsLink || info.IsDirectory || info.Attributes.HasFlag(FileAttributes.Device) || info.Attributes.HasFlag(Placeholder) || !Inside(path, final.TrimEnd(Path.DirectorySeparatorChar)) || !string.Equals(Path.GetFileName(path), name, StringComparison.OrdinalIgnoreCase))
                { refusal = "The file is not a plain file inside its folder, so it is not trusted."; return null; }
                if (info.Length > limit) { refusal = "The file is larger than " + limit + " bytes, so it is not trusted."; return null; }
                var bytes = new byte[info.Length];
                using var stream = new FileStream(new SafeFileHandle(file.DangerousGetHandle(), false), FileAccess.Read, 1, false);
                var read = 0;
                while (read < bytes.Length) { var count = stream.Read(bytes, read, bytes.Length - read); if (count == 0) break; read += count; }
                return read == bytes.Length ? bytes : bytes[..read];
            }
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct ByHandle
    {
        public uint Attributes;
        public long Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicInformation { public long Creation, Access, Write, Change; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoStatus { public IntPtr Status, Information; }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandle information);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    [DllImport("kernel32.dll", EntryPoint = "QueryDosDeviceW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint QueryDosDevice(string name, StringBuilder target, uint length);
    [DllImport("kernel32.dll", EntryPoint = "GetDriveTypeW", CharSet = CharSet.Unicode)]
    private static extern uint GetDriveType(string root);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle handle, uint control, IntPtr input, uint inputLength, byte[] output, uint outputLength, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, IntPtr buffer, uint size);
    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref uint value, uint size);
    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref BasicInformation value, uint size);
    [DllImport("advapi32.dll")]
    private static extern uint GetSecurityInfo(SafeFileHandle handle, int objectType, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetKernelObjectSecurity(SafeFileHandle handle, uint information, byte[]? descriptor, uint length, out uint needed);
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationFile(SafeFileHandle handle, out IoStatus status, IntPtr information, uint length, int kind);
}
