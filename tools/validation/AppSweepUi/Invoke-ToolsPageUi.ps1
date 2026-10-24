param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutRoot,
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE,
    [int]$PauseMs = 1200
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
[void](Initialize-HarnessInvocation 'tools-page' $OutRoot)
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory = New-HarnessEvidenceDirectory $OutRoot 'tools-page'
if ([string]::IsNullOrWhiteSpace($DotNetPath)) { $DotNetPath = @((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'), (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'), (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Where-Object { @(& $_ --list-sdks 2>$null).Count } | Select-Object -First 1)[0] }
if (-not $DotNetPath) { throw 'No .NET SDK was found to build the app.' }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesToolsPageUi
{
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
}
'@
[void][RooIndustriesToolsPageUi]::SetProcessDpiAwarenessContext([IntPtr]-4)

$element = [Windows.Automation.AutomationElement]
$scope = [Windows.Automation.TreeScope]
$controls = [Windows.Automation.ControlType]
$jargon = [regex]::new('\b(?:telemetry|mitigations?|runtimes?|redistributable|legacy|librar(?:y|ies)|components?|interrupts?|parking|pcie|x64|x86|dpc|isr|qos|affinity|registry|powershell|processes|process|child|dynamic boosts?|execution|profiles?|enum|0x[0-9a-f]+)\b', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
$catalog = @(([IO.File]::ReadAllText((Join-Path $Source 'modules\tool-launchers.json')) | ConvertFrom-Json).tools)
$names = @($catalog | ForEach-Object { $_.name } | Sort-Object Length -Descending)
$checks = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.List[string]]::new()
$categories = @()
$counts = [ordered]@{}
$term = ''
$oneMatch = ''
$app = $null
$handle = [IntPtr]::Zero
$buildLog = Join-Path $directory 'build.log'

function Get-AppWindow { if ($script:handle -ne [IntPtr]::Zero) { $element::FromHandle($script:handle) } }
function New-Id([string]$Id) { New-Object Windows.Automation.PropertyCondition($element::AutomationIdProperty, $Id) }
function Find-Id([string]$Id) {
    $window = Get-AppWindow
    if ($null -eq $window) { return $null }
    $window.FindFirst($scope::Descendants, (New-Id $Id))
}
function Find-Named([string]$Name, $Type) {
    $window = Get-AppWindow
    if ($null -eq $window) { return $null }
    $condition = New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition($element::NameProperty, $Name)), (New-Object Windows.Automation.PropertyCondition($element::ControlTypeProperty, $Type)))
    $window.FindFirst($scope::Descendants, $condition)
}
function Wait-For([scriptblock]$Probe, [string]$What, [int]$Seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try { $value = & $Probe } catch { $value = $null }
        if ($value) { return $value }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $What"
}
function Get-Value($Item) {
    $pattern = $null
    if ($Item.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { $pattern.Current.Value }
}
function Get-Page {
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    $page = $walker.GetParent((Wait-For { Find-Id 'ToolSearch' } 'the tool search box'))
    while ($page -and -not ($page.FindFirst($scope::Descendants, (New-Id 'OpenFirmware')) -and $page.FindFirst($scope::Descendants, (New-Id 'RefreshTools')))) { $page = $walker.GetParent($page) }
    if (-not $page) { throw 'No element holds both the Tools header and the tool list.' }
    $page
}
function Get-Texts {
    $left = (Find-Id 'ToolSearch').Current.BoundingRectangle.Left - 4
    foreach ($item in @((Get-Page).FindAll($scope::Descendants, [Windows.Automation.Condition]::TrueCondition))) {
        try {
            $current = $item.Current
            if ($current.BoundingRectangle.Left -lt $left) { continue }
            foreach ($text in @($current.Name, (Get-Value $item))) { if (-not [string]::IsNullOrWhiteSpace($text)) { $text.Trim() } }
        }
        catch [Windows.Automation.ElementNotAvailableException] { continue }
    }
}
function Add-Seen([string[]]$Texts) { foreach ($text in $Texts) { if (-not $seen.Contains($text)) { $seen.Add($text) } } }
function Read-Page {
    Add-Seen @(Get-Texts)
    $grid = Find-Id 'ToolGrid'
    $pattern = $null
    if (-not ($grid -and $grid.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$pattern) -and $pattern.Current.VerticallyScrollable)) { return }
    $pattern.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 0)
    for ($step = 0; $step -lt 40 -and $pattern.Current.VerticalScrollPercent -lt 99.9; $step++) {
        $before = $pattern.Current.VerticalScrollPercent
        $pattern.ScrollVertical([Windows.Automation.ScrollAmount]::LargeIncrement)
        Start-Sleep -Milliseconds 400
        Add-Seen @(Get-Texts)
        if ($pattern.Current.VerticalScrollPercent -le $before) { break }
    }
    $pattern.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 0)
    Start-Sleep -Milliseconds 400
}
function Get-Count { @(Get-Texts | Where-Object { $_ -match '^\d+ tools?$' -or $_.StartsWith('No tools match') }) | Select-Object -First 1 }
function Wait-Count([string]$Pattern) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $count = Get-Count
        if ($count -match $Pattern) { return $count }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    [string]$count
}
function Get-Expected([string]$Category) { if ($Category -eq $categories[0]) { $catalog.Count } else { @($catalog | Where-Object { $_.category -ceq $Category }).Count } }
function Get-ComboItems($Combo) { @($Combo.FindAll($scope::Descendants, (New-Object Windows.Automation.PropertyCondition($element::ControlTypeProperty, $controls::ListItem)))) }
function Open-Categories {
    $combo = Wait-For { Find-Id 'ToolCategory' } 'the category picker'
    $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    [void](Wait-For { @(Get-ComboItems $combo).Count -gt 1 } 'the category list')
    $combo
}
function Close-Categories($Combo) {
    try { $Combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch { Write-Verbose 'The picker closed itself.' }
    Start-Sleep -Milliseconds 400
}
function Select-Category([string]$Name) {
    $combo = Open-Categories
    $item = Wait-For { Get-ComboItems $combo | Where-Object { $_.Current.Name -ceq $Name } | Select-Object -First 1 } "the $Name category"
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Close-Categories $combo
}
function Save-Shot([string]$Name) {
    $rect = New-Object RooIndustriesToolsPageUi+Rect
    [void][RooIndustriesToolsPageUi]::GetWindowRect($script:handle, [ref]$rect)
    $frame = New-Object RooIndustriesToolsPageUi+Rect
    if ([RooIndustriesToolsPageUi]::DwmGetWindowAttribute($script:handle, 9, [ref]$frame, 16) -ne 0) { $frame = $rect }
    $bitmap = New-Object Drawing.Bitmap ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    try { [void][RooIndustriesToolsPageUi]::PrintWindow($script:handle, $dc, 2) } finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
    $area = [Drawing.Rectangle]::Intersect((New-Object Drawing.Rectangle ($frame.Left - $rect.Left), ($frame.Top - $rect.Top), ($frame.Right - $frame.Left), ($frame.Bottom - $frame.Top)), (New-Object Drawing.Rectangle 0, 0, $bitmap.Width, $bitmap.Height))
    $window = $bitmap.Clone($area, $bitmap.PixelFormat)
    try { $window.Save((Join-Path $directory ($Name + '.png')), [Drawing.Imaging.ImageFormat]::Png) } finally { $window.Dispose(); $bitmap.Dispose() }
}
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail = '') {
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail }) | Out-Null
    Write-Output (($(if ($Passed) { 'PASS ' } else { 'FAIL ' })) + $Name + $(if ($Detail) { ' :: ' + $Detail } else { '' }))
}
function Invoke-Build {
    $ErrorActionPreference = 'Continue'
    Initialize-HarnessBuildFolders $Source
    Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
    & $DotNetPath publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:UseSharedCompilation=false *>> $buildLog
    if ($LASTEXITCODE -ne 0) { throw 'The helper build failed; see build.log.' }
    & $DotNetPath build (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj') --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:UseSharedCompilation=false *>> $buildLog
    if ($LASTEXITCODE -ne 0) { throw 'The app build failed; see build.log.' }
}

try {
    if (Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue) { throw 'The app is already open; this check does not take over another window.' }
    $env:MSBUILDDISABLENODEREUSE = '1'; $env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    Invoke-Build
    $exe = Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $exe) { throw 'The app build produced no executable.' }

    $env:DOTNET_ROOT = Split-Path $DotNetPath -Parent; $env:ROO_INDUSTRIES_DOTNET_EXE = $DotNetPath; $env:ROO_INDUSTRIES_INITIAL_NAV = 'tools'
    $app = Start-OwnedProcess -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
    Remove-Item Env:ROO_INDUSTRIES_INITIAL_NAV
    $window = Wait-For { $found = $element::RootElement.FindFirst($scope::Children, (New-Object Windows.Automation.PropertyCondition($element::ProcessIdProperty, [int]$app.Identity.pid))); if ($found -and $found.Current.NativeWindowHandle) { $found } } 'the app window' 120
    $handle = [IntPtr]$window.Current.NativeWindowHandle
    [void](Wait-For { $tool = Find-Named $catalog[0].name $controls::Text; $tool -and -not $tool.Current.IsOffscreen } ('the ' + $catalog[0].name + ' card') 120)
    [void](Wait-Count ('^' + $catalog.Count + ' tools?$'))
    Start-Sleep -Milliseconds $PauseMs
    Read-Page
    Save-Shot 'tools-page'

    $combo = Open-Categories
    $categories = @(Get-ComboItems $combo | ForEach-Object { $_.Current.Name })
    Close-Categories $combo
    Add-Seen $categories
    foreach ($category in $categories) {
        Select-Category $category
        $counts[$category] = Wait-Count ('^' + (Get-Expected $category) + ' tools?$')
        Read-Page
    }
    Start-Sleep -Milliseconds $PauseMs
    Save-Shot 'tools-category'

    Select-Category $categories[0]
    $term = ($catalog | Where-Object { $name = $_.name; @($catalog | Where-Object { ($_.name + ' ' + $_.description).IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -eq 1 } | Select-Object -First 1).name
    $search = (Find-Id 'ToolSearch').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue($term)
    $oneMatch = Wait-Count '^1 tools?$'
    Add-Seen @(Get-Texts)
    $search.SetValue('')

    $missing = @($catalog | Where-Object { -not $seen.Contains($_.name) } | ForEach-Object { $_.name })
    Add-Check 'The Tools page shows every tool in the catalog' ($missing.Count -eq 0) ($missing -join ', ')
    $hits = @(foreach ($text in $seen) {
        $plain = $text
        foreach ($name in $names) { $plain = $plain.Replace($name, '') }
        $hit = $jargon.Match($plain)
        if ($hit.Success) { '"' + $text + '" (' + $hit.Value + ')' }
    })
    Add-Check 'No text on the Tools page or in its category list uses jargon' ($hits.Count -eq 0) ($hits -join '; ')
    Add-Check 'The category list has Game support' ($categories -ccontains 'Game support') ($categories -join ', ')
    Add-Check 'The category list has no Runtimes' (-not ($categories -contains 'Runtimes')) ($categories -join ', ')
    $wrong = @(foreach ($category in $categories) { if ($counts[$category] -notmatch ('^' + (Get-Expected $category) + ' tools?$')) { $category + ': ' + $counts[$category] } })
    Add-Check 'Each category shows as many tools as the catalog lists for it' ($wrong.Count -eq 0) ($wrong -join '; ')
    Add-Check 'One matching tool reads "1 tool", never "1 tools"' ($oneMatch -ceq '1 tool' -and -not @($counts.Values | Where-Object { $_ -ceq '1 tools' }).Count) ($term + ': ' + $oneMatch)
}
catch {
    Add-Check ('UI run finished: ' + $_.Exception.Message) $false
}
finally {
    if ($env:ROO_INDUSTRIES_INITIAL_NAV) { Remove-Item Env:ROO_INDUSTRIES_INITIAL_NAV }
    if ($app) {
        if (-not $app.process.HasExited) { [void]$app.process.CloseMainWindow(); [void]$app.process.WaitForExit(20000) }
        Stop-HarnessProcess $app
    }
    $checks | ForEach-Object { $(if ($_.passed) { 'PASS ' } else { 'FAIL ' }) + $_.name + $(if ($_.detail) { ' :: ' + $_.detail } else { '' }) } | Set-Content -LiteralPath (Join-Path $directory 'tools-page-ui.txt') -Encoding UTF8
    [ordered]@{ categories = $categories; counts = $counts; search = $term; oneMatch = $oneMatch; texts = $seen; checks = $checks } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory 'tools-page-ui.json') -Encoding UTF8
    Write-Output ('ROO_INDUSTRIES_TOOLS_PAGE ' + $(if (@($checks | Where-Object { -not $_.passed }).Count) { 'fail' } else { 'pass' }) + ' ' + $directory)
}
if (@($checks | Where-Object { -not $_.passed }).Count) { exit 1 }
