param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string[]]$Only = @())
# One Background limits run lowers a real probe's CPU, I/O and memory priority, an optional newer run lowers its
# CPU priority further, and a Restore of the older run is cut at one step of putting I/O priority back. Then
# another program may change that I/O priority, and status and a second Restore run. Each cell checks the final
# value, the ownership saved on disk, whether status offers Restore, and the words the card shows.
$ErrorActionPreference = 'Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
$oraclePath = Join-Path $Source 'tools\validation\Background\Oracle.cs'
Add-Type -Path $oraclePath
$directory = Join-Path $OutRoot 'ownership'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$scripts = Join-Path $Source 'backend\scripts'
$failures = New-Object System.Collections.Generic.List[string]
$results = New-Object System.Collections.Generic.List[object]
$owned = $null
$probe = $null
$workerOwned = $null
$cellIndex = 0
$probeName = 'OwnershipFixture'
$probeExe = Join-Path $directory ($probeName + '.exe')
Copy-Item "$env:SystemRoot\System32\PING.EXE" $probeExe -Force

$texts = @{
    saveFailed = 'Background limits couldn''t save its record for this setting, so Restore stopped there. Try Restore again.'
    interrupted = 'Restore stopped part-way while putting this setting back'
    readbackFailed = 'Windows couldn''t read this setting back after Restore put it back'
    unreadableNewer = 'A newer Background limits run whose saved files couldn''t be read may have changed this setting, so it was left alone.'
    unreadableRun = 'Its saved files couldn''t be read, so Restore leaves alone every setting it may have changed. They go back to normal when those apps restart.'
    newerHolds = 'A newer Background limits run still holds this setting. Restore that run first.'
}
$original = @{ priorityClass = 'Normal'; io = 2; memory = 5 }
$lowered = @{ priorityClass = 'BelowNormal'; io = 1; memory = 2 }
$otherIo = 0

function Save([string]$Name,$Value) { [IO.File]::WriteAllText((Join-Path $directory ($Name + '.json')), ($Value | ConvertTo-Json -Depth 40), $utf8) }
function Case([string]$Cell,[bool]$Passed,[string]$Name,[string]$Detail = '') {
    $line = $(if ($Passed) { 'PASS ' } else { 'FAIL ' }) + $Cell + ': ' + $Name + $(if ($Passed -or [string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' (' + $Detail + ')' })
    [Console]::WriteLine($line)
    $script:results.Add([pscustomobject]@{ cell = $Cell; check = $Name; passed = $Passed; detail = $Detail }) | Out-Null
    if (-not $Passed) { $script:failures.Add($Cell + ': ' + $Name) | Out-Null }
}

function Start-OwnershipProbe {
    $process = Start-Process $probeExe -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru
    $script:owned = New-OwnedProcess $process
    $script:probe = $process
    $process.PriorityClass = 'Normal'
    [RooIndustriesBackgroundOracle]::SetIo($process, 2)
    [RooIndustriesBackgroundOracle]::SetMemory($process, 5)
}

function Stop-OwnershipProbe {
    if ($null -ne $script:owned) { Stop-OwnedProcess $script:owned; $script:probe.WaitForExit(10000) | Out-Null }
    $script:owned = $null
    $script:probe = $null
}

function Read-Probe {
    $script:probe.Refresh()
    return [pscustomobject]@{ priorityClass = [string]$script:probe.PriorityClass; io = [RooIndustriesBackgroundOracle]::Io($script:probe); memory = [int][RooIndustriesBackgroundOracle]::Memory($script:probe) }
}

function New-Profile([string]$Name,[string]$Priority) {
    $profile = Get-Content -Raw (Join-Path $Source 'backend\profiles\probalance-governor.profile.json') | ConvertFrom-Json
    $profile.protectedCatalogPath = Join-Path $Source 'backend\profiles\protected-processes.json'
    $profile.governor.candidateSelectors = @([pscustomobject]@{ ruleId = 'fixture'; enabled = $true; match = @{ processNames = @($probeName + '.exe') } })
    $thresholds = $profile.governor.thresholds
    $thresholds.totalCpuPressureThresholdPercent = 0
    $thresholds.perProcessCpuThresholdPercent = 0
    $thresholds.timeOverThresholdSeconds = 0
    $thresholds.minimumRestraintSeconds = 600
    $profile.governor.restraint.priorityClass = $Priority
    $path = Join-Path $directory ($Name + '-profile.json')
    [IO.File]::WriteAllText($path, ($profile | ConvertTo-Json -Depth 40), $utf8)
    return $path
}
$olderProfile = New-Profile 'older' 'BelowNormal'
$newerProfile = New-Profile 'newer' 'Idle'

function Start-Limits([string]$Cell,[string]$Name,[string]$Profile,[string]$State) {
    $output = Join-Path $directory ($Cell + '-' + $Name + '.json')
    & (Join-Path $scripts 'Start-ProcessGovernorSession.ps1') -ProfilePath $Profile -StateRoot $State -MaxDurationSeconds 3 -PollIntervalSeconds 1 -SampleIntervalMilliseconds 250 -ConfirmApply -OutputPath $output | Out-Null
    return Get-Content -Raw $output | ConvertFrom-Json
}

function Get-Status([string]$Cell,[string]$Name,[string]$State) {
    $output = Join-Path $directory ($Cell + '-' + $Name + '.json')
    & (Join-Path $scripts 'Get-ProcessGovernorSessionStatus.ps1') -StateRoot $State -OutputPath $output | Out-Null
    return Get-Content -Raw $output | ConvertFrom-Json
}

function Stop-Limits([string]$Cell,[string]$Name,$Run,[string]$State) {
    $output = Join-Path $directory ($Cell + '-' + $Name + '.json')
    try { & (Join-Path $scripts 'Stop-ProcessGovernorSession.ps1') -SessionPath $Run.sessionPath -StateRoot $State -ConfirmApply -OutputPath $output | Out-Null } catch { }
    return Get-Content -Raw $output | ConvertFrom-Json
}

function Quote([string]$Text) { return "'" + $Text.Replace("'", "''") + "'" }

# A real Restore in its own Windows PowerShell, cut at one step of putting I/O priority back. The cut is made
# where any build saves, writes and reads back, so the same cells run against older builds.
function Invoke-CutRestore([string]$Cell,[string]$Fault,$Run,[string]$State) {
    $output = Join-Path $directory ($Cell + '-cut.json')
    $script = Join-Path $directory ($Cell + '-cut.ps1')
    $text = @"
`$ErrorActionPreference = 'Stop'
Add-Type -Path $(Quote $oraclePath)
`$global:CutFault = $(Quote $Fault)
`$global:CutStage = 0
`$global:CutDone = `$false
`$global:CutProbe = $($script:probe.Id)
`$global:CutStateReads = 0
function global:Test-CutIoRecord(`$Value,[string]`$Field) {
    foreach (`$snapshot in @(`$Value.snapshots)) {
        if ([int]`$snapshot.processId -ne `$global:CutProbe) { continue }
        foreach (`$record in @(`$snapshot.controlChanges)) { if (`$record.control -eq 'ioPriority' -and `$null -ne `$record.PSObject.Properties[`$Field]) { return `$true } }
    }
    return `$false
}
Set-PSBreakpoint -Command Set-RooIndustriesProcessIoPriority -Action {
    if (`$global:CutFault -eq 'kill-after-intent') { [Environment]::Exit(9) }
    `$global:CutStage = 1
} | Out-Null
Set-PSBreakpoint -Command Get-RooIndustriesProcessControlReadback -Action {
    if (`$Control -ne 'ioPriority' -or `$global:CutStage -ne 1) { return }
    `$global:CutStage = 2
    if (`$global:CutFault -eq 'kill-after-write') { [Environment]::Exit(9) }
    if (`$global:CutFault -eq 'readback-fails') { Set-Variable -Name Control -Value 'unreadable' -Scope 1 }
} | Out-Null
Set-PSBreakpoint -Command Get-RooIndustriesProcessControlState -Action {
    if (`$global:CutFault -ne 'original-then-lowered' -or `$ProcessId -ne `$global:CutProbe) { return }
    `$global:CutStateReads++
    if (`$global:CutStateReads -eq 2) { [RooIndustriesBackgroundOracle]::SetIo([Diagnostics.Process]::GetProcessById(`$global:CutProbe), 2) }
} | Out-Null
Set-PSBreakpoint -Command Write-RooIndustriesProcessGovernorJsonFile -Action {
    if (`$global:CutDone -or [IO.Path]::GetFileName(`$Path) -ne 'backup.json') { return }
    if (`$global:CutFault -eq 'intent-save-fails' -and (Test-CutIoRecord `$Value 'restoreIntent')) {
        `$global:CutDone = `$true
        Set-Variable -Name Path -Value (`$Path + '|') -Scope 1
    } elseif (`$global:CutFault -eq 'kill-after-readback' -and `$global:CutStage -eq 2) {
        [Environment]::Exit(9)
    } elseif (`$global:CutFault -eq 'release-save-fails' -and `$global:CutStage -eq 2) {
        `$global:CutDone = `$true
        Set-Variable -Name Path -Value (`$Path + '|') -Scope 1
    } elseif (`$global:CutFault -eq 'original-then-lowered' -and (Test-CutIoRecord `$Value 'restoredAtUtc')) {
        `$global:CutDone = `$true
        [RooIndustriesBackgroundOracle]::SetIo([Diagnostics.Process]::GetProcessById(`$global:CutProbe), 1)
    }
} | Out-Null
& $(Quote (Join-Path $scripts 'Stop-ProcessGovernorSession.ps1')) -SessionPath $(Quote $Run.sessionPath) -StateRoot $(Quote $State) -ConfirmApply -OutputPath $(Quote $output)
"@
    [IO.File]::WriteAllText($script, $text, [Text.UTF8Encoding]::new($true))
    $worker = Start-Process (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '"') -WindowStyle Hidden -PassThru
    $script:workerOwned = New-OwnedProcess $worker
    if (-not $worker.WaitForExit(90000)) { throw "The cut Restore for $Cell did not finish" }
    $script:workerOwned = $null
    $result = if (Test-Path -LiteralPath $output) { Get-Content -Raw $output | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ exitCode = $worker.ExitCode; result = $result }
}

function Get-IoOwnership($Run) {
    $backup = Get-Content -Raw $Run.backupManifestPath | ConvertFrom-Json
    $record = @(@($backup.snapshots)[-1].controlChanges | Where-Object { $_.control -eq 'ioPriority' })[0]
    if ($null -eq $record) { return 'none' }
    if (-not [string]::IsNullOrWhiteSpace([string]$record.restoredAtUtc)) { return 'released' }
    if ($null -ne $record.PSObject.Properties['restoreIntent']) { return 'restoreIntent' }
    return 'owned'
}

function Get-PriorityOwnership($Run) {
    $backup = Get-Content -Raw $Run.backupManifestPath | ConvertFrom-Json
    $record = @(@($backup.snapshots)[-1].controlChanges | Where-Object { $_.control -eq 'priorityClass' })[0]
    if (-not [string]::IsNullOrWhiteSpace([string]$record.restoredAtUtc)) { return 'released' }
    return 'owned'
}

function Get-Reasons($Envelope) {
    if ($null -eq $Envelope) { return '' }
    return ((@($Envelope.skippedItems) | ForEach-Object { [string]$_.reason }) + (@($Envelope.errors) | ForEach-Object { [string]$_.message }) + @([string]$Envelope.result.summary)) -join ' | '
}

function Break-Newer([string]$Newer,$Run) {
    switch ($Newer) {
        'unreadable-session' { [IO.File]::WriteAllText($Run.sessionPath, '{ "restorable": true,', $utf8) }
        'empty-session' { [IO.File]::WriteAllText($Run.sessionPath, '{}', $utf8) }
        'empty-backup' { [IO.File]::WriteAllText($Run.backupManifestPath, '{}', $utf8) }
        'null-snapshots' { [IO.File]::WriteAllText($Run.backupManifestPath, '{"snapshots":null}', $utf8) }
        'object-snapshots' {
            $backup = Get-Content -Raw $Run.backupManifestPath | ConvertFrom-Json
            $backup.snapshots = @($backup.snapshots)[0]
            [IO.File]::WriteAllText($Run.backupManifestPath, ($backup | ConvertTo-Json -Depth 40), $utf8)
        }
        'partial-backup' {
            $text = [IO.File]::ReadAllText($Run.backupManifestPath)
            [IO.File]::WriteAllText($Run.backupManifestPath, $text.Substring(0, [int]($text.Length / 2)), $utf8)
        }
    }
}

# What a fault leaves for I/O priority: who owns it on disk and its value, and whether memory priority, which
# Restore reaches after I/O priority, was put back.
function Get-AfterCut([string]$Fault) {
    switch ($Fault) {
        'none' { return @{ own = 'released'; io = $original.io; memoryBack = $true } }
        'intent-save-fails' { return @{ own = 'owned'; io = $lowered.io; memoryBack = $false } }
        'kill-after-intent' { return @{ own = 'restoreIntent'; io = $lowered.io; memoryBack = $false } }
        'kill-after-write' { return @{ own = 'restoreIntent'; io = $original.io; memoryBack = $false } }
        'readback-fails' { return @{ own = 'restoreIntent'; io = $original.io; memoryBack = $true } }
        'kill-after-readback' { return @{ own = 'restoreIntent'; io = $original.io; memoryBack = $false } }
        'release-save-fails' { return @{ own = 'restoreIntent'; io = $original.io; memoryBack = $false } }
        'original-then-lowered' { return @{ own = 'released'; io = $lowered.io; memoryBack = $true } }
    }
}

# The second Restore's step for I/O priority under the ownership rules.
function Get-SecondIo([string]$Own,[int]$Io,[string]$Newer) {
    $unknownSession = $Newer -in 'unreadable-session', 'empty-session'
    $blocked = $Newer -in 'empty-backup', 'null-snapshots', 'object-snapshots', 'partial-backup'
    if ($Own -eq 'released') { return @{ own = 'released'; io = $Io; text = $null; leftAsSet = $false } }
    if ($blocked) { return @{ own = $Own; io = $Io; text = $texts.unreadableNewer; leftAsSet = $false } }
    if ($Io -eq $original.io) {
        if ($Own -eq 'restoreIntent') { return @{ own = 'released'; io = $Io; text = $null; leftAsSet = $false } }
        if ($unknownSession) { return @{ own = $Own; io = $Io; text = $texts.unreadableNewer; leftAsSet = $false } }
        return @{ own = 'released'; io = $Io; text = $null; leftAsSet = $false }
    }
    if ($Io -eq $lowered.io) {
        if ($Own -eq 'restoreIntent') { return @{ own = 'restoreIntent'; io = $Io; text = $texts.interrupted; leftAsSet = $false } }
        return @{ own = 'released'; io = $original.io; text = $null; leftAsSet = $false }
    }
    if ($unknownSession) { return @{ own = $Own; io = $Io; text = $texts.unreadableNewer; leftAsSet = $false } }
    return @{ own = 'released'; io = $Io; text = $null; leftAsSet = $true }
}

function Invoke-Cell([string]$Fault,[string]$Next,[string]$Newer) {
    $cell = $Fault + '.' + $Next + '.' + $Newer
    if ($Only.Count -gt 0 -and -not @($Only | Where-Object { $cell -like $_ })) { return }
    # A short state folder keeps each run's saved files under the 260-character path limit of Windows PowerShell 5.1.
    $script:cellIndex++
    $state = Join-Path $directory ('s' + $script:cellIndex)
    $unknownSession = $Newer -in 'unreadable-session', 'empty-session'
    $blocked = $Newer -in 'empty-backup', 'null-snapshots', 'object-snapshots', 'partial-backup'
    try {
        Start-OwnershipProbe
        $older = Start-Limits $cell 'older' $olderProfile $state
        $value = Read-Probe
        if (-not $older.restorable -or $value.priorityClass -ne $lowered.priorityClass -or $value.io -ne $lowered.io -or $value.memory -ne $lowered.memory) { throw "The older run didn't lower the probe: $($value | ConvertTo-Json -Compress)" }
        $newerRun = $null
        if ($Newer -ne 'none') {
            $newerRun = Start-Limits $cell 'newer' $newerProfile $state
            $controls = @(@((Get-Content -Raw $newerRun.backupManifestPath | ConvertFrom-Json).snapshots)[-1].controlChanges | ForEach-Object { $_.control })
            if ((Read-Probe).priorityClass -ne 'Idle' -or ($controls -join ',') -ne 'priorityClass') { throw "The newer run didn't lower only CPU priority: $($controls -join ',')" }
            Break-Newer $Newer $newerRun
        }
        $cut = Invoke-CutRestore $cell $Fault $older $state
        $after = Get-AfterCut $Fault
        if ($blocked) { $after = @{ own = 'owned'; io = $lowered.io; memoryBack = $false } }
        $value = Read-Probe
        Case $cell ($value.io -eq $after.io) 'The cut Restore leaves I/O priority where that step leaves it' ("io " + $value.io)
        Case $cell ((Get-IoOwnership $older) -eq $after.own) 'The cut Restore saves I/O ownership as that step leaves it' (Get-IoOwnership $older)
        if ($Fault -in 'intent-save-fails', 'release-save-fails' -and -not $blocked) {
            Case $cell ((Get-Reasons $cut.result) -like ('*' + $texts.saveFailed + '*')) 'A save that fails stops Restore and says so' (Get-Reasons $cut.result)
        }

        $nextIo = switch ($Next) { 'nothing' { $after.io } 'other-value' { $otherIo } 'lowered-value' { $lowered.io } }
        if ($Next -ne 'nothing') { [RooIndustriesBackgroundOracle]::SetIo($script:probe, $nextIo) }

        # Status offers Restore for the older run only while it holds a value Restore can put back.
        $ioHolds = $after.own -eq 'owned' -and $nextIo -eq $lowered.io -and -not $blocked
        $memoryHolds = -not $after.memoryBack -and -not $blocked
        $status = Get-Status $cell 'status-before' $state
        if ($Newer -eq 'readable') {
            Case $cell ($status.restorable -and $status.sessionId -eq $newerRun.sessionId) 'Status offers the newer run that holds CPU priority first'
        } else {
            $holds = $ioHolds -or $memoryHolds
            Case $cell ((($status.restorable -and $status.sessionId -eq $older.sessionId)) -eq $holds) ('Status counts the older run as ' + $(if ($holds) { 'held' } else { 'not held' })) ([string]$status.sessionId)
        }
        if ($Newer -notin 'none', 'readable') {
            $named = @($status.unreadableRuns | Where-Object { $_.sessionId -eq $newerRun.sessionId -and $_.reason -eq $texts.unreadableRun })
            Case $cell ($named.Count -eq 1) 'Status names the newer run whose files can''t be read, in words that hold in every case' ((@($status.unreadableRuns) | ConvertTo-Json -Compress -Depth 5))
        }

        $second = Stop-Limits $cell 'second' $older $state
        $expected = Get-SecondIo $after.own $nextIo $Newer
        $value = Read-Probe
        Case $cell ($value.io -eq $expected.io) ('The next Restore leaves I/O priority at ' + $expected.io) ("io " + $value.io)
        Case $cell ((Get-IoOwnership $older) -eq $expected.own) ('The next Restore saves I/O ownership as ' + $expected.own) (Get-IoOwnership $older)
        $reasons = Get-Reasons $second
        if ($null -ne $expected.text) { Case $cell ($reasons -like ('*' + $expected.text + '*')) 'The card says why I/O priority was left alone' $reasons }
        if ($expected.leftAsSet) { Case $cell (@($second.leftAsSetItems | Where-Object { $_.control -eq 'ioPriority' -and [string]$_.currentValue -eq 'VeryLow' }).Count -eq 1) 'The card names the I/O priority another program set' $reasons }
        if (-not $blocked) { Case $cell ($value.memory -eq $original.memory) 'Memory priority comes back exactly' ("memory " + $value.memory) }
        else { Case $cell ($value.memory -eq $lowered.memory -and $value.priorityClass -eq 'Idle') 'Every setting of an app a newer unreadable run names is left alone' ($value | ConvertTo-Json -Compress) }
        switch ($Newer) {
            'none' { Case $cell ($value.priorityClass -eq $original.priorityClass) 'CPU priority comes back exactly' $value.priorityClass }
            'readable' { Case $cell ($value.priorityClass -eq 'Idle' -and $reasons -like ('*' + $texts.newerHolds + '*') -and (Get-PriorityOwnership $older) -eq 'owned') 'The newer run''s CPU priority is left for that run, and the older run keeps it' $reasons }
            default {
                if ($unknownSession) {
                    Case $cell ($value.priorityClass -eq 'Idle' -and (Get-PriorityOwnership $older) -eq 'owned' -and $reasons -like ('*' + $texts.unreadableNewer + '*')) 'An older run keeps CPU priority a newer unreadable run may have changed, and says why' $reasons
                }
            }
        }
        $status = Get-Status $cell 'status-after' $state
        if ($Newer -eq 'readable') {
            $undo = Stop-Limits $cell 'newer-undo' $newerRun $state
            $undo = Stop-Limits $cell 'older-again' $older $state
            Case $cell ((Read-Probe).priorityClass -eq $original.priorityClass) 'Restoring the newer run and then the older run puts CPU priority back exactly'
        } else {
            Case $cell (-not ($status.restorable -and $status.sessionId -eq $older.sessionId)) 'Afterwards status offers no Restore that can''t act' ([string]$status.sessionId)
        }
    } catch {
        Case $cell $false 'The cell ran' $_.Exception.Message
    } finally {
        if ($null -ne $script:workerOwned) { Stop-OwnedProcess $script:workerOwned; $script:workerOwned = $null }
        Stop-OwnershipProbe
    }
}

# Runs a Restore walk passes over must let go durably, so a later lowered value never becomes theirs again.
function Invoke-WalkCell([string]$Kind) {
    $cell = 'walk.' + $Kind
    if ($Only.Count -gt 0 -and -not @($Only | Where-Object { $cell -like $_ })) { return }
    # A short state folder keeps each run's saved files under the 260-character path limit of Windows PowerShell 5.1.
    $script:cellIndex++
    $state = Join-Path $directory ('s' + $script:cellIndex)
    $holderOwned = $null
    try {
        Start-OwnershipProbe
        $holder = $script:probe
        $holderOwned = $script:owned
        $older = Start-Limits $cell 'older' $olderProfile $state
        # The newer run finds the first probe already at its limits, so it lowers only the second probe.
        Start-OwnershipProbe
        $newer = Start-Limits $cell 'newer' $olderProfile $state
        $newerLowered = Read-Probe
        $snapshots = @((Get-Content -Raw $newer.backupManifestPath | ConvertFrom-Json).snapshots)
        if ($snapshots.Count -ne 1 -or $snapshots[0].processId -ne $script:probe.Id) { throw 'The newer run didn''t lower only the second probe' }
        if ($Kind -eq 'left-as-set') {
            $script:probe.PriorityClass = 'AboveNormal'; [RooIndustriesBackgroundOracle]::SetIo($script:probe, $otherIo); [RooIndustriesBackgroundOracle]::SetMemory($script:probe, 3)
        } else {
            $script:probe.PriorityClass = 'Normal'; [RooIndustriesBackgroundOracle]::SetIo($script:probe, 2); [RooIndustriesBackgroundOracle]::SetMemory($script:probe, 5)
        }
        $status = Get-Status $cell 'status-walk' $state
        Case $cell ($status.sessionId -eq $older.sessionId) 'Status passes over the newer run that holds nothing and offers the older run' ([string]$status.sessionId)
        $undo = Stop-Limits $cell 'undo-older' $older $state
        $script:probe.PriorityClass = $newerLowered.priorityClass; [RooIndustriesBackgroundOracle]::SetIo($script:probe, $newerLowered.io); [RooIndustriesBackgroundOracle]::SetMemory($script:probe, $newerLowered.memory)
        $status = Get-Status $cell 'status-after-walk' $state
        Case $cell (-not $status.restorable) 'After the walk, the passed-over run doesn''t take the lowered values another program set as its own' ([string]$status.sessionId)
        $backup = Get-Content -Raw $newer.backupManifestPath | ConvertFrom-Json
        $released = @(@($backup.snapshots)[-1].controlChanges | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.restoredAtUtc) })
        Case $cell ($released.Count -eq 3) 'The walk saved every setting of the passed-over run as let go' ([string]$released.Count)
        $undo = Stop-Limits $cell 'undo-newer' $newer $state
        $value = Read-Probe
        Case $cell ($value.priorityClass -eq $newerLowered.priorityClass -and $value.io -eq $newerLowered.io -and $value.memory -eq $newerLowered.memory) 'A Restore of that run leaves those values as the other program set them' ($value | ConvertTo-Json -Compress)
    } catch {
        Case $cell $false 'The cell ran' $_.Exception.Message
    } finally {
        if ($null -ne $holderOwned) { Stop-OwnedProcess $holderOwned }
        Stop-OwnershipProbe
    }
}

try {
    foreach ($newer in 'none', 'readable', 'unreadable-session', 'empty-backup') {
        foreach ($fault in 'none', 'intent-save-fails', 'kill-after-intent', 'kill-after-write', 'readback-fails', 'kill-after-readback', 'release-save-fails') {
            foreach ($next in 'nothing', 'other-value', 'lowered-value') { Invoke-Cell $fault $next $newer }
        }
    }
    Invoke-Cell 'original-then-lowered' 'nothing' 'none'
    foreach ($newer in 'empty-session', 'null-snapshots', 'object-snapshots', 'partial-backup') { Invoke-Cell 'none' 'nothing' $newer }
    Invoke-WalkCell 'left-as-set'
    Invoke-WalkCell 'already-original'
    $cells = @($results | Group-Object cell)
    $failedCells = @($cells | Where-Object { @($_.Group | Where-Object { -not $_.passed }).Count -gt 0 } | ForEach-Object { $_.Name })
    Save 'done' @{ passed = ($failures.Count -eq 0); cells = $cells.Count; failedCells = $failedCells; failures = @($failures) }
    [Console]::WriteLine("Cells: $($cells.Count), failed: $($failedCells.Count)")
    if ($failures.Count) { throw ('Background limits ownership checks failed in ' + $failedCells.Count + ' cell(s): ' + ($failedCells -join ', ')) }
} catch { Save 'failure' @{ error = $_.Exception.ToString(); stack = $_.ScriptStackTrace }; throw }
finally {
    Save 'results' @($results.ToArray())
    if ($null -ne $workerOwned) { Stop-OwnedProcess $workerOwned }
    Stop-OwnershipProbe
}
