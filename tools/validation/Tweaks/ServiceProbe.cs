using System.Runtime.InteropServices;

static class ServiceProbe
{
    public const string Name = "RooIndustriesTweakProbe_ec3d917cb672498785218eb3d0aa790f";
    private static readonly ManualResetEventSlim Stop = new(false);
    private static readonly ServiceMain Main = Run;
    private static readonly ServiceHandler Handler = Control;
    private static IntPtr _status;
    public static void Start()
    {
        var table = new[] { new ServiceTable { Name = Name, Main = Main }, new ServiceTable() };
        if (!StartServiceCtrlDispatcher(table)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    private static void Run(uint count, IntPtr arguments)
    {
        _status = RegisterServiceCtrlHandler(Name, Handler);
        if (_status == IntPtr.Zero) return;
        Set(4); Stop.Wait(); Set(1);
    }
    private static void Control(uint code) { if (code == 1) { Set(3); Stop.Set(); } }
    private static void Set(uint state)
    {
        var status = new ServiceStatus { Type = 16, State = state, Accepted = state == 4 ? 1u : 0u, WaitHint = state == 3 ? 5000u : 0u };
        if (!SetServiceStatus(_status, ref status)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    private delegate void ServiceMain(uint count, IntPtr arguments);
    private delegate void ServiceHandler(uint control);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ServiceTable { public string? Name; public ServiceMain? Main; }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint Type, State, Accepted, Win32Exit, ServiceExit, Checkpoint, WaitHint; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool StartServiceCtrlDispatcher([In] ServiceTable[] table);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr RegisterServiceCtrlHandler(string name, ServiceHandler handler);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetServiceStatus(IntPtr handle, ref ServiceStatus status);
}
