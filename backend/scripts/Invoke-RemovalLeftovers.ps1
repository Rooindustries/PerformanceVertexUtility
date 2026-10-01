param(
    [ValidateSet('Scan','Preview','Apply','Restore')][string]$Action='Scan',
    [Parameter(Mandatory=$true)][string]$QueueJournalPath,
    [Parameter(Mandatory=$true)][string]$AppId,
    [string[]]$ItemId=@(),
    [string]$ReviewPath='', [string]$ReviewSha256='',
    [string]$OutputPath='', [switch]$ConfirmApply, [switch]$ManualReviewApproved
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$result=[pscustomobject]@{schemaVersion=1;actionId='apps.removalLeftovers.'+$Action.ToLowerInvariant();status='failed';dryRun=$true;data=$null;errors=@()}
$scratch=$null
try {
    Assert-RooIndustriesDistinctOperationPaths @($QueueJournalPath,$ReviewPath,$OutputPath)
    $queue=(Read-RooIndustriesOperationJson $QueueJournalPath).data
    if($queue.kind -ne 'bulk-uninstall-journal'){throw 'A bulk removal journal is required.'}
    Assert-RooIndustriesOperationOwner $queue.plan.owner
    $entries=@($queue.plan.entries|Where-Object {$_.appId -ceq $AppId})
    $states=@($queue.entries|Where-Object {$_.appId -ceq $AppId})
    if($entries.Count -ne 1 -or $states.Count -ne 1){throw 'App identity is not unique in the removal journal.'}
    $entry=$entries[0];$state=$states[0]
    if($entry.protected -or -not $state.registrationAbsent -or $state.state -notin @('removed','already-absent')){throw 'Official removal must be reconciled before leftover cleanup.'}
    if(Test-RooIndustriesBulkAppPresent $entry.identity ([string]$queue.plan.fixtureRoot)){throw 'The app registration is present again. Review the current installation instead.'}
    if($Action -in @('Scan','Preview')) {
        if($null -eq $entry.appSnapshot){throw 'This older queue has no saved app metadata for a post-removal scan.'}
        $scratch=Join-Path (Split-Path ([IO.Path]::GetFullPath($QueueJournalPath)) -Parent) ('leftover-discovery-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($scratch)|Out-Null
        $inventoryPath=Join-Path $scratch 'inventory.json';$scanPath=Join-Path $scratch 'scan.json'
        Write-RooIndustriesOperationJson @{schemaVersion=1;apps=@($entry.appSnapshot)} $inventoryPath
        $scan=(& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -AppId $AppId -InventoryPath $inventoryPath -OutputPath $scanPath)|ConvertFrom-Json
        if(@($scan.errors).Count -gt 0){throw (@($scan.errors|ForEach-Object {$_.message}) -join ' ')}
        if($Action -eq 'Scan') {$result.data=$scan;$result.status='preview'}
        else {
            if(-not $OutputPath -or $ItemId.Count -eq 0 -or @($ItemId|Select-Object -Unique).Count -ne $ItemId.Count){throw 'Preview requires an output path and explicit, distinct leftover item IDs.'}
            foreach($id in $ItemId){
                $matches=@($scan.items|Where-Object {$_.itemId -ceq $id -and -not $_.protected -and $_.type -in @('file','folder')})
                if($matches.Count -ne 1){throw 'A selected leftover is unavailable, protected or not a file/folder.'}
            }
            $directory=Join-Path (Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent) ('files-'+[guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($directory)|Out-Null
            $manifestPath=Join-Path $directory 'manifest.json';$officialPath=Join-Path $directory 'official.json'
            $manifest=(& (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') -ScanPath $scanPath -ItemId $ItemId -OutputPath $manifestPath)|ConvertFrom-Json
            if(@($manifest.errors).Count -gt 0){throw 'The selected cleanup manifest could not be built.'}
            $official=@{schemaVersion=1;status='preview';commands=@(@{appId=$AppId;displayName=$entry.displayName;executable=$null;blocked=$false;protected=$false;reviewRequired=[bool]$entry.reviewRequired});errors=@()}
            Write-RooIndustriesOperationJson $official $officialPath
            $result.data=[pscustomobject]@{queueId=$queue.plan.queueId;appId=$AppId;displayName=$entry.displayName;items=@($manifest.items);
                requiresReview=[bool]$entry.reviewRequired;manifestPath=$manifestPath;manifestSha256=(Get-FileHash $manifestPath).Hash;
                officialPath=$officialPath;officialSha256=(Get-FileHash $officialPath).Hash;backupRoot=(Join-Path $directory 'backup');rollbackPath=(Join-Path $directory 'rollback.json')}
            $result.status='preview'
        }
    } else {
        if(-not $ReviewPath -or $ReviewSha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'The reviewed cleanup preview and its SHA-256 are required.'}
        $review=(Read-RooIndustriesOperationJson $ReviewPath $ReviewSha256).data
        $data=$review.data
        if($review.status -ne 'preview' -or $review.actionId -ne 'apps.removalLeftovers.preview' -or $data.appId -cne $AppId -or $data.queueId -cne $queue.plan.queueId){throw 'Cleanup review does not belong to this app and queue.'}
        if($Action -eq 'Apply') {
            $args=@{OfficialPreviewPath=$data.officialPath;CleanupManifestPath=$data.manifestPath;ApprovedAppId=$AppId;
                OfficialPreviewSha256=$data.officialSha256;CleanupManifestSha256=$data.manifestSha256;ExactTargetAllowlist=@($data.items|ForEach-Object {$_.target});
                BackupRoot=$data.backupRoot;RollbackManifestPath=$data.rollbackPath;OfficialUninstallCommandApproved=$true;CleanupDeletionManifestApproved=$true;
                ManualReviewApproved=[bool]$ManualReviewApproved;ConfirmApply=[bool]$ConfirmApply;UserApproved=[bool]$ConfirmApply;AllowRealSystemExecution=[bool]$ConfirmApply;
                ExecutorMode=if($ConfirmApply){'Real'}else{'Preview'}}
            $applied=(& (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupApplyPackage.ps1') @args)|ConvertFrom-Json
        } else {
            if($ConfirmApply -and -not (Test-RooIndustriesWrittenAfterProtection ([string]$data.rollbackPath))){throw ("This backup was made by an earlier version of the app, before its data folder was protected, so it can't be restored automatically. Its files are kept at "+(Split-Path ([string]$data.rollbackPath) -Parent)+'.')}
            $applied=(& (Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1') -RollbackManifestPath $data.rollbackPath -ConfirmApply:$ConfirmApply -AllowRealSystemExecution:$ConfirmApply -UserApproved:$ConfirmApply)|ConvertFrom-Json
        }
        $result.status=$applied.status;$result.dryRun=$applied.dryRun;$result.data=$applied
        $result.errors=@($applied.errors)
    }
} catch {$result.errors=@([pscustomobject]@{code='REMOVAL_LEFTOVERS_REJECTED';message=$_.Exception.Message})}
finally {if($scratch -and (Test-Path -LiteralPath $scratch)){Remove-Item -LiteralPath $scratch -Recurse -Force}}
if($OutputPath -and [IO.Path]::GetFullPath($OutputPath) -ine [IO.Path]::GetFullPath($QueueJournalPath) -and (-not $ReviewPath -or [IO.Path]::GetFullPath($OutputPath) -ine [IO.Path]::GetFullPath($ReviewPath))){Write-RooIndustriesOperationJson $result $OutputPath}
$result|ConvertTo-Json -Depth 32
if($result.status -eq 'failed'){exit 1}
