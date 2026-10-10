using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class BackgroundPriority
{
    private const uint SetInformation = 0x0200;
    private const uint QueryLimited = 0x1000;
    private readonly object _gate = new();
    private readonly List<SafeProcessHandle> _roots = new();
    private bool _raised;

    public void Register(Process process)
    {
        lock (_gate)
        {
            if (_raised) return;
            try
            {
                _roots.Add(Duplicate(process.SafeHandle));
                process.PriorityClass = ProcessPriorityClass.BelowNormal;
            }
            catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
        }
    }

    public void Raise()
    {
        lock (_gate)
        {
            if (_raised) return;
            _raised = true;
            foreach (var root in _roots)
            {
                try { if (WaitForSingleObject(root, 0) != 0) SetTree(root, ProcessPriorityClass.Normal); }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
                finally { root.Dispose(); }
            }
            _roots.Clear();
        }
    }

    private static SafeProcessHandle Duplicate(SafeProcessHandle source)
    {
        var current = GetCurrentProcess();
        if (!DuplicateHandle(current, source, current, out var copy, 0, false, 2)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return copy;
    }

    private static bool Created(SafeProcessHandle handle, out long created) => GetProcessTimes(handle, out created, out _, out _, out _);

    private static bool ChildOf(SafeProcessHandle handle, int parent)
    {
        var information = new ProcessBasicInformation();
        return NtQueryInformationProcess(handle, 0, ref information, Marshal.SizeOf<ProcessBasicInformation>(), out _) == 0 && information.InheritedFromUniqueProcessId.ToInt64() == parent;
    }

    private static void SetTree(SafeProcessHandle root, ProcessPriorityClass priority)
    {
        if (!Created(root, out var rootCreated) || !SetPriorityClass(root, (uint)priority)) return;
        var children = new Dictionary<int, List<int>>();
        var snapshot = CreateToolhelp32Snapshot(0x2, 0);
        if (snapshot != new IntPtr(-1))
        {
            try
            {
                var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
                for (var more = Process32First(snapshot, ref entry); more; more = Process32Next(snapshot, ref entry))
                {
                    if (!children.TryGetValue((int)entry.ParentProcessId, out var list)) children[(int)entry.ParentProcessId] = list = new();
                    if (entry.ProcessId != entry.ParentProcessId) list.Add((int)entry.ProcessId);
                }
            }
            finally { CloseHandle(snapshot); }
        }
        var pending = new Stack<(int Id, long Created)>(); pending.Push((GetProcessId(root), rootCreated));
        var seen = new HashSet<int>();
        while (pending.Count > 0)
        {
            var (id, parentCreated) = pending.Pop();
            if (!children.TryGetValue(id, out var list)) continue;
            foreach (var childId in list)
            {
                if (!seen.Add(childId)) continue;
                using var child = new SafeProcessHandle(OpenProcess(SetInformation | QueryLimited, false, childId), true);
                if (child.IsInvalid || !Created(child, out var created) || created < parentCreated || !ChildOf(child, id) || !SetPriorityClass(child, (uint)priority)) continue;
                pending.Push((childId, created));
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public IntPtr DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriorityBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DuplicateHandle(IntPtr sourceProcess, SafeProcessHandle source, IntPtr targetProcess, out SafeProcessHandle target, uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int processId);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);
    [DllImport("kernel32.dll")] private static extern int GetProcessId(SafeProcessHandle handle);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetPriorityClass(SafeProcessHandle handle, uint priority);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetProcessTimes(SafeProcessHandle handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(SafeProcessHandle handle, int informationClass, ref ProcessBasicInformation information, int size, out int returned);
}
