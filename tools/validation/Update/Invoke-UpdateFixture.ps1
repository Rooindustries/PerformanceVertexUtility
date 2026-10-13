param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
    [Parameter(Mandatory)][ValidateSet('start-game','stop-game','block-setup','unblock-setup','read-security','reset-download','contract-probe')][string]$Action,[string]$Version='',[string]$CurrentVersion='',[string]$Probe='',[string]$Manifest='',[string]$FeedUrl='',[string]$InstallerPath='')
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('fixture-'+$Action) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('fixture-'+$Action)
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
$install='C:\Program Files\Roo Industries\Optimization Suite'
$hostExe=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$data=Get-RooIndustriesLocalDataRoot
$utf8=[Text.UTF8Encoding]::new($false)
function Save([string]$name,$value){Write-HarnessResult $directory $name $value|Out-Null}
function Core([string]$action,[hashtable]$fields){Assert-HarnessHostLease;$request=@{schemaVersion=1;repoRoot=$install;confirm=$true};foreach($key in $fields.Keys){$request[$key]=$fields[$key]};$result=Invoke-HarnessHost $hostExe $action $request;if($result.status -ne 'completed'){throw ($result|ConvertTo-Json -Depth 30)};$result.data}
$state='fail'
try{
switch($Action){
 'contract-probe' {
  if(-not$Probe -or -not$Manifest -or -not$FeedUrl -or -not$CurrentVersion){throw 'Contract probe arguments are missing.'}
  $output=Get-HarnessOutputPath $directory 'contract-probe.json';$env:ROO_HARNESS_NONCE=$nonce
  $arguments=(@($Manifest,$FeedUrl,$CurrentVersion,$output)+@($(if($InstallerPath){$InstallerPath})))|Where-Object {$_}|ForEach-Object {'"'+$_+'"'}
  $process=Start-OwnedProcess -FilePath $Probe -ArgumentList ($arguments -join ' ') -Purpose contract
  if(-not$process.process.WaitForExit(120000)){throw 'Contract probe timeout'}
  if($process.process.ExitCode -ne 0){throw 'Contract probe failed'}
  $entry=Register-HarnessFile $output 'probe-result';$record=[IO.File]::ReadAllText((Get-HarnessLongPath $output))|ConvertFrom-Json
  if($record.nonce -cne $nonce){throw 'Contract output nonce differs.'}
  Save 'contract.json' $record.data
 }


 'reset-download' {
  if(-not$Version -or -not$CurrentVersion){throw 'reset-download requires this run current and next versions.'}
  $updates=Join-Path $data 'updates';Initialize-HarnessCache $updates @($CurrentVersion,$Version)
  $entry=Register-HarnessCache $Version
  if($entry){Save 'reset-download.json' @{version=$Version;entry=$entry};Remove-HarnessEntry $entry}
 }
 'start-game' {
  $fixture=Join-Path $directory 'game-fixture';New-HarnessDirectory $fixture 'game-fixture'|Out-Null
  $launcher=Join-Path $fixture 'ota-launcher.exe';$game=Join-Path $fixture 'ota-game.exe'
  Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $launcher|Out-Null;Copy-HarnessFile "$env:SystemRoot\System32\PING.EXE" $game|Out-Null
  $owned=Start-OwnedProcess -FilePath $launcher -ArgumentList '-t 127.0.0.1' -Purpose game-launcher -Lifetime run;$process=$owned.process
  Save 'game-launcher.json' @{identity=$owned.Identity;ledgerId=$owned.LedgerId}
  $preview=Join-Path $fixture 'preview.json'
  $plan=Core 'protected-session-preview' @{processId=$process.Id;gamePath=$game;controls=@{cpuPriority='Normal'};acceptLauncherScope=$true;outputPath=$preview}
  $session=Join-Path $data ('operations\game-session-'+$plan.operationId+'\session')
  $result=@(& (Join-Path $install 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action Start -PreviewPath $preview -ReviewHash (Get-HarnessFileSha256 $preview) -SessionRoot $session -ConfirmApply) -join "`n"
  Save 'game-session.json' @{sessionRoot=$session;result=($result|ConvertFrom-Json)}
 }
 'stop-game' {
  $session=Read-HarnessLatestResult 'game-session.json' 'fixture-start-game'
  $result=@(& (Join-Path $install 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot $session.sessionRoot -ConfirmApply) -join "`n"
  Save 'game-stop.json' ($result|ConvertFrom-Json)
  $launcher=Read-HarnessLatestResult 'game-launcher.json' 'fixture-start-game';Remove-HarnessEntry (Get-HarnessEntryById $launcher.ledgerId)
 }
 'block-setup' {
  $path=Join-Path $install 'setup';if(Test-HarnessPath $path){throw 'Setup path already exists; retain it'}
  $entry=New-HarnessText $path 'Roo Industries OTA E2E preparation refusal' 'setup-blocker'
  Save 'setup-blocker.json' @{ledgerId=$entry.id}
 }
 'unblock-setup' { $blocker=Read-HarnessLatestResult 'setup-blocker.json' 'fixture-block-setup';Remove-HarnessEntry (Get-HarnessEntryById $blocker.ledgerId) }
 'read-security' {
  $paths=@($data,(Join-Path $data 'updates'))
  $rows=@(foreach($path in $paths){$acl=Get-Acl -LiteralPath (Get-HarnessLongPath $path);@{path=$path;owner=$acl.Owner;sddl=$acl.Sddl;protected=$acl.AreAccessRulesProtected;rules=@($acl.Access|ForEach-Object {@{sid=$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;rights=[string]$_.FileSystemRights;type=[string]$_.AccessControlType;inherited=$_.IsInherited}})}})
  Save 'update-folder-security.json' $rows
  Add-Type @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
public static class RooUpdatePermissions {
 [StructLayout(LayoutKind.Sequential)] struct Sid { public IntPtr address; public uint attributes; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out SafeAccessTokenHandle token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(SafeAccessTokenHandle token,uint flags,uint disabled,[In] Sid[] sids,uint deleted,IntPtr privileges,uint restricted,IntPtr restrictSids,out SafeAccessTokenHandle result);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 public static int[] Check(string control,string protectedFile) {
  SafeAccessTokenHandle original,low;
  if(!OpenProcessToken(GetCurrentProcess(),10,out original)) throw new Win32Exception();
  var sid=new SecurityIdentifier("S-1-5-32-544");var bytes=new byte[sid.BinaryLength];sid.GetBinaryForm(bytes,0);var memory=Marshal.AllocHGlobal(bytes.Length);
  try { Marshal.Copy(bytes,0,memory,bytes.Length);
   if(!CreateRestrictedToken(original,1,1,new[]{new Sid{address=memory}},0,IntPtr.Zero,0,IntPtr.Zero,out low)) throw new Win32Exception();
   using(low) { return WindowsIdentity.RunImpersonated(low,()=> {
    if(new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))throw new InvalidOperationException("Restricted token still has Administrators enabled");
    var paths=new[]{control,protectedFile};var results=new int[2];
    for(int i=0;i<paths.Length;i++){using(var file=CreateFile(paths[i],0x40000000,0,IntPtr.Zero,1,128,IntPtr.Zero)){results[i]=file.IsInvalid?Marshal.GetLastWin32Error():0;}}
    return results;
   }); }
  }finally{Marshal.FreeHGlobal(memory);original.Dispose();}
 }
}
'@
  $probeName='roo-ota-write-'+[Guid]::NewGuid().ToString('N')+'.tmp'
  $control=Join-Path (Join-Path (Get-RooIndustriesLocalAppData) 'Temp') $probeName;$sealed=Join-Path (Join-Path $data 'updates') $probeName
  try{$result=[RooUpdatePermissions]::Check((Get-HarnessLongPath $control),(Get-HarnessLongPath $sealed));if($result[0] -eq 0){$controlEntry=Register-HarnessFile $control 'restricted-write' 'invocation'};if($result[1] -eq 0){$sealedEntry=Register-HarnessFile $sealed 'restricted-write' 'invocation'};Save 'update-folder-write-probe.json' @{administratorGroupDisabled=$true;privilegesRemoved=$true;controlWin32=$result[0];updatesWin32=$result[1]};if($result[0] -ne 0 -or $result[1] -ne 5){throw 'Update-folder permission control failed'}}finally{foreach($entry in @($controlEntry,$sealedEntry)){if($entry){Remove-HarnessEntry $entry}}}
 }
}

$state='pass'
}finally{$state=Complete-HarnessInvocation $state -Cleanup;Save 'invocation.json' @{status=$state;nonce=$nonce}}
