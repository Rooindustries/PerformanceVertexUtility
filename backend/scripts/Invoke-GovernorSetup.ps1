param(
    [Parameter(Mandatory=$true)][ValidateSet('Suspend','Resume','Remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [string]$StatePath='',
    [string]$LogPath=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$AppRoot=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
$hostExe=Join-Path $AppRoot 'backend\bin\optimizer\Optimizer.Host.exe'
$workerScript=Join-Path $AppRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value

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
        [pscustomobject]@{taskName=$task.TaskName;taskPath=$task.TaskPath;userSid=$parts[1];policyRoot=$root;enabled=([string]$task.State -ne 'Disabled');trusted=[bool]$trusted}
    }
}

function Save-Records($Records){
    if($StatePath){[IO.File]::WriteAllText($StatePath,(ConvertTo-Json -InputObject @($Records.ToArray()) -Depth 5),[Text.UTF8Encoding]::new($false))}
}

function Invoke-Host([string]$HostAction,[string]$PolicyRoot,[hashtable]$Extra=@{}){
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-setup-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    try {
        $request=@{schemaVersion=1;repoRoot=$AppRoot;policyRoot=$PolicyRoot;confirm=$true}
        foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
        $path=Join-Path $directory 'request.json'
        [IO.File]::WriteAllText($path,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $text=@(& $hostExe $HostAction $path) -join "`n"
        $result=$text|ConvertFrom-Json
        if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw ($HostAction+' failed: '+$result.error.message)}
        return $result.data
    } finally {Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue}
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

function Stop-Governor($Task){
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

switch($Action){
    'Suspend' {
        $records=New-Object System.Collections.Generic.List[object]
        Save-Records $records
        foreach($task in @(Get-GovernorTasks)){
            if(-not $task.trusted){Write-Log ('Ignoring a task that is not a governor registered by an administrator: '+$task.taskName);continue}
            $record=[pscustomobject][ordered]@{taskName=$task.taskName;taskPath=$task.taskPath;userSid=$task.userSid;policyRoot=$task.policyRoot;enabled=$task.enabled;wasRunning=$false}
            $records.Add($record)
            Save-Records $records
            Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath|Out-Null
            if($task.userSid -eq $me){
                try {
                    $legacy=$false
                    if(Test-Path -LiteralPath $hostExe){try {Invoke-Host 'policy-summary' $task.policyRoot|Out-Null} catch {$legacy=$true}}
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
            } else {
                Write-Log ('Ending the governor of another Windows user '+$task.userSid)
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
                $records.Add([pscustomobject]@{taskName='';taskPath='\';userSid=$me;policyRoot=$root;enabled=$true;wasRunning=$false})
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
        Write-Log ('Resumed '+$records.Count+' governor tasks with '+$failures+' failures')
        if($failures -gt 0){exit 2}
    }
    'Remove' {
        foreach($task in @(Get-GovernorTasks)){
            Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath|Out-Null
            if($task.trusted -and $task.userSid -eq $me -and (Test-Path -LiteralPath $workerScript)){
                try {
                    $text=@(& $workerScript -Action Remove -PolicyRoot $task.policyRoot -HostDirectory (Split-Path $hostExe -Parent) -ConfirmApply) -join "`n"
                    $result=$text|ConvertFrom-Json
                    if($result.status -ne 'completed'){throw ($result.errors|ForEach-Object {$_.message}) -join '; '}
                    Write-Log ('Governor stopped, settings restored and task removed for '+$task.policyRoot)
                } catch {Write-Log ('Could not stop the governor cleanly for '+$task.policyRoot+': '+$_.Exception.Message)}
            } else {
                Write-Log ('Ending the governor of another Windows user '+$task.userSid+'; its apps keep their settings until they close')
                Stop-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath -ErrorAction SilentlyContinue
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
