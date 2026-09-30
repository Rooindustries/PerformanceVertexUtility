param(
    [Parameter(Mandatory=$true)][ValidateSet('Suspend','Resume','Remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [string]$StatePath='',
    [string]$LogPath=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$OutputEncoding=[Text.UTF8Encoding]::new($false)
$AppRoot=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
$hostExe=Join-Path $AppRoot 'backend\bin\optimizer\Optimizer.Host.exe'
$workerScript=Join-Path $AppRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$watchdog='RooIndustriesOptimizationSuite.GovernorSetupWatchdog'
$conhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
$schtasks=Join-Path ([Environment]::GetFolderPath('System')) 'schtasks.exe'

function Write-Log([string]$Text){
    $line=[DateTime]::UtcNow.ToString('o')+' '+$Action+' '+$Text
    if($LogPath){[IO.File]::AppendAllText($LogPath,$line+"`r`n",[Text.UTF8Encoding]::new($false))}
    [Console]::Out.WriteLine($line)
}

function Get-Sid([string]$Account){
    if($Account -match '^S-1-'){return $Account}
    try {return [Security.Principal.NTAccount]::new($Account).Translate([Security.Principal.SecurityIdentifier]).Value} catch {return ''}
}

function Get-GovernorTasks {
    foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)){
        $parts=@([string]$task.Description -split ' \| ',3)
        if($parts.Count -ne 3 -or $parts[1] -notmatch '^S-1-'){Write-Log ('Skipping task with an unexpected description: '+$task.TaskName);continue}
        $profile=@(Get-CimInstance Win32_UserProfile -Filter ("SID='"+$parts[1]+"'") -ErrorAction SilentlyContinue)[0]
        $local=if($profile){[IO.Path]::GetFullPath((Join-Path $profile.LocalPath 'AppData\Local')).TrimEnd('\')+'\'}elseif($parts[1] -eq $me){[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'}else{$null}
        $root=try{[IO.Path]::GetFullPath($parts[2])}catch{''}
        $trusted=[string]$task.Principal.RunLevel -eq 'Highest' -and (Get-Sid ([string]$task.Principal.UserId)) -eq $parts[1] -and $local -and $root.StartsWith($local,[StringComparison]::OrdinalIgnoreCase)
        [pscustomobject]@{taskName=$task.TaskName;taskPath=$task.TaskPath;description=[string]$task.Description;userSid=$parts[1];policyRoot=$root;enabled=([string]$task.State -ne 'Disabled');trusted=[bool]$trusted}
    }
}

function Save-Records($Records){
    if($StatePath){[IO.File]::WriteAllText($StatePath,(ConvertTo-Json -InputObject @($Records.ToArray()) -Depth 5),[Text.UTF8Encoding]::new($false))}
}

function Invoke-Host([string]$HostAction,[string]$PolicyRoot,[hashtable]$Extra=@{}){
    $request=@{schemaVersion=1;repoRoot=$AppRoot;policyRoot=$PolicyRoot;confirm=$true}
    foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
    $json=$request|ConvertTo-Json -Depth 5 -Compress
    $text=@($json|& $hostExe $HostAction '-') -join "`n"
    $result=$text|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -and [string]$result.error.message -match "'-'|path|file"){
        $directory=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-setup-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($directory)|Out-Null
        try {
            $path=Join-Path $directory 'request.json'
            [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))
            $result=(@(& $hostExe $HostAction $path) -join "`n")|ConvertFrom-Json
        } finally {Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue}
    }
    if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw ($HostAction+' failed: '+$result.error.message)}
    return $result.data
}

function Get-Workers {
    $prefix=(Join-Path $AppRoot 'backend\bin\optimizer')+'\'
    return @(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'"|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [string]$_.CommandLine -match 'policy-run'})
}

function Stop-Leftovers {
    foreach($worker in Get-Workers){
        Write-Log ('Ending leftover governor process '+$worker.ProcessId+': '+$worker.CommandLine)
        Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(@(Get-Workers).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 200}
    if(@(Get-Workers).Count -gt 0){throw 'A Roo Industries Governor process is still running from the app folder.'}
}

function Test-Alive($Identity){
    if(-not $Identity){return $false}
    $process=Get-Process -Id ([int]$Identity.processId) -ErrorAction SilentlyContinue
    if(-not $process){return $false}
    try {return $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq [string]$Identity.creationTimeFileTimeUtc} catch {return $true}
}

function Stop-Governor($Task){
    if($Task.userSid -ne $me){
        $statePath=Join-Path $Task.policyRoot 'host.json'
        $state=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
        if(-not $state -or -not (Test-Alive $state.host)){Write-Log ('Governor of Windows user '+$Task.userSid+' was not running');return [pscustomobject]@{wasRunning=$false;state=$state}}
        $request=[ordered]@{owner=[ordered]@{machine=[string]$state.owner.machine;userSid=[string]$state.owner.userSid};host=$state.host}
        $target=Join-Path $Task.policyRoot 'stop.request'
        $temporary=$target+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllText($temporary,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $target -Force
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while((Test-Alive $state.host) -and $clock.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 200}
        if(Test-Alive $state.host){Write-Log ('Governor of Windows user '+$Task.userSid+' did not stop in time; ending it');Stop-Process -Id ([int]$state.host.processId) -Force -ErrorAction SilentlyContinue}
        else {Write-Log ('Governor of Windows user '+$Task.userSid+' stopped and restored settings for '+$Task.policyRoot)}
        return [pscustomobject]@{wasRunning=$true;state=$state}
    }
    if(-not (Test-Path -LiteralPath $hostExe)){Write-Log ('No installed helper; ending task '+$Task.taskName);Stop-ScheduledTask -TaskName $Task.taskName -TaskPath $Task.taskPath -ErrorAction SilentlyContinue;return $null}
    $status=Invoke-Host 'policy-status' $Task.policyRoot
    $wasRunning=($status.hostRunning -eq $true)
    if($wasRunning){
        Invoke-Host 'policy-stop' $Task.policyRoot|Out-Null
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {Start-Sleep -Milliseconds 200;$status=Invoke-Host 'policy-status' $Task.policyRoot}while($status.hostRunning -eq $true -and $clock.Elapsed.TotalSeconds -lt 30)
        if($status.hostRunning -eq $true){Write-Log ('Governor did not stop in time; ending task '+$Task.taskName);Stop-ScheduledTask -TaskName $Task.taskName -TaskPath $Task.taskPath -ErrorAction SilentlyContinue}
        else {Write-Log ('Governor stopped and restored settings for '+$Task.policyRoot+' (state '+$status.state.status+')')}
    } else {Write-Log ('Governor was not running for '+$Task.policyRoot)}
    return [pscustomobject]@{wasRunning=$wasRunning;state=$status.state}
}

function Register-Watchdog($Tasks){
    $actions=@($Tasks|Where-Object {$_.enabled}|ForEach-Object {New-ScheduledTaskAction -Execute $schtasks -Argument ('/Change /TN "'+$_.taskPath+$_.taskName+'" /ENABLE')})
    $actions+=New-ScheduledTaskAction -Execute $schtasks -Argument ('/Delete /TN "\'+$watchdog+'" /F')
    $triggers=@((New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(5))),(New-ScheduledTaskTrigger -AtStartup))
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $watchdog -Description 'Roo Industries Governor setup recovery' -Action $actions -Trigger $triggers -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) -Force|Out-Null
    Write-Log ('Registered setup recovery for '+@($Tasks|Where-Object {$_.enabled}).Count+' governor tasks')
}

function Remove-Watchdog {
    if(Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $watchdog -Confirm:$false;Write-Log 'Removed setup recovery'}
}

function Register-OtherGovernor($Record){
    $request=Join-Path $Record.policyRoot 'worker-request.json'
    if(Test-Path -LiteralPath $hostExe){
        try {Invoke-Host 'policy-secure' $Record.policyRoot @{userSid=$Record.userSid}|Out-Null}
        catch {Write-Log ('Could not protect the rules of Windows user '+$Record.userSid+': '+$_.Exception.Message)}
    }
    $settingsPath=Join-Path $Record.policyRoot 'governor.json'
    $paused=(Test-Path -LiteralPath $settingsPath) -and [bool](Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json).paused
    $execute=New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$hostExe+'" policy-run "'+$request+'"') -WorkingDirectory (Split-Path $hostExe -Parent)
    $principal=New-ScheduledTaskPrincipal -UserId $Record.userSid -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 6
    $settings.Enabled=([bool]$Record.enabled -and -not $paused)
    $clock=New-ScheduledTaskTrigger -Once -At ([DateTime]::Now) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $logon=New-ScheduledTaskTrigger -AtLogOn -User $Record.userSid
    $logon.Repetition=$clock.Repetition
    Register-ScheduledTask -TaskName $Record.taskName -TaskPath $Record.taskPath -Description $Record.description -Action $execute -Principal $principal -Settings $settings -Trigger @($logon,$clock) -Force|Out-Null
    Write-Log ('Registered the governor of Windows user '+$Record.userSid+' again: enabled='+$settings.Enabled+' paused='+$paused)
}

switch($Action){
    'Suspend' {
        $records=New-Object System.Collections.Generic.List[object]
        Save-Records $records
        $tasks=@(Get-GovernorTasks)
        foreach($task in @($tasks|Where-Object {-not $_.trusted})){Write-Log ('Ignoring a task that is not a governor registered by an administrator: '+$task.taskName)}
        $tasks=@($tasks|Where-Object {$_.trusted})
        if($tasks.Count -gt 0){Register-Watchdog $tasks}
        foreach($task in $tasks){
            $record=[pscustomobject][ordered]@{taskName=$task.taskName;taskPath=$task.taskPath;description=$task.description;userSid=$task.userSid;policyRoot=$task.policyRoot;enabled=$task.enabled;wasRunning=$false}
            $records.Add($record)
            Save-Records $records
            Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath|Out-Null
            try {
                $legacy=$false
                if($task.userSid -eq $me -and (Test-Path -LiteralPath $hostExe)){try {Invoke-Host 'policy-summary' $task.policyRoot|Out-Null} catch {$legacy=$true}}
                $stopped=Stop-Governor $task
                if($stopped){$record.wasRunning=$stopped.wasRunning;Save-Records $records}
                if($stopped -and $legacy){
                    $settings=Join-Path $task.policyRoot 'governor.json'
                    if(-not (Test-Path -LiteralPath $settings) -and (Test-Path -LiteralPath (Join-Path $task.policyRoot 'rules')) -and -not $stopped.wasRunning -and $stopped.state -and [string]$stopped.state.status -in @('stopped','stoppedWithConflicts')){
                        [IO.File]::WriteAllText($settings,'{"schemaVersion":1,"paused":true}',[Text.UTF8Encoding]::new($false))
                        Write-Log ('Kept the stopped rules of the earlier version paused: '+$task.policyRoot)
                    }
                }
            } catch {
                Write-Log ('Could not stop the governor cleanly: '+$_.Exception.Message+'; ending task '+$task.taskName)
                Stop-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath -ErrorAction SilentlyContinue
            }
        }
        Stop-Leftovers
        Write-Log ('Suspended '+$records.Count+' governor tasks')
    }
    'Resume' {
        $records=New-Object System.Collections.Generic.List[object]
        if($StatePath -and (Test-Path -LiteralPath $StatePath)){foreach($item in @((Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8|ConvertFrom-Json))){if($null -ne $item){$records.Add($item)}}}
        $local=[Environment]::GetFolderPath('LocalApplicationData')
        $dataRoot=@(Get-ChildItem -LiteralPath $local -Directory -Filter '*OptimizationSuite' -ErrorAction SilentlyContinue|Where-Object {$_.Name -ne 'RooIndustriesOptimizationSuite'}|ForEach-Object {$_.FullName})+@(Join-Path $local 'RooIndustriesOptimizationSuite')|Select-Object -First 1
        foreach($root in @(Join-Path $dataRoot 'process-rules')){
            if((Test-Path -LiteralPath (Join-Path $root 'rules')) -and -not @($records|Where-Object {$_.userSid -eq $me -and [string]$_.policyRoot -ieq $root}).Count){
                Write-Log ('Found saved rules without a governor task: '+$root)
                $records.Add([pscustomobject]@{taskName='';taskPath='\';description='';userSid=$me;policyRoot=$root;enabled=$true;wasRunning=$false})
            }
        }
        $failures=0
        foreach($record in $records){
            if($null -eq $record){continue}
            try {
                if($record.userSid -eq $me){
                    $supportsSync=(Test-Path -LiteralPath $workerScript) -and ([IO.File]::ReadAllText($workerScript) -match "'Sync'")
                    if($supportsSync){
                        $text=@(& $workerScript -Action Sync -PolicyRoot $record.policyRoot -HostDirectory (Split-Path $hostExe -Parent) -ConfirmApply) -join "`n"
                        $result=$text|ConvertFrom-Json
                        if($result.status -ne 'completed'){throw ($result.errors|ForEach-Object {$_.message}) -join '; '}
                        Write-Log ('Governor synced for '+$record.policyRoot+': registered='+$result.data.registered+' enabled='+$result.data.enabled+' running='+$result.data.worker.hostRunning+' paused='+$result.data.paused)
                    } elseif($record.wasRunning){
                        & $workerScript -Action Start -PolicyRoot $record.policyRoot -ConfirmApply|Out-Null
                        Write-Log ('Earlier governor restarted for '+$record.policyRoot)
                    } elseif($record.enabled -and $record.taskName -and (Get-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath -ErrorAction SilentlyContinue)) {
                        Enable-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath|Out-Null
                    }
                } elseif($record.taskName -and (Test-Path -LiteralPath $hostExe) -and ([IO.File]::ReadAllText($workerScript) -match "'Sync'")){
                    Register-OtherGovernor $record
                } elseif($record.enabled -and $record.taskName -and (Get-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath -ErrorAction SilentlyContinue)){
                    Enable-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath|Out-Null
                    Write-Log ('Re-enabled the governor task of another Windows user '+$record.userSid)
                }
            } catch {
                $failures++
                Write-Log ('Could not resume the governor for '+$record.policyRoot+': '+$_.Exception.Message)
                if($record.enabled -and $record.taskName -and (Get-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath -ErrorAction SilentlyContinue)){Enable-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath|Out-Null}
            }
        }
        Remove-Watchdog
        Write-Log ('Resumed '+$records.Count+' governor tasks with '+$failures+' failures')
        if($failures -gt 0){exit 2}
    }
    'Remove' {
        Remove-Watchdog
        foreach($task in @(Get-GovernorTasks)){
            Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath|Out-Null
            if($task.trusted -and $task.userSid -eq $me -and (Test-Path -LiteralPath $workerScript)){
                try {
                    $text=@(& $workerScript -Action Remove -PolicyRoot $task.policyRoot -HostDirectory (Split-Path $hostExe -Parent) -ConfirmApply) -join "`n"
                    $result=$text|ConvertFrom-Json
                    if($result.status -ne 'completed'){throw ($result.errors|ForEach-Object {$_.message}) -join '; '}
                    Write-Log ('Governor stopped, settings restored and task removed for '+$task.policyRoot)
                } catch {Write-Log ('Could not stop the governor cleanly for '+$task.policyRoot+': '+$_.Exception.Message)}
            } elseif($task.trusted) {
                try {Stop-Governor $task|Out-Null} catch {Write-Log ('Could not stop the governor of Windows user '+$task.userSid+': '+$_.Exception.Message)}
            }
            if(Get-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath -Confirm:$false}
        }
        Stop-Leftovers
        $left=@(Get-GovernorTasks).Count
        Write-Log ('Governor tasks left: '+$left+'; governor processes left: '+@(Get-Workers).Count)
        if($left -gt 0){exit 3}
    }
}
exit 0
