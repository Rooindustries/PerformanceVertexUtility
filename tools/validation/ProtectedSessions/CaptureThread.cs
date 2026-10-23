using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

sealed record CaptureRate(double Wakes, double Cycles, double HostCpuMilliseconds)
{
    public override string ToString() => $"capture thread wakes/s={Wakes:F1} cycles/s={Cycles:F0} host CPU ms/s={HostCpuMilliseconds:F2}";
}

sealed class CaptureThread : IDisposable
{
    readonly Process _host;
    readonly SafeWaitHandle _thread;
    readonly int _id;

    internal CaptureThread(Process host)
    {
        if (IntPtr.Size != 8) throw new PlatformNotSupportedException("The capture thread probe reads 64-bit process records.");
        _host = host; host.Refresh();
        var found = new List<(int Id, SafeWaitHandle Handle)>();
        foreach (ProcessThread candidate in host.Threads)
        {
            var handle = OpenThread(0x800, false, candidate.Id);
            if (handle.IsInvalid) { handle.Dispose(); continue; }
            if (Description(handle) == "GPU launch handles") found.Add((candidate.Id, handle)); else handle.Dispose();
        }
        if (found.Count != 1) { foreach (var item in found) item.Handle.Dispose(); throw new InvalidOperationException("Expected one GPU launch capture thread in the session host; found " + found.Count + "."); }
        (_id, _thread) = found[0];
    }

    internal CaptureRate Measure(Action during)
    {
        var clock = Stopwatch.StartNew(); var before = Sample();
        during();
        var after = Sample(); var seconds = clock.Elapsed.TotalSeconds;
        return new((after.Wakes - before.Wakes) / seconds, (after.Cycles - before.Cycles) / seconds, (after.Cpu - before.Cpu).TotalMilliseconds / seconds);
    }

    (double Wakes, double Cycles, TimeSpan Cpu) Sample()
    {
        if (!QueryThreadCycleTime(_thread, out var cycles)) throw new Win32Exception(Marshal.GetLastWin32Error());
        _host.Refresh();
        return (ContextSwitches(), cycles, _host.TotalProcessorTime);
    }

    uint ContextSwitches()
    {
        for (var size = 4 << 20; ; size *= 2)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                var status = NtQuerySystemInformation(5, buffer, size, out _);
                if (status == unchecked((int)0xC0000004) && size < 256 << 20) continue;
                if (status != 0) throw new InvalidOperationException("SystemProcessInformation failed: 0x" + status.ToString("X8"));
                for (var entry = buffer; ; )
                {
                    if (Marshal.ReadIntPtr(entry, 0x50) == _host.Id)
                        for (var index = 0; index < Marshal.ReadInt32(entry, 4); index++)
                        {
                            var thread = entry + 0x100 + index * 0x50;
                            if (Marshal.ReadIntPtr(thread, 0x30) == _id) return unchecked((uint)Marshal.ReadInt32(thread, 0x40));
                        }
                    var next = Marshal.ReadInt32(entry, 0);
                    if (next == 0) throw new InvalidOperationException("The GPU launch capture thread is no longer running.");
                    entry += next;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    static string? Description(SafeWaitHandle thread)
    {
        if (GetThreadDescription(thread, out var text) < 0) return null;
        try { return Marshal.PtrToStringUni(text); } finally { LocalFree(text); }
    }

    public void Dispose() => _thread.Dispose();
    [DllImport("kernel32.dll", SetLastError = true)] static extern SafeWaitHandle OpenThread(uint access, bool inherit, int id);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(SafeWaitHandle thread, out IntPtr text);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryThreadCycleTime(SafeWaitHandle thread, out ulong cycles);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int kind, IntPtr data, int size, out int needed);
}
