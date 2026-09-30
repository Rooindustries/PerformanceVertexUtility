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
}
'@
[ModeCheckU32]::SetProcessDPIAware() | Out-Null
[ModeCheckU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir 'modes.log'
$script:Failures = 0
$script:Renamed = @()

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
function Start-Roo {
    Stop-Roo
    $script:App = Start-Process $Exe -PassThru
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [ModeCheckU32]::ShowWindow($h, 9) | Out-Null; [ModeCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [ModeCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { Named 'Start here' } 60 'Home' | Out-Null
}
function Stop-Roo {
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
function Script-Path([string]$name) {
    $root = Split-Path (Split-Path $Exe -Parent) -Parent
    $found = @(Get-ChildItem $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) { throw "Expected one $name under the install folder, found $($found.Count)." }
    return $found[0].FullName
}
function Disable-Script([string]$path) { Rename-Item $path ($path + '.roo-test-off'); $script:Renamed += $path; Log ("disabled " + (Split-Path $path -Leaf)) }
function Restore-Script([string]$path) {
    if (Test-Path ($path + '.roo-test-off')) { Rename-Item ($path + '.roo-test-off') $path }
    $script:Renamed = @($script:Renamed | Where-Object { $_ -ne $path }); Log ("restored " + (Split-Path $path -Leaf))
}
function Memory-Error { @(Named 'Memory information is unavailable').Count -gt 0 }
function Memory-Loaded { (@(Named 'Memory by process').Count -gt 0) -and -not (Memory-Error) }
function Memory-Note { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text)) | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.Name -like 'Memory by process is unavailable*' }).Count -gt 0 }

$wasSimple = $null
try {
    Start-Roo
    $wasSimple = Set-Simple $true
    Start-Roo
    Check-Mode $true 'with simple mode on at launch'
    Set-Simple $false | Out-Null
    Check-Mode $false 'after switching simple mode off'
    Set-Simple $true | Out-Null
    Check-Mode $true 'after switching simple mode back on'
    Set-Simple $false | Out-Null
    Stop-Roo

    $inventory = Script-Path 'Get-ProcessInventory.ps1'
    $classification = Script-Path 'Get-ProcessClassification.ps1'
    Disable-Script $inventory; Disable-Script $classification
    Start-Roo
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
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    foreach ($path in @($script:Renamed)) { try { Restore-Script $path } catch { Log ('CLEANUP NEEDED: restore ' + $path) } }
    if ($null -ne $wasSimple) { try { if (-not $script:App -or $script:App.HasExited) { Start-Roo }; Set-Simple $wasSimple | Out-Null } catch { Log ('CLEANUP NEEDED: simple mode ' + $wasSimple) } }
    Stop-Roo
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir 'modes.done')
}
