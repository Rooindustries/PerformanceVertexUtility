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

    public static string? FinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(1024);
        var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        if (length >= buffer.Capacity) { buffer = new StringBuilder((int)length + 1); length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0); }
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

    public static (PathWalk Walk, string? Path) ResolvedPath(string path)
    {
        path = path.Replace('/', '\\');
        if ((path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\??\", StringComparison.Ordinal)) && !path[4..].StartsWith(@"UNC\", StringComparison.OrdinalIgnoreCase)) path = path[4..];
        if (path.Contains('\0')) return (PathWalk.Unknown, null);
        var links = 0;
        try
        {
            var (walk, physical) = Walk(path, ref links);
            if (walk != PathWalk.Local) return (walk, null);
            using var handle = Open(physical, ReadAttributes | Synchronize, ShareAll, BackupSemantics | NoRecallAnonymous);
            return FinalPath(handle) is { } final ? (PathWalk.Local, Normalize(final)) : (PathWalk.Unknown, null);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return (PathWalk.Unknown, null); }
    }

    private static (PathWalk Walk, string Physical) Walk(string path, ref int links)
    {
        var root = LocalRoot(path);
        if (root != PathWalk.Local) return (root, path);
        path = Path.GetFullPath(path);
        var current = path[..3];
        foreach (var part in path[3..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            FileAttributes attributes;
            try { attributes = File.GetAttributes(current); }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return (PathWalk.Absent, current); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return (PathWalk.Unknown, current); }
            if ((attributes & FileAttributes.ReparsePoint) == 0) continue;
            string? target;
            try { target = ((attributes & FileAttributes.Directory) != 0 ? new DirectoryInfo(current) : (FileSystemInfo)new FileInfo(current)).LinkTarget; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return (PathWalk.Unknown, current); }
            if (target is null) return (PathWalk.Unknown, current);
            if (++links > 16) return (PathWalk.Unknown, current);
            target = target.Replace('/', '\\');
            if (target.StartsWith(@"\\?\", StringComparison.Ordinal) || target.StartsWith(@"\??\", StringComparison.Ordinal)) target = target[4..];
            if (target.StartsWith("Volume{", StringComparison.OrdinalIgnoreCase)) return (PathWalk.Unknown, current);
            if (target.StartsWith(@"UNC\", StringComparison.OrdinalIgnoreCase)) return (PathWalk.OffComputer, current);
            if (!Path.IsPathFullyQualified(target))
            {
                if (Path.IsPathRooted(target)) return (PathWalk.Unknown, current);
                target = Path.Combine(Path.GetDirectoryName(current)!, target);
            }
            var (inner, physical) = Walk(target, ref links);
            if (inner != PathWalk.Local) return (inner, physical);
            current = physical;
        }
        return (PathWalk.Local, current);
    }

    private static PathWalk LocalRoot(string path)
    {
        if (path.StartsWith(@"\\", StringComparison.Ordinal) || path.StartsWith(@"UNC\", StringComparison.OrdinalIgnoreCase)) return PathWalk.OffComputer;
        if (path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\') return PathWalk.Unknown;
        var device = new StringBuilder(32768);
        if (QueryDosDevice(path[..2], device, (uint)device.Capacity) == 0) return PathWalk.Unknown;
        var mapping = device.ToString();
        const string local = @"\Device\HarddiskVolume";
        if (!mapping.StartsWith(local, StringComparison.OrdinalIgnoreCase) || mapping.Length == local.Length || !mapping[local.Length..].All(char.IsAsciiDigit)) return PathWalk.Unknown;
        try
        {
            return new DriveInfo(path[..3]).DriveType switch
            {
                DriveType.Fixed => PathWalk.Local,
                DriveType.Removable or DriveType.CDRom or DriveType.Network or DriveType.Ram => PathWalk.OffComputer,
                _ => PathWalk.Unknown,
            };
        }
        catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException) { return PathWalk.Unknown; }
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
