param([Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir|Out-Null
$results=New-Object System.Collections.Generic.List[object]
function Check([bool]$Condition,[string]$Message,[string]$Detail=''){$results.Add([pscustomobject]@{passed=$Condition;check=$Message;detail=$Detail});if($Condition){"PASS $Message"}else{"FAIL $Message :: $Detail"}}
$watchdog='RooIndustriesOptimizationSuite.GovernorSetupWatchdog'
if(@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue).Count -gt 0 -or (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue)){throw 'Governor or setup recovery tasks already exist on this PC; refusing to run the setup fallback check.'}
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$local=[Environment]::GetFolderPath('LocalApplicationData')
$work=Join-Path $env:SystemRoot ('Temp\roo-industries-setup-check-'+$id)
$appRoot=Join-Path $work 'app'
$policyRoot=Join-Path $local ('RooIndustriesSetupCheck-'+$id+'\process-rules')
$taskName='RooIndustriesOptimizationSuite.ProcessRules.SetupCheck'+$id
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $appRoot 'backend\scripts'),$policyRoot|Out-Null
$copy=Join-Path $work 'Invoke-GovernorSetup.ps1'
Copy-Item -LiteralPath $Script -Destination $copy
function Set-Worker([string]$Status){
    $body="param([string]`$Action,[string]`$PolicyRoot,[string]`$HostDirectory,[switch]`$ConfirmApply)`r`n# 'Sync'`r`n"+'[pscustomobject]@{schemaVersion=1;status='''+$Status+''';data=[pscustomobject]@{registered=$true;enabled=$true;paused=$false;worker=[pscustomobject]@{hostRunning=$true}};errors=@([pscustomobject]@{message=''forced '+$Status+'''})}|ConvertTo-Json -Depth 5'
    [IO.File]::WriteAllText((Join-Path $appRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'),$body,[Text.UTF8Encoding]::new($true))
}
function Register-FakeGovernor {
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\PING.EXE') -Argument '-n 900 127.0.0.1'
    $principal=New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Description ('Roo Industries process rules | '+$me+' | '+$policyRoot) -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force|Out-Null
    Start-ScheduledTask -TaskName $taskName
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while([string](Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -and $clock.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 200}
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
} catch {Check $false 'The setup fallback check ran to the end' ($_|Out-String)}
finally {
    foreach($name in @($taskName,$watchdog)){
        try {if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $name -Confirm:$false}} catch {}
        $ErrorActionPreference='Continue'; & (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Delete /TN ('\'+$name) /F 2>$null|Out-Null; $ErrorActionPreference='Stop'
        Check ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) ('The check removed its task '+$name)
    }
    if($setup -and -not $setup.HasExited){Stop-Process -Id $setup.Id -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Split-Path $policyRoot -Parent) -Recurse -Force -ErrorAction SilentlyContinue
}
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutDir 'setup-fallbacks.json') -Encoding UTF8
$failed=@($results|Where-Object {-not $_.passed}).Count
"RESULT failures=$failed"
exit [int]($failed -gt 0)
