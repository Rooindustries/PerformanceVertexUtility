param(
    [string]$Configuration = 'Debug',
    [string]$DotNetPath = $env:ROO_DOTNET_EXE
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$projectPath = Join-Path $repoRoot 'docs\internal\frontend\Roo.OptimizationSuite.App\Roo.OptimizationSuite.App.csproj'

function Resolve-DotNetSdk {
    param([string]$RequestedPath)

    $candidatePaths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidatePaths.Add($RequestedPath) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidatePaths.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')) | Out-Null
    }

    $command = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($command) {
        $candidatePaths.Add($command.Source) | Out-Null
    }

    foreach ($candidate in $candidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        $sdks = & $candidate --list-sdks 2>$null
        if ($LASTEXITCODE -eq 0 -and @($sdks).Count -gt 0) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'No dotnet executable with an installed SDK was found. Set ROO_DOTNET_EXE or pass -DotNetPath to a dotnet.exe that has an SDK.'
}

if (-not (Test-Path -LiteralPath $projectPath)) {
    throw "Frontend project not found: $projectPath"
}

$dotnet = Resolve-DotNetSdk -RequestedPath $DotNetPath
Write-Host "Using dotnet SDK host: $dotnet"
& $dotnet publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration $Configuration --self-contained false -o (Join-Path $repoRoot 'backend\bin\optimizer')
if ($LASTEXITCODE -ne 0) { throw 'The optimizer helper build failed.' }
& $dotnet build $projectPath --configuration $Configuration -p:Platform=x64
exit $LASTEXITCODE
