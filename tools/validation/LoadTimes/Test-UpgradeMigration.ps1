param(
    [Parameter(Mandatory)][ValidateSet('before', 'after')][string]$Phase,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class MigrationU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
[MigrationU32]::SetProcessDPIAware() | Out-Null
[MigrationU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir ('migration-' + $Phase + '.log')
$script:Failures = 0
$Setting = 'windows.0689e69eedc05770'
$Profile = 'roo-industries-migration-check'
$RuleName = 'roo-industries-migration-rule'
$Personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$StatePath = Join-Path $env:TEMP 'roo-industries-migration-state.json'
$ProbePath = Join-Path $env:TEMP 'RooIndustriesMigrationProbe.exe'

function Log([string]$m) { [IO.File]::AppendAllText($script:LogPath, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m + "`r`n") }
function Check([bool]$ok, [string]$name, [string]$detail) { if (-not $ok) { $script:Failures++ }; Log ($(if ($ok) { 'PASS ' } else { 'FAIL ' }) + $name + ' :: ' + $detail) }
$install = Split-Path (Split-Path $Exe -Parent) -Parent
$scripts = Join-Path $install 'backend\scripts'
$hostExe = Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$system = [Environment]::GetFolderPath('System')
. (Join-Path $PSScriptRoot 'LauncherChecks.Common.ps1')
function Policy-Tasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '*OptimizationSuite.ProcessRules.*' }) }
function Policy-Workers([string]$requestPath) { if (-not $requestPath) { return @() }; @(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'policy-run' -and $_.CommandLine.IndexOf($requestPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
function Any-Policy-Workers { @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'Optimizer.Host.exe', 'dotnet.exe' -and [string]$_.CommandLine -match 'policy-run' }) }
function Shot([string]$name) {
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $b = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height; $g = [Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $b.Size); $b.Save((Join-Path $OutDir ('shot-' + $Phase + '-' + $name + '.png')), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
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
function Has-Profile([string[]]$texts) { for ($i = 0; $i -lt $texts.Count - 1; $i++) { if ($texts[$i] -ceq $Profile -and $texts[$i + 1] -match 'selected settings') { return $true } }; return $false }
function Undo-Texts { Nav 'Undo changes'; WaitFor { $t = @(Texts); if (($t -contains 'Saved settings') -and ($t -notcontains 'Reading restore state')) { $t } } 60 'Undo page' }
function Select-Tab([string]$id) { Invoke-Element (WaitFor { ById $id } 20 $id); Start-Sleep 1 }
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
function Probe-Priority($id) { try { [string](Get-Process -Id $id -ErrorAction Stop).PriorityClass } catch { '<gone>' } }
function Set-Profile {
    $advanced = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Show advanced options')) } 20 'Show advanced options'
    Set-Toggle $advanced $true; Start-Sleep 1
    $expander = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profiles & tools')) } 20 'Profiles & tools'
    try { $expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
    $name = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profile name'), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Edit))) } 20 'Profile name box'
    $name.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Profile); Start-Sleep 1
}
function Apply-Reviewed([string]$what) {
    WaitFor { $r = ById 'WindowsTweaksReview'; if ($r -and @($r.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text))).Count) { $r } } 60 "$what review" | Out-Null
    $texts = @(Review-Texts)
    Log ("$what review: " + ($texts -join ' | '))
    if ((($texts -join ' ') -notmatch 'Transparency') -or @($texts | Where-Object { $_ -match 'timer|Hypervisor|SEHOP|IPv6|Firewall|Defender' }).Count) { throw "$what review is not exactly the Transparency change; refusing to apply" }
    Set-Toggle (ById 'WindowsTweaksApproval') $true
    Invoke-Element (WaitFor { $b = ById 'WindowsTweaksApply'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'apply button')
    Start-Sleep 2
    Tweaks-Idle | Out-Null
}
function Open-App {
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
    $script:App = Start-Process $Exe -PassThru
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 180 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [MigrationU32]::ShowWindow($h, 9) | Out-Null; [MigrationU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [MigrationU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}

$script:App = $null
try {
    if ($Phase -eq 'before') {
        Open-App
        Log ('version ' + (Get-Item $Exe).VersionInfo.ProductVersion)
        $undo = @(Undo-Texts)
        if (Has-Profile $undo) { throw "A $Profile profile already exists on this PC; refusing to change it." }
        $registryBefore = Transparency
        Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
        Set-Profile
        $search = WaitFor { ById 'WindowsTweaksSearch' } 30 'search box'
        $search.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Transparency Effects'); Start-Sleep 1
        $row = WaitFor { ById ($Setting + '.select') } 30 'Transparency Effects row'
        $target = if ($registryBefore -eq '0') { 'On (1)' } else { 'Off (0)' }
        Set-Toggle $row $true
        $combo = WaitFor { ById ($Setting + '.value') } 20 'value combo'
        $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -Milliseconds 800
        $choice = WaitFor { $combo.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, $target)) } 10 "choice $target"
        $choice.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 500
        Invoke-Element (ById 'WindowsTweaksPreview'); Start-Sleep 2; Tweaks-Idle | Out-Null
        Apply-Reviewed 'apply'
        WaitFor { if ((Transparency) -ne $registryBefore) { $true } } 60 'registry change' | Out-Null
        $registryApplied = Transparency
        Check ($registryApplied -ne $registryBefore) 'the earlier version applied the tweak profile' "before=$registryBefore after=$registryApplied"

        Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $ProbePath -Force
        $probe = Start-Process $ProbePath -ArgumentList '-n', '7200', '127.0.0.1' -WindowStyle Hidden -PassThru
        $probeId = $probe.Id
        (Get-Process -Id $probeId).PriorityClass = 'Normal'
        Check ((Probe-Priority $probeId) -eq 'Normal') 'the probe starts at normal priority (a process started by a scheduled task inherits below normal, so it is set explicitly)' ('priority=' + (Probe-Priority $probeId))
        Start-Sleep 3
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        Invoke-Element (WaitFor { ById 'ProcessRefresh' } 20 'process refresh'); Start-Sleep 2
        Pick 'ProcessPicker' '*RooIndustriesMigrationProbe*'
        Process-Status '^Controls for' 60 'probe controls' | Out-Null
        Pick 'cpuPriority' 'Below normal'
        Invoke-Element (WaitFor { $b = ById 'ProcessPreview'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'review button')
        Process-Status '^Review the requested controls' 60 'process review' | Out-Null
        try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        (WaitFor { ById 'ProcessRuleName' } 10 'rule name').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($RuleName); Start-Sleep 1
        Invoke-Element (WaitFor { $b = ById 'ProcessSaveRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'save rule button')
        $saved = Process-Status '^(Rule saved and (on|enabled)\.|Rule saved\. The governor is paused|Saved rules need attention)' 180 'rule save'
        Check ($saved -match '^Rule saved') 'the earlier version saved the governor rule' ($saved + ' :: ' + (ById 'ProcessDetail').Current.Name)
        $enforced = $null; try { $enforced = WaitFor { if ((Probe-Priority $probeId) -eq 'BelowNormal') { $true } } 240 'rule enforced' } catch {}
        Check ([bool]$enforced) 'the earlier version enforces the rule on the probe' ('priority=' + (Probe-Priority $probeId))
        Shot 'saved'
        $oldWorkers = @(Any-Policy-Workers | ForEach-Object { [ordered]@{ pid = $_.ProcessId; created = $_.CreationDate.ToUniversalTime().ToString('o'); name = $_.Name } })
        $oldTasks = @(Policy-Tasks | ForEach-Object { $_.TaskName })
        Check ($oldWorkers.Count -ge 1 -and $oldTasks.Count -ge 1) 'the earlier version has a governor task and a running governor worker to replace' ('workers=' + $oldWorkers.Count + ' tasks=' + $oldTasks.Count)
        [ordered]@{ registryBefore = $registryBefore; registryApplied = $registryApplied; probeId = $probe.Id; probeStart = $probe.StartTime.ToUniversalTime().ToString('o'); oldWorkers = $oldWorkers; oldTasks = $oldTasks } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    } else {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        Copy-Item -LiteralPath $StatePath -Destination (Join-Path $OutDir 'migration-state.json') -Force
        $probe = Get-Process -Id $state.probeId -ErrorAction SilentlyContinue
        Check ($null -ne $probe -and $probe.StartTime.ToUniversalTime().ToString('o') -eq $state.probeStart) 'the probe from before the upgrade is still running' ('pid=' + $state.probeId)
        $enforced = $null; try { $enforced = WaitFor { if ((Probe-Priority $state.probeId) -eq 'BelowNormal') { $true } } 150 'rule enforced after upgrade' } catch {}
        Check ([bool]$enforced) 'after the upgrade the governor still enforces the earlier rule' ('priority=' + (Probe-Priority $state.probeId))
        $tasks = @(Policy-Tasks)
        Check ($tasks.Count -ge 1) 'the upgraded install has a governor task' ('tasks=' + $tasks.Count + ' before=' + @($state.oldTasks).Count)
        $upgradedRequest = $null
        foreach ($task in $tasks) {
            $xmlText = Task-Xml $task.TaskName $task.TaskPath
            Set-Content -LiteralPath (Join-Path $OutDir ('task-' + $task.TaskName + '.xml')) -Value $xmlText -Encoding UTF8
            $policyRoot = ([string]$task.Description -split ' \| ')[-1]
            $upgradedRequest = Join-Path $policyRoot 'worker-request.json'
            Check-TaskLauncher ('upgraded governor task ' + $task.TaskName) $xmlText $hostExe @('policy-run', $upgradedRequest) (Split-Path $hostExe -Parent)
        }
        $worker = $null; try { $worker = WaitFor { @(Policy-Workers $upgradedRequest | Where-Object { $_.ExecutablePath -ieq $hostExe })[0] } 150 'the upgraded governor worker' } catch {}
        $old = @($state.oldWorkers | ForEach-Object { [string]$_.pid + '|' + [string]$_.created })
        Check ($null -ne $worker -and $old -notcontains ([string]$worker.ProcessId + '|' + $worker.CreationDate.ToUniversalTime().ToString('o'))) 'the governor worker running after the upgrade is the installed new one, not the worker of the earlier version' ($(if ($worker) { 'pid=' + $worker.ProcessId + ' image=' + $worker.ExecutablePath + ' earlier=' + ($old -join ',') } else { 'no governor worker from ' + $hostExe + ' for ' + $upgradedRequest }))
        if ($worker) { Check-Chain 'upgraded governor' $worker ([xml](Task-Xml $tasks[0].TaskName $tasks[0].TaskPath)).Task.Actions.Exec.Arguments }
        $fresh = Start-Process $ProbePath -ArgumentList '-n', '7200', '127.0.0.1' -WindowStyle Hidden -PassThru
        try {
            (Get-Process -Id $fresh.Id).PriorityClass = 'Normal'
            $freshStart = Probe-Priority $fresh.Id
            $freshEnforced = $null; try { $freshEnforced = WaitFor { if ((Probe-Priority $fresh.Id) -eq 'BelowNormal') { $true } } 150 'rule applied to a new process after the upgrade' } catch {}
            Check ($freshStart -eq 'Normal' -and [bool]$freshEnforced) 'a process started after the upgrade gets the migrated rule from the new governor (starts Normal, reaches BelowNormal)' ("started at $freshStart, now " + (Probe-Priority $fresh.Id))
        } finally { try { if (-not $fresh.HasExited) { $fresh.Kill() } } catch {} }
        Open-App
        Log ('version ' + (Get-Item $Exe).VersionInfo.ProductVersion)
        $undo = @(Undo-Texts)
        Check (Has-Profile $undo) 'the Undo page lists the profile applied by the earlier version' ($undo -join ' | ')
        Shot 'undo'
        Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
        Set-Profile
        $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
        Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
        Apply-Reviewed 'restore'
        $registryRestored = Transparency
        Check ($registryRestored -eq [string]$state.registryBefore) 'the new version restores the tweak applied by the earlier version' ("before=" + $state.registryBefore + " applied=" + $state.registryApplied + " restored=" + $registryRestored)
        $undo = @(Undo-Texts)
        Check (-not (Has-Profile $undo)) 'the restored profile leaves the Undo page' ($undo -join ' | ')
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        Pick 'ProcessRulesList' ($RuleName + '*')
        Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule button')
        $deleted = Process-Status '^(Rule deleted|Couldn.t update the rule)' 180 'rule delete'
        $released = $null; try { $released = WaitFor { if ((Probe-Priority $state.probeId) -eq 'Normal') { $true } } 60 'rule released' } catch {}
        Check ($deleted -match '^Rule deleted' -and [bool]$released) 'deleting the migrated rule gives the probe its normal priority back' ($deleted + ' priority=' + (Probe-Priority $state.probeId))
        Shot 'done'
    }
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { $script:App.Kill() } }
    if ($Phase -eq 'after' -or $script:Failures -gt 0) { Get-Process RooIndustriesMigrationProbe -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; Remove-Item $ProbePath -Force -ErrorAction SilentlyContinue }
    if ($Phase -eq 'before' -and $script:Failures -gt 0) { Log ('CLEANUP NEEDED: the earlier version may have left the ' + $Profile + ' profile applied and the ' + $RuleName + ' rule saved; restore the profile and delete the rule in the app') }
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir ('migration-' + $Phase + '.done'))
}
