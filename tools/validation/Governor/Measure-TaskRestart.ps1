$ErrorActionPreference='Stop'
$sid='S-1-5-21-2864832615-2000329836-3074386272-1001'
$dir=Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-governor-restart'
[IO.Directory]::CreateDirectory($dir)|Out-Null
$conhost=Join-Path $env:SystemRoot 'System32\conhost.exe'
$cases=@(
    @{name='RooIndustriesGovernorRestart-OnFailure';exe='restartOnFailure.exe';repeat=$false;restart=$true},
    @{name='RooIndustriesGovernorRestart-Repetition';exe='restartRepetition.exe';repeat=$true;restart=$false}
)
$result=[ordered]@{startedAtUtc=[DateTime]::UtcNow.ToString('o');cases=@()}
try {
    foreach($case in $cases){
        Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') (Join-Path $dir $case.exe) -Force
        if(Get-ScheduledTask -TaskName $case.name -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $case.name -Confirm:$false}
        $action=New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+(Join-Path $dir $case.exe)+'" -n 3600 127.0.0.1')
        $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
        $settings=if($case.restart){New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)}else{New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew}
        $trigger=if($case.repeat){New-ScheduledTaskTrigger -Once -At ([DateTime]::Now) -RepetitionInterval (New-TimeSpan -Minutes 1)}else{New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddDays(1))}
        Register-ScheduledTask -TaskName $case.name -Action $action -Principal $principal -Settings $settings -Trigger $trigger|Out-Null
        Start-ScheduledTask -TaskName $case.name
    }
    Start-Sleep -Seconds 5
    $killed=@{}
    foreach($case in $cases){
        $process=@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($case.exe)) -ErrorAction SilentlyContinue)
        $killed[$case.name]=@($process|ForEach-Object {$_.Id})
        $process|Stop-Process -Force
    }
    $killedAt=[DateTime]::UtcNow
    $seen=@{}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt 150){
        foreach($case in $cases){
            if($seen.ContainsKey($case.name)){continue}
            $again=@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($case.exe)) -ErrorAction SilentlyContinue|Where-Object {$killed[$case.name] -notcontains $_.Id})
            if($again.Count -gt 0){$seen[$case.name]=[Math]::Round($clock.Elapsed.TotalSeconds,1)}
        }
        Start-Sleep -Seconds 2
    }
    foreach($case in $cases){
        $task=Get-ScheduledTask -TaskName $case.name
        $info=Get-ScheduledTaskInfo -TaskName $case.name
        $result.cases+=[ordered]@{task=$case.name;restartOnFailureSettings=$case.restart;repetitionTrigger=$case.repeat;killedPids=$killed[$case.name];restartedAfterSeconds=$seen[$case.name];lastTaskResult=('0x{0:X}' -f $info.LastTaskResult);state=[string]$task.State
            triggerRepetition=@($task.Triggers|ForEach-Object {[ordered]@{interval=$_.Repetition.Interval;duration=$_.Repetition.Duration;stopAtDurationEnd=$_.Repetition.StopAtDurationEnd}});restartCount=$task.Settings.RestartCount;restartInterval=$task.Settings.RestartInterval}
    }
} finally {
    foreach($case in $cases){
        if(Get-ScheduledTask -TaskName $case.name -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $case.name -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $case.name -Confirm:$false}
        Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($case.exe)) -ErrorAction SilentlyContinue|Stop-Process -Force
    }
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
$result.finishedAtUtc=[DateTime]::UtcNow.ToString('o')
$result|ConvertTo-Json -Depth 6
