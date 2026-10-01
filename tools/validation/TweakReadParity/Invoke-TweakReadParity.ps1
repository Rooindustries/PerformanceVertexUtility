param(
    [string]$DotNetPath,
    [string]$OutDir = (Join-Path $env:TEMP 'roo-industries-tweak-read-parity'),
    [ValidateSet('parity', 'kill', 'suspend', 'chunk', 'partial', 'detect')][string[]]$Mode = @('parity', 'kill', 'suspend', 'chunk', 'partial', 'detect')
)
$ErrorActionPreference = 'Stop'
if (-not $DotNetPath) { $candidate = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'; $DotNetPath = if (Test-Path $candidate) { $candidate } else { (Get-Command dotnet.exe -ErrorAction Stop).Source } }
$root = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$bin = Join-Path $OutDir 'bin'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
& $DotNetPath build (Join-Path $PSScriptRoot 'TweakReadParity.csproj') -c Release -o $bin -v q
if ($LASTEXITCODE -ne 0) { throw 'TweakReadParity did not build.' }
$failed = 0
foreach ($name in $Mode) {
    $log = Join-Path $OutDir "parity-$name.out"
    & $DotNetPath (Join-Path $bin 'TweakReadParity.dll') $root (Join-Path $OutDir "data-$name") $name 1500 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
exit $failed
