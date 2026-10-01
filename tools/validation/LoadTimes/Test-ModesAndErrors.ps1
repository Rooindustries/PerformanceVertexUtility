param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ModeCheckU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@
[ModeCheckU32]::SetProcessDPIAware() | Out-Null
[ModeCheckU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir 'modes.log'
$script:Failures = 0
$script:Renamed = @()
$script:HangFlag = $null
$script:Skipped = 0

function Log([string]$m) { [IO.File]::AppendAllText($script:LogPath, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m + "`r`n") }
function Check([bool]$ok, [string]$name, [string]$detail) { if (-not $ok) { $script:Failures++ }; Log ($(if ($ok) { 'PASS ' } else { 'FAIL ' }) + $name + ' :: ' + $detail) }
function Shot([string]$name) {
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $b = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height; $g = [Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $b.Size); $b.Save((Join-Path $OutDir ('shot-' + $name + '.png')), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
}
function WaitFor([scriptblock]$probe, [double]$seconds, [string]$what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { try { $r = & $probe } catch { $r = $null }; if ($r) { return $r }; Start-Sleep -Milliseconds 100 }
    throw "Timed out waiting for $what"
}
function Eventually([scriptblock]$probe, [double]$seconds) { try { [bool](WaitFor $probe $seconds 'condition') } catch { $false } }
function ById($id) { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, $id)) }
function Visible($e) { $e -and -not $e.Current.IsOffscreen }
function Named([string]$name, $type) {
    $condition = [Windows.Automation.PropertyCondition]::new($A::NameProperty, $name)
    if ($type) { $condition = [Windows.Automation.AndCondition]::new($condition, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $type)) }
    @($script:Win.FindAll($TS::Descendants, $condition) | Where-Object { -not $_.Current.IsOffscreen })
}
function Invoke-Element($e) {
    try { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); return } catch {}
    try { $e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); return } catch {}
    $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
}
function Nav([string]$name) {
    $item = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, $name), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))) } 30 "nav $name"
    Invoke-Element $item; Log "nav $name"; Start-Sleep -Milliseconds 800
}
function Start-RooIndustriesApp {
    Stop-RooIndustriesApp
    $script:App = Start-Process $Exe -PassThru
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [ModeCheckU32]::ShowWindow($h, 9) | Out-Null; [ModeCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [ModeCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { Named 'Start here' } 60 'Home' | Out-Null
}
function Stop-RooIndustriesApp {
    if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { $script:App.Kill() } }
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
}
function Set-Simple([bool]$simple) {
    Nav 'Settings'
    $toggle = WaitFor { ById 'SimpleModeToggle' } 20 'simple mode toggle'
    $pattern = $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    $was = [string]$pattern.Current.ToggleState -eq 'On'
    if ($was -ne $simple) { $pattern.Toggle(); Start-Sleep 2 }
    Log "simple mode $was -> $simple"
    return $was
}
function Timer-Tile { @(Named 'Timer & cache' $CT::Button).Count -gt 0 }
function Tweaks-Advanced { @(Named 'Profiles & tools').Count -gt 0 }
function Check-Mode([bool]$simple, [string]$when) {
    Nav 'Home'
    WaitFor { Named 'Start here' } 30 'Home' | Out-Null
    $expected = -not $simple
    Check (Eventually { (Timer-Tile) -eq $expected } 5) "Home Timer tile is $(if ($expected) { 'shown' } else { 'hidden' }) $when" ''
    Shot ("home-" + ($when -replace '\W', '-'))
    Nav 'Windows tweaks'
    WaitFor { ById 'WindowsTweaksList' } 60 'Windows tweaks list' | Out-Null
    Check (Eventually { (Tweaks-Advanced) -eq $expected } 5) "Windows tweaks advanced view is $(if ($expected) { 'shown' } else { 'hidden' }) $when" ''
    Shot ("tweaks-" + ($when -replace '\W', '-'))
}
function App-Log {
    $root = [Environment]::GetFolderPath('LocalApplicationData')
    $folder = if (Test-Path (Join-Path $root ('RooIndustriesOptimizationSuite' -replace 'Industries',''))) { ('RooIndustriesOptimizationSuite' -replace 'Industries','') } else { 'RooIndustriesOptimizationSuite' }
    $candidate = Join-Path $root ($folder + '\logs\app.log')
    if (Test-Path $candidate) { return $candidate }
}
function Hook-Count { $log = App-Log; if ($log) { @(Get-Content $log | Select-String '\[test\] test hooks enabled').Count } else { 0 } }
function Tweaks-Settled([double]$seconds) {
    WaitFor { $r = ById 'WindowsTweaksRefresh'; $s = ById 'WindowsTweaksStatus'; if ($r -and $r.Current.IsEnabled -and $s -and $s.Current.Name -notmatch '^Loading|checking Windows features') { $s.Current.Name } } $seconds 'Windows tweaks settled'
}
function Row-Current([string]$name) {
    $search = WaitFor { ById 'WindowsTweaksSearch' } 30 'search box'
    $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($name); Start-Sleep 1
    $prefix = $name + ': current value '
    $text = WaitFor { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text)) | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.Name -like ($prefix + '*') })[0] } 20 "current value of $name"
    return $text.Current.Name.Substring($prefix.Length)
}
function Script-Path([string]$name) {
    $root = Split-Path (Split-Path $Exe -Parent) -Parent
    $found = @(Get-ChildItem $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) { throw "Expected one $name under the install folder, found $($found.Count)." }
    return $found[0].FullName
}
function Disable-Script([string]$path) { Rename-Item $path ($path + '.roo-industries-test-off'); $script:Renamed += $path; Log ("disabled " + (Split-Path $path -Leaf)) }
function Restore-Script([string]$path) {
    if (Test-Path ($path + '.roo-industries-test-off')) { Rename-Item ($path + '.roo-industries-test-off') $path }
    $script:Renamed = @($script:Renamed | Where-Object { $_ -ne $path }); Log ("restored " + (Split-Path $path -Leaf))
}
function Memory-Error { @(Named 'Memory information is unavailable').Count -gt 0 }
function Memory-Loaded { (@(Named 'Memory by process').Count -gt 0) -and -not (Memory-Error) }
function Memory-Note { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text)) | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.Name -like 'Memory by process is unavailable*' }).Count -gt 0 }

$wasSimple = $null
try {
    Start-RooIndustriesApp
    $wasSimple = Set-Simple $true
    Start-RooIndustriesApp
    Check-Mode $true 'with simple mode on at launch'
    Set-Simple $false | Out-Null
    Check-Mode $false 'after switching simple mode off'
    Set-Simple $true | Out-Null
    Check-Mode $true 'after switching simple mode back on'
    Set-Simple $false | Out-Null
    Stop-RooIndustriesApp

    $inventory = Script-Path 'Get-ProcessInventory.ps1'
    $classification = Script-Path 'Get-ProcessClassification.ps1'
    Disable-Script $inventory; Disable-Script $classification
    Start-RooIndustriesApp
    Nav 'Memory'
    Check (Eventually { Memory-Error } 60) 'Memory page shows the error panel when both memory reads fail' ''
    $retry = WaitFor { $b = ById 'MemoryRetry'; if (Visible $b) { $b } } 10 'Retry button'
    Check ($null -ne $retry) 'the error panel offers Retry' ''
    Shot 'memory-error'

    Restore-Script $inventory
    Invoke-Element $retry
    Check (Eventually { (Memory-Loaded) -and (Memory-Note) } 60) 'Retry with only the process list still failing loads the page and says memory by process is unavailable' ''
    Shot 'memory-partial'

    Restore-Script $classification
    Nav 'Home'; Nav 'Memory'
    Check (Eventually { (Memory-Loaded) -and -not (Memory-Note) } 60) 'after both scripts are restored, revisiting Memory loads the full page' ''
    Shot 'memory-loaded'

    Disable-Script $inventory; Disable-Script $classification
    Nav 'Home'; Start-Sleep 4; Nav 'Memory'
    Check (Eventually { Memory-Error } 60) 'a revisit whose reads both fail shows the error panel instead of the old list' ''
    Restore-Script $inventory; Restore-Script $classification
    Invoke-Element (WaitFor { $b = ById 'MemoryRetry'; if (Visible $b) { $b } } 10 'Retry button')
    Check (Eventually { (Memory-Loaded) -and -not (Memory-Note) } 60) 'Retry after restoring both scripts loads the full page' ''
    Shot 'memory-retry-loaded'

    $flag = Join-Path $env:TEMP 'roo-industries-feature-hang.flag'
    $checkingText = 'Checking' + [char]0x2026
    $featureRow = 'Hyper-V: Hypervisor Platform'; $otherRow = 'Transparency Effects'; $otherId = 'windows.0689e69eedc05770'
    $script:HangFlag = $flag
    Set-Content $flag 'x'
    $env:ROO_INDUSTRIES_TEST_FEATURE_HANG = $flag
    $hookBefore = Hook-Count
    $launched = [Diagnostics.Stopwatch]::StartNew()
    try { Start-RooIndustriesApp } finally { Remove-Item Env:ROO_INDUSTRIES_TEST_FEATURE_HANG -ErrorAction SilentlyContinue }
    if (-not (Eventually { (Hook-Count) -gt $hookBefore } 30)) {
        $script:Skipped++; Log 'NOT RUN the Windows features hang check: it needs a build with test hooks (build the installer with Build-Release.ps1 -TestHooks); a production installer cannot run it'
        Stop-RooIndustriesApp
    }
    else {
        Set-Simple $false | Out-Null
        Nav 'Windows tweaks'
        WaitFor { ById 'WindowsTweaksList' } 60 'Windows tweaks list' | Out-Null
        $checking = Eventually { $s = ById 'WindowsTweaksStatus'; $s -and $s.Current.Name -match 'checking Windows features' } 30
        $partialRead = if ($checking) { Row-Current $otherRow } else { '' }
        Check ($checking -and $partialRead -and $partialRead -notin @('Not read', $checkingText)) 'while Windows features have not answered the other settings already show their state' ("status=" + (ById 'WindowsTweaksStatus').Current.Name + "; $otherRow=" + $partialRead)
        Shot 'features-checking'
        $settledStatus = Tweaks-Settled 150
        $seconds = [int]$launched.Elapsed.TotalSeconds
        Check ($seconds -le 100) 'a Windows features read that never answers is given up on within 100 seconds of launch' ("settled after $seconds s: " + $settledStatus)
        $featureRead = Row-Current $featureRow
        Check ($featureRead -eq "Couldn't check") 'the feature row says it could not be checked' ("$featureRow=" + $featureRead)
        Check ((Row-Current $otherRow) -notin @('Not read', "Couldn't check", $checkingText)) 'other settings keep their state after the feature read gave up' ("$otherRow=" + (Row-Current $otherRow))
        Shot 'features-gave-up'
        $current = Row-Current $otherRow
        $target = if ($current -like 'On*') { 'Off (0)' } else { 'On (1)' }
        $pick = WaitFor { ById ($otherId + '.select') } 20 'Transparency Effects selection'
        $pickPattern = $pick.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        if ([string]$pickPattern.Current.ToggleState -ne 'On') { $pickPattern.Toggle(); Start-Sleep 1 }
        $combo = WaitFor { ById ($otherId + '.value') } 20 'value combo'
        $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -Milliseconds 800
        $choice = WaitFor { $combo.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, $target)) } 10 "choice $target"
        $choice.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 800
        $check = ById 'WindowsTweaksPreview'
        Check ($check -and $check.Current.IsEnabled) 'review stays available for settings that were read while the feature rows could not be checked' ("picked $otherRow $current -> $target")
        $pickPattern = (ById ($otherId + '.select')).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
        if ([string]$pickPattern.Current.ToggleState -eq 'On') { $pickPattern.Toggle(); Start-Sleep 1 }
        Remove-Item $flag -Force
        Invoke-Element (ById 'WindowsTweaksRefresh')
        Start-Sleep 2
        Tweaks-Settled 120 | Out-Null
        $retried = Row-Current $featureRow
        Check ($retried -notin @("Couldn't check", 'Not read', $checkingText)) 'Refresh reads the Windows features again once they answer' ("$featureRow=" + $retried)
        Shot 'features-retried'
        Stop-RooIndustriesApp
    }

    Start-RooIndustriesApp
    $first = $script:App; $firstWindow = [IntPtr]::new($script:Win.Current.NativeWindowHandle)
    Nav 'Settings'
    [ModeCheckU32]::ShowWindow($firstWindow, 6) | Out-Null; Start-Sleep 1
    $second = Start-Process $Exe -PassThru
    $secondExited = $second.WaitForExit(30000)
    Start-Sleep 2
    $running = @(Get-Process RooIndustries.OptimizationSuite.App -ErrorAction SilentlyContinue)
    $foreground = [ModeCheckU32]::GetForegroundWindow()
    Check ($secondExited -and $running.Count -eq 1 -and $running[0].Id -eq $first.Id -and -not $first.HasExited) 'a second launch hands over to the open window and exits' ("second exited=" + $secondExited + " app processes=" + $running.Count)
    Check (-not [ModeCheckU32]::IsIconic($firstWindow)) 'the minimized open window is restored after a second launch' ("minimized=" + [ModeCheckU32]::IsIconic($firstWindow) + " foreground is the app window=" + ($foreground -eq $firstWindow) + " (Windows only lets it take the foreground when the second launch had foreground rights; this test launches it from a background task)")
    [ModeCheckU32]::ShowWindow($firstWindow, 9) | Out-Null; [ModeCheckU32]::SetForegroundWindow($firstWindow) | Out-Null; Start-Sleep 1
    $ownershipFile = Join-Path $env:TEMP 'roo-industries-ownership-probe.txt'
    'x' | Set-Content $ownershipFile
    $third = Start-Process $Exe -ArgumentList '--ownership-review', ('"' + $ownershipFile + '"') -PassThru
    $thirdExited = $third.WaitForExit(30000)
    $opened = Eventually { $status = ById 'WindowsTweaksStatus'; $status -and $status.Current.Name -eq 'Review file ownership' } 45
    Check ($thirdExited -and $opened) 'a second launch with --ownership-review opens that review in the open window' ("second exited=" + $thirdExited + " status=" + $(if (ById 'WindowsTweaksStatus') { (ById 'WindowsTweaksStatus').Current.Name } else { '<none>' }))
    Shot 'second-launch-ownership'
    Remove-Item $ownershipFile -Force -ErrorAction SilentlyContinue
    if (-not $thirdExited) { Stop-Process -Id $third.Id -Force -ErrorAction SilentlyContinue }
    if (-not $secondExited) { Stop-Process -Id $second.Id -Force -ErrorAction SilentlyContinue }
    Get-Process RooIndustries.OptimizationSuite.App -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $first.Id } | Stop-Process -Force -ErrorAction SilentlyContinue

    Nav 'Games'
    $tab = WaitFor { ById 'BackgroundTab' } 30 'Background apps tab'
    Invoke-Element $tab; Start-Sleep 2
    $scroller = try { WaitFor { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::IsScrollPatternAvailableProperty, $true)) | Where-Object { -not $_.Current.IsOffscreen -and $_.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable -and $_.Current.BoundingRectangle.Height -gt 300 } | Select-Object -Last 1) } 30 'scrollable Background apps list' } catch { $null }
    if (-not $scroller) { $script:Skipped++; Log 'NOT RUN the Background apps scroll check: the list is not long enough to scroll on this PC' }
    else {
    $scroll = $scroller.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
    $scroll.SetScrollPercent(-1, 60); Start-Sleep 1
    $set = $scroll.Current.VerticalScrollPercent
    Nav 'Home'; Start-Sleep 2; Nav 'Games'; Start-Sleep 4
    $scroller = WaitFor { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::IsScrollPatternAvailableProperty, $true)) | Where-Object { -not $_.Current.IsOffscreen -and $_.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable -and $_.Current.BoundingRectangle.Height -gt 300 } | Select-Object -Last 1) } 30 'scrollable Background apps list'
    $kept = $scroller.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticalScrollPercent
    Check ($set -gt 30 -and [Math]::Abs($kept - $set) -lt 15) 'the Background apps list keeps its scroll position after a revisit refreshes it' ("set=" + [Math]::Round($set, 1) + "% after revisit=" + [Math]::Round($kept, 1) + "%")
    Shot 'games-scroll-after-revisit'
    }
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    if ($script:HangFlag) { Remove-Item $script:HangFlag -Force -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '-n 400 127\.0\.0\.1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    foreach ($path in @($script:Renamed)) { try { Restore-Script $path } catch { Log ('CLEANUP NEEDED: restore ' + $path) } }
    if ($null -ne $wasSimple) { try { if (-not $script:App -or $script:App.HasExited) { Start-RooIndustriesApp }; Set-Simple $wasSimple | Out-Null } catch { Log ('CLEANUP NEEDED: simple mode ' + $wasSimple) } }
    Stop-RooIndustriesApp
    Log ('RESULT failures=' + $script:Failures + ' skipped=' + $script:Skipped)
    'x' | Set-Content (Join-Path $OutDir 'modes.done')
}
