$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Host "PASS $Message"}
function Read-Result($Lines){return ($Lines -join [Environment]::NewLine)|ConvertFrom-Json}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-bulk-uninstall-'+[guid]::NewGuid().ToString('N'))
$planScript=Join-Path $PSScriptRoot 'New-BulkUninstallPlan.ps1'
$runScript=Join-Path $PSScriptRoot 'Invoke-BulkUninstall.ps1'
$liveFixtures=New-Object System.Collections.Generic.List[object]
$msiCode=[guid]::NewGuid().ToString('B').ToUpperInvariant()
$msiKeyPath='Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$msiCode
$msiAppId='registry:roo-industries-msi-fixture-'+$msiCode
$msiClaim=Get-RooIndustriesBulkClaimPath ([pscustomobject]@{appId=$msiAppId})
function New-Case([string]$Name,[string]$FirstMode='remove',[int]$FirstExit=0) {
    $directory=Join-Path $root $Name;[IO.Directory]::CreateDirectory($directory)|Out-Null
    $exe=Join-Path $directory 'Roo Industries Bulk Removal Fixture.exe';Copy-Item -LiteralPath $script:fixtureExe -Destination $exe
    $journalPath=Join-Path $directory 'journal.json';$counter=Join-Path $directory 'launch count.txt'
    $apps=@();$markers=@()
    foreach($i in 1..2){
        $marker=Join-Path $directory "installed $i.txt";[IO.File]::WriteAllText($marker,'installed');$markers+=@($marker)
        $mode=if($i -eq 1){$FirstMode}else{'remove'};$code=if($i -eq 1){$FirstExit}else{0}
        $arguments=@($marker,$counter,[string]$code,$mode,($journalPath+'.cancel'),'quoted "value" with trailing\')
        $install=Join-Path $directory ('app-'+$i);[IO.Directory]::CreateDirectory($install)|Out-Null;[IO.File]::WriteAllText((Join-Path $install 'settings.txt'),'original settings')
        $apps+=@([pscustomobject]@{appId="fixture:$Name-$i";displayName="Roo Industries disposable app $i";publisher='Roo Industries Fixture';sourceType='registry';
            sourceIdentity=@{kind='fixture';presencePath=$marker};installLocation=$install;risk='low';protected=$false;categories=@('application');
            uninstallString=((ConvertTo-RooIndustriesWindowsArgument $exe)+' '+(Join-RooIndustriesWindowsArguments $arguments))})
    }
    $inventory=Join-Path $directory 'inventory.json';Write-RooIndustriesOperationJson @{schemaVersion=1;apps=$apps} $inventory
    $planPath=Join-Path $directory 'plan.json'
    $preview=Read-Result (& $planScript -AppId @($apps.appId) -InventoryPath $inventory -FixtureRoot $directory -OutputPath $planPath)
    if($preview.status -ne 'preview'){throw ($preview|ConvertTo-Json -Depth 12)}
    return @{directory=$directory;markers=$markers;counter=$counter;plan=$preview.data;planPath=$planPath;exe=$exe;
        args=@{Action='Apply';InputPath=$planPath;ReviewSha256=(Get-FileHash $planPath).Hash;JournalPath=$journalPath;AllowFixtureExecution=$true;ConfirmApply=$true;ManualReviewApproved=$true}}
}
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $script:fixtureExe=Join-Path $root 'RooIndustriesBulkFixture.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class RooIndustriesBulkFixture {
    public static int Main(string[] args) {
        Console.WriteLine("A vendor console message must not corrupt the JSON response.");
        Console.Error.WriteLine("Vendor diagnostic output.");
        if(args.Length!=6||args[5]!="quoted \"value\" with trailing\\") return 87;
        File.AppendAllText(args[1]+".command-lines",Environment.CommandLine+Environment.NewLine);
        if(args[3]=="verbose") Console.Write(new String('x',200000));
        File.AppendAllText(args[1],args[0]+Environment.NewLine);
        if(args[3]=="wait") Thread.Sleep(15000);
        if(args[3]=="cancel") File.WriteAllText(args[4],"stop after this entry");
        if(args[3]!="keep") File.Delete(args[0]);
        return Int32.Parse(args[2]);
    }
}
'@ -OutputAssembly $script:fixtureExe -OutputType ConsoleApplication
    $msiDirectory=Join-Path $root 'msi';[IO.Directory]::CreateDirectory($msiDirectory)|Out-Null
    $msiKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($msiKeyPath)
    try {$msiKey.SetValue('DisplayName','Roo Industries MSI command fixture');$msiKey.SetValue('UninstallString',"MsiExec.exe /X$msiCode");$msiKey.SetValue('WindowsInstaller',1,[Microsoft.Win32.RegistryValueKind]::DWord)}
    finally {$msiKey.Dispose()}
    $msiApp=[pscustomobject]@{appId=$msiAppId;displayName='Roo Industries MSI command fixture';sourceType='msi';packageId=$msiCode;risk='low';protected=$false;categories=@('application');
        sourceIdentity=@{kind='registry';hive='CurrentUser';view='Registry64';keyPath=$msiKeyPath;userSid=(Get-RooIndustriesOperationOwner).userSid};uninstallString="MsiExec.exe /X$msiCode"}
    $msiInventory=Join-Path $msiDirectory 'inventory.json';Write-RooIndustriesOperationJson @{schemaVersion=1;apps=@($msiApp)} $msiInventory
    $msiPlanPath=Join-Path $msiDirectory 'plan.json'
    $msiPlan=Read-Result (& $planScript -AppId @($msiAppId) -InventoryPath $msiInventory -Quiet -OutputPath $msiPlanPath)
    $msiexec=Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
    Assert ($msiPlan.status -eq 'preview' -and $msiPlan.data.entries[0].commandLine -ceq ('"'+$msiexec+'" /x '+$msiCode+' /qn /norestart')) 'MSI removal is reviewed as one unquoted msiexec command line built from the ProductCode'
    $msiJournal=Join-Path $msiDirectory 'journal.json'
    $msiRun=Read-Result (& $runScript -Action Apply -InputPath $msiPlanPath -ReviewSha256 (Get-FileHash $msiPlanPath).Hash -JournalPath $msiJournal -TimeoutSeconds 30 -ConfirmApply -ManualReviewApproved)
    Assert ($null -ne $msiRun.data.entries[0].outcome -and $msiRun.data.entries[0].outcome.exitCode -eq 1605) 'msiexec parses the executed MSI command and reports the unknown ProductCode instead of showing its usage window'
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($msiKeyPath)
    $msiReconciled=Read-Result (& $runScript -Action Reconcile -JournalPath $msiJournal -ConfirmApply)
    Assert ($msiReconciled.data.entries[0].state -eq 'removed' -and -not(Test-Path -LiteralPath $msiClaim)) 'The MSI fixture queue reconciles after its registration is removed and releases its removal claim'
    $case=New-Case 'success';$a=$case.args
    Assert ((Test-Path $case.markers[0]) -and -not(Test-Path $case.counter) -and -not(Test-Path $a.JournalPath)) 'Bulk preview executes nothing and creates no journal'
    $withoutApproval=@{};foreach($key in $a.Keys){$withoutApproval[$key]=$a[$key]};$withoutApproval.ConfirmApply=$false
    $preview=Read-Result (& $runScript @withoutApproval)
    Assert ($preview.status -eq 'preview' -and -not(Test-Path $a.JournalPath)) 'Apply without confirmation remains a preview'
    $overwrite=Read-Result (& $runScript @a -OutputPath $case.planPath)
    Assert ($overwrite.status -eq 'failed' -and (Get-FileHash $case.planPath).Hash -eq $a.ReviewSha256 -and -not(Test-Path $case.counter)) 'An output collision cannot destroy the reviewed bulk plan or launch a command'
    foreach($control in '.cancel','.lock'){
        $controlOutput=Read-Result (& $runScript @a -OutputPath ($a.JournalPath+$control))
        Assert ($controlOutput.status -eq 'failed' -and $controlOutput.errors[0].message -eq 'OutputPath cannot replace queue control files.' -and -not(Test-Path ($a.JournalPath+$control)) -and -not(Test-Path $case.counter)) "An output path cannot replace the queue $control file"
    }
    $lease=Lock-RooIndustriesOperation $a.JournalPath
    try{$busy=Read-Result (& $runScript @a)}finally{$lease.Dispose()}
    Assert ($busy.status -eq 'failed' -and -not(Test-Path $case.counter)) 'Concurrent queue invocation cannot dispatch through an occupied journal lease'
    $run=Read-Result (& $runScript @a)
    if($run.status -ne 'cleanup-review-required'){Write-Host ($run|ConvertTo-Json -Depth 20)}
    Assert ($run.status -eq 'cleanup-review-required' -and @($run.data.entries|Where-Object {$_.registrationAbsent}).Count -eq 2 -and (Get-Content $case.counter).Count -eq 2) 'Two exact harmless removal commands run sequentially and registration absence is verified'
    Assert ($run.data.entries[0].output.stdout -like '*vendor console message*' -and $run.data.entries[0].output.stderr -like '*Vendor diagnostic*') 'Vendor stdout and stderr are captured inside the response without contaminating its JSON'
    $again=Read-Result (& $runScript @a)
    Assert ($again.status -eq 'cleanup-review-required' -and (Get-Content $case.counter).Count -eq 2) 'Replaying a completed bulk queue does not run either remover again'
    $commandLines=@(Get-Content -LiteralPath ($case.counter+'.command-lines'))
    Assert ($commandLines.Count -eq 2 -and $commandLines[0] -ceq $case.plan.entries[0].commandLine -and $commandLines[1] -ceq $case.plan.entries[1].commandLine) 'Each remover receives exactly the reviewed command line, including spaces, quotes and a trailing backslash'
    $case=New-Case 'cancel' 'cancel';$a=$case.args
    $canceled=Read-Result (& $runScript @a)
    Assert ($canceled.status -eq 'canceled' -and -not(Test-Path $case.markers[0]) -and (Test-Path $case.markers[1]) -and $canceled.data.entries[1].attemptCount -eq 0) 'Cancellation between entries leaves untouched applications installed'
    $resume=Read-Result (& $runScript @a)
    Assert ($resume.status -eq 'cleanup-review-required' -and (Get-Content $case.counter).Count -eq 2) 'A confirmed resume executes only the untouched remainder'
    $case=New-Case 'contradictory-success' 'keep';$a=$case.args
    $uncertain=Read-Result (& $runScript @a)
    Assert ($uncertain.status -eq 'needs-reconciliation' -and (Test-Path $case.markers[0]) -and $uncertain.data.entries[1].attemptCount -eq 0) 'Exit zero with the exact registration still present does not prove removal'
    $again=Read-Result (& $runScript @a)
    Assert ($again.status -eq 'needs-reconciliation' -and @(Get-Content $case.counter).Count -eq 1) 'An uncertain earlier invocation is never retried automatically'
    Remove-Item -LiteralPath $case.markers[0]
    $reconciled=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($reconciled.status -eq 'ready' -and $reconciled.data.entries[0].registrationAbsent -and $reconciled.data.entries[1].attemptCount -eq 0) 'Reconciliation uses observed registration absence without dispatching another command'
    $resumed=Read-Result (& $runScript @a)
    Assert ($resumed.status -eq 'cleanup-review-required' -and @(Get-Content $case.counter).Count -eq 2) 'Reconciled completion permits only previously untouched queue entries'
    $case=New-Case 'generic-msi-code' 'remove' 3010;$a=$case.args
    $notMsi=Read-Result (& $runScript @a)
    Assert ($notMsi.status -eq 'needs-reconciliation' -and -not $notMsi.data.entries[0].outcome.success -and $notMsi.data.entries[1].attemptCount -eq 0) 'An arbitrary executable returning 3010 does not inherit MSI success semantics'
    $case=New-Case 'changed-executable';$a=$case.args
    [IO.File]::AppendAllText($case.exe,'changed after preview')
    $stale=Read-Result (& $runScript @a)
    Assert ($stale.status -eq 'needs-reconciliation' -and $stale.data.entries[0].attemptCount -eq 0 -and -not(Test-Path $case.counter)) 'A replaced executable is rejected before any dispatch intent or process launch'
    $case=New-Case 'timeout' 'wait';$a=$case.args;$a.TimeoutSeconds=1
    $timed=Read-Result (& $runScript @a)
    $invocation=$timed.data.entries[0].invocation
    $process=[Diagnostics.Process]::GetProcessById([int]$invocation.processId);$liveFixtures.Add($process)|Out-Null
    Assert ($timed.status -eq 'needs-reconciliation' -and -not $process.HasExited -and $timed.data.entries[1].attemptCount -eq 0) 'Observation timeout leaves the remover intact and prevents the next entry from starting'
    $check=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($check.status -eq 'needs-reconciliation' -and (Test-Path $case.markers[0])) 'A still-running exact process cannot be reconciled as completed'
    $process.Kill();Assert ($process.WaitForExit(10000)) 'Disposable timed-out remover is explicitly stopped and its exit verified'
    $case=New-Case 'crash-intent';$a=$case.args
    $journal=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-journal';status='running';reviewSha256=$a.ReviewSha256.ToLowerInvariant();plan=$case.plan;updatedAtUtc=Get-RooIndustriesUtcStamp;
        entries=@($case.plan.entries|ForEach-Object {[pscustomobject]@{entryId=$_.entryId;appId=$_.appId;state='pending';attemptCount=0;invocation=$null;outcome=$null;error=$null;registrationAbsent=$false;updatedAtUtc=Get-RooIndustriesUtcStamp}})}
    $journal.entries[0].state='dispatching';$journal.entries[0].attemptCount=1
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $crash=Read-Result (& $runScript @a)
    Assert ($crash.status -eq 'needs-reconciliation' -and -not(Test-Path $case.counter)) 'A crash after durable dispatch intent cannot silently launch the uncertain entry again'
    $journal|Add-Member -NotePropertyName bootTimeUtc -NotePropertyValue (Get-RooIndustriesBulkBootTime)
    $journal.entries[0].state='reboot-required';$journal.entries[0].outcome=Get-RooIndustriesUninstallOutcome windows-installer 3010
    $journal.entries[0].invocation=@{processId=$PID;creationTimeFileTimeUtc=([Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().ToFileTimeUtc().ToString()}
    Remove-Item -LiteralPath $case.markers[0];$journal.entries[0].registrationAbsent=$true
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $beforeReboot=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($beforeReboot.status -eq 'reboot-required' -and $beforeReboot.data.entries[1].attemptCount -eq 0) 'Registration absence cannot clear an MSI reboot requirement during the same boot'
    $journal.bootTimeUtc='2000-01-01T00:00:00Z';Write-RooIndustriesOperationJson $journal $a.JournalPath
    $resumedQueue=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($resumedQueue.status -eq 'reboot-required' -and $resumedQueue.data.entries[1].attemptCount -eq 0) 'An earlier reboot recorded for the queue cannot clear a later remover restart requirement'
    $journal.entries[0].invocation.creationTimeFileTimeUtc=([datetime](Get-RooIndustriesBulkBootTime)).ToUniversalTime().AddMinutes(-1).ToFileTimeUtc().ToString()
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $afterReboot=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($afterReboot.status -eq 'ready' -and $afterReboot.data.entries[0].state -eq 'removed' -and -not(Test-Path $case.counter)) 'A boot after the remover creation time and absent registration reconcile without dispatching an uninstaller'
    $case=New-Case 'changed-registration';$a=$case.args
    [IO.File]::WriteAllText($case.markers[0],'reinstalled after preview')
    $changedRegistration=Read-Result (& $runScript @a)
    Assert ($changedRegistration.status -eq 'needs-reconciliation' -and $changedRegistration.data.entries[0].attemptCount -eq 0 -and -not(Test-Path $case.counter)) 'A changed installed record invalidates the reviewed removal command before dispatch'
    $case=New-Case 'overlapping-queue' 'keep';$a=$case.args
    $first=Read-Result (& $runScript @a)
    $otherPlan=Read-RooIndustriesOperationJson $case.planPath;$otherPlan.data.data.queueId=[guid]::NewGuid().ToString('N')
    $otherPath=Join-Path $case.directory 'second-plan.json';Write-RooIndustriesOperationJson $otherPlan.data $otherPath
    $other=Read-Result (& $runScript -Action Apply -InputPath $otherPath -ReviewSha256 (Get-FileHash $otherPath).Hash -JournalPath (Join-Path $case.directory 'second-journal.json') -ConfirmApply -ManualReviewApproved -AllowFixtureExecution)
    Assert ($other.status -eq 'needs-reconciliation' -and $other.data.entries[0].attemptCount -eq 0 -and @(Get-Content $case.counter).Count -eq 1) 'A different queue cannot relaunch an app with an unresolved durable removal claim'
    $case=New-Case 'bounded-output' 'verbose';$a=$case.args
    $verbose=Read-Result (& $runScript @a)
    Assert ($verbose.status -eq 'cleanup-review-required' -and $verbose.data.entries[0].output.truncated -and $verbose.data.entries[0].output.stdout.Length -eq 65536) 'Verbose vendor output is drained while retained text stays within its explicit memory limit'
    $case=New-Case 'routed';$a=$case.args
    $requestPath=Join-Path $case.directory 'apply request.json'
    Write-RooIndustriesOperationJson @{schemaVersion=1;inputPath=$case.planPath;reviewSha256=$a.ReviewSha256;journalPath=$a.JournalPath;manualReviewApproved=$true;allowFixtureExecution=$true} $requestPath
    $routed=Read-Result (& (Join-Path $PSScriptRoot 'Invoke-RooIndustriesCapability.ps1') -CapabilityId 'cleanup-uninstall.bulk-removal' -Action apply -RequestPath $requestPath -ConfirmApply)
    Assert ($routed.status -eq 'completed' -and $routed.changed -and $routed.evidence.status -eq 'cleanup-review-required' -and @(Get-Content $case.counter).Count -eq 2) 'Capability router executes the reviewed bulk request and reports actual dispatch evidence'
    $leftoverScript=Join-Path $PSScriptRoot 'Invoke-RemovalLeftovers.ps1'
    $appId=$case.plan.entries[0].appId
    $scan=Read-Result (& $leftoverScript -Action Scan -QueueJournalPath $a.JournalPath -AppId $appId)
    $target=Join-Path $case.directory 'app-1'
    $item=@($scan.data.items|Where-Object {$_.target -ieq $target})
    Assert ($scan.status -eq 'preview' -and $item.Count -eq 1 -and (Test-Path $target)) 'Post-removal scan uses saved app metadata and observes current leftovers'
    $reviewPath=Join-Path $case.directory 'leftover-review.json'
    $review=Read-Result (& $leftoverScript -Action Preview -QueueJournalPath $a.JournalPath -AppId $appId -ItemId $item[0].itemId -OutputPath $reviewPath)
    $hash=(Get-FileHash $reviewPath).Hash
    $previewOnly=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash)
    Assert ($previewOnly.status -eq 'preview' -and $previewOnly.dryRun -and (Test-Path $target) -and -not(Test-Path $review.data.rollbackPath)) 'Unconfirmed leftover cleanup creates no deletion or recovery files'
    $changedReview=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 ('0'*64) -ConfirmApply -ManualReviewApproved)
    Assert ($changedReview.status -eq 'failed' -and (Test-Path $target)) 'An altered leftover review hash is rejected before deletion'
    [IO.File]::WriteAllText($case.markers[0],'reinstalled')
    $reinstalled=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply -ManualReviewApproved)
    Assert ($reinstalled.status -eq 'failed' -and (Test-Path $target)) 'An app registered again cannot reuse the old removal approval for cleanup'
    Remove-Item -LiteralPath $case.markers[0]
    $journalHash=(Get-FileHash $a.JournalPath).Hash
    $collision=Read-Result (& $leftoverScript -Action Scan -QueueJournalPath $a.JournalPath -AppId $appId -OutputPath $a.JournalPath)
    Assert ($collision.status -eq 'failed' -and (Get-FileHash $a.JournalPath).Hash -eq $journalHash) 'Scan output cannot overwrite its removal journal'
    $clean=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply -ManualReviewApproved)
    Assert ($clean.status -eq 'success' -and -not(Test-Path $target) -and $clean.data.summary.deletedCount -eq 1) 'A separately reviewed post-removal cleanup deletes only the selected fixture folder'
    $restored=Read-Result (& $leftoverScript -Action Restore -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply)
    Assert ($restored.status -eq 'success' -and [IO.File]::ReadAllText((Join-Path $target 'settings.txt')) -ceq 'original settings' -and [IO.File]::ReadAllText((Join-Path $case.directory 'app-2\settings.txt')) -ceq 'original settings') 'Post-removal file cleanup restores its backed-up contents and leaves the other app unchanged'
    $wrong=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $case.plan.entries[1].appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply)
    Assert ($wrong.status -eq 'failed' -and (Test-Path $target)) 'A cleanup review cannot be replayed against another app in the queue'

} finally {
    foreach($process in @(Get-CimInstance Win32_Process|Where-Object {$_.Name -ieq 'msiexec.exe' -and $_.CommandLine -like "*$msiCode*"})){Stop-Process -Id $process.ProcessId -Force}
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($msiKeyPath,$false)
    if(Test-Path -LiteralPath $msiClaim){Remove-Item -LiteralPath $msiClaim -Force}
    foreach($process in $liveFixtures){if(-not $process.HasExited){$process.Kill()};if(-not $process.WaitForExit(10000)){throw 'Bulk fixture process did not exit'};$process.Dispose()}
    if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path $root) -and -not(Test-Path -LiteralPath ('HKCU:\'+$msiKeyPath)) -and -not(Test-Path -LiteralPath $msiClaim)) 'Bulk tests leave no fixture process, presence marker, registration, claim or journal behind'
