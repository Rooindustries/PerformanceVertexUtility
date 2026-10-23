param(
    [Parameter(Mandatory = $true)][string]$OutRoot,
    [string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Timer startup validation requires Windows.' }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Split-Path $root -Parent
if (-not $DotNetPath) {
    $candidate = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    $DotNetPath = if (Test-Path -LiteralPath $candidate) { $candidate } else { (Get-Command dotnet.exe -ErrorAction Stop).Source }
}
if (Test-Path -LiteralPath $OutRoot) { throw 'The timer startup evidence directory must be new.' }
[void][IO.Directory]::CreateDirectory($OutRoot)
$build = Join-Path $OutRoot 'host'
try {
    & $DotNetPath publish (Join-Path $root 'tools\validation\Tweaks\Tweaks.csproj') --configuration Release --runtime win-x64 --self-contained true -p:TimerStartupFixture=true -p:UseSharedCompilation=false --output $build 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'publish.log')
    if ($LASTEXITCODE -ne 0) { throw 'The timer startup fixture host did not publish.' }
    & (Join-Path $build 'Optimizer.Host.exe') $root --timer-startup-fixture (Join-Path $OutRoot 'proof') 2>&1 | Tee-Object -FilePath (Join-Path $OutRoot 'checks.log')
    if ($LASTEXITCODE -ne 0) { throw 'Timer startup checks failed.' }
} finally {
    if (Test-Path -LiteralPath $build) { [IO.Directory]::Delete($build, $true) }
}
