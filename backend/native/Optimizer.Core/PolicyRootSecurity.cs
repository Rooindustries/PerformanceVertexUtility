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

    public static bool Secure(string root)
    {
        root = Normalize(root);
        var parent = Path.GetDirectoryName(root) ?? throw new InvalidDataException("The saved rules folder needs a parent folder.");
        var name = Path.GetFileName(root);
        RequireElevated();
        var local = Canonical(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        if (!Canonical(root).StartsWith(local + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("The saved rules folder must be inside this Windows user's local app data.");
        using var mutex = new Mutex(false, @"Global\RooIndustriesGovernorSecure-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root.ToUpperInvariant())))[..32]);
        try { mutex.WaitOne(TimeSpan.FromMinutes(2)); } catch (AbandonedMutexException) { }
        try
        {
            if (!Directory.Exists(root) && Directory.Exists(parent))
                foreach (var candidate in new DirectoryInfo(parent).GetDirectories(name + ".secure-*").OrderByDescending(item => item.LastWriteTimeUtc))
                    if (File.Exists(Path.Combine(candidate.FullName, ".migrated")) && Problem(candidate.FullName) is null) { Directory.Move(candidate.FullName, root); break; }
            if (!Directory.Exists(root))
            {
                Directory.CreateDirectory(parent);
                CreateSecured(root);
                Mark(root);
                RemoveLeftovers(parent, name);
                return false;
            }
            if (Problem(root) is null) { Mark(root); RemoveLeftovers(parent, name); return false; }
            if (Marked(root))
                throw new UnauthorizedAccessException("The saved rules folder was changed without administrator rights after it was protected, so it is not trusted. Delete " + root + " and save your rules again.");
            RequireMigratable(root);
            var temporary = Path.Combine(parent, name + ".secure-" + Guid.NewGuid().ToString("N"));
            try
            {
                CreateSecured(temporary);
                Copy(root, temporary);
                File.WriteAllBytes(Path.Combine(temporary, ".migrated"), []);
                if (Problem(temporary) is { } copied) throw new UnauthorizedAccessException("The protected copy of saved rules is not protected: " + copied);
                var legacy = Path.Combine(parent, name + ".legacy-" + Guid.NewGuid().ToString("N"));
                try { Directory.Move(root, legacy); }
                catch (IOException error) { throw new IOException("Stop the Roo Industries Governor before protecting its saved rules folder. " + error.Message, error); }
                Directory.Move(temporary, root);
            }
            catch
            {
                if (Directory.Exists(temporary) && Directory.Exists(root)) Directory.Delete(temporary, true);
                throw;
            }
            Mark(root);
            RemoveLeftovers(parent, name);
            return true;
        }
        finally { mutex.ReleaseMutex(); }
    }

    public static void RequireSecured(string root)
    {
        if (Problem(root) is { } problem) throw new UnauthorizedAccessException("The saved rules folder is not protected (" + problem + "). Open the app as an administrator to repair it.");
    }

    public static string? Problem(string root, bool deep = true)
    {
        var directory = new DirectoryInfo(Normalize(root));
        if (!directory.Exists) return "missing";
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) return "the folder is a link";
        var security = directory.GetAccessControl();
        if (!security.AreAccessRulesProtected) return "the folder inherits permissions";
        if (!Trusted(security.GetOwner(typeof(SecurityIdentifier)))) return "the folder owner is not Administrators";
        if (Writers(security) is { } writer) return writer + " can change the folder";
        if (!Limited(security, OwnerRights)) return "the folder does not limit owner rights";
        var entries = deep
            ? directory.EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false })
            : directory.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0 }).Where(entry => entry.Name is "rules" or "governor.json" or "worker-request.json" or "host.json")
                .Concat(Directory.Exists(Path.Combine(directory.FullName, "rules")) ? new DirectoryInfo(Path.Combine(directory.FullName, "rules")).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0 }) : []);
        foreach (var entry in entries)
        {
            try
            {
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) return entry.Name + " is a link";
                FileSystemSecurity child = entry is DirectoryInfo folder ? folder.GetAccessControl() : ((FileInfo)entry).GetAccessControl();
                if (!Trusted(child.GetOwner(typeof(SecurityIdentifier))) && !Limited(child, OwnerRights)) return entry.Name + " has an untrusted owner";
                if (Writers(child) is { } childWriter) return childWriter + " can change " + entry.Name;
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
        return null;
    }

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

    private static bool Marked(string root)
    {
        using var key = Registry.LocalMachine.OpenSubKey(MarkerKey);
        return key?.GetValue(root.ToUpperInvariant()) is not null;
    }

    private static void Mark(string root)
    {
        using var identity = WindowsIdentity.GetCurrent();
        using var key = Registry.LocalMachine.CreateSubKey(MarkerKey, true);
        if (key.GetValue(root.ToUpperInvariant()) is null) key.SetValue(root.ToUpperInvariant(), identity.User?.Value ?? "", RegistryValueKind.String);
    }

    private static void RequireElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw new UnauthorizedAccessException(NotAdministrator);
    }

    private static void CreateSecured(string path)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw new InvalidOperationException("The current Windows user SID is unavailable.");
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(true, false);
        const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(LocalSystem, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(Administrators, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(OwnerRights, FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize, inherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(security);
        if (Problem(path) is { } problem) throw new UnauthorizedAccessException("The saved rules folder could not be protected (" + problem + ").");
    }

    private static void RequireMigratable(string root)
    {
        var directory = new DirectoryInfo(root);
        foreach (var entry in new FileSystemInfo[] { directory }.Concat(directory.EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false })))
            if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new UnauthorizedAccessException("The saved rules folder contains a link (" + entry.FullName + "), so it is not trusted. Delete " + root + " and save your rules again.");
    }

    private static void Copy(string source, string destination)
    {
        foreach (var folder in Directory.EnumerateDirectories(source, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0 }))
            Directory.CreateDirectory(Path.Combine(destination, Path.GetRelativePath(source, folder)));
        foreach (var file in Directory.EnumerateFiles(source, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0 }))
        {
            if (file.EndsWith(".lock", StringComparison.OrdinalIgnoreCase) || file.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)) continue;
            File.WriteAllBytes(Path.Combine(destination, Path.GetRelativePath(source, file)), File.ReadAllBytes(file));
        }
    }

    private static void RemoveLeftovers(string parent, string name)
    {
        foreach (var leftover in Directory.GetDirectories(parent, name + ".secure-*").Concat(Directory.GetDirectories(parent, name + ".legacy-*")))
        {
            try { Directory.Delete(leftover, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static bool Trusted(IdentityReference? owner) => owner is SecurityIdentifier sid && (sid == Administrators || sid == LocalSystem);

    private static string? Writers(FileSystemSecurity security)
    {
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow || Trusted(rule.IdentityReference)) continue;
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
    private PolicyRootLease(SafeFileHandle handle) { _handle = handle; _opened = FinalPath(handle) ?? throw new IOException("The saved rules folder path could not be read."); }

    public static PolicyRootLease Acquire(string root)
    {
        root = PolicyRootSecurity.Normalize(root);
        var handle = CreateFile(root, 0x1 | 0x20000 | 0x100000, 0x1 | 0x2, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new IOException("The saved rules folder could not be opened: " + new Win32Exception(error).Message);
        }
        PolicyRootLease lease;
        try { lease = new PolicyRootLease(handle); }
        catch { handle.Dispose(); throw; }
        try
        {
            PolicyRootSecurity.RequireSecured(root);
            if (lease.Moved) throw new UnauthorizedAccessException("The saved rules folder moved while it was checked.");
        }
        catch { lease.Dispose(); throw; }
        return lease;
    }

    public bool Moved => !string.Equals(FinalPath(_handle), _opened, StringComparison.OrdinalIgnoreCase);

    private static string? FinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(1024);
        var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        return length == 0 || length >= buffer.Capacity ? null : buffer.ToString();
    }

    public void Dispose() => _handle.Dispose();

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
}
