#nullable enable
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using ProcessHandle = RooIndustries.Optimization.CpuSets.ProcessHandle;
using CpuApi = RooIndustries.Optimization.CpuSets.Native;
using CpuFailure = RooIndustries.Optimization.CpuSets.NativeFailure;

namespace RooIndustries.Optimizer;

public sealed class ProcessTarget : IDisposable
{
    public static readonly string[] ControlNames = ["cpuPriority", "affinity", "cpuSets", "ioPriority", "gpuPriority", "memoryPriority", "executionQoS", "priorityBoost"];
    private readonly ProcessHandle _handle;
    private readonly uint _access;
    private readonly int _pid;
    private readonly HashSet<string> _writable;
    private readonly bool _borrowed;

    private ProcessTarget(ProcessHandle handle, int processId, uint access, HashSet<string> writable, bool borrowed = false)
    {
        _handle = handle; _pid = processId; _access = access; _writable = writable; _borrowed = borrowed;
    }

    internal static ProcessTarget CaptureGpu(int processId)
        => new(CpuApi.OpenWithoutPrivileges(0x101200, processId), processId, 0x101200, ["gpuPriority"]);

    internal static ProcessTarget ReceiveGpu(long value)
    {
        if (value <= 0) throw new InvalidDataException("Invalid retained process handle.");
        var handle = new ProcessHandle(new IntPtr(value));
        var pid = GetProcessId(handle);
        if (pid == 0) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new CpuFailure("GetProcessId", error, 0x101200); }
        return new(handle, checked((int)pid), 0x101200, ["gpuPriority"]);
    }

    internal long CopyTo(ProcessHandle destination)
    {
        if (!DuplicateHandle(new IntPtr(-1), _handle, destination, out var copy, 0, false, 2)) Fail("DuplicateHandle");
        return copy.ToInt64();
    }

    internal static ProcessHandle OpenReceiver(RunningProcess identity)
    {
        var handle = CpuApi.OpenWithoutPrivileges(0x101040, identity.ProcessId);
        try { using var target = new ProcessTarget(handle, identity.ProcessId, 0x101040, [], true); identity.Verify(target.Identity()); return handle; }
        catch { handle.Dispose(); throw; }
    }

    internal ProcessTarget Borrow(IEnumerable<string>? writable = null)
    {
        var fields = (writable ?? []).ToHashSet(StringComparer.Ordinal);
        if (!fields.IsSubsetOf(_writable)) throw new InvalidOperationException("The retained handle does not authorize these controls.");
        return new(_handle, _pid, _access, fields, true);
    }

    public ProcessTarget(int processId, IEnumerable<string>? writable = null, IEnumerable<string>? readControls = null)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException(nameof(processId));
        _writable = (writable ?? []).ToHashSet(StringComparer.Ordinal);
        if (_writable.Any(name => !ControlNames.Contains(name))) throw new InvalidDataException("Unknown process control.");
        _access = 0x1000 | 0x100000;
        if (_writable.Contains("cpuSets")) _access |= 0x2000;
        if (_writable.Any(name => name != "cpuSets")) _access |= 0x0200;
        // D3DKMT priority queries require SET_INFORMATION on the tested Windows runtime.
        if ((readControls ?? []).Contains("gpuPriority")) _access |= 0x0200;
        _pid = processId;
        _handle = CpuApi.OpenWithoutPrivileges(_access, processId);
        try { EnsureRunning(); }
        catch { _handle.Dispose(); throw; }
    }

    public RunningProcess Identity()
    {
        EnsureRunning();
        if (!CpuApi.GetProcessTimes(_handle, out var creation, out _, out _, out _)) Fail("GetProcessTimes");
        var capacity = 260;
        while (true)
        {
            var path = new StringBuilder(capacity);
            uint length = (uint)path.Capacity;
            if (CpuApi.QueryFullProcessImageName(_handle, 0, path, ref length))
                return new(_pid, creation.ToString(CultureInfo.InvariantCulture), path.ToString());
            var error = Marshal.GetLastWin32Error();
            if (error != 122 || capacity == 32768) throw new CpuFailure("QueryFullProcessImageName", error, _access);
            capacity = Math.Min(capacity * 2, 32768);
        }
    }

    public bool HasExited
    {
        get
        {
            var state = WaitForSingleObject(_handle, 0);
            if (state == 0) return true;
            if (state == 258) return false;
            Fail("WaitForSingleObject");
            return false;
        }
    }

    public ControlRead Protection() => Capture(() =>
    {
        if (!CpuApi.GetProcessInformation(_handle, 7, out var level, 4)) Fail("GetProcessInformation(ProcessProtectionLevelInfo)");
        return level;
    });

    public string UserSid()
    {
        if (!OpenProcessToken(_handle, 8, out var token)) Fail("OpenProcessToken(target user)");
        using (token)
        {
            if (GetTokenInformation(token, 1, IntPtr.Zero, 0, out var size) || Marshal.GetLastWin32Error() != 122) Fail("GetTokenInformation(size)");
            if (size is < 8 or > 65536) throw new InvalidDataException("Invalid target token information size.");
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetTokenInformation(token, 1, buffer, size, out _)) Fail("GetTokenInformation(TokenUser)");
                return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    public void RequireUnprotected()
    {
        if (Protection().Require().GetUInt32() != 0xfffffffe)
            throw new InvalidOperationException("Windows reports a protected process. Its controls are left unchanged.");
    }

    public IReadOnlyList<LogicalCpu> Topology()
    {
        EnsureRunning();
        bool retained = false;
        try
        {
            _handle.DangerousAddRef(ref retained);
            return RooIndustries.Optimization.CpuSets.TopologyReader.Read(_handle.DangerousGetHandle(), _access)
                .Select(cpu => new LogicalCpu(cpu.id, cpu.group, cpu.logicalProcessorIndex, cpu.coreIndex,
                    cpu.lastLevelCacheIndex, cpu.numaNodeIndex, cpu.efficiencyClass, cpu.parked, cpu.allocated, cpu.allocatedToTargetProcess)).ToArray();
        }
        finally { if (retained) _handle.DangerousRelease(); }
    }

    public ProcessControlSnapshot Snapshot()
        => new(Identity(), Protection(), Topology(), ControlNames.ToDictionary(name => name, Read));

    public ControlRead Read(string name)
    {
        EnsureRunning();
        return name switch
        {
            "cpuPriority" => Capture(() =>
            {
                var value = GetPriorityClass(_handle);
                if (value == 0) Fail("GetPriorityClass");
                return PriorityName(value);
            }),
            "affinity" => Capture(ReadAffinity),
            "cpuSets" => Capture(ReadCpuSets),
            "ioPriority" => Capture(() =>
            {
                var value = 0;
                CheckStatus(NtQueryInformationProcess(_handle, 33, ref value, 4, IntPtr.Zero), "NtQueryInformationProcess(ProcessIoPriority)");
                if (value is < 0 or > 3) throw new InvalidDataException("Windows returned an unsupported I/O priority value.");
                return value;
            }),
            "gpuPriority" => Capture(ReadGpu),
            "memoryPriority" => Capture(() =>
            {
                if (!GetProcessInformation(_handle, 0, out uint value, 4)) Fail("GetProcessInformation(ProcessMemoryPriority)");
                if (value is < 1 or > 5) throw new InvalidDataException("Windows returned an unsupported memory priority value.");
                return value;
            }),
            "executionQoS" => Capture(ReadPower),
            "priorityBoost" => Capture(() =>
            {
                if (!GetProcessPriorityBoost(_handle, out var disabled)) Fail("GetProcessPriorityBoost");
                return !disabled;
            }),
            _ => throw new InvalidDataException("Unknown process control: " + name),
        };
    }

    internal void Write(string name, JsonElement value)
    {
        if (!_writable.Contains(name)) throw new InvalidOperationException("This handle was not opened to change " + name + ".");
        EnsureRunning();
        switch (name)
        {
            case "cpuPriority":
                var priority = PriorityValue(value.GetString()!);
                using (priority == 0x100 ? new PrivilegeScope("Realtime CPU priority", "SeIncreaseBasePriorityPrivilege") : null)
                    if (!SetPriorityClass(_handle, priority)) Fail("SetPriorityClass");
                break;
            case "affinity":
                var affinity = value.Deserialize<AffinityState>(OperationFiles.Json) ?? throw new InvalidDataException("Affinity is missing.");
                var current = ReadAffinity();
                var mask = ParseMask(affinity.Mask);
                if (current.Group != affinity.Group || mask == 0) throw new InvalidDataException("Hard affinity must use the process's current processor group and a nonzero mask.");
                if (!GetProcessAffinityMask(_handle, out _, out var system)) Fail("GetProcessAffinityMask");
                if ((mask & ~system.ToUInt64()) != 0) throw new InvalidDataException("Affinity includes unavailable processors.");
                if (!SetProcessAffinityMask(_handle, (UIntPtr)mask)) Fail("SetProcessAffinityMask");
                break;
            case "cpuSets":
                var ids = value.Deserialize<uint[]>() ?? throw new InvalidDataException("CPU Set selection is missing.");
                var available = Topology().Where(cpu => cpu.Available).Select(cpu => cpu.Id).ToHashSet();
                if (ids.Distinct().Count() != ids.Length || ids.Any(id => !available.Contains(id)))
                    throw new InvalidDataException("CPU Set IDs are duplicated, missing or reserved.");
                if (!CpuApi.SetProcessDefaultCpuSets(_handle, ids.Length == 0 ? null : ids, (uint)ids.Length)) Fail("SetProcessDefaultCpuSets");
                break;
            case "ioPriority":
                var io = value.GetInt32();
                if (io is < 0 or > 3) throw new InvalidDataException("I/O priority is outside the supported range.");
                using (io == 3 ? new PrivilegeScope("High I/O priority", "SeIncreaseBasePriorityPrivilege") : null)
                    CheckStatus(NtSetInformationProcess(_handle, 33, ref io, 4), "NtSetInformationProcess(ProcessIoPriority)");
                break;
            case "gpuPriority":
                var gpu = value.GetInt32();
                if (gpu is < 0 or > 5) throw new InvalidDataException("GPU priority is outside the Windows range.");
                using (gpu == 5 ? new PrivilegeScope("Realtime GPU priority", "SeIncreaseBasePriorityPrivilege") : null)
                    CheckStatus(D3DKMTSetProcessSchedulingPriorityClass(_handle, gpu), "D3DKMTSetProcessSchedulingPriorityClass");
                break;
            case "memoryPriority":
                var memory = value.GetUInt32();
                if (memory is < 1 or > 5) throw new InvalidDataException("Memory priority must be between 1 and 5.");
                if (!SetProcessInformation(_handle, 0, ref memory, 4)) Fail("SetProcessInformation(ProcessMemoryPriority)");
                break;
            case "executionQoS":
                var requested = value.Deserialize<PowerThrottling>(OperationFiles.Json) ?? throw new InvalidDataException("Execution QoS is missing.");
                var power = ReadPower().WithExecutionMode(requested.ExecutionMode);
                var data = new NativePower { Version = 1, ControlMask = power.ControlMask, StateMask = power.StateMask };
                if (!SetPowerInformation(_handle, 4, ref data, 12)) Fail("SetProcessInformation(ProcessPowerThrottling)");
                break;
            case "priorityBoost":
                if (!SetProcessPriorityBoost(_handle, !value.GetBoolean())) Fail("SetProcessPriorityBoost");
                break;
            default: throw new InvalidDataException("Unknown process control: " + name);
        }
    }

    public static bool Equivalent(string name, JsonElement left, JsonElement right)
    {
        if (name == "executionQoS") return left.Deserialize<PowerThrottling>(OperationFiles.Json)?.ExecutionMode == right.Deserialize<PowerThrottling>(OperationFiles.Json)?.ExecutionMode;
        if (name == "cpuSets") return left.Deserialize<uint[]>()!.Order().SequenceEqual(right.Deserialize<uint[]>()!.Order());
        if (name == "affinity")
        {
            var first = left.Deserialize<AffinityState>(OperationFiles.Json)!;
            var second = right.Deserialize<AffinityState>(OperationFiles.Json)!;
            return first.Group == second.Group && ParseMask(first.Mask) == ParseMask(second.Mask);
        }
        return left.GetRawText() == right.GetRawText();
    }

    private AffinityState ReadAffinity()
    {
        ushort count = 64;
        var groups = new ushort[count];
        if (!GetProcessGroupAffinity(_handle, ref count, groups)) Fail("GetProcessGroupAffinity");
        if (count != 1) throw new InvalidDataException("This process spans processor groups. Use CPU Sets instead of a single hard-affinity mask.");
        if (!GetProcessAffinityMask(_handle, out var mask, out _)) Fail("GetProcessAffinityMask");
        if (mask == UIntPtr.Zero) throw new InvalidDataException("Windows did not return a usable single-group affinity mask.");
        return new(groups[0], "0x" + mask.ToUInt64().ToString("X", CultureInfo.InvariantCulture));
    }

    private uint[] ReadCpuSets()
    {
        var ids = new uint[4096];
        if (!CpuApi.GetProcessDefaultCpuSets(_handle, ids, (uint)ids.Length, out var needed)) Fail("GetProcessDefaultCpuSets");
        if (needed > ids.Length) throw new InvalidDataException("CPU Set assignment exceeded the supported query size.");
        return ids.Take((int)needed).Order().ToArray();
    }

    private PowerThrottling ReadPower()
    {
        var data = new NativePower { Version = 1 };
        if (!GetPowerInformation(_handle, 4, ref data, 12)) Fail("GetProcessInformation(ProcessPowerThrottling)");
        if (data.Version != 1) throw new InvalidDataException("Unknown power-throttling structure version.");
        return new(data.ControlMask, data.StateMask);
    }

    private int ReadGpu()
    {
        if ((_access & 0x0200) == 0)
        {
            using var query = new ProcessTarget(_pid, readControls: ["gpuPriority"]);
            Identity().Verify(query.Identity());
            return query.ReadGpu();
        }
        CheckStatus(D3DKMTGetProcessSchedulingPriorityClass(_handle, out var value), "D3DKMTGetProcessSchedulingPriorityClass");
        if (value is < 0 or > 5) throw new InvalidDataException("Windows returned an unsupported GPU priority value.");
        return value;
    }

    private ControlRead Capture<T>(Func<T> read)
    {
        try { return ControlRead.From(read()); }
        catch (CpuFailure error) { return ControlRead.Failed(new(error.Api, "win32", error.NativeErrorCode, "0x" + error.RequestedAccess.ToString("X"), error.Message)); }
        catch (NtFailure error) { return ControlRead.Failed(new(error.Api, "ntstatus", error.Code, "0x" + error.Access.ToString("X"), error.Message)); }
        catch (InvalidDataException error) { return ControlRead.Failed(new("ReadControl", "contract", 0, "0x" + _access.ToString("X"), error.Message)); }
    }

    private void EnsureRunning()
    {
        if (HasExited) throw new ProcessEndedException();
    }

    private void Fail(string api) => throw new CpuFailure(api, Marshal.GetLastWin32Error(), _access);
    private void CheckStatus(int status, string api) { if (status != 0) throw new NtFailure(api, status, _access); }
    public static ulong ParseMask(string text) => text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
        ? ulong.Parse(text[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture) : ulong.Parse(text, CultureInfo.InvariantCulture);
    private static string PriorityName(uint value) => value switch { 0x40 => "Idle", 0x4000 => "BelowNormal", 0x20 => "Normal", 0x8000 => "AboveNormal", 0x80 => "High", 0x100 => "Realtime", _ => throw new InvalidDataException("Unknown CPU priority class.") };
    private static uint PriorityValue(string name) => name switch { "Idle" => 0x40, "BelowNormal" => 0x4000, "Normal" => 0x20, "AboveNormal" => 0x8000, "High" => 0x80, "Realtime" => 0x100, _ => throw new InvalidDataException("Unknown CPU priority class.") };
    public void Dispose() { if (!_borrowed) _handle.Dispose(); }

    private sealed class NtFailure(string api, int status, uint access) : Exception(api + " failed with NTSTATUS 0x" + unchecked((uint)status).ToString("X8"))
    {
        public string Api { get; } = api;
        public uint Code { get; } = unchecked((uint)status);
        public uint Access { get; } = access;
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativePower { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetProcessId(ProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DuplicateHandle(IntPtr source, ProcessHandle handle, ProcessHandle destination, out IntPtr copy, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(ProcessHandle process, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetPriorityClass(ProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetPriorityClass(ProcessHandle process, uint value);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessAffinityMask(ProcessHandle process, out UIntPtr processMask, out UIntPtr systemMask);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetProcessAffinityMask(ProcessHandle process, UIntPtr mask);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessGroupAffinity(ProcessHandle process, ref ushort count, [Out] ushort[] groups);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessPriorityBoost(ProcessHandle process, [MarshalAs(UnmanagedType.Bool)] out bool disabled);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetProcessPriorityBoost(ProcessHandle process, [MarshalAs(UnmanagedType.Bool)] bool disabled);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessInformation(ProcessHandle process, int informationClass, out uint value, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetProcessInformation(ProcessHandle process, int informationClass, ref uint value, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetProcessInformation", SetLastError = true)] private static extern bool GetPowerInformation(ProcessHandle process, int informationClass, ref NativePower value, uint size);
    [DllImport("kernel32.dll", EntryPoint = "SetProcessInformation", SetLastError = true)] private static extern bool SetPowerInformation(ProcessHandle process, int informationClass, ref NativePower value, uint size);
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(ProcessHandle process, int informationClass, ref int value, int size, IntPtr returned);
    [DllImport("ntdll.dll")] private static extern int NtSetInformationProcess(ProcessHandle process, int informationClass, ref int value, int size);
    [DllImport("gdi32.dll")] private static extern int D3DKMTGetProcessSchedulingPriorityClass(ProcessHandle process, out int value);
    [DllImport("gdi32.dll")] private static extern int D3DKMTSetProcessSchedulingPriorityClass(ProcessHandle process, int value);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(ProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int informationClass, IntPtr buffer, int size, out int needed);
}
