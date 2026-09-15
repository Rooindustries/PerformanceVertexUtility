param([Parameter(Mandatory=$true)][string]$QueueJournalPath,[Parameter(Mandatory=$true)][string]$AppId)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$result=[ordered]@{appId=$AppId;providerIdentityHash='';owner=(Get-RooOperationOwner);providerQueryComplete=$false;
    registrationPresent=$null;rebootPending=$null;removerRunning=$null;removalResolved=$null;errors=@()}
try {
    $queue=(Read-RooOperationJson $QueueJournalPath).data
    if($queue.schemaVersion -ne 1 -or $queue.kind -ne 'bulk-uninstall-journal'){throw 'A versioned removal journal is required.'}
    Assert-RooOperationOwner $queue.plan.owner
    $entries=@($queue.plan.entries|Where-Object {$_.appId -ceq $AppId})
    $states=@($queue.entries|Where-Object {$_.appId -ceq $AppId})
    if($entries.Count -ne 1 -or $states.Count -ne 1){throw 'App identity is not unique in the queue.'}
    $entry=$entries[0];$state=$states[0]
    if($entry.entryId -cne $state.entryId -or $entry.protected -isnot [bool] -or $entry.protected){throw 'Entry binding or protection state does not authorize cleanup.'}
    Assert-RooBulkIdentity $entry.identity ([string]$queue.plan.fixtureRoot)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$result.providerIdentityHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($entry.identity|ConvertTo-Json -Depth 12 -Compress))))).Replace('-','')}
    finally {$sha.Dispose()}
    if($entry.identity.kind -eq 'fixture') {
        try {[IO.File]::GetAttributes([string]$entry.identity.presencePath)|Out-Null;$result.registrationPresent=$true}
        catch [IO.FileNotFoundException] {$result.registrationPresent=$false}
        catch [IO.DirectoryNotFoundException] {$result.registrationPresent=$false}
    } else {$result.registrationPresent=[bool](Test-RooBulkAppPresent $entry.identity ([string]$queue.plan.fixtureRoot))}
    $result.providerQueryComplete=$true
    if($state.registrationAbsent -isnot [bool] -or -not $state.registrationAbsent -or $state.state -notin @('removed','already-absent')){throw 'The selected removal is not reconciled as absent.'}
    if($state.attemptCount -isnot [int] -or $state.attemptCount -lt 0){throw 'The dispatch count is unknown.'}
    if($state.attemptCount -eq 0 -and $state.state -eq 'already-absent' -and $null -eq $state.invocation) {
        $result.removerRunning=$false;$result.rebootPending=$false;$result.removalResolved=$true
    } else {
        if($state.invocation.processId -isnot [int] -or $state.invocation.processId -le 0 -or [string]::IsNullOrWhiteSpace([string]$state.invocation.creationTimeFileTimeUtc)){throw 'The remover process identity is incomplete.'}
        $result.removerRunning=[bool](Test-RooBulkInvocationLive $state.invocation)
        if($state.outcome.exitCode -isnot [int] -or $state.outcome.success -isnot [bool] -or $state.outcome.rebootRequired -isnot [bool] -or
            $state.outcome.stopQueue -isnot [bool] -or $state.outcome.policy -cne $entry.exitCodePolicy){throw 'The remover outcome is missing or incomplete.'}
        $expected=Get-RooUninstallOutcome $entry.exitCodePolicy $state.outcome.exitCode
        foreach($name in @('success','rebootRequired','stopQueue','state')){if($state.outcome.$name -cne $expected.$name){throw 'Recorded outcome signals disagree with the exit-code policy.'}}
        $result.rebootPending=[bool]$expected.rebootRequired
        if($expected.rebootRequired) {
            $result.rebootPending=-not(Test-RooBulkRestartAfterInvocation $state.invocation)
        }
        $result.removalResolved=[bool]($expected.success -and -not $result.removerRunning -and -not $result.rebootPending)
    }
} catch {$result.errors=@($_.Exception.Message)}
$result|ConvertTo-Json -Depth 8
