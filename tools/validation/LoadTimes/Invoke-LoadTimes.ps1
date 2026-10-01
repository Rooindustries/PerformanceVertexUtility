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
    [ValidateSet('loadtimes', 'invalidation', 'modes', 'migration-before', 'migration-after')][string]$Scenario = 'loadtimes',
    [int]$MemoryPasses = 0,
    [string]$GcDump,
    [switch]$Uninstall
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
$task = 'RooIndustries_LoadTimes'
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
$ps = Join-Path $PSHOME 'powershell.exe'
$scenarioScript = @{ invalidation = 'Test-CacheInvalidation.ps1'; modes = 'Test-ModesAndErrors.ps1'; 'migration-before' = 'Test-UpgradeMigration.ps1'; 'migration-after' = 'Test-UpgradeMigration.ps1' }[$Scenario]
$arguments = if ($scenarioScript) { '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $scenarioScript) + '" -OutDir "' + $out + '" -Exe "' + $exe + '"' + $(if ($Scenario -like 'migration-*') { ' -Phase ' + $Scenario.Substring(10) } else { '' }) }
else { '--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Measure-AppLoadTimes.ps1') + '" -Label "' + $Label + '" -OutDir "' + $out + '" -ColdRuns ' + $ColdRuns + ' -Tours ' + $Tours + ' -ColdTweaksRuns ' + $ColdTweaksRuns + ' -MemoryPasses ' + $MemoryPasses + $(if ($GcDump) { ' -GcDump "' + $GcDump + '"' } else { '' }) + ' -Exe "' + $exe + '"' + $(if ($SkipAdvanced) { ' -SkipAdvanced' } else { '' }) }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\conhost.exe' -Argument $arguments -WorkingDirectory $out
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($Minutes + 5)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force | Out-Null
Start-ScheduledTask -TaskName $task
$done = Join-Path $out $(if ($scenarioScript) { "$Scenario.done" } else { 'measure.done' })
$deadline = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt $deadline -and -not (Test-Path $done)) { Start-Sleep 5 }
$info = Get-ScheduledTaskInfo -TaskName $task
"RESULT done=$(Test-Path $done) lastResult=$($info.LastTaskResult)"
if (-not (Test-Path $done)) { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue; Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
Unregister-ScheduledTask -TaskName $task -Confirm:$false
if ($Uninstall) { "RESULT uninstall " + (Uninstall-App) }
"RESULT out=$out"
Get-Content (Join-Path $out $(if ($scenarioScript) { "$Scenario.log" } else { 'LOADTIMES.md' })) -ErrorAction SilentlyContinue
