$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Host "PASS $Message"}
function Read-Result($Lines){return ($Lines -join [Environment]::NewLine)|ConvertFrom-Json}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-bulk-uninstall-'+[guid]::NewGuid().ToString('N'))
$planScript=Join-Path $PSScriptRoot 'New-BulkUninstallPlan.ps1'
$runScript=Join-Path $PSScriptRoot 'Invoke-BulkUninstall.ps1'
$liveFixtures=New-Object System.Collections.Generic.List[object]
$msiCode=[guid]::NewGuid().ToString('B').ToUpperInvariant()
$msiKeyPath='Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$msiCode
$msiAppId='registry:roo-industries-msi-fixture-'+$msiCode
$msiClaim=Get-RooIndustriesBulkClaimPath ([pscustomobject]@{appId=$msiAppId})
function Invoke-ChildQueue([hashtable]$Arguments,[string]$Prelude,[string]$Directory) {
    $argsPath=Join-Path $Directory ('child arguments '+[guid]::NewGuid().ToString('N')+'.json');$Arguments|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $argsPath -Encoding UTF8
    $script=Join-Path $Directory ('child run '+[guid]::NewGuid().ToString('N')+'.ps1');$log=$script+'.log'
    Set-Content -LiteralPath $script -Encoding UTF8 -Value ("param([string]`$RunScript,[string]`$ArgumentsPath,[string]`$OutputPath)`n`$ErrorActionPreference='Stop'`n"+$Prelude+"`n`$values=@{};(Get-Content -LiteralPath `$ArgumentsPath -Raw|ConvertFrom-Json).PSObject.Properties|ForEach-Object {`$values[`$_.Name]=`$_.Value}`n& `$RunScript @values *> `$OutputPath`n")
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),('-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -RunScript "'+$runScript+'" -ArgumentsPath "'+$argsPath+'" -OutputPath "'+$log+'"'))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $child=[Diagnostics.Process]::Start($start)
    if(-not $child.WaitForExit(90000)){$child.Kill();throw 'The child queue run did not return.'}
    if(Test-Path -LiteralPath $log){return @(Get-Content -LiteralPath $log)}
    return @()
}
function New-Case([string]$Name,[string]$FirstMode='remove',[int]$FirstExit=0,[switch]$Unquoted,[switch]$BrokenExe,[switch]$ExeInBin) {
    $directory=Join-Path $root $Name;[IO.Directory]::CreateDirectory($directory)|Out-Null
    $exe=if($ExeInBin){Join-Path $directory 'bin\Roo Industries Bulk Removal Fixture.exe'}else{Join-Path $directory 'Roo Industries Bulk Removal Fixture.exe'}
    [IO.Directory]::CreateDirectory((Split-Path $exe -Parent))|Out-Null;Copy-Item -LiteralPath $script:fixtureExe -Destination $exe
    if($BrokenExe){[IO.File]::WriteAllText($exe,'This fixture is not a Windows program.')}
    $journalPath=Join-Path $directory 'journal.json';$counter=Join-Path $directory 'launch count.txt'
    $apps=@();$markers=@()
    foreach($i in 1..2){
        $marker=Join-Path $directory "installed $i.txt";[IO.File]::WriteAllText($marker,'installed');$markers+=@($marker)
        $mode=if($i -eq 1){$FirstMode}else{'remove'};$code=if($i -eq 1){$FirstExit}else{0}
        $arguments=@($marker,$counter,[string]$code,$mode,($journalPath+'.cancel'),'quoted "value" with trailing\')
        $install=Join-Path $directory ('app-'+$i);[IO.Directory]::CreateDirectory($install)|Out-Null;[IO.File]::WriteAllText((Join-Path $install 'settings.txt'),'original settings')
        $apps+=@([pscustomobject]@{appId="fixture:$Name-$i";displayName="Roo Industries disposable app $i";publisher='Roo Industries Fixture';sourceType='registry';
            sourceIdentity=@{kind='fixture';presencePath=$marker};installLocation=$install;risk='low';protected=$false;categories=@('application');
            uninstallString=$(if(-not $Unquoted){ConvertTo-RooIndustriesWindowsArgument $exe}elseif($i -eq 1){$exe}else{$exe.Substring(0,$exe.Length-4)})+' '+(Join-RooIndustriesWindowsArguments $arguments)})
    }
    $inventory=Join-Path $directory 'inventory.json';Write-RooIndustriesOperationJson @{schemaVersion=1;apps=$apps} $inventory
    $planPath=Join-Path $directory 'plan.json'
    $preview=Read-Result (& $planScript -AppId @($apps.appId) -InventoryPath $inventory -FixtureRoot $directory -OutputPath $planPath)
    if($preview.status -ne 'preview'){throw ($preview|ConvertTo-Json -Depth 12)}
    return @{directory=$directory;markers=$markers;counter=$counter;plan=$preview.data;planPath=$planPath;exe=$exe;
        args=@{Action='Apply';InputPath=$planPath;ReviewSha256=(Get-FileHash $planPath).Hash;JournalPath=$journalPath;AllowFixtureExecution=$true;ConfirmApply=$true;ManualReviewApproved=$true}}
}
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class RooIndustriesBulkAccessFixture {
    [StructLayout(LayoutKind.Sequential, Pack=4)] private struct Privilege { public int Count; public long Luid; public int Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool LookupPrivilegeValueW(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref Privilege state, int length, ref Privilege previous, out int returned);
    [DllImport("advapi32.dll")] private static extern uint SetSecurityInfo(IntPtr handle, int type, uint information, IntPtr owner, IntPtr group, byte[] dacl, IntPtr sacl);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    public static void DenyAll(IntPtr process) {
        byte[] dacl = new byte[8];
        new System.Security.AccessControl.RawAcl(2, 0).GetBinaryForm(dacl, 0);
        uint error = SetSecurityInfo(process, 6, 4, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
        if (error != 0) throw new Win32Exception((int)error);
    }
    public static int OpenError(int processId) {
        IntPtr handle = OpenProcess(0x101000, false, processId);
        if (handle == IntPtr.Zero) return Marshal.GetLastWin32Error();
        CloseHandle(handle);
        return 0;
    }
    private static int Adjust(int attributes) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            Privilege state = new Privilege { Count = 1, Attributes = attributes }, previous = new Privilege();
            if (!LookupPrivilegeValueW(null, "SeDebugPrivilege", out state.Luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            int returned;
            if (!AdjustTokenPrivileges(token, false, ref state, Marshal.SizeOf(typeof(Privilege)), ref previous, out returned) || Marshal.GetLastWin32Error() != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            return previous.Count == 0 ? attributes : previous.Attributes;
        } finally { CloseHandle(token); }
    }
    public static int SetDebug(bool enabled) { return Adjust(enabled ? 2 : 0); }
    public static void RestoreDebug(int attributes) { Adjust(attributes & 2); }
}
'@
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $script:fixtureExe=Join-Path $root 'RooIndustriesBulkFixture.exe'
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public class RooIndustriesBulkFixture {
    public static int Main(string[] args) {
        if(args[3]=="child"){Thread.Sleep(1500);File.Delete(args[0]);Thread.Sleep(3000);File.WriteAllText(args[0]+".done","finished");return 0;}
        if(args[3]=="child-hang"){File.Delete(args[0]);Thread.Sleep(120000);return 0;}
        if(args[3]=="child-shell"){Thread.Sleep(120000);return 0;}
        Console.WriteLine("A vendor console message must not corrupt the JSON response.");
        Console.Error.WriteLine("Vendor diagnostic output.");
        if(args.Length!=6||args[5]!="quoted \"value\" with trailing\\") return 87;
        File.AppendAllText(args[1]+".command-lines",Environment.CommandLine+Environment.NewLine);
        if(args[3]=="verbose") Console.Write(new String('x',200000));
        File.AppendAllText(args[1],args[0]+Environment.NewLine);
        if(args[3].StartsWith("handoff")){
            string copy=Path.Combine(Path.GetDirectoryName(args[1]),"temp copy\\~nsu1.tmp\\Au_.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(copy));
            File.Copy(System.Reflection.Assembly.GetEntryAssembly().Location,copy,true);
            ProcessStartInfo start=new ProcessStartInfo(copy,"\""+args[0]+"\" \""+args[1]+"\" 0 "+(args[3]=="handoff"?"child":"child-hang"));
            start.UseShellExecute=true;start.WindowStyle=ProcessWindowStyle.Hidden;
            Process.Start(start).Dispose();
            return 0;
        }
        if(args[3]=="shell"){
            string shell=Path.Combine(Path.GetDirectoryName(args[1]),"shell host\\explorer.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(shell));
            File.Copy(System.Reflection.Assembly.GetEntryAssembly().Location,shell,true);
            ProcessStartInfo start=new ProcessStartInfo(shell,"\""+args[0]+"\" \""+args[1]+"\" 0 child-shell");
            start.UseShellExecute=true;start.WindowStyle=ProcessWindowStyle.Hidden;
            Process.Start(start).Dispose();
        }
        if(args[3]=="wait") Thread.Sleep(15000);
        if(args[3]=="cancel") File.WriteAllText(args[4],"stop after this entry");
        if(args[3]!="keep") File.Delete(args[0]);
        return Int32.Parse(args[2]);
    }
}
'@ -OutputAssembly $script:fixtureExe -OutputType ConsoleApplication
    $msiDirectory=Join-Path $root 'msi';[IO.Directory]::CreateDirectory($msiDirectory)|Out-Null
    $msiKey=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($msiKeyPath)
    try {$msiKey.SetValue('DisplayName','Roo Industries MSI command fixture');$msiKey.SetValue('UninstallString',"MsiExec.exe /X$msiCode");$msiKey.SetValue('WindowsInstaller',1,[Microsoft.Win32.RegistryValueKind]::DWord)}
    finally {$msiKey.Dispose()}
    $msiApp=[pscustomobject]@{appId=$msiAppId;displayName='Roo Industries MSI command fixture';sourceType='msi';packageId=$msiCode;risk='low';protected=$false;categories=@('application');
        sourceIdentity=@{kind='registry';hive='CurrentUser';view='Registry64';keyPath=$msiKeyPath;userSid=(Get-RooIndustriesOperationOwner).userSid};uninstallString="MsiExec.exe /X$msiCode"}
    $msiInventory=Join-Path $msiDirectory 'inventory.json';Write-RooIndustriesOperationJson @{schemaVersion=1;apps=@($msiApp)} $msiInventory
    $msiPlanPath=Join-Path $msiDirectory 'plan.json'
    $msiPlan=Read-Result (& $planScript -AppId @($msiAppId) -InventoryPath $msiInventory -Quiet -OutputPath $msiPlanPath)
    $msiexec=Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
    Assert ($msiPlan.status -eq 'preview' -and $msiPlan.data.entries[0].commandLine -ceq ('"'+$msiexec+'" /x '+$msiCode+' /qn /norestart')) 'MSI removal is reviewed as one unquoted msiexec command line built from the ProductCode'
    $msiJournal=Join-Path $msiDirectory 'journal.json'
    $msiRun=Read-Result (& $runScript -Action Apply -InputPath $msiPlanPath -ReviewSha256 (Get-FileHash $msiPlanPath).Hash -JournalPath $msiJournal -TimeoutSeconds 30 -ConfirmApply -ManualReviewApproved)
    Assert ($null -ne $msiRun.data.entries[0].outcome -and $msiRun.data.entries[0].outcome.exitCode -eq 1605) 'msiexec parses the executed MSI command and reports the unknown ProductCode instead of showing its usage window'
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($msiKeyPath)
    $msiReconciled=Read-Result (& $runScript -Action Reconcile -JournalPath $msiJournal -ConfirmApply)
    Assert ($msiReconciled.data.entries[0].state -eq 'removed' -and -not(Test-Path -LiteralPath $msiClaim)) 'The MSI fixture queue reconciles after its registration is removed and releases its removal claim'
    $case=New-Case 'success';$a=$case.args
    Assert ((Test-Path $case.markers[0]) -and -not(Test-Path $case.counter) -and -not(Test-Path $a.JournalPath)) 'Bulk preview executes nothing and creates no journal'
    $withoutApproval=@{};foreach($key in $a.Keys){$withoutApproval[$key]=$a[$key]};$withoutApproval.ConfirmApply=$false
    $preview=Read-Result (& $runScript @withoutApproval)
    Assert ($preview.status -eq 'preview' -and -not(Test-Path $a.JournalPath)) 'Apply without confirmation remains a preview'
    $overwrite=Read-Result (& $runScript @a -OutputPath $case.planPath)
    Assert ($overwrite.status -eq 'failed' -and (Get-FileHash $case.planPath).Hash -eq $a.ReviewSha256 -and -not(Test-Path $case.counter)) 'An output collision cannot destroy the reviewed bulk plan or launch a command'
    foreach($control in '.cancel','.lock'){
        $controlOutput=Read-Result (& $runScript @a -OutputPath ($a.JournalPath+$control))
        Assert ($controlOutput.status -eq 'failed' -and $controlOutput.errors[0].message -eq 'OutputPath cannot replace queue control files.' -and -not(Test-Path ($a.JournalPath+$control)) -and -not(Test-Path $case.counter)) "An output path cannot replace the queue $control file"
    }
    $lease=Lock-RooIndustriesOperation $a.JournalPath
    try{$busy=Read-Result (& $runScript @a)}finally{$lease.Dispose()}
    Assert ($busy.status -eq 'failed' -and -not(Test-Path $case.counter)) 'Concurrent queue invocation cannot dispatch through an occupied journal lease'
    $run=Read-Result (& $runScript @a)
    if($run.status -ne 'cleanup-review-required'){Write-Host ($run|ConvertTo-Json -Depth 20)}
    Assert ($run.status -eq 'cleanup-review-required' -and @($run.data.entries|Where-Object {$_.registrationAbsent}).Count -eq 2 -and (Get-Content $case.counter).Count -eq 2) 'Two exact harmless removal commands run sequentially and registration absence is verified'
    Assert ($run.data.entries[0].output.stdout -like '*vendor console message*' -and $run.data.entries[0].output.stderr -like '*Vendor diagnostic*') 'Vendor stdout and stderr are captured inside the response without contaminating its JSON'
    $again=Read-Result (& $runScript @a)
    Assert ($again.status -eq 'cleanup-review-required' -and (Get-Content $case.counter).Count -eq 2) 'Replaying a completed bulk queue does not run either remover again'
    $commandLines=@(Get-Content -LiteralPath ($case.counter+'.command-lines'))
    Assert ($commandLines.Count -eq 2 -and $commandLines[0] -ceq $case.plan.entries[0].commandLine -and $commandLines[1] -ceq $case.plan.entries[1].commandLine) 'Each remover receives exactly the reviewed command line, including spaces, quotes and a trailing backslash'
    $case=New-Case 'unquoted' -Unquoted;$a=$case.args
    $argumentText=Join-RooIndustriesWindowsArguments @($case.markers[0],$case.counter,'0','remove',($a.JournalPath+'.cancel'),'quoted "value" with trailing\')
    Assert (@($case.plan.entries|Where-Object {$_.executable -ceq $case.exe}).Count -eq 2 -and $case.plan.entries[0].rawArguments -ceq $argumentText -and $case.plan.entries[0].commandLine -ceq ('"'+$case.exe+'" '+$argumentText)) 'An unquoted registry path with spaces, with or without .exe, resolves to the existing program and the rest becomes its arguments'
    $unquoted=Read-Result (& $runScript @a)
    $commandLines=@(Get-Content -LiteralPath ($case.counter+'.command-lines'))
    Assert ($unquoted.status -eq 'cleanup-review-required' -and $commandLines.Count -eq 2 -and $commandLines[0] -ceq $case.plan.entries[0].commandLine -and $commandLines[1] -ceq $case.plan.entries[1].commandLine) 'Unquoted removal commands run exactly as reviewed'
    $missingInventory=Join-Path $case.directory 'missing-inventory.json'
    $missingApp=[pscustomobject]@{appId='fixture:unquoted-missing';displayName='Roo Industries missing remover';publisher='Roo Industries Fixture';sourceType='registry';
        sourceIdentity=@{kind='fixture';presencePath=$case.markers[0]};risk='low';protected=$false;categories=@('application');uninstallString=(Join-Path $case.directory 'Missing Folder\uninst.exe')+' /S'}
    [IO.File]::WriteAllText($case.markers[0],'installed')
    Write-RooIndustriesOperationJson @{schemaVersion=1;apps=@($missingApp)} $missingInventory
    $missing=Read-Result (& $planScript -AppId @($missingApp.appId) -InventoryPath $missingInventory -FixtureRoot $case.directory)
    Assert ($missing.status -eq 'failed' -and $missing.errors[0].message -like '*does not start with an existing program*') 'An unquoted command whose program cannot be found is refused instead of guessed'
    $case=New-Case 'cancel' 'cancel';$a=$case.args
    $canceled=Read-Result (& $runScript @a)
    Assert ($canceled.status -eq 'canceled' -and -not(Test-Path $case.markers[0]) -and (Test-Path $case.markers[1]) -and $canceled.data.entries[1].attemptCount -eq 0) 'Cancellation between entries leaves untouched applications installed'
    $resume=Read-Result (& $runScript @a)
    Assert ($resume.status -eq 'cleanup-review-required' -and (Get-Content $case.counter).Count -eq 2) 'A confirmed resume executes only the untouched remainder'
    $case=New-Case 'contradictory-success' 'keep';$a=$case.args
    $uncertain=Read-Result (& $runScript @a)
    Assert ($uncertain.status -eq 'needs-reconciliation' -and (Test-Path $case.markers[0]) -and $uncertain.data.entries[1].attemptCount -eq 0) 'Exit zero with the exact registration still present does not prove removal'
    $again=Read-Result (& $runScript @a)
    Assert ($again.status -eq 'needs-reconciliation' -and @(Get-Content $case.counter).Count -eq 1) 'An uncertain earlier invocation is never retried automatically'
    Remove-Item -LiteralPath $case.markers[0]
    $reconciled=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($reconciled.status -eq 'ready' -and $reconciled.data.entries[0].registrationAbsent -and $reconciled.data.entries[1].attemptCount -eq 0) 'Reconciliation uses observed registration absence without dispatching another command'
    $resumed=Read-Result (& $runScript @a)
    Assert ($resumed.status -eq 'cleanup-review-required' -and @(Get-Content $case.counter).Count -eq 2) 'Reconciled completion permits only previously untouched queue entries'
    $case=New-Case 'generic-msi-code' 'remove' 3010;$a=$case.args
    $notMsi=Read-Result (& $runScript @a)
    Assert ($notMsi.status -eq 'needs-reconciliation' -and -not $notMsi.data.entries[0].outcome.success -and $notMsi.data.entries[1].attemptCount -eq 0) 'An arbitrary executable returning 3010 does not inherit MSI success semantics'
    $case=New-Case 'changed-executable';$a=$case.args
    [IO.File]::AppendAllText($case.exe,'changed after preview')
    $stale=Read-Result (& $runScript @a)
    Assert ($stale.status -eq 'needs-reconciliation' -and $stale.data.entries[0].attemptCount -eq 0 -and -not(Test-Path $case.counter)) 'A replaced executable is rejected before any dispatch intent or process launch'
    $case=New-Case 'timeout' 'wait';$a=$case.args;$a.TimeoutSeconds=1
    $timed=Read-Result (& $runScript @a)
    $invocation=$timed.data.entries[0].invocation
    $process=[Diagnostics.Process]::GetProcessById([int]$invocation.processId);$liveFixtures.Add($process)|Out-Null
    Assert ($timed.status -eq 'needs-reconciliation' -and -not $process.HasExited -and $timed.data.entries[1].attemptCount -eq 0) 'Observation timeout leaves the remover intact and prevents the next entry from starting'
    $check=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($check.status -eq 'needs-reconciliation' -and (Test-Path $case.markers[0])) 'A still-running exact process cannot be reconciled as completed'
    $liveDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    Assert ($liveDismiss.status -eq 'failed' -and $liveDismiss.errors[0].message -like '*still running*' -and (Read-RooIndustriesOperationJson $a.JournalPath).data.status -eq 'needs-reconciliation') 'Start over refuses a list whose remover process is still running'
    $process.Kill();Assert ($process.WaitForExit(10000)) 'Disposable timed-out remover is explicitly stopped and its exit verified'
    $case=New-Case 'shell-host' 'shell';$a=$case.args;$a.TimeoutSeconds=20
    $shellRun=Read-Result (& $runScript @a)
    $shellHost=@(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.ExecutablePath -like (Join-Path $case.directory 'shell host\*') })
    foreach($member in $shellHost){$liveFixtures.Add([Diagnostics.Process]::GetProcessById([int]$member.ProcessId))|Out-Null}
    Assert ($shellRun.status -eq 'cleanup-review-required' -and $shellHost.Count -eq 1 -and @($shellRun.data.entries[0].invocation.descendants|Where-Object {$_.name -ieq 'explorer.exe'}).Count -eq 0) 'A remover that restarts Explorer or opens a browser is verified without waiting for that long-lived process, which is left running'
    foreach($member in $shellHost){Stop-Process -Id $member.ProcessId -Force;Wait-Process -Id $member.ProcessId -Timeout 10 -ErrorAction SilentlyContinue}
    $case=New-Case 'handoff' 'handoff';$a=$case.args
    $handoff=Read-Result (& $runScript @a)
    Assert ($handoff.status -eq 'cleanup-review-required' -and (Test-Path ($case.markers[0]+'.done')) -and @($handoff.data.entries[0].invocation.descendants|Where-Object {$_.name -ieq 'Au_.exe'}).Count -eq 1) 'A remover that hands off to a temporary copy is verified only after that copy finishes'
    $case=New-Case 'handoff-hang' 'handoff-hang';$a=$case.args;$a.TimeoutSeconds=5
    $hung=Read-Result (& $runScript @a)
    $child=@($hung.data.entries[0].invocation.descendants|Where-Object {$_.name -ieq 'Au_.exe'})
    Assert ($hung.status -eq 'needs-reconciliation' -and $hung.data.entries[0].state -eq 'needs-reconciliation' -and -not $hung.data.entries[0].registrationAbsent -and $child.Count -eq 1 -and $hung.data.entries[1].attemptCount -eq 0) 'A handed-off remover that never exits keeps the entry unresolved'
    $childProcess=[Diagnostics.Process]::GetProcessById([int]$child[0].processId);$liveFixtures.Add($childProcess)|Out-Null
    $whileRunning=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($whileRunning.status -eq 'needs-reconciliation' -and $whileRunning.data.entries[0].state -eq 'needs-reconciliation' -and -not(Test-Path $case.markers[0]) -and -not $childProcess.HasExited) 'Check state does not report removal while the handed-off remover is still running, and does not stop it'
    $childProcess.Kill();Assert ($childProcess.WaitForExit(10000)) 'Disposable handed-off remover is explicitly stopped and its exit verified'
    Write-Host ('Recorded remover tree: '+(@($hung.data.entries[0].invocation.descendants|ForEach-Object {$_.name})-join ', '))
    foreach($member in @($hung.data.entries[0].invocation.descendants)){Wait-Process -Id ([int]$member.processId) -Timeout 10 -ErrorAction SilentlyContinue}
    $afterExit=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($afterExit.status -eq 'ready' -and $afterExit.data.entries[0].state -eq 'removed' -and $afterExit.data.entries[1].attemptCount -eq 0) 'Check state reports removal once the handed-off remover has exited and the registration is gone'
    $case=New-Case 'leftover-tab-claim';$a=$case.args
    $claimFile=Get-RooIndustriesBulkClaimPath $case.plan.entries[0] $case.directory
    $self=[Diagnostics.Process]::GetCurrentProcess()
    Write-RooIndustriesOperationJson ([pscustomobject]@{kind='cleanup-apply';appId=$case.plan.entries[0].appId;invocation=[pscustomobject]@{processId=$PID;creationTimeFileTimeUtc=$self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();descendants=@()}}) $claimFile
    $busyClaim=Read-Result (& $runScript @a)
    Assert ($busyClaim.status -eq 'needs-reconciliation' -and $busyClaim.data.entries[0].error -like '*Leftover cleanup is still running*' -and -not(Test-Path $case.counter)) 'A running Leftover cleanup remover blocks the same app in the removal queue'
    Remove-Item -LiteralPath $a.JournalPath
    Write-RooIndustriesOperationJson ([pscustomobject]@{kind='cleanup-apply';appId=$case.plan.entries[0].appId;invocation=[pscustomobject]@{processId=$PID;creationTimeFileTimeUtc='1';descendants=@()}}) $claimFile
    $staleClaim=Read-Result (& $runScript @a)
    Assert ($staleClaim.status -eq 'cleanup-review-required' -and -not(Test-Path -LiteralPath $claimFile)) 'A finished Leftover cleanup remover no longer blocks the removal queue'
    $case=New-Case 'unreadable-remover';$a=$case.args
    $deniedExe=Join-Path $case.directory 'unreadable remover.exe';Copy-Item -LiteralPath $script:fixtureExe -Destination $deniedExe
    $deniedStart=[Diagnostics.ProcessStartInfo]::new($deniedExe,'x y 0 child-shell');$deniedStart.UseShellExecute=$false;$deniedStart.CreateNoWindow=$true
    $denied=[Diagnostics.Process]::Start($deniedStart);$liveFixtures.Add($denied)|Out-Null
    $deniedCreated=$denied.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    [RooIndustriesBulkAccessFixture]::DenyAll($denied.Handle)
    $journal=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-journal';status='needs-reconciliation';reviewSha256=$a.ReviewSha256.ToLowerInvariant();plan=$case.plan;bootTimeUtc=Get-RooIndustriesBulkBootTime;updatedAtUtc=Get-RooIndustriesUtcStamp;
        entries=@($case.plan.entries|ForEach-Object {[pscustomobject]@{entryId=$_.entryId;appId=$_.appId;state='pending';attemptCount=0;invocation=$null;outcome=$null;error=$null;registrationAbsent=$false;updatedAtUtc=Get-RooIndustriesUtcStamp}})}
    $journal.entries[0].state='needs-reconciliation';$journal.entries[0].attemptCount=1
    $journal.entries[0].invocation=[pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$deniedCreated;descendants=@()}
    Remove-Item -LiteralPath $case.markers[0]
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $deniedClaim=Get-RooIndustriesBulkClaimPath $case.plan.entries[0] $case.directory
    Write-RooIndustriesOperationJson ([pscustomobject]@{queueId=$case.plan.queueId;entryId=$case.plan.entries[0].entryId;journalPath=$a.JournalPath}) $deniedClaim
    Import-RooIndustriesBulkProcessTypes
    $debug=[RooIndustriesBulkAccessFixture]::SetDebug($false)
    try {
        $openError=[RooIndustriesBulkAccessFixture]::OpenError($denied.Id)
        $unreadable=[RooIndustries.Optimization.ProcessOutput.Tree]::Probe($denied.Id,$deniedCreated) -ne 0
        $lastBoot=([datetime](Get-RooIndustriesBulkBootTime)).ToUniversalTime()
        $reusedAfterRestart=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$lastBoot.AddHours(-2).ToFileTimeUtc().ToString();descendants=@()})
        $nearBoot=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$lastBoot.AddMinutes(-1).ToFileTimeUtc().ToString();descendants=@()})
        $currentBootId=Get-RooIndustriesBootId
        $bootIdOnly=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$deniedCreated;bootId='roo-industries-other-boot';descendants=@()})
        $bootTimeOnly=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$lastBoot.AddHours(-2).ToFileTimeUtc().ToString();bootId=$currentBootId;descendants=@()})
        $bothChanged=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$lastBoot.AddHours(-2).ToFileTimeUtc().ToString();bootId='roo-industries-other-boot';descendants=@()})
        $sameBoot=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$denied.Id;creationTimeFileTimeUtc=$deniedCreated;bootId=$currentBootId;descendants=@()})
        $self=[Diagnostics.Process]::GetCurrentProcess()
        $hibernated=Test-RooIndustriesBulkInvocationLive ([pscustomobject]@{processId=$self.Id;creationTimeFileTimeUtc=$self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();bootId='roo-industries-other-boot';descendants=@()})
        $shiftedSameBoot=Test-RooIndustriesBulkRestartAfterInvocation ([pscustomobject]@{processId=$self.Id;creationTimeFileTimeUtc=$lastBoot.AddHours(-2).ToFileTimeUtc().ToString();bootId=$currentBootId})
        $shiftedOtherBoot=Test-RooIndustriesBulkRestartAfterInvocation ([pscustomobject]@{processId=$self.Id;creationTimeFileTimeUtc=$lastBoot.AddHours(1).ToFileTimeUtc().ToString();bootId='roo-industries-other-boot'})
        $restartedBoth=Test-RooIndustriesBulkRestartAfterInvocation ([pscustomobject]@{processId=$self.Id;creationTimeFileTimeUtc=$lastBoot.AddHours(-2).ToFileTimeUtc().ToString();bootId='roo-industries-other-boot'})
        $deniedReconcile=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
        $deniedDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    } finally {[RooIndustriesBulkAccessFixture]::RestoreDebug($debug)}
    Assert ($openError -eq 5) "The unreadable remover fixture refuses inspection with access denied (error $openError)"
    Assert $unreadable 'A remover Windows refuses to open is treated as still running, never as stopped'
    Assert (-not $reusedAfterRestart) 'A remover recorded well before the last restart is not running, even when its process ID now belongs to a process that cannot be opened'
    Assert $nearBoot 'A remover recorded just before the reported boot time is still checked, so a clock jump cannot make it look stopped'
    Assert ($currentBootId -and $bootIdOnly -and $bootTimeOnly -and -not $bothChanged -and $sameBoot) "An unreadable remover counts as gone only when both the boot ID changed and the boot time is later than its start (boot ID $currentBootId)"
    Assert $hibernated 'A readable process whose ID and start time still match stays running even under a different boot ID'
    Assert (-not $shiftedSameBoot -and -not $shiftedOtherBoot -and $restartedBoth) 'A restart is recognised only when the boot ID changed and the boot time is later than the remover'
    Assert ($deniedReconcile.status -eq 'needs-reconciliation' -and $deniedReconcile.data.entries[0].state -eq 'needs-reconciliation' -and $deniedReconcile.data.entries[0].error -like "*still running or can't be checked*" -and -not $deniedReconcile.data.entries[0].registrationAbsent) 'Check state reports an unreadable remover as still running or unchecked instead of removed'
    Assert ($deniedDismiss.status -eq 'failed' -and $deniedDismiss.errors[0].message -like "*still running or can't be checked*" -and (Test-Path -LiteralPath $deniedClaim) -and (Read-RooIndustriesOperationJson $a.JournalPath).data.status -ne 'dismissed') 'Start over refuses while a remover cannot be checked and keeps its claim'
    $denied.Kill();Assert ($denied.WaitForExit(10000)) 'Disposable unreadable remover is explicitly stopped and its exit verified'
    $killBeforeRecord=@'
Import-Module Microsoft.PowerShell.Management
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath,[string[]]$Name)
    if($Name -contains 'BootId'){[Diagnostics.Process]::GetCurrentProcess().Kill()}
    Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
}
'@
    $killAfterRecord=@'
Import-Module Microsoft.PowerShell.Utility
function global:Start-Sleep {
    [CmdletBinding()] param([int]$Seconds,[int]$Milliseconds)
    if($Milliseconds -eq 250){[Diagnostics.Process]::GetCurrentProcess().Kill()}
    Microsoft.PowerShell.Utility\Start-Sleep @PSBoundParameters
}
'@
    $case=New-Case 'queue-killed-before-record' 'wait';$a=$case.args
    [void](Invoke-ChildQueue $a $killBeforeRecord $case.directory)
    $settle=[DateTime]::UtcNow.AddSeconds(10)
    while(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $case.exe}).Count -gt 0 -and [DateTime]::UtcNow -lt $settle){Start-Sleep -Milliseconds 100}
    $killedJournal=(Read-RooIndustriesOperationJson $a.JournalPath).data
    $killedClaim=Get-RooIndustriesBulkClaimPath $case.plan.entries[0] $case.directory
    $killedLeft=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $case.exe}).Count
    $killedDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    Assert (-not(Test-Path $case.counter) -and $killedLeft -eq 0 -and $killedJournal.entries[0].state -eq 'dispatching' -and $null -eq $killedJournal.entries[0].invocation -and $killedDismiss.status -eq 'dismissed' -and -not(Test-Path -LiteralPath $killedClaim)) "A queue killed before it records its remover leaves a remover that never ran, and Start over clears it ($killedLeft left)"
    $case=New-Case 'queue-killed-after-record' 'wait';$a=$case.args
    [void](Invoke-ChildQueue $a $killAfterRecord $case.directory)
    $recordedJournal=(Read-RooIndustriesOperationJson $a.JournalPath).data
    $recordedPid=[int](@($recordedJournal.entries)[0].invocation.processId)
    $recordedAlive=$recordedPid -gt 0 -and $null -ne (Get-Process -Id $recordedPid -ErrorAction SilentlyContinue)
    $recordedDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    Assert ($recordedAlive -and $recordedDismiss.status -eq 'failed' -and $recordedDismiss.errors[0].message -like "*still running or can't be checked*") "Start over refuses while a queue remover recorded before the host was killed is alive (pid $recordedPid)"
    if($recordedPid -gt 0){$recordedProcess=Get-Process -Id $recordedPid -ErrorAction SilentlyContinue;if($recordedProcess){$recordedProcess.Kill();[void]$recordedProcess.WaitForExit(10000)}}
    $case=New-Case 'queue-appx-style-claim' 'keep';$a=$case.args
    $journal=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-journal';status='running';reviewSha256=$a.ReviewSha256.ToLowerInvariant();plan=$case.plan;bootTimeUtc=Get-RooIndustriesBulkBootTime;updatedAtUtc=Get-RooIndustriesUtcStamp;
        entries=@($case.plan.entries|ForEach-Object {[pscustomobject]@{entryId=$_.entryId;appId=$_.appId;state='pending';attemptCount=0;invocation=$null;outcome=$null;error=$null;registrationAbsent=$false;updatedAtUtc=Get-RooIndustriesUtcStamp}})}
    $journal.entries[0].state='dispatching';$journal.entries[0].attemptCount=1
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $appxClaim=Get-RooIndustriesBulkClaimPath $case.plan.entries[0] $case.directory
    $powershellExe=Join-Path $PSHOME 'powershell.exe'
    Write-RooIndustriesOperationJson ([pscustomobject]@{queueId=$case.plan.queueId;entryId=$case.plan.entries[0].entryId;journalPath=$a.JournalPath;executable=$powershellExe;claimedAtUtc=Get-RooIndustriesUtcStamp}) $appxClaim
    $unrelatedStart=[Diagnostics.ProcessStartInfo]::new($powershellExe,'-NoProfile -Command Start-Sleep -Seconds 60');$unrelatedStart.UseShellExecute=$false;$unrelatedStart.CreateNoWindow=$true
    $unrelated=[Diagnostics.Process]::Start($unrelatedStart)
    try {$appxDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)}
    finally {if(-not $unrelated.HasExited){$unrelated.Kill()};[void]$unrelated.WaitForExit(10000)}
    Assert ($appxDismiss.status -eq 'dismissed' -and -not(Test-Path -LiteralPath $appxClaim)) 'Start over clears an Appx-style claim with no recorded remover even while an unrelated powershell.exe runs'
    $case=New-Case 'queue-linked-remover' -ExeInBin;$a=$case.args
    $binDir=Split-Path $case.exe -Parent
    $linkPrelude=@'
Import-Module Microsoft.PowerShell.Utility
function global:Get-FileHash {
    [CmdletBinding()] param([string]$LiteralPath,[string]$Algorithm)
    $value=Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters
    if($LiteralPath -like '*\queue-linked-remover\installed 1.txt' -and -not $global:RooIndustriesLinked){
        $global:RooIndustriesLinked=$true
        $bin=Join-Path (Split-Path $LiteralPath -Parent) 'bin'
        [IO.Directory]::Move($bin,$bin+'-real')
        cmd.exe /c mklink /J "$bin" "$bin-real" | Out-Null
    }
    return $value
}
'@
    $linkedOutput=Invoke-ChildQueue $a $linkPrelude $case.directory
    $linkedJournal=(Read-RooIndustriesOperationJson $a.JournalPath).data
    $wasLinked=(Get-Item -LiteralPath $binDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
    cmd.exe /c rmdir "$binDir" | Out-Null
    [IO.Directory]::Move($binDir+'-real',$binDir)
    Assert ($wasLinked -and -not(Test-Path $case.counter) -and $linkedJournal.entries[0].state -eq 'failed-before-start' -and $linkedJournal.entries[0].error -like '*reached through a link*') "A queue remover whose path becomes a link after review is refused inside the launch lease ($($linkedJournal.entries[0].state): $($linkedJournal.entries[0].error))"
    $case=New-Case 'queue-start-failed' -BrokenExe;$a=$case.args
    $startFailed=Read-Result (& $runScript @a)
    $startChecked=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($startFailed.data.entries[0].attemptCount -eq 1 -and $null -eq $startFailed.data.entries[0].invocation -and $startChecked.data.entries[0].launchUnconfirmed -ne $true) "A remover Windows refused to start is not marked as an unconfirmed launch ($($startFailed.data.entries[0].error))"
    $case=New-Case 'crash-intent';$a=$case.args
    $journal=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-journal';status='running';reviewSha256=$a.ReviewSha256.ToLowerInvariant();plan=$case.plan;updatedAtUtc=Get-RooIndustriesUtcStamp;
        entries=@($case.plan.entries|ForEach-Object {[pscustomobject]@{entryId=$_.entryId;appId=$_.appId;state='pending';attemptCount=0;invocation=$null;outcome=$null;error=$null;registrationAbsent=$false;updatedAtUtc=Get-RooIndustriesUtcStamp}})}
    $journal.entries[0].state='dispatching';$journal.entries[0].attemptCount=1
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $crash=Read-Result (& $runScript @a)
    Assert ($crash.status -eq 'needs-reconciliation' -and -not(Test-Path $case.counter)) 'A crash after durable dispatch intent cannot silently launch the uncertain entry again'
    $crashChecked=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($crashChecked.data.entries[0].launchUnconfirmed -eq $true -and $crashChecked.data.entries[0].state -eq 'needs-reconciliation' -and -not(Test-Path $case.counter)) 'Check state keeps the mark that a remover launch was never confirmed'
    $journal|Add-Member -NotePropertyName bootTimeUtc -NotePropertyValue (Get-RooIndustriesBulkBootTime)
    $journal.entries[0].state='reboot-required';$journal.entries[0].outcome=Get-RooIndustriesUninstallOutcome windows-installer 3010
    $journal.entries[0].invocation=@{processId=$PID;creationTimeFileTimeUtc=([Diagnostics.Process]::GetCurrentProcess()).StartTime.ToUniversalTime().ToFileTimeUtc().ToString()}
    Remove-Item -LiteralPath $case.markers[0];$journal.entries[0].registrationAbsent=$true
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $beforeReboot=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($beforeReboot.status -eq 'reboot-required' -and $beforeReboot.data.entries[1].attemptCount -eq 0) 'Registration absence cannot clear an MSI reboot requirement during the same boot'
    $exitedRemover=($journal|ConvertTo-Json -Depth 32)|ConvertFrom-Json
    $exitedRemover.entries[0].invocation=[pscustomobject]@{processId=2147483646;creationTimeFileTimeUtc=[DateTime]::UtcNow.ToFileTimeUtc().ToString()}
    Write-RooIndustriesOperationJson $exitedRemover $a.JournalPath
    $pendingDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    Assert ($pendingDismiss.status -eq 'failed' -and $pendingDismiss.errors[0].message -like 'Restart Windows*' -and (Read-RooIndustriesOperationJson $a.JournalPath).data.status -eq $exitedRemover.status) 'Start over waits for the restart a removal still needs'
    $journal.bootTimeUtc='2000-01-01T00:00:00Z';Write-RooIndustriesOperationJson $journal $a.JournalPath
    $resumedQueue=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($resumedQueue.status -eq 'reboot-required' -and $resumedQueue.data.entries[1].attemptCount -eq 0) 'An earlier reboot recorded for the queue cannot clear a later remover restart requirement'
    $journal.entries[0].invocation.creationTimeFileTimeUtc=([datetime](Get-RooIndustriesBulkBootTime)).ToUniversalTime().AddMinutes(-1).ToFileTimeUtc().ToString()
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $afterReboot=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($afterReboot.status -eq 'ready' -and $afterReboot.data.entries[0].state -eq 'removed' -and -not(Test-Path $case.counter)) 'A boot after the remover creation time and absent registration reconcile without dispatching an uninstaller'
    $case=New-Case 'changed-registration';$a=$case.args
    [IO.File]::WriteAllText($case.markers[0],'reinstalled after preview')
    $changedRegistration=Read-Result (& $runScript @a)
    Assert ($changedRegistration.status -eq 'needs-reconciliation' -and $changedRegistration.data.entries[0].attemptCount -eq 0 -and -not(Test-Path $case.counter)) 'A changed installed record invalidates the reviewed removal command before dispatch'
    $case=New-Case 'overlapping-queue' 'keep';$a=$case.args
    $first=Read-Result (& $runScript @a)
    $otherPlan=Read-RooIndustriesOperationJson $case.planPath;$otherPlan.data.data.queueId=[guid]::NewGuid().ToString('N')
    $otherPath=Join-Path $case.directory 'second-plan.json';Write-RooIndustriesOperationJson $otherPlan.data $otherPath
    $other=Read-Result (& $runScript -Action Apply -InputPath $otherPath -ReviewSha256 (Get-FileHash $otherPath).Hash -JournalPath (Join-Path $case.directory 'second-journal.json') -ConfirmApply -ManualReviewApproved -AllowFixtureExecution)
    Assert ($other.status -eq 'needs-reconciliation' -and $other.data.entries[0].attemptCount -eq 0 -and @(Get-Content $case.counter).Count -eq 1) 'A different queue cannot relaunch an app with an unresolved durable removal claim'
    $stuck=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($stuck.status -eq 'needs-reconciliation' -and (Test-Path $case.markers[0])) 'A failed removal whose app is still installed stays unresolved after checking its state'
    $claimPath=Get-RooIndustriesBulkClaimPath $case.plan.entries[0] ([string]$case.plan.fixtureRoot)
    $unconfirmed=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath)
    Assert ($unconfirmed.status -eq 'preview' -and (Read-RooIndustriesOperationJson $a.JournalPath).data.status -eq 'needs-reconciliation' -and (Test-Path -LiteralPath $claimPath)) 'Start over without confirmation changes nothing'
    $lease=Lock-RooIndustriesOperation $a.JournalPath
    try{$busyDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)}finally{$lease.Dispose()}
    Assert ($busyDismiss.status -eq 'failed' -and $busyDismiss.errors[0].message -like '*still running*' -and (Test-Path -LiteralPath $claimPath)) 'Start over refuses a list another process is still running'
    $dismissed=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    Assert ($dismissed.status -eq 'dismissed' -and (Read-RooIndustriesOperationJson $a.JournalPath).data.status -eq 'dismissed' -and -not(Test-Path -LiteralPath $claimPath) -and @(Get-Content $case.counter).Count -eq 1) 'Start over clears a failed list and releases its app without running anything'
    $replayed=Read-Result (& $runScript @a)
    $rechecked=Read-Result (& $runScript -Action Reconcile -JournalPath $a.JournalPath -AllowFixtureExecution -ConfirmApply)
    Assert ($replayed.status -eq 'failed' -and $rechecked.status -eq 'failed' -and @(Get-Content $case.counter).Count -eq 1) 'A cleared list cannot be resumed or checked again'
    $retryPlan=Read-RooIndustriesOperationJson $case.planPath;$retryPlan.data.data.queueId=[guid]::NewGuid().ToString('N')
    $retryPath=Join-Path $case.directory 'retry-plan.json';Write-RooIndustriesOperationJson $retryPlan.data $retryPath
    $retry=Read-Result (& $runScript -Action Apply -InputPath $retryPath -ReviewSha256 (Get-FileHash $retryPath).Hash -JournalPath (Join-Path $case.directory 'retry-journal.json') -ConfirmApply -ManualReviewApproved -AllowFixtureExecution)
    Assert ($retry.data.entries[0].attemptCount -eq 1 -and @(Get-Content $case.counter).Count -eq 2) 'After starting over, a new list can retry the app that failed'
    $case=New-Case 'partial-dismiss' 'cancel';$a=$case.args
    $partial=Read-Result (& $runScript @a)
    $partialDismiss=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    $kept=(Read-RooIndustriesOperationJson $a.JournalPath).data.entries
    $partialScan=Read-Result (& (Join-Path $PSScriptRoot 'Invoke-RemovalLeftovers.ps1') -Action Scan -QueueJournalPath $a.JournalPath -AppId $case.plan.entries[0].appId)
    $case=New-Case 'restart-no-invocation';$a=$case.args
    $journal=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-journal';status='reboot-required';reviewSha256=$a.ReviewSha256.ToLowerInvariant();plan=$case.plan;updatedAtUtc=Get-RooIndustriesUtcStamp;
        entries=@($case.plan.entries|ForEach-Object {[pscustomobject]@{entryId=$_.entryId;appId=$_.appId;state='pending';attemptCount=0;invocation=$null;outcome=$null;error=$null;registrationAbsent=$false;updatedAtUtc=Get-RooIndustriesUtcStamp}})}
    $journal.entries[0].state='reboot-required';$journal.entries[0].attemptCount=1
    Write-RooIndustriesOperationJson $journal $a.JournalPath
    $sameBoot=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    $journal.entries[0].updatedAtUtc='2000-01-01T00:00:00.0000000Z';Write-RooIndustriesOperationJson $journal $a.JournalPath
    $afterBoot=Read-Result (& $runScript -Action Dismiss -JournalPath $a.JournalPath -ConfirmApply)
    Assert ($sameBoot.status -eq 'failed' -and $sameBoot.errors[0].message -like 'Restart Windows*' -and $afterBoot.status -eq 'dismissed') 'A restart-pending entry without remover details can still be cleared once Windows has restarted'
    Assert ($partial.status -eq 'canceled' -and $partialDismiss.status -eq 'dismissed' -and $kept[0].state -eq 'removed' -and $kept[0].registrationAbsent -and $kept[1].attemptCount -eq 0 -and (Test-Path $case.markers[1]) -and $partialScan.status -eq 'preview') 'Starting over a partly finished list keeps finished removals available for leftover review'
    $case=New-Case 'bounded-output' 'verbose';$a=$case.args
    $verbose=Read-Result (& $runScript @a)
    Assert ($verbose.status -eq 'cleanup-review-required' -and $verbose.data.entries[0].output.truncated -and $verbose.data.entries[0].output.stdout.Length -eq 65536) 'Verbose vendor output is drained while retained text stays within its explicit memory limit'
    $case=New-Case 'routed';$a=$case.args
    $requestPath=Join-Path $case.directory 'apply request.json'
    Write-RooIndustriesOperationJson @{schemaVersion=1;inputPath=$case.planPath;reviewSha256=$a.ReviewSha256;journalPath=$a.JournalPath;manualReviewApproved=$true;allowFixtureExecution=$true} $requestPath
    $routed=Read-Result (& (Join-Path $PSScriptRoot 'Invoke-RooIndustriesCapability.ps1') -CapabilityId 'cleanup-uninstall.bulk-removal' -Action apply -RequestPath $requestPath -ConfirmApply)
    Assert ($routed.status -eq 'completed' -and $routed.changed -and $routed.evidence.status -eq 'cleanup-review-required' -and @(Get-Content $case.counter).Count -eq 2) 'Capability router executes the reviewed bulk request and reports actual dispatch evidence'
    $leftoverScript=Join-Path $PSScriptRoot 'Invoke-RemovalLeftovers.ps1'
    $appId=$case.plan.entries[0].appId
    $scan=Read-Result (& $leftoverScript -Action Scan -QueueJournalPath $a.JournalPath -AppId $appId)
    $target=Join-Path $case.directory 'app-1'
    $item=@($scan.data.items|Where-Object {$_.target -ieq $target})
    Assert ($scan.status -eq 'preview' -and $item.Count -eq 1 -and (Test-Path $target)) 'Post-removal scan uses saved app metadata and observes current leftovers'
    $reviewPath=Join-Path $case.directory 'leftover-review.json'
    $review=Read-Result (& $leftoverScript -Action Preview -QueueJournalPath $a.JournalPath -AppId $appId -ItemId $item[0].itemId -OutputPath $reviewPath)
    $hash=(Get-FileHash $reviewPath).Hash
    $previewOnly=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash)
    Assert ($previewOnly.status -eq 'preview' -and $previewOnly.dryRun -and (Test-Path $target) -and -not(Test-Path $review.data.rollbackPath)) 'Unconfirmed leftover cleanup creates no deletion or recovery files'
    $changedReview=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 ('0'*64) -ConfirmApply -ManualReviewApproved)
    Assert ($changedReview.status -eq 'failed' -and (Test-Path $target)) 'An altered leftover review hash is rejected before deletion'
    [IO.File]::WriteAllText($case.markers[0],'reinstalled')
    $reinstalled=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply -ManualReviewApproved)
    Assert ($reinstalled.status -eq 'failed' -and (Test-Path $target)) 'An app registered again cannot reuse the old removal approval for cleanup'
    Remove-Item -LiteralPath $case.markers[0]
    $journalHash=(Get-FileHash $a.JournalPath).Hash
    $collision=Read-Result (& $leftoverScript -Action Scan -QueueJournalPath $a.JournalPath -AppId $appId -OutputPath $a.JournalPath)
    Assert ($collision.status -eq 'failed' -and (Get-FileHash $a.JournalPath).Hash -eq $journalHash) 'Scan output cannot overwrite its removal journal'
    $clean=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply -ManualReviewApproved)
    Assert ($clean.status -eq 'success' -and -not(Test-Path $target) -and $clean.data.summary.deletedCount -eq 1) 'A separately reviewed post-removal cleanup deletes only the selected fixture folder'
    $restored=Read-Result (& $leftoverScript -Action Restore -QueueJournalPath $a.JournalPath -AppId $appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply)
    Assert ($restored.status -eq 'success' -and [IO.File]::ReadAllText((Join-Path $target 'settings.txt')) -ceq 'original settings' -and [IO.File]::ReadAllText((Join-Path $case.directory 'app-2\settings.txt')) -ceq 'original settings') 'Post-removal file cleanup restores its backed-up contents and leaves the other app unchanged'
    $wrong=Read-Result (& $leftoverScript -Action Apply -QueueJournalPath $a.JournalPath -AppId $case.plan.entries[1].appId -ReviewPath $reviewPath -ReviewSha256 $hash -ConfirmApply)
    Assert ($wrong.status -eq 'failed' -and (Test-Path $target)) 'A cleanup review cannot be replayed against another app in the queue'

} finally {
    foreach($process in @(Get-CimInstance Win32_Process|Where-Object {$_.Name -ieq 'msiexec.exe' -and $_.CommandLine -like "*$msiCode*"})){Stop-Process -Id $process.ProcessId -Force}
    $tracked=@($liveFixtures|ForEach-Object {$_.Id})
    foreach($process in @(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)})){
        if([int]$process.ProcessId -in $tracked){continue}
        try {$liveFixtures.Add([Diagnostics.Process]::GetProcessById([int]$process.ProcessId))|Out-Null} catch {}
    }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($msiKeyPath,$false)
    if(Test-Path -LiteralPath $msiClaim){Remove-Item -LiteralPath $msiClaim -Force}
    $cleanupErrors=@()
    foreach($process in $liveFixtures){
        try {if(-not $process.HasExited){$process.Kill()};if(-not $process.WaitForExit(10000)){$cleanupErrors+='Bulk fixture process '+$process.Id+' did not exit'}}
        catch {$cleanupErrors+='Bulk fixture process cleanup failed: '+$_.Exception.Message}
        finally {$process.Dispose()}
    }
    if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
if($cleanupErrors.Count){throw ($cleanupErrors -join '; ')}
Assert (-not(Test-Path $root) -and -not(Test-Path -LiteralPath ('HKCU:\'+$msiKeyPath)) -and -not(Test-Path -LiteralPath $msiClaim)) 'Bulk tests leave no fixture process, presence marker, registration, claim or journal behind'
