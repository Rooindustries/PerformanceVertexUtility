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
public static class CacheCheckU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
[CacheCheckU32]::SetProcessDPIAware() | Out-Null
[CacheCheckU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir 'invalidation.log'
$script:Failures = 0
$Setting = 'windows.0689e69eedc05770'
$CheckProfile = 'roo-cache-check'
$Personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

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
function ById($id) { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, $id)) }
function Texts { @($script:Win.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text)) | Where-Object { -not $_.Current.IsOffscreen } | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) }
function Invoke-Element($e) {
    try { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); return } catch {}
    try { $e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); return } catch {}
    $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
}
function Set-Toggle($e, [bool]$on) {
    $pattern = $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if (([string]$pattern.Current.ToggleState -eq 'On') -ne $on) { $pattern.Toggle(); Start-Sleep -Milliseconds 400 }
}
function Nav([string]$name) {
    $item = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, $name), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))) } 30 "nav $name"
    Invoke-Element $item; Log "nav $name"
}
function Tweaks-Idle { WaitFor { $r = ById 'WindowsTweaksRefresh'; $s = ById 'WindowsTweaksStatus'; if ($r -and $r.Current.IsEnabled -and $s -and $s.Current.Name -notmatch '^Loading') { $s.Current.Name } } 600 'Windows tweaks idle' }
function Review-Texts { @((ById 'WindowsTweaksReview').FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text)) | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) }
function Transparency { $v = Get-ItemProperty $Personalize -Name EnableTransparency -ErrorAction SilentlyContinue; if ($v) { [string]$v.EnableTransparency } else { '<absent>' } }
function Has-Profile([string[]]$texts) { for ($i = 0; $i -lt $texts.Count - 1; $i++) { if ($texts[$i] -ceq $CheckProfile -and $texts[$i + 1] -match 'selected settings') { return $true } }; return $false }
function Undo-Profiles { Nav 'Undo changes'; WaitFor { $t = @(Texts); if (($t -contains 'Saved settings') -and ($t -notcontains 'Reading restore state')) { $t } } 60 'Undo page' }
function Find-Row {
    $search = WaitFor { ById 'WindowsTweaksSearch' } 30 'search box'
    $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Transparency Effects'); Start-Sleep 1
    WaitFor { ById ($Setting + '.select') } 30 'Transparency Effects row'
}
function Apply-Reviewed([string]$what) {
    $texts = @(Review-Texts)
    Log ("$what review: " + ($texts -join ' | '))
    if ((($texts -join ' ') -notmatch 'Transparency') -or @($texts | Where-Object { $_ -match 'timer|Hypervisor|SEHOP|IPv6|Firewall|Defender' }).Count) { throw "$what review is not exactly the Transparency change; refusing to apply" }
    Set-Toggle (ById 'WindowsTweaksApproval') $true
    Invoke-Element (WaitFor { $b = ById 'WindowsTweaksApply'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'apply button'); Start-Sleep 2
    Tweaks-Idle | Out-Null
}

$app = $null
$script:Cleanup = $null
try {
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
    $app = Start-Process $Exe -PassThru
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $app.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 120 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [CacheCheckU32]::ShowWindow($h, 9) | Out-Null; [CacheCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [CacheCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null

    $before = @(Undo-Profiles)
    if (Has-Profile $before) { throw "A $CheckProfile profile already exists on this PC; refusing to change it." }
    Log ('Undo before: ' + ($before -join ' | ')); Shot '1-undo-before'
    $registryBefore = Transparency
    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $advanced = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Show advanced options')) } 20 'Show advanced options'
    Set-Toggle $advanced $true; Start-Sleep 1
    $expander = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profiles & tools')) } 20 'Profiles & tools'
    try { $expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
    $name = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profile name'), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Edit))) } 20 'Profile name box'
    $name.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($CheckProfile); Start-Sleep 1
    Log ('profile name set to ' + $name.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value)
    $row = Find-Row
    $target = if ($registryBefore -eq '0') { 'On (1)' } else { 'Off (0)' }
    Set-Toggle $row $true
    $combo = WaitFor { ById ($Setting + '.value') } 20 'value combo'
    $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -Milliseconds 800
    $choice = WaitFor { $combo.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, $target)) } 10 "choice $target"
    $choice.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 500
    Invoke-Element (ById 'WindowsTweaksPreview'); Start-Sleep 2; Tweaks-Idle | Out-Null
    $script:Cleanup = "restore the $CheckProfile profile in Windows tweaks; EnableTransparency was $registryBefore"
    Apply-Reviewed 'apply'
    $registryApplied = Transparency
    Check ($registryApplied -ne $registryBefore) 'apply changed the registry value' "before=$registryBefore after=$registryApplied"
    Shot '2-applied'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $after = @(Undo-Profiles)
    Check (Has-Profile $after) 'cached Undo page reloads after the apply and lists the new profile' ("ms=" + $sw.ElapsedMilliseconds + " :: " + ($after -join ' | '))
    Shot '3-undo-after-apply'

    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
    Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
    Apply-Reviewed 'restore'
    $registryRestored = Transparency
    Check ($registryRestored -eq $registryBefore) 'restore returned the registry value' "before=$registryBefore restored=$registryRestored"
    if ($registryRestored -eq $registryBefore) { $script:Cleanup = $null }

    $final = @(Undo-Profiles)
    Check (-not (Has-Profile $final)) 'cached Undo page reloads after the restore and drops the profile' ($final -join ' | ')
    Shot '4-undo-after-restore'
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    if ($app -and -not $app.HasExited) { $app.CloseMainWindow() | Out-Null; if (-not $app.WaitForExit(20000)) { $app.Kill() } }
    if ($script:Cleanup) { Log ('CLEANUP NEEDED: ' + $script:Cleanup) }
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir 'invalidation.done')
}
