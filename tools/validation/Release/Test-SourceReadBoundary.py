import argparse
import hashlib
import importlib.util
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', ROOT / 'tools/validation/windows_ssh.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
p = w.ps_literal
parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)

def cleanup_execution(execution, helper_path, out):
    cleanup = w.REMOTE_GUARDS + "\n. " + p(helper_path) + ";$run=" + p(execution) + r"""
Assert-ProtectedFrame $run
$task=Get-Content -Raw -LiteralPath (Join-Path $run 'task.json')|ConvertFrom-Json
Assert-OwnedTaskAbsent $task.name
$directory=[SourceBoundary.DirectoryReceipt]::new($run);$held=[Collections.Generic.List[object]]::new();$identities=[Collections.Generic.List[object]]::new()
try {
 foreach($name in 'ownership.ps1','native.ps1','entry.ps1','result.json','task.json'){
  $path=Join-Path $run $name;Assert-PlainAncestry $path
  $h=[RooValidationOwnership.Native]::CreateFile($path,2147483648,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
  if($h.IsInvalid){throw 'Execution evidence identity missing; retained'}
  try{$id=[RooValidationOwnership.Native]::FileId($h)}finally{$h.Dispose()}
  $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  $r=[RooValidationOwnership.ProbeFile]::Open($path,$id,$hash);$held.Add($r);$identities.Add($r.Identity)
 }
 foreach($r in $held){$r.Remove()};$directory.Remove()
 @{execution=$run;directoryId=$directory.Id;files=@($identities);task=$task.name;taskAbsent=$true;executionAbsent=(-not[IO.Directory]::Exists($run))}|ConvertTo-Json -Depth 6 -Compress
}finally{foreach($r in $held){$r.Dispose()};$directory.Dispose()}
"""
    (out / 'execution-cleanup.ps1').write_text(cleanup)
    result = w.invoke('optimizer-9070', 'SERVI-WINDOWS-D', cleanup, timeout=w.CLEANUP_TIMEOUT)
    (out / 'execution-cleanup.json').write_text(result.stdout)
    return json.loads(result.stdout.strip().splitlines()[-1])


ASSEMBLY = r'''
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text.Json;
class Program {
 static int Main(string[] args) {
  using var identity = WindowsIdentity.GetCurrent();
  using var process = Process.GetCurrentProcess();
  var dll = typeof(Program).Assembly.Location;
  var report = new {
   sid = identity.User!.Value,
   adminGroup = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator),
   pid = process.Id, created = process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
   image = process.MainModule!.FileName, assembly = dll,
   hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(dll)))
  };
  using (var output = new FileStream(Path.Combine(args[0], "assembly.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read)) {
   JsonSerializer.Serialize(output, report); output.Flush(true);
  }
  var deadline = DateTime.UtcNow.AddSeconds(35);
  while (!File.Exists(Path.Combine(args[0], "release-assembly.txt")) && DateTime.UtcNow < deadline) System.Threading.Thread.Sleep(50);
  return File.Exists(Path.Combine(args[0], "release-assembly.txt")) ? 0 : 7;
 }
}
'''

NATIVE = r'''
namespace SourceBoundary {
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
 public sealed class DirectoryReceipt : IDisposable {
  SafeFileHandle handle; public string Id; public string Path;
  public DirectoryReceipt(string path,bool sharedDelete=false) {
   Path = path;
   handle = RooValidationOwnership.Native.CreateFile(path,0x10000,sharedDelete?7u:3u,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
   if(handle.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
   Id = RooValidationOwnership.Native.FileId(handle);
  }
  public void Remove() {
   if(Id != RooValidationOwnership.Native.FileId(handle))throw new InvalidOperationException("Directory changed; retained");
   RooValidationOwnership.Native.Delete(handle); Dispose();
  }
  public void Dispose(){if(handle!=null){handle.Dispose();handle=null;}}
 }
 public static class Token {
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static bool Admin(IntPtr process) {
   IntPtr token;if(!OpenProcessToken(process,10,out token))throw new Win32Exception(Marshal.GetLastWin32Error());
   try {using(var id=new System.Security.Principal.WindowsIdentity(token))return new System.Security.Principal.WindowsPrincipal(id).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);}
   finally{CloseHandle(token);}
  }
 }
}
'''

CHILD = r'''
$ErrorActionPreference='Stop'
BOUNDARY_HELPER
function Denied([scriptblock]$Action) {
 try {& $Action;return $false} catch {$error=$_.Exception.GetBaseException();$code=$error.HResult -band 0xffff;$probe.denials.Add([pscustomobject]@{type=$error.GetType().FullName;code=$code;message=$error.Message});return $code -eq 5}
}
$output=__OUTPUT__;$source=__SOURCE__;$dll=__DLL__;$dotnet=__DOTNET__
$self=New-OwnedProcess (Get-Process -Id $PID)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$probe=[ordered]@{sid=$identity.User.Value;adminGroup=([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator));process=$self.Identity;readHash=$null;readError=$null;sourceWriteDenied=$false;sourceCreateDenied=$false;sourceRenameDenied=$false;evidenceReadDenied=$false;recoveryReadDenied=$false;manifestReadHash=$null;assemblyExit=$null;denials=[Collections.Generic.List[object]]::new()}
try {$probe.readHash=(Get-FileHash -LiteralPath (Join-Path $source 'selected source.txt') -Algorithm SHA256).Hash;$probe.manifestReadHash=(Get-FileHash -LiteralPath (Join-Path $source 'source-verification.json') -Algorithm SHA256).Hash} catch {$probe.readError=$_.Exception.Message}
$probe.sourceWriteDenied=Denied {$f=[IO.File]::Open((Join-Path $source 'selected source.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$f.Dispose()}
$probe.sourceCreateDenied=Denied {[IO.Directory]::CreateDirectory((Join-Path $source 'forbidden child'))|Out-Null}
$probe.sourceRenameDenied=Denied {[IO.Directory]::Move((Join-Path $source 'rename target'),(Join-Path $source 'renamed forbidden'))}
$probe.evidenceReadDenied=Denied {[IO.File]::ReadAllText(__EVIDENCE__)|Out-Null}
$probe.recoveryReadDenied=Denied {[IO.File]::ReadAllText(__RECOVERY__)|Out-Null}
$record=New-OwnedTextFile (Join-Path $output 'process.json') ($self.Identity|ConvertTo-Json -Compress);$record.Dispose()
$child=$null;$owned=$null
try {
 $env:DOTNET_ROOT=[IO.Path]::GetDirectoryName($dotnet)
 $child=Start-Process -FilePath $dotnet -ArgumentList ('"'+$dll+'" "'+$output+'"') -RedirectStandardOutput (Join-Path $output 'assembly-stdout.txt') -RedirectStandardError (Join-Path $output 'assembly-stderr.txt') -PassThru -WindowStyle Hidden
 $owned=New-OwnedProcess $child
 if($owned){$record=New-OwnedTextFile (Join-Path $output 'dotnet-process.json') ($owned.Identity|ConvertTo-Json -Compress);$record.Dispose()}
 if(-not$child.WaitForExit(40000)){Stop-OwnedProcess $owned;throw 'Assembly timeout'}
 $child.Refresh();$probe.assemblyExit=$child.ExitCode
} finally {if($owned -and -not$child.HasExited){Stop-OwnedProcess $owned};if($child){$child.Dispose()}}
$record=New-OwnedTextFile (Join-Path $output 'probe.json') ($probe|ConvertTo-Json -Depth 8 -Compress);$record.Dispose()
$deadline=[DateTime]::UtcNow.AddSeconds(35)
while(-not[IO.File]::Exists((Join-Path $output 'release-child.txt')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
'''

REMOTE = r'''
$expected='S-1-5-21-2864832615-2000329836-3074386272-1001'
if($env:COMPUTERNAME -cne 'SERVI-WINDOWS-D' -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne $expected){throw 'Native fixture target differs'}
if(-not[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevated staging required'}
__GUARDS__
. __PARENT_HELPER__

$frame=__FRAME__
$source=Join-Path $frame 'source';$output=Join-Path $frame 'selected output';$evidence=Join-Path $frame 'evidence';$recovery=Join-Path $frame 'recovery'
$dirs=[Collections.Generic.List[object]]::new();$files=[Collections.Generic.List[object]]::new();$processes=[Collections.Generic.List[object]]::new();$results=[ordered]@{frame=$frame;machine=$env:COMPUTERNAME;sid=$expected;parentSddl=(Get-Acl C:\RooBuild).Sddl;passed=$false;cleanup=$false;error=$null}
$results.output=$output
$clock=[Diagnostics.Stopwatch]::StartNew()
function Get-Receipt([string]$Path) {
 $h=[RooValidationOwnership.Native]::CreateFile($Path,2147483648,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
 if($h.IsInvalid){throw 'Fixture identity open failed'}
 try {[pscustomobject]@{path=$Path;id=[RooValidationOwnership.Native]::FileId($h);hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}}finally{$h.Dispose()}
} 
function Seal-ReadFile([string]$Path) {
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
 foreach($sid in $expected,'S-1-3-4'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'ReadAndExecute','Allow'))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
$sourceReceipts=@();$generatedDirs=@();$helperReceipt=$null;$childScriptReceipt=$null
try {
 Assert-ProtectedFrame $frame;$dirs.Add([SourceBoundary.DirectoryReceipt]::new($frame))
 $results.scopeRefusals=[ordered]@{}
 foreach($sid in 'S-1-5-21-2864832615-2000329836-3074386272-1002','not-a-sid',''){
  $candidate=Join-Path $frame ('refused-'+[Guid]::NewGuid().ToString('N'));$refused=$false
  try{New-ProtectedFrame $candidate $sid}catch{$refused=$true}
  $results.scopeRefusals[$sid]=($refused -and -not[IO.Directory]::Exists($candidate))
  if([IO.Directory]::Exists($candidate)){$dirs.Add([SourceBoundary.DirectoryReceipt]::new($candidate))}
 }
 New-ProtectedFrame $source $expected;$dirs.Add([SourceBoundary.DirectoryReceipt]::new($source))
 foreach($path in $evidence,$recovery){New-ProtectedFrame $path;$dirs.Add([SourceBoundary.DirectoryReceipt]::new($path))}
 New-ProtectedFrame $output
 $acl=Get-Acl -LiteralPath $output;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($expected),'Modify','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $output -AclObject $acl
 $dirs.Add([SourceBoundary.DirectoryReceipt]::new($output))
 $nested=Join-Path $source 'path with spaces';[IO.Directory]::CreateDirectory($nested)|Out-Null;$dirs.Add([SourceBoundary.DirectoryReceipt]::new($nested))
 $rename=Join-Path $source 'rename target';[IO.Directory]::CreateDirectory($rename)|Out-Null;$dirs.Add([SourceBoundary.DirectoryReceipt]::new($rename,$true))
 foreach($pair in @(@((Join-Path $source 'selected source.txt'),'exact selected source bytes'),@((Join-Path $evidence 'sentinel.txt'),'sealed evidence'),@((Join-Path $recovery 'sentinel.txt'),'sealed recovery'),@((Join-Path $nested 'Program.cs'),__ASSEMBLY__),@((Join-Path $nested 'Boundary.csproj'),'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0-windows</TargetFramework><UseAppHost>false</UseAppHost></PropertyGroup></Project>'))){$f=New-OwnedTextFile $pair[0] $pair[1];$files.Add($f.Identity);$f.Dispose()}
 $dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';if(-not[IO.File]::Exists($dotnet)){throw 'Native SDK absent'}
 $build=Start-Process -FilePath $dotnet -WorkingDirectory $nested -ArgumentList ('build "'+(Join-Path $nested 'Boundary.csproj')+'" -c Release --nologo --disable-build-servers -p:NuGetAudit=false') -RedirectStandardOutput (Join-Path $output 'build-stdout.txt') -RedirectStandardError (Join-Path $output 'build-stderr.txt') -PassThru -WindowStyle Hidden
 $buildOwner=New-OwnedProcess $build;$processes.Add($buildOwner)
 if(-not$build.WaitForExit(60000)){Stop-OwnedProcess $buildOwner;throw 'Build timeout'};$build.Refresh();$sourceReceipts=@(Get-ChildItem -LiteralPath $source -File -Recurse|ForEach-Object{Get-Receipt $_.FullName});$generatedDirs=@(Get-ChildItem -LiteralPath $source -Directory -Recurse|Where-Object{$_.FullName -notin @($dirs|ForEach-Object{$_.Path})}|ForEach-Object{[SourceBoundary.DirectoryReceipt]::new($_.FullName)});if($build.ExitCode -ne 0){throw ('Fixture build failed: '+[IO.File]::ReadAllText((Join-Path $output 'build-stdout.txt')))}
 $dll=Join-Path $nested 'bin\Release\net8.0-windows\Boundary.dll'
 $manifest=[ordered]@{protocol='roo-industries-source-snapshot/v2';machine=$env:COMPUTERNAME;sid=$expected;frameId=([IO.Path]::GetFileName($frame).Split('-')[-1]);files=[ordered]@{}}
 foreach($f in Get-ChildItem -LiteralPath $source -File -Recurse){$name=$f.FullName.Substring($source.Length+1).Replace('\','/');$manifest.files[$name]=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash}
 $m=New-OwnedTextFile (Join-Path $source 'source-verification.json') ($manifest|ConvertTo-Json -Depth 8 -Compress);$manifestHash=$m.Identity.hash;$m.Dispose()
 $null=Assert-SourceSnapshot $source $manifestHash
 $sourceReceipts=@(Get-ChildItem -LiteralPath $source -File -Recurse|ForEach-Object{Get-Receipt $_.FullName})
 $helperReceipt=New-OwnedTextFile (Join-Path $output 'ownership.ps1') ([IO.File]::ReadAllText(__PARENT_HELPER__));Seal-ReadFile $helperReceipt.Identity.path;$helperReceipt.Dispose()
 $results.manifestMismatchRefused=$false;try{$null=Assert-SourceSnapshot $source ('0'*64)}catch{$results.manifestMismatchRefused=$true}
 foreach($path in @($source)+@(Get-ChildItem -LiteralPath $source -Recurse|ForEach-Object{$_.FullName})){Assert-ProtectedFrame $path}
 $results.dllSddl=(Get-Acl $dll).Sddl
 $results.sourceIdentities=$sourceReceipts;$results.directoryIdentities=@(@($dirs)+@($generatedDirs)|ForEach-Object{@{path=$_.Path;id=$_.Id}})
 $results.sourceSddl=(Get-Acl $source).Sddl;$results.evidenceSddl=(Get-Acl $evidence).Sddl;$results.manifestHash=$manifestHash;$results.dllHash=(Get-FileHash $dll -Algorithm SHA256).Hash;$results.sourceHash=$manifest.files['selected source.txt']
 $child=__CHILD__
 $child=$child.Replace('BOUNDARY_HELPER',('. '+"'"+(Join-Path $output 'ownership.ps1')+"'")).Replace('__OUTPUT__',("'"+$output.Replace("'","''")+"'")).Replace('__SOURCE__',("'"+$source.Replace("'","''")+"'")).Replace('__DLL__',("'"+$dll.Replace("'","''")+"'")).Replace('__DOTNET__',("'"+$dotnet.Replace("'","''")+"'")).Replace('__EVIDENCE__',("'"+(Join-Path $evidence 'sentinel.txt')+"'")).Replace('__RECOVERY__',("'"+(Join-Path $recovery 'sentinel.txt')+"'"))
 $childScriptReceipt=New-OwnedTextFile (Join-Path $output 'child.ps1') $child;Seal-ReadFile $childScriptReceipt.Identity.path;$childScriptReceipt.Dispose()
 $stub='try{. '+"'"+(Join-Path $output 'child.ps1')+"'"+' *> '+"'"+(Join-Path $output 'child-diagnostic.txt')+"'"+'}catch{$_|Out-String|Set-Content -LiteralPath '+"'"+(Join-Path $output 'child-error.txt')+"'"+'}'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($stub))
 $system=[Environment]::SystemDirectory
 $runasArgs='/trustlevel:0x20000 "'+(Join-Path $system 'conhost.exe')+' --headless '+(Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe')+' -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded+'"'
 if($runasArgs.Length -gt 30000){throw 'Native command exceeds bounded length'}
 $runas=Start-Process -FilePath (Join-Path $system 'runas.exe') -ArgumentList $runasArgs -RedirectStandardOutput (Join-Path $output 'runas-stdout.txt') -RedirectStandardError (Join-Path $output 'runas-stderr.txt') -PassThru -WindowStyle Hidden
 $runasOwner=New-OwnedProcess $runas;$processes.Add($runasOwner)
 if(-not$runas.WaitForExit(10000)){Stop-OwnedProcess $runasOwner;throw 'Runas timeout'};$runas.Refresh();$results.runasExit=$runas.ExitCode
 $deadline=[DateTime]::UtcNow.AddSeconds(25);$heldChild=$null;$heldDotnet=$null
 while([DateTime]::UtcNow -lt $deadline){
  foreach($item in @(@('process.json','heldChild'),@('dotnet-process.json','heldDotnet'))){
   $path=Join-Path $output $item[0]
   if(-not(Get-Variable -Name $item[1] -ValueOnly) -and [IO.File]::Exists($path)){
    $r=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json;$process=Get-Process -Id $r.pid -ErrorAction SilentlyContinue
    if($process){$owned=New-OwnedProcess $process;if($owned){if($owned.Identity.creationTimeFileTimeUtc -cne $r.creationTimeFileTimeUtc -or $owned.Identity.imagePath -ine $r.imagePath){throw 'Child process identity mismatch'};$processes.Add($owned);if([SourceBoundary.Token]::Admin($owned.handle)){throw 'Restricted process has Administrators enabled'};Set-Variable -Name $item[1] -Value $owned}}
   }
  }
  if([IO.File]::Exists((Join-Path $output 'assembly.json')) -or [IO.File]::Exists((Join-Path $output 'probe.json'))){break}
  Start-Sleep -Milliseconds 50
 }
 if(-not$heldChild){throw 'Actual restricted child identity absent'}
 $results.childIdentity=$heldChild.Identity
 if([IO.File]::Exists((Join-Path $output 'assembly.json'))){
  $a=Get-Content -Raw (Join-Path $output 'assembly.json')|ConvertFrom-Json;$results.assembly=$a
  if(-not$heldDotnet -or $a.pid -ne $heldDotnet.Identity.pid -or $a.created -cne $heldDotnet.Identity.creationTimeFileTimeUtc -or $a.sid -cne $expected -or $a.adminGroup -or $a.hash -ine $results.dllHash -or $a.assembly -ine $dll){throw 'Launched assembly identity/token/hash differs'}
  $results.dotnetIdentity=$heldDotnet.Identity
  $release=New-OwnedTextFile (Join-Path $output 'release-assembly.txt') 'release';$release.Dispose()
 }
 $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not[IO.File]::Exists((Join-Path $output 'probe.json')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
 if(-not[IO.File]::Exists((Join-Path $output 'probe.json'))){throw 'Restricted probe absent'}
 $probe=Get-Content -Raw (Join-Path $output 'probe.json')|ConvertFrom-Json;$results.probe=$probe
 $release=New-OwnedTextFile (Join-Path $output 'release-child.txt') 'release';$release.Dispose()
 if(-not$heldChild.process.WaitForExit(5000)){throw 'Restricted child remains after release'}
 $null=Assert-SourceSnapshot $source $manifestHash
 $results.sourceUnchanged=$true;$results.parentUnchanged=((Get-Acl C:\RooBuild).Sddl -ceq $results.parentSddl)
 $results.assemblyError=[IO.File]::ReadAllText((Join-Path $output 'assembly-stderr.txt'))
 $results.passed=($probe.sid -ceq $expected -and -not$probe.adminGroup -and $probe.readHash -ceq $results.sourceHash -and $probe.manifestReadHash -ceq $manifestHash -and $probe.sourceWriteDenied -and $probe.sourceCreateDenied -and $probe.sourceRenameDenied -and $probe.evidenceReadDenied -and $probe.recoveryReadDenied -and $probe.assemblyExit -eq 0 -and $results.Contains('assembly') -and $results.parentUnchanged -and $results.manifestMismatchRefused -and @($results.scopeRefusals.Values|Where-Object{-not$_}).Count -eq 0)
} catch {$results.error=$_.Exception.Message;$results.childDiagnostics=@(foreach($name in 'child-diagnostic.txt','child-error.txt'){if([IO.File]::Exists((Join-Path $output $name))){[IO.File]::ReadAllText((Join-Path $output $name))}})} finally {
 foreach($owned in $processes){if($owned){try{Stop-OwnedProcess $owned}catch{$results.error=($results.error+'; cleanup: '+$_.Exception.Message)}}}
 try {
  if($childScriptReceipt){$r=Open-OwnedProbe $childScriptReceipt.Identity;$r.Remove()};if($helperReceipt){$r=Open-OwnedProbe $helperReceipt.Identity;$r.Remove()}
  foreach($f in $sourceReceipts){$r=Open-OwnedProbe $f;$r.Remove()}
  foreach($f in $files){if([IO.File]::Exists($f.path)){$r=Open-OwnedProbe $f;$r.Remove()}}
  $knownOutput='child-diagnostic.txt','child-error.txt','build-stdout.txt','build-stderr.txt','runas-stdout.txt','runas-stderr.txt','process.json','dotnet-process.json','assembly.json','assembly-stdout.txt','assembly-stderr.txt','probe.json','release-assembly.txt','release-child.txt'
  foreach($name in $knownOutput){$path=Join-Path $output $name;if([IO.File]::Exists($path)){$r=Open-OwnedProbe (Get-Receipt $path);$r.Remove()}}
  foreach($d in @($generatedDirs|Sort-Object {$_.Path.Length} -Descending)){$d.Remove()}
  for($i=$dirs.Count-1;$i -ge 0;$i--){$dirs[$i].Remove()}
  $results.cleanup=(-not[IO.Directory]::Exists($frame) -and -not[IO.Directory]::Exists($output))
 } catch {$results.cleanupError=$_.Exception.Message} finally {foreach($d in @($dirs)+@($generatedDirs)){$d.Dispose()};if($helperReceipt){$helperReceipt.Dispose()};if($childScriptReceipt){$childScriptReceipt.Dispose()};foreach($owned in $processes){if($owned){$owned.process.Dispose()}}}
 $results.durationMs=$clock.ElapsedMilliseconds
}
$results|ConvertTo-Json -Depth 12 -Compress
'''

helper = (ROOT / 'tools/validation/LoadTimes/CleanupOwnership.Common.ps1').read_text()
parent_helper = helper.replace("'@\n}", NATIVE + "\n'@\n}", 1)
frame = 'C:\\RooBuild\\roo-industries-source-boundary-' + uuid.uuid4().hex
helper_file = args.out / 'ownership.ps1'
helper_file.write_text(parent_helper)
execution = 'C:\\RooBuild\\roo-industries-source-boundary-execution-' + uuid.uuid4().hex
helper_path = execution + '\\ownership.ps1'
(args.out / 'frame.json').write_text(json.dumps({'frame': frame, 'execution': execution, 'helperHash': hashlib.sha256(helper_file.read_bytes()).hexdigest()}, indent=2))
w.invoke('optimizer-9070', 'SERVI-WINDOWS-D', w.REMOTE_GUARDS + "\nif([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-21-2864832615-2000329836-3074386272-1001'){throw 'Target SID differs'};New-ProtectedFrame " + p(frame) + ';New-ProtectedFrame ' + p(execution))
subprocess.run(['scp', *w.SSH_OPTIONS, str(helper_file), 'optimizer-9070:' + helper_path.replace('\\', '/')], check=True, capture_output=True)
script = REMOTE.replace('__GUARDS__', w.REMOTE_GUARDS).replace('__FRAME__', p(frame)).replace('__PARENT_HELPER__', p(helper_path))
script = script.replace('. ' + p(helper_path), "if((Get-FileHash -LiteralPath " + p(helper_path) + " -Algorithm SHA256).Hash -ine '" + hashlib.sha256(helper_file.read_bytes()).hexdigest() + "'){throw 'Fixture helper bytes differ'}; . " + p(helper_path), 1)
for key, value in {'__ASSEMBLY__': ASSEMBLY, '__CHILD__': CHILD}.items():
    script = script.replace(key, p(value))
(args.out / 'native.ps1').write_text(script)
(args.out / 'input.json').write_text(json.dumps({'host': 'optimizer-9070', 'machine': 'SERVI-WINDOWS-D', 'sourceToolHash': hashlib.sha256((ROOT / 'tools/validation/windows_ssh.py').read_bytes()).hexdigest()}, indent=2))
started = time.monotonic()
try:
    subprocess.run(['scp', *w.SSH_OPTIONS, str(args.out / 'native.ps1'), 'optimizer-9070:' + (execution + '\\native.ps1').replace('\\', '/')], check=True, capture_output=True)
    task_name = 'RooSourceBoundary_' + uuid.uuid4().hex
    wrapper = "$ErrorActionPreference='Stop';if((Get-FileHash -LiteralPath " + p(execution + '\\native.ps1') + " -Algorithm SHA256).Hash -ine '" + hashlib.sha256((args.out / 'native.ps1').read_bytes()).hexdigest() + "'){throw 'Native fixture bytes differ'};& " + p(execution + '\\native.ps1') + " | Set-Content -LiteralPath " + p(execution + '\\result.json')
    entry = args.out / 'entry.ps1'
    entry.write_text(wrapper)
    subprocess.run(['scp', *w.SSH_OPTIONS, str(entry), 'optimizer-9070:' + (execution + '\\entry.ps1').replace('\\', '/')], check=True, capture_output=True)
    setup = w.REMOTE_GUARDS + "\nif((Get-FileHash -LiteralPath " + p(helper_path) + " -Algorithm SHA256).Hash -ine '" + hashlib.sha256(helper_file.read_bytes()).hexdigest() + "'){throw 'Task helper bytes differ'};. " + p(helper_path) + ";$name=" + p(task_name) + ";$run=" + p(execution) + ";$system=[Environment]::SystemDirectory;$r=$null;try{if((Get-FileHash -LiteralPath (Join-Path $run 'entry.ps1') -Algorithm SHA256).Hash -ine '" + hashlib.sha256(entry.read_bytes()).hexdigest() + "'){throw 'Task entry bytes differ'};$r=Register-OwnedProbeTask $name (Join-Path $system 'conhost.exe') ('--headless \"'+(Join-Path $system 'WindowsPowerShell\\v1.0\\powershell.exe')+'\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"'+(Join-Path $run 'entry.ps1')+'\"') $system 'S-1-5-21-2864832615-2000329836-3074386272-1001' 3 3;$r|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $run 'task.json');Assert-OwnedTaskUnchanged $r;[void](Get-OwnedTaskFolder '\\').GetTask($name).Run($null);$deadline=[DateTime]::UtcNow.AddSeconds(100);while(-not[IO.File]::Exists((Join-Path $run 'result.json')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100};if(-not[IO.File]::Exists((Join-Path $run 'result.json'))){throw 'Native scheduled fixture timeout'};Get-Content -Raw -LiteralPath (Join-Path $run 'result.json')}finally{if($r){Remove-OwnedTask $r;Assert-OwnedTaskAbsent $r.name}}"
    (args.out / 'task-setup.ps1').write_text(setup)
    result = w.invoke('optimizer-9070', 'SERVI-WINDOWS-D', setup, timeout=300)
    (args.out / 'stdout.txt').write_text(result.stdout)
    (args.out / 'stderr.txt').write_text(result.stderr)
    evidence = json.loads(result.stdout.strip().splitlines()[-1])
    cleanup = cleanup_execution(execution, helper_path, args.out)
    evidence['executionCleanup'] = cleanup['executionAbsent'] and cleanup['taskAbsent']
    evidence['task'] = cleanup['task']
    evidence['transportSeconds'] = round(time.monotonic() - started, 3)
    (args.out / 'result.json').write_text(json.dumps(evidence, indent=2))
    print(json.dumps({key: evidence.get(key) for key in ('passed', 'cleanup', 'executionCleanup', 'error', 'frame', 'durationMs', 'transportSeconds')}, indent=2))
    sys.exit(0 if evidence['passed'] and evidence['cleanup'] and evidence['executionCleanup'] else 1)
except subprocess.CalledProcessError as error:
    (args.out / 'stdout.txt').write_text(error.stdout or '')
    (args.out / 'stderr.txt').write_text(error.stderr or '')
    print(error.stderr or error.stdout, file=sys.stderr)
    sys.exit(error.returncode)
