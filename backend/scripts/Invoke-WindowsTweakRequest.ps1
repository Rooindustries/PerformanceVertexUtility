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
$hostPath=Join-Path $root 'backend/bin/optimizer/Optimizer.Host.dll'
if(-not(Test-Path $hostPath)){throw 'Build the optimizer helper with backend/scripts/Build-OptimizerHost.ps1 first.'}
$hostArgs=@($hostPath)
if(-not $DotNetPath -and (Test-Path -LiteralPath (Join-Path (Split-Path $hostPath -Parent) 'hostpolicy.dll'))){$DotNetPath=Join-Path (Split-Path $hostPath -Parent) 'Optimizer.Host.exe';$hostArgs=@()}
if(-not $DotNetPath){. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1');$DotNetPath=Get-RooIndustriesDevelopmentDotNet (Split-Path $hostPath -Parent)}
$OutputEncoding=[Text.UTF8Encoding]::new($false)
[IO.File]::ReadAllText($RequestPath,[Text.UTF8Encoding]::new($false))|& $DotNetPath @hostArgs ('tweak-'+$Action.ToLowerInvariant()) '-' $root
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
