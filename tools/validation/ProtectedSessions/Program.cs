using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

if(args is ["--fixture-cleanup-checks",var cleanupFrame]) { FixtureCleanupChecks.Run(cleanupFrame); return; }
if(args is ["--runtime-root",var runtimeReceipt]) { File.WriteAllText(runtimeReceipt,System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()); return; }
if(args is ["run",var cleanupHost]) { FixtureCleanupChecks.Sentinel(); return; }
if(args is ["watch",var cleanupWatch]) { FixtureCleanupChecks.Sentinel(); return; }
if(args is ["--cleanup-sentinel",var privateSentinelFrame,var privateSentinel]) { FixtureCleanupChecks.Sentinel(); return; }
if(args is ["--cleanup-sentinel",var sentinelFrame]) { FixtureCleanupChecks.Sentinel(); return; }
if(args is ["--retained-launcher",var retainedRoot]) { RetainedGpuChecks.Launcher(retainedRoot); return; }
if(args is ["--retained-game",var retainedGame,var retainedSession]) { RetainedGpuChecks.Game(retainedGame,retainedSession); return; }
if(args is [var retainedRepo,var retainedDotnet,"--retained-gpu"]) { RetainedGpuChecks.Run(retainedRepo,retainedDotnet); return; }
if(args is ["--high-io-launcher",var highIoRoot]) { HighIoChecks.Launcher(highIoRoot); return; }
if(args is ["--high-io-stub",var stubRoot]) { HighIoChecks.Stub(stubRoot); return; }
if(args is [var highIoRepo,var highIoDotnet,"--high-io",var inspectSeconds]) { HighIoChecks.Run(highIoRepo,highIoDotnet,int.Parse(inspectSeconds,System.Globalization.CultureInfo.InvariantCulture)); return; }
if(args is ["--launcher",var launcherRoot]) { Fixtures.Launcher(launcherRoot); return; }
if(args is ["--hold-lock",var holdPath,var holdReady,var holdStop]) { Fixtures.Hold(holdPath,holdReady,holdStop); return; }
if(args is ["--game",var gameRoot,var hardware]) { Fixtures.Game(gameRoot,hardware=="gpu"); return; }
if(args.Length is < 2 or > 3)throw new ArgumentException("Provide repository, dotnet executable, and optionally --hardware-gpu.");
var repo=Path.GetFullPath(args[0]);var dotnet=Path.GetFullPath(args[1]);bool hardwareGpu=args.Length==3&&args[2]=="--hardware-gpu";
var workerExe=Path.Combine(repo,"backend","bin","optimizer","session","RooIndustries.SessionHost.exe");
var root=Path.Combine(Path.GetTempPath(),"roo-industries-protected-session-validation-"+Guid.NewGuid().ToString("N"));
var bin=Path.GetDirectoryName(typeof(Fixtures).Assembly.Location)!;
var gamePath=Path.Combine(bin,"RooIndustriesLaunchPolicyProbe.exe");var launcherPath=Path.Combine(bin,"RooIndustriesProtectedLauncher.exe");
var evidence=Path.Combine(repo,"artifacts","validation","protected-session-cleanup-"+Guid.NewGuid().ToString("N"));
var fixture=new FixtureScope(root,evidence);var launcherCopy=new FixtureCopy(gamePath,launcherPath);
var ownedProcesses=new Dictionary<Process,FixtureProcess>();
ulong originalMask=0,firstMask=0,secondMask=0;
Process? launcher=null,worker=null;var activeRoots=new List<string>();var sameName=new List<(FixtureProcess Process,string Root)>();var session=new ProtectedSessions(_=>false);int passed=0;
void Check(bool ok,string text){if(!ok)throw new InvalidOperationException(text);Console.WriteLine("PASS "+text);passed++;}
void Until(Func<bool> condition,string text,int seconds=20){var clock=Stopwatch.StartNew();while(!condition()){if(clock.Elapsed.TotalSeconds>seconds)throw new TimeoutException(text);Thread.Sleep(100);}}
JsonElement V<T>(T value)=>JsonSerializer.SerializeToElement(value,OperationFiles.Json);
Dictionary<string,JsonElement> Wanted()=>new(){["cpuPriority"]=V("AboveNormal"),["ioPriority"]=V(2),["memoryPriority"]=V(5),["affinity"]=V(new AffinityState(0,"0x"+firstMask.ToString("X"))),["gpuPriority"]=V(3)};
void Reject(Action action,string text){bool rejected=false;try{action();}catch(InvalidDataException){rejected=true;}catch(InvalidOperationException){rejected=true;}Check(rejected,text);}
Process Start(string executable,params string[] values){var info=new ProcessStartInfo(executable){UseShellExecute=false,CreateNoWindow=true};foreach(var value in values)info.ArgumentList.Add(value);info.Environment["DOTNET_ROOT_X64"]=Path.GetDirectoryName(dotnet);var process=Process.Start(info)??throw new Exception("Fixture start failed");ownedProcesses.Add(process,FixtureProcess.Started(process,evidence));return process;}
FixtureProcess? holder=null;var holderDir=Path.Combine(Environment.GetEnvironmentVariable("PUBLIC")??@"C:\Users\Public","roo-industries-protected-holder-"+Guid.NewGuid().ToString("N"));
FixtureProcess StandardHolder(string path){var held=StandardFixtureHolder.Start(dotnet,Path.Combine(bin,"RooIndustriesLaunchPolicyProbe.dll"),path,holderDir,evidence);Check(true,"The process holding the old temp launcher lock name runs without administrator rights");return held;}
bool HeldElsewhere(string path){try{using var probe=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None);return false;}catch(IOException){return true;}}
string Review(string name){var path=Path.Combine(root,name+".preview.json");OperationFiles.Write(path,session.Preview(launcher!.Id,gamePath,Wanted(),true));return path;}
Process Run(string preview,string target){Directory.CreateDirectory(target);activeRoots.Add(target);var request=Path.Combine(target,"request.json");OperationFiles.Write(request,new{schemaVersion=1,repoRoot=repo,sessionRoot=target,previewPath=preview,reviewHash=OperationFiles.HashFile(preview),confirm=true});return Start(workerExe,"run",request);}
ProtectedSessionState State(string target)=>session.Status(target).State??throw new Exception("Session state missing");
Process Launch(int number){var gameRoot=Path.Combine(root,"game-"+number);Directory.CreateDirectory(gameRoot);OperationFiles.Write(Path.Combine(root,"launch.json"),new{root=gameRoot,hardware=hardwareGpu?"gpu":"none"});Until(()=>File.Exists(Path.Combine(gameRoot,"ready.json")),"Game fixture did not start");var data=OperationFiles.Read<JsonElement>(Path.Combine(gameRoot,"ready.json"));var game=Process.GetProcessById(data.GetProperty("pid").GetInt32());_ = game.Handle;var identity=FixtureProcess.Ready(Path.Combine(gameRoot,"ready.json"),gamePath,["--game",gameRoot,hardwareGpu?"gpu":"none"],true,evidence);if(FixtureProcess.Created(game)!=identity.Creation){identity.Dispose();game.Dispose();throw new InvalidDataException("Fixture game handle identity mismatch.");}ownedProcesses.Add(game,identity);return game;}
void CheckGame(Process game,int number){Check(game.WaitForExit(20000)&&game.ExitCode==0,"Owned game fixture exits successfully");if(hardwareGpu){var result=OperationFiles.Read<JsonElement>(Path.Combine(root,"game-"+number,"gpu-result.json"));Check(result.GetProperty("Adapter").GetProperty("VendorId").GetInt32()==0x1002&&result.GetProperty("Adapter").GetProperty("DeviceId").GetInt32()==0x7550&&result.GetProperty("Dispatches").GetInt64()>0&&result.GetProperty("verified").GetArrayLength()==4,"Actual RX9070XT GPU work and independent output checks completed");}}
double Captured(string target,Process game){var created=FixtureProcess.Created(game);var path=Path.Combine(target,"gpu-handles",game.Id+"-"+created+".transfer.json");Until(()=>File.Exists(path),"The game's GPU launch handle was not captured");var latency=(File.GetCreationTimeUtc(path)-DateTime.FromFileTimeUtc(created)).TotalMilliseconds;Console.WriteLine("MEASURE game "+game.Id+" captured "+latency.ToString("F1")+" ms after launch");return latency;}
void Restored(string target){Until(()=>File.Exists(Path.Combine(target,"recovery-result.json")),"Recovery watcher did not finish");var state=State(target);Check(state.Status=="stopped"&&state.RegistryStatus=="restored"&&state.JobStatus=="cleared","Recovery reports cleared job and restored launch state");using var key=Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesLaunchPolicyProbe.exe");Check(key is null,"Approved fixture IFEO image key is absent after restoration");Check(Oracle.Affinity(launcher!)==originalMask&&Oracle.Io(launcher!)==1&&Oracle.Memory(launcher!)==2,"Independent launcher oracle returns original controls");}
try{
 fixture.Secure();launcherCopy.Create();
 using(var existing=Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesLaunchPolicyProbe.exe")){if(existing is not null)throw new InvalidOperationException("Fixture registry key already exists; do not overwrite it.");}
 launcher=Start(launcherPath,"--launcher",root);Until(()=>File.Exists(Path.Combine(root,"launcher-ready.json")),"Launcher fixture did not start");
 originalMask=Oracle.Affinity(launcher);firstMask=originalMask&(~originalMask+1);secondMask=originalMask^firstMask;
 if(secondMask==0)throw new InvalidOperationException("At least two allowed logical processors are required for the affinity-switch fixture.");
 Check(Oracle.Affinity(launcher)==originalMask&&Oracle.Io(launcher)==1&&Oracle.Memory(launcher)==2,"Discriminating launcher baseline is independently verified");
 Reject(()=>session.Preview(launcher.Id,gamePath,Wanted(),false),"Launcher-tree scope must be explicitly accepted");
 var preview=Review("first");var originalHash=OperationFiles.HashFile(preview);File.AppendAllText(preview," ");Reject(()=>session.Check(preview,originalHash),"Changed review bytes fail before mutation");
 var plan=OperationFiles.Read<ProtectedSessionPreview>(preview);OperationFiles.Write(preview,plan with{OriginalAffinity=new(0,"0x0")});Reject(()=>session.Check(preview,OperationFiles.HashFile(preview)),"A conflicting original affinity cannot authorize apply");OperationFiles.Write(preview,plan);
 var oldLock=Path.Combine(Path.GetTempPath(),BrandCompatibility.LauncherLeasePrefix+plan.Launcher.ProcessId+"-"+plan.Launcher.CreationTimeFileTimeUtc+".lock");
 holder=StandardHolder(oldLock);Check(HeldElsewhere(oldLock),"The old user temp launcher lock name is held open by that process");
 var target=Path.Combine(root,"session1");worker=Run(preview,target);Until(()=>File.Exists(Path.Combine(target,"session.json"))&&State(target).Status=="armed","Session did not arm");
 Check(!holder.Wait(0)&&HeldElsewhere(oldLock),"The session armed while that process still held the old temp launcher lock name");
 Check(File.Exists(Path.Combine(root,BrandCompatibility.LauncherLeasePrefix+plan.Launcher.ProcessId+"-"+plan.Launcher.CreationTimeFileTimeUtc+".lock")),"The session keeps its launcher lock inside the protected recovery folder");
 Check(!worker.HasExited&&State(target).JobStatus=="applied"&&worker.MainWindowHandle==IntPtr.Zero,"Worker is armed without an automatic expiry or visible window");
 File.Delete(preview);Check(State(target).Status=="armed","The session retains reviewed bytes independently of the caller preview file");
 using var capture=new CaptureThread(worker);var waiting=capture.Measure(()=>Thread.Sleep(5000));Console.WriteLine("MEASURE armed, no game: "+waiting);
 if(OperatingSystem.IsWindowsVersionAtLeast(10,0,26100,4770))Check(Directory.Exists(Path.Combine(target,"gpu-handles")),"GPU launch capture watches for the game");else Console.WriteLine("SKIP GPU launch capture needs Windows 11 build 26100.4770 or later");
 var otherBin=Directory.CreateDirectory(Path.Combine(root,"same-name")).FullName;var otherGame=Path.Combine(otherBin,Path.GetFileName(gamePath));
 foreach(var file in Directory.GetFiles(bin,"*.dll").Concat(Directory.GetFiles(bin,"*.json")))File.Copy(file,Path.Combine(otherBin,Path.GetFileName(file)));File.Copy(gamePath,otherGame);
 Environment.SetEnvironmentVariable("DOTNET_ROOT_X64",Path.GetDirectoryName(dotnet));var sid=System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value;
 foreach(var refusing in new[]{true,false}){var folder=Directory.CreateDirectory(Path.Combine(root,refusing?"same-name-refusing":"same-name-plain")).FullName;sameName.Add((FixtureProcess.Create(otherGame,["--game",folder,"none"],refusing?"D:(D;;0x200;;;"+sid+")(A;;0x1FFFFF;;;"+sid+")(A;;0x1FFFFF;;;BA)(A;;0x1FFFFF;;;SY)":null,evidence),folder));Until(()=>File.Exists(Path.Combine(folder,"ready.json")),"Same-name program did not start");}
 var refusingPid=OperationFiles.Read<JsonElement>(Path.Combine(root,"same-name-refusing","ready.json")).GetProperty("pid").GetInt32();bool refused=false;try{using var fresh=new ProcessTarget(refusingPid,readControls:["gpuPriority"]);}catch(RooIndustries.Optimization.CpuSets.NativeFailure failure)when(failure.Api=="OpenProcess"&&failure.NativeErrorCode==5){refused=true;}
 Check(refused,"One copy refuses a GPU-control handle, like a Windows service or protected program with that name");
 string? ended=null;var watch=Stopwatch.StartNew();while(ended is null&&watch.Elapsed.TotalSeconds<6){var live=State(target);if(worker.HasExited||live.Status!="armed"||live.Errors.Count!=0)ended=live.Status+": "+string.Join("; ",live.Errors);Thread.Sleep(250);}
 Check(ended is null,"Programs with the game's file name from another folder, one refusing GPU access, leave the armed session running"+(ended is null?"":" ("+ended+")"));
 Check(State(target).Games.Count==0&&!Directory.EnumerateFiles(target,"*.transfer.json",SearchOption.AllDirectories).Any(),"The session keeps no game record or GPU handle for those programs");
 using(var game=Launch(1)){
  Until(()=>State(target).Status=="active","Requested controls were not independently applied");
  Check(game.PriorityClass==ProcessPriorityClass.AboveNormal&&Oracle.Io(game)==2&&Oracle.Memory(game)==5&&Oracle.Gpu(game)==3&&Oracle.Affinity(game)==firstMask,"Actual launch, GPU and strict-affinity values match the request");
  var playing=capture.Measure(()=>{var hold=Stopwatch.StartNew();while(hold.Elapsed.TotalSeconds<12){if(Oracle.Gpu(game)!=3||Oracle.Affinity(game)!=firstMask)throw new InvalidOperationException("A sustained control drifted during the hold");Thread.Sleep(1000);}});Check(true,"Independent readback confirms sustained true GPU priority and strict affinity over the hold");
  Console.WriteLine("MEASURE game running: "+playing);var caught=Captured(target,game);
  Check(waiting.Wakes<=5&&playing.Wakes<=5,"The armed session reads the process list at most 5 times a second while it waits for the game and while the game runs");
  Check(caught<=50,"The session catches the game within 50 ms of its launch");
  var contradictory=State(target);var copiedRoot=Path.Combine(root,"contradictory");
  contradictory.LauncherJournal=Path.Combine(copiedRoot,"launcher-journal.json");
  foreach(var field in contradictory.Games.SelectMany(item=>item.Fields)){if(field.JournalPath is not null)field.JournalPath=field.JournalPath.Replace(target,copiedRoot,StringComparison.OrdinalIgnoreCase);}
  contradictory.Games.Single().Fields.Single(field=>field.Name=="gpuPriority").Observed=new ControlRead(false,V(3),null);
  OperationFiles.Write(Path.Combine(copiedRoot,"session.json"),contradictory);
  Reject(()=>session.Status(copiedRoot),"Active metadata with missing GPU evidence cannot report an applied control");Directory.Delete(copiedRoot,true);
  Oracle.SetGpu(game,2);Reject(()=>{if(Oracle.Gpu(game)!=3)throw new InvalidOperationException("GPU readback mismatch");},"Independent oracle rejects a falsely reported applied GPU priority");
  Until(()=>Oracle.Gpu(game)==3&&State(target).Games.Single().Fields.Single(field=>field.Name=="gpuPriority").Reapplications>0,"GPU reset was not reapplied");
  Check(Oracle.Gpu(game)==3,"The actual GPU class is restored after a benign reset to its captured original");
  var live=State(target);OperationFiles.Write(Path.Combine(target,"command.json"),new ProtectedSessionCommand(OperationOwner.Current(),Guid.NewGuid().ToString("N"),live.Host,"stop",null));
  Until(()=>File.Exists(Path.Combine(target,"command-rejected.json")),"Stale command was not rejected");
  Check(!worker.HasExited&&Oracle.Gpu(game)==3,"A stale stop request cannot end or alter the active session");
  using(var heldSnapshot=new FileStream(Path.Combine(target,"session.json"),FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete)){
   session.Command(target,"affinity",new(0,"0x"+secondMask.ToString("X")));Until(()=>Oracle.Affinity(game)==secondMask,"Second CPU-subset switch failed");
   Check(Oracle.Affinity(game)==secondMask&&!worker.HasExited,"Live core changes publish reader-safe state while a prior snapshot remains open");
  }
  session.Command(target,"affinity",new(0,"0x"+firstMask.ToString("X")));Until(()=>Oracle.Affinity(game)==firstMask,"First CPU-subset restoration failed");
  using(var copy=Launch(5)){
   Until(()=>State(target).Games.Count==2&&State(target).Status=="active","A second copy started while the game runs did not receive saved controls");
   Check(Captured(target,copy)<=50&&Oracle.Gpu(copy)==3,"A second copy started while the game runs is caught within 50 ms and gets the GPU priority");
   File.WriteAllText(Path.Combine(root,"game-5","stop"),"");CheckGame(copy,5);
  }
  File.WriteAllText(Path.Combine(root,"game-1","stop"),"");CheckGame(game,1);
 }
 foreach(var item in sameName)File.WriteAllText(Path.Combine(item.Root,"stop"),"");Check(sameName.All(item=>item.Process.Wait(15000)),"The same-name programs exit after the game got its settings beside them");
 Until(()=>State(target).Status=="armed","Session did not rearm after game exit");
 Oracle.SetMemory(launcher,2);Oracle.SetIo(launcher,1);
 Until(()=>Oracle.Memory(launcher)==5&&Oracle.Io(launcher)==2,"Launcher defaults were not sustained after a reset");
 Check(Oracle.Memory(launcher)==5&&Oracle.Io(launcher)==2,"Launcher I/O and memory defaults are sustained for the next game start");
 using(var game=Launch(2)){
  Until(()=>State(target).Games.Count==3&&State(target).Status=="active","Second game instance did not receive saved controls");
  Check(game.PriorityClass==ProcessPriorityClass.AboveNormal&&Oracle.Gpu(game)==3&&Oracle.Memory(game)==5,"A new game PID receives the same saved launch and actual GPU priorities");
  Check(Captured(target,game)<=50,"The armed session catches a later game start within 50 ms");
  session.Command(target,"stop");Check(worker.WaitForExit(20000),"Worker stops on explicit request");Restored(target);
  Check(Oracle.Gpu(game)==2&&Oracle.Affinity(game)==originalMask,"Independent live readback confirms GPU and affinity restoration");
  Check(State(target).Games.Last().Fields.Where(field=>field.Route=="launch").All(field=>field.Status=="restartRequired"),"Startup priorities accurately report restart required for a running game");
  File.WriteAllText(Path.Combine(root,"game-2","stop"),"");CheckGame(game,2);
 }
 worker.Dispose();worker=null;
 var crashPreview=Review("crash");var crashRoot=Path.Combine(root,"session2");worker=Run(crashPreview,crashRoot);Until(()=>File.Exists(Path.Combine(crashRoot,"session.json"))&&State(crashRoot).Status=="armed","Crash-test session did not arm");
 using(var game=Launch(3)){
  Until(()=>State(crashRoot).Status=="active","Crash-test controls were not applied");Check(Captured(crashRoot,game)<=50,"A new session catches its game within 50 ms");
  Reject(()=>session.Recover(crashRoot,State(crashRoot).Preview.OperationId),"Concurrent recovery cannot take over a live worker");
  ownedProcesses[worker].Stop();Check(worker.WaitForExit(10000),"Only the disposable session worker is terminated for the crash test");Restored(crashRoot);
  Check(Oracle.Gpu(game)==2&&Oracle.Affinity(game)==originalMask,"Independent watcher restores actual GPU priority and job affinity after worker termination");
  File.WriteAllText(Path.Combine(root,"game-3","stop"),"");CheckGame(game,3);
 }
 worker.Dispose();worker=null;
 var conflictPreview=Review("conflict");var conflictRoot=Path.Combine(root,"session3");worker=Run(conflictPreview,conflictRoot);Until(()=>File.Exists(Path.Combine(conflictRoot,"session.json"))&&State(conflictRoot).Status=="armed","Conflict session did not arm");
 using(var game=Launch(4)){
  Until(()=>State(conflictRoot).Status=="active","Conflict-test controls not applied");Oracle.SetGpu(game,1);
  Until(()=>State(conflictRoot).Games.Single().Fields.Single(field=>field.Name=="gpuPriority").Status=="conflict","Foreign GPU value was not reported");
  Check(Oracle.Gpu(game)==1,"A different third-party GPU value is preserved");session.Command(conflictRoot,"stop");Check(worker.WaitForExit(20000),"Conflicting session stops without overwriting another writer");
  Until(()=>File.Exists(Path.Combine(conflictRoot,"recovery-result.json")),"Conflict recovery watcher did not finish");
  Check(State(conflictRoot).Status=="recoveryRequired"&&Oracle.Gpu(game)==1&&Oracle.Affinity(game)==originalMask,"GPU conflict remains explicit while independently owned affinity is released");
  Oracle.SetGpu(game,3);var reconciled=session.Recover(conflictRoot,State(conflictRoot).Preview.OperationId);
  Check(reconciled.JobStatus=="cleared"&&reconciled.RegistryStatus=="restored"&&Oracle.Gpu(game)==2,"Reconciled GPU value restores its captured original");
  File.WriteAllText(Path.Combine(root,"game-4","stop"),"");CheckGame(game,4);
 }
 Console.WriteLine("Protected-session assertions: "+passed);
}finally{
 bool finished=true;
 void Step(Action action){try{action();}catch{finished=false;throw;}}
 FixtureScope.Finish(
  ()=>Step(()=>{if(worker is not null){ownedProcesses[worker].Stop();worker.Dispose();}}),
  ()=>Step(()=>{if(holder is not null){StandardFixtureHolder.SignalStop(holderDir);if(!holder.Wait(15000))holder.Stop();holder.Dispose();}}),
  ()=>Step(()=>{if(launcher is not null){File.WriteAllText(Path.Combine(root,"stop-launcher"),"");if(!launcher.WaitForExit(15000))ownedProcesses[launcher].Stop();launcher.Dispose();}}),
  ()=>Step(()=>{foreach(var target in activeRoots){if(File.Exists(Path.Combine(target,"session.json"))){FixtureScope.AwaitRecovery(target,evidence);var saved=session.Status(target).State!;session.Recover(target,saved.Preview.OperationId);}}}),
  ()=>Step(()=>{foreach(var identity in ownedProcesses.Values)identity.Stop();}),
  ()=>Step(()=>{foreach(var(probe,_) in sameName)probe.Stop();}),
  ()=>{fixture.Cleanup(finished);},
  ()=>{launcherCopy.Remove();},
  ()=>{if(finished && holder is not null && Directory.Exists(holderDir))Directory.Delete(holderDir,true);},
  ()=>{foreach(var identity in ownedProcesses.Values)identity.Dispose();foreach(var(probe,_) in sameName)probe.Dispose();});

}

static class Fixtures{
 public static void Hold(string path,string ready,string stop){using var file=new FileStream(path,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None,4096,FileOptions.DeleteOnClose);var principal=new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent());File.WriteAllText(ready,JsonSerializer.Serialize(new{pid=Environment.ProcessId,creationTimeFileTimeUtc=FixtureProcess.Created(Process.GetCurrentProcess()).ToString(),administrator=principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator)}));var until=DateTime.UtcNow.AddMinutes(10);while(!File.Exists(stop)&&DateTime.UtcNow<until)Thread.Sleep(100);}
 public static void Launcher(string root){using var self=Process.GetCurrentProcess();Oracle.SetIo(self,1);Oracle.SetMemory(self,2);File.WriteAllText(Path.Combine(root,"launcher-ready.json"),JsonSerializer.Serialize(new{pid=self.Id}));var children=new List<Process>();Directory.CreateDirectory(Path.Combine(root,"process-receipts"));try{var until=DateTime.UtcNow.AddMinutes(10);while(!File.Exists(Path.Combine(root,"stop-launcher"))&&DateTime.UtcNow<until){var path=Path.Combine(root,"launch.json");if(File.Exists(path)){using var doc=JsonDocument.Parse(File.ReadAllText(path));File.Delete(path);var info=new ProcessStartInfo(Path.Combine(Path.GetDirectoryName(typeof(Fixtures).Assembly.Location)!,doc.RootElement.TryGetProperty("exe",out var exe)?Path.GetFileName(exe.GetString()!):"RooIndustriesLaunchPolicyProbe.exe")){UseShellExecute=false,CreateNoWindow=true};info.ArgumentList.Add("--game");info.ArgumentList.Add(doc.RootElement.GetProperty("root").GetString()!);info.ArgumentList.Add(doc.RootElement.GetProperty("hardware").GetString()!);var child=Process.Start(info)!;_ = child.Handle;children.Add(child);}Thread.Sleep(50);}}finally{foreach(var child in children){if(!child.HasExited){using var owned=FixtureProcess.Started(child,Path.Combine(root,"process-receipts"));owned.Stop();child.WaitForExit();}child.Dispose();}}}
 public static void Game(string root,bool hardware){using var self=Process.GetCurrentProcess();using var gpu=hardware?new GpuWorkload(0x1002,0x7550,16384,256):null;File.WriteAllText(Path.Combine(root,"ready.json"),JsonSerializer.Serialize(new{pid=self.Id,creationTimeFileTimeUtc=FixtureProcess.Created(self).ToString(),administrator=true,adapter=gpu?.Adapter}));var until=DateTime.UtcNow.AddMinutes(8);while(!File.Exists(Path.Combine(root,"stop"))&&DateTime.UtcNow<until){gpu?.Run(1);Thread.Sleep(10);}if(gpu is not null)File.WriteAllText(Path.Combine(root,"gpu-result.json"),JsonSerializer.Serialize(new{gpu.Adapter,gpu.Dispatches,verified=gpu.VerifyOutput()}));}
}
static class Oracle{
 public static ulong Affinity(Process p){if(!GetProcessAffinityMask(p.Handle,out var value,out _))throw new System.ComponentModel.Win32Exception();return value.ToUInt64();}
 public static int Gpu(Process p){int status=D3DKMTGetProcessSchedulingPriorityClass(p.Handle,out int value);if(status<0)throw new Exception("GPU query "+status.ToString("X8"));return value;}
 public static void SetGpu(Process p,int value){int status=D3DKMTSetProcessSchedulingPriorityClass(p.Handle,value);if(status<0)throw new Exception("GPU set "+status.ToString("X8"));}
 public static int Io(Process p){int value=0;if(NtQueryInformationProcess(p.Handle,33,ref value,4,IntPtr.Zero)<0)throw new Exception("IO query");return value;}
 public static void SetIo(Process p,int value){if(NtSetInformationProcess(p.Handle,33,ref value,4)<0)throw new Exception("IO set");}
 public static uint Memory(Process p){if(!GetProcessInformation(p.Handle,0,out uint value,4))throw new System.ComponentModel.Win32Exception();return value;}
 public static void SetMemory(Process p,uint value){if(!SetProcessInformation(p.Handle,0,ref value,4))throw new System.ComponentModel.Win32Exception();}
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetProcessAffinityMask(IntPtr p,out UIntPtr value,out UIntPtr system);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetProcessInformation(IntPtr p,int c,out uint v,uint n);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool SetProcessInformation(IntPtr p,int c,ref uint v,uint n);
 [DllImport("ntdll.dll")]static extern int NtQueryInformationProcess(IntPtr p,int c,ref int v,int n,IntPtr ret);
 [DllImport("ntdll.dll")]static extern int NtSetInformationProcess(IntPtr p,int c,ref int v,int n);
 [DllImport("gdi32.dll")]static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr p,out int value);
 [DllImport("gdi32.dll")]static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr p,int value);
}
