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
$full=$ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'
$script:SchedulerOnly=$false
$script:SetupCommonLoaded=$false
$localAppData=''
$nativeSystem=Join-Path (Split-Path $system -Parent) 'System32'
$env:SystemRoot=Split-Path $nativeSystem -Parent
$env:windir=$env:SystemRoot

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

function ConvertFrom-XmlText([string]$Text){return $Text.Replace('&lt;','<').Replace('&gt;','>').Replace('&quot;','"').Replace('&apos;',"'").Replace('&amp;','&')}

function Get-CurrentUser {
    if($script:CurrentUser){return $script:CurrentUser}
    $sid='';$name=''
    if($full){
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $sid=$identity.User.Value;$name=$identity.Name
    } else {
        $ErrorActionPreference='Continue'
        $output=@(& (Join-Path $system 'whoami.exe') /user /fo csv /nh 2>$null)
        $line=if($output.Count -gt 0){[string]$output[0]}else{''}
        $parts=@($line -split '","')
        if($parts.Count -eq 2){$name=$parts[0].Trim('"');$sid=$parts[1].Trim('"')}
    }
    $script:CurrentUser=@{sid=$sid;name=$name}
    return $script:CurrentUser
}

function Get-Sid([string]$Account){
    if($Account -match '^S-1-'){return $Account}
    if($full){try {return [Security.Principal.NTAccount]::new($Account).Translate([Security.Principal.SecurityIdentifier]).Value} catch {return ''}}
    $user=Get-CurrentUser
    if($Account -and $user.sid -and ($Account -ieq $user.name -or $Account -ieq @($user.name -split '\\')[-1])){return $user.sid}
    return ''
}

function Resolve-PathText([string]$Path){
    $text=$Path.Replace('/','\')
    if($text -notmatch '^[A-Za-z]:\\' -or $text -match '[<>"|?*\x00-\x1F]' -or $text.Substring(2) -match ':'){return ''}
    if($full){try {return [IO.Path]::GetFullPath($text)} catch {return ''}}
    if($text -match '(^|\\)\.{1,2}(\\|$)'){return ''}
    return $text -replace '\\{2,}','\'
}

function Test-StartsWith([string]$Text,[string]$Prefix){return $Text.Length -ge $Prefix.Length -and $Text.Substring(0,$Prefix.Length) -ieq $Prefix}

function Get-ListedGovernorNames {
    return @(Invoke-Schtasks /Query /FO CSV /NH|ForEach-Object {([string]$_ -split '","')[0].Trim('"')}|Where-Object {$_ -match '^(\\[^\\]+)*\\[^\\]*OptimizationSuite\.ProcessRules\.[^\\]*$'}|Select-Object -Unique)
}

function Get-GovernorSources {
    if(-not $script:SchedulerOnly){
        foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)){
            $actions=@($task.Actions)
            @{taskName=[string]$task.TaskName;taskPath=[string]$task.TaskPath;description=[string]$task.Description;userId=[string]$task.Principal.UserId;runLevel=[string]$task.Principal.RunLevel;disabled=([string]$task.State -eq 'Disabled');actionCount=$actions.Count;execute=[string]$actions[0].Execute;arguments=[string]$actions[0].Arguments}
        }
        return
    }
    foreach($name in @(Get-ListedGovernorNames)){
        $xml=@(Invoke-Schtasks /Query /TN $name /XML) -join "`n"
        if($script:SchtasksExit -ne 0 -or -not $xml){Write-Log ('Task Scheduler could not describe '+$name+', so setup leaves it alone');continue}
        $definition=Join-Path (Join-Path $nativeSystem 'Tasks') $name.TrimStart('\')
        try {$stored=Get-Content -LiteralPath $definition -Raw -ErrorAction Stop;if($stored){$xml=$stored}} catch {}
        $info=if($xml -match '(?s)<RegistrationInfo>.*?</RegistrationInfo>'){$Matches[0]}else{''}
        $description=if($info -match '(?s)<Description>(.*?)</Description>'){ConvertFrom-XmlText $Matches[1]}else{''}
        $principal=if($xml -match '(?s)<Principals>.*?</Principals>'){$Matches[0]}else{''}
        $userId=if($principal -match '(?s)<UserId>(.*?)</UserId>'){ConvertFrom-XmlText $Matches[1]}else{''}
        $level=if($principal -match '<RunLevel>(.*?)</RunLevel>'){$Matches[1]}else{''}
        $settings=if($xml -match '(?s)<Settings>.*?</Settings>'){$Matches[0]}else{''}
        $actionBlock=if($xml -match '(?s)<Actions[^>]*>.*?</Actions>'){$Matches[0]}else{''}
        $execute=if($actionBlock -match '(?s)<Command>(.*?)</Command>'){ConvertFrom-XmlText $Matches[1]}else{''}
        $arguments=if($actionBlock -match '(?s)<Arguments>(.*?)</Arguments>'){ConvertFrom-XmlText $Matches[1]}else{''}
        $split=$name.LastIndexOf('\')+1
        @{taskName=$name.Substring($split);taskPath=$name.Substring(0,$split);description=$description;userId=$userId;runLevel=$(if($level -eq 'HighestAvailable'){'Highest'}else{$level});disabled=[bool]($settings -match '<Enabled>false</Enabled>');actionCount=@($actionBlock -split '<(?:Exec|ComHandler|SendEmail|ShowMessage)[\s>/]').Count-1;execute=$execute;arguments=$arguments}
    }
}

function Get-GovernorArguments([string]$Text){
    if($Text -match '[\x00-\x1F]'){return @()}
    $parts=@()
    while($Text){
        $Text=$Text.TrimStart(' ')
        if(-not $Text){break}
        if($Text.StartsWith('"')){
            $end=$Text.IndexOf('"',1)
            if($end -lt 0){return @()}
            $parts+=($Text.Substring(1,$end-1))
            $Text=$Text.Substring($end+1)
            if($Text -and -not $Text.StartsWith(' ')){return @()}
        } else {
            $end=$Text.IndexOf(' ')
            if($end -lt 0){$end=$Text.Length}
            $part=$Text.Substring(0,$end)
            if($part.Contains('"')){return @()}
            $parts+=$part
            $Text=$Text.Substring($end)
        }
    }
    return $parts
}

function Test-GovernorDotNet([string]$Executable,[string]$HostDirectory){
    if((Split-Path $Executable -Leaf) -ine 'dotnet.exe' -or (Resolve-PathText $Executable) -ine $Executable){return $false}
    try {
        $file=Get-Item -LiteralPath $Executable -ErrorAction Stop
        if($file.PSIsContainer -or $file.VersionInfo.OriginalFilename -notin @('dotnet.exe','.NET Host','.NET Core Host')){return $false}
        $signature=Get-AuthenticodeSignature -LiteralPath $Executable -ErrorAction Stop
        if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'){return $false}
        $options=(Get-Content -LiteralPath (Join-Path $HostDirectory 'Optimizer.Host.runtimeconfig.json') -Raw -ErrorAction Stop|ConvertFrom-Json).runtimeOptions
        return @(@($options.framework)+@($options.frameworks)|Where-Object {$_.name -eq 'Microsoft.NETCore.App' -and $_.version -is [string] -and $_.version}).Count -gt 0
    } catch {return $false}
}

function Test-GovernorPayload($Parts,[string]$Root){
    $hostDirectory=$appRootPath+'\backend\bin\optimizer'
    $request=$Root+'\worker-request.json'
    if($Parts.Count -eq 3){return $Parts[0] -ieq ($hostDirectory+'\Optimizer.Host.exe') -and $Parts[1] -ceq 'policy-run' -and $Parts[2] -ieq $request}
    if($Parts.Count -eq 4 -and $Parts[1] -ieq ($hostDirectory+'\Optimizer.Host.dll') -and $Parts[2] -ceq 'policy-run' -and $Parts[3] -ieq $request){return Test-GovernorDotNet $Parts[0] $hostDirectory}
    return $false
}

function Test-GovernorAction($Task,[string]$Root){
    if($Task.actionCount -ne 1){return $false}
    $execute=[string]$Task.execute
    $arguments=[string]$Task.arguments
    $launcher=$appRootPath+'\backend\scripts\Start-RooIndustriesHelper.cmd'
    foreach($directory in $systemDirectories){
        if($execute -ine ($directory+'\conhost.exe')){continue}
        foreach($shell in @(('/d /e:on /v:off /c set "SystemRoot='+(Split-Path $directory -Parent)+'"&call '),'/d /v:off /c call ')){
            $clean='--headless "'+$directory+'\cmd.exe" '+$shell+'"'+$launcher+'" " ?'
            if((Test-StartsWith $arguments $clean) -and $arguments.EndsWith('"')){
                $parts=@($arguments.Substring($clean.Length,$arguments.Length-$clean.Length-1) -split '\?')
                $text=$launcher+($parts -join '')
                if($text -match '["?^*<>|\r\n]' -or @($text -split '%').Count -gt 2){return $false}
                return Test-GovernorPayload $parts $Root
            }
        }
        $clear=(@('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_ARM64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')|ForEach-Object {'set '+$_+'='}) -join '&'
        $inline='--headless "'+$directory+'\cmd.exe" /d /s /c "'+$clear+'&'
        if((Test-StartsWith $arguments $inline) -and $arguments.EndsWith('"')){
            $body=$arguments.Substring($inline.Length,$arguments.Length-$inline.Length-1)
            $parts=@(Get-GovernorArguments $body)
            if($parts.Count -notin @(3,4)){return $false}
            $expected='"'+$parts[0]+'" '+$(if($parts.Count -eq 4){'"'+$parts[1]+'" '})+'policy-run "'+$Root+'\worker-request.json"'
            if($body -ine $expected -or @($body -split '%').Count -gt 2){return $false}
            return Test-GovernorPayload $parts $Root
        }
        if(Test-StartsWith $arguments '--headless '){return Test-GovernorPayload @(Get-GovernorArguments $arguments.Substring(11)) $Root}
        return $false
    }
    return Test-GovernorPayload (@($execute)+@(Get-GovernorArguments $arguments)) $Root
}

function Get-GovernorProblem($Task,$Parts,[string]$Root,$Local){
    if($Task.taskPath -ne '\'){return 'it is not in the Task Scheduler root folder'}
    if($Task.taskName -notmatch ('^(RooIndustriesOptimizationSuite|'+('RooIndustriesOptimizationSuite' -replace 'Industries','')+')\.ProcessRules\.[0-9A-F]{20}$')){return 'its name is not one this product registers'}
    if($Parts.Count -ne 3){return 'its description does not have three parts'}
    if($Parts[0] -ne 'Roo Industries process rules' -and $Parts[0] -ne ('Roo Industries process rules' -replace ' Industries','')){return 'its description does not start with the product text'}
    if($Parts[1] -notmatch '^S-1-[0-9]+(-[0-9]+)+$'){return 'its description does not name a Windows user'}
    if(-not $Root){return 'its description does not name a valid rules folder'}
    if((-not $Local -or $Root.Length -lt $Local.Length -or $Root.Substring(0,$Local.Length) -ine $Local) -and -not (Test-GovernorRootMarker $Root $Parts[1])){return 'its rules folder is outside the profile of the user its description names'}
    if($Task.runLevel -ne 'Highest'){return 'it does not run with the highest privileges'}
    if((Get-Sid $Task.userId) -ne $Parts[1]){return 'it does not run as the user its description names'}
    if(-not (Test-GovernorAction $Task $Root)){return 'it does not start the governor of this installation'}
    return $null
}

function Get-RawRegistryValue([string]$Key,[string]$Name){
    $ErrorActionPreference='Continue'
    $output=@(& (Join-Path $nativeSystem 'reg.exe') query $Key /v $Name 2>$null)
    $code=$LASTEXITCODE
    if($code -ne 0){return @{present=$false;value='';kind=''}}
    foreach($line in $output){
        if([string]$line -match ('^\s*'+[regex]::Escape($Name)+'\s+(REG_[A-Z0-9_]+)\s*(.*)$')){return @{present=$true;kind=$Matches[1];value=$Matches[2]}}
    }
    throw "Roo Industries could not read that Windows user's folder settings."
}

function Get-UserLocalFolder([string]$Sid){
    if($full){
        $key=Get-Item -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$Sid) -ErrorAction SilentlyContinue
        $raw=if($key){$key.GetValue('ProfileImagePath',$null,'DoNotExpandEnvironmentNames')}else{$null}
        $profile=@{present=($null -ne $raw);value=$raw;kind=$(if($raw -is [string] -and $key.GetValueKind('ProfileImagePath') -in @('String','ExpandString')){'REG_SZ'}else{''})}
    }else{$profile=Get-RawRegistryValue ('HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$Sid) 'ProfileImagePath'}
    if(-not $profile.present -or $profile.kind -notin @('REG_SZ','REG_EXPAND_SZ')){return ''}
    $profilePath=$profile.value -replace '(?i)%SystemDrive%',(Split-Path $nativeSystem -Qualifier)
    if($full -and $Sid -eq $me){$profilePath=[Environment]::GetFolderPath('UserProfile')}
    if(-not (Resolve-PathText $profilePath) -or $profilePath -match '%.*%'){return ''}
    if($full -and $script:SetupCommonLoaded){try {return Get-RooIndustriesUserFolder -Sid $Sid -Profile $profilePath} catch {return ''}}
    $ErrorActionPreference='Continue'
    & (Join-Path $nativeSystem 'reg.exe') query ('HKU\'+$Sid) 2>$null|Out-Null
    if($LASTEXITCODE -ne 0){return ''}
    $raw=Get-RawRegistryValue ('HKU\'+$Sid+'\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') 'Local AppData'
    if($raw.present){
        if($raw.kind -notin @('REG_SZ','REG_EXPAND_SZ')){return ''}
        $local=$raw.value -replace '(?i)%USERPROFILE%',$profilePath.Replace('$','$$')
    }else{$local=Join-Path $profilePath 'AppData\Local'}
    if($local -match '%.*%' -or -not (Resolve-PathText $local) -or $local -match '^[A-Za-z]:\\$' -or -not (Test-Path -LiteralPath $local -PathType Container)){return ''}
    $local=(Get-Item -LiteralPath $local -Force -ErrorAction Stop).FullName.TrimEnd('\')
    for($ancestor=$local;$ancestor;$ancestor=Split-Path $ancestor -Parent){
        $item=Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if(-not $item -or $item.Attributes -band 1024){return ''}
    }
    foreach($blocked in @((Split-Path $nativeSystem -Parent),$AppRoot)){
        if($local -ieq $blocked -or (Test-StartsWith ($local+'\') ($blocked.TrimEnd('\')+'\'))){return ''}
    }
    $programFiles=Get-RawRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir'
    $programFilesX86=Get-RawRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir (x86)'
    foreach($blocked in @($programFiles.value,$programFilesX86.value)){
        if($blocked -and ($local -ieq $blocked -or (Test-StartsWith ($local+'\') ($blocked.TrimEnd('\')+'\')))){return ''}
    }
    return (Get-Item -LiteralPath $local -Force -ErrorAction Stop).FullName.TrimEnd('\')
}

function Test-GovernorRootMarker([string]$Root,[string]$Sid){
    if(-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)){return $false}
    if($full -and $script:SetupCommonLoaded){
        $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
        return $null -ne $key -and $key.GetValue((Get-RooIndustriesDataRootMarkerName $Root),$null,'DoNotExpandEnvironmentNames') -ceq $Sid
    }
    $marker=Get-RawRegistryValue 'HKLM\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' ((Get-Item -LiteralPath $Root -Force).FullName.ToUpperInvariant())
    return $marker.present -and $marker.kind -eq 'REG_SZ' -and $marker.value -ceq $Sid
}

function Get-GovernorTasks {
    foreach($task in @(Get-GovernorSources)){
        try {
            $parts=@([string]$task.description -split ' \| ',3)
            $sid=if($parts.Count -eq 3 -and $parts[1] -match '^S-1-[0-9]+(-[0-9]+)+$'){$parts[1]}else{''}
            $localPath=if($sid){Get-UserLocalFolder $sid}else{''}
            $local=if($localPath){$localPath.TrimEnd('\')+'\'}else{$null}
            $root=if($parts.Count -eq 3){Resolve-PathText $parts[2]}else{''}
            $problem=Get-GovernorProblem $task $parts $root $local
            $enabled=-not $task.disabled
            if($problem){Write-Log ('Ignoring a task that is not a governor registered by an administrator: '+$task.taskName+' ('+$problem+')')}
            else {
                $paused=$false;try {$paused=(Test-Path -LiteralPath (Join-Path $root 'governor.json')) -and [bool](Get-Content -LiteralPath (Join-Path $root 'governor.json') -Raw -Encoding UTF8|ConvertFrom-Json).paused} catch {$paused=$true}
                $hasRules=@(Get-ChildItem -LiteralPath (Join-Path $root 'rules') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0
                $enabled=$enabled -or (-not $paused -and $hasRules)
            }
            @{taskName=$task.taskName;taskPath=$task.taskPath;description=[string]$task.description;userSid=$sid;policyRoot=$root;enabled=$enabled;disabled=[bool]$task.disabled;trusted=(-not $problem)}
        } catch {Write-Log ('Ignoring a task that could not be read: '+$task.taskName+' ('+$_.Exception.Message+')')}
    }
}

function Register-Watchdog($Tasks){
    if(-not $StatePath){Write-Log 'No setup folder was given, so no setup recovery task was registered';return $false}
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
    if($code -ne 0){Write-Log ('Task Scheduler could not register setup recovery (exit '+$code+')');return $false}
    Write-Log ('Registered setup recovery for '+@($Tasks|Where-Object {$_.enabled}).Count+' governor tasks')
    return $true
}

function Test-WatchdogRegistered($Tasks){
    try {return @(Register-Watchdog $Tasks)[-1] -eq $true} catch {Write-Log ('Setup recovery could not be registered: '+$_.Exception.Message);return $false}
}

function Remove-Watchdog {
    Invoke-Schtasks /Query /TN ('\'+$watchdog)|Out-Null
    if($script:SchtasksExit -ne 0){return}
    Invoke-Schtasks /Delete /TN ('\'+$watchdog) /F|Out-Null
    if($script:SchtasksExit -eq 0){Write-Log 'Removed setup recovery'}else{Write-Log ('Task Scheduler could not remove setup recovery (exit '+$script:SchtasksExit+')')}
}

$appRootPath=(Resolve-PathText $AppRoot).TrimEnd('\')
if(-not $appRootPath){throw 'The app folder must be a full path on a local drive.'}
$systemDirectories=@($system,$nativeSystem|Select-Object -Unique)
$me=(Get-CurrentUser).sid
$script:RooIndustriesInstallRoot=$appRootPath
if($full){
    $common=Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1'
    if(Test-Path -LiteralPath $common -PathType Leaf){. $common;$script:SetupCommonLoaded=$true;$localAppData=Get-RooIndustriesLocalAppData}else{$script:SchedulerOnly=$true;$localAppData=Get-UserLocalFolder $me;if(-not $localAppData){throw "Roo Industries could not use this Windows user's AppData folder settings."}}
}else{
    $localAppData=Get-UserLocalFolder $me
    if(-not $localAppData){throw "Roo Industries could not use this Windows user's AppData folder settings."}
}
$listed=@(Get-ListedGovernorNames)
$visible=$null
if($full){try {$visible=@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)} catch {$visible=$null}}
if($script:SchedulerOnly -or -not $full -or $null -eq $visible -or $listed.Count -gt $visible.Count){
    Write-Log ('PowerShell runs in '+$ExecutionContext.SessionState.LanguageMode+$(if($full){' but Windows could not list the governor tasks'}else{''})+', so setup uses Task Scheduler only')
    $script:SchedulerOnly=$true
    $tasks=@(Get-GovernorTasks|Where-Object {$_.trusted})
    if($Action -eq 'Suspend'){
        $records=@($tasks|ForEach-Object {@{taskName=$_.taskName;taskPath=$_.taskPath;description=$_.description;userSid=$_.userSid;policyRoot=$_.policyRoot;enabled=$_.enabled;wasRunning=$false}})
        if($StatePath){ConvertTo-Json -InputObject @($records) -Depth 3|Set-Content -LiteralPath $StatePath -Encoding UTF8}
        if($tasks.Count -gt 0 -and -not (Test-WatchdogRegistered $tasks)){
            Write-Log 'Setup recovery could not be registered, so the governor tasks were left running and setup must not replace files'
            exit 4
        }
        foreach($task in $tasks){
            Invoke-Schtasks /Change /TN ($task.taskPath+$task.taskName) /DISABLE|Out-Null
            Invoke-Schtasks /End /TN ($task.taskPath+$task.taskName)|Out-Null
            Write-Log ('Disabled and ended governor task '+$task.taskName+'; its apps keep the rule settings until they close or the governor starts again')
        }
        Write-Log ('Suspended '+$tasks.Count+' governor tasks')
    } elseif($Action -eq 'Resume'){
        $saved=@()
        if($StatePath -and (Test-Path -LiteralPath $StatePath)){$saved=@((Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8|ConvertFrom-Json))}
        $failures=0;$resumed=0
        foreach($task in $tasks){
            $recorded=@($saved|Where-Object {$null -ne $_ -and $_.taskName -eq $task.taskName -and $_.taskPath -eq $task.taskPath -and $_.userSid -eq $task.userSid -and [string]$_.policyRoot -ieq $task.policyRoot})
            if(-not ($task.enabled -or ($recorded.Count -eq 1 -and $recorded[0].enabled))){Write-Log ('Left governor task '+$task.taskName+' disabled because its rules are paused or missing');continue}
            $resumed++
            if(-not $task.disabled){continue}
            Invoke-Schtasks /Change /TN ($task.taskPath+$task.taskName) /ENABLE|Out-Null
            if($script:SchtasksExit -eq 0){Write-Log ('Enabled governor task '+$task.taskName+' again')}else{$failures++;Write-Log ('Could not enable governor task '+$task.taskName)}
        }
        Write-Log ('Resumed '+$resumed+' governor tasks with '+$failures+' failures')
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
        if(@(Get-GovernorTasks|Where-Object {$_.trusted}).Count -gt 0){exit 3}
    }
    exit 0
}

$OutputEncoding=[Text.UTF8Encoding]::new($false)
$AppRoot=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
$hostExe=Join-Path $AppRoot 'backend\bin\optimizer\Optimizer.Host.exe'
$workerScript=Join-Path $AppRoot 'backend\scripts\Invoke-ProcessPolicyWorker.ps1'

function Save-Records($Records){
    if($StatePath){[IO.File]::WriteAllText($StatePath,(ConvertTo-Json -InputObject @($Records.ToArray()) -Depth 5),[Text.UTF8Encoding]::new($false))}
}

function Start-HostProcess([string]$HostAction,[string]$Json,[string]$Path){
    $ErrorActionPreference='Continue'
    $output=if($Path){@(& $hostExe $HostAction $Path 2>&1)}else{@($Json|& $hostExe $HostAction '-' 2>&1)}
    $code=$global:LASTEXITCODE
    $errors=@($output|Where-Object {$_ -is [Management.Automation.ErrorRecord]}|ForEach-Object {[string]$_})
    $text=(@($output|Where-Object {$_ -isnot [Management.Automation.ErrorRecord]}|ForEach-Object {[string]$_}) -join "`n").Trim()
    $result=$null
    if($text){try {$result=$text|ConvertFrom-Json} catch {}}
    return [pscustomobject]@{exitCode=$code;text=$text;stderr=($errors -join ' ').Trim();result=$result}
}

function Invoke-Host([string]$HostAction,[string]$PolicyRoot,[hashtable]$Extra=@{}){
    $request=@{schemaVersion=1;repoRoot=$AppRoot;policyRoot=$PolicyRoot;confirm=$true}
    foreach($key in $Extra.Keys){$request[$key]=$Extra[$key]}
    $json=$request|ConvertTo-Json -Depth 5 -Compress
    $run=Start-HostProcess $HostAction $json ''
    if($run.exitCode -ne 0 -and [string]$run.result.error.message -match "Could not find file '.*\\-'"){
        $directory=New-AdminOnlyDirectory (Join-Path $AppRoot ('setup-request-'+[Guid]::NewGuid().ToString('N')))
        try {
            $path=Join-Path $directory 'request.json'
            [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))
            $run=Start-HostProcess $HostAction '' $path
        } finally {Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue}
    }
    if($run.exitCode -ne 0 -or $run.stderr -or -not $run.text.StartsWith('{') -or $run.result -isnot [pscustomobject] -or $run.result.status -isnot [string] -or $run.result.status -cne 'completed' -or $run.result.data -isnot [pscustomobject]){
        $reason=if($run.result -and $run.result.error.message){[string]$run.result.error.message}elseif($run.stderr){$run.stderr}elseif($run.text){$run.text}else{'the helper printed nothing'}
        throw ($HostAction+' failed (exit '+$run.exitCode+'): '+$reason.Substring(0,[Math]::Min(400,$reason.Length)))
    }
    return $run.result.data
}

function Invoke-Worker([string]$WorkerAction,[string]$PolicyRoot){
    $ErrorActionPreference='Continue'
    $global:LASTEXITCODE=0
    $output=@(& $workerScript -Action $WorkerAction -PolicyRoot $PolicyRoot -HostDirectory (Split-Path $hostExe -Parent) -ConfirmApply 2>&1)
    $code=$global:LASTEXITCODE
    $errors=@($output|Where-Object {$_ -is [Management.Automation.ErrorRecord]}|ForEach-Object {[string]$_})
    $text=(@($output|Where-Object {$_ -isnot [Management.Automation.ErrorRecord]}|ForEach-Object {[string]$_}) -join "`n").Trim()
    $result=$null
    if($text){try {$result=ConvertFrom-Json -InputObject $text -ErrorAction Stop} catch {}}
    if($code -ne 0 -or $errors.Count -gt 0 -or -not $text.StartsWith('{') -or $result -isnot [pscustomobject] -or $result.status -isnot [string] -or $result.status -cne 'completed' -or $result.data -isnot [pscustomobject]){
        $messages=@($result.errors|ForEach-Object {$_.message}|Where-Object {$_})
        $reason=if($errors.Count){($errors -join ' ').Trim()}elseif($messages.Count){$messages -join '; '}elseif(-not $text){'the helper printed nothing'}else{'invalid response: '+$text}
        if($code -ne 0){$reason='exit '+$code+': '+$reason}
        throw ($WorkerAction+' failed: '+$reason.Substring(0,[Math]::Min(400,$reason.Length)))
    }
    return $result
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
    $script:WorkersKnown=$true
    try {$all=@(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'" -ErrorAction Stop)}
    catch {$script:WorkersKnown=$false;Write-Log ('Windows could not list processes ('+$_.Exception.Message+')');return @()}
    return @($all|Where-Object {
        $parts=@(Get-GovernorArguments ([string]$_.CommandLine))
        $_.ExecutablePath -ieq $hostExe -and $parts.Count -eq 3 -and $parts[0] -ieq $hostExe -and $parts[1] -ceq 'policy-run'
    })
}

function Stop-GovernorIdentity([int]$ProcessId,[string]$Created){
    $process=$null
    try {
        $process=[Diagnostics.Process]::GetProcessById($ProcessId)
        [void]$process.Handle
        if($process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -cne $Created){return $false}
        $process.Kill()
        return $true
    } catch {return $false}
    finally {if($process){$process.Dispose()}}
}

function Stop-Leftovers($Tasks){
    $opened=@{}
    try {
        foreach($process in @(Get-Process -Name 'Optimizer.Host' -ErrorAction SilentlyContinue)){
            try {[void]$process.Handle;if($process.Path -ieq $hostExe){$opened[$process.Id]=$process;continue}} catch {}
            $process.Dispose()
        }
        $workers=@(Get-Workers)
        if(-not $script:WorkersKnown){
            foreach($task in @($Tasks)){Invoke-Schtasks /End /TN ($task.taskPath+$task.taskName)|Out-Null;Write-Log ('Ended governor task '+$task.taskName+' through Task Scheduler')}
            Write-Log ($opened.Count.ToString()+' helper processes from the app folder may still be running; setup closes them before replacing files')
            return
        }
        foreach($worker in $workers){
            $process=$opened[[int]$worker.ProcessId]
            if(-not $process -or -not $worker.CreationDate){continue}
            $created=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
            if(($created-($created%10)) -ne $worker.CreationDate.ToUniversalTime().ToFileTimeUtc()){continue}
            if(Stop-GovernorIdentity ([int]$worker.ProcessId) $created.ToString()){
                Write-Log ('Ended leftover governor process '+$worker.ProcessId+': '+$worker.CommandLine)
            }
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(@(Get-Workers).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt 10){Start-Sleep -Milliseconds 200}
        if(@(Get-Workers).Count -gt 0 -and $script:WorkersKnown){throw 'A Roo Industries Governor process is still running from the app folder.'}
    } finally {
        foreach($process in $opened.Values){$process.Dispose()}
    }
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
        if(Test-Alive $state.host $Task.userSid){
            if(Stop-GovernorIdentity ([int]$state.host.processId) ([string]$state.host.creationTimeFileTimeUtc)){Write-Log ('Governor of Windows user '+$Task.userSid+' did not stop in time; ended it. Its apps keep the rule settings until they close or the governor starts again')}
            elseif(Test-Alive $state.host $Task.userSid){throw 'The governor did not stop and its process identity could not be confirmed for termination.'}
        }
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
        $tasks=@(Get-GovernorTasks|Where-Object {$_.trusted})
        if($tasks.Count -gt 0 -and -not (Test-WatchdogRegistered $tasks)){
            Write-Log 'Setup recovery could not be registered, so the governor tasks were left running and setup must not replace files'
            exit 4
        }
        foreach($task in $tasks){
            $record=[pscustomobject][ordered]@{taskName=$task.taskName;taskPath=$task.taskPath;description=$task.description;userSid=$task.userSid;policyRoot=$task.policyRoot;enabled=$task.enabled;wasRunning=$false}
            $records.Add($record)
            Save-Records $records
            Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath|Out-Null
            try {
                $stopped=Stop-Governor $task
                if($stopped){$record.wasRunning=$stopped.wasRunning;Save-Records $records}
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
        $failures=0
        try {
            $dataRoot=Get-RooIndustriesLocalDataRoot
            foreach($root in @(Join-Path $dataRoot 'process-rules')){
                if((Test-Path -LiteralPath (Join-Path $root 'rules')) -and -not @($records|Where-Object {$_.userSid -eq $me -and [string]$_.policyRoot -ieq $root}).Count){
                    Write-Log ('Found saved rules without a governor task: '+$root)
                    $records.Add([pscustomobject]@{taskName='';taskPath='\';description='';userSid=$me;policyRoot=$root;enabled=$true;wasRunning=$false})
                }
            }
        } catch {
            $failures++
            Write-Log ('Could not find saved rules for Windows user '+$me+': '+$_.Exception.Message)
        }
        foreach($record in $records){
            if($null -eq $record){continue}
            try {
                if($record.userSid -eq $me){
                    $supportsSync=(Test-Path -LiteralPath $workerScript) -and ([IO.File]::ReadAllText($workerScript) -match "'Sync'")
                    if($supportsSync){
                        $result=Invoke-Worker 'Sync' $record.policyRoot
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
                Write-Log ('Could not resume the governor for Windows user '+$record.userSid+' at '+$record.policyRoot+': '+$_.Exception.Message)
                if($record.enabled -and $record.taskName -and (Get-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath -ErrorAction SilentlyContinue)){Enable-ScheduledTask -TaskName $record.taskName -TaskPath $record.taskPath|Out-Null}
            }
        }
        if(Test-Path -LiteralPath $hostExe){
            try {Write-Log ('Timer startup: '+[string](Invoke-Host 'timer-refresh-installed' '').message)}
            catch {Write-Log ('Timer startup refresh failed: '+$_.Exception.Message)}
        }
        Write-Log ('Resumed '+$records.Count+' governor tasks with '+$failures+' failures')
        if($failures -gt 0){Write-Log 'Setup recovery stays registered to turn the governor tasks back on';exit 2}
        Remove-Watchdog
    }
    'Remove' {
        Remove-Watchdog
        if(Test-Path -LiteralPath $hostExe){
            try {foreach($message in @((Invoke-Host 'timer-remove-installed' '').messages)){Write-Log ([string]$message)}}
            catch {Write-Log ('Timer tasks kept because ownership could not be checked: '+$_.Exception.Message)}
        } else {Write-Log 'kept: older-version timer task, if present; installed helper is missing'}
        foreach($task in @(Get-GovernorTasks|Where-Object {$_.trusted})){
            Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath|Out-Null
            if($task.trusted -and $task.userSid -eq $me -and (Test-Path -LiteralPath $workerScript)){
                try {
                    $result=Invoke-Worker 'Remove' $task.policyRoot
                    Write-Log ('Governor stopped, settings restored and task removed for '+$task.policyRoot)
                } catch {Write-Log ('Could not stop the governor cleanly for '+$task.policyRoot+': '+$_.Exception.Message)}
            } elseif($task.trusted) {
                try {Stop-Governor $task|Out-Null} catch {Write-Log ('Could not stop the governor of Windows user '+$task.userSid+': '+$_.Exception.Message)}
            }
            if(Get-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath -Confirm:$false}
        }
        Stop-Leftovers @()
        $left=@(Get-GovernorTasks|Where-Object {$_.trusted}).Count
        $workersLeft=@(Get-Workers).Count
        Write-Log ('Governor tasks left: '+$left+'; governor processes left: '+$(if($script:WorkersKnown){$workersLeft}else{'unknown'}))
        if($left -gt 0){exit 3}
    }
}
exit 0
