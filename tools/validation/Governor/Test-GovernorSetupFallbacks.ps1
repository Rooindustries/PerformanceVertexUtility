param([Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir|Out-Null
$results=New-Object System.Collections.Generic.List[object]
function Check([bool]$Condition,[string]$Message,[string]$Detail=''){$results.Add([pscustomobject]@{passed=$Condition;check=$Message;detail=$Detail});if($Condition){"PASS $Message"}else{"FAIL $Message :: $Detail"}}
$watchdog='RooIndustriesOptimizationSuite.GovernorSetupWatchdog'
if(@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue).Count -gt 0 -or (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)){throw 'Governor or setup recovery tasks already exist on this PC; refusing to run the setup fallback check.'}
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$started=Get-Date
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$local=[Environment]::GetFolderPath('LocalApplicationData')
$work=Join-Path $env:SystemRoot ('Temp\roo-industries-setup-check-'+$id)
$appRoot=Join-Path $work 'app'
$policyRoot=Join-Path $local ('RooIndustriesSetupCheck-'+$id+'\process-rules')
function New-TaskName{return 'RooIndustriesOptimizationSuite.ProcessRules.'+[Guid]::NewGuid().ToString('N').Substring(0,20).ToUpperInvariant()}
$taskName=New-TaskName
$untrustedName=New-TaskName
$decoyNames=New-Object System.Collections.Generic.List[string]
$probeName='RooIndustriesSetupCheckProbe'+$id
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hostDirectory=Join-Path $appRoot 'backend\bin\optimizer'
$hostExe=Join-Path $hostDirectory 'Optimizer.Host.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $appRoot 'backend\scripts'),$hostDirectory,$policyRoot|Out-Null
$copy=Join-Path $work 'Invoke-GovernorSetup.ps1'
Copy-Item -LiteralPath $Script -Destination $copy
Copy-Item -LiteralPath (Join-Path (Split-Path $Script -Parent) 'BrandCompatibility.Common.ps1') -Destination (Join-Path $appRoot 'backend\scripts')
[IO.File]::WriteAllText((Join-Path $appRoot 'backend\scripts\Start-RooIndustriesHelper.cmd'),"@echo off`r`nping -n 900 127.0.0.1 >nul`r`n")
. (Join-Path $appRoot 'backend\scripts\BrandCompatibility.Common.ps1')
function Set-Worker([string]$Status){
    $body="param([string]`$Action,[string]`$PolicyRoot,[string]`$HostDirectory,[switch]`$ConfirmApply)`r`n# 'Sync'`r`n"+'[pscustomobject]@{schemaVersion=1;status='''+$Status+''';data=[pscustomobject]@{registered=$true;enabled=$true;paused=$false;worker=[pscustomobject]@{hostRunning=$true}};errors=@([pscustomobject]@{message=''forced '+$Status+'''})}|ConvertTo-Json -Depth 5'
    [IO.File]::WriteAllText((Join-Path $appRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'),$body,[Text.UTF8Encoding]::new($true))
}
function Set-SilentWorker {
    $body="param([string]`$Action,[string]`$PolicyRoot,[string]`$HostDirectory,[switch]`$ConfirmApply)`r`n# 'Sync'`r`n"
    [IO.File]::WriteAllText((Join-Path $appRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'),$body,[Text.UTF8Encoding]::new($true))
}
function New-GovernorAction([string]$Root){return New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',(Join-Path $Root 'worker-request.json')) $hostDirectory}
function Register-Governor([string]$Name,$Description,$Action){
    $principal=New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    $parameters=@{TaskName=$Name;Action=$Action;Principal=$principal;Settings=(New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries);Force=$true}
    if($null -ne $Description){$parameters.Description=$Description}
    Register-ScheduledTask @parameters|Out-Null
}
function Register-FakeGovernor {
    Register-Governor $taskName ('Roo Industries process rules | '+$me+' | '+$policyRoot) (New-GovernorAction $policyRoot)
    Start-Fixture
}
function Start-Fixture {
    Start-ScheduledTask -TaskName $taskName
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while([string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and $clock.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 200}
}
function Register-UntrustedGovernor {
    $root=Join-Path $work 'untrusted\process-rules'
    Register-Governor $untrustedName ('Roo Industries process rules | '+$me+' | '+$root) (New-GovernorAction $root)
}
function Set-Fixture([bool]$Disabled,[bool]$Rules,[bool]$Paused){
    Unregister-ScheduledTask -TaskName $watchdog -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $work 'state.json'),(Join-Path $appRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1') -Force -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $rulesFolder=Join-Path $policyRoot 'rules'
    if($Rules){New-Item -ItemType Directory -Force -Path $rulesFolder|Out-Null;[IO.File]::WriteAllText((Join-Path $rulesFolder 'rule.json'),'{}')}else{Remove-Item -LiteralPath $rulesFolder -Recurse -Force -ErrorAction SilentlyContinue}
    $pause=Join-Path $policyRoot 'governor.json'
    if($Paused){[IO.File]::WriteAllText($pause,'{"schemaVersion":1,"paused":true}')}else{Remove-Item -LiteralPath $pause -Force -ErrorAction SilentlyContinue}
    if($Disabled){Disable-ScheduledTask -TaskName $taskName|Out-Null}else{Enable-ScheduledTask -TaskName $taskName|Out-Null}
}
function Get-DecoyProblems($Decoys,$Before,[string]$Log){
    $problems=@()
    foreach($decoy in $Decoys){
        $task=Get-ScheduledTask -TaskName $decoy.name -ErrorAction SilentlyContinue
        if(-not $task){$problems+=($decoy.label+': it is no longer registered');continue}
        if([string]$task.State -ne $Before[$decoy.name]){$problems+=($decoy.label+': its state changed to '+$task.State)}
        if($Log -notmatch [regex]::Escape('Ignoring a task that is not a governor registered by an administrator: '+$decoy.name)){$problems+=($decoy.label+': setup did not log that it skipped it')}
    }
    return $problems
}
function Get-RecoveryEnables {
    $recovery=Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue
    return @(if($recovery){@($recovery.Actions)|Where-Object {[string]$_.Arguments -match '/Change .*/ENABLE'}}).Count
}
function Invoke-Setup([string]$Name,[string]$Action,[string]$Prefix,[int]$SetupId){
    $state=Join-Path $work 'state.json'
    $log=Join-Path $work ($Name+'.log')
    $identity=if([IO.File]::ReadAllText($copy) -match 'SetupProcessId'){' -SetupProcessId '+$SetupId}else{''}
    $command=$Prefix+"try { & '"+$copy+"' -Action "+$Action+" -AppRoot '"+$appRoot+"' -StatePath '"+$state+"' -LogPath '"+$log+"'"+$identity+'; exit $LASTEXITCODE } catch { $_ | Out-String | Write-Error; exit 99 }'
    $process=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput (Join-Path $work ($Name+'.out')) -RedirectStandardError (Join-Path $work ($Name+'.err'))
    $text=@(if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log})+@(Get-Content -LiteralPath (Join-Path $work ($Name+'.err')) -ErrorAction SilentlyContinue)
    Copy-Item -LiteralPath $log -Destination (Join-Path $OutDir ($Name+'.log')) -ErrorAction SilentlyContinue
    [pscustomobject]@{exit=$process.ExitCode;log=($text -join "`n")}
}
$clm='$ExecutionContext.SessionState.LanguageMode=''ConstrainedLanguage''; '
$noWmi='function Get-CimInstance { throw ''WMI is unavailable'' }; function Invoke-CimMethod { throw ''WMI is unavailable'' }; '
$noTasks=$noWmi+'function Get-ScheduledTask { }; function Disable-ScheduledTask { throw ''WMI is unavailable'' }; function Enable-ScheduledTask { throw ''WMI is unavailable'' }; function Register-ScheduledTask { throw ''WMI is unavailable'' }; '
$denyWatchdog=@'
function Set-Content {
    param([string]$LiteralPath,[Parameter(ValueFromPipeline=$true)]$Value,[string]$Encoding)
    process {
        if($LiteralPath -like '*governor-recovery.xml'){$Value='<Task'}
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding
    }
}

'@
$modes=@(@{name='full';prefix=''},@{name='clm';prefix=$clm},@{name='nowmi';prefix=$noTasks})
$setup=$null
try {
    $setup=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n','900','127.0.0.1' -WindowStyle Hidden -PassThru
    $setupCreated=$setup.StartTime.ToUniversalTime().ToFileTimeUtc()

    $run=Invoke-Setup 'clm-none' 'Suspend' $clm $setup.Id
    Check ($run.exit -eq 0 -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'Constrained Language Mode with no governor: setup continues' ("exit="+$run.exit+" "+$run.log)

    Register-FakeGovernor
    $running=[string](Get-ScheduledTask -TaskName $taskName).State
    $run=Invoke-Setup 'clm-suspend' 'Suspend' $clm $setup.Id
    $task=Get-ScheduledTask -TaskName $taskName
    Check ($running -eq 'Running' -and $run.exit -eq 0 -and [string]$task.State -eq 'Disabled' -and $run.log -match 'ConstrainedLanguage') 'Constrained Language Mode with a governor: setup disables and ends it through Task Scheduler' ("before="+$running+" exit="+$run.exit+" state="+$task.State+" "+$run.log)
    $recovery=Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue
    $wait=if($recovery){[string]@($recovery.Actions)[0].Arguments}else{''}
    Check ($null -ne $recovery -and $wait -match ('Get-Process -Id '+$setup.Id+'\b') -and $wait -match [regex]::Escape([string]$setupCreated)) 'The recovery task waits on the setup process ID and its creation time' $wait
    $run=Invoke-Setup 'clm-resume' 'Resume' $clm $setup.Id
    Check ($run.exit -eq 0 -and [string](Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled' -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'Constrained Language Mode resume turns the governor back on and removes the recovery task' ("exit="+$run.exit+" "+$run.log)

    if($wait){
        $command=($wait -replace '^-NoProfile -NonInteractive -Command "','') -replace '"$',''
        $live=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) -WindowStyle Hidden -PassThru
        $other=$command.Replace([string]$setupCreated,[string]($setupCreated-10000000))
        $reused=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($other))) -WindowStyle Hidden -PassThru
        $reusedDone=$reused.WaitForExit(20000)
        Start-Sleep -Seconds 2
        $liveWaiting=-not $live.HasExited
        Stop-Process -Id $setup.Id -Force; $setup.WaitForExit(5000)|Out-Null
        $liveDone=$live.WaitForExit(20000)
        Check ($reusedDone -and $liveWaiting -and $liveDone) 'The recovery wait returns at once for another process with the same ID and waits for the real setup until it exits' ("reusedDone="+$reusedDone+" liveWaiting="+$liveWaiting+" liveDone="+$liveDone)
        $setup=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n','900','127.0.0.1' -WindowStyle Hidden -PassThru
    } else {Check $false 'The recovery wait returns at once for another process with the same ID and waits for the real setup until it exits' 'no recovery action'}

    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $run=Invoke-Setup 'nowmi-all-suspend' 'Suspend' $noTasks $setup.Id
    $task=Get-ScheduledTask -TaskName $taskName
    Check ($run.exit -eq 0 -and [string]$task.State -eq 'Disabled' -and $null -ne (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue) -and $run.log -match 'could not list the governor tasks') 'When Windows cannot list scheduled tasks or processes, setup finds the governor through schtasks, stops it and continues' ("exit="+$run.exit+" state="+$task.State+" "+$run.log)
    $run=Invoke-Setup 'nowmi-all-resume' 'Resume' $noTasks $setup.Id
    Check ($run.exit -eq 0 -and [string](Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled' -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'Without scheduled-task listing, resume turns the governor back on through schtasks' ("exit="+$run.exit+" "+$run.log)
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $run=Invoke-Setup 'nowmi-suspend' 'Suspend' $noWmi $setup.Id
    $task=Get-ScheduledTask -TaskName $taskName
    Check ($run.exit -eq 0 -and [string]$task.State -eq 'Disabled' -and $null -ne (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'When Windows cannot list processes, setup still stops the governor through Task Scheduler and continues' ("exit="+$run.exit+" state="+$task.State+" "+$run.log)

    Set-Worker 'failed'
    $run=Invoke-Setup 'resume-failed' 'Resume' '' $setup.Id
    Check ($run.exit -ne 0 -and $null -ne (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'A failed resume keeps the recovery task so the governor comes back later' ("exit="+$run.exit+" "+$run.log)
    Set-Worker 'completed'
    $run=Invoke-Setup 'resume-ok' 'Resume' '' $setup.Id
    Check ($run.exit -eq 0 -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) 'A successful resume removes the recovery task' ("exit="+$run.exit+" "+$run.log)

    $malformed=Join-Path $work 'malformed-recovery.xml'
    [IO.File]::WriteAllText($malformed,'<Task',[Text.Encoding]::Unicode)
    $ErrorActionPreference='Continue'; $probe=@(& (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Create /TN ('\'+$probeName) /XML $malformed /F 2>&1); $probeExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    Check ($probeExit -ne 0 -and $null -eq (Get-ScheduledTask -TaskName $probeName -ErrorAction SilentlyContinue)) 'Task Scheduler rejects a malformed recovery file, which is how the refused-recovery scenarios deny the recovery task' ('exit='+$probeExit+' '+($probe -join ' '))

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    foreach($mode in $modes){
        $run=Invoke-Setup ('denied-'+$mode.name+'-no-governor') 'Suspend' ($mode.prefix+$denyWatchdog) $setup.Id
        Check ($run.exit -eq 0 -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) ('With no governor task there is nothing to protect, so setup needs no recovery task and continues ('+$mode.name+' mode)') ("exit="+$run.exit+" "+$run.log)
    }
    Register-FakeGovernor
    foreach($mode in $modes){
        Set-Fixture $false $true $false
        Start-Fixture
        $run=Invoke-Setup ('denied-'+$mode.name+'-suspend') 'Suspend' ($mode.prefix+$denyWatchdog) $setup.Id
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($run.exit -eq 4 -and $taskState -eq 'Running' -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue) -and $run.log -match 'could not register setup recovery \(exit [1-9]' -and $run.log -match 'tasks were left running') ('When the recovery task cannot be registered, setup refuses and leaves the governor task enabled and running ('+$mode.name+' mode)') ("exit="+$run.exit+" state="+$taskState+" "+$run.log)
        Stop-Process -Id $setup.Id -Force; $setup.WaitForExit(5000)|Out-Null
        Start-Sleep -Seconds 3
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($taskState -eq 'Running' -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) ('Killing setup after the refused suspend leaves the governor task enabled ('+$mode.name+' mode)') ('state='+$taskState)
        $setup=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n','900','127.0.0.1' -WindowStyle Hidden -PassThru
        $run=Invoke-Setup ('denied-'+$mode.name+'-resume') 'Resume' $mode.prefix $setup.Id
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($run.exit -eq 0 -and $taskState -ne 'Disabled') ('The installer runs resume after the refused suspend and it succeeds with the governor enabled ('+$mode.name+' mode)') ("exit="+$run.exit+" state="+$taskState+" "+$run.log)
    }

    foreach($mode in $modes){
        Set-Fixture $true $true $false
        $suspend=Invoke-Setup ($mode.name+'-left-disabled-suspend') 'Suspend' $mode.prefix $setup.Id
        $enables=Get-RecoveryEnables
        $resume=Invoke-Setup ($mode.name+'-left-disabled-resume') 'Resume' $mode.prefix $setup.Id
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($suspend.exit -eq 0 -and $enables -eq 1 -and $resume.exit -eq 0 -and $taskState -ne 'Disabled' -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) ('A governor task left disabled by an earlier killed setup, with saved rules and no pause, is protected by the recovery task and enabled again by resume ('+$mode.name+' mode)') ("suspend="+$suspend.exit+" recoveryEnables="+$enables+" resume="+$resume.exit+" state="+$taskState+" "+$suspend.log+" "+$resume.log)
        Set-Fixture $true $true $true
        $suspend=Invoke-Setup ($mode.name+'-paused-suspend') 'Suspend' $mode.prefix $setup.Id
        $enables=Get-RecoveryEnables
        $resume=Invoke-Setup ($mode.name+'-paused-resume') 'Resume' $mode.prefix $setup.Id
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($suspend.exit -eq 0 -and $enables -eq 0 -and $resume.exit -eq 0 -and $taskState -eq 'Disabled' -and [IO.File]::ReadAllText((Join-Path $policyRoot 'governor.json')) -match '"paused":\s*true') ('A paused governor task stays disabled through setup and is not listed for recovery ('+$mode.name+' mode)') ("suspend="+$suspend.exit+" recoveryEnables="+$enables+" resume="+$resume.exit+" state="+$taskState+" "+$suspend.log+" "+$resume.log)
    }
    foreach($mode in @($modes|Where-Object {$_.name -ne 'full'})){
        Set-Fixture $true $true $false
        $run=Invoke-Setup ($mode.name+'-resume-only-left-disabled') 'Resume' $mode.prefix $setup.Id
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($run.exit -eq 0 -and $taskState -ne 'Disabled') ('Without a setup state file, resume enables a disabled governor task that has saved rules and no pause ('+$mode.name+' mode)') ("exit="+$run.exit+" state="+$taskState+" "+$run.log)
        Set-Fixture $true $true $true
        $run=Invoke-Setup ($mode.name+'-resume-only-paused') 'Resume' $mode.prefix $setup.Id
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($run.exit -eq 0 -and $taskState -eq 'Disabled') ('Without a setup state file, resume leaves a paused governor task disabled ('+$mode.name+' mode)') ("exit="+$run.exit+" state="+$taskState+" "+$run.log)
    }

    Register-UntrustedGovernor
    foreach($mode in $modes){
        Set-Fixture $false $true $false
        $suspend=Invoke-Setup ($mode.name+'-untrusted-suspend') 'Suspend' $mode.prefix $setup.Id
        $enables=Get-RecoveryEnables
        $trustedState=[string](Get-ScheduledTask -TaskName $taskName).State
        $otherState=[string](Get-ScheduledTask -TaskName $untrustedName).State
        $resume=Invoke-Setup ($mode.name+'-untrusted-resume') 'Resume' $mode.prefix $setup.Id
        Check ($suspend.exit -eq 0 -and $enables -eq 1 -and $trustedState -eq 'Disabled' -and $otherState -ne 'Disabled' -and $suspend.log -match [regex]::Escape('Ignoring a task that is not a governor registered by an administrator: '+$untrustedName) -and $resume.exit -eq 0) ('A governor task whose rules folder is outside its owner profile is ignored by setup: not disabled and not listed for recovery ('+$mode.name+' mode)') ("suspend="+$suspend.exit+" recoveryEnables="+$enables+" trusted="+$trustedState+" other="+$otherState+" resume="+$resume.exit+" "+$suspend.log)
    }
    Unregister-ScheduledTask -TaskName $untrustedName -Confirm:$false

    $goodDescription='Roo Industries process rules | '+$me+' | '+$policyRoot
    $decoys=@(
        @{label='an empty description';description=$null;action=(New-GovernorAction $policyRoot)},
        @{label='a description without a Windows user';description='Roo Industries process rules | notasid | ';action=(New-GovernorAction $policyRoot)},
        @{label='a relative rules folder';description=('Roo Industries process rules | '+$me+' | ..\..\Windows\Temp\process-rules');action=(New-GovernorAction $policyRoot)},
        @{label='a rules folder with invalid characters';description=('Roo Industries process rules | '+$me+' | '+$local+'\bad<>|name\process-rules');action=(New-GovernorAction $policyRoot)},
        @{label='an empty rules folder';description=('Roo Industries process rules | '+$me+' | ');action=(New-GovernorAction $policyRoot)},
        @{label='a complete description but another program';description=$goodDescription;action=(New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\PING.EXE') -Argument '-n 900 127.0.0.1')},
        @{label='a complete description and action but a name this product never registers';name='RooIndustriesOptimizationSuite.ProcessRules.NotAnInstallSuffix';description=$goodDescription;action=(New-GovernorAction $policyRoot)}
    )
    $before=@{}
    foreach($decoy in $decoys){
        $decoy.name=if($decoy.name){$decoy.name}else{New-TaskName}
        $decoyNames.Add($decoy.name)
        Register-Governor $decoy.name $decoy.description $decoy.action
        $before[$decoy.name]=[string](Get-ScheduledTask -TaskName $decoy.name).State
    }
    foreach($mode in $modes){
        Set-Fixture $false $true $false
        $suspend=Invoke-Setup ($mode.name+'-decoys-suspend') 'Suspend' $mode.prefix $setup.Id
        $suspendProblems=@(Get-DecoyProblems $decoys $before $suspend.log)
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($suspend.exit -eq 0 -and $taskState -eq 'Disabled' -and $suspendProblems.Count -eq 0) ('Suspend handles the real governor task and skips look-alike tasks with bad descriptions, rules folders, programs or names ('+$mode.name+' mode)') ("exit="+$suspend.exit+" fixture="+$taskState+" "+($suspendProblems -join '; ')+" "+$suspend.log)
        $resume=Invoke-Setup ($mode.name+'-decoys-resume') 'Resume' $mode.prefix $setup.Id
        $resumeProblems=@(Get-DecoyProblems $decoys $before $resume.log)
        $taskState=[string](Get-ScheduledTask -TaskName $taskName).State
        Check ($resume.exit -eq 0 -and $taskState -ne 'Disabled' -and $resumeProblems.Count -eq 0) ('Resume enables the real governor task again and leaves look-alike tasks untouched ('+$mode.name+' mode)') ("exit="+$resume.exit+" fixture="+$taskState+" "+($resumeProblems -join '; ')+" "+$resume.log)
        $remove=Invoke-Setup ($mode.name+'-decoys-remove') 'Remove' $mode.prefix $setup.Id
        $removeProblems=@(Get-DecoyProblems $decoys $before $remove.log)
        Check ($remove.exit -eq 0 -and $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -and $removeProblems.Count -eq 0) ('Remove deletes the real governor task, exits 0 and leaves look-alike tasks untouched ('+$mode.name+' mode)') ("exit="+$remove.exit+" "+($removeProblems -join '; ')+" "+$remove.log)
        Register-FakeGovernor
    }
    Add-Type -TypeDefinition 'public static class RooIndustriesSetupSilentHelper { public static int Main(string[] args) { System.Console.Error.WriteLine("helper failed on purpose"); return 3; } }' -OutputAssembly $hostExe -OutputType ConsoleApplication
    Set-Fixture $false $true $false
    $run=Invoke-Setup 'silent-helper-suspend' 'Suspend' '' $setup.Id
    Check ($run.exit -eq 0 -and $run.log -match 'policy-status failed \(exit 3\): helper failed on purpose' -and $run.log -notmatch 'Cannot bind argument') 'When the helper exits with an error and prints nothing, setup reports the helper''s own failure instead of a parser error' ("exit="+$run.exit+" "+$run.log)
    $resume=Invoke-Setup 'silent-helper-resume' 'Resume' '' $setup.Id
    Set-Fixture $false $true $false
    Set-SilentWorker
    $null=Invoke-Setup 'silent-worker-suspend' 'Suspend' '' $setup.Id
    $run=Invoke-Setup 'silent-worker-resume' 'Resume' '' $setup.Id
    Check ($run.exit -ne 0 -and $null -ne (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue) -and $run.log -match 'Could not resume the governor for .*: Sync failed: the helper printed nothing' -and $run.log -notmatch 'Cannot bind argument') 'When the governor worker prints nothing, Resume reports that instead of a parser error and keeps the recovery task' ("exit="+$run.exit+" "+$run.log)
    $run=Invoke-Setup 'silent-worker-remove' 'Remove' '' $setup.Id
    Check ($run.log -match 'Could not stop the governor cleanly for .*: Remove failed: the helper printed nothing' -and $run.log -notmatch 'Cannot bind argument') 'When the governor worker prints nothing, Remove reports that instead of a parser error' ("exit="+$run.exit+" "+$run.log)
    Register-FakeGovernor
    Remove-Item -LiteralPath $hostExe -Force -ErrorAction SilentlyContinue
    $direct=New-ScheduledTaskAction -Execute (Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe') -Argument ('--headless "'+$hostExe+'" policy-run "'+(Join-Path $policyRoot 'worker-request.json')+'"') -WorkingDirectory $hostDirectory
    $earlier=@(
        @{label='the earlier direct launch';name=(New-TaskName);description=$goodDescription},
        @{label='the earlier legacy name and description';name=(('RooIndustriesOptimizationSuite' -replace 'Industries','')+'.ProcessRules.'+[Guid]::NewGuid().ToString('N').Substring(0,20).ToUpperInvariant());description=(('Roo Industries process rules' -replace ' Industries','')+' | '+$me+' | '+$policyRoot)}
    )
    foreach($task in $earlier){$decoyNames.Add($task.name);Register-Governor $task.name $task.description $direct}
    foreach($mode in $modes){
        Set-Fixture $false $true $false
        $suspend=Invoke-Setup ($mode.name+'-earlier-suspend') 'Suspend' $mode.prefix $setup.Id
        $suspended=@($earlier|ForEach-Object {[string](Get-ScheduledTask -TaskName $_.name).State})
        $ignored=@($earlier|Where-Object {$suspend.log -match [regex]::Escape('Ignoring a task that is not a governor registered by an administrator: '+$_.name)})
        $resume=Invoke-Setup ($mode.name+'-earlier-resume') 'Resume' $mode.prefix $setup.Id
        $resumed=@($earlier|ForEach-Object {[string](Get-ScheduledTask -TaskName $_.name).State})
        Check ($suspend.exit -eq 0 -and @($suspended|Where-Object {$_ -ne 'Disabled'}).Count -eq 0 -and $ignored.Count -eq 0 -and $resume.exit -eq 0 -and @($resumed|Where-Object {$_ -eq 'Disabled'}).Count -eq 0) ('Tasks registered by an earlier version, with the direct launch or the earlier name and description, are still recognised: Suspend disables them and Resume enables them again ('+$mode.name+' mode)') ("suspend="+$suspend.exit+" states="+($suspended -join ',')+" ignored="+$ignored.Count+" resume="+$resume.exit+" after="+($resumed -join ',')+" "+$suspend.log)
    }
    foreach($name in $decoyNames){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue}
} catch {Check $false 'The setup fallback check ran to the end' ($_|Out-String)}
finally {
    foreach($name in @($taskName,$untrustedName,$probeName,$watchdog)+@($decoyNames)){
        try {if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false}} catch {}
        $ErrorActionPreference='Continue'; & (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Delete /TN ('\'+$name) /F 2>$null|Out-Null; $ErrorActionPreference='Stop'
        Check ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) ('The check removed its task '+$name)
    }
    if($setup -and -not $setup.HasExited){Stop-Process -Id $setup.Id -Force -ErrorAction SilentlyContinue}
    foreach($leftover in @(Get-CimInstance Win32_Process|Where-Object {[string]$_.CommandLine -like ('*'+$work+'*') -or ($_.Name -eq 'PING.exe' -and [string]$_.CommandLine -match '-n 900 127\.0\.0\.1' -and $_.CreationDate -ge $started)})){Stop-Process -Id $leftover.ProcessId -Force -ErrorAction SilentlyContinue}
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path $policyRoot -Parent) -Recurse -Force -ErrorAction SilentlyContinue
}
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutDir 'setup-fallbacks.json') -Encoding UTF8
$failed=@($results|Where-Object {-not $_.passed}).Count
"RESULT failures=$failed"
exit [int]($failed -gt 0)
