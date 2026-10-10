param(
    [Parameter(Mandatory)][ValidateSet('override', 'incomplete')][string]$Check,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe',
    [switch]$Before
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
$script:AppReceipt = $null
. (Join-Path $PSScriptRoot 'LauncherChecks.Common.ps1')
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
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class HelperStartEnv {
 [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr Exit, Peb, Affinity, Priority, Pid, ParentPid; }
 [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
 [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI info, int size, out int returned);
 static IntPtr Pointer(IntPtr h, IntPtr address) { var b = new byte[8]; IntPtr n; if (!ReadProcessMemory(h, address, b, (IntPtr)8, out n)) throw new System.ComponentModel.Win32Exception(); return (IntPtr)BitConverter.ToInt64(b, 0); }
 [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
 [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
 [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
 [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
 static IntPtr suspendedThread;
 public static int StartSuspended(string exe, string directory) {
  var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); PROCESS_INFORMATION pi;
  if (!CreateProcessW(exe, "\"" + exe + "\"", IntPtr.Zero, IntPtr.Zero, false, 0x00000004 | 0x00000400, IntPtr.Zero, directory, ref si, out pi)) throw new System.ComponentModel.Win32Exception();
  suspendedThread = pi.hThread; CloseHandle(pi.hProcess); return pi.dwProcessId;
 }
 public static void Resume() { ResumeThread(suspendedThread); CloseHandle(suspendedThread); suspendedThread = IntPtr.Zero; }
 public static string[] Names(int pid) {
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
   var entries = System.Text.Encoding.Unicode.GetString(data).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
   var names = new System.Collections.Generic.List<string>();
   foreach (var entry in entries) { int i = entry.IndexOf('=', 1); names.Add(i > 0 ? entry.Substring(0, i) : entry); }
   return names.ToArray();
  } finally { CloseHandle(h); }
 }
}
'@
[HelperStartU32]::SetProcessDPIAware() | Out-Null
[HelperStartU32]::SetThreadExecutionState([uint32]2147483651) | Out-Null
$A = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]; $CT = [Windows.Automation.ControlType]
$Tag = if ($Before) { $Check + '-before' } else { $Check }
$script:LogPath = Join-Path $OutDir ($Tag + '.log')
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
    $g.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $b.Size); $b.Save((Join-Path $OutDir ('shot-' + $Tag + '-' + $name + '.png')), [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()
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
    $script:AppReceipt = New-OwnedProcess $script:App
    Wait-RooIndustriesWindow
}
function Start-SuspendedRooIndustriesApp {
    Stop-RooIndustriesApp
    $id = [HelperStartEnv]::StartSuspended($Exe, (Split-Path $Exe -Parent))
    $script:App = Get-Process -Id $id
    $script:AppReceipt = New-OwnedProcess $script:App
    return $id
}
function Wait-RooIndustriesWindow {
    $script:Win = WaitFor { @($A::RootElement.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty, $script:App.Id)) | Where-Object { $_.Current.NativeWindowHandle -ne 0 -and $_.Current.Name -like 'Roo Industries*' })[0] } 60 'main window'
    $h = [IntPtr]::new($script:Win.Current.NativeWindowHandle); [HelperStartU32]::ShowWindow($h, 9) | Out-Null; [HelperStartU32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1600, 1000, 0x0040) | Out-Null; [HelperStartU32]::SetForegroundWindow($h) | Out-Null
    WaitFor { $script:Win.FindFirst($TS::Descendants, [Windows.Automation.PropertyCondition]::new($A::NameProperty, 'Start here')) } 60 'Home' | Out-Null
}
function Stop-RooIndustriesApp {
    Stop-OwnedValidationApp $script:App $script:AppReceipt
    Start-Sleep 1
}
function Data-Root {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    $current = Join-Path $local 'RooIndustriesOptimizationSuite'; $legacy = Join-Path $local ('RooIndustriesOptimizationSuite' -replace 'Industries','')
    if ((Test-Path -LiteralPath $legacy -PathType Container) -and -not ($markers -and $null -ne $markers.GetValue($current.ToUpperInvariant()) -and $null -eq $markers.GetValue($legacy.ToUpperInvariant()))) { $legacy } else { $current }
}
function Log-Since($before) { $all = @(Log-Lines); if($before.Count -eq 0){return $all}; $last=[Array]::LastIndexOf([object[]]$all,[object]$before[-1]); if($last -lt 0){throw 'The app log rotated or changed; this check cannot establish its log boundary.'}; @($all | Select-Object -Skip ($last+1)) }
function Log-Lines { $path = Join-Path (Data-Root) 'logs\app.log'; if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path -Encoding UTF8) } else { @() } }
function Flush-Starts {
    foreach ($e in @(Get-Event -SourceIdentifier RooIndustriesHelperStartWatch -ErrorAction SilentlyContinue)) {
        $n = $e.SourceEventArgs.NewEvent
        $entry = [pscustomobject]@{ utc = [DateTime]::FromFileTimeUtc([int64]$n.TIME_CREATED).ToString('HH:mm:ss.fff'); pid = [int]$n.ProcessID; parent = [int]$n.ParentProcessID; name = [string]$n.ProcessName }
        $script:Starts.Add($entry); $script:AllStarts.Add($entry)
        Remove-Event -EventIdentifier $e.EventIdentifier
    }
}
function Watch-Rows { $path = Join-Path $OutDir ($Tag + '-processes.csv'); if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_ -notmatch '^#' } | ConvertFrom-Csv) } else { @() } }
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
    $watcher = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'Watch-HelperProcesses.ps1') + '"'), '-OutCsv', ('"' + (Join-Path $OutDir ($Tag + '-processes.csv')) + '"'), '-StopFile', ('"' + $stopFile + '"')) -WindowStyle Hidden -PassThru
    WaitFor { Test-Path (Join-Path $OutDir ($Tag + '-processes.csv.ready')) } 30 'the process watcher' | Out-Null
    Log ('dotnet.exe candidates on this PC: ' + ((Dotnet-Candidates) -join '; '))
    if (Test-Path -LiteralPath $userDotNet) {
        $controlRun = Start-Process $userDotNet -ArgumentList '--version' -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $OutDir ($Tag + '-control-dotnet-version.txt'))
        Start-Sleep 2; Flush-Starts
        Check (@($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' -and $_.pid -eq $controlRun.Id }).Count -eq 1) 'control: the process trace sees a dotnet.exe that this scenario starts on purpose' ("pid=" + $controlRun.Id + " exit=" + $controlRun.ExitCode)
        $script:Starts.Clear()
    }
    else { Check $false 'control: the process trace sees a dotnet.exe that this scenario starts on purpose' ('no dotnet.exe at ' + $userDotNet) }

    if ($Check -eq 'override') {
        Check (-not (Test-Path -LiteralPath $noSuchDotNet)) 'the override target does not exist' $noSuchDotNet
        $logBefore = @(Log-Lines)
        $env:ROO_INDUSTRIES_DOTNET_EXE = $noSuchDotNet
        $initialNames = @()
        try {
            $suspendedId = Start-SuspendedRooIndustriesApp
            $initialNames = @([HelperStartEnv]::Names($suspendedId))
            [HelperStartEnv]::Resume()
            Wait-RooIndustriesWindow
        } finally { Remove-Item Env:ROO_INDUSTRIES_DOTNET_EXE -ErrorAction SilentlyContinue }
        Nav 'Windows tweaks'
        $list = WaitFor { ById 'WindowsTweaksList' } 60 'Windows tweaks list'
        $rows = WaitFor { $c = @($list.FindAll($TS::Children, [Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $CT::ListItem))).Count; if ($c -gt 0) { $c } } 180 'Windows tweaks rows'
        $status = WaitFor { $s = ById 'WindowsTweaksStatus'; if ($s -and $s.Current.Name -notmatch '^Loading|checking Windows features') { $s.Current.Name } } 180 'Windows tweaks status'
        Shot 'tweaks'
        Flush-Starts
        $hostRows = @(Watch-Rows | Where-Object { $_.name -eq 'Optimizer.Host.exe' -and [int]$_.ppid -eq $script:App.Id -and $_.command_line })
        $images = @($hostRows | ForEach-Object { Image-Of $_.command_line } | Select-Object -Unique)
        $inside = @($images | Where-Object { $_.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase) })
        Check ($rows -gt 0 -and $status -match '^\d+ settings$') 'with ROO_INDUSTRIES_DOTNET_EXE pointing at a missing dotnet.exe, the release app still loads the Windows tweaks rows and finishes reading Windows' ("rows=$rows status=$status")
        Check ($initialNames -contains 'ROO_INDUSTRIES_DOTNET_EXE') 'the override reached the app: ROO_INDUSTRIES_DOTNET_EXE is in the environment block the app process was created with, read before its first instruction ran' ('names in that environment block: ' + $initialNames.Count)
        Check ($hostRows.Count -gt 0 -and $inside.Count -eq $images.Count) 'the app started Optimizer.Host.exe children whose image is inside the install folder' ("children=$($hostRows.Count) images=" + ($images -join '; '))
        $new = @(Log-Since $logBefore)
        Check ($new.Count -gt 0 -and @($new | Where-Object { $_ -match 'RooIndustriesNoSuchFolder' }).Count -eq 0) 'the app wrote to the log this check reads, and the new log lines do not mention the override path' ('new log lines: ' + $new.Count)
        Check (@($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' }).Count -eq 0) 'the app never started a dotnet.exe' ('dotnet.exe starts: ' + @($script:Starts | Where-Object { $_.name -eq 'dotnet.exe' }).Count)
    }
    else {
        $dll = Join-Path $hostDirectory 'hostpolicy.dll'
        $dataRoot = Data-Root
        $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
        if (-not ($markers -and $null -ne $markers.GetValue($dataRoot.ToUpperInvariant()))) { Start-RooIndustriesApp; Stop-RooIndustriesApp; $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue }
        Check ($markers -and $null -ne $markers.GetValue($dataRoot.ToUpperInvariant())) 'the data folder is already protected before hostpolicy.dll is renamed (the app protects it through the helper on its first start, so the check starts from a used install)' $dataRoot
        Check (Test-Path -LiteralPath $dll) 'hostpolicy.dll is installed before the check' $dll
        Check (Test-Path -LiteralPath $userDotNet) 'a genuine Microsoft dotnet.exe is installed in the user profile (so a fallback would find it)' ($userDotNet + ' ' + $(if (Test-Path -LiteralPath $userDotNet) { (Get-Item $userDotNet).VersionInfo.ProductVersion } else { '' }))
        $script:Renamed += (Rename-OwnedFile $dll ($dll + '.roo-industries-test-off'))
        Log 'renamed hostpolicy.dll to hostpolicy.dll.roo-industries-test-off'
        $logBefore = @(Log-Lines)
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
        $new = @(Log-Since $logBefore)
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
            Set-Content -LiteralPath (Join-Path $OutDir ($Tag + '-' + $case.Script + '.txt')) -Value ('exit ' + $run.exit + "`n" + $run.text) -Encoding UTF8
            if ($Before) {
                Check ($caseStarts.Count -gt 0 -and $run.text -notmatch 'missing or damaged') ("BEFORE (commit 6d86fd8): the installed " + $case.Script + ' starts dotnet.exe from the user profile') ("exit=$($run.exit) dotnet.exe starts=$($caseStarts.Count) output=" + $run.text.Substring(0, [Math]::Min(300, $run.text.Length)))
            }
            else {
                Check ($run.exit -ne 0 -and $run.text -match 'missing or damaged' -and $caseStarts.Count -eq 0) ("the installed " + $case.Script + ' refuses with the missing-or-damaged message and starts no dotnet.exe') ("exit=$($run.exit) dotnet.exe starts=$($caseStarts.Count) output=" + $run.text.Substring(0, [Math]::Min(300, $run.text.Length)))
            }
        }
        Restore-OwnedFile $script:Renamed[0]; $script:Renamed = @()
        Check (Test-Path -LiteralPath $dll) 'hostpolicy.dll is back in place' $dll
    }
}
catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)); try { Shot 'fatal' } catch {} }
finally {
    foreach ($receipt in @($script:Renamed)) { try { Restore-OwnedFile $receipt; Log ('restored ' + (Split-Path $receipt.Identity.path -Leaf)) } catch { $script:Failures++; Log ('CLEANUP NEEDED: restore ' + $receipt.Identity.path + ': ' + $_.Exception.Message); $receipt.Dispose() } }
    Remove-Item Env:ROO_INDUSTRIES_DOTNET_EXE -ErrorAction SilentlyContinue
    Stop-RooIndustriesApp
    try { Flush-Starts; $script:AllStarts | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir ($Tag + '-process-starts.csv')) } catch {}
    Get-EventSubscriber -SourceIdentifier RooIndustriesHelperStartWatch -ErrorAction SilentlyContinue | Unregister-Event
    'x' | Set-Content $stopFile
    if ($watcher) { $watcher.WaitForExit(15000) | Out-Null }
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir ($Tag + '.done'))
}
