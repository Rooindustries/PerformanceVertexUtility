param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
    [Parameter(Mandatory)][ValidateSet('start-game','stop-game','block-setup','unblock-setup','read-security','reset-download')][string]$Action)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
$install='C:\Program Files\Roo Industries\Optimization Suite'
$hostExe=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$data=Get-RooIndustriesLocalDataRoot
$utf8=[Text.UTF8Encoding]::new($false)
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $OutRoot $name),($value|ConvertTo-Json -Depth 40),$utf8)}
function Core([string]$action,[hashtable]$fields){$request=@{schemaVersion=1;repoRoot=$install;confirm=$true};foreach($key in $fields.Keys){$request[$key]=$fields[$key]};$OutputEncoding=$utf8;$raw=@(($request|ConvertTo-Json -Depth 30)|& $hostExe $action '-') -join "`n";$result=$raw|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw $raw};$result.data}
switch($Action){
 'reset-download' {
  $folder=Join-Path $data 'updates\0.11.1-beta';$manifest=Join-Path $folder 'manifest.json'
  $binary=Join-Path $folder 'RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe'
  if(Test-Path $binary){
   $envelope=Get-Content -Raw $manifest|ConvertFrom-Json
   $release=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($envelope.payload))|ConvertFrom-Json
   if($release.version -ne '0.11.1-beta' -or (Get-Item $binary).Length -ne $release.installer.size -or (Get-FileHash $binary).Hash -ine $release.installer.sha256){throw 'Cached test installer changed; retain it'}
   Save 'reset-download.json' @{installer=$binary;sha256=$release.installer.sha256;size=$release.installer.size}
   [IO.File]::Delete($binary);[IO.File]::Delete($manifest)
   if(@(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0){[IO.Directory]::Delete($folder)}
  }
 }
 'start-game' {
  $fixture=Join-Path $OutRoot 'game-fixture';[IO.Directory]::CreateDirectory($fixture)|Out-Null
  $launcher=Join-Path $fixture 'ota-launcher.exe';$game=Join-Path $fixture 'ota-game.exe'
  Copy-Item "$env:SystemRoot\System32\PING.EXE" $launcher;Copy-Item "$env:SystemRoot\System32\PING.EXE" $game
  $process=Start-Process $launcher -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $process
  Save 'game-launcher.json' $owned.Identity
  $preview=Join-Path $fixture 'preview.json'
  $plan=Core 'protected-session-preview' @{processId=$process.Id;gamePath=$game;controls=@{cpuPriority='Normal'};acceptLauncherScope=$true;outputPath=$preview}
  $session=Join-Path $data ('operations\game-session-'+$plan.operationId+'\session')
  $result=@(& (Join-Path $install 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action Start -PreviewPath $preview -ReviewHash (Get-FileHash $preview).Hash -SessionRoot $session -ConfirmApply) -join "`n"
  Save 'game-session.json' @{sessionRoot=$session;result=($result|ConvertFrom-Json)}
 }
 'stop-game' {
  $session=Get-Content -Raw (Join-Path $OutRoot 'game-session.json')|ConvertFrom-Json
  $result=@(& (Join-Path $install 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot $session.sessionRoot -ConfirmApply) -join "`n"
  Save 'game-stop.json' ($result|ConvertFrom-Json)
  Stop-OwnedProcessIdentity (Get-Content -Raw (Join-Path $OutRoot 'game-launcher.json')|ConvertFrom-Json)
 }
 'block-setup' {
  $path=Join-Path $install 'setup';if(Test-Path $path){throw 'Setup path already exists; retain it'}
  $file=New-OwnedTextFile $path 'Roo Industries OTA E2E preparation refusal'
  Save 'setup-blocker.json' $file.Identity;$file.Dispose()
 }
 'unblock-setup' { $file=Open-OwnedProbe (Get-Content -Raw (Join-Path $OutRoot 'setup-blocker.json')|ConvertFrom-Json);Remove-OwnedProbe $file }
 'read-security' {
  $paths=@($data,(Join-Path $data 'updates'))
  $rows=@(foreach($path in $paths){$acl=Get-Acl $path;@{path=$path;owner=$acl.Owner;sddl=$acl.Sddl;protected=$acl.AreAccessRulesProtected;rules=@($acl.Access|ForEach-Object {@{sid=$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;rights=[string]$_.FileSystemRights;type=[string]$_.AccessControlType;inherited=$_.IsInherited}})}})
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
  try{$result=[RooUpdatePermissions]::Check($control,$sealed);Save 'update-folder-write-probe.json' @{administratorGroupDisabled=$true;privilegesRemoved=$true;controlWin32=$result[0];updatesWin32=$result[1]};if($result[0] -ne 0 -or $result[1] -ne 5){throw 'Update-folder permission control failed'}}finally{foreach($path in @($control,$sealed)){if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}}
 }
}
