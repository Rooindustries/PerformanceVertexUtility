using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RooIndustries.Optimization.ProcessOutput
{
    public sealed class TreeMember
    {
        public int ProcessId { get; internal set; }
        public string CreationTimeFileTimeUtc { get; internal set; }
        public string Name { get; internal set; }
    }

    public sealed class Tree : IDisposable
    {
        private sealed class Tracked
        {
            internal IntPtr Handle;
            internal long Created;
            internal TreeMember Member;
        }

        private readonly IntPtr job;
        private readonly int rootId;
        private readonly Dictionary<int, Tracked> tracked = new Dictionary<int, Tracked>();

        public bool Contained { get; private set; }

        public Tree(Process root)
        {
            rootId = root.Id;
            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job != IntPtr.Zero)
            {
                ExtendedLimits limits = new ExtendedLimits();
                limits.LimitFlags = 0x800;
                if (SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
                    Contained = AssignProcessToJobObject(job, root.Handle);
            }
            IntPtr handle = OpenProcess(0x101000, false, rootId);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover process could not be observed.");
            long created;
            if (!Created(handle, out created)) { CloseHandle(handle); throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover start time could not be read."); }
            tracked[rootId] = new Tracked { Handle = handle, Created = created, Member = Member(rootId, created, System.IO.Path.GetFileName(root.StartInfo.FileName)) };
        }

        public void Refresh()
        {
            bool added = true;
            while (added)
            {
                added = false;
                List<Entry> snapshot = Snapshot();
                HashSet<int> members = new HashSet<int>(JobProcessIds());
                foreach (Entry entry in snapshot)
                {
                    if (tracked.ContainsKey(entry.ProcessId)) continue;
                    Tracked parent;
                    bool child = tracked.TryGetValue(entry.ParentProcessId, out parent);
                    if (!members.Contains(entry.ProcessId) && !child) continue;
                    IntPtr handle = OpenProcess(0x101000, false, entry.ProcessId);
                    if (handle == IntPtr.Zero) continue;
                    long created;
                    if (!Created(handle, out created) || (!members.Contains(entry.ProcessId) && created < parent.Created)) { CloseHandle(handle); continue; }
                    tracked[entry.ProcessId] = new Tracked { Handle = handle, Created = created, Member = Member(entry.ProcessId, created, entry.Name) };
                    added = true;
                }
            }
        }

        public int Count { get { return tracked.Count; } }

        public TreeMember[] Descendants()
        {
            List<TreeMember> result = new List<TreeMember>();
            foreach (KeyValuePair<int, Tracked> item in tracked) if (item.Key != rootId) result.Add(item.Value.Member);
            return result.ToArray();
        }

        public TreeMember[] Live()
        {
            List<TreeMember> result = new List<TreeMember>();
            foreach (Tracked item in tracked.Values) if (WaitForSingleObject(item.Handle, 0) == 0x102) result.Add(item.Member);
            return result.ToArray();
        }

        public static bool IsRunning(int processId, string creationTimeFileTimeUtc)
        {
            IntPtr handle = OpenProcess(0x101000, false, processId);
            if (handle == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == 87) return false;
                throw new Win32Exception(error, "Process " + processId + " could not be inspected.");
            }
            try
            {
                long created;
                if (!Created(handle, out created)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Process " + processId + " start time could not be read.");
                return created.ToString(System.Globalization.CultureInfo.InvariantCulture) == creationTimeFileTimeUtc && WaitForSingleObject(handle, 0) == 0x102;
            }
            finally { CloseHandle(handle); }
        }

        public void Dispose()
        {
            foreach (Tracked item in tracked.Values) CloseHandle(item.Handle);
            tracked.Clear();
            if (job != IntPtr.Zero) CloseHandle(job);
        }

        private static TreeMember Member(int processId, long created, string name)
        {
            return new TreeMember { ProcessId = processId, CreationTimeFileTimeUtc = created.ToString(System.Globalization.CultureInfo.InvariantCulture), Name = name };
        }

        private static bool Created(IntPtr handle, out long created)
        {
            long exit, kernel, user;
            return GetProcessTimes(handle, out created, out exit, out kernel, out user);
        }

        private int[] JobProcessIds()
        {
            if (!Contained) return new int[0];
            int capacity = 256;
            while (true)
            {
                int size = 8 + IntPtr.Size * capacity;
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (QueryInformationJobObject(job, 3, buffer, (uint)size, IntPtr.Zero))
                    {
                        int count = Marshal.ReadInt32(buffer, 4);
                        int[] ids = new int[count];
                        for (int i = 0; i < count; i++) ids[i] = (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64();
                        return ids;
                    }
                    int error = Marshal.GetLastWin32Error();
                    if (error != 234 && error != 24) throw new Win32Exception(error, "The remover job could not be listed.");
                    capacity = Math.Max(capacity * 2, Marshal.ReadInt32(buffer, 0) + 16);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }

        private struct Entry
        {
            internal int ProcessId;
            internal int ParentProcessId;
            internal string Name;
        }

        private static List<Entry> Snapshot()
        {
            IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
            if (snapshot == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Running processes could not be listed.");
            try
            {
                List<Entry> result = new List<Entry>();
                ProcessEntry entry = new ProcessEntry();
                entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
                if (!Process32FirstW(snapshot, ref entry))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 18) return result;
                    throw new Win32Exception(error, "Running processes could not be listed.");
                }
                do result.Add(new Entry { ProcessId = (int)entry.ProcessId, ParentProcessId = (int)entry.ParentProcessId, Name = entry.ExeFile });
                while (Process32NextW(snapshot, ref entry));
                int last = Marshal.GetLastWin32Error();
                if (last != 18) throw new Win32Exception(last, "Running processes could not be listed.");
                return result;
            }
            finally { CloseHandle(snapshot); }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct ProcessEntry
        {
            public uint Size, Usage, ProcessId;
            public IntPtr DefaultHeapId;
            public uint ModuleId, Threads, ParentProcessId;
            public int PriorityClassBase;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits value, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int kind, IntPtr value, uint size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    }
}
