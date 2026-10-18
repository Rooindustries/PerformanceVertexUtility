param(
    [Parameter(Mandatory=$true)][string]$OutDir,
    [ValidateSet('Raw','Corrected','Scenarios')][string]$Mode='Raw',
    [string]$HostDirectory='',
    [string]$DotNetPath='',
    [string[]]$Scenario=@()
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$repoRoot=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repoRoot 'backend\scripts\GovernorScenarios\Scenario.Common.ps1')
. (Join-Path $repoRoot 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$probeDirectory=Join-Path $OutDir ('fixture-'+[Guid]::NewGuid().ToString('N'))
$script:probes=[Collections.Generic.List[Diagnostics.Process]]::new()
$receipts=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$measurements=[ordered]@{}
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Security.Principal;
public static class RooIndustriesGovernorBaselineToken {
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static string Sid(IntPtr process) { IntPtr token; if(!OpenProcessToken(process,8,out token)) throw new System.ComponentModel.Win32Exception(); try { using(var identity=new WindowsIdentity(token)) return identity.User.Value; } finally { CloseHandle(token); } }
}
'@
function Check([bool]$Passed,[string]$Name){$checks.Add([pscustomobject]@{passed=$Passed;check=$Name});Write-Output ($(if($Passed){'PASS '}else{'FAIL '})+$Name)}
function Capture([string]$Name,[Diagnostics.Process]$Process){
    $receipt=New-OwnedProcess $Process
    if(-not $receipt){throw 'Owned fixture identity could not be held'}
    $receipts.Add($receipt)
    $receipt.Identity|Add-Member -NotePropertyName userSid -NotePropertyValue ([RooIndustriesGovernorBaselineToken]::Sid($receipt.handle))
    if($null -eq (Wait-Until {$null -ne (Read-Controls $Process)} 10)){throw 'All eight fixture controls were not observable'}
    $measurements[$Name]=[ordered]@{identity=$receipt.Identity;controls=(Read-Controls $Process)}
    return $receipt
}
function Hash-Bytes([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}}
function Shared-Fingerprint {
    $tasks=[ordered]@{}
    $service=New-Object -ComObject Schedule.Service;$service.Connect()
    $pending=[Collections.Generic.Queue[object]]::new();$pending.Enqueue($service.GetFolder('\'))
    while($pending.Count){$folder=$pending.Dequeue();foreach($task in $folder.GetTasks(1)){$tasks[$task.Path]=Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($task.Xml+'|'+$task.GetSecurityDescriptor(7)))};foreach($child in $folder.GetFolders(0)){$pending.Enqueue($child)}}
    $registry=[ordered]@{}
    foreach($pair in @(@('HKLM',[Microsoft.Win32.Registry]::LocalMachine,'SOFTWARE\RooIndustriesOptimizationSuite'),@('HKCU',[Microsoft.Win32.Registry]::CurrentUser,'Software\RooIndustries\OptimizationSuite'),@('HKCU',[Microsoft.Win32.Registry]::CurrentUser,'Software\RooOptimizationSuite'),@('HKLM',[Microsoft.Win32.Registry]::LocalMachine,'SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'))){
        $key=$pair[1].OpenSubKey($pair[2],$false)
        if(-not $key){$registry[$pair[0]+'\'+$pair[2]]='absent';continue}
        $pendingKeys=[Collections.Generic.Queue[object]]::new();$pendingKeys.Enqueue($key)
        while($pendingKeys.Count){$currentKey=$pendingKeys.Dequeue();try{$registry[$currentKey.Name+'|sddl']=$currentKey.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group');foreach($name in $currentKey.GetValueNames()|Sort-Object){$kind=$currentKey.GetValueKind($name);$value=$currentKey.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);[byte[]]$bytes=if($value -is [byte[]]){,$value}else{,[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Compress))};$registry[$currentKey.Name+'\'+$name]=[ordered]@{kind=[int]$kind;length=$bytes.Length;sha256=(Hash-Bytes $bytes)}};foreach($child in $currentKey.GetSubKeyNames()){$pendingKeys.Enqueue($currentKey.OpenSubKey($child,$false))}}finally{$currentKey.Dispose()}}
    }
    [ordered]@{tasks=$tasks;registry=$registry}
}
try {
    if($Mode -eq 'Scenarios'){
        if(-not $Scenario.Count -or -not (Test-Path -LiteralPath (Join-Path $HostDirectory 'Optimizer.Host.dll')) -or -not (Test-Path -LiteralPath $DotNetPath)){throw 'Named scenarios and verified native host/dotnet paths are required'}
        $before=Shared-Fingerprint
        $measurements.sharedBefore=$before
        $measurements.requestedScenarios=$Scenario
        $runner=Join-Path $repoRoot 'backend\scripts\Test-GovernorScenarios.ps1'
        $evidence=Join-Path $OutDir 'scenario-evidence.json'
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$runner+'" -Scenario "'+($Scenario -join ',')+'" -DotNetPath "'+$DotNetPath+'" -HostDirectory "'+$HostDirectory+'" -EvidencePath "'+$evidence+'"'))
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $runnerProcess=[Diagnostics.Process]::Start($info);$script:probes.Add($runnerProcess)
        $runnerReceipt=New-OwnedProcess $runnerProcess;$receipts.Add($runnerReceipt)
        $stdout=$runnerProcess.StandardOutput.ReadToEndAsync();$stderr=$runnerProcess.StandardError.ReadToEndAsync()
        if(-not $runnerProcess.WaitForExit(1080000)){throw 'Named governor scenarios exceeded eighteen minutes'}
        [IO.File]::WriteAllText((Join-Path $OutDir 'scenarios.log'),$stdout.Result,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $OutDir 'scenarios-error.log'),$stderr.Result,[Text.UTF8Encoding]::new($false))
        $measurements.runner=[ordered]@{identity=$runnerReceipt.Identity;exitCode=$runnerProcess.ExitCode}
        Check ($runnerProcess.ExitCode -eq 0) 'Named original governor scenarios exited zero'
        $ran=Get-Content -Raw -LiteralPath $evidence|ConvertFrom-Json
        Check (@($ran.scenarios.PSObject.Properties).Count -eq $Scenario.Count -and @($Scenario|Where-Object {$ran.scenarios.$_.passed -ne $true}).Count -eq 0) 'Every requested scenario retained a passing record'
        $after=Shared-Fingerprint;$measurements.sharedAfter=$after
        Check (($before|ConvertTo-Json -Depth 16 -Compress) -ceq ($after|ConvertTo-Json -Depth 16 -Compress)) 'Unrelated tasks and typed real registry state match the exact before snapshot'
    }else{
    Initialize-ScenarioFixtures
    $parent=Get-Process -Id $PID
    $measurements.parent=[ordered]@{processId=$PID;controls=(Read-Controls $parent)}
    $path=Join-Path $probeDirectory 'RooIndustriesGovernorProbe.exe'
    if($Mode -eq 'Raw'){
        $info=[Diagnostics.ProcessStartInfo]::new($path,'120');$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $probe=[Diagnostics.Process]::Start($info);$script:probes.Add($probe)
        $null=Capture 'probe' $probe
        Check (-not $probe.HasExited) 'Raw fixture is alive with retained exact identity'
    }else{
        foreach($case in @('normal','noWait','denyImmediate','denyDelayed')){
            $fixturePath=if($case -like 'deny*'){Join-Path $probeDirectory 'RooIndustriesGovernorFixture.exe'}else{$path}
            $arguments=if($case -eq 'denyImmediate'){'0 1600 0 120'}elseif($case -eq 'denyDelayed'){'2 1600 0 120'}else{'120'}
            $probe=Start-Probe $fixturePath $arguments -NoWait:($case -ne 'normal')
            $immediate=[ordered]@{cpuPriority=(Read-Field $probe 'cpuPriority');ioPriority=(Read-Field $probe 'ioPriority');memoryPriority=(Read-Field $probe 'memoryPriority')}
            Check ($immediate.cpuPriority -eq 'Normal' -and $immediate.ioPriority -eq 2 -and $immediate.memoryPriority -eq 5) ($case+': baseline is explicit at return')
            $receipt=Capture $case $probe
            $measurements[$case].atReturn=$immediate
            $before=$measurements[$case].controls
            Check ($receipt.Identity.pid -eq $probe.Id -and $receipt.Identity.imagePath -ieq [RooIndustriesValidationOwnership.Native]::Canonical($fixturePath) -and $receipt.Identity.creationTimeFileTimeUtc -ceq $probe.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -and $receipt.Identity.userSid -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) ($case+': PID creation image and token agree')
            if($case -like 'deny*'){
                Start-Sleep -Seconds 3
                $after=Read-Controls $probe
                $measurements[$case].afterDenial=$after
                Check ((Same $before $after) -and -not $probe.HasExited) ($case+': exact held fixture retains all eight controls after denial')
            }
        }
        $exited=[Collections.Generic.List[object]]::new()
        for($index=0;$index -lt 40;$index++){
            $instant=Start-Probe $path '0' -NoWait
            $id=$instant.Id;$created=[RooIndustriesValidationOwnership.Native]::Created($instant.Handle).ToString()
            $finished=$instant.WaitForExit(10000)
            $exited.Add([ordered]@{pid=$id;creationTimeFileTimeUtc=$created;waitCompleted=$finished;exited=$instant.HasExited})
        }
        $measurements.immediateExit=$exited
        Check (@($exited|Where-Object {-not $_.waitCompleted -or -not $_.exited}).Count -eq 0 -and $exited.Count -eq 40) 'Forty immediate-exit NoWait fixtures keep usable handles and leave no owned live process'
        $errors=$null;$tokens=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'backend\scripts\GovernorScenarios\Scenario.Common.ps1'),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Fixture common source failed native PowerShell parsing'}
        $oracle=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class RooIndustriesGovernorScenarioOracle')},$true))[0].Value
        $faulted=$oracle.Replace('RooIndustriesGovernorScenarioOracle','RooIndustriesGovernorBaselineFault').Replace('public static Process Start(', 'public static int FailedPid; public static long FailedCreation; public static Process Start(').Replace('SetIo(created.Process, 2);','FailedPid=(int)created.ProcessId; FailedCreation=nativeTime; SetIo(created.Process, 2);').Replace('SetMemory(created.Process, 5);','SetMemory(created.Process, 99);')
        Add-Type -TypeDefinition $faulted
        $failure=$null
        try{$unexpected=[RooIndustriesGovernorBaselineFault]::Start($path,'120');$script:probes.Add($unexpected)}catch{$failure=$_.Exception;while($failure.InnerException){$failure=$failure.InnerException}}
        $surviving=$false;$candidate=$null
        try{$candidate=Get-Process -Id ([RooIndustriesGovernorBaselineFault]::FailedPid) -ErrorAction SilentlyContinue;if($candidate){$surviving=[RooIndustriesValidationOwnership.Native]::Created($candidate.Handle) -eq [RooIndustriesGovernorBaselineFault]::FailedCreation -and -not $candidate.HasExited}}finally{if($candidate){$candidate.Dispose()}}
        $measurements.initializationFailure=[ordered]@{processId=[RooIndustriesGovernorBaselineFault]::FailedPid;creationTimeFileTimeUtc=[RooIndustriesGovernorBaselineFault]::FailedCreation.ToString();errorCode=$failure.NativeErrorCode;exactProcessAlive=$surviving}
        Check ($failure.NativeErrorCode -eq 87 -and [RooIndustriesGovernorBaselineFault]::FailedPid -gt 0 -and -not $surviving) 'Native invalid memory priority after creation stops the exact suspended fixture'
    }
    }
}finally{
    foreach($receipt in $receipts){Stop-OwnedProcess $receipt}
    $measurements.cleanup=[ordered]@{processes=@($receipts|ForEach-Object {[ordered]@{identity=$_.Identity;exited=$_.Process.HasExited}})}
    foreach($probe in $script:probes){if(-not $probe.HasExited){$probe.Kill();$probe.WaitForExit(10000)|Out-Null};$probe.Dispose()}
    if(Test-Path -LiteralPath $probeDirectory){Remove-Item -LiteralPath $probeDirectory -Recurse -Force}
    Check (-not (Test-Path -LiteralPath $probeDirectory)) 'Only the unique fixture directory was removed'
    $hashes=[ordered]@{}
    foreach($file in @($PSCommandPath,(Join-Path $repoRoot 'backend\scripts\GovernorScenarios\Scenario.Common.ps1'))){$hashes[$file]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
    [IO.File]::WriteAllText((Join-Path $OutDir 'baseline.json'),([ordered]@{machine=$env:COMPUTERNAME;mode=$Mode;sourceHashes=$hashes;measurements=$measurements;checks=$checks}|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
}
if(@($checks|Where-Object {-not $_.passed}).Count){exit 1}
