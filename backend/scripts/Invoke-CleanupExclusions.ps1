param(
    [ValidateSet('Status','Save','Check')][string]$Action='Status',
    [string]$InputPath='',
    [string]$ExpectedRevision,
    [string[]]$FileTarget=@(),
    [string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,
    [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($Action -eq 'Save' -and -not $ConfirmApply){throw 'Confirm the new cleanup exclusion list before saving it.'}
$hostDirectory=Join-Path $root 'backend\bin\optimizer'
$hostArgs=@(Join-Path $hostDirectory 'Optimizer.Host.dll')
if(-not $DotNetPath -and (Test-Path -LiteralPath (Join-Path $hostDirectory 'hostpolicy.dll'))){$DotNetPath=Join-Path $hostDirectory 'Optimizer.Host.exe';$hostArgs=@()}
if(-not $DotNetPath){. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1');$DotNetPath=Get-RooIndustriesDevelopmentDotNet $hostDirectory}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$hostDll=Join-Path $root 'backend\bin\optimizer\Optimizer.Host.dll'
if(-not(Test-Path $hostDll)){throw 'Build the cleanup host with backend\scripts\Build-OptimizerHost.ps1 before using exclusions.'}
$request=@{schemaVersion=1;repoRoot=$root}
$coreAction='cleanup-exclusions-'+$Action.ToLowerInvariant()
if($Action -eq 'Save'){
    if(-not $InputPath){throw 'Provide a JSON file containing explicit paths and registry lists.'}
    $request.exclusions=(Read-RooIndustriesOperationJson $InputPath).data
    $request.expectedRevision=if($ExpectedRevision){$ExpectedRevision}else{$null}
    $request.confirm=$true
}
if($Action -eq 'Check'){$request.fileTargets=@($FileTarget)}
$OutputEncoding=[Text.UTF8Encoding]::new($false)
$output=@(($request|ConvertTo-Json -Depth 32)|& $DotNetPath @hostArgs $coreAction '-') -join "`n"
$code=$LASTEXITCODE
$result=$output|ConvertFrom-Json
if($code -ne 0 -or $result.status -ne 'completed'){throw ('Cleanup exclusions failed (exit '+$code+'): '+$result.error.message)}
$output

