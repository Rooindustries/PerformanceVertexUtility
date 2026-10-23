using System;
using System.Collections.Generic;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading;

public static class BackgroundPollingUi
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint to, bool enable);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    public static string Focus(IntPtr target)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            if (GetForegroundWindow() == target) return attempt == 0 ? "already" : "direct";
            SetForegroundWindow(target);
            if (GetForegroundWindow() == target) return "direct";
            uint ignored;
            var theirs = GetWindowThreadProcessId(GetForegroundWindow(), out ignored);
            var mine = GetCurrentThreadId();
            if (theirs != 0 && theirs != mine && AttachThreadInput(mine, theirs, true))
            {
                try { BringWindowToTop(target); SetForegroundWindow(target); }
                finally { AttachThreadInput(mine, theirs, false); }
                if (GetForegroundWindow() == target) return "attached";
            }
            Thread.Sleep(50);
        }
        return null;
    }
}

public sealed class BackgroundPollingStart
{
    public uint Pid;
    public uint Parent;
    public string Name;
    public long Created;
    public long Seen;
    public string CommandLine;
}

public sealed class BackgroundPollingWatch : IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Entry { public uint Size, Usage, ProcessId; public IntPtr Heap; public uint Module, Threads, Parent; public int Base; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string File; }
    [StructLayout(LayoutKind.Sequential)] struct Text { public ushort Length, Maximum; public IntPtr Buffer; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, IntPtr buffer, int length, out int written);

    readonly uint _parent;
    readonly object _lock = new object();
    readonly List<BackgroundPollingStart> _traced = new List<BackgroundPollingStart>();
    readonly List<BackgroundPollingStart> _polled = new List<BackgroundPollingStart>();
    readonly Dictionary<uint, IntPtr> _handles = new Dictionary<uint, IntPtr>();
    readonly ManagementEventWatcher _trace;
    readonly Thread _poller;
    volatile bool _stop;

    public BackgroundPollingWatch(uint parent)
    {
        _parent = parent;
        _trace = new ManagementEventWatcher(new WqlEventQuery("SELECT * FROM Win32_ProcessStartTrace WHERE ParentProcessID = " + parent));
        _trace.EventArrived += (sender, args) =>
        {
            var e = args.NewEvent;
            lock (_lock) _traced.Add(new BackgroundPollingStart { Pid = (uint)e["ProcessID"], Parent = (uint)e["ParentProcessID"], Name = (string)e["ProcessName"], Created = (long)(ulong)e["TIME_CREATED"], Seen = DateTime.UtcNow.ToFileTimeUtc() });
        };
        _trace.Start();
        _poller = new Thread(Poll) { IsBackground = true };
        _poller.Start();
    }

    public BackgroundPollingStart[] Traced() { lock (_lock) return _traced.ToArray(); }
    public BackgroundPollingStart[] Polled() { lock (_lock) return _polled.ToArray(); }

    public bool Running(uint processId)
    {
        lock (_lock)
        {
            IntPtr handle;
            return _handles.TryGetValue(processId, out handle) && WaitForSingleObject(handle, 0) != 0;
        }
    }

    void Poll()
    {
        var known = new HashSet<uint>();
        while (!_stop)
        {
            var snapshot = CreateToolhelp32Snapshot(2, 0);
            try
            {
                var entry = new Entry { Size = (uint)Marshal.SizeOf(typeof(Entry)) };
                for (var more = Process32FirstW(snapshot, ref entry); more; more = Process32NextW(snapshot, ref entry))
                {
                    if (entry.Parent != _parent || !known.Add(entry.ProcessId)) continue;
                    var start = new BackgroundPollingStart { Pid = entry.ProcessId, Parent = entry.Parent, Name = entry.File, Seen = DateTime.UtcNow.ToFileTimeUtc() };
                    var handle = OpenProcess(0x1000 | 0x100000, false, entry.ProcessId);
                    if (handle != IntPtr.Zero)
                    {
                        long created, exited, kernel, user;
                        if (GetProcessTimes(handle, out created, out exited, out kernel, out user)) start.Created = created;
                        start.CommandLine = CommandLine(handle);
                    }
                    lock (_lock) { _polled.Add(start); if (handle != IntPtr.Zero) _handles[entry.ProcessId] = handle; }
                }
            }
            finally { CloseHandle(snapshot); }
            Thread.Sleep(10);
        }
    }

    static string CommandLine(IntPtr process)
    {
        var buffer = Marshal.AllocHGlobal(65536);
        try
        {
            int written;
            if (NtQueryInformationProcess(process, 60, buffer, 65536, out written) != 0) return null;
            var text = (Text)Marshal.PtrToStructure(buffer, typeof(Text));
            return Marshal.PtrToStringUni(text.Buffer, text.Length / 2);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public void Dispose()
    {
        _stop = true;
        _poller.Join(2000);
        _trace.Stop();
        _trace.Dispose();
        lock (_lock) { foreach (var handle in _handles.Values) CloseHandle(handle); _handles.Clear(); }
    }
}
