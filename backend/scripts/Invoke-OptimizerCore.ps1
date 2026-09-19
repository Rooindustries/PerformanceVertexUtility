param(
    [Parameter(Mandatory=$true)][ValidateSet('protected-session-preview','protected-session-check','protected-session-run','protected-session-status','protected-session-stop','protected-session-affinity','protected-session-recover','protected-session-watch','process-status','process-preview','process-apply','process-restore','rules-list','rule-save','rule-delete','policy-run','policy-stop','policy-status',
        'cleanup-authority','cleanup-scan','cleanup-preview','cleanup-apply','cleanup-restore','cleanup-batch-preview','cleanup-batch-apply','cleanup-batch-cancel','cleanup-batch-restore')][string]$Action,
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,
    [string]$HostDirectory=''
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $HostDirectory){$HostDirectory=Join-Path $root 'backend\bin\optimizer'}
$hostDll=Join-Path $HostDirectory 'Optimizer.Host.dll'
if(-not(Test-Path -LiteralPath $hostDll)){throw 'Build the optimizer host with Build-OptimizerHost.ps1 before invoking this endpoint.'}
if(-not $DotNetPath){
    $candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    if(Test-Path -LiteralPath $candidate){$DotNetPath=$candidate}else{$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
& $DotNetPath $hostDll $Action ([IO.Path]::GetFullPath($RequestPath))
exit $LASTEXITCODE
