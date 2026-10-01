param([string]$IsccPath = '')
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $IsccPath) {
    foreach ($candidate in @((Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'), (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))) { if (Test-Path -LiteralPath $candidate) { $IsccPath = $candidate; break } }
}
if (-not $IsccPath) { throw 'Inno Setup 6 was not found.' }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; Write-Output ('PASS ' + $Message) }
$work = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-setup-process-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory((Join-Path $work 'setup-temp')) | Out-Null
    & $IsccPath /Q "/DOutputDir=$work" (Join-Path $repoRoot 'tools\release\SetupProcess.Test.iss')
    if ($LASTEXITCODE -ne 0) { throw 'The setup process check did not compile.' }
    $process = Start-Process -FilePath (Join-Path $work 'SetupProcessCheck.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/work="' + $work + '"')) -PassThru -Wait
    Assert ($process.ExitCode -eq 1) 'The check setup exits without installing anything'
    $report = @(Get-Content -LiteralPath (Join-Path $work 'report.txt'))
    $windows = [Environment]::GetFolderPath('Windows')
    $system = [Environment]::SystemDirectory
    $env = @{}
    foreach ($line in (Get-Content -LiteralPath (Join-Path $work 'env.txt'))) { $index = $line.IndexOf('='); if ($index -gt 0) { $env[$line.Substring(0, $index)] = $line.Substring($index + 1) } }
    Assert ($report -contains 'A ran=1 exit=7' -or @($report | Where-Object { $_ -like 'A ran=1 exit=7 ms=*' }).Count -eq 1) 'A bounded run reports the exit code of a script that finishes'
    Assert ($env['SystemRoot'] -ceq $windows -and $env['windir'] -ceq $windows) 'The script sees the real Windows folder, not the marker'
    Assert ($env['PATH'] -ceq ($system + ';' + $windows + ';' + $system + '\Wbem;' + $system + '\WindowsPowerShell\v1.0')) 'The script sees only the system folders on PATH'
    Assert ($env['TEMP'] -ceq (Join-Path $work 'setup-temp') -and $env['TMP'] -ceq $env['TEMP']) 'The script sees the setup folder as its temp folder'
    Assert ($env['ComSpec'] -ceq (Join-Path $system 'cmd.exe') -and $env['SystemDrive'] -ceq [IO.Path]::GetPathRoot($windows).TrimEnd('\')) 'The script sees the real command interpreter and system drive'
    Assert (-not $env.ContainsKey('DOTNET_gcServer') -and -not $env.ContainsKey('COMPlus_gcServer')) 'The script does not see inherited runtime tuning names'
    Assert (@($env.Values | Where-Object { $_ -like ($work + '\marker*') }).Count -eq 0) 'No marker value reaches the script'
    $timed = @($report | Where-Object { $_ -match '^B ran=0 exit=258 ms=(\d+)$' })
    Assert ($timed.Count -eq 1 -and [int]([regex]::Match($timed[0], '\d+$').Value) -lt 8000) 'A hung script is stopped at the limit with the timed out code'
    Assert ($report -contains 'B finished=0' -and (Test-Path -LiteralPath (Join-Path $work 'started.txt')) -and -not (Test-Path -LiteralPath (Join-Path $work 'finished.txt'))) 'The hung script was running and never finished'
    Assert ($report -contains 'C ran=0 exit=1') 'A missing program reports failure'
    $plain = @($report | Where-Object { $_ -match '^D ran=1 exit=0 ms=(\d+)$' })
    Assert ($plain.Count -eq 1 -and [int]([regex]::Match($plain[0], '\d+$').Value) -ge 11000) 'Setup''s plain wait on the same kind of script has no limit'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
Assert (-not (Test-Path -LiteralPath $work)) 'The setup process check removes its folder'
