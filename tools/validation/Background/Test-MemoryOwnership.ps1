param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'memory-ownership';[IO.Directory]::CreateDirectory($directory)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$install='C:\Program Files\Roo Industries\Optimization Suite';$hostExe=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
$ruleId=[Guid]::NewGuid().ToString('N');$saved=$false;$owned=$null;$process=$null
function Save([string]$name,$value){[IO.File]::WriteAllText((Join-Path $directory $name),($value|ConvertTo-Json -Depth 40),$utf8)}
function HostCall([string]$action,[hashtable]$request){
 $request.schemaVersion=1;$request.repoRoot=$install;$request.confirm=$true
 $s=[Diagnostics.ProcessStartInfo]::new($hostExe,$action+' -');$s.UseShellExecute=$false;$s.CreateNoWindow=$true;$s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true
 foreach($name in @($s.EnvironmentVariables.Keys)){if($name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'){$s.EnvironmentVariables.Remove($name)}}
 $p=[Diagnostics.Process]::Start($s);$receipt=New-OwnedProcess $p
 try{$p.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 30 -Compress));$p.StandardInput.Close();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not$p.WaitForExit(60000)){throw 'Host timed out'};$response=$out.Result|ConvertFrom-Json;if($p.ExitCode -ne 0){throw ($err.Result+' '+$out.Result)};return $response}finally{Stop-OwnedProcess $receipt;$p.Dispose()}
}
try {
 $path=Join-Path $directory 'RooFixtureOwnedUpdater.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $path;$process=Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru;$owned=New-OwnedProcess $process
 $process.PriorityClass='Normal';[RooIndustriesBackgroundOracle]::SetIo($process,2);[RooIndustriesBackgroundOracle]::SetMemory($process,1)
 $owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
 $rule=@{schemaVersion=1;ruleId=$ruleId;owner=$owner;name='Memory ownership fixture';enabled=$true;matchMode='path';executablePath=$path;executableHash=$null;cpuSelection=$null;controls=@{memoryPriority=1}}
 Save 'rule-save.json' (HostCall 'rule-save' @{policyRoot=$root;rule=$rule});$saved=$true
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\game-session.profile.json')|ConvertFrom-Json
 $profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json';$profile.foregroundGame.processNames=@();$profile.targetGames=@();$profile.rules=@(@{ruleId='owned-background';enabled=$true;match=@{processNames=@('RooFixtureOwnedUpdater.exe')};action=@{actionType='setPriority';priorityClass='BelowNormal'}})
 $profilePath=Join-Path $directory 'profile.json';[IO.File]::WriteAllText($profilePath,($profile|ConvertTo-Json -Depth 30),$utf8)
 $before=@{cpu=[string]$process.PriorityClass;memory=[RooIndustriesBackgroundOracle]::Memory($process);affinity=$process.ProcessorAffinity.ToInt64()};Save 'before.json' $before
 $result=& (Join-Path $Source 'backend\scripts\Apply-ProcessProfile.ps1') -ProfilePath $profilePath -StateRoot (Join-Path $directory 'state') -ConfirmApply|ConvertFrom-Json;Save 'lower.json' $result
 $process.Refresh();Save 'after-lower.json' @{cpu=[string]$process.PriorityClass;memory=[RooIndustriesBackgroundOracle]::Memory($process)}
 if($process.PriorityClass -ne 'BelowNormal' -or [RooIndustriesBackgroundOracle]::Memory($process) -ne 1){throw 'Per-field ownership did not skip only memory'}
 if(-not@($result.result.skippedItems|Where-Object {$_.reason -match 'Managed by the governor'}).Count){throw 'Memory ownership skip was not reported'}
 $restore=& (Join-Path $Source 'backend\scripts\Restore-ProcessProfileBackup.ps1') -BackupPath $result.backup.location -ConfirmApply|ConvertFrom-Json;Save 'restore.json' $restore
 $placement=& (Join-Path $Source 'backend\scripts\Apply-ProcessProfile.ps1') -ProfilePath $profilePath -Preset placement -StateRoot (Join-Path $directory 'state') -ConfirmApply|ConvertFrom-Json;Save 'placement.json' $placement
 $process.Refresh();if($process.PriorityClass -ne 'Normal' -or [RooIndustriesBackgroundOracle]::Memory($process) -ne 1 -or $process.ProcessorAffinity.ToInt64() -ne $before.affinity){throw 'Placement changed a saved-rule-owned process'}
 Save 'done.json' @{status='passed';ruleId=$ruleId;machine=$env:COMPUTERNAME}
} finally {
 if($saved){Save 'rule-delete.json' (HostCall 'rule-delete' @{policyRoot=$root;ruleId=$ruleId})}
 if($owned){Stop-OwnedProcess $owned}
 Save 'cleanup.json' @{fixtureStopped=if($process){$process.HasExited}else{$true};ruleRetained=(Test-Path (Join-Path $root ('rules\'+$ruleId+'.json')))}
}
