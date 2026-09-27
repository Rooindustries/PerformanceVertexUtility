. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallOutcome.Common.ps1')
. (Join-Path $PSScriptRoot 'AppxInventory.Common.ps1')

function Assert-RooIndustriesBulkFixtureRoot {
    param([string]$Root)
    $full=[IO.Path]::GetFullPath($Root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+'\'
    if (-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Test-RooIndustriesCleanupReparsePath $full -Recurse)) {
        throw 'Fixture execution requires an isolated directory beneath the current user temp folder, without reparse paths.'
    }
    return $full
}

function Assert-RooIndustriesBulkIdentity {
    param($Identity,[string]$FixtureRoot='')
    if ($null -eq $Identity) {throw 'App identity is incomplete. Refresh inventory before preview.'}
    $owner=Get-RooIndustriesOperationOwner
    switch ([string]$Identity.kind) {
        'registry' {
            if ($Identity.hive -notin @('LocalMachine','CurrentUser') -or $Identity.view -notin @('Registry32','Registry64') -or
                [string]$Identity.keyPath -notmatch '^Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$') {throw 'Invalid registry uninstall identity.'}
            if ($Identity.hive -eq 'CurrentUser' -and $Identity.userSid -cne $owner.userSid) {throw 'Selected registry app belongs to another Windows user.'}
        }
        'appx' {
            if ($Identity.scope -notin @('current-user','registered-user') -or $Identity.userSid -notmatch '^S-1-\d+(?:-\d+)+$' -or
                $Identity.packageFullName -notmatch '^[^_]+_[^_]+_[^_]+_[^_]*_[^_]+$') {throw 'Invalid Appx user/package identity.'}
            if($Identity.scope -eq 'current-user' -and $Identity.userSid -cne $owner.userSid){throw 'The current-user package identity belongs to another Windows account.'}
            if($Identity.scope -eq 'registered-user' -and -not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Removing another account''s Appx registration requires an administrator token.'}
        }
        'fixture' {
            if (-not $FixtureRoot -or -not (Test-RooIndustriesCleanupPathWithin ([string]$Identity.presencePath) $FixtureRoot) -or
                [IO.Path]::GetFullPath([string]$Identity.presencePath) -ieq $FixtureRoot) {throw 'Fixture identity is outside its declared fixture root.'}
        }
        default {throw 'No exact removal adapter is available for this app identity.'}
    }
}

function Test-RooIndustriesBulkAppPresent {
    param($Identity,[string]$FixtureRoot='')
    Assert-RooIndustriesBulkIdentity $Identity $FixtureRoot
    if ($Identity.kind -eq 'fixture') {return [IO.File]::Exists([string]$Identity.presencePath)}
    if ($Identity.kind -eq 'appx') {
        return $null -ne (Get-RooIndustriesExactAppxPackage $Identity)
    }
    $hive=[Microsoft.Win32.RegistryHive]([string]$Identity.hive)
    $view=[Microsoft.Win32.RegistryView]([string]$Identity.view)
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view); $key=$null
    try {$key=$base.OpenSubKey([string]$Identity.keyPath,$false); return $null -ne $key}
    finally {if($null -ne $key){$key.Dispose()};$base.Dispose()}
}

function Get-RooIndustriesBulkExecutableHash {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or -not [IO.File]::Exists($Path)) {throw 'Removal executable must be an existing absolute file path.'}
    if (Test-RooIndustriesCleanupReparsePath $Path) {throw 'Removal executable cannot be reached through a reparse path.'}
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RooIndustriesBulkRegistrationState {
    param($Identity,[string]$FixtureRoot='')
    Assert-RooIndustriesBulkIdentity $Identity $FixtureRoot
    if($Identity.kind -eq 'fixture'){return [pscustomobject]@{fingerprint=(Get-FileHash -LiteralPath $Identity.presencePath -Algorithm SHA256).Hash.ToLowerInvariant();displayValues=$null}}
    $values=[ordered]@{identity=$Identity}
    $displayValues=@{}
    if($Identity.kind -eq 'appx'){
        $package=Get-RooIndustriesExactAppxPackage $Identity
        if($null -eq $package){throw 'The exact Appx user registration disappeared during review.'}
        $values.packageFacts=Get-RooIndustriesAppxFacts $package
        $displayValues=$values.packageFacts
    }
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

function Get-RooIndustriesBulkRegistrationFingerprint {
    param($Identity,[string]$FixtureRoot='')
    return (Get-RooIndustriesBulkRegistrationState $Identity $FixtureRoot).fingerprint
}

function Assert-RooIndustriesBulkInventoryBinding {
    param($App,$Registration)
    if($App.sourceIdentity.kind -eq 'appx'){
        $facts=$Registration.displayValues
        if($facts.nonRemovable -or $facts.isFramework -or $facts.isResource){throw 'Windows protects this package or identifies it as a shared dependency.'}
        if($null -ne $App.PSObject.Properties['packageFacts'] -and ($App.packageFacts|ConvertTo-Json -Depth 8 -Compress) -cne ($facts|ConvertTo-Json -Depth 8 -Compress)){throw 'Appx dependency or protection information changed after inventory. Refresh before removal.'}
        return
    }
    if($App.sourceIdentity.kind -ne 'registry'){return}
    $mapping=@{displayName='DisplayName';version='DisplayVersion';publisher='Publisher';installLocation='InstallLocation';uninstallString='UninstallString';quietUninstallString='QuietUninstallString'}
    foreach($name in $mapping.Keys) {
        if([string](Get-RooIndustriesUninstallPropertyValue $App $name '') -cne [string]$Registration.displayValues[$mapping[$name]]) {
            throw 'Inventory differs from the current app registration. Refresh inventory before reviewing a removal command.'
        }
    }
    $productCode=[guid]::Empty
    $msi=($Registration.displayValues.WindowsInstaller -eq 1 -and [guid]::TryParseExact([string]$App.packageId,'B',[ref]$productCode))
    if(($App.sourceType -eq 'msi') -ne $msi){throw 'Installer identity changed after inventory capture.'}
}

function Get-RooIndustriesBulkArguments {
    param($Entry)
    if($Entry.argumentMode -eq 'raw'){return [string]$Entry.rawArguments}
    return Join-RooIndustriesWindowsArguments ([string[]]@($Entry.arguments))
}

function Get-RooIndustriesBulkCommandLine {
    param($Entry)
    return Get-RooIndustriesUninstallCommandLine ([string]$Entry.executable) (Get-RooIndustriesBulkArguments $Entry)
}

function Get-RooIndustriesBulkClaimPath {
    param($Entry,[string]$FixtureRoot='')
    $root=if($FixtureRoot){Join-Path $FixtureRoot '.removal-claims'}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RooIndustriesOptimizationSuite\uninstall-claims'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Entry.appId)))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    return Join-Path $root ($id+'.json')
}

function Remove-RooIndustriesBulkOwnedClaim {
    param($Entry,$Plan,[string]$FixtureRoot='')
    $path=Get-RooIndustriesBulkClaimPath $Entry $FixtureRoot
    $lease=Lock-RooIndustriesOperation $path
    try {
        if(Test-Path -LiteralPath $path){$claim=(Read-RooIndustriesOperationJson $path).data;if($claim.queueId -ceq $Plan.queueId){Remove-Item -LiteralPath $path -Force}}
    } finally {$lease.Dispose()}
}

function Import-RooIndustriesBulkProcessTypes {
    if($null -eq ('RooIndustries.Optimization.ProcessOutput.Capture' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot '..\native\ProcessOutput\RooIndustriesProcessOutput.cs')}
    if($null -eq ('RooIndustries.Optimization.ProcessOutput.Tree' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot '..\native\ProcessOutput\RooIndustriesProcessTree.cs')}
}

function Test-RooIndustriesBulkInvocationLive {
    param($Invocation)
    if ($null -eq $Invocation -or $null -eq $Invocation.processId) {return $false}
    Import-RooIndustriesBulkProcessTypes
    $members=@($Invocation)
    if($null -ne $Invocation.PSObject.Properties['descendants']){$members+=@($Invocation.descendants)}
    $boot=$null
    foreach($member in $members){
        $created=[long]0
        if([long]::TryParse([string]$member.creationTimeFileTimeUtc,[ref]$created) -and $created -gt 0) {
            if($null -eq $boot){
                try {$boot=[datetime]::Parse((Get-RooIndustriesBulkBootTime),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()}
                catch {$boot=[datetime]::MinValue}
            }
            if([datetime]::FromFileTimeUtc($created) -lt $boot){continue}
        }
        if([RooIndustries.Optimization.ProcessOutput.Tree]::IsRunning([int]$member.processId,[string]$member.creationTimeFileTimeUtc)){return $true}
    }
    return $false
}

function Test-RooIndustriesBulkClaimLive {
    param($Claim)
    $invocation=Get-RooIndustriesUninstallPropertyValue $Claim 'invocation' $null
    if($null -ne $invocation){return Test-RooIndustriesBulkInvocationLive $invocation}
    $executable=[string](Get-RooIndustriesUninstallPropertyValue $Claim 'executable' '')
    $claimed=[string](Get-RooIndustriesUninstallPropertyValue $Claim 'claimedAtUtc' '')
    if(-not $executable -or -not $claimed){return $false}
    try {
        $since=[datetime]::Parse($claimed,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().AddSeconds(-1)
        return @(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.ExecutablePath -and $_.ExecutablePath -ieq $executable -and $_.CreationDate.ToUniversalTime() -ge $since}).Count -gt 0
    } catch {return $true}
}

function ConvertTo-RooIndustriesRemoverMembers {
    param($Tree)
    return @($Tree.Descendants()|ForEach-Object {[pscustomobject]@{processId=$_.ProcessId;creationTimeFileTimeUtc=$_.CreationTimeFileTimeUtc;name=$_.Name}})
}

function Wait-RooIndustriesRemoverTree {
    param($Process,$Tree,[int]$TimeoutSeconds,[scriptblock]$OnChange)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds); $recorded=1; $waitingFor=''
    while($true) {
        $Tree.Refresh()
        $live=@($Tree.Live()); $settled=$false
        if($live.Count -eq 0){$known=$Tree.Count;$Tree.Refresh();$settled=($Tree.Count -eq $known)}
        $names=(@($live|Where-Object {$_.ProcessId -ne $Process.Id}|ForEach-Object {$_.Name}|Sort-Object -Unique) -join ', ')
        if($Tree.Count -ne $recorded -or ($Process.HasExited -and $names -cne $waitingFor)) {
            $recorded=$Tree.Count; $waitingFor=if($Process.HasExited){$names}else{''}
            if($null -ne $OnChange){& $OnChange $waitingFor}
        }
        if($settled){return [pscustomobject]@{completed=$true;rootRunning=$false;running=''}}
        if([DateTime]::UtcNow -ge $deadline){return [pscustomobject]@{completed=$false;rootRunning=(-not $Process.HasExited);running=$names}}
        Start-Sleep -Milliseconds 250
    }
}

function Get-RooIndustriesRemoverTimeoutMessage {
    param($Wait)
    if($Wait.rootRunning){return 'Removal exceeded the observation timeout. It may still be running; it was not killed or automatically repeated.'}
    if(-not $Wait.running){return 'The remover kept starting short-lived helper processes until the observation timeout. They were not killed or automatically repeated.'}
    return "The remover handed off to $($Wait.running), which was still running at the observation timeout. It was not killed or automatically repeated."
}

function Invoke-RooIndustriesObservedRemover {
    param([string]$FilePath,[string]$Arguments,[string]$WorkingDirectory,[int]$TimeoutSeconds,[scriptblock]$OnProgress,[string]$ExpectedCommandLine,[IDisposable]$ExecutableLease)
    $commandLine=Get-RooIndustriesUninstallCommandLine $FilePath $Arguments
    if($commandLine -cne $ExpectedCommandLine){throw 'The remover command differs from the reviewed command. Check the removal path again.'}
    Import-RooIndustriesBulkProcessTypes
    $result=[ordered]@{startedAtUtc=Get-RooIndustriesUtcStamp;completedAtUtc=$null;filePath=$FilePath;rawArguments=$Arguments
        commandLine=$commandLine;processStarted=$false;startError=$null;exitCode=$null
        timedOut=$false;processExitVerified=$false;descendantExitVerified=$false;outputIncomplete=$false;stillRunning='';error=$null
        timeoutSeconds=$TimeoutSeconds;invocation=$null;stdout='';stderr=''}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$FilePath; $start.Arguments=$Arguments
    if($WorkingDirectory){$start.WorkingDirectory=$WorkingDirectory}
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start; $capture=$null; $tree=$null
    try {
        try {$result.processStarted=$process.Start()} catch {$result.startError=$_.Exception.Message}
        if($result.processStarted) {
            if($null -ne $ExecutableLease){$ExecutableLease.Dispose()}
            $result.invocation=[pscustomobject]@{processId=$process.Id;creationTimeFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();startedAtUtc=$result.startedAtUtc;treeContained=$false;descendants=@()}
            if($null -ne $OnProgress){& $OnProgress $result.invocation}
            $capture=[RooIndustries.Optimization.ProcessOutput.Capture]::new($process,65536)
            $tree=[RooIndustries.Optimization.ProcessOutput.Tree]::new($process)
            $result.invocation.treeContained=$tree.Contained
            $wait=Wait-RooIndustriesRemoverTree $process $tree $TimeoutSeconds {
                param($waitingFor)
                $result.invocation.descendants=ConvertTo-RooIndustriesRemoverMembers $tree
                if($null -ne $OnProgress){& $OnProgress $result.invocation}
            }
            if($wait.completed) {
                $result.processExitVerified=$true; $result.descendantExitVerified=$true; $result.exitCode=$process.ExitCode
                if(-not $capture.Complete(2000)){$result.outputIncomplete=$true}
            } else {
                $result.timedOut=$true; $result.processExitVerified=-not $wait.rootRunning; $result.stillRunning=$wait.running
                $result.error=Get-RooIndustriesRemoverTimeoutMessage $wait
            }
        }
    } catch {
        $result.error=$_.Exception.Message
        if($result.processStarted){$result.timedOut=$true}
    } finally {
        if($null -ne $capture){$result.stdout=$capture.Stdout;$result.stderr=$capture.Stderr;$capture.Dispose()}
        if($null -ne $tree){$tree.Dispose()}
        if($null -ne $ExecutableLease){$ExecutableLease.Dispose()}
        $process.Dispose()
        $result.completedAtUtc=Get-RooIndustriesUtcStamp
    }
    return [pscustomobject]$result
}

function Get-RooIndustriesBulkBootTime {
    # Preserve the reboot boundary separately from command/registration success.
    $system=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return $system.LastBootUpTime.ToUniversalTime().ToString('o')
}

function Test-RooIndustriesBulkRestartAfterInvocation {
    param($Invocation)
    $createdFileTime=[long]0
    if($null -eq $Invocation -or -not [long]::TryParse([string]$Invocation.creationTimeFileTimeUtc,[ref]$createdFileTime) -or $createdFileTime -le 0){
        throw 'The remover creation time is missing; a later restart cannot be verified.'
    }
    $created=[datetime]::FromFileTimeUtc($createdFileTime)
    $boot=[datetime]::Parse((Get-RooIndustriesBulkBootTime),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    return $boot -gt $created
}

function Invoke-RooIndustriesBulkEntry {
    param($Entry,$JournalEntry,$Journal,[string]$JournalPath,[int]$TimeoutSeconds,[string]$FixtureRoot='')
    $process=$null; $executableLease=$null; $claimLease=$null; $capture=$null; $tree=$null
    try {
        Import-RooIndustriesBulkProcessTypes
        $claimPath=Get-RooIndustriesBulkClaimPath $Entry $FixtureRoot
        try {$claimLease=Lock-RooIndustriesOperation $claimPath} catch [IO.IOException] {throw 'Another removal of this app is running right now. Let it finish, then try again.'}
        if(Test-Path -LiteralPath $claimPath) {
            $claim=(Read-RooIndustriesOperationJson $claimPath).data
            if([string](Get-RooIndustriesUninstallPropertyValue $claim 'kind' '') -eq 'cleanup-apply') {
                if(Test-RooIndustriesBulkClaimLive $claim){throw 'An earlier removal of this app from Leftover cleanup is still running or can''t be checked. Let it finish, then try again.'}
                Remove-Item -LiteralPath $claimPath -Force
            } elseif($claim.queueId -cne $Journal.plan.queueId -or $claim.entryId -cne $Entry.entryId){throw 'Another queue has an unresolved removal claim for this app. Reconcile that queue before starting a new one.'}
        }
        if((Get-RooIndustriesBulkRegistrationFingerprint $Entry.identity $FixtureRoot) -cne $Entry.registrationFingerprint){throw 'App registration changed after review. Create a fresh plan for the current installed version.'}
        if((Get-RooIndustriesBulkCommandLine $Entry) -cne [string]$Entry.commandLine){throw 'The removal command differs from the reviewed command. Create a fresh plan.'}
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
        $start.Arguments=Get-RooIndustriesBulkArguments $Entry
        $JournalEntry.state='dispatching'; $JournalEntry.attemptCount++; $JournalEntry.updatedAtUtc=Get-RooIndustriesUtcStamp
        Write-RooIndustriesOperationJson $Journal $JournalPath
        Write-RooIndustriesOperationJson ([pscustomobject]@{queueId=$Journal.plan.queueId;entryId=$Entry.entryId;journalPath=$JournalPath}) $claimPath
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        if(-not $process.Start()){throw 'CreateProcess returned false.'}
        $capture=[RooIndustries.Optimization.ProcessOutput.Capture]::new($process,65536)
        $tree=[RooIndustries.Optimization.ProcessOutput.Tree]::new($process)
        $executableLease.Dispose();$executableLease=$null
        $JournalEntry.invocation=[pscustomobject]@{processId=$process.Id; creationTimeFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(); startedAtUtc=Get-RooIndustriesUtcStamp; treeContained=$tree.Contained; descendants=@()}
        $JournalEntry.state='running'; Write-RooIndustriesOperationJson $Journal $JournalPath
        $wait=Wait-RooIndustriesRemoverTree $process $tree $TimeoutSeconds {
            param($waitingFor)
            $JournalEntry.invocation.descendants=ConvertTo-RooIndustriesRemoverMembers $tree
            $JournalEntry.error=if($waitingFor){"Waiting for $waitingFor to finish."}else{$null}
            $JournalEntry.updatedAtUtc=Get-RooIndustriesUtcStamp; Write-RooIndustriesOperationJson $Journal $JournalPath
        }
        if(-not $wait.completed) {
            $JournalEntry.state='needs-reconciliation'
            $JournalEntry.error=Get-RooIndustriesRemoverTimeoutMessage $wait
            return
        }
        $JournalEntry.error=$null
        $JournalEntry.outcome=Get-RooIndustriesUninstallOutcome $Entry.exitCodePolicy $process.ExitCode
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
        if($null -ne $tree){$tree.Dispose()}
        if($null -ne $process){$process.Dispose()}
        if($null -ne $claimLease){$claimLease.Dispose()}
        $JournalEntry.updatedAtUtc=Get-RooIndustriesUtcStamp
        Write-RooIndustriesOperationJson $Journal $JournalPath
    }
}
