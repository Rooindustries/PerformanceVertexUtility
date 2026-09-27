$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$claimPath = Get-RooIndustriesBulkClaimPath ([pscustomobject]@{appId='fixture:app'})
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-uninstall-apply-package-' + [guid]::NewGuid().ToString('N'))
$applyScript = Join-Path $PSScriptRoot 'Invoke-UninstallCleanupApplyPackage.ps1'
$restoreScript = Join-Path $PSScriptRoot 'Restore-UninstallCleanupExecution.ps1'
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
function Write-Input($Value, $Path) { $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Read-Result($Output) { ($Output -join [Environment]::NewLine) | ConvertFrom-Json }
function New-Case([string]$Name) {
    $root = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'cache\nested') -Force | Out-Null
    Set-Content (Join-Path $root 'cache\nested\data.txt') 'original cache'
    Set-Content (Join-Path $root 'loose.txt') 'original file'
    $targets = @((Join-Path $root 'cache'), (Join-Path $root 'loose.txt'))
    $official = @{ actionId='apps.previewOfficialUninstall'; status='preview'; commands=@(@{appId='fixture:app'; executable=$null; blocked=$false; protected=$false; reviewRequired=$false}); errors=@() }
    $manifest = @{ appId='fixture:app'; manifestId=$Name; displayName='Fixture'; errors=@(); items=@(
        @{itemId='cache'; type='folder'; target=$targets[0]; protected=$false},
        @{itemId='file'; type='file'; target=$targets[1]; protected=$false}
    ) }
    $officialPath=Join-Path $root 'official.json'; $manifestPath=Join-Path $root 'cleanup.json'
    Write-Input $official $officialPath; Write-Input $manifest $manifestPath
    $args = @{OfficialPreviewPath=$officialPath; CleanupManifestPath=$manifestPath; ApprovedAppId='fixture:app'; ExecutorMode='Real';
        ExactTargetAllowlist=$targets; BackupRoot=(Join-Path $root 'backup'); RollbackManifestPath=(Join-Path $root 'backup\rollback.json');
        ConfirmApply=$true; OfficialUninstallCommandApproved=$true; CleanupDeletionManifestApproved=$true; UserApproved=$true; AllowRealSystemExecution=$true;
        OfficialPreviewSha256=(Get-FileHash $officialPath -Algorithm SHA256).Hash; CleanupManifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash }
    return @{root=$root; targets=$targets; official=$official; manifest=$manifest; args=$args}
}
function New-HandoffCase([string]$Name, [string]$Mode) {
    $case = New-Case $Name
    $case.remover = Join-Path $case.root 'remover state'
    $case.official.commands[0].executable = $handoffExe
    $case.official.commands[0].arguments = @($case.remover, $Mode)
    $case.args.AllowedOfficialExecutablePath = $handoffExe; Refresh-Hashes $case
    return $case
}
function Refresh-Hashes($Case) {
    Write-Input $Case.official $Case.args.OfficialPreviewPath; Write-Input $Case.manifest $Case.args.CleanupManifestPath
    $Case.args.OfficialPreviewSha256=(Get-FileHash $Case.args.OfficialPreviewPath -Algorithm SHA256).Hash
    $Case.args.CleanupManifestSha256=(Get-FileHash $Case.args.CleanupManifestPath -Algorithm SHA256).Hash
}
try {
    $case=New-Case 'preview'; $a=$case.args
    $preview=Read-Result (& $applyScript -OfficialPreviewPath $a.OfficialPreviewPath -CleanupManifestPath $a.CleanupManifestPath)
    Assert ($preview.status -eq 'preview' -and (Test-Path $case.targets[0]) -and -not (Test-Path $a.BackupRoot)) 'Default preview writes no backup or deletion state'
    Assert ($preview.approval.officialPreviewSha256 -eq $a.OfficialPreviewSha256) 'Preview binds approval to the exact input bytes'
    $vanished=New-Case 'targets-disappeared'; $vanishedArgs=$vanished.args
    $reviewArgs=$vanishedArgs.Clone(); $reviewArgs.ExecutorMode='Preview'; $reviewArgs.ConfirmApply=$false
    $reviewed=Read-Result (& $applyScript @reviewArgs)
    Assert ($reviewed.status -eq 'preview' -and $reviewed.summary.approvalReady) 'Vanishing-target case begins with an approved preview'
    Remove-Item -LiteralPath $vanished.targets -Recurse -Force
    $unchanged=Read-Result (& $applyScript @vanishedArgs)
    Assert ($unchanged.status -eq 'success' -and -not $unchanged.dryRun -and $unchanged.summary.deletedCount -eq 0 -and -not $unchanged.summary.restoreReady) 'Targets missing at apply produce a confirmed no-op without invented recovery'
    foreach ($scenario in @('missing-allowlist','wrong-app','mixed-app','stale-hash','manual-review','preview-error','overlap','backup-inside-target','duplicate-id','unsupported-type')) {
        $case=New-Case $scenario; $a=$case.args
        switch ($scenario) {
            'missing-allowlist' {$a.ExactTargetAllowlist=@()}
            'wrong-app' {$a.ApprovedAppId='other'}
            'mixed-app' {$case.official.commands[0].appId='other'; Refresh-Hashes $case}
            'stale-hash' {$a.CleanupManifestSha256='old-hash'}
            'manual-review' {$case.official.commands[0].reviewRequired=$true; Refresh-Hashes $case}
            'preview-error' {$case.official.errors=@(@{code='FAILED'}); Refresh-Hashes $case}
            'overlap' {$case.manifest.items[1].target=Join-Path $case.targets[0] 'nested\data.txt'; $a.ExactTargetAllowlist=@($case.targets[0],$case.manifest.items[1].target); Refresh-Hashes $case}
            'backup-inside-target' {$a.BackupRoot=Join-Path $case.targets[0] 'backup'}
            'duplicate-id' {$case.manifest.items[1].itemId='cache'; Refresh-Hashes $case}
            'unsupported-type' {$case.manifest.items[1].type='registryKey'; Refresh-Hashes $case}
        }
        $result=Read-Result (& $applyScript @a)
        Assert ($result.status -eq 'blocked' -and $result.dryRun -and (Test-Path $case.targets[0]) -and (Test-Path $case.targets[1]) -and -not (Test-Path $a.RollbackManifestPath)) "Invalid $scenario input cannot delete or create recovery state"
    }
    $case=New-Case 'success'; $a=$case.args
    $case.official.commands[0].reviewRequired=$true; Refresh-Hashes $case; $a.ManualReviewApproved=$true
    $result=Read-Result (& $applyScript @a)
    if ($result.status -ne 'success') { Write-Host ($result | ConvertTo-Json -Depth 12) }
    Assert ($result.status -eq 'success' -and -not $result.dryRun -and $result.summary.deletedCount -eq 2 -and $result.summary.restoreReady) 'Approved dependency review permits backed-up file and folder execution'
    $journal=Get-Content $a.RollbackManifestPath -Raw | ConvertFrom-Json
    Assert ($journal.fileBackups.Count -eq 2 -and $journal.fileBackups[0].deleteAttempted) 'Durable journal records originals and attempted deletion'
    $again=Read-Result (& $applyScript @a)
    Assert ($again.executionReused -and $again.summary.deletedCount -eq 2) 'Duplicate apply reuses the saved operation without executing again'
    1..2 | ForEach-Object {
        $restore=Read-Result (& $restoreScript -RollbackManifestPath $a.RollbackManifestPath -ConfirmApply -AllowRealSystemExecution -UserApproved)
        Assert ($restore.status -eq 'success' -and (Get-Content (Join-Path $case.targets[0] 'nested\data.txt') -Raw).Trim() -eq 'original cache' -and (Get-Content $case.targets[1] -Raw).Trim() -eq 'original file') "Restore attempt $_ returns the exact original contents"
        Assert (@(Get-ChildItem $case.targets[0] -Recurse -File).Count -eq 1) 'Repeated folder restore does not nest backup folders'
    }
    $case=New-Case 'partial'; $a=$case.args
    $held=[IO.File]::Open($case.targets[1],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $partial=Read-Result (& $applyScript @a) } finally { $held.Dispose() }
    Assert ($partial.status -eq 'partial' -and -not $partial.dryRun -and $partial.summary.deletedCount -eq 1 -and $partial.summary.restoreReady) 'A locked second target preserves the first deletion and recovery details'
    $partialJournal=Get-Content $a.RollbackManifestPath -Raw | ConvertFrom-Json
    Assert ($partialJournal.fileBackups[1].deleteAttempted -and -not $partialJournal.fileBackups[1].deleted) 'Failed deletion remains distinguishable from successful deletion'
    $retry=Read-Result (& $applyScript @a)
    Assert ($retry.executionReused -and $retry.status -eq 'partial' -and (Test-Path $case.targets[1])) 'Retry of an incomplete operation cannot silently delete more files'
    $restored=Read-Result (& $restoreScript -RollbackManifestPath $a.RollbackManifestPath -ConfirmApply -AllowRealSystemExecution -UserApproved)
    Assert ($restored.status -eq 'success' -and (Test-Path (Join-Path $case.targets[0] 'nested\data.txt'))) 'Partial execution can be recovered through the normal restore command'
    $case=New-Case 'concurrent'; $a=$case.args
    New-Item -ItemType Directory -Path $a.BackupRoot | Out-Null
    $held=[IO.File]::Open($a.RollbackManifestPath+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $blocked=Read-Result (& $applyScript @a) } finally { $held.Dispose() }
    Assert ($blocked.status -eq 'failed' -and $blocked.dryRun -and (Test-Path $case.targets[0])) 'Concurrent operation lock fails before mutation'
    $case=New-Case 'vendor-changes-content'; $a=$case.args
    $vendorExe=Join-Path $case.root 'Roo Industries Vendor Fixture.exe'
    Add-Type -TypeDefinition 'using System.IO; public class RooIndustriesVendorFixture {public static int Main(string[] args) {File.WriteAllText(Path.Combine(args[0],"nested","data.txt"),"changed by vendor"); File.WriteAllText(Path.Combine(args[0],"new user file.txt"),"created during removal"); return 0;}}' -OutputAssembly $vendorExe -OutputType ConsoleApplication
    $case.official.commands[0].executable=$vendorExe
    $case.official.commands[0].arguments=@($case.targets[0])
    $a.AllowedOfficialExecutablePath=$vendorExe; Refresh-Hashes $case
    $review=Read-Result (& $applyScript @a)
    if ($review.status -ne 'cleanup-review-required' -or -not $review.summary.officialRunnerCompleted -or $review.summary.restoreReady -or $review.summary.deletedCount -ne 0) {Write-Host ($review|ConvertTo-Json -Depth 20)}
    Assert ($review.status -eq 'cleanup-review-required' -and $review.summary.officialRunnerCompleted -and $review.summary.deletedCount -eq 0 -and -not $review.summary.restoreReady) 'Vendor removal invalidates the old cleanup approval and creates no misleading file rollback'
    Assert ((Get-Content (Join-Path $case.targets[0] 'nested\data.txt') -Raw) -eq 'changed by vendor' -and (Test-Path (Join-Path $case.targets[0] 'new user file.txt'))) 'Changed and newly created vendor-stage files survive the earlier cleanup list'
    Assert ($review.postUninstallReview.reviewRequired -and @($review.postUninstallReview.targets[0].entries | Where-Object {$_.path -like '*new user file.txt' -and $_.sha256}).Count -eq 1) 'A fresh post-vendor scan returns current content hashes for separate review'
    $replay=Read-Result (& $applyScript @a)
    Assert ($replay.executionReused -and $replay.status -eq 'cleanup-review-required' -and $replay.executionSequence.Count -eq 0) 'Replaying vendor completion neither relaunches it nor deletes leftovers'
    $handoffExe = Join-Path $tempRoot 'Roo Industries Handoff Fixture.exe'
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public class RooIndustriesHandoffFixture {
    public static int Main(string[] args) {
        if(args[1]=="child"){Thread.Sleep(3000);File.WriteAllText(args[0]+".done","finished");return 0;}
        if(args[1]=="child-hang"){Thread.Sleep(120000);return 0;}
        File.AppendAllText(args[0]+".launches","launched"+Environment.NewLine);
        if(args[1]=="hang"){Thread.Sleep(120000);return 0;}
        string copy=Path.Combine(Path.GetDirectoryName(args[0]),"temp copy\\~nsu1.tmp\\Au_.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(copy));
        File.Copy(System.Reflection.Assembly.GetEntryAssembly().Location,copy,true);
        ProcessStartInfo start=new ProcessStartInfo(copy,"\""+args[0]+"\" "+(args[1]=="handoff"?"child":"child-hang"));
        start.UseShellExecute=true;start.WindowStyle=ProcessWindowStyle.Hidden;
        Process.Start(start).Dispose();
        return 0;
    }
}
'@ -OutputAssembly $handoffExe -OutputType ConsoleApplication
    $case=New-HandoffCase 'handoff' 'handoff'; $a=$case.args
    $handoff=Read-Result (& $applyScript @a)
    Assert ($handoff.status -eq 'cleanup-review-required' -and $handoff.summary.officialRunnerCompleted -and (Test-Path -LiteralPath ($case.remover+'.done'))) 'A leftover-tab remover that hands off to a temporary copy completes only after that copy finishes'
    $case=New-HandoffCase 'handoff-hang' 'handoff-hang'; $a=$case.args; $a.TimeoutSeconds=3
    $hung=Read-Result (& $applyScript @a)
    $journal=Get-Content -LiteralPath $a.RollbackManifestPath -Raw | ConvertFrom-Json
    $child=@($journal.officialInvocation.descendants | Where-Object { $_.name -ieq 'Au_.exe' })
    Assert ($hung.status -eq 'needs-reconciliation' -and -not $hung.summary.officialRunnerCompleted -and $child.Count -eq 1) 'A handed-off remover still running at the timeout is reported as needing checking'
    $childProcess=[Diagnostics.Process]::GetProcessById([int]$child[0].processId)
    Assert (-not $childProcess.HasExited) 'The handed-off remover is not stopped at the timeout'
    $second=New-HandoffCase 'handoff-second' 'handoff'; $secondArgs=$second.args
    $blocked=Read-Result (& $applyScript @secondArgs)
    Assert ($blocked.status -eq 'failed' -and -not (Test-Path -LiteralPath ($second.remover+'.launches')) -and -not $childProcess.HasExited) 'Another removal of the same app cannot launch while the earlier remover is still running'
    $childProcess.Kill(); Assert ($childProcess.WaitForExit(10000)) 'Disposable handed-off remover is explicitly stopped and its exit verified'
    $case=New-HandoffCase 'root-hang' 'hang'; $a=$case.args; $a.TimeoutSeconds=3
    $rootHung=Read-Result (& $applyScript @a)
    $journal=Get-Content -LiteralPath $a.RollbackManifestPath -Raw | ConvertFrom-Json
    $rootProcess=[Diagnostics.Process]::GetProcessById([int]$journal.officialInvocation.processId)
    Assert ($rootHung.status -eq 'needs-reconciliation' -and -not $rootProcess.HasExited) 'A remover that never exits is reported as needing checking and is not killed'
    $rootProcess.Kill(); Assert ($rootProcess.WaitForExit(10000)) 'Disposable hung remover is explicitly stopped and its exit verified'
    $second=New-HandoffCase 'after-stale-claim' 'handoff'; $secondArgs=$second.args
    $afterStale=Read-Result (& $applyScript @secondArgs)
    Assert ($afterStale.status -eq 'cleanup-review-required' -and (Test-Path -LiteralPath ($second.remover+'.done')) -and -not (Test-Path -LiteralPath $claimPath)) 'An exited earlier remover no longer blocks the app and a completed removal releases its claim'
} finally {
    foreach ($process in @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) })) { Stop-Process -Id $process.ProcessId -Force; Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $claimPath) { Remove-Item -LiteralPath $claimPath -Force }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
$stateRoot=Join-Path $repoRoot 'backend\state'
Assert ((-not (Test-Path $stateRoot)) -or @(Get-ChildItem $stateRoot -Force -Recurse).Count -eq 0) 'backend/state remains empty'
