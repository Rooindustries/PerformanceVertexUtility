param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:ROO_INDUSTRIES_DOTNET_EXE=$DotNetPath
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-exclusion-host-'+[Guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source\backend'
$scripts=Join-Path $source 'scripts'
$policy=Join-Path $root 'cleanup-exclusions.json'
$command=Join-Path $scripts 'Invoke-CleanupExclusions.ps1'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
try {
    [IO.Directory]::CreateDirectory($source)|Out-Null
    $backend=Split-Path $PSScriptRoot -Parent
    foreach($folder in 'scripts','profiles','uninstall'){
        Copy-Item -LiteralPath (Join-Path $backend $folder) -Destination (Join-Path $source $folder) -Recurse
    }
    $project=Join-Path $backend 'native\Optimizer.Host\Optimizer.Host.csproj'
    $hostOutput=Join-Path $source 'bin\optimizer'
    & $DotNetPath publish $project -c Release --self-contained false -p:GovernorTestHooks=true -o $hostOutput|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cleanup host build failed'}
    $env:ROO_INDUSTRIES_TEST_CLEANUP_EXCLUSIONS=$policy
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
    $manifest=(& (Join-Path $scripts 'New-CleanupDeletionManifest.ps1') -ScanPath $scanPath -ItemId @('folder'))|ConvertFrom-Json
    Assert (@($manifest.errors).Count -eq 1 -and $manifest.errors[0].message -like '*Excluded path:*') 'Legacy manifest creation respects native cleanup exclusions'
    $arguments=@{OfficialPreviewPath=$officialPath;CleanupManifestPath=$manifestPath;ApprovedAppId='fixture:exclusion';ExecutorMode='Real';
        OfficialPreviewSha256=(Get-FileHash $officialPath).Hash;CleanupManifestSha256=(Get-FileHash $manifestPath).Hash;
        ExactTargetAllowlist=@($target);BackupRoot=(Join-Path $root 'backup');RollbackManifestPath=(Join-Path $root 'backup\journal.json');
        ConfirmApply=$true;OfficialUninstallCommandApproved=$true;CleanupDeletionManifestApproved=$true;UserApproved=$true;AllowRealSystemExecution=$true}
    $blocked=(& (Join-Path $scripts 'Invoke-UninstallCleanupApplyPackage.ps1') @arguments)|ConvertFrom-Json
    Assert ($blocked.status -eq 'failed' -and $blocked.dryRun -and $blocked.errors[0].message -like '*Excluded path:*' -and
        [IO.File]::ReadAllText($sentinel) -eq 'independent legacy sentinel' -and -not(Test-Path $arguments.RollbackManifestPath)) 'Legacy execution cannot bypass the current exclusion list'
} finally {
    Remove-Item Env:\ROO_INDUSTRIES_TEST_CLEANUP_EXCLUSIONS -ErrorAction SilentlyContinue
    if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path $root)) 'Exclusion validation removes its fixture and its exclusion list'
