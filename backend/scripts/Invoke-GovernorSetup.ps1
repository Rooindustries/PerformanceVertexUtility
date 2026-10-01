param(
    [Parameter(Mandatory=$true)][ValidateSet('Suspend','Resume','Remove')][string]$Action,
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [string]$StatePath='',
    [string]$LogPath='',
    [int]$SetupProcessId=0
)
$env:PSModulePath=$PSHOME+'\Modules'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$system=Split-Path (Split-Path $PSHOME -Parent) -Parent
$watchdog='RooIndustriesOptimizationSuite.GovernorSetupWatchdog'
$schtasks=Join-Path $system 'schtasks.exe'
$powershell=Join-Path $PSHOME 'powershell.exe'

function Write-Log([string]$Text){
    $line=[DateTime]::UtcNow.ToString('o')+' '+$Action+' '+$Text
    if($LogPath){Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8}
    Write-Host $line
}

function Invoke-Schtasks {
    $ErrorActionPreference='Continue'
    $output=@(& $schtasks @args 2>$null)
    $script:SchtasksExit=$LASTEXITCODE
    return $output
}

function ConvertTo-XmlText([string]$Text){return $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')}

function Get-ListedGovernors {
    $names=@(Invoke-Schtasks /Query /FO CSV /NH|ForEach-Object {([string]$_ -split '","')[0].Trim('"')}|Where-Object {$_ -match '^\\(RooIndustries|Roo)OptimizationSuite\.ProcessRules\.[^\\]+$'}|Select-Object -Unique)
    foreach($name in $names){
        $xml=@(Invoke-Schtasks /Query /TN $name /XML) -join "`n"
        $settings=if($xml -match '(?s)<Settings>.*?</Settings>'){$Matches[0]}else{''}
        @{taskName=$name.Substring(1);taskPath='\';enabled=($settings -notmatch '<Enabled>false</Enabled>');highest=($xml -match '<RunLevel>HighestAvailable</RunLevel>')}
    }
}

function Register-Watchdog($Tasks){
    if(-not $StatePath){Write-Log 'No setup folder was given, so no setup recovery task was registered';return}
    $setupId=$SetupProcessId
    if($setupId -le 0 -and $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'){try {$setupId=[int](Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)).ParentProcessId} catch {$setupId=0}}
    $setup=$null
    if($setupId -gt 0){$setup=Get-Process -Id $setupId -ErrorAction SilentlyContinue}
    $actions=''
    $triggers='<BootTrigger><Enabled>true</Enabled></BootTrigger>'
    if($setup){
        $created=$setup.StartTime.ToUniversalTime().ToFileTimeUtc()
        $wait='$p=Get-Process -Id '+$setupId+' -ErrorAction SilentlyContinue;if($p -and $p.StartTime.ToUniversalTime().ToFileTimeUtc() -eq '+$created+'){Wait-Process -InputObject $p -ErrorAction SilentlyContinue}'
        $actions+='<Exec><Command>'+(ConvertTo-XmlText $powershell)+'</Command><Arguments>'+(ConvertTo-XmlText ('-NoProfile -NonInteractive -Command "'+$wait+'"'))+'</Arguments></Exec>'
        $triggers+='<TimeTrigger><StartBoundary>'+[DateTime]::Now.AddMinutes(2).ToString('s')+'</StartBoundary><Enabled>true</Enabled></TimeTrigger>'
    } else {Write-Log 'The setup process could not be identified, so setup recovery waits for the next restart'}
    foreach($task in @($Tasks|Where-Object {$_.enabled})){$actions+='<Exec><Command>'+(ConvertTo-XmlText $schtasks)+'</Command><Arguments>'+(ConvertTo-XmlText ('/Change /TN "'+$task.taskPath+$task.taskName+'" /ENABLE'))+'</Arguments></Exec>'}
    $actions+='<Exec><Command>'+(ConvertTo-XmlText $schtasks)+'</Command><Arguments>'+(ConvertTo-XmlText ('/Delete /TN "\'+$watchdog+'" /F'))+'</Arguments></Exec>'
    $definition='<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>Roo Industries Governor setup recovery</Description></RegistrationInfo><Triggers>'+$triggers+'</Triggers><Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT3H</ExecutionTimeLimit><Enabled>true</Enabled></Settings><Actions Context="Author">'+$actions+'</Actions></Task>'
    $file=Join-Path (Split-Path $StatePath -Parent) 'governor-recovery.xml'
    Set-Content -LiteralPath $file -Value $definition -Encoding Unicode
    Invoke-Schtasks /Create /TN ('\'+$watchdog) /XML $file /F|Out-Null
    $code=$script:SchtasksExit
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if($code -ne 0){Write-Log ('Task Scheduler could not register setup recovery (exit '+$code+')');return}
    Write-Log ('Registered setup recovery for '+@($Tasks|Where-Object {$_.enabled}).Count+' governor tasks')
}

function Remove-Watchdog {
    Invoke-Schtasks /Query /TN ('\'+$watchdog)|Out-Null
    if($script:SchtasksExit -ne 0){return}
    Invoke-Schtasks /Delete /TN ('\'+$watchdog) /F|Out-Null
    if($script:SchtasksExit -eq 0){Write-Log 'Removed setup recovery'}else{Write-Log ('Task Scheduler could not remove setup recovery (exit '+$script:SchtasksExit+')')}
}

$listed=@(Get-ListedGovernors)
$full=$ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'
$visible=$null
if($full){try {$visible=@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)} catch {$visible=$null}}
if(-not $full -or $null -eq $visible -or $listed.Count -gt $visible.Count){
    Write-Log ('PowerShell runs in '+$ExecutionContext.SessionState.LanguageMode+$(if($full){' but Windows could not list the governor tasks'}else{''})+', so setup uses Task Scheduler only')
    $tasks=@($listed|Where-Object {$_['highest']})
    if($Action -eq 'Suspend'){
        if($StatePath){ConvertTo-Json -InputObject @($tasks) -Depth 3|Set-Content -LiteralPath $StatePath -Encoding UTF8}
        if($tasks.Count -gt 0){Register-Watchdog $tasks}
        foreach($task in $tasks){
            Invoke-Schtasks /Change /TN ($task.taskPath+$task.taskName) /DISABLE|Out-Null
            Invoke-Schtasks /End /TN ($task.taskPath+$task.taskName)|Out-Null
            Write-Log ('Disabled and ended governor task '+$task.taskName+'; its apps keep the rule settings until they close or the governor starts again')
        }
        Write-Log ('Suspended '+$tasks.Count+' governor tasks')
    } elseif($Action -eq 'Resume'){
        $saved=@()
        if($StatePath -and (Test-Path -LiteralPath $StatePath)){$saved=@((Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json))}
        $failures=0
        foreach($item in $saved){
            if($null -eq $item -or -not $item.enabled){continue}
            if(@($tasks|Where-Object {$_.taskName -eq $item.taskName -and $_.taskPath -eq $item.taskPath}).Count -ne 1){continue}
            Invoke-Schtasks /Change /TN ($item.taskPath+$item.taskName) /ENABLE|Out-Null
            if($script:SchtasksExit -eq 0){Write-Log ('Enabled governor task '+$item.taskName+' again')}else{$failures++;Write-Log ('Could not enable governor task '+$item.taskName)}
        }
        Write-Log ('Resumed '+$saved.Count+' governor tasks with '+$failures+' failures')
        if($failures -gt 0){Write-Log 'Setup recovery stays registered to turn the governor tasks back on';exit 2}
        Remove-Watchdog
    } else {
        Remove-Watchdog
        foreach($task in $tasks){
            Invoke-Schtasks /Change /TN ($task.taskPath+$task.taskName) /DISABLE|Out-Null
            Invoke-Schtasks /End /TN ($task.taskPath+$task.taskName)|Out-Null
            Invoke-Schtasks /Delete /TN ($task.taskPath+$task.taskName) /F|Out-Null
            Write-Log ('Removed governor task '+$task.taskName)
        }
        if(@(Get-ListedGovernors).Count -gt 0){exit 3}
    }
    exit 0
}

$OutputEncoding=[Text.UTF8Encoding]::new($false)
$AppRoot=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
$hostExe=Join-Path $AppRoot 'backend\bin\optimizer\Optimizer.Host.exe'
$workerScript=Join-Path $AppRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Get-Sid([string]$Account){
    if($Account -match '^S-1-'){return $Account}
    try {return [Security.Principal.NTAccount]::new($Account).Translate([Security.Principal.SecurityIdentifier]).Value} catch {return ''}
}

function Get-GovernorTasks {
    foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)){
        $parts=@([string]$task.Description -split ' \| ',3)
        if($parts.Count -ne 3 -or $parts[1] -notmatch '^S-1-'){Write-Log ('Skipping task with an unexpected description: '+$task.TaskName);continue}
        $profile=[string](Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$parts[1]) -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        $local=if($profile){[IO.Path]::GetFullPath((Join-Path $profile 'AppData\Local')).TrimEnd('\')+'\'}elseif($parts[1] -eq $me){[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'}else{$null}
        $root=try{[IO.Path]::GetFullPath($parts[2])}catch{''}
        $trusted=[string]$task.Principal.RunLevel -eq 'Highest' -and (Get-Sid ([string]$task.Principal.UserId)) -eq $parts[1] -and $local -and $root.StartsWith($local,[StringComparison]::OrdinalIgnoreCase)
        $settingsPath=Join-Path $root 'governor.json'
        $paused=$false;try {$paused=(Test-Path -LiteralPath $settingsPath) -and [bool](Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json).paused} catch {$paused=$true}
        $enabled=([string]$task.State -ne 'Disabled') -or (-not $paused -and (Test-Path -LiteralPath (Join-Path $root 'rules')))
        [pscustomobject]@{taskName=$task.TaskName;taskPath=$task.TaskPath;description=[string]$task.Description;userSid=$parts[1];policyRoot=$root;enabled=$enabled;trusted=[bool]$trusted}
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
    if($LASTEXITCODE -ne 0 -and [string]$result.error.message -match "Could not find file '.*\\-'"){
        $directory=New-AdminOnlyDirectory (Join-Path $AppRoot ('setup-request-'+[Guid]::NewGuid().ToString('N')))
        try {
            $path=Join-Path $directory 'request.json'
            [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))
            $result=(@(& $hostExe $HostAction $path) -join "`n")|ConvertFrom-Json
        } finally {Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue}
    }
    if($LASTEXITCODE -ne 0 -or $result.status -ne 'completed'){throw ($HostAction+' failed: '+$result.error.message)}
    return $result.data
}

function New-AdminOnlyDirectory([string]$Path){
    $security=New-Object Security.AccessControl.DirectorySecurity
    $administrators=New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){$security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
    if(Test-Path -LiteralPath $Path){throw ('The setup request folder already exists: '+$Path)}
    $created=[IO.Directory]::CreateDirectory($Path,$security)
    $acl=$created.GetAccessControl()
    $others=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')})
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or $others.Count -gt 0){throw ('The setup request folder is not admin-only: '+$Path)}
    return $Path
}

function Get-Workers {
    $prefix=(Join-Path $AppRoot 'backend\bin\optimizer')+'\'
    $script:WorkersKnown=$true
    try {$all=@(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction Stop)}
    catch {$script:WorkersKnown=$false;Write-Log ('Windows could not list processes ('+$_.Exception.Message+')');return @()}
    return @($all|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [string]$_.CommandLine -match 'policy-run'})
}

function Stop-Leftovers($Tasks){
    $workers=@(Get-Workers)
    if(-not $script:WorkersKnown){
        foreach($task in @($Tasks)){Invoke-Schtasks /End /TN ($task.taskPath+$task.taskName)|Out-Null;Write-Log ('Ended governor task '+$task.taskName+' through Task Scheduler')}
        $running=@(Get-Process -Name 'Optimizer.Host' -ErrorAction SilentlyContinue|Where-Object {$_.Path -and $_.Path.StartsWith((Join-Path $AppRoot 'backend\bin\optimizer')+'\',[StringComparison]::OrdinalIgnoreCase)})
        Write-Log ($running.Count.ToString()+' helper processes from the app folder are still running; setup closes them before replacing files')
        return
    }
    foreach($worker in $workers){
        Write-Log ('Ending leftover governor process '+$worker.ProcessId+': '+$worker.CommandLine)
        Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(@(Get-Workers).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 200}
    if(@(Get-Workers).Count -gt 0 -and $script:WorkersKnown){throw 'A Roo Industries Governor process is still running from the app folder.'}
}

function Test-Alive($Identity,[string]$OwnerSid){
    if(-not $Identity){return $false}
    $process=Get-Process -Id ([int]$Identity.processId) -ErrorAction SilentlyContinue
    if(-not $process){return $false}
    try {if($process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne [string]$Identity.creationTimeFileTimeUtc){return $false}} catch {return $false}
    try {$details=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$Identity.processId) -ErrorAction Stop} catch {return $true}
    if(-not $details -or [string]$details.CommandLine -notmatch 'policy-run'){return $false}
    try {return -not $OwnerSid -or (Invoke-CimMethod -InputObject $details -MethodName GetOwnerSid -ErrorAction Stop).Sid -eq $OwnerSid} catch {return $true}
}

function Stop-Governor($Task){
    if($Task.userSid -ne $me){
        $statePath=Join-Path $Task.policyRoot 'host.json'
        $secured=$false;try {$secured=[bool](Invoke-Host 'policy-summary' $Task.policyRoot).secured} catch {}
        if(-not $secured){Write-Log ('The rules folder of Windows user '+$Task.userSid+' is not protected, so its state is not trusted; ending its task');Stop-ScheduledTask -TaskName $Task.taskName -TaskPath $Task.taskPath -ErrorAction SilentlyContinue;return [pscustomobject]@{wasRunning=$false;state=$null}}
        $state=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
        if(-not $state -or -not (Test-Alive $state.host $Task.userSid)){Write-Log ('Governor of Windows user '+$Task.userSid+' was not running');return [pscustomobject]@{wasRunning=$false;state=$state}}
        $request=[ordered]@{owner=[ordered]@{machine=[string]$state.owner.machine;userSid=[string]$state.owner.userSid};host=$state.host}
        $target=Join-Path $Task.policyRoot 'stop.request'
        $temporary=$target+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllText($temporary,($request|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $target -Force
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while((Test-Alive $state.host $Task.userSid) -and $clock.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 200}
        if(Test-Alive $state.host $Task.userSid){Write-Log ('Governor of Windows user '+$Task.userSid+' did not stop in time; ending it. Its apps keep the rule settings until they close or the governor starts again');Stop-Process -Id ([int]$state.host.processId) -Force -ErrorAction SilentlyContinue}
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

function Register-OtherGovernor($Record){
    $request=Join-Path $Record.policyRoot 'worker-request.json'
    Invoke-Host 'policy-secure' $Record.policyRoot @{userSid=$Record.userSid}|Out-Null
    $temporary=$request+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,(@{schemaVersion=1;repoRoot=$AppRoot;policyRoot=$Record.policyRoot;confirm=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $request -Force
    $settingsPath=Join-Path $Record.policyRoot 'governor.json'
    $paused=(Test-Path -LiteralPath $settingsPath) -and [bool](Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json).paused
    . (Join-Path $AppRoot 'backend\scripts\BrandCompatibility.Common.ps1')
    $execute=New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',$request) (Split-Path $hostExe -Parent)
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
        Stop-Leftovers $tasks
        Write-Log ('Suspended '+$records.Count+' governor tasks')
    }
    'Resume' {
        $live=@(Get-GovernorTasks|Where-Object {$_.trusted})
        $records=New-Object System.Collections.Generic.List[object]
        if($StatePath -and (Test-Path -LiteralPath $StatePath)){
            foreach($item in @((Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8|ConvertFrom-Json))){
                if($null -eq $item){continue}
                $match=@($live|Where-Object {$_.taskName -eq $item.taskName -and $_.taskPath -eq $item.taskPath -and $_.userSid -eq $item.userSid -and $_.policyRoot -ieq [string]$item.policyRoot})
                if($match.Count -ne 1){Write-Log ('Ignoring a setup record that does not match a trusted governor task: '+$item.taskName);continue}
                $item|Add-Member -NotePropertyName description -NotePropertyValue $match[0].description -Force
                $records.Add($item)
            }
        }
        $local=[Environment]::GetFolderPath('LocalApplicationData')
        $markers=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
        $current=Join-Path $local 'RooIndustriesOptimizationSuite'
        $legacy=Join-Path $local 'RooOptimizationSuite'
        $currentMarked=$null -ne $markers -and $null -ne $markers.GetValue($current.ToUpperInvariant())
        $legacyMarked=$null -ne $markers -and $null -ne $markers.GetValue($legacy.ToUpperInvariant())
        $dataRoot=if((Test-Path -LiteralPath $legacy -PathType Container) -and -not ($currentMarked -and -not $legacyMarked)){$legacy}else{$current}
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
        Write-Log ('Resumed '+$records.Count+' governor tasks with '+$failures+' failures')
        if($failures -gt 0){Write-Log 'Setup recovery stays registered to turn the governor tasks back on';exit 2}
        Remove-Watchdog
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
        Stop-Leftovers @()
        $left=@(Get-GovernorTasks).Count
        $workersLeft=@(Get-Workers).Count
        Write-Log ('Governor tasks left: '+$left+'; governor processes left: '+$(if($script:WorkersKnown){$workersLeft}else{'unknown'}))
        if($left -gt 0){exit 3}
    }
}
exit 0
