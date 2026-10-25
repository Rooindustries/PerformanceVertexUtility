using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

static class TestFixtures
{
    public static string InheritingRoot(string label)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-" + label + "-" + Guid.NewGuid().ToString("N"));
        var directory = Directory.CreateDirectory(root);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), WindowsIdentity.GetCurrent().User! })
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(security);
        return root;
    }
}

sealed class TestVolume : IDisposable
{
    private readonly string _image;
    public string Root { get; }

    private TestVolume(string image, string root) { _image = image; Root = root; }

    public static TestVolume Create(string folder, int megabytes)
    {
        var used = DriveInfo.GetDrives().Select(drive => char.ToUpperInvariant(drive.Name[0])).ToHashSet();
        var letter = Enumerable.Range('M', 'Z' - 'M' + 1).Select(code => (char)code).Reverse().First(candidate => !used.Contains(candidate));
        var image = Path.Combine(folder, "roo-industries-volume-" + Guid.NewGuid().ToString("N") + ".vhdx");
        var volume = new TestVolume(image, letter + ":\\");
        try
        {
            DiskPart("create vdisk file=\"" + image + "\" maximum=" + megabytes + " type=expandable", "select vdisk file=\"" + image + "\"", "attach vdisk",
                "create partition primary", "format fs=ntfs quick label=RooIndustriesTest", "assign letter=" + letter);
            if (!new DriveInfo(volume.Root).IsReady || new DriveInfo(volume.Root).DriveFormat != "NTFS") throw new InvalidOperationException("The disposable test drive did not mount at " + volume.Root);
            return volume;
        }
        catch
        {
            try { volume.Dispose(); }
            catch (Exception cleanup) { Console.WriteLine("FATAL the test drive at " + image + " could not be removed: " + cleanup.Message); }
            throw;
        }
    }

    public void Dispose()
    {
        if (!File.Exists(_image)) return;
        try { DiskPart("select vdisk file=\"" + _image + "\"", "detach vdisk"); }
        finally { File.Delete(_image); }
    }

    private static void DiskPart(params string[] commands)
    {
        var script = Path.Combine(Path.GetTempPath(), "roo-industries-diskpart-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllLines(script, commands);
        try
        {
            var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "diskpart.exe"), "/s \"" + script + "\"")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            };
            using var process = System.Diagnostics.Process.Start(start) ?? throw new InvalidOperationException("diskpart did not start.");
            var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            if (!process.WaitForExit(120000)) { process.Kill(); throw new TimeoutException("diskpart did not finish."); }
            if (process.ExitCode != 0) throw new InvalidOperationException("diskpart failed (" + process.ExitCode + "): " + output);
        }
        finally { File.Delete(script); }
    }
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
