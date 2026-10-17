param(
    [string[]]$TestName = @(),
    [string]$ResultsRoot = '',
    [switch]$BuildFrontend,
    [switch]$ParseOnly,
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE,
    [ValidateRange(1, 86400)][int]$TestTimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repoRoot 'backend\scripts\ProcessProfile.Common.ps1')
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $ResultsRoot = Join-Path $repoRoot ('artifacts\validation\' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')) }
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
function Get-ValidationTempPaths {
    $paths = @()
    foreach ($pattern in @('roo-industries-*','RooIndustriesBackend*','RooIndustriesNvidia*','RooIndustriesStutter*')) {
        $paths += @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter $pattern -Force -ErrorAction Stop | Select-Object -ExpandProperty FullName)
    }
    return @($paths | Sort-Object -Unique)
}
$baselineProcess = [Diagnostics.Process]::GetCurrentProcess()
$baselineProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
Set-RooIndustriesProcessIoPriority $baselineProcess 'Normal'
$baselineProcess.Dispose()
$tempBefore = @(Get-ValidationTempPaths)
$results = New-Object System.Collections.Generic.List[object]
$outputReaderFailure = $false
$suiteTimeoutSeconds = @{ 'Test-GovernorScenarios.ps1' = 2700 }
$testScripts = @(Get-ChildItem (Join-Path $repoRoot 'backend\scripts') -Filter 'Test-*.ps1' -File | Sort-Object Name)
if ($TestName.Count -gt 0) {
    $unknown = @($TestName | Where-Object { $_ -notin $testScripts.Name })
    if ($unknown.Count -gt 0) { throw ('Unknown tests: ' + ($unknown -join ', ')) }
    $testScripts = @($testScripts | Where-Object { $_.Name -in $TestName })
}
$parseErrors = @()
$parsedFiles = 0
foreach ($file in @((Get-ChildItem (Join-Path $repoRoot 'backend') -Filter '*.ps1' -Recurse -File),(Get-ChildItem (Join-Path $repoRoot 'tools') -Filter '*.ps1' -Recurse -File),(Get-Item (Join-Path $repoRoot 'LeanClientOptimizer.ps1'))) | ForEach-Object { $_ }) {
    $parsedFiles++
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $parseErrors += @($errors)
}
if ($parseErrors.Count -gt 0) { $parseErrors | Format-List; throw 'PowerShell parser validation failed.' }
if ($ParseOnly) { 'PowerShell parser validation passed for ' + $parsedFiles + ' files.'; return }
foreach ($test in $testScripts) {
    $log = Join-Path $ResultsRoot ($test.BaseName + '.stdout.log')
    $errorLog = Join-Path $ResultsRoot ($test.BaseName + '.stderr.log')
    Write-Host "RUN $($test.Name)"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'powershell.exe'
    $start.Arguments = Join-RooIndustriesWindowsArguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$test.FullName)
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
    $timeoutSeconds = if ($suiteTimeoutSeconds.ContainsKey($test.Name)) { [math]::Max($suiteTimeoutSeconds[$test.Name], $TestTimeoutSeconds) } else { $TestTimeoutSeconds }
    $timedOut = -not $process.WaitForExit($timeoutSeconds * 1000)
    $exitCode = $null
    $leftoverProcesses = @()
    $testNotes = New-Object System.Collections.Generic.List[string]
    if ($timedOut) {
        $tree = New-Object System.Collections.Generic.List[object]
        $snapshot = @()
        try {
            $snapshot = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate -OperationTimeoutSec 30 | ForEach-Object {
                [pscustomobject]@{ processId=[int]$_.ProcessId; parentProcessId=[int]$_.ParentProcessId; creationDate=$(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime() } else { $null }) }
            })
        } catch { $testNotes.Add('Process tree snapshot failed: ' + $_.Exception.Message) }
        $rootProcess = @($snapshot | Where-Object { $_.processId -eq $process.Id })
        $queue = New-Object System.Collections.Generic.Queue[object]
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        if ($rootProcess.Count) { $queue.Enqueue($rootProcess[0]) }
        else { $queue.Enqueue([pscustomobject]@{ processId=$process.Id; creationDate=$process.StartTime.ToUniversalTime() }) }
        while ($queue.Count) {
            $member = $queue.Dequeue()
            if (-not $seen.Add($member.processId)) { continue }
            $tree.Add($member)
            foreach ($child in @($snapshot | Where-Object { $_.parentProcessId -eq $member.processId })) {
                if ($child.creationDate -and $member.creationDate -and $child.creationDate -lt $member.creationDate) { continue }
                $queue.Enqueue($child)
            }
        }
        $killer = [Diagnostics.Process]::new()
        try {
            $killer.StartInfo = [Diagnostics.ProcessStartInfo]::new()
            $killer.StartInfo.FileName = 'taskkill.exe'
            $killer.StartInfo.Arguments = '/PID ' + $process.Id + ' /T /F'
            $killer.StartInfo.UseShellExecute = $false
            $killer.StartInfo.CreateNoWindow = $true
            [void]$killer.Start()
            if (-not $killer.WaitForExit(30000)) {
                $testNotes.Add('taskkill did not finish within 30 seconds.')
                $killer.Kill()
                if (-not $killer.WaitForExit(5000)) { $testNotes.Add('taskkill did not exit after forced termination.') }
            } elseif ($killer.ExitCode -ne 0) { $testNotes.Add('taskkill exit code: ' + $killer.ExitCode) }
        } catch { $testNotes.Add('Process tree termination failed: ' + $_.Exception.Message) }
        finally { $killer.Dispose() }
        [void]$process.WaitForExit(30000)
        try {
            $remaining = @(Get-CimInstance Win32_Process -Property ProcessId,CreationDate -OperationTimeoutSec 30)
            $leftoverProcesses = @(foreach ($member in $tree) {
                foreach ($candidate in @($remaining | Where-Object { [int]$_.ProcessId -eq $member.processId })) {
                    if (-not $member.creationDate -or -not $candidate.CreationDate) {
                        $testNotes.Add('Process creation date unavailable; cleanup could not be verified for PID ' + $member.processId)
                    } elseif ($candidate.CreationDate.ToUniversalTime() -eq $member.creationDate) {
                        [pscustomobject]@{ processId=$member.processId; creationDate=$member.creationDate.ToString('o') }
                    }
                }
            })
        } catch { $testNotes.Add('Process tree cleanup could not be verified: ' + $_.Exception.Message) }
    } else { $exitCode = $process.ExitCode }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 60000) }
    catch { $testNotes.Add('Output reader wait failed: ' + $_.Exception.Message) }
    $readers = @($stdout, $stderr)
    $output = @('', '')
    for ($index = 0; $index -lt $readers.Count; $index++) {
        if ($readers[$index].Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $output[$index] = $readers[$index].GetAwaiter().GetResult() }
        else {
            $outputReaderFailure = $true
            if ($readers[$index].IsFaulted -or $readers[$index].IsCanceled) { $output[$index] = '[output unavailable: reader failed]' }
            else { $output[$index] = '[output unavailable: reader did not finish]' }
        }
    }
    [IO.File]::WriteAllText($log, [string]$output[0])
    $errorOutput = [string]$output[1]
    if ($testNotes.Count) { $errorOutput += [Environment]::NewLine + ($testNotes.ToArray() -join [Environment]::NewLine) }
    [IO.File]::WriteAllText($errorLog, $errorOutput)
    $process.Dispose()
    $watch.Stop()
    $results.Add([pscustomobject]@{ test=$test.Name; exitCode=$exitCode; timedOut=$timedOut; timeoutSeconds=$timeoutSeconds; leftoverProcesses=@($leftoverProcesses); seconds=[math]::Round($watch.Elapsed.TotalSeconds,2); stdout=$log; stderr=$errorLog }) | Out-Null
    if ($timedOut) { Write-Host "TIMEOUT $($test.Name) ($($timeoutSeconds)s)" }
    else { Write-Host "EXIT $($test.Name) $exitCode ($([math]::Round($watch.Elapsed.TotalSeconds,1))s)" }
}
$buildExit = $null
if ($BuildFrontend) {
    & (Join-Path $PSScriptRoot 'Build-Frontend.ps1') -Configuration Release -DotNetPath $DotNetPath
    $buildExit = $LASTEXITCODE
}
$stateRoot = Join-Path $repoRoot 'backend\state'
$stateEntries = if (Test-Path $stateRoot) { @(Get-ChildItem $stateRoot -Force -Recurse).Count } else { 0 }
$newTempArtifacts = @(Get-ValidationTempPaths | Where-Object { $_ -notin $tempBefore })
$summary = [pscustomobject]@{ newTempArtifacts = $newTempArtifacts; machine=$env:COMPUTERNAME; completedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); testTimeoutSeconds=$TestTimeoutSeconds; outputReaderFailure=$outputReaderFailure; tests=@($results.ToArray()); failedCount=@($results.ToArray() | Where-Object {$_.exitCode -ne 0 -or $_.timedOut}).Count; buildExitCode=$buildExit; stateEntries=$stateEntries }
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsRoot 'summary.json') -Encoding UTF8
Write-Host "Summary: $ResultsRoot\summary.json"
if ($summary.failedCount -gt 0 -or @($results.ToArray() | Where-Object { $_.leftoverProcesses.Count -gt 0 }).Count -gt 0 -or $outputReaderFailure -or $newTempArtifacts.Count -ne 0 -or $stateEntries -ne 0 -or ($BuildFrontend -and $buildExit -ne 0)) { exit 1 }
