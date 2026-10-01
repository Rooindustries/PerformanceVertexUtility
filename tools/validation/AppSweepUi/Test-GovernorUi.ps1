param([string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference = 'Stop'
if (-not $DotNetPath) {
    $candidate = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    $DotNetPath = if (Test-Path $candidate) { $candidate } else { (Get-Command dotnet.exe -ErrorAction Stop).Source }
}
& $DotNetPath run --project (Join-Path $PSScriptRoot 'AppSweepUi.csproj') --configuration Release -- governor
if ($LASTEXITCODE -ne 0) { throw 'Governor status checks failed' }
