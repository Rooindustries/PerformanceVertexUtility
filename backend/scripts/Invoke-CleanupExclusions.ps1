param(
    [ValidateSet('Status','Save','Check')][string]$Action='Status',
    [string]$InputPath='',
    [string]$ExpectedRevision,
    [string[]]$FileTarget=@(),
    [string]$DotNetPath=$env:ROO_DOTNET_EXE,
    [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if($Action -eq 'Save' -and -not $ConfirmApply){throw 'Confirm the new cleanup exclusion list before saving it.'}
if(-not $DotNetPath){
    $candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    $DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}
}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$hostDll=Join-Path $root 'backend\bin\optimizer\Optimizer.Host.dll'
if(-not(Test-Path $hostDll)){throw 'Build the cleanup host with backend\scripts\Build-OptimizerHost.ps1 before using exclusions.'}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('roo-cleanup-exclusions-'+[Guid]::NewGuid().ToString('N'))
try {
    $request=@{schemaVersion=1;repoRoot=$root}
    $coreAction='cleanup-exclusions-'+$Action.ToLowerInvariant()
    if($Action -eq 'Save'){
        if(-not $InputPath){throw 'Provide a JSON file containing explicit paths and registry lists.'}
        $request.exclusions=(Read-RooOperationJson $InputPath).data
        $request.expectedRevision=if($ExpectedRevision){$ExpectedRevision}else{$null}
        $request.confirm=$true
    }
    if($Action -eq 'Check'){$request.fileTargets=@($FileTarget)}
    $path=Join-Path $scratch 'request.json'
    Write-RooOperationJson $request $path
    $output=@(& $DotNetPath $hostDll $coreAction $path) -join "`n"
    $code=$LASTEXITCODE
    $result=$output|ConvertFrom-Json
    if($code -ne 0 -or $result.status -ne 'completed'){throw ('Cleanup exclusions failed (exit '+$code+'): '+$result.error.message)}
    $output
} finally {
    if(Test-Path $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}
}
