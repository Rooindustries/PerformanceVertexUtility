#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using CpuApi = Roo.Optimization.CpuSets.Native;
using ProcessHandle = Roo.Optimization.CpuSets.ProcessHandle;

namespace Roo.Optimizer;

public sealed class ProcessJob : IDisposable
{
    private readonly JobHandle _handle;
    private ProcessJob(JobHandle handle) => _handle = handle;
    public static string Name(string operationId)
    {
        if (!Guid.TryParseExact(operationId, "N", out _)) throw new InvalidDataException("Invalid session identity.");
        return "Global\\RooProtectedSession-" + operationId;
    }
    public static ProcessJob Create(string operationId)
    {
        var handle = CreateJobObject(IntPtr.Zero, Name(operationId));
        var error = Marshal.GetLastWin32Error();
        if (handle.IsInvalid) { handle.Dispose(); throw Failure(error, "CreateJobObject"); }
        if (error == 183) { handle.Dispose(); throw new InvalidOperationException("This session job already exists."); }
        return new(handle);
    }
    public static ProcessJob? Open(string operationId)
    {
        var handle = OpenJobObject(0x6, false, Name(operationId));
        if (!handle.IsInvalid) return new(handle);
        var error = Marshal.GetLastWin32Error(); handle.Dispose();
        if (error == 2) return null;
        throw Failure(error, "OpenJobObject");
    }
    public void Attach(RunningProcess expected)
    {
        using var target = new ProcessTarget(expected.ProcessId); expected.Verify(target.Identity());
        using var handle = CpuApi.OpenWithoutPrivileges(0x101101, expected.ProcessId);
        Check(CpuApi.GetProcessTimes(handle, out var creation, out _, out _, out _), "GetProcessTimes(launcher)");
        if (creation.ToString(System.Globalization.CultureInfo.InvariantCulture) != expected.CreationTimeFileTimeUtc)
            throw new InvalidDataException("Launcher identity changed before job assignment.");
        Check(AssignProcessToJobObject(_handle, handle), "AssignProcessToJobObject");
    }
    public bool Contains(int pid)
    {
        using var process = CpuApi.OpenWithoutPrivileges(0x1000, pid);
        Check(IsProcessInJob(process, _handle, out var inside), "IsProcessInJob");
        return inside;
    }
    public ulong ReadAffinity()
    {
        Check(QueryInformationJobObject(_handle, 2, out var info, (uint)Marshal.SizeOf<Limits>(), IntPtr.Zero), "QueryInformationJobObject");
        if ((info.Flags & ~0x10u) != 0) throw new InvalidOperationException("Another writer changed this session's job limits.");
        return (info.Flags & 0x10) == 0 ? 0 : info.Affinity.ToUInt64();
    }
    public void SetAffinity(ulong mask)
    {
        if (mask == 0) throw new InvalidDataException("A job affinity cannot be empty.");
        ReadAffinity();
        var info = new Limits { Flags = 0x10, Affinity = new(mask) };
        Check(SetInformationJobObject(_handle, 2, ref info, (uint)Marshal.SizeOf<Limits>()), "SetInformationJobObject(affinity)");
        if (ReadAffinity() != mask) throw new InvalidOperationException("Windows did not retain the job affinity.");
    }
    public void Clear(ulong originalMask)
    {
        SetAffinity(originalMask);
        var info = new Limits();
        Check(SetInformationJobObject(_handle, 2, ref info, (uint)Marshal.SizeOf<Limits>()), "SetInformationJobObject(clear)");
        if (ReadAffinity() != 0) throw new InvalidOperationException("The job affinity limit was not cleared.");
    }
    public void Dispose() => _handle.Dispose();
    private static void Check(bool ok, string api) { if (!ok) throw Failure(Marshal.GetLastWin32Error(), api); }
    private static Win32Exception Failure(int error, string api) => new(error, api + " failed with Win32 " + error + ": " + new Win32Exception(error).Message);
    [StructLayout(LayoutKind.Sequential)] private struct Limits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    private sealed class JobHandle() : SafeHandleZeroOrMinusOneIsInvalid(true)
    {
        protected override bool ReleaseHandle() => CloseHandle(handle);
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern JobHandle CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", EntryPoint = "OpenJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern JobHandle OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(JobHandle job, ProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool IsProcessInJob(ProcessHandle process, JobHandle job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(JobHandle job, int kind, ref Limits value, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(JobHandle job, int kind, out Limits value, uint size, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
