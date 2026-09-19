param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateSet('all','branding','operation-files','files','registry','policies','discovery','cleanup','batch','firmware')][string]$Area='all')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($DotNetPath)){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$arguments=@('run','--project',(Join-Path $root 'tools\validation\OptimizerCore\OptimizerCore.csproj'),'--configuration','Release')
if($Area -ne 'all'){$arguments+=@('--',('--'+$Area))}
& $DotNetPath @arguments
exit $LASTEXITCODE
