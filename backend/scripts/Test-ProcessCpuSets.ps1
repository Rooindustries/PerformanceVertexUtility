$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CpuSets.Common.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS $Message" }
function Read-Result($Lines) { return ($Lines -join [Environment]::NewLine) | ConvertFrom-Json }
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-cpu-sets-'+[guid]::NewGuid().ToString('N'))
$scriptPath=Join-Path $PSScriptRoot 'Invoke-ProcessCpuSets.ps1'
$probe=$null; $control=$null
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Initialize-RooCpuSets
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CpuSetOracle {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint length);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetKernelObjectSecurity(IntPtr handle, uint information, IntPtr descriptor);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessDefaultCpuSets(IntPtr process, [Out] uint[] ids, uint count, out uint needed);
    public static uint[] Read(int pid) {
        IntPtr h=OpenProcess(0x1000,false,pid);
        if(h==IntPtr.Zero) throw new Exception("Oracle OpenProcess failed");
        try { uint needed; uint[] ids=new uint[4096]; if(!GetProcessDefaultCpuSets(h,ids,(uint)ids.Length,out needed)) throw new Exception("Oracle query failed"); Array.Resize(ref ids,(int)needed); Array.Sort(ids); return ids; }
        finally {CloseHandle(h);}
    }
    public static void DenySetLimitedOnFixture(IntPtr handle) {
        IntPtr descriptor; uint length;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:(D;;0x2000;;;WD)(A;;GA;;;WD)",1,out descriptor,out length)) throw new Exception("Fixture descriptor failed");
        try {if(!SetKernelObjectSecurity(handle,4,descriptor)) throw new Exception("Fixture DACL failed: "+Marshal.GetLastWin32Error());}
        finally {LocalFree(descriptor);}
    }
}
'@
    $bytes=New-Object byte[] 40
    [BitConverter]::GetBytes([uint32]40).CopyTo($bytes,0)
    [BitConverter]::GetBytes([uint32]901).CopyTo($bytes,8)
    [BitConverter]::GetBytes([uint16]2).CopyTo($bytes,12)
    $bytes[14]=7; $bytes[15]=3; $bytes[16]=1; $bytes[17]=4; $bytes[18]=9; $bytes[19]=15; $bytes[20]=12
    $parsed=@([Roo.Optimization.CpuSets.TopologyReader]::Parse($bytes))
    Assert ($parsed.Count -eq 1 -and $parsed[0].id -eq 901 -and $parsed[0].group -eq 2 -and $parsed[0].logicalProcessorIndex -eq 7 -and $parsed[0].coreIndex -eq 3 -and $parsed[0].efficiencyClass -eq 9 -and $parsed[0].schedulingClass -eq 12 -and $parsed[0].parked -and $parsed[0].allocatedToTargetProcess) 'Variable records preserve opaque IDs, processor groups, topology and flags'
    $unknown=New-Object byte[] 8; [BitConverter]::GetBytes([uint32]8).CopyTo($unknown,0); $unknown[4]=9
    Assert (@([Roo.Optimization.CpuSets.TopologyReader]::Parse([byte[]]($unknown+$bytes))).Count -eq 1) 'Unknown record types are skipped by their declared size'
    foreach ($invalid in @(@(0,0,0,0,0,0,0,0),@(32,0,0,0),@(24,0,0,0,0,0,0,0),($bytes+$bytes))) {
        $rejected=$false; try { [Roo.Optimization.CpuSets.TopologyReader]::Parse([byte[]]$invalid) | Out-Null } catch { $rejected=$true }
        Assert $rejected 'Malformed, truncated or duplicate topology cannot authorize selection'
    }
    $exe=Join-Path $root 'RooCpuSet Probe.exe'
    Add-Type -TypeDefinition 'using System.Threading; public class RooCpuSetProbe { public static void Main() { Thread.Sleep(120000); } }' -OutputAssembly $exe -OutputType ConsoleApplication
    $start=[Diagnostics.ProcessStartInfo]::new($exe); $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $probe=[Diagnostics.Process]::new(); $probe.StartInfo=$start; $probe.Start() | Out-Null
    $control=[Roo.Optimization.CpuSets.Target]::new($probe.Id,$true)
    $original=@([CpuSetOracle]::Read($probe.Id))
    $available=@($control.Topology() | Where-Object { -not $_.allocated -or $_.allocatedToTargetProcess })
    Assert ($available.Count -gt 1) 'Live target exposes multiple usable CPU Set IDs'
    $selected=[uint32]$available[0].id
    $previewPath=Join-Path $root 'preview with spaces.json'; $journalPath=Join-Path $root 'operation.json'
    $preview=Read-Result (& $scriptPath -Action Preview -TargetProcessId $probe.Id -CpuSetId $selected -OutputPath $previewPath)
    Assert ($preview.status -eq 'preview' -and -not (Test-Path $journalPath) -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) $original)) 'Preview reads live controls without creating recovery or changing the process'
    $a=@{Action='Apply'; InputPath=$previewPath; ReviewSha256=(Get-FileHash $previewPath -Algorithm SHA256).Hash; JournalPath=$journalPath}
    $noApproval=Read-Result (& $scriptPath @a)
    Assert ($noApproval.status -eq 'preview' -and -not (Test-Path $journalPath)) 'Unconfirmed apply leaves no journal or mutation'
    $bad=@{}; foreach($key in $a.Keys){$bad[$key]=$a[$key]}; $bad.ReviewSha256=('0'*64)
    $stale=Read-Result (& $scriptPath @bad -ConfirmApply)
    Assert ($stale.status -eq 'failed' -and -not (Test-Path $journalPath)) 'Altered preview hash fails before mutation'
    $overwrite=Read-Result (& $scriptPath @a -OutputPath $previewPath -ConfirmApply)
    Assert ($overwrite.status -eq 'failed' -and (Get-FileHash $previewPath).Hash -eq $a.ReviewSha256 -and -not(Test-Path $journalPath)) 'An output-path collision cannot overwrite the reviewed preview or change process controls'
    $lease=Lock-RooOperation $journalPath
    try { $busy=Read-Result (& $scriptPath @a -ConfirmApply) } finally { $lease.Dispose() }
    Assert ($busy.status -eq 'failed' -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) $original)) 'Concurrent journal lease rejects a second writer'
    $applied=Read-Result (& $scriptPath @a -ConfirmApply)
    if ($applied.status -ne 'applied') { Write-Host ($applied | ConvertTo-Json -Depth 16) }
    Assert ($applied.status -eq 'applied' -and -not $applied.dryRun -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) @($selected))) 'Confirmed CPU Set apply is visible through an independent Windows query'
    $again=Read-Result (& $scriptPath @a -ConfirmApply)
    Assert ($again.status -eq 'applied' -and $again.dryRun) 'Duplicate apply verifies state without writing it again'
    $interrupted=(Read-RooOperationJson $journalPath).data;$interrupted.status='apply-intent';Write-RooOperationJson $interrupted $journalPath
    $reconciled=Read-Result (& $scriptPath @a -ConfirmApply)
    Assert ($reconciled.status -eq 'applied' -and -not $reconciled.changed) 'A crash after CPU Set mutation is reconciled from actual Windows assignment'
    $control.Write([uint32[]]@($available[1].id))
    $conflict=Read-Result (& $scriptPath -Action Restore -JournalPath $journalPath -ConfirmApply)
    Assert ($conflict.status -eq 'failed' -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) @($available[1].id))) 'Restore preserves an external CPU Set change'
    $control.Write([uint32[]]@($selected))
    $restored=Read-Result (& $scriptPath -Action Restore -JournalPath $journalPath -ConfirmApply)
    Assert ($restored.status -eq 'restored' -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) $original)) 'Restore clears a previously empty default through the Windows API'
    $again=Read-Result (& $scriptPath -Action Restore -JournalPath $journalPath -ConfirmApply)
    Assert ($again.status -eq 'restored' -and $again.dryRun) 'Repeated restore performs no second mutation'
    $postRestore=Read-Result (& $scriptPath @a -ConfirmApply)
    Assert ($postRestore.status -eq 'restored' -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) $original)) 'Replaying a restored operation cannot reapply it'
    $control.Write([uint32[]]@($selected))
    $resetPath=Join-Path $root 'reset.json'; $resetJournal=Join-Path $root 'reset-journal.json'
    $resetPreview=Read-Result (& $scriptPath -Action Preview -TargetProcessId $probe.Id -ResetDefault -OutputPath $resetPath)
    $reset=Read-Result (& $scriptPath -Action Apply -InputPath $resetPath -ReviewSha256 (Get-FileHash $resetPath).Hash -JournalPath $resetJournal -ConfirmApply)
    Assert ($reset.status -eq 'applied' -and @([CpuSetOracle]::Read($probe.Id)).Count -eq 0) 'Explicit ResetDefault clears a nonempty assignment'
    $resetRestore=Read-Result (& $scriptPath -Action Restore -JournalPath $resetJournal -ConfirmApply)
    Assert ($resetRestore.status -eq 'restored' -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) @($selected))) 'Reset rollback restores the exact nonempty original assignment'
    $mismatched=$preview; $mismatched.data.identity.creationTimeFileTimeUtc='1'
    $mismatchPath=Join-Path $root 'mismatch.json'; Write-RooOperationJson $mismatched $mismatchPath
    $identityFailure=Read-Result (& $scriptPath -Action Apply -InputPath $mismatchPath -ReviewSha256 (Get-FileHash $mismatchPath).Hash -JournalPath (Join-Path $root 'mismatch-journal.json') -ConfirmApply)
    Assert ($identityFailure.status -eq 'failed' -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) @($selected))) 'A reused PID or mismatched creation identity cannot authorize a change'
    $invalidIds=Read-Result (& $scriptPath -Action Preview -TargetProcessId $probe.Id -CpuSetId ([uint32]::MaxValue))
    Assert ($invalidIds.status -eq 'failed') 'An ID absent from current target topology is rejected'
    $denied=Read-Result (& $scriptPath -Action Status -TargetProcessId ([int]::MaxValue))
    Assert ($denied.status -eq 'failed' -and $denied.errors[0].api -eq 'OpenProcess' -and $denied.errors[0].requestedAccess -eq '0x101000' -and $null -ne $denied.errors[0].win32Error) 'Native rejection reports the exact API, Win32 code and query/synchronization access mask'
    $queryOnly=[Roo.Optimization.CpuSets.Target]::new($probe.Id,$false)
    try { $rejected=$false; try {$queryOnly.Write([uint32[]]@())} catch {$rejected=$true}; Assert $rejected 'A detection handle cannot mutate process controls' } finally {$queryOnly.Dispose()}
    $control.Write([uint32[]]$original)
    $router=Join-Path $PSScriptRoot 'Invoke-RooCapability.ps1'
    $requestPath=Join-Path $root 'router request.json';$routePreviewPath=Join-Path $root 'routed preview.json';$routeJournalPath=Join-Path $root 'routed journal.json'
    Write-RooOperationJson @{schemaVersion=1;targetProcessId=$probe.Id;cpuSetIds=@($selected);outputPath=$routePreviewPath} $requestPath
    $routedPreview=Read-Result (& $router -CapabilityId 'process-controls.cpu-sets' -Action preview -RequestPath $requestPath)
    Assert ($routedPreview.status -eq 'completed' -and $routedPreview.evidence.status -eq 'preview') 'Capability router dispatches a typed CPU Set preview request'
    Write-RooOperationJson @{schemaVersion=1;inputPath=$routePreviewPath;reviewSha256=(Get-FileHash $routePreviewPath).Hash;journalPath=$routeJournalPath} $requestPath
    $routedApply=Read-Result (& $router -CapabilityId 'process-controls.cpu-sets' -Action apply -RequestPath $requestPath -ConfirmApply)
    Assert ($routedApply.status -eq 'completed' -and $routedApply.changed -and $routedApply.restoreAvailable -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) @($selected))) 'Routed apply reports the actual change and available restoration'
    $routedRestore=Read-Result (& $router -CapabilityId 'process-controls.cpu-sets' -Action restore -RequestPath $requestPath -ConfirmApply)
    Assert ($routedRestore.status -eq 'completed' -and $routedRestore.changed -and -not $routedRestore.restoreAvailable -and (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) $original)) 'Routed restore returns the process to its original CPU assignment'
    Write-RooOperationJson @{schemaVersion=1;targetProcessId=$probe.Id;cpuSetIds='256'} $requestPath
    $invalidRequest=Read-Result (& $router -CapabilityId 'process-controls.cpu-sets' -Action preview -RequestPath $requestPath)
    Assert ($invalidRequest.status -eq 'failed' -and $invalidRequest.dryRun -and $invalidRequest.evidence.errors[0].code -eq 'INVALID_OPTIMIZER_REQUEST') 'Invalid request types retain structured rejection evidence at the router boundary'
    [CpuSetOracle]::DenySetLimitedOnFixture($probe.Handle)
    $contextBefore=[Security.Principal.WindowsIdentity]::GetCurrent().ImpersonationLevel
    $privilegesBefore=(@(& whoami.exe /priv /fo csv) -join "`n")
    $deniedJournal=Join-Path $root 'denied.json'
    $deniedApply=Read-Result (& $scriptPath -Action Apply -InputPath $previewPath -ReviewSha256 (Get-FileHash $previewPath).Hash -JournalPath $deniedJournal -ConfirmApply)
    if ($deniedApply.status -ne 'failed' -or $deniedApply.errors[0].win32Error -ne 5) { Write-Host ($deniedApply|ConvertTo-Json -Depth 16); & whoami.exe /priv /fo csv | Where-Object {$_ -match 'SeDebugPrivilege'} | Write-Host }
    Assert ($deniedApply.status -eq 'failed' -and $deniedApply.errors[0].api -eq 'OpenProcess' -and $deniedApply.errors[0].win32Error -eq 5 -and $deniedApply.errors[0].requestedAccess -eq '0x103000' -and -not(Test-Path $deniedJournal)) 'A disposable process denying SET_LIMITED_INFORMATION is respected without escalation or mutation'
    Assert ([Security.Principal.WindowsIdentity]::GetCurrent().ImpersonationLevel -eq $contextBefore -and (@(& whoami.exe /priv /fo csv) -join "`n") -ceq $privilegesBefore) 'A denied target open restores the caller context and preserves process-token privileges'
    $caller=[Security.Principal.WindowsIdentity]::GetCurrent();$nested=$caller.Impersonate()
    try {
        $nestedBefore=[Security.Principal.WindowsIdentity]::GetCurrent().ImpersonationLevel
        $nestedDenied=Read-Result (& $scriptPath -Action Apply -InputPath $previewPath -ReviewSha256 (Get-FileHash $previewPath).Hash -JournalPath $deniedJournal -ConfirmApply)
        Assert ($nestedDenied.errors[0].win32Error -eq 5 -and [Security.Principal.WindowsIdentity]::GetCurrent().ImpersonationLevel -eq $nestedBefore) 'A pre-existing impersonation context is retained after access denial'
    } finally {$nested.Undo();$nested.Dispose();$caller.Dispose()}
    Assert (Test-RooCpuSetIdsEqual ([CpuSetOracle]::Read($probe.Id)) $original) 'The access-denied fixture retains its exact original CPU assignment'
} finally {
    if ($null -ne $control) {$control.Dispose()}
    if ($null -ne $probe) {
        if (-not $probe.HasExited) {$probe.Kill()}
        if (-not $probe.WaitForExit(10000)) {throw 'CPU Set fixture did not exit.'}
        $probe.Dispose()
    }
    if (Test-Path -LiteralPath $root) {Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not (Test-Path $root)) 'All CPU Set test processes and disposable operation files are removed'
