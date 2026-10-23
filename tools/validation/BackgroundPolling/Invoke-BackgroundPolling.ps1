param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$OutRoot,
    [ValidateSet('all','games','processes')][string]$Scenario = 'all',
    [ValidateRange(10, 300)][int]$InactiveSeconds = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
. (Join-Path $Source 'tools\validation\UiAutomation\ComboChoice.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type -Path (Join-Path $Source 'tools\validation\BackgroundPolling\BackgroundPollingWatch.cs') -ReferencedAssemblies System.Management
[BackgroundPollingUi]::SetProcessDPIAware() | Out-Null

$directory = Join-Path $OutRoot 'background-polling'
if (Test-Path -LiteralPath $directory) { throw 'Evidence directory already exists; choose a fresh OutRoot.' }
[IO.Directory]::CreateDirectory($directory) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$owned = [Collections.Generic.List[object]]::new()
$cases = [Collections.Generic.List[object]]::new()
$focusLog = [Collections.Generic.List[object]]::new()
$app = $null; $receipt = $null; $watch = $null; $window = $null; $sessionRoot = $null; $launcherReceipt = $null; $gamePath = $null; $operations = $null; $existingOperations = @()
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$hostNames = 'dotnet.exe', 'Optimizer.Host.exe'
$settled = 0
$held = @{}

function Save([string]$name, $value) { [IO.File]::WriteAllText((Join-Path $directory $name), ($value | ConvertTo-Json -Depth 30), $utf8) }
function WaitFor([scriptblock]$probe, [double]$seconds, [string]$what) { $deadline = [DateTime]::UtcNow.AddSeconds($seconds); while ([DateTime]::UtcNow -lt $deadline) { try { $v = & $probe } catch { $v = $null }; if ($v) { return $v }; Start-Sleep -Milliseconds 100 }; throw ('Timed out: ' + $what) }
function ById([string]$id) { $window.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty, $id)) }
function All { @($window.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) }
function Texts { @(All | Where-Object { $_.Current.ControlType -eq $CT::Text } | ForEach-Object { $_.Current.Name }) }
function Activate($e) { if (-not $e) { throw 'Missing UI element' }; try { $e.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView() } catch {}; try { $e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); return } catch {}; try { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); return } catch {}; $e.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() }
function InvokeId([string]$id) { Activate (WaitFor { $e = ById $id; if ($e -and $e.Current.IsEnabled) { $e } } 90 $id) }
function SetValue([string]$id, [string]$value) { (WaitFor { $e = ById $id; if ($e -and $e.Current.IsEnabled) { $e } } 90 $id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($value) }
function Toggle([string]$id) { $e = WaitFor { ById $id } 45 $id; $p = $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern); if ([string]$p.Current.ToggleState -ne 'On') { $p.Toggle() } }
function Nav([string]$name) { Activate (WaitFor { @(All | Where-Object { $_.Current.Name -eq $name -and $_.Current.ControlType -eq $CT::ListItem }) | Select-Object -First 1 } 45 $name) }
function ChooseId([string]$id, [string]$pattern) { Select-ComboChoice $window $id $pattern 90 | Out-Null }
function Shot([string]$name) { $r = $window.Current.BoundingRectangle; $b = [Drawing.Bitmap]::new([int]$r.Width, [int]$r.Height); $g = [Drawing.Graphics]::FromImage($b); try { $g.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $b.Size); $b.Save((Join-Path $directory ($name + '.png')), [Drawing.Imaging.ImageFormat]::Png) } finally { $g.Dispose(); $b.Dispose() } }
function Fixture([string]$name) { $path = Join-Path $directory ($name + '.exe'); Copy-Item "$env:SystemRoot\System32\PING.EXE" $path; $p = Start-Process $path -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru; $r = New-OwnedProcess $p; $owned.Add($r); Save 'owned-fixtures.json' @($owned | ForEach-Object { $_.Identity }); return $r }
function Now { [DateTime]::UtcNow.ToFileTimeUtc() }
function Action([string]$commandLine) { if ($commandLine -match 'Optimizer\.Host(?:\.dll|\.exe)"?\s+(\S+)') { $Matches[1] } else { '<unknown>' } }
function Focus([IntPtr]$target, [string]$what) {
    $requested = Now
    $method = [BackgroundPollingUi]::Focus($target)
    if (-not $method) { throw ('Could not bring the ' + $what + ' window to the foreground') }
    $script:settled = (Now) + 5000000
    $focusLog.Add([ordered]@{ target = $what; requested = $requested; settled = $script:settled; method = $method; appMinimized = [BackgroundPollingUi]::IsIconic($appWindow) }) | Out-Null
    return $requested
}
function Case([string]$name, [long]$from, [long]$to, [int]$minimum, [int]$maximum, [hashtable]$extra = @{}) {
    Start-Sleep -Seconds 2
    $hosts = @($watch.Polled() | Where-Object { $_.Name -in $hostNames })
    $polled = @($hosts | Where-Object { $_.Created -ge $from -and $_.Created -lt $to })
    $traced = @($watch.Traced() | Where-Object { $_.Name -in $hostNames -and $_.Created -ge $from -and $_.Created -lt $to })
    $seenIds = @($hosts | ForEach-Object { $_.Pid })
    $untimed = @($hosts | Where-Object { -not $_.Created -and $_.Seen -ge $from -and $_.Seen -lt $to + 20000000 } | ForEach-Object { $_.Pid })
    $untimed += @($watch.Traced() | Where-Object { $_.Name -in $hostNames -and $_.Pid -notin $seenIds -and $_.Created -ge $from -and $_.Created -lt $to + 20000000 } | ForEach-Object { $_.Pid })
    $other = @($watch.Polled() | Where-Object { $_.Name -notin $hostNames -and $_.Created -ge $from -and $_.Created -lt $to } | ForEach-Object { $_.Name })
    $result = [ordered]@{ case = $name; seconds = [Math]::Round(($to - $from) / 1e7, 2); hostStarts = $polled.Count; expectedMinimum = $minimum; expectedMaximum = $maximum
        tracedHostStarts = $traced.Count; untimedHostStarts = $untimed; actions = @($polled | ForEach-Object { Action $_.CommandLine }); otherChildren = $other; from = $from; to = $to }
    $result.foreground = $script:held
    $result.otherAppProcesses = @(Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $app.Id }).Count
    foreach ($key in $extra.Keys) { $result[$key] = $extra[$key] }
    $result.passed = $polled.Count -ge $minimum -and $polled.Count -le $maximum -and -not $untimed.Count -and $extra.passed -ne $false -and $result.otherAppProcesses -eq 0
    $script:held = @{}
    $cases.Add($result) | Out-Null
    Save 'cases.json' $cases
    Save 'focus.json' $focusLog
}
function Hold([IntPtr]$expected, [double]$seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds); $samples = 0; $away = 0; $appInFront = 0
    while ([DateTime]::UtcNow -lt $deadline) { $front = [BackgroundPollingUi]::GetForegroundWindow(); $samples++; if ($front -ne $expected) { $away++ }; if ($front -eq $appWindow) { $appInFront++ }; Start-Sleep -Milliseconds 100 }
    $script:held = @{ samples = $samples; awayFromExpected = $away; appInFront = $appInFront }
}
function Window([IntPtr]$target, [string]$what, [int]$seconds) { $from = Focus $target $what; Hold $target $seconds; return @($from, (Now)) }
function ActiveBaseline([string]$name) { $span = Window $appWindow 'app' 10; Case $name $span[0] $span[1] 3 8 }
function Inactive([string]$name) { Window $probeWindow 'probe' $InactiveSeconds | Out-Null; Case $name $script:settled (Now) 0 0 @{ appMinimizedDuringWindow = [BackgroundPollingUi]::IsIconic($appWindow); passed = $script:held.appInFront -eq 0 } }
function ReactivateOnce([string]$name) {
    $from = Focus $appWindow 'app'
    Start-Sleep -Milliseconds 1200
    Focus $probeWindow 'probe' | Out-Null
    Start-Sleep -Seconds 5
    Case $name $from (Now) 1 1
}

try {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated interactive session.' }
    $lease = 'C:\RooBuild\host-lease.json'
    if (Test-Path -LiteralPath $lease) { $held = Get-Content -Raw -LiteralPath $lease | ConvertFrom-Json; if ($held.runRoot -and (Test-Path -LiteralPath $held.runRoot)) { throw ('BUSY: the test PC is leased by frame ' + $held.frameId + '; retry later.') } }
    Assert-NoUnownedAppProcess

    $dotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet)) { $dotnet = (Get-Command dotnet.exe -ErrorAction Stop).Source }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_ROOT = Split-Path $dotnet -Parent
    if (-not (@(& $dotnet --list-runtimes) -match '^Microsoft\.WindowsDesktop\.App 8\.')) { throw ('The .NET 8 Desktop Runtime is missing next to ' + $dotnet + '.') }
    & (Join-Path $Source 'backend\scripts\Build-OptimizerHost.ps1') -DotNetPath $dotnet *> (Join-Path $directory 'build-host.log')
    if ($LASTEXITCODE) { throw 'The optimizer helper build failed; see build-host.log.' }
    $appDirectory = Join-Path $Source 'artifacts\background-polling-app'
    & $dotnet publish (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj') -c Release -r win-x64 --self-contained false -p:Platform=x64 -p:WindowsAppSDKSelfContained=true -p:WindowsPackageType=None ("-p:SelfContainedIntermediateOutputPath=" + (Join-Path $directory 'wasdk') + '\') -p:UseSharedCompilation=false -o $appDirectory *> (Join-Path $directory 'build-app.log')
    if ($LASTEXITCODE) { throw 'The app build failed; see build-app.log.' }
    if (Test-Path -LiteralPath (Join-Path $appDirectory 'hostpolicy.dll')) { throw 'The validation app must not run as an installed copy.' }

    $probeExe = Join-Path $directory 'PollingFocusProbe.exe'
    Add-Type -OutputAssembly $probeExe -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms -TypeDefinition 'using System.Windows.Forms; public static class PollingFocusProbe { [System.STAThread] public static void Main(string[] args) { Application.Run(new Form { Text = "Background polling probe", WindowState = FormWindowState.Maximized }); } }'
    $target = if ($Scenario -ne 'games') { Fixture 'PollingFixtureTarget' }
    if ($Scenario -ne 'processes') {
        $launcherReceipt = Fixture 'PollingFixtureLauncher'
        $gamePath = Join-Path $directory 'PollingFixtureGame.exe'
        Copy-Item "$env:SystemRoot\System32\PING.EXE" $gamePath
    }
    $probeProcess = Start-Process $probeExe -PassThru
    $owned.Add((New-OwnedProcess $probeProcess))
    $probeWindow = WaitFor { $probeProcess.Refresh(); if ($probeProcess.MainWindowHandle -ne [IntPtr]::Zero) { $probeProcess.MainWindowHandle } } 30 'probe window'

    $operations = Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'
    $existingOperations = @(if (Test-Path -LiteralPath $operations) { Get-ChildItem -LiteralPath $operations -Directory -Filter 'game-session-*' | ForEach-Object { $_.FullName } })
    $appStart = [DateTime]::UtcNow
    $app = Start-Process (Join-Path $appDirectory 'RooIndustries.OptimizationSuite.App.exe') -PassThru
    $receipt = New-OwnedProcess $app
    Save 'owned-app.json' $receipt.Identity
    $watch = [BackgroundPollingWatch]::new([uint32]$app.Id)
    $window = WaitFor { $A::RootElement.FindFirst($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $app.Id)) } 120 'app window'
    $appWindow = [IntPtr]::new($window.Current.NativeWindowHandle)
    Focus $appWindow 'app' | Out-Null
    if (ById 'UpdateLaterButton') { InvokeId 'UpdateLaterButton' }
    WaitFor { @(Texts) -contains 'Start here' } 90 'Home' | Out-Null
    Nav 'Games'

    if ($Scenario -ne 'processes') {
        InvokeId 'GamesTab'; InvokeId 'GameSessionNew'
        Start-Sleep -Seconds 2
        if ((ById 'GameSessionDetail').Current.Name -like 'Stop or recover the existing session*') { throw 'BUSY: another game session is still open on this PC; retry after it stops.' }
        SetValue 'GameSessionExecutable' $gamePath
        ChooseId 'GameSessionLauncher' ('*PollingFixtureLauncher*PID ' + $launcherReceipt.Identity.pid)
        Toggle 'GameSessionScope'
        InvokeId 'GameSessionPreview'
        WaitFor { (ById 'GameSessionStart').Current.IsEnabled } 60 'session review' | Out-Null
        InvokeId 'GameSessionStart'
        WaitFor { (ById 'GameSessionStatus').Current.Name -like 'Ready*' } 90 'armed session' | Out-Null
        $sessionRoot = WaitFor { @(Get-ChildItem -LiteralPath $operations -Directory -Filter 'game-session-*' | Where-Object { $_.FullName -notin $existingOperations -and (Test-Path -LiteralPath (Join-Path $_.FullName 'session\session.json')) } | ForEach-Object { Join-Path $_.FullName 'session' }) | Select-Object -First 1 } 30 'session folder'
        Shot 'games-armed'

        ActiveBaseline 'games-active-baseline'
        Inactive 'games-inactive'
        ReactivateOnce 'games-reactivated-once'

        $inFlight = $null
        for ($try = 0; $try -lt 5 -and -not $inFlight; $try++) {
            $mark = Focus $appWindow 'app'
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $running = @($watch.Polled() | Where-Object { $_.Name -in $hostNames -and $_.Created -ge $mark -and $watch.Running($_.Pid) }) | Select-Object -First 1
                if ($running) {
                    Focus $probeWindow 'probe' | Out-Null
                    if ($watch.Running($running.Pid)) { $inFlight = [ordered]@{ action = Action $running.CommandLine; created = $running.Created; deactivated = $script:settled; runningAfterDeactivation = $true } }
                    break
                }
                Start-Sleep -Milliseconds 5
            }
            if (-not $inFlight) { Focus $probeWindow 'probe' | Out-Null; Start-Sleep -Seconds 3 }
        }
        if (-not $inFlight) { throw 'No status read was caught in flight at deactivation.' }
        Hold $probeWindow 10
        Case 'games-read-in-flight-at-deactivation' $inFlight.deactivated (Now) 0 0 @{ inFlight = $inFlight; passed = $script:held.appInFront -eq 0 }

        $from = Now
        for ($i = 0; $i -lt 10; $i++) { Focus $appWindow 'app' | Out-Null; Start-Sleep -Milliseconds 300; Focus $probeWindow 'probe' | Out-Null; Start-Sleep -Milliseconds 300 }
        Start-Sleep -Seconds 6
        Case 'games-quick-toggles' $from (Now) 1 4

        Focus $appWindow 'app' | Out-Null
        [BackgroundPollingUi]::ShowWindow($appWindow, 6) | Out-Null
        WaitFor { [BackgroundPollingUi]::IsIconic($appWindow) } 10 'minimized app' | Out-Null
        $from = Now; Hold $probeWindow 20
        Case 'games-minimized' $from (Now) 0 0 @{ passed = $script:held.appInFront -eq 0 -and [BackgroundPollingUi]::IsIconic($appWindow) }
        $from = Now
        [BackgroundPollingUi]::ShowWindow($appWindow, 9) | Out-Null
        Focus $appWindow 'app' | Out-Null; Start-Sleep -Seconds 3
        Case 'games-restored' $from (Now) 1 3

        Focus $probeWindow 'probe' | Out-Null
        $from = $script:settled
        Stop-OwnedProcess $launcherReceipt
        WaitFor { -not @(Get-Process RooIndustries.SessionHost -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Source, [StringComparison]::OrdinalIgnoreCase) }).Count } 30 'session host exit' | Out-Null
        $ended = Get-Content -Raw -LiteralPath (Join-Path $sessionRoot 'session.json') | ConvertFrom-Json
        Start-Sleep -Seconds 5
        $beforeReturn = (ById 'GameSessionStatus').Current.Name
        $expected = if ($ended.status -in 'stopped', 'stoppedWithErrors') { 'Stopped*' } else { 'Recovery required*' }
        $returned = Focus $appWindow 'app'
        $shown = $null
        try { $shown = WaitFor { $text = (ById 'GameSessionStatus').Current.Name; if ($text -like $expected) { $text } } 3 'ended session shown after return' } catch {}
        Shot 'games-ended-after-return'
        Case 'games-session-ended-while-inactive' $from $returned 0 0 @{ sessionStatus = $ended.status; statusBeforeReturn = $beforeReturn; statusAfterReturn = $shown; expectedAfterReturn = $expected; passed = [bool]$shown }
    }

    if ($Scenario -ne 'games') {
        Focus $appWindow 'app' | Out-Null
        InvokeId 'ProcessesTab'
        WaitFor { ById 'ProcessPicker' } 90 'process panel' | Out-Null
        ChooseId 'ProcessPicker' ('*PollingFixtureTarget*PID ' + $target.Identity.pid)
        WaitFor { $c = ById 'cpuPriority'; $c -and $c.Current.IsEnabled } 60 'process rows' | Out-Null
        Shot 'processes-selected'
        ActiveBaseline 'processes-active-baseline'
        Inactive 'processes-inactive'
        ReactivateOnce 'processes-reactivated-once'
    }
} catch {
    Save 'failure.json' @{ error = $_.Exception.Message; stack = $_.ScriptStackTrace }
    if ($window) { try { Shot 'failure' } catch {} }
    throw
} finally {
    if ($app) { Stop-OwnedValidationApp $app $receipt }
    if ($watch) { Save 'children.json' ([ordered]@{ polled = @($watch.Polled() | ForEach-Object { [ordered]@{ pid = $_.Pid; name = $_.Name; created = $_.Created; seen = $_.Seen; action = Action $_.CommandLine } }); traced = @($watch.Traced() | ForEach-Object { [ordered]@{ pid = $_.Pid; name = $_.Name; created = $_.Created } }) }); $watch.Dispose() }
    if ($app -and $gamePath) {
        $sessionCleanup = [Collections.Generic.List[object]]::new()
        foreach ($operation in @(Get-ChildItem -LiteralPath $operations -Directory -Filter 'game-session-*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $existingOperations })) {
            $preview = Join-Path $operation.FullName 'preview.json'
            if (-not (Test-Path -LiteralPath $preview) -or (Get-Content -Raw -LiteralPath $preview | ConvertFrom-Json).gamePath -ine $gamePath) { continue }
            $stopExit = 0; $stop = @()
            if (Test-Path -LiteralPath (Join-Path $operation.FullName 'session')) {
                $stop = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Source 'backend\scripts\Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot (Join-Path $operation.FullName 'session') -ConfirmApply 2>&1 | ForEach-Object { [string]$_ })
                $stopExit = $LASTEXITCODE
            }
            if (-not $stopExit) { Remove-Item -LiteralPath $operation.FullName -Recurse -Force }
            $sessionCleanup.Add([ordered]@{ operation = $operation.Name; stopExit = $stopExit; stopOutput = $stop; removed = -not (Test-Path -LiteralPath $operation.FullName) }) | Out-Null
        }
        Save 'session-cleanup.json' $sessionCleanup
    }
    foreach ($r in $owned) { Stop-OwnedProcess $r }
    Save 'cases.json' $cases
    Save 'focus.json' $focusLog
}
$failed = @($cases | Where-Object { -not $_.passed })
$cases | ForEach-Object { Write-Output (('{0}: {1} host starts in {2}s (expected {3}-{4}) {5}' -f $_.case, $_.hostStarts, $_.seconds, $_.expectedMinimum, $_.expectedMaximum, $(if ($_.passed) { 'PASS' } else { 'FAIL' }))) }
if ($failed.Count) { Write-Output ('FAIL ' + $failed.Count + ' background polling case(s)'); exit 1 }
Write-Output 'ROO_INDUSTRIES_BACKGROUND_POLLING_PASS'
