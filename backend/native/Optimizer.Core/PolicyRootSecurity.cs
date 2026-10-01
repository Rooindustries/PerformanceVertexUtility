#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public sealed record ProtectedFolder(string Label, string Restart, string Busy, string NotAdministrator, bool KeepUntrusted, string[] ShallowNames, string? UserFolder,
    Func<string, Action?>? Quiesce = null)
{
    public static readonly ProtectedFolder Rules = new("saved rules folder", "save your rules again", "Stop the Roo Industries Governor before protecting its saved rules folder.",
        PolicyRootSecurity.NotAdministrator, false, ["rules", "governor.json", "worker-request.json", "host.json"], null);
}

public static class PolicyRootSecurity
{
    public const string NotAdministrator = "Saved rules need administrator rights. Open the app as an administrator and try again.";
    public const string MarkerKey = @"SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots";
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);
    private static readonly SecurityIdentifier LocalSystem = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier OwnerRights = new("S-1-3-4");
    private const int GenericAll = 0x10000000, GenericWrite = 0x40000000;
    private const FileSystemRights WriteRights = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.WriteAttributes | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
    private const FileSystemRights UserFolderRights = FileSystemRights.Modify | FileSystemRights.Synchronize;

    public static bool Secure(string root, string? userSid = null) => Secure(root, ProtectedFolder.Rules, userSid);

    public static bool Secure(string root, ProtectedFolder kind, string? userSid = null)
    {
        root = Normalize(root);
        var parent = Path.GetDirectoryName(root) ?? throw new InvalidDataException("The " + kind.Label + " needs a parent folder.");
        var name = Path.GetFileName(root);
        RequireElevated(kind);
        using var identity = WindowsIdentity.GetCurrent();
        var user = userSid is null ? identity.User ?? throw new InvalidOperationException("The current Windows user SID is unavailable.") : new SecurityIdentifier(userSid);
        var local = Canonical(user == identity.User ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) : Path.Combine(ProfilePath(user), "AppData", "Local"));
        if (!Canonical(root).StartsWith(local + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("The " + kind.Label + " must be inside the Windows user's local app data.");
        var marker = MarkerName(root);
        using var mutex = new Mutex(false, @"Global\RooIndustriesGovernorSecure-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(marker)))[..32]);
        bool held;
        try { held = mutex.WaitOne(TimeSpan.FromMinutes(2)); } catch (AbandonedMutexException) { held = true; }
        if (!held) throw new IOException("Another app is protecting the " + kind.Label + ". Try again in a moment.");
        try
        {
            if (!Directory.Exists(root) && Directory.Exists(parent))
                foreach (var candidate in new DirectoryInfo(parent).GetDirectories(name + ".secure-*").OrderByDescending(item => item.LastWriteTimeUtc))
                    if (File.Exists(Path.Combine(candidate.FullName, ".migrated")) && Problem(candidate.FullName, kind) is null) { Directory.Move(candidate.FullName, root); break; }
            if (!Directory.Exists(root))
            {
                Directory.CreateDirectory(parent);
                CreateSecured(root, user, kind);
                Mark(marker, user);
                RemoveLeftovers(parent, name, kind);
                return false;
            }
            if (Problem(root, kind) is null) { Mark(marker, user); RemoveLeftovers(parent, name, kind); return false; }
            if (Marked(marker))
                throw new UnauthorizedAccessException("The " + kind.Label + " was changed without administrator rights after it was protected, so it is not trusted. Delete " + root + " and " + kind.Restart + ".");
            if (!kind.KeepUntrusted) RequireMigratable(root, kind);
            var resume = kind.Quiesce?.Invoke(root);
            try
            {
                Migrate(root, parent, name, user, kind);
                Mark(marker, user);
                RemoveLeftovers(parent, name, kind);
            }
            catch (Exception error)
            {
                try { resume?.Invoke(); }
                catch (Exception resumeError) { throw new AggregateException(error.Message + " " + resumeError.Message, error, resumeError); }
                throw;
            }
            resume?.Invoke();
            return true;
        }
        finally { mutex.ReleaseMutex(); }
    }

    private static void Migrate(string root, string parent, string name, SecurityIdentifier user, ProtectedFolder kind)
    {
        for (var attempt = 1; ; attempt++)
        {
            var temporary = Path.Combine(parent, name + ".secure-" + Guid.NewGuid().ToString("N"));
            var legacy = Path.Combine(parent, name + ".legacy-" + Guid.NewGuid().ToString("N"));
            var kept = false;
            try
            {
                CreateSecured(temporary, user, kind);
                kept = Copy(root, temporary, kind, user);
                File.WriteAllBytes(Path.Combine(temporary, ".migrated"), []);
                if (Problem(temporary, kind) is { } copied) throw new UnauthorizedAccessException("The protected copy of the " + kind.Label + " is not protected: " + copied);
                try { Directory.Move(root, legacy); }
                catch (IOException) when (attempt < 5 && kind.KeepUntrusted) { Directory.Delete(temporary, true); Thread.Sleep(200 * attempt); continue; }
                catch (IOException error) { throw new IOException(kind.Busy + " " + error.Message, error); }
                catch (UnauthorizedAccessException) when (attempt < 5 && kind.KeepUntrusted) { Directory.Delete(temporary, true); Thread.Sleep(200 * attempt); continue; }
                catch (UnauthorizedAccessException error) { throw new IOException(kind.Busy + " " + error.Message, error); }
            }
            catch
            {
                if (Directory.Exists(temporary) && Directory.Exists(root)) Directory.Delete(temporary, true);
                throw;
            }
            try { kept |= Copy(legacy, temporary, kind, user, mirror: true); }
            catch
            {
                try { Directory.Move(legacy, root); Directory.Delete(temporary, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                throw;
            }
            var strays = new List<string>();
            while (true)
            {
                try { Directory.Move(temporary, root); break; }
                catch (IOException) when (Directory.Exists(root) && strays.Count < 3)
                {
                    var stray = Path.Combine(parent, name + ".stray-" + Guid.NewGuid().ToString("N"));
                    Directory.Move(root, stray); strays.Add(stray);
                }
            }
            foreach (var stray in strays)
            {
                if (Copy(stray, root, kind, user, merge: true) || WriterOf(parent) is not null) Directory.Move(stray, Path.Combine(parent, name + ".untrusted-" + Guid.NewGuid().ToString("N")));
                else Directory.Delete(stray, true);
            }
            if (kept || WriterOf(parent) is not null) Directory.Move(legacy, Path.Combine(parent, name + ".untrusted-" + Guid.NewGuid().ToString("N")));
            return;
        }
    }

    public static void RequireSecured(string root) => RequireSecured(root, ProtectedFolder.Rules);

    public static void RequireSecured(string root, ProtectedFolder kind, bool deep = true)
    {
        if (Problem(root, kind, deep) is { } problem) throw new UnauthorizedAccessException("The " + kind.Label + " is not protected (" + problem + "). Open the app as an administrator to repair it.");
    }

    public static string? Problem(string root, bool deep = true) => Problem(root, ProtectedFolder.Rules, deep);

    public static string? Problem(string root, ProtectedFolder kind, bool deep = true)
    {
        var directory = new DirectoryInfo(Normalize(root));
        if (!directory.Exists) return "missing";
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) return "the folder is a link";
        var security = directory.GetAccessControl();
        if (!security.AreAccessRulesProtected) return "the folder inherits permissions";
        if (!Trusted(security.GetOwner(typeof(SecurityIdentifier)))) return "the folder owner is not Administrators";
        if (Writers(security) is { } writer) return writer + " can change the folder";
        if (!Limited(security, OwnerRights)) return "the folder does not limit owner rights";
        foreach (var entry in Entries(directory, kind, deep))
        {
            try
            {
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) return entry.Name + " is a link";
                FileSystemSecurity child = entry is DirectoryInfo folder ? folder.GetAccessControl() : ((FileInfo)entry).GetAccessControl();
                if (!Trusted(child.GetOwner(typeof(SecurityIdentifier))) && !Limited(child, OwnerRights)) return entry.Name + " has an untrusted owner";
                if (Writers(child, UserWritable(directory, entry, kind)) is { } childWriter) return childWriter + " can change " + entry.Name;
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch (UnauthorizedAccessException) when (!File.Exists(entry.FullName) && !Directory.Exists(entry.FullName)) { }
        }
        return null;
    }

    private static IEnumerable<FileSystemInfo> Entries(DirectoryInfo directory, ProtectedFolder kind, bool deep)
    {
        var top = directory.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false });
        if (!deep)
        {
            foreach (var entry in top.Where(entry => kind.ShallowNames.Contains(entry.Name, StringComparer.OrdinalIgnoreCase)))
            {
                yield return entry;
                if (entry is DirectoryInfo folder && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    foreach (var child in folder.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0 })) yield return child;
            }
            yield break;
        }
        var pending = new Stack<IEnumerable<FileSystemInfo>>();
        pending.Push(top);
        while (pending.Count > 0)
            foreach (var entry in pending.Pop())
            {
                yield return entry;
                if (entry is DirectoryInfo folder && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint) && !IsUserFolder(directory, entry, kind))
                    pending.Push(folder.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false }));
            }
    }

    private static bool IsUserFolder(DirectoryInfo root, FileSystemInfo entry, ProtectedFolder kind)
        => kind.UserFolder is { } folder && entry is DirectoryInfo && string.Equals(Path.GetFullPath(entry.FullName).TrimEnd(Path.DirectorySeparatorChar), Path.Combine(root.FullName.TrimEnd(Path.DirectorySeparatorChar), folder), StringComparison.OrdinalIgnoreCase);

    private static bool UserWritable(DirectoryInfo root, FileSystemInfo entry, ProtectedFolder kind) => IsUserFolder(root, entry, kind);

    public static string Normalize(string path) => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);

    private static string Canonical(string path)
    {
        var existing = Normalize(path);
        var rest = "";
        while (!Directory.Exists(existing) && Path.GetDirectoryName(existing) is { } parent) { rest = Path.Combine(Path.GetFileName(existing), rest); existing = parent; }
        var buffer = new StringBuilder(1024);
        var length = GetLongPathName(existing, buffer, (uint)buffer.Capacity);
        var longPath = length == 0 || length >= buffer.Capacity ? existing : buffer.ToString();
        return Normalize(rest.Length == 0 ? longPath : Path.Combine(longPath, rest));
    }

    [DllImport("kernel32.dll", EntryPoint = "GetLongPathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint length);

    public static string MarkerName(string root) => Canonical(root).ToUpperInvariant();

    public static bool Marked(string marker)
    {
        using var key = Registry.LocalMachine.OpenSubKey(MarkerKey);
        return key?.GetValue(marker) is not null;
    }

    private static void Mark(string marker, SecurityIdentifier user)
    {
        using var key = Registry.LocalMachine.CreateSubKey(MarkerKey, true);
        if (key.GetValue(marker) is not null) return;
        key.SetValue(marker + ProtectedAtSuffix, DateTime.UtcNow.ToFileTimeUtc(), RegistryValueKind.QWord);
        key.SetValue(marker, user.Value, RegistryValueKind.String);
    }

    public const string ProtectedAtSuffix = "|protected-at";

    public static DateTime? ProtectedAt(string root)
    {
        using var key = Registry.LocalMachine.OpenSubKey(MarkerKey);
        return key?.GetValue(MarkerName(root) + ProtectedAtSuffix) is long time ? DateTime.FromFileTimeUtc(time) : null;
    }

    public static void RequireWrittenAfterProtection(string file, string message)
    {
        var full = Normalize(file);
        for (var directory = Path.GetDirectoryName(full); directory is not null; directory = Path.GetDirectoryName(directory))
        {
            if (!Marked(MarkerName(directory))) continue;
            if (ProtectedAt(directory) is { } at && File.Exists(full) && File.GetCreationTimeUtc(full) > at) return;
            break;
        }
        throw new InvalidDataException(message);
    }

    private static string ProfilePath(SecurityIdentifier user)
    {
        using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + user.Value);
        return key?.GetValue("ProfileImagePath") is string path ? Environment.ExpandEnvironmentVariables(path) : throw new InvalidDataException("That Windows user has no profile on this PC.");
    }

    public static bool Elevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static void RequireElevated(ProtectedFolder kind)
    {
        if (!Elevated()) throw new UnauthorizedAccessException(kind.NotAdministrator);
    }

    private static void CreateSecured(string path, SecurityIdentifier user, ProtectedFolder kind)
    {
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(true, false);
        const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(LocalSystem, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(Administrators, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(OwnerRights, FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize, inherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(security);
        if (kind.UserFolder is { } folder && !Nested(folder)) CreateUserFolder(Path.Combine(path, folder), user);
        if (Problem(path, kind) is { } problem) throw new UnauthorizedAccessException("The " + kind.Label + " could not be protected (" + problem + ").");
    }

    public static void RepairUserFolder(string root, ProtectedFolder kind)
    {
        if (kind.UserFolder is not { } folder || Nested(folder) || Directory.Exists(Path.Combine(root, folder))) return;
        using var identity = WindowsIdentity.GetCurrent();
        CreateUserFolder(Path.Combine(Normalize(root), folder), identity.User ?? throw new InvalidOperationException("The current Windows user SID is unavailable."));
    }

    private static bool Nested(string folder) => folder.Contains(Path.DirectorySeparatorChar);

    public static string? WriterOf(string directory) => Writers(new DirectoryInfo(Normalize(directory)).GetAccessControl());

    private static void PreserveProtection(DirectorySecurity source, string target)
    {
        if (!source.AreAccessRulesProtected || !Trusted(source.GetOwner(typeof(SecurityIdentifier))) || Writers(source) is not null || !Limited(source, OwnerRights)) return;
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(true, false);
        foreach (FileSystemAccessRule rule in source.GetAccessRules(true, false, typeof(SecurityIdentifier))) security.AddAccessRule(rule);
        new DirectoryInfo(target).SetAccessControl(security);
    }

    private static void CreateUserFolder(string path, SecurityIdentifier user)
    {
        var directory = new DirectoryInfo(path);
        if (!directory.Exists) directory.Create();
        var security = directory.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(user, UserFolderRights & ~FileSystemRights.Delete, InheritanceFlags.None, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(user, UserFolderRights, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.InheritOnly, AccessControlType.Allow));
        directory.SetAccessControl(security);
    }

    private static void RequireMigratable(string root, ProtectedFolder kind)
    {
        var directory = new DirectoryInfo(root);
        foreach (var entry in new FileSystemInfo[] { directory }.Concat(directory.EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false })))
        {
            if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new UnauthorizedAccessException("The " + kind.Label + " contains a link (" + entry.FullName + "), so it is not trusted. Delete " + root + " and " + kind.Restart + ".");
            if (!Trusted((entry is DirectoryInfo folder ? (FileSystemSecurity)folder.GetAccessControl() : ((FileInfo)entry).GetAccessControl()).GetOwner(typeof(SecurityIdentifier))))
                throw new UnauthorizedAccessException("The " + kind.Label + " has files the app did not write with administrator rights (" + entry.FullName + "). Delete " + root + " and " + kind.Restart + ".");
        }
    }

    private static bool Copy(string source, string destination, ProtectedFolder kind, SecurityIdentifier user, bool mirror = false, bool merge = false)
    {
        using var sourceHandle = PolicyRootLease.OpenDirectory(source);
        var sourcePath = PolicyRootLease.FinalPath(sourceHandle) ?? throw new IOException("The " + kind.Label + " path could not be read.");
        var skipped = false;
        var copied = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Refuse(string message) { if (!kind.KeepUntrusted) throw new UnauthorizedAccessException(message); skipped = true; }
        void Walk(string folder, bool userFolder)
        {
            foreach (var entry in new DirectoryInfo(folder).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false }))
            {
                var relative = Path.GetRelativePath(source, entry.FullName);
                var target = Path.Combine(destination, relative);
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) { Refuse("The " + kind.Label + " changed into a link while it was copied."); continue; }
                if (entry is DirectoryInfo child)
                {
                    var isUserFolder = kind.UserFolder is { } name && string.Equals(relative, name, StringComparison.OrdinalIgnoreCase);
                    var inUserFolder = userFolder || isUserFolder;
                    var childSecurity = child.GetAccessControl();
                    if (!inUserFolder && !Trusted(childSecurity.GetOwner(typeof(SecurityIdentifier)))) { Refuse("The " + kind.Label + " changed while it was copied, so it is not trusted."); continue; }
                    Directory.CreateDirectory(target);
                    if (!inUserFolder) PreserveProtection(childSecurity, target);
                    if (isUserFolder) CreateUserFolder(target, user);
                    copied.Add(relative);
                    Walk(child.FullName, inUserFolder);
                    continue;
                }
                if (entry.Name.EndsWith(".lock", StringComparison.OrdinalIgnoreCase) || entry.Name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)) continue;
                copied.Add(relative);
                if (merge && File.Exists(target)) continue;
                using var input = new FileStream(entry.FullName, FileMode.Open, FileAccess.Read, FileShare.Read);
                var inputPath = PolicyRootLease.FinalPath(input.SafeFileHandle);
                if (inputPath is null || !inputPath.StartsWith(sourcePath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || PolicyRootLease.Links(input.SafeFileHandle) != 1 ||
                    !userFolder && !Trusted(input.GetAccessControl().GetOwner(typeof(SecurityIdentifier))))
                {
                    copied.Remove(relative);
                    Refuse("The " + kind.Label + " changed while it was copied, so it is not trusted.");
                    continue;
                }
                using var output = new FileStream(target, mirror ? FileMode.Create : FileMode.CreateNew, FileAccess.Write, FileShare.None);
                input.CopyTo(output);
            }
        }
        if (new DirectoryInfo(source).Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UnauthorizedAccessException("The " + kind.Label + " changed into a link while it was copied.");
        Walk(source, false);
        if (mirror)
        {
            foreach (var stale in Directory.EnumerateFiles(destination, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0 }).ToArray())
            {
                var relative = Path.GetRelativePath(destination, stale);
                if (relative != ".migrated" && !copied.Contains(relative)) File.Delete(stale);
            }
            foreach (var stale in Directory.EnumerateDirectories(destination, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0 }).OrderByDescending(path => path.Length).ToArray())
                if (!copied.Contains(Path.GetRelativePath(destination, stale)) && !(kind.UserFolder is { } name && string.Equals(Path.GetRelativePath(destination, stale), name, StringComparison.OrdinalIgnoreCase)))
                    Directory.Delete(stale, true);
        }
        return skipped;
    }

    private static void RemoveLeftovers(string parent, string name, ProtectedFolder kind)
    {
        var open = WriterOf(parent) is not null;
        foreach (var leftover in Directory.GetDirectories(parent, name + ".secure-*").Concat(Directory.GetDirectories(parent, name + ".legacy-*")))
        {
            if (open && (Path.GetFileName(leftover).StartsWith(name + ".legacy-", StringComparison.OrdinalIgnoreCase) || Problem(leftover, kind) is not null)) continue;
            try { Directory.Delete(leftover, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static bool Trusted(IdentityReference? owner) => owner is SecurityIdentifier sid && (sid == Administrators || sid == LocalSystem);

    private static string? Writers(FileSystemSecurity security, bool userFolder = false)
    {
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow || Trusted(rule.IdentityReference)) continue;
            if (userFolder && rule.IdentityReference != OwnerRights && (rule.FileSystemRights & ~UserFolderRights) == 0) continue;
            if ((rule.FileSystemRights & WriteRights) != 0 || ((int)rule.FileSystemRights & (GenericAll | GenericWrite)) != 0) return rule.IdentityReference.Value;
        }
        return null;
    }

    private static bool Limited(FileSystemSecurity security, SecurityIdentifier sid)
    {
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference == sid) return true;
        return false;
    }
}

public sealed class PolicyRootLease : IDisposable
{
    private readonly SafeFileHandle _handle;
    private readonly string _opened;
    private PolicyRootLease(SafeFileHandle handle) { _handle = handle; _opened = FinalPath(handle) ?? throw new IOException("The protected folder path could not be read."); }

    internal static SafeFileHandle OpenDirectory(string path)
    {
        var handle = CreateFile(PolicyRootSecurity.Normalize(path), 0x1 | 0x20000 | 0x100000, 0x1 | 0x2, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw new IOException("The protected folder could not be opened: " + new Win32Exception(error).Message);
    }

    public static PolicyRootLease Acquire(string root) => Acquire(root, ProtectedFolder.Rules, deep: true);

    public static PolicyRootLease Acquire(string root, ProtectedFolder kind, bool deep)
    {
        root = PolicyRootSecurity.Normalize(root);
        var handle = OpenDirectory(root);
        PolicyRootLease lease;
        try { lease = new PolicyRootLease(handle); }
        catch { handle.Dispose(); throw; }
        try
        {
            PolicyRootSecurity.RequireSecured(root, kind, deep);
            if (lease.Moved) throw new UnauthorizedAccessException("The " + kind.Label + " moved while it was checked.");
        }
        catch { lease.Dispose(); throw; }
        return lease;
    }

    public bool Moved => !string.Equals(FinalPath(_handle), _opened, StringComparison.OrdinalIgnoreCase);

    internal static string? FinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(1024);
        var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        return length == 0 || length >= buffer.Capacity ? null : buffer.ToString();
    }

    internal static uint Links(SafeFileHandle handle)
        => GetFileInformationByHandle(handle, out var information) ? information.NumberOfLinks : throw new Win32Exception(Marshal.GetLastWin32Error());

    public void Dispose() => _handle.Dispose();

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
}
