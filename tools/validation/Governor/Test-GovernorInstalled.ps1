param([Parameter(Mandatory)][string]$Phase,[Parameter(Mandatory)][Alias('GIWork')][string]$Work,[Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$SourceManifestSha256,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$FixtureId,[string]$OwnerSha256='',[string]$Installer='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($Phase -in 'kill-setup','kill-setup-rerun','legacy-before'){throw 'This historical mode cannot prove exclusive child ownership. Use the retained tools/validation/SetupMigration/Test-SetupMigration.ps1 interrupted-Resume E2E; no mutation was performed.'}
function Assert-GiProtected([string]$Path){
 $p=[IO.Path]::GetFullPath($Path)
 while($p){$item=Get-Item -LiteralPath $p -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse fixture ancestry: '+$p)};$p=[IO.Path]::GetDirectoryName($p)}
 $acl=Get-Acl -LiteralPath $Path
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544'){throw 'Fixture owner is not admin'}
 foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' -and ([long]$ace.FileSystemRights -band 0x500D0156)){throw 'Fixture allows non-admin changes'}}
}
$Source=[IO.Path]::GetFullPath($Source).TrimEnd('\');$Work=[IO.Path]::GetFullPath($Work).TrimEnd('\')
Assert-GiProtected $Source
$manifestPath=Join-Path $Source 'source-verification.json'
if((Get-FileHash -LiteralPath $manifestPath).Hash -ine $SourceManifestSha256){throw 'Source receipt changed'}
$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($manifest.protocol -cne 'roo-industries-source-snapshot/v2' -or $manifest.machine -ine $env:COMPUTERNAME -or $manifest.sid -cne $sid -or $manifest.frameId -cne $FixtureId){throw 'Source fixture scope differs'}
foreach($file in $manifest.files.PSObject.Properties){$path=[IO.Path]::GetFullPath((Join-Path $Source $file.Name));if(-not$path.StartsWith($Source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source traversal'};Assert-GiProtected ([IO.Path]::GetDirectoryName($path));if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $path).Hash -ine $file.Value){throw ('Staged source changed: '+$file.Name)}}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
function Get-GiDirectoryId([string]$Path){$handle=[RooIndustriesValidationOwnership.Native]::CreateFile($Path,0,7,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero);try{if($handle.IsInvalid){throw 'Cannot identify fixture folder'};[RooIndustriesValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}}
$runRoot=Split-Path $Source -Parent
if((Split-Path $Work -Parent) -ine $runRoot -or (Split-Path $Work -Leaf) -cne ('gi-'+$FixtureId)){throw 'GI work must be this source frame GUID child'}
$ownerPath=Join-Path $Work 'fixture-owner.json';$statePath=Join-Path $Work 'state.json'
if($Phase -eq 'initialize'){
 if(Test-Path -LiteralPath $Work){throw 'Existing GI work retained; use its exact receipt or a fresh source frame'}
 Assert-GiProtected $runRoot;[IO.Directory]::CreateDirectory($Work)|Out-Null;Assert-GiProtected $Work
 $owner=[ordered]@{protocol='roo-industries-gi-owner/v1';machine=$env:COMPUTERNAME;sid=$sid;fixtureId=$FixtureId;source=$Source;sourceManifestSha256=$SourceManifestSha256;work=$Work;directoryId=(Get-GiDirectoryId $Work)}
 [IO.File]::WriteAllText($ownerPath,($owner|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$OwnerSha256=(Get-FileHash -LiteralPath $ownerPath).Hash
 [IO.File]::WriteAllText($statePath,(@{protocol='roo-industries-gi/v1';fixtureId=$FixtureId;ownerSha256=$OwnerSha256;probes=@()}|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
Assert-GiProtected $Work
if(-not$OwnerSha256 -or -not(Test-Path -LiteralPath $ownerPath) -or (Get-FileHash -LiteralPath $ownerPath).Hash -ine $OwnerSha256){throw 'Missing or substituted GI ownership receipt; retained'}
$fixtureOwner=Get-Content -Raw -LiteralPath $ownerPath|ConvertFrom-Json;$fixtureOwnerHash=$OwnerSha256
if($fixtureOwner.protocol -cne 'roo-industries-gi-owner/v1' -or $fixtureOwner.machine -ine $env:COMPUTERNAME -or $fixtureOwner.sid -cne $sid -or $fixtureOwner.fixtureId -cne $FixtureId -or $fixtureOwner.source -ine $Source -or $fixtureOwner.sourceManifestSha256 -ine $SourceManifestSha256 -or $fixtureOwner.work -ine $Work -or $fixtureOwner.directoryId -cne (Get-GiDirectoryId $Work)){throw 'GI fixture identity differs; retained'}
if(-not(Test-Path -LiteralPath $statePath)){throw 'GI state receipt missing; retained'}
$state=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json
function Assert-GiState {
 if($state.protocol -cne 'roo-industries-gi/v1' -or $state.fixtureId -cne $fixtureOwner.fixtureId -or $state.ownerSha256 -ine $fixtureOwnerHash -or -not$state.PSObject.Properties['probes']){throw 'Missing or substituted GI state; retained'}
}
Assert-GiState
$app='C:\Program Files\Roo Industries\Optimization Suite'
$hostExe=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe'
$workerScript=Join-Path $app 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'
$local=[Environment]::GetFolderPath('LocalApplicationData')
if(Test-Path -LiteralPath $app){. (Join-Path $app 'backend\scripts\BrandCompatibility.Common.ps1');$dataRoot=Get-RooIndustriesLocalDataRoot;if($state.dataRoot -and $dataRoot -ine $state.dataRoot){throw 'Installed governor data root changed; retained'}}else{$dataRoot=$state.dataRoot}
$bootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$policyRoot=if($dataRoot){Join-Path $dataRoot 'process-rules'}else{$null}
$out=[ordered]@{phase=$Phase;atUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;fixtureId=$FixtureId;ownerSha256=$OwnerSha256;policyRoot=$policyRoot;checks=@()}
function Check([bool]$Condition,[string]$Message){$script:out.checks+=[ordered]@{passed=$Condition;check=$Message};if($Condition){"PASS $Message"}else{"FAIL $Message"}}
$OutputEncoding=[Text.UTF8Encoding]::new($false)
function Host-Call([string]$Action,[hashtable]$Extra=@{}){
 if($Action -notin 'policy-status','process-status'){Assert-GiProductScope}
 $request=@{schemaVersion=1;repoRoot=$app;policyRoot=$policyRoot;confirm=$true}
 foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
 $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$text=@(($request|ConvertTo-Json -Depth 32 -Compress)|& $hostExe $Action '-' 2>&1)|ForEach-Object {[string]$_};$exit=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
 $result=($text -join "`n")|ConvertFrom-Json
 if($exit -ne 0 -or $result.status -cne 'completed'){throw ($Action+': '+$result.error.message)}
 return $result.data
}
function Set-StateValue([string]$Name,$Value){if($state.PSObject.Properties[$Name]){$state.$Name=$Value}else{$state|Add-Member -NotePropertyName $Name -NotePropertyValue $Value}}
function Save-State{
 $tmp=$statePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp';[IO.File]::WriteAllText($tmp,($state|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))
 if(Test-Path -LiteralPath $statePath){[IO.File]::Replace($tmp,$statePath,$statePath+'.previous-'+[Guid]::NewGuid().ToString('N'))}else{[IO.File]::Move($tmp,$statePath)}
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesInstalledOracle {
    [StructLayout(LayoutKind.Sequential)] struct Throttling { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr process, int kind, out uint value, uint size);
    [DllImport("kernel32.dll", SetLastError=true, EntryPoint="GetProcessInformation")] static extern bool GetThrottling(IntPtr process, int kind, ref Throttling value, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessPriorityBoost(IntPtr process, out bool disabled);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process, uint[] ids, uint count, out uint required);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, out int value, int size, IntPtr length);
    [DllImport("gdi32.dll")] static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr process, out int value);
    public static uint Memory(IntPtr p) { uint v; if(!GetProcessInformation(p,0,out v,4)) throw new System.ComponentModel.Win32Exception(); return v; }
    public static string Qos(IntPtr p) { var t=new Throttling{Version=1}; if(!GetThrottling(p,4,ref t,12)) throw new System.ComponentModel.Win32Exception(); return (t.ControlMask&1)==0?"systemManaged":(t.StateMask&1)!=0?"eco":"high"; }
    public static bool BoostDisabled(IntPtr p) { bool d; if(!GetProcessPriorityBoost(p,out d)) throw new System.ComponentModel.Win32Exception(); return d; }
    public static string CpuSets(IntPtr p) { uint n; GetProcessDefaultCpuSets(p,null,0,out n); var ids=new uint[n]; if(n>0 && !GetProcessDefaultCpuSets(p,ids,n,out n)) throw new System.ComponentModel.Win32Exception(); return string.Join(",",ids); }
    public static int Io(IntPtr p) { int v; int s=NtQueryInformationProcess(p,33,out v,4,IntPtr.Zero); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
    public static int Gpu(IntPtr p) { int v; int s=D3DKMTGetProcessSchedulingPriorityClass(p,out v); if(s!=0) throw new InvalidOperationException("NTSTATUS "+s); return v; }
}
'@
function Read-Controls([Diagnostics.Process]$Process){
    $Process.Refresh()
    return [ordered]@{cpuPriority=[string]$Process.PriorityClass;affinity=('0x{0:X}' -f [int64]$Process.ProcessorAffinity);cpuSets=[RooIndustriesInstalledOracle]::CpuSets($Process.Handle)
        ioPriority=[RooIndustriesInstalledOracle]::Io($Process.Handle);gpuPriority=[RooIndustriesInstalledOracle]::Gpu($Process.Handle);memoryPriority=[RooIndustriesInstalledOracle]::Memory($Process.Handle)
        executionQoS=[RooIndustriesInstalledOracle]::Qos($Process.Handle);priorityBoostDisabled=[RooIndustriesInstalledOracle]::BoostDisabled($Process.Handle)}
}
function Same($Left,$Right){return (($Left|ConvertTo-Json -Compress) -eq ($Right|ConvertTo-Json -Compress))}
function Wait-Until([scriptblock]$Condition,[double]$Seconds){$clock=[Diagnostics.Stopwatch]::StartNew();while($true){$met=$false;try{$met=[bool](& $Condition)}catch{};if($met){break};if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null};Start-Sleep -Milliseconds 50};return [Math]::Round($clock.Elapsed.TotalSeconds,3)}
$probeExe=Join-Path $Work 'probe\RooIndustriesGovernorProbe.exe'
function Assert-GiProbeReceipt($Row){
 if(-not$Row -or -not$Row.identity -or -not$Row.file -or -not$Row.identity.pid -or -not$Row.identity.creationTimeFileTimeUtc -or -not$Row.identity.imagePath -or -not$Row.file.id -or -not$Row.file.hash -or $Row.file.path -ine $probeExe){throw 'Incomplete or foreign GI probe receipt; retained'}
 $file=Open-OwnedProbe $Row.file
 try{if($Row.identity.imagePath -ine [RooIndustriesValidationOwnership.Native]::Canonical($Row.file.path)){throw 'Probe receipt image differs; retained'}}finally{$file.Dispose()}
}
function Get-GiProbe($Row){
 Assert-GiProbeReceipt $Row
 $p=Get-Process -Id $Row.identity.pid -ErrorAction SilentlyContinue
 if(-not$p){return $null}
 try{if([RooIndustriesValidationOwnership.Native]::Created($p.Handle).ToString() -cne $Row.identity.creationTimeFileTimeUtc -or [RooIndustriesValidationOwnership.Native]::Image($p.Handle) -ine $Row.identity.imagePath){throw 'GI probe native identity differs; retained'};return $p}catch{$p.Dispose();throw}
}
function Get-Probe([int]$Id){$rows=@($state.probes|Where-Object {$_.identity.pid -eq $Id -and -not$_.stopped});if($rows.Count -ne 1){throw 'Probe has no unique retained receipt'};Get-GiProbe $rows[0]}
function Start-Probe {
 $file=Open-OwnedProbe $state.probeFile;$receipt=$null
 try{$info=[Diagnostics.ProcessStartInfo]::new($probeExe,'7200');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$p=[Diagnostics.Process]::Start($info);$receipt=New-OwnedProcess $p
 $row=[pscustomobject]@{identity=$receipt.Identity;file=$state.probeFile;original=$null;stopped=$false;bootUtc=$bootUtc};Set-StateValue 'probes' @(@($state.probes)+@($row));Save-State
 $row.original=Read-Controls $p;Save-State;return $p
 }catch{if($receipt){Stop-OwnedProcess $receipt};throw}finally{$file.Dispose()}
}
function Stop-GiProbes {
 foreach($row in @($state.probes|Where-Object {-not$_.stopped})){
  Assert-GiProbeReceipt $row
  if($bootUtc -and $row.bootUtc -and $row.bootUtc -cne $bootUtc){$row.stopped=$true;$row|Add-Member -NotePropertyName stopReason -NotePropertyValue 'observed reboot' -Force;Save-State;continue}
  Stop-OwnedProcessIdentity $row.identity
  $row.stopped=$true;Save-State
 }
}
function Assert-GiRule {
 if(-not$state.ruleId -or $state.ruleId -notmatch '^[0-9a-f]{32}$' -or -not$state.ruleSha256 -or -not$policyRoot){throw 'Missing rule receipt; retained'}
 $path=Join-Path $policyRoot ('rules\'+$state.ruleId+'.json')
 if(-not(Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $path).Hash -ine $state.ruleSha256){throw 'Owned rule changed; retained'}
 return $path
}
function Remove-GiRule {
 if($state.ruleDeleted){return}
 $path=Assert-GiRule
 Host-Call 'rule-delete' @{ruleId=$state.ruleId}|Out-Null
 if(Test-Path -LiteralPath $path){throw 'Owned rule deletion did not complete'}
 Set-StateValue 'ruleDeleted' $true;Save-State
}
function Tasks {
 if(-not$policyRoot){return @()}
 $hash=[Security.Cryptography.SHA256]::Create();try{$suffix=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid+'|'+$policyRoot.ToUpperInvariant())))).Replace('-','').Substring(0,20)}finally{$hash.Dispose()}
 $names=@(('RooIndustriesOptimizationSuite.ProcessRules.'+$suffix),('RooOptimizationSuite.ProcessRules.'+$suffix))
 $tasks=@(Get-ScheduledTask -TaskName $names -TaskPath '\' -ErrorAction SilentlyContinue)
 if($tasks.Count -gt 1){throw 'Both governor task identities exist; retained'}
 foreach($task in $tasks){
  $brand=if($task.TaskName -ceq $names[0]){'Roo Industries'}else{'Roo'}
  try{$principalSid=if($task.Principal.UserId -match '^S-1-') {[Security.Principal.SecurityIdentifier]::new($task.Principal.UserId).Value}else{[Security.Principal.NTAccount]::new($task.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value}}catch{throw 'Governor task principal cannot be identified; retained'}
  if($task.Description -cne ($brand+' process rules | '+$sid+' | '+$policyRoot) -or $principalSid -cne $sid -or $task.Principal.GroupId){throw 'Governor task scope differs; retained'}
  if(Test-Path -LiteralPath $hostExe){$expected=New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',(Join-Path $policyRoot 'worker-request.json')) (Split-Path $hostExe -Parent);if(@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $expected.Execute -or $task.Actions[0].Arguments -cne $expected.Arguments -or $task.Actions[0].WorkingDirectory -ine $expected.WorkingDirectory){throw 'Governor task action differs; retained'}}
 }
 return $tasks
}
function Assert-GiProductScope {
 if(-not(Test-Path -LiteralPath $app) -or -not$policyRoot -or $dataRoot -ine (Get-RooIndustriesLocalDataRoot)){throw 'Installed product root differs; retained'}
 [void](Tasks)
}
function Workers {
 if(-not(Test-Path -LiteralPath $hostExe)){return @()}
 $status=Host-Call 'policy-status'
 if($null -eq $status.hostRunning){throw 'Governor worker status identity unreadable'}
 if(-not$status.hostRunning){return @()}
 $identity=$status.state.host
 if(-not$identity -or -not$identity.creationTimeFileTimeUtc -or $identity.executablePath -ine $hostExe){throw 'Governor status host identity differs'}
 $p=Get-Process -Id $identity.processId -ErrorAction Stop
 try{if([RooIndustriesValidationOwnership.Native]::Created($p.Handle).ToString() -cne $identity.creationTimeFileTimeUtc -or [RooIndustriesValidationOwnership.Native]::Image($p.Handle) -ine [RooIndustriesValidationOwnership.Native]::Canonical($hostExe)){throw 'Governor native host identity differs'}}finally{$p.Dispose()}
 $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$identity.processId)
 if(-not$row -or $row.ExecutablePath -ine $hostExe){throw 'Governor process row contradicts native identity'}
 return @($row)
}
function Get-GiTaskWithoutEnabled([string]$Text) {
 $xml=[xml]$Text;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t',$xml.DocumentElement.NamespaceURI)
 $node=$xml.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns);if($node){[void]$node.ParentNode.RemoveChild($node)}
 $xml.OuterXml
}
function Set-GiTaskDisabled {
 $tasks=@(Tasks);if($tasks.Count -ne 1){throw 'Expected one exact governor task'}
 $before=Get-OwnedTaskReceipt $tasks[0].TaskName $tasks[0].TaskPath
 if($state.taskVisual){throw 'Earlier task fixture must be restored first'}
 Set-StateValue 'taskVisual' ([pscustomobject]@{before=$before;after=$null;expectedEnabled=$false});Save-State;Assert-OwnedTaskUnchanged $before
 $task=(Get-OwnedTaskFolder $before.path).GetTask($before.name);$task.Enabled=$false
 $after=Get-OwnedTaskReceipt $before.name $before.path
 if($after.sddl -cne $before.sddl -or (Get-GiTaskWithoutEnabled $after.xml) -cne (Get-GiTaskWithoutEnabled $before.xml) -or (Get-OwnedTaskFolder $after.path).GetTask($after.name).Enabled){throw 'Task changed beyond expected enabled state; retained'}
 $state.taskVisual.after=$after;Save-State
}
function Restore-GiTask {
 if(-not$state.taskVisual){return}
 $r=$state.taskVisual
 if(-not$r.after){throw 'Task fixture transition lacks final receipt; retained for recovery owner'}
 Assert-OwnedTaskUnchanged $r.after
 $before=[xml]$r.before.xml;$ns=[Xml.XmlNamespaceManager]::new($before.NameTable);$ns.AddNamespace('t',$before.DocumentElement.NamespaceURI)
 $enabled=$before.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns);$restoreEnabled=if($enabled){[Xml.XmlConvert]::ToBoolean($enabled.InnerText)}else{$true}
 $task=(Get-OwnedTaskFolder $r.after.path).GetTask($r.after.name);$task.Enabled=$restoreEnabled
 Assert-OwnedTaskUnchanged $r.before;Set-StateValue 'taskVisual' $null;Save-State
}
function Set-GiDamagedRule {
 Assert-GiProductScope
 $path=Join-Path $policyRoot ('rules\damaged-'+$FixtureId+'.json')
 if($state.damagedRule -or (Test-Path -LiteralPath $path)){throw 'Existing damaged-rule fixture retained'}
 $source=Join-Path $Work ('damaged-source-'+[Guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($source,'{ this is not a rule')
 $file=Copy-OwnedProbe $source $path
 try{Set-StateValue 'damagedRule' $file.Identity;Save-State}finally{$file.Dispose()}
}
function Remove-GiDamagedRule {
 if(-not$state.damagedRule){throw 'Missing damaged-rule receipt; retained'}
 if($state.damagedRule.path -ine (Join-Path $policyRoot ('rules\damaged-'+$FixtureId+'.json'))){throw 'Foreign damaged-rule path'}
 $file=Open-OwnedProbe $state.damagedRule;try{Remove-OwnedProbe $file}finally{$file.Dispose()}
 Set-StateValue 'damagedRule' $null;Save-State
}
function Invoke-GiCleanup {
    Assert-GiState
        if($state.taskVisual){Restore-GiTask}
        if($state.damagedRule){Remove-GiDamagedRule}
        if($state.ruleId -and -not$state.ruleDeleted){if(-not(Test-Path -LiteralPath $hostExe)){throw 'Installed rule-delete API is absent; retain rule for sealed recovery owner'};Remove-GiRule}
        Stop-GiProbes
        if($state.probeFile -and -not$state.probeFileRemoved){$file=Open-OwnedProbe $state.probeFile;try{Remove-OwnedProbe $file;Set-StateValue 'probeFileRemoved' $true;Save-State}finally{$file.Dispose()}}
        $out.left=[ordered]@{ownedProbes=@($state.probes|Where-Object {-not$_.stopped}).Count;ownedRuleRemaining=($state.ruleId -and -not$state.ruleDeleted);evidenceRetained=(Test-Path -LiteralPath $Work)}
        Check ($out.left.ownedProbes -eq 0 -and -not$out.left.ownedRuleRemaining -and $out.left.evidenceRetained) 'Fixture probes and only its GUID rule were cleaned; evidence retained'
}
function Describe-State {
    $result=[ordered]@{}
    $result.tasks=@(Tasks|ForEach-Object {[ordered]@{name=$_.TaskName;state=[string]$_.State;execute=$_.Actions[0].Execute;arguments=$_.Actions[0].Arguments;runLevel=[string]$_.Principal.RunLevel;triggers=@($_.Triggers|ForEach-Object {[ordered]@{kind=$_.CimClass.CimClassName;interval=$_.Repetition.Interval;duration=$_.Repetition.Duration}})}})
    Mark 'tasks'
    $result.workers=@(Workers|ForEach-Object {[ordered]@{pid=$_.ProcessId;name=$_.Name;path=$_.ExecutablePath;session=$_.SessionId;commandLine=$_.CommandLine}})
    Mark 'workers'
    $status=if(Test-Path -LiteralPath $hostExe){try{Host-Call 'policy-status'}catch{$_.Exception.Message}}else{'no host'}
    Mark 'status'
    $result.hostRunning=$status.hostRunning;$result.stateStatus=$status.state.status;$result.hostPid=$status.state.host.processId;$result.hostIdentity=$status.state.host
    $result.instances=@($status.state.instances|ForEach-Object {[ordered]@{pid=$_.process.processId;status=$_.status;journal=$_.journalPath}})
    Mark 'instances'
    $result.ruleFiles=@(if(Test-Path -LiteralPath (Join-Path $policyRoot 'rules')){Get-ChildItem -LiteralPath (Join-Path $policyRoot 'rules') -Filter *.json|ForEach-Object {[ordered]@{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}}})
    Mark 'rules'
    $result.governorJson=if(Test-Path -LiteralPath (Join-Path $policyRoot 'governor.json')){[IO.File]::ReadAllText((Join-Path $policyRoot 'governor.json'))}else{$null}
    $acl=if(Test-Path -LiteralPath $policyRoot){Get-Acl -LiteralPath $policyRoot}else{$null}
    $result.rootOwner=if($acl){$acl.Owner}else{$null};$result.rootProtected=if($acl){$acl.AreAccessRulesProtected}else{$null}
    $result.rootAccess=if($acl){@($acl.Access|ForEach-Object {''+$_.IdentityReference+':'+$_.FileSystemRights+':'+$_.AccessControlType+':'+$_.IsInherited})}else{$null}
    Mark 'acl'
    $result.appRunning=@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count
    $dll=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.dll'
    $result.hostFile=if(Test-Path -LiteralPath $dll){[ordered]@{lastWriteUtc=(Get-Item -LiteralPath $dll).LastWriteTimeUtc.ToString("o");createdUtc=(Get-Item -LiteralPath $dll).CreationTimeUtc.ToString("o");sha256=(Get-FileHash -LiteralPath $dll).Hash}}else{$null}
    Mark 'hostFile'
    $result.bootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    Mark 'boot'
    return $result
}
function Mark([string]$Name){if($env:ROO_INDUSTRIES_GOVERNOR_TRACE){[IO.File]::AppendAllText($env:ROO_INDUSTRIES_GOVERNOR_TRACE,$Name+' '+[DateTime]::Now.ToString('HH:mm:ss.fff')+"`r`n")}}
switch($Phase){
    'initialize' {Check $true 'Fresh protected fixture scope retained'}
    'disable-task' {Set-GiTaskDisabled;Check $true 'Exact governor task disabled with receipt'}
    'restore-task' {Restore-GiTask;Check $true 'Exact governor task restored byte for byte'}
    'damage-rule' {Set-GiDamagedRule;Check $true 'GUID damaged rule fixture retained'}
    'remove-damaged-rule' {Remove-GiDamagedRule;Check $true 'Exact damaged rule removed'}
    'resume' {Assert-GiProductScope;$text=@(& $workerScript -Action Resume -PolicyRoot $policyRoot -ConfirmApply) -join "`n";$result=$text|ConvertFrom-Json;Check ($result.status -ceq 'completed') 'Exact installed governor resumed'}
    'describe' {$out.state=Describe-State}
    'create-rule' {
        [IO.Directory]::CreateDirectory((Split-Path $probeExe -Parent))|Out-Null
        if($state.ruleId -or $state.probeFile -or (Test-Path -LiteralPath $probeExe)){throw 'Existing fixture resources retained'}
        $compiled=Join-Path $Work ('compile-'+[Guid]::NewGuid().ToString('N')+'.exe')
        Add-Type -TypeDefinition 'public static class RooIndustriesGovernorProbe { public static void Main(string[] args) { System.Threading.Thread.Sleep(System.TimeSpan.FromSeconds(args.Length > 0 ? int.Parse(args[0]) : 600)); } }' -OutputAssembly $compiled -OutputType ConsoleApplication
        $file=Copy-OwnedProbe $compiled $probeExe;try{Set-StateValue 'probeFile' $file.Identity;Save-State}finally{$file.Dispose()}
        $probe=Start-Probe
        Wait-Until {$null -ne (Read-Controls $probe)} 15|Out-Null
        $original=Read-Controls $probe
        $snapshot=Host-Call 'process-status' @{processId=$probe.Id}
        $topology=@($snapshot.topology|Sort-Object group,index)
        $sha=[Security.Cryptography.SHA256]::Create()
        $topologyHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((($topology|ForEach-Object {''+$_.group+':'+$_.index+':'+$_.core+':'+$_.cache+':'+$_.numa+':'+$_.efficiency}) -join ';'))))).Replace('-','')
        $cpu=@($topology|Where-Object {$_.available -and $_.group -eq 0})[1]
        $gpu=if($original.gpuPriority -eq 1){2}else{1}
        $cpuClass=if($original.cpuPriority -eq 'AboveNormal'){'High'}else{'AboveNormal'}
        $io=if($original.ioPriority -eq 2){1}else{2}
        $memory=if($original.memoryPriority -eq 3){4}else{3}
        $wanted=[ordered]@{cpuPriority=$cpuClass;affinity='0x3';cpuSets=[string]$cpu.id;ioPriority=$io;gpuPriority=$gpu;memoryPriority=$memory;executionQoS='eco';priorityBoostDisabled=$true}
        $rule=@{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value};name='Installed governor validation';enabled=$true
            matchMode='path';executablePath=$probeExe;executableHash=$null;affinityTopologyHash=$topologyHash
            controls=@{cpuPriority=$cpuClass;affinity=@{group=0;mask='0x3'};ioPriority=$io;gpuPriority=$gpu;memoryPriority=$memory;executionQoS=@{controlMask=1;stateMask=1};priorityBoost=$false}
            cpuSelection=@{kind='logical';topologyHash=$topologyHash;processors=@(@{group=0;index=[int]$cpu.index});oneThreadPerCore=$false}}
        Set-StateValue 'ruleId' $rule.ruleId;Set-StateValue 'dataRoot' $dataRoot;Save-State
        if(Test-Path -LiteralPath (Join-Path $policyRoot ('rules\'+$rule.ruleId+'.json'))){throw 'GUID rule already exists; retained'}
        Host-Call 'rule-save' @{rule=$rule}|Out-Null
        Set-StateValue 'ruleSha256' (Get-FileHash -LiteralPath (Join-Path $policyRoot ('rules\'+$rule.ruleId+'.json'))).Hash;Save-State
        $legacy=([IO.File]::ReadAllText($workerScript) -notmatch "'Sync'")
        $text=if($legacy){@(& $workerScript -Action Start -PolicyRoot $policyRoot -ConfirmApply) -join "`n"}else{@(& $workerScript -Action Sync -PolicyRoot $policyRoot -ConfirmApply) -join "`n"}
        $out.startResult=$text|ConvertFrom-Json
        $applied=Wait-Until {Same (Read-Controls $probe) $wanted} 10
        Set-StateValue 'probePid' $probe.Id;Set-StateValue 'original' $original;Set-StateValue 'wanted' $wanted;Set-StateValue 'ruleId' $rule.ruleId;Set-StateValue 'legacyVersion' $legacy
        Save-State
        $out.legacyVersion=$legacy;$out.appliedSeconds=$applied
        Check ($null -ne $applied) ('The '+$(if($legacy){'earlier'}else{'new'})+' installed version applies all 8 controls to the probe')
        $out.state=Describe-State
    }
    'verify-running' {
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check ($s.appRunning -eq 0) 'The desktop app is not running'
        Check ($s.hostRunning -eq $true -and @($s.workers).Count -eq 1) 'Exactly one governor worker is running and its identity is live'
        Check (@($s.workers).Count -eq 1 -and $s.workers[0].path -ieq $hostExe -and $hostExe.StartsWith('C:\Program Files\',[StringComparison]::OrdinalIgnoreCase)) 'The governor worker runs from the installed Optimizer.Host.exe under C:\Program Files'
        $workerRow=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$s.hostPid) -ErrorAction SilentlyContinue
        $launcherRow=if($workerRow){Get-CimInstance Win32_Process -Filter ('ProcessId='+$workerRow.ParentProcessId) -ErrorAction SilentlyContinue}
        $consoleRow=if($launcherRow){Get-CimInstance Win32_Process -Filter ('ProcessId='+$launcherRow.ParentProcessId) -ErrorAction SilentlyContinue}
        Check ($launcherRow -and $consoleRow -and $launcherRow.Name -eq 'cmd.exe' -and $launcherRow.CommandLine -match 'Start-RooIndustriesHelper\.cmd' -and $consoleRow.Name -eq 'conhost.exe' -and $consoleRow.CommandLine -match '--headless') 'The governor worker was started through the clean launcher under a hidden console host'
        . (Join-Path $app 'backend\scripts\BrandCompatibility.Common.ps1')
        Check (@($s.tasks).Count -eq 1 -and $s.tasks[0].state -ne 'Disabled' -and $s.tasks[0].execute -like '*\conhost.exe' -and $s.tasks[0].arguments -ceq (New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',(Join-Path $policyRoot 'worker-request.json')) (Split-Path $hostExe -Parent)).Arguments -and @($s.tasks[0].triggers|Where-Object {$_.kind -eq 'MSFT_TaskLogonTrigger' -and $_.interval -eq 'PT1M'}).Count -eq 1 -and @($s.tasks[0].triggers|Where-Object {$_.kind -eq 'MSFT_TaskTimeTrigger' -and $_.interval -eq 'PT1M'}).Count -eq 1) 'One enabled governor task runs the installed host headless with sign-in and one-minute triggers'
        Check ($s.rootOwner -eq 'BUILTIN\Administrators' -and $s.rootProtected -and @($s.rootAccess|Where-Object {$_ -match 'FullControl' -and $_ -notmatch '^(NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators):'}).Count -eq 0) 'The rules folder is owned by Administrators with no inherited or user write access'
        Check (@($s.ruleFiles).Count -ge 1 -and @($s.ruleFiles|Where-Object {$_.name -eq ($state.ruleId+'.json')}).Count -eq 1) 'The saved rule is still present'
        Check ($probe -and (Same (Read-Controls $probe) $state.wanted)) 'The long-running probe still has all 8 requested controls'
        $fresh=Start-Probe
        $seconds=Wait-Until {Same (Read-Controls $fresh) $state.wanted} 10
        $out.newProcessSeconds=$seconds
        Check ($null -ne $seconds) ('A newly started probe gets all 8 controls ('+$seconds+' s)')
        . (Join-Path $app 'backend\scripts\ProcessProfile.Common.ps1')
        $current=Get-RooIndustriesProcessControlState $fresh.Id
        $plan=Get-RooIndustriesApplicableProcessControlChanges @([pscustomobject]@{control='priorityClass';proposedValue='High';blocked=$false},[pscustomobject]@{control='ioPriority';proposedValue='VeryLow';blocked=$false}) $current
        $out.powerShellPlan=@($plan.skippedControls|ForEach-Object {[string]$_.control+": "+[string]$_.category+" "+[string]$_.reason})
        $thrown=$null;try {Invoke-RooIndustriesProcessControlChange $fresh ([pscustomobject]@{control='priorityClass';proposedValue='High'})} catch {$thrown=$_.Exception.Message}
        Check (@($plan.changes).Count -eq 0 -and @($plan.skippedControls|Where-Object {$_.category -eq 'managed' -and $_.reason -eq 'Managed by the governor'}).Count -eq 2 -and $thrown -eq 'Managed by the governor' -and (Same (Read-Controls $fresh) $state.wanted)) 'GameTune, Background limits and Background profile skip or refuse fields the governor owns and report Managed by the governor'
        $freshRow=@($state.probes|Where-Object {$_.identity.pid -eq $fresh.Id -and -not$_.stopped})[0];Stop-OwnedProcessIdentity $freshRow.identity;$freshRow.stopped=$true;Save-State;$fresh.Dispose()
    }
    'measure' {
        $s=Describe-State;$out.state=$s
        $worker=Get-Process -Id $s.hostPid -ErrorAction Stop
        $seconds=60
        $before=$worker.TotalProcessorTime;$started=Get-Date
        Start-Sleep -Seconds $seconds
        $worker.Refresh()
        $elapsed=((Get-Date)-$started).TotalSeconds
        $cpu=[Math]::Round((($worker.TotalProcessorTime-$before).TotalSeconds/$elapsed)*100,2)
        $out.measurement=[ordered]@{seconds=[Math]::Round($elapsed,1);cpuPercentOfOneCore=$cpu;workingSetMB=[Math]::Round($worker.WorkingSet64/1MB,1);privateMB=[Math]::Round($worker.PrivateMemorySize64/1MB,1);threads=$worker.Threads.Count;handles=$worker.HandleCount}
        Check ($cpu -lt 5 -and $worker.WorkingSet64 -lt 80MB) ('The idle governor stays light: '+$cpu+' percent of one core, '+[Math]::Round($worker.WorkingSet64/1MB,1)+' MB working set over '+[Math]::Round($elapsed)+' s')
    }
    'app-cycle' {
        $before=Describe-State
        $exe=Join-Path $app 'app\RooIndustries.OptimizationSuite.App.exe'
        if(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue){throw 'An app is already running; retained'}
        $process=Start-Process $exe -PassThru;$appReceipt=New-OwnedProcess $process
        try {
        Start-Sleep -Seconds 20
        $during=Describe-State
        $process.CloseMainWindow()|Out-Null
        if(-not $process.WaitForExit(20000)){Stop-OwnedProcess $appReceipt}
        Start-Sleep -Seconds 3
        $after=Describe-State
        $probe=Get-Probe $state.probePid
        $out.before=$before;$out.during=$during;$out.after=$after
        Check ($before.hostIdentity -and (Same $before.hostIdentity $during.hostIdentity) -and (Same $during.hostIdentity $after.hostIdentity) -and $after.hostRunning -eq $true) 'Opening and closing the app leaves the same governor running'
        Check ($probe -and (Same (Read-Controls $probe) $state.wanted)) 'The probe keeps its rules after the app closes'
        }finally{Stop-OwnedProcess $appReceipt;$process.Dispose()}
    }
    'new-paused-probe' {
        $probe=Start-Probe
        Set-StateValue 'probePid' $probe.Id;Save-State
        Check (Same (Read-Controls $probe) $state.original) 'A new probe after the paused reboot retains all 8 original controls'
    }
    'new-probe' {
        $probe=Start-Probe
        $seconds=Wait-Until {Same (Read-Controls $probe) $state.wanted} 10
        Set-StateValue 'probePid' $probe.Id;Save-State
        $out.appliedSeconds=$seconds
        Check ($null -ne $seconds) ('A new long-running probe gets all 8 controls ('+$seconds+' s)')
    }
    'pause' {
        Assert-GiProductScope
        $text=@(& $workerScript -Action Pause -PolicyRoot $policyRoot -ConfirmApply) -join "`n"
        $out.pauseResult=$text|ConvertFrom-Json
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check ($out.pauseResult.status -eq 'completed' -and $out.pauseResult.data.paused -and @($s.workers).Count -eq 0 -and @($s.tasks).Count -eq 1 -and $s.tasks[0].state -eq 'Disabled') 'Pause stops the installed governor and disables its task'
        Check ($probe -and (Same (Read-Controls $probe) $state.original)) 'Pause gives the probe its original 8 controls back'
    }
    'verify-paused' {
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check (@($s.tasks).Count -eq 1 -and $s.tasks[0].state -eq 'Disabled' -and @($s.workers).Count -eq 0 -and [string]$s.governorJson -match '"paused":\s*true') 'After setup the governor is still paused: task disabled, no worker, pause kept'
        Check ($probe -and (Same (Read-Controls $probe) $state.original)) 'After setup the paused rules are not applied to the probe'
        Start-Sleep -Seconds 75
        $later=Describe-State;$out.later=$later
        Check (@($later.workers).Count -eq 0 -and $later.tasks[0].state -eq 'Disabled' -and ($probe -and (Same (Read-Controls $probe) $state.original))) 'Seventy-five seconds later nothing restarted the paused governor'
    }
    'record' {
        $s=Describe-State;$out.state=$s
        Set-StateValue ('record_'+$Phase) $s;Set-StateValue 'recordedHostPid' $s.hostPid;Set-StateValue 'recordedHostIdentity' $s.hostIdentity;Set-StateValue 'recordedHostFile' $s.hostFile;Set-StateValue 'recordedRules' $s.ruleFiles;Save-State
        Check (Test-Path -LiteralPath $statePath -PathType Leaf) 'The governor replacement snapshot was written'
        $saved=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json
        Check ($null -ne $saved -and $saved.protocol -ceq 'roo-industries-gi/v1' -and $saved.fixtureId -ceq $FixtureId -and $saved.ownerSha256 -ieq $OwnerSha256) 'The written governor replacement snapshot parses and keeps its fixture identity'
        $required='record_record','recordedHostPid','recordedHostIdentity','recordedHostFile','recordedRules'
        $present=@($required|Where-Object {-not$saved.PSObject.Properties[$_]}).Count -eq 0
        $rules=@($saved.recordedRules)
        $validRules=$rules.Count -gt 0 -and @($rules|Where-Object {-not$_.name -or $_.sha256 -notmatch '^[0-9a-fA-F]{64}$'}).Count -eq 0
        Check ($present -and $saved.recordedHostPid -gt 0 -and $saved.recordedHostIdentity.processId -eq $saved.recordedHostPid -and $saved.recordedHostIdentity.creationTimeFileTimeUtc -match '^\d+$' -and $saved.recordedHostFile.createdUtc -and $validRules -and (Same $saved.recordedHostIdentity $s.hostIdentity) -and (Same $saved.recordedHostFile $s.hostFile) -and (Same $rules @($s.ruleFiles))) 'The parsed snapshot retains the host identity, host creation time and rule hashes needed to verify replacement'
    }
    'verify-replaced' {
        $s=Describe-State;$out.state=$s
        Check ($s.hostRunning -eq $true -and $state.recordedHostIdentity -and $s.hostIdentity -and $s.hostIdentity.creationTimeFileTimeUtc -cne $state.recordedHostIdentity.creationTimeFileTimeUtc) 'A new governor worker runs after setup'
        Check ($s.hostFile.createdUtc -ne $state.recordedHostFile.createdUtc) 'Setup deleted and replaced the host files'
        Check ((Same @($s.ruleFiles|Sort-Object {$_.name}) @($state.recordedRules|Sort-Object {$_.name}))) 'Setup kept the saved rules byte for byte'
    }
    'verify-removed' {
        $probe=Get-Probe $state.probePid
        $s=Describe-State;$out.state=$s
        Check (@($s.tasks).Count -eq 0) 'Uninstall removed every governor task'
        Check (@($s.workers).Count -eq 0) 'No governor process is left'
        Check (-not (Test-Path -LiteralPath $app)) 'The app folder is gone'
        Check (@($s.ruleFiles|Where-Object {$_.name -eq ($state.ruleId+'.json')}).Count -eq 1) 'Uninstall kept the saved rules'
        $keptMarkers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
        Check (Test-Path -LiteralPath (Join-Path $dataRoot 'operations') -PathType Container) 'Uninstall kept the operations folder with its journals'
        Check ($null -ne $keptMarkers -and $null -ne $keptMarkers.GetValue($dataRoot.ToUpperInvariant())) 'Uninstall kept the data folder protection marker'
        if($probe){Check (Same (Read-Controls $probe) $state.original) 'Uninstall gave the running probe its original 8 controls back'}else{Check $false 'The long-running probe is still alive to verify restoration'}
    }
    'cleanup' {Invoke-GiCleanup}
    default {throw ('Unknown GI phase: '+$Phase)}
}
$json=$out|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText((Join-Path $Work ('phase-'+$Phase+'-'+[Guid]::NewGuid().ToString('N')+'.json')),$json,[Text.UTF8Encoding]::new($false))
$json
if(@($out.checks|Where-Object {-not$_.passed}).Count){exit 1}
