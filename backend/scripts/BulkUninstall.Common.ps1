. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallOutcome.Common.ps1')

function Assert-RooBulkFixtureRoot {
    param([string]$Root)
    $full=[IO.Path]::GetFullPath($Root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+'\'
    if (-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Test-RooCleanupReparsePath $full -Recurse)) {
        throw 'Fixture execution requires an isolated directory beneath the current user temp folder, without reparse paths.'
    }
    return $full
}

function Assert-RooBulkIdentity {
    param($Identity,[string]$FixtureRoot='')
    if ($null -eq $Identity) {throw 'App identity is incomplete. Refresh inventory before preview.'}
    $owner=Get-RooOperationOwner
    switch ([string]$Identity.kind) {
        'registry' {
            if ($Identity.hive -notin @('LocalMachine','CurrentUser') -or $Identity.view -notin @('Registry32','Registry64') -or
                [string]$Identity.keyPath -notmatch '^Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$') {throw 'Invalid registry uninstall identity.'}
            if ($Identity.hive -eq 'CurrentUser' -and $Identity.userSid -cne $owner.userSid) {throw 'Selected registry app belongs to another Windows user.'}
        }
        'appx' {
            if ($Identity.scope -ne 'current-user' -or $Identity.userSid -cne $owner.userSid -or
                $Identity.packageFullName -notmatch '^[^_]+_[^_]+_[^_]+_[^_]*_[^_]+$') {throw 'Invalid current-user Appx identity.'}
        }
        'fixture' {
            if (-not $FixtureRoot -or -not (Test-RooCleanupPathWithin ([string]$Identity.presencePath) $FixtureRoot) -or
                [IO.Path]::GetFullPath([string]$Identity.presencePath) -ieq $FixtureRoot) {throw 'Fixture identity is outside its declared fixture root.'}
        }
        default {throw 'No exact removal adapter is available for this app identity.'}
    }
}

function Test-RooBulkAppPresent {
    param($Identity,[string]$FixtureRoot='')
    Assert-RooBulkIdentity $Identity $FixtureRoot
    if ($Identity.kind -eq 'fixture') {return [IO.File]::Exists([string]$Identity.presencePath)}
    if ($Identity.kind -eq 'appx') {
        return @(Get-AppxPackage -ErrorAction Stop | Where-Object {$_.PackageFullName -ceq $Identity.packageFullName}).Count -gt 0
    }
    $hive=[Microsoft.Win32.RegistryHive]([string]$Identity.hive)
    $view=[Microsoft.Win32.RegistryView]([string]$Identity.view)
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view); $key=$null
    try {$key=$base.OpenSubKey([string]$Identity.keyPath,$false); return $null -ne $key}
    finally {if($null -ne $key){$key.Dispose()};$base.Dispose()}
}

function Get-RooBulkExecutableHash {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or -not [IO.File]::Exists($Path)) {throw 'Removal executable must be an existing absolute file path.'}
    if (Test-RooCleanupReparsePath $Path) {throw 'Removal executable cannot be reached through a reparse path.'}
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RooBulkRegistrationState {
    param($Identity,[string]$FixtureRoot='')
    Assert-RooBulkIdentity $Identity $FixtureRoot
    if($Identity.kind -eq 'fixture'){return [pscustomobject]@{fingerprint=(Get-FileHash -LiteralPath $Identity.presencePath -Algorithm SHA256).Hash.ToLowerInvariant();displayValues=$null}}
    $values=[ordered]@{identity=$Identity}
    $displayValues=@{}
    if($Identity.kind -eq 'registry') {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]([string]$Identity.hive),[Microsoft.Win32.RegistryView]([string]$Identity.view));$key=$null
        try {
            $key=$base.OpenSubKey([string]$Identity.keyPath,$false)
            if($null -eq $key){throw 'App registration disappeared during review.'}
            foreach($name in @('DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','QuietUninstallString','WindowsInstaller')) {
                $values[$name]=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $displayValues[$name]=$values[$name]
                if($null -ne $values[$name] -and $key.GetValueKind($name) -eq [Microsoft.Win32.RegistryValueKind]::ExpandString){$displayValues[$name]=[Environment]::ExpandEnvironmentVariables([string]$values[$name])}
            }
        } finally {if($null -ne $key){$key.Dispose()};$base.Dispose()}
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try {return [pscustomobject]@{fingerprint=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($values|ConvertTo-Json -Depth 12 -Compress))))).Replace('-','').ToLowerInvariant();displayValues=$displayValues}}
    finally {$sha.Dispose()}
}

function Get-RooBulkRegistrationFingerprint {
    param($Identity,[string]$FixtureRoot='')
    return (Get-RooBulkRegistrationState $Identity $FixtureRoot).fingerprint
}

function Assert-RooBulkInventoryBinding {
    param($App,$Registration)
    if($App.sourceIdentity.kind -ne 'registry'){return}
    $mapping=@{displayName='DisplayName';version='DisplayVersion';publisher='Publisher';installLocation='InstallLocation';uninstallString='UninstallString';quietUninstallString='QuietUninstallString'}
    foreach($name in $mapping.Keys) {
        if([string](Get-RooUninstallPropertyValue $App $name '') -cne [string]$Registration.displayValues[$mapping[$name]]) {
            throw 'Inventory differs from the current app registration. Refresh inventory before reviewing a removal command.'
        }
    }
    $productCode=[guid]::Empty
    $msi=($Registration.displayValues.WindowsInstaller -eq 1 -and [guid]::TryParseExact([string]$App.packageId,'B',[ref]$productCode))
    if(($App.sourceType -eq 'msi') -ne $msi){throw 'Installer identity changed after inventory capture.'}
}

function Get-RooBulkClaimPath {
    param($Entry,[string]$FixtureRoot='')
    $root=if($FixtureRoot){Join-Path $FixtureRoot '.removal-claims'}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RooOptimizationSuite\uninstall-claims'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Entry.appId)))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    return Join-Path $root ($id+'.json')
}

function Remove-RooBulkOwnedClaim {
    param($Entry,$Plan,[string]$FixtureRoot='')
    $path=Get-RooBulkClaimPath $Entry $FixtureRoot
    $lease=Lock-RooOperation $path
    try {
        if(Test-Path -LiteralPath $path){$claim=(Read-RooOperationJson $path).data;if($claim.queueId -ceq $Plan.queueId){Remove-Item -LiteralPath $path -Force}}
    } finally {$lease.Dispose()}
}

function Test-RooBulkInvocationLive {
    param($Invocation)
    if ($null -eq $Invocation -or $null -eq $Invocation.processId) {return $false}
    $process=$null
    try {
        $process=[Diagnostics.Process]::GetProcessById([int]$Invocation.processId)
        return -not $process.HasExited -and $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $Invocation.creationTimeFileTimeUtc
    } catch [ArgumentException] {return $false}
    finally {if($null -ne $process){$process.Dispose()}}
}

function Get-RooBulkBootTime {
    # Preserve the reboot boundary separately from command/registration success.
    $system=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return $system.LastBootUpTime.ToUniversalTime().ToString('o')
}

function Invoke-RooBulkEntry {
    param($Entry,$JournalEntry,$Journal,[string]$JournalPath,[int]$TimeoutSeconds,[string]$FixtureRoot='')
    $process=$null; $executableLease=$null; $claimLease=$null; $capture=$null
    try {
        if($null -eq ('Roo.Optimization.ProcessOutput.Capture' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot '..\native\ProcessOutput\RooProcessOutput.cs')}
        $claimPath=Get-RooBulkClaimPath $Entry $FixtureRoot
        $claimLease=Lock-RooOperation $claimPath
        if(Test-Path -LiteralPath $claimPath) {
            $claim=(Read-RooOperationJson $claimPath).data
            if($claim.queueId -cne $Journal.plan.queueId -or $claim.entryId -cne $Entry.entryId){throw 'Another queue has an unresolved removal claim for this app. Reconcile that queue before starting a new one.'}
        }
        if((Get-RooBulkRegistrationFingerprint $Entry.identity $FixtureRoot) -cne $Entry.registrationFingerprint){throw 'App registration changed after review. Create a fresh plan for the current installed version.'}
        # Retain a read lease through CreateProcess so the reviewed executable
        # cannot be replaced between its hash check and launch.
        $executableLease=[IO.File]::Open($Entry.executable,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$digest=([BitConverter]::ToString($sha.ComputeHash($executableLease))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
        if ($digest -cne $Entry.executableSha256) {throw 'Removal executable changed after review.'}
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$Entry.executable; $start.WorkingDirectory=$Entry.workingDirectory
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.Arguments=if($Entry.argumentMode -eq 'raw') {[string]$Entry.rawArguments} else {Join-RooWindowsArguments ([string[]]@($Entry.arguments))}
        $JournalEntry.state='dispatching'; $JournalEntry.attemptCount++; $JournalEntry.updatedAtUtc=Get-RooUtcStamp
        Write-RooOperationJson $Journal $JournalPath
        Write-RooOperationJson ([pscustomobject]@{queueId=$Journal.plan.queueId;entryId=$Entry.entryId;journalPath=$JournalPath}) $claimPath
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        if(-not $process.Start()){throw 'CreateProcess returned false.'}
        $capture=[Roo.Optimization.ProcessOutput.Capture]::new($process,65536)
        $executableLease.Dispose();$executableLease=$null
        $JournalEntry.invocation=[pscustomobject]@{processId=$process.Id; creationTimeFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(); startedAtUtc=Get-RooUtcStamp}
        $JournalEntry.state='running'; Write-RooOperationJson $Journal $JournalPath
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
            $JournalEntry.state='needs-reconciliation'
            $JournalEntry.error='Removal exceeded the observation timeout. It may still be running; it was not killed or automatically repeated.'
            return
        }
        $JournalEntry.outcome=Get-RooUninstallOutcome $Entry.exitCodePolicy $process.ExitCode
        $JournalEntry.state=$JournalEntry.outcome.state
        if(-not $capture.Complete(2000)) {
            $JournalEntry.state='needs-reconciliation'
            $JournalEntry.error='The parent exited but output pipes did not finish. A descendant may still be running.'
        }
    } catch {
        $JournalEntry.error=$_.Exception.Message
        $JournalEntry.state=if($JournalEntry.state -in @('dispatching','running')){'needs-reconciliation'}else{'failed-before-start'}
    } finally {
        if($null -ne $executableLease){$executableLease.Dispose()}
        if($null -ne $capture){
            $JournalEntry|Add-Member -NotePropertyName output -NotePropertyValue ([pscustomobject]@{stdout=$capture.Stdout;stderr=$capture.Stderr;truncated=$capture.Truncated}) -Force
            $capture.Dispose()
        }
        if($null -ne $process){$process.Dispose()}
        if($null -ne $claimLease){$claimLease.Dispose()}
        $JournalEntry.updatedAtUtc=Get-RooUtcStamp
        Write-RooOperationJson $Journal $JournalPath
    }
}
