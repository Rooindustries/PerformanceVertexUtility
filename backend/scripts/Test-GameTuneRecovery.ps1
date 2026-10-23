$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')
. (Join-Path $PSScriptRoot 'GameTuneSession.Common.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-tune-recovery-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$failures = New-Object System.Collections.Generic.List[string]
$owned = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$passes = 0
function Check([bool]$Ok, [string]$Message) {
    if ($Ok) { $script:passes++; Write-Host "PASS $Message" }
    else { $failures.Add($Message) | Out-Null; Write-Host "FAIL $Message" }
}
function Wait-For([scriptblock]$Probe) {
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    while ([datetime]::UtcNow -lt $deadline) { $value = & $Probe; if ($value) { return $value }; Start-Sleep -Milliseconds 100 }
    throw 'The disposable session did not reach its checkpoint.'
}
function Priority($Process) { $Process.Refresh(); return [string]$Process.PriorityClass }
function Probe([string]$Directory) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $exe = Join-Path $Directory 'RooIndustriesRecoveryProbe.exe'
    Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $exe
    $process = Start-Process $exe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 600' -WindowStyle Hidden -PassThru
    $owned.Add($process) | Out-Null
    Start-Sleep -Milliseconds 800
    $process.PriorityClass = 'Normal'
    return $process
}
function Interrupted([string]$Name, [switch]$AppOwner, [int]$Duration = 120) {
    $directory = Join-Path $root $Name
    $game = Probe $directory
    $profile = Join-Path $directory 'profile.json'
    $state = Join-Path $directory 'state'
    $reviewPath = Join-Path $directory 'review.json'
    $scripts = $PSScriptRoot.Replace("'", "''")
    $profileData = [pscustomobject]@{ schemaVersion = 1; profileId = 'recovery-probe'; name = 'Recovery probe'; profileKind = 'process-controls'; foregroundGame = @{ ruleId = 'recovery-game'; processNames = @('RooIndustriesRecoveryProbe.exe'); priorityClass = 'AboveNormal'; reason = 'Disposable recovery probe.' }; protectedCatalogPath = (Join-Path $PSScriptRoot '..\profiles\protected-processes.json'); targetGames = @(); rules = @(); safeCandidates = @(); protectedCompanions = @(); protectedPreviewProcessNames = @() }
    Write-RooIndustriesOperationJson $profileData $profile
    $review = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') -ProfilePath $profile -PollIntervalSeconds 1 -MaxDurationSeconds 1 | ConvertFrom-Json
    $reviewArgs = ''
    if ($null -ne $review.review) {
        Write-RooIndustriesOperationJson $review.review $reviewPath
        $reviewArgs = " -ReviewPath '$reviewPath' -ReviewSha256 '$((Get-FileHash $reviewPath).Hash)'"
    }
    $command = "& '$scripts\Start-GameTuneSession.ps1' -ProfilePath '$profile' -StateRoot '$state' -PollIntervalSeconds 1 -MaxDurationSeconds 120$reviewArgs -ConfirmApply"
    $appController = $null
    if ($AppOwner) {
        $appController = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-WindowStyle','Hidden','-Command','Start-Sleep -Seconds 600' -WindowStyle Hidden -PassThru
        $owned.Add($appController) | Out-Null
        $command += " -ControllerProcessId $($appController.Id) -ControllerStartTimeUtc '$($appController.StartTime.ToUniversalTime().ToString('o'))'"
    }
    $command = $command.Replace('-MaxDurationSeconds 120', "-MaxDurationSeconds $Duration")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $controller = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile','-EncodedCommand',$encoded -WindowStyle Hidden -PassThru
    $owned.Add($controller) | Out-Null
    $sessionPath = Wait-For { $path = Get-RooIndustriesGameTuneLatestSessionFile (Join-Path $state 'game-tune-sessions'); if ($path -and (Priority $game) -eq 'AboveNormal') { $path } }
    return [pscustomobject]@{ Game = $game; Controller = $controller; App = $appController; Path = $sessionPath; Directory = $directory }
}
function Status($Run, [switch]$Recover) {
    if ($Recover) { return (& (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1') -SessionPath $Run.Path -RecoverInterrupted | ConvertFrom-Json) }
    return (& (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1') -SessionPath $Run.Path | ConvertFrom-Json)
}
function Finish($Run) {
    Stop-RooIndustriesValidationProcess $Run.Controller
    Stop-RooIndustriesValidationProcess $Run.App
    $session = Read-RooIndustriesJsonFile $Run.Path
    if ($session.restorable) { & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $Run.Path -ConfirmApply | Out-Null }
    Stop-RooIndustriesValidationProcess $Run.Game
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Set-RooIndustriesValidationNormalPriority
    $run = Interrupted 'crash'
    $active = Status $run -Recover
    Check ($active.active -and (Priority $run.Game) -eq 'AboveNormal') 'A live controller remains active and tuned during recovery reads'
    $saved = Read-RooIndustriesJsonFile $run.Path
    Check ($saved.ownerProcessId -eq $run.Controller.Id -and $saved.ownerStartTimeUtc) 'The session records its controller identity before changing the probe'
    Stop-RooIndustriesValidationProcess $run.Controller
    $readOnly = Status $run
    Check ($readOnly.active -and (Priority $run.Game) -eq 'AboveNormal') 'A plain status read does not change process controls'
    $recovered = Status $run -Recover
    Check ($recovered.completed -and $recovered.recoveryPerformed -and -not $recovered.restorable -and (Priority $run.Game) -eq 'Normal') 'Restarting the app after a controller crash restores the original priority and reports changed readings'
    $bytes = [IO.File]::ReadAllBytes($run.Path)
    $again = Status $run -Recover
    Check ($again.completed -and -not $again.recoveryPerformed -and [Convert]::ToBase64String($bytes) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($run.Path))) 'Repeated app refreshes leave the recovered session and cached readings unchanged'
    Finish $run

    $run = Interrupted 'restarted-game'
    Stop-RooIndustriesValidationProcess $run.Controller
    Stop-RooIndustriesValidationProcess $run.Game
    $replacement = Probe (Join-Path $run.Directory 'replacement')
    $recovered = Status $run -Recover
    Check ($recovered.completed -and -not $recovered.restorable -and (Priority $replacement) -eq 'Normal') 'After all original processes end, recovery leaves a replacement game unchanged'
    Stop-RooIndustriesValidationProcess $replacement
    Finish $run

    $run = Interrupted 'foreign-value'
    Stop-RooIndustriesValidationProcess $run.Controller
    $run.Game.PriorityClass = 'High'
    $failed = Status $run -Recover
    Check ($failed.failed -and $failed.restorable -and (Priority $run.Game) -eq 'High' -and @($failed.errors | Where-Object code -eq 'GAME_TUNE_RECOVERY_NEEDS_ATTENTION').Count -eq 1) 'Recovery preserves another program value and retains the backup with a clear error'
    $run.Game.PriorityClass = 'AboveNormal'
    $again = Status $run -Recover
    Check ($again.failed -and (Priority $run.Game) -eq 'AboveNormal') 'A failed recovery does not retry on later refreshes'
    Finish $run

    $run = Interrupted 'owner-id-reused'
    Stop-RooIndustriesValidationProcess $run.Controller
    $session = Read-RooIndustriesJsonFile $run.Path
    $session | Add-Member ownerProcessId $PID -Force
    $session | Add-Member ownerStartTimeUtc ((Get-Process -Id $PID).StartTime.ToUniversalTime().AddSeconds(-30).ToString('o')) -Force
    Write-RooIndustriesOperationJson $session $run.Path
    $recovered = Status $run -Recover
    Check ($recovered.completed -and (Priority $run.Game) -eq 'Normal') 'A reused controller process ID cannot keep an interrupted session active'
    Finish $run

    $run = Interrupted 'missing-backup'
    Stop-RooIndustriesValidationProcess $run.Controller
    $session = Read-RooIndustriesJsonFile $run.Path
    $backupBytes = [IO.File]::ReadAllBytes($session.backupManifestPath)
    Remove-Item -LiteralPath $session.backupManifestPath
    $failed = Status $run -Recover
    Check ($failed.failed -and $failed.restorable -and (Priority $run.Game) -eq 'AboveNormal') 'A missing backup keeps the process unchanged and reports recovery attention'
    [IO.File]::WriteAllBytes($session.backupManifestPath, $backupBytes)
    Finish $run

    $run = Interrupted 'app-crash' -AppOwner
    Stop-RooIndustriesValidationProcess $run.App
    $exited = $run.Controller.WaitForExit(15000)
    $after = Status $run
    Check ($exited -and $after.completed -and -not $after.restorable -and (Priority $run.Game) -eq 'Normal') 'An app crash makes its live backend restore the game without another app launch'
    Finish $run

    $run = Interrupted 'backend-crash' -AppOwner
    Stop-RooIndustriesValidationProcess $run.Controller
    $recovered = Status $run -Recover
    Check ($recovered.completed -and -not $run.App.HasExited -and (Priority $run.Game) -eq 'Normal') 'An app refresh recovers a crashed backend even while the app owner is still alive'
    Finish $run

    $run = Interrupted 'completed-before-app-crash' -AppOwner -Duration 2
    $exited = $run.Controller.WaitForExit(15000)
    $before = Status $run -Recover
    Check ($exited -and $before.restorable -and (Priority $run.Game) -eq 'AboveNormal') 'A completed session keeps its Restore while its app is still open'
    Stop-RooIndustriesValidationProcess $run.App
    $recovered = Status $run -Recover
    Check ($recovered.completed -and $recovered.recoveryPerformed -and -not $recovered.restorable -and (Priority $run.Game) -eq 'Normal') 'Reopening the app also recovers a session that finished just before the app crashed and reports changed readings'
    Finish $run

    $run = Interrupted 'hidden-restore' -AppOwner -Duration 2
    Check ($run.Controller.WaitForExit(15000)) 'The first session completes before another Start'
    $profile = Join-Path $run.Directory 'profile.json'
    $state = Join-Path $run.Directory 'state'
    $reviewPath = Join-Path $run.Directory 'second-review.json'
    $review = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') -ProfilePath $profile -PollIntervalSeconds 1 -MaxDurationSeconds 1 | ConvertFrom-Json
    $arguments = @{}
    if ($null -ne $review.review) {
        Write-RooIndustriesOperationJson $review.review $reviewPath
        $arguments = @{ ReviewPath = $reviewPath; ReviewSha256 = (Get-FileHash $reviewPath).Hash }
    }
    $second = & (Join-Path $PSScriptRoot 'Start-GameTuneSession.ps1') -ProfilePath $profile -StateRoot $state -PollIntervalSeconds 1 -MaxDurationSeconds 1 -ControllerProcessId $run.App.Id -ControllerStartTimeUtc $run.App.StartTime.ToUniversalTime().ToString('o') @arguments -ConfirmApply | ConvertFrom-Json
    Check (-not $second.restorable -and $second.sessionPath -ne $run.Path) 'A second Start on the tuned game creates a separate empty session'
    $before = & (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1') -StateRoot $state -RecoverInterrupted | ConvertFrom-Json
    Check ($before.restorable -and $before.sessionPath -eq $run.Path) 'A newer empty session cannot hide the older Restore'
    Stop-RooIndustriesValidationProcess $run.App
    $after = & (Join-Path $PSScriptRoot 'Get-GameTuneSessionStatus.ps1') -StateRoot $state -RecoverInterrupted | ConvertFrom-Json
    $original = Status $run
    Check ($after.recoveryPerformed -and -not $original.restorable -and (Priority $run.Game) -eq 'Normal') 'Reopening recovers the older session behind the newer empty session'
    Finish $run

    $run = Interrupted 'unreadable-controller' -AppOwner -Duration 2
    Check ($run.Controller.WaitForExit(15000)) 'The controller identity fixture finishes tuning'
    Stop-RooIndustriesValidationProcess $run.App
    $session = Read-RooIndustriesJsonFile $run.Path
    $session.ownerStartTimeUtc = 'unreadable'
    Write-RooIndustriesOperationJson $session $run.Path
    $failed = Status $run -Recover
    Check ($failed.failed -and $failed.restorable -and (Priority $run.Game) -eq 'AboveNormal' -and @($failed.errors | Where-Object code -eq 'GAME_TUNE_RECOVERY_NEEDS_ATTENTION').Count -eq 1) 'An unreadable app controller keeps its backup and reports recovery attention'
    Finish $run

    $run = Interrupted 'unreadable-identity'
    Stop-RooIndustriesValidationProcess $run.Controller
    $session = Read-RooIndustriesJsonFile $run.Path
    $backupBytes = [IO.File]::ReadAllBytes($session.backupManifestPath)
    $backup = Read-RooIndustriesJsonFile $session.backupManifestPath
    foreach ($snapshot in @($backup.snapshots)) { $snapshot.processStartTimeUtc = $null }
    Write-RooIndustriesOperationJson $backup $session.backupManifestPath
    $failed = Status $run -Recover
    Check ($failed.failed -and $failed.restorable -and (Priority $run.Game) -eq 'AboveNormal') 'An unverified saved process identity keeps its value and backup'
    [IO.File]::WriteAllBytes($session.backupManifestPath, $backupBytes)
    Finish $run
} catch {
    $failures.Add($_.Exception.Message + ' :: ' + $_.ScriptStackTrace) | Out-Null
    Write-Host ('FAIL ' + $_.Exception.Message + ' :: ' + $_.ScriptStackTrace)
} finally {
    foreach ($process in $owned) { try { Stop-RooIndustriesValidationProcess $process } catch { $failures.Add($_.Exception.Message) | Out-Null } }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Host "Game Tune recovery: $passes passed, $($failures.Count) failed."
if ($failures.Count) { exit 1 }
