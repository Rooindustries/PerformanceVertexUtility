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
        private readonly bool ownsJob = true;
        private readonly int rootId;
        private readonly Dictionary<int, Tracked> tracked = new Dictionary<int, Tracked>();
        private readonly HashSet<int> ignored = new HashSet<int>();
        private static readonly HashSet<string> ShellHosts = new HashSet<string>(new[] { "explorer.exe", "msedge.exe", "chrome.exe", "firefox.exe", "brave.exe", "opera.exe", "iexplore.exe" }, StringComparer.OrdinalIgnoreCase);

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
            if (handle == IntPtr.Zero) { int error = Marshal.GetLastWin32Error(); if (job != IntPtr.Zero) CloseHandle(job); throw new Win32Exception(error, "The remover process could not be observed."); }
            long created;
            if (!Created(handle, out created)) { int error = Marshal.GetLastWin32Error(); CloseHandle(handle); if (job != IntPtr.Zero) CloseHandle(job); throw new Win32Exception(error, "The remover start time could not be read."); }
            tracked[rootId] = new Tracked { Handle = handle, Created = created, Member = Member(rootId, created, System.IO.Path.GetFileName(root.StartInfo.FileName)) };
        }

        public Tree(Launch launch)
        {
            rootId = launch.Id;
            job = launch.JobHandle;
            ownsJob = false;
            Contained = true;
            IntPtr handle = OpenProcess(0x101000, false, rootId);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover process could not be observed.");
            long created;
            if (!Created(handle, out created)) { int error = Marshal.GetLastWin32Error(); CloseHandle(handle); throw new Win32Exception(error, "The remover start time could not be read."); }
            tracked[rootId] = new Tracked { Handle = handle, Created = created, Member = Member(rootId, created, System.IO.Path.GetFileName(launch.FileName)) };
        }

        public void Refresh()
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(2);
            bool added = true;
            while (added && DateTime.UtcNow < deadline)
            {
                added = false;
                List<Entry> snapshot = Snapshot();
                HashSet<int> members = new HashSet<int>(JobProcessIds());
                foreach (Entry entry in snapshot)
                {
                    if (tracked.ContainsKey(entry.ProcessId) || ignored.Contains(entry.ProcessId)) continue;
                    Tracked parent;
                    bool child = tracked.TryGetValue(entry.ParentProcessId, out parent);
                    bool shellChild = ignored.Contains(entry.ParentProcessId);
                    if (!members.Contains(entry.ProcessId) && !child && !shellChild) continue;
                    if (shellChild || ShellHosts.Contains(entry.Name ?? "")) { ignored.Add(entry.ProcessId); added = true; continue; }
                    IntPtr handle = OpenProcess(0x101000, false, entry.ProcessId);
                    if (handle == IntPtr.Zero) continue;
                    long created;
                    if (!Created(handle, out created) || (!members.Contains(entry.ProcessId) && created < parent.Created)) { CloseHandle(handle); continue; }
                    tracked[entry.ProcessId] = new Tracked { Handle = handle, Created = created, Member = Member(entry.ProcessId, created, entry.Name) };
                    added = true;
                }
                if (added) System.Threading.Thread.Sleep(20);
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

        public static int Probe(int processId, string creationTimeFileTimeUtc)
        {
            IntPtr handle = OpenProcess(0x101000, false, processId);
            if (handle == IntPtr.Zero) return Marshal.GetLastWin32Error() == 87 ? 0 : 2;
            try
            {
                long created;
                if (!Created(handle, out created)) return 2;
                if (created.ToString(System.Globalization.CultureInfo.InvariantCulture) != creationTimeFileTimeUtc) return 0;
                uint state = WaitForSingleObject(handle, 0);
                return state == 0x102 ? 1 : state == 0 ? 0 : 2;
            }
            finally { CloseHandle(handle); }
        }

        public static bool IsRunning(int processId, string creationTimeFileTimeUtc)
        {
            return Probe(processId, creationTimeFileTimeUtc) != 0;
        }

        public void Dispose()
        {
            foreach (Tracked item in tracked.Values) CloseHandle(item.Handle);
            tracked.Clear();
            if (ownsJob && job != IntPtr.Zero) CloseHandle(job);
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

    public sealed class Launch : IDisposable
    {
        private IntPtr job, process, thread;

        public int Id { get; private set; }
        public string FileName { get; private set; }
        public string CreationTimeFileTimeUtc { get; private set; }
        public System.IO.Stream Stdout { get; private set; }
        public System.IO.Stream Stderr { get; private set; }
        public bool Resumed { get; private set; }
        public IntPtr JobHandle { get { return job; } }
        public bool HasExited { get { return WaitForSingleObject(process, 0) == 0; } }
        public int ExitCode
        {
            get
            {
                uint code;
                if (!GetExitCodeProcess(process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover exit code could not be read.");
                return unchecked((int)code);
            }
        }

        private Launch() { }

        public static Launch Suspended(string fileName, string arguments, string workingDirectory)
        {
            Launch launch = new Launch();
            launch.FileName = fileName;
            IntPtr outRead = IntPtr.Zero, outWrite = IntPtr.Zero, errorRead = IntPtr.Zero, errorWrite = IntPtr.Zero;
            try
            {
                launch.job = CreateJobObjectW(IntPtr.Zero, null);
                if (launch.job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover job could not be created.");
                ExtendedLimits limits = new ExtendedLimits();
                limits.LimitFlags = 0x2000 | 0x800;
                if (!SetInformationJobObject(launch.job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover job could not be prepared.");
                SecurityAttributes inherit = new SecurityAttributes();
                inherit.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                inherit.InheritHandle = 1;
                if (!CreatePipe(out outRead, out outWrite, ref inherit, 0) || !CreatePipe(out errorRead, out errorWrite, ref inherit, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover output pipes could not be created.");
                if (!SetHandleInformation(outRead, 1, 0) || !SetHandleInformation(errorRead, 1, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover output pipes could not be prepared.");
                StartupInfo startup = new StartupInfo();
                startup.Size = Marshal.SizeOf(typeof(StartupInfo));
                startup.Flags = 0x100;
                startup.StdInput = GetStdHandle(-10);
                startup.StdOutput = outWrite;
                startup.StdError = errorWrite;
                System.Text.StringBuilder commandLine = new System.Text.StringBuilder("\"" + fileName + "\"" + (string.IsNullOrEmpty(arguments) ? "" : " " + arguments));
                ProcessInformation info;
                if (!CreateProcessW(fileName, commandLine, IntPtr.Zero, IntPtr.Zero, true, 0x4 | 0x08000000, IntPtr.Zero, string.IsNullOrEmpty(workingDirectory) ? null : workingDirectory, ref startup, out info))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                launch.process = info.Process;
                launch.thread = info.Thread;
                launch.Id = info.ProcessId;
                if (!AssignProcessToJobObject(launch.job, launch.process))
                {
                    int error = Marshal.GetLastWin32Error();
                    TerminateProcess(launch.process, 1);
                    throw new Win32Exception(error, "The remover could not be placed in its tracking job, so it was not started.");
                }
                long created, exit, kernel, user;
                if (!GetProcessTimes(launch.process, out created, out exit, out kernel, out user))
                {
                    int error = Marshal.GetLastWin32Error();
                    TerminateProcess(launch.process, 1);
                    throw new Win32Exception(error, "The remover start time could not be read, so it was not started.");
                }
                launch.CreationTimeFileTimeUtc = created.ToString(System.Globalization.CultureInfo.InvariantCulture);
                CloseHandle(outWrite); outWrite = IntPtr.Zero;
                CloseHandle(errorWrite); errorWrite = IntPtr.Zero;
                launch.Stdout = new System.IO.FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(outRead, true), System.IO.FileAccess.Read, 4096, false); outRead = IntPtr.Zero;
                launch.Stderr = new System.IO.FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(errorRead, true), System.IO.FileAccess.Read, 4096, false); errorRead = IntPtr.Zero;
                return launch;
            }
            catch
            {
                foreach (IntPtr handle in new[] { outRead, outWrite, errorRead, errorWrite }) if (handle != IntPtr.Zero) CloseHandle(handle);
                launch.Dispose();
                throw;
            }
        }

        public void Resume()
        {
            ExtendedLimits limits = new ExtendedLimits();
            limits.LimitFlags = 0x800;
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits)))) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover job could not be released, so the remover was not started.");
            if (ResumeThread(thread) == 0xFFFFFFFF) throw new Win32Exception(Marshal.GetLastWin32Error(), "The remover could not be resumed.");
            Resumed = true;
        }

        public void Dispose()
        {
            if (Stdout != null) Stdout.Dispose();
            if (Stderr != null) Stderr.Dispose();
            if (thread != IntPtr.Zero) { CloseHandle(thread); thread = IntPtr.Zero; }
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
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

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            public int InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public short ShowWindow, Reserved2;
            public IntPtr Reserved3, StdInput, StdOutput, StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits value, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes attributes, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetStdHandle(int kind);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcessW(string application, System.Text.StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation information);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    }
}
