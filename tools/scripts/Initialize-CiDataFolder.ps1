param([string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference = 'Stop'
$disposableRunner = $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -or $env:RUNNER_NAME -like 'blacksmith-*'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $disposableRunner -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This script protects the app data folder only on disposable GitHub-hosted or Blacksmith runners.'
}
if ([string]::IsNullOrWhiteSpace($DotNetPath)) { $DotNetPath = (Get-Command dotnet.exe -ErrorAction Stop).Source }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hostRoot = Join-Path $env:RUNNER_TEMP ('optimizer-host-' + [Guid]::NewGuid().ToString('N'))
& (Join-Path $repoRoot 'backend\scripts\Build-OptimizerHost.ps1') -DotNetPath $DotNetPath -OutputPath $hostRoot
if ($LASTEXITCODE -ne 0) { throw 'The optimizer host build failed.' }
$request = @{ schemaVersion = 1; repoRoot = $repoRoot; confirm = $true } | ConvertTo-Json -Compress
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $reply = (@($request | & $DotNetPath (Join-Path $hostRoot 'Optimizer.Host.dll') 'data-secure' '-' 2>&1) | ForEach-Object { [string]$_ }) -join "`n" }
finally { $ErrorActionPreference = $previous }
$result = try { $reply | ConvertFrom-Json } catch { $null }
if ($null -eq $result -or $result.status -ne 'completed') { throw ('The app data folder could not be protected: ' + $reply) }
Write-Host ('Protected app data folder: ' + $result.data.root)
