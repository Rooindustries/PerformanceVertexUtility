param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,40}$')][string]$Label
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1'))
$nonce = Initialize-HarnessInvocation 'license-rows' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$postMessage = '[DllImport("user32.dll")] public static extern bool PostMessage(' +
    'IntPtr window, uint message, IntPtr wParam, IntPtr lParam);'
Add-Type -Namespace RooIndustriesLicenseRows -Name Native -MemberDefinition $postMessage
$A = [Windows.Automation.AutomationElement]
$TS = [Windows.Automation.TreeScope]
$CT = [Windows.Automation.ControlType]
$out = Join-Path $OutRoot $Label
if (Test-HarnessPath $out) { throw 'The output folder already exists; use a new label.' }
Enter-HarnessHostLease
New-HarnessDirectory $out 'evidence' | Out-Null
$installKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
$installDir = Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite'
$results = [ordered]@{ S1 = [ordered]@{ result = 'not run' } }
$steps = [Collections.Generic.List[object]]::new()
$utf8 = [Text.UTF8Encoding]::new($false)

function Note([string]$Row, [string]$Step, $Detail) {
    $steps.Add([ordered]@{ row = $Row; step = $Step; timeUtc = [DateTime]::UtcNow.ToString('o'); detail = $Detail })
    [Console]::Out.WriteLine($Row + ' ' + $Step + ' :: ' + (ConvertTo-Json $Detail -Compress -Depth 6))
}

function Poll([scriptblock]$Probe, [double]$Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
    $null
}

function Visible($Root) {
    $all = $Root.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)
    @($all | Where-Object { -not $_.Current.IsOffscreen })
}

function Lines([string]$Text) {
    ($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n")
}

function TextOf($Element) {
    $pattern = $null
    if ($Element.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
        return $pattern.DocumentRange.GetText(-1)
    }
    ''
}

function Invoke($Element, [int]$ProcessId) {
    if ($Element.Current.ProcessId -ne $ProcessId) { throw 'The control belongs to another process.' }
    $pattern = $null
    if ($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return
    }
    $handle = [IntPtr]::new($Element.Current.NativeWindowHandle)
    $sent = [RooIndustriesLicenseRows.Native]::PostMessage($handle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $sent) { throw 'The button press could not be sent.' }
}

function Installed {
    [ordered]@{ uninstallKey = (Test-Path -LiteralPath $installKey); installFolder = (Test-HarnessPath $installDir) }
}

function Build {
    $copy = Join-Path (Split-Path $Source) ('b-' + $Label)
    if (Test-HarnessPath $copy) { throw 'The build copy already exists; use a new label.' }
    New-HarnessDirectory $copy 'build-source' | Out-Null
    foreach ($file in Get-HarnessTree $Source -FilesOnly | Where-Object { Test-HarnessVisiblePath $_ $Source }) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        if ($relative -match '(^|\\)(obj|bin|artifacts|\.git)(\\|$)') { continue }
        if ($relative -eq 'source-verification.json') { continue }
        $destination = Join-Path $copy $relative
        [IO.Directory]::CreateDirectory((Get-HarnessLongPath ([IO.Path]::GetDirectoryName($destination)))) | Out-Null
        [IO.File]::Copy($file.LongPath, (Get-HarnessLongPath $destination), $true)
    }
    $app = 'docs\internal\frontend\RooIndustries.OptimizationSuite.App'
    $project = Join-Path $copy ($app + '\RooIndustries.OptimizationSuite.App.csproj')
    $text = [IO.File]::ReadAllText((Get-HarnessLongPath $project))
    $found = [regex]::Matches($text, '<Version>(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?</Version>')
    if ($found.Count -ne 1) { throw 'Expected exactly one Version element in the app project.' }
    $match = $found[0]
    $headVersion = $match.Value.Substring(9).Replace('</Version>', '')
    $patch = [int]$match.Groups[3].Value + 1
    $version = '{0}.{1}.{2}-licensecheck' -f $match.Groups[1].Value, $match.Groups[2].Value, $patch
    $raised = $text.Replace($match.Value, '<Version>' + $version + '</Version>')
    [IO.File]::WriteAllText((Get-HarnessLongPath $project), $raised, $utf8)
    Initialize-HarnessBuildFolders $copy
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $script = Join-Path $copy 'tools\scripts\Build-Release.ps1'
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -Command "& ''' + $script + ''' -UpdateFeedUrl ''''"'
    $log = Invoke-HarnessProcess $powershell $arguments 'release-build'
    [IO.File]::WriteAllText((Join-Path $out 'release-build.log'), $log, $utf8)
    $release = Join-Path $copy 'artifacts\release'
    $installer = Join-Path $release ('RooIndustries-OptimizationSuite-' + $version + '-setup.exe')
    $stage = Join-Path $release ('work-' + $version + '\stage')
    if (-not (Test-HarnessPath $installer)) { throw 'The release build left no installer.' }
    if (-not (Test-HarnessPath $stage)) { throw 'The release build left no layout.' }
    $layout = @(Get-HarnessTree $stage -FilesOnly | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($stage.Length + 1); bytes = $_.Length }
    })
    [IO.File]::WriteAllText((Join-Path $out 'layout.json'), (ConvertTo-Json $layout -Depth 4), $utf8)
    $build = [ordered]@{
        headVersion = $headVersion
        buildVersion = $version
        changedFromHead = @('the app project Version line')
        installer = $installer
        sha256 = (Get-HarnessFileSha256 $installer)
        stage = $stage
        layoutFiles = $layout.Count
    }
    Note 'build' 'release built by Build-Release.ps1' $build
    $build
}

function WizardWindow($Owned) {
    $condition = [Windows.Automation.PropertyCondition]::new($A::ClassNameProperty, 'TWizardForm')
    $windows = $A::RootElement.FindAll($TS::Children, $condition)
    @($windows | Where-Object { Test-OwnedDescendant ([int]$_.Current.ProcessId) -Ancestor $Owned })
}

function Page($Window, [string]$License) {
    $visible = Visible $Window
    $buttonElements = $visible | Where-Object {
        $_.Current.ControlType -eq $CT::Button -or $_.Current.ClassName -ceq 'TNewButton'
    }
    $buttons = @($buttonElements | ForEach-Object {
        [ordered]@{ name = [string]$_.Current.Name; enabled = $_.Current.IsEnabled; element = $_ }
    })
    $viewers = $visible | Where-Object { $_.Current.ClassName -match 'RichEdit' }
    $texts = @($viewers | ForEach-Object { Lines (TextOf $_) })
    $headings = $visible | Where-Object {
        $_.Current.ControlType -eq $CT::Text -or $_.Current.ClassName -ceq 'TNewStaticText'
    }
    $choices = $visible | Where-Object {
        $_.Current.ControlType -eq $CT::RadioButton -or $_.Current.ControlType -eq $CT::CheckBox -or
            $_.Current.ClassName -match '^TNew(RadioButton|CheckBox|CheckListBox)$'
    }
    $enabled = @($buttons | Where-Object { $_.enabled })
    $headingNames = @($headings | ForEach-Object { [string]$_.Current.Name } | Where-Object { $_ })
    [ordered]@{
        heading = @($headingNames | Select-Object -First 2)
        buttons = @($buttons | ForEach-Object { $_.name })
        next = @($enabled | Where-Object { $_.name -match '^&?Next\s*>?$' } | ForEach-Object { $_.element })[0]
        install = @($enabled | Where-Object { $_.name -match '^&?Install$' }).Count -gt 0
        cancel = @($enabled | Where-Object { $_.name -match '^&?Cancel$' } | ForEach-Object { $_.element })[0]
        choices = @($choices | ForEach-Object { [string]$_.Current.Name })
        viewerChars = @($texts | ForEach-Object { $_.Length })
        license = @($texts | Where-Object { $_ -ceq $License }).Count -gt 0
        unread = @($texts | Where-Object { -not $_ }).Count
    }
}

function PageControls($Window) {
    $all = $Window.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)
    @($all | ForEach-Object {
        $current = $_.Current
        $current.ControlType.ProgrammaticName + '|' + $current.Name + '|' + $current.ClassName + '|offscreen=' +
            $current.IsOffscreen + '|enabled=' + $current.IsEnabled
    })
}

function WalkWizard($Row, $Build, $Owned, [string]$License, $Pages) {
    $window = Poll { @(WizardWindow $Owned)[0] } 120
    $wizardTitle = if ($window) { $window.Current.Name } else { $null }
    $Row.start = [ordered]@{
        installer = $Build.installer
        sha256 = $Build.sha256
        arguments = ''
        wizard = $wizardTitle
        installedBefore = $Row.installedBefore
    }
    Note 'S1' 'start' $Row.start
    if (-not $window) {
        $Row.result = 'invalid'
        $Row.reason = 'The setup wizard never appeared.'
        return
    }
    $previous = $null
    for ($n = 1; $n -le 12; $n++) {
        $page = Poll {
            $candidate = Page $window $License
            $key = ($candidate.heading + $candidate.buttons) -join '|'
            if ($key -cne $previous -and ($candidate.next -or $candidate.install)) { $candidate }
        } 30
        if (-not $page) {
            Note 'S1' ('page ' + $n + ' controls') (PageControls $window)
            $Row.result = 'invalid'
            $Row.reason = 'Page ' + $n + ' could not be read or offered neither Next nor Install.'
            return
        }
        $previous = ($page.heading + $page.buttons) -join '|'
        $Row.cancel = $page.cancel
        $record = [ordered]@{
            number = $n
            heading = $page.heading
            buttons = $page.buttons
            choices = $page.choices
            viewerChars = $page.viewerChars
            showsLicense = $page.license
            install = $page.install
        }
        $Pages.Add($record)
        Note 'S1' ('page ' + $n) $record
        if ($page.unread) {
            $Row.result = 'invalid'
            $Row.reason = 'The text on page ' + $n + ' could not be read.'
            return
        }
        if ($page.install) { break }
        Invoke $page.next ([int]$window.Current.ProcessId)
    }
    if (-not @($Pages | Where-Object { $_.install }).Count) {
        $Row.result = 'invalid'
        $Row.reason = 'The wizard never reached the page with Install.'
        return
    }
    $licensePages = @($Pages | Where-Object {
        $_.showsLicense -and -not $_.install -and $_.buttons -match '^&?Next\s*>?$' -and $_.choices.Count -eq 0
    })
    $Row.observation = [ordered]@{
        pagesBeforeInstall = $Pages.Count - 1
        licensePages = @($licensePages | ForEach-Object { $_.number })
        licenseChars = $License.Length
    }
    Note 'S1' 'wizard observed' $Row.observation
    $Row.result = if ($licensePages.Count -ge 1) { 'passed' } else { 'failed' }
}

function CloseSetup($Row, $Owned) {
    $cancel = $Row['cancel']
    $Row.Remove('cancel')
    if ($cancel -and -not $Owned.process.HasExited) {
        Invoke $cancel ([int]$cancel.Current.ProcessId)
        $dialogs = [Windows.Automation.PropertyCondition]::new($A::ClassNameProperty, '#32770')
        $yesCondition = [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Yes')
        $yes = Poll {
            $owned = $A::RootElement.FindAll($TS::Children, $dialogs) | Where-Object {
                Test-OwnedDescendant ([int]$_.Current.ProcessId) -Ancestor $Owned
            }
            @($owned | ForEach-Object { $_.FindFirst($TS::Descendants, $yesCondition) } | Where-Object { $_ })[0]
        } 15
        if ($yes) { Invoke $yes ([int]$yes.Current.ProcessId) }
    }
    if (-not $Owned.process.WaitForExit(30000)) { Stop-HarnessProcess $Owned }
}

function RowS1($Build) {
    $row = $results.S1
    $license = Lines ([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'LICENSE'))))
    if (@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '(?i)setup.*\.(exe|tmp)$' }).Count) {
        throw 'Another setup is running; this run left it alone.'
    }
    $row.installedBefore = Installed
    $owned = Start-OwnedProcess -FilePath $Build.installer -WindowStyle Normal -Purpose 'hand-run-setup'
    $pages = [Collections.Generic.List[object]]::new()
    try {
        WalkWizard $row $Build $owned $license $pages
    } finally {
        $row.pages = @($pages)
        CloseSetup $row $owned
        $row.installedAfter = Installed
        $closed = [ordered]@{
            exited = $owned.process.HasExited
            installedBefore = $row.installedBefore
            installedAfter = $row.installedAfter
        }
        Note 'S1' 'setup closed' $closed
        if (($row.installedAfter | ConvertTo-Json) -cne ($row.installedBefore | ConvertTo-Json)) {
            $row.result = 'invalid'
            $row.reason = 'Setup changed the install state.'
        }
    }
}

try {
    $build = Build
    RowS1 $build
} catch {
    $results.S1.result = 'invalid'
    $results.S1.reason = $_.Exception.Message
    Note 'S1' 'error' $_.ScriptStackTrace
} finally {
    $json = ConvertTo-Json @{ label = $Label; rows = $results; steps = $steps } -Depth 10
    [IO.File]::WriteAllText((Join-Path $out 'results.json'), $json, $utf8)
    $reason = if ($results.S1.reason) { ' :: ' + $results.S1.reason } else { '' }
    Write-Output ('ROW S1 ' + $results.S1.result + $reason)
    Complete-HarnessInvocation $(if ($results.S1.result -ne 'passed') { 'fail' } else { 'pass' }) -Cleanup | Out-Null
}
if ($results.S1.result -ne 'passed') { throw ('Row S1 ' + $results.S1.result) }
