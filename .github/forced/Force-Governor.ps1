param([string]$Mode = 'lag', [int]$Rounds = 4)
$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PWD 'backend\scripts'
. (Join-Path $scripts 'Validation.Common.ps1')
Set-RooIndustriesValidationNormalPriority
$n = [Environment]::ProcessorCount
$threads = if ($Mode -eq 'saturate') { $n } else { [Math]::Max(1, [int][Math]::Ceiling($n * 0.4)) }
if ($Mode -eq 'lag') { $env:ROO_FORCE_FIRST_POLL_LAG_MS = '7000' } else { Remove-Item Env:ROO_FORCE_FIRST_POLL_LAG_MS -ErrorAction SilentlyContinue }
$probeScript = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition 'using System; using System.Threading; using System.Runtime.InteropServices; public static class ForceProbe { public static void Run() { while (true) { Thread.SpinWait(1000000); } } [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }'
`$s = [System.Delegate]::CreateDelegate([System.Threading.ThreadStart], [ForceProbe].GetMethod('Run'))
for (`$i = 0; `$i -lt $threads; `$i++) { `$t = [System.Threading.Thread]::new(`$s); `$t.IsBackground = `$true; `$t.Start() }
`$dir = Split-Path ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
Set-Content -LiteralPath (Join-Path `$dir 'ready') -Value ready
`$end = (Get-Date).AddSeconds(120)
`$form = `$null
while ((Get-Date) -lt `$end) {
    if (`$null -eq `$form -and (Test-Path -LiteralPath (Join-Path `$dir 'go'))) {
        `$form = New-Object System.Windows.Forms.Form
        `$form.Text = 'Force foreground probe'
        `$form.Show(); `$form.Activate(); [ForceProbe]::SetForegroundWindow(`$form.Handle) | Out-Null
    }
    if (`$form) {
        [System.Windows.Forms.Application]::DoEvents()
        if ([ForceProbe]::GetForegroundWindow() -eq `$form.Handle) { Set-Content -LiteralPath (Join-Path `$dir 'fg') -Value fg }
    }
    Start-Sleep -Milliseconds 50
}
"@
$hits = 0
for ($r = 1; $r -le $Rounds; $r++) {
    $root = Join-Path $env:RUNNER_TEMP "force-$Mode-$r"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $exe = Join-Path $root 'RooIndustriesForceWebHelperProbe.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $exe -Force
    Set-Content -LiteralPath (Join-Path $root 'probe.ps1') -Value $probeScript
    $probe = Start-Process -FilePath $exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'probe.ps1') -PassThru
    try {
        while (-not (Test-Path -LiteralPath (Join-Path $root 'ready'))) { if ($probe.HasExited) { throw 'probe exited' }; Start-Sleep -Milliseconds 100 }
        $state = Join-Path $root 'state'
        $out = Join-Path $root 'session.out.json'
        $sessionArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts 'Start-ProcessGovernorSession.ps1'),'-SampleIntervalMilliseconds','200','-PollIntervalSeconds','1','-MaxDurationSeconds','14','-ConfirmApply','-StateRoot',$state)
        if ($Mode -ne 'fg') { $sessionArgs += @('-ForegroundProcessId', [string]$PID) }
        $session = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-RooIndustriesWindowsArguments $sessionArgs) -RedirectStandardOutput $out -WindowStyle Hidden -PassThru
        $switched = $false
        if ($Mode -eq 'fg') {
            do { Start-Sleep -Milliseconds 100; $f = Get-ChildItem -LiteralPath $state -Filter session.json -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1; $pc = 0; if ($f) { try { $pc = [int]((Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json).pollCount) } catch { } } } while ($pc -lt 1 -and -not $session.HasExited)
            Set-Content -LiteralPath (Join-Path $root 'go') -Value go
            $deadline = (Get-Date).AddSeconds(5)
            while (-not (Test-Path -LiteralPath (Join-Path $root 'fg')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $switched = Test-Path -LiteralPath (Join-Path $root 'fg')
        }
        $session.WaitForExit()
        $result = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
        $hit = @($result.changedItems | Where-Object { [int]$_.processId -eq $probe.Id }).Count -gt 0
        if ($hit) { $hits++ }
        $times = @($result.polls | ForEach-Object { ([datetime]$_.capturedAtUtc).ToUniversalTime().ToString('ss.fff') }) -join ','
        Write-Host "ROUND $r mode=$Mode threads=$threads/$n restrained=$hit switchedToForeground=$switched sessionForeground=$($result.foregroundProcessId) probe=$($probe.Id) polls=$($result.pollCount) captured=$times"
        if ($result.restorable) { & (Join-Path $scripts 'Stop-ProcessGovernorSession.ps1') -SessionPath $result.sessionPath -ConfirmApply | Out-Null }
    } finally {
        if (-not $probe.HasExited) { $probe.Kill(); $probe.WaitForExit() }
    }
}
Write-Host "SCORE mode=$Mode restrained $hits of $Rounds"
