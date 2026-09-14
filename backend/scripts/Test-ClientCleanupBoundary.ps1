param([string]$DotNetPath = $env:ROO_DOTNET_EXE)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($DotNetPath)) { $DotNetPath = (Get-Command dotnet.exe -ErrorAction Stop).Source }
& $DotNetPath run --project (Join-Path $root 'tools\validation\ClientBoundary\ClientBoundary.csproj') --configuration Release -- $root
if ($LASTEXITCODE -ne 0) { throw "Client cleanup boundary regression failed with exit code $LASTEXITCODE." }
