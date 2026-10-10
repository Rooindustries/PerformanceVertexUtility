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
function Measure-PipedChildApply([hashtable]$Arguments, [string]$Root, [int]$WaitSeconds) {
    $argsPath = Join-Path $Root ('piped arguments ' + [guid]::NewGuid().ToString('N') + '.json')
    $Arguments | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $argsPath -Encoding UTF8
    $script = Join-Path $Root ('piped apply ' + [guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $script -Encoding UTF8 -Value "param([string]`$ApplyScript,[string]`$ArgumentsPath)`n`$ErrorActionPreference='Stop'`n`$values=@{}; (Get-Content -LiteralPath `$ArgumentsPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { `$values[`$_.Name]=`$_.Value }`n`$values.ExactTargetAllowlist=[string[]]@(`$values.ExactTargetAllowlist)`n& `$ApplyScript @values`n"
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -ApplyScript "' + $applyScript + '" -ArgumentsPath "' + $argsPath + '"'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $child = [Diagnostics.Process]::Start($start)
    $stdout = $child.StandardOutput.ReadToEndAsync(); $stderr = $child.StandardError.ReadToEndAsync()
    $finished = [Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), $WaitSeconds * 1000)
    $watch.Stop()
    return [pscustomobject]@{ finished = $finished; seconds = $watch.Elapsed.TotalSeconds; hostExited = $child.WaitForExit(0) }
}
function Invoke-ChildApply([hashtable]$Arguments, [string]$Prelude, [string]$Root) {
    $argsPath = Join-Path $Root ('child arguments ' + [guid]::NewGuid().ToString('N') + '.json')
    $Arguments | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $argsPath -Encoding UTF8
    $script = Join-Path $Root ('child apply ' + [guid]::NewGuid().ToString('N') + '.ps1')
    $log = $script + '.log'
    Set-Content -LiteralPath $script -Encoding UTF8 -Value ("param([string]`$ApplyScript,[string]`$ArgumentsPath,[string]`$OutputPath)`n`$ErrorActionPreference='Stop'`n" + $Prelude + "`n`$values=@{}; (Get-Content -LiteralPath `$ArgumentsPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { `$values[`$_.Name]=`$_.Value }`n`$values.ExactTargetAllowlist=[string[]]@(`$values.ExactTargetAllowlist)`n& `$ApplyScript @values *> `$OutputPath`n")
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -ApplyScript "' + $applyScript + '" -ArgumentsPath "' + $argsPath + '" -OutputPath "' + $log + '"'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $child = [Diagnostics.Process]::Start($start)
    if (-not $child.WaitForExit(90000)) { $child.Kill(); throw 'The child apply run did not return.' }
    if (Test-Path -LiteralPath $log) { return @(Get-Content -LiteralPath $log) }
    return @()
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
        if(args[1]=="pipe-holder"){
            string shell=Path.Combine(Path.GetDirectoryName(args[0]),"shell host\\explorer.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(shell));
            File.Copy(System.Reflection.Assembly.GetEntryAssembly().Location,shell,true);
            ProcessStartInfo holder=new ProcessStartInfo(shell,"\""+args[0]+"\" child-hang");
            holder.UseShellExecute=false;holder.CreateNoWindow=true;
            Process.Start(holder).Dispose();
            return 0;
        }
        if(args[1]=="self-delete"){
            File.AppendAllText(args[0]+".launches","launched"+Environment.NewLine);
            ProcessStartInfo remove=new ProcessStartInfo("cmd.exe","/c ping -n 3 127.0.0.1 >nul & del /f /q \""+System.Reflection.Assembly.GetEntryAssembly().Location+"\"");
            remove.UseShellExecute=false;remove.CreateNoWindow=true;
            Process.Start(remove).Dispose();
            return 0;
        }
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
    $script:firstRecord=$null
    $jobState=Join-Path $tempRoot 'job check state'
    $jobRun=Invoke-RooIndustriesObservedRemover $handoffExe ('"' + $jobState + '" noop') $tempRoot 10 { param($invocation) if ($null -eq $script:firstRecord) { $script:firstRecord=[pscustomobject]@{ treeContained=[bool]$invocation.treeContained; processId=$invocation.processId } } } ('"' + $handoffExe + '" "' + $jobState + '" noop')
    Assert ($jobRun.processStarted -and $null -ne $script:firstRecord -and $script:firstRecord.treeContained -and [int]$script:firstRecord.processId -gt 0) 'The first record of a launched remover already shows it inside its tracking job'
    $powershellExe=Join-Path $PSHOME 'powershell.exe'
    $powershellArgs='-NoProfile -NonInteractive -Command "[Console]::Out.Write(''appx route''); exit 7"'
    $powershellRun=Invoke-RooIndustriesObservedRemover $powershellExe $powershellArgs $tempRoot 30 $null (Get-RooIndustriesUninstallCommandLine $powershellExe $powershellArgs)
    Assert ($powershellRun.processStarted -and $powershellRun.exitCode -eq 7 -and $powershellRun.stdout -like '*appx route*') "A PowerShell (Appx-style) remover starts suspended, resumes and reports its exit code and output ($($powershellRun.exitCode) $($powershellRun.startError))"
    $manifest=Join-Path $tempRoot 'require-administrator.manifest'
    Set-Content -LiteralPath $manifest -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false"/></requestedPrivileges></security></trustInfo></assembly>'
    $adminExe=Join-Path $tempRoot 'Roo Industries Admin Remover.exe'
    $adminSource=Join-Path $tempRoot 'admin remover.cs'
    Set-Content -LiteralPath $adminSource -Encoding UTF8 -Value 'public static class RooIndustriesAdminRemover { public static int Main() { return 3; } }'
    & (Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe') /nologo /target:exe "/win32manifest:$manifest" "/out:$adminExe" "$adminSource" | Out-Null
    $adminRun=Invoke-RooIndustriesObservedRemover $adminExe '' $tempRoot 30 $null (Get-RooIndustriesUninstallCommandLine $adminExe '')
    Assert ($adminRun.processStarted -and $adminRun.exitCode -eq 3) "A remover whose manifest requires administrator starts from the elevated host ($($adminRun.exitCode) $($adminRun.startError))"
    $msiexec=Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
    $msiArgs='/x {00000000-1111-2222-3333-444444444444} /qn /norestart'
    $msiRun=Invoke-RooIndustriesObservedRemover $msiexec $msiArgs $tempRoot 60 $null (Get-RooIndustriesUninstallCommandLine $msiexec $msiArgs)
    Assert ($msiRun.processStarted -and $msiRun.exitCode -eq 1605) "msiexec starts suspended, resumes and reports an unknown product ($($msiRun.exitCode) $($msiRun.startError))"
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
    $killBeforeRecord=@'
Import-Module Microsoft.PowerShell.Management
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string[]]$Name)
    if ($Name -contains 'BootId') { [Diagnostics.Process]::GetCurrentProcess().Kill() }
    Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
}
'@
    $killAfterRecord=@'
Import-Module Microsoft.PowerShell.Utility
function global:Start-Sleep {
    [CmdletBinding()] param([int]$Seconds, [int]$Milliseconds)
    if ($Milliseconds -eq 250) { [Diagnostics.Process]::GetCurrentProcess().Kill() }
    Microsoft.PowerShell.Utility\Start-Sleep @PSBoundParameters
}
'@
    $case=New-HandoffCase 'host-killed-before-record' 'hang'; $a=$case.args
    [void](Invoke-ChildApply $a $killBeforeRecord $case.root)
    $settle=[DateTime]::UtcNow.AddSeconds(10)
    while (@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($case.remover) }).Count -gt 0 -and [DateTime]::UtcNow -lt $settle) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Seconds 1
    $unrecordedClaim=if (Test-Path -LiteralPath $claimPath) { (Read-RooIndustriesOperationJson $claimPath).data } else { $null }
    $leftBehind=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($case.remover) }).Count
    Assert (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and $leftBehind -eq 0 -and $null -ne $unrecordedClaim -and $null -eq $unrecordedClaim.invocation) "A leftover run killed before it records its remover leaves a remover that never ran ($leftBehind left)"
    $afterKilled=New-HandoffCase 'after-host-killed-before-record' 'handoff'; $afterArgs=$afterKilled.args
    $clearedKilled=Read-Result (& $applyScript @afterArgs)
    Assert ($clearedKilled.status -eq 'cleanup-review-required' -and (Test-Path -LiteralPath ($afterKilled.remover+'.done')) -and -not (Test-Path -LiteralPath $claimPath)) 'The next leftover run clears a claim whose remover never ran'
    $case=New-HandoffCase 'remover-outlives-host' 'hang'; $a=$case.args; $a.TimeoutSeconds=3
    $piped=Measure-PipedChildApply $a $case.root 40
    $outlivingClaim=if (Test-Path -LiteralPath $claimPath) { (Read-RooIndustriesOperationJson $claimPath).data } else { $null }
    if ($null -ne $outlivingClaim -and [int]$outlivingClaim.invocation.processId -gt 0) { Stop-Process -Id ([int]$outlivingClaim.invocation.processId) -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $claimPath) { Remove-Item -LiteralPath $claimPath -Force }
    Assert ($piped.finished -and $piped.seconds -lt 35 -and $null -ne $outlivingClaim) "The host's own output ends when the host exits, even while its remover keeps running ($([math]::Round($piped.seconds,1)) s)"
    $case=New-HandoffCase 'untracked-pipe-holder' 'pipe-holder'; $a=$case.args
    $holderRun=Read-Result (& $applyScript @a)
    $holderClaim=Test-Path -LiteralPath $claimPath
    foreach ($holder in @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($case.root, [StringComparison]::OrdinalIgnoreCase) })) { Stop-Process -Id $holder.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($holderClaim) { Remove-Item -LiteralPath $claimPath -Force }
    Assert ($holderRun.status -eq 'needs-reconciliation' -and $holderClaim -and -not $holderRun.summary.officialRunnerCompleted) "A remover whose untracked child still holds its output keeps its claim and needs checking ($($holderRun.status))"
    $treeSource=Join-Path $PSScriptRoot '..\native\ProcessOutput\RooIndustriesProcessTree.cs'
    $case=New-HandoffCase 'host-killed-before-resume' 'hang'; $a=$case.args
    $killBeforeResume="Add-Type -Path '$treeSource'`n[RooIndustries.Optimization.ProcessOutput.Launch]::AfterJobReleaseForTests=[Action]{ [Diagnostics.Process]::GetCurrentProcess().Kill() }"
    [void](Invoke-ChildApply $a $killBeforeResume $case.root)
    $suspendedClaim=if (Test-Path -LiteralPath $claimPath) { (Read-RooIndustriesOperationJson $claimPath).data } else { $null }
    Import-RooIndustriesBulkProcessTypes
    [RooIndustries.Optimization.ProcessOutput.Tree]::NeverRanGraceSeconds=1
    Start-Sleep -Seconds 2
    try {
        $afterSuspended=New-HandoffCase 'after-suspended-remover' 'handoff'; $afterArgs=$afterSuspended.args
        $clearedSuspended=Read-Result (& $applyScript @afterArgs)
    } finally { [RooIndustries.Optimization.ProcessOutput.Tree]::NeverRanGraceSeconds=60 }
    $suspendedLeft=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($case.remover) })
    foreach ($orphan in $suspendedLeft) { Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue }
    Assert ($null -ne $suspendedClaim -and [int]$suspendedClaim.invocation.processId -gt 0 -and -not $suspendedClaim.launchConfirmed) 'A remover recorded but never resumed is claimed as not yet confirmed'
    Assert (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and $suspendedLeft.Count -eq 0 -and $clearedSuspended.status -eq 'cleanup-review-required' -and -not (Test-Path -LiteralPath $claimPath)) "A recorded remover that never ran is ended and its claim cleared by the next run ($($suspendedLeft.Count) left, $($clearedSuspended.status))"
    $case=New-HandoffCase 'resume-fails' 'hang'; $a=$case.args
    $failResume="Add-Type -Path '$treeSource'`n[RooIndustries.Optimization.ProcessOutput.Launch]::SimulateResumeFailureForTests=[Func[bool]]{ `$true }"
    $resumeOutput=Invoke-ChildApply $a $failResume $case.root
    Start-Sleep -Seconds 1
    $resumeLeft=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($case.remover) })
    foreach ($orphan in $resumeLeft) { Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue }
    Assert (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and $resumeLeft.Count -eq 0 -and -not (Test-Path -LiteralPath $claimPath) -and (($resumeOutput -join ' ') -like '*The remover could not be started*')) "A remover that fails to resume is ended before it runs and reported as not started ($($resumeLeft.Count) left)"
    $case=New-HandoffCase 'host-killed-after-create' 'hang'; $a=$case.args
    $treeSource=Join-Path $PSScriptRoot '..\native\ProcessOutput\RooIndustriesProcessTree.cs'
    $killAfterCreate="Add-Type -Path '$treeSource'`n[RooIndustries.Optimization.ProcessOutput.Launch]::AfterCreateForTests=[Action]{ [Diagnostics.Process]::GetCurrentProcess().Kill() }"
    [void](Invoke-ChildApply $a $killAfterCreate $case.root)
    $settle=[DateTime]::UtcNow.AddSeconds(10)
    while (@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($case.remover) }).Count -gt 0 -and [DateTime]::UtcNow -lt $settle) { Start-Sleep -Milliseconds 100 }
    $orphans=@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($case.remover) })
    foreach ($orphan in $orphans) { Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue }
    Assert (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and $orphans.Count -eq 0) "A host killed right after creating the suspended remover leaves no remover process behind ($($orphans.Count) left)"
    $case=New-HandoffCase 'host-killed-after-record' 'hang'; $a=$case.args
    [void](Invoke-ChildApply $a $killAfterRecord $case.root)
    $launchDeadline=[DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and [DateTime]::UtcNow -lt $launchDeadline) { Start-Sleep -Milliseconds 100 }
    $recordedClaim=if (Test-Path -LiteralPath $claimPath) { (Read-RooIndustriesOperationJson $claimPath).data } else { $null }
    Assert ($null -ne $recordedClaim -and [int]$recordedClaim.invocation.processId -gt 0 -and (Test-Path -LiteralPath ($case.remover+'.launches'))) 'A leftover run killed after it records its remover leaves that remover running and recorded'
    $blockedCase=New-HandoffCase 'while-recorded-remover-runs' 'handoff'; $blockedArgs=$blockedCase.args
    $refused=Read-Result (& $applyScript @blockedArgs)
    Assert ($refused.status -eq 'failed' -and -not (Test-Path -LiteralPath ($blockedCase.remover+'.launches')) -and (Test-Path -LiteralPath $claimPath)) 'Another removal is refused while the recorded remover from a killed run is alive'
    $recordedProcess=[Diagnostics.Process]::GetProcessById([int]$recordedClaim.invocation.processId)
    $recordedProcess.Kill(); Assert ($recordedProcess.WaitForExit(10000)) 'Disposable recorded remover is explicitly stopped and its exit verified'
    $afterRecorded=New-HandoffCase 'after-recorded-remover' 'handoff'; $afterArgs=$afterRecorded.args
    $clearedRecorded=Read-Result (& $applyScript @afterArgs)
    Assert ($clearedRecorded.status -eq 'cleanup-review-required' -and (Test-Path -LiteralPath ($afterRecorded.remover+'.done')) -and -not (Test-Path -LiteralPath $claimPath)) 'Once the recorded remover has exited, a later removal clears its claim'
    $powershellExe=Join-Path $PSHOME 'powershell.exe'
    Write-RooIndustriesOperationJson ([pscustomobject]@{ kind='cleanup-apply'; appId='fixture:app'; executable=$powershellExe; claimedAtUtc=(Get-RooIndustriesUtcStamp); launchConfirmed=$false; invocation=$null }) $claimPath
    $unrelatedStart=[Diagnostics.ProcessStartInfo]::new($powershellExe, '-NoProfile -Command Start-Sleep -Seconds 60'); $unrelatedStart.UseShellExecute=$false; $unrelatedStart.CreateNoWindow=$true
    $unrelated=[Diagnostics.Process]::Start($unrelatedStart)
    try {
        $case=New-HandoffCase 'appx-style-claim' 'handoff'; $a=$case.args
        $appxCleared=Read-Result (& $applyScript @a)
    } finally { if (-not $unrelated.HasExited) { $unrelated.Kill() }; [void]$unrelated.WaitForExit(10000) }
    Assert ($appxCleared.status -eq 'cleanup-review-required' -and (Test-Path -LiteralPath ($case.remover+'.done')) -and -not (Test-Path -LiteralPath $claimPath)) 'A claim with no recorded remover is cleared even while an unrelated powershell.exe runs'
    $case=New-Case 'self-deleting-remover'; $a=$case.args
    $ownExe=Join-Path $case.root 'Roo Industries Self Deleting Remover.exe'; Copy-Item -LiteralPath $handoffExe -Destination $ownExe
    $case.remover=Join-Path $case.root 'remover state'
    Set-Remover $case $ownExe @($case.remover, 'self-delete')
    $firstRun=Read-Result (& $applyScript @a)
    $replayRun=Read-Result (& $applyScript @a)
    Assert ($firstRun.status -eq 'cleanup-review-required' -and -not (Test-Path -LiteralPath $ownExe) -and $replayRun.status -eq 'cleanup-review-required' -and $replayRun.executionReused -and @(Get-Content -LiteralPath ($case.remover+'.launches')).Count -eq 1) "Replaying a finished run whose remover deleted itself returns the recorded result ($($firstRun.status), $($replayRun.status))"
    $case=New-Case 'linked-remover'; $a=$case.args
    $realDir=Join-Path $case.root 'real remover'; $linkDir=Join-Path $case.root 'linked remover'
    New-Item -ItemType Directory -Path $realDir | Out-Null
    Copy-Item -LiteralPath $handoffExe -Destination (Join-Path $realDir 'remover.exe')
    cmd.exe /c mklink /J "$linkDir" "$realDir" | Out-Null
    $case.remover=Join-Path $case.root 'remover state'
    Set-Remover $case (Join-Path $linkDir 'remover.exe') @($case.remover, 'handoff')
    foreach ($name in @('FixtureRoot','AllowFixtureClaims','ConfirmApply','UserApproved','AllowRealSystemExecution')) { $a.Remove($name) }
    $a.ExecutorMode='Preview'
    $linked=Read-Result (& $applyScript @a)
    Assert ((Test-Path -LiteralPath $linkDir) -and $linked.status -eq 'preview' -and @($linked.gates | Where-Object { $_.gateId -eq 'reviewed-executable-unchanged' -and $_.blocking }).Count -eq 1 -and -not (Test-Path -LiteralPath ($case.remover+'.launches'))) 'A remover reached through a junction fails its review gate'
    cmd.exe /c rmdir "$linkDir" | Out-Null
    $case=New-Case 'swapped-inside-lease'; $a=$case.args
    $ownExe=Join-Path $case.root 'Roo Industries Swapped Remover.exe'; Copy-Item -LiteralPath $handoffExe -Destination $ownExe
    $case.remover=Join-Path $case.root 'remover state'
    Set-Remover $case $ownExe @($case.remover, 'handoff')
    $swapPrelude=@'
Import-Module Microsoft.PowerShell.Utility
function global:Get-FileHash {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Algorithm)
    $value = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
    if ($LiteralPath -like '*Roo Industries Swapped Remover.exe') { [IO.File]::AppendAllText($LiteralPath, 'swapped after the gate') }
    return $value
}
'@
    $swappedOutput=Invoke-ChildApply $a $swapPrelude $case.root
    if (-not ((($swappedOutput -join ' ') -like '*changed after review*'))) { Write-Host ('swap output: launched=' + (Test-Path -LiteralPath ($case.remover+'.launches')) + ' claim=' + (Test-Path -LiteralPath $claimPath) + ' ' + (($swappedOutput -join ' ') -replace '\s+',' ')) }
    Assert (-not (Test-Path -LiteralPath ($case.remover+'.launches')) -and -not (Test-Path -LiteralPath $claimPath) -and (($swappedOutput -join ' ') -like '*changed after review*')) 'A remover swapped after the review gate but before launch is caught by the locked re-hash'
    $case=New-HandoffCase 'capture-dispose-throws' 'hang'; $a=$case.args; $a.TimeoutSeconds=3
    $capturePrelude=@'
Add-Type -TypeDefinition 'namespace RooIndustries.Optimization.ProcessOutput { public sealed class Capture : System.IDisposable { public Capture(System.IO.Stream stdout, System.IO.Stream stderr, int limit) {} public bool Complete(int timeout) { return true; } public string Stdout { get { return ""; } } public string Stderr { get { return ""; } } public bool Truncated { get { return false; } } public void Dispose() { throw new System.InvalidOperationException("Simulated failure while closing output."); } } }'
'@
    $captureOutput=Invoke-ChildApply $a $capturePrelude $case.root
    $keptClaim=if (Test-Path -LiteralPath $claimPath) { (Read-RooIndustriesOperationJson $claimPath).data } else { $null }
    Assert ($null -ne $keptClaim -and [int]$keptClaim.invocation.processId -gt 0 -and (($captureOutput -join ' ') -like '*Simulated failure while closing output*')) 'A failure after the remover started keeps its claim'
    $capturedProcess=[Diagnostics.Process]::GetProcessById([int]$keptClaim.invocation.processId)
    $capturedProcess.Kill(); Assert ($capturedProcess.WaitForExit(10000)) 'Disposable remover from the output-failure run is stopped and its exit verified'
    Remove-Item -LiteralPath $claimPath -Force
    $case=New-Case 'real-remover-with-fixture-claims'; $a=$case.args
    $case.remover=Join-Path $case.root 'remover state'
    $whoami=Join-Path ([Environment]::SystemDirectory) 'whoami.exe'
    Set-Remover $case $whoami @()
    $realRemover=Read-Result (& $applyScript @a)
    Assert ($realRemover.status -eq 'failed' -and @($realRemover.executionSequence).Count -eq 0 -and -not (Test-Path $a.RollbackManifestPath)) 'Fixture claims are refused for a remover outside the fixture root'
    $case=New-Case 'linked-inside-lease'; $a=$case.args
    $binDir=Join-Path $case.root 'bin'; New-Item -ItemType Directory -Path $binDir | Out-Null
    Copy-Item -LiteralPath $handoffExe -Destination (Join-Path $binDir 'remover.exe')
    $case.remover=Join-Path $case.root 'remover state'
    Set-Remover $case (Join-Path $binDir 'remover.exe') @($case.remover, 'handoff')
    $linkPrelude=@'
Import-Module Microsoft.PowerShell.Utility
function global:Get-FileHash {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Algorithm)
    $value = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
    if ($LiteralPath -like '*\linked-inside-lease\bin\remover.exe' -and -not $global:RooIndustriesLinked) {
        $global:RooIndustriesLinked = $true
        $bin = Split-Path $LiteralPath -Parent
        [IO.Directory]::Move($bin, $bin + '-real')
        cmd.exe /c mklink /J "$bin" "$bin-real" | Out-Null
    }
    return $value
}
'@
    $linkedOutput=Invoke-ChildApply $a $linkPrelude $case.root
    $linkedJunction=(Get-Item -LiteralPath $binDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
    cmd.exe /c rmdir "$binDir" | Out-Null
    Assert ($linkedJunction -and -not (Test-Path -LiteralPath ($case.remover+'.launches')) -and -not (Test-Path -LiteralPath $claimPath) -and (($linkedOutput -join ' ') -like '*reached through a link*')) 'A remover path that becomes a link after the review gate is refused inside the launch lease'
    $waitShell=[powershell]::Create()
    [void]$waitShell.AddScript(". '" + (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1') + "'`n" + '$tree=[pscustomobject]@{Count=1}; $tree | Add-Member ScriptMethod Refresh { $this.Count++ }; $tree | Add-Member ScriptMethod Live { ,@() }; Wait-RooIndustriesRemoverTree ([pscustomobject]@{Id=0;HasExited=$true}) $tree 2 $null; $tree.Count')
    $waitWatch=[Diagnostics.Stopwatch]::StartNew()
    $waitHandle=$waitShell.BeginInvoke()
    $waitFinished=$waitHandle.AsyncWaitHandle.WaitOne(30000)
    $waitWatch.Stop()
    $waitResult=@(if ($waitFinished) { $waitShell.EndInvoke($waitHandle) } else { $waitShell.Stop() })
    $waitShell.Dispose()
    $refreshes=if ($waitResult.Count -eq 2) { [int]$waitResult[1] - 1 } else { -1 }
    Assert ($waitFinished -and $waitWatch.Elapsed.TotalSeconds -lt 10 -and $waitResult.Count -eq 2 -and -not $waitResult[0].completed -and -not $waitResult[0].rootRunning -and $refreshes -ge 1 -and $refreshes -le 30) "A remover tree whose helpers keep appearing and exiting returns at its 2 s deadline after a paced number of refreshes ($([math]::Round($waitWatch.Elapsed.TotalSeconds,1)) s, $refreshes refreshes)"
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
