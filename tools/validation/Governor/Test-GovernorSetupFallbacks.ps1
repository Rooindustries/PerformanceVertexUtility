param([Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$OutDir,[ValidateSet('All','Identity','Responses','Poison','FolderDrive')][string]$Scenario='All',[string]$ResponseCase='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir|Out-Null
$results=New-Object System.Collections.Generic.List[object]
function Check([bool]$Condition,[string]$Message,[string]$Detail=''){$results.Add([pscustomobject]@{passed=$Condition;check=$Message;detail=$Detail});if($Condition){"PASS $Message"}else{"FAIL $Message :: $Detail"}}
function Stop-FixtureRow($Row){
    $process=Get-Process -Id $Row.ProcessId -ErrorAction SilentlyContinue
    if(-not $process){return}
    try {
        $null=$process.Handle
        $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Row.ProcessId) -ErrorAction Stop
        if($current -and $current.CreationDate -eq $Row.CreationDate -and $current.ExecutablePath -ieq $Row.ExecutablePath -and $current.CommandLine -ceq $Row.CommandLine){$process.Kill()}
    } finally {$process.Dispose()}
}
$watchdog='RooIndustriesOptimizationSuite.GovernorSetupWatchdog'
if(@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue).Count -gt 0 -or (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)){Check $false 'The setup fallback fixture has an isolated Task Scheduler' 'Existing governor or recovery tasks; refusing to touch them';$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutDir 'setup-fallbacks.json') -Encoding UTF8;'RESULT failures=1';exit 1}
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$started=Get-Date
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$local=[Environment]::GetFolderPath('LocalApplicationData')
$work=Join-Path $env:SystemRoot ('Temp\roo-industries-setup-check-'+$id)
$appRoot=Join-Path $work 'Roo Industries café 日本'
$policyRoot=Join-Path $local ('RooIndustriesSetupCheck-'+$id+' café 日本\process-rules')
function New-TaskName{return 'RooIndustriesOptimizationSuite.ProcessRules.'+[Guid]::NewGuid().ToString('N').Substring(0,20).ToUpperInvariant()}
$taskName=New-TaskName
$untrustedName=New-TaskName
$decoyNames=New-Object System.Collections.Generic.List[string]
$probeName='RooIndustriesSetupCheckProbe'+$id
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hostDirectory=Join-Path $appRoot 'backend\bin\optimizer'
$hostExe=Join-Path $hostDirectory 'Optimizer.Host.exe'
$hostDll=Join-Path $hostDirectory 'Optimizer.Host.dll'
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$conhost=Join-Path $env:SystemRoot 'System32\conhost.exe'
$ping=Join-Path $env:SystemRoot 'System32\PING.EXE'
$request=Join-Path $policyRoot 'worker-request.json'
$policyParent=Split-Path $policyRoot -Parent
if((Test-Path -LiteralPath $work) -or (Test-Path -LiteralPath $policyParent)){Check $false 'The setup fallback fixture paths are absent' 'Refusing to reuse an existing folder';$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutDir 'setup-fallbacks.json') -Encoding UTF8;'RESULT failures=1';exit 1}
New-Item -ItemType Directory -Path $work,$policyParent|Out-Null
Set-Content -LiteralPath (Join-Path $work 'fixture-owner.txt') -Value $id -Encoding ASCII
Set-Content -LiteralPath (Join-Path $policyParent 'fixture-owner.txt') -Value $id -Encoding ASCII
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
    $tasks=@{}
    foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)){$tasks[$task.TaskName]=$task}
    foreach($decoy in $Decoys){
        $task=$tasks[$decoy.name]
        if(-not $task){$problems+=($decoy.label+': it is no longer registered');continue}
        if([string]$task.State -ne $Before[$decoy.name].state){$problems+=($decoy.label+': its state changed to '+$task.State)}
        $actionText=($task.Actions|ConvertTo-Json -Depth 5 -Compress)
        if($actionText -cne $Before[$decoy.name].actions -or $task.Description -cne $Before[$decoy.name].description -or $task.Principal.UserId -cne $Before[$decoy.name].userId){$problems+=($decoy.label+': its definition changed')}
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
    $command=$Prefix+$fixtureOnly+"try { & '"+$copy+"' -Action "+$Action+" -AppRoot '"+$appRoot+"' -StatePath '"+$state+"' -LogPath '"+$log+"'"+$identity+'; exit $LASTEXITCODE } catch { $_ | Out-String | Write-Error; exit 99 }'
    $process=Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-NonInteractive','-OutputFormat','Text','-ExecutionPolicy','Bypass','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput (Join-Path $work ($Name+'.out')) -RedirectStandardError (Join-Path $work ($Name+'.err'))
    $text=@(if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log})+@(Get-Content -LiteralPath (Join-Path $work ($Name+'.err')) -ErrorAction SilentlyContinue)
    Copy-Item -LiteralPath $log -Destination (Join-Path $OutDir ($Name+'.log')) -ErrorAction SilentlyContinue
    [pscustomobject]@{exit=$process.ExitCode;log=($text -join "`n")}
}
$fixtureOnly=@'
function Test-Path {
    param([string]$LiteralPath,[string]$Path,[string]$PathType)
    $target=if($LiteralPath){$LiteralPath}else{$Path}
    if($target -in @('CURRENT_RULES','LEGACY_RULES')){return $false}
    $parameters=@{}
    if($LiteralPath){$parameters.LiteralPath=$LiteralPath}else{$parameters.Path=$Path}
    if($PathType){$parameters.PathType=$PathType}
    Microsoft.PowerShell.Management\Test-Path @parameters
}

'@
$fixtureOnly=$fixtureOnly.Replace('CURRENT_RULES',(Join-Path $local 'RooIndustriesOptimizationSuite\process-rules\rules').Replace("'","''")).Replace('LEGACY_RULES',(Join-Path $local 'RooOptimizationSuite\process-rules\rules').Replace("'","''"))
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

    if($Scenario -in @('All','FolderDrive')){
        $fsutil=Join-Path $env:SystemRoot 'System32\fsutil.exe'
        foreach($case in @(@{name='localized';body='$global:LASTEXITCODE=0; ''C: - Lecteur fixe'''},@{name='unavailable';body='$global:LASTEXITCODE=1; ''Drive provider unavailable'''})){
            Register-FakeGovernor
            Set-Fixture $false $true $false
            Start-Fixture
            $rule=Join-Path $policyRoot 'rules\rule.json'
            $before=(Get-FileHash -LiteralPath $rule -Algorithm SHA256).Hash
            $prefix=('function global:'+$fsutil+' { '+$case.body+' }; function Get-Volume { throw ''Storage provider unavailable'' }; ')+$noTasks+$clm
            $run=Invoke-Setup ($case.name+'-drive-suspend') 'Suspend' $prefix $setup.Id
            Check ($run.exit -eq 0 -and [string](Get-ScheduledTask -TaskName $taskName).State -eq 'Disabled') ('Scheduler fallback suspends the exact registered governor with '+$case.name+' drive information') ('exit='+$run.exit+' '+$run.log)
            $run=Invoke-Setup ($case.name+'-drive-resume') 'Resume' $prefix $setup.Id
            Check ($run.exit -eq 0 -and [string](Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled' -and $null -eq (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)) ('Scheduler fallback resumes the exact registered governor with '+$case.name+' drive information') ('exit='+$run.exit+' '+$run.log)
            $run=Invoke-Setup ($case.name+'-drive-remove') 'Remove' $prefix $setup.Id
            Check ($run.exit -eq 0 -and $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) -and (Get-FileHash -LiteralPath $rule -Algorithm SHA256).Hash -ceq $before) ('Scheduler fallback removes only its task and retains the saved rules with '+$case.name+' drive information') ('exit='+$run.exit+' '+$run.log)
            if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $taskName;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
        }
    }

    if($Scenario -eq 'All'){
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
        $setup.Kill(); $setup.WaitForExit(5000)|Out-Null
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
        $setup.Kill(); $setup.WaitForExit(5000)|Out-Null
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

    } elseif($Scenario -ne 'FolderDrive'){Register-FakeGovernor}
    $goodDescription='Roo Industries process rules | '+$me+' | '+$policyRoot
    if($Scenario -eq 'Poison'){
        $decoyWindows=Join-Path $work 'poisoned-Windows'
        $decoyTasks=Join-Path $decoyWindows 'System32\Tasks'
        New-Item -ItemType Directory -Force -Path $decoyTasks|Out-Null
        $decoyXml=Export-ScheduledTask -TaskName $taskName
        $decoyXml=$decoyXml.Replace('Roo Industries process rules | ','Fabricated process rules | ')
        [IO.File]::WriteAllText((Join-Path $decoyTasks $taskName),$decoyXml,[Text.Encoding]::Unicode)
        foreach($mode in @(@{name='nowmi';prefix=$noTasks},@{name='clm';prefix=$clm})){
            Set-Fixture $false $true $false
            $prefix='@()|ConvertTo-Json|Out-Null; '+$mode.prefix+'$env:SystemRoot='''+$decoyWindows.Replace("'","''")+'''; '
            $run=Invoke-Setup ($mode.name+'-systemroot-decoy-suspend') 'Suspend' $prefix $setup.Id
            $state=[string](Get-ScheduledTask -TaskName $taskName).State
            Check ($run.exit -eq 0 -and $state -eq 'Disabled' -and $run.log -match 'Suspended 1 governor tasks' -and $run.log -notmatch ('Ignoring.*'+[regex]::Escape($taskName))) ('RV2e: scheduler XML stays authoritative under poisoned SystemRoot with a fabricated native task file ('+$mode.name+')') ('exit='+$run.exit+' state='+$state+' '+$run.log)
            $resume=Invoke-Setup ($mode.name+'-systemroot-decoy-resume') 'Resume' $prefix $setup.Id
            Check ($resume.exit -eq 0 -and [string](Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled') ('RV2e: the real Unicode task resumes under poisoned SystemRoot ('+$mode.name+')') ('exit='+$resume.exit+' '+$resume.log)
        }
    }
    if($Scenario -in @('All','Identity')){
    $decoys=@(
        @{label='an empty description';description=$null;action=(New-GovernorAction $policyRoot)},
        @{label='a description without a Windows user';description='Roo Industries process rules | notasid | ';action=(New-GovernorAction $policyRoot)},
        @{label='a relative rules folder';description=('Roo Industries process rules | '+$me+' | ..\..\Windows\Temp\process-rules');action=(New-GovernorAction $policyRoot)},
        @{label='a rules folder with invalid characters';description=('Roo Industries process rules | '+$me+' | '+$local+'\bad<>|name\process-rules');action=(New-GovernorAction $policyRoot)},
        @{label='an empty rules folder';description=('Roo Industries process rules | '+$me+' | ');action=(New-GovernorAction $policyRoot)},
        @{label='clean launcher with another payload executable';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $ping @('policy-run',$request) $hostDirectory)},
        @{label='clean Host with a different request';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',($request+'.other')) $hostDirectory)},
        @{label='clean Host with an extra argument';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',$request,'extra') $hostDirectory)},
        @{label='clean Host with another action';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $hostExe @('not-policy-run',$request) $hostDirectory)},
        @{label='direct Host with substring action';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $hostExe -Argument ('not-policy-run "'+$request+'"'))},
        @{label='direct Host with a different request';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $hostExe -Argument ('policy-run "'+$request+'.other"'))},
        @{label='direct Host with an extra argument';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $hostExe -Argument ('policy-run "'+$request+'" extra'))},
        @{label='direct unrelated executable with this Host dll';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $ping -Argument ('"'+$hostDll+'" policy-run "'+$request+'"'))},
        @{label='legacy conhost with unrelated executable and this Host dll';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$ping+'" "'+$hostDll+'" policy-run "'+$request+'"'))},
        @{label='legacy conhost Host with a different request';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$hostExe+'" policy-run "'+$request+'.other"'))},
        @{label='legacy conhost Host with an extra argument';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$hostExe+'" policy-run "'+$request+'" extra'))},
        @{label='direct dotnet with another dll';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $dotnet -Argument ('"'+$hostDll+'.other" policy-run "'+$request+'"'))},
        @{label='direct dotnet with an extra argument';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $dotnet -Argument ('"'+$hostDll+'" policy-run "'+$request+'" extra'))},
        @{label='direct dotnet with a different request';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $dotnet -Argument ('"'+$hostDll+'" policy-run "'+$request+'.other"'))},
        @{label='legacy dotnet with another dll';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$dotnet+'" "'+$hostDll+'.other" policy-run "'+$request+'"'))},
        @{label='legacy dotnet with an extra argument';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$dotnet+'" "'+$hostDll+'" policy-run "'+$request+'" extra'))},
        @{label='clean dotnet with another dll';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $dotnet @(($hostDll+'.other'),'policy-run',$request) $hostDirectory)},
        @{label='clean dotnet with another request';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $dotnet @($hostDll,'policy-run',($request+'.other')) $hostDirectory)},
        @{label='a complete description but another program';description=$goodDescription;action=(New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\PING.EXE') -Argument '-n 900 127.0.0.1')},
        @{label='a complete description and action but a name this product never registers';name='RooIndustriesOptimizationSuite.ProcessRules.NotAnInstallSuffix';description=$goodDescription;action=(New-GovernorAction $policyRoot)}
    )
    $clean=New-GovernorAction $policyRoot
    $fakeDotnet=Join-Path $hostDirectory 'dotnet.exe'
    Copy-Item -LiteralPath $ping -Destination $fakeDotnet
    $decoys+=@(
        @{label='clean launcher with a suffix payload';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ($clean.Arguments+' & "'+$ping+'"'))},
        @{label='clean launcher with another launcher path';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument $clean.Arguments.Replace('Start-RooIndustriesHelper.cmd','AnotherHelper.cmd'))},
        @{label='clean launcher with another shell';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument $clean.Arguments.Replace('cmd.exe','PING.EXE'))},
        @{label='clean launcher with another outer executable';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $ping -Argument $clean.Arguments)},
        @{label='direct fake dotnet executable';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $fakeDotnet -Argument ('"'+$hostDll+'" policy-run "'+$request+'"'))},
        @{label='legacy conhost fake dotnet executable';description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$fakeDotnet+'" "'+$hostDll+'" policy-run "'+$request+'"'))},
        @{label='clean fake dotnet executable';description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $fakeDotnet @($hostDll,'policy-run',$request) $hostDirectory)},
        @{label='multiple governor actions';description=$goodDescription;action=@($clean,$clean)}
    )
    [IO.File]::WriteAllText((Join-Path $hostDirectory 'Optimizer.Host.runtimeconfig.json'),' {"runtimeOptions":{"framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}')
    $percentRoot=$policyRoot+' %windir%'
    $caretRoot=$policyRoot+' ^ marker'
    $decoys+=@(
        @{label='clean launcher with expanding percent path';description=('Roo Industries process rules | '+$me+' | '+$percentRoot);action=(New-ScheduledTaskAction -Execute $conhost -Argument $clean.Arguments.Replace($request,($percentRoot+'\worker-request.json')))},
        @{label='clean launcher with unsupported caret path';description=('Roo Industries process rules | '+$me+' | '+$caretRoot);action=(New-ScheduledTaskAction -Execute $conhost -Argument $clean.Arguments.Replace($request,($caretRoot+'\worker-request.json')))}
    )
    $before=@{}
    foreach($decoy in $decoys){
        $decoy.name=if($decoy.name){$decoy.name}else{New-TaskName}
        $decoyNames.Add($decoy.name)
        Register-Governor $decoy.name $decoy.description $decoy.action
        $saved=Get-ScheduledTask -TaskName $decoy.name
        $before[$decoy.name]=@{state=[string]$saved.State;actions=($saved.Actions|ConvertTo-Json -Depth 5 -Compress);description=$saved.Description;userId=$saved.Principal.UserId}
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
    }
    if($Scenario -in @('All','Responses')){
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class RooIndustriesSetupResponseHelper {
 public static int Main(string[] args) {
  Console.In.ReadToEnd();
  string path=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"response.txt");
  string[] response=File.ReadAllLines(path);
  if(response[1].Length>0) Console.Error.WriteLine(response[1]);
  if(response.Length>2) Console.Out.WriteLine(string.Join("\n",response,2,response.Length-2));
  return int.Parse(response[0]);
 }
}
'@ -OutputAssembly $hostExe -OutputType ConsoleApplication
    $completed='{"status":"completed","data":{"hostRunning":false,"state":{"status":"stopped"}}}'
    $hostResponses=@(
        @{name='nonzero-completed';code=3;stderr='';json=$completed;reason='policy-status failed \(exit 3\)'},
        @{name='stderr-completed';code=0;stderr='host-error-before-completed';json=$completed;reason='policy-status failed \(exit 0\): host-error-before-completed'},
        @{name='silent-helper';code=3;stderr='helper failed on purpose';json='';reason='policy-status failed \(exit 3\): helper failed on purpose'},
        @{name='array-status-helper';code=0;stderr='';json='{"status":["completed"],"data":{}}';reason='policy-status failed \(exit 0\)'},
        @{name='valid-helper';code=0;stderr='';json=$completed;reason='Governor was not running'}
    )
    $selectedResponses=0
    if($ResponseCase){$hostResponses=@($hostResponses|Where-Object {$_.name -eq $ResponseCase})}
    foreach($response in $hostResponses){
        $selectedResponses++
        Set-Fixture $false $true $false
        [IO.File]::WriteAllText((Join-Path $hostDirectory 'response.txt'),($response.code.ToString()+"`r`n"+$response.stderr+"`r`n"+$response.json))
        $run=Invoke-Setup ($response.name+'-suspend') 'Suspend' '' $setup.Id
        Check ($run.exit -eq 0 -and $run.log -match $response.reason -and $run.log -notmatch 'Cannot bind argument') ('Host output: '+$response.name+' is classified truthfully during Suspend') ("exit="+$run.exit+" "+$run.log)
    }
    [IO.File]::WriteAllText((Join-Path $hostDirectory 'response.txt'),("0`r`n`r`n"+$completed))
    $validWorker='{"schemaVersion":1,"status":"completed","data":{"registered":true,"enabled":true,"paused":false,"worker":{"hostRunning":true}}}'
    $workerResponses=@(
        @{name='silent-worker';body='';reason='the helper printed nothing'},
        @{name='invalid-worker';body="'not-json-worker'";reason='not-json-worker'},
        @{name='missing-status-worker';body='''{"data":{}}''';reason='invalid response'},
        @{name='missing-data-worker';body='''{"status":"completed"}''';reason='invalid response'},
        @{name='array-status-worker';body='''{"status":["completed"],"data":{}}''';reason='invalid response'},
        @{name='array-data-worker';body='''{"status":"completed","data":[]}''';reason='invalid response'},
        @{name='array-worker';body=("' ["+$validWorker+"] '");reason='invalid response'},
        @{name='nonzero-completed-worker';body=("'"+$validWorker+"'; exit 3");reason='exit 3'},
        @{name='error-completed-worker';body=("Write-Error 'worker-error-before-completed'; '"+$validWorker+"'");reason='worker-error-before-completed'},
        @{name='failed-worker';body='''{"status":"failed","errors":[{"message":"worker-failure-message"}]}''';reason='worker-failure-message'},
        @{name='failed-no-message-worker';body='''{"status":"failed"}''';reason='invalid response'},
        @{name='valid-worker';body=("'"+$validWorker+"'");reason='';valid=$true}
    )
    if($ResponseCase){$workerResponses=@($workerResponses|Where-Object {$_.name -eq $ResponseCase})}
    foreach($response in $workerResponses){
        $selectedResponses++
        Set-Fixture $false $true $false
        $null=Invoke-Setup ($response.name+'-suspend') 'Suspend' '' $setup.Id
        $body="param([string]`$Action,[string]`$PolicyRoot,[string]`$HostDirectory,[switch]`$ConfirmApply)`r`n# 'Sync'`r`n"+"if(`$PolicyRoot -ine '"+$policyRoot.Replace("'","''")+"'){throw 'Worker request escaped fixture'}; "+$response.body
        [IO.File]::WriteAllText((Join-Path $appRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'),$body,[Text.UTF8Encoding]::new($true))
        $run=Invoke-Setup ($response.name+'-resume') 'Resume' '' $setup.Id
        $recovery=[bool](Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)
        $ok=if($response.valid){$run.exit -eq 0 -and -not $recovery -and $run.log -match 'Governor synced'}else{$run.exit -eq 2 -and $recovery -and $run.log -match ('Sync failed: .*'+$response.reason) -and $run.log -notmatch 'Governor synced'}
        Check $ok ('Worker output: '+$response.name+' has truthful Resume exit and recovery') ("exit="+$run.exit+" recovery="+$recovery+" "+$run.log)
        $run=Invoke-Setup ($response.name+'-remove') 'Remove' '' $setup.Id
        $ok=if($response.valid){$run.exit -eq 0 -and $run.log -match 'Governor stopped, settings restored and task removed'}else{$run.exit -eq 0 -and $run.log -match ('Remove failed: .*'+$response.reason) -and $run.log -notmatch 'Governor stopped, settings restored and task removed'}
        Check $ok ('Worker output: '+$response.name+' has truthful Remove diagnostics') ("exit="+$run.exit+" "+$run.log)
        Register-FakeGovernor
    }
    if($ResponseCase -and $selectedResponses -eq 0){Check $false 'The named response case ran' ('Unknown response case: '+$ResponseCase)}
    }
    if($Scenario -in @('All','Identity')){
    Register-FakeGovernor
    Remove-Item -LiteralPath $hostExe -Force -ErrorAction SilentlyContinue
    $direct=New-ScheduledTaskAction -Execute (Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe') -Argument ('--headless "'+$hostExe+'" policy-run "'+(Join-Path $policyRoot 'worker-request.json')+'"') -WorkingDirectory $hostDirectory
    $earlier=@(
        @{label='the earlier conhost Host launch';name=(New-TaskName);description=$goodDescription;action=$direct},
        @{label='the earlier legacy name and description';name=(('RooIndustriesOptimizationSuite' -replace 'Industries','')+'.ProcessRules.'+[Guid]::NewGuid().ToString('N').Substring(0,20).ToUpperInvariant());description=(('Roo Industries process rules' -replace ' Industries','')+' | '+$me+' | '+$policyRoot)}
    )
    if(-not (Test-Path -LiteralPath $dotnet)){throw 'The retained development action check needs the existing Windows SDK'}
    $earlier+=@(
        @{label='direct Host';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $hostExe -Argument ('policy-run "'+$request+'"'))},
        @{label='direct dotnet';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $dotnet -Argument ('"'+$hostDll+'" policy-run "'+$request+'"'))},
        @{label='conhost dotnet';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$dotnet+'" "'+$hostDll+'" policy-run "'+$request+'"'))},
        @{label='old clean Host';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+(Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe')+'" /d /v:off /c call "'+(Join-Path $appRoot 'backend\scripts\Start-RooIndustriesHelper.cmd')+'" " ?'+$hostExe+'?policy-run?'+$request+'"'))},
        @{label='old clean dotnet';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+(Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe')+'" /d /v:off /c call "'+(Join-Path $appRoot 'backend\scripts\Start-RooIndustriesHelper.cmd')+'" " ?'+$dotnet+'?'+$hostDll+'?policy-run?'+$request+'"'))},
        @{label='clean dotnet';name=(New-TaskName);description=$goodDescription;action=(New-RooIndustriesElevatedTaskAction $dotnet @($hostDll,'policy-run',$request) $hostDirectory)}
    )
    $historicalClear=(@('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_ARM64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')|ForEach-Object {'set '+$_+'='}) -join '&'
    $inlinePrefix='--headless "'+(Join-Path $env:SystemRoot 'System32\cmd.exe')+'" /d /s /c "'+$historicalClear+'&"'
    $earlier+=@(
        @{label='historical inline cmd Host';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ($inlinePrefix+$hostExe+'" policy-run "'+$request+'""'))},
        @{label='historical inline cmd dotnet';name=(New-TaskName);description=$goodDescription;action=(New-ScheduledTaskAction -Execute $conhost -Argument ($inlinePrefix+$dotnet+'" "'+$hostDll+'" policy-run "'+$request+'""'))}
    )
    foreach($task in $earlier){$decoyNames.Add($task.name);Register-Governor $task.name $task.description $(if($task.action){$task.action}else{$direct})}
    foreach($mode in $modes){
        Set-Fixture $false $true $false
        $suspend=Invoke-Setup ($mode.name+'-earlier-suspend') 'Suspend' $mode.prefix $setup.Id
        $suspended=@($earlier|ForEach-Object {[string](Get-ScheduledTask -TaskName $_.name).State})
        $ignored=@($earlier|Where-Object {$suspend.log -match [regex]::Escape('Ignoring a task that is not a governor registered by an administrator: '+$_.name)})
        $resume=Invoke-Setup ($mode.name+'-earlier-resume') 'Resume' $mode.prefix $setup.Id
        $resumed=@($earlier|ForEach-Object {[string](Get-ScheduledTask -TaskName $_.name).State})
        Check ($suspend.exit -eq 0 -and @($suspended|Where-Object {$_ -ne 'Disabled'}).Count -eq 0 -and $ignored.Count -eq 0 -and $resume.exit -eq 0 -and @($resumed|Where-Object {$_ -eq 'Disabled'}).Count -eq 0) ('Tasks registered by an earlier version, with the direct launch or the earlier name and description, are still recognised: Suspend disables them and Resume enables them again ('+$mode.name+' mode)') ("suspend="+$suspend.exit+" states="+($suspended -join ',')+" ignored="+$ignored.Count+" resume="+$resume.exit+" after="+($resumed -join ',')+" "+$suspend.log)
        $remove=Invoke-Setup ($mode.name+'-earlier-remove') 'Remove' $mode.prefix $setup.Id
        $remaining=@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -in @($earlier.name)})
        Check ($remove.exit -eq 0 -and $remaining.Count -eq 0) ('All supported historical actions are removed during uninstall ('+$mode.name+' mode)') ("exit="+$remove.exit+" remaining="+$remaining.Count+" "+$remove.log)
        Register-FakeGovernor
        foreach($task in $earlier){Register-Governor $task.name $task.description $(if($task.action){$task.action}else{$direct})}

    }
    foreach($name in $decoyNames){Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue}
    }
} catch {Check $false 'The setup fallback check ran to the end' ($_|Out-String)}
finally {
    foreach($name in @($taskName,$untrustedName,$probeName,$watchdog)+@($decoyNames)){
        try {if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false}} catch {}
        $ErrorActionPreference='Continue'; & (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Delete /TN ('\'+$name) /F 2>$null|Out-Null; $ErrorActionPreference='Stop'
        Check ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) ('The check removed its task '+$name)
    }
    if($setup -and -not $setup.HasExited){$setup.Kill();$setup.WaitForExit(5000)|Out-Null}
    $processes=@(Get-CimInstance Win32_Process)
    $owned=@($processes|Where-Object {[string]$_.CommandLine -like ('*'+$work+'*')}|ForEach-Object {$_.ProcessId})
    do {$children=@(foreach($parentId in $owned){$parentRow=$processes|Where-Object ProcessId -eq $parentId;$processes|Where-Object {$_.ParentProcessId -eq $parentId -and $_.CreationDate -ge $parentRow.CreationDate -and $_.ProcessId -notin $owned}|ForEach-Object ProcessId});$owned+=@($children)}while($children.Count)
    foreach($leftover in @($processes|Where-Object {$_.ProcessId -in $owned -and $_.CreationDate -ge $started})){Stop-FixtureRow $leftover}
    Start-Sleep -Seconds 1
    foreach($tree in @($work,$policyParent)){
        $marker=Join-Path $tree 'fixture-owner.txt'
        if((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $id){Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue}
        Check (-not (Test-Path -LiteralPath $tree)) 'The check removed its marker-owned fixture tree'
    }
}
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutDir 'setup-fallbacks.json') -Encoding UTF8
$failed=@($results|Where-Object {-not $_.passed}).Count
"RESULT failures=$failed"
exit [int]($failed -gt 0)
