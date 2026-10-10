param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:ROO_INDUSTRIES_DOTNET_EXE=$DotNetPath
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-exclusion-host-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$policy=Join-Path (Get-RooIndustriesLocalDataRoot) 'cleanup-exclusions.json'
$before=if(Test-Path $policy){[IO.File]::ReadAllBytes($policy)}else{$null}
$ownedRevision=$null
$command=Join-Path $PSScriptRoot 'Invoke-CleanupExclusions.ps1'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
try {
    & (Join-Path $PSScriptRoot 'Build-OptimizerHost.ps1') -DotNetPath $DotNetPath|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cleanup host build failed'}
    $original=(& $command -Action Status -DotNetPath $DotNetPath)|ConvertFrom-Json
    $target=Join-Path $root 'sample\keep'
    [IO.Directory]::CreateDirectory($target)|Out-Null
    $sentinel=Join-Path $target 'data.txt'
    [IO.File]::WriteAllText($sentinel,'independent legacy sentinel')
    $exclusionInput=Join-Path $root 'exclusions.json'
    $exclusions=@{paths=@($original.data.exclusions.paths)+@($sentinel);registry=@($original.data.exclusions.registry)}
    Write-RooIndustriesOperationJson $exclusions $exclusionInput
    $unconfirmed=$false
    try {& $command -Action Save -InputPath $exclusionInput -DotNetPath $DotNetPath|Out-Null} catch {if($_.Exception.Message -notlike '*Confirm the new cleanup exclusion list*'){throw};$unconfirmed=$true}
    Assert $unconfirmed 'Public exclusion updates require explicit confirmation'
    $saved=(& $command -Action Save -InputPath $exclusionInput -ExpectedRevision $original.data.revision -DotNetPath $DotNetPath -ConfirmApply)|ConvertFrom-Json
    $ownedRevision=[string]$saved.data.revision
    Assert ($saved.data.exclusions.paths -contains $sentinel) 'The public command persists the requested exclusion'
    $stale=$false
    try {& $command -Action Save -InputPath $exclusionInput -ExpectedRevision $original.data.revision -DotNetPath $DotNetPath -ConfirmApply|Out-Null}
    catch {if($_.Exception.Message -notlike '*Cleanup exclusions changed*'){throw};$stale=$true}
    Assert ($stale -and (Get-FileHash $policy).Hash -eq $ownedRevision) 'A stale public writer cannot replace the current list'
    $denied=$false
    try {& $command -Action Check -FileTarget @($target) -DotNetPath $DotNetPath|Out-Null}
    catch {if($_.Exception.Message -notlike '*Excluded path:*'){throw};$denied=$true}
    Assert $denied 'Public target checks protect a directory containing an excluded file'
    $allowed=(& $command -Action Check -FileTarget @($target+'-different') -DotNetPath $DotNetPath)|ConvertFrom-Json
    Assert ($allowed.data.allowed -eq $true) 'A distinct sibling prefix remains eligible'

    $officialPath=Join-Path $root 'official.json'
    $manifestPath=Join-Path $root 'manifest.json'
    $scanPath=Join-Path $root 'scan.json'
    $item=@{itemId='folder';type='folder';target=$target;protected=$false;defaultSelected=$true}
    Write-RooIndustriesOperationJson @{status='preview';commands=@(@{appId='fixture:exclusion';executable=$null;blocked=$false;protected=$false;reviewRequired=$false});errors=@()} $officialPath
    Write-RooIndustriesOperationJson @{appId='fixture:exclusion';manifestId='fixture-exclusion';items=@($item);errors=@()} $manifestPath
    Write-RooIndustriesOperationJson @{appId='fixture:exclusion';scanId='fixture-scan';items=@($item);errors=@()} $scanPath
    $manifest=(& (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') -ScanPath $scanPath -ItemId @('folder'))|ConvertFrom-Json
    Assert (@($manifest.errors).Count -eq 1 -and $manifest.errors[0].message -like '*Excluded path:*') 'Legacy manifest creation respects native cleanup exclusions'
    $arguments=@{OfficialPreviewPath=$officialPath;CleanupManifestPath=$manifestPath;ApprovedAppId='fixture:exclusion';ExecutorMode='Real';
        OfficialPreviewSha256=(Get-FileHash $officialPath).Hash;CleanupManifestSha256=(Get-FileHash $manifestPath).Hash;
        ExactTargetAllowlist=@($target);BackupRoot=(Join-Path $root 'backup');RollbackManifestPath=(Join-Path $root 'backup\journal.json');
        ConfirmApply=$true;OfficialUninstallCommandApproved=$true;CleanupDeletionManifestApproved=$true;UserApproved=$true;AllowRealSystemExecution=$true}
    $blocked=(& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupApplyPackage.ps1') @arguments)|ConvertFrom-Json
    Assert ($blocked.status -eq 'failed' -and $blocked.dryRun -and $blocked.errors[0].message -like '*Excluded path:*' -and
        [IO.File]::ReadAllText($sentinel) -eq 'independent legacy sentinel' -and -not(Test-Path $arguments.RollbackManifestPath)) 'Legacy execution cannot bypass the current exclusion list'
} finally {
    if($ownedRevision){
        if(-not(Test-Path $policy) -or (Get-FileHash $policy).Hash -ne $ownedRevision){throw 'Exclusions changed outside this test; current settings were preserved for review'}
        if($null -eq $before){Remove-Item -LiteralPath $policy}else{[IO.File]::WriteAllBytes($policy,$before)}
    }
    if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert ((-not(Test-Path $root)) -and $(if($null -eq $before){-not(Test-Path $policy)}else{[Convert]::ToBase64String([IO.File]::ReadAllBytes($policy)) -ceq [Convert]::ToBase64String($before)})) 'Exclusion validation restores original settings and removes its fixture'
