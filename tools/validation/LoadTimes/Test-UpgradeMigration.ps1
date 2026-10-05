param(
    [Parameter(Mandatory)][ValidateSet('before', 'after', 'undo-blocker', 'timer-on')][string]$Phase,
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
$TimerSetting = 'windows.e9d78835a38cf818'
$BlockerSetting = 'windows.71e22a554a5cb947'
$BlockerFolder = Join-Path $env:ProgramFiles 'LogiDownloadAssistant'
$script:OlderAsked = 0
$script:OlderText = ''
$script:SawPreparing = $false
$Profile = 'roo-industries-migration-check'
$TimerProfile = 'roo-industries-migration-timer'
$BlockerProfile = 'roo-industries-migration-blocker'
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
. (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
$script:MigrationProbe = $null
$script:MigrationProbeIdentity = $null
$script:MigrationFile = $null
$script:MigrationFileIdentity = $null
$script:AppReceipt = $null
$script:PersistentOutputTasks = @()
$script:PersistentOutputProcesses = @()
function Blocker-Receipts { @(foreach ($folder in (Join-Path $env:LOCALAPPDATA 'RooOptimizationSuite'), (Join-Path $env:LOCALAPPDATA 'RooIndustriesOptimizationSuite')) { if (Test-Path -LiteralPath $folder) { Get-ChildItem -LiteralPath $folder -Recurse -Filter 'logitech-downloads.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } } }) }
function Timer-Task { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'RooIndustries.Timer.*' })[0] }
function Timer-Pins($task) {
    if (-not $task) { return @() }
    $script = [regex]::Match([string]$task.Actions[0].Arguments, '-File "([^"]+startup\.ps1)"').Groups[1].Value
    if ($script -and (Test-Path -LiteralPath $script)) { @([regex]::Matches((Get-Content -LiteralPath $script -Raw), '-cne ''([0-9A-F]{64})''') | ForEach-Object { $_.Groups[1].Value }) } else { @() }
}
function Timer-Registration($Task, [string]$ControlRoot) {
    $startup = Get-Content -LiteralPath (Join-Path $ControlRoot 'startup.json') -Raw | ConvertFrom-Json
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not $Task -or $Task.TaskPath -cne '\' -or $startup.phase -cne 'created' -or $startup.taskName -cne $Task.TaskName -or $startup.owner.machine -ine $env:COMPUTERNAME -or $startup.owner.userSid -cne $sid) { throw 'Timer registration does not match its ownership receipt; retained.' }
    $taskReceipt = Get-OwnedTaskReceipt $Task.TaskName $Task.TaskPath
    Add-Type -AssemblyName System.Xml.Linq
    $definition = [Xml.Linq.XDocument]::Parse($taskReceipt.xml)
    $enabled = $definition.Root.Element($definition.Root.Name.Namespace + 'Settings').Element($definition.Root.Name.Namespace + 'Enabled')
    if ($enabled) { $enabled.Remove() }
    $fingerprint = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($definition.ToString([Xml.Linq.SaveOptions]::DisableFormatting) + "`n" + $taskReceipt.sddl))).Replace('-', '')
    if ($fingerprint -ine $startup.definitionHash) { throw 'Timer task native XML/security fingerprint differs from its startup receipt; retained.' }
    $scriptPath = Join-Path $ControlRoot 'startup.ps1'
    $expectedArguments = '--headless "' + (Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe') + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    if ($startup.scriptHash -ine (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash -or @($Task.Actions).Count -ne 1 -or [string]$Task.Actions[0].Execute -ine (Join-Path $system 'conhost.exe') -or [string]$Task.Actions[0].Arguments -ine $expectedArguments) { throw 'Timer task action differs from its startup receipt; retained.' }
    $taskReceipt
}
function Timer-Ownership($Task, [string]$ControlRoot, [string]$SessionPath, [DateTime]$StartedAfter, [ValidateSet('worker','autostart')][string]$LaunchKind = 'worker') {
    $taskReceipt = Timer-Registration $Task $ControlRoot
    $state = Get-Content -LiteralPath $SessionPath -Raw | ConvertFrom-Json
    $launchPath = Join-Path $(if ($LaunchKind -ceq 'autostart') { Split-Path $SessionPath -Parent } else { $ControlRoot }) 'launch.json'
    $launch = Get-Content -LiteralPath $launchPath -Raw | ConvertFrom-Json
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $assembly = Join-Path (Split-Path $hostExe -Parent) 'Optimizer.Host.dll'
    if ($launch.owner.machine -ine $env:COMPUTERNAME -or $launch.owner.userSid -cne $sid -or $launch.root -ine $ControlRoot -or $launch.assemblyPath -ine $assembly -or $launch.assemblyHash -ine (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash -or
        ($state.launch | ConvertTo-Json -Depth 8 -Compress) -cne ($launch | ConvertTo-Json -Depth 8 -Compress) -or $state.executable -ine $hostExe -or -not $state.acquired -or $state.released -or $null -ne $state.error) { throw 'Timer output does not match this installed helper and its startup/launch receipts; retained.' }
    $expectedCommand = '"' + $hostExe + '" --timer-' + $LaunchKind + ' "' + $(if ($LaunchKind -ceq 'autostart') { $ControlRoot } else { $launchPath }) + '"'
    $row = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $state.processId) -ErrorAction Stop
    if (-not $row -or $row.ExecutablePath -ine $hostExe -or [string]$row.CommandLine -ine $expectedCommand) { throw 'Timer worker command differs from its launch receipt; retained.' }
    $process = Get-Process -Id $state.processId -ErrorAction Stop
    try {
        $owned = New-OwnedProcess $process
        if ($owned.Identity.creationTimeFileTimeUtc -cne [string]$state.creationTime -or $owned.Identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($hostExe) -or $process.StartTime.ToUniversalTime() -lt $StartedAfter) { throw 'Timer worker native identity differs from its session receipt; retained.' }
        [pscustomobject]@{task=$taskReceipt;process=$owned.Identity;sessionPath=$SessionPath;sessionSha256=(Get-FileHash -LiteralPath $SessionPath -Algorithm SHA256).Hash}
    } finally { $process.Dispose() }
}
function Expected-TimerStartup([string]$ControlRoot) {
    $assembly = Join-Path (Split-Path $hostExe -Parent) 'Optimizer.Host.dll'
    $text = "`$ErrorActionPreference='Stop'`n"
    foreach ($file in $assembly, $hostExe) { $text += 'if((Get-FileHash -LiteralPath ' + (Quote-Literal $file) + ' -Algorithm SHA256).Hash -cne ' + (Quote-Literal (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) + "){throw 'The timer helper changed; review its startup registration again.'}`n" }
    $text += '& ' + (Quote-Literal $hostExe) + " '--timer-autostart' " + (Quote-Literal $ControlRoot) + "`nexit `$LASTEXITCODE`n"
    ,([Text.Encoding]::UTF8.GetBytes($text))
}
function Installed-Helper-Hashes { @((Join-Path (Split-Path $hostExe -Parent) 'Optimizer.Host.dll'), $hostExe | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) }
function Policy-Tasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '*OptimizationSuite.ProcessRules.*' }) }
function Policy-Workers([string]$requestPath) { if (-not $requestPath) { return @() }; @(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'policy-run' -and $_.CommandLine.IndexOf($requestPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
function Any-Policy-Workers { @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'Optimizer.Host.exe', 'dotnet.exe' -and [string]$_.CommandLine -match 'policy-run' }) }
function Data-Root {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    $current = Join-Path $local 'RooIndustriesOptimizationSuite'; $legacy = Join-Path $local ('RooIndustriesOptimizationSuite' -replace 'Industries','')
    if ((Test-Path -LiteralPath $legacy -PathType Container) -and -not ($markers -and $null -ne $markers.GetValue($current.ToUpperInvariant()) -and $null -eq $markers.GetValue($legacy.ToUpperInvariant()))) { $legacy } else { $current }
}
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
function Older-Dialog { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Saved by an older version')) }
function Tweaks-Idle {
    $deadline = (Get-Date).AddSeconds(600); $seen = $false
    while ((Get-Date) -lt $deadline) {
        $dialog = $null; try { $dialog = Older-Dialog } catch {}
        if ($dialog) {
            if (-not $seen) {
                $seen = $true; $script:OlderAsked++
                $script:OlderText = (@(Texts | Where-Object { $_ -like '*saved by an older version*' }) -join ' | ')
                Log ('the app asked about the backup saved by an older version: ' + $script:OlderText)
                Shot 'older-version'
                $continue = $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Continue'), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Button)))
                if ($continue) { Invoke-Element $continue }
            }
        } else {
            $seen = $false
            $r = ById 'WindowsTweaksRefresh'; $s = ById 'WindowsTweaksStatus'
            if ($r -and $r.Current.IsEnabled -and $s -and $s.Current.Name -notmatch '^Loading') { return $s.Current.Name }
        }
        Start-Sleep -Milliseconds 150
    }
    throw 'Timed out waiting for Windows tweaks idle'
}
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
function Set-Profile([string]$profileName = $Profile) {
    $advanced = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Show advanced options')) } 20 'Show advanced options'
    Set-Toggle $advanced $true; Start-Sleep 1
    $expander = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profiles & tools')) } 20 'Profiles & tools'
    try { $expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
    $name = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Profile name'), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Edit))) } 20 'Profile name box'
    $name.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($profileName); Start-Sleep 1
}
function Restore-Profile([string]$profileName, [string]$expect, [string]$forbid) {
    Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
    Set-Profile $profileName
    $restore = WaitFor { $b = ById 'WindowsTweaksRestore'; if ($b -and $b.Current.IsEnabled) { $b } } 60 'restore button'
    Invoke-Element $restore; Start-Sleep 2; Tweaks-Idle | Out-Null
    Apply-Reviewed "restore $profileName" $expect $forbid
}
function Show-Advanced { Set-Toggle (WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Show advanced options')) } 20 'Show advanced options') $true; Start-Sleep 1 }
function Choose-Setting([string]$settingId, [string]$search, [string]$choice) {
    $box = WaitFor { ById 'WindowsTweaksSearch' } 30 'search box'
    $box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($search); Start-Sleep 1
    $selector = WaitFor { ById ($settingId + '.select') } 30 ($search + ' row')
    Set-Toggle $selector $false; Set-Toggle $selector $true
    $combo = $null; try { $combo = WaitFor { ById ($settingId + '.value') } 5 'value combo' } catch {}
    if ($combo) {
        $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); Start-Sleep -Milliseconds 800
        $item = WaitFor { $combo.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, $choice)) } 10 "choice $choice"
        $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 500
    } else {
        Log ("$search offers a single change, so its switch alone selects it")
    }
    Invoke-Element (ById 'WindowsTweaksPreview'); Start-Sleep 2; Tweaks-Idle | Out-Null
}
function Apply-Reviewed([string]$what, [string]$expect = 'Transparency', [string]$forbid = 'timer|Hypervisor|SEHOP|IPv6|Firewall|Defender') {
    try {WaitFor { $r = ById 'WindowsTweaksReview'; if ($r -and @($r.FindAll($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::Text))).Count) { $r } } 60 "$what review" | Out-Null} catch { Log ('the review did not appear; status: ' + (ById 'WindowsTweaksStatus').Current.Name + ' | detail: ' + (ById 'WindowsTweaksDetail').Current.Name + ' | texts: ' + ((Texts | Select-Object -First 40) -join ' | ')); throw }
    $texts = @(Review-Texts)
    Log ("$what review: " + ($texts -join ' | '))
    if ((($texts -join ' ') -notmatch $expect) -or @($texts | Where-Object { $_ -match $forbid }).Count) { throw "$what review is not exactly the $expect change; refusing to apply" }
    Set-Toggle (ById 'WindowsTweaksApproval') $true
    Invoke-Element (WaitFor { $b = ById 'WindowsTweaksApply'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'apply button')
    Start-Sleep 2
    Tweaks-Idle | Out-Null
}
function Open-App {
    if (@(Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue).Count) { throw 'An app is already open; refusing to stop an unowned process.' }
    $script:App = Start-Process $Exe -PassThru
    $script:AppReceipt = New-OwnedProcess $script:App
    $script:Win = $null
    $deadline = (Get-Date).AddSeconds(900)
    while ((Get-Date) -lt $deadline -and -not $script:Win) {
        $windows = @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 })
        foreach ($window in $windows) {
            if (-not $script:SawPreparing -and $window.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Preparing your saved settings'))) {
                $script:SawPreparing = $true; Shot 'preparing'; Log 'the Preparing your saved settings window is showing'
            }
        }
        $script:Win = @($windows | Where-Object { $_.Current.Name -like 'Roo Industries*' -and $_.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) })[0]
        if (-not $script:Win) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $script:Win) { throw 'Timed out waiting for the main window and Home' }
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [MigrationU32]::ShowWindow($h, 9) | Out-Null; [MigrationU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [MigrationU32]::SetForegroundWindow($h) | Out-Null
}

function Read-MigrationProbeOwnership($State) {
    if (-not $State.probeIdentity -or -not $State.probeFileIdentity -or -not $State.probeIdentity.creationTimeFileTimeUtc) { throw 'Migration ownership receipt is missing; resources retained.' }
    if ([int]$State.probeId -ne [int]$State.probeIdentity.pid -or [IO.Path]::GetFullPath($State.probeFileIdentity.path) -ine [IO.Path]::GetFullPath($ProbePath)) { throw 'Migration ownership fields disagree; resources retained.' }
    if ($State.probeIdentity.imagePath -ine [RooValidationOwnership.Native]::Canonical($ProbePath)) { throw 'Migration image ownership differs; resources retained.' }
    [pscustomobject]@{probeIdentity=$State.probeIdentity;probeFileIdentity=$State.probeFileIdentity}
}

function Remove-MigrationProbe {
    $stopped = $true
    try {
        if ($script:MigrationProbeIdentity) { Stop-OwnedProcessIdentity $script:MigrationProbeIdentity }
        elseif ($script:MigrationProbe) { Stop-OwnedProcess $script:MigrationProbe }
    } catch { $stopped = $false; Log ('CLEANUP NEEDED: migration probe retained: ' + $_.Exception.Message) }
    if (-not $stopped) { return }
    try {
        if ($script:MigrationFile) { Remove-OwnedProbe $script:MigrationFile }
        elseif ($script:MigrationFileIdentity) { $file = Open-OwnedProbe $script:MigrationFileIdentity; try { Remove-OwnedProbe $file } finally { $file.Dispose() } }
    } catch { Log ('CLEANUP NEEDED: migration probe file retained: ' + $_.Exception.Message) }
}

$script:App = $null
try {
    if ($Phase -eq 'before') {
        if (Test-Path -LiteralPath $BlockerFolder) { throw "$BlockerFolder already exists on this PC; refusing to change it." }
        if ((Test-Path -LiteralPath $StatePath) -or (Test-Path -LiteralPath $ProbePath)) { throw 'Migration fixture already exists; recover it before starting.' }
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

        $script:MigrationFile = Copy-OwnedProbe (Join-Path $system 'PING.EXE') $ProbePath
        $script:MigrationFileIdentity = $MigrationFile.Identity
        $probe = Start-Process $ProbePath -ArgumentList '-n', '7200', '127.0.0.1' -WindowStyle Hidden -PassThru
        $script:MigrationProbe = New-OwnedProcess $probe
        $script:MigrationProbeIdentity = $MigrationProbe.Identity
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
        Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
        Set-Profile $TimerProfile
        Choose-Setting $TimerSetting 'Start timer at Windows sign-in' 'Enabled'
        $timerApplyStarted = [DateTime]::UtcNow
        Apply-Reviewed 'timer apply' 'timer' 'Transparency|Hypervisor|SEHOP|IPv6|Firewall|Defender'
        $timerTask = $null; try { $timerTask = WaitFor { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'RooIndustries.Timer.*' })[0] } 90 'the sign-in timer task' } catch {}
        Check ($null -ne $timerTask) 'the earlier version registered the sign-in timer' ($(if ($timerTask) { $timerTask.TaskName + ' state=' + $timerTask.State } else { 'no RooIndustries.Timer task' }))
        $timerControl = Join-Path (Data-Root) 'operations\windows-timer'
        $timerOutput = Timer-Ownership $timerTask $timerControl (Join-Path $timerControl 'session.json') $timerApplyStarted
        Check ($null -ne $timerOutput.process) 'the earlier timer worker has an exact native identity and matching launch receipt' ('pid=' + $timerOutput.process.pid + ' session=' + $timerOutput.sessionPath + ' sha256=' + $timerOutput.sessionSha256)
        Shot 'timer'
        Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
        Set-Profile $BlockerProfile
        Choose-Setting $BlockerSetting 'Logitech download folder writes' 'Enabled'
        Apply-Reviewed 'download folder blocker apply' 'Logitech' 'Transparency|timer|Hypervisor|SEHOP|IPv6|Firewall|Defender'
        $blockerFolderMade = $null; try { $blockerFolderMade = WaitFor { if (Test-Path -LiteralPath $BlockerFolder) { $true } } 90 'the download folder' } catch {}
        $receipts = @(Blocker-Receipts)
        Check ([bool]$blockerFolderMade -and $receipts.Count -ge 1) 'the earlier version applied the download folder blocker and saved its receipt, the file the older-version question is about' ('folder=' + [bool]$blockerFolderMade + ' receipts=' + ($receipts -join ','))
        Shot 'blocker'
        $oldRequest = Join-Path (Data-Root) 'process-rules\worker-request.json'
        $oldWorkers = @(Any-Policy-Workers | Where-Object {$_.CommandLine.IndexOf($oldRequest,[StringComparison]::OrdinalIgnoreCase) -ge 0} | ForEach-Object { [ordered]@{ pid = $_.ProcessId; created = $_.CreationDate.ToUniversalTime().ToString('o'); name = $_.Name } })
        $oldTasks = @(Policy-Tasks | ForEach-Object { $_.TaskName })
        Check ($oldWorkers.Count -ge 1 -and $oldTasks.Count -ge 1) 'the earlier version has a governor task and a running governor worker to replace' ('workers=' + $oldWorkers.Count + ' tasks=' + $oldTasks.Count)
        $script:PersistentOutputTasks = @(Policy-Tasks | ForEach-Object { Get-OwnedTaskReceipt $_.TaskName $_.TaskPath }) + @($timerOutput.task)
        $script:PersistentOutputProcesses = @(Any-Policy-Workers | Where-Object { $_.CommandLine.IndexOf($oldRequest,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | ForEach-Object { (New-OwnedProcess (Get-Process -Id $_.ProcessId)).Identity }) + @($timerOutput.process)
        [ordered]@{ registryBefore = $registryBefore; registryApplied = $registryApplied; probeId = $probe.Id; probeStart = $probe.StartTime.ToUniversalTime().ToString('o'); probeIdentity = $MigrationProbeIdentity; probeFileIdentity = $MigrationFileIdentity; oldWorkers = $oldWorkers; oldTasks = $oldTasks; timerTask = $(if ($timerTask) { $timerTask.TaskName } else { '' }); timerScriptHash = (Get-FileHash -LiteralPath (Join-Path $timerControl 'startup.ps1')).Hash; timerReceiptHash = (Get-FileHash -LiteralPath (Join-Path $timerControl 'startup.json')).Hash } | ConvertTo-Json -Depth 5 | ForEach-Object { $bytes = [Text.Encoding]::UTF8.GetBytes($_); $file = [IO.File]::Open($StatePath, 'CreateNew', 'Write', 'Read'); try { $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() } }
    } elseif ($Phase -eq 'undo-blocker') {
        Open-App
        Restore-Profile $BlockerProfile 'Logitech' 'Transparency|timer|Hypervisor|SEHOP|IPv6|Firewall|Defender'
        $blockerGone = $null; try { $blockerGone = WaitFor { if (-not (Test-Path -LiteralPath $BlockerFolder)) { $true } } 90 'the download folder to be removed' } catch {}
        Check ([bool]$blockerGone) 'the new version undoes the download folder blocker applied by the earlier version and removes the folder it created' ('folderExists=' + (Test-Path -LiteralPath $BlockerFolder))
        Shot 'blocker-undone'
    } elseif ($Phase -eq 'timer-on') {
        $timerState = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RooIndustriesOptimizationSuite.Timer'
        $stateFile = Join-Path $timerState 'session.json'
        $stampBefore = if (Test-Path -LiteralPath $stateFile) { (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc } else { [DateTime]::MinValue }
        $earlierTask = Timer-Task
        $earlierPins = @(Timer-Pins $earlierTask); $installedHashes = @(Installed-Helper-Hashes)
        Log ('NOTE the sign-in timer registered by the earlier version pins ' + $earlierPins.Count + ' helper file hashes and ' + @($earlierPins | Where-Object { $installedHashes -contains $_ }).Count + ' of them match the installed files')
        Open-App
        Nav 'Windows tweaks'; Tweaks-Idle | Out-Null
        Set-Profile $TimerProfile
        Choose-Setting $TimerSetting 'Start timer at Windows sign-in' 'Enabled'
        Apply-Reviewed 'timer on' 'timer' 'Transparency|Hypervisor|SEHOP|IPv6|Firewall|Defender|Logitech'
        $stateMade = $null; try { $stateMade = WaitFor { if ((Test-Path -LiteralPath $stateFile) -and (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc -gt $stampBefore) { $true } } 90 'the timer state to be written' } catch {}
        Check ([bool]$stateMade) 'the new version starts the timer and creates its state folder outside the data folder' ($timerState + ' written=' + [bool]$stateMade)
        $timerOutput = Timer-Ownership (Timer-Task) (Join-Path (Data-Root) 'operations\windows-timer') $stateFile ([DateTime]::MinValue)
        Check ($null -ne $timerOutput.process) 'the timer worker runs from the installed helper' ('pid=' + $timerOutput.process.pid + ' image=' + $timerOutput.process.imagePath + ' session=' + $timerOutput.sessionPath + ' sha256=' + $timerOutput.sessionSha256)
        Shot 'timer-on'
        $script:PersistentOutputTasks = @($timerOutput.task)
        $script:PersistentOutputProcesses = @($timerOutput.process)
    } else {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        if ($state.timerScriptHash -cnotmatch '\A[0-9A-F]{64}\z' -or $state.timerReceiptHash -cnotmatch '\A[0-9A-F]{64}\z') { throw 'The earlier timer script/receipt hashes are missing; retained.' }
        Copy-Item -LiteralPath $StatePath -Destination (Join-Path $OutDir 'migration-state.json') -Force
        $ownership = Read-MigrationProbeOwnership $state
        $script:MigrationFile = Open-OwnedProbe $ownership.probeFileIdentity
        $script:MigrationProbeIdentity = $ownership.probeIdentity
        $script:MigrationFileIdentity = $ownership.probeFileIdentity
        $probe = Get-Process -Id $state.probeId -ErrorAction SilentlyContinue
        if ($probe) { $script:MigrationProbe = New-OwnedProcess $probe; if ($MigrationProbe.Identity.creationTimeFileTimeUtc -cne $MigrationProbeIdentity.creationTimeFileTimeUtc -or $MigrationProbe.Identity.imagePath -ine $MigrationProbeIdentity.imagePath) { throw 'Migration process identity changed; retained.' } }
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
        $freshReceipt = New-OwnedProcess $fresh
        try {
            (Get-Process -Id $fresh.Id).PriorityClass = 'Normal'
            $freshStart = Probe-Priority $fresh.Id
            $freshEnforced = $null; try { $freshEnforced = WaitFor { if ((Probe-Priority $fresh.Id) -eq 'BelowNormal') { $true } } 150 'rule applied to a new process after the upgrade' } catch {}
            Check ($freshStart -eq 'Normal' -and [bool]$freshEnforced) 'a process started after the upgrade gets the migrated rule from the new governor (starts Normal, reaches BelowNormal)' ("started at $freshStart, now " + (Probe-Priority $fresh.Id))
        } finally { Stop-OwnedProcess $freshReceipt; $fresh.Dispose() }
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
        Check ($script:OlderAsked -eq 1 -and $script:OlderText -match 'saved by an older version') 'the app asked once whether to use the backup saved by an older version, and the undo went on after Continue' ('asked=' + $script:OlderAsked + ' text=' + $script:OlderText)
        $timerTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'RooIndustries.Timer.*' })
        Check ($timerTasks.Count -eq 1 -and $timerTasks[0].TaskName -eq $state.timerTask) 'the sign-in timer of the earlier version is still registered after the upgrade' ('now=' + (($timerTasks | ForEach-Object { $_.TaskName + ' ' + $_.State }) -join ',') + ' before=' + $state.timerTask)
        $timerState = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RooIndustriesOptimizationSuite.Timer'
        Log ('download folder blocker receipts after the upgrade: ' + (@(Blocker-Receipts) -join ','))
        Log ('sign-in timer state folder after the upgrade: ' + (Test-Path -LiteralPath $timerState) + ' (' + $timerState + ')')
        if ($timerTasks.Count -ne 1 -or $timerTasks[0].TaskName -cne $state.timerTask) { throw 'The migrated timer task differs; refusing to start it.' }
        $timerControl = Join-Path (Data-Root) 'operations\windows-timer'
        $timerTaskReceipt = Timer-Registration $timerTasks[0] $timerControl
        $setupLog = Join-Path (Split-Path (Split-Path $OutDir -Parent) -Parent) 'upgrade\setup.log'
        $refreshLines = @([IO.File]::ReadAllLines($setupLog) | Where-Object { $_ -match ('Timer startup: refreshed: timer startup ' + [regex]::Escape($state.timerTask) + '\s*$') })
        Check ($refreshLines.Count -ge 1) 'the upgrade setup log confirms that the sign-in timer script was refreshed' ($setupLog + ' :: ' + ($refreshLines -join ' | '))
        if (-not $refreshLines.Count) { throw 'No timer refresh was confirmed by setup; refusing to start it.' }
        $startupPath = Join-Path $timerControl 'startup.ps1'
        $startupBytes = [IO.File]::ReadAllBytes($startupPath)
        $expectedBytes = Expected-TimerStartup $timerControl
        $startupHash = (Get-FileHash -LiteralPath $startupPath).Hash
        $bytesMatch = [Convert]::ToBase64String($startupBytes) -ceq [Convert]::ToBase64String($expectedBytes)
        Check ($bytesMatch -and $startupHash -cne $state.timerScriptHash) 'the upgraded sign-in timer script equals the installed helper script byte for byte and differs from the old script' ('before=' + $state.timerScriptHash + ' after=' + $startupHash + ' bytes=' + $startupBytes.Length)
        if (-not $bytesMatch -or $startupHash -ceq $state.timerScriptHash) { throw 'The upgraded startup bytes do not match this install; refusing to start the task.' }
        $startupReceipt = Get-Content -LiteralPath (Join-Path $timerControl 'startup.json') -Raw | ConvertFrom-Json
        Check ($startupReceipt.scriptHash -ceq $startupHash) 'the refreshed sign-in timer script SHA256 matches its created ownership receipt' ('script=' + $startupHash + ' receipt=' + $startupReceipt.scriptHash)
        [ordered]@{task=$timerTaskReceipt;scriptPath=$startupPath;scriptSha256=$startupHash;scriptBytes=$startupBytes.Length;oldScriptSha256=$state.timerScriptHash;receiptSha256=(Get-FileHash -LiteralPath (Join-Path $timerControl 'startup.json')).Hash;oldReceiptSha256=$state.timerReceiptHash;setupLog=$setupLog;setupLogSha256=(Get-FileHash -LiteralPath $setupLog).Hash;refreshLines=$refreshLines} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'timer-startup-upgraded.json') -Encoding UTF8
        $timerSession = Join-Path $timerState 'session.json'
        if (Test-Path -LiteralPath $timerSession) {
            $priorTimerState = Get-Content -LiteralPath $timerSession -Raw | ConvertFrom-Json
            if ($priorTimerState.acquired -and -not $priorTimerState.released -and (Get-Process -Id $priorTimerState.processId -ErrorAction SilentlyContinue)) {
                $priorTimer = Timer-Ownership $timerTasks[0] $timerControl $timerSession ([DateTime]::MinValue)
                Stop-OwnedProcessIdentity $priorTimer.process
                Check $true 'the existing exact owned timer worker was stopped before the sign-in task test' ('pid=' + $priorTimer.process.pid + ' creation=' + $priorTimer.process.creationTimeFileTimeUtc)
            }
        }
        Assert-OwnedTaskUnchanged $timerTaskReceipt
        $taskStarted = [DateTime]::UtcNow
        Start-ScheduledTask -TaskName $timerTaskReceipt.name -TaskPath $timerTaskReceipt.path
        $timerOutput = WaitFor { Timer-Ownership (Get-ScheduledTask -TaskName $timerTaskReceipt.name -TaskPath $timerTaskReceipt.path) $timerControl $timerSession $taskStarted 'autostart' } 90 'the upgraded sign-in task to acquire the timer through the installed helper'
        Check ($null -ne $timerOutput.process) 'starting the exact upgraded sign-in task launches the installed timer helper with a new native identity' ('pid=' + $timerOutput.process.pid + ' creation=' + $timerOutput.process.creationTimeFileTimeUtc + ' image=' + $timerOutput.process.imagePath + ' sessionSha256=' + $timerOutput.sessionSha256)
        $timerOutput | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'timer-signin-worker.json') -Encoding UTF8
        $timerProcess = Get-Process -Id $timerOutput.process.pid -ErrorAction Stop
        try {
            $heldTimer = New-OwnedProcess $timerProcess
            if ($heldTimer.Identity.creationTimeFileTimeUtc -cne $timerOutput.process.creationTimeFileTimeUtc -or $heldTimer.Identity.imagePath -ine $timerOutput.process.imagePath) { throw 'Timer identity changed before its profile cleanup; retained.' }
            Restore-Profile $TimerProfile 'timer' 'Transparency|Hypervisor|SEHOP|IPv6|Firewall|Defender|Logitech'
            $timerReleased = Get-Content -LiteralPath $timerSession -Raw | ConvertFrom-Json
            Check ($timerProcess.WaitForExit(30000) -and $timerReleased.released -and $null -ne $timerReleased.releaseStatus -and $timerReleased.releaseStatus -ge 0 -and $timerReleased.creationTime -ceq $timerOutput.process.creationTimeFileTimeUtc -and $null -eq $timerReleased.error) 'the existing timer profile cleanup stops the exact sign-in worker and confirms its native release' ('pid=' + $timerOutput.process.pid + ' released=' + $timerReleased.released + ' releaseStatus=' + $timerReleased.releaseStatus)
            Check (@(Get-ScheduledTask -TaskName $timerTaskReceipt.name -TaskPath $timerTaskReceipt.path -ErrorAction SilentlyContinue).Count -eq 0) 'the timer profile cleanup removes the exact upgraded sign-in task' $timerTaskReceipt.name
        } finally { $timerProcess.Dispose() }
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
    try { if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { Stop-OwnedProcess $script:AppReceipt } } } catch { Log ('CLEANUP NEEDED: migration app retained: ' + $_.Exception.Message) }
    if ($Phase -eq 'after' -or $script:Failures -gt 0) { Remove-MigrationProbe }
    if ($script:MigrationFile) { $script:MigrationFile.Dispose() }
    if ($Phase -eq 'before' -and $script:Failures -gt 0) { Log ('CLEANUP NEEDED: the earlier version may have left the ' + $Profile + ' profile applied and the ' + $RuleName + ' rule saved; restore the profile and delete the rule in the app') }
    if ($script:Failures -eq 0 -and $Phase -in 'before','timer-on') { [ordered]@{ scenario=('migration-' + $Phase); tasks=$script:PersistentOutputTasks; processes=$script:PersistentOutputProcesses } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'persistent-resources.json') -Encoding UTF8 }
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir ('migration-' + $Phase + '.done'))
}
