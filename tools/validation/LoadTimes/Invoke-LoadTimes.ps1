param(
    [Parameter(Mandatory)][string]$Label,
    [string]$SetupPath,
    [string]$ExpectedSha256,
    [string]$OutRoot = (Join-Path $env:TEMP 'roo-industries-loadtimes'),
    [int]$ColdRuns = 3,
    [int]$Tours = 2,
    [int]$ColdTweaksRuns = 2,
    [int]$Minutes = 45,
    [switch]$SkipAdvanced,
    [ValidateSet('loadtimes', 'invalidation', 'modes', 'migration-before', 'migration-after', 'migration-undo-blocker', 'migration-timer-on', 'permissions', 'hardware', 'launchers', 'launchers-session', 'override', 'incomplete', 'incomplete-before')][string]$Scenario = 'loadtimes',
    [int]$MemoryPasses = 0,
    [string]$GcDump,
    [switch]$Uninstall,
    [switch]$ReplaceExisting,
    [switch]$KeepInstalled
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'LauncherChecks.Common.ps1')
. (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
$taskReceipt = $null
$script:ChildCompleted = $false
$script:PersistentResources = $null
$probeDirectory = $env:TEMP
$appDir = 'C:\Program Files\Roo Industries\Optimization Suite'
$exe = Join-Path $appDir 'app\RooIndustries.OptimizationSuite.App.exe'
$out = Join-Path $OutRoot $Label
if (@(Get-Process cs2 -ErrorAction SilentlyContinue).Count) { throw 'CS2 is running; refusing to measure.' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated session.' }
if (Test-Path -LiteralPath $out) { throw 'Output already exists; choose a fresh label to preserve previous evidence.' }
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Uninstall-App {
    $uninstaller = Get-ChildItem $appDir -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $uninstaller) { return 'not installed' }
    if (@(Get-Process RooIndustries.OptimizationSuite.*, Optimizer.Host, DismHost -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($appDir + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'CLEANUP NEEDED: installed processes remain; close them through their owner before uninstall.' }
    $p = Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    for ($i = 0; $i -lt 60 -and (Test-Path $exe); $i++) { Start-Sleep 1 }
    return "exit=$($p.ExitCode) remaining=$(Test-Path $exe)"
}

function Report-UnownedLoadTimesResources {
    $persistent = if ($script:ChildCompleted -and $script:PersistentResources -and $script:PersistentResources.scenario -ceq $Scenario -and $Scenario -in 'migration-before','migration-timer-on') { $script:PersistentResources } else { $null }
    foreach ($name in 'roo-industries-feature-hang.flag', 'RooIndustriesLoadTimesProbe.exe', 'RooIndustriesLauncherProbe.exe', 'RooIndustriesProtectedLauncherProbe.exe', 'RooIndustriesProtectedGameProbe.exe', 'RooIndustriesEnvironmentControl.exe') {
        $path = Join-Path $probeDirectory $name
        if (Test-Path -LiteralPath $path) { "RESULT CLEANUP NEEDED: retained child-owned or unowned file $path" }
    }
    if (Test-Path -LiteralPath $ifeoProbe) { "RESULT CLEANUP NEEDED: retained protected-session registry key $ifeoProbe for its journal owner" }
    foreach ($candidate in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' -or $_.TaskName -like 'Roo Industries Protected Session *' -or $_.TaskName -eq 'RooIndustries_EnvironmentControl' })) {
        $identity = $candidate.TaskPath + $candidate.TaskName
        if ($ruleTasksBefore -contains $identity -or $sessionTasksBefore -contains $identity) { continue }
        $expected = @($persistent.tasks | Where-Object { $_.name -ceq $candidate.TaskName -and $_.path -ceq $candidate.TaskPath })
        if ($expected.Count -eq 1) { try { Assert-OwnedTaskUnchanged $expected[0]; continue } catch {} }
        "RESULT CLEANUP NEEDED: retained task $identity without a matching completed-child receipt"
    }
    foreach ($process in @(Get-Process RooIndustries.OptimizationSuite.*, Optimizer.Host, DismHost -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($appDir + '\', [StringComparison]::OrdinalIgnoreCase) })) {
        $expected = @($persistent.processes | Where-Object { [int]$_.pid -eq $process.Id })
        if ($expected.Count -eq 1) { try { $handle=$process.Handle; if ([RooValidationOwnership.Native]::Created($handle).ToString() -ceq [string]$expected[0].creationTimeFileTimeUtc -and [RooValidationOwnership.Native]::Image($handle) -ieq $expected[0].imagePath) { continue } } catch {} }
        "RESULT CLEANUP NEEDED: retained installed process $($process.Id) without a matching completed-child receipt"
    }
}

if (@(Get-Process RooIndustries.OptimizationSuite.App -ErrorAction SilentlyContinue).Count) { throw 'The app is open; close it before measuring.' }
$installedBefore = Test-Path $exe
$ruleTasksBefore = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' } | ForEach-Object { $_.TaskPath + $_.TaskName })
$sessionTasksBefore = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Roo Industries Protected Session *' } | ForEach-Object { $_.TaskPath + $_.TaskName })
if ($SetupPath -and $installedBefore) { throw 'The app is already installed; no verified rollback installer was supplied, so replacement is refused.' }
$task = 'RooIndustries_LoadTimes'
$standalone = 'loadtimes', 'invalidation', 'modes', 'hardware', 'launchers', 'launchers-session', 'override', 'incomplete', 'incomplete-before'
$ifeoProbe = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProtectedGameProbe.exe'
try {
if ($SetupPath) {
    $hash = (Get-FileHash -LiteralPath $SetupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "RESULT setup sha256=$hash"
    if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Installer hash mismatch.' }
    if (Test-Path $exe) { "RESULT previous install removed: " + (Uninstall-App) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $SetupPath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $out 'install.log')`"" -Wait -PassThru
    "RESULT install exit=$($p.ExitCode) ms=$($sw.ElapsedMilliseconds)"
    Start-Sleep 3
    if (@(Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue).Count) { throw 'CLEANUP NEEDED: installer left an app open; close it through its owner.' }
}
if (-not (Test-Path $exe)) { throw 'The app is not installed.' }
"RESULT version=" + (Get-Item $exe).VersionInfo.ProductVersion

$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -ge 1 } | Select-Object -First 1
if (-not $explorer) { throw 'No interactive desktop session.' }
$sid = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid).Sid
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { throw 'A previous load-times task exists; recover it before starting this run.' }
$ps = Join-Path $PSHOME 'powershell.exe'
$scenarioScript = @{ invalidation = 'Test-CacheInvalidation.ps1'; modes = 'Test-ModesAndErrors.ps1'; 'migration-before' = 'Test-UpgradeMigration.ps1'; 'migration-after' = 'Test-UpgradeMigration.ps1'; 'migration-undo-blocker' = 'Test-UpgradeMigration.ps1'; 'migration-timer-on' = 'Test-UpgradeMigration.ps1'; permissions = 'Test-DataFolderPermissions.ps1'; hardware = 'Test-HardwareAge.ps1'; launchers = 'Test-ElevatedLaunchers.ps1'; 'launchers-session' = 'Test-ElevatedLaunchers.ps1'; override = 'Test-HelperStart.ps1'; incomplete = 'Test-HelperStart.ps1'; 'incomplete-before' = 'Test-HelperStart.ps1' }[$Scenario]
$scenarioExtra = @{ 'migration-before' = ' -Phase before'; 'migration-after' = ' -Phase after'; 'migration-undo-blocker' = ' -Phase undo-blocker'; 'migration-timer-on' = ' -Phase timer-on'; 'launchers-session' = ' -Part session'; override = ' -Check override'; incomplete = ' -Check incomplete'; 'incomplete-before' = ' -Check incomplete -Before' }[$Scenario]
$arguments = if ($scenarioScript) { '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $scenarioScript) + '" -OutDir "' + $out + '" -Exe "' + $exe + '"' + $scenarioExtra }
else { '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Measure-AppLoadTimes.ps1') + '" -Label "' + $Label + '" -OutDir "' + $out + '" -ColdRuns ' + $ColdRuns + ' -Tours ' + $Tours + ' -ColdTweaksRuns ' + $ColdTweaksRuns + ' -MemoryPasses ' + $MemoryPasses + $(if ($GcDump) { ' -GcDump "' + $GcDump + '"' } else { '' }) + ' -Exe "' + $exe + '"' + $(if ($SkipAdvanced) { ' -SkipAdvanced' } else { '' }) }
$taskReceipt = Register-OwnedProbeTask $task 'C:\Windows\System32\conhost.exe' $arguments $out $sid ($Minutes + 5)
Start-ScheduledTask -TaskName $task
$done = Join-Path $out $(if ($scenarioScript) { "$Scenario.done" } else { 'measure.done' })
$deadline = (Get-Date).AddMinutes($Minutes)
$started = Get-Date
while ((Get-Date) -lt $deadline -and -not (Test-Path $done)) {
    Start-Sleep 5
    Assert-OwnedTaskUnchanged $taskReceipt
    if (((Get-Date) - $started).TotalSeconds -gt 60 -and (Get-ScheduledTask -TaskName $task).State -ne 'Running' -and -not (Test-Path $done)) { "RESULT the scenario task ended without finishing"; break }
}
if (-not (Test-Path $done) -and (Get-Date) -ge $deadline) {
    "RESULT deadline passed; giving the scenario 5 more minutes to finish its cleanup"
    $grace = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $grace -and -not (Test-Path $done)) { Start-Sleep 5 }
}
$exitDeadline = (Get-Date).AddSeconds(30)
do {
    Assert-OwnedTaskUnchanged $taskReceipt
    $taskState = (Get-ScheduledTask -TaskName $taskReceipt.name -TaskPath $taskReceipt.path).State
    $info = Get-ScheduledTaskInfo -TaskName $taskReceipt.name -TaskPath $taskReceipt.path
    $active = $taskState -in 'Running','Queued' -or $info.LastTaskResult -eq 267009
    if (-not $active -or (Get-Date) -ge $exitDeadline) { break }
    Start-Sleep -Milliseconds 100
} while ($true)
$script:ChildCompleted = (Test-Path -LiteralPath $done) -and -not $active -and $info.LastTaskResult -eq 0
$persistentPath = Join-Path $out 'persistent-resources.json'
if ($script:ChildCompleted -and (Test-Path -LiteralPath $persistentPath)) { $script:PersistentResources = Get-Content -LiteralPath $persistentPath -Raw | ConvertFrom-Json }
"RESULT done=$(Test-Path $done) state=$taskState lastResult=$($info.LastTaskResult)"
if (-not $script:ChildCompleted) { throw 'The scenario did not finish with exit 0; child-owned resources are retained for recovery.' }
}
finally {
    function Step([string]$what, [scriptblock]$body) { try { & $body } catch { "RESULT CLEANUP NEEDED: $what failed: " + $_.Exception.Message } }
    Step 'remove the owned scheduled task' { Remove-OwnedTask $taskReceipt }
    Step 'report resources retained for their owner' { Report-UnownedLoadTimesResources }
    Step 'read the scenario log' {
        $log = Get-ChildItem $out -Filter '*.log' -ErrorAction SilentlyContinue | Select-String 'CLEANUP NEEDED' | ForEach-Object { $_.Line }
        foreach ($line in @($log)) { "RESULT $line" }
    }
    if ($Uninstall -or ($Scenario -in $standalone -and $SetupPath -and -not $installedBefore -and -not $KeepInstalled)) { Step 'uninstall the test build' { "RESULT uninstall " + (Uninstall-App) } }
}
"RESULT out=$out"
Get-Content (Join-Path $out $(if ($scenarioScript) { "$Scenario.log" } else { 'LOADTIMES.md' })) -ErrorAction SilentlyContinue
