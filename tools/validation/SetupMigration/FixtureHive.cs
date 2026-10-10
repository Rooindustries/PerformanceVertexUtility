using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public sealed class SetupMigrationHive : IDisposable
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegLoadAppKeyW(string file, out IntPtr key, int access, int options, int reserved);
    [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
    public static string TokenLocal()
    {
        var id = new Guid("F1B32785-6FBA-4FCF-9D55-7B8E7F157091");
        IntPtr result;
        using (var identity = WindowsIdentity.GetCurrent())
        {
            var status = SHGetKnownFolderPath(ref id, 0x4000, identity.Token, out result);
            if (status != 0) Marshal.ThrowExceptionForHR(status);
            try { return Marshal.PtrToStringUni(result); }
            finally { Marshal.FreeCoTaskMem(result); }
        }
    }
    static readonly IntPtr Users = new IntPtr(unchecked((int)0x80000003));
    IntPtr hive;
    bool mapped;
    static void Require(int status) { if (status != 0) throw new System.ComponentModel.Win32Exception(status); }
    public SetupMigrationHive(string file, string local)
    {
        Require(RegLoadAppKeyW(file, out hive, 0xF003F, 1, 0));
        try
        {
            using (var root = RegistryKey.FromHandle(new SafeRegistryHandle(hive, false), RegistryView.Registry64))
            using (var identity = WindowsIdentity.GetCurrent())
            {
                var sid = identity.User;
                if (sid == null) throw new InvalidOperationException("Missing token SID");
                using (var folders = root.CreateSubKey(sid.Value + @"\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
                {
                    folders.SetValue("Local AppData", local, RegistryValueKind.String);
                    folders.SetValue("AppData", System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Roaming"), RegistryValueKind.String);
                }
            }
            Require(RegOverridePredefKey(Users, hive));
            mapped = true;
        }
        catch { Dispose(); throw; }
    }
    public void Dispose()
    {
        if (mapped) { Require(RegOverridePredefKey(Users, IntPtr.Zero)); mapped = false; }
        if (hive != IntPtr.Zero) { Require(RegCloseKey(hive)); hive = IntPtr.Zero; }
    }
}
