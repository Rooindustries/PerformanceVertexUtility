#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

sealed class FilePolicyPrivileges : IDisposable
{
    private static readonly object Gate = new();
    private readonly SafeFileHandle _token;
    private readonly List<TokenPrivileges> _previous = [];
    public FilePolicyPrivileges()
    {
        Monitor.Enter(Gate);
        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out _token)) throw Error("OpenProcessToken");
            foreach (var name in new[] { "SeBackupPrivilege", "SeRestorePrivilege" })
            {
                if (!LookupPrivilegeValue(null, name, out var luid)) throw Error("LookupPrivilegeValue(" + name + ")");
                var request = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
                if (!AdjustTokenPrivileges(_token, false, ref request, Marshal.SizeOf<TokenPrivileges>(), out var previous, out _)) throw Error("AdjustTokenPrivileges(" + name + ")");
                if (Marshal.GetLastWin32Error() == 1300) throw new Win32Exception(1300, "File permission recovery requires an administrator token with " + name + ".");
                _previous.Add(previous);
            }
        }
        catch { Dispose(); throw; }
    }
    public void Dispose()
    {
        try
        {
            if (_token is not null && !_token.IsClosed)
            {
                foreach (var saved in _previous.AsEnumerable().Reverse())
                {
                    var value = saved;
                    if (value.Count != 0 && !RestoreTokenPrivileges(_token, false, ref value, 0, IntPtr.Zero, IntPtr.Zero)) throw Error("AdjustTokenPrivileges(restore)");
                }
            }
        }
        finally { _token?.Dispose(); Monitor.Exit(Gate); }
    }
    private static Win32Exception Error(string api) => new(Marshal.GetLastWin32Error(), api + " failed.");
    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] private struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(IntPtr process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool LookupPrivilegeValue(string? system, string name, out Luid luid);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AdjustTokenPrivileges(SafeFileHandle token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges request, int length, out TokenPrivileges previous, out int needed);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RestoreTokenPrivileges(SafeFileHandle token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges request, int length, IntPtr previous, IntPtr needed);
}
