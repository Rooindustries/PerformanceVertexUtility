param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$ReferenceGovernorPath,
    [Parameter(Mandatory=$true)][string]$RecoveryHeartbeatPath,
    [ValidateRange(1,30)][int]$Blocks=10,
    [ValidateRange(3,60)][int]$Seconds=9,
    [string]$DotNetPath=$env:ROO_DOTNET_EXE
)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputPath){throw 'Choose a new result path for this experiment.'}
if((Get-Service ProcessGovernor).Status -ne 'Stopped'){throw 'The installed governor must be stopped under an approved recovery guard before comparison.'}
if(-not(Test-Path -LiteralPath $RecoveryHeartbeatPath -PathType Leaf)){throw 'The active service-recovery heartbeat is missing.'}
if((Get-AuthenticodeSignature -LiteralPath $ReferenceGovernorPath).Status -ne 'Valid' -or
    (Get-FileHash -LiteralPath $ReferenceGovernorPath -Algorithm SHA256).Hash -ne 'EA338D4C47F61BB3AA107A26DE3614D112F19DA9438291B3A8212F21BB01D495'){
    throw 'Provide the verified signed Process Lasso 18.3.0.34 governor.'
}
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
[IO.File]::SetLastWriteTimeUtc($RecoveryHeartbeatPath,[DateTime]::UtcNow)
& (Join-Path $PSScriptRoot 'Build-OptimizerHost.ps1') -DotNetPath $DotNetPath
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
$project=Join-Path $root 'tools\validation\OptimizerBench\OptimizerBench.csproj'
& $DotNetPath build $project --configuration Release -t:Rebuild
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
[IO.File]::SetLastWriteTimeUtc($RecoveryHeartbeatPath,[DateTime]::UtcNow)
& $DotNetPath run --no-build --project $project --configuration Release -- --cpu-reference-measure $root $DotNetPath ([IO.Path]::GetFullPath($OutputPath)) $Blocks $Seconds ([IO.Path]::GetFullPath($ReferenceGovernorPath)) ([IO.Path]::GetFullPath($RecoveryHeartbeatPath))
exit $LASTEXITCODE
