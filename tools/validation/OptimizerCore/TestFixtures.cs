using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class TestFixtures
{
    public const string VolumeFile = "roo-industries-fixture.vhdx";
    private static readonly Dictionary<string, FileStream> Runs = new(StringComparer.OrdinalIgnoreCase);

    public static string InheritingRoot(string label)
    {
        Sweep(label);
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-" + label + "-" + Guid.NewGuid().ToString("N"));
        var run = new FileStream(root + ".run", FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
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
        DiskPart(root,
            "create vdisk file=\"" + file + "\" maximum=16 type=expandable",
            "select vdisk file=\"" + file + "\"",
            "attach vdisk",
            "create partition primary",
            "format fs=ntfs quick label=RooIndustries",
            "remove all noerr",
            "assign mount=\"" + mount + "\"");
        var name = new StringBuilder(64);
        if (!GetVolumeNameForVolumeMountPoint(mount + "\\", name, (uint)name.Capacity)) throw new Win32Exception();
        return (mount, name.ToString());
    }

    public static void Remove(string root)
    {
        lock (Runs) if (Runs.Remove(root, out var run)) run.Dispose();
        if (Directory.Exists(root))
        {
            var links = LocalTree.Entries(root, links: true).Where(entry => entry.Attributes.HasFlag(FileAttributes.ReparsePoint));
            foreach (var link in links.ToArray()) Unlink(link.FullName);
            foreach (var volume in LocalTree.Entries(root, VolumeFile).OfType<FileInfo>().ToArray())
                DiskPart(root, "select vdisk file=\"" + volume.FullName + "\"", "detach vdisk noerr");
            Directory.Delete(root, true);
        }
        File.Delete(root + ".run");
        if (Path.Exists(root)) throw new IOException("The fixture is still on disk after cleanup: " + root);
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
            try { new FileStream(stale + ".run", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None).Dispose(); }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { continue; }
            Remove(stale);
        }
    }

    private static void DiskPart(string root, params string[] commands)
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
            if (diskpart.ExitCode != 0)
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
