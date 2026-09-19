$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Host "PASS $Message"}
function Read-Authority {(& (Join-Path $PSScriptRoot 'Get-CleanupAuthority.ps1') -QueueJournalPath $script:journalPath -AppId 'fixture:authority')|ConvertFrom-Json}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-authority-'+[guid]::NewGuid().ToString('N'))
$probe=$null
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $marker=Join-Path $root 'registration.txt'
    $script:journalPath=Join-Path $root 'journal.json'
    $exitGate=Join-Path $root 'finish.txt'
    $command="while(-not(Test-Path -LiteralPath '"+$exitGate.Replace("'","''")+"')){Start-Sleep -Milliseconds 50};exit 0"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),('-NoProfile -NonInteractive -EncodedCommand '+$encoded))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $probe=[Diagnostics.Process]::Start($start)
    $invocation=@{processId=$probe.Id;creationTimeFileTimeUtc=$probe.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()}
    $entry=@{appId='fixture:authority';entryId='entry-1';protected=$false;identity=@{kind='fixture';presencePath=$marker};exitCodePolicy='generic'}
    $state=@{appId='fixture:authority';entryId='entry-1';state='removed';attemptCount=1;registrationAbsent=$true;invocation=$invocation;
        outcome=@{policy='generic';exitCode=0;state='removed';success=$true;rebootRequired=$false;stopQueue=$false}}
    $queue=@{schemaVersion=1;kind='bulk-uninstall-journal';plan=@{owner=(Get-RooIndustriesOperationOwner);fixtureRoot=$root;entries=@($entry)};entries=@($state);bootTimeUtc=$null}
    Write-RooIndustriesOperationJson $queue $journalPath
    $live=Read-Authority
    Assert ($live.providerQueryComplete -and -not $live.registrationPresent -and $live.removerRunning -and -not $live.removalResolved) 'A favorable removed state cannot hide a still-running remover'
    [IO.File]::WriteAllText($exitGate,'finish')
    if(-not $probe.WaitForExit(10000) -or $probe.ExitCode -ne 0){throw 'Authority fixture did not complete with exit zero'}
    $resolved=Read-Authority
    Assert ($resolved.errors.Count -eq 0 -and $resolved.providerQueryComplete -and -not $resolved.registrationPresent -and -not $resolved.removerRunning -and -not $resolved.rebootPending -and $resolved.removalResolved) 'Complete removal evidence is independently established after verified shutdown'
    [IO.File]::WriteAllText($marker,'reinstalled')
    $reinstalled=Read-Authority
    Assert ($reinstalled.registrationPresent -and $reinstalled.removalResolved) 'Returning registration remains a separate blocking signal even after a successful removal'
    [IO.File]::Delete($marker)
    $state.outcome.Remove('rebootRequired');Write-RooIndustriesOperationJson $queue $journalPath
    $missing=Read-Authority
    Assert ($missing.errors.Count -gt 0 -and $null -eq $missing.rebootPending -and $null -eq $missing.removalResolved) 'Missing reboot detail stays unknown instead of becoming false'
    $state.outcome.rebootRequired=$true;$state.outcome.exitCode=0;Write-RooIndustriesOperationJson $queue $journalPath
    $contradictory=Read-Authority
    Assert ($contradictory.errors.Count -gt 0 -and $null -eq $contradictory.removalResolved) 'Contradictory success and reboot signals are rejected against the exit-code policy'
    $entry.exitCodePolicy='windows-installer';$state.outcome=@{policy='windows-installer';exitCode=3010;state='reboot-required';success=$true;rebootRequired=$true;stopQueue=$true}
    $queue.bootTimeUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');Write-RooIndustriesOperationJson $queue $journalPath
    $pending=Read-Authority
    Assert ($pending.rebootPending -and -not $pending.removalResolved) 'Installer success does not override an independent pending reboot'
    $queue.bootTimeUtc='1900-01-01T00:00:00.0000000Z';Write-RooIndustriesOperationJson $queue $journalPath
    $olderQueue=Read-Authority
    Assert ($olderQueue.rebootPending -and -not $olderQueue.removalResolved) 'A reboot before this remover started cannot satisfy its later restart requirement'
    $invocation.creationTimeFileTimeUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().AddMinutes(-1).ToFileTimeUtc().ToString()
    Write-RooIndustriesOperationJson $queue $journalPath
    $rebooted=Read-Authority
    Assert (-not $rebooted.rebootPending -and $rebooted.removalResolved) 'A changed verified boot boundary resolves the recorded reboot requirement'
    $state.state='already-absent';$state.attemptCount=0;$state.invocation=$null;$state.outcome=$null;Write-RooIndustriesOperationJson $queue $journalPath
    $notAttempted=Read-Authority
    Assert ($notAttempted.removalResolved -and -not $notAttempted.removerRunning -and -not $notAttempted.rebootPending) 'An already-absent app with no dispatch has explicit no-remover semantics'
} finally {
    if($probe){if(-not $probe.HasExited){$probe.Kill()};$probe.WaitForExit();$probe.Dispose()}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Authority validation removes its fixture and journal'
