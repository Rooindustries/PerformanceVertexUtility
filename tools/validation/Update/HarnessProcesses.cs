using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class RooHarnessProcesses : IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessEntry
    {
        public uint size, usage, pid;
        public IntPtr heap;
        public uint module, threads, parent;
        public int priority;
        public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string image;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(IntPtr handle, int flags, StringBuilder path, ref int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFinalPathNameByHandleW(IntPtr handle, StringBuilder path, uint size, uint flags);
    public sealed class Held
    {
        public Process Process;
        public IntPtr Handle;
        public int Pid;
        public long Created;
        public string Image, LedgerId;
    }
    readonly Dictionary<int, Held> held = new Dictionary<int, Held>();
    readonly string ledgerPath, frameId, manifest, nonce, machine;
    readonly Thread thread;
    volatile bool stop;
    public string Error { get; private set; }
    static long Birth(IntPtr handle)
    {
        long created, exited, kernel, user;
        if (!GetProcessTimes(handle, out created, out exited, out kernel, out user)) throw new Win32Exception();
        return created;
    }
    static string Image(IntPtr handle)
    {
        var path = new StringBuilder(32768);
        int length = path.Capacity;
        if (!QueryFullProcessImageName(handle, 0, path, ref length)) throw new Win32Exception();
        IntPtr file = CreateFileW(path.ToString(), 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (file == new IntPtr(-1)) throw new Win32Exception();
        try
        {
            var result = new StringBuilder(32768);
            uint count = GetFinalPathNameByHandleW(file, result, (uint)result.Capacity, 0);
            if (count == 0 || count >= result.Capacity) throw new Win32Exception();
            return result.ToString();
        }
        finally { CloseHandle(file); }
    }
    public RooHarnessProcesses(int pid, long created, string image, string ledgerPath, string frameId, string manifest, string nonce, string machine)
    {
        this.ledgerPath = ledgerPath; this.frameId = frameId; this.manifest = manifest; this.nonce = nonce; this.machine = machine;
        Process process = Process.GetProcessById(pid);
        try
        {
            IntPtr handle = process.Handle;
            if (Birth(handle) != created || !String.Equals(Image(handle), image, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Tracking root identity changed; retained.");
            held.Add(pid, new Held { Process = process, Handle = handle, Pid = pid, Created = created, Image = image });
        }
        catch { process.Dispose(); throw; }
        thread = new Thread(Watch) { IsBackground = true };
        thread.Start();
    }
    Dictionary<int, int> Snapshot()
    {
        IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) throw new Win32Exception();
        try
        {
            var result = new Dictionary<int, int>();
            var entry = new ProcessEntry { size = (uint)Marshal.SizeOf(typeof(ProcessEntry)) };
            if (!Process32FirstW(snapshot, ref entry)) throw new Win32Exception();
            do { result[(int)entry.pid] = (int)entry.parent; } while (Process32NextW(snapshot, ref entry));
            return result;
        }
        finally { CloseHandle(snapshot); }
    }
    void Append(Held child, Held parent)
    {
        var serializer = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue, RecursionLimit = 100 };
        FileStream stream = null;
        for (int attempt = 0; ; attempt++)
        {
            try { stream = new FileStream(ledgerPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None); break; }
            catch (IOException) { if (attempt == 9) throw; Thread.Sleep(200); }
        }
        using (stream)
        {
            string text;
            using (var reader = new StreamReader(stream, new UTF8Encoding(false), true, 4096, true)) text = reader.ReadToEnd();
            var ledger = serializer.Deserialize<Dictionary<string, object>>(text);
            if ((string)ledger["frameId"] != frameId || (string)ledger["manifestSha256"] != manifest || (string)ledger["machine"] != machine) throw new InvalidOperationException("Tracking ledger scope changed; retained.");
            var entries = new List<object>();
            foreach (object entry in (IList)ledger["entries"]) entries.Add(entry);
            foreach (Dictionary<string, object> entry in entries)
            {
                if ((string)entry["kind"] != "process" || (string)entry["state"] != "active") continue;
                var metadata = entry["metadata"] as Dictionary<string, object>;
                if (metadata != null && metadata.ContainsKey("platform") && (string)metadata["platform"] == "linux") continue;
                var identity = (Dictionary<string, object>)entry["identity"];
                if (Convert.ToInt32(identity["pid"]) == child.Pid && (string)identity["creationTimeFileTimeUtc"] == child.Created.ToString() && String.Equals((string)identity["imagePath"], child.Image, StringComparison.OrdinalIgnoreCase)) { child.LedgerId = (string)entry["id"]; return; }
            }
            child.LedgerId = Guid.NewGuid().ToString("N");
            entries.Add(new Dictionary<string, object> {
                { "id", child.LedgerId }, { "nonce", nonce }, { "kind", "process" },
                { "identity", new Dictionary<string, object> { { "pid", child.Pid }, { "creationTimeFileTimeUtc", child.Created.ToString() }, { "imagePath", child.Image } } },
                { "purpose", "descendant" }, { "lifetime", "invocation" },
                { "metadata", new Dictionary<string, object> { { "parentPid", parent.Pid }, { "parentCreationTimeFileTimeUtc", parent.Created.ToString() }, { "tracker", "native-live-chain" } } },
                { "createdAtUtc", DateTime.UtcNow.ToString("o") }, { "state", "active" }, { "cleanupError", null }
            });
            ledger["entries"] = entries.ToArray();
            byte[] bytes = new UTF8Encoding(false).GetBytes(serializer.Serialize(ledger));
            stream.Position = 0; stream.SetLength(0); stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
        }
    }
    void Scan()
    {
        var processes = Snapshot();
        foreach (int pid in processes.Keys)
        {
            if (pid <= 4 || held.ContainsKey(pid)) continue;
            var chain = new List<int>();
            var seen = new HashSet<int>();
            int cursor = pid;
            while (cursor > 4 && seen.Add(cursor) && !held.ContainsKey(cursor) && processes.ContainsKey(cursor))
            {
                chain.Add(cursor); cursor = processes[cursor];
            }
            Held parent;
            if (!held.TryGetValue(cursor, out parent)) continue;
            chain.Reverse();
            foreach (int childPid in chain)
            {
                Held existing;
                if (held.TryGetValue(childPid, out existing)) { parent = existing; continue; }
                Process process = null;
                Held child;
                try
                {
                    process = Process.GetProcessById(childPid);
                    IntPtr handle = process.Handle;
                    child = new Held { Process = process, Handle = handle, Pid = childPid, Created = Birth(handle), Image = Image(handle) };
                    if (child.Created < parent.Created || process.HasExited || Birth(parent.Handle) != parent.Created) { process.Dispose(); break; }
                    int liveParent;
                    if (!Snapshot().TryGetValue(childPid, out liveParent) || liveParent != parent.Pid) { process.Dispose(); break; }
                }
                catch (ArgumentException) { if (process != null) process.Dispose(); break; }
                catch (InvalidOperationException) { if (process != null) process.Dispose(); break; }
                catch (Win32Exception) { if (process != null) process.Dispose(); break; }
                try { Append(child, parent); }
                catch { process.Dispose(); throw; }
                lock (held) held.Add(childPid, child);
                parent = child;
            }
        }
    }
    void Watch()
    {
        try { while (!stop) { Scan(); Thread.Sleep(2); } }
        catch (Exception error) { Error = error.ToString(); }
    }
    public Held[] Entries() { lock (held) { var result = new List<Held>(); foreach (var entry in held.Values) if (entry.LedgerId != null) result.Add(entry); return result.ToArray(); } }
    public void Stop() { stop = true; if (!thread.Join(5000)) throw new InvalidOperationException("Process tracker did not stop."); }
    public void Dispose() { Stop(); lock (held) { foreach (var entry in held.Values) entry.Process.Dispose(); held.Clear(); } }
}
