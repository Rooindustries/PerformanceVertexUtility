param([Parameter(Mandatory)][string]$OutCsv, [Parameter(Mandatory)][string]$StopFile)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Threading; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class RooIndustriesProcPoll {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PE32 { public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile; }
  [StructLayout(LayoutKind.Sequential)] struct US { public ushort Length, MaximumLength; public IntPtr Buffer; }
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint f, uint p);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr s, ref PE32 e);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr s, ref PE32 e);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
  [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h, out long c, out long e, out long k, out long u);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr buf, int len, out int ret);
  class P { public uint pid, ppid; public string name, cmd; public long create; public IntPtr h; }
  static string Q(string s) { return s == null ? "" : "\"" + s.Replace("\"", "\"\"").Replace("\r", " ").Replace("\n", " ") + "\""; }
  static string Cmd(IntPtr h) {
    IntPtr buf = Marshal.AllocHGlobal(65536);
    try { int ret; if (NtQueryInformationProcess(h, 60, buf, 65536, out ret) != 0) return "<unreadable>"; var us = (US)Marshal.PtrToStructure(buf, typeof(US)); return Marshal.PtrToStringUni(us.Buffer, us.Length / 2); }
    finally { Marshal.FreeHGlobal(buf); }
  }
  static List<PE32> Snap() {
    var l = new List<PE32>(); IntPtr s = CreateToolhelp32Snapshot(2, 0); var e = new PE32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PE32));
    if (Process32FirstW(s, ref e)) do { l.Add(e); e = new PE32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PE32)); } while (Process32NextW(s, ref e));
    CloseHandle(s); return l;
  }
  public static void Run(string path, string stopFile, int intervalMs) {
    var w = new StreamWriter(path, false, new UTF8Encoding(false));
    w.WriteLine("pid,ppid,name,create_filetime,exit_filetime,exit_code,cpu_ms,first_seen_filetime,command_line"); w.Flush();
    var baseline = new HashSet<uint>(); var tracked = new Dictionary<uint, P>(); long start = DateTime.UtcNow.ToFileTimeUtc();
    foreach (var e in Snap()) baseline.Add(e.th32ProcessID);
    File.WriteAllText(path + ".ready", start.ToString());
    int loops = 0; long maxLoopTicks = 0;
    while (true) {
      bool stopping = File.Exists(stopFile);
      var t0 = DateTime.UtcNow.Ticks;
      var snap = Snap(); var seen = new HashSet<uint>();
      foreach (var e in snap) {
        seen.Add(e.th32ProcessID);
        if (baseline.Contains(e.th32ProcessID) || tracked.ContainsKey(e.th32ProcessID)) continue;
        var p = new P { pid = e.th32ProcessID, ppid = e.th32ParentProcessID, name = e.szExeFile };
        p.h = OpenProcess(0x1000 | 0x100000, false, p.pid);
        long c, x, k, u; if (p.h != IntPtr.Zero && GetProcessTimes(p.h, out c, out x, out k, out u)) p.create = c;
        p.cmd = p.h != IntPtr.Zero ? Cmd(p.h) : "<no access>";
        w.WriteLine(p.pid + "," + p.ppid + "," + Q(p.name) + "," + p.create + ",,,," + DateTime.UtcNow.ToFileTimeUtc() + "," + Q(p.cmd)); w.Flush();
        tracked[p.pid] = p;
      }
      baseline.IntersectWith(seen);
      var gone = new List<uint>();
      foreach (var p in tracked.Values) {
        if (p.h == IntPtr.Zero) { if (!seen.Contains(p.pid)) { w.WriteLine(p.pid + "," + p.ppid + "," + Q(p.name) + "," + p.create + "," + DateTime.UtcNow.ToFileTimeUtc() + ",noaccess,,,"); gone.Add(p.pid); } continue; }
        if (WaitForSingleObject(p.h, 0) == 0 || stopping) {
          long c, x, k, u; uint code = 0; GetProcessTimes(p.h, out c, out x, out k, out u); GetExitCodeProcess(p.h, out code);
          bool exited = WaitForSingleObject(p.h, 0) == 0;
          w.WriteLine(p.pid + "," + p.ppid + "," + Q(p.name) + "," + p.create + "," + (exited ? x.ToString() : "") + "," + (exited ? code.ToString() : "running") + "," + ((k + u) / 10000) + ",,");
          CloseHandle(p.h); gone.Add(p.pid);
        }
      }
      foreach (var g in gone) tracked.Remove(g);
      w.Flush(); loops++; maxLoopTicks = Math.Max(maxLoopTicks, DateTime.UtcNow.Ticks - t0);
      if (stopping) break;
      Thread.Sleep(intervalMs);
    }
    w.WriteLine("#loops=" + loops + " maxLoopMs=" + (maxLoopTicks / 10000)); w.Dispose();
  }
}
'@
[RooIndustriesProcPoll]::Run($OutCsv, $StopFile, 20)
