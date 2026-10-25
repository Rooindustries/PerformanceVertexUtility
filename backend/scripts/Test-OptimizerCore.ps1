param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateSet('all','branding','data-folder','operation-files','files','registry','policies','discovery','path-spelling','cleanup','batch','firmware','control-reads','process-controls')][string]$Area='all',[string[]]$Scenario=@(),[string]$Evidence='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($DotNetPath)){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$arguments=@('run','--project',(Join-Path $root 'tools\validation\OptimizerCore\OptimizerCore.csproj'),'--configuration','Release')
if($Area -in 'all','data-folder','operation-files','files'){$arguments+='-p:GovernorTestHooks=true'}
if($Area -ne 'all'){$arguments+=@('--',('--'+$Area))+$Scenario}
if($Evidence){
    New-Item -ItemType Directory -Force -Path (Split-Path $Evidence -Parent)|Out-Null
    & $DotNetPath @arguments 2>&1|Tee-Object -FilePath $Evidence
} else {& $DotNetPath @arguments}
exit $LASTEXITCODE
