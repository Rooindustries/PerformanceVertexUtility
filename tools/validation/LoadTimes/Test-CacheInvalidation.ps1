param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
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
$script:Skipped = 0
$Setting = 'windows.0689e69eedc05770'
$CheckProfile = 'roo-industries-cache-check'
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
function Open-TransparencyRegistry {
    $key = Get-Item -LiteralPath $Personalize
    try { $name = $key.Name } finally { $key.Dispose() }
    if (-not $name.StartsWith('HKEY_CURRENT_USER\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Transparency registry hive differs; retained' }
    $writable = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($name.Substring(18), $true)
    if (-not $writable) { throw 'Transparency registry key unavailable; retained' }
    $writable
}
function Has-Profile([string[]]$texts) { for ($i = 0; $i -lt $texts.Count - 1; $i++) { if ($texts[$i] -ceq $CheckProfile -and $texts[$i + 1] -match 'selected settings') { return $true } }; return $false }
function Undo-Profiles { Nav 'Undo changes'; WaitFor { $t = @(Texts); if (($t -contains 'Saved settings') -and ($t -notcontains 'Reading restore state')) { $t } } 60 'Undo page' }
function Find-Row {
    $search = WaitFor { ById 'WindowsTweaksSearch' } 30 'search box'
    $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Transparency Effects'); Start-Sleep 1
    WaitFor { ById ($Setting + '.select') } 30 'Transparency Effects row'
}
function Combo-Items([string]$id) {
    $combo = WaitFor { $c = ById $id; if ($c -and $c.Current.IsEnabled) { $c } } 60 "$id enabled"
    $pattern = $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
    $pattern.Expand(); Start-Sleep -Milliseconds 700
    $names = @($combo.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem)) | ForEach-Object { $_.Current.Name })
    try { $pattern.Collapse() } catch {}; Start-Sleep -Milliseconds 300
    return $names
}
function Wait-Listed([string]$id, [bool]$present, [double]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do { $names = @(Combo-Items $id); $found = @($names | Where-Object { $_ -like '*RooIndustriesLoadTimesProbe*' }).Count -gt 0; if ($found -eq $present) { return $true }; Start-Sleep 1 } while ((Get-Date) -lt $deadline)
    return $false
}
function Select-Tab([string]$id) { Invoke-Element (WaitFor { ById $id } 20 $id); Start-Sleep 1 }
function Governor-Row {
    Nav 'Undo changes'
    WaitFor { $t = @(Texts); $i = [Array]::IndexOf($t, 'Roo Industries Governor'); if (($t -notcontains 'Reading restore state') -and $i -ge 0 -and $i -lt $t.Count - 1) { $t[$i + 1] } } 60 'Governor row on the Undo page'
}
function Pick([string]$id, [string]$like) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $combo = WaitFor { $c = ById $id; if ($c -and $c.Current.IsEnabled) { $c } } 60 "$id enabled"
        $pattern = $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
        $pattern.Expand(); Start-Sleep -Milliseconds 700
        $item = WaitFor { @($combo.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem)) | Where-Object { $_.Current.Name -like $like })[0] } 20 "$id item $like"
        try { $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
        catch {
            if ($_.FullyQualifiedErrorId -ne 'ElementNotEnabledException' -or $attempt -eq 4) { throw }
            Log "the $id list was refreshed while choosing $like; trying again"
            try { $pattern.Collapse() } catch {}
            Start-Sleep -Seconds 2
            continue
        }
        Start-Sleep -Milliseconds 500
        try { $pattern.Collapse() } catch {}
        return
    }
}
function Process-Status([string]$pattern, [double]$seconds, [string]$what) { WaitFor { $s = ById 'ProcessStatus'; if ($s -and $s.Current.Name -match $pattern) { $s.Current.Name } } $seconds $what }
function Apply-Reviewed([string]$what, [switch]$NoWait) {
    WaitFor { $r = ById 'WindowsTweaksReview'; if ($r -and @($r.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text))).Count) { $r } } 60 "$what review" | Out-Null
    $texts = @(Review-Texts)
    Log ("$what review: " + ($texts -join ' | '))
    if ((($texts -join ' ') -notmatch 'Transparency') -or @($texts | Where-Object { $_ -match 'timer|Hypervisor|SEHOP|IPv6|Firewall|Defender' }).Count) { throw "$what review is not exactly the Transparency change; refusing to apply" }
    Set-Toggle (ById 'WindowsTweaksApproval') $true
    $apply = WaitFor { $b = ById 'WindowsTweaksApply'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'apply button'
    if ($what -eq 'apply') {
        if ((Get-OwnedRegistryField $script:RegistryBefore.key $script:RegistryBefore.name) -cne $script:RegistryBefore.before) { throw 'EnableTransparency changed before apply; retained' }
    } else { Assert-OwnedRegistryFieldCurrent $script:RegistryBefore | Out-Null }
    Invoke-Element $apply
    if ($NoWait) { return }
    Start-Sleep 2
    Tweaks-Idle | Out-Null
}

$app = $null
$script:Cleanup = $null
$script:App = $null
$script:RegistryBefore = $null
function Start-RooIndustriesApp {
    Stop-RooIndustriesApp
    $script:App = Start-Process $Exe -PassThru
    $script:AppReceipt = New-OwnedProcess $script:App
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [CacheCheckU32]::ShowWindow($h, 9) | Out-Null; [CacheCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [CacheCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}
function Stop-RooIndustriesApp {
    Stop-OwnedValidationApp $script:App $script:AppReceipt
}
function Select-ComboItem([string]$id, [string]$like) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $combo = WaitFor { $c = ById $id; if ($c -and $c.Current.IsEnabled) { $c } } 60 "$id enabled"
        $pattern = $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
        $pattern.Expand(); Start-Sleep -Milliseconds 700
        $item = WaitFor { @($combo.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem)) | Where-Object { $_.Current.Name -like $like })[0] } 10 "$like in $id"
        try { $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
        catch {
            if ($_.FullyQualifiedErrorId -ne 'ElementNotEnabledException' -or $attempt -eq 4) { throw }
            Log "the $id list was refreshed while choosing $like; trying again"
            try { $pattern.Collapse() } catch {}
            Start-Sleep -Seconds 2
            continue
        }
        Start-Sleep -Milliseconds 500
        try { $pattern.Collapse() } catch {}
        return
    }
}
function Host-Tree([int]$appId) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate)
    $hosts = @($all | Where-Object { $_.ParentProcessId -eq $appId -and $_.Name -like 'Optimizer.Host*' })
    $found = [Collections.Generic.List[object]]::new(); $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($h in $hosts) { $found.Add($h); $queue.Enqueue($h) }
    while ($queue.Count) { $parent = $queue.Dequeue(); foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $parent.ProcessId -and $_.ProcessId -ne $parent.ProcessId -and $_.CreationDate -ge $parent.CreationDate }) { $found.Add($child); $queue.Enqueue($child) } }
    return $found
}

$probePath = Join-Path $env:TEMP 'RooIndustriesLoadTimesProbe.exe'
$probe = $null; $probe2 = $null
$probeFile = $null
$script:ProbeReceipts = [Collections.Generic.List[object]]::new()
function Start-CacheProbe([int]$Seconds) {
    $process = Start-Process $probePath -ArgumentList '-n', $Seconds, '127.0.0.1' -WindowStyle Hidden -PassThru
    $script:ProbeReceipts.Add((New-OwnedProcess $process))
    $process | Add-Member -MemberType NoteProperty -Name OwnershipReceipt -Value $script:ProbeReceipts[$script:ProbeReceipts.Count - 1]
    $process
}
$script:RuleSaved = $false
$script:RuleTest = $false
$script:GovernorRule = $false
$ruleName = 'roo-industries-cache-check rule'
try {
    Start-RooIndustriesApp
    $app = $script:App

    $before = @(Undo-Profiles)
    if (Has-Profile $before) { throw "A $CheckProfile profile already exists on this PC; refusing to change it." }
    Log ('Undo before: ' + ($before -join ' | ')); Shot '1-undo-before'
    $targetValue = if ((Transparency) -eq '0') { [int]1 } else { [int]0 }
    $registryKey = Open-TransparencyRegistry
    $script:RegistryBefore = New-OwnedRegistryFieldIntent $registryKey 'EnableTransparency' $targetValue 'DWord'
    $registryBefore = if ($script:RegistryBefore.before -ceq 'absent') { '<absent>' } else { [string]$script:RegistryBefore.original }
    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $advanced = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Show advanced options')) } 20 'Show advanced options'
    Set-Toggle $advanced $true; Start-Sleep 1
    $expander = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profiles & tools')) } 20 'Profiles & tools'
    try { $expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
    $name = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profile name'), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Edit))) } 20 'profile name'
    $name.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($CheckProfile); Start-Sleep 1
    Log ('profile name set to ' + $name.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value)
    $row = Find-Row
    $target = if ($targetValue -eq 1) { 'On (1)' } else { 'Off (0)' }
    Set-Toggle $row $true
    $combo = WaitFor { ById ($Setting + '.value') } 20 'value combo'
    $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -Milliseconds 800
    $choice = WaitFor { $combo.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, $target)) } 10 "choice $target"
    $choice.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 500
    Invoke-Element (ById 'WindowsTweaksPreview'); Start-Sleep 2; Tweaks-Idle | Out-Null
    $script:Cleanup = "restore the $CheckProfile profile in Windows tweaks; EnableTransparency was $registryBefore"
    Apply-Reviewed 'apply' -NoWait
    $registryAtNav = Transparency
    Nav 'Undo changes'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    WaitFor { $t = @(Texts); if (Has-Profile $t) { $t } } 120 'the new profile on the Undo page left open during the apply' | Out-Null
    Check $true 'Undo page opened while the apply was running shows the new profile once the apply finishes, without navigating again' ("registry when the Undo page opened=" + $registryAtNav + " (before=" + $registryBefore + "), ms after opening=" + $sw.ElapsedMilliseconds)
    Check ($registryAtNav -eq $registryBefore) 'the Undo page was opened before the apply reached Windows' "registry at open=$registryAtNav before=$registryBefore"
    WaitFor { if ((Get-OwnedRegistryField $script:RegistryBefore.key $script:RegistryBefore.name) -ceq $script:RegistryBefore.after) { $true } } 60 'the expected typed registry change' | Out-Null
    $registryApplied = Transparency
    Check ((Get-OwnedRegistryField $script:RegistryBefore.key $script:RegistryBefore.name) -ceq $script:RegistryBefore.after) 'apply changed the registry value' "before=$registryBefore after=$registryApplied"
    Shot '2-applied'
    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $after = @(Undo-Profiles)
    Check (Has-Profile $after) 'cached Undo page still lists the new profile on revisit' ("ms=" + $sw.ElapsedMilliseconds)
    Shot '3-undo-after-apply'

    $probeFile = Copy-OwnedProbe (Join-Path $env:SystemRoot 'System32\PING.EXE') $probePath
    Nav 'Games'; Start-Sleep 2; Select-Tab 'ProcessesTab'; Start-Sleep 3
    Check (Wait-Listed 'ProcessPicker' $false 5) 'Processes list does not show the probe before it starts' ''
    Select-Tab 'GamesTab'
    Check (Wait-Listed 'GameSessionLauncher' $false 5) 'Games launcher list does not show the probe before it starts' ''
    Nav 'Home'; Start-Sleep 2
    $probe = Start-CacheProbe 600
    Start-Sleep 4
    Nav 'Games'; Start-Sleep 1
    Check (Wait-Listed 'GameSessionLauncher' $true 20) 'Games launcher list shows a process started while the page was cached' ''
    Select-Tab 'ProcessesTab'
    Check (Wait-Listed 'ProcessPicker' $true 20) 'Processes list shows a process started while the page was cached' ''
    Select-Tab 'GamesTab'
    Nav 'Home'; Start-Sleep 1
    Stop-OwnedProcess $probe.OwnershipReceipt; $probe.WaitForExit(10000) | Out-Null
    Start-Sleep 4
    Nav 'Games'; Start-Sleep 1
    Check (Wait-Listed 'GameSessionLauncher' $false 20) 'Games launcher list drops a process that exited while the page was cached' ''
    Select-Tab 'ProcessesTab'
    Check (Wait-Listed 'ProcessPicker' $false 20) 'Processes list drops a process that exited while the page was cached' ''

    $probe2 = Start-CacheProbe 900
    Start-Sleep 4
    Nav 'Home'; Start-Sleep 1; Nav 'Games'; Start-Sleep 1
    Select-Tab 'GamesTab'
    WaitFor { if (Wait-Listed 'GameSessionLauncher' $true 5) { $true } } 30 'probe in the launcher list' | Out-Null
    Select-ComboItem 'GameSessionLauncher' '*RooIndustriesLoadTimesProbe*'
    Start-Sleep 3
    $statusBefore = (WaitFor { ById 'GameSessionStatus' } 20 'Games tab status').Current.Name
    Log ("Games tab status with the probe selected as launcher: " + $statusBefore)

    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
    Assert-OwnedRegistryFieldCurrent $script:RegistryBefore | Out-Null
    Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
    Apply-Reviewed 'restore'
    $registryRestored = Transparency
    Check ((Get-OwnedRegistryField $script:RegistryBefore.key $script:RegistryBefore.name) -ceq $script:RegistryBefore.before) 'restore returned the registry value' "before=$registryBefore restored=$registryRestored"
    if ((Get-OwnedRegistryField $script:RegistryBefore.key $script:RegistryBefore.name) -ceq $script:RegistryBefore.before) { $script:Cleanup = $null }
    $final = @(Undo-Profiles)
    Check (-not (Has-Profile $final)) 'cached Undo page reloads after the restore and drops the profile' ''
    Shot '4-undo-after-restore'

    Nav 'Games'; Start-Sleep 1; Select-Tab 'GamesTab'
    $notice = $false; $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) { $s = ById 'GameSessionStatus'; if ($s -and $s.Current.Name -eq 'Settings changed elsewhere') { $notice = $true; break }; Start-Sleep 1 }
    Check $notice 'the Games tab with a launcher picked says settings changed elsewhere after a change on another page' ("status before=" + $statusBefore + " now=" + (ById 'GameSessionStatus').Current.Name)
    Shot '5-games-notice'
    Stop-OwnedProcess $probe2.OwnershipReceipt

    $ruleTasksBefore = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' })
    $policyRoot = Get-ChildItem $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OptimizationSuite' } | ForEach-Object { Join-Path $_.FullName 'process-rules' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    $governorBuild = (@(Undo-Profiles) -contains 'Roo Industries Governor')
    if ($governorBuild) {
        $probe = Start-CacheProbe 900
        Start-Sleep 3
        $rowBefore = Governor-Row
        Log ('Governor row before the rule: ' + $rowBefore); Shot '5-undo-before-rule'
        if ($rowBefore -ne 'No rules') { throw "The governor already has rules on this PC ($rowBefore); refusing to add a test rule." }
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        Invoke-Element (WaitFor { ById 'ProcessRefresh' } 20 'process refresh'); Start-Sleep 2
        Pick 'ProcessPicker' '*RooIndustriesLoadTimesProbe*'
        Process-Status '^Controls for' 60 'probe controls' | Out-Null
        Pick 'cpuPriority' 'Below normal'
        Invoke-Element (WaitFor { $b = ById 'ProcessPreview'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'review button')
        Process-Status '^Review the requested controls' 60 'process review' | Out-Null
        try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        (WaitFor { ById 'ProcessRuleName' } 10 'rule name').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($ruleName); Start-Sleep 1
        $script:Cleanup = "delete the governor rule '$ruleName' in Games > Processes"; $script:GovernorRule = $true
        Invoke-Element (WaitFor { $b = ById 'ProcessSaveRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'save rule button')
        $saved = Process-Status '^(Rule saved and (on|enabled)\.|Rule saved\. The governor is paused|Saved rules need attention)' 180 'rule save'
        Check ($saved -match '^Rule saved') 'the governor rule was saved' ($saved + ' :: ' + (ById 'ProcessDetail').Current.Name)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rowAfter = Governor-Row
        Check ($rowAfter -match '^Running') 'cached Undo page shows the governor row for the new rule on return' ("row=" + $rowAfter + " ms=" + $sw.ElapsedMilliseconds)
        Shot '6-undo-after-rule'

        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        Pick 'ProcessRulesList' ($ruleName + '*')
        Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule button')
        $deleted = Process-Status '^(Rule deleted|Couldn.t update the rule)' 180 'rule delete'
        Check ($deleted -match '^Rule deleted') 'the governor rule was deleted' ($deleted + ' :: ' + (ById 'ProcessDetail').Current.Name)
        if ($deleted -match '^Rule deleted') { $script:Cleanup = $null; $script:GovernorRule = $false }
        $rowDeleted = Governor-Row
        Check ($rowDeleted -eq 'No rules') 'cached Undo page drops the governor rule after it is deleted' ("row=" + $rowDeleted)
        Shot '7-undo-after-delete'
        Stop-OwnedProcess $probe.OwnershipReceipt
    }
    elseif ($ruleTasksBefore.Count -or $policyRoot) {
        $script:Skipped++; Log ('SKIPPED the process rule check: this PC already has saved process rules or a rule task (' + $ruleTasksBefore.Count + ' tasks); the test does not touch them')
    }
    else {
        Stop-RooIndustriesApp
        $probe2 = Start-CacheProbe 900
        Start-RooIndustriesApp
        Nav 'Games'; Start-Sleep 2; Select-Tab 'ProcessesTab'
        Select-ComboItem 'ProcessPicker' '*RooIndustriesLoadTimesProbe*'
        $priority = WaitFor { $c = ById 'cpuPriority'; if ($c -and $c.Current.IsEnabled) { $c } } 30 'CPU priority control'
        $pattern = $priority.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern); $pattern.Expand(); Start-Sleep -Milliseconds 700
        $options = @($priority.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem)))
        @($options | Where-Object { $_.Current.Name -match 'Below normal' })[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 500
        try { $pattern.Collapse() } catch {}
        Invoke-Element (WaitFor { $b = ById 'ProcessPreview'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'process review button')
        $rules = WaitFor { ById 'ProcessSavedRules' } 20 'saved rules'
        try { $rules.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        $save = WaitFor { $b = ById 'ProcessSaveRule'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'save rule button'
        $script:RuleTest = $true
        $script:Cleanup = 'delete the RooIndustriesLoadTimesProbe rule, stop the rule worker, remove the rule task and the process-rules folder'
        Invoke-Element $save; $script:RuleSaved = $true
        WaitFor { $s = ById 'ProcessStatus'; if ($s -and $s.Current.Name -match 'Rule saved and enabled|need attention') { $s.Current.Name } } 60 'rule save result' | Out-Null
        Log ('rule save status: ' + (ById 'ProcessStatus').Current.Name)
        Select-Tab 'GamesTab'; Nav 'Undo changes'; Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        $listed = @(Combo-Items 'ProcessRulesList') -join ' | '
        Check ($listed -match 'RooIndustriesLoadTimesProbe') 'a saved process rule is listed on the Processes tab after leaving and returning' $listed
        $undoTexts = @(Undo-Profiles) -join ' | '
        Log ('Undo page after the rule save (this branch does not list process rules there): ' + $undoTexts.Substring(0, [Math]::Min(300, $undoTexts.Length)))
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        Select-ComboItem 'ProcessRulesList' '*RooIndustriesLoadTimesProbe*'
        Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule')
        WaitFor { $s = ById 'ProcessStatus'; if ($s -and $s.Current.Name -match 'Rule deleted|Couldn') { $true } } 60 'rule delete' | Out-Null
        $stop = ById 'ProcessStopWorker'; if ($stop -and $stop.Current.IsEnabled) { Invoke-Element $stop; Start-Sleep 5 }
        $left = @(Combo-Items 'ProcessRulesList') -join ' | '
        if ($left -notmatch 'RooIndustriesLoadTimesProbe') { $script:RuleSaved = $false }
        Check (-not $script:RuleSaved) 'the test rule was deleted and the rule worker stopped' $left
        Stop-OwnedProcess $probe2.OwnershipReceipt
    }

    Stop-RooIndustriesApp
    Start-RooIndustriesApp
    WaitFor { if (@(Host-Tree $script:App.Id).Count) { $true } } 20 'the Windows tweaks preload helper' | Out-Null
    Log ('preload helpers before opening Windows tweaks: ' + ((@(Host-Tree $script:App.Id) | ForEach-Object { $_.Name + ':' + (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).PriorityClass }) -join ', '))
    Nav 'Windows tweaks'
    $seen = @{}; $low = @()
    $sample = [Diagnostics.Stopwatch]::StartNew()
    while ($sample.ElapsedMilliseconds -lt 4000) {
        foreach ($p in @(Host-Tree $script:App.Id)) {
            try { $pc = (Get-Process -Id $p.ProcessId -ErrorAction Stop).PriorityClass; $key = $p.Name + ':' + $pc; if (-not $seen.ContainsKey($key)) { $seen[$key] = $sample.ElapsedMilliseconds }; if ($sample.ElapsedMilliseconds -gt 1500 -and "$pc" -eq 'BelowNormal') { $low += $p.Name } } catch {}
        }
        Start-Sleep -Milliseconds 200
    }
    $summary = ($seen.GetEnumerator() | Sort-Object Value | ForEach-Object { $_.Key + '@' + $_.Value + 'ms' }) -join ', '
    Check ($seen.Count -gt 0 -and $low.Count -eq 0) 'opening Windows tweaks while its preload runs raises the preload helper processes to normal priority' $summary
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    foreach ($receipt in $script:ProbeReceipts) { try { Stop-OwnedProcess $receipt } catch { $script:Failures++; Log ('CLEANUP NEEDED: probe retained: ' + $_.Exception.Message) } }
    if ($script:GovernorRule) {
        try {
            if (-not $script:App -or $script:App.HasExited) { Start-RooIndustriesApp }
            Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
            try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
            Pick 'ProcessRulesList' ($ruleName + '*')
            Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule button')
            $deleted = Process-Status '^(Rule deleted|Couldn.t update the rule)' 180 'rule delete'
            if ($deleted -match '^Rule deleted') { $script:GovernorRule = $false; Log 'cleanup: deleted the governor test rule' }
        } catch { Log ('cleanup: could not delete the governor test rule: ' + $_.Exception.Message) }
        if ($script:GovernorRule) { Log "CLEANUP NEEDED: delete the governor rule '$ruleName' in Games > Processes" }
    }
    if ($script:RuleSaved) {
        try {
            if (-not $script:App -or $script:App.HasExited) { Start-RooIndustriesApp }
            Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
            Select-ComboItem 'ProcessRulesList' '*RooIndustriesLoadTimesProbe*'
            Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule')
            Start-Sleep 5
            $stop = ById 'ProcessStopWorker'; if ($stop -and $stop.Current.IsEnabled) { Invoke-Element $stop; Start-Sleep 5 }
            if ((@(Combo-Items 'ProcessRulesList') -join ' ') -notmatch 'RooIndustriesLoadTimesProbe') { $script:RuleSaved = $false; Log 'cleanup: deleted the test rule' }
        } catch { Log ('cleanup: could not delete the test rule: ' + $_.Exception.Message) }
        if ($script:RuleSaved) { Log 'CLEANUP NEEDED: delete the RooIndustriesLoadTimesProbe rule on the Processes tab and stop the rule worker' }
    }
    if ($script:RuleTest -and ($script:RuleSaved -or $script:GovernorRule)) {Log 'CLEANUP NEEDED: rule cleanup failed; retained the rules and recovery state for the owner.'}
    if ($null -ne $script:RegistryBefore) {
        try {
            $current = Assert-OwnedRegistryFieldCurrent $script:RegistryBefore
            if ($current -cne $script:RegistryBefore.before) {
                try {
                    if (-not $script:App -or $script:App.HasExited) { Start-RooIndustriesApp }
                    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
                    $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
                    Assert-OwnedRegistryFieldCurrent $script:RegistryBefore | Out-Null
                    Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
                    Apply-Reviewed 'cleanup restore'
                } catch { Log ('cleanup: app restore failed: ' + $_.Exception.Message) }
                $current = Assert-OwnedRegistryFieldCurrent $script:RegistryBefore
                if ($current -cne $script:RegistryBefore.before) {
                    Restore-OwnedRegistryField $script:RegistryBefore
                    Log 'cleanup: restored the exact original EnableTransparency presence, kind and raw value directly'
                    $script:Cleanup = "the app may still list the $CheckProfile profile; restore or delete it in Windows tweaks"
                }
                else { Log 'cleanup: restored the test profile through the app'; $script:Cleanup = $null }
            }
        } catch { $script:Failures++; Log ('CLEANUP NEEDED: EnableTransparency retained: ' + $_.Exception.Message) }
    }
    if ($registryKey) { $registryKey.Dispose() }
    try { Stop-RooIndustriesApp } catch { $script:Failures++; Log ('CLEANUP NEEDED: app retained: ' + $_.Exception.Message) }
    try { Remove-OwnedProbe $probeFile } catch { $script:Failures++; Log ('CLEANUP NEEDED: probe file retained: ' + $_.Exception.Message); if ($probeFile) { $probeFile.Dispose() } }
    if ($script:Cleanup) { Log ('CLEANUP NEEDED: ' + $script:Cleanup) }
    Log ('RESULT failures=' + $script:Failures + ' skipped=' + $script:Skipped)
    'x' | Set-Content (Join-Path $OutDir 'invalidation.done')
}
