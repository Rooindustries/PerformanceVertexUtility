param(
    [Parameter(Mandatory)][ValidateSet('override', 'incomplete')][string]$Check,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe',
    [switch]$Before
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class HelperStartU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
[HelperStartU32]::SetProcessDPIAware() | Out-Null
[HelperStartU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$Name = if ($Before) { $Check + '-before' } else { $Check }
$script:LogPath = Join-Path $OutDir ($Name + '.log')
$script:Failures = 0
$script:Renamed = @()
$script:App = $null
$script:Starts = [Collections.Generic.List[object]]::new()
$script:AllStarts = [Collections.Generic.List[object]]::new()
$install = Split-Path (Split-Path $Exe -Parent) -Parent
$hostDirectory = Join-Path $install 'backend\bin\optimizer'
$noSuchDotNet = 'C:\RooIndustriesNoSuchFolder\dotnet.exe'
$userDotNet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'

function Log([string]$m) { [IO.File]::AppendAllText($script:LogPath, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m + "`r`n") }
function Check([bool]$ok, [string]$name, [string]$detail) { if (-not $ok) { $script:Failures++ }; Log ($(if ($ok) { 'PASS ' } else { 'FAIL ' }) + $name + ' :: ' + $detail) }
function Shot([string]$name) {
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $b = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height; $g = [Drawing.Graphics]::FromImage($b)
    $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $b.Size); $b.Save((Join-Path $OutDir ('shot-' + $Name + '-' + $name + '.png')), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
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
function Nav([string]$name) {
    $item = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, $name), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))) } 30 "nav $name"
    Invoke-Element $item; Log "nav $name"
}
function Start-RooIndustriesApp {
    Stop-RooIndustriesApp
    $script:App = Start-Process $Exe -PassThru
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [HelperStartU32]::ShowWindow($h, 9) | Out-Null; [HelperStartU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [HelperStartU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}
function Stop-RooIndustriesApp {
    if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { $script:App.Kill() } }
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 1
}
function Data-Root {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    $current = Join-Path $local 'RooIndustriesOptimizationSuite'; $legacy = Join-Path $local ('RooIndustriesOptimizationSuite' -replace 'Industries','')
    if ((Test-Path -LiteralPath $legacy -PathType Container) -and -not ($markers -and $null -ne $markers.GetValue($current.ToUpperInvariant()) -and $null -eq $markers.GetValue($legacy.ToUpperInvariant()))) { $legacy } else { $current }
}
function Log-Lines { $path = Join-Path (Data-Root) 'logs\app.log'; if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path -Encoding UTF8) } else { @() } }
function Flush-Starts {
    foreach ($e in @(Get-Event -SourceIdentifier RooIndustriesHelperStartWatch -ErrorAction SilentlyContinue)) {
        $n = $e.SourceEventArgs.NewEvent
        $entry = [pscustomobject]@{ utc = [DateTime]::FromFileTimeUtc([int64]$n.TIME_CREATED).ToString('HH:mm:ss.fff'); pid = [int]$n.ProcessID; parent = [int]$n.ParentProcessID; name = [string]$n.ProcessName }
        $script:Starts.Add($entry); $script:AllStarts.Add($entry)
        Remove-Event -EventIdentifier $e.EventIdentifier
    }
}
function Watch-Rows { $path = Join-Path $OutDir ($Name + '-processes.csv'); if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ -notmatch '^#' } | ConvertFrom-Csv) } else { @() } }
function Image-Of([string]$commandLine) { if ($commandLine -match '^"([^"]+)"') { $Matches[1] } elseif ($commandLine -match '^(\S+)') { $Matches[1] } else { '' } }
function Descendants-Of([int[]]$roots) {
    $set = [Collections.Generic.HashSet[int]]::new(); foreach ($r in $roots) { [void]$set.Add($r) }
    do { $added = $false; foreach ($s in @($script:Starts)) { if ($set.Contains($s.parent) -and -not $set.Contains($s.pid)) { [void]$set.Add($s.pid); $added = $true } } } while ($added)
    $set
}
function Run-Script([string]$name, [string[]]$arguments) {
    $path = Join-Path $install ('backend\scripts\' + $name)
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $text = @(& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path @arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ exit = $code; text = ($text -join "`n") }
}
function Dotnet-Candidates { @($userDotNet, (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')) + @(Get-Command dotnet.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique }

$watcher = $null
$stopFile = Join-Path $OutDir 'procmon.stop'
try {
    Log ("check=$Check before=$([bool]$Before) install=$install version=" + (Get-Item $Exe).VersionInfo.ProductVersion)
    Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier RooIndustriesHelperStartWatch | Out-Null
    Remove-Item $stopFile -ErrorAction SilentlyContinue
    $watcher = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Watch-HelperProcesses.ps1'), '-OutCsv', (Join-Path $OutDir ($Name + '-processes.csv')), '-StopFile', $stopFile) -WindowStyle Hidden -PassThru
    WaitFor { Test-Path (Join-Path $OutDir ($Name + '-processes.csv.ready')) } 30 'the process watcher' | Out-Null
    Log ('dotnet.exe candidates on this PC: ' + ((Dotnet-Candidates) -join '; '))
    if (Test-Path -LiteralPath $userDotNet) {
        $controlRun = Start-Process $userDotNet -ArgumentList '--version' -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $OutDir ($Name + '-control-dotnet-version.txt'))
        Start-Sleep 2; Flush-Starts
        Check (@($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' -and $_.pid -eq $controlRun.Id }).Count -eq 1) 'control: the process trace sees a dotnet.exe that this scenario starts on purpose' ("pid=" + $controlRun.Id + " exit=" + $controlRun.ExitCode)
        $script:Starts.Clear()
    }
    else { Check $false 'control: the process trace sees a dotnet.exe that this scenario starts on purpose' ('no dotnet.exe at ' + $userDotNet) }

    if ($Check -eq 'override') {
        Check (-not (Test-Path -LiteralPath $noSuchDotNet)) 'the override target does not exist' $noSuchDotNet
        $logBefore = (Log-Lines).Count
        $env:ROO_INDUSTRIES_DOTNET_EXE = $noSuchDotNet
        try { Start-RooIndustriesApp } finally { Remove-Item Env:ROO_INDUSTRIES_DOTNET_EXE -ErrorAction SilentlyContinue }
        Nav 'Windows tweaks'
        $list = WaitFor { ById 'WindowsTweaksList' } 60 'Windows tweaks list'
        $rows = WaitFor { $c = @($list.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))).Count; if ($c -gt 0) { $c } } 180 'Windows tweaks rows'
        $status = WaitFor { $s = ById 'WindowsTweaksStatus'; if ($s -and $s.Current.Name -notmatch '^Loading') { $s.Current.Name } } 180 'Windows tweaks status'
        Shot 'tweaks'
        Flush-Starts
        $hostRows = @(Watch-Rows | Where-Object { $_.name -eq 'Optimizer.Host.exe' -and [int]$_.ppid -eq $script:App.Id -and $_.command_line })
        $images = @($hostRows | ForEach-Object { Image-Of $_.command_line } | Select-Object -Unique)
        $inside = @($images | Where-Object { $_.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase) })
        Check ($rows -gt 0 -and $status -notmatch 'missing|went wrong|couldn') 'with ROO_INDUSTRIES_DOTNET_EXE pointing at a missing dotnet.exe, the release app still loads the Windows tweaks rows' ("rows=$rows status=$status")
        Check ($hostRows.Count -gt 0 -and $inside.Count -eq $images.Count) 'the app started Optimizer.Host.exe children whose image is inside the install folder' ("children=$($hostRows.Count) images=" + ($images -join '; '))
        $new = @(Log-Lines | Select-Object -Skip $logBefore)
        Check (@($new | Where-Object { $_ -match 'RooIndustriesNoSuchFolder' }).Count -eq 0) 'the app log does not mention the override path' ('new log lines: ' + $new.Count)
        Check (@($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' }).Count -eq 0) 'the app never started a dotnet.exe' ('dotnet.exe starts: ' + @($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' }).Count)
    }
    else {
        $dll = Join-Path $hostDirectory 'hostpolicy.dll'
        Check (Test-Path -LiteralPath $dll) 'hostpolicy.dll is installed before the check' $dll
        Check (Test-Path -LiteralPath $userDotNet) 'a genuine Microsoft dotnet.exe is installed in the user profile (so a fallback would find it)' ($userDotNet + ' ' + $(if (Test-Path -LiteralPath $userDotNet) { (Get-Item $userDotNet).VersionInfo.ProductVersion } else { '' }))
        Rename-Item -LiteralPath $dll -NewName 'hostpolicy.dll.roo-industries-test-off'; $script:Renamed += $dll
        Log 'renamed hostpolicy.dll to hostpolicy.dll.roo-industries-test-off'
        $logBefore = (Log-Lines).Count
        Flush-Starts; $script:Starts.Clear()
        Start-RooIndustriesApp
        Nav 'Windows tweaks'
        $message = $null
        try { $message = WaitFor { @(Texts | Where-Object { $_ -match 'app files are missing' })[0] } 90 'the missing-files message' } catch {}
        Start-Sleep 3
        Shot 'tweaks'
        Flush-Starts
        $appTree = Descendants-Of @($script:App.Id)
        $dotnetStarts = @($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' })
        $byApp = @($dotnetStarts | Where-Object { $appTree.Contains($_.parent) })
        $new = @(Log-Lines | Select-Object -Skip $logBefore)
        $logged = @($new | Where-Object { $_ -match 'Missing .*hostpolicy\.dll' })
        $csv = @(Watch-Rows | Where-Object { $_.name -eq 'dotnet.exe' -and $_.command_line } | ForEach-Object { $_.command_line })
        if ($Before) {
            Check ($byApp.Count -gt 0) 'BEFORE (commit 6d86fd8): the app starts dotnet.exe from the user profile when the bundled runtime is missing' ("dotnet.exe starts by the app: $($byApp.Count); all dotnet.exe starts: $($dotnetStarts.Count); sampled command lines: " + (($csv | Select-Object -First 2) -join ' || '))
            Check ($null -eq $message) 'BEFORE (commit 6d86fd8): no missing-files message is shown (the app went on to run the fallback runtime)' ("message=" + $message + " texts=" + ((Texts | Select-Object -First 12) -join ' | '))
            Check ($logged.Count -eq 0) 'BEFORE (commit 6d86fd8): the app log has no Missing hostpolicy.dll line' ($logged -join ' | ')
        }
        else {
            Check ($null -ne $message) 'Windows tweaks shows the missing-files message when hostpolicy.dll is missing' ("message=" + $message)
            Check ($logged.Count -gt 0) 'the app log has a Missing hostpolicy.dll line' ($logged -join ' | ')
            Check ($dotnetStarts.Count -eq 0) 'no dotnet.exe was started anywhere on this PC while the app was open on the incomplete install' ("dotnet.exe starts: $($dotnetStarts.Count); starts by the app tree: $($byApp.Count); sampled command lines: " + (($csv | Select-Object -First 2) -join ' || '))
        }
        Stop-RooIndustriesApp
        Flush-Starts; $script:Starts.Clear()
        $sessionRoot = Join-Path (Data-Root) 'operations\game-session-roo-industries-incomplete-check\session'
        foreach ($case in @(
            @{ Script = 'Invoke-CleanupExclusions.ps1'; Arguments = @('-Action', 'Status') },
            @{ Script = 'Invoke-ProtectedGameSession.ps1'; Arguments = @('-Action', 'Status', '-SessionRoot', $sessionRoot) })) {
            Flush-Starts; $script:Starts.Clear()
            $run = Run-Script $case.Script $case.Arguments
            Start-Sleep 1
            Flush-Starts
            $caseStarts = @($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' })
            Set-Content -LiteralPath (Join-Path $OutDir ($Name + '-' + $case.Script + '.txt')) -Value ('exit ' + $run.exit + "`n" + $run.text) -Encoding UTF8
            if ($Before) {
                Check ($caseStarts.Count -gt 0 -and $run.text -notmatch 'missing or damaged') ("BEFORE (commit 6d86fd8): the installed " + $case.Script + ' starts dotnet.exe from the user profile') ("exit=$($run.exit) dotnet.exe starts=$($caseStarts.Count) output=" + $run.text.Substring(0, [Math]::Min(300, $run.text.Length)))
            }
            else {
                Check ($run.exit -ne 0 -and $run.text -match 'missing or damaged' -and $caseStarts.Count -eq 0) ("the installed " + $case.Script + ' refuses with the missing-or-damaged message and starts no dotnet.exe') ("exit=$($run.exit) dotnet.exe starts=$($caseStarts.Count) output=" + $run.text.Substring(0, [Math]::Min(300, $run.text.Length)))
            }
        }
        Rename-Item -LiteralPath ($dll + '.roo-industries-test-off') -NewName 'hostpolicy.dll'; $script:Renamed = @()
        Check (Test-Path -LiteralPath $dll) 'hostpolicy.dll is back in place' $dll
    }
}
catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    foreach ($path in @($script:Renamed)) { try { if (-not (Test-Path -LiteralPath $path)) { Rename-Item -LiteralPath ($path + '.roo-industries-test-off') -NewName (Split-Path $path -Leaf) }; Log ('restored ' + (Split-Path $path -Leaf)) } catch { Log ('CLEANUP NEEDED: restore ' + $path) } }
    Remove-Item Env:ROO_INDUSTRIES_DOTNET_EXE -ErrorAction SilentlyContinue
    Stop-RooIndustriesApp
    try { Flush-Starts; $script:AllStarts | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir ($Name + '-process-starts.csv')) } catch {}
    Get-EventSubscriber -SourceIdentifier RooIndustriesHelperStartWatch -ErrorAction SilentlyContinue | Unregister-Event
    'x' | Set-Content $stopFile
    if ($watcher) { $watcher.WaitForExit(15000) | Out-Null }
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir ($Name + '.done'))
}
