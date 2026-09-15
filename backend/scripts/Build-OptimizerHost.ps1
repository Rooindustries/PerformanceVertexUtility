param([string]$DotNetPath=$env:ROO_DOTNET_EXE,[string]$OutputPath='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($DotNetPath)){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $OutputPath){$OutputPath=Join-Path $root 'backend\bin\optimizer'}
& $DotNetPath publish (Join-Path $root 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $OutputPath
exit $LASTEXITCODE
