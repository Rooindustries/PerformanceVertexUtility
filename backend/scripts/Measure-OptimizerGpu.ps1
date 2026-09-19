param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateRange(1,30)][int]$Blocks=10,
    [ValidateRange(3,60)][int]$Seconds=9,
    [uint32]$VendorId=0x1002,
    [uint32]$DeviceId=0x7550,
    [string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE
)
$ErrorActionPreference='Stop'
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& (Join-Path $PSScriptRoot 'Build-OptimizerHost.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
& $DotNetPath run --project (Join-Path $root 'tools\validation\OptimizerGpuBench\OptimizerGpuBench.csproj') --configuration Release -- $root $DotNetPath ([IO.Path]::GetFullPath($OutputPath)) $Blocks $Seconds $VendorId $DeviceId
exit $LASTEXITCODE
