using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Roo.Optimization.CpuSets
{
    public sealed class NativeFailure : Win32Exception
    {
        public string Api { get; private set; }
        public uint RequestedAccess { get; private set; }
        public NativeFailure(string api, int error, uint access)
            : base(error, api + " failed with Win32 " + error + " (access 0x" + access.ToString("X4") + "): " + new Win32Exception(error).Message)
        { Api = api; RequestedAccess = access; }
    }

    public sealed class CpuSet
    {
        public uint id;
        public ushort group;
        public byte logicalProcessorIndex, coreIndex, lastLevelCacheIndex, numaNodeIndex, efficiencyClass, schedulingClass;
        public bool parked, allocated, allocatedToTargetProcess, realTime;
    }

    public sealed class ProcessIdentity
    {
        public int processId;
        public string executablePath, creationTimeFileTimeUtc, startTimeUtc;
    }

    public sealed class ProtectionInfo
    {
        public bool known;
        public uint level;
        public int win32Error;
        public bool protectedProcess;
    }

    internal sealed class ProcessHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal ProcessHandle(IntPtr value) : base(true) { SetHandle(value); }
        protected override bool ReleaseHandle() { return Native.CloseHandle(handle); }
    }

    internal static class Native
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern bool QueryFullProcessImageName(ProcessHandle process, uint flags, StringBuilder name, ref uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetProcessTimes(ProcessHandle process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(ProcessHandle process, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetProcessInformation(ProcessHandle process, int informationClass, out uint level, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetProcessDefaultCpuSets(ProcessHandle process, [Out] uint[] ids, uint count, out uint required);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetProcessDefaultCpuSets(ProcessHandle process, uint[] ids, uint count);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetSystemCpuSetInformation(IntPtr buffer, uint length, out uint returned, IntPtr process, uint flags);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenThreadToken(IntPtr thread, uint access, bool openAsSelf, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CreateRestrictedToken(IntPtr token, uint flags, uint disabledCount, IntPtr disabled,
            uint deletedCount, IntPtr deleted, uint restrictedCount, IntPtr restricted, out IntPtr result);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool ImpersonateLoggedOnUser(IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool SetThreadToken(IntPtr thread, IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool RevertToSelf();

        internal static ProcessHandle OpenWithoutPrivileges(uint access, int processId)
        {
            IntPtr previous = IntPtr.Zero, primary = IntPtr.Zero, restricted = IntPtr.Zero;
            ProcessHandle result = null;
            bool impersonating = false;
            try
            {
                // Preserve a caller's existing impersonation instead of substituting
                // the host process identity. Pseudo-handles -2/-1 are current thread/process.
                if (!OpenThreadToken(new IntPtr(-2), 0x000e, true, out previous))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != 1008) throw new NativeFailure("OpenThreadToken", error, 0x000e);
                    if (!OpenProcessToken(new IntPtr(-1), 0x000a, out primary))
                        throw new NativeFailure("OpenProcessToken", Marshal.GetLastWin32Error(), 0x000a);
                }
                IntPtr source = previous != IntPtr.Zero ? previous : primary;
                // DISABLE_MAX_PRIVILEGE removes ambient debug/ownership privileges
                // from this access check. No restricting SID or policy-bypass flag is used.
                if (!CreateRestrictedToken(source, 0x1, 0, IntPtr.Zero, 0, IntPtr.Zero, 0, IntPtr.Zero, out restricted))
                    throw new NativeFailure("CreateRestrictedToken", Marshal.GetLastWin32Error(), 0x000a);
                if (!ImpersonateLoggedOnUser(restricted))
                    throw new NativeFailure("ImpersonateLoggedOnUser", Marshal.GetLastWin32Error(), 0x000a);
                impersonating = true;
                IntPtr raw = OpenProcess(access, false, processId);
                if (raw == IntPtr.Zero) throw new NativeFailure("OpenProcess", Marshal.GetLastWin32Error(), access);
                result = new ProcessHandle(raw);
            }
            finally
            {
                try
                {
                    if (impersonating && !(previous == IntPtr.Zero ? RevertToSelf() : SetThreadToken(IntPtr.Zero, previous)))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (result != null) result.Dispose();
                        throw new NativeFailure("RestoreThreadToken", error, 0x0004);
                    }
                }
                finally
                {
                    if (restricted != IntPtr.Zero) CloseHandle(restricted);
                    if (primary != IntPtr.Zero) CloseHandle(primary);
                    if (previous != IntPtr.Zero) CloseHandle(previous);
                }
            }
            return result;
        }
    }

    // Retain one minimally privileged handle from identity verification through read/write/readback.
    public sealed class Target : IDisposable
    {
        public const uint QueryAccess = 0x101000;
        public const uint ChangeAccess = 0x103000;
        private readonly ProcessHandle handle;
        private readonly uint access;
        private readonly int pid;

        public Target(int processId, bool writable)
        {
            if (processId <= 0) throw new ArgumentOutOfRangeException("processId");
            access = writable ? ChangeAccess : QueryAccess;
            handle = Native.OpenWithoutPrivileges(access, processId);
            pid = processId;
        }

        public ProcessIdentity Identity()
        {
            uint wait = Native.WaitForSingleObject(handle, 0);
            if (wait == 0) throw new InvalidOperationException("The target process has exited.");
            if (wait != 258) throw new NativeFailure("WaitForSingleObject", Marshal.GetLastWin32Error(), access);
            long creation, exit, kernel, user;
            if (!Native.GetProcessTimes(handle, out creation, out exit, out kernel, out user))
                throw new NativeFailure("GetProcessTimes", Marshal.GetLastWin32Error(), access);
            uint capacity = 32768;
            StringBuilder image = new StringBuilder((int)capacity);
            if (!Native.QueryFullProcessImageName(handle, 0, image, ref capacity))
                throw new NativeFailure("QueryFullProcessImageName", Marshal.GetLastWin32Error(), access);
            return new ProcessIdentity { processId = pid, executablePath = image.ToString(),
                creationTimeFileTimeUtc = creation.ToString(CultureInfo.InvariantCulture),
                startTimeUtc = DateTime.FromFileTimeUtc(creation).ToString("o") };
        }

        public ProtectionInfo Protection()
        {
            uint level;
            if (!Native.GetProcessInformation(handle, 7, out level, 4))
                return new ProtectionInfo { known = false, win32Error = Marshal.GetLastWin32Error() };
            return new ProtectionInfo { known = true, level = level, protectedProcess = level != 0xfffffffe };
        }

        public uint[] Read()
        {
            uint required;
            bool ok = Native.GetProcessDefaultCpuSets(handle, null, 0, out required);
            int error = Marshal.GetLastWin32Error();
            if (!ok && error != 122) throw new NativeFailure("GetProcessDefaultCpuSets", error, access);
            for (int attempt = 0; attempt < 4; attempt++)
            {
                if (required == 0) return new uint[0];
                if (required > 1048576) throw new InvalidOperationException("Invalid CPU Set ID count.");
                uint[] ids = new uint[(int)required];
                uint capacity = required;
                ok = Native.GetProcessDefaultCpuSets(handle, ids, capacity, out required);
                error = Marshal.GetLastWin32Error();
                if (ok)
                {
                    if (required > capacity) throw new InvalidOperationException("CPU Set count exceeded the returned buffer.");
                    Array.Resize(ref ids, (int)required);
                    Array.Sort(ids);
                    return ids;
                }
                if (error != 122) throw new NativeFailure("GetProcessDefaultCpuSets", error, access);
            }
            throw new InvalidOperationException("CPU Set assignment changed repeatedly during query; retry preview.");
        }

        public CpuSet[] Topology()
        {
            bool retained = false;
            try
            {
                handle.DangerousAddRef(ref retained);
                return TopologyReader.Read(handle.DangerousGetHandle(), access);
            }
            finally { if (retained) handle.DangerousRelease(); }
        }

        public void Write(uint[] ids)
        {
            if (access != ChangeAccess) throw new InvalidOperationException("This target was opened for detection only.");
            if (ids == null) throw new ArgumentNullException("ids");
            Identity();
            HashSet<uint> available = new HashSet<uint>();
            foreach (CpuSet set in Topology())
                if (!set.allocated || set.allocatedToTargetProcess) available.Add(set.id);
            HashSet<uint> unique = new HashSet<uint>();
            foreach (uint id in ids)
            {
                if (!unique.Add(id)) throw new ArgumentException("Duplicate CPU Set ID: " + id);
                if (!available.Contains(id)) throw new ArgumentException("CPU Set is unavailable or reserved for another process: " + id);
            }
            if (!Native.SetProcessDefaultCpuSets(handle, ids.Length == 0 ? null : ids, (uint)ids.Length))
                throw new NativeFailure("SetProcessDefaultCpuSets", Marshal.GetLastWin32Error(), access);
        }

        public void Dispose() { handle.Dispose(); }
    }

    public static class TopologyReader
    {
        public static CpuSet[] ReadSystem() { return Read(IntPtr.Zero, 0); }

        internal static CpuSet[] Read(IntPtr target, uint access)
        {
            uint required;
            bool ok = Native.GetSystemCpuSetInformation(IntPtr.Zero, 0, out required, target, 0);
            int error = Marshal.GetLastWin32Error();
            if (!ok && error != 122) throw new NativeFailure("GetSystemCpuSetInformation", error, access);
            for (int attempt = 0; attempt < 4; attempt++)
            {
                if (required == 0) return new CpuSet[0];
                if (required > 16777216) throw new InvalidOperationException("Invalid CPU Set topology size.");
                uint capacity = required;
                IntPtr buffer = Marshal.AllocHGlobal((int)capacity);
                try
                {
                    ok = Native.GetSystemCpuSetInformation(buffer, capacity, out required, target, 0);
                    error = Marshal.GetLastWin32Error();
                    if (ok)
                    {
                        if (required > capacity) throw new InvalidOperationException("Topology exceeded the returned buffer.");
                        byte[] bytes = new byte[(int)required];
                        Marshal.Copy(buffer, bytes, 0, bytes.Length);
                        return Parse(bytes);
                    }
                    if (error != 122) throw new NativeFailure("GetSystemCpuSetInformation", error, access);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("Topology changed repeatedly during query; retry preview.");
        }

        public static CpuSet[] Parse(byte[] bytes)
        {
            if (bytes == null) throw new ArgumentNullException("bytes");
            List<CpuSet> sets = new List<CpuSet>();
            HashSet<uint> ids = new HashSet<uint>();
            int offset = 0;
            while (offset < bytes.Length)
            {
                if (bytes.Length - offset < 8) throw new ArgumentException("Truncated CPU Set record header.");
                uint size = BitConverter.ToUInt32(bytes, offset);
                uint type = BitConverter.ToUInt32(bytes, offset + 4);
                if (size < 8 || size > bytes.Length - offset) throw new ArgumentException("Invalid CPU Set record size.");
                if (type == 0)
                {
                    if (size < 32) throw new ArgumentException("Truncated CPU Set information record.");
                    uint id = BitConverter.ToUInt32(bytes, offset + 8);
                    if (!ids.Add(id)) throw new ArgumentException("Duplicate CPU Set topology ID.");
                    byte flags = bytes[offset + 19];
                    sets.Add(new CpuSet { id = id, group = BitConverter.ToUInt16(bytes, offset + 12),
                        logicalProcessorIndex = bytes[offset + 14], coreIndex = bytes[offset + 15],
                        lastLevelCacheIndex = bytes[offset + 16], numaNodeIndex = bytes[offset + 17],
                        efficiencyClass = bytes[offset + 18], schedulingClass = bytes[offset + 20],
                        parked = (flags & 1) != 0, allocated = (flags & 2) != 0,
                        allocatedToTargetProcess = (flags & 4) != 0, realTime = (flags & 8) != 0 });
                }
                offset += (int)size;
            }
            return sets.ToArray();
        }
    }
}
