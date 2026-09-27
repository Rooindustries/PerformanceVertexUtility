$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-uninstall-apply-package-' + [guid]::NewGuid().ToString('N'))
$claimPath = Get-RooIndustriesBulkClaimPath ([pscustomobject]@{appId='fixture:app'}) $tempRoot
$userClaimPath = Get-RooIndustriesBulkClaimPath ([pscustomobject]@{appId='fixture:app'})
$userClaimBefore = Test-Path -LiteralPath $userClaimPath
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
        ConfirmApply=$true; OfficialUninstallCommandApproved=$true; CleanupDeletionManifestApproved=$true; UserApproved=$true; AllowRealSystemExecution=$true; FixtureRoot=$tempRoot; AllowFixtureClaims=$true;
        OfficialPreviewSha256=(Get-FileHash $officialPath -Algorithm SHA256).Hash; CleanupManifestSha256=(Get-FileHash $manifestPath -Algorithm SHA256).Hash }
    return @{root=$root; targets=$targets; official=$official; manifest=$manifest; args=$args}
}
function Set-Remover($Case, [string]$Executable, [string[]]$Arguments) {
    $Case.official.commands[0].executable = $Executable
    $Case.official.commands[0].arguments = $Arguments
    $Case.official.commands[0].commandLine = Get-RooIndustriesUninstallCommandLine $Executable (Join-RooIndustriesWindowsArguments $Arguments)
    $Case.official.commands[0].executableSha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $Case.args.AllowedOfficialExecutablePath = $Executable; Refresh-Hashes $Case
}
function New-HandoffCase([string]$Name, [string]$Mode, [string[]]$Extra = @()) {
    $case = New-Case $Name
    $case.remover = Join-Path $case.root 'remover state'
    Set-Remover $case $handoffExe (@($case.remover, $Mode) + $Extra)
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
    Set-Remover $case $vendorExe @($case.targets[0])
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
        if(args[1]=="noop")return 0;
        if(args[1]=="spawner"){
            long until=Int64.Parse(args[2]);
            string self=System.Reflection.Assembly.GetEntryAssembly().Location;
            ThreadStart work=delegate{
                while(!File.Exists(args[0]+".stop")&&DateTime.UtcNow.Ticks<until){
                    ProcessStartInfo helper=new ProcessStartInfo(self,"\""+args[0]+"\" noop");
                    helper.UseShellExecute=false;helper.CreateNoWindow=true;
                    try{Process.Start(helper).Dispose();}catch(Exception){}
                }
            };
            Thread[] threads=new Thread[3];
            for(int i=0;i<threads.Length;i++){threads[i]=new Thread(work);threads[i].Start();}
            foreach(Thread thread in threads)thread.Join();
            return 0;
        }
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
    Assert ((Test-Path -LiteralPath $claimPath) -and ((Test-Path -LiteralPath $userClaimPath) -eq $userClaimBefore)) 'A running leftover-tab remover keeps its claim in the fixture root, never in the user profile'
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
    foreach ($scenario in @('changed-command-line','missing-command-line')) {
        $case=New-HandoffCase $scenario 'handoff'; $a=$case.args
        if ($scenario -eq 'changed-command-line') { $case.official.commands[0].commandLine = $case.official.commands[0].commandLine + ' /extra' } else { $case.official.commands[0].commandLine = $null }
        Refresh-Hashes $case
        $result=Read-Result (& $applyScript @a)
        Assert ($result.status -eq 'blocked' -and @($result.gates | Where-Object { $_.gateId -eq 'reviewed-command-line' -and $_.blocking }).Count -eq 1 -and -not (Test-Path -LiteralPath ($case.remover+'.launches')) -and -not (Test-Path $a.RollbackManifestPath)) "A remover whose command differs from the reviewed command ($scenario) never launches"
    }
    foreach ($scenario in @('swapped-remover','missing-remover-hash')) {
        $case=New-Case $scenario; $a=$case.args
        $ownExe=Join-Path $case.root 'Roo Industries Own Remover.exe'; Copy-Item -LiteralPath $handoffExe -Destination $ownExe
        $case.remover=Join-Path $case.root 'remover state'
        Set-Remover $case $ownExe @($case.remover, 'handoff')
        if ($scenario -eq 'swapped-remover') { [IO.File]::AppendAllText($ownExe, 'swapped after review') } else { $case.official.commands[0].executableSha256 = $null; Refresh-Hashes $case }
        $result=Read-Result (& $applyScript @a)
        Assert ($result.status -eq 'blocked' -and @($result.gates | Where-Object { $_.gateId -eq 'reviewed-executable-unchanged' -and $_.blocking }).Count -eq 1 -and -not (Test-Path -LiteralPath ($case.remover+'.launches')) -and -not (Test-Path $a.RollbackManifestPath)) "A remover file that no longer matches its reviewed hash ($scenario) never launches"
    }
    $case=New-HandoffCase 'fixture-root-without-switch' 'handoff'; $a=$case.args; $a.Remove('AllowFixtureClaims')
    $result=Read-Result (& $applyScript @a)
    Assert ($result.status -eq 'failed' -and -not (Test-Path -LiteralPath ($case.remover+'.launches')) -and -not (Test-Path $a.RollbackManifestPath)) 'A fixture claim root is refused unless the validation switch is passed'
    $case=New-HandoffCase 'stopped-after-launch' 'hang'; $a=$case.args
    $argsPath=Join-Path $case.root 'apply arguments.json'
    $a | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $argsPath -Encoding UTF8
    $stoppedScript=Join-Path $case.root 'stopped after launch.ps1'
    Set-Content -LiteralPath $stoppedScript -Encoding UTF8 -Value @'
param([string]$ApplyScript,[string]$ArgumentsPath,[string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition 'namespace RooIndustries.Optimization.ProcessOutput { public sealed class Tree : System.IDisposable { public Tree(System.Diagnostics.Process root) { throw new System.InvalidOperationException("Simulated stop right after launch."); } public void Dispose() {} } }'
$values=@{}; (Get-Content -LiteralPath $ArgumentsPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $values[$_.Name]=$_.Value }
$values.ExactTargetAllowlist=[string[]]@($values.ExactTargetAllowlist)
& $ApplyScript @values *> $OutputPath
'@
    $stoppedLog=Join-Path $case.root 'stopped after launch.log'
    $stoppedStart=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -ExecutionPolicy Bypass -File "' + $stoppedScript + '" -ApplyScript "' + $applyScript + '" -ArgumentsPath "' + $argsPath + '" -OutputPath "' + $stoppedLog + '"'))
    $stoppedStart.UseShellExecute=$false; $stoppedStart.CreateNoWindow=$true
    $stoppedRun=[Diagnostics.Process]::Start($stoppedStart)
    Assert ($stoppedRun.WaitForExit(60000)) 'The interrupted leftover run returns without waiting for its remover'
    $stoppedOutput=if (Test-Path -LiteralPath $stoppedLog) { Get-Content -LiteralPath $stoppedLog } else { @() }
    $launchDeadline=[DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and [DateTime]::UtcNow -lt $launchDeadline) { Start-Sleep -Milliseconds 100 }
    $stoppedClaim=if (Test-Path -LiteralPath $claimPath) { (Read-RooIndustriesOperationJson $claimPath).data } else { $null }
    if ($null -eq $stoppedClaim -or $null -eq $stoppedClaim.invocation) { Write-Host ($stoppedOutput -join [Environment]::NewLine) }
    Assert ((Test-Path -LiteralPath ($case.remover+'.launches')) -and $null -ne $stoppedClaim -and $stoppedClaim.kind -eq 'cleanup-apply' -and $stoppedClaim.launchConfirmed -and [int]$stoppedClaim.invocation.processId -gt 0 -and $stoppedClaim.executable -ieq $handoffExe) 'A stop right after launch still leaves the remover process and its file in the claim'
    $blockedCase=New-HandoffCase 'while-stopped-remover-runs' 'handoff'; $blockedArgs=$blockedCase.args
    $refused=Read-Result (& $applyScript @blockedArgs)
    Assert ($refused.status -eq 'failed' -and -not (Test-Path -LiteralPath ($blockedCase.remover+'.launches')) -and (Test-Path -LiteralPath $claimPath)) 'Another removal is refused while the remover from an interrupted run is still alive'
    $stoppedProcess=[Diagnostics.Process]::GetProcessById([int]$stoppedClaim.invocation.processId)
    $stoppedProcess.Kill(); Assert ($stoppedProcess.WaitForExit(10000)) 'Disposable interrupted remover is explicitly stopped and its exit verified'
    $afterStopped=New-HandoffCase 'after-stopped-remover' 'handoff'; $afterArgs=$afterStopped.args
    $cleared=Read-Result (& $applyScript @afterArgs)
    Assert ($cleared.status -eq 'cleanup-review-required' -and (Test-Path -LiteralPath ($afterStopped.remover+'.done')) -and -not (Test-Path -LiteralPath $claimPath)) 'Once the interrupted remover has exited, a later removal clears its claim'
    $pendingRemover=Join-Path $tempRoot 'pending remover state'
    Write-RooIndustriesOperationJson ([pscustomobject]@{ kind='cleanup-apply'; appId='fixture:app'; executable=$handoffExe; claimedAtUtc=(Get-RooIndustriesUtcStamp); launchConfirmed=$false; invocation=$null }) $claimPath
    $pendingStart=[Diagnostics.ProcessStartInfo]::new($handoffExe, ('"' + $pendingRemover + '" hang')); $pendingStart.UseShellExecute=$false; $pendingStart.CreateNoWindow=$true
    $pending=[Diagnostics.Process]::Start($pendingStart)
    $case=New-HandoffCase 'unconfirmed-while-remover-runs' 'handoff'; $a=$case.args
    $refusedPending=Read-Result (& $applyScript @a)
    Assert ($refusedPending.status -eq 'failed' -and -not (Test-Path -LiteralPath ($case.remover+'.launches')) -and (Test-Path -LiteralPath $claimPath)) 'An unconfirmed claim still blocks while a process of its remover file started after the claim'
    $pending.Kill(); Assert ($pending.WaitForExit(10000)) 'Disposable pending remover is explicitly stopped and its exit verified'
    $case=New-HandoffCase 'unconfirmed-after-remover-exits' 'handoff'; $a=$case.args
    $clearedPending=Read-Result (& $applyScript @a)
    Assert ($clearedPending.status -eq 'cleanup-review-required' -and (Test-Path -LiteralPath ($case.remover+'.done')) -and -not (Test-Path -LiteralPath $claimPath)) 'An unconfirmed claim is cleared once no process of its remover file is running'
    $waitShell=[powershell]::Create()
    [void]$waitShell.AddScript(". '" + (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1') + "'`n" + '$tree=[pscustomobject]@{Count=1}; $tree | Add-Member ScriptMethod Refresh { $this.Count++ }; $tree | Add-Member ScriptMethod Live { ,@() }; Wait-RooIndustriesRemoverTree ([pscustomobject]@{Id=0;HasExited=$true}) $tree 2 $null')
    $waitWatch=[Diagnostics.Stopwatch]::StartNew()
    $waitHandle=$waitShell.BeginInvoke()
    $waitFinished=$waitHandle.AsyncWaitHandle.WaitOne(30000)
    $waitWatch.Stop()
    $waitResult=@(if ($waitFinished) { $waitShell.EndInvoke($waitHandle) } else { $waitShell.Stop() })
    $waitShell.Dispose()
    Assert ($waitFinished -and $waitWatch.Elapsed.TotalSeconds -lt 10 -and $waitResult.Count -eq 1 -and -not $waitResult[0].completed -and -not $waitResult[0].rootRunning) "A remover tree whose helpers keep appearing and exiting returns at its 2 s deadline instead of spinning ($([math]::Round($waitWatch.Elapsed.TotalSeconds,1)) s)"
    $case=New-HandoffCase 'endless-helpers' 'spawner' @([DateTime]::UtcNow.AddSeconds(90).Ticks.ToString()); $a=$case.args; $a.TimeoutSeconds=3
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $endless=Read-Result (& $applyScript @a)
    $watch.Stop()
    [IO.File]::WriteAllText($case.remover+'.stop','stop')
    $settleDeadline=[DateTime]::UtcNow.AddSeconds(30)
    while (@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -ieq $handoffExe }).Count -gt 0 -and [DateTime]::UtcNow -lt $settleDeadline) { Start-Sleep -Milliseconds 200 }
    Assert ($endless.status -eq 'needs-reconciliation' -and $watch.Elapsed.TotalSeconds -lt 45) "A remover that keeps starting helpers is reported at the timeout instead of refreshing its process tree forever ($([int]$watch.Elapsed.TotalSeconds) s)"
    if (Test-Path -LiteralPath $claimPath) { Remove-Item -LiteralPath $claimPath -Force }
} finally {
    foreach ($process in @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) })) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue; Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Assert ((Test-Path -LiteralPath $userClaimPath) -eq $userClaimBefore) 'Leftover cleanup tests leave the user profile removal claims untouched'
$stateRoot=Join-Path $repoRoot 'backend\state'
Assert ((-not (Test-Path $stateRoot)) -or @(Get-ChildItem $stateRoot -Force -Recurse).Count -eq 0) 'backend/state remains empty'
