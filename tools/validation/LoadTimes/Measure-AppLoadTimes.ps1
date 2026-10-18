param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$OutDir,
    [int]$ColdRuns = 3,
    [int]$Tours = 2,
    [int]$ColdTweaksRuns = 2,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe',
    [switch]$SkipAdvanced,
    [int]$MemoryPasses = 0,
    [string]$GcDump
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
$script:AppReceipt = $null
. (Join-Path $PSScriptRoot 'LauncherChecks.Common.ps1')
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class LoadTimesU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f, int x, int y, uint d, IntPtr e);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
[LoadTimesU32]::SetProcessDPIAware() | Out-Null
[LoadTimesU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir 'loadtimes.log'
$script:Rows = [Collections.Generic.List[object]]::new()
$script:App = $null; $script:Win = $null

function Log([string]$m) { $line = (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m; [IO.File]::AppendAllText($script:LogPath, $line + "`r`n") }
function Wake { [LoadTimesU32]::mouse_event(1, 3, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 200; [LoadTimesU32]::mouse_event(1, -3, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 500 }
function Shot([string]$name) {
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $b = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height; $g = [Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $b.Size); $b.Save((Join-Path $OutDir ('shot-' + $name + '.png')), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
}
function ById($id) { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, $id)) }
function ByName($name) { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, $name)) }
function Visible($e) { $e -and -not $e.Current.IsOffscreen }
function HasName($name) { Visible (ByName $name) }
function Texts { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text)) | Where-Object { -not $_.Current.IsOffscreen } | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) }
function HasText([string]$pattern) { [bool](@(Texts) -match $pattern) }
function Enabled($id) { $e = ById $id; $e -and $e.Current.IsEnabled -and -not $e.Current.IsOffscreen }
function Activate($e) {
    try { $e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); return } catch {}
    try { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); return } catch {}
    $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
}
function WaitFor([scriptblock]$probe, [double]$seconds, [string]$what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { try { $r = & $probe } catch { $r = $null }; if ($r) { return $r }; Start-Sleep -Milliseconds 50 }
    throw "Timed out waiting for $what"
}
function Find-MainWindow([int]$procId) {
    $c = [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $procId)
    @($A::RootElement.FindAll($TS::Children, $c) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and ($_.Current.Name -like 'Performance Vertex Utility*' -or $_.Current.Name -like 'Roo Industries*') })[0]
}
function Get-Descendants([int]$root) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)
    $found = [Collections.Generic.List[int]]::new(); $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue($root)
    while ($queue.Count) { $parent = $queue.Dequeue(); foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $parent -and $_.ProcessId -ne $root }) { if (-not $found.Contains([int]$child.ProcessId)) { $found.Add([int]$child.ProcessId); $queue.Enqueue([int]$child.ProcessId) } } }
    return $found
}
function Stop-App {
    Stop-OwnedValidationApp $script:App $script:AppReceipt
    $script:App = $null; $script:AppReceipt = $null; $script:Win = $null
    Start-Sleep -Milliseconds 800
}
function Start-App {
    Stop-App
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:App = Start-Process $Exe -PassThru
    $script:AppReceipt = New-OwnedProcess $script:App
    $script:Win = WaitFor { Find-MainWindow $script:App.Id } 120 'main window'
    $window = $sw.ElapsedMilliseconds
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [LoadTimesU32]::ShowWindow($h, 9) | Out-Null
    [LoadTimesU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [LoadTimesU32]::SetForegroundWindow($h) | Out-Null
    return @{ Stopwatch = $sw; WindowMs = $window }
}
function Measure-Until([Diagnostics.Stopwatch]$sw, [scriptblock]$usable, [scriptblock]$complete, [double]$timeout, [int]$poll = 60, [scriptblock]$state = $null) {
    $u = $null; $c = $null; $p = $null; $deadline = $sw.ElapsedMilliseconds + $timeout * 1000
    while ($sw.ElapsedMilliseconds -lt $deadline -and ($null -eq $u -or $null -eq $c)) {
        if ($null -eq $u) { try { if (& $usable) { $u = $sw.ElapsedMilliseconds } } catch {} }
        if ($state -and $null -eq $p) { try { if (& $state) { $p = $sw.ElapsedMilliseconds } } catch {} }
        if ($null -eq $c) { try { if (& $complete) { $c = $sw.ElapsedMilliseconds; if ($null -eq $u) { $u = $c }; if ($state -and $null -eq $p) { $p = $c } } } catch {} }
        Start-Sleep -Milliseconds $poll
    }
    return @($u, $c, $p)
}
function Settle([Diagnostics.Stopwatch]$sw, [double]$quietSeconds, [double]$timeout) {
    $last = ''; $changed = $sw.ElapsedMilliseconds; $deadline = $sw.ElapsedMilliseconds + $timeout * 1000
    while ($sw.ElapsedMilliseconds -lt $deadline) {
        $now = (@(Texts) | Where-Object { $_ -notmatch '^\d+(\.\d+)? ?(%|MB|GB|fps|ms|°C)' }) -join '|'
        if ($now -ne $last) { $last = $now; $changed = $sw.ElapsedMilliseconds }
        elseif ($sw.ElapsedMilliseconds - $changed -ge $quietSeconds * 1000) { return $changed }
        Start-Sleep -Milliseconds 250
    }
    return $null
}
function Add-Row([string]$tour, [string]$page, [string]$visit, $usable, $complete, [string]$note = '', $state = $null, [bool]$navigationIncludesTabSwitch = $false) {
    $row = [pscustomobject]@{ label = $Label; tour = $tour; page = $page; visit = $visit; usable_ms = $usable; complete_ms = $complete; state_ms = $state; note = $note; utc = (Get-Date).ToUniversalTime().ToString('o'); navigation_includes_tab_switch = $navigationIncludesTabSwitch }
    $script:Rows.Add($row); Log ("ROW $tour $page $visit usable=$usable complete=$complete $note")
    $script:Rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir 'loadtimes.csv')
}
$script:Memory = [Collections.Generic.List[object]]::new()
function Add-Memory([string]$tour, [string]$when, $process) {
    $row = [pscustomobject]@{ label = $Label; tour = $tour; when = $when; private_mb = [int]($process.PrivateMemorySize64 / 1MB); working_set_mb = [int]($process.WorkingSet64 / 1MB); cpu_ms = [int]$process.TotalProcessorTime.TotalMilliseconds }
    $script:Memory.Add($row); Log ("MEMORY $tour $when private=$($row.private_mb) MB ws=$($row.working_set_mb) MB cpu=$($row.cpu_ms) ms")
    $script:Memory | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir 'memory.csv')
}
function Nav([string]$name) {
    $item = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, $name), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))) } 30 "nav $name"
    $sw = [Diagnostics.Stopwatch]::StartNew(); Activate $item; return $sw
}
function Measure-Cycle([Diagnostics.Stopwatch]$sw, [scriptblock]$usable, [string]$id, [double]$timeout) {
    $u = $null; $enabledAt = $null; $seen = $false; $deadline = $sw.ElapsedMilliseconds + $timeout * 1000
    while ($sw.ElapsedMilliseconds -lt $deadline) {
        if ($null -eq $u) { try { if (& $usable) { $u = $sw.ElapsedMilliseconds } } catch {} }
        $e = $null; try { $e = ById $id } catch {}
        if ($e -and -not $e.Current.IsOffscreen) {
            if (-not $e.Current.IsEnabled) { $seen = $true; $enabledAt = $null }
            elseif ($seen) { $c = $sw.ElapsedMilliseconds; if ($null -eq $u) { $u = $c }; return @($u, $c) }
            elseif ($null -eq $enabledAt) { $enabledAt = $sw.ElapsedMilliseconds }
            elseif ($sw.ElapsedMilliseconds - $enabledAt -ge 1500) { if ($null -eq $u) { $u = $enabledAt }; return @($u, $enabledAt) }
        }
        Start-Sleep -Milliseconds 40
    }
    return @($u, $null)
}
$Pages = @(
    @{ Name = 'Games'; Nav = 'Games'; Tab = 'GamesTab'; Usable = { HasName '1. Choose a game' }; Complete = 'cycle:GameSessionRefresh'; Timeout = 60 },
    @{ Name = 'Games/Processes'; Tab = 'ProcessesTab'; Usable = { Visible (ById 'ProcessPicker') }; Complete = 'cycle:ProcessRefresh'; Timeout = 60 },
    @{ Name = 'Games/Background'; Tab = 'BackgroundTab'; Usable = { HasText ' running$' }; Complete = { HasText ' running$' }; Timeout = 60; After = 'GamesTab' },
    @{ Name = 'Remove apps'; Nav = 'Remove apps'; Usable = { HasName 'Remove selected applications, then review leftover files and registry data.' }; Complete = { HasText '^[1-9]\d* apps installed' }; Timeout = 60 },
    @{ Name = 'Graphics drivers'; Nav = 'Graphics drivers'; Usable = { HasName 'Drivers & GPU' }; Complete = { HasName 'Processor' }; Timeout = 60 },
    @{ Name = 'Windows tweaks'; Nav = 'Windows tweaks'; Usable = { $l = ById 'WindowsTweaksList'; $l -and $l.FindFirst($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem)) }; Complete = { $s = ById 'WindowsTweaksStatus'; $s -and $s.Current.Name -match '^\d+ settings$|recovery|Restart' }; State = { $s = ById 'WindowsTweaksStatus'; $s -and $s.Current.Name -match '^\d+ settings|recovery|Restart' }; Timeout = 120 },
    @{ Name = 'Tools'; Nav = 'Tools'; Usable = { HasName 'HWiNFO' }; Complete = { HasName 'HWiNFO' }; Timeout = 45 },
    @{ Name = 'Tools/BIOS settings'; Invoke = 'OpenFirmware'; Usable = { HasName 'Load your BIOS settings' }; Complete = 'settle'; Timeout = 45 },
    @{ Name = 'Undo changes'; Nav = 'Undo changes'; Usable = { HasName 'Saved settings' }; Complete = { (HasName 'Saved settings') -and -not (HasName 'Reading restore state') }; Timeout = 60 },
    @{ Name = 'Report a bug'; Nav = 'Report a bug'; Usable = { HasName 'Your report' }; Complete = { HasName 'Processor' }; Timeout = 60 },
    @{ Name = 'Settings'; Nav = 'Settings'; Usable = { HasName 'Appearance' }; Complete = { HasName 'Appearance' }; Timeout = 30 },
    @{ Name = 'Home'; Nav = 'Home'; Usable = { HasName 'Start here' }; Complete = { HasText ' in the background$' }; Timeout = 60 }
)
$Advanced = @(
    @{ Name = 'Remove apps/Leftovers'; Before = 'Remove apps'; Tab = 'LeftoversTab'; Usable = { HasName 'Pick an app to review' }; Complete = 'settle'; Timeout = 60; After = 'RemovalTab' },
    @{ Name = 'Startup & services'; Nav = 'Startup & services'; Usable = { HasName 'Running background apps' }; Complete = { (HasName 'Running background apps') -and -not (HasName 'Reading startup and services') }; Timeout = 60 },
    @{ Name = 'Memory'; Nav = 'Memory'; Usable = { HasName 'Memory by process' }; Complete = { (HasName 'Memory by process') -and -not (HasName 'Reading memory and latency') }; Timeout = 60 },
    @{ Name = 'Timer & cache'; Nav = 'Timer & cache'; Usable = { HasName 'Timer & shader cache' }; Complete = 'settle'; Timeout = 60 }
)
function Visit([hashtable]$page, [string]$tour, [string]$visit) {
    if ($page.Before) { Nav $page.Before | Out-Null; Start-Sleep -Milliseconds 1500 }
    if ($page.Nav) { $sw = Nav $page.Nav }
    else {
        $target = WaitFor { ById ($(if ($page.Tab) { $page.Tab } else { $page.Invoke })) } 30 $page.Name
        $sw = [Diagnostics.Stopwatch]::StartNew(); Activate $target
    }
    if ($page.Nav -and $page.Tab) {
        $target = WaitFor { ById $page.Tab } 30 $page.Name
        Activate $target
    }
    if ($page.Tab) {
        WaitFor { $tab = ById $page.Tab; $tab -and $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } 10 ($page.Name + ' tab selected') | Out-Null
    }
    $complete = $page.Complete
    if ($complete -is [string] -and $complete.StartsWith('cycle:')) { $r = Measure-Cycle $sw $page.Usable $complete.Substring(6) $page.Timeout }
    elseif ($complete -is [string] -and $complete -eq 'settle') {
        $u = (Measure-Until $sw $page.Usable $page.Usable $page.Timeout)[0]
        $r = @($u, (Settle $sw 3 $page.Timeout))
    } else { $r = Measure-Until $sw $page.Usable $complete $page.Timeout 60 $page.State }
    Add-Row $tour $page.Name $visit $r[0] $r[1] $(if ($null -eq $r[1]) { 'timeout' } else { '' }) $r[2] ([bool]($page.Nav -and $page.Tab))
    Shot ("$tour-$visit-" + ($page.Name -replace '\W', ''))
    if ($page.After) { $tab = ById $page.After; if ($tab) { Activate $tab } }
    Start-Sleep -Milliseconds 1500
}
function Set-SimpleMode([bool]$simple) {
    Nav 'Settings' | Out-Null
    $toggle = WaitFor { ById 'SimpleModeToggle' } 20 'simple mode toggle'
    $state = [string]$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
    if (($state -eq 'On') -ne $simple) { $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle(); Start-Sleep 2 }
    return $state -eq 'On'
}

$procmon = $null
try {
    Log "START label=$Label exe=$Exe version=$((Get-Item $Exe).VersionInfo.ProductVersion)"
    $stopFile = Join-Path $OutDir 'procmon.stop'; Remove-Item $stopFile -ErrorAction SilentlyContinue
    $procmon = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'Watch-HelperProcesses.ps1') + '"'), '-OutCsv', ('"' + (Join-Path $OutDir 'processes.csv') + '"'), '-StopFile', ('"' + $stopFile + '"')) -WindowStyle Hidden -PassThru
    Start-Sleep 3
    Wake
    for ($run = 1; $run -le $ColdRuns; $run++) {
        $s = Start-App

        $r = Measure-Until $s.Stopwatch { HasName 'Start here' } { HasText ' in the background$' } 90
        Add-Row "cold$run" 'Start: window' 'cold' $s.WindowMs $s.WindowMs
        Add-Row "cold$run" 'Start: Home' 'cold' $r[0] $r[1] $(if ($null -eq $r[1]) { 'timeout' } else { '' })
        if ($run -eq 1) {
            $seen = @{}
            for ($i = 0; $i -lt 40; $i++) {
                foreach ($id in @(Get-Descendants $script:App.Id)) {
                    try { $child = Get-Process -Id $id -ErrorAction Stop; $key = $child.ProcessName + ':' + $child.PriorityClass; if (-not $seen.ContainsKey($key)) { $seen[$key] = [int]$s.Stopwatch.ElapsedMilliseconds } } catch {}
                }
                Start-Sleep -Milliseconds 150
            }
            Log ('PRIORITY helper processes after Home: ' + (($seen.GetEnumerator() | Sort-Object Value | ForEach-Object { $_.Key + '@' + $_.Value + 'ms' }) -join ', '))
        }
        Shot "cold$run-home"
        Start-Sleep 2
    }
    if ($MemoryPasses -gt 0) {
        if ($GcDump -and -not $env:DOTNET_ROOT) { $env:DOTNET_ROOT = Join-Path $env:USERPROFILE '.dotnet' }
        $s = Start-App
        $null = Measure-Until $s.Stopwatch { HasName 'Start here' } { HasText ' in the background$' } 90
        Start-Sleep 8
        for ($pass = 1; $pass -le $MemoryPasses; $pass++) {
            foreach ($page in $Pages) { try { Visit $page 'memory' "pass $pass" } catch { Log ("ERROR memory pass $pass $($page.Name) :: " + $_.Exception.Message) } }
            Start-Sleep 8
            $p = Get-Process -Id $script:App.Id; $p.Refresh(); Add-Memory 'memory' "after pass $pass" $p
            if ($GcDump) {
                $dump = Join-Path $OutDir ("pass$pass.gcdump")
                $text = (& $GcDump collect -p $script:App.Id -o $dump 2>&1) -join ' '
                Start-Sleep 3
                $p.Refresh(); Add-Memory 'memory' "after pass $pass, forced full GC" $p
                $report = (& $GcDump report $dump 2>&1) -join "`n"
                $heap = [regex]::Match($report, '([\d,]+)\s+GC Heap bytes').Groups[1].Value
                Log ("GCDUMP pass $pass managed heap bytes=" + $heap + " :: " + ($report.Substring(0, [Math]::Min(160, $report.Length)) -replace '\s+', ' '))
                Remove-Item $dump -ErrorAction SilentlyContinue
            }
        }
        Stop-App
        $Tours = 0; $ColdRuns = 0; $ColdTweaksRuns = 0
    }
    $tweaks = $Pages | Where-Object { $_.Name -eq 'Windows tweaks' }
    for ($run = 1; $run -le $ColdTweaksRuns; $run++) {
        $s = Start-App
        $null = Measure-Until $s.Stopwatch { HasName 'Start here' } { HasName 'Start here' } 90
        $sw = Nav 'Windows tweaks'
        $r = Measure-Until $sw $tweaks.Usable $tweaks.Complete $tweaks.Timeout 60 $tweaks.State
        Add-Row "coldtweaks$run" 'Start: Windows tweaks right after launch' 'cold' $r[0] $r[1] $(if ($null -eq $r[1]) { 'timeout' } else { '' }) $r[2]
        Shot "coldtweaks$run"
        Start-Sleep 2
    }
    for ($tour = 1; $tour -le $Tours; $tour++) {
        $s = Start-App
        $r = Measure-Until $s.Stopwatch { HasName 'Start here' } { HasText ' in the background$' } 90
        Add-Row "tour$tour" 'Start: Home' 'cold' $r[0] $r[1]
        Start-Sleep 8
        $p = Get-Process -Id $script:App.Id; $p.Refresh()
        Add-Memory "tour$tour" 'after start' $p
        foreach ($visit in 'first', 'revisit', 'third visit') {
            foreach ($page in $Pages) {
                try { Visit $page "tour$tour" $visit } catch { Log ("ERROR $($page.Name) $visit :: " + $_.Exception.Message); Add-Row "tour$tour" $page.Name $visit $null $null ('error: ' + $_.Exception.Message) }
            }
            Start-Sleep 8
            $p = Get-Process -Id $script:App.Id; $p.Refresh()
            Add-Memory "tour$tour" "after $visit pass" $p
        }
        if (-not $SkipAdvanced) {
            $wasSimple = $true
            try {
                $wasSimple = Set-SimpleMode $false
                foreach ($visit in 'first', 'revisit') { foreach ($page in $Advanced) { try { Visit $page "tour$tour" $visit } catch { Add-Row "tour$tour" $page.Name $visit $null $null ('error: ' + $_.Exception.Message) } } }
            } finally { try { Set-SimpleMode $wasSimple | Out-Null } catch { Log ('could not restore simple mode: ' + $_.Exception.Message) } }
        }
        $p = Get-Process -Id $script:App.Id; Log ("tour$tour cpu ms=" + [int]$p.TotalProcessorTime.TotalMilliseconds + " ws MB=" + [int]($p.WorkingSet64 / 1MB))
        Stop-App
    }
} catch { Log ("FATAL " + ($_ | Out-String)) }
finally {
    try { Stop-App } catch {}
    'x' | Set-Content (Join-Path $OutDir 'procmon.stop')
    if ($procmon) { $procmon.WaitForExit(15000) | Out-Null }
    $md = @("# App load times: $Label", '', "Machine: $env:COMPUTERNAME. Times in ms from navigation (Start rows: from process launch).", '', '| page | visit | usable ms (median) | state ms (median) | complete ms (median) | samples | timeouts or errors |', '|---|---|---|---|---|---|---|')
    function Median($values) { $v = @($values | Where-Object { $null -ne $_ -and $_ -ne '' } | ForEach-Object { [double]$_ } | Sort-Object); if ($v.Count -eq 0) { return 'timeout' }; if ($v.Count % 2) { return [int]$v[[int][Math]::Floor($v.Count / 2)] }; return [int](($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2) }
    foreach ($group in $script:Rows | Group-Object page, visit) {
        $first = $group.Group[0]
        $md += "| $($first.page) | $($first.visit) | $(Median $group.Group.usable_ms) | $(if (@($group.Group | Where-Object { $_.state_ms }).Count) { Median $group.Group.state_ms } else { '-' }) | $(Median $group.Group.complete_ms) | $($group.Count) | $(@($group.Group | Where-Object { $null -eq $_.complete_ms -or $_.complete_ms -eq '' }).Count) |"
    }
    $md += @('', '| tour | when | private MB | working set MB | app CPU ms |', '|---|---|---|---|---|')
    foreach ($m in $script:Memory) { $md += "| $($m.tour) | $($m.when) | $($m.private_mb) | $($m.working_set_mb) | $($m.cpu_ms) |" }
    $md -join "`r`n" | Set-Content -Encoding UTF8 (Join-Path $OutDir 'LOADTIMES.md')
    'x' | Set-Content (Join-Path $OutDir 'measure.done')
}
