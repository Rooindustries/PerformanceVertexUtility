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
function Quote-Literal([string]$value) { "'" + $value.Replace("'", "''") + "'" }
function Invoke-Ps51([string]$command) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { (& (Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { [string]$_ }) -join "`n" }
    finally { $ErrorActionPreference = $previous }
}
function Product-Launcher([string]$executable, [string[]]$argumentList, [string]$workingDirectory) {
    $command = '. ' + (Quote-Literal (Join-Path $scripts 'BrandCompatibility.Common.ps1')) + '; $a = New-RooIndustriesElevatedTaskAction -Executable ' + (Quote-Literal $executable) + ' -ArgumentList @(' + (($argumentList | ForEach-Object { Quote-Literal $_ }) -join ',') + ') -WorkingDirectory ' + (Quote-Literal $workingDirectory) + '; @{ Command = $a.Execute; Arguments = $a.Arguments; WorkingDirectory = $a.WorkingDirectory } | ConvertTo-Json -Compress'
    $text = Invoke-Ps51 $command
    try { $text | ConvertFrom-Json } catch { Log ('could not build the expected action: ' + $text); $null }
}
function Product-ClearedNames {
    $command = '. ' + (Quote-Literal (Join-Path $scripts 'BrandCompatibility.Common.ps1')) + '; $script:RooIndustriesCodeLoadingVariables | ConvertTo-Json -Compress'
    [string[]](Invoke-Ps51 $command | ConvertFrom-Json)
}
function Task-Xml([string]$name, [string]$path) { [string](Export-ScheduledTask -TaskName $name -TaskPath $path) }
function Check-TaskLauncher([string]$label, [string]$xmlText, [string]$executable, [string[]]$argumentList, [string]$workingDirectory) {
    $exec = ([xml]$xmlText).Task.Actions.Exec
    $principal = ([xml]$xmlText).Task.Principals.Principal
    $expected = Product-Launcher $executable $argumentList $workingDirectory
    Check ($null -ne $expected -and $exec.Command -ieq $expected.Command -and $exec.Arguments -ceq $expected.Arguments -and $exec.WorkingDirectory -ieq $expected.WorkingDirectory) "$label's registered action equals what the installed New-RooIndustriesElevatedTaskAction produces for that helper and arguments" ("registered: " + $exec.Command + ' ' + $exec.Arguments + " | expected: " + $expected.Command + ' ' + $expected.Arguments)
    Check ($principal.RunLevel -eq 'HighestAvailable') "$label runs with the highest available privileges" ("runLevel=" + $principal.RunLevel)
}
function Env-Names($environment) { @($environment | ForEach-Object { $i = ([string]$_).IndexOf('=', 1); if ($i -gt 0) { ([string]$_).Substring(0, $i) } else { [string]$_ } }) }
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

function Stop-ProcessRow($row) {
    if(-not $row -or -not $row.CreationDate){throw 'Refusing to stop a process without its creation time.'}
    $process=Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
    if(-not $process){return}
    try {
        $null=$process.Handle
        $current=Process-Row $row.ProcessId
        if($current -and $current.CreationDate -eq $row.CreationDate -and $current.ExecutablePath -ieq $row.ExecutablePath -and $current.CommandLine -ceq $row.CommandLine){$process.Kill()}
        elseif($current){throw ('Process identity changed; kept pid '+$row.ProcessId)}
    } finally {$process.Dispose()}
}
function Child-Rows($parent) {
    if(-not $parent -or $parent.HasExited){return @()}
    $null=$parent.Handle
    $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    $found=[Collections.Generic.List[object]]::new()
    $parents=@([pscustomobject]@{ProcessId=$parent.Id;CreationDate=$parent.StartTime})
    while($parents.Count){
        $children=@(foreach($root in $parents){$all|Where-Object {$_.ParentProcessId -eq $root.ProcessId -and $_.CreationDate -ge $root.CreationDate -and $_.ProcessId -ne $parent.Id -and $found.ProcessId -notcontains $_.ProcessId}})
        foreach($child in $children){$found.Add($child)}
        $parents=$children
    }
    @($found.ToArray())
}
