#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public static class PolicyRootSecurity
{
    public const string NotAdministrator = "Saved rules need administrator rights. Open the app as an administrator and try again.";
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);
    private static readonly SecurityIdentifier LocalSystem = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier OwnerRights = new("S-1-3-4");
    private const int GenericAll = 0x10000000, GenericWrite = 0x40000000;
    private const FileSystemRights WriteRights = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.WriteAttributes | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;

    public static bool Secure(string root)
    {
        root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        var parent = Path.GetDirectoryName(root) ?? throw new InvalidDataException("The saved rules folder needs a parent folder.");
        var name = Path.GetFileName(root);
        RequireElevated();
        if (!Directory.Exists(root) && Directory.Exists(parent))
            foreach (var candidate in Directory.GetDirectories(parent, name + ".secure-*"))
                if (File.Exists(Path.Combine(candidate, ".migrated")) && Problem(candidate) is null) { Directory.Move(candidate, root); break; }
        if (!Directory.Exists(root))
        {
            Directory.CreateDirectory(parent);
            CreateSecured(root);
            RemoveLeftovers(parent, name);
            return false;
        }
        if (Problem(root) is null) { RemoveLeftovers(parent, name); return false; }
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
        RemoveLeftovers(parent, name);
        return true;
    }

    public static void RequireSecured(string root)
    {
        if (Problem(root) is { } problem) throw new UnauthorizedAccessException("The saved rules folder is not protected (" + problem + "). Open the app as an administrator to repair it.");
    }

    public static string? Problem(string root)
    {
        var directory = new DirectoryInfo(Path.GetFullPath(root));
        if (!directory.Exists) return "missing";
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) return "the folder is a link";
        var security = directory.GetAccessControl();
        if (!security.AreAccessRulesProtected) return "the folder inherits permissions";
        if (!Trusted(security.GetOwner(typeof(SecurityIdentifier)))) return "the folder owner is not Administrators";
        if (Writers(security) is { } writer) return writer + " can change the folder";
        if (!Limited(security, OwnerRights)) return "the folder does not limit owner rights";
        foreach (var entry in directory.EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false }))
        {
            if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) return entry.Name + " is a link";
            FileSystemSecurity child = entry is DirectoryInfo folder ? folder.GetAccessControl() : ((FileInfo)entry).GetAccessControl();
            if (!Trusted(child.GetOwner(typeof(SecurityIdentifier))) && !Limited(child, OwnerRights)) return entry.Name + " has an untrusted owner";
            if (Writers(child) is { } childWriter) return childWriter + " can change " + entry.Name;
        }
        return null;
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
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UnauthorizedAccessException("The saved rules folder is a link. Delete " + root + " and save your rules again.");
        foreach (var entry in new FileSystemInfo[] { directory }.Concat(directory.EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false })))
        {
            if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint) || !Trusted((entry is DirectoryInfo folder ? (FileSystemSecurity)folder.GetAccessControl() : ((FileInfo)entry).GetAccessControl()).GetOwner(typeof(SecurityIdentifier))))
                throw new UnauthorizedAccessException("The saved rules folder has files the app did not write with administrator rights (" + entry.FullName + "). Delete " + root + " and save your rules again.");
        }
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
    private PolicyRootLease(SafeFileHandle handle) => _handle = handle;

    public static PolicyRootLease Acquire(string root)
    {
        root = Path.GetFullPath(root);
        var handle = CreateFile(root, 0x80, 0x1 | 0x2, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new IOException("The saved rules folder could not be opened: " + new Win32Exception(error).Message);
        }
        try { PolicyRootSecurity.RequireSecured(root); }
        catch { handle.Dispose(); throw; }
        return new(handle);
    }

    public void Dispose() => _handle.Dispose();

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
