#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace RooIndustries.Optimizer;

internal static class WindowsPermissions
{
    public static void Restore(SafeHandle handle, uint objectType, byte[] security)
    {
        var descriptor = Marshal.AllocHGlobal(security.Length);
        try
        {
            Marshal.Copy(security, 0, descriptor, security.Length);
            if (!GetSecurityDescriptorOwner(descriptor, out var owner, out _)) throw Error("GetSecurityDescriptorOwner");
            if (!GetSecurityDescriptorGroup(descriptor, out var group, out _)) throw Error("GetSecurityDescriptorGroup");
            if (!GetSecurityDescriptorDacl(descriptor, out var present, out var dacl, out _)) throw Error("GetSecurityDescriptorDacl");
            if (!present) throw new InvalidDataException("An absent DACL requires a separate recovery contract.");
            var control = unchecked((ushort)Marshal.ReadInt16(descriptor, 2));
            if (objectType == 4 && (control & 0x400) == 0)
            {
                var information = 7u | ((control & 0x1000) != 0 ? 0x80000000u : 0u);
                var result = RegSetKeySecurity(handle, information, security);
                if (result != 0) throw new Win32Exception(result, "RegSetKeySecurity failed: " + result);
                return;
            }
            var protection = (control & 0x1000) != 0 ? 0x80000000u : 0x20000000u;
            var status = SetSecurityInfo(handle, objectType, 7 | protection, owner, group, dacl, IntPtr.Zero);
            if (status != 0) throw new Win32Exception((int)status, "SetSecurityInfo failed: " + status);
        }
        finally { Marshal.FreeHGlobal(descriptor); }
    }

    private static Win32Exception Error(string api) => new(Marshal.GetLastWin32Error(), api + " failed.");
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetSecurityDescriptorOwner(IntPtr security, out IntPtr owner, out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetSecurityDescriptorGroup(IntPtr security, out IntPtr group, out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetSecurityDescriptorDacl(IntPtr security, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll")] static extern uint SetSecurityInfo(SafeHandle handle, uint objectType, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(SafeHandle handle, uint information, byte[] descriptor);
}
