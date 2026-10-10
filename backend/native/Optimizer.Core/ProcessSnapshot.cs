#nullable enable
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace RooIndustries.Optimizer;

public sealed record SnapshotProcess(int ProcessId, string CreationTimeFileTimeUtc, string ImageName);

public static class ProcessSnapshot
{
    public static Dictionary<int, SnapshotProcess> Take()
    {
        if (IntPtr.Size != 8) return Fallback();
        var size = 1 << 20;
        while (true)
        {
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                var status = NtQuerySystemInformation(5, buffer, (uint)size, out var needed);
                if (status == unchecked((int)0xC0000004))
                {
                    size = Math.Max(size * 2, (int)needed + (1 << 16));
                    continue;
                }
                if (status != 0) throw new InvalidOperationException("NtQuerySystemInformation(SystemProcessInformation) failed with NTSTATUS 0x" + status.ToString("X8", CultureInfo.InvariantCulture) + ".");
                var found = new Dictionary<int, SnapshotProcess>();
                var offset = 0;
                while (true)
                {
                    var entry = buffer + offset;
                    var created = Marshal.ReadInt64(entry, 32);
                    var length = Marshal.ReadInt16(entry, 56) & 0xFFFF;
                    var name = Marshal.ReadIntPtr(entry, 64);
                    var processId = checked((int)Marshal.ReadInt64(entry, 80));
                    if (processId > 4 && name != IntPtr.Zero && length > 0)
                        found[processId] = new(processId, created.ToString(CultureInfo.InvariantCulture), Marshal.PtrToStringUni(name, length / 2));
                    var next = Marshal.ReadInt32(entry, 0);
                    if (next == 0) break;
                    offset += next;
                }
                return found;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    private static Dictionary<int, SnapshotProcess> Fallback()
    {
        var found = new Dictionary<int, SnapshotProcess>();
        foreach (var process in System.Diagnostics.Process.GetProcesses())
            using (process)
            {
                try { found[process.Id] = new(process.Id, process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(CultureInfo.InvariantCulture), process.ProcessName + ".exe"); }
                catch (Exception) { }
            }
        return found;
    }

    public static string? ImagePath(int processId)
    {
        if (IntPtr.Size != 8) return null;
        const int capacity = 32766;
        var text = Marshal.AllocHGlobal(capacity * 2);
        var info = Marshal.AllocHGlobal(24);
        try
        {
            Marshal.WriteInt64(info, 0, processId);
            Marshal.WriteInt16(info, 8, 0);
            Marshal.WriteInt16(info, 10, unchecked((short)(capacity * 2)));
            Marshal.WriteInt32(info, 12, 0);
            Marshal.WriteIntPtr(info, 16, text);
            if (NtQuerySystemInformation(88, info, 24, out _) != 0) return null;
            var length = Marshal.ReadInt16(info, 8) & 0xFFFF;
            var native = Marshal.PtrToStringUni(text, length / 2);
            foreach (var drive in Environment.GetLogicalDrives())
            {
                var name = drive.TrimEnd('\\');
                var target = new System.Text.StringBuilder(1024);
                if (QueryDosDevice(name, target, target.Capacity) == 0) continue;
                var device = target.ToString();
                if (native.StartsWith(device + "\\", StringComparison.OrdinalIgnoreCase)) return name + native[device.Length..];
            }
            return null;
        }
        finally
        {
            Marshal.FreeHGlobal(info);
            Marshal.FreeHGlobal(text);
        }
    }

    public static string? UserSid(int processId)
    {
        var level = 1u;
        if (TokenUser(processId) is { } owner) return owner;
        if (!WTSEnumerateProcessesEx(IntPtr.Zero, ref level, 0xFFFFFFFE, out var processes, out var count)) return null;
        try
        {
            var size = Marshal.SizeOf<ProcessInfo>();
            for (var index = 0; index < count; index++)
            {
                var info = Marshal.PtrToStructure<ProcessInfo>(processes + index * size);
                if (info.ProcessId == processId) return info.UserSid == IntPtr.Zero ? null : new SecurityIdentifier(info.UserSid).Value;
            }
            return null;
        }
        finally { WTSFreeMemoryEx(1, processes, (uint)count); }
    }

    private static string? TokenUser(int processId)
    {
        try
        {
            using var privilege = new PrivilegeScope("Process owner check", "SeDebugPrivilege");
            using var process = OpenProcess(0x1000, false, processId);
            if (process.IsInvalid || !OpenProcessToken(process, 8, out var token)) return null;
            using (token)
            {
                GetTokenInformation(token, 1, IntPtr.Zero, 0, out var size);
                if (size is < 8 or > 65536) return null;
                var buffer = Marshal.AllocHGlobal(size);
                try { return GetTokenInformation(token, 1, buffer, size, out _) ? new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value : null; }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        catch (System.ComponentModel.Win32Exception) { return null; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo
    {
        public uint SessionId;
        public uint ProcessId;
        public IntPtr ProcessName;
        public IntPtr UserSid;
        public uint NumberOfThreads, HandleCount, PagefileUsage, PeakPagefileUsage, WorkingSetSize, PeakWorkingSetSize;
        public long UserTime, KernelTime;
    }

    [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int kind, IntPtr data, uint size, out uint needed);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern Microsoft.Win32.SafeHandles.SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(Microsoft.Win32.SafeHandles.SafeProcessHandle process, uint access, out Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(Microsoft.Win32.SafeHandles.SafeAccessTokenHandle token, int kind, IntPtr buffer, int size, out int needed);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "QueryDosDeviceW")]
    private static extern int QueryDosDevice(string device, System.Text.StringBuilder target, int capacity);
    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "WTSEnumerateProcessesExW")]
    private static extern bool WTSEnumerateProcessesEx(IntPtr server, ref uint level, uint sessionId, out IntPtr processes, out int count);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "WTSFreeMemoryExW")]
    private static extern bool WTSFreeMemoryEx(int type, IntPtr memory, uint count);
}
