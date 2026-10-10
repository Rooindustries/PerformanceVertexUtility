using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public sealed class RooIndustriesClaimsHive : IDisposable
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegLoadAppKeyW(string file, out IntPtr key, int access, int options, int reserved);
    [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
    static readonly IntPtr Users = new IntPtr(unchecked((int)0x80000003));
    IntPtr hive;
    bool mapped;
    static void Require(int status) { if (status != 0) throw new System.ComponentModel.Win32Exception(status); }
    public RooIndustriesClaimsHive(string file, string local)
    {
        Require(RegLoadAppKeyW(file, out hive, 0xF003F, 1, 0));
        try
        {
            using (var root = RegistryKey.FromHandle(new SafeRegistryHandle(hive, false), RegistryView.Registry64))
            using (var identity = WindowsIdentity.GetCurrent())
            {
                using (var folders = root.CreateSubKey(identity.User.Value + @"\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"))
                    folders.SetValue("Local AppData", local, RegistryValueKind.String);
                using (var real = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var source = real.OpenSubKey(@"SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots"))
                using (var target = root.CreateSubKey(@"RooIndustriesClaimsMachine\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots"))
                {
                    var prefix = System.IO.Path.GetFullPath(local).TrimEnd('\\').ToUpperInvariant() + @"\";
                    if (source != null)
                        foreach (var name in source.GetValueNames())
                            if (name.StartsWith(prefix, StringComparison.Ordinal))
                                target.SetValue(name, source.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames), source.GetValueKind(name));
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
