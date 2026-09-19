$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-recovery-'+[Guid]::NewGuid().ToString('N'))
$probe=$null
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $worker=Join-Path $root 'RooIndustriesGovernorRecoveryProbe.exe'
    $build=(& (Join-Path $PSScriptRoot 'Build-NativeProcessGovernor.ps1') -OutputPath $worker -Force)|ConvertFrom-Json
    if($build.status -ne 'built'){throw 'Governor fixture did not build.'}
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($worker))
    $type=$assembly.GetType('RooIndustriesProcessGovernor')
    $flags=[Reflection.BindingFlags]'NonPublic,Static'
    $snapshotMethod=$type.GetMethod('SnapshotProcess',$flags)
    $buildChanges=$type.GetMethod('BuildControlChanges',$flags)
    $apply=$type.GetMethod('ApplyChanges',$flags)
    $restore=$type.GetMethod('RestoreSnapshot',$flags)
    $writeBackup=$type.GetMethod('WriteBackup',$flags)
    $restraint=[RooIndustriesProcessGovernor+GovernorRestraint]::new()
    $restraint.priorityClass='BelowNormal';$restraint.affinityMask=1;$restraint.ioPriority='Low';$restraint.gpuPriority='BelowNormal'
    $unknown=[RooIndustriesProcessGovernor+ProcessSnapshot]::new()
    $changes=$buildChanges.Invoke($null,@($unknown,$restraint))
    Assert ($changes.Count -eq 4 -and @($changes|Where-Object {-not $_['blocked']}).Count -eq 0) 'Unknown originals cannot become executable native governor changes'
    $probe=Start-Process -FilePath $worker -ArgumentList '--probe sleep 0 120' -WindowStyle Hidden -PassThru
    $before=$snapshotMethod.Invoke($null,@($probe.PSObject.BaseObject))
    $priorityBefore=$probe.PriorityClass
    $priority=if($priorityBefore -eq [Diagnostics.ProcessPriorityClass]::BelowNormal){'Normal'}else{'BelowNormal'}
    $affinityBefore=$probe.ProcessorAffinity.ToInt64()
    $affinityTarget=$affinityBefore -band (-$affinityBefore)
    if($affinityTarget -eq $affinityBefore){throw 'The recovery fixture needs two available logical processors for its independent affinity writer.'}
    $changes=[Collections.Generic.List[Collections.Generic.Dictionary[string,object]]]::new()
    foreach($values in @(
        @{control='priorityClass';currentValue=$before.priorityClass;proposedValue=$priority;blocked=$false},
        @{control='ioPriority';currentValue=$before.ioPriority;proposedValue='InjectedUnsupportedPriority';blocked=$false},
        @{control='affinityMask';currentValue=$affinityBefore;proposedValue=$affinityTarget;blocked=$false}
    )){
        $change=[Collections.Generic.Dictionary[string,object]]::new()
        foreach($key in $values.Keys){$change.Add($key,$values[$key])}
        $changes.Add($change)
    }
    $backup=[RooIndustriesProcessGovernor+BackupSnapshot]::FromProcess($before,$probe,$changes,'recovery-fixture','fixture-session')
    $snapshots=[Collections.Generic.List[RooIndustriesProcessGovernor+BackupSnapshot]]::new();$snapshots.Add($backup)
    $path=Join-Path $root 'backup.json'
    $proof=[pscustomobject]@{beforeWrite=$false;afterWrite=$false}
    [Action]$checkpoint={
        $writeBackup.Invoke($null,@($path.PSObject.BaseObject,'recovery-fixture','fixture-session',[datetime]::UtcNow,$snapshots.PSObject.BaseObject))|Out-Null
        $saved=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).snapshots[0]
        $probe.Refresh()
        if($saved.appliedControls[0].state -eq 'applyIntent' -and $probe.PriorityClass -eq $priorityBefore){$proof.beforeWrite=$true}
        if($saved.appliedControls[0].state -eq 'applied' -and $probe.PriorityClass.ToString() -eq $priority){$proof.afterWrite=$true}
    }
    $failed=$false
    try {$apply.Invoke($null,@($probe.PSObject.BaseObject,$backup.appliedControls,$checkpoint))}
    catch {if($_.Exception.GetBaseException().Message -notlike '*outside the allow-list*'){throw};$failed=$true}
    Assert ($failed -and $proof.beforeWrite -and $proof.afterWrite) 'A later setter failure retains durable before-write intent and verified earlier changes'
    Assert ($backup.appliedControls[2]['state'] -eq 'pending') 'A never-attempted field remains distinguishable from an applied field'
    $probe.ProcessorAffinity=[IntPtr]::new($affinityTarget)
    $result=$restore.Invoke($null,@($backup,0))
    $probe.Refresh()
    Assert ($probe.PriorityClass -eq $priorityBefore -and $probe.ProcessorAffinity.ToInt64() -eq $affinityTarget) 'Recovery restores an earlier applied field and preserves a foreign change to an unattempted field'
} finally {
    if($probe){if(-not $probe.HasExited){$probe.Kill()};if(-not $probe.WaitForExit(10000)){throw 'Governor fixture did not exit.'};$probe.Dispose()}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Native governor recovery validation leaves no process, backup or temporary binary'
