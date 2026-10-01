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
    [ValidateSet('loadtimes', 'invalidation', 'modes', 'migration-before', 'migration-after', 'permissions', 'hardware', 'launchers', 'override', 'incomplete', 'incomplete-before')][string]$Scenario = 'loadtimes',
    [int]$MemoryPasses = 0,
    [string]$GcDump,
    [switch]$Uninstall,
    [switch]$ReplaceExisting,
    [switch]$KeepInstalled
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$appDir = 'C:\Program Files\Roo Industries\Optimization Suite'
$exe = Join-Path $appDir 'app\RooIndustries.OptimizationSuite.App.exe'
$out = Join-Path $OutRoot $Label
if (@(Get-Process cs2 -ErrorAction SilentlyContinue).Count) { throw 'CS2 is running; refusing to measure.' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated session.' }
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Uninstall-App {
    $uninstaller = Get-ChildItem $appDir -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $uninstaller) { return 'not installed' }
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    for ($i = 0; $i -lt 60 -and (Test-Path $exe); $i++) { Start-Sleep 1 }
    return "exit=$($p.ExitCode) remaining=$(Test-Path $exe)"
}

if (@(Get-Process RooIndustries.OptimizationSuite.App -ErrorAction SilentlyContinue).Count) { throw 'The app is open; close it before measuring.' }
$installedBefore = Test-Path $exe
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$transparencyBefore = (Get-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency
$ruleTasksBefore = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' } | ForEach-Object { $_.TaskPath + $_.TaskName })
$sessionTasksBefore = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Roo Industries Protected Session *' } | ForEach-Object { $_.TaskPath + $_.TaskName })
if ($SetupPath -and $installedBefore -and -not $ReplaceExisting) { throw 'The app is already installed on this PC; pass -ReplaceExisting to replace it with the test build.' }
$task = 'RooIndustries_LoadTimes'
$standalone = 'loadtimes', 'invalidation', 'modes', 'hardware', 'launchers', 'override', 'incomplete', 'incomplete-before'
$ifeoProbe = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProtectedGameProbe.exe'
$ifeoBefore = Test-Path $ifeoProbe
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
    Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" | Where-Object { $_.CommandLine -match 'README' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $exe)) { throw 'The app is not installed.' }
"RESULT version=" + (Get-Item $exe).VersionInfo.ProductVersion

$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -ge 1 } | Select-Object -First 1
if (-not $explorer) { throw 'No interactive desktop session.' }
$sid = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid).Sid
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
$ps = Join-Path $PSHOME 'powershell.exe'
$scenarioScript = @{ invalidation = 'Test-CacheInvalidation.ps1'; modes = 'Test-ModesAndErrors.ps1'; 'migration-before' = 'Test-UpgradeMigration.ps1'; 'migration-after' = 'Test-UpgradeMigration.ps1'; permissions = 'Test-DataFolderPermissions.ps1'; hardware = 'Test-HardwareAge.ps1'; launchers = 'Test-ElevatedLaunchers.ps1'; override = 'Test-HelperStart.ps1'; incomplete = 'Test-HelperStart.ps1'; 'incomplete-before' = 'Test-HelperStart.ps1' }[$Scenario]
$scenarioExtra = @{ 'migration-before' = ' -Phase before'; 'migration-after' = ' -Phase after'; override = ' -Check override'; incomplete = ' -Check incomplete'; 'incomplete-before' = ' -Check incomplete -Before' }[$Scenario]
$arguments = if ($scenarioScript) { '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $scenarioScript) + '" -OutDir "' + $out + '" -Exe "' + $exe + '"' + $scenarioExtra }
else { '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Measure-AppLoadTimes.ps1') + '" -Label "' + $Label + '" -OutDir "' + $out + '" -ColdRuns ' + $ColdRuns + ' -Tours ' + $Tours + ' -ColdTweaksRuns ' + $ColdTweaksRuns + ' -MemoryPasses ' + $MemoryPasses + $(if ($GcDump) { ' -GcDump "' + $GcDump + '"' } else { '' }) + ' -Exe "' + $exe + '"' + $(if ($SkipAdvanced) { ' -SkipAdvanced' } else { '' }) }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\conhost.exe' -Argument $arguments -WorkingDirectory $out
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($Minutes + 5)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force | Out-Null
Start-ScheduledTask -TaskName $task
$done = Join-Path $out $(if ($scenarioScript) { "$Scenario.done" } else { 'measure.done' })
$deadline = (Get-Date).AddMinutes($Minutes)
$started = Get-Date
while ((Get-Date) -lt $deadline -and -not (Test-Path $done)) {
    Start-Sleep 5
    if (((Get-Date) - $started).TotalSeconds -gt 60 -and (Get-ScheduledTask -TaskName $task).State -ne 'Running' -and -not (Test-Path $done)) { "RESULT the scenario task ended without finishing"; break }
}
if (-not (Test-Path $done) -and (Get-Date) -ge $deadline) {
    "RESULT deadline passed; giving the scenario 5 more minutes to finish its cleanup"
    $grace = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $grace -and -not (Test-Path $done)) { Start-Sleep 5 }
}
$info = Get-ScheduledTaskInfo -TaskName $task
"RESULT done=$(Test-Path $done) lastResult=$($info.LastTaskResult)"
if (-not (Test-Path $done)) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue; Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
}
finally {
    function Step([string]$what, [scriptblock]$body) { try { & $body } catch { "RESULT CLEANUP NEEDED: $what failed: " + $_.Exception.Message } }
    Step 'remove the scheduled task' { if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $task -Confirm:$false } }
    Step 'restore renamed scripts' {
        foreach ($renamed in @(Get-ChildItem $appDir -Recurse -File -Filter '*.roo-industries-test-off' -ErrorAction SilentlyContinue)) {
            $original = $renamed.FullName.Substring(0, $renamed.FullName.Length - '.roo-industries-test-off'.Length)
            if (-not (Test-Path $original)) { Rename-Item $renamed.FullName $original; "RESULT restored renamed script " + $renamed.Name }
        }
    }
    if ($Scenario -in $standalone) {
        Step 'restore EnableTransparency' {
            $transparencyAfter = (Get-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency
            if ("$transparencyAfter" -ne "$transparencyBefore") {
                if ($null -eq $transparencyBefore) { Remove-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue } else { Set-ItemProperty $personalize -Name EnableTransparency -Value $transparencyBefore -Type DWord }
                "RESULT CLEANUP: EnableTransparency was left at $transparencyAfter; set back to $transparencyBefore"
            }
        }
        Step 'remove rule tasks' {
            foreach ($ruleTask in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' -and $ruleTasksBefore -notcontains ($_.TaskPath + $_.TaskName) })) {
                Unregister-ScheduledTask -TaskName $ruleTask.TaskName -TaskPath $ruleTask.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
                "RESULT CLEANUP: removed rule task " + $ruleTask.TaskName + " left by the run"
            }
        }
        Step 'remove test helpers' {
            Remove-Item (Join-Path $env:TEMP 'roo-industries-feature-hang.flag') -Force -ErrorAction SilentlyContinue
            Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '-n (400|600|900) 127\.0\.0\.1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Get-Process RooIndustriesLoadTimesProbe, RooIndustriesLauncherProbe, RooIndustriesProtectedLauncherProbe -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            Remove-Item (Join-Path $env:TEMP 'RooIndustriesLoadTimesProbe.exe'), (Join-Path $env:TEMP 'RooIndustriesLauncherProbe.exe'), (Join-Path $env:TEMP 'RooIndustriesProtectedLauncherProbe.exe'), (Join-Path $env:TEMP 'RooIndustriesProtectedGameProbe.exe') -Force -ErrorAction SilentlyContinue
        }
        Step 'remove protected-session leftovers' {
            if ($Scenario -eq 'launchers') {
                foreach ($sessionTask in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Roo Industries Protected Session *' -and $sessionTasksBefore -notcontains ($_.TaskPath + $_.TaskName) })) {
                    Stop-ScheduledTask -TaskName $sessionTask.TaskName -TaskPath $sessionTask.TaskPath -ErrorAction SilentlyContinue
                    Unregister-ScheduledTask -TaskName $sessionTask.TaskName -TaskPath $sessionTask.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
                    "RESULT CLEANUP: removed protected-session task " + $sessionTask.TaskName + " left by the run"
                }
                if (-not $ifeoBefore -and (Test-Path $ifeoProbe)) { Remove-Item $ifeoProbe -Recurse -Force; "RESULT CLEANUP: removed " + $ifeoProbe }
            }
        }
    }
    Step 'read the scenario log' {
        $log = Get-ChildItem $out -Filter '*.log' -ErrorAction SilentlyContinue | Select-String 'CLEANUP NEEDED' | ForEach-Object { $_.Line }
        foreach ($line in @($log)) { "RESULT $line" }
    }
    Step 'stop the app' {
        Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process Optimizer.Host, DismHost -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ($Uninstall -or ($Scenario -in $standalone -and $SetupPath -and -not $installedBefore -and -not $KeepInstalled)) { Step 'uninstall the test build' { "RESULT uninstall " + (Uninstall-App) } }
}
"RESULT out=$out"
Get-Content (Join-Path $out $(if ($scenarioScript) { "$Scenario.log" } else { 'LOADTIMES.md' })) -ErrorAction SilentlyContinue
