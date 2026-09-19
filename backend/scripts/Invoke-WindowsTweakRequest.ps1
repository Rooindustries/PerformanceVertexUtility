param(
    [Parameter(Mandatory=$true)][ValidateSet('Preview','Apply','Restore')][string]$Action,
    [string]$RequestPath='', [switch]$ConfirmApply, [string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not $RequestPath){
    if($Action -ne 'Preview'){throw 'RequestPath is required.'}
    & (Join-Path $PSScriptRoot 'Invoke-WindowsTweaks.ps1') -Action Catalog -DotNetPath $DotNetPath
    return
}
if($Action -ne 'Preview' -and -not $ConfirmApply){throw 'This action requires ConfirmApply.'}
$RequestPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RequestPath)
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
$hostPath=Join-Path $root 'backend/bin/optimizer/Optimizer.Host.dll'
if(-not(Test-Path $hostPath)){throw 'Build the optimizer helper with backend/scripts/Build-OptimizerHost.ps1 first.'}
& $DotNetPath $hostPath ('tweak-'+$Action.ToLowerInvariant()) $RequestPath $root
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
