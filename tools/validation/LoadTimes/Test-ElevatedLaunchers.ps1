param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe',
    [ValidateSet('both', 'governor', 'session')][string]$Part = 'both'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class LauncherCheckU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class LauncherCheckPriority {
 [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessInformation(IntPtr h, int kind, out uint value, uint size);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, out int value, int size, IntPtr returned);
 public static int Memory(int pid) {
  IntPtr h = OpenProcess(0x0400, false, pid);
  if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
  try { uint v; if (!GetProcessInformation(h, 0, out v, 4)) throw new System.ComponentModel.Win32Exception(); return (int)v; } finally { CloseHandle(h); }
 }
 public static int Io(int pid) {
  IntPtr h = OpenProcess(0x0400, false, pid);
  if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
  try { int v; int status = NtQueryInformationProcess(h, 33, out v, 4, IntPtr.Zero); if (status != 0) throw new InvalidOperationException("NTSTATUS " + status); return v; } finally { CloseHandle(h); }
 }
}
'@
[LauncherCheckU32]::SetProcessDPIAware() | Out-Null
[LauncherCheckU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$Tag = if ($Part -eq 'both') { 'launchers' } else { 'launchers-' + $Part }
$script:LogPath = Join-Path $OutDir ($Tag + '.log')
$script:Failures = 0
$script:App = $null
$install = Split-Path (Split-Path $Exe -Parent) -Parent
$scripts = Join-Path $install 'backend\scripts'
$hostExe = Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$sessionExe = Join-Path $install 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe'
$system = [Environment]::GetFolderPath('System')
$clearNames = @('DOTNET_STARTUP_HOOKS', 'DOTNET_ADDITIONAL_DEPS', 'DOTNET_SHARED_STORE', 'CORECLR_ENABLE_PROFILING', 'CORECLR_PROFILER', 'CORECLR_PROFILER_PATH', 'CORECLR_PROFILER_PATH_32', 'CORECLR_PROFILER_PATH_64', 'CORECLR_PROFILER_PATH_ARM64', 'COR_ENABLE_PROFILING', 'COR_PROFILER', 'COR_PROFILER_PATH', 'COR_PROFILER_PATH_32', 'COR_PROFILER_PATH_64')
$ruleName = 'roo-industries-launcher-check rule ' + [Guid]::NewGuid().ToString('N')
$probeName = 'RooIndustriesLauncherProbe'
$probePath = Join-Path $env:TEMP ($probeName + '.exe')
$sessionLauncherPath = Join-Path $env:TEMP 'RooIndustriesProtectedLauncherProbe.exe'
$sessionGamePath = Join-Path $env:TEMP 'RooIndustriesProtectedGameProbe.exe'
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProtectedGameProbe.exe'

function Log([string]$m) { [IO.File]::AppendAllText($script:LogPath, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m + "`r`n") }
function Check([bool]$ok, [string]$name, [string]$detail) { if (-not $ok) { $script:Failures++ }; Log ($(if ($ok) { 'PASS ' } else { 'FAIL ' }) + $name + ' :: ' + $detail) }
. (Join-Path $PSScriptRoot 'LauncherChecks.Common.ps1')
. (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
$script:AppReceipt = $null
$probeFile = $null
$sessionLauncherFile = $null
$sessionGameFile = $null
$probeReceipt = $null
$secondReceipt = $null
$sessionLauncherReceipt = $null
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
function Invoke-Element($e) {
    try { $e.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); return } catch {}
    try { $e.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select(); return } catch {}
    $e.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
}
function Nav([string]$name) {
    $item = WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty, $name), [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))) } 30 "nav $name"
    Invoke-Element $item; Log "nav $name"
}
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
function Start-RooIndustriesApp {
    Stop-RooIndustriesApp
    $script:App = Start-Process $Exe -PassThru
    $script:AppReceipt = New-OwnedProcess $script:App
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [LauncherCheckU32]::ShowWindow($h, 9) | Out-Null; [LauncherCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [LauncherCheckU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}
function Stop-RooIndustriesApp {
    $children=@(Child-Rows $script:App)
    $held=@()
    $waitRows=[Collections.Generic.List[object]]::new()
    try {
        foreach ($child in $children | Where-Object { $_.ParentProcessId -eq $script:App.Id }) {
            $process=Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
            if (-not $process) { continue }
            try {
                $receipt=New-OwnedProcess $process
                if (-not $receipt) { $process.Dispose(); continue }
                $current=Process-Row $child.ProcessId
                if (-not $current) { $process.Dispose(); continue }
                if ($current.CreationDate -ne $child.CreationDate -or $current.ExecutablePath -ine $child.ExecutablePath -or $current.CommandLine -cne $child.CommandLine -or $current.ParentProcessId -ne $child.ParentProcessId -or $receipt.Identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($child.ExecutablePath)) { throw 'App child identity changed; retained.' }
                $record=[ordered]@{identity=$receipt.Identity;parent=$child.ParentProcessId;parentIdentity=$script:AppReceipt.Identity;commandLine=$child.CommandLine;capturedUtc=[DateTime]::UtcNow.ToString('o');closeRequestedUtc=$null;exited=$null;exitUtc=$null;observedUtc=$null;waitBudgetSeconds=60}
                $waitRows.Add($record)
                $held+=@{process=$process;identity=$receipt.Identity;row=$child;record=$record}
            } catch { $process.Dispose(); throw }
        }
        $closeRequestedUtc=[DateTime]::UtcNow.ToString('o')
        foreach($child in $held){$child.record.closeRequestedUtc=$closeRequestedUtc}
        if ($script:App -and -not $script:App.HasExited) { $script:App.CloseMainWindow() | Out-Null; if (-not $script:App.WaitForExit(20000)) { Stop-OwnedProcess $script:AppReceipt } }
        $waitClock=[Diagnostics.Stopwatch]::StartNew()
        foreach ($child in $held) {
            $remaining=[Math]::Max(0,60000-[int]$waitClock.ElapsedMilliseconds)
            $exited=$child.process.WaitForExit($remaining)
            $child.record.exited=$exited
            $child.record.observedUtc=[DateTime]::UtcNow.ToString('o')
            if($exited){$child.record.exitUtc=$child.process.ExitTime.ToUniversalTime().ToString('o')}
            if (-not $exited) { Log ('CLEANUP NEEDED: retained app child after bounded wait: '+($child.identity|ConvertTo-Json -Compress)) }
        }
        foreach ($child in $children | Where-Object { $_.ProcessId -notin @($held | ForEach-Object { $_.identity.pid }) }) { $current = Process-Row $child.ProcessId; if ($current -and $current.CreationDate -eq $child.CreationDate) { Log ('CLEANUP NEEDED: retained app child for its lifecycle owner: ' + $child.ProcessId) } }
    } finally {
        foreach ($child in $held) { $child.process.Dispose() }
        if ($waitRows.Count) { $waitRows.ToArray() | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir ('app-child-wait-'+[Guid]::NewGuid().ToString('N')+'.json')) -Encoding UTF8 }
    }
    if (@(Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue).Count) { throw 'CLEANUP NEEDED: another app process remains; retained without an ownership receipt.' }
    Start-Sleep 1
}
function Data-Root {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    $current = Join-Path $local 'RooIndustriesOptimizationSuite'; $legacy = Join-Path $local ('RooIndustriesOptimizationSuite' -replace 'Industries','')
    if ((Test-Path -LiteralPath $legacy -PathType Container) -and -not ($markers -and $null -ne $markers.GetValue($current.ToUpperInvariant()) -and $null -eq $markers.GetValue($legacy.ToUpperInvariant()))) { $legacy } else { $current }
}
$plantName = 'DOTNET_STARTUP_HOOKS'
$plantValue = 'C:\RooIndustriesNoSuchFolder\hook.dll'
$script:Planted = $false
$script:EnvironmentInherited = $false
function Plant-Name {
    if ($script:EnvironmentConflict) { throw 'A concurrent environment write was retained; refusing another plant.' }
    if (-not $script:plantRegistry) { $script:plantRegistry = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true) }
    if (-not $script:plantRegistry) { throw 'User environment key is missing; refusing to create it.' }
    $script:PlantReceipt = Set-OwnedRegistryField $script:plantRegistry $plantName $plantValue 'String'
    $script:Planted = $true
    Log ('planted ' + $plantName + ' with an exact typed original field receipt, without a broadcast')
}
function Unplant-Name {
    if (-not $script:Planted) { return }
    try { Restore-OwnedRegistryField $script:PlantReceipt; Log ('restored original ' + $plantName + ' field') }
    catch { $script:EnvironmentConflict = $true; Log ('CLEANUP NEEDED: environment field retained: ' + $_.Exception.Message) }
    $script:Planted = $false
}
function Test-Inheritance(
    [string]$controlPath = (Join-Path $env:TEMP 'RooIndustriesEnvironmentControl.exe'),
    [string]$controlTask = 'RooIndustries_EnvironmentControl',
    [string]$controlUserId = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value),
    [int]$controlLogonType = 3
) {
    if((Test-Path -LiteralPath $controlPath) -or (Get-ScheduledTask -TaskName $controlTask -ErrorAction SilentlyContinue)){throw 'A previous environment control exists; it must be recovered before this scenario.'}
    $controlFile = Copy-OwnedProbe (Join-Path $system 'PING.EXE') $controlPath
    $controlReceipt = $null
    $controlTaskReceipt = $null
    $process = $null
    try {
        $controlTaskReceipt = Register-OwnedProbeTask $controlTask (Join-Path $system 'conhost.exe') ('--headless "' + $controlPath + '" -n 60 127.0.0.1') $env:TEMP $controlUserId 5 $controlLogonType
        $controlStarted = [DateTime]::UtcNow
        Start-ScheduledTask -TaskName $controlTask
        $row = WaitFor { @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -ieq $controlPath -and $_.CreationDate.ToUniversalTime() -ge $controlStarted })[0] } 30 'the launcher-less control process'
        $process = Get-Process -Id $row.ProcessId -ErrorAction Stop
        $controlReceipt = New-OwnedProcess $process
        $names = @(Env-Names ([LauncherCheckEnv]::Read([int]$row.ProcessId)))
        ($names | Sort-Object) | Set-Content -LiteralPath (Join-Path $OutDir 'environment-names-control.txt') -Encoding UTF8
        $inherited = $names -contains $plantName
        Check $inherited ('control: a task that starts a program directly, with no launcher, inherits the planted ' + $plantName + ' from the user environment') ('names read=' + $names.Count + ' planted name present=' + $inherited)
        $script:EnvironmentInherited = $inherited
    }
    finally {
        try { Remove-OwnedTask $controlTaskReceipt } catch { Log ('CLEANUP NEEDED: control task retained: ' + $_.Exception.Message) }
        try { Stop-OwnedProcess $controlReceipt } catch { Log ('CLEANUP NEEDED: control process retained: ' + $_.Exception.Message) }
        try { Remove-OwnedProbe $controlFile } catch { Log ('CLEANUP NEEDED: control file retained: ' + $_.Exception.Message) }
        $controlFile.Dispose()
    }
}
function Check-Environment([string]$label, $worker) {
    $prefixes = @(Product-ClearedNames)
    $workerEnvironment = @(); $workerNames = @(); $err = $null
    try { $workerEnvironment = @([LauncherCheckEnv]::Read([int]$worker.ProcessId)); $workerNames = @(Env-Names $workerEnvironment) } catch { $err = $_.Exception.Message }
    $present = @(foreach ($entry in $workerEnvironment) {
        $index=([string]$entry).IndexOf('=',1)
        if ($index -le 0) { continue }
        $name=([string]$entry).Substring(0,$index); $value=([string]$entry).Substring($index+1)
        if (@($prefixes | Where-Object { $name.StartsWith($_,[StringComparison]::OrdinalIgnoreCase) }).Count -and -not ($name -match '^(DOTNET_|COMPlus_)EnableDiagnostics(_(IPC|Debugger|Profiler))?$' -and $value -ceq '0')) { $name }
    })
    ($workerNames | Sort-Object) | Set-Content -LiteralPath (Join-Path $OutDir ('environment-names-' + ($label -replace '\W', '-') + '.txt')) -Encoding UTF8
    Check ($prefixes.Count -gt 0 -and $script:EnvironmentInherited -and -not $err -and $workerNames.Count -gt 0 -and $present.Count -eq 0) "$label worker's own process environment contains none of the variables matching the $($prefixes.Count) cleared prefixes except pinned diagnostics switches set to 0, although $plantName was set in the user environment and a launcher-less task inherits it" ("names read=" + $(if ($err) { $err } else { $workerNames.Count }) + " present=" + ($present -join ',') + " planted name reached the launcher-less control=" + $script:EnvironmentInherited)
}
function Probe-Priority($id) { try { [string](Get-Process -Id $id -ErrorAction Stop).PriorityClass } catch { '<gone>' } }
function Policy-Tasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '*OptimizationSuite.ProcessRules.*' }) }
function Policy-Workers([string]$requestPath) { if (-not $requestPath) { return @() }; @(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'policy-run' -and $_.CommandLine.IndexOf($requestPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.ExecutablePath -ieq $hostExe }) }
function Run-Script([string]$name, [string[]]$arguments) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $text = @(& (Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $scripts $name) @arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ exit = $code; text = ($text -join "`n") }
}
function Parse-Json([string]$text) { $start = $text.IndexOf('{'); $end = $text.LastIndexOf('}'); if ($start -ge 0 -and $end -gt $start) { $text.Substring($start, $end - $start + 1) | ConvertFrom-Json } }

$probe = $null; $probeId = $null; $second = $null; $secondId = $null; $sessionLauncher = $null
$requestPath = $null
$script:RuleSaved = $false
$script:SessionRoot = $null
$script:SessionTask = $null
$script:SessionTaskReceipt = $null
$script:SessionStopped = $false
$script:SessionIfeoBefore = $null
$script:SessionIfeoAfter = $null
$script:PreviewDir = $null
$script:StartedSessionDir = $null
$ifeoBefore = Test-Path -LiteralPath $ifeo
try {
    $cleared = @(Product-ClearedNames)
    $missingNames = @($clearNames | Where-Object { $name=$_; -not @($cleared | Where-Object { $name.StartsWith($_,[StringComparison]::OrdinalIgnoreCase) }).Count })
    Check ($cleared.Count -gt 0 -and $missingNames.Count -eq 0) 'the installed launcher clears every code-loading variable by prefixes matching RuntimeEnvironment.ClearPrefixes and covering every planted name' ("installed prefixes: " + ($cleared -join ',') + "; uncovered: " + ($missingNames -join ','))
    $control = [Diagnostics.ProcessStartInfo]::new((Join-Path $system 'PING.EXE'), '-n 20 127.0.0.1'); $control.UseShellExecute = $false; $control.CreateNoWindow = $true
    $control.EnvironmentVariables['DOTNET_STARTUP_HOOKS'] = 'C:\RooIndustriesNoSuchFolder\hook.dll'
    $controlProcess = [Diagnostics.Process]::Start($control)
    $directControlReceipt = New-OwnedProcess $controlProcess
    try { $controlEnv = @([LauncherCheckEnv]::Read($controlProcess.Id)) } finally { Stop-OwnedProcess $directControlReceipt; $controlProcess.Dispose() }
    Check (@($controlEnv | Where-Object { $_ -like 'DOTNET_STARTUP_HOOKS=*' }).Count -eq 1) 'control: the environment reader sees DOTNET_STARTUP_HOOKS in a process that was started with it' ("variables read=" + $controlEnv.Count)
}
catch { $script:Failures++; Log ('FATAL list check ' + ($_ | Out-String)) }

if ($Part -in 'both', 'governor') {
    try {
        $rulesBefore = @(Policy-Tasks)
        if ($rulesBefore.Count) { throw "A governor task already exists on this PC ($($rulesBefore[0].TaskName)); refusing to add a test rule." }
        $probeFile = Copy-OwnedProbe (Join-Path $system 'PING.EXE') $probePath
        $probe = Start-Process $probePath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
        $probeReceipt = New-OwnedProcess $probe
        $probeId = $probe.Id
        (Get-Process -Id $probeId).PriorityClass = 'Normal'
        Check ((Probe-Priority $probeId) -eq 'Normal') 'the probe starts at normal priority (a process started by a scheduled task inherits below normal, so it is set explicitly)' ('priority=' + (Probe-Priority $probeId))
        Start-Sleep 3
        Start-RooIndustriesApp
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        Invoke-Element (WaitFor { ById 'ProcessRefresh' } 20 'process refresh'); Start-Sleep 2
        Pick 'ProcessPicker' ('*' + $probeName + '*')
        Process-Status '^Controls for' 60 'probe controls' | Out-Null
        Pick 'cpuPriority' 'Below normal'
        Invoke-Element (WaitFor { $b = ById 'ProcessPreview'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'review button')
        Process-Status '^Review the requested controls' 60 'process review' | Out-Null
        try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        (WaitFor { ById 'ProcessRuleName' } 10 'rule name').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($ruleName); Start-Sleep 1
        $script:RuleSaved = $true
        $requestPath = Join-Path (Data-Root) 'process-rules\worker-request.json'
        Plant-Name
        Test-Inheritance
        Invoke-Element (WaitFor { $b = ById 'ProcessSaveRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'save rule button')
        $saved = Process-Status '^(Rule saved and (on|enabled)\.|Rule saved\. The governor is paused|Saved rules need attention)' 180 'rule save'
        Check ($saved -match '^Rule saved') 'the governor rule was saved through the app' ($saved + ' :: ' + (ById 'ProcessDetail').Current.Name)
        Shot 'rule-saved'

        $tasks = @(Policy-Tasks)
        Check ($tasks.Count -ge 1) 'at least one governor task exists after saving a rule' ("tasks=$($tasks.Count): " + (($tasks | ForEach-Object { $_.TaskName }) -join ', '))
        foreach ($task in $tasks) {
            $xmlText = Task-Xml $task.TaskName $task.TaskPath
            Set-Content -LiteralPath (Join-Path $OutDir ('task-' + $task.TaskName + '.xml')) -Value $xmlText -Encoding UTF8
            $registeredArguments = ([xml]$xmlText).Task.Actions.Exec.Arguments
            Check-TaskLauncher ('governor task ' + $task.TaskName) $xmlText $hostExe @('policy-run', $requestPath) (Split-Path $hostExe -Parent)
        }
        $worker = $null; try { $worker = WaitFor { @(Policy-Workers $requestPath)[0] } 90 'the governor worker' } catch {}
        $taskInfo = @($tasks | ForEach-Object { $i = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath; $_.TaskName + ' state=' + $_.State + ' lastResult=0x{0:X} lastRun=' -f $i.LastTaskResult + $i.LastRunTime }) -join '; '
        Check ($null -ne $worker) 'the governor worker is running after the rule was saved' ($(if ($worker) { 'pid=' + $worker.ProcessId } else { 'no Optimizer.Host.exe policy-run process; ' + $taskInfo }))
        Check ($null -ne $worker -and $worker.ExecutablePath -ieq $hostExe -and $hostExe.StartsWith($env:ProgramFiles + '\', [StringComparison]::OrdinalIgnoreCase)) 'the governor worker image is the installed Optimizer.Host.exe under C:\Program Files' ($(if ($worker) { $worker.ExecutablePath } else { 'no worker' }))
    if ($worker) { Check-Chain 'governor' $worker $registeredArguments; Check-Environment 'governor' $worker }
        Unplant-Name
        if ($worker) {
            $enforced = $null; try { $enforced = WaitFor { if ((Probe-Priority $probeId) -eq 'BelowNormal') { $true } } 90 'rule enforced' } catch {}
            Check ([bool]$enforced) 'the governor enforces the saved rule on the probe' ('priority=' + (Probe-Priority $probeId))

            Stop-RooIndustriesApp
            $still = @(Policy-Workers $requestPath)
            Check ($worker -and $still.Count -ge 1 -and $still[0].ProcessId -eq $worker.ProcessId) 'with the app closed the same governor worker is still running' ("pid before=$(if ($worker) { $worker.ProcessId }) after=" + (($still | ForEach-Object { $_.ProcessId }) -join ','))
            $second = Start-Process $probePath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
            $secondReceipt = New-OwnedProcess $second
        $secondId = $second.Id
            (Get-Process -Id $secondId).PriorityClass = 'Normal'
            $startedAt = Probe-Priority $secondId
            $later = $null; try { $later = WaitFor { if ((Probe-Priority $secondId) -eq 'BelowNormal') { $true } } 150 'rule applied to a later process' } catch {}
            Check ($startedAt -eq 'Normal' -and [bool]$later) 'with the app closed the governor applies the saved rule to a matching process that starts later' ("started at $startedAt, now " + (Probe-Priority $secondId))
        }
        else {
            Check $false 'the governor enforces the saved rule on the probe' 'not tested: the governor worker is not running'
            Check $false 'with the app closed the governor keeps enforcing the saved rule' 'not tested: the governor worker is not running'
            Stop-RooIndustriesApp
        }
        Start-RooIndustriesApp
        Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
        try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
        Pick 'ProcessRulesList' ($ruleName + '*')
        Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule button')
        $deleted = Process-Status '^(Rule deleted|Couldn.t update the rule)' 180 'rule delete'
        Check ($deleted -match '^Rule deleted') 'the governor rule was deleted through the app' ($deleted + ' :: ' + (ById 'ProcessDetail').Current.Name)
        if ($deleted -match '^Rule deleted') { $script:RuleSaved = $false }
        $gone = $null; try { $gone = WaitFor { if ((Policy-Tasks).Count -eq 0 -and (Policy-Workers $requestPath).Count -eq 0) { $true } } 60 'governor removal' } catch {}
        Check ([bool]$gone) 'deleting the last rule removes the governor task and ends the worker' ("tasks=" + (Policy-Tasks).Count + " workers=" + (Policy-Workers $requestPath).Count)
        $released = $null; if ($secondId) { try { $released = WaitFor { if ((Probe-Priority $secondId) -eq 'Normal') { $true } } 60 'priority released' } catch {} }
        Check ([bool]$released) 'deleting the rule gives the process it was applied to its normal priority back' ('priority=' + $(if ($secondId) { Probe-Priority $secondId } else { '<no process>' }))
        Shot 'rule-deleted'
    }
    catch { $script:Failures++; Log ('FATAL governor part ' + ($_ | Out-String)); try { Shot 'fatal-governor' } catch {} }
    finally {
        if ($script:RuleSaved) {
            try {
                if (-not $script:App -or $script:App.HasExited) { Start-RooIndustriesApp }
                Nav 'Games'; Start-Sleep 1; Select-Tab 'ProcessesTab'
                try { (WaitFor { ById 'ProcessSavedRules' } 10 'saved rules').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() } catch {}; Start-Sleep 1
                Pick 'ProcessRulesList' ($ruleName + '*')
                Invoke-Element (WaitFor { $b = ById 'ProcessDeleteRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'delete rule button')
                if ((Process-Status '^(Rule deleted|Couldn.t update the rule)' 180 'rule delete') -match '^Rule deleted') { $script:RuleSaved = $false; Log 'cleanup: deleted the governor test rule through the app' }
            } catch { Log ('cleanup: could not delete the governor test rule: ' + $_.Exception.Message) }
        }
        try { Stop-RooIndustriesApp } catch { Log ('CLEANUP NEEDED: app cleanup retained resources: ' + $_.Exception.Message) }
        Unplant-Name
        foreach ($owned in @($probeReceipt, $secondReceipt)) { try { Stop-OwnedProcess $owned } catch { Log ('CLEANUP NEEDED: probe retained: ' + $_.Exception.Message) } }
        if ($script:RuleSaved) {
            Log 'CLEANUP NEEDED: governor tasks and workers retained for their saved-rule owner; no fallback ownership receipt exists.'
            Log ('CLEANUP NEEDED: the rule ' + $ruleName + ' may still be saved; delete it in Games > Processes')
        }
        try { Remove-OwnedProbe $probeFile } catch { Log ('CLEANUP NEEDED: probe file retained: ' + $_.Exception.Message) }
        if ($probeFile) { $probeFile.Dispose() }
    }
}
function Get-LauncherIfeoFields {
    $key = Get-Item -LiteralPath (Join-Path $ifeo 'PerfOptions') -ErrorAction SilentlyContinue
    $fields = [ordered]@{}
    try { foreach ($name in 'CpuPriorityClass','IoPriority','PagePriority') { $fields[$name] = if ($key) { Get-OwnedRegistryField $key $name } else { 'absent' } } }
    finally { if ($key) { $key.Dispose() } }
    $fields
}
function Invoke-LauncherSessionCleanup([string]$Root, [string]$Action) {
    if ($Root -ine $script:ExpectedSessionRoot) { throw 'CLEANUP NEEDED: unexpected session root; retained' }
    Assert-OwnedTaskUnchanged $script:SessionTaskReceipt
    if (-not $script:SessionIfeoBefore -or -not $script:SessionIfeoAfter) { throw 'CLEANUP NEEDED: session registry ownership is missing; retained' }
    $fields = Get-LauncherIfeoFields
    foreach ($name in 'CpuPriorityClass','IoPriority','PagePriority') { if ($fields[$name] -cne $script:SessionIfeoAfter[$name] -and $fields[$name] -cne $script:SessionIfeoBefore[$name]) { throw ('CLEANUP NEEDED: session registry field changed; retained ' + $name) } }
    Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', $Action, '-SessionRoot', $Root, '-ConfirmApply')
}
function Launcher-State([int]$id) { [ordered]@{ affinity = '0x{0:X}' -f [int64](Get-Process -Id $id -ErrorAction Stop).ProcessorAffinity; memory = [LauncherCheckPriority]::Memory($id); io = [LauncherCheckPriority]::Io($id) } }
function Session-Workers([string]$sessionRoot) { if (-not $sessionRoot) { return @() }; @(Get-CimInstance Win32_Process -Filter "Name='RooIndustries.SessionHost.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -ieq $sessionExe -and $_.CommandLine.IndexOf($sessionRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
if ($Part -in 'both', 'session') {
    $script:ExpectedSessionRoot = $null
    try {
        if ($ifeoBefore) { throw 'The protected-session probe image key already exists; refusing to overwrite it.' }
        $script:SessionIfeoBefore = Get-LauncherIfeoFields
        $sessionLauncherFile = Copy-OwnedProbe (Join-Path $system 'PING.EXE') $sessionLauncherPath
        $sessionGameFile = Copy-OwnedProbe (Join-Path $system 'PING.EXE') $sessionGamePath
        $sessionLauncher = Start-Process $sessionLauncherPath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
        $sessionLauncherReceipt = New-OwnedProcess $sessionLauncher
        Start-Sleep 2
        $baseline = Launcher-State $sessionLauncher.Id
        $baselinePriority = Probe-Priority $sessionLauncher.Id
        $baselineMask = [int64]::Parse($baseline.affinity.Substring(2), [Globalization.NumberStyles]::HexNumber)
        $wantedMask = $baselineMask -band (-$baselineMask)
        $wanted = [ordered]@{ affinity = '0x{0:X}' -f $wantedMask; memory = $(if ($baseline.memory -eq 3) { 4 } else { 3 }); io = $(if ($baseline.io -eq 1) { 2 } else { 1 }) }
        Check ($baselineMask -ne $wantedMask -and $wanted.memory -ne $baseline.memory -and $wanted.io -ne $baseline.io) 'the session will change the launcher probe from values it really has now (a different affinity, memory priority and I/O priority are requested)' ("launcher now: " + ($baseline | ConvertTo-Json -Compress) + " requested: " + ($wanted | ConvertTo-Json -Compress))
        $script:PreviewDir = Join-Path (Data-Root) ('operations\game-session-roo-industries-launcher-check-' + [Guid]::NewGuid().ToString('N'))
        if (Test-Path -LiteralPath $script:PreviewDir) { throw 'Session preview folder already exists; retained.' }
        New-Item -ItemType Directory -Path $script:PreviewDir | Out-Null
        $controls = Join-Path $script:PreviewDir 'controls.json'
        $controlBytes = [Text.Encoding]::ASCII.GetBytes((@{ cpuPriority = 'AboveNormal'; ioPriority = $wanted.io; memoryPriority = $wanted.memory; affinity = @{ group = 0; mask = $wanted.affinity } } | ConvertTo-Json -Compress))
        $controlFile = [IO.File]::Open($controls, 'CreateNew', 'Write', 'Read')
        try { $controlFile.Write($controlBytes, 0, $controlBytes.Length) } finally { $controlFile.Dispose() }
        $previewPath = Join-Path $script:PreviewDir 'preview.json'
        $preview = Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', 'Preview', '-LauncherProcessId', [string]$sessionLauncher.Id, '-GamePath', $sessionGamePath, '-ControlsPath', $controls, '-PreviewPath', $previewPath, '-AcceptLauncherScope')
        $previewData = Parse-Json $preview.text
        Check ($preview.exit -eq 0 -and $previewData.status -eq 'completed' -and $previewData.data.reviewHash) 'a protected-session preview is created with a harmless probe as the launcher' ("exit=$($preview.exit) " + $preview.text.Substring(0, [Math]::Min(300, $preview.text.Length)))
        if ($previewData.data.preview.operationId) { $script:ExpectedSessionRoot = Join-Path (Join-Path (Data-Root) 'operations') ('game-session-' + $previewData.data.preview.operationId + '\session') }
        Plant-Name
        $script:EnvironmentInherited = $false
        Test-Inheritance
        if (-not $script:ExpectedSessionRoot) { throw 'Preview returned no expected session identity; refusing start.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:ExpectedSessionRoot.ToLowerInvariant())))).Replace('-', '').Substring(0, 16) } finally { $sha.Dispose() }
        $expectedTaskName = 'Roo Industries Protected Session ' + $suffix
        Assert-OwnedTaskAbsent $expectedTaskName
        Assert-OwnedTaskAbsent ('Roo Protected Session ' + $suffix)
        $fields = Get-LauncherIfeoFields
        foreach ($name in 'CpuPriorityClass','IoPriority','PagePriority') { if ($fields[$name] -cne $script:SessionIfeoBefore[$name]) { throw ('Session registry changed before start; retained ' + $name) } }
        $script:SessionIfeoAfter = [ordered]@{}
        foreach ($entry in @(@('CpuPriorityClass',6),@('IoPriority',[int]$wanted.io),@('PagePriority',[int]$wanted.memory))) { $script:SessionIfeoAfter[$entry[0]] = ConvertTo-Json -InputObject ([ordered]@{kind=4;value=$entry[1]}) -Compress }
        $start = Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', 'Start', '-PreviewPath', $previewPath, '-ReviewHash', [string]$previewData.data.reviewHash, '-ConfirmApply')
        Set-Content -LiteralPath (Join-Path $OutDir 'session-start.txt') -Value ('exit ' + $start.exit + "`n" + $start.text) -Encoding UTF8
        $startData = Parse-Json $start.text
        $script:SessionRoot = if ($startData) { $startData.data.sessionRoot } else { $null }
        if ($script:SessionRoot) { $script:StartedSessionDir = Split-Path $script:SessionRoot -Parent }
        $script:SessionTask = if ($startData) { $startData.data.taskName }
        if ($script:SessionRoot -ine $script:ExpectedSessionRoot -or $script:SessionTask -cne $expectedTaskName) { throw 'Start returned an unexpected session identity; retained for recovery.' }
        $script:SessionTaskReceipt = Get-OwnedTaskReceipt $script:SessionTask
        Check ($start.exit -eq 0 -and $startData.data.worker.state.status -eq 'armed' -and $startData.data.worker.hostRunning -eq $true) 'the protected session is armed and its worker is running' ("exit=$($start.exit) status=" + $startData.data.worker.state.status + " registry=" + $startData.data.worker.state.registryStatus + " job=" + $startData.data.worker.state.jobStatus)
        Check ((Test-Path -LiteralPath $ifeo) -and $startData.data.worker.state.registryStatus -eq 'applied' -and $startData.data.worker.state.jobStatus -eq 'applied') 'arming wrote the probe image launch settings and attached the job' ("ifeo key present=" + (Test-Path -LiteralPath $ifeo))
        $task = Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue
        Check ($null -ne $task) 'the protected-session task is registered' ([string]$script:SessionTask)
        if ($task) {
            $xmlText = Task-Xml $task.TaskName $task.TaskPath
            Set-Content -LiteralPath (Join-Path $OutDir ('task-' + ($task.TaskName -replace '\W', '-') + '.xml')) -Value $xmlText -Encoding UTF8
            $sessionArguments = ([xml]$xmlText).Task.Actions.Exec.Arguments
            Check-TaskLauncher 'protected-session task' $xmlText $sessionExe @('run', (Join-Path $script:SessionRoot 'worker-request.json')) (Split-Path $sessionExe -Parent)
        }
        $sessionWorker = $null
        if ($script:SessionRoot) { $sessionWorker = @(Session-Workers $script:SessionRoot | Where-Object { $_.CommandLine -match '(^|\s)"?run"?(\s|$)' })[0] }
        Check ($null -ne $sessionWorker) 'the protected-session worker of this session is actually running' ($(if ($sessionWorker) { 'pid=' + $sessionWorker.ProcessId } else { 'no RooIndustries.SessionHost.exe run process for ' + $script:SessionRoot }))
        Check ($null -ne $sessionWorker -and $sessionWorker.ExecutablePath -ieq $sessionExe -and $sessionExe.StartsWith($env:ProgramFiles + '\', [StringComparison]::OrdinalIgnoreCase)) 'the protected-session worker image is the installed RooIndustries.SessionHost.exe under C:\Program Files' ($(if ($sessionWorker) { $sessionWorker.ExecutablePath } else { 'no worker' }))
    if ($sessionWorker) { Check-Chain 'protected session' $sessionWorker $sessionArguments; Check-Environment 'protected session' $sessionWorker }
        Unplant-Name
        $armedState = $null
        try { $armedState = WaitFor { $s = Launcher-State $sessionLauncher.Id; if ($s.affinity -eq $wanted.affinity -and $s.memory -eq $wanted.memory -and $s.io -eq $wanted.io) { $s } } 30 'the launcher defaults while armed' } catch {}
        Check ($null -ne $armedState) 'while the session is armed the launcher has the requested affinity, memory priority and I/O priority' ("before=" + ($baseline | ConvertTo-Json -Compress) + " now=" + (Launcher-State $sessionLauncher.Id | ConvertTo-Json -Compress) + " requested=" + ($wanted | ConvertTo-Json -Compress))
        Shot 'session-armed'
        $stop = Invoke-LauncherSessionCleanup $script:SessionRoot 'Stop'
        Set-Content -LiteralPath (Join-Path $OutDir 'session-stop.txt') -Value ('exit ' + $stop.exit + "`n" + $stop.text) -Encoding UTF8
        $stopData = Parse-Json $stop.text
        $state = $stopData.data.worker.state
        Check ($stop.exit -eq 0 -and $state.status -eq 'stopped' -and $state.registryStatus -eq 'restored' -and $state.jobStatus -eq 'cleared' -and $stopData.data.worker.hostRunning -eq $false) 'stopping the session reports it stopped with the launch settings restored and the job cleared' ("exit=$($stop.exit) status=" + $state.status + " registry=" + $state.registryStatus + " job=" + $state.jobStatus + " hostRunning=" + $stopData.data.worker.hostRunning)
        if ($stop.exit -eq 0) { $script:SessionRoot = $null; $script:SessionStopped = $true }
        $after = $null
        try { $after = WaitFor { $s = Launcher-State $sessionLauncher.Id; if ($s.affinity -eq $baseline.affinity -and $s.memory -eq $baseline.memory -and $s.io -eq $baseline.io) { $s } } 20 'the launcher defaults after the stop' } catch {}
        $fields = Get-LauncherIfeoFields
        Check (@('CpuPriorityClass','IoPriority','PagePriority' | Where-Object { $fields[$_] -cne $script:SessionIfeoBefore[$_] }).Count -eq 0) 'the probe image launch setting fields are restored after the stop' $ifeo
        $gone = $null
        try { $gone = WaitFor { if ($null -eq (Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue) -and @(Session-Workers $script:ExpectedSessionRoot).Count -eq 0) { $true } } 20 'the session task and worker to go' } catch {}
        Check ([bool]$gone) 'the protected-session task and every SessionHost process of this session are gone after the stop' ("task=" + [bool](Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue) + " workers=" + @(Session-Workers $script:ExpectedSessionRoot).Count)
        Check ($null -ne $after -and (Probe-Priority $sessionLauncher.Id) -eq $baselinePriority) 'the launcher probe has its original affinity, memory priority, I/O priority and CPU priority back after the stop' ("before=" + ($baseline | ConvertTo-Json -Compress) + " after=" + (Launcher-State $sessionLauncher.Id | ConvertTo-Json -Compress) + " cpu before=$baselinePriority after=" + (Probe-Priority $sessionLauncher.Id))
    }
    catch { $script:Failures++; Log ('FATAL protected-session part ' + ($_ | Out-String)); try { Shot 'fatal-session' } catch {} }
    finally {
        Unplant-Name
        $recoverRoot = if ($script:SessionStopped) { $null } elseif ($script:SessionRoot) { $script:SessionRoot } elseif ($script:ExpectedSessionRoot -and (Test-Path -LiteralPath (Join-Path $script:ExpectedSessionRoot 'session.json'))) { $script:ExpectedSessionRoot } else { $null }
        if ($recoverRoot) {
            foreach ($action in 'Stop', 'Recover') {
                try { $run = Invoke-LauncherSessionCleanup $recoverRoot $action } catch { Log ('CLEANUP NEEDED: protected-session recovery refused: ' + $_.Exception.Message); break }
                Log ("cleanup: $action exit=" + $run.exit)
                if ($run.exit -eq 0) { $script:SessionRoot = $null; $recoverRoot = $null; break }
            }
            if ($recoverRoot) { Log ('CLEANUP NEEDED: stop or recover the protected session at ' + $recoverRoot) }
        }
        if ($script:SessionTask -and (Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue)) { Log ('CLEANUP NEEDED: retained protected-session task for its journal owner: ' + $script:SessionTask) }
        if (Test-Path -LiteralPath $ifeo) { Log ('CLEANUP NEEDED: retained protected-session IFEO key and every unrelated field: ' + $ifeo) }
        try { Stop-OwnedProcess $sessionLauncherReceipt } catch { Log ('CLEANUP NEEDED: session launcher retained: ' + $_.Exception.Message) }
        foreach ($leftover in @($script:PreviewDir, $script:StartedSessionDir, $(if ($script:ExpectedSessionRoot) { Split-Path $script:ExpectedSessionRoot -Parent }))) {
            if ($leftover -and (Test-Path -LiteralPath $leftover)) { Log ($(if ($script:SessionStopped) { 'NOTE: retained completed session evidence for epoch recovery: ' } else { 'CLEANUP NEEDED: retained session evidence for epoch recovery: ' }) + $leftover) }
        }
        foreach ($file in @($sessionLauncherFile, $sessionGameFile)) {
            try { Remove-OwnedProbe $file } catch { Log ('CLEANUP NEEDED: session probe file retained: ' + $_.Exception.Message) }
            if ($file) { $file.Dispose() }
        }
    }
}
Log ('RESULT failures=' + $script:Failures)
'x' | Set-Content (Join-Path $OutDir ($Tag + '.done'))
