param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class HardwareCheckU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
[HardwareCheckU32]::SetProcessDPIAware() | Out-Null
[HardwareCheckU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir 'hardware.log'
$script:Failures = 0
$script:App = $null

function Log([string]$m) { [IO.File]::AppendAllText($script:LogPath, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m + "`r`n") }
function Check([bool]$ok, [string]$name, [string]$detail) { if (-not $ok) { $script:Failures++ }; Log ($(if ($ok) { 'PASS ' } else { 'FAIL ' }) + $name + ' :: ' + $detail) }
function WaitFor([scriptblock]$probe, [double]$seconds, [string]$what) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { try { $r = & $probe } catch { $r = $null }; if ($r) { return $r }; Start-Sleep -Milliseconds 100 }
    throw "Timed out waiting for $what"
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
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [HardwareCheckU32]::ShowWindow($h, 9) | Out-Null; [HardwareCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [HardwareCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}
function Stop-RooIndustriesApp {
    if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { $script:App.Kill() } }
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
}
function App-Log {
    $root = [Environment]::GetFolderPath('LocalApplicationData')
    $folder = if (Test-Path (Join-Path $root ('RooIndustriesOptimizationSuite' -replace 'Industries',''))) { ('RooIndustriesOptimizationSuite' -replace 'Industries','') } else { 'RooIndustriesOptimizationSuite' }
    Join-Path $root ($folder + '\logs\app.log')
}
function Hardware-Reads {
    $log = App-Log
    if (-not (Test-Path $log)) { return 0 }
    @(Get-Content $log | Select-String '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \[timing\] Get-DriverHardwareSummary\.ps1' | Where-Object { [datetime]::ParseExact($_.Matches[0].Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null) -ge $script:Started }).Count
}

try {
    $script:Started = (Get-Date).AddSeconds(-2)
    $before = Hardware-Reads
    Start-RooIndustriesApp
    Nav 'Home'
    $first = WaitFor { $n = Hardware-Reads; if ($n -gt $before) { $n } } 60 'the first hardware summary read'
    Log "hardware summary reads after the first Home visit: $first"
    Nav 'Settings'; Start-Sleep 3; Nav 'Home'; Start-Sleep 5
    $quick = Hardware-Reads
    Check ($quick -eq $first) 'a revisit to Home within 10 minutes reuses the hardware summary' ("reads before=$first after=$quick")
    Nav 'Settings'
    Log 'waiting 10.5 minutes'
    Start-Sleep 630
    Nav 'Home'
    $reread = $false; $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $reread) { $reread = (Hardware-Reads) -gt $quick; if (-not $reread) { Start-Sleep 1 } }
    Check $reread 'Home reads the hardware summary again on a visit more than 10 minutes after the last read' ("reads before=$quick after=" + (Hardware-Reads))
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)) }
finally {
    Stop-RooIndustriesApp
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir 'hardware.done')
}
