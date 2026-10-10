param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')
$directory=Join-Path $OutRoot 'gpu-release';[IO.Directory]::CreateDirectory($directory)|Out-Null
$owned=[Collections.Generic.List[object]]::new()
function Save($name,$value){ConvertTo-Json -InputObject $value -Depth 55|Set-Content (Join-Path $directory ($name+'.json')) -Encoding UTF8}
function Backend($name,$fields,$label){$raw=& (Join-Path $Source ('backend\scripts\'+$name+'.ps1')) @fields;$result=$raw|ConvertFrom-Json;Save $label $result;if(@($result.errors|Where-Object blocking).Count){throw ($label+' failed: '+($result.errors|ConvertTo-Json -Depth 10 -Compress))};$result}
try {
 $exe=Join-Path $directory 'RooFixtureUpdaterGpu.exe'
 & "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /out:$exe (Join-Path $Source 'tools\validation\Background\LauncherFixture.cs');if($LASTEXITCODE){throw 'GPU fixture compile failed'}
 $signal=Join-Path $directory 'gpu.signal';$child=Join-Path $directory 'RooFixtureChild.exe';Copy-Item "$env:SystemRoot\System32\PING.EXE" $child
 $process=Start-Process $exe -ArgumentList ('"'+$signal+'" "'+$child+'" --gpu') -WindowStyle Hidden -PassThru;$owned.Add((New-OwnedProcess $process))
 $until=[DateTime]::UtcNow.AddSeconds(20);while(-not(Test-Path ($signal+'.gpu-ready')) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 100};if(-not(Test-Path ($signal+'.gpu-ready'))){throw 'GPU device not ready'}
 $process.PriorityClass='Normal';[RooBackgroundOracle]::SetIo($process,2);[RooBackgroundOracle]::SetMemory($process,5)
 $original=[RooBackgroundOracle]::Gpu($process);Save 'before' @{pid=$process.Id;gpu=$original}
 if($original -ne 2){throw 'Expected Normal GPU original'}
 $profile=Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json')|ConvertFrom-Json
 $profile.profileId='roo20-gpu-release';$profile.protectedCatalogPath=Join-Path $Source 'backend\profiles\protected-processes.json'
 $profile.governor.candidateSelectors=@([pscustomobject]@{ruleId='fixture';enabled=$true;match=@{processNames=@('RooFixtureUpdaterGpu.exe')}})
 $t=$profile.governor.thresholds;$t.totalCpuPressureThresholdPercent=0;$t.perProcessCpuThresholdPercent=0;$t.timeOverThresholdSeconds=0;$t.minimumRestraintSeconds=0;$t.restoreCpuThresholdPercent=100;$t.cooldownAfterRestoreSeconds=0
 $profile.governor.restraint|Add-Member -NotePropertyName gpuPriority -NotePropertyValue 'BelowNormal' -Force
 Save 'profile' $profile;$profilePath=Join-Path $directory 'profile.json'
 $apply=Backend 'Start-ProcessGovernorSession' @{ProfilePath=$profilePath;StateRoot=(Join-Path $directory 'state');ConfirmApply=$true;MaxDurationSeconds=25;PollIntervalSeconds=1;SampleIntervalMilliseconds=250} 'apply'
 $restored=@($apply.result.restoredItems);$changed=@($apply.result.changedItems);if($restored.Count -lt 1 -or $changed.Count -lt 2){throw 'Fixture did not release and re-restrain in the same session'}
 foreach($r in $restored){if($r.restoredGpuPriority -ne 'Normal'){throw 'Released GPU did not return to Normal'}}
 $backup=Get-Content -Raw $apply.backup.location|ConvertFrom-Json;Save 'backup' $backup
 foreach($snapshot in $backup.snapshots){if($snapshot.originalGpuPriority -ne 'Normal'){throw 'Re-restraint captured a lowered GPU original'}}
 $stop=Backend 'Stop-ProcessGovernorSession' @{BackupPath=$apply.backup.location;ConfirmApply=$true} 'stop'
 $actual=[RooBackgroundOracle]::Gpu($process);if($actual -ne $original){throw 'Final GPU restore differs from independent original'}
 . (Join-Path $Source 'backend\scripts\ProcessPolicy.Common.ps1')
 $policy=Get-Content -Raw (Join-Path $Source 'backend\profiles\persistent-policy.profile.json')|ConvertFrom-Json
 $policy.policy.rules=@([pscustomobject]@{ruleId='gpu-only';enabled=$true;match=@{processNames=@('RooFixtureUpdaterGpu.exe')};controls=@{gpuPriority='BelowNormal'}})
 Save 'policy-profile' $policy;$policy=Get-Content -Raw (Join-Path $directory 'policy-profile.json')|ConvertFrom-Json
 $row=[pscustomobject]@{pid=$process.Id;name='RooFixtureUpdaterGpu.exe';category='backgroundApp';priorityClass='Normal';executablePath=$exe}
 $catalog=Get-Content -Raw (Join-Path $Source 'backend\profiles\protected-processes.json')|ConvertFrom-Json
 $entry=New-RooIndustriesProcessPolicyPreviewEntry $row $policy $catalog;Save 'policy-preview' $entry
 if($entry.currentGpuPriority -ne 'Normal' -or @($entry.controlChanges|Where-Object {$_.control -eq 'gpuPriority' -and $_.currentValue -eq 'Normal' -and $_.proposedValue -eq 'BelowNormal'}).Count -ne 1){throw 'Persistent-policy GPU preview did not read requested GPU control'}
 Save 'done' @{status='passed';releases=$restored.Count;restraints=$changed.Count;originalGpu=$original;restoredGpu=$actual}
}catch{Save 'failure' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace};throw}
finally{foreach($r in $owned){Stop-OwnedProcess $r};Save 'cleanup' @($owned|ForEach-Object {@{pid=$_.Identity.pid;exited=$_.Process.HasExited}})}
