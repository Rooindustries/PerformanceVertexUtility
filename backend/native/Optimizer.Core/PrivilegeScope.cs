#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

sealed class PrivilegeScope : IDisposable
{
    private static readonly object Gate = new();
    private readonly SafeFileHandle _token;
    private readonly List<TokenPrivileges> _previous = [];
    private bool _disposed;
    internal static Func<bool>? SimulateRestoreFailure;
    internal static Func<bool>? SimulateDisableFailure;
    public static PrivilegeScope FilePolicy() => new("File permission recovery", "SeBackupPrivilege", "SeRestorePrivilege");
    public PrivilegeScope(string operation, params string[] names)
    {
        Monitor.Enter(Gate);
        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out _token)) throw Error("OpenProcessToken");
            foreach (var name in names)
            {
                if (!LookupPrivilegeValue(null, name, out var luid)) throw Error("LookupPrivilegeValue(" + name + ")");
                var request = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 2 };
                if (!AdjustTokenPrivileges(_token, false, ref request, Marshal.SizeOf<TokenPrivileges>(), out var previous, out _)) throw Error("AdjustTokenPrivileges(" + name + ")");
                if (Marshal.GetLastWin32Error() == 1300) throw new Win32Exception(1300, operation + " requires an administrator token with " + name + ".");
                _previous.Add(previous);
            }
        }
        catch (Exception error)
        {
            try { Dispose(); }
            catch (Exception cleanup)
            {
                var message = error.Message + " A privilege could not be returned to its previous state afterwards: " + cleanup.Message;
                if (error is Win32Exception win32) throw new Win32Exception(win32.NativeErrorCode, message);
                throw new InvalidOperationException(message, error);
            }
            throw;
        }
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Win32Exception? stuck = null;
        try
        {
            if (_token is not null && !_token.IsClosed)
            {
                foreach (var saved in _previous.AsEnumerable().Reverse())
                {
                    var value = saved;
                    if (value.Count == 0) continue;
                    if (SimulateRestoreFailure?.Invoke() != true && RestoreTokenPrivileges(_token, false, ref value, 0, IntPtr.Zero, IntPtr.Zero)) continue;
                    var disable = new TokenPrivileges { Count = 1, Luid = value.Luid, Attributes = 0 };
                    if (SimulateDisableFailure?.Invoke() == true || !RestoreTokenPrivileges(_token, false, ref disable, 0, IntPtr.Zero, IntPtr.Zero)) stuck ??= Error("AdjustTokenPrivileges(disable)");
                }
            }
        }
        finally { _token?.Dispose(); Monitor.Exit(Gate); }
        if (stuck is not null) throw stuck;
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
