param([switch]$InMemory, [string]$OutRoot = '')

$ErrorActionPreference = 'Stop'
if ($InMemory) {
    $source = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    if ([string]::IsNullOrWhiteSpace($OutRoot)) { $OutRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-game-tune-ownership-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
    & (Join-Path $source 'tools/validation/GameTune/Test-GameTuneRecoveryOwnership.ps1') -Source $source -Out $OutRoot
    exit $LASTEXITCODE
}
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
function Interrupted([string]$Name, [switch]$AppOwner, [int]$Duration = 120, [switch]$Pair) {
    $directory = Join-Path $root $Name
    $game = Probe $directory
    $peer = if ($Pair) { Probe (Join-Path $directory 'peer') } else { $null }
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
    $sessionPath = Wait-For { $path = Get-RooIndustriesGameTuneLatestSessionFile (Join-Path $state 'game-tune-sessions'); if ($path -and (Priority $game) -eq 'AboveNormal' -and (-not $peer -or (Priority $peer) -eq 'AboveNormal')) { $path } }
    Wait-For { try { $backup = [string](Read-RooIndustriesJsonFile $sessionPath).backupManifestPath; $backup -and (Test-Path -LiteralPath $backup) -and @((Read-RooIndustriesJsonFile $backup).snapshots | ForEach-Object { $_.controlChanges } | Where-Object outcome -eq 'applied').Count -ge $(if ($Pair) { 2 } else { 1 }) } catch { $false } } | Out-Null
    return [pscustomobject]@{ Game = $game; Peer = $peer; Controller = $controller; App = $appController; Path = $sessionPath; Directory = $directory }
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
    Stop-RooIndustriesValidationProcess $Run.Peer
}
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
public static class RooIndustriesRecoveryAccessFixture {
    [StructLayout(LayoutKind.Sequential, Pack=4)] private struct Privilege { public int Count; public long Luid; public int Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool LookupPrivilegeValueW(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref Privilege state, int length, ref Privilege previous, out int returned);
    [DllImport("advapi32.dll")] private static extern uint SetSecurityInfo(IntPtr handle, int type, uint information, IntPtr owner, IntPtr group, byte[] dacl, IntPtr sacl);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    public static void Grant(IntPtr process, int access) {
        RawAcl acl = new RawAcl(2, 1);
        acl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, access, new SecurityIdentifier(WellKnownSidType.WorldSid, null), false, null));
        byte[] dacl = new byte[acl.BinaryLength];
        acl.GetBinaryForm(dacl, 0);
        uint error = SetSecurityInfo(process, 6, 4, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
        if (error != 0) throw new Win32Exception((int)error);
    }
    public static bool SetDebug(bool enabled) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            Privilege state = new Privilege { Count = 1, Attributes = enabled ? 2 : 0 }, previous = new Privilege();
            if (!LookupPrivilegeValueW(null, "SeDebugPrivilege", out state.Luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            int returned;
            if (!AdjustTokenPrivileges(token, false, ref state, Marshal.SizeOf(typeof(Privilege)), ref previous, out returned)) throw new Win32Exception(Marshal.GetLastWin32Error());
            int error = Marshal.GetLastWin32Error();
            if (error == 1300) return false;
            if (error != 0) throw new Win32Exception(error);
            return previous.Count == 0 ? enabled : (previous.Attributes & 2) != 0;
        } finally { CloseHandle(token); }
    }
}
'@
$unprovenShown = 'Restore couldn''t confirm it set this value, so it was left alone. It resets when that app restarts; then Restore again.'
$foreignShown = 'Another program changed it, so recovery left it alone and kept the backup. Restore keeps that program''s value and finishes.'
$unreadableShown = 'Windows couldn''t read it, so recovery left it alone and kept the backup. Restore stays available; try it again later.'
function Edit-Backup($Run, [scriptblock]$Edit) {
    $path = [string](Read-RooIndustriesJsonFile $Run.Path).backupManifestPath
    $backup = Read-RooIndustriesJsonFile $path
    & $Edit $backup
    Write-RooIndustriesGameTuneJsonFile $backup $path
    return $backup
}
function Read-Control($Process, [string]$Control) { return Get-RooIndustriesProcessControlReadback $Process $Control }
function Get-SavedOriginal($Run, [string]$Control) {
    $snapshot = (Read-RooIndustriesJsonFile (Read-RooIndustriesJsonFile $Run.Path).backupManifestPath).snapshots[0]
    $saved = Get-RooIndustriesPropertyValue $snapshot ('original' + $Control.Substring(0, 1).ToUpperInvariant() + $Control.Substring(1)) $null
    if ($null -ne $saved) { return $saved }
    return Read-Control $Run.Game $Control
}
function Write-Control($Process, [string]$Control, $Value) { Invoke-RooIndustriesProcessControlChange $Process ([pscustomobject]@{ control = $Control; proposedValue = $Value; action = 'set' }) }
function Pick($Values, $Except) { return @($Values | Where-Object { [string]$_ -notin @($Except | ForEach-Object { [string]$_ }) }) }
function Add-Change($Snapshot, [string]$Control, $Original, $Proposed, [string]$Outcome) {
    $suffix = $Control.Substring(0, 1).ToUpperInvariant() + $Control.Substring(1)
    $Snapshot | Add-Member ('original' + $suffix) $Original -Force
    $Snapshot.controlChanges = @($Snapshot.controlChanges | Where-Object { $_.control -ne $Control }) + @([pscustomobject]@{ control = $Control; currentValue = $Original; proposedValue = $Proposed; action = 'set' + $suffix; reason = 'Disposable recovery probe.'; blocked = $false; blockedReason = $null; outcome = $Outcome })
}
function Get-RecoveryMessage($Result) { return [string]@($Result.errors | Where-Object code -eq 'GAME_TUNE_RECOVERY_NEEDS_ATTENTION')[-1].message }
function Get-PreviewChange($Run, [string]$Control) {
    $preview = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $Run.Path | ConvertFrom-Json
    return @($preview.preview | ForEach-Object { $_.controlChanges } | Where-Object control -eq $Control)
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
    $game = [string](Read-RooIndustriesJsonFile (Read-RooIndustriesJsonFile $run.Path).backupManifestPath).snapshots[0].processName
    $foreign = 'Another program changed it, so recovery left it alone and kept the backup. Restore keeps that program''s value and finishes.'
    Check ([string]@($failed.errors | Where-Object code -eq 'GAME_TUNE_RECOVERY_NEEDS_ATTENTION')[0].message -ceq ('CPU priority for ' + $game + ': ' + $foreign) -and @($failed.skippedItems).Count -eq 1 -and [string]$failed.skippedItems[0].reason -ceq ('priorityClass: ' + $foreign)) 'Recovery names the setting another program holds and what Restore does next'
    $run.Game.PriorityClass = 'AboveNormal'
    $again = Status $run -Recover
    Check ($again.failed -and (Priority $run.Game) -eq 'AboveNormal') 'A failed recovery does not retry on later refreshes'
    Finish $run

    $run = Interrupted 'pending-foreign'
    Stop-RooIndustriesValidationProcess $run.Controller
    $gpuOriginal = Get-SavedOriginal $run 'gpuPriority'
    $memoryOriginal = Get-SavedOriginal $run 'memoryPriority'
    $gpu = Pick @('BelowNormal', 'AboveNormal', 'Idle') @($gpuOriginal, (Read-Control $run.Game 'gpuPriority'))
    $memory = Pick @(3, 2, 4, 1) @($memoryOriginal, (Read-Control $run.Game 'memoryPriority'))
    $backup = Edit-Backup $run {
        param($Backup)
        foreach ($change in @($Backup.snapshots | ForEach-Object { $_.controlChanges })) { $change.outcome = 'pending' }
        Add-Change $Backup.snapshots[0] 'gpuPriority' $gpuOriginal $gpu[0] 'pending'
        Add-Change $Backup.snapshots[0] 'memoryPriority' $memoryOriginal $memory[0] 'pending'
    }
    Write-Control $run.Game 'priorityClass' 'High'
    Write-Control $run.Game 'gpuPriority' $gpu[1]
    Write-Control $run.Game 'memoryPriority' $memory[1]
    $held = { (Priority $run.Game) -eq 'High' -and (Read-Control $run.Game 'gpuPriority') -eq $gpu[1] -and (Read-Control $run.Game 'memoryPriority') -eq $memory[1] }
    $blocked = @('priorityClass', 'gpuPriority', 'memoryPriority' | Where-Object { $change = @(Get-PreviewChange $run $_); $change.Count -eq 1 -and $change[0].blocked -and [string]$change[0].blockedReason -ceq $script:RooIndustriesUnprovenWrite })
    Check ($blocked.Count -eq 3 -and (& $held) -and (Read-RooIndustriesJsonFile $run.Path).restorable) 'Restore preview blocks each pending setting another program holds, writes nothing and keeps Restore'
    $failed = Status $run -Recover
    $game = [string]$backup.snapshots[0].processName
    $named = 'CPU priority for ' + $game + ': ' + $unprovenShown + ' GPU priority for ' + $game + ': ' + $unprovenShown + ' Memory priority for ' + $game + ': ' + $unprovenShown
    $reason = (@('priorityClass', 'gpuPriority', 'memoryPriority') | ForEach-Object { $_ + ': ' + $script:RooIndustriesUnprovenWrite }) -join '; '
    Check ($failed.failed -and $failed.restorable -and (& $held) -and (Get-RecoveryMessage $failed) -ceq $named -and @($failed.skippedItems).Count -eq 1 -and [string]$failed.skippedItems[0].reason -ceq $reason) "Recovery names every pending setting another program holds and writes none of them: $(Get-RecoveryMessage $failed)"
    $again = Status $run -Recover
    Check ($again.failed -and $again.restorable -and (& $held)) 'A refused pending recovery does not retry on later refreshes'
    Finish $run

    $run = Interrupted 'failed-write-foreign'
    Stop-RooIndustriesValidationProcess $run.Controller
    $gpuOriginal = Get-SavedOriginal $run 'gpuPriority'
    $gpu = Pick @('AboveNormal', 'BelowNormal', 'Idle') @($gpuOriginal, (Read-Control $run.Game 'gpuPriority'))
    Write-Control $run.Game 'gpuPriority' $gpu[0]
    $backup = Edit-Backup $run {
        param($Backup)
        foreach ($change in @($Backup.snapshots | ForEach-Object { $_.controlChanges } | Where-Object control -eq 'priorityClass')) { $change.outcome = 'failed' }
        Add-Change $Backup.snapshots[0] 'gpuPriority' $gpuOriginal $gpu[0] 'applied'
    }
    Write-Control $run.Game 'priorityClass' 'High'
    $change = @(Get-PreviewChange $run 'priorityClass')
    Check ($change.Count -eq 1 -and $change[0].blocked -and [string]$change[0].blockedReason -ceq $script:RooIndustriesUnprovenWrite -and (Priority $run.Game) -eq 'High' -and (Read-Control $run.Game 'gpuPriority') -eq $gpu[0]) 'Restore preview blocks a failed write another program now holds and writes nothing'
    $failed = Status $run -Recover
    $game = [string]$backup.snapshots[0].processName
    Check ($failed.failed -and $failed.restorable -and (Priority $run.Game) -eq 'High' -and (Read-Control $run.Game 'gpuPriority') -eq $gpuOriginal -and (Get-RecoveryMessage $failed) -ceq ('The interrupted session could not be fully restored. Its backup was kept. CPU priority for ' + $game + ': ' + $unprovenShown)) "Recovery restores the confirmed setting, keeps the failed write another program holds and names it: $(Get-RecoveryMessage $failed)"
    Finish $run

    $run = Interrupted 'unreadable-confirmed'
    Stop-RooIndustriesValidationProcess $run.Controller
    $gpuOriginal = Get-SavedOriginal $run 'gpuPriority'
    $gpu = Pick @('AboveNormal', 'BelowNormal', 'Idle') @($gpuOriginal, (Read-Control $run.Game 'gpuPriority'))
    Write-Control $run.Game 'gpuPriority' $gpu[0]
    $backup = Edit-Backup $run { param($Backup) Add-Change $Backup.snapshots[0] 'gpuPriority' $gpuOriginal $gpu[0] 'applied' }
    $debug = [RooIndustriesRecoveryAccessFixture]::SetDebug($false)
    try {
        [RooIndustriesRecoveryAccessFixture]::Grant($run.Game.Handle, 0x1FFFFF -band -bnot 0x200)
        $denied = try { -not (Get-RooIndustriesProcessGpuPriority $run.Game -ForControl).available } catch { $true }
        Check ($denied -and (Priority $run.Game) -eq 'AboveNormal') 'The probe denies the GPU priority read while its identity and CPU priority stay readable'
        $failed = Status $run -Recover
    } finally {
        [RooIndustriesRecoveryAccessFixture]::Grant($run.Game.Handle, 0x1FFFFF)
        [RooIndustriesRecoveryAccessFixture]::SetDebug($debug) | Out-Null
    }
    $game = [string]$backup.snapshots[0].processName
    Check ($failed.failed -and $failed.restorable -and (Priority $run.Game) -eq 'AboveNormal' -and (Read-Control $run.Game 'gpuPriority') -eq $gpu[0] -and (Get-RecoveryMessage $failed) -ceq ('GPU priority for ' + $game + ': ' + $unreadableShown) -and @($failed.skippedItems).Count -eq 1 -and [string]$failed.skippedItems[0].reason -ceq ('gpuPriority: ' + $script:RooIndustriesRecoveryUnreadable)) "Recovery says a confirmed setting Windows couldn't read was left alone and Restore stays available: $(Get-RecoveryMessage $failed)"
    $restored = & (Join-Path $PSScriptRoot 'Stop-GameTuneSession.ps1') -SessionPath $run.Path -ConfirmApply | ConvertFrom-Json
    Check (-not $restored.restorable -and (Priority $run.Game) -eq 'Normal' -and (Read-Control $run.Game 'gpuPriority') -eq $gpuOriginal) 'Once Windows can read it again, Restore puts back both original values'
    Finish $run

    $run = Interrupted 'held-then-unverified' -Pair
    Stop-RooIndustriesValidationProcess $run.Controller
    $backup = Edit-Backup $run { param($Backup) $Backup.snapshots[1].processStartTimeUtc = $null }
    $first = if ($backup.snapshots[0].processId -eq $run.Game.Id) { $run.Game } else { $run.Peer }
    $second = if ($first -eq $run.Game) { $run.Peer } else { $run.Game }
    Write-Control $first 'priorityClass' 'High'
    $failed = Status $run -Recover
    $named = 'CPU priority for ' + [string]$backup.snapshots[0].processName + ': ' + $foreignShown + ' A saved app identity could not be checked. Its values were kept.'
    Check ($failed.failed -and $failed.restorable -and (Priority $first) -eq 'High' -and (Priority $second) -eq 'AboveNormal' -and (Get-RecoveryMessage $failed) -ceq $named -and @($failed.skippedItems).Count -eq 1 -and [int]$failed.skippedItems[0].processId -eq $first.Id -and [string]$failed.skippedItems[0].reason -ceq ('priorityClass: ' + $script:RooIndustriesRecoveryLeftForeign)) "Recovery keeps the held setting's name when a later app can't be checked and reports both: $(Get-RecoveryMessage $failed)"
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
    Check ($second.status -eq 'completed' -and -not $second.restorable -and -not [string]::IsNullOrWhiteSpace($second.sessionPath) -and (Test-Path -LiteralPath $second.sessionPath -PathType Leaf) -and $second.sessionPath -ne $run.Path) 'A second Start on the tuned game creates a separate empty session'
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
