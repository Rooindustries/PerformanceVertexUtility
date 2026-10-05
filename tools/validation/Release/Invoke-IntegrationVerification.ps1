param(
    [Parameter(Mandatory=$true)][ValidateSet('preflight','validators','release-build','install-old','upgrade','install-other','static-checks','scenario','setup-fallbacks','uninstall','summary','cleanup')][string]$Phase,
    [ValidateSet('loadtimes','invalidation','modes','migration-before','migration-after','migration-undo-blocker','migration-timer-on','permissions','hardware','launchers','launchers-session','override','incomplete','incomplete-before')][string]$Scenario='',
    [string]$Source=(Join-Path $env:TEMP 'roo-industries-integration-src'),
    [string]$Evidence=(Join-Path $env:TEMP 'roo-industries-integration-evidence'),
    [string]$OldInstaller='',
    [string]$NewInstaller='',
    [string]$OtherInstaller='',
    [string]$Label='other',
    [int]$Minutes=45,
    [string[]]$Only=@(),
    [string[]]$Expect=@('preflight','validators','release-build','install-old','scenario-migration-before','upgrade','scenario-migration-after','static-checks','scenario-migration-undo-blocker','scenario-migration-timer-on','scenario-permissions','scenario-launchers','scenario-override','scenario-incomplete','scenario-invalidation','scenario-modes','setup-fallbacks','scenario-hardware','scenario-loadtimes'),
    [switch]$TestHooks,
    [switch]$ReplaceExisting,
    [string]$BuildOutput='',
    [string]$BackupRoot=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'RooIndustriesIntegrationRecovery')
)
trap { if($log){Log ('FAIL unhandled exception :: '+$_.Exception.Message)}else{Write-Output ('FAIL unhandled exception :: '+$_.Exception.Message)}; exit 1 }
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot '..\LoadTimes\LauncherChecks.Common.ps1')
. (Join-Path $PSScriptRoot '..\LoadTimes\CleanupOwnership.Common.ps1')
$app='C:\Program Files\Roo Industries\Optimization Suite'
$local=[Environment]::GetFolderPath('LocalApplicationData')
$markerKey='HKLM\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$stateKey='HKLM\SOFTWARE\RooIndustriesOptimizationSuite'
$personalize='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$blockerFolder=Join-Path $env:ProgramFiles 'LogiDownloadAssistant'
$ifeoProbe='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProtectedGameProbe.exe'
$productKeys=@('HKLM:\SOFTWARE\RooIndustries\OptimizationSuite','HKLM:\SOFTWARE\RooIndustries')
$backup=$BackupRoot
$userEnvironment='HKCU:\Environment'
$plantedName='DOTNET_STARTUP_HOOKS'
$plantedValue='C:\RooIndustriesNoSuchFolder\hook.dll'
$rooHklm='HKLM\SOFTWARE\RooIndustries'
$requiredChecks=@{
    'validators'=@('optimizer-core exit 0','build-host exit 0','tweaks exit 0','process-policy-worker exit 0','protected-sessions exit 0','tool-launcher exit 0','frontend exit 0','client-cleanup-boundary exit 0','optimizer-host exit 0','data-root-marker-paths exit 0','governor-setup-legacy-pause exit 0','earlier-version-gate exit 0','script-parser exit 0','governor-scenarios exit 0','client-cleanup-boundary left the real data folders and the protection markers as it found them','tool-launcher left the real data folders and the protection markers as it found them')
    'setup-fallbacks'=@('setup-fallbacks exit 0')
    'release-build'=@('the dynamic binding guard rejected its own fixture during the release build','the dynamic binding guard passed on the four release assemblies','the release build produced a production installer')
    'static-checks'=@('exactly the three shipped runtimeconfig files are installed','startup hooks are off in app\RooIndustries.OptimizationSuite.App.runtimeconfig.json','startup hooks are off in backend\bin\optimizer\Optimizer.Host.runtimeconfig.json','startup hooks are off in backend\bin\optimizer\session\RooIndustries.SessionHost.runtimeconfig.json','control: Optimizer.Host.exe without those variables','control: RooIndustries.SessionHost.exe without those variables','Optimizer.Host.exe refuses to start with DOTNET_STARTUP_HOOKS set','Optimizer.Host.exe refuses to start with CORECLR_ENABLE_PROFILING and CORECLR_PROFILER_PATH set','RooIndustries.SessionHost.exe refuses to start with DOTNET_STARTUP_HOOKS set','RooIndustries.SessionHost.exe refuses to start with CORECLR_ENABLE_PROFILING and CORECLR_PROFILER_PATH set','the installed product has exactly one uninstall entry')
    'scenario-launchers'=@('the installed launcher clears every code-loading variable','control: the environment reader sees DOTNET_STARTUP_HOOKS','the governor rule was saved through the app','governor task * registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','protected-session task''s registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','control: a task that starts a program directly, with no launcher, inherits the planted DOTNET_STARTUP_HOOKS','governor worker''s own process environment contains none of the','protected session worker''s own process environment contains none of the','governor worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','protected session worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','the governor worker is running after the rule was saved','the governor worker image is the installed Optimizer.Host.exe under C:\Program Files','the protected-session worker image is the installed RooIndustries.SessionHost.exe under C:\Program Files','with the app closed the governor applies the saved rule to a matching process that starts later','the protected session is armed and its worker is running','while the session is armed the launcher has the requested affinity, memory priority and I/O priority','the launcher probe has its original affinity, memory priority, I/O priority and CPU priority back after the stop')
    'scenario-launchers-session'=@('the protected-session worker image is the installed RooIndustries.SessionHost.exe under C:\Program Files','control: a task that starts a program directly, with no launcher, inherits the planted DOTNET_STARTUP_HOOKS','protected-session task''s registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','protected session worker''s own process environment contains none of the','protected session worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','the protected session is armed and its worker is running')
    'scenario-override'=@('control: the process trace sees a dotnet.exe that this scenario starts on purpose','the release app still loads the Windows tweaks rows and finishes reading Windows','the override reached the app','the app started Optimizer.Host.exe children whose image is inside the install folder','the app never started a dotnet.exe')
    'scenario-incomplete'=@('control: the process trace sees a dotnet.exe that this scenario starts on purpose','Windows tweaks shows the missing-files message when hostpolicy.dll is missing','the app log has a Missing hostpolicy.dll line','no dotnet.exe was started anywhere on this PC','the installed Invoke-CleanupExclusions.ps1 refuses','the installed Invoke-ProtectedGameSession.ps1 refuses','hostpolicy.dll is back in place')
    'scenario-permissions'=@('runas /trustlevel:0x20000 gave a standard token','root is owned by Administrators or SYSTEM','operations is owned by Administrators or SYSTEM','timer is owned by Administrators or SYSTEM','firmware is owned by Administrators or SYSTEM','tools is owned by Administrators or SYSTEM','settings is owned by Administrators or SYSTEM','rules is owned by Administrators or SYSTEM','a standard token is denied writing into root','a standard token is denied writing into operations','a standard token is denied writing into timer','a standard token is denied writing into firmware','a standard token is denied writing into tools','a standard token is denied writing into settings','a standard token is denied writing into rules','the sign-in timer state folder is a plain folder outside the protected data folder','the sign-in timer state folder is owned by the signed-in user','a standard token can write the sign-in timer state folder')
    'scenario-migration-before'=@('the earlier version applied the tweak profile','the earlier version saved the governor rule','the earlier version enforces the rule on the probe','the earlier version has a governor task and a running governor worker to replace','the earlier version registered the sign-in timer','the earlier version applied the download folder blocker and saved its receipt')
    'scenario-migration-undo-blocker'=@('the new version undoes the download folder blocker applied by the earlier version')
    'scenario-migration-timer-on'=@('the new version starts the timer and creates its state folder outside the data folder','the timer worker runs from the installed helper')
    'scenario-migration-after'=@('the probe from before the upgrade is still running','after the upgrade the governor still enforces the earlier rule','the upgraded install has a governor task','upgraded governor task * registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','the governor worker running after the upgrade is the installed new one','upgraded governor worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','a process started after the upgrade gets the migrated rule from the new governor','the Undo page lists the profile applied by the earlier version','the app asked once whether to use the backup saved by an older version','the sign-in timer of the earlier version is still registered after the upgrade','the new version restores the tweak applied by the earlier version','deleting the migrated rule gives the probe its normal priority back')
}
$noSuch='C:\RooIndustriesNoSuchFolder'
$dotnet=@((Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'))|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
if($Phase -eq 'preflight' -and (Test-Path -LiteralPath $Evidence) -and @(Get-ChildItem -LiteralPath $Evidence -Force).Count){Move-Item -LiteralPath $Evidence -Destination ($Evidence+'.previous-'+[DateTime]::UtcNow.Ticks)}
New-Item -ItemType Directory -Force -Path $Evidence|Out-Null
$log=Join-Path $Evidence (($Phase+$(if($Phase -eq 'scenario'){'-'+$Scenario}elseif($Phase -eq 'install-other'){'-'+$Label}else{''}))+'.log')
if(Test-Path -LiteralPath $log){Move-Item -LiteralPath $log -Destination ($log+'.previous-'+[DateTime]::UtcNow.Ticks)}
function Log([string]$Text){$line=[DateTime]::UtcNow.ToString('o')+' '+$Text;Add-Content -LiteralPath $log -Value $line -Encoding UTF8;$line}
$script:Failures=0
function Check([bool]$Ok,[string]$Name,[string]$Detail=''){if(-not $Ok){$script:Failures++};Log ($(if($Ok){'PASS '}else{'FAIL '})+$Name+' :: '+$Detail)}
function Invoke-Native([string]$File,[string[]]$Arguments,[string[]]$Stdin=@()){
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {
        $text=@($(if($Stdin.Count){$Stdin|& $File @Arguments 2>&1}else{& $File @Arguments 2>&1})|ForEach-Object {[string]$_})
        return [pscustomobject]@{Exit=$LASTEXITCODE;Text=($text -join "`n")}
    } finally {$ErrorActionPreference=$previous}
}
function Get-DataFolderState {
    $names='RooIndustriesOptimizationSuite',('RooIndustriesOptimizationSuite' -replace 'Industries',''),'RooIndustriesOptimizationSuite.Timer'
    $rows=[Collections.Generic.List[object]]::new()
    $parts=foreach($name in $names){
        $path=Join-Path $local $name
        if(Test-Path -LiteralPath $path){
            $base=(Get-Item -LiteralPath $path -Force).FullName
            $items=@(Get-Item -LiteralPath $path -Force)+@(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction Stop)
            $text=(@($items|ForEach-Object {
                if(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Cannot back up a reparse point: '+$_.FullName)}
                $relative=$_.FullName.Substring($base.Length);$size=if($_.PSIsContainer){0}else{$_.Length};$hash=if($_.PSIsContainer){''}else{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash};$lastWrite=if($_.PSIsContainer){[IO.Directory]::GetLastWriteTimeUtc($_.FullName)}else{[IO.File]::GetLastWriteTimeUtc($_.FullName)};$ticks=$lastWrite.Ticks
                $line=$relative+'|'+$(if($_.PSIsContainer){'dir'}else{[string]$size+'|sha256='+$hash})+'|'+$ticks
                $rows.Add([pscustomobject][ordered]@{root=$name;relative=$relative;kind=$(if($_.PSIsContainer){'directory'}else{'file'});size=$size;lastWriteFileTimeUtc=$lastWrite.ToFileTimeUtc().ToString();sha256=$hash;hashInput=$line})
                $line
            })|Sort-Object) -join "`n"
            $name+'|'+$items.Count+'|'+[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','')
        } else {$rows.Add([pscustomobject][ordered]@{root=$name;relative='';kind='missing';size=$null;lastWriteFileTimeUtc=$null;sha256=$null;hashInput='<missing>'});$name+'|<missing>'}
    }
    $key=Get-Item -LiteralPath ('Registry::'+$markerKey) -ErrorAction SilentlyContinue
    $marks=if($key){@($key.GetValueNames()|Sort-Object|ForEach-Object {$_+'='+$key.GetValue($_)})}else{@('<no marker key>')}
    return [pscustomobject][ordered]@{state=(@($parts)+@($marks)) -join "`n";rows=@($rows|Sort-Object root,relative);markers=@($marks)}
}
function Run([string]$Name,[scriptblock]$Body,[switch]$GuardData){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if($GuardData){
        $guardId=$Phase+'-'+$Name+'-data-'+[Guid]::NewGuid().ToString('N')
        $beforePath=Join-Path $Evidence ($guardId+'-before.json');$afterPath=Join-Path $Evidence ($guardId+'-after.json')
        $dataBefore=Get-DataFolderState
        $dataBefore|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $beforePath -Encoding UTF8
    }
    $ErrorActionPreference='Continue'
    $global:LASTEXITCODE=0
    $output=[Collections.Generic.List[string]]::new()
    $errors=0
    try {& $Body 2>&1|ForEach-Object {if($_ -is [Management.Automation.ErrorRecord]){$errors++};$output.Add([string]$_)};$code=$LASTEXITCODE}
    catch {$output.Add(($_|Out-String));$code=1}
    $output|Set-Content -LiteralPath (Join-Path $Evidence ($Phase+'-'+$Name+'.txt')) -Encoding UTF8
    $ran=if($Name -eq 'build-host'){@($output|Where-Object {$_ -match 'Optimizer.Host ->'}).Count -gt 0 -and @($output|Where-Object {$_ -match 'Optimizer.SessionHost ->'}).Count -gt 0}elseif($Name -eq 'script-parser'){@($output|Where-Object {$_ -match 'PowerShell parser validation passed for [1-9]\d* files'}).Count -gt 0}else{@($output|Where-Object {$_ -cmatch '^PASS '}).Count -gt 0}
    $passes=@($output|Where-Object {$_ -cmatch '^PASS '}).Count
    $fails=@($output|Where-Object {$_ -cmatch '^FAIL '}).Count
    $skips=@($output|Where-Object {$_ -cmatch '^SKIP'})
    $last=@($output|Where-Object {$_.Trim()}|Select-Object -Last 1)
    if($GuardData){
        $dataAfter=Get-DataFolderState
        $dataAfter|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $afterPath -Encoding UTF8
        $same=$dataAfter.state -eq $dataBefore.state
        $guardDetail='same; before='+$beforePath+'; after='+$afterPath
        if(-not$same){
            $beforeRows=@($dataBefore.rows|ForEach-Object {$_|ConvertTo-Json -Compress})+@($dataBefore.markers|ForEach-Object {[ordered]@{marker=$_}|ConvertTo-Json -Compress})
            $afterRows=@($dataAfter.rows|ForEach-Object {$_|ConvertTo-Json -Compress})+@($dataAfter.markers|ForEach-Object {[ordered]@{marker=$_}|ConvertTo-Json -Compress})
            $diff=@(Compare-Object $beforeRows $afterRows -CaseSensitive|ForEach-Object {[pscustomobject][ordered]@{side=$(if($_.SideIndicator -ceq '<='){'before'}else{'after'});row=($_.InputObject|ConvertFrom-Json)}})
            $diffPath=Join-Path $Evidence ($guardId+'-diff.json');ConvertTo-Json -InputObject $diff -Depth 10|Set-Content -LiteralPath $diffPath -Encoding UTF8
            $guardDetail='before='+$beforePath+'; after='+$afterPath+'; diff='+$diffPath+'; '+(@($diff|ForEach-Object {$_.side+' '+($_.row|ConvertTo-Json -Compress)}) -join ' // ')
        }
        Check $same ($Name+' left the real data folders and the protection markers as it found them') $guardDetail
    }
    Check ($ran -and $code -eq 0 -and $errors -eq 0 -and $fails -eq 0 -and $skips.Count -eq 0) ($Name+' exit '+$code+' in '+[Math]::Round($clock.Elapsed.TotalSeconds)+' s; PASS lines '+$passes+', FAIL lines '+$fails+', SKIP lines '+$skips.Count+'; last line: '+([string]$last).Substring(0,[Math]::Min(120,([string]$last).Length))) (@($output|Where-Object {$_ -match 'FAIL|error|Exception|^SKIP'}|Select-Object -First 3) -join ' / ')
}
function Uninstall-App {
    $uninstaller=Get-ChildItem -LiteralPath $app -Filter 'unins*.exe' -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $uninstaller){return 'not installed'}
    Assert-RecoveryIdle
    Assert-SealedRecovery $Evidence
    $nativeEvidence=Join-Path $Evidence ($Phase+'-uninstall-'+[Guid]::NewGuid().ToString('N'))
    New-SealedDirectory $nativeEvidence
    $script:NativeUninstallLog=Join-Path $nativeEvidence 'native-uninstall.log'
    $p=Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="'+$script:NativeUninstallLog+'"') -Wait -PassThru
    for($i=0;$i -lt 60 -and (Test-Path -LiteralPath (Join-Path $app 'app'));$i++){Start-Sleep 1}
    'exit='+$p.ExitCode+' appLeft='+(Test-Path -LiteralPath (Join-Path $app 'app'))
}
function Stop-AfterInstall {
    Start-Sleep -Seconds 3
    $s=Read-RecoveryScope
    Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" -ErrorAction Stop|Where-Object {$_.CommandLine -match [regex]::Escape((Join-Path $app 'README')) -and (Get-RecoveryProcessOwner $_) -ceq $s.sid}|ForEach-Object {Stop-ProcessRow $_}
    Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.ExecutablePath -ieq (Join-Path $app 'app\RooIndustries.OptimizationSuite.App.exe') -and (Get-RecoveryProcessOwner $_) -ceq $s.sid}|ForEach-Object {Stop-ProcessRow $_}
}
function Get-VerificationInvocationTask {
    $variable=Get-Variable RooVerificationInvocationContext -Scope Global -ErrorAction SilentlyContinue
    if(-not$variable){return $null}
    $context=$variable.Value
    if(-not$context -or $context.protocol -cne 'roo-industries-verification-invocation/v1' -or -not$context.run -or -not$context.taskName -or -not$context.task -or -not$context.wrapper){throw 'Missing verification invocation context'}
    Assert-SealedRecovery $context.run
    $task=$context.task;$wrapper=$context.wrapper
    if($task.name -cne $context.taskName -or $task.path -cne '\' -or -not$task.xml -or -not$task.sddl -or -not$wrapper.pid -or -not$wrapper.creationTimeFileTimeUtc -or -not$wrapper.imagePath){throw 'Verification invocation receipt scope differs'}
    $retainedTask=Get-Content -Raw -LiteralPath (Join-Path $context.run 'task.json')|ConvertFrom-Json
    $retainedWrapper=Get-Content -Raw -LiteralPath (Join-Path $context.run 'wrapper.json')|ConvertFrom-Json
    foreach($field in 'name','path','xml','sddl'){if($task.$field -cne $retainedTask.$field){throw 'Verification task context differs from retained receipt'}}
    foreach($field in 'pid','creationTimeFileTimeUtc','imagePath'){if($wrapper.$field -cne $retainedWrapper.$field){throw 'Verification parent context differs from retained receipt'}}
    $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID) -ErrorAction Stop
    if(-not$current -or $current.ParentProcessId -ne $wrapper.pid){throw 'Verification invocation native parent differs'}
    $parent=Get-Process -Id $wrapper.pid -ErrorAction Stop
    try{
        $native=New-OwnedProcess $parent
        if(-not$native -or $native.Identity.creationTimeFileTimeUtc -cne $wrapper.creationTimeFileTimeUtc -or $native.Identity.imagePath -cne $wrapper.imagePath){throw 'Verification invocation native parent identity differs'}
        $system=[Environment]::SystemDirectory
        if($wrapper.imagePath -cne [RooValidationOwnership.Native]::Canonical((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'))){throw 'Verification wrapper image differs'}
        Assert-OwnedTaskUnchanged $task
        $xml=[xml]$task.xml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t',$xml.DocumentElement.NamespaceURI)
        $actions=@($xml.SelectNodes('/t:Task/t:Actions/t:Exec',$ns))
        if($actions.Count -ne 1 -or @($xml.SelectNodes('/t:Task/t:Actions/*',$ns)).Count -ne 1){throw 'Verification invocation task actions differ'}
        $action=$actions[0]
        if($action.WorkingDirectory -cne $context.run -or [RooValidationOwnership.Native]::Canonical([string]$action.Command) -cne [RooValidationOwnership.Native]::Canonical((Join-Path $system 'conhost.exe'))){throw 'Verification invocation task frame differs'}
        $pattern='^--headless "'+[regex]::Escape((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'))+'" (-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand [A-Za-z0-9+/=]+)$'
        if([string]$action.Arguments -cnotmatch $pattern){throw 'Verification invocation task command differs'}
        $suffix=$Matches[1]
        $parentRow=Get-CimInstance Win32_Process -Filter ('ProcessId='+$wrapper.pid) -ErrorAction Stop
        if(-not$parentRow -or -not([string]$parentRow.CommandLine).EndsWith(' '+$suffix,[StringComparison]::Ordinal)){throw 'Verification task does not launch the current wrapper'}
        Assert-OwnedTaskUnchanged $task
        if($parent.HasExited){throw 'Verification wrapper exited during capture'}
        return $task.path+$task.name
    }finally{$parent.Dispose()}
}
function Get-MachineState {
    $invocationTask=Get-VerificationInvocationTask
    $hypervisor=@((Invoke-Native bcdedit.exe @('/enum','{current}')).Text -split "`n"|Where-Object {$_ -match 'hypervisorlaunchtype'})
    $guard=Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    $rename=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    $transparency=(Get-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency
    $machineState=[ordered]@{
        hypervisorlaunchtype=($hypervisor -join ';').Trim()
        vbsStatus=[string]@($guard|ForEach-Object {$_.VirtualizationBasedSecurityStatus})
        vbsRunning=(@($guard|ForEach-Object {$_.SecurityServicesRunning}) -join ',')
        rebootPendingCbs=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        rebootRequiredUpdate=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        pendingFileRenames=(@($rename)-join '|')
        tasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object {$_.TaskName -match 'OptimizationSuite|Protected Session|RooIndustries' -and ($_.TaskPath+$_.TaskName) -cne $invocationTask}|ForEach-Object {$_.TaskPath+$_.TaskName}|Sort-Object)
        productKeys=@($productKeys|Where-Object {Test-Path -LiteralPath $_})
        uninstallEntries=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue|Where-Object {$_.PSChildName -match 'RooIndustries|OptimizationSuite' -or $_.PSChildName -like '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}*'}|ForEach-Object PSChildName)
        appFolder=(Test-Path -LiteralPath 'C:\Program Files\Roo Industries')
        enableTransparency=$(if($null -ne $transparency){[string]$transparency}else{'<absent>'})
        ifeoProbeKey=(Test-Path -LiteralPath $ifeoProbe)
        downloadBlockerFolder=(Test-Path -LiteralPath $blockerFolder)
        localSiblings=@(Get-ChildItem -LiteralPath $local -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'OptimizationSuite'}|ForEach-Object Name|Sort-Object)
        userEnvironmentNames=@((Get-Item -LiteralPath $userEnvironment).GetValueNames()|Sort-Object)
    }
    if($invocationTask -and (Get-VerificationInvocationTask) -cne $invocationTask){throw 'Verification invocation changed during machine capture'}
    return $machineState
}
function Show-Difference($Expected,$Actual){(@(Compare-Object $Expected $Actual|Select-Object -First 3|ForEach-Object {$_.SideIndicator+' '+$_.InputObject}) -join ' // ')}
function Get-RegistryFingerprint([string]$Key) {
    $Key=Resolve-RecoveryRegistryKey $Key
    $item=Get-Item -LiteralPath ('Registry::'+$Key) -ErrorAction SilentlyContinue
    if(-not $item){return '<absent>'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        foreach($node in @($item)+@(Get-ChildItem -LiteralPath ('Registry::'+$Key) -Recurse -ErrorAction SilentlyContinue)){
            $bytes=[Text.Encoding]::UTF8.GetBytes($node.Name+"`n");[void]$sha.TransformBlock($bytes,0,$bytes.Length,$null,0)
            foreach($name in @($node.GetValueNames()|Sort-Object)){
                $value=$node.GetValue($name,$null,'DoNotExpandEnvironmentNames')
                $bytes=$value
                if($value -isnot [byte[]]){$bytes=[Text.Encoding]::UTF8.GetBytes((@($value) -join "`n"))}
                $head=[Text.Encoding]::UTF8.GetBytes($name+'|'+$node.GetValueKind($name)+'|'+$bytes.Length+"`n");[void]$sha.TransformBlock($head,0,$head.Length,$null,0)
                [void]$sha.TransformBlock($bytes,0,$bytes.Length,$null,0)
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    } finally {$sha.Dispose()}
}
function ConvertTo-RecoveryNativePath([string]$Path) { Assert-PlainRecoveryPath $Path -PassThru }
function Read-RecoveryJson([string]$Path) { $v=[IO.File]::ReadAllText((ConvertTo-RecoveryNativePath $Path))|ConvertFrom-Json;return $v }
function Get-RecoveryNames { @('RooIndustriesOptimizationSuite','RooOptimizationSuite','RooIndustriesOptimizationSuite.Timer') }
function Initialize-RecoveryNative {
    if('RooVerificationRecovery.Native' -as [type]){return}
    $temp=$backup+'.native-temp-'+[Guid]::NewGuid().ToString('N')
    New-SealedDirectory $temp
    $oldTemp=$env:TEMP;$oldTmp=$env:TMP
    try {
        $env:TEMP=$temp;$env:TMP=$temp
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace RooVerificationRecovery {
 public static class Native {
  [DllImport("advapi32.dll",EntryPoint="SetFileSecurityW",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool Set(string p,uint i,byte[] d);
  [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] struct Privilege { public uint Count; public Luid Id; public uint Attributes; }
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr t);
  [DllImport("advapi32.dll",EntryPoint="LookupPrivilegeValueW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Lookup(string system,string name,out Luid id);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t,bool all,ref Privilege value,uint size,out Privilege previous,out uint length);
  [DllImport("advapi32.dll",EntryPoint="AdjustTokenPrivileges",SetLastError=true)] static extern bool Reset(IntPtr t,bool all,ref Privilege value,uint size,IntPtr previous,IntPtr length);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static bool Exact(string p,uint i,byte[] d) {
   IntPtr token;if(!OpenProcessToken(new IntPtr(-1),40,out token))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   var prior=new Privilege();bool changed=false;
   try {
    Luid id;if(!Lookup(null,"SeSecurityPrivilege",out id))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    var enabled=new Privilege { Count=1,Id=id,Attributes=2 };uint length;
    if(!AdjustTokenPrivileges(token,false,ref enabled,(uint)Marshal.SizeOf(typeof(Privilege)),out prior,out length)||Marshal.GetLastWin32Error()!=0)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    changed=true;var value=(byte[])d.Clone();var control=BitConverter.ToUInt16(value,2);
    if((control&0x400)!=0)value[3]|=1;
    if((control&0x800)!=0)value[3]|=2;
    uint info=i|8|((control&0x2000)!=0?0x40000000u:0x10000000u);
    return Set(p,info,value);
   } finally {try{if(changed&&!Reset(token,false,ref prior,0,IntPtr.Zero,IntPtr.Zero))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());}finally{CloseHandle(token);}}
  }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Stream { public long Size; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=296)] public string Name; }
  [DllImport("kernel32.dll",EntryPoint="FindFirstStreamW",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr First(string p,int level,out Stream data,int flags);
  [DllImport("kernel32.dll",EntryPoint="FindNextStreamW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Next(IntPtr h,out Stream data);
  [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr h);
  [StructLayout(LayoutKind.Sequential,Pack=4)] public struct DirectoryInfo { public uint Attributes; public long Creation; public long Access; public long Write; public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IdHigh; public uint IdLow; }
  [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenDirectory(string p,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr h,out DirectoryInfo value);
  public static DirectoryInfo DirectoryMetadata(string p) {
   var h=OpenDirectory(p,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
   if(h==new IntPtr(-1))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   try {DirectoryInfo value;if(!GetFileInformationByHandle(h,out value))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());if((value.Attributes&0x400)!=0||(value.Attributes&16)==0)throw new InvalidOperationException("Companion is not a plain directory");return value;}finally{CloseHandle(h);}
  }
  public static string[] Streams(string p) {
   var names=new List<string>();Stream s;var h=First(p,0,out s,0);
   if(h==new IntPtr(-1)){int e=Marshal.GetLastWin32Error();if(e==38)return names.ToArray();throw new System.ComponentModel.Win32Exception(e);}
   try {names.Add(s.Name);while(Next(h,out s))names.Add(s.Name);int e=Marshal.GetLastWin32Error();if(e!=38)throw new System.ComponentModel.Win32Exception(e);}finally{FindClose(h);}
   return names.ToArray();
  }
 }
}
'@
    } finally {$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
}
function Assert-PlainRecoveryPath([string]$Path,[switch]$PassThru) {
    if($Path.StartsWith('\\?\',[StringComparison]::Ordinal)){$Path=$Path.Substring(4)}
    $plain=[IO.Path]::GetFullPath($Path)
    if($plain -notmatch '^[A-Za-z]:\\'){throw 'Recovery requires an absolute local path'}
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($plain))
    if($drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -ine 'NTFS'){throw 'Recovery requires a fixed NTFS volume'}
    $native='\\?\'+$plain;$p=$native
    while($p){
        try {$attributes=[IO.File]::GetAttributes($p)} catch {
            $error=$_.Exception.GetBaseException()
            if($error -isnot [IO.FileNotFoundException] -and $error -isnot [IO.DirectoryNotFoundException]){throw}
            $attributes=0
        }
        if($attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Recovery path has reparse ancestry: '+$p)}
        $p=[IO.Path]::GetDirectoryName($p)
    }
    if($PassThru){return $native}
}
function Assert-RecoveryEvidenceParent {
    $parent=[IO.Path]::GetDirectoryName((ConvertTo-RecoveryNativePath $backup))
    Assert-PlainRecoveryPath $parent
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    while($parent){
        $acl=Get-Acl -LiteralPath $parent
        if($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'Recovery ancestry has an untrusted owner'}
        foreach($r in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly){continue};if($r.AccessControlType -eq 'Allow' -and $trusted -notcontains $r.IdentityReference.Value -and (([int]$r.FileSystemRights -band 0xD0040) -ne 0)){throw 'Recovery ancestry permits replacement of sealed evidence'}}
        $parent=[IO.Path]::GetDirectoryName($parent)
    }
}
function New-SealedDirectory([string]$Path) {
    $nativePath=Assert-PlainRecoveryPath $Path -PassThru
    if(-not('RooVerificationDirectoryCreator' -as [type])){
        $assembly=[AppDomain]::CurrentDomain.DefineDynamicAssembly([Reflection.AssemblyName]::new('RooVerificationDirectoryCreator'),[Reflection.Emit.AssemblyBuilderAccess]::Run)
        $module=$assembly.DefineDynamicModule('Native')
        $type=$module.DefineType('RooVerificationDirectoryCreator',[Reflection.TypeAttributes]::Public)
        $method=$type.DefinePInvokeMethod('Create','kernel32.dll','CreateDirectoryW',[Reflection.MethodAttributes]'Public, Static, PinvokeImpl',[Reflection.CallingConventions]::Standard,[int],[type[]]@([string],[IntPtr]),[Runtime.InteropServices.CallingConvention]::Winapi,[Runtime.InteropServices.CharSet]::Unicode)
        $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
        $type.CreateType()|Out-Null
    }
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;RC;;;OW)')
    $bytes=$acl.GetSecurityDescriptorBinaryForm()
    $descriptor=[Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    $size=if([IntPtr]::Size -eq 8){24}else{12};$offset=if([IntPtr]::Size -eq 8){8}else{4}
    $attributes=[Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        [Runtime.InteropServices.Marshal]::Copy($bytes,0,$descriptor,$bytes.Length)
        [Runtime.InteropServices.Marshal]::WriteInt32($attributes,0,$size)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($attributes,$offset,$descriptor)
        [Runtime.InteropServices.Marshal]::WriteInt32($attributes,($offset+[IntPtr]::Size),0)
        if([RooVerificationDirectoryCreator]::Create($nativePath,$attributes) -eq 0){throw ('Exclusive sealed directory creation failed: '+$Path)}
    } finally {[Runtime.InteropServices.Marshal]::FreeHGlobal($attributes);[Runtime.InteropServices.Marshal]::FreeHGlobal($descriptor)}
    Assert-SealedRecovery $Path
}
function Assert-SealedRecovery([string]$Path) {
    $Path=Assert-PlainRecoveryPath $Path -PassThru
    $items=@(Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
    if(-not$items.Count){throw ('Recovery evidence does not exist or cannot be read: '+$Path)}
    if($items[0].PSIsContainer){$q=[Collections.Generic.Queue[object]]::new();$q.Enqueue($items[0]);$items=@();while($q.Count){$i=$q.Dequeue();$items+=@($i);if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Recovery evidence has a reparse point'};if($i.PSIsContainer){foreach($c in @(Get-ChildItem -LiteralPath $i.FullName -Force -ErrorAction Stop)){$q.Enqueue($c)}}}}
    foreach($i in $items){
        $acl=Get-Acl -LiteralPath $i.FullName
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544'){throw 'Recovery evidence has an untrusted owner'}
        foreach($r in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' -and (([int]$r.FileSystemRights -band 0xD0156) -ne 0)){throw ('Recovery evidence permits an untrusted writer: '+$i.FullName)}}
    }
}
function Save-RecoveryJson([string]$Path,$Value) {
    $Path=ConvertTo-RecoveryNativePath $Path
    Assert-SealedRecovery $backup
    if(Test-Path -LiteralPath $Path){throw ('Recovery evidence already exists: '+$Path)}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 30))
    $file=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$file.Write($bytes,0,$bytes.Length);$file.Flush($true)} finally {$file.Dispose()}
    Assert-SealedRecovery $Path
}
function Get-RecoveryRows([string]$Path) {
    $Path=ConvertTo-RecoveryNativePath $Path
    Initialize-RecoveryNative
    $base=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if(-not$base){throw ('Recovery path does not exist or cannot be read: '+$Path)}
    $q=[Collections.Generic.Queue[object]]::new();$q.Enqueue($base);$rows=[Collections.Generic.List[object]]::new()
    while($q.Count){
        $i=$q.Dequeue();$i.Refresh()
        if(-not$i.Exists -or [int]$i.Attributes -eq -1){throw ('Recovery entry cannot be read: '+$i.FullName)}
        if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Cannot copy reparse point: '+$i.FullName)}
        if(@([RooVerificationRecovery.Native]::Streams($i.FullName)|Where-Object {$_ -cne '::$DATA'}).Count){throw ('Named alternate streams require a separate audited capture: '+$i.FullName)}
        $acl=Get-Acl -LiteralPath $i.FullName -Audit -ErrorAction Stop
        if([Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0).SystemAcl -ne $null){throw ('Audit ACL requires a separate audited capture: '+$i.FullName)}
        $rows.Add([pscustomobject][ordered]@{relative=$i.FullName.Substring($base.FullName.Length);directory=[bool]$i.PSIsContainer;length=$(if($i.PSIsContainer){0}else{$i.Length});creation=$i.CreationTimeUtc.Ticks.ToString();write=$i.LastWriteTimeUtc.Ticks.ToString();attributes=[int]$i.Attributes;sha256=$(if($i.PSIsContainer){''}else{(Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256 -ErrorAction Stop).Hash});sddl=$acl.Sddl;control=[int][Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0).ControlFlags;descriptor=[Convert]::ToBase64String($acl.GetSecurityDescriptorBinaryForm())})
        if($i.PSIsContainer){foreach($c in @(Get-ChildItem -LiteralPath $i.FullName -Force -ErrorAction Stop)){$q.Enqueue($c)}}
    }
    @($rows|Sort-Object relative)
}
function Recovery-Lines($Rows,[switch]$DataOnly) {
    @($Rows|ForEach-Object {if($DataOnly){[ordered]@{relative=$_.relative;directory=$_.directory;length=$_.length;creation=$_.creation;write=$_.write;attributes=$_.attributes;sha256=$_.sha256}|ConvertTo-Json -Compress}else{[ordered]@{relative=$_.relative;directory=$_.directory;length=$_.length;creation=$_.creation;write=$_.write;attributes=$_.attributes;sha256=$_.sha256;sddl=$_.sddl;control=$_.control}|ConvertTo-Json -Compress}})
}
function Assert-RecoveryEqual($Expected,$Actual,[string]$Label) {
    if(@(Compare-Object @($Expected) @($Actual) -CaseSensitive).Count){throw ('Recovery fingerprint changed: '+$Label)}
}
function Get-TreeFingerprint([string]$Path) {
    $Path=ConvertTo-RecoveryNativePath $Path
    if(-not(Test-Path -LiteralPath $Path)){return @('<missing>')}
    Recovery-Lines @(Get-RecoveryRows $Path)
}
function Copy-VerifiedTree([string]$SourcePath,[string]$TargetPath,[switch]$SealTarget,$OriginalRows=$null) {
    if(Test-Path -LiteralPath (ConvertTo-RecoveryNativePath $TargetPath)){throw 'Clone destination already exists'}
    if($null -ne $OriginalRows){Assert-SealedRecovery $SourcePath}
    $before=@(Get-RecoveryRows $SourcePath)
    $expected=if($null -ne $OriginalRows){@($OriginalRows)}else{$before}
    Assert-RecoveryEqual (Recovery-Lines $expected -DataOnly) (Recovery-Lines $before -DataOnly) 'source bytes/metadata'
    New-SealedDirectory $TargetPath
    $copy=Invoke-Native robocopy.exe @($SourcePath,$TargetPath,'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NP')
    Log ('verified clone '+$SourcePath+' -> '+$TargetPath+' exit '+$copy.Exit)
    if($copy.Exit -lt 0 -or $copy.Exit -ge 8){throw ('Clone failed with exit '+$copy.Exit)}
    Assert-RecoveryEqual (Recovery-Lines $before) (Recovery-Lines @(Get-RecoveryRows $SourcePath)) 'source drift during copy'
    Assert-RecoveryEqual (Recovery-Lines $expected -DataOnly) (Recovery-Lines @(Get-RecoveryRows $TargetPath) -DataOnly) 'clone bytes/metadata'
    Restore-RecoveryDescriptors $expected $TargetPath -Seal:$SealTarget
    if($SealTarget){Assert-SealedRecovery $TargetPath;Assert-RecoveryEqual (Recovery-Lines $expected -DataOnly) (Recovery-Lines @(Get-RecoveryRows $TargetPath) -DataOnly) 'sealed clone bytes/metadata';Save-RecoveryJson ($TargetPath+'.manifest.json') $expected}
    else{Assert-RecoveryEqual (Recovery-Lines $expected) (Recovery-Lines @(Get-RecoveryRows $TargetPath)) 'raw descriptor clone'}
    Assert-RecoveryEqual (Recovery-Lines $before) (Recovery-Lines @(Get-RecoveryRows $SourcePath)) 'source drift after verification'
    return ,$expected
}
function Get-RecoveryRegistry([string]$Root) {
    $Root=Resolve-RecoveryRegistryKey $Root
    $p='Registry::'+$Root
    if(-not(Test-Path -LiteralPath $p)){return @()}
    $items=@(Get-Item -LiteralPath $p -ErrorAction Stop)+@(Get-ChildItem -LiteralPath $p -Recurse -ErrorAction Stop)
    @($items|Sort-Object Name|ForEach-Object {$key=$_;[pscustomobject][ordered]@{key=$key.Name;name=$null;kind='<key>';value=$key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')};foreach($n in @($key.GetValueNames()|Sort-Object)){[pscustomobject][ordered]@{key=$key.Name;name=$n;kind=[string]$key.GetValueKind($n);value=$key.GetValue($n,$null,'DoNotExpandEnvironmentNames')}}})
}
function New-RecoveryScope($State) {
    Assert-RecoveryEvidenceParent
    New-SealedDirectory $backup
    $folders=foreach($name in Get-RecoveryNames){$p=Join-Path $local $name;$lines=@(Get-TreeFingerprint $p);if($lines[0] -cne '<missing>'){Copy-VerifiedTree $p (Join-Path $backup $name) -SealTarget|Out-Null};[ordered]@{name=$name;expected=$lines}}
    $registry=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    $exports=foreach($pair in @(@($rooHklm,'hklm-roo-industries.reg'),@($stateKey,'tweak-state.reg'))){$p=Join-Path $backup $pair[1];$before=Get-RegistryFingerprint $pair[0];if($before -cne '<absent>'){$r=Invoke-Native reg.exe @('export',$pair[0],$p,'/y');if($r.Exit -ne 0){throw 'Registry export failed'};Assert-RecoveryEqual @($before) @(Get-RegistryFingerprint $pair[0]) 'registry drift during export';[ordered]@{file=$pair[1];hash=(Get-FileHash -LiteralPath $p).Hash}}}
    $registryAfter=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    Assert-RecoveryEqual @($registry|ForEach-Object {$_|ConvertTo-Json -Depth 10 -Compress}) @($registryAfter|ForEach-Object {$_|ConvertTo-Json -Depth 10 -Compress}) 'registry drift before sealing baseline'
    foreach($f in $folders){Assert-RecoveryEqual @($f.expected) @(Get-TreeFingerprint (Join-Path $local $f.name)) 'source drift before sealing baseline'}
    $State.backupFormat=3
    Save-RecoveryJson (Join-Path $backup 'machine-state.json') $State
    Save-RecoveryJson (Join-Path $backup 'recovery-scope.json') ([ordered]@{format=1;machine=$env:COMPUTERNAME;sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;local=$local;rooHklm=$rooHklm;stateKey=$stateKey;baselineHash=(Get-FileHash -LiteralPath (Join-Path $backup 'machine-state.json')).Hash;folders=@($folders);registry=$registry;exports=@($exports);auxiliary=@(Get-RecoveryAuxiliaryBaseline)})
}

function Get-RecoveryAuxiliaryBaseline {
    foreach($f in @(@($personalize,'EnableTransparency'),@($userEnvironment,$plantedName))){
        $path=([string]$f[0]).Replace('Registry::','');$path=$path.Replace('HKCU:\','HKEY_CURRENT_USER\');$key=Resolve-RecoveryRegistryKey $path;$item=Get-Item -LiteralPath ('Registry::'+$key) -ErrorAction SilentlyContinue
        @{key=$key;name=$f[1];before=(Get-RecoveryRegistryValue $key $f[1]);sddl=$(if($item){$item.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')}else{'<missing>'})}
    }
}
function Register-RecoveryAuxiliaryIntent([string]$Scenario) {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace
    $name=if($Scenario -in 'invalidation','migration-before'){'EnableTransparency'}elseif($Scenario -in 'launchers','launchers-session'){$plantedName}else{return}
    $f=@($s.auxiliary|Where-Object name -CEQ $name);if($f.Count -ne 1){throw 'Auxiliary typed baseline is missing'};$f=$f[0]
    Assert-RecoveryEqual @($f.before) @(Get-RecoveryRegistryValue $f.key $f.name) 'auxiliary drift before scenario'
    $value=if($name -ceq $plantedName){$plantedValue}else{if($f.before -cne '<missing>' -and [string](($f.before|ConvertFrom-Json).value) -ceq '0'){1}else{0}}
    $kind=if($name -ceq $plantedName){'String'}else{'DWord'}
    $expected=ConvertTo-Json -InputObject ([ordered]@{key=$f.key;name=$f.name;kind=$kind;value=$value}) -Depth 10 -Compress
    $file=Join-Path $d ('auxiliary-'+$name+'.json');if(Test-Path -LiteralPath $file){$r=Read-RecoveryJson $file;if($r.expected -cne $expected -or $r.before -cne $f.before){throw 'Auxiliary intent differs'};return}
    Save-RecoveryJson $file @{key=$f.key;name=$f.name;before=$f.before;expected=$expected;scenario=$Scenario}
}
function Get-RecoveryAuxiliaryPlans {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace
    foreach($f in @($s.auxiliary)){
        $key=Get-Item -LiteralPath ('Registry::'+$f.key) -ErrorAction SilentlyContinue;$sddl=if($key){$key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')}else{'<missing>'};if($sddl -cne $f.sddl){throw 'Auxiliary key presence or permissions drifted'}
        $live=Get-RecoveryRegistryValue $f.key $f.name;if($live -ceq $f.before){continue}
        $file=Join-Path $d ('auxiliary-'+$f.name+'.json');if(-not(Test-Path -LiteralPath $file)){throw 'Changed auxiliary field has no exact pre-action intent'}
        $r=Read-RecoveryJson $file;if($r.key -cne $f.key -or $r.name -cne $f.name -or $r.before -cne $f.before -or $r.expected -cne $live){throw 'Unknown auxiliary field change retained'}
        [pscustomobject]@{identity=[pscustomobject]@{key=$f.key;name=$f.name};original=@($f.before);expected=@($live)}
    }
}
function Restore-RecoveryAuxiliaryFields {
    $plans=@(Get-RecoveryAuxiliaryPlans)
    foreach($p in $plans){Restore-RecoveryRegistryField $p}
}

function Read-RecoveryScope {
    Assert-RecoveryEvidenceParent
    Assert-SealedRecovery $backup
    $s=Get-Content -LiteralPath (Join-Path $backup 'recovery-scope.json') -Raw -ErrorAction Stop|ConvertFrom-Json
    $required='format','machine','sid','local','rooHklm','stateKey','baselineHash','folders','registry','exports','auxiliary'
    if(@($required|Where-Object {$s.PSObject.Properties.Name -notcontains $_}).Count){throw 'Recovery scope is incomplete'}
    if($s.format -ne 1 -or $s.machine -cne $env:COMPUTERNAME -or $s.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $s.local -cne $local -or $s.rooHklm -cne $rooHklm -or $s.stateKey -cne $stateKey){throw 'Recovery scope identity is invalid'}
    if((Get-FileHash -LiteralPath (Join-Path $backup 'machine-state.json')).Hash -cne $s.baselineHash){throw 'Baseline machine state changed'}
    $exportNames=@($s.exports.file)
    foreach($pair in @(@('rooHklmFingerprint','hklm-roo-industries.reg'),@('tweakStateKey','tweak-state.reg'))){$b=Read-RecoveryJson (Join-Path $backup 'machine-state.json');if($b.($pair[0]) -ne '<absent>' -and $exportNames -notcontains $pair[1]){throw 'Baseline registry export record is missing'}}
    foreach($e in $s.exports){if($e.file -cnotin 'hklm-roo-industries.reg','tweak-state.reg'){throw 'Unknown baseline export identity'};if((Get-FileHash -LiteralPath (Join-Path $backup $e.file) -ErrorAction Stop).Hash -cne $e.hash){throw 'Baseline registry export changed'}}
    if(@($s.folders).Count -ne 3 -or @($s.folders.name|Sort-Object -Unique).Count -ne 3 -or @(Get-RecoveryNames|Where-Object {$s.folders.name -notcontains $_}).Count){throw 'Recovery folder scope is incomplete'}
    foreach($f in $s.folders){if(-not @($f.expected).Count){throw 'Baseline folder fingerprint is missing'}}
    return $s
}
function Resolve-RecoveryRegistryKey([string]$Key) {
    if($Key.StartsWith('HKLM\',[StringComparison]::OrdinalIgnoreCase)){return 'HKEY_LOCAL_MACHINE\'+$Key.Substring(5)}
    if($Key.StartsWith('HKCU\',[StringComparison]::OrdinalIgnoreCase)){return 'HKEY_CURRENT_USER\'+$Key.Substring(5)}
    return $Key
}
function Get-RecoveryRegistryHandleValue($Key,[string]$Name) {
    if($Key.GetValueNames() -cnotcontains $Name){return '<missing>'}
    [ordered]@{key=$Key.Name;name=$Name;kind=[string]$Key.GetValueKind($Name);value=$Key.GetValue($Name,$null,'DoNotExpandEnvironmentNames')}|ConvertTo-Json -Depth 10 -Compress
}
function Get-RecoveryRegistryValue([string]$Key,[string]$Name) {
    $Key=Resolve-RecoveryRegistryKey $Key
    $p='Registry::'+$Key
    if(-not(Test-Path -LiteralPath $p)){return '<missing>'}
    Get-RecoveryRegistryHandleValue (Get-Item -LiteralPath $p -ErrorAction Stop) $Name
}
function Assert-RecoveryRegistryIdentity($Identity,$Scope) {
    if(-not $Identity.key -or -not $Identity.name){throw 'Registry receipt lacks exact field identity'}
    $key=[string]$Identity.key;$name=[string]$Identity.name
    if($key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\Tweaks\'+$Scope.sid)) -and $name -ceq 'State'){return}
    if($key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\BootMarker')) -and $name -ceq 'Id'){return}
    if($key -ceq (Resolve-RecoveryRegistryKey $markerKey) -and $name -cin @(Get-RecoveryMarkerNames)){return}
    throw 'Registry receipt is outside exact current-user product fields'
}
function Read-RecoveryReceipts($Scope) {
    $rows=@(Get-ChildItem -LiteralPath (Get-RecoveryWorkspace) -Filter 'owned-mutation-*.json' -ErrorAction Stop|Sort-Object Name|ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json})
    foreach($r in $rows){if($r.phase -notin 'fixture','validators','installed','data-secure','install-old','upgrade','scenario','uninstall'){throw 'Mutation receipt has an invalid phase'};if($r.kind -ceq 'folder'){if((Get-RecoveryNames) -cnotcontains $r.identity){throw 'Mutation receipt has an invalid folder'}}elseif($r.kind -ceq 'registry'){Assert-RecoveryRegistryIdentity $r.identity $Scope}else{throw 'Mutation receipt has an invalid kind'}}
    return $rows
}
function Register-RecoveryMutation([string]$Kind,$Identity,$Before,$After,[string]$AuthorizedPhase) {
    $s=Read-RecoveryScope
    if($AuthorizedPhase -notin 'fixture','validators','installed','data-secure','install-old','upgrade','scenario','uninstall'){throw 'No authorized mutation phase'}
    if(Test-Path -LiteralPath (Join-Path (Get-RecoveryWorkspace) 'restore-journal.json')){throw 'Recovery already started'}
    $receipts=@(Read-RecoveryReceipts $s)
    if($Kind -ceq 'folder'){
        if((Get-RecoveryNames) -cnotcontains $Identity){throw 'Mutation receipt has an invalid folder'}
        $entry=@($s.folders|Where-Object name -CEQ $Identity)[0];$expected=@($entry.expected)
        foreach($r in $receipts|Where-Object {$_.kind -ceq 'folder' -and $_.identity -ceq $Identity}){Assert-RecoveryEqual $expected @($r.before) 'mutation receipt chain';$expected=@($r.after)}
        $actual=@(Get-TreeFingerprint (Join-Path $local $Identity))
    }elseif($Kind -ceq 'registry'){
        Assert-RecoveryRegistryIdentity $Identity $s
        $row=@($s.registry|Where-Object {$_.key -ceq $Identity.key -and $_.name -ceq $Identity.name})
        $expected=if($row.Count){@($row[0]|ConvertTo-Json -Depth 10 -Compress)}else{@('<missing>')}
        foreach($r in $receipts|Where-Object {$_.kind -ceq 'registry' -and $_.identity.key -ceq $Identity.key -and $_.identity.name -ceq $Identity.name}){Assert-RecoveryEqual $expected @($r.before) 'registry receipt chain';$expected=@($r.after)}
        $actual=@(Get-RecoveryRegistryValue $Identity.key $Identity.name)
    }else{throw 'Mutation receipt has an invalid kind'}
    Assert-RecoveryEqual $expected @($Before) 'owned mutation previous state'
    Assert-RecoveryEqual @($After) $actual 'owned mutation result'
    Save-RecoveryJson (Join-Path (Get-RecoveryWorkspace) ('owned-mutation-'+($receipts.Count.ToString('D6'))+'.json')) @{kind=$Kind;identity=$Identity;phase=$AuthorizedPhase;before=@($Before);after=@($After)}
}
function Get-RecoveryRegistryPlan($Scope,$Receipts) {
    $changes=@{}
    foreach($r in $Receipts|Where-Object kind -CEQ 'registry'){
        $id=$r.identity.key+'|'+$r.identity.name
        if(-not $changes.ContainsKey($id)){$row=@($Scope.registry|Where-Object {$_.key -ceq $r.identity.key -and $_.name -ceq $r.identity.name});$original=if($row.Count){@($row[0]|ConvertTo-Json -Depth 10 -Compress)}else{@('<missing>')};$changes[$id]=[pscustomobject]@{identity=$r.identity;original=@($original);expected=@($original)}}
        Assert-RecoveryEqual $changes[$id].expected @($r.before) 'registry mutation chain';$changes[$id].expected=@($r.after)
    }
    foreach($row in $Scope.registry){
        if($row.kind -ceq '<key>'){if(-not(Test-Path -LiteralPath ('Registry::'+$row.key)) -or (Get-Item -LiteralPath ('Registry::'+$row.key)).GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group') -cne [string]$row.value){throw 'Baseline registry key ACL changed'};continue}
        $id=$row.key+'|'+$row.name
        $expected=if($changes.ContainsKey($id)){$changes[$id].expected}else{@($row|ConvertTo-Json -Depth 10 -Compress)}
        Assert-RecoveryEqual $expected @(Get-RecoveryRegistryValue $row.key $row.name) ('unowned registry change '+$id)
    }
    $current=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    foreach($row in $current){
        if($row.kind -ceq '<key>'){continue}
        $inScope=$row.key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\Tweaks\'+$Scope.sid))
        if($row.key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\BootMarker'))){$inScope=$true};if($row.key -ceq (Resolve-RecoveryRegistryKey $markerKey) -and $row.name -cin @(Get-RecoveryMarkerNames)){$inScope=$true}
        if($inScope -and -not @($Scope.registry|Where-Object {$_.key -ceq $row.key -and $_.name -ceq $row.name}).Count -and -not $changes.ContainsKey(($row.key+'|'+$row.name))){throw ('Unowned new registry field: '+$row.key+' '+$row.name)}
    }
    foreach($c in $changes.Values){Assert-RecoveryEqual $c.expected @(Get-RecoveryRegistryValue $c.identity.key $c.identity.name) 'owned registry drift'}
    @($changes.Values|Sort-Object {$_.identity.key+'|'+$_.identity.name})
}
function Restore-RecoveryRegistryField($Plan) {
    $key=$Plan.identity.key;$name=$Plan.identity.name
    Assert-RecoveryEqual $Plan.expected @(Get-RecoveryRegistryValue $key $name) 'registry changed immediately before mutation'
    $separator=$key.IndexOf([char]'\')
    if($separator -lt 1){throw 'Registry field has an invalid hive path'}
    $hive=switch($key.Substring(0,$separator)){'HKEY_LOCAL_MACHINE'{[Microsoft.Win32.Registry]::LocalMachine};'HKEY_CURRENT_USER'{[Microsoft.Win32.Registry]::CurrentUser};default{throw 'Unsupported registry hive'}}
    $k=$hive.OpenSubKey($key.Substring($separator+1),$true)
    if(-not $k){throw 'Registry key disappeared before restoration'}
    if($k.Name -cne $key){$k.Dispose();throw 'Opened registry key does not match the recorded identity'}
    try {
    Assert-RecoveryEqual $Plan.expected @(Get-RecoveryRegistryHandleValue $k $name) 'opened registry value changed immediately before mutation'
    if(@($Plan.original)[0] -ceq '<missing>'){$k.DeleteValue($name,$false)}else{
        $row=@($Plan.original)[0]|ConvertFrom-Json
        $kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$row.kind,$false)
        $value=switch($row.kind){'Binary'{,[byte[]]$row.value};'DWord'{[int]$row.value};'QWord'{[long]$row.value};'MultiString'{,[string[]]$row.value};'String'{[string]$row.value};'ExpandString'{[string]$row.value};'None'{,[byte[]]$row.value};default{throw 'Unknown registry value kind'}}
        $k.SetValue($name,$value,$kind)
    }
    } finally {$k.Dispose()}
    Assert-RecoveryEqual $Plan.original @(Get-RecoveryRegistryValue $key $name) 'restored registry field'
}

function Restore-RecoveryDescriptors($Rows,[string]$TargetPath,[switch]$Seal) {
    foreach($r in $Rows){
        $sddl=if($Seal){'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;RC;;;OW)'}else{[string]$r.sddl}
        if(-not $Seal -and $r.descriptor){$bytes=[Convert]::FromBase64String([string]$r.descriptor)}else{$raw=[Security.AccessControl.RawSecurityDescriptor]::new($sddl);if(-not $Seal){$raw.SetFlags([Security.AccessControl.ControlFlags][int]$r.control)};$bytes=New-Object byte[] $raw.BinaryLength;$raw.GetBinaryForm($bytes,0)}
        $info=if($Seal){[uint32]2147483655}else{[uint32]7}
        if(-not[RooVerificationRecovery.Native]::Exact((ConvertTo-RecoveryNativePath ($TargetPath+$r.relative)),$info,$bytes)){throw ('Native descriptor restore failed: '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
    }
}
function Restore-Folder([string]$Name,$Plan) {
    if($null -eq $Plan){throw 'Folder restoration requires a verified complete recovery plan'}
    $p=Join-Path $local $Name
    if($Plan.stage){Assert-RecoveryEqual @($Plan.original) @(Get-TreeFingerprint $Plan.stage) 'stage changed immediately before activation'}
    Assert-RecoveryEqual @($Plan.live) @(Get-TreeFingerprint $p) 'live changed immediately before mutation'
    if($Plan.live[0] -cne '<missing>'){
        $q=Join-Path (Get-RecoveryWorkspace) ('quarantine-'+$Name)
        if([IO.Path]::GetPathRoot($p) -cne [IO.Path]::GetPathRoot($q)){$q=$p+'.roo-industries-quarantine-'+(Split-Path (Get-RecoveryWorkspace) -Leaf)}
        if(Test-Path -LiteralPath $q){throw 'Quarantine already exists'}
        [IO.Directory]::Move((ConvertTo-RecoveryNativePath $p),(ConvertTo-RecoveryNativePath $q))
        $rows=@($Plan.live|ForEach-Object {$_|ConvertFrom-Json})
        Restore-RecoveryDescriptors $rows $q
        Assert-RecoveryEqual @($Plan.live) @(Get-TreeFingerprint $q) 'quarantine identity after raw descriptor repair'
        Restore-RecoveryDescriptors $rows $q -Seal
        Assert-SealedRecovery $q
        Log ('Retained original live tree at '+$q+'; immutable source ACLs are in the as-now manifest')
    }
    if($Plan.stage){
        [IO.Directory]::Move((ConvertTo-RecoveryNativePath $Plan.stage),(ConvertTo-RecoveryNativePath $p))
        Restore-RecoveryDescriptors @($Plan.original|ForEach-Object {$_|ConvertFrom-Json}) $p
        Assert-RecoveryEqual @($Plan.original) @(Get-TreeFingerprint $p) 'restored baseline'
    }
}
function Prepare-RecoveryPlan {
    $s=Read-RecoveryScope
    $workspace=Get-RecoveryWorkspace
    if($workspace -cne $backup -and -not(Test-Path -LiteralPath (Join-Path $workspace 'closed.json'))){throw 'Epoch contract must close before activation planning'}
    $journal=Join-Path $workspace 'restore-journal.json'
    if(Test-Path -LiteralPath $journal){throw 'Recovery journal already exists; inspect retained evidence before resuming'}
    $expected=@{};foreach($f in $s.folders){$expected[$f.name]=@($f.expected)}
    $receipts=@(Read-RecoveryReceipts $s)
    foreach($r in $receipts|Where-Object kind -CEQ 'folder'){
        Assert-RecoveryEqual $expected[$r.identity] @($r.before) 'owned mutation chain';$expected[$r.identity]=@($r.after)
    }
    $registryPlans=@(Get-RecoveryRegistryPlan $s $receipts)
    $auxiliaryPlans=@(Get-RecoveryAuxiliaryPlans)
    Prepare-RecoveryStage
    $companions=@();$d=Get-RecoveryWorkspace
    if($d -cne $backup){$lease=Read-RecoveryJson (Join-Path $d 'lease.json');$companions=@(Get-RecoveryCompanions $s $lease);$ci=0;foreach($c in $companions){Copy-VerifiedTree $c.path (Join-Path $d ('asnow-companion-'+($ci++).ToString('D6'))) -SealTarget|Out-Null}}
    $plans=foreach($f in $s.folders){
        $p=Join-Path $local $f.name;$live=@(Get-TreeFingerprint $p)
        Assert-RecoveryEqual $expected[$f.name] $live ('unowned live change '+$f.name)
        $original=@($f.expected);$stage=$null
        if($original[0] -cne '<missing>'){
            $saved=Join-Path $backup $f.name;$rows=@(Read-RecoveryJson ($saved+'.manifest.json'))
            Assert-RecoveryEqual $original (Recovery-Lines $rows) 'original manifest'
            $stage=Get-RecoveryStagePath $f.name
            Assert-RecoveryEqual $original @(Get-TreeFingerprint $stage) 'prepared rollback stage'
        }
        if($live[0] -cne '<missing>'){Copy-VerifiedTree $p (Join-Path (Get-RecoveryWorkspace) ('asnow-'+$f.name)) -SealTarget|Out-Null}
        [pscustomobject]@{name=$f.name;live=$live;original=$original;stage=$stage}
    }
    foreach($plan in $plans){Assert-RecoveryEqual @($plan.live) @(Get-TreeFingerprint (Join-Path $local $plan.name)) 'live drift after staging'}
    $current=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    Save-RecoveryJson (Join-Path (Get-RecoveryWorkspace) 'registry-asnow.json') $current
    Save-RecoveryJson $journal @{phase='staged';plans=@($plans);registry=$current;registryPlans=$registryPlans;auxiliaryPlans=$auxiliaryPlans;auxiliary=@(Get-RecoveryAuxiliaryBaseline);companions=$companions;atUtc=[DateTime]::UtcNow.ToString('o')}
    $script:PreparedRecoveryPlan=[pscustomobject]@{scope=$s;receipts=$receipts;folders=@($plans);registry=$registryPlans;auxiliary=$auxiliaryPlans;companions=$companions;journalHash=(Get-FileHash -LiteralPath $journal).Hash}
    return $script:PreparedRecoveryPlan
}
function Restore-AppData($PreparedPlan=$null) {
    if($null -eq $PreparedPlan){$PreparedPlan=Prepare-RecoveryPlan}
    if(-not [object]::ReferenceEquals($PreparedPlan,$script:PreparedRecoveryPlan)){throw 'Recovery activation requires the plan prepared in this invocation'}
    Read-RecoveryScope|Out-Null
    $journal=Join-Path (Get-RecoveryWorkspace) 'restore-journal.json'
    if((Get-FileHash -LiteralPath $journal).Hash -cne $PreparedPlan.journalHash){throw 'Prepared recovery journal changed'}
    Get-RecoveryRegistryPlan $PreparedPlan.scope $PreparedPlan.receipts|Out-Null
    foreach($c in @($PreparedPlan.companions)){Assert-RecoveryEqual @($c.live) @(Get-TreeFingerprint $c.path) 'companion drift before activation'}
    foreach($plan in @($PreparedPlan.auxiliary)){Assert-RecoveryEqual @($plan.expected) @(Get-RecoveryRegistryValue $plan.identity.key $plan.identity.name) 'auxiliary drift before activation'}
    foreach($plan in $PreparedPlan.folders){Restore-Folder $plan.name $plan}
    Restore-RecoveryCompanions $PreparedPlan
    foreach($plan in $PreparedPlan.registry){Restore-RecoveryRegistryField $plan}
    foreach($plan in @($PreparedPlan.auxiliary)){Restore-RecoveryRegistryField $plan}
    Remove-RecoveryEmptyKeys $PreparedPlan.scope
    Save-RecoveryJson (Join-Path (Get-RecoveryWorkspace) 'restore-complete.json') @{phase='complete';atUtc=[DateTime]::UtcNow.ToString('o')}
    $script:PreparedRecoveryPlan=$null
    Log ('Recovery complete; baseline, as-now copies, quarantine and journal retained at '+$backup)
}

function Get-RecoveryWorkspace {
    if($script:epochDir){Assert-SealedRecovery $script:epochDir;return $script:epochDir}
    $open=@(Get-ChildItem -LiteralPath $backup -Directory -Filter 'epoch-*' -ErrorAction Stop|Where-Object {(Test-Path -LiteralPath (Join-Path $_.FullName 'lease.json')) -and -not(Test-Path -LiteralPath (Join-Path $_.FullName 'restore-complete.json'))})
    if($open.Count -gt 1){throw 'Multiple incomplete recovery epochs'}
    if($open.Count){$script:epochDir=$open[0].FullName;Assert-SealedRecovery $script:epochDir;return $script:epochDir}
    return $backup
}
function Require-RecoveryEpoch([string]$Label) {
    $d=Get-RecoveryWorkspace
    if($d -ceq $backup -or (Test-Path -LiteralPath (Join-Path $d 'restore-complete.json'))){throw 'An incomplete recovery epoch is required'}
    $lease=Read-RecoveryJson (Join-Path $d 'lease.json')
    if($lease.label -cne $Label){throw 'Wrong recovery epoch for this phase'}
    if(Test-Path -LiteralPath (Join-Path $d 'restore-journal.json')){throw 'Activation already started; inspect retained recovery evidence'}
    return $lease
}
function Open-RecoveryEpoch([ValidateSet('validators','installed')][string]$Label,[scriptblock]$AssertIdle={Assert-RecoveryIdle}) {
    $s=Read-RecoveryScope
    foreach($e in @(Get-ChildItem -LiteralPath $backup -Directory -Filter 'epoch-*')){if(-not(Test-Path -LiteralPath (Join-Path $e.FullName 'restore-complete.json'))){throw 'An earlier recovery epoch is incomplete'}}
    if(Test-Path -LiteralPath (Join-Path $backup 'restore-journal.json')){throw 'Legacy recovery journal cannot be adopted into epochs'}
    $script:epochDir=$null
    $d=Join-Path $backup ('epoch-'+$Label)
    if(Test-Path -LiteralPath $d){throw 'Completed recovery epoch cannot be reused'}
    & $AssertIdle
    foreach($f in $s.folders){Assert-RecoveryEqual @($f.expected) @(Get-TreeFingerprint (Join-Path $local $f.name)) 'baseline drift between epochs'}
    $current=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    Assert-RecoveryEqual @($s.registry|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) @($current|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) 'registry baseline drift between epochs'
    Assert-RecoveryEqual @($s.auxiliary|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) @(Get-RecoveryAuxiliaryBaseline|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) 'auxiliary baseline drift between epochs'
    New-SealedDirectory $d
    Save-RecoveryJson (Join-Path $d 'lease.json') @{label=$Label;startUtc=[DateTime]::UtcNow.ToString('o');baselineHash=$s.baselineHash;sid=$s.sid;roots=@($s.folders.name);siblings=@(Get-ChildItem -LiteralPath $local -Force|ForEach-Object Name)}
    $script:epochDir=$d
}
function Test-RecoveryProductPath([string]$Relative,[string]$RootName) {
    $r=$Relative.TrimStart('\').Replace('/','\')
    if(-not $r){return $true}
    if($RootName -ceq 'RooIndustriesOptimizationSuite.Timer'){return $r -in 'launch.json','stop.json','session.json','worker.lock','control.lock'}
    return $r -match '^(logs|cache|tool-cache|tools|firmware|temp|settings|process-rules|operations|uninstall-claims)(\\|$)' -or $r -in 'settings.json','cleanup-exclusions.json','tweak-choices.json','.migrated'
}
function Assert-RecoveryFolderContract($Folder,$Lease) {
    $p=Join-Path $local $Folder.name;$live=@(Get-TreeFingerprint $p);$original=@($Folder.expected)
    if($Lease.label -ceq 'validators' -and $Folder.name -ceq 'RooIndustriesOptimizationSuite.Timer'){Assert-RecoveryEqual $original $live 'validators changed timer';return $live}
    $old=@{};if($original[0] -cne '<missing>'){foreach($r in $original){$v=$r|ConvertFrom-Json;$old[[string]$v.relative]=$v}}
    $now=@{};if($live[0] -cne '<missing>'){foreach($r in $live){$v=$r|ConvertFrom-Json;$now[[string]$v.relative]=$v}}
    $archived=@{};$manifest=Join-Path $p '.migrated';$inLeaseMigration=$false
    if(Test-Path -LiteralPath $manifest){if(-not$old.ContainsKey('\.migrated') -or $old['\.migrated'].sha256 -cne $now['\.migrated'].sha256){Assert-SealedRecovery $manifest;$m=Read-RecoveryJson $manifest;Assert-RecoveryMigrationManifest $m $p $Lease;$inLeaseMigration=$true;if($m.Legacy -and (Test-Path -LiteralPath $m.Legacy)){foreach($r in @(Get-TreeFingerprint $m.Legacy)){$v=$r|ConvertFrom-Json;$archived[[string]$v.relative]=$v}}}}
    foreach($r in $now.Values){if(-not $old.ContainsKey([string]$r.relative) -and -not(Test-RecoveryProductPath $r.relative $Folder.name)){throw ('Unknown new root entry '+$p+$r.relative)}}
    foreach($r in $old.Values){
        if(Test-RecoveryProductPath $r.relative $Folder.name){continue}
        if($now.ContainsKey([string]$r.relative)){$n=$now[[string]$r.relative]}elseif($archived.ContainsKey([string]$r.relative)){$n=$archived[[string]$r.relative]}else{throw ('Original non-product entry deleted '+$p+$r.relative)}
        $creationOnly=$inLeaseMigration -and ($r.directory -or (-not$n.directory -and [string]$r.length -ceq [string]$n.length -and [string]$r.sha256 -ceq [string]$n.sha256 -and [string]$r.write -ceq [string]$n.write -and [string]$r.attributes -ceq [string]$n.attributes))
        foreach($field in 'directory','length','creation','attributes','sha256'){if($field -ceq 'creation' -and $creationOnly){continue};if([string]$r.$field -cne [string]$n.$field){throw ('Original non-product entry changed '+$p+$r.relative+' '+$field)}}
        if(-not$r.directory -and $r.write -cne $n.write){throw ('Original non-product file timestamp changed '+$p+$r.relative)}
    }
    return $live
}
function Assert-RecoveryMigrationManifest($Manifest,[string]$Root,$Lease) {
    if($Manifest.Id -cnotmatch '^[a-fA-F0-9]{32}$' -or [string]$Manifest.Source -cne $Root -or -not$Manifest.Started){throw 'Migration manifest has no exact source identity'}
    $at=[DateTime]::Parse($Manifest.Started).ToUniversalTime();if($at -lt [DateTime]::Parse($Lease.startUtc).ToUniversalTime() -or $at -gt [DateTime]::UtcNow){throw 'Migration manifest is outside lease'}
    if($Manifest.Legacy){$l=[IO.Path]::GetFullPath($Manifest.Legacy);if([IO.Path]::GetDirectoryName($l) -cne $local -or [IO.Path]::GetFileName($l) -cnotmatch ('^'+[regex]::Escape([IO.Path]::GetFileName($Root))+'\.legacy-[a-fA-F0-9]{32}$') -or @($Lease.siblings) -contains [IO.Path]::GetFileName($l)){throw 'Migration legacy identity is not run-created'}}
}
function Assert-RecoveryStateContract([string]$Before,[string]$After,$Lease,$Scope) {
    if($Lease.label -ceq 'validators'){throw 'Validators cannot lease State changes'}
    if($After -ceq '<missing>'){throw 'State was deleted'}
    $row=$After|ConvertFrom-Json;if($row.kind -cne 'Binary'){throw 'State is not Binary JSON'}
    $v=[Text.Encoding]::UTF8.GetString([byte[]]$row.value)|ConvertFrom-Json
    $required='schemaVersion','context','revision','profiles','history','held','controls','createdKeys','notices'
    if($v.schemaVersion -ne 1 -or @($required|Where-Object {$v.PSObject.Properties.Name -notcontains $_}).Count -or @($v.PSObject.Properties.Name|Where-Object {$_ -notin $required}).Count){throw 'State schema is outside the recorded contract'}
    if(-not($v.revision -is [string]) -or -not$v.revision -or @($v.profiles|Group-Object id|Where-Object Count -GT 1).Count -or @($v.history|Group-Object operationId|Where-Object Count -GT 1).Count){throw 'State revision or unique identities are invalid'}
    if($v.context.owner.userSid -cne $Scope.sid -or $v.context.owner.machine -cne $env:COMPUTERNAME){throw 'State context has a foreign owner'}
    $approved='roo-industries-cache-check','roo-industries-migration-check','roo-industries-migration-timer','roo-industries-migration-blocker'
    $old=$null;if($Before -cne '<missing>'){$b=$Before|ConvertFrom-Json;if($b.kind -cne 'Binary'){throw 'Baseline State is not Binary JSON'};$old=[Text.Encoding]::UTF8.GetString([byte[]]$b.value)|ConvertFrom-Json;Assert-RecoveryEqual @((ConvertTo-Json -InputObject $old.context -Depth 100 -Compress)) @((ConvertTo-Json -InputObject $v.context -Depth 100 -Compress)) 'State context changed'}
    foreach($field in 'profiles','history','held','controls','createdKeys','notices'){
        $beforeRows=if($old){@($old.$field)}else{@()};$afterRows=@($v.$field)
        foreach($item in $beforeRows){$json=ConvertTo-Json -InputObject $item -Depth 100 -Compress;if(@($afterRows|Where-Object {(ConvertTo-Json -InputObject $_ -Depth 100 -Compress) -ceq $json}).Count -ne 1){throw ('Baseline State '+$field+' changed or deleted')}}
        $added=@($afterRows|Where-Object {$json=ConvertTo-Json -InputObject $_ -Depth 100 -Compress; -not @($beforeRows|Where-Object {(ConvertTo-Json -InputObject $_ -Depth 100 -Compress) -ceq $json}).Count})
        foreach($item in $added){
            if($field -ceq 'profiles'){if($item.id -cnotin $approved){throw 'Foreign State profile'}}
            elseif($field -ceq 'history'){if($item.profileId -cnotin $approved -or -not$item.operationId -or -not$item.atUtc){throw 'Foreign State history'};$at=[DateTime]::Parse($item.atUtc).ToUniversalTime();if($at -lt [DateTime]::Parse($Lease.startUtc).ToUniversalTime() -or $at -gt [DateTime]::UtcNow){throw 'State history outside lease'}}
            elseif($field -ceq 'held'){$targets=@($v.profiles|Where-Object id -CIn $approved|ForEach-Object {$_.claims|ForEach-Object {$_.target}});if(-not$item.original.nativeKey -or -not @($targets|Where-Object {$_.nativeKey -ceq $item.original.nativeKey -and $_.address.valueName -ceq $item.original.address.valueName}).Count){throw 'Unproven State held value'}}
            elseif($field -ceq 'controls'){$targets=@($v.profiles|Where-Object id -CIn $approved|ForEach-Object {$_.controls|ForEach-Object {$_.target}});if(-not$item.original.identity -or -not @($targets|Where-Object {$_.identity -ceq $item.original.identity -and $_.binding -ceq $item.original.binding}).Count){throw 'Unproven State held control'}}
            elseif($field -ceq 'createdKeys'){
                $keys=@($v.profiles|Where-Object id -CIn $approved|ForEach-Object {$_.claims|ForEach-Object {$_.target.nativeKey}})
                if(-not$item.nativeKey -or -not$item.metadataHash -or -not @($keys|Where-Object {$_ -ceq $item.nativeKey -or $_.StartsWith($item.nativeKey+'\',[StringComparison]::Ordinal)}).Count){throw 'Unproven State created key'}
            }
            else {throw ('Unproven State addition '+$field)}
        }
    }
}
function Get-RecoveryMarkerNames {
    foreach($n in Get-RecoveryNames){$root=(Join-Path $local $n).ToUpperInvariant();foreach($child in @('','\process-rules','\operations')){if($n -ceq 'RooIndustriesOptimizationSuite.Timer' -and $child){continue};$r=($root+$child).ToUpperInvariant();$r;$r+'|protected-at'}}
}
function Get-RecoveryOwnedKeyNames($Scope) {
    @($stateKey,($stateKey+'\Tweaks'),($stateKey+'\Tweaks\'+$Scope.sid),($stateKey+'\BootMarker'),$rooHklm,($rooHklm+'\OptimizationSuite'),($rooHklm+'\OptimizationSuite\SuspendedForMove'),$markerKey)|ForEach-Object {Resolve-RecoveryRegistryKey $_}
}
function Get-RecoveryContractChanges($Scope,$Lease) {
    $changes=[Collections.Generic.List[object]]::new()
    foreach($f in $Scope.folders){$after=@(Assert-RecoveryFolderContract $f $Lease);if(@(Compare-Object @($f.expected) $after -CaseSensitive).Count){$changes.Add(@{kind='folder';identity=$f.name;before=@($f.expected);after=$after})}}
    foreach($root in Get-RecoveryNames){if((Get-RecoveryRegistryValue ($rooHklm+'\OptimizationSuite\SuspendedForMove') (Join-Path $local $root).ToUpperInvariant()) -cne '<missing>'){throw 'Data-folder suspension remains incomplete'}}
    $pending=Get-RecoveryRegistryValue ($stateKey+'\Tweaks\'+$Scope.sid) 'Pending';if($pending -cne '<missing>'){throw 'Pending is present; incomplete operation must be recovered by its owner'}
    foreach($root in @(Get-RecoveryMarkerNames|Where-Object {-not $_.EndsWith('|protected-at')})){
        $key=Resolve-RecoveryRegistryKey $markerKey;$own=Get-RecoveryRegistryValue $key $root;$stamp=Get-RecoveryRegistryValue $key ($root+'|protected-at')
        $original=@($Scope.registry|Where-Object {$_.key -ceq $key -and $_.name -cin @($root,($root+'|protected-at')) -and $_.kind -cne '<key>'})
        $a=@($original|Where-Object name -CEQ $root);$b=@($original|Where-Object name -CEQ ($root+'|protected-at'))
        $beforeOwn=if($a.Count){ConvertTo-Json -InputObject $a[0] -Depth 30 -Compress}else{'<missing>'};$beforeStamp=if($b.Count){ConvertTo-Json -InputObject $b[0] -Depth 30 -Compress}else{'<missing>'}
        if($own -cne $beforeOwn -or $stamp -cne $beforeStamp){if($own -ceq '<missing>' -or $stamp -ceq '<missing>'){throw 'Incomplete protected root marker pair'};$o=$own|ConvertFrom-Json;$t=$stamp|ConvertFrom-Json;if($o.kind -cne 'String' -or $o.value -cne $Scope.sid -or $t.kind -cne 'QWord'){throw 'Protected root marker pair identity differs'}}
    }
    $current=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    $fields=@([pscustomobject]@{key=(Resolve-RecoveryRegistryKey ($stateKey+'\Tweaks\'+$Scope.sid));name='State'},[pscustomobject]@{key=(Resolve-RecoveryRegistryKey ($stateKey+'\BootMarker'));name='Id'})+@(Get-RecoveryMarkerNames|ForEach-Object {[pscustomobject]@{key=(Resolve-RecoveryRegistryKey $markerKey);name=$_}})
    foreach($id in $fields){$b=@($Scope.registry|Where-Object {$_.kind -cne '<key>' -and $_.key -ceq $id.key -and $_.name -ceq $id.name});$before=if($b.Count){ConvertTo-Json -InputObject $b[0] -Depth 30 -Compress}else{'<missing>'};$after=Get-RecoveryRegistryValue $id.key $id.name;if($before -ceq $after){continue}
        if($id.name -ceq 'State'){Assert-RecoveryStateContract $before $after $Lease $Scope}
        elseif($id.key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\BootMarker'))){$r=$after|ConvertFrom-Json;if($r.kind -cne 'String' -or $r.value -cnotmatch '^[a-fA-F0-9]{32}$'){throw 'BootMarker Id is invalid'}}
        else{if($before -cne '<missing>' -or $after -ceq '<missing>'){throw 'Baseline marker changed'};$r=$after|ConvertFrom-Json;if($id.name.EndsWith('|protected-at')){$at=[DateTime]::FromFileTimeUtc([long]$r.value);if($r.kind -cne 'QWord' -or $at -lt [DateTime]::Parse($Lease.startUtc).ToUniversalTime() -or $at -gt [DateTime]::UtcNow){throw 'Marker FILETIME outside lease'}}elseif($r.kind -cne 'String' -or $r.value -cne $Scope.sid){throw 'Marker SID is invalid'}}
        $changes.Add(@{kind='registry';identity=$id;before=@($before);after=@($after)})
    }
    foreach($r in $current|Where-Object kind -CNE '<key>'){if($r.key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\Tweaks\'+$Scope.sid)) -or $r.key -ceq (Resolve-RecoveryRegistryKey ($stateKey+'\BootMarker'))){if(-not @($fields|Where-Object {$_.key -ceq $r.key -and $_.name -ceq $r.name}).Count){throw 'Unknown own registry leaf'}}}
    Get-RecoveryRegistryPlan $Scope $changes.ToArray()|Out-Null
    return $changes.ToArray()
}
function Get-RecoveryStagePath([string]$Name) {
    $d=Get-RecoveryWorkspace;$sha=[Security.Cryptography.SHA256]::Create();try{$tag=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($backup).ToUpperInvariant()))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}
    return (Join-Path $local $Name)+'.roo-industries-restore-'+$tag+'-'+(Split-Path $d -Leaf)
}
function Prepare-RecoveryStage {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace;$ready=Join-Path $d 'stage-ready.json';$intent=Join-Path $d 'stage-intent.json'
    $plans=@(foreach($f in $s.folders){if(@($f.expected)[0] -ceq '<missing>'){continue};$saved=Join-Path $backup $f.name;$rows=@(Read-RecoveryJson ($saved+'.manifest.json'));Assert-RecoveryEqual @($f.expected) (Recovery-Lines $rows) 'rollback original manifest';[pscustomobject]@{name=$f.name;path=(Get-RecoveryStagePath $f.name);expected=@($f.expected);rows=$rows;saved=$saved}})
    if(Test-Path -LiteralPath $ready){$record=Read-RecoveryJson $ready;if($record.baselineHash -cne $s.baselineHash -or @($record.stages).Count -ne $plans.Count){throw 'Rollback stage receipt is invalid'};foreach($p in $plans){$prior=@($record.stages|Where-Object {$_.name -ceq $p.name -and $_.path -ceq $p.path});if($prior.Count -ne 1){throw 'Rollback stage identity differs'};Assert-RecoveryEqual @($p.expected) @($prior[0].expected) 'rollback stage receipt';Assert-RecoveryEqual @($p.expected) @(Get-TreeFingerprint $p.path) 'retry rollback stage'};return}
    if(Test-Path -LiteralPath $intent){throw 'An earlier rollback stage copy did not finish; inspect retained evidence'}
    foreach($p in $plans){if(Test-Path -LiteralPath $p.path){throw ('Unowned rollback stage retained '+$p.path)}}
    Save-RecoveryJson $intent @{baselineHash=$s.baselineHash;stages=@($plans|ForEach-Object {@{name=$_.name;path=$_.path;expected=$_.expected}})}
    foreach($p in $plans){Copy-VerifiedTree $p.saved $p.path -OriginalRows $p.rows|Out-Null}
    foreach($p in $plans){Assert-RecoveryEqual @($p.expected) @(Get-TreeFingerprint $p.path) 'rollback stage final verification'}
    Save-RecoveryJson $ready @{baselineHash=$s.baselineHash;stages=@($plans|ForEach-Object {@{name=$_.name;path=$_.path;expected=$_.expected}})}
}

function Capture-RecoveryAsNow([string]$Label) {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace;$index=@(Get-ChildItem -LiteralPath $d -Directory -Filter ($Label+'-*')).Count;$capture=Join-Path $d ($Label+'-'+$index.ToString('D6'));New-SealedDirectory $capture
    $registry=@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey)
    $auxiliary=@(Get-RecoveryAuxiliaryBaseline)
    $rows=foreach($f in $s.folders){$p=Join-Path $local $f.name;$before=@(Get-TreeFingerprint $p);if($before[0] -cne '<missing>'){Copy-VerifiedTree $p (Join-Path $capture $f.name) -SealTarget|Out-Null};@{name=$f.name;live=$before}}
    foreach($r in $rows){Assert-RecoveryEqual @($r.live) @(Get-TreeFingerprint (Join-Path $local $r.name)) 'as-now cross-tree drift'}
    Assert-RecoveryEqual @($registry|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) @((@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey))|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) 'as-now registry drift'
    $companions=@(Get-RecoveryCompanions $s (Read-RecoveryJson (Join-Path $d 'lease.json')));$ci=0;foreach($c in $companions){Copy-VerifiedTree $c.path (Join-Path $capture ('companion-'+($ci++).ToString('D6'))) -SealTarget|Out-Null}
    foreach($c in $companions){Assert-RecoveryEqual @($c.live) @(Get-TreeFingerprint $c.path) 'pre-uninstall companion drift'}
    foreach($r in $rows){Assert-RecoveryEqual @($r.live) @(Get-TreeFingerprint (Join-Path $local $r.name)) 'as-now drift after companion copies'}
    Assert-RecoveryEqual @($registry|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) @((@(Get-RecoveryRegistry $rooHklm)+@(Get-RecoveryRegistry $stateKey))|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) 'as-now registry drift after companion copies'
    Assert-RecoveryEqual @($auxiliary|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) @(Get-RecoveryAuxiliaryBaseline|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) 'auxiliary drift during as-now capture'
    Save-RecoveryJson (Join-Path $capture 'capture.json') @{folders=@($rows);registry=$registry;auxiliary=$auxiliary;companions=$companions;atUtc=[DateTime]::UtcNow.ToString('o')}
}
function Close-RecoveryEpoch {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace;$lease=Read-RecoveryJson (Join-Path $d 'lease.json');Require-RecoveryEpoch $lease.label|Out-Null
    if(Test-Path -LiteralPath (Join-Path $d 'closed.json')){throw 'Epoch already closed'}
    Get-RecoveryAuxiliaryPlans|Out-Null
    $changes=@(Get-RecoveryContractChanges $s $lease)
    foreach($c in $changes){Register-RecoveryMutation $c.kind $c.identity $c.before $c.after $lease.label}
    Get-RecoveryRegistryPlan $s @(Read-RecoveryReceipts $s)|Out-Null
    $keys=@(Get-RecoveryOwnedKeyNames $s|Where-Object {$key=$_; -not @($s.registry|Where-Object {$_.kind -ceq '<key>' -and $_.key -ceq $key}).Count -and (Test-Path -LiteralPath ('Registry::'+$key))}|ForEach-Object {@{key=$_;sddl=(Get-Item -LiteralPath ('Registry::'+$_)).GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')}})
    Save-RecoveryJson (Join-Path $d 'closed.json') @{atUtc=[DateTime]::UtcNow.ToString('o');createdKeys=$keys}
}
function Remove-RecoveryEmptyKeys($Scope) {
    $d=Get-RecoveryWorkspace;$f=Join-Path $d 'closed.json';if(-not(Test-Path -LiteralPath $f)){return}
    foreach($record in @((Read-RecoveryJson $f).createdKeys|Sort-Object {$_.key.Length} -Descending)){
        $key=[string]$record.key
        if($key -cnotin @(Get-RecoveryOwnedKeyNames $Scope)){throw 'Unowned registry key receipt'}
        $separator=$key.IndexOf([char]'\');$hive=switch($key.Substring(0,$separator)){'HKEY_LOCAL_MACHINE'{[Microsoft.Win32.Registry]::LocalMachine};'HKEY_CURRENT_USER'{[Microsoft.Win32.Registry]::CurrentUser};default{throw 'Unsupported registry hive'}}
        $last=$key.LastIndexOf([char]'\');$parent=$hive.OpenSubKey($key.Substring($separator+1,$last-$separator-1),$true);if(-not$parent){continue}
        try{if($parent.Name -cne $key.Substring(0,$last)){throw 'Opened parent registry identity differs'};$leaf=$key.Substring($last+1);$k=$parent.OpenSubKey($leaf,$true);if(-not$k){continue};try{if($k.Name -cne $key){throw 'Opened empty registry key identity differs'};$empty=$k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0;if($k.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group') -cne $record.sddl){throw 'Created key permissions drifted before empty-key cleanup'};if($empty -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0){$parent.DeleteSubKey($leaf,$false)}else{Log ('Kept foreign neighbors in '+$key)}}finally{$k.Dispose()}}finally{$parent.Dispose()}
    }
}
function Prepare-RecoveryUninstall([scriptblock]$Quiesce={Suspend-RecoveryWriters},[scriptblock]$AssertQuiescent={Assert-RecoveryIdle}) {
    $d=Get-RecoveryWorkspace;$lease=Read-RecoveryJson (Join-Path $d 'lease.json');Require-RecoveryEpoch $lease.label|Out-Null
    Get-RecoveryAuxiliaryPlans|Out-Null
    Prepare-RecoveryStage
    & $Quiesce
    & $AssertQuiescent
    Get-RecoveryContractChanges (Read-RecoveryScope) $lease|Out-Null
    Capture-RecoveryAsNow 'preuninstall'
}
function Invoke-EpochRecovery([scriptblock]$Quiesce={Suspend-RecoveryWriters},[scriptblock]$Uninstall={},[scriptblock]$AssertQuiescent={Assert-RecoveryIdle}) {
    Prepare-RecoveryUninstall $Quiesce $AssertQuiescent
    & $Uninstall
    & $AssertQuiescent
    Close-RecoveryEpoch
    $plan=Prepare-RecoveryPlan
    Restore-AppData $plan
}

function Test-RecoveryInstalledPath([string]$Path) {
    if(-not$Path){return $false}
    if($Path -notmatch '^[A-Za-z]:\\'){return $false}
    try{$full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetFullPath($app)}catch{return $false}
    return $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Get-RecoveryProcessOwner($Row) {
    $r=Invoke-CimMethod -InputObject $Row -MethodName GetOwnerSid -ErrorAction Stop
    if($r.ReturnValue -ne 0 -or -not$r.Sid){throw 'Process owner cannot be verified'}
    return [string]$r.Sid
}
function Get-RecoveryProbeIdentities {
    $p=Join-Path (Get-RecoveryWorkspace) 'scenario-migration-before-identity.json'
    if(-not(Test-Path -LiteralPath $p)){return @()}
    $r=Read-RecoveryJson $p
    if(-not$r.probeIdentity -or -not$r.probeIdentity.creationTimeFileTimeUtc -or -not$r.probeIdentity.imagePath){throw 'Native migration probe receipt is missing; retained'}
    $r.probeIdentity
}
function Test-RecoveryOwnedProcess($Row,$Scope) {
    if(Test-RecoveryInstalledPath $Row.ExecutablePath){return (Get-RecoveryProcessOwner $Row) -ceq $Scope.sid}
    foreach($probe in @(Get-RecoveryProbeIdentities)){if($Row.ProcessId -eq $probe.pid){
        $process=Get-Process -Id $probe.pid -ErrorAction SilentlyContinue;if(-not$process){return $false}
        try{$actual=New-OwnedProcess $process;if($actual.Identity.creationTimeFileTimeUtc -cne [string]$probe.creationTimeFileTimeUtc -or $actual.Identity.imagePath -ine [string]$probe.imagePath){return $false};return (Get-RecoveryProcessOwner $Row) -ceq $Scope.sid}finally{$process.Dispose()}
    }}
    return $false
}

function Get-RecoveryTaskSuffix([string]$Text,[int]$Length) {
    $sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').Substring(0,$Length)}finally{$sha.Dispose()}
}
function Test-RecoveryTaskOwnership($Task,$Scope,[string]$Xml,[string]$Sddl) {
    if(@($baseline.tasks) -contains ($Task.TaskPath+$Task.TaskName)){return $false}
    $account=[string]$Task.Principal.UserId
    try{$owner=if($account -match '^S-'){$account}else{([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value}}catch{return $false}
    if($owner -cne $Scope.sid){return $false}
    if($Task.TaskPath -cne '\' -or @($Task.Actions).Count -ne 1 -or [string]$Task.Principal.LogonType -cne 'Interactive'){return $false}
    foreach($action in @($Task.Actions)){
        $parts=@([string]$Task.Description -split ' \| ');$root=if($parts.Count -eq 3){$parts[2]}else{''};$exe='';$mode=''
        if($parts.Count -eq 3 -and $parts[1] -ceq $Scope.sid -and [string]$Task.Principal.RunLevel -ceq 'Highest'){
            if($Task.TaskName -cmatch '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.ProcessRules\.[0-9A-F]{20}$' -and $parts[0] -cin @('Roo Industries process rules','Roo process rules') -and $root -iin @(Get-RecoveryNames|ForEach-Object {Join-Path (Join-Path $local $_) 'process-rules'})){$exe=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe';$mode='policy-run'}
            elseif($Task.TaskName -cmatch '^(Roo Industries Protected Session |Roo Protected Session )[0-9A-F]{16}$' -and $parts[0] -cin @('Roo Industries protected game session','Roo protected game session')){foreach($n in Get-RecoveryNames){$prefix=(Join-Path (Join-Path $local $n) 'operations')+'\';if($root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and $root.Substring($prefix.Length) -cmatch '^game-session-[a-fA-F0-9]{32}\\session$'){$exe=Join-Path $app 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe';$mode='run'}}}
        }
        if($exe){$suffix=if($mode -ceq 'policy-run'){Get-RecoveryTaskSuffix ($Scope.sid+'|'+$root.ToUpperInvariant()) 20}else{Get-RecoveryTaskSuffix $root.ToLowerInvariant() 16};if(-not $Task.TaskName.EndsWith($suffix,[StringComparison]::Ordinal)){$exe=''}}
        if($exe -and [string]::Equals([string]$action.WorkingDirectory,(Split-Path $exe -Parent),[StringComparison]::OrdinalIgnoreCase)){
            $request=Join-Path $root 'worker-request.json';$windows=[Environment]::GetFolderPath('Windows');$launcher=Join-Path $app 'backend\scripts\Start-RooIndustriesHelper.cmd'
            if(($launcher+$exe+$request) -notmatch '["?^*<>|\r\n]' -and @((($windows+$launcher+$exe+$request) -split '%')).Count -le 2){
                foreach($system in @((Join-Path $windows 'System32'),(Join-Path $windows 'Sysnative'))){foreach($prefix in @(('/d /e:on /v:off /c set "SystemRoot='+$windows+'"&call '),'/d /v:off /c call ')){
                    $expected='--headless "'+$system+'\cmd.exe" '+$prefix+'"'+$launcher+'" " ?'+$exe+'?'+$mode+'?'+$request+'"'
                    $arguments=[string]$action.Arguments;$token='?'+$mode+'?';$tokenIndex=$expected.IndexOf($token,[StringComparison]::Ordinal)
                    if([string]::Equals([string]$action.Execute,(Join-Path $system 'conhost.exe'),[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($arguments,$expected,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($arguments.Substring($tokenIndex,$token.Length),$token,[StringComparison]::Ordinal)){return $true}
                }}
            }
            if([string]::Equals([string]$action.Execute,$exe,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$action.Arguments,($mode+' "'+$request+'"'),[StringComparison]::OrdinalIgnoreCase) -and ([string]$action.Arguments).StartsWith($mode+' ',[StringComparison]::Ordinal)){return $true}
        }
        foreach($n in Get-RecoveryNames){$control=Join-Path (Join-Path $local $n) 'operations\windows-timer';$script=Join-Path $control 'startup.ps1';$receipt=Join-Path $control 'startup.json';if(-not(Test-Path -LiteralPath $receipt) -or -not(Test-Path -LiteralPath $script)){continue}
            if(-not([string]$action.Arguments).Contains('"'+$script+'"')){continue}
            try{Assert-SealedRecovery $receipt;Assert-SealedRecovery $script}catch{continue}
            $r=Read-RecoveryJson $receipt;$scriptHash=(Get-FileHash -LiteralPath $script).Hash;$receiptScriptHash=[string]$r.scriptHash
            if($r.owner.userSid -cne $Scope.sid -or $r.owner.machine -cne $env:COMPUTERNAME -or $r.taskName -cne $Task.TaskName -or $r.phase -cne 'created' -or $scriptHash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or $receiptScriptHash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or -not [string]::Equals($scriptHash,$receiptScriptHash,[StringComparison]::OrdinalIgnoreCase)){continue}
            Add-Type -AssemblyName System.Xml.Linq
            $x=[System.Xml.Linq.XDocument]::Parse($Xml);$ns=$x.Root.Name.Namespace;$enabled=$x.Root.Element($ns+'Settings').Element($ns+'Enabled');if($enabled){$enabled.Remove()}
            $bytes=[Text.Encoding]::UTF8.GetBytes($x.ToString([System.Xml.Linq.SaveOptions]::DisableFormatting)+"`n"+$Sddl);$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            $receiptDefinitionHash=[string]$r.definitionHash
            if($hash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or $receiptDefinitionHash -cnotmatch '\A[0-9A-Fa-f]{64}\z' -or -not [string]::Equals($hash,$receiptDefinitionHash,[StringComparison]::OrdinalIgnoreCase)){continue}
            $text=[IO.File]::ReadAllText($script);if($text.Contains("& '"+$app+'\')){return $true}
        }
    }
    return $false
}
function Get-RecoveryTasks($Scope) {
    $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect()
    try{foreach($task in @(Get-ScheduledTask -ErrorAction Stop)){
        if($task.TaskPath -cne '\'){continue}
        $registered=$scheduler.GetFolder($task.TaskPath).GetTask($task.TaskName)
        try{$xml=[string]$registered.Xml;$sddl=[string]$registered.GetSecurityDescriptor(7);if(Test-RecoveryTaskOwnership $task $Scope $xml $sddl){[pscustomobject]@{task=$task;xml=$xml;sddl=$sddl;enabled=[bool]$registered.Enabled}}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($registered)}
    }}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($scheduler)}
}
function Test-RecoveryPotentialTaskWriter($Task) {
    foreach($action in @($Task.Actions)){
        if(Test-RecoveryInstalledPath ([string]$action.Execute)){return $true}
        foreach($match in [regex]::Matches([string]$action.Arguments,'"([A-Za-z]:\\[^"\r\n]+)"')){if(Test-RecoveryInstalledPath $match.Groups[1].Value){return $true}}
        if(([string]$action.Arguments).IndexOf($app+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0){return $true}
        foreach($n in Get-RecoveryNames){if(([string]$action.Arguments).IndexOf((Join-Path (Join-Path $local $n) 'operations\windows-timer\startup.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0){return $true}}
    }
    return $false
}
function Assert-RecoveryIdle {
    $s=Read-RecoveryScope
    foreach($row in @(Get-CimInstance Win32_Process -ErrorAction Stop)){if($row.Name -in 'RooIndustries.OptimizationSuite.App.exe','RooOptimizationSuite.App.exe' -or (Test-RecoveryInstalledPath $row.ExecutablePath) -or (Test-RecoveryOwnedProcess $row $s)){throw ('Installed or probe writer is still running; retained pid '+$row.ProcessId)}}
    foreach($task in @(Get-ScheduledTask -ErrorAction Stop)){if([string]$task.State -ne 'Disabled' -and (Test-RecoveryPotentialTaskWriter $task)){throw ('Potential installed writer task remains enabled or running; retained '+$task.TaskPath+$task.TaskName)}}
    foreach($row in @(Get-RecoveryTasks $s)){if($row.enabled -or [string]$row.task.State -eq 'Running'){throw ('Run-owned task is still able to write '+$row.task.TaskName)}}
}
function Suspend-RecoveryWriters {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace;$attempt=@(Get-ChildItem -LiteralPath $d -Filter 'quiesce-*.json').Count
    $tasks=@(Get-RecoveryTasks $s);$processes=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {Test-RecoveryOwnedProcess $_ $s})
    Save-RecoveryJson (Join-Path $d ('quiesce-'+$attempt.ToString('D6')+'.json')) @{tasks=@($tasks|ForEach-Object {@{name=$_.task.TaskName;path=$_.task.TaskPath;xml=$_.xml;sddl=$_.sddl;enabled=$_.enabled}});processes=@($processes|ForEach-Object {@{pid=$_.ProcessId;created=$_.CreationDate.ToUniversalTime().ToString('o');image=$_.ExecutablePath;commandLine=$_.CommandLine;sid=$s.sid}})}
    foreach($row in $tasks){$now=@(Get-RecoveryTasks $s|Where-Object {$_.task.TaskName -ceq $row.task.TaskName -and $_.task.TaskPath -ceq $row.task.TaskPath});if($now.Count -ne 1 -or $now[0].xml -cne $row.xml -or $now[0].sddl -cne $row.sddl){throw 'Task changed before quiescence'};Disable-ScheduledTask -InputObject $now[0].task|Out-Null;Stop-ScheduledTask -InputObject $now[0].task}
    foreach($row in $processes){if(Test-RecoveryInstalledPath $row.ExecutablePath){Stop-ProcessRow $row}else{$probe=@(Get-RecoveryProbeIdentities|Where-Object pid -EQ $row.ProcessId);if($probe.Count -ne 1){throw 'Exact native probe identity is missing'};Stop-OwnedProcessIdentity $probe[0]}}
}
function Invoke-VerifiedUninstall {
    $result=Uninstall-App;Log ('uninstall: '+$result)
    if($result -cne 'not installed' -and $result -notmatch '^exit=0 appLeft=False$'){throw ('Uninstall failed; pre-uninstall evidence and rollback stages retained: '+$result)}
    if(Test-Path -LiteralPath (Join-Path $app 'app')){throw 'Installed app remains after uninstall'}
    Assert-RecoveryIdle
    Remove-RecoveryOwnedTasks
}
function Invoke-RecoveryUninstall {
    Require-RecoveryEpoch 'installed'|Out-Null
    Prepare-RecoveryUninstall
    Invoke-VerifiedUninstall
}

function Retain-RecoveryRemnants {
    $d=Get-RecoveryWorkspace;$artifact=Join-Path $d 'scenario-migration-before-identity.json'
    if(Test-Path -LiteralPath $artifact){$r=Read-RecoveryJson $artifact;foreach($field in 'statePath','image'){$path=[string]$r.$field;if(-not(Test-Path -LiteralPath $path)){continue};$expected=if($field -ceq 'statePath'){$r.stateHash}else{$r.imageHash};if($field -ceq 'image'){$file=Open-OwnedProbe $r.probeFileIdentity;$file.Dispose()};Move-RecoveryOwnedFile $path $expected ([IO.Path]::GetFileName($path))}}
    foreach($path in @((Join-Path $env:TEMP 'roo-industries-migration-state.json'),(Join-Path $env:TEMP 'RooIndustriesMigrationProbe.exe'),(Join-Path $env:TEMP 'roo-industries-governor-installed'))){if(Test-Path -LiteralPath $path){throw ('Unproven remnant retained at '+$path+'; exact immutable action evidence is required')}}
}

function Get-RecoveryCompanions($Scope,$Lease) {
    foreach($f in $Scope.folders){$root=Join-Path $local $f.name;$manifest=Join-Path $root '.migrated'
        $pattern='^'+[regex]::Escape($f.name)+'\.(untrusted|legacy)-[a-fA-F0-9]{32}$'
        $new=@(Get-ChildItem -LiteralPath $local -Force -ErrorAction Stop|Where-Object {$_.Name -cmatch $pattern -and @($Lease.siblings) -cnotcontains $_.Name})
        if(-not(Test-Path -LiteralPath $manifest)){if($new.Count){Log ('Kept migration companions for '+$root+': missing manifest')|Out-Null};continue}
        $original=@($f.expected|Where-Object {$_ -cne '<missing>'}|ForEach-Object {$_|ConvertFrom-Json}|Where-Object relative -CEQ '\.migrated')
        if($original.Count -and $original[0].sha256 -ceq (Get-FileHash -LiteralPath $manifest).Hash){if($new.Count){Log ('Kept migration companions for '+$root+': manifest is unchanged from baseline')|Out-Null};continue}
        Assert-SealedRecovery $manifest
        $m=Read-RecoveryJson $manifest;Assert-RecoveryMigrationManifest $m $root $Lease
        if($m.Legacy -and (Test-Path -LiteralPath $m.Legacy)){[pscustomobject]@{name=[IO.Path]::GetFileName($m.Legacy);path=[string]$m.Legacy;root=$root;manifestHash=(Get-FileHash -LiteralPath $manifest).Hash;live=@(Get-TreeFingerprint $m.Legacy)};continue}
        try {
            if(-not$m.Legacy){throw 'Manifest has no absent legacy source'}
            if($new.Count -ne 1 -or $new[0].Name -cnotmatch ('^'+[regex]::Escape($f.name)+'\.untrusted-[a-fA-F0-9]{32}$')){throw ('Expected exactly one new untrusted/legacy sibling; found '+$new.Count)}
            $candidate=$new[0].FullName;Assert-PlainRecoveryPath $candidate
            $saved=Join-Path $backup $f.name;Assert-SealedRecovery $saved;Assert-SealedRecovery ($saved+'.manifest.json')
            $rows=@(Read-RecoveryJson ($saved+'.manifest.json'));Assert-RecoveryEqual @($f.expected) (Recovery-Lines $rows) 'companion original manifest'
            Assert-RecoveryEqual (Recovery-Lines $rows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $saved) -DataOnly) 'companion sealed baseline'
            $baselineRoot=@($rows|Where-Object relative -ceq '')
            if($baselineRoot.Count -ne 1 -or -not$baselineRoot[0].directory){throw 'Original root directory row is missing'}
            $native=[RooVerificationRecovery.Native]::DirectoryMetadata((ConvertTo-RecoveryNativePath $candidate))
            if($native.Creation -ne [DateTime]::new([long]$baselineRoot[0].creation,[DateTimeKind]::Utc).ToFileTimeUtc()){throw 'Companion native creation differs from original root'}
            $write=[DateTime]::FromFileTimeUtc($native.Write);$start=[DateTime]::Parse($m.Started).ToUniversalTime()
            if($write -lt $start -or $write -lt [DateTime]::Parse($Lease.startUtc).ToUniversalTime() -or $write -gt [DateTime]::UtcNow){throw 'Companion native last-write is outside migration lease'}
            if(@($rows|Where-Object relative -ceq '\logs\data-folder-migration.log').Count){throw 'Migration log was present before lease'}
            $migrationLog=Join-Path $root 'logs\data-folder-migration.log';Assert-SealedRecovery $migrationLog
            $lines=[IO.File]::ReadAllLines((ConvertTo-RecoveryNativePath $migrationLog));$prefix='Entries that were not carried over are kept at '
            $destinations=@($lines|Where-Object {$_.StartsWith($prefix,[StringComparison]::Ordinal)})
            if($destinations.Count -ne 1 -or $destinations[0] -cne ($prefix+$candidate)){throw 'Migration log does not name exactly this companion once'}
            $lookup=@{};foreach($r in $rows){$lookup[[string]$r.relative]=$r}
            $liveRows=@(Get-RecoveryRows $candidate)
            foreach($r in $liveRows){$old=$lookup[[string]$r.relative];if(-not$old -or $old.directory -ne $r.directory -or (-not$r.directory -and ($old.length -ne $r.length -or $old.sha256 -cne $r.sha256))){throw ('Companion entry is outside byte-identical baseline: '+$r.relative)}}
            Assert-RecoveryEqual (Recovery-Lines $liveRows) @(Get-TreeFingerprint $candidate) 'companion drift during qualification'
            [pscustomobject]@{kind='kept';name=$new[0].Name;path=$candidate;root=$root;manifestHash=(Get-FileHash -LiteralPath $manifest).Hash;logHash=(Get-FileHash -LiteralPath $migrationLog).Hash;nativeCreationFileTimeUtc=$native.Creation.ToString();nativeWriteFileTimeUtc=$native.Write.ToString();live=@(Recovery-Lines $liveRows)}
        } catch {Log ('Kept migration companions for '+$root+': '+$_.Exception.Message)|Out-Null}
    }
}
function Restore-RecoveryCompanions($Plan) {
    $d=Get-RecoveryWorkspace
    $ci=0;foreach($c in @($Plan.companions)){
        if($c.kind -ceq 'kept'){$f=@($Plan.scope.folders|Where-Object {(Join-Path $local $_.name) -ceq $c.root});if($f.Count -ne 1){throw 'Kept companion has no exact original root plan'};Assert-RecoveryEqual @($f[0].expected) @(Get-TreeFingerprint $c.root) 'original root must be restored before kept companion quarantine'}
        Assert-RecoveryEqual @($c.live) @(Get-TreeFingerprint $c.path) 'companion drift before quarantine'
        $q=Join-Path $d ('quarantine-companion-'+($ci++).ToString('D6'));if([IO.Path]::GetPathRoot($q) -cne [IO.Path]::GetPathRoot($c.path)){$q=$c.path+'.roo-industries-quarantine-'+(Split-Path $d -Leaf)}
        if(Test-Path -LiteralPath $q){throw 'Companion quarantine exists'}
        [IO.Directory]::Move((ConvertTo-RecoveryNativePath $c.path),(ConvertTo-RecoveryNativePath $q));$rows=@($c.live|ForEach-Object {$_|ConvertFrom-Json});Restore-RecoveryDescriptors $rows $q;Assert-RecoveryEqual @($c.live) @(Get-TreeFingerprint $q) 'companion moved identity';Restore-RecoveryDescriptors $rows $q -Seal;Assert-SealedRecovery $q
    }
}

function Get-RecoveryTaskDefinition([string]$Xml) {
    $x=[xml]$Xml;$node=$x.SelectSingleNode("/*[local-name()='Task']/*[local-name()='Settings']/*[local-name()='Enabled']");if($node){[void]$node.ParentNode.RemoveChild($node)}
    return $x.OuterXml
}
function Remove-RecoveryOwnedTasks {
    $s=Read-RecoveryScope;$d=Get-RecoveryWorkspace
    $records=@(Get-ChildItem -LiteralPath $d -Filter 'quiesce-*.json'|Sort-Object Name -Descending|ForEach-Object {(Read-RecoveryJson $_.FullName).tasks})
    $seen=@{};$scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect()
    try{foreach($prior in $records){
        $id=$prior.path+$prior.name;if($seen.ContainsKey($id)){continue};$seen[$id]=$true
        if(@($baseline.tasks) -contains $id){throw 'Baseline task is not a cleanup target'}
        $folder=$scheduler.GetFolder($prior.path);$task=$null
        try{try{$task=$folder.GetTask($prior.name)}catch{if($_.Exception.HResult -eq -2147024894 -or $_.Exception.InnerException.HResult -eq -2147024894){continue};throw}
            if($task.Enabled -or [int]$task.State -eq 4 -or [string]$task.GetSecurityDescriptor(7) -cne [string]$prior.sddl -or (Get-RecoveryTaskDefinition ([string]$task.Xml)) -cne (Get-RecoveryTaskDefinition $prior.xml)){throw ('Changed task retained after uninstall '+$id)}
            $folder.DeleteTask($prior.name,0)
        }finally{if($task){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($folder)}
    }}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($scheduler)}
}

function Register-RecoveryMigrationArtifacts([DateTime]$StartedUtc) {
    $d=Get-RecoveryWorkspace;$s=Read-RecoveryScope;$file=Join-Path $env:TEMP 'roo-industries-migration-state.json';$image=Join-Path $env:TEMP 'RooIndustriesMigrationProbe.exe'
    if(-not(Test-Path -LiteralPath $file) -or -not(Test-Path -LiteralPath $image)){return}
    $state=Read-RecoveryJson $file
    $identity=$state.probeIdentity;$fileIdentity=$state.probeFileIdentity
    if(-not$identity -or -not$identity.pid -or -not$identity.creationTimeFileTimeUtc -or -not$identity.imagePath -or -not$fileIdentity){throw 'Migration artifact has no native ownership receipt'}
    $created=[DateTime]::FromFileTimeUtc([long]$identity.creationTimeFileTimeUtc);if($created -lt $StartedUtc -or $created -gt [DateTime]::UtcNow){throw 'Migration probe creation is outside its exact action interval'}
    if($fileIdentity.path -ine [IO.Path]::GetFullPath($image) -or $identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($image)){throw 'Migration receipt has the wrong probe image'}
    $opened=Open-OwnedProbe $fileIdentity;try{if($opened.Identity.hash -cne (Get-FileHash -LiteralPath (Join-Path ([Environment]::GetFolderPath('System')) 'PING.EXE')).Hash){throw 'Migration probe does not match its scenario source image'}}finally{$opened.Dispose()}
    $process=Get-Process -Id ([int]$identity.pid) -ErrorAction Stop
    try{$actual=New-OwnedProcess $process;if($actual.Identity.creationTimeFileTimeUtc -cne [string]$identity.creationTimeFileTimeUtc -or $actual.Identity.imagePath -ine [string]$identity.imagePath){throw 'Migration artifact does not identify the live native probe'}}finally{$process.Dispose()}
    $row=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$identity.pid) -ErrorAction Stop;if(-not$row -or (Get-RecoveryProcessOwner $row) -cne $s.sid){throw 'Migration probe owner differs'}
    $artifact=Join-Path $d 'scenario-migration-before-identity.json'
    Save-RecoveryJson $artifact @{probeIdentity=$identity;probeFileIdentity=$fileIdentity;probeStartDiagnostic=$state.probeStart;pid=[int]$identity.pid;created=$created.ToString('o');image=$image;sid=$s.sid;statePath=$file;stateBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file));stateHash=(Get-FileHash -LiteralPath $file).Hash;imageHash=(Get-FileHash -LiteralPath $image).Hash;actionStartedUtc=$StartedUtc.ToString('o')}
}
function Move-RecoveryOwnedFile([string]$Path,[string]$ExpectedHash,[string]$Label) {
    Assert-PlainRecoveryPath $Path
    if((Get-FileHash -LiteralPath $Path).Hash -cne $ExpectedHash){throw ('Changed remnant retained '+$Path)}
    $d=Get-RecoveryWorkspace;$rows=@(Get-RecoveryRows $Path);$target=Join-Path $d ('remnant-'+$Label)
    Save-RecoveryJson ($target+'.manifest.json') $rows
    if(Test-Path -LiteralPath $target){throw 'Remnant evidence already exists'}
    Assert-RecoveryEqual (Recovery-Lines $rows) @(Get-TreeFingerprint $Path) 'remnant drift immediately before move'
    [IO.File]::Move((ConvertTo-RecoveryNativePath $Path),(ConvertTo-RecoveryNativePath $target));Restore-RecoveryDescriptors $rows $target;Assert-RecoveryEqual (Recovery-Lines $rows) @(Get-TreeFingerprint $target) 'remnant move identity';Restore-RecoveryDescriptors $rows $target -Seal;Assert-SealedRecovery $target
}

function Assert-RecoveryProbePreflight([string]$TempRoot=$env:TEMP,[object[]]$ProcessRows=$null) {
    $names='RooIndustriesMigrationProbe','RooIndustriesLoadTimesProbe','RooIndustriesLauncherProbe','RooIndustriesProtectedLauncherProbe','RooIndustriesProtectedGameProbe','RooIndustriesEnvironmentControl','RooIndustriesGovernorProbe'
    if($null -eq $ProcessRows){$ProcessRows=@(Get-Process $names -ErrorAction SilentlyContinue)}
    if($ProcessRows.Count){throw 'A test probe process already exists; recover its exact owner first'}
    foreach($name in @($names|ForEach-Object {$_+'.exe'})+@('roo-industries-migration-state.json','roo-industries-governor-installed')){if(Test-Path -LiteralPath (Join-Path $TempRoot $name)){throw ('Existing test remnant must be recovered first: '+$name)}}
}

function Get-InstalledFingerprint {
    [ordered]@{
        app=(Get-FileHash -LiteralPath (Join-Path $app 'app\RooIndustries.OptimizationSuite.App.dll') -Algorithm SHA256).Hash
        host=(Get-FileHash -LiteralPath (Join-Path $app 'backend\bin\optimizer\Optimizer.Host.dll') -Algorithm SHA256).Hash
        version=(Get-Item -LiteralPath (Join-Path $app 'app\RooIndustries.OptimizationSuite.App.exe')).VersionInfo.ProductVersion
    }
}
function Invoke-Helper([string]$Path,[string[]]$Arguments,[hashtable]$Environment,[string]$StdinText=''){
    $previous=@{}
    foreach($name in $Environment.Keys){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,[string]$Environment[$name],'Process')}
    $stem=Join-Path $Evidence ('helper-'+[Guid]::NewGuid().ToString('N'))
    try {
        $start=@{FilePath=$Path;ArgumentList=$Arguments;NoNewWindow=$true;Wait=$true;PassThru=$true;RedirectStandardOutput=($stem+'.out');RedirectStandardError=($stem+'.err')}
        if($StdinText){[IO.File]::WriteAllText(($stem+'.in'),$StdinText,[Text.UTF8Encoding]::new($false));$start.RedirectStandardInput=($stem+'.in')}
        $process=Start-Process @start
        $text=@((Get-Content -LiteralPath ($stem+'.out') -ErrorAction SilentlyContinue),(Get-Content -LiteralPath ($stem+'.err') -ErrorAction SilentlyContinue))|ForEach-Object {$_}
        return [pscustomobject]@{Exit=$process.ExitCode;Text=((@($text)|ForEach-Object {[string]$_}) -join "`n")}
    } finally {
        foreach($name in $Environment.Keys){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
        Remove-Item -Path ($stem+'.*') -Force -ErrorAction SilentlyContinue
    }
}

if($Phase -in 'install-old','install-other','upgrade','uninstall','cleanup','validators','scenario','static-checks','setup-fallbacks'){
    $baselinePath=Join-Path $backup 'machine-state.json'
    if(-not (Test-Path -LiteralPath $baselinePath)){throw 'No baseline machine-state.json; this phase refuses to alter the PC.'}
    $baseline=Get-Content -LiteralPath $baselinePath -Raw|ConvertFrom-Json
    $requiredState='backupFormat','appFolder','uninstallEntries','localSiblings','tasks','productKeys','enableTransparency','ifeoProbeKey','downloadBlockerFolder','userEnvironmentNames','tweakStateKey','rooHklmFingerprint','hypervisorlaunchtype','vbsStatus','vbsRunning','rebootPendingCbs','rebootRequiredUpdate','pendingFileRenames'
    if(@($requiredState|Where-Object {$baseline.PSObject.Properties.Name -notcontains $_}).Count){throw 'The baseline is incomplete; this phase keeps the PC unchanged.'}
    if($baseline.appFolder -isnot [bool] -or $baseline.ifeoProbeKey -isnot [bool] -or $baseline.downloadBlockerFolder -isnot [bool]){throw 'The baseline has invalid state fields; this phase keeps the PC unchanged.'}
    foreach($name in 'RooIndustriesOptimizationSuite',('RooIndustriesOptimizationSuite' -replace 'Industries',''),'RooIndustriesOptimizationSuite.Timer'){if(@($baseline.localSiblings) -contains $name -and (-not (Test-Path -LiteralPath (Join-Path $backup $name)) -or -not (Test-Path -LiteralPath ((Join-Path $backup $name)+'.manifest.json')))){throw ('The backup of '+$name+' is missing; no live data will be touched.')}}
    if($baseline.backupFormat -ne 3){throw 'Historical backup format requires an audited manual restore; this driver keeps it unchanged.'}
    $recoveryScope=Read-RecoveryScope
    if($baseline.appFolder -or @($baseline.uninstallEntries).Count){throw 'The as-found installation has no verified rollback source; this phase refuses to remove it.'}
}
if($Phase -in 'install-other','upgrade','uninstall','scenario','static-checks','setup-fallbacks'){Require-RecoveryEpoch 'installed'|Out-Null}
switch($Phase){
    'preflight' {
        Assert-RecoveryProbePreflight
        if(@(Get-Process cs2 -ErrorAction SilentlyContinue).Count){throw 'CS2 is running.'}
        $busy=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like '*OptimizationSuite.ProcessRules.*' -or $_.TaskName -like 'RooIndustries_Governor*' -or ($_.TaskName -like 'Roo Industries Protected Session*' -and [string]$_.State -eq 'Running')})
        if($busy.Count){throw ('Other Roo Industries test tasks exist: '+(($busy|ForEach-Object TaskName) -join ', '))}
        if(Test-Path -LiteralPath $backup){throw "A backup from an earlier run is still at $backup; restore it with -Phase cleanup first."}
        if(@((Get-Item -LiteralPath $userEnvironment).GetValueNames()) -contains $plantedName){throw ($plantedName+' is already set in the user environment; the launcher scenarios plant it and would hide it. Remove it first.')}
        if(Test-Path -LiteralPath (Join-Path $app 'app')){throw 'The app is already installed. This driver has no verified reinstall source for the as-found installation; use a clean test PC.'}
        try {
            $state=Get-MachineState
            $state.tweakStateKey=Get-RegistryFingerprint $stateKey
            $state.rooHklmFingerprint=Get-RegistryFingerprint $rooHklm
            New-RecoveryScope $state
            Log ('Baseline and sealed recovery scope created at '+$backup)
        } catch {Log ('Backup incomplete; kept at '+$backup+' for inspection.');throw}
    }
    'validators' {
        $env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
        $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        function Invoke-Suite([string]$Relative,[string[]]$Arguments=@()){& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Source $Relative) @Arguments 2>&1}
        function Protect-RealDataFolder {
            $hostDll=Join-Path $Source 'backend\bin\optimizer\Optimizer.Host.dll'
            if(-not (Test-Path -LiteralPath $hostDll)){Invoke-Suite 'backend\scripts\Build-OptimizerHost.ps1' @('-DotNetPath',$dotnet)|Out-Null}
            $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
            try {$reply=(@((@{schemaVersion=1;repoRoot=$Source;confirm=$true}|ConvertTo-Json -Compress)|& $dotnet $hostDll 'data-secure' '-' 2>&1)|ForEach-Object {[string]$_}) -join "`n"} finally {$ErrorActionPreference=$previous}
            $status=try {($reply|ConvertFrom-Json).status} catch {''}
            if($status -ne 'completed'){throw ('The real data folder could not be protected for the removal queue suite: '+$reply)}
            'The suite needs the real data folder protected, as the app leaves it after its first start; it is protected inside the backup frame and restored afterwards.'
        }
        $all=[ordered]@{
            'optimizer-core'={Invoke-Suite 'backend\scripts\Test-OptimizerCore.ps1' @('-DotNetPath',$dotnet)}
            'build-host'={Invoke-Suite 'backend\scripts\Build-OptimizerHost.ps1' @('-DotNetPath',$dotnet)}
            'tweaks'={Invoke-Suite 'backend\scripts\Test-Tweaks.ps1' @('-DotNetPath',$dotnet)}
            'process-policy-worker'={Invoke-Suite 'backend\scripts\Test-ProcessPolicyWorker.ps1' @('-DotNetPath',$dotnet)}
            'protected-sessions'={Invoke-Suite 'backend\scripts\Test-ProtectedGameSessions.ps1' @('-DotNetPath',$dotnet)}
            'tool-launcher'={Invoke-Suite 'tools\scripts\Test-ToolLauncher.ps1' @('-DotNetPath',$dotnet)}
            'frontend'={Invoke-Suite 'tools\scripts\Test-Frontend.ps1' @('-DotNetPath',$dotnet)}
            'client-cleanup-boundary'={Invoke-Suite 'backend\scripts\Test-ClientCleanupBoundary.ps1' @('-DotNetPath',$dotnet)}
            'optimizer-host'={Open-RecoveryEpoch 'validators';Protect-RealDataFolder;Invoke-Suite 'backend\scripts\Test-OptimizerHost.ps1' @('-DotNetPath',$dotnet)}
            'data-root-marker-paths'={Invoke-Suite 'backend\scripts\Test-DataRootMarkerPaths.ps1'}
            'governor-setup-legacy-pause'={Invoke-Suite 'backend\scripts\Test-GovernorSetupLegacyPause.ps1'}
            'earlier-version-gate'={Invoke-Suite 'backend\scripts\Test-EarlierVersionGate.ps1' @('-DotNetPath',$dotnet)}
            'script-parser'={Invoke-Suite 'tools\scripts\Test-Baseline.ps1' @('-ParseOnly')}
            'governor-scenarios'={Invoke-Suite 'backend\scripts\Test-GovernorScenarios.ps1' @('-DotNetPath',$dotnet)}
        }
        $Only=@($Only|ForEach-Object {$_ -split ','}|Where-Object {$_})
        foreach($name in $all.Keys){if($Only.Count -eq 0 -or $Only -contains $name){Run $name $all[$name] -GuardData:($name -ne 'optimizer-host')}}
        if($script:epochDir){Invoke-EpochRecovery}
    }
    'release-build' {
        $buildArguments=@{}
        if($TestHooks){$buildArguments.TestHooks=$true}
        if($BuildOutput){$buildArguments.OutputRoot=$BuildOutput}
        $buildName='build-release'+$(if($TestHooks){'-test-hooks'}else{''})
        Run $buildName {& (Join-Path $Source 'tools\scripts\Build-Release.ps1') @buildArguments}
        $buildText=Get-Content -LiteralPath (Join-Path $Evidence ($Phase+'-'+$buildName+'.txt')) -Raw -Encoding UTF8
        Check ($buildText -match 'PASS the guard rejects dynamic property') 'the dynamic binding guard rejected its own fixture during the release build' ''
        Check ($buildText -match 'PASS \d+ dynamic operations in 4 assemblies stay inside COM interop code') 'the dynamic binding guard passed on the four release assemblies (Core, Host, SessionHost, App)' ''
        $built=[regex]::Match($buildText,'"installer"\s*:\s*"([^"]+)"').Groups[1].Value.Replace('\\','\')
        $builtHash=[regex]::Match($buildText,'"sha256"\s*:\s*"([0-9a-f]{64})"').Groups[1].Value
        Check ($built -and (Test-Path -LiteralPath $built) -and $builtHash -eq (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash.ToLowerInvariant() -and -not $TestHooks) 'the release build produced a production installer (no test hooks) whose SHA-256 matches the build report' ($built+' sha256='+$builtHash)
    }
    'install-old' {
        Open-RecoveryEpoch 'installed'
        Run 'install-old' {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $OldInstaller -OutDir (Join-Path $Evidence 'install-old')}
        Stop-AfterInstall
        $fingerprint=Get-InstalledFingerprint
        $fingerprint|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence 'installed-old.json') -Encoding UTF8
        Log ('installed after install-old: '+($fingerprint|ConvertTo-Json -Compress)+' installer sha256='+(Get-FileHash -LiteralPath $OldInstaller -Algorithm SHA256).Hash)
        $entries=@((Get-MachineState).uninstallEntries)
        Check ($entries.Count -eq 1) 'the installed product has exactly one uninstall entry' ($entries -join ',')
    }
    'upgrade' {
        $old=if(Test-Path -LiteralPath (Join-Path $Evidence 'installed-old.json')){Get-Content -LiteralPath (Join-Path $Evidence 'installed-old.json') -Raw|ConvertFrom-Json}
        Run 'upgrade' {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $NewInstaller -OutDir (Join-Path $Evidence 'upgrade')}
        Stop-AfterInstall
        $fingerprint=Get-InstalledFingerprint
        $fingerprint|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence 'installed-new.json') -Encoding UTF8
        Log ('installed after upgrade: '+($fingerprint|ConvertTo-Json -Compress)+' installer sha256='+(Get-FileHash -LiteralPath $NewInstaller -Algorithm SHA256).Hash)
        $entries=@((Get-MachineState).uninstallEntries)
        Check ($entries.Count -eq 1) 'the upgraded product has exactly one uninstall entry' ($entries -join ',')
        Check ($null -ne $old -and $old.app -ne $fingerprint.app -and $old.host -ne $fingerprint.host) 'the upgrade replaced the app and the helper assemblies (their hashes differ from the earlier install)' ('app '+$old.app+' -> '+$fingerprint.app+', host '+$old.host+' -> '+$fingerprint.host)
    }
    'install-other' {
        Invoke-RecoveryUninstall
        Run ('install-'+$Label) {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $OtherInstaller -OutDir (Join-Path $Evidence ('install-'+$Label))}
        Stop-AfterInstall
        $fingerprint=Get-InstalledFingerprint
        $fingerprint|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence ('installed-'+$Label+'.json')) -Encoding UTF8
        Log ('installed '+$Label+': '+($fingerprint|ConvertTo-Json -Compress)+' installer sha256='+(Get-FileHash -LiteralPath $OtherInstaller -Algorithm SHA256).Hash)
        $entries=@((Get-MachineState).uninstallEntries)
        Check ($entries.Count -eq 1) ('the installed product has exactly one uninstall entry ('+$Label+')') ($entries -join ',')
    }
    'static-checks' {
        $shipped=@('app\RooIndustries.OptimizationSuite.App.runtimeconfig.json','backend\bin\optimizer\Optimizer.Host.runtimeconfig.json','backend\bin\optimizer\session\RooIndustries.SessionHost.runtimeconfig.json')
        $present=@(Get-ChildItem -LiteralPath $app -Recurse -Filter '*.runtimeconfig.json' -File -ErrorAction SilentlyContinue|ForEach-Object {$_.FullName.Substring($app.Length+1)}|Sort-Object)
        Check ($present.Count -eq 3 -and @($shipped|Where-Object {$present -notcontains $_}).Count -eq 0) 'exactly the three shipped runtimeconfig files are installed' ('found '+$present.Count+': '+($present -join ', '))
        foreach($relative in $shipped){
            $path=Join-Path $app $relative
            if(-not (Test-Path -LiteralPath $path)){Check $false ('startup hooks are off in '+$relative) 'the file is missing';continue}
            Copy-Item -LiteralPath $path -Destination (Join-Path $Evidence ('runtimeconfig-'+(Split-Path $relative -Leaf))) -Force
            $value=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).runtimeOptions.configProperties.'System.StartupHookProvider.IsSupported'
            Check ($value -is [bool] -and -not $value) ('startup hooks are off in '+$relative) ('System.StartupHookProvider.IsSupported='+$(if($null -eq $value){'<absent>'}else{[string]$value}))
        }
        $request='{"schemaVersion":1,"repoRoot":"'+$app.Replace('\','\\')+'"}'
        $helpers=@(
            @{Name='Optimizer.Host.exe';Path=(Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe');Arguments=@('tweak-catalog','-');StdinText=$request;CleanRun={param($r) $r.Exit -eq 0 -and $r.Text -match '"status"\s*:\s*"completed"'};CleanMeaning='starts, runs and completes'},
            @{Name='RooIndustries.SessionHost.exe';Path=(Join-Path $app 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe');Arguments=@('run',(Join-Path $noSuch 'request.json'));StdinText='';CleanRun={param($r) $r.Exit -ne 0 -and $r.Text.Trim().Length -gt 0 -and $r.Text -notmatch 'will not run with these'};CleanMeaning='fails on the missing request and says why'}
        )
        $cases=@(
            @{Name='DOTNET_STARTUP_HOOKS';Variables=[ordered]@{DOTNET_STARTUP_HOOKS=(Join-Path $noSuch 'hook.dll')};Listed='DOTNET_STARTUP_HOOKS'},
            @{Name='CORECLR_ENABLE_PROFILING';Variables=[ordered]@{CORECLR_ENABLE_PROFILING='1';CORECLR_PROFILER_PATH=(Join-Path $noSuch 'profiler.dll')};Listed='CORECLR_ENABLE_PROFILING, CORECLR_PROFILER_PATH'}
        )
        foreach($helper in $helpers){
            $clean=Invoke-Helper $helper.Path $helper.Arguments @{} $helper.StdinText
            Set-Content -LiteralPath (Join-Path $Evidence ('helper-'+$helper.Name+'-clean.txt')) -Value ('exit '+$clean.Exit+"`n"+$clean.Text.Substring(0,[Math]::Min(2000,$clean.Text.Length))) -Encoding UTF8
            Check ([bool](& $helper.CleanRun $clean)) ('control: '+$helper.Name+' without those variables '+$helper.CleanMeaning) ('exit '+$clean.Exit+': '+$(if($clean.Text.Length -gt 300){$clean.Text.Substring(0,300)}else{$clean.Text}))
            foreach($case in $cases){
                $result=Invoke-Helper $helper.Path $helper.Arguments $case.Variables $helper.StdinText
                Set-Content -LiteralPath (Join-Path $Evidence ('helper-'+$helper.Name+'-'+$case.Name+'.txt')) -Value ('exit '+$result.Exit+"`n"+$result.Text) -Encoding UTF8
                Check ($result.Exit -ne 0 -and $result.Text -match ('will not run with these \.NET settings in its environment: '+[regex]::Escape($case.Listed)+'\.')) ($helper.Name+' refuses to start with '+(($case.Variables.Keys) -join ' and ')+' set (paths that do not exist)') ('exit '+$result.Exit+': '+$result.Text)
            }
        }
        $entries=@((Get-MachineState).uninstallEntries)
        Check ($entries.Count -eq 1) 'the installed product has exactly one uninstall entry' ($entries -join ',')
        $markers=Get-Item -LiteralPath ('Registry::'+$markerKey) -ErrorAction SilentlyContinue
        Log ('markers: '+$(if($markers){(@($markers.GetValueNames())|ForEach-Object {$_+'='+$markers.GetValue($_)}) -join ' ; '}else{'<none>'}))
    }
    'scenario' {
        if(-not $Scenario){throw 'Provide -Scenario.'}
        Register-RecoveryAuxiliaryIntent $Scenario
        $root=Join-Path $Evidence 'scenarios'
        $arguments=@{Label=$Scenario;Scenario=$Scenario;OutRoot=$root;Minutes=$Minutes}
        $actionStartedUtc=[DateTime]::UtcNow
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $ErrorActionPreference='Continue'
        $console=@()
        try {$console=@(& (Join-Path $Source 'tools\validation\LoadTimes\Invoke-LoadTimes.ps1') @arguments 2>&1|ForEach-Object {[string]$_})}
        catch {$console+=('Invoke-LoadTimes stopped: '+($_|Out-String));Check $false ('scenario '+$Scenario+' could not run') $_.Exception.Message}
        $ErrorActionPreference='Stop'
        if($Scenario -ceq 'migration-before'){Register-RecoveryMigrationArtifacts $actionStartedUtc}
        $console|Set-Content -LiteralPath (Join-Path $Evidence ('scenario-'+$Scenario+'-console.txt')) -Encoding UTF8
        $dir=Join-Path $root $Scenario
        $scenarioLog=Join-Path $dir $(if($Scenario -eq 'loadtimes'){'loadtimes.log'}else{$Scenario+'.log'})
        $done=Join-Path $dir $(if($Scenario -eq 'loadtimes'){'measure.done'}else{$Scenario+'.done'})
        $lines=@(if(Test-Path -LiteralPath $scenarioLog){Get-Content -LiteralPath $scenarioLog -Encoding UTF8})
        $passed=@($lines|Where-Object {$_ -cmatch '^\S+ PASS '}).Count
        $failed=@($lines|Where-Object {$_ -cmatch '^\S+ (FAIL|FATAL|ERROR) '}).Count
        $skipped=@($lines|Where-Object {$_ -cmatch '^\S+ (SKIPPED|NOT RUN) '})
        $cleanup=@($lines|Where-Object {$_ -match 'CLEANUP NEEDED'})+@($console|Where-Object {$_ -match 'CLEANUP NEEDED'})
        $result=@($lines|Where-Object {$_ -match 'RESULT failures=(\d+)'})|Select-Object -Last 1
        foreach($line in $lines){
            if($line -cmatch '^\S+ (PASS|FAIL|SKIPPED) (.*)$'){$text=$Matches[2];$length=[Math]::Min(700,$text.Length);Log ($Matches[1]+' '+$text.Substring(0,$length))}
            elseif($line -cmatch '^\S+ NOT RUN (.*)$'){Log ('SKIPPED '+$Matches[1])}
        }
        if($Scenario -eq 'loadtimes'){
            $rows=@(if(Test-Path -LiteralPath (Join-Path $dir 'loadtimes.csv')){Import-Csv -LiteralPath (Join-Path $dir 'loadtimes.csv')})
            $bad=@($rows|Where-Object {$_.note -match 'timeout|error' -or -not $_.complete_ms -or -not $_.usable_ms})
            $aborted=@($lines|Where-Object {$_ -cmatch '^\S+ (FATAL|ERROR) '})
            $pageNames='Games','Games/Processes','Games/Background','Remove apps','Graphics drivers','Windows tweaks','Tools','Tools/BIOS settings','Undo changes','Report a bug','Settings','Home','Remove apps/Leftovers','Startup & services','Memory','Timer & cache'
            foreach($tour in 'tour1','tour2'){foreach($page in $pageNames){$visits=if($page -in 'Remove apps/Leftovers','Startup & services','Memory','Timer & cache'){@('first','revisit')}else{@('first','revisit','third visit')};foreach($visit in $visits){Check (@($rows|Where-Object {$_.tour -eq $tour -and $_.page -eq $page -and $_.visit -eq $visit}).Count -eq 1) ('loadtimes measured '+$tour+' '+$page+' '+$visit) ''}}}
            foreach($page in 'Start: window','Start: Home'){Check (@($rows|Where-Object {$_.page -eq $page -and $_.tour -like 'cold*'}).Count -eq 3) ('loadtimes measured three cold runs of '+$page) ''}
            Check (@($rows|Where-Object {$_.page -eq 'Start: Windows tweaks right after launch'}).Count -eq 2) 'loadtimes measured both cold Windows tweaks runs' ''
            Check ((Test-Path -LiteralPath $done) -and $rows.Count -gt 0 -and $bad.Count -eq 0 -and $aborted.Count -eq 0) 'loadtimes finished and no page timed out or failed' ('rows='+$rows.Count+' bad='+$bad.Count+' '+(@($bad|Select-Object -First 3|ForEach-Object {$_.page+' '+$_.visit+' '+$_.note}) -join ' / '))
        } else {
            Check ((Test-Path -LiteralPath $done) -and $failed -eq 0 -and $passed -gt 0 -and $result -match 'RESULT failures=0') ('scenario '+$Scenario+': PASS '+$passed+' FAIL '+$failed+' SKIPPED '+$skipped.Count) ($(if($result){$result}else{'no RESULT line'})+$(if(-not (Test-Path -LiteralPath $done)){' (not finished)'}else{''}))
            Check ($skipped.Count -eq 0) ('scenario '+$Scenario+' skipped no check') (($skipped|Select-Object -First 3) -join ' / ')
        }
        Check ($cleanup.Count -eq 0) ('scenario '+$Scenario+' left nothing to clean up by hand') ($cleanup -join ' / ')
        Log ('scenario '+$Scenario+' took '+[Math]::Round($clock.Elapsed.TotalMinutes,1)+' min; evidence '+$dir)
    }
    'uninstall' {
        $before=@(Get-ChildItem -LiteralPath $app -Filter 'unins*.exe' -ErrorAction SilentlyContinue).Count
        $timerTasksBefore=@(Get-ScheduledTask -ErrorAction Stop|Where-Object TaskName -Like 'RooIndustries.Timer.*')
        Invoke-RecoveryUninstall
        Check ($before -ge 1) 'the installed app was uninstalled by its own uninstaller' 'verified successful exit and no installed writers'
        $nativeLogExists=$script:NativeUninstallLog -and (Test-Path -LiteralPath $script:NativeUninstallLog -PathType Leaf)
        Check ([bool]$nativeLogExists) 'the native uninstall log was retained in protected evidence' $script:NativeUninstallLog
        $nativeLogText=if($nativeLogExists){Assert-SealedRecovery $script:NativeUninstallLog;[IO.File]::ReadAllText($script:NativeUninstallLog)}else{''}
        foreach($timer in $timerTasksBefore){
            Check ($nativeLogText -match ('(?m)removed: timer task '+[regex]::Escape($timer.TaskName)+'\s*$')) ('the native uninstall log confirms removed: timer task '+$timer.TaskName) $script:NativeUninstallLog
            Check (@(Get-ScheduledTask -TaskName $timer.TaskName -TaskPath $timer.TaskPath -ErrorAction SilentlyContinue).Count -eq 0) ('the uninstall removed timer task '+$timer.TaskPath+$timer.TaskName) ''
        }
        $entries=@((Get-MachineState).uninstallEntries)
        Check ($entries.Count -eq 0) 'the uninstall removed the product''s uninstall entry' ($entries -join ',')
        Check (@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue).Count -eq 0) 'the uninstall removed every governor task' ''
    }
    'setup-fallbacks' {
        Run 'setup-fallbacks' {& (Join-Path $Source 'tools\validation\Governor\Test-GovernorSetupFallbacks.ps1') -Script (Join-Path $Source 'backend\scripts\Invoke-GovernorSetup.ps1') -OutDir (Join-Path $Evidence 'setup-fallbacks')}
    }
    'summary' {
        foreach($name in $Expect){
            $file=Join-Path $Evidence ($name+'.log')
            $lines=@(if(Test-Path -LiteralPath $file){Get-Content -LiteralPath $file -Encoding UTF8})
            $passLines=@($lines|Where-Object {$_ -cmatch '^\S+ PASS '}|ForEach-Object {($_ -creplace '^\S+ PASS ','')})
            $failed=@($lines|Where-Object {$_ -cmatch '^\S+ (FAIL|FATAL|ERROR) '}).Count
            $skipped=@($lines|Where-Object {$_ -cmatch '^\S+ (SKIPPED|NOT RUN) '}).Count
            Check ((Test-Path -LiteralPath $file) -and $failed -eq 0 -and $skipped -eq 0 -and ($passLines.Count -gt 0 -or $name -eq 'preflight')) ('phase '+$name+': PASS '+$passLines.Count+' FAIL '+$failed+' SKIPPED '+$skipped) $(if(Test-Path -LiteralPath $file){$file}else{'no log was written'})
            foreach($needle in @($requiredChecks[$name])){
                $found=@($passLines|Where-Object {$_ -like ('*'+$needle+'*')}).Count
                Check ($found -ge 1) ('phase '+$name+' ran the check: '+$needle) ('passed '+$found+' time(s)')
            }
        }
    }
    'cleanup' {
        $workspace=Get-RecoveryWorkspace
        if($workspace -cne $backup){Invoke-EpochRecovery -Uninstall {Invoke-VerifiedUninstall;Retain-RecoveryRemnants}}
        else{foreach($f in (Read-RecoveryScope).folders){Assert-RecoveryEqual @($f.expected) @(Get-TreeFingerprint (Join-Path $local $f.name)) 'no-open-epoch baseline'}}
        Restore-RecoveryAuxiliaryFields
        if(Test-Path -LiteralPath $backup){
            $before=$baseline
            if($before){
                if(-not $before.ifeoProbeKey -and (Test-Path -LiteralPath $ifeoProbe)){Log 'CLEANUP NEEDED: retained the protected-session probe image key; recovery requires its exact native operation receipt'}
                if(-not $before.downloadBlockerFolder -and (Test-Path -LiteralPath $blockerFolder)){Log 'CLEANUP NEEDED: retained the download blocker folder; removal requires its exact native control receipt'}
                $now=Get-MachineState
                $now.tweakStateKey=Get-RegistryFingerprint $stateKey
                $now.rooHklmFingerprint=Get-RegistryFingerprint $rooHklm
                foreach($field in 'hypervisorlaunchtype','vbsStatus','vbsRunning','rebootPendingCbs','rebootRequiredUpdate','appFolder','tweakStateKey','rooHklmFingerprint','enableTransparency','ifeoProbeKey','downloadBlockerFolder'){Check ([string]$now[$field] -eq [string]$before.$field) ('machine state unchanged: '+$field) ('before='+[string]$before.$field+' now='+[string]$now[$field])}
                $added=@(([string]$now.pendingFileRenames -split '\|')|Where-Object {$_ -and ([string]$before.pendingFileRenames).IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -lt 0})
                Check ($added.Count -eq 0) 'no pending file rename was added by this run (a restart may have processed older ones)' ('added='+($added -join '|'))
                foreach($field in 'tasks','productKeys','uninstallEntries','localSiblings','userEnvironmentNames'){Check ((@($now[$field])-join '|') -eq (@($before.$field)-join '|')) ('machine state unchanged: '+$field) ('before='+(@($before.$field)-join '|')+' now='+(@($now[$field])-join '|'))}
            }
            if($script:Failures -eq 0){Log ('Verified recovery evidence retained at '+$backup)}
            else{Log ('the backup is kept at '+$backup+' because a restore check failed')}
        }
    }
}
if($script:Failures){exit 1}
