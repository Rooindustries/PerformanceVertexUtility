using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

sealed class FixtureScope
{
    internal string Root { get; }
    readonly string marker, evidence, sid;
    readonly Dictionary<string, (RegistryValueKind Kind, object Value)> owned = [];
    internal FixtureScope(string root, string evidenceFolder)
    {
        Root = Path.GetFullPath(root); evidence = Path.Combine(evidenceFolder, "cleanup-" + Guid.NewGuid().ToString("N") + ".json");
        marker = PolicyRootSecurity.MarkerName(Root); using var identity = WindowsIdentity.GetCurrent(); sid = identity.User!.Value;
        using var key = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
        if (Directory.Exists(Root) || File.Exists(Root) || key?.GetValueNames().Any(name => name.Equals(marker, StringComparison.OrdinalIgnoreCase) || name.Equals(marker + PolicyRootSecurity.ProtectedAtSuffix, StringComparison.OrdinalIgnoreCase)) == true) throw new InvalidOperationException("Fixture root or marker collision; preserved " + Root);
        Directory.CreateDirectory(evidenceFolder); Save("allocated");
    }
    void Save(string status, string? error = null) => File.WriteAllText(evidence, JsonSerializer.Serialize(new { Root, marker, sid, status, error, fields = owned.Select(pair => new { name = pair.Key, kind = pair.Value.Kind, value = pair.Value.Value }) }, new JsonSerializerOptions { WriteIndented = true }));
    internal void Secure(Action? action = null)
    {
        using var gate = new Mutex(false, PolicyRootSecurity.MutexName(marker)); bool held;
        try { held = gate.WaitOne(TimeSpan.FromSeconds(30)); } catch (AbandonedMutexException) { held = true; }
        if (!held) throw new TimeoutException("Fixture secure mutex timeout; receipt " + evidence);
        try
        {
            using var before = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
            if (before?.GetValueNames().Any(name => name.Equals(marker, StringComparison.OrdinalIgnoreCase) || name.Equals(marker + PolicyRootSecurity.ProtectedAtSuffix, StringComparison.OrdinalIgnoreCase)) == true || Directory.Exists(Root) || File.Exists(Root)) throw new InvalidOperationException("Fixture changed before Secure; retained " + evidence);
            var start = DateTime.UtcNow.ToFileTimeUtc(); Save("securing");
            try { if (action is null) OperationsFolder.Secure(Root); else action(); }
            finally
            {
                using var key = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
                foreach (var name in new[] { marker, marker + PolicyRootSecurity.ProtectedAtSuffix })
                {
                    if (key?.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase) != true) continue;
                    var kind = key.GetValueKind(name); var value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if (name == marker ? kind != RegistryValueKind.String || !Equals(value, sid) : kind != RegistryValueKind.QWord || value is not long time || time < start || time > DateTime.UtcNow.ToFileTimeUtc()) { Save("marker-conflict", name); throw new InvalidDataException("Unowned fixture marker retained: " + name + "; receipt " + evidence); }
                    owned[name] = (kind, value!); Save("secured");
                }
            }
        }
        finally { gate.ReleaseMutex(); }
    }
    internal void Cleanup(bool actorsFinished)
    {
        try
        {
            if (!actorsFinished) throw new InvalidOperationException("Fixture actors or recovery are unfinished.");
            if (Directory.Exists(Root))
            {
                var files=new List<string>();var pending=new Stack<string>();pending.Push(Root);
                while(pending.Count!=0){var folder=pending.Pop();if((File.GetAttributes(folder)&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Fixture cleanup refuses a reparse directory: "+folder);foreach(var entry in Directory.EnumerateFileSystemEntries(folder)){var attributes=File.GetAttributes(entry);if((attributes&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Fixture cleanup refuses a reparse entry: "+entry);if((attributes&FileAttributes.Directory)!=0)pending.Push(entry);else files.Add(entry);}}
                foreach (var path in files.Where(path=>Path.GetFileName(path).Equals("session.json",StringComparison.OrdinalIgnoreCase)))
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(path)); var state = doc.RootElement;
                    if (state.GetProperty("status").GetString() is not ("stopped" or "stoppedWithErrors") || state.GetProperty("registryStatus").GetString() != "restored" || state.GetProperty("jobStatus").GetString() != "cleared") throw new InvalidOperationException("Fixture has unfinished recovery: " + path);
                    foreach(var game in state.GetProperty("games").EnumerateArray()){
                        var identity=game.GetProperty("identity").Deserialize<RunningProcess>(OperationFiles.Json)??throw new InvalidDataException("Fixture game identity is invalid.");
                        foreach(var field in game.GetProperty("fields").EnumerateArray()){
                            var status=field.GetProperty("status").GetString();var route=field.GetProperty("route").GetString();
                            if(route switch{"launch"=>status is not ("expired" or "restartRequired"),"job"=>status!="released","native"=>status is not ("restored" or "expired"),_=>true})throw new InvalidOperationException("Fixture has unfinished control recovery: "+path);
                            if(route=="native" && (!field.TryGetProperty("journalPath",out var requiredJournal) || requiredJournal.ValueKind!=JsonValueKind.String || string.IsNullOrWhiteSpace(requiredJournal.GetString())))throw new InvalidDataException("Fixture native control lacks its recovery journal.");
                            if(field.TryGetProperty("journalPath",out var journalPath) && journalPath.ValueKind!=JsonValueKind.Null){
                                var journal=Path.GetFullPath(journalPath.GetString()!);if(!journal.StartsWith(Root.TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Fixture recovery journal is outside its root.");
                                using var saved=JsonDocument.Parse(File.ReadAllText(journal));if(saved.RootElement.GetProperty("status").GetString() is not ("restored" or "expired"))throw new InvalidOperationException("Fixture has unfinished native journal: "+journal);
                                identity.Verify(saved.RootElement.GetProperty("preview").GetProperty("identity").Deserialize<RunningProcess>(OperationFiles.Json)??throw new InvalidDataException("Fixture journal identity is invalid."));
                            }
                        }
                    }
                    foreach(var game in state.GetProperty("games").EnumerateArray())FixtureProcess.RequireExited(game.GetProperty("identity").Deserialize<RunningProcess>(OperationFiles.Json)??throw new InvalidDataException("Fixture game identity is invalid."));
                    if(!state.TryGetProperty("host",out var host))throw new InvalidDataException("Fixture recovery state lacks host identity.");
                    var hostIdentity=host.Deserialize<RunningProcess>(OperationFiles.Json)??throw new InvalidDataException("Fixture host identity is invalid.");
                    using(var hostProcess=FixtureProcess.Identity(hostIdentity,["run",Path.Combine(Path.GetDirectoryName(path)!,"request.json")],true,Path.GetDirectoryName(evidence)!)){if(hostProcess is not null && !hostProcess.Wait(0))throw new InvalidOperationException("Fixture host is still running.");}
                    var watch = Path.Combine(Path.GetDirectoryName(path)!, "watch.json");
                    if (File.Exists(watch))
                    {
                        var saved = OperationFiles.Read<ProtectedWatchReady>(watch).Watcher;
                        using var process = FixtureProcess.Identity(saved, ["watch", Path.Combine(Path.GetDirectoryName(path)!, "watch-request.json")], true, Path.GetDirectoryName(evidence)!);
                        if (process is not null && !process.Wait(20000)) throw new TimeoutException("Fixture recovery watcher is still running.");
                    }
                }
            }
            using var gate = new Mutex(false, PolicyRootSecurity.MutexName(marker)); bool held;
            try { held = gate.WaitOne(TimeSpan.FromSeconds(30)); } catch (AbandonedMutexException) { held = true; }
            if (!held) throw new TimeoutException("Fixture cleanup mutex timeout.");
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true);
                foreach (var name in new[] { marker, marker + PolicyRootSecurity.ProtectedAtSuffix })
                {
                    if (key?.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase) != true) continue;
                    if (!owned.TryGetValue(name, out var field) || key.GetValueKind(name) != field.Kind || !Equals(key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames), field.Value)) throw new InvalidDataException("Fixture marker changed; preserved " + name);
                }
                foreach (var field in owned)
                {
                    if (key?.GetValueNames().Contains(field.Key, StringComparer.OrdinalIgnoreCase) != true) continue;
                    if (key.GetValueKind(field.Key) != field.Value.Kind || !Equals(key.GetValue(field.Key, null, RegistryValueOptions.DoNotExpandEnvironmentNames), field.Value.Value)) throw new InvalidDataException("Fixture marker changed during cleanup; preserved " + field.Key);
                    key.DeleteValue(field.Key, false); key.Flush();
                    if (key.GetValueNames().Contains(field.Key, StringComparer.OrdinalIgnoreCase)) throw new IOException("Fixture marker deletion did not persist: " + field.Key);
                }
                if (Directory.Exists(Root)) Directory.Delete(Root, true);
                Save("cleaned");
            }
            finally { gate.ReleaseMutex(); }
        }
        catch (Exception error) { Save("retained", error.ToString()); throw new InvalidOperationException("Fixture cleanup incomplete; retained evidence " + evidence, error); }
    }
    internal static void AwaitRecovery(string folder,string evidence)
    {
        var watch=Path.Combine(folder,"watch.json");if(!File.Exists(watch))return;
        var identity=OperationFiles.Read<ProtectedWatchReady>(watch).Watcher;
        using var process=FixtureProcess.Identity(identity,["watch",Path.Combine(folder,"watch-request.json")],true,evidence);
        if(process is not null && !process.Wait(20000))throw new TimeoutException("Fixture recovery watcher remains live; evidence retained.");
    }
    internal static void Finish(params Action[] steps)
    {
        var errors = new List<Exception>(); foreach (var step in steps) { try { step(); } catch (Exception error) { errors.Add(error); } }
        if (errors.Count != 0) throw new AggregateException("Fixture cleanup failed; evidence retained.", errors);
    }
}

sealed class FixtureCopy(string source, string path)
{
    FileStream? held;
    internal void Create()
    {
        var handle=CreateFile(path,0xC0010000,1,IntPtr.Zero,1,0,IntPtr.Zero);
        if(handle.IsInvalid){var error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
        held=new FileStream(handle,FileAccess.ReadWrite);
        using var original=File.OpenRead(source);original.CopyTo(held);held.Flush(true);held.Position=0;
        if(Convert.ToHexString(SHA256.HashData(held))!=OperationFiles.HashFile(source))throw new InvalidDataException("Fixture executable copy hash mismatch; held receipt retained.");
        var originalId=Identity(held.SafeFileHandle);held.Dispose();held=null;
        var reader=CreateFile(path,0x80010000,1,IntPtr.Zero,3,0,IntPtr.Zero);if(reader.IsInvalid){var error=Marshal.GetLastWin32Error();reader.Dispose();throw new Win32Exception(error);}
        if(Identity(reader)!=originalId){reader.Dispose();throw new InvalidDataException("Fixture copy identity changed; foreign destination preserved.");}
        held=new FileStream(reader,FileAccess.Read);
    }
    internal void Remove()
    {
        if(held is null)return;byte delete=1;if(!SetFileInformationByHandle(held.SafeFileHandle,4,ref delete,1))throw new Win32Exception(Marshal.GetLastWin32Error());held.Dispose();held=null;
    }
    static string Identity(SafeFileHandle handle){if(!GetFileInformationByHandle(handle,out var info))throw new Win32Exception(Marshal.GetLastWin32Error());return info.volume.ToString("X8")+info.high.ToString("X8")+info.low.ToString("X8")+":"+info.created;}
    [StructLayout(LayoutKind.Sequential,Pack=4)]struct FileInfo{public uint attributes;public long created,accessed,written;public uint volume,sizeHigh,sizeLow,links,high,low;}
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FileInfo info);
    [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,SetLastError=true)]static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool SetFileInformationByHandle(SafeFileHandle file,int kind,ref byte value,uint size);
}

sealed class FixtureProcess : IDisposable
{
    readonly SafeProcessHandle handle;
    readonly string image, command;
    readonly int pid;
    string? sid;
    bool elevated, tokenElevated;
    internal long Creation { get; }
    internal object Receipt => new {pid,creationTimeFileTimeUtc=Creation.ToString(),image,command,sid,administrator=elevated,tokenElevated};
    FixtureProcess(SafeProcessHandle handle, int pid, string evidence)
    {
        Directory.CreateDirectory(evidence);
        this.pid=pid;this.handle = handle; Check(GetProcessTimes(handle, out var created, out _, out _, out _)); Creation = created;
        var buffer = new StringBuilder(32768); var size = buffer.Capacity; Check(QueryFullProcessImageName(handle, 0, buffer, ref size)); image = buffer.ToString(); command = Command(handle);
    }
    void Token()
    {
        Check(OpenProcessToken(handle, 10, out var token)); using (token) { using var identity = new WindowsIdentity(token.DangerousGetHandle()); sid = identity.User!.Value;Check(DuplicateToken(token,2,out var membership));using(membership){var administrators=new SecurityIdentifier("S-1-5-32-544");var group=new byte[administrators.BinaryLength];administrators.GetBinaryForm(group,0);Check(CheckTokenMembership(membership,group,out elevated));} var memory = Marshal.AllocHGlobal(4); try { Check(GetTokenInformation(token, 20, memory, 4, out _)); tokenElevated = Marshal.ReadInt32(memory) != 0; } finally { Marshal.FreeHGlobal(memory); } }
    }
    void Record(string evidence)=>File.WriteAllText(Path.Combine(evidence,"process-"+pid+"-"+Creation+".json"),JsonSerializer.Serialize(Receipt));
    void RejectReceipt(string evidence)=>File.WriteAllText(Path.Combine(evidence,"rejected-"+pid+"-"+Creation+".json"),JsonSerializer.Serialize(new {pid,creationTimeFileTimeUtc=Creation.ToString(),image,status="ownership-refused"}));
    internal static FixtureProcess Started(Process process, string evidence, bool persist = true)
    {
        Check(DuplicateHandle(GetCurrentProcess(), process.Handle, GetCurrentProcess(), out var held, 0, false, 2));
        try { var receipt=new FixtureProcess(held, process.Id, evidence);receipt.Token();if(persist)receipt.Record(evidence);return receipt; } catch { held.Dispose(); throw; }
    }
    internal static FixtureProcess Ready(string ready, string executable, string[] args, bool elevated, string evidence)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(ready)); var data = doc.RootElement;
        var process = Attach(data.GetProperty("pid").GetInt32(), evidence) ?? throw new InvalidDataException("Readiness process already exited.");
        try { process.Verify(executable, args, elevated); if (data.GetProperty("creationTimeFileTimeUtc").GetString() != process.Creation.ToString() || data.GetProperty("administrator").GetBoolean() != elevated) throw new InvalidDataException("Readiness identity/token contradicts native evidence."); process.Record(evidence);return process; } catch { process.RejectReceipt(evidence);process.Dispose(); throw; }
    }
    internal static FixtureProcess? Identity(RunningProcess identity, string[] args, bool elevated, string evidence)
    {
        var process = Attach(identity.ProcessId, evidence); if (process is null) return null;
        try { process.Verify(identity.ExecutablePath, args, elevated); if (process.Creation.ToString() != identity.CreationTimeFileTimeUtc) throw new InvalidDataException("Fixture process creation changed."); process.Record(evidence);return process; } catch { process.RejectReceipt(evidence);process.Dispose(); throw; }
    }
    static FixtureProcess? Attach(int pid, string evidence)
    {
        var handle = OpenProcess(0x101001, false, pid); if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); if (error == 87) return null; throw new Win32Exception(error); }
        if(WaitForSingleObject(handle,0)==0){handle.Dispose();return null;}
        try { return new FixtureProcess(handle, pid, evidence); } catch { handle.Dispose(); throw; }
    }
    void Verify(string executable, string[] args, bool expectedElevation)
    {
        using var identity = WindowsIdentity.GetCurrent(); var parsed = Arguments(command);
        if (!image.Equals(Path.GetFullPath(executable), StringComparison.OrdinalIgnoreCase) || parsed.Length != args.Length + 1 || !parsed.Skip(1).SequenceEqual(args, StringComparer.Ordinal))throw new InvalidDataException("Unowned native fixture image/command; process retained.");
        Token();if(sid!=identity.User!.Value || elevated!=expectedElevation)throw new InvalidDataException("Unowned native fixture token; process retained.");
    }
    internal static void RequireExited(RunningProcess identity)
    {
        if(identity.ProcessId<=0 || !long.TryParse(identity.CreationTimeFileTimeUtc,out var expected) || expected<=0)throw new InvalidDataException("Fixture actor identity is invalid.");
        using var handle=OpenProcess(0x101000,false,identity.ProcessId);
        if(handle.IsInvalid){var error=Marshal.GetLastWin32Error();if(error==87)return;throw new Win32Exception(error);}
        Check(GetProcessTimes(handle,out var created,out _,out _,out _));if(created!=expected)return;
        var wait=WaitForSingleObject(handle,0);if(wait==uint.MaxValue)throw new Win32Exception(Marshal.GetLastWin32Error());if(wait!=0)throw new InvalidOperationException("An exact native fixture game actor is still running.");
    }
    internal bool Wait(int milliseconds) { var result = WaitForSingleObject(handle, checked((uint)milliseconds)); if (result == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error()); return result == 0; }
    internal void Stop() { if (Wait(0)) return; Check(GetProcessTimes(handle, out var created, out _, out _, out _)); if (created != Creation || Command(handle) != command) throw new InvalidDataException("Held fixture identity changed."); Check(TerminateProcess(handle, 1)); if (!Wait(10000)) throw new TimeoutException("Owned fixture did not stop."); }
    internal static long Created(Process process) { Check(GetProcessTimes(process.SafeHandle, out var created, out _, out _, out _)); return created; }
    static string Command(SafeProcessHandle handle)
    {
        NtQueryInformationProcess(handle, 60, IntPtr.Zero, 0, out var size); if (size < 16 || size > 1 << 20) throw new InvalidDataException("Native fixture command size invalid."); var memory = Marshal.AllocHGlobal(size);
        try { var status = NtQueryInformationProcess(handle, 60, memory, size, out _); if (status < 0) throw new InvalidOperationException("Native command query failed: " + status.ToString("X8")); var length = (ushort)Marshal.ReadInt16(memory); var pointer = Marshal.ReadIntPtr(memory, IntPtr.Size == 8 ? 8 : 4); return Marshal.PtrToStringUni(pointer, length / 2)!; } finally { Marshal.FreeHGlobal(memory); }
    }
    static string[] Arguments(string command) { var pointer = CommandLineToArgvW(command, out var count); if (pointer == IntPtr.Zero) throw new Win32Exception(); try { return Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, i * IntPtr.Size))!).ToArray(); } finally { LocalFree(pointer); } }
    static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public void Dispose() => handle.Dispose();
    [DllImport("kernel32.dll", SetLastError = true)] static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(SafeProcessHandle process, out long created, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(SafeProcessHandle process, int flags, StringBuilder image, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool DuplicateHandle(IntPtr source, IntPtr handle, IntPtr target, out SafeProcessHandle copy, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(SafeProcessHandle process, uint exit);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll",SetLastError=true)]static extern bool DuplicateToken(SafeAccessTokenHandle token,int level,out SafeAccessTokenHandle copy);
    [DllImport("advapi32.dll",SetLastError=true)]static extern bool CheckTokenMembership(SafeAccessTokenHandle token,byte[] sid,out bool member);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(SafeAccessTokenHandle token, int kind, IntPtr data, int size, out int needed);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(SafeProcessHandle process, int kind, IntPtr data, int size, out int needed);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
}

static class StandardFixtureHolder
{
    internal static void SignalStop(string directory)
    {
        if((File.GetAttributes(directory)&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Holder directory changed; retained.");var path=Path.Combine(directory,"holder-stop");if(File.Exists(path))return;using var signal=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read);
    }
    internal static FixtureProcess Start(string dotnet, string dll, string path, string directory, string evidence, int seconds = 30, bool probeRead = false)
    {
        if(Directory.Exists(directory) || File.Exists(directory))throw new InvalidOperationException("Holder directory collision; preserved " + directory);
        Directory.CreateDirectory(directory);using(var identity=WindowsIdentity.GetCurrent()){var acl=new DirectoryInfo(directory).GetAccessControl();acl.AddAccessRule(new FileSystemAccessRule(identity.User!,FileSystemRights.Modify,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));new DirectoryInfo(directory).SetAccessControl(acl);}
        var ready = Path.Combine(directory, "holder-ready.json"); var stop = Path.Combine(directory, "holder-stop"); var script = Path.Combine(directory, "hold.cmd");
        var probe=probeRead?"@whoami /user /fo csv >\""+Path.Combine(directory,"holder-user.csv")+"\"\r\n@powershell.exe -NoProfile -NonInteractive -Command \"try { [IO.File]::OpenRead('"+dll+"').Dispose(); 'readable'; exit 0 } catch { $_.Exception.InnerException.GetType().FullName; $_.Exception.Message; exit 9 }\" >\""+Path.Combine(directory,"holder-source-read.txt")+"\" 2>&1\r\n@if errorlevel 9 (echo denied) else (echo readable) >\""+Path.Combine(directory,"holder-source-read.exit")+"\"\r\n":"";
        File.WriteAllText(script, probe+"@\"" + dotnet + "\" \"" + dll + "\" --hold-lock \"" + path + "\" \"" + ready + "\" \"" + stop + "\"\r\n");
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "runas.exe")) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory, RedirectStandardOutput = true, RedirectStandardError = true, Arguments = "/trustlevel:0x20000 \"cmd.exe /d /c \"" + script + "\"\"" };
        using var starter = Process.Start(info) ?? throw new InvalidOperationException("runas did not start"); using var owned = FixtureProcess.Started(starter, evidence); var output = starter.StandardOutput.ReadToEndAsync(); var errors = starter.StandardError.ReadToEndAsync();
        var watch = Stopwatch.StartNew(); try { while (!File.Exists(ready)) { if (watch.Elapsed.TotalSeconds >= seconds) throw new TimeoutException("The standard-token lock holder did not start; runas " + (starter.HasExited ? "exit " + starter.ExitCode + " " + output.GetAwaiter().GetResult() + errors.GetAwaiter().GetResult() : "is still running")); Thread.Sleep(100); } return FixtureProcess.Ready(ready, dotnet, [dll, "--hold-lock", path, ready, stop], false, evidence); }
        catch { FixtureScope.Finish(()=>owned.Stop(),()=>SignalStop(directory));throw; }
        finally { owned.Stop(); }
    }
}
