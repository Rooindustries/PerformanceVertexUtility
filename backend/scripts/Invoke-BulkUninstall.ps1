param(
    [ValidateSet('Apply','Status','Cancel','Reconcile')][string]$Action='Status',
    [string]$InputPath='', [string]$ReviewSha256='',
    [Parameter(Mandatory=$true)][string]$JournalPath,
    [ValidateRange(1,86400)][int]$TimeoutSeconds=600,
    [string]$OutputPath='',
    [switch]$ConfirmApply, [switch]$ManualReviewApproved, [switch]$AllowFixtureExecution
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$result=[pscustomobject]@{schemaVersion=1;actionId='apps.bulkUninstall.'+$Action.ToLowerInvariant();status='failed';dryRun=$true;changed=$false;data=$null;errors=@()}
$lease=$null;$journal=$null
$attemptsBefore=$null
$outputSafe=$false
try {
    Assert-RooDistinctOperationPaths @($InputPath,$JournalPath,$OutputPath)
    if($OutputPath -and [IO.Path]::GetFullPath($OutputPath) -in @([IO.Path]::GetFullPath($JournalPath)+'.cancel',[IO.Path]::GetFullPath($JournalPath)+'.lock')){throw 'OutputPath cannot replace queue control files.'}
    $outputSafe=$true
    $JournalPath=[IO.Path]::GetFullPath($JournalPath)
    $cancelPath=$JournalPath+'.cancel'
    if($Action -eq 'Apply') {
        if(-not $InputPath -or $ReviewSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Apply requires the reviewed plan path and SHA-256.'}
        $input=Read-RooOperationJson $InputPath $ReviewSha256
        $plan=$input.data.data
        if($input.data.status -ne 'preview' -or $plan.kind -ne 'bulk-uninstall-plan'){throw 'Input is not a successful bulk removal preview.'}
    } else {
        $journal=(Read-RooOperationJson $JournalPath).data
        if($journal.kind -ne 'bulk-uninstall-journal'){throw 'Input is not a bulk uninstall journal.'}
        $plan=$journal.plan
    }
    Assert-RooOperationOwner $plan.owner
    $fixtureRoot=[string]$plan.fixtureRoot
    if($fixtureRoot){$fixtureRoot=Assert-RooBulkFixtureRoot $fixtureRoot;if($Action -in @('Apply','Reconcile') -and -not $AllowFixtureExecution){throw 'Disposable plans require AllowFixtureExecution.'}}
    if($Action -eq 'Status') {$result.status=$journal.status;$result.data=$journal}
    elseif($Action -eq 'Cancel') {
        if(-not $ConfirmApply){$result.status='preview';$result.data=$journal}
        else {Write-RooOperationJson ([pscustomobject]@{queueId=$plan.queueId;requestedAtUtc=Get-RooUtcStamp}) $cancelPath;$result.status='cancel-requested';$result.dryRun=$false;$result.data=$journal}
    } elseif(-not $ConfirmApply) {$result.status='preview';$result.data=$plan}
    else {
        $lease=Lock-RooOperation $JournalPath
        if(Test-Path -LiteralPath $JournalPath) {
            $journal=(Read-RooOperationJson $JournalPath).data
            if($journal.kind -ne 'bulk-uninstall-journal' -or $journal.plan.queueId -cne $plan.queueId -or
                ($Action -eq 'Apply' -and $journal.reviewSha256 -ine $ReviewSha256)){throw 'Journal belongs to a different reviewed queue.'}
            $plan=$journal.plan;Assert-RooOperationOwner $plan.owner
        } elseif($Action -eq 'Apply') {
            $states=@($plan.entries|ForEach-Object {[pscustomobject]@{entryId=$_.entryId;appId=$_.appId;state='pending';attemptCount=0;invocation=$null;outcome=$null;error=$null;registrationAbsent=$false;updatedAtUtc=Get-RooUtcStamp}})
            $journal=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-journal';status='ready';reviewSha256=$input.sha256;plan=$plan;entries=$states;bootTimeUtc=Get-RooBulkBootTime;updatedAtUtc=Get-RooUtcStamp}
        } else {throw 'Journal no longer exists.'}
        $attemptsBefore=($journal.entries|Measure-Object -Property attemptCount -Sum).Sum
        foreach($entry in $plan.entries) {
            Assert-RooBulkIdentity $entry.identity $fixtureRoot
            if($entry.protected -or ($entry.reviewRequired -and -not $ManualReviewApproved -and $Action -eq 'Apply')){throw 'This selection requires dependency review or contains a protected app.'}
        }
        $result.dryRun=$false
        if($Action -eq 'Apply' -and $journal.status -eq 'canceled' -and (Test-Path $cancelPath)) {
            # A new confirmed Apply resumes only entries that were never attempted.
            Remove-Item -LiteralPath $cancelPath -Force
        }
        Write-RooOperationJson $journal $JournalPath
        foreach($entry in $plan.entries) {
            $state=@($journal.entries|Where-Object {$_.entryId -ceq $entry.entryId})
            if($state.Count -ne 1){throw 'Journal entry identity does not match the reviewed plan.'};$state=$state[0]
            if($state.state -in @('removed','already-absent') -and $state.registrationAbsent){continue}
            if($Action -eq 'Reconcile') {
                if($state.attemptCount -eq 0){continue}
                if($null -ne $state.outcome -and $state.outcome.rebootRequired -and $state.state -in @('reboot-required','restart-initiated')) {
                    if(-not $journal.bootTimeUtc -or $journal.bootTimeUtc -ceq (Get-RooBulkBootTime)){continue}
                }
                if((Test-RooBulkInvocationLive $state.invocation)){$state.state='needs-reconciliation';continue}
                if(-not(Test-RooBulkAppPresent $entry.identity $fixtureRoot)){$state.state='removed';$state.registrationAbsent=$true;$state.error=$null;Remove-RooBulkOwnedClaim $entry $plan $fixtureRoot}
                else {$state.state='needs-reconciliation'}
                continue
            }
            if($state.attemptCount -gt 0){$journal.status='needs-reconciliation';break}
            if(Test-Path -LiteralPath $cancelPath){$journal.status='canceled';break}
            if(-not(Test-RooBulkAppPresent $entry.identity $fixtureRoot)){
                $state.state='already-absent';$state.registrationAbsent=$true;Write-RooOperationJson $journal $JournalPath;continue
            }
            $journal.status='running';Write-RooOperationJson $journal $JournalPath
            Invoke-RooBulkEntry $entry $state $journal $JournalPath $TimeoutSeconds $fixtureRoot
            if($null -ne $state.outcome -and $state.outcome.success) {
                $state.registrationAbsent=-not(Test-RooBulkAppPresent $entry.identity $fixtureRoot)
                if(-not $state.registrationAbsent -and -not $state.outcome.rebootRequired){$state.state='needs-reconciliation';$state.error='The remover reported success but the exact registration is still present.'}
                if($state.registrationAbsent){Remove-RooBulkOwnedClaim $entry $plan $fixtureRoot}
            }
            Write-RooOperationJson $journal $JournalPath
            if($state.state -notin @('removed','already-absent') -or ($null -ne $state.outcome -and $state.outcome.stopQueue)) {
                $journal.status=if($null -ne $state.outcome -and $state.outcome.rebootRequired){'reboot-required'}else{'needs-reconciliation'};break
            }
        }
        if(@($journal.entries|Where-Object {-not $_.registrationAbsent -or $_.state -notin @('removed','already-absent')}).Count -eq 0){$journal.status='cleanup-review-required'}
        elseif($Action -eq 'Reconcile'){
            $journal.status=if(@($journal.entries|Where-Object {$_.state -in @('reboot-required','restart-initiated')}).Count){'reboot-required'}elseif(@($journal.entries|Where-Object {$_.attemptCount -gt 0 -and -not $_.registrationAbsent}).Count){'needs-reconciliation'}else{'ready'}
        }
        $journal.updatedAtUtc=Get-RooUtcStamp;Write-RooOperationJson $journal $JournalPath
        $result.status=$journal.status;$result.data=$journal
    }
} catch {$result.errors=@([pscustomobject]@{code='BULK_OPERATION_REJECTED';message=$_.Exception.Message});$result.data=$journal}
finally {if($null -ne $lease){$lease.Dispose()}}
if($null -ne $attemptsBefore -and $null -ne $journal){$result.changed=(($journal.entries|Measure-Object -Property attemptCount -Sum).Sum -gt $attemptsBefore)}
if($OutputPath -and $outputSafe){Write-RooOperationJson $result $OutputPath}
$result|ConvertTo-Json -Depth 32
if($result.status -eq 'failed'){exit 1}
