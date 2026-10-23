param(
    [ValidateSet('before', 'after')][string]$Label = 'after',
    [string]$OutRoot,
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE,
    [int]$PauseMs = 1200
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($DotNetPath)) { $candidate = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'; $DotNetPath = if (Test-Path $candidate) { $candidate } else { (Get-Command dotnet.exe -ErrorAction Stop).Source } }
if ([string]::IsNullOrWhiteSpace($OutRoot)) { $OutRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-firmware-page-ui-' + $Label) }
if (Test-Path -LiteralPath $OutRoot) { throw "Evidence folder already exists: $OutRoot" }
[IO.Directory]::CreateDirectory($OutRoot) | Out-Null

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesFirmwarePageUi
{
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
}
'@
[void][RooIndustriesFirmwarePageUi]::SetProcessDpiAwarenessContext([IntPtr]-4)

$element = [Windows.Automation.AutomationElement]
$scope = [Windows.Automation.TreeScope]
$controls = [Windows.Automation.ControlType]
$writing = "Writing the reviewed changes to the BIOS. Keep the app open until it's done. You can use other pages while it runs."
$checkpoints = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[object]]::new()
$app = $null
$frameShell = $null
$frameRun = $null
$frameState = [hashtable]::Synchronized(@{ stop = $false; count = 0 })
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-firmware-ui-cli-' + [guid]::NewGuid().ToString('N'))
$firmwareRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-firmware-ui-root-' + [guid]::NewGuid().ToString('N'))
$hold = $null

function Get-AppWindow {
    $condition = New-Object Windows.Automation.PropertyCondition($element::ProcessIdProperty, $app.Id)
    $element::RootElement.FindFirst($scope::Children, $condition)
}
function Find-Id([string]$Id) {
    $window = Get-AppWindow
    if ($null -eq $window) { return $null }
    $window.FindFirst($scope::Descendants, (New-Object Windows.Automation.PropertyCondition($element::AutomationIdProperty, $Id)))
}
function Find-Named([string]$Name, $Type) {
    $window = Get-AppWindow
    if ($null -eq $window) { return $null }
    $condition = New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($element::NameProperty, $Name)), (New-Object Windows.Automation.PropertyCondition($element::ControlTypeProperty, $Type)))
    $window.FindFirst($scope::Descendants, $condition)
}
function Find-DialogButton([string]$Name) {
    $window = Get-AppWindow
    if ($null -eq $window) { return $null }
    $condition = New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($element::NameProperty, $Name)), (New-Object Windows.Automation.PropertyCondition($element::AutomationIdProperty, 'PrimaryButton')))
    $window.FindFirst($scope::Descendants, $condition)
}
function Wait-For([scriptblock]$Probe, [string]$What, [int]$Seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $What"
}
function Invoke-Control($Control) { $Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Get-Text([string]$Id) { $found = Find-Id $Id; if ($found) { $found.Current.Name } else { '' } }
function Test-Shown([string]$Id) { $found = Find-Id $Id; [bool]($found -and -not $found.Current.IsOffscreen) }
function Open-Nav([string]$Name) {
    $item = Wait-For { Find-Named $Name $controls::ListItem } "the $Name navigation item"
    $pattern = $null
    if ($item.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke() }
    else { $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
}
function Open-Firmware {
    Open-Nav 'Tools'
    Invoke-Control (Wait-For { Find-Id 'OpenFirmware' } 'the Tools page')
    [void](Wait-For { Find-Id 'FirmwareStep' } 'the BIOS page')
}
function Set-Choice([string]$Setting, [string]$Choice) {
    $combo = Wait-For { Find-Named $Setting $controls::ComboBox } "the $Setting picker"
    $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $item = Wait-For {
        $items = @($combo.FindAll($scope::Descendants, (New-Object Windows.Automation.PropertyCondition($element::ControlTypeProperty, $controls::ListItem))))
        if ($items.Count -eq 0) { $items = @((Get-AppWindow).FindAll($scope::Descendants, (New-Object Windows.Automation.PropertyCondition($element::ControlTypeProperty, $controls::ListItem)))) }
        $items | Where-Object { $_.Current.Name -eq $Choice -or $_.Current.Name -like "*Label = $Choice *" } | Select-Object -First 1
    } "the $Choice option"
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    try { $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch { Write-Verbose 'The picker closed itself.' }
}
function Get-Choice([string]$Setting) {
    $combo = Find-Named $Setting $controls::ComboBox
    if (-not $combo) { return '' }
    $selected = @($combo.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection())
    if (-not $selected.Count) { return '' }
    $name = $selected[0].Current.Name
    if ($name -match 'Label = (.+) }$') { $Matches[1] } else { $name }
}
function Set-Number([string]$Setting, [string]$Value) {
    $box = Wait-For { Find-Named $Setting $controls::Edit } "the $Setting box"
    $box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
}
function Get-Number([string]$Setting) {
    $box = Find-Named $Setting $controls::Edit
    if ($box) { $box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value } else { '' }
}
function Save-Shot([string]$Name) {
    $window = Get-AppWindow
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    $rect = New-Object RooIndustriesFirmwarePageUi+Rect
    [void][RooIndustriesFirmwarePageUi]::GetWindowRect($handle, [ref]$rect)
    $bitmap = New-Object Drawing.Bitmap ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    try { [void][RooIndustriesFirmwarePageUi]::PrintWindow($handle, $dc, 2) } finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
    $bitmap.Save((Join-Path $OutRoot ($Name + '.png')), [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}
function Start-Frames {
    $folder = Join-Path $OutRoot 'frames'
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $script:frameShell = [powershell]::Create()
    [void]$script:frameShell.AddScript({
        param([IntPtr]$Handle, [string]$Folder, $State)
        Add-Type -AssemblyName System.Drawing
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $State.stop) {
            $rect = New-Object RooIndustriesFirmwarePageUi+Rect
            [void][RooIndustriesFirmwarePageUi]::GetWindowRect($Handle, [ref]$rect)
            $width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
            $full = New-Object Drawing.Bitmap $width, $height
            $graphics = [Drawing.Graphics]::FromImage($full); $dc = $graphics.GetHdc()
            try { [void][RooIndustriesFirmwarePageUi]::PrintWindow($Handle, $dc, 2) } finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
            $scale = [Math]::Min(1.0, 1600.0 / $width)
            $small = New-Object Drawing.Bitmap ([int]($width * $scale)), ([int]($height * $scale))
            $draw = [Drawing.Graphics]::FromImage($small); $draw.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $draw.DrawImage($full, 0, 0, $small.Width, $small.Height); $draw.Dispose(); $full.Dispose()
            $small.Save((Join-Path $Folder ('{0:D5}-{1:D7}.jpg' -f $State.count, $clock.ElapsedMilliseconds)), [Drawing.Imaging.ImageFormat]::Jpeg); $small.Dispose()
            $State.count++
            Start-Sleep -Milliseconds 40
        }
    }).AddArgument([IntPtr](Get-AppWindow).Current.NativeWindowHandle).AddArgument($folder).AddArgument($frameState)
    $script:frameRun = $script:frameShell.BeginInvoke()
}
function Stop-Frames {
    if (-not $script:frameShell) { return }
    $frameState.stop = $true
    [void]$script:frameShell.EndInvoke($script:frameRun)
    $script:frameShell.Dispose()
    $script:frameShell = $null
}
function Add-Checkpoint([string]$Name) {
    Start-Sleep -Milliseconds $PauseMs
    $checkpoints.Add([ordered]@{
        name = $Name; step = Get-Text 'FirmwareStep'; message = Get-Text 'FirmwareMessage'; result = Get-Text 'FirmwareResultMessage'
        loadShown = Test-Shown 'LoadFirmwareSettings'; startOverShown = Test-Shown 'FirmwareStartOver'; restartShown = Test-Shown 'RestartAfterFirmware'
        option = Get-Choice 'Fixture option'; delay = Get-Number 'Fixture delay'
    }) | Out-Null
    Save-Shot $Name
    $checkpoints[$checkpoints.Count - 1]
}
function Add-Check([string]$Name, [bool]$Passed) {
    $checks.Add([ordered]@{ name = $Name; passed = $Passed }) | Out-Null
    Write-Output (($(if ($Passed) { 'PASS ' } else { 'FAIL ' })) + $Name)
}
function Wait-Load {
    Invoke-Control (Wait-For { $load = Find-Id 'LoadFirmwareSettings'; if ($load -and $load.Current.IsEnabled -and -not $load.Current.IsOffscreen) { $load } } 'Load settings' 60)
}
function Wait-Written {
    [void](Wait-For { @(Get-ChildItem -Path (Join-Path $firmwareRoot 'sessions\*\journal.json') -ErrorAction SilentlyContinue | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json).status -ne 'importing' }).Count } 'the fixture write to finish')
}
function Get-Calls([string]$Kind) {
    $log = Join-Path $package 'calls.log'
    if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log | Where-Object { $_.StartsWith($Kind + '|') }).Count } else { 0 }
}

try {
    $exe = Get-ChildItem -LiteralPath (Join-Path $root 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $exe) { throw 'Build the app with -p:RooIndustriesTestHooks=true first.' }
    $assembly = [IO.File]::ReadAllBytes((Join-Path $exe.DirectoryName 'RooIndustries.OptimizationSuite.App.dll'))
    $hook = 'ROO_INDUSTRIES_TEST_FIRMWARE_ROOT'
    if (-not ([Text.Encoding]::Unicode.GetString($assembly).Contains($hook) -or [Text.Encoding]::Unicode.GetString($assembly, 1, $assembly.Length - 1).Contains($hook))) { throw 'This app build has no fixture firmware root, so it could reach a real BIOS. Rebuild it with test hooks.' }

    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    & $compiler /nologo /target:exe /platform:x64 ('/out:' + (Join-Path $fixture 'SCEWIN64.exe')) (Join-Path $root 'tools\validation\fixtures\FirmwareHelperFixture.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the file-only firmware fixture' }
    [IO.File]::WriteAllText((Join-Path $fixture 'fixture-authority.txt'), 'roo-industries-firmware-cli-fixture/v1')
    $package = (& $DotNetPath run --no-build --project (Join-Path $root 'tools\validation\AppSweepUi\AppSweepUi.csproj') --configuration Release -- firmware-fixture $fixture $firmwareRoot | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $package 'package.json'))) { throw 'Could not prepare the fixture SCEWIN package.' }
    $hold = Join-Path $package 'fixture-import-hold.txt'
    $version = (Get-Content -Raw -LiteralPath (Join-Path $package 'package.json') | ConvertFrom-Json).version
    $expectedPackage = $(if ($version -eq 'Not specified') { 'SCEWIN' } else { 'SCEWIN ' + $version }) + ' ' + [char]0x00B7 + ' Ready to load settings'

    [void](Wait-For { -not (Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue) } 'another app window to close' 600)
    $env:ROO_INDUSTRIES_TEST_FIRMWARE_ROOT = $firmwareRoot
    $env:ROO_INDUSTRIES_INITIAL_NAV = 'tools'
    $app = Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
    Remove-Item Env:ROO_INDUSTRIES_TEST_FIRMWARE_ROOT, Env:ROO_INDUSTRIES_INITIAL_NAV
    $window = Wait-For { Get-AppWindow } 'the app window' 90
    [void][RooIndustriesFirmwarePageUi]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle)
    Invoke-Control (Wait-For { Find-Id 'OpenFirmware' } 'the Tools page' 90)
    [void](Wait-For { (Get-Text 'FirmwarePackageStatus') -ne '' -and (Get-Text 'FirmwarePackageStatus') -notlike 'First use*' } 'the SCEWIN package status' 60)
    $shownPackage = Get-Text 'FirmwarePackageStatus'
    if ($shownPackage -ne $expectedPackage) { throw "The BIOS page is not using the fixture package (shows '$shownPackage'). Nothing was loaded." }

    Wait-Load
    [void](Wait-For { Find-Named 'Fixture option' $controls::ComboBox } 'the loaded settings' 60)
    Set-Choice 'Fixture option' 'On'
    Set-Number 'Fixture delay' '9'
    Start-Frames
    [void](Add-Checkpoint '01-picked')
    Open-Nav 'Home'
    [void](Wait-For { -not (Find-Id 'FirmwareStep') } 'leaving the BIOS page')
    Start-Sleep -Milliseconds $PauseMs
    Open-Firmware
    $back = Add-Checkpoint '02-back-after-editing'
    Add-Check 'Coming back after leaving mid-edit keeps the picked values' ($back.step -eq '2  Edit settings' -and $back.option -eq 'On' -and $back.delay -eq '9')

    if ($back.step -ne '2  Edit settings') {
        Wait-Load
        [void](Wait-For { Find-Named 'Fixture option' $controls::ComboBox } 'the loaded settings' 60)
        Set-Choice 'Fixture option' 'On'
        Set-Number 'Fixture delay' '9'
    }
    Invoke-Control (Wait-For { $review = Find-Id 'ReviewFirmwareChanges'; if ($review -and $review.Current.IsEnabled) { $review } } 'Review changes')
    Invoke-Control (Wait-For { $apply = Find-Id 'ApplyFirmwareChanges'; if ($apply -and $apply.Current.IsEnabled) { $apply } } 'Apply')
    [IO.File]::WriteAllText($hold, 'held by the BIOS page UI run')
    Invoke-Control (Wait-For { Find-DialogButton 'Apply 2 changes' } 'the write confirmation')
    [void](Wait-For { (Get-Calls '/i') -eq 1 } 'the fixture write to start')
    [void](Add-Checkpoint '03-writing')
    Open-Nav 'Home'
    [void](Wait-For { -not (Find-Id 'FirmwareStep') } 'leaving the BIOS page')
    Start-Sleep -Milliseconds $PauseMs
    Open-Firmware
    $during = Add-Checkpoint '04-back-during-write'
    Add-Check 'Coming back during a write shows it still running' ($during.step -eq '3  Review changes' -and $during.message -eq $writing -and -not $during.loadShown -and -not $during.startOverShown)
    if ($during.loadShown) {
        Wait-Load
        [void](Wait-For { (Get-Text 'FirmwareMessage') -ne '' -and (Find-Id 'LoadFirmwareSettings').Current.IsEnabled } 'the Load attempt to end')
    }
    $load = Add-Checkpoint '05-load-during-write'
    Add-Check 'Load during a write starts nothing and shows no file-lock error' ($load.message -notlike '*another process*' -and (Get-Calls '/i') -eq 1)

    Remove-Item -LiteralPath $hold
    Wait-Written
    $result = Add-Checkpoint '06-result'
    Add-Check 'The write result and restart prompt appear once on the page' ($result.step -eq '4  Verify and restart' -and $result.restartShown -and [bool](Find-Named 'Changes saved. Restart when ready.' $controls::Text) -and (Get-Calls '/i') -eq 1)
    Stop-Frames

    Open-Nav 'Tools'
    $tools = $true
    try { [void](Wait-For { Find-Id 'OpenFirmware' } 'the Tools page' 5) } catch { $tools = $false }
    Add-Check 'The selected Tools item leads back to the tools list from the BIOS page' $tools
    Save-Shot '07-tools-item'

    if ($Label -eq 'after') {
        Open-Firmware
        Invoke-Control (Wait-For { $over = Find-Id 'FirmwareStartOver'; if ($over -and $over.Current.IsEnabled) { $over } } 'Start over')
        Wait-Load
        [void](Wait-For { Find-Named 'Fixture delay' $controls::Edit } 'the loaded settings' 60)
        Set-Number 'Fixture delay' '7'
        Invoke-Control (Wait-For { $over = Find-Id 'FirmwareStartOver'; if ($over -and $over.Current.IsEnabled) { $over } } 'Start over')
        [void](Wait-For { Find-Named 'Keep editing' $controls::Button } 'the discard question')
        Start-Sleep -Milliseconds $PauseMs
        Save-Shot '08-discard-question'
        Invoke-Control (Find-DialogButton 'Discard changes')
        [void](Wait-For { Test-Shown 'LoadFirmwareSettings' } 'the first step')
        $discarded = Add-Checkpoint '09-discarded'
        Add-Check 'Start over discards picks on purpose' ($discarded.step -like '1  Set up*' -and $discarded.loadShown -and (Get-Calls '/i') -eq 1)
    }
}
catch {
    Add-Check ('UI run finished: ' + $_.Exception.Message) $false
}
finally {
    if ($hold -and (Test-Path -LiteralPath $hold)) { Remove-Item -LiteralPath $hold }
    try { Stop-Frames } catch { Write-Verbose ('Frame capture stopped: ' + $_.Exception.Message) }
    if ($app -and -not $app.HasExited) { [void]$app.CloseMainWindow(); if (-not $app.WaitForExit(20000)) { Stop-Process -Id $app.Id -Force } }
    [ordered]@{ label = $Label; checkpoints = $checkpoints; checks = $checks } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutRoot 'ui-result.json') -Encoding UTF8
    foreach ($path in $firmwareRoot, $fixture) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    Write-Output ('Evidence: ' + $OutRoot)
}
if (@($checks | Where-Object { -not $_.passed }).Count) { exit 1 }
