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
public static class LauncherCheckU32 {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);
}
'@
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class LauncherCheckEnv {
 [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr Exit, Peb, Affinity, Priority, Pid, ParentPid; }
 [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
 [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI info, int size, out int returned);
 static IntPtr Pointer(IntPtr h, IntPtr address) { var b = new byte[8]; IntPtr n; if (!ReadProcessMemory(h, address, b, (IntPtr)8, out n)) throw new System.ComponentModel.Win32Exception(); return (IntPtr)BitConverter.ToInt64(b, 0); }
 public static string[] Read(int pid) {
  IntPtr h = OpenProcess(0x0410, false, pid);
  if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
  try {
   var info = new PBI(); int returned;
   if (NtQueryInformationProcess(h, 0, ref info, Marshal.SizeOf(typeof(PBI)), out returned) != 0) throw new InvalidOperationException("NtQueryInformationProcess failed");
   IntPtr parameters = Pointer(h, (IntPtr)(info.Peb.ToInt64() + 0x20));
   IntPtr environment = Pointer(h, (IntPtr)(parameters.ToInt64() + 0x80));
   var sizeBytes = new byte[8]; IntPtr n;
   if (!ReadProcessMemory(h, (IntPtr)(parameters.ToInt64() + 0x3F0), sizeBytes, (IntPtr)8, out n)) throw new System.ComponentModel.Win32Exception();
   int size = (int)BitConverter.ToInt64(sizeBytes, 0);
   if (size <= 0 || size > 4 * 1024 * 1024) throw new InvalidOperationException("Unexpected environment size " + size);
   var data = new byte[size];
   if (!ReadProcessMemory(h, environment, data, (IntPtr)size, out n)) throw new System.ComponentModel.Win32Exception();
   return System.Text.Encoding.Unicode.GetString(data).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
  } finally { CloseHandle(h); }
 }
}
'@
[LauncherCheckU32]::SetProcessDPIAware() | Out-Null
[LauncherCheckU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$script:LogPath = Join-Path $OutDir 'launchers.log'
$script:Failures = 0
$script:App = $null
$install = Split-Path (Split-Path $Exe -Parent) -Parent
$scripts = Join-Path $install 'backend\scripts'
$hostExe = Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
$sessionExe = Join-Path $install 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe'
$system = [Environment]::GetFolderPath('System')
$clearNames = @('DOTNET_STARTUP_HOOKS', 'DOTNET_ADDITIONAL_DEPS', 'DOTNET_SHARED_STORE', 'CORECLR_ENABLE_PROFILING', 'CORECLR_PROFILER', 'CORECLR_PROFILER_PATH', 'CORECLR_PROFILER_PATH_32', 'CORECLR_PROFILER_PATH_64', 'CORECLR_PROFILER_PATH_ARM64', 'COR_ENABLE_PROFILING', 'COR_PROFILER', 'COR_PROFILER_PATH', 'COR_PROFILER_PATH_32', 'COR_PROFILER_PATH_64')
$ruleName = 'roo-industries-launcher-check rule'
$probeName = 'RooIndustriesLauncherProbe'
$probePath = Join-Path $env:TEMP ($probeName + '.exe')
$sessionLauncherPath = Join-Path $env:TEMP 'RooIndustriesProtectedLauncherProbe.exe'
$sessionGamePath = Join-Path $env:TEMP 'RooIndustriesProtectedGameProbe.exe'
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProtectedGameProbe.exe'

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
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [LauncherCheckU32]::ShowWindow($h, 9) | Out-Null; [LauncherCheckU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [LauncherCheckU32]::SetForegroundWindow($h) | Out-Null
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
function Quote-Literal([string]$value) { "'" + $value.Replace("'", "''") + "'" }
function Product-Launcher([string]$executable, [string[]]$argumentList, [string]$workingDirectory) {
    $command = '. ' + (Quote-Literal (Join-Path $scripts 'BrandCompatibility.Common.ps1')) + '; $a = New-RooIndustriesElevatedTaskAction -Executable ' + (Quote-Literal $executable) + ' -ArgumentList @(' + (($argumentList | ForEach-Object { Quote-Literal $_ }) -join ',') + ') -WorkingDirectory ' + (Quote-Literal $workingDirectory) + '; @{ Command = $a.Execute; Arguments = $a.Arguments; WorkingDirectory = $a.WorkingDirectory } | ConvertTo-Json -Compress'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $text = (& (Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    try { $text | ConvertFrom-Json } catch { Log ('could not build the expected action: ' + $text); $null }
}
function Product-ClearedNames {
    $command = '. ' + (Quote-Literal (Join-Path $scripts 'BrandCompatibility.Common.ps1')) + '; $script:RooIndustriesCodeLoadingVariables | ConvertTo-Json -Compress'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $text = (& (Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    [string[]]($text | ConvertFrom-Json)
}
function Task-Xml([string]$name, [string]$path) { [string](Export-ScheduledTask -TaskName $name -TaskPath $path) }
function Check-TaskLauncher([string]$label, [string]$xmlText, [string]$executable, [string[]]$argumentList, [string]$workingDirectory) {
    $exec = ([xml]$xmlText).Task.Actions.Exec
    $principal = ([xml]$xmlText).Task.Principals.Principal
    $expected = Product-Launcher $executable $argumentList $workingDirectory
    Check ($null -ne $expected -and $exec.Command -ieq $expected.Command -and $exec.Arguments -ceq $expected.Arguments -and $exec.WorkingDirectory -ieq $expected.WorkingDirectory) "$label's registered action equals what the installed New-RooIndustriesElevatedTaskAction produces for that helper and arguments" ("registered: " + $exec.Command + ' ' + $exec.Arguments + " | expected: " + $expected.Command + ' ' + $expected.Arguments)
    Check ($principal.RunLevel -eq 'HighestAvailable') "$label runs with the highest available privileges" ("runLevel=" + $principal.RunLevel)
}
function Check-Environment([string]$label, $worker) {
    $names = @(Product-ClearedNames)
    $present = @()
    try { $environment = @([LauncherCheckEnv]::Read([int]$worker.ProcessId)) } catch { $environment = $null; $err = $_.Exception.Message }
    if ($environment) { $present = @($environment | ForEach-Object { $_.Split('=')[0] } | Where-Object { $names -contains $_ }) }
    $environment | Set-Content -LiteralPath (Join-Path $OutDir ('environment-' + ($label -replace '\W', '-') + '.txt')) -Encoding UTF8
    Check ($null -ne $environment -and $environment.Count -gt 0 -and $present.Count -eq 0) "$label worker's own process environment contains none of the $($names.Count) code-loading variables" ("variables read=" + $(if ($environment) { $environment.Count } else { $err }) + " present=" + ($present -join ','))
}
function Process-Row([int]$processId) { Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue }
function Check-Chain([string]$label, $worker, [string]$actionArguments) {
    $cmd = if ($worker) { Process-Row $worker.ParentProcessId }
    $conhost = if ($cmd) { Process-Row $cmd.ParentProcessId }
    $actionTail = ($actionArguments -replace '^--headless\s+"[^"]*cmd\.exe"\s*', '')
    $chain = @($worker, $cmd, $conhost) | Where-Object { $_ } | ForEach-Object { [ordered]@{ pid = $_.ProcessId; parent = $_.ParentProcessId; name = $_.Name; image = $_.ExecutablePath; created = $_.CreationDate.ToUniversalTime().ToString('o'); commandLine = $_.CommandLine } }
    $chain | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir ('chain-' + ($label -replace '\W', '-') + '.json')) -Encoding UTF8
    $ok = $worker -and $cmd -and $conhost -and $cmd.Name -eq 'cmd.exe' -and $cmd.ExecutablePath -ieq (Join-Path $system 'cmd.exe') -and $cmd.CommandLine -match '/c' -and $cmd.CommandLine.Contains($actionTail) -and $conhost.Name -eq 'conhost.exe' -and $conhost.ExecutablePath -ieq (Join-Path $system 'conhost.exe') -and $conhost.CommandLine -match '--headless' -and $cmd.CreationDate -ge $conhost.CreationDate -and $worker.CreationDate -ge $cmd.CreationDate
    Check ([bool]$ok) "$label worker's parent is the cmd.exe the registered action starts under conhost.exe --headless" (($chain | ForEach-Object { $_.name + '(' + $_.pid + ')' }) -join ' <- ')
}
function Probe-Priority($id) { try { [string](Get-Process -Id $id -ErrorAction Stop).PriorityClass } catch { '<gone>' } }
function Policy-Tasks { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like '*OptimizationSuite.ProcessRules.*' }) }
function Policy-Workers { @(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'policy-run' }) }
function Run-Script([string]$name, [string[]]$arguments) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $text = @(& (Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $scripts $name) @arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ exit = $code; text = ($text -join "`n") }
}
function Parse-Json([string]$text) { $start = $text.IndexOf('{'); $end = $text.LastIndexOf('}'); if ($start -ge 0 -and $end -gt $start) { $text.Substring($start, $end - $start + 1) | ConvertFrom-Json } }

$probe = $null; $probeId = $null; $secondId = $null; $sessionLauncher = $null
$script:RuleSaved = $false
$script:SessionRoot = $null
$script:SessionTask = $null
$script:PreviewDir = $null
$script:StartedSessionDir = $null
$ifeoBefore = Test-Path -LiteralPath $ifeo
try {
    $cleared = @(Product-ClearedNames)
    $missingNames = @($clearNames | Where-Object { $cleared -notcontains $_ })
    Check ($cleared.Count -ge $clearNames.Count -and $missingNames.Count -eq 0) 'the installed launcher clears every code-loading variable the app itself refuses (none dropped from its list)' ("installed list has $($cleared.Count): " + ($cleared -join ',') + "; missing: " + ($missingNames -join ','))
    $control = [Diagnostics.ProcessStartInfo]::new((Join-Path $system 'PING.EXE'), '-n 20 127.0.0.1'); $control.UseShellExecute = $false; $control.CreateNoWindow = $true
    $control.EnvironmentVariables['DOTNET_STARTUP_HOOKS'] = 'C:\RooIndustriesNoSuchFolder\hook.dll'
    $controlProcess = [Diagnostics.Process]::Start($control)
    try { $controlEnv = @([LauncherCheckEnv]::Read($controlProcess.Id)) } finally { Stop-Process -Id $controlProcess.Id -Force -ErrorAction SilentlyContinue }
    Check (@($controlEnv | Where-Object { $_ -like 'DOTNET_STARTUP_HOOKS=*' }).Count -eq 1) 'control: the environment reader sees DOTNET_STARTUP_HOOKS in a process that was started with it' ("variables read=" + $controlEnv.Count)
}
catch { $script:Failures++; Log ('FATAL list check ' + ($_ | Out-String)) }

try {
    $rulesBefore = Policy-Tasks
    if ($rulesBefore.Count) { throw "A governor task already exists on this PC ($($rulesBefore[0].TaskName)); refusing to add a test rule." }
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $probePath -Force
    $probe = Start-Process $probePath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
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
    Invoke-Element (WaitFor { $b = ById 'ProcessSaveRule'; if ($b -and $b.Current.IsEnabled) { $b } } 30 'save rule button')
    $saved = Process-Status '^(Rule saved and (on|enabled)\.|Rule saved\. The governor is paused|Saved rules need attention)' 180 'rule save'
    Check ($saved -match '^Rule saved') 'the governor rule was saved through the app' ($saved + ' :: ' + (ById 'ProcessDetail').Current.Name)
    Shot 'rule-saved'

    $tasks = Policy-Tasks
    Check ($tasks.Count -ge 1) 'at least one governor task exists after saving a rule' ("tasks=$($tasks.Count): " + (($tasks | ForEach-Object { $_.TaskName }) -join ', '))
    $requestPath = Join-Path (Data-Root) 'process-rules\worker-request.json'
    foreach ($task in $tasks) {
        $xmlText = Task-Xml $task.TaskName $task.TaskPath
        Set-Content -LiteralPath (Join-Path $OutDir ('task-' + $task.TaskName + '.xml')) -Value $xmlText -Encoding UTF8
        $registeredArguments = ([xml]$xmlText).Task.Actions.Exec.Arguments
        Check-TaskLauncher ('governor task ' + $task.TaskName) $xmlText $hostExe @('policy-run', $requestPath) (Split-Path $hostExe -Parent)
    }
    $worker = $null; try { $worker = WaitFor { @(Policy-Workers)[0] } 90 'the governor worker' } catch {}
    $taskInfo = @($tasks | ForEach-Object { $i = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath; $_.TaskName + ' state=' + $_.State + ' lastResult=0x{0:X} lastRun=' -f $i.LastTaskResult + $i.LastRunTime }) -join '; '
    Check ($null -ne $worker) 'the governor worker is running after the rule was saved' ($(if ($worker) { 'pid=' + $worker.ProcessId } else { 'no Optimizer.Host.exe policy-run process; ' + $taskInfo }))
    if ($worker) { Check-Chain 'governor' $worker $registeredArguments; Check-Environment 'governor' $worker }
    if ($worker) {
        $enforced = $null; try { $enforced = WaitFor { if ((Probe-Priority $probeId) -eq 'BelowNormal') { $true } } 90 'rule enforced' } catch {}
        Check ([bool]$enforced) 'the governor enforces the saved rule on the probe' ('priority=' + (Probe-Priority $probeId))

        Stop-RooIndustriesApp
        $still = @(Policy-Workers)
        Check ($worker -and $still.Count -ge 1 -and $still[0].ProcessId -eq $worker.ProcessId) 'with the app closed the same governor worker is still running' ("pid before=$(if ($worker) { $worker.ProcessId }) after=" + (($still | ForEach-Object { $_.ProcessId }) -join ','))
        $second = Start-Process $probePath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
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
    $gone = $null; try { $gone = WaitFor { if ((Policy-Tasks).Count -eq 0 -and (Policy-Workers).Count -eq 0) { $true } } 60 'governor removal' } catch {}
    Check ([bool]$gone) 'deleting the last rule removes the governor task and ends the worker' ("tasks=" + (Policy-Tasks).Count + " workers=" + (Policy-Workers).Count)
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
    Stop-RooIndustriesApp
    foreach ($id in @($probeId, $secondId)) { if ($id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
    if ($script:RuleSaved) {
        foreach ($task in Policy-Tasks) { try { Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false; Log ('cleanup: removed governor task ' + $task.TaskName) } catch { Log ('CLEANUP NEEDED: remove scheduled task ' + $task.TaskName) } }
        Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'policy-run' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Log 'cleanup: stopped a governor worker' }
        Log ('CLEANUP NEEDED: the rule ' + $ruleName + ' may still be saved; delete it in Games > Processes')
    }
    Remove-Item $probePath -Force -ErrorAction SilentlyContinue
}

try {
    if ($ifeoBefore) { throw 'The protected-session probe image key already exists; refusing to overwrite it.' }
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $sessionLauncherPath -Force
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $sessionGamePath -Force
    $sessionLauncher = Start-Process $sessionLauncherPath -ArgumentList '-n', '900', '127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep 2
    $baseline = [ordered]@{ priority = Probe-Priority $sessionLauncher.Id; affinity = '0x{0:X}' -f [int64](Get-Process -Id $sessionLauncher.Id).ProcessorAffinity }
    $script:PreviewDir = Join-Path (Data-Root) 'operations\game-session-roo-industries-launcher-check'
    New-Item -ItemType Directory -Force -Path $script:PreviewDir | Out-Null
    $controls = Join-Path $script:PreviewDir 'controls.json'
    Set-Content -LiteralPath $controls -Value '{"cpuPriority":"AboveNormal"}' -Encoding ASCII
    $previewPath = Join-Path $script:PreviewDir 'preview.json'
    $preview = Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', 'Preview', '-LauncherProcessId', [string]$sessionLauncher.Id, '-GamePath', $sessionGamePath, '-ControlsPath', $controls, '-PreviewPath', $previewPath, '-AcceptLauncherScope')
    $previewData = Parse-Json $preview.text
    Check ($preview.exit -eq 0 -and $previewData.status -eq 'completed' -and $previewData.data.reviewHash) 'a protected-session preview is created with a harmless probe as the launcher' ("exit=$($preview.exit) " + $preview.text.Substring(0, [Math]::Min(300, $preview.text.Length)))
    $start = Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', 'Start', '-PreviewPath', $previewPath, '-ReviewHash', [string]$previewData.data.reviewHash, '-ConfirmApply')
    Set-Content -LiteralPath (Join-Path $OutDir 'session-start.txt') -Value ('exit ' + $start.exit + "`n" + $start.text) -Encoding UTF8
    $startData = Parse-Json $start.text
    $script:SessionRoot = if ($startData) { $startData.data.sessionRoot }
    if ($script:SessionRoot) { $script:StartedSessionDir = Split-Path $script:SessionRoot -Parent }
    $script:SessionTask = if ($startData) { $startData.data.taskName }
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
    $sessionWorker = @(Get-CimInstance Win32_Process -Filter "Name='RooIndustries.SessionHost.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '(^|\s)"?run"?(\s|$)' })[0]
    Check ($null -ne $sessionWorker) 'the protected-session worker is actually running' ($(if ($sessionWorker) { 'pid=' + $sessionWorker.ProcessId } else { 'no RooIndustries.SessionHost.exe run process' }))
    if ($sessionWorker) { Check-Chain 'protected session' $sessionWorker $sessionArguments; Check-Environment 'protected session' $sessionWorker }
    Shot 'session-armed'
    $stop = Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', 'Stop', '-SessionRoot', $script:SessionRoot, '-ConfirmApply')
    Set-Content -LiteralPath (Join-Path $OutDir 'session-stop.txt') -Value ('exit ' + $stop.exit + "`n" + $stop.text) -Encoding UTF8
    $stopData = Parse-Json $stop.text
    $state = $stopData.data.worker.state
    Check ($stop.exit -eq 0 -and $state.status -eq 'stopped' -and $state.registryStatus -eq 'restored' -and $state.jobStatus -eq 'cleared' -and $stopData.data.worker.hostRunning -eq $false) 'stopping the session reports it stopped with the launch settings restored and the job cleared' ("exit=$($stop.exit) status=" + $state.status + " registry=" + $state.registryStatus + " job=" + $state.jobStatus + " hostRunning=" + $stopData.data.worker.hostRunning)
    if ($stop.exit -eq 0) { $script:SessionRoot = $null }
    Start-Sleep 1
    $after = [ordered]@{ priority = Probe-Priority $sessionLauncher.Id; affinity = '0x{0:X}' -f [int64](Get-Process -Id $sessionLauncher.Id).ProcessorAffinity }
    Check (-not (Test-Path -LiteralPath $ifeo)) 'the probe image launch settings key is gone after the stop' $ifeo
    Check ($null -eq (Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue) -and @(Get-Process RooIndustries.SessionHost -ErrorAction SilentlyContinue).Count -eq 0) 'the protected-session task and worker are gone after the stop' ("task=" + [bool](Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue) + " workers=" + @(Get-Process RooIndustries.SessionHost -ErrorAction SilentlyContinue).Count)
    Check ($after.priority -eq $baseline.priority -and $after.affinity -eq $baseline.affinity) 'the launcher probe has its original priority and affinity back' ("before=" + ($baseline | ConvertTo-Json -Compress) + " after=" + ($after | ConvertTo-Json -Compress))
}
catch { $script:Failures++; Log ('FATAL protected-session part ' + ($_ | Out-String)); try { Shot 'fatal-session' } catch {} }
finally {
    if ($script:SessionRoot) {
        foreach ($action in 'Stop', 'Recover') {
            $run = Run-Script 'Invoke-ProtectedGameSession.ps1' @('-Action', $action, '-SessionRoot', $script:SessionRoot, '-ConfirmApply')
            Log ("cleanup: $action exit=" + $run.exit)
            if ($run.exit -eq 0) { $script:SessionRoot = $null; break }
        }
        if ($script:SessionRoot) { Log ('CLEANUP NEEDED: stop or recover the protected session at ' + $script:SessionRoot) }
    }
    if ($script:SessionTask) { Get-ScheduledTask -TaskName $script:SessionTask -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue }
    if (-not $ifeoBefore -and (Test-Path -LiteralPath $ifeo)) { Remove-Item -LiteralPath $ifeo -Recurse -Force -ErrorAction SilentlyContinue; Log ('cleanup: removed ' + $ifeo) }
    if ($sessionLauncher) { Stop-Process -Id $sessionLauncher.Id -Force -ErrorAction SilentlyContinue }
    foreach ($leftover in @($script:PreviewDir, $script:StartedSessionDir)) { if ($leftover -and (Test-Path -LiteralPath $leftover)) { try { Copy-Item -LiteralPath $leftover -Destination (Join-Path $OutDir (Split-Path $leftover -Leaf)) -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $leftover -Recurse -Force; Log ('cleanup: removed ' + $leftover) } catch { Log ('CLEANUP NEEDED: remove ' + $leftover) } } }
    Remove-Item $sessionLauncherPath, $sessionGamePath -Force -ErrorAction SilentlyContinue
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir 'launchers.done')
}
