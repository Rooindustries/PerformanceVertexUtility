using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class FixtureCleanupChecks
{
    internal static void Run(string frame)
    {
        var evidence = Path.Combine(frame, "evidence"); Directory.CreateDirectory(evidence);
        using var user = WindowsIdentity.GetCurrent(); var sid = user.User!.Value;
        using var key = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true) ?? throw new Exception("Existing marker key required; no product key creation.");
        string Snapshot() => JsonSerializer.Serialize(key.GetValueNames().Order().Select(name => new { name, kind = key.GetValueKind(name), value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) }));
        var before = Snapshot(); File.WriteAllText(Path.Combine(frame, "registry-before.json"), before);
        var checks = new List<string>();
        void Check(bool ok, string text) { if (!ok) throw new Exception(text); checks.Add(text); Console.WriteLine("PASS " + text); }
        string NewRoot() => Path.Combine(frame, "case-" + Guid.NewGuid().ToString("N"));
        void Mark(string root) => typeof(PolicyRootSecurity).GetMethod("Mark", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!.Invoke(null, [PolicyRootSecurity.MarkerName(root), new SecurityIdentifier(sid)]);
        void Reject(Action action, string text) { try { action(); } catch (Exception error) when (error is InvalidDataException or InvalidOperationException or AggregateException or TimeoutException) { Check(true, text); return; } throw new Exception("Expected refusal: " + text); }
        var dotnet = Environment.ProcessPath!; var dll = typeof(FixtureCleanupChecks).Assembly.Location;
        var sealedBin = Path.Combine(frame, "unreadable"); Directory.CreateDirectory(sealedBin);
        var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false); acl.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
        foreach (var id in new[] { "S-1-5-18", "S-1-5-32-544" }) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(id), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-3-4"), FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(sealedBin).SetAccessControl(acl);
        foreach (var file in Directory.GetFiles(Path.GetDirectoryName(dll)!)) File.Copy(file, Path.Combine(sealedBin, Path.GetFileName(file)));
        var unreadableDll = Path.Combine(sealedBin, Path.GetFileName(dll));
        var legacy = NewRoot();var legacyScope=new FixtureScope(legacy,evidence);legacyScope.Secure(()=>{Directory.CreateDirectory(legacy);Mark(legacy);});
        try
        {
            try { StandardFixtureHolder.Start(dotnet, unreadableDll, Path.Combine(legacy, "lock"), Path.Combine(frame, "legacy-holder"), evidence, 30, true); throw new Exception("Unreadable holder unexpectedly ran"); }
            catch (TimeoutException error) { File.WriteAllText(Path.Combine(frame, "baseline-timeout.txt"), error.ToString()); }
            Check(File.ReadAllText(Path.Combine(frame,"legacy-holder","holder-source-read.txt")).Contains("System.UnauthorizedAccessException") && File.ReadAllText(Path.Combine(frame,"legacy-holder","holder-user.csv")).Contains(sid),"Native selected standard-token script reaches exact DLL and cannot read it");
            Directory.Delete(legacy, true);
            Check(key.GetValue(PolicyRootSecurity.MarkerName(legacy)) is string && key.GetValue(PolicyRootSecurity.MarkerName(legacy) + PolicyRootSecurity.ProtectedAtSuffix) is long, "Baseline exact unreadable-source timeout leaves two typed marker fields");
            File.WriteAllText(Path.Combine(frame, "registry-baseline.json"), Snapshot());
            File.WriteAllText(Path.Combine(frame, "baseline-recovery.json"), JsonSerializer.Serialize(new { legacy, legacyOwner=key.GetValue(PolicyRootSecurity.MarkerName(legacy)), legacyTime=key.GetValue(PolicyRootSecurity.MarkerName(legacy)+PolicyRootSecurity.ProtectedAtSuffix) }));
        }
        finally { legacyScope.Cleanup(true); }
        foreach (var failure in new[] { "secure-before", "secure-partial", "copy", "timeout" })
        {
            var root = NewRoot(); var scope = new FixtureScope(root, evidence);
            try
            {
                scope.Secure(() => { if (failure == "secure-before") throw new IOException("Secure before mutation"); Directory.CreateDirectory(root); if (failure == "secure-partial") { key.SetValue(PolicyRootSecurity.MarkerName(root) + PolicyRootSecurity.ProtectedAtSuffix, DateTime.UtcNow.ToFileTimeUtc(), RegistryValueKind.QWord); throw new IOException("Secure after timestamp"); } Mark(root); });
                if (failure == "copy") File.Copy(Path.Combine(frame, "absent-source.exe"), Path.Combine(root, "launcher.exe"));
                if (failure == "timeout") StandardFixtureHolder.Start(dotnet, unreadableDll, Path.Combine(root, "lock"), Path.Combine(frame, "fixed-holder"), evidence, 30, true);
            }
            catch (Exception error) when (error is IOException or TimeoutException) { File.WriteAllText(Path.Combine(evidence, failure + ".txt"), error.ToString()); }
            finally { scope.Cleanup(true); }
            if(failure=="timeout")Check(File.ReadAllText(Path.Combine(frame,"fixed-holder","holder-source-read.txt")).Contains("System.UnauthorizedAccessException"),"Fixed exact timeout reaches the same unreadable DLL");
            Check(!Directory.Exists(root) && key.GetValue(PolicyRootSecurity.MarkerName(root)) is null && key.GetValue(PolicyRootSecurity.MarkerName(root) + PolicyRootSecurity.ProtectedAtSuffix) is null && Snapshot() == before, failure + " restores exact owned fields and preserves all siblings");
        }
        var copied=Path.Combine(Path.GetDirectoryName(dll)!,"owned-copy.exe");var copy=new FixtureCopy(Path.ChangeExtension(dll,".exe"),copied);copy.Create();try{var copiedStart=new ProcessStartInfo(copied){UseShellExecute=false,CreateNoWindow=true};copiedStart.Environment["DOTNET_ROOT_X64"]=Path.GetDirectoryName(dotnet);copiedStart.ArgumentList.Add("--cleanup-sentinel");copiedStart.ArgumentList.Add(frame);using(var copyProcess=Process.Start(copiedStart)!){using var copyOwned=FixtureProcess.Started(copyProcess,evidence);try{Check(!copyProcess.HasExited,"Held native copy remains executable");}finally{copyOwned.Stop();}}Reject(()=>{try{File.WriteAllText(copied,"foreign");}catch(IOException error){throw new InvalidDataException("Held file excludes foreign writer",error);}},"Held native fixture copy refuses foreign replacement");}finally{copy.Remove();}Check(!File.Exists(copied),"Owned copied executable is removed through its held native file handle");
        var priorCopy=Path.Combine(frame,"prior-copy.exe");File.WriteAllText(priorCopy,"prior");try{try{new FixtureCopy(dll,priorCopy).Create();throw new Exception("Copy collision was accepted");}catch(System.ComponentModel.Win32Exception){Check(File.ReadAllText(priorCopy)=="prior","Preexisting launcher copy collision preserves original bytes");}}finally{File.Delete(priorCopy);}
        var partialCopy=Path.Combine(frame,"partial-copy.exe");var brokenCopy=new FixtureCopy(Path.Combine(frame,"absent-copy-source"),partialCopy);try{try{brokenCopy.Create();throw new Exception("Absent copy source accepted");}catch(FileNotFoundException){Check(File.Exists(partialCopy),"Partial native copy failure retains exact owned destination handle");}}finally{brokenCopy.Remove();}Check(!File.Exists(partialCopy),"Partial native copy is removed without touching other files");
        var readable=Path.Combine(frame,"readable-holder-source");Directory.CreateDirectory(readable);var readAcl=new DirectoryInfo(readable).GetAccessControl();readAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid),FileSystemRights.ReadAndExecute,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));new DirectoryInfo(readable).SetAccessControl(readAcl);foreach(var file in Directory.GetFiles(Path.GetDirectoryName(dll)!))File.Copy(file,Path.Combine(readable,Path.GetFileName(file)));
        var successfulDir=Path.Combine(frame,"successful-holder");using(var held=StandardFixtureHolder.Start(dotnet,Path.Combine(readable,Path.GetFileName(dll)),Path.Combine(successfulDir,"lock"),successfulDir,evidence,30,true)){try{Check(!held.Wait(0) && File.Exists(Path.Combine(successfulDir,"holder-ready.json")),"Actual standard holder is bound by native handle creation image command and token");StandardFixtureHolder.SignalStop(successfulDir);Check(held.Wait(15000),"Bound standard holder exits gracefully and releases lock");}finally{held.Stop();}}Check(!File.Exists(Path.Combine(successfulDir,"lock")),"Bound holder leaves no native file lock");
        var sentinelInfo = new ProcessStartInfo(dotnet) { UseShellExecute = false, CreateNoWindow = true }; sentinelInfo.ArgumentList.Add(dll); sentinelInfo.ArgumentList.Add("--cleanup-sentinel"); sentinelInfo.ArgumentList.Add(frame);var privateArgument="roo-private-sentinel-"+Guid.NewGuid().ToString("N");sentinelInfo.ArgumentList.Add(privateArgument);
        using var sentinel = Process.Start(sentinelInfo)!; using var owned = FixtureProcess.Started(sentinel, evidence,false);
        try
        {
        File.WriteAllText(Path.Combine(evidence, "forged-ready.json"), JsonSerializer.Serialize(new { pid = sentinel.Id, administrator = false, creationTimeFileTimeUtc = owned.Creation.ToString() }));
        Reject(() => { using var forged = FixtureProcess.Ready(Path.Combine(evidence, "forged-ready.json"), dotnet, [dll, "--hold-lock", "wrong", "wrong", "wrong"], false, evidence); }, "Forged ready PID with unrelated native command is refused");
        Check(!sentinel.HasExited, "Unrelated held sentinel survives forged readiness");
        Reject(() => { using var forged = FixtureProcess.Ready(Path.Combine(evidence, "forged-ready.json"), dotnet, [dll, "--cleanup-sentinel", frame,privateArgument], false, evidence); }, "Native elevated token contradicts forged standard-token JSON and is refused");
        Check(!sentinel.HasExited, "Sentinel survives token-validation failure");
        Check(!Directory.GetFiles(evidence,"*.json").Any(path=>File.ReadAllText(path).Contains(privateArgument)),"Unrelated same-image sentinel private argument never enters receipts");
        var conflictRoot = NewRoot(); var conflict = new FixtureScope(conflictRoot, evidence); conflict.Secure(() => { Directory.CreateDirectory(conflictRoot); Mark(conflictRoot); });
        var conflictName = PolicyRootSecurity.MarkerName(conflictRoot); var timestamp = key.GetValue(conflictName + PolicyRootSecurity.ProtectedAtSuffix);
        key.SetValue(conflictName, "foreign-owner", RegistryValueKind.ExpandString);
        Reject(() => conflict.Cleanup(true), "Foreign changed owner kind/value refuses deletion and reports conflict");
        Check(Directory.Exists(conflictRoot) && key.GetValueKind(conflictName) == RegistryValueKind.ExpandString && Equals(key.GetValue(conflictName), "foreign-owner"), "Foreign owner and fixture tree remain intact");
        key.SetValue(conflictName, sid, RegistryValueKind.String); key.SetValue(conflictName + PolicyRootSecurity.ProtectedAtSuffix, timestamp!, RegistryValueKind.QWord); conflict.Cleanup(true);
        foreach (var status in new[] { "armed", "recoveryRequired", "malformed", "missing-host" })
        {
            var root = NewRoot(); var scope = new FixtureScope(root, evidence); scope.Secure(() => { Directory.CreateDirectory(root); Mark(root); });
            File.WriteAllText(Path.Combine(root, "session.json"), status == "malformed" ? "{" : status == "missing-host" ? JsonSerializer.Serialize(new { status="stopped", registryStatus="restored", jobStatus="cleared" }) : JsonSerializer.Serialize(new { status, registryStatus = "applied", jobStatus = "applied" }));
            Reject(() => scope.Cleanup(true), status + " recovery evidence refuses directory deletion"); Check(Directory.Exists(root) && File.Exists(Path.Combine(root, "session.json")), status + " recovery evidence survives cleanup");
            File.Delete(Path.Combine(root, "session.json")); scope.Cleanup(true);
        }
        foreach(var status in new[]{"stopped","stoppedWithErrors"}){
            var recoveredRoot=NewRoot();var recoveredScope=new FixtureScope(recoveredRoot,evidence);recoveredScope.Secure(()=>{Directory.CreateDirectory(recoveredRoot);Mark(recoveredRoot);});
            var hostInfo=new ProcessStartInfo(Path.ChangeExtension(dll,".exe")){UseShellExecute=false,CreateNoWindow=true};hostInfo.Environment["DOTNET_ROOT_X64"]=Path.GetDirectoryName(dotnet);hostInfo.ArgumentList.Add("run");hostInfo.ArgumentList.Add(Path.Combine(recoveredRoot,"request.json"));
            using(var host=Process.Start(hostInfo)!){using var hostOwned=FixtureProcess.Started(host,evidence);try{
                var identity=new RunningProcess(host.Id,hostOwned.Creation.ToString(),Path.ChangeExtension(dll,".exe"));var journal=Path.Combine(recoveredRoot,"gpu-journal.json");
                void Save(string fieldStatus,string journalStatus,RunningProcess? gameIdentity=null,bool hasJournal=true){var game=gameIdentity??identity;OperationFiles.Write(journal,new{status=journalStatus,preview=new{identity=game}});OperationFiles.Write(Path.Combine(recoveredRoot,"session.json"),new {status,registryStatus="restored",jobStatus="cleared",host=identity,errors=status=="stoppedWithErrors"?new[]{"Native restoration needs reconciliation: gpuPriority"}:Array.Empty<string>(),games=new[]{new{identity=game,fields=new[]{new{name="gpuPriority",route="native",status=fieldStatus,journalPath=hasJournal?journal:null}}}}});}
                Save("restored","restored");Reject(()=>recoveredScope.Cleanup(true),status+" live native host prevents deletion");Check(!host.HasExited && Directory.Exists(recoveredRoot),status+" active native host and recovery evidence survive");hostOwned.Stop();
                Save("applied","restored");Reject(()=>recoveredScope.Cleanup(true),status+" contradictory applied native field preserves recovery");
                Save("restored","needsReconciliation");Reject(()=>recoveredScope.Cleanup(true),status+" unreconciled native journal preserves recovery");
                Save("restored","restored",hasJournal:false);Reject(()=>recoveredScope.Cleanup(true),status+" restored field without its native journal preserves recovery");
                Save("restored","restored",new RunningProcess(sentinel.Id,owned.Creation.ToString(),dotnet));Reject(()=>recoveredScope.Cleanup(true),status+" live exact native game actor preserves recovery");Check(!sentinel.HasExited && Directory.Exists(recoveredRoot),status+" live unrelated sentinel and fixture survive actor refusal");
                Save("restored","restored");recoveredScope.Cleanup(true);Check(!Directory.Exists(recoveredRoot),status+" terminal native host and restored field/journal allow exact fixture cleanup");
            }finally{hostOwned.Stop();}}
        }
        var watchRoot=NewRoot();var watchScope=new FixtureScope(watchRoot,evidence);watchScope.Secure(()=>{Directory.CreateDirectory(watchRoot);Mark(watchRoot);});
        var watchInfo=new ProcessStartInfo(Path.ChangeExtension(dll,".exe")){UseShellExecute=false,CreateNoWindow=true};watchInfo.Environment["DOTNET_ROOT_X64"]=Path.GetDirectoryName(dotnet);watchInfo.ArgumentList.Add("watch");watchInfo.ArgumentList.Add(Path.Combine(watchRoot,"watch-request.json"));
        using(var watcher=Process.Start(watchInfo)!){using var watchOwned=FixtureProcess.Started(watcher,evidence);try{var native=new RunningProcess(watcher.Id,watchOwned.Creation.ToString(),Path.ChangeExtension(dll,".exe"));OperationFiles.Write(Path.Combine(watchRoot,"watch.json"),new ProtectedWatchReady(OperationOwner.Current(),Guid.NewGuid().ToString("N"),native,native,true));Reject(()=>FixtureScope.AwaitRecovery(watchRoot,evidence),"Held live recovery watcher times out without termination");Check(!watcher.HasExited && File.Exists(Path.Combine(watchRoot,"watch.json")),"Live recovery watcher and exact evidence survive timeout");}finally{watchOwned.Stop();}}
        watchScope.Cleanup(true);
        var changedTimeRoot=NewRoot();var changedTime=new FixtureScope(changedTimeRoot,evidence);changedTime.Secure(()=>{Directory.CreateDirectory(changedTimeRoot);Mark(changedTimeRoot);});var changedTimeName=PolicyRootSecurity.MarkerName(changedTimeRoot)+PolicyRootSecurity.ProtectedAtSuffix;var oldTime=key.GetValue(changedTimeName)!;key.SetValue(changedTimeName,"foreign-time",RegistryValueKind.String);Reject(()=>changedTime.Cleanup(true),"Foreign timestamp kind/value preserves both markers and tree");Check(Equals(key.GetValue(changedTimeName),"foreign-time") && Equals(key.GetValue(PolicyRootSecurity.MarkerName(changedTimeRoot)),sid),"Timestamp conflict cannot partially delete owner");key.SetValue(changedTimeName,oldTime,RegistryValueKind.QWord);changedTime.Cleanup(true);
        var heldRoot=NewRoot();var heldScope=new FixtureScope(heldRoot,evidence);heldScope.Secure(()=>{Directory.CreateDirectory(heldRoot);Mark(heldRoot);});var heldPath=Path.Combine(heldRoot,"held-recovery.txt");using(var heldFile=new FileStream(heldPath,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None)){Reject(()=>heldScope.Cleanup(true),"Native held file prevents tree deletion and cleanup failure is surfaced");Check(Directory.Exists(heldRoot) && File.Exists(heldPath),"Held recovery bytes survive failed directory deletion");}heldScope.Cleanup(true);
        var collidedRoot = NewRoot(); key.SetValue(PolicyRootSecurity.MarkerName(collidedRoot), "prior", RegistryValueKind.String);
        Reject(() => { _ = new FixtureScope(collidedRoot, evidence); }, "Preexisting marker collision refuses before mutation"); Check(Equals(key.GetValue(PolicyRootSecurity.MarkerName(collidedRoot)), "prior"), "Preexisting marker value survives collision"); key.DeleteValue(PolicyRootSecurity.MarkerName(collidedRoot));
        owned.Stop(); Check(sentinel.WaitForExit(5000), "Only exact held native fixture identity is terminated");
        var after = Snapshot(); File.WriteAllText(Path.Combine(frame, "registry-after.json"), after); Check(after == before, "Complete typed registry snapshot is restored exactly");
        Check(!Directory.GetDirectories(frame, "case-*").Any() && !Directory.Exists(legacy), "Zero disposable root leftovers");
        File.WriteAllText(Path.Combine(frame, "cleanup-result.json"), JsonSerializer.Serialize(new { passed = checks.Count, checks, sentinel = new {pid=sentinel.Id,creationTimeFileTimeUtc=owned.Creation.ToString()}, sentinelExited = sentinel.HasExited, registryEqual = before == after, roots = Directory.GetDirectories(frame, "case-*"), sourceHash = OperationFiles.HashFile(dll), unreadableSourceHash = OperationFiles.HashFile(unreadableDll) }, new JsonSerializerOptions { WriteIndented = true }));
        }
        finally { owned.Stop(); }
    }
    internal static void Sentinel() { Thread.Sleep(TimeSpan.FromMinutes(3)); }
}
