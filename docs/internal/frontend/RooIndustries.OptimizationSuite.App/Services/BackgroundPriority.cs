using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class BackgroundPriority
{
    private readonly object _gate = new();
    private readonly List<Process> _roots = new();
    private bool _raised;

    public void Register(Process process)
    {
        lock (_gate)
        {
            if (_raised) return;
            _roots.Add(process);
            try { process.PriorityClass = ProcessPriorityClass.BelowNormal; }
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
                try { if (!root.HasExited) SetTree(root.Id, ProcessPriorityClass.Normal); }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
            }
        }
    }

    private static void SetTree(int root, ProcessPriorityClass priority)
    {
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
        var pending = new Stack<(int Id, DateTime? ParentStarted)>(); pending.Push((root, null));
        var seen = new HashSet<int>();
        while (pending.Count > 0)
        {
            var (id, parentStarted) = pending.Pop();
            if (!seen.Add(id)) continue;
            DateTime started;
            try
            {
                using var process = Process.GetProcessById(id);
                started = process.StartTime;
                if (parentStarted is { } parent && started < parent) continue;
                process.PriorityClass = priority;
            }
            catch (Exception error) when (error is ArgumentException or InvalidOperationException or Win32Exception) { continue; }
            if (children.TryGetValue(id, out var list)) foreach (var child in list) pending.Push((child, started));
        }
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
}
