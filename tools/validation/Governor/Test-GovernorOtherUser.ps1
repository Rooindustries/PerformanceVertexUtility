param([Parameter(Mandatory=$true)][ValidateSet('setup','after-upgrade','restart','after-uninstall','cleanup')][string]$Phase,[ValidateSet('','account-created')][string]$InterruptAfter='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$app='C:\Program Files\Roo Industries\Optimization Suite'
$hostExe=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe'
if(Test-Path -LiteralPath (Join-Path $app 'backend\scripts\BrandCompatibility.Common.ps1')){. (Join-Path $app 'backend\scripts\BrandCompatibility.Common.ps1')}
$account='rigovtest'
$work=Join-Path $env:ProgramData 'RooIndustriesGovernorTest'
$probeExe=Join-Path $work 'RooIndustriesGovernorProbe.exe'
$statePath=Join-Path $work 'state.json'
$ownerPath=Join-Path $work 'fixture-owner.txt'
$tasks=@('RooIndustriesGovernorOtherSetup','RooIndustriesGovernorOtherProbe','RooIndustriesGovernorOtherWorker')
$out=[ordered]@{phase=$Phase;atUtc=[DateTime]::UtcNow.ToString('o');checks=@()}
function Check([bool]$Condition,[string]$Message){$script:out.checks+=[ordered]@{passed=$Condition;check=$Message};if($Condition){"PASS $Message"}else{"FAIL $Message"}}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesOtherUserOracle {
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr process, int kind, out uint value, uint size);
    public static uint Memory(IntPtr p) { uint v; if(!GetProcessInformation(p,0,out v,4)) throw new System.ComponentModel.Win32Exception(); return v; }
}
'@
[Diagnostics.Process]::EnterDebugMode()
function Read-Probe{
    $probe=@(Get-CimInstance Win32_Process -Filter "Name='RooIndustriesGovernorProbe.exe'"|Where-Object {$_.ExecutablePath -eq $probeExe})[0]
    if(-not $probe){return $null}
    $process=Get-Process -Id $probe.ProcessId
    return [ordered]@{pid=$probe.ProcessId;owner=(Invoke-CimMethod -InputObject $probe -MethodName GetOwnerSid).Sid;cpuPriority=[string]$process.PriorityClass;memoryPriority=[RooIndustriesOtherUserOracle]::Memory($process.Handle)}
}
function Wait-Until([scriptblock]$Condition,[double]$Seconds){$clock=[Diagnostics.Stopwatch]::StartNew();while($true){$met=$false;try{$met=[bool](& $Condition)}catch{};if($met){return [Math]::Round($clock.Elapsed.TotalSeconds,2)};if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null};Start-Sleep -Milliseconds 250}}
function Governor-Task([string]$Sid){@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue|Where-Object {([string]$_.Description -split ' \| ')[1] -eq $Sid})}
function Worker-Of([string]$Sid){@(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'"|Where-Object {[string]$_.CommandLine -match 'policy-run' -and (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $Sid})}
$state=if(Test-Path -LiteralPath $statePath){Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json}else{$null}

switch($Phase){
    'setup' {
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
        if(Test-Path -LiteralPath $work){throw 'The test folder already exists; run cleanup first.'}
        if(Get-LocalUser -Name $account -ErrorAction SilentlyContinue){throw 'The test account already exists and was not created by this test.'}
        foreach($name in $tasks){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw ('The test task already exists and was not created by this test: '+$name)}}
        [IO.Directory]::CreateDirectory($work,$acl)|Out-Null
        Set-Content -LiteralPath $ownerPath -Value 'pending' -Encoding ASCII
        Add-Type -TypeDefinition 'public static class RooIndustriesGovernorProbe { public static void Main(string[] args) { System.Threading.Thread.Sleep(System.TimeSpan.FromSeconds(args.Length > 0 ? int.Parse(args[0]) : 600)); } }' -OutputAssembly $probeExe -OutputType ConsoleApplication
        $password='Rg'+[Guid]::NewGuid().ToString('N').Substring(0,20)+'!7'
        Set-Content -LiteralPath $ownerPath -Value 'creating' -Encoding ASCII
        & net.exe user $account $password /add /y|Out-Null
        if($LASTEXITCODE -ne 0){throw 'The test account could not be created.'}
        if($InterruptAfter -eq 'account-created'){throw 'Setup interrupted after creating the test account.'}
        $sid=[Security.Principal.NTAccount]::new($env:COMPUTERNAME+'\'+$account).Translate([Security.Principal.SecurityIdentifier]).Value
        Set-Content -LiteralPath $ownerPath -Value $sid -Encoding ASCII
        & net.exe localgroup Administrators $account /add|Out-Null
        if($LASTEXITCODE -ne 0){throw 'The test account could not be made an administrator.'}
        $setupScript=Join-Path $work 'other-setup.ps1'
        [IO.File]::WriteAllText($setupScript,@'
$ErrorActionPreference='Stop'
$OutputEncoding=[Text.UTF8Encoding]::new($false)
$app='APP';$hostExe=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe'
$root=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RooIndustriesOptimizationSuite\process-rules'
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$rule=@{schemaVersion=1;ruleId=[Guid]::NewGuid().ToString('N');owner=@{machine=$env:COMPUTERNAME;userSid=$me};name='Other user rule';enabled=$true;matchMode='path';executablePath='PROBE';executableHash=$null;controls=@{cpuPriority='AboveNormal';memoryPriority=3};cpuSelection=$null}
$save=(@((@{schemaVersion=1;repoRoot=$app;policyRoot=$root;confirm=$true;rule=$rule}|ConvertTo-Json -Depth 10 -Compress)|& $hostExe 'rule-save' '-') -join "`n")|ConvertFrom-Json
$sync=(@(& (Join-Path $app 'backend\scripts\Invoke-ProcessPolicyWorker.ps1') -Action Sync -PolicyRoot $root -ConfirmApply) -join "`n")|ConvertFrom-Json
@{sid=$me;root=$root;save=$save.status;saveError=$save.error.message;sync=$sync.status;syncError=@($sync.errors|ForEach-Object {$_.message})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath 'OUT' -Encoding UTF8
'@.Replace('APP',$app).Replace('PROBE',$probeExe).Replace('OUT',(Join-Path $work 'other-setup.json')),[Text.UTF8Encoding]::new($true))
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'RooIndustriesGovernorOtherSetup' -Action (New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$setupScript+'"')) -User ($env:COMPUTERNAME+'\'+$account) -Password $password -RunLevel Highest -Settings $settings -Force|Out-Null
        Start-ScheduledTask -TaskName 'RooIndustriesGovernorOtherSetup'
        $setupDone=Wait-Until {Test-Path -LiteralPath (Join-Path $work 'other-setup.json')} 120
        $other=Get-Content -Raw -LiteralPath (Join-Path $work 'other-setup.json')|ConvertFrom-Json
        $out.otherSetup=$other
        Register-ScheduledTask -TaskName 'RooIndustriesGovernorOtherProbe' -Action (New-ScheduledTaskAction -Execute $probeExe -Argument '7200') -User ($env:COMPUTERNAME+'\'+$account) -Password $password -RunLevel Highest -Settings $settings -Force|Out-Null
        Register-ScheduledTask -TaskName 'RooIndustriesGovernorOtherWorker' -Action (New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ('--headless "'+$hostExe+'" policy-run "'+(Join-Path $other.root 'worker-request.json')+'"')) -User ($env:COMPUTERNAME+'\'+$account) -Password $password -RunLevel Highest -Settings $settings -Force|Out-Null
        Start-ScheduledTask -TaskName 'RooIndustriesGovernorOtherProbe'
        $null=Wait-Until {$null -ne (Read-Probe)} 30
        $original=Read-Probe
        Start-ScheduledTask -TaskName 'RooIndustriesGovernorOtherWorker'
        $applied=Wait-Until {$p=Read-Probe;$p.cpuPriority -eq 'AboveNormal' -and $p.memoryPriority -eq 3} 30
        [IO.File]::WriteAllText($statePath,(@{sid=$sid;root=$other.root;original=$original}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $task=@(Governor-Task $sid)
        $out.original=$original;$out.applied=Read-Probe;$out.task=@($task|ForEach-Object {[ordered]@{name=$_.TaskName;state=[string]$_.State;runLevel=[string]$_.Principal.RunLevel;user=$_.Principal.UserId}})
        Check ($null -ne $setupDone -and $other.save -eq 'completed' -and $task.Count -eq 1 -and [string]$task[0].Principal.RunLevel -eq 'Highest') 'A second administrator saved a rule and has a governor task of their own'
        Check ($original.owner -eq $sid -and $original.cpuPriority -ne 'AboveNormal' -and $null -ne $applied -and @(Worker-Of $sid).Count -eq 1) 'The second administrator governor is running and applies the rule to their own process'
    }
    'after-upgrade' {
        $probe=Read-Probe
        $task=@(Governor-Task $state.sid)
        $out.probe=$probe;$out.task=@($task|ForEach-Object {[ordered]@{name=$_.TaskName;state=[string]$_.State;execute=$_.Actions[0].Execute;arguments=$_.Actions[0].Arguments;triggers=@($_.Triggers|ForEach-Object {[string]$_.CimClass.CimClassName+' '+$_.UserId+' '+$_.Repetition.Interval})}})
        Check ($null -ne $probe -and $probe.cpuPriority -eq $state.original.cpuPriority -and $probe.memoryPriority -eq $state.original.memoryPriority -and @(Worker-Of $state.sid).Count -eq 0) 'Setup stopped the second administrator governor and restored their process'
        Check ($task.Count -eq 1 -and [string]$task[0].State -ne 'Disabled' -and $task[0].Actions[0].Execute -like '*\conhost.exe' -and $task[0].Actions[0].Arguments -ceq (New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',(Join-Path $state.root 'worker-request.json')) (Split-Path $hostExe -Parent)).Arguments -and @($task[0].Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and (([string]$_.UserId -eq $state.sid) -or ([Security.Principal.NTAccount]::new([string]$_.UserId).Translate([Security.Principal.SecurityIdentifier]).Value -eq $state.sid)) -and $_.Repetition.Interval -eq 'PT1M'}).Count -eq 1) 'Their governor task is registered again and enabled, so it starts at their next sign-in'
        $acl=Get-Acl -LiteralPath $state.root
        Check ($acl.Owner -eq 'BUILTIN\Administrators' -and $acl.AreAccessRulesProtected -and @($acl.Access|Where-Object {[string]$_.IdentityReference -like ('*\'+$account) -and [string]$_.FileSystemRights -match 'Read'}).Count -ge 1) 'Their rules folder is protected and still readable by them'
    }
    'restart' {
        Start-ScheduledTask -TaskName 'RooIndustriesGovernorOtherWorker'
        $applied=Wait-Until {$p=Read-Probe;$p.cpuPriority -eq 'AboveNormal' -and $p.memoryPriority -eq 3} 30
        $out.probe=Read-Probe
        Check ($null -ne $applied -and @(Worker-Of $state.sid).Count -eq 1) 'The second administrator governor starts with the new files and enforces their kept rule'
    }
    'after-uninstall' {
        $probe=Read-Probe
        $out.probe=$probe
        Check ($null -ne $probe -and $probe.cpuPriority -eq $state.original.cpuPriority -and $probe.memoryPriority -eq $state.original.memoryPriority -and @(Worker-Of $state.sid).Count -eq 0) 'Uninstall stopped the second administrator governor and restored their process'
        Check (@(Governor-Task $state.sid).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $state.root 'rules'))) 'Uninstall removed their governor task and kept their rules'
    }
    'cleanup' {
        if(-not(Test-Path -LiteralPath $ownerPath)){Check $false 'Cleanup removes only what setup recorded, and found no setup record';break}
        $sid=(Get-Content -Raw -LiteralPath $ownerPath).Trim()
        $currentUser=@(Get-LocalUser -ErrorAction Stop|Where-Object Name -EQ $account)
        if($sid -notlike 'S-1-5-21-*'){
            if($currentUser.Count){$out.left=[ordered]@{account=$true;work=$true};Check $false 'Setup stopped before recording the test account it created, so cleanup kept the account and the setup record';break}
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop;Check (-not(Test-Path -LiteralPath $work)) 'Setup stopped before creating the account, so cleanup removed only the test folder';break
        }
        $current=if($currentUser.Count){$currentUser[0].SID.Value}else{$null}
        if($current -and $current -cne $sid){Check $false 'The test account was replaced after setup, so cleanup kept it';break}
        $keptTasks=@();$remainingTasks=@();$taskErrors=@()
        foreach($verify in @($false,$true)){
            try{$registered=@(Get-ScheduledTask -ErrorAction Stop)}catch{$taskErrors+=('Task discovery failed: '+$_.Exception.Message);continue}
            foreach($task in $registered){
                $fixture=$tasks -contains $task.TaskName
                $governor=$task.TaskName -like '*OptimizationSuite.ProcessRules.*' -and ([string]$task.Description -split ' \| ')[1] -ceq $sid
                if(-not($fixture -or $governor)){continue}
                $name=$task.TaskPath+$task.TaskName
                if($fixture){
                    $runsAs=try{[Security.Principal.NTAccount]::new([string]$task.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value}catch{[string]$task.Principal.UserId}
                    if($runsAs -cne $sid){$keptTasks+=$name;continue}
                }
                if($verify){$remainingTasks+=$name;continue}
                if($fixture){try{Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop}catch{$taskErrors+=('Could not stop '+$name+': '+$_.Exception.Message)}}
                try{Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop}catch{$taskErrors+=('Could not remove '+$name+': '+$_.Exception.Message)}
            }
        }
        if($taskErrors.Count -or $remainingTasks.Count -or $keptTasks.Count){
            $out.taskErrors=$taskErrors;$out.left=[ordered]@{account=($currentUser.Count -gt 0);work=(Test-Path -LiteralPath $work);tasksRemaining=$remainingTasks;tasksKept=@($keptTasks|Select-Object -Unique)}
            Check $false ('Task cleanup could not be verified, so cleanup kept the account, profile, test folder and setup record: '+(@($taskErrors)+@($remainingTasks)+@($keptTasks|Select-Object -Unique) -join '; '));break
        }
        Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq $probeExe -or ($sid -and (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $sid)}|ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
        Start-Sleep -Seconds 3
        if($sid){
            $markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
            if($markers){foreach($name in @($markers.GetValueNames()|Where-Object {$markers.GetValue($_) -eq $sid})){Remove-ItemProperty -LiteralPath $markers.PSPath -Name $name}}
            for($attempt=0;$attempt -lt 24 -and @(Get-CimInstance Win32_UserProfile -Filter ("SID='"+$sid+"'")).Count -gt 0;$attempt++){try{Get-CimInstance Win32_UserProfile -Filter ("SID='"+$sid+"'")|Remove-CimInstance -ErrorAction Stop}catch{Start-Sleep -Seconds 3}}
        }
        if($currentUser.Count){& net.exe user $account /delete 2>&1|Out-Null}
        $accountLeft=@(Get-LocalUser -ErrorAction Stop|Where-Object Name -EQ $account).Count -gt 0
        if(-not $accountLeft -and @(Get-CimInstance Win32_UserProfile -Filter ("SID='"+$sid+"'")).Count -eq 0){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop}
        $out.left=[ordered]@{account=$accountLeft;work=(Test-Path -LiteralPath $work);profile=if($sid){@(Get-CimInstance Win32_UserProfile -Filter ("SID='"+$sid+"'")).Count}else{0};profileFolder=(Test-Path -LiteralPath ('C:\Users\'+$account));tasksKept=$keptTasks}
        Check (-not $out.left.account -and -not $out.left.work -and $out.left.profile -eq 0) 'The second administrator account, its profile and the test folder are removed'
        Check ($keptTasks.Count -eq 0) ('Cleanup removed only the test tasks that run as the test account'+$(if($keptTasks.Count){'; kept tasks it did not create: '+($keptTasks -join ', ')}else{''}))
    }
}
$out|ConvertTo-Json -Depth 8
