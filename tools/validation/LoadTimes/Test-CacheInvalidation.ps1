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
$script:Skipped = 0
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
    do { $names = @(Combo-Items $id); $found = @($names | Where-Object { $_ -like '*RooLoadTimesProbe*' }).Count -gt 0; if ($found -eq $present) { return $true }; Start-Sleep 1 } while ((Get-Date) -lt $deadline)
    return $false
}
function Select-Tab([string]$id) { Invoke-Element (WaitFor { ById $id } 20 $id); Start-Sleep 1 }
function Apply-Reviewed([string]$what, [switch]$NoWait) {
    WaitFor { $r = ById 'WindowsTweaksReview'; if ($r -and @($r.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text))).Count) { $r } } 60 "$what review" | Out-Null
    $texts = @(Review-Texts)
    Log ("$what review: " + ($texts -join ' | '))
    if ((($texts -join ' ') -notmatch 'Transparency') -or @($texts | Where-Object { $_ -match 'timer|Hypervisor|SEHOP|IPv6|Firewall|Defender' }).Count) { throw "$what review is not exactly the Transparency change; refusing to apply" }
    Set-Toggle (ById 'WindowsTweaksApproval') $true
    Invoke-Element (WaitFor { $b = ById 'WindowsTweaksApply'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'apply button')
    if ($NoWait) { return }
    Start-Sleep 2
    Tweaks-Idle | Out-Null
}

$app = $null
$script:Cleanup = $null
$script:App = $null
$script:RegistryBefore = $null
function Start-Roo {
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
    $script:App = Start-Process $Exe -PassThru
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [CacheCheckU32]::ShowWindow($h, 9) | Out-Null; [CacheCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [CacheCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}
function Stop-Roo {
    if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { $script:App.Kill() } }
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
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

$probePath = Join-Path $env:TEMP 'RooLoadTimesProbe.exe'
$probe = $null; $probe2 = $null
$script:RuleSaved = $false
$script:RuleTest = $false
try {
    Start-Roo
    $app = $script:App

    $before = @(Undo-Profiles)
    if (Has-Profile $before) { throw "A $CheckProfile profile already exists on this PC; refusing to change it." }
    Log ('Undo before: ' + ($before -join ' | ')); Shot '1-undo-before'
    $script:RegistryBefore = Transparency
    $registryBefore = $script:RegistryBefore
    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $advanced = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Show advanced options')) } 20 'Show advanced options'
    Set-Toggle $advanced $true; Start-Sleep 1
    $expander = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profiles & tools')) } 20 'Profiles & tools'
    try { $expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
    $name = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profile name'), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Edit))) } 20 'profile name'
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
    Apply-Reviewed 'apply' -NoWait
    $registryAtNav = Transparency
    Nav 'Undo changes'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    WaitFor { $t = @(Texts); if (Has-Profile $t) { $t } } 120 'the new profile on the Undo page left open during the apply' | Out-Null
    Check $true 'Undo page opened while the apply was running shows the new profile once the apply finishes, without navigating again' ("registry when the Undo page opened=" + $registryAtNav + " (before=" + $registryBefore + "), ms after opening=" + $sw.ElapsedMilliseconds)
    Check ($registryAtNav -eq $registryBefore) 'the Undo page was opened before the apply reached Windows' "registry at open=$registryAtNav before=$registryBefore"
    WaitFor { if ((Transparency) -ne $registryBefore) { $true } } 60 'registry change' | Out-Null
    $registryApplied = Transparency
    Check ($registryApplied -ne $registryBefore) 'apply changed the registry value' "before=$registryBefore after=$registryApplied"
    Shot '2-applied'
    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $after = @(Undo-Profiles)
    Check (Has-Profile $after) 'cached Undo page still lists the new profile on revisit' ("ms=" + $sw.ElapsedMilliseconds)
    Shot '3-undo-after-apply'

    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $probePath -Force
    Nav 'Games'; Start-Sleep 2; Select-Tab 'ProcessesTab'; Start-Sleep 3
    Check (Wait-Listed 'ProcessPicker' $false 5) 'Processes list does not show the probe before it starts' ''
    Select-Tab 'GamesTab'
    Check (Wait-Listed 'GameSessionLauncher' $false 5) 'Games launcher list does not show the probe before it starts' ''
    Nav 'Home'; Start-Sleep 2
    $probe = Start-Process $probePath -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep 4
    Nav 'Games'; Start-Sleep 1
    Check (Wait-Listed 'GameSessionLauncher' $true 20) 'Games launcher list shows a process started while the page was cached' ''
    Select-Tab 'ProcessesTab'
    Check (Wait-Listed 'ProcessPicker' $true 20) 'Processes list shows a process started while the page was cached' ''
    Select-Tab 'GamesTab'
    Nav 'Home'; Start-Sleep 1
    Stop-Process -Id $probe.Id -Force; $probe.WaitForExit(10000) | Out-Null
    Start-Sleep 4
    Nav 'Games'; Start-Sleep 1
    Check (Wait-Listed 'GameSessionLauncher' $false 20) 'Games launcher list drops a process that exited while the page was cached' ''
    Select-Tab 'ProcessesTab'
    Check (Wait-Listed 'ProcessPicker' $false 20) 'Processes list drops a process that exited while the page was cached' ''

    $probe2 = Start-Process $probePath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep 4
    Nav 'Home'; Start-Sleep 1; Nav 'Games'; Start-Sleep 1
    Select-Tab 'GamesTab'
    WaitFor { if (Wait-Listed 'GameSessionLauncher' $true 5) { $true } } 30 'probe in the launcher list' | Out-Null
    Select-ComboItem 'GameSessionLauncher' '*RooLoadTimesProbe*'
    Start-Sleep 3
    $statusBefore = (WaitFor { ById 'GameSessionStatus' } 20 'Games tab status').Current.Name
    Log ("Games tab status with the probe selected as launcher: " + $statusBefore)

    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
    Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
    Apply-Reviewed 'restore'
    $registryRestored = Transparency
    Check ($registryRestored -eq $registryBefore) 'restore returned the registry value' "before=$registryBefore restored=$registryRestored"
    if ($registryRestored -eq $registryBefore) { $script:Cleanup = $null }
    $final = @(Undo-Profiles)
    Check (-not (Has-Profile $final)) 'cached Undo page reloads after the restore and drops the profile' ''
    Shot '4-undo-after-restore'

    Nav 'Games'; Start-Sleep 1; Select-Tab 'GamesTab'
    $notice = $false; $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) { $s = ById 'GameSessionStatus'; if ($s -and $s.Current.Name -eq 'Settings changed elsewhere') { $notice = $true; break }; Start-Sleep 1 }
    Check $notice 'the Games tab with a launcher picked says settings changed elsewhere after a change on another page' ("status before=" + $statusBefore + " now=" + (ById 'GameSessionStatus').Current.Name)
    Shot '5-games-notice'
    Stop-Process -Id $probe2.Id -Force -ErrorAction SilentlyContinue

    $ruleTasksBefore = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' })
    $policyRoot = Get-ChildItem $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Roo' } | ForEach-Object { Join-Path $_.FullName 'process-rules' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    $governorBuild = (@(Undo-Profiles) -contains 'Roo Industries Governor')
    if ($governorBuild) {
        $script:Skipped++; Log 'SKIPPED the process rule check: this build has the always-on governor, which has its own scenario'
    }
    elseif ($ruleTasksBefore.Count -or $policyRoot) {
        $script:Skipped++; Log ('SKIPPED the process rule check: this PC already has saved process rules or a rule task (' + $ruleTasksBefore.Count + ' tasks); the test does not touch them')
    }
    else {
        Stop-Roo
        $probe2 = Start-Process $probePath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
        Start-Roo
        Nav 'Games'; Start-Sleep 2; Select-Tab 'ProcessesTab'
        Select-ComboItem 'ProcessPicker' '*RooLoadTimesProbe*'
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
        $script:Cleanup = 'delete the RooLoadTimesProbe rule, stop the rule worker, remove the rule task and the process-rules folder'
        Invoke-Element $save; $script:RuleSaved = $true
        WaitFor { $s = ById 'ProcessStatus'; if ($s -and $s.Current.Name -match 'Rule saved and enabled|need attention') { $s.Current.Name } } 60 'rule save result' | Out-Null
        Log ('rule save status: ' + (ById 'ProcessStatus').Current.Name)
        Select-Tab 'GamesTab'; Nav 'Undo changes'; Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        $listed = @(Combo-Items 'ProcessRulesList') -join ' | '
        Check ($listed -match 'RooLoadTimesProbe') 'a saved process rule is listed on the Processes tab after leaving and returning' $listed
        $undoTexts = @(Undo-Profiles) -join ' | '
        Log ('Undo page after the rule save (this branch does not list process rules there): ' + $undoTexts.Substring(0, [Math]::Min(300, $undoTexts.Length)))
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        Select-ComboItem 'ProcessRulesList' '*RooLoadTimesProbe*'
        Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule')
        WaitFor { $s = ById 'ProcessStatus'; if ($s -and $s.Current.Name -match 'Rule deleted|Couldn') { $true } } 60 'rule delete' | Out-Null
        $stop = ById 'ProcessStopWorker'; if ($stop -and $stop.Current.IsEnabled) { Invoke-Element $stop; Start-Sleep 5 }
        $left = @(Combo-Items 'ProcessRulesList') -join ' | '
        if ($left -notmatch 'RooLoadTimesProbe') { $script:RuleSaved = $false }
        Check (-not $script:RuleSaved) 'the test rule was deleted and the rule worker stopped' $left
        Stop-Process -Id $probe2.Id -Force -ErrorAction SilentlyContinue
    }

    Stop-Roo
    Start-Roo
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
    foreach ($p in @($probe, $probe2)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    if ($script:RuleSaved) {
        try {
            if (-not $script:App -or $script:App.HasExited) { Start-Roo }
            Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
            Select-ComboItem 'ProcessRulesList' '*RooLoadTimesProbe*'
            Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule')
            Start-Sleep 5
            $stop = ById 'ProcessStopWorker'; if ($stop -and $stop.Current.IsEnabled) { Invoke-Element $stop; Start-Sleep 5 }
            if ((@(Combo-Items 'ProcessRulesList') -join ' ') -notmatch 'RooLoadTimesProbe') { $script:RuleSaved = $false; Log 'cleanup: deleted the test rule' }
        } catch { Log ('cleanup: could not delete the test rule: ' + $_.Exception.Message) }
        if ($script:RuleSaved) { Log 'CLEANUP NEEDED: delete the RooLoadTimesProbe rule on the Processes tab and stop the rule worker' }
    }
    if ($script:RuleTest) {
        Stop-Roo
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ProcessRules' })) {
            try { Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false; Log ('cleanup: removed rule task ' + $task.TaskName) } catch { Log ('CLEANUP NEEDED: remove scheduled task ' + $task.TaskName) }
        }
        Get-CimInstance Win32_Process -Filter "Name like 'Optimizer.Host%'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'process-rules|policy' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Log 'cleanup: stopped a rule worker' }
        foreach ($root in @(Get-ChildItem $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Roo' } | ForEach-Object { Join-Path $_.FullName 'process-rules' } | Where-Object { Test-Path $_ })) {
            try { Remove-Item $root -Recurse -Force; Log 'cleanup: removed the process-rules folder the test created' } catch { Log ('CLEANUP NEEDED: remove ' + $root) }
        }
        if (-not $script:RuleSaved -and $script:Cleanup -match 'rule') { $script:Cleanup = $null }
    }
    if ($null -ne $script:RegistryBefore -and (Transparency) -ne $script:RegistryBefore) {
        try {
            if (-not $script:App -or $script:App.HasExited) { Start-Roo }
            Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
            $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
            Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
            Apply-Reviewed 'cleanup restore'
        } catch { Log ('cleanup: app restore failed: ' + $_.Exception.Message) }
        if ((Transparency) -ne $script:RegistryBefore) {
            try {
                if ($script:RegistryBefore -eq '<absent>') { Remove-ItemProperty $Personalize -Name EnableTransparency -ErrorAction Stop }
                else { Set-ItemProperty $Personalize -Name EnableTransparency -Value ([int]$script:RegistryBefore) -Type DWord -ErrorAction Stop }
                Log ('cleanup: set EnableTransparency back to ' + $script:RegistryBefore + ' directly')
                $script:Cleanup = "the app may still list the $CheckProfile profile; restore or delete it in Windows tweaks"
            } catch { Log ('cleanup: could not reset EnableTransparency: ' + $_.Exception.Message) }
        }
        else { Log 'cleanup: restored the test profile through the app'; $script:Cleanup = $null }
    }
    Stop-Roo
    Remove-Item $probePath -Force -ErrorAction SilentlyContinue
    if ($script:Cleanup) { Log ('CLEANUP NEEDED: ' + $script:Cleanup) }
    Log ('RESULT failures=' + $script:Failures + ' skipped=' + $script:Skipped)
    'x' | Set-Content (Join-Path $OutDir 'invalidation.done')
}
