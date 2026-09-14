param(
    [string[]]$TestName = @(),
    [string]$ResultsRoot = '',
    [switch]$BuildFrontend,
    [string]$DotNetPath = $env:ROO_DOTNET_EXE
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repoRoot 'backend\scripts\ProcessProfile.Common.ps1')
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = Join-Path $repoRoot ('artifacts\validation\' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')) }
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
function Get-ValidationTempPaths {
    $paths = @()
    foreach ($pattern in @('roo-*','RooBackend*','RooNvidia*','RooStutter*')) {
        $paths += @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter $pattern -Force -ErrorAction Stop | Select-Object -ExpandProperty FullName)
    }
    return @($paths | Sort-Object -Unique)
}
$tempBefore = @(Get-ValidationTempPaths)
$results = New-Object System.Collections.Generic.List[object]
$testScripts = @(Get-ChildItem (Join-Path $repoRoot 'backend\scripts') -Filter 'Test-*.ps1' -File | Sort-Object Name)
if ($TestName.Count -gt 0) {
    $unknown = @($TestName | Where-Object { $_ -notin $testScripts.Name })
    if ($unknown.Count -gt 0) { throw ('Unknown tests: ' + ($unknown -join ', ')) }
    $testScripts = @($testScripts | Where-Object { $_.Name -in $TestName })
}
$parseErrors = @()
foreach ($file in @((Get-ChildItem (Join-Path $repoRoot 'backend') -Filter '*.ps1' -Recurse -File),(Get-ChildItem (Join-Path $repoRoot 'tools') -Filter '*.ps1' -Recurse -File),(Get-Item (Join-Path $repoRoot 'LeanClientOptimizer.ps1'))) | ForEach-Object { $_ }) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $parseErrors += @($errors)
}
if ($parseErrors.Count -gt 0) { $parseErrors | Format-List; throw 'PowerShell parser validation failed.' }
foreach ($test in $testScripts) {
    $log = Join-Path $ResultsRoot ($test.BaseName + '.stdout.log')
    $errorLog = Join-Path $ResultsRoot ($test.BaseName + '.stderr.log')
    Write-Host "RUN $($test.Name)"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'powershell.exe'
    $start.Arguments = Join-RooWindowsArguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$test.FullName)
    $start.WorkingDirectory = $repoRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    [IO.File]::WriteAllText($log, $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText($errorLog, $stderr.GetAwaiter().GetResult())
    $process.Dispose()
    $watch.Stop()
    $results.Add([pscustomobject]@{ test=$test.Name; exitCode=$exitCode; seconds=[math]::Round($watch.Elapsed.TotalSeconds,2); stdout=$log; stderr=$errorLog }) | Out-Null
    Write-Host "EXIT $($test.Name) $exitCode ($([math]::Round($watch.Elapsed.TotalSeconds,1))s)"
}
$buildExit = $null
if ($BuildFrontend) {
    & (Join-Path $PSScriptRoot 'Build-Frontend.ps1') -Configuration Release -DotNetPath $DotNetPath
    $buildExit = $LASTEXITCODE
}
$stateRoot = Join-Path $repoRoot 'backend\state'
$stateEntries = if (Test-Path $stateRoot) { @(Get-ChildItem $stateRoot -Force -Recurse).Count } else { 0 }
$newTempArtifacts = @(Get-ValidationTempPaths | Where-Object { $_ -notin $tempBefore })
$summary = [pscustomobject]@{ newTempArtifacts = $newTempArtifacts; machine=$env:COMPUTERNAME; completedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); tests=@($results.ToArray()); failedCount=@($results.ToArray() | Where-Object {$_.exitCode -ne 0}).Count; buildExitCode=$buildExit; stateEntries=$stateEntries }
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsRoot 'summary.json') -Encoding UTF8
Write-Host "Summary: $ResultsRoot\summary.json"
if ($summary.failedCount -gt 0 -or $newTempArtifacts.Count -ne 0 -or $stateEntries -ne 0 -or ($BuildFrontend -and $buildExit -ne 0)) { exit 1 }
