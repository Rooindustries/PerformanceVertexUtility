$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')
. (Join-Path $PSScriptRoot 'GameTuneSession.Common.ps1')

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
function Add-Check([bool]$Condition, [string]$Pass, [string]$Fail) {
    if ($Condition) { $passes.Add($Pass) | Out-Null; Write-Host "PASS $Pass" }
    else { $failures.Add($Fail) | Out-Null; Write-Host "FAIL $Fail" }
}

$suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
$gameA = "RooIndustriesTuneGameA$suffix.exe"
$gameB = "RooIndustriesTuneGameB$suffix.exe"
$helper = "RooIndustriesTuneHelper$suffix.exe"
$root = Join-Path ([IO.Path]::GetTempPath()) "roo-industries-game-tune-review-$suffix"
$probes = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$profilePath = Join-Path $root 'profile.json'
$hookPath = Join-Path $PSScriptRoot '..\test-hooks.enabled'
$hookToken = [guid]::NewGuid().ToString('N')
$hookOwned = $false

function Write-Profile([string]$GamePriority = 'AboveNormal') {
    $profile = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        profileId = 'game-tune-review-binding'
        name = 'Game Tune Review Binding'
        profileKind = 'process-controls'
        risk = 'medium'
        protectedCatalogPath = (Join-Path $repoRoot 'backend\profiles\protected-processes.json')
        foregroundGame = [pscustomobject]@{ ruleId = 'review-binding-game'; processNames = @($gameA, $gameB); priorityClass = $GamePriority; reason = 'Review binding probe game.'; reasonCodes = @('LIVE_VALIDATION') }
        targetGames = @()
        protectedCompanions = @()
        protectedPreviewProcessNames = @()
        safeCandidates = @()
        rules = @([pscustomobject]@{ ruleId = 'review-binding-helper'; enabled = $true; match = [pscustomobject]@{ processNames = @($helper) }; action = [pscustomobject]@{ actionType = 'setPriority'; priorityClass = 'BelowNormal'; reason = 'Review binding probe helper.' }; risk = 'low'; rollback = [pscustomobject]@{ restorePriorityClass = $true } })
    }
    [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Start-Probe([string]$Name, [string]$Folder = 'a') {
    $directory = Join-Path $root $Folder
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $exe = Join-Path $directory $Name
    if (-not (Test-Path -LiteralPath $exe)) { Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $exe }
    $process = Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', 'Start-Sleep -Seconds 300' -WindowStyle Hidden -PassThru
    $probes.Add($process) | Out-Null
    Start-Sleep -Milliseconds 800
    $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    return $process
}

function Stop-Probe([System.Diagnostics.Process]$Process) {
    Stop-RooIndustriesValidationProcess $Process
}

function Get-Priority([System.Diagnostics.Process]$Process) {
    $Process.Refresh()
    return [string]$Process.PriorityClass
}

function Invoke-Review([string]$Name) {
    $dry = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') -ProfilePath $profilePath -PollIntervalSeconds 1 -MaxDurationSeconds 1 | ConvertFrom-Json
    $path = Join-Path $root "$Name-review.json"
    $data = $dry.review
    if ($null -eq $data) {
        $preview = & (Join-Path $PSScriptRoot 'Preview-ProcessProfile.ps1') -ProfilePath $profilePath | ConvertFrom-Json
        $data = [pscustomobject]@{ schemaVersion = 1; kind = 'game-tune-review'; profileId = $preview.profileId; profilePath = $profilePath; profileSha256 = (Get-FileHash $profilePath).Hash; targetGameProcessName = $null; entries = @($preview.preview | Where-Object { $_.classification -eq 'gameTarget' -or @($_.controlChanges).Count -gt 0 }) }
    }
    Write-RooIndustriesOperationJson $data $path
    return [pscustomobject]@{ Envelope = $dry; Path = $path; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}

function Invoke-Start([object]$Review, [string]$Name, [string]$Sha256 = $Review.Sha256) {
    $state = Join-Path $root "$Name-state"
    $result = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') -ProfilePath $profilePath -PollIntervalSeconds 1 -MaxDurationSeconds 2 -StateRoot $state -ReviewPath $Review.Path -ReviewSha256 $Sha256 -ConfirmApply | ConvertFrom-Json
    return [pscustomobject]@{ Envelope = $result; StateRoot = $state }
}

function Test-Refused([object]$Start, [string]$Code, [string]$Label) {
    $envelope = $Start.Envelope
    Add-Check ($envelope.status -eq 'refused' -and $envelope.dryRun -eq $false -and @($envelope.errors).Count -eq 1 -and $envelope.errors[0].code -eq $Code -and @($envelope.changedItems).Count -eq 0 -and $envelope.restorable -eq $false -and $null -eq $envelope.sessionPath -and -not (Test-Path -LiteralPath $Start.StateRoot)) `
        "$Label refuses with $Code and writes no session" `
        "$Label did not refuse cleanly: status $($envelope.status), code $(@($envelope.errors | ForEach-Object { $_.code }) -join ','), changed $(@($envelope.changedItems).Count), state $(Test-Path -LiteralPath $Start.StateRoot)"
    if ($envelope.restorable -and $envelope.sessionPath) {
        $undo = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $envelope.sessionPath -ConfirmApply | ConvertFrom-Json
        Add-Check (-not $undo.restorable) "$Label cleans up the unexpected apply" "$Label left changes after Stop"
    }
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Set-RooIndustriesValidationNormalPriority
    Write-Profile

    $a = Start-Probe $gameA
    $kept = Start-Probe $helper
    $closed = Start-Probe $helper 'b'
    $review = Invoke-Review 'bound'
    $reviewed = @($review.Envelope.review.entries)
    Add-Check ($review.Envelope.dryRun -eq $true -and @($reviewed | Where-Object { $_.processId -eq $a.Id -and $_.classification -eq 'gameTarget' -and $_.processStartTimeUtc }).Count -eq 1 -and @($reviewed | Where-Object { $_.processId -in @($kept.Id, $closed.Id) }).Count -eq 2 -and (Get-Priority $a) -eq 'Normal') `
        'Review records game A and both helpers with their start times and changes nothing' `
        "Review did not record the expected plan: $(@($reviewed | ForEach-Object { "$($_.processName):$($_.processId)" }) -join ', ')"
    Add-Check (@($review.Envelope.preview | Where-Object { $_.processId -eq $a.Id }).Count -eq 1) 'Review shows the plan it records' 'Review envelope has no preview entry for game A'

    Stop-Probe $closed
    $b = Start-Probe $gameB
    $late = Start-Probe $helper 'c'
    $bound = Invoke-Start $review 'bound'
    $after = @{ a = Get-Priority $a; kept = Get-Priority $kept; b = Get-Priority $b; late = Get-Priority $late }
    Add-Check ($bound.Envelope.status -eq 'completed' -and $bound.Envelope.restorable -eq $true -and $after.a -eq 'AboveNormal' -and $after.kept -eq 'BelowNormal') `
        'Start tunes the reviewed game and the reviewed helper that is still running' `
        "Start did not tune the reviewed plan: status $($bound.Envelope.status), A $($after.a), helper $($after.kept)"
    Add-Check ($after.b -eq 'Normal' -and $after.late -eq 'Normal' -and @($bound.Envelope.changedItems | Where-Object { $_.processId -in @($b.Id, $late.Id) }).Count -eq 0) `
        'Start leaves game B and a helper started after the review unchanged across every poll' `
        "Start tuned an app that was not reviewed: B $($after.b), late helper $($after.late)"

    $stop = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $bound.Envelope.sessionPath -ConfirmApply | ConvertFrom-Json
    Add-Check ($stop.status -eq 'completed' -and (Get-Priority $a) -eq 'Normal' -and (Get-Priority $kept) -eq 'Normal' -and (Get-Priority $b) -eq 'Normal' -and (Get-Priority $late) -eq 'Normal') `
        'Stop puts back exactly what the bound Start changed' `
        "Stop did not restore the bound session: status $($stop.status), A $(Get-Priority $a), helper $(Get-Priority $kept)"
    foreach ($probe in @($b, $late, $kept)) { Stop-Probe $probe }

    $review = Invoke-Review 'gone'
    Stop-Probe $a
    $b = Start-Probe $gameB
    Test-Refused (Invoke-Start $review 'gone') 'GAME_TUNE_REVIEWED_GAME_GONE' 'Start after game A closed and game B opened'
    Add-Check ((Get-Priority $b) -eq 'Normal') 'Game B stays unchanged when the reviewed game is gone' "Game B changed to $(Get-Priority $b)"
    Stop-Probe $b

    $a = Start-Probe $gameA
    $review = Invoke-Review 'restart'
    Stop-Probe $a
    $a = Start-Probe $gameA
    Test-Refused (Invoke-Start $review 'restart') 'GAME_TUNE_REVIEWED_GAME_GONE' 'Start after game A restarted with a new process ID'
    Add-Check ((Get-Priority $a) -eq 'Normal') 'The restarted game stays unchanged' "The restarted game changed to $(Get-Priority $a)"

    $review = Invoke-Review 'reused'
    $data = Get-Content -LiteralPath $review.Path -Raw | ConvertFrom-Json
    foreach ($entry in @($data.entries | Where-Object { $_.processId -eq $a.Id })) { $entry.processStartTimeUtc = ([datetime]::Parse([string]$entry.processStartTimeUtc).ToUniversalTime().AddSeconds(-30)).ToString('o') }
    Write-RooIndustriesOperationJson $data $review.Path
    $reused = [pscustomobject]@{ Path = $review.Path; Sha256 = (Get-FileHash -LiteralPath $review.Path -Algorithm SHA256).Hash }
    Test-Refused (Invoke-Start $reused 'reused') 'GAME_TUNE_REVIEWED_GAME_GONE' 'Start when the reviewed process ID now belongs to a different start time'
    Add-Check ((Get-Priority $a) -eq 'Normal') 'A reused process ID stays unchanged' "A reused process ID changed to $(Get-Priority $a)"

    $review = Invoke-Review 'drift'
    $a.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
    Test-Refused (Invoke-Start $review 'drift') 'GAME_TUNE_REVIEW_PLAN_CHANGED' 'Start after another program changed game A priority'
    Add-Check ((Get-Priority $a) -eq 'High') 'The other program value stays in place' "Game A priority changed to $(Get-Priority $a)"
    $a.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal

    $review = Invoke-Review 'profile'
    Write-Profile 'High'
    Test-Refused (Invoke-Start $review 'profile') 'GAME_TUNE_REVIEW_PLAN_CHANGED' 'Start after the profile changed'
    Add-Check ((Get-Priority $a) -eq 'Normal') 'Game A stays unchanged after a profile change' "Game A changed to $(Get-Priority $a) after a profile change"
    Write-Profile

    $review = Invoke-Review 'edited'
    $data = Get-Content -LiteralPath $review.Path -Raw | ConvertFrom-Json
    foreach ($change in @($data.entries | ForEach-Object { $_.controlChanges })) { if ($change.control -eq 'priorityClass') { $change.proposedValue = 'High' } }
    Write-RooIndustriesOperationJson $data $review.Path
    Test-Refused (Invoke-Start $review 'edited') 'GAME_TUNE_REVIEW_OUT_OF_DATE' 'Start with a review file edited after it was saved'
    Test-Refused (Invoke-Start $review 'unhashed' '') 'GAME_TUNE_REVIEW_OUT_OF_DATE' 'Start with a review but no hash'
    Add-Check ((Get-Priority $a) -eq 'Normal') 'Game A stays unchanged after an edited review' "Game A changed to $(Get-Priority $a) after an edited review"
    Stop-Probe $a

    $kept = Start-Probe $helper
    $review = Invoke-Review 'nogame'
    Test-Refused (Invoke-Start $review 'nogame') 'GAME_TUNE_REVIEW_NO_GAME' 'Start with a review taken while no game ran'
    Add-Check ((Get-Priority $kept) -eq 'Normal') 'A reviewed helper stays unchanged when no game was reviewed' "The helper changed to $(Get-Priority $kept)"
    Stop-Probe $kept

    foreach ($race in @('gate-race', 'setter-race')) {
        $a = Start-Probe $gameA
        $review = Invoke-Review $race
        $stateRoot = Join-Path $root "$race-state"
        $output = Join-Path $root "$race-result.json"
        $gate = $null
        if ($race -eq 'gate-race') { $gate = Enter-RooIndustriesGovernorGate; if ($null -eq $gate) { throw 'The test could not claim its gate checkpoint.' } }
        else {
            $stream = [IO.File]::Open($hookPath, [IO.FileMode]::CreateNew)
            $stream.Dispose()
            $hookOwned = $true
            [IO.File]::WriteAllText($hookPath, $hookToken)
            $pauseRoot = Join-Path $stateRoot 'game-tune-sessions'
            New-Item -ItemType Directory -Path $pauseRoot -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $pauseRoot 'test-pause-ms.txt'), '5000')
        }
        try {
            $command = "& '$PSScriptRoot\Start-GameTuneSession.ps1' -ProfilePath '$profilePath' -StateRoot '$stateRoot' -ReviewPath '$($review.Path)' -ReviewSha256 '$($review.Sha256)' -PollIntervalSeconds 1 -MaxDurationSeconds 1 -OutputPath '$output' -ConfirmApply"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $worker = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-EncodedCommand',$encoded -WindowStyle Hidden -PassThru
            $probes.Add($worker) | Out-Null
            $checkpoint = if ($race -eq 'gate-race') { 'session.json' } else { 'backup.json' }
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            do {
                $found = @(Get-ChildItem -LiteralPath $stateRoot -Filter $checkpoint -File -Recurse -ErrorAction SilentlyContinue)
                if ($found.Count) { break }
                Start-Sleep -Milliseconds 50
            } while ([datetime]::UtcNow -lt $deadline -and -not $worker.HasExited)
            if (-not $found.Count) { throw "The $race fixture did not reach $checkpoint." }
            $a.PriorityClass = 'BelowNormal'
        } finally { Exit-RooIndustriesGovernorGate $gate }
        if (-not $worker.WaitForExit(45000)) { throw "The $race worker did not finish." }
        $result = Read-RooIndustriesJsonFile $output
        Add-Check ((Get-Priority $a) -eq 'BelowNormal' -and @($result.changedItems).Count -eq 0 -and $result.status -eq 'failed' -and @($result.errors | Where-Object code -eq 'GAME_TUNE_REVIEW_PLAN_CHANGED').Count -eq 1) `
            "$race preserves the value changed after validation and reports a stale review" "$race overwrote an unreviewed current value or hid the refusal"
        if ($result.restorable) {
            & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $result.sessionPath -ConfirmApply | Out-Null
            Add-Check ((Get-Priority $a) -eq 'BelowNormal') "$race Stop leaves the control we never wrote" "$race Stop overwrote an unwritten control"
        }
        if ($hookOwned -and [IO.File]::ReadAllText($hookPath) -eq $hookToken) { Remove-Item -LiteralPath $hookPath; $hookOwned = $false }
        Stop-Probe $a
    }
} catch {
    $failures.Add("Game Tune review binding validation failed: $($_.Exception.Message)") | Out-Null
} finally {
    if ($hookOwned -and (Test-Path -LiteralPath $hookPath) -and [IO.File]::ReadAllText($hookPath) -eq $hookToken) { Remove-Item -LiteralPath $hookPath }
    foreach ($probe in $probes) { try { Stop-Probe $probe } catch { $failures.Add("Probe cleanup failed: $($_.Exception.Message)") | Out-Null } }
    $fullRoot = [IO.Path]::GetFullPath($root)
    if ($fullRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullRoot)) { Remove-Item -LiteralPath $fullRoot -Recurse -Force }
    if (Test-Path -LiteralPath $fullRoot) { $failures.Add("Game Tune review binding left its fixture directory: $fullRoot") | Out-Null }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Game Tune review binding validation completed. $($passes.Count) checks passed."
    exit 0
}
Write-Host "FAIL Game Tune review binding validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
