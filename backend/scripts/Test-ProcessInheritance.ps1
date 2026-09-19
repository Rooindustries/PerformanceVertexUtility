param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$project=Join-Path $root 'tools\validation\ProcessInheritance\ProcessInheritance.csproj'
& $DotNetPath build $project --configuration Release -t:Rebuild
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
& $DotNetPath run --project $project --configuration Release --no-build
exit $LASTEXITCODE
