param([Parameter(Mandatory=$true)][string]$Runner,[Parameter(Mandatory=$true)][string]$Frame,[ValidatePattern('^[a-z0-9-]+$')][string]$RunName='proof',[ValidatePattern('^[a-z0-9]{8}$')][string]$CloneName='recovery')
$ErrorActionPreference='Stop'
$clock=[Diagnostics.Stopwatch]::StartNew()
if($env:COMPUTERNAME -cne 'SERVI-WINDOWS-D' -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-21-2864832615-2000329836-3074386272-1001'){throw 'Wrong native fixture target'}
if($Frame -cnotmatch '^C:\\RooBuild\\roo-industries-final-run-[a-f0-9]{32}$'){throw 'Not a private GUID fixture'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner does not parse'}
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$backup=Join-Path $Frame ($RunName+'-fixture')
Assert-RecoveryEvidenceParent
New-SealedDirectory $backup
$log=Join-Path $backup 'runner.log'
$env:TEMP=$backup;$env:TMP=$backup
Initialize-RecoveryNative
Add-Type @'
using System;using System.Runtime.InteropServices;using System.IO;using System.Security.Cryptography;using Microsoft.Win32.SafeHandles;
public static class RecoveryLongProbe {
 [DllImport("kernel32.dll",EntryPoint="GetFileAttributesW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern uint Attributes(string p);
 [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle Open(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",EntryPoint="CreateSymbolicLinkW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Link(string p,string target,uint flags);
 public static string Hash(string p){using(var h=Open(p,0x80000000,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)){if(h.IsInvalid)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());using(var fs=new FileStream(h,FileAccess.Read))using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-","");}}
}
'@
$checks=[Collections.Generic.List[object]]::new()
function Pass([string]$Name,$Detail){$checks.Add(@{name=$Name;detail=$Detail});Write-Output ('PASS '+$Name)}
function Require([bool]$Ok,[string]$Name){if(-not$Ok){throw $Name};Pass $Name $true}
function Refuses([scriptblock]$Body,[string]$Pattern,[string]$Name){$caught=$null;try{& $Body|Out-Null}catch{$caught=$_.Exception.Message};if(-not$caught -or $caught -notmatch $Pattern){throw ($Name+' expected '+$Pattern+', received '+$caught)};Pass $Name $caught}
function Extended([string]$Path){'\\?\'+$Path}
function RawRows([string]$Root){
 $base=[IO.DirectoryInfo]::new((Extended $Root));$items=@($base)+@($base.GetFileSystemInfos('*',[IO.SearchOption]::AllDirectories))
 @($items|ForEach-Object {$i=$_;$i.Refresh();$acl=$i.GetAccessControl([Security.AccessControl.AccessControlSections]::All);[pscustomobject]@{relative=$i.FullName.Substring($base.FullName.Length);directory=($i -is [IO.DirectoryInfo]);length=$(if($i -is [IO.DirectoryInfo]){0}else{$i.Length});creation=$i.CreationTimeUtc.Ticks.ToString();write=$i.LastWriteTimeUtc.Ticks.ToString();attributes=[int]$i.Attributes;sha256=$(if($i -is [IO.DirectoryInfo]){''}else{[RecoveryLongProbe]::Hash($i.FullName)});sddl=$acl.Sddl;control=[int][Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0).ControlFlags;descriptor=[Convert]::ToBase64String($acl.GetSecurityDescriptorBinaryForm())}}|Sort-Object relative)
}
function ExactRaw($Expected,$Actual,[string]$Name){
 $a=@($Expected|ForEach-Object {$_|ConvertTo-Json -Compress});$b=@($Actual|ForEach-Object {$_|ConvertTo-Json -Compress})
 if(@(Compare-Object $a $b -CaseSensitive).Count){throw ('Independent raw mismatch: '+$Name)};Pass $Name $true
}
try {
 $sourceParent=Join-Path $Frame ('s'+$RunName.Substring(0,[Math]::Min(6,$RunName.Length)))
 New-SealedDirectory $sourceParent
 $source=Join-Path $sourceParent 'RooOptimizationSuite'
 $relative='\firmware\verification\runs\8f7687d1aa4e47689e55ca68a2a6d798\sessions\24cb1f5b816e444c9b30cdc31d704fd6\execution-3efc59d2cc244c20bdeee089de104158.txt.result.json'
 $file=$source+$relative
 [IO.Directory]::CreateDirectory((Extended ([IO.Path]::GetDirectoryName($file))))|Out-Null
 $bytes=New-Object byte[] 684;for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[byte]($i%251)}
 [IO.File]::WriteAllBytes((Extended $file),$bytes)
 $sentinel=Join-Path $source 'foreign-sentinel.bin';[IO.File]::WriteAllText((Extended $sentinel),'foreign value retained')
 $readOnly=Join-Path $source 'readonly.bin';[IO.File]::WriteAllText((Extended $readOnly),'readonly value retained')
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;RC;;;OW)');[IO.File]::SetAccessControl((Extended $readOnly),$acl)
 foreach($i in @([IO.DirectoryInfo]::new((Extended $source)))+@([IO.DirectoryInfo]::new((Extended $source)).GetFileSystemInfos('*',[IO.SearchOption]::AllDirectories))){$i.CreationTimeUtc=[DateTime]::new(639264763609996092,[DateTimeKind]::Utc);$i.LastWriteTimeUtc=[DateTime]::new(638900000001234567,[DateTimeKind]::Utc)}
 [IO.File]::SetAttributes((Extended $readOnly),[IO.FileAttributes]33)
 $original=@(RawRows $source)
 $diagnostic=Join-Path $Frame ('d'+$RunName.PadRight(7,'0').Substring(0,7));New-SealedDirectory $diagnostic
 $probe=(Join-Path $diagnostic 'RooOptimizationSuite')+$relative;[IO.Directory]::CreateDirectory((Extended ([IO.Path]::GetDirectoryName($probe))))|Out-Null;[IO.File]::WriteAllBytes((Extended $probe),$bytes)
 $legacy=[IO.FileInfo]::new($probe);$legacy.Refresh()
 Require ([int]$legacy.Attributes -eq -1 -and [RecoveryLongProbe]::Attributes((Extended $probe)) -eq 32 -and $probe.Length -eq 260) 'native-long-path-exists-legacy-refresh-falsely-reparse'
 Pass 'source-destination-shape' @{sourceLength=$file.Length;probeLength=$probe.Length;originalCaseLength=260;relative=$relative;bytes=684;nativeHash=[RecoveryLongProbe]::Hash((Extended $file))}
 $bootstrap=[powershell]::Create()
 try {
  $body=(@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Assert-PlainRecoveryPath','New-SealedDirectory','Assert-SealedRecovery'},$false)|ForEach-Object {$_.Extent.Text}) -join "`n")+"`nNew-SealedDirectory '"+(Join-Path $backup 'three-function-bootstrap')+"'"
  [void]$bootstrap.AddScript($body);$bootstrap.Invoke()|Out-Null
  Require (-not$bootstrap.HadErrors) 'existing-three-function-bootstrap-compatible'
 } finally {$bootstrap.Dispose()}
 $rows=@(Get-RecoveryRows $source)
 Require ($rows.Count -eq $original.Count) 'shared-reader-enumerates-every-long-path'
 $exact=Join-Path $Frame $CloneName;New-SealedDirectory $exact
 $clone=Join-Path $exact 'RooOptimizationSuite'
 Require (($clone+$relative).Length -eq 260) 'exact-260-character-destination'
 Copy-VerifiedTree $source $clone -SealTarget|Out-Null
 Assert-SealedRecovery $clone
 $manifest=@(Read-RecoveryJson ($clone+'.manifest.json'))
 Assert-RecoveryEqual (Recovery-Lines $rows) (Recovery-Lines $manifest) 'retained-original-manifest'
 Pass 'complete-copy-seal-retains-original-rows' $manifest.Count
 $epoch=Join-Path $backup ('epoch-installed-'+('7'*32));New-SealedDirectory $epoch
 $asnow=Join-Path $epoch 'asnow-RooOptimizationSuite'
 Copy-VerifiedTree $source $asnow -SealTarget|Out-Null
 $rollback=Join-Path $epoch 'rollback-RooOptimizationSuite'
 Copy-VerifiedTree $clone $rollback -OriginalRows $manifest|Out-Null
 ExactRaw $original @(RawRows $rollback) 'long-rollback-raw-acl-control-times-attributes-hashes-exact'
 $local=Join-Path $epoch 'local';New-SealedDirectory $local
 $activated=Join-Path $local 'RooOptimizationSuite'
 Copy-VerifiedTree $source $activated|Out-Null
 $liveLines=@(Get-TreeFingerprint $activated)
 $script:epochDir=$epoch
 Restore-Folder 'RooOptimizationSuite' @{stage=$rollback;original=@(Recovery-Lines $manifest);live=$liveLines}
 ExactRaw $original @(RawRows $activated) 'activation-rename-descriptor-reapply-exact'
 $quarantine=Join-Path $epoch 'quarantine-RooOptimizationSuite'
 Assert-SealedRecovery $quarantine
 Assert-RecoveryEqual (Recovery-Lines $rows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $quarantine) -DataOnly) 'quarantine bytes metadata'
 Pass 'actual-shared-restore-retains-sealed-quarantine' $true
 $longJson=Join-Path ([IO.Path]::GetDirectoryName($asnow+$relative)) ('epoch-recovery-original-'+('8'*64)+'.json')
 Save-RecoveryJson $longJson @{fixture='asnow';state=@('original','retained');length=$longJson.Length}
 $read=Read-RecoveryJson $longJson
 Require ($read.fixture -ceq 'asnow' -and $longJson.Length -gt ($clone+$relative).Length) 'long-evidence-json-exclusive-write-read'
 Refuses {Save-RecoveryJson $longJson @{fixture='replaced'}} 'already exists' 'existing-long-evidence-not-overwritten'
 Require ((Read-RecoveryJson $longJson).fixture -ceq 'asnow') 'exclusive-json-retains-original'
 $adsParent=Join-Path $backup 'ads';New-SealedDirectory $adsParent
 $adsFile=(Join-Path $adsParent 'RooOptimizationSuite')+$relative;[IO.Directory]::CreateDirectory((Extended ([IO.Path]::GetDirectoryName($adsFile))))|Out-Null;[IO.File]::WriteAllText((Extended $adsFile),'base');[IO.File]::WriteAllText((Extended ($adsFile+':foreign')),'foreign stream')
 Refuses {Get-RecoveryRows $adsParent} 'Named alternate streams' 'named-ads-still-refused'
 $linkParent=Join-Path $backup 'links';New-SealedDirectory $linkParent
 $link=(Join-Path $linkParent 'RooOptimizationSuite')+$relative;[IO.Directory]::CreateDirectory((Extended ([IO.Path]::GetDirectoryName($link))))|Out-Null
 Require ([RecoveryLongProbe]::Link((Extended $link),(Extended $sentinel),0)) 'real-reparse-fixture-created'
 Refuses {Get-RecoveryRows $linkParent} 'reparse' 'real-reparse-still-refused'
 Refuses {Assert-SealedRecovery $linkParent} 'reparse' 'sealed-evidence-refuses-real-reparse'
 Refuses {Assert-PlainRecoveryPath $link} 'reparse' 'ancestry-refuses-real-reparse'
 $missing=Join-Path $epoch ('missing-'+('9'*140)+'.bin')
 Refuses {Get-RecoveryRows $missing} 'cannot find|does not exist|not find' 'missing-long-path-reported-as-missing'
 $writerParent=Join-Path $backup 'untrusted';New-SealedDirectory $writerParent
 $writer=(Join-Path $writerParent 'RooOptimizationSuite')+$relative;[IO.Directory]::CreateDirectory((Extended ([IO.Path]::GetDirectoryName($writer))))|Out-Null;[IO.File]::WriteAllText((Extended $writer),'retained')
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FW;;;WD)');[IO.File]::SetAccessControl((Extended $writer),$acl)
 Refuses {Assert-SealedRecovery $writerParent} 'untrusted writer' 'long-path-untrusted-writer-still-refused'
 $auditParent=Join-Path $backup 'audited';New-SealedDirectory $auditParent
 $audit=(Join-Path $auditParent 'RooOptimizationSuite')+$relative;[IO.Directory]::CreateDirectory((Extended ([IO.Path]::GetDirectoryName($audit))))|Out-Null;[IO.File]::WriteAllText((Extended $audit),'retained audit')
 $raw=[Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)S:(AU;SAFA;FA;;;WD)');$descriptor=New-Object byte[] $raw.BinaryLength;$raw.GetBinaryForm($descriptor,0)
 Require ([RooVerificationRecovery.Native]::Exact((Extended $audit),[uint32]7,$descriptor)) 'real-audit-acl-fixture-created'
 Refuses {Get-RecoveryRows $auditParent} 'Audit ACL' 'audit-acl-still-refused'
 Require (@(@($adsFile,$link,$writer,$audit,$missing)|Where-Object {$_.Length -lt 260}).Count -eq 0) 'every-negative-fixture-uses-a-long-path'
 ExactRaw $original @(RawRows $source) 'original-and-foreign-sentinel-readonly-unchanged'
 $proof=@{machine=$env:COMPUTERNAME;sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ps=$PSVersionTable.PSVersion.ToString();runnerHash=(Get-FileHash -LiteralPath $Runner).Hash;testHash=(Get-FileHash -LiteralPath $PSCommandPath).Hash;checks=$checks;source=$source;clone=$clone;asnow=$asnow;activated=$activated;json=$longJson;elapsedSeconds=$clock.Elapsed.TotalSeconds}
 [IO.File]::WriteAllText((Join-Path $backup 'proof.json'),($proof|ConvertTo-Json -Depth 8))
 $proof|ConvertTo-Json -Depth 8
} catch {
 [IO.File]::WriteAllText((Join-Path $backup 'failure.json'),(@{error=$_.Exception.Message;stack=$_.ScriptStackTrace;checks=$checks;elapsedSeconds=$clock.Elapsed.TotalSeconds}|ConvertTo-Json -Depth 8))
 throw
}
