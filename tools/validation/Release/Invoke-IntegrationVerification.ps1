param(
    [Parameter(Mandatory=$true)][ValidateSet('preflight','validators','release-build','install-old','upgrade','install-other','static-checks','scenario','setup-fallbacks','uninstall','summary','cleanup')][string]$Phase,
    [ValidateSet('loadtimes','invalidation','modes','migration-before','migration-after','migration-undo-timer','permissions','hardware','launchers','launchers-session','override','incomplete','incomplete-before')][string]$Scenario='',
    [string]$Source=(Join-Path $env:TEMP 'roo-industries-integration-src'),
    [string]$Evidence=(Join-Path $env:TEMP 'roo-industries-integration-evidence'),
    [string]$OldInstaller='',
    [string]$NewInstaller='',
    [string]$OtherInstaller='',
    [string]$Label='other',
    [int]$Minutes=45,
    [string[]]$Only=@(),
    [string[]]$Expect=@('preflight','validators','release-build','install-old','scenario-migration-before','upgrade','scenario-migration-after','static-checks','scenario-permissions','scenario-migration-undo-timer','scenario-launchers','scenario-override','scenario-incomplete','scenario-invalidation','scenario-modes','setup-fallbacks','scenario-hardware','scenario-loadtimes'),
    [switch]$TestHooks,
    [switch]$ReplaceExisting,
    [string]$BuildOutput='',
    [string]$BackupRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'roo-industries-backup')
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$app='C:\Program Files\Roo Industries\Optimization Suite'
$local=[Environment]::GetFolderPath('LocalApplicationData')
$markerKey='HKLM\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$stateKey='HKLM\SOFTWARE\RooIndustriesOptimizationSuite'
$personalize='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
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
    'scenario-launchers'=@('the installed launcher clears every code-loading variable','control: the environment reader sees DOTNET_STARTUP_HOOKS','the governor rule was saved through the app','governor task * registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','protected-session task''s registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','control: a task that starts a program directly, with no launcher, inherits the planted DOTNET_STARTUP_HOOKS','governor worker''s own process environment contains none of the','protected session worker''s own process environment contains none of the','governor worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','protected session worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','the governor worker running after the rule was saved','the governor worker image is the installed Optimizer.Host.exe under C:\Program Files','the protected-session worker image is the installed RooIndustries.SessionHost.exe under C:\Program Files','with the app closed the governor applies the saved rule to a matching process that starts later','the protected session is armed and its worker is running','while the session is armed the launcher has the requested affinity, memory priority and I/O priority','the launcher probe has its original affinity, memory priority, I/O priority and CPU priority back after the stop')
    'scenario-launchers-session'=@('the protected-session worker image is the installed RooIndustries.SessionHost.exe under C:\Program Files','control: a task that starts a program directly, with no launcher, inherits the planted DOTNET_STARTUP_HOOKS','protected-session task''s registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','protected session worker''s own process environment contains none of the','protected session worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','the protected session is armed and its worker is running')
    'scenario-override'=@('control: the process trace sees a dotnet.exe that this scenario starts on purpose','the release app still loads the Windows tweaks rows and finishes reading Windows','the override reached the app','the app started Optimizer.Host.exe children whose image is inside the install folder','the app never started a dotnet.exe')
    'scenario-incomplete'=@('control: the process trace sees a dotnet.exe that this scenario starts on purpose','Windows tweaks shows the missing-files message when hostpolicy.dll is missing','the app log has a Missing hostpolicy.dll line','no dotnet.exe was started anywhere on this PC','the installed Invoke-CleanupExclusions.ps1 refuses','the installed Invoke-ProtectedGameSession.ps1 refuses','hostpolicy.dll is back in place')
    'scenario-permissions'=@('runas /trustlevel:0x20000 gave a standard token','root is owned by Administrators or SYSTEM','operations is owned by Administrators or SYSTEM','timer is owned by Administrators or SYSTEM','firmware is owned by Administrators or SYSTEM','tools is owned by Administrators or SYSTEM','settings is owned by Administrators or SYSTEM','rules is owned by Administrators or SYSTEM','a standard token is denied writing into root','a standard token is denied writing into operations','a standard token is denied writing into timer','a standard token is denied writing into firmware','a standard token is denied writing into tools','a standard token is denied writing into settings','a standard token is denied writing into rules','the sign-in timer state folder is a plain folder outside the protected data folder','the sign-in timer state folder is owned by the signed-in user','a standard token can write the sign-in timer state folder')
    'scenario-migration-before'=@('the earlier version applied the tweak profile','the earlier version saved the governor rule','the earlier version enforces the rule on the probe','the earlier version has a governor task and a running governor worker to replace','the earlier version registered the sign-in timer')
    'scenario-migration-undo-timer'=@('the new version undoes the sign-in timer applied by the earlier version')
    'scenario-migration-after'=@('the probe from before the upgrade is still running','after the upgrade the governor still enforces the earlier rule','the upgraded install has a governor task','upgraded governor task * registered action equals what the installed New-RooIndustriesElevatedTaskAction produces','the governor worker running after the upgrade is the installed new one','upgraded governor worker''s parent is the cmd.exe the registered action starts under conhost.exe --headless','a process started after the upgrade gets the migrated rule from the new governor','the Undo page lists the profile applied by the earlier version','the app asked once whether to use the backup saved by an older version','the sign-in timer of the earlier version is still registered after the upgrade','the new version restores the tweak applied by the earlier version','deleting the migrated rule gives the probe its normal priority back')
}
$noSuch='C:\RooIndustriesNoSuchFolder'
$dotnet=@((Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'))|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
New-Item -ItemType Directory -Force -Path $Evidence|Out-Null
$log=Join-Path $Evidence (($Phase+$(if($Phase -eq 'scenario'){'-'+$Scenario}elseif($Phase -eq 'install-other'){'-'+$Label}else{''}))+'.log')
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
    $parts=foreach($name in $names){
        $path=Join-Path $local $name
        if(Test-Path -LiteralPath $path){
            $base=(Get-Item -LiteralPath $path -Force).FullName
            $items=@(Get-Item -LiteralPath $path -Force)+@(Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue)
            $text=(@($items|ForEach-Object {$_.FullName.Substring($base.Length)+'|'+$(if($_.PSIsContainer){'dir'}else{$_.Length})+'|'+$_.LastWriteTimeUtc.Ticks})|Sort-Object) -join "`n"
            $name+'|'+$items.Count+'|'+[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','')
        } else {$name+'|<missing>'}
    }
    $key=Get-Item -LiteralPath ('Registry::'+$markerKey) -ErrorAction SilentlyContinue
    $marks=if($key){@($key.GetValueNames()|Sort-Object|ForEach-Object {$_+'='+$key.GetValue($_)})}else{@('<no marker key>')}
    (@($parts)+@($marks)) -join "`n"
}
function Run([string]$Name,[scriptblock]$Body,[switch]$GuardData){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $dataBefore=if($GuardData){Get-DataFolderState}
    $ErrorActionPreference='Continue'
    $global:LASTEXITCODE=0
    $output=[Collections.Generic.List[string]]::new()
    try {& $Body 2>&1|ForEach-Object {$output.Add([string]$_)};$code=$LASTEXITCODE}
    catch {$output.Add(($_|Out-String));$code=1}
    $output|Set-Content -LiteralPath (Join-Path $Evidence ($Phase+'-'+$Name+'.txt')) -Encoding UTF8
    $passes=@($output|Where-Object {$_ -cmatch '^PASS '}).Count
    $fails=@($output|Where-Object {$_ -cmatch '^FAIL '}).Count
    $skips=@($output|Where-Object {$_ -cmatch '^SKIP'})
    $last=@($output|Where-Object {$_.Trim()}|Select-Object -Last 1)
    if($GuardData){$dataAfter=Get-DataFolderState;Check ($dataAfter -eq $dataBefore) ($Name+' left the real data folders and the protection markers as it found them') $(if($dataAfter -ne $dataBefore){(@(Compare-Object ($dataBefore -split "`n") ($dataAfter -split "`n")|Select-Object -First 4|ForEach-Object {$_.SideIndicator+' '+$_.InputObject}) -join ' // ')}else{'same'})}
    Check ($code -eq 0 -and $skips.Count -eq 0) ($Name+' exit '+$code+' in '+[Math]::Round($clock.Elapsed.TotalSeconds)+' s; PASS lines '+$passes+', FAIL lines '+$fails+', SKIP lines '+$skips.Count+'; last line: '+([string]$last).Substring(0,[Math]::Min(120,([string]$last).Length))) (@($output|Where-Object {$_ -match 'FAIL|error|Exception|^SKIP'}|Select-Object -First 3) -join ' / ')
}
function Uninstall-App {
    $uninstaller=Get-ChildItem -LiteralPath $app -Filter 'unins*.exe' -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $uninstaller){return 'not installed'}
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue|Stop-Process -Force
    $p=Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
    for($i=0;$i -lt 60 -and (Test-Path -LiteralPath (Join-Path $app 'app'));$i++){Start-Sleep 1}
    'exit='+$p.ExitCode+' appLeft='+(Test-Path -LiteralPath (Join-Path $app 'app'))
}
function Stop-AfterInstall {
    Start-Sleep -Seconds 3
    Get-CimInstance Win32_Process -Filter "Name='notepad.exe'" -ErrorAction SilentlyContinue|Where-Object {$_.CommandLine -match 'README'}|ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue
}
function Get-MachineState {
    $hypervisor=@((Invoke-Native bcdedit.exe @('/enum','{current}')).Text -split "`n"|Where-Object {$_ -match 'hypervisorlaunchtype'})
    $guard=Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
    $rename=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    $transparency=(Get-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency
    [ordered]@{
        hypervisorlaunchtype=($hypervisor -join ';').Trim()
        vbsStatus=[string]@($guard|ForEach-Object {$_.VirtualizationBasedSecurityStatus})
        vbsRunning=(@($guard|ForEach-Object {$_.SecurityServicesRunning}) -join ',')
        rebootPendingCbs=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        rebootRequiredUpdate=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        pendingFileRenames=(@($rename)-join '|')
        tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -match 'OptimizationSuite|Protected Session|RooIndustries' -and $_.TaskName -ne 'RooIndustries_VerifyRun'}|ForEach-Object {$_.TaskPath+$_.TaskName}|Sort-Object)
        productKeys=@($productKeys|Where-Object {Test-Path -LiteralPath $_})
        uninstallEntries=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue|Where-Object {$_.PSChildName -match 'RooIndustries|OptimizationSuite' -or $_.PSChildName -like '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}*'}|ForEach-Object PSChildName)
        appFolder=(Test-Path -LiteralPath 'C:\Program Files\Roo Industries')
        enableTransparency=$(if($null -ne $transparency){[string]$transparency}else{'<absent>'})
        ifeoProbeKey=(Test-Path -LiteralPath $ifeoProbe)
        localSiblings=@(Get-ChildItem -LiteralPath $local -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'OptimizationSuite'}|ForEach-Object Name|Sort-Object)
        userEnvironmentNames=@((Get-Item -LiteralPath $userEnvironment).GetValueNames()|Sort-Object)
    }
}
function Show-Difference($Expected,$Actual){(@(Compare-Object $Expected $Actual|Select-Object -First 3|ForEach-Object {$_.SideIndicator+' '+$_.InputObject}) -join ' // ')}
function Get-RegistryFingerprint([string]$Key) {
    $item=Get-Item -LiteralPath ('Registry::'+$Key) -ErrorAction SilentlyContinue
    if(-not $item){return '<absent>'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        foreach($node in @($item)+@(Get-ChildItem -LiteralPath ('Registry::'+$Key) -Recurse -ErrorAction SilentlyContinue)){
            $bytes=[Text.Encoding]::UTF8.GetBytes($node.Name+"`n");[void]$sha.TransformBlock($bytes,0,$bytes.Length,$null,0)
            foreach($name in @($node.GetValueNames()|Sort-Object)){
                $value=$node.GetValue($name,$null,'DoNotExpandEnvironmentNames')
                $bytes=if($value -is [byte[]]){$value}else{[Text.Encoding]::UTF8.GetBytes((@($value) -join "`n"))}
                $head=[Text.Encoding]::UTF8.GetBytes($name+'|'+$node.GetValueKind($name)+'|'+$bytes.Length+"`n");[void]$sha.TransformBlock($head,0,$head.Length,$null,0)
                [void]$sha.TransformBlock($bytes,0,$bytes.Length,$null,0)
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    } finally {$sha.Dispose()}
}
function Get-TreeFingerprint([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)){return @('<missing>')}
    $base=(Get-Item -LiteralPath $Path -Force).FullName
    $items=@(Get-Item -LiteralPath $Path -Force)+@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
    @($items|ForEach-Object {
        $acl=Get-Acl -LiteralPath $_.FullName
        $_.FullName.Substring($base.Length)+'|'+$(if($_.PSIsContainer){'dir'}else{$_.Length})+'|'+$_.LastWriteTimeUtc.ToString('o')+'|'+[string]$_.Attributes+'|'+$acl.Sddl
    }|Sort-Object)
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

function Restore-Folder([string]$Name){
    $path=Join-Path $local $Name
    $saved=Join-Path $backup $Name
    if(-not (Test-Path -LiteralPath $saved)){
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force;Log "removed $path"}
        Check (-not (Test-Path -LiteralPath $path)) ($Name+' did not exist before this run and is gone now') $path
        return
    }
    $stage=$path+'.roo-industries-restore'
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    $copy=Invoke-Native robocopy.exe @($saved,$stage,'/E','/COPYALL','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NP')
    $expected=@(Get-Content -LiteralPath (Join-Path $backup ($Name+'.fingerprint.txt')) -Encoding UTF8)
    $difference=@(Compare-Object $expected @(Get-TreeFingerprint $stage))
    Check ($copy.Exit -lt 8 -and $difference.Count -eq 0) ('the copy of '+$Name+' made for the restore matches the backup (names, sizes, times, attributes, permissions) before the live folder is touched') ('robocopy exit '+$copy.Exit+'; '+$expected.Count+' items; '+$difference.Count+' differ'+$(if($difference.Count){': '+(Show-Difference $expected @(Get-TreeFingerprint $stage))}))
    if($copy.Exit -ge 8 -or $difference.Count){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue;Log "the live folder $path was left in place because the restore copy is not trusted; the backup is at $saved";return}
    try {
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force;Log "removed $path"}
        Rename-Item -LiteralPath $stage -NewName $Name
    } catch {Check $false ('the restored copy of '+$Name+' could not replace the live folder') $_.Exception.Message;return}
    $difference=@(Compare-Object $expected @(Get-TreeFingerprint $path))
    Check ($difference.Count -eq 0) ('restored '+$Name+' matches the backup (names, sizes, times, attributes, permissions)') ($expected.Count.ToString()+' items; '+$difference.Count+' differ'+$(if($difference.Count){': '+(Show-Difference $expected @(Get-TreeFingerprint $path))}else{''}))
}
function Restore-AppData {
    $before=if(Test-Path -LiteralPath (Join-Path $backup 'machine-state.json')){Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json}
    foreach($name in 'RooIndustriesOptimizationSuite',('RooIndustriesOptimizationSuite' -replace 'Industries',''),'RooIndustriesOptimizationSuite.Timer'){Restore-Folder $name}
    if($before){
        foreach($sibling in @(Get-ChildItem -LiteralPath $local -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'OptimizationSuite' -and @($before.localSiblings) -notcontains $_.Name})){Remove-Item -LiteralPath $sibling.FullName -Recurse -Force -ErrorAction SilentlyContinue;Log ('removed '+$sibling.FullName+' (created by this run)')}
        Check ((@(Get-ChildItem -LiteralPath $local -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'OptimizationSuite'}|ForEach-Object Name|Sort-Object) -join '|') -eq (@($before.localSiblings) -join '|')) 'the folders next to the data folder are the ones that existed before this run' ((@($before.localSiblings) -join '|'))
    }
    Invoke-Native reg.exe @('delete',$rooHklm,'/f')|Out-Null
    if(Test-Path -LiteralPath (Join-Path $backup 'hklm-roo-industries.reg')){$import=Invoke-Native reg.exe @('import',(Join-Path $backup 'hklm-roo-industries.reg'));Log ('HKLM\SOFTWARE\RooIndustries restored, exit '+$import.Exit)}
    else{Log 'HKLM\SOFTWARE\RooIndustries did not exist before this run; removed'}
    $stateBefore=if($before){$before.tweakStateKey}
    if(Test-Path -LiteralPath (Join-Path $backup 'tweak-state.reg')){
        Invoke-Native reg.exe @('delete',$stateKey,'/f')|Out-Null
        $stateImport=Invoke-Native reg.exe @('import',(Join-Path $backup 'tweak-state.reg'));Log ('Windows tweak state restored, exit '+$stateImport.Exit)
    }
    elseif($stateBefore -eq '<absent>'){Invoke-Native reg.exe @('delete',$stateKey,'/f')|Out-Null;Log 'Windows tweak state did not exist before this run; removed'}
    else{Log 'Windows tweak state was not backed up by this run; left as it is'}
}

switch($Phase){
    'preflight' {
        if(@(Get-Process cs2 -ErrorAction SilentlyContinue).Count){throw 'CS2 is running.'}
        $busy=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like '*OptimizationSuite.ProcessRules.*' -or $_.TaskName -like 'RooIndustries_Governor*' -or ($_.TaskName -like 'Roo Industries Protected Session*' -and [string]$_.State -eq 'Running')})
        if($busy.Count){throw ('Other Roo Industries test tasks exist: '+(($busy|ForEach-Object TaskName) -join ', '))}
        if(Test-Path -LiteralPath $backup){throw "A backup from an earlier run is still at $backup; restore it with -Phase cleanup first."}
        if(@((Get-Item -LiteralPath $userEnvironment).GetValueNames()) -contains $plantedName){throw ($plantedName+' is already set in the user environment; the launcher scenarios plant it and would hide it. Remove it first.')}
        if((Test-Path -LiteralPath (Join-Path $app 'app')) -and -not $ReplaceExisting){throw 'The app is already installed on this PC. This run uninstalls it and cannot put it back; pass -ReplaceExisting to allow that.'}
        New-Item -ItemType Directory -Force -Path $backup|Out-Null
        try {
            foreach($name in 'RooIndustriesOptimizationSuite',('RooIndustriesOptimizationSuite' -replace 'Industries',''),'RooIndustriesOptimizationSuite.Timer'){
                $path=Join-Path $local $name
                if(Test-Path -LiteralPath $path){
                    $copy=Invoke-Native robocopy.exe @($path,(Join-Path $backup $name),'/E','/COPYALL','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NP');Log ("backed up $path (robocopy exit "+$copy.Exit+')')
                    if($copy.Exit -ge 8){throw ('The backup of '+$path+' failed (robocopy exit '+$copy.Exit+'); nothing was changed.')}
                    $liveItems=@(Get-TreeFingerprint $path);$saved=@(Get-TreeFingerprint (Join-Path $backup $name))
                    if(@(Compare-Object $liveItems $saved).Count){$liveItems|Set-Content -LiteralPath (Join-Path $Evidence ('preflight-'+$name+'-live.txt')) -Encoding UTF8;$saved|Set-Content -LiteralPath (Join-Path $Evidence ('preflight-'+$name+'-backup.txt')) -Encoding UTF8;throw ('The backup of '+$path+' does not match it (source '+$liveItems.Count+' items, backup '+$saved.Count+' items; '+(Show-Difference $liveItems $saved)+'); nothing was changed.')}
                    $liveItems|Set-Content -LiteralPath (Join-Path $backup ($name+'.fingerprint.txt')) -Encoding UTF8
                }
            }
            $export=Invoke-Native reg.exe @('export',$rooHklm,(Join-Path $backup 'hklm-roo-industries.reg'),'/y')
            Log ('HKLM\SOFTWARE\RooIndustries export exit '+$export.Exit+$(if($export.Exit -ne 0){' (no such key before this run)'}else{''}))
            $state=Get-MachineState
            $state.tweakStateKey=Get-RegistryFingerprint $stateKey
            $state.rooHklmFingerprint=Get-RegistryFingerprint $rooHklm
            if($state.tweakStateKey -ne '<absent>'){$tweakExport=Invoke-Native reg.exe @('export',$stateKey,(Join-Path $backup 'tweak-state.reg'),'/y');Log ('Windows tweak state export exit '+$tweakExport.Exit)}
            $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Encoding UTF8
            Log ('machine state before: '+($state|ConvertTo-Json -Depth 5 -Compress))
            Log ('installed='+(Test-Path -LiteralPath (Join-Path $app 'app'))+' dotnet='+$dotnet)
        } catch {Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue;throw}
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
            'optimizer-host'={Protect-RealDataFolder;Invoke-Suite 'backend\scripts\Test-OptimizerHost.ps1' @('-DotNetPath',$dotnet)}
            'data-root-marker-paths'={Invoke-Suite 'backend\scripts\Test-DataRootMarkerPaths.ps1'}
            'governor-setup-legacy-pause'={Invoke-Suite 'backend\scripts\Test-GovernorSetupLegacyPause.ps1'}
            'earlier-version-gate'={Invoke-Suite 'backend\scripts\Test-EarlierVersionGate.ps1' @('-DotNetPath',$dotnet)}
            'script-parser'={Invoke-Suite 'tools\scripts\Test-Baseline.ps1' @('-ParseOnly')}
            'governor-scenarios'={Invoke-Suite 'backend\scripts\Test-GovernorScenarios.ps1' @('-DotNetPath',$dotnet)}
        }
        $Only=@($Only|ForEach-Object {$_ -split ','}|Where-Object {$_})
        foreach($name in $all.Keys){if($Only.Count -eq 0 -or $Only -contains $name){Run $name $all[$name] -GuardData:($name -ne 'optimizer-host')}}
        if(Test-Path -LiteralPath $backup){Restore-AppData}
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
        Log ('previous install removed: '+(Uninstall-App))
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
        Log ('previous install removed: '+(Uninstall-App))
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
        $root=Join-Path $Evidence 'scenarios'
        $arguments=@{Label=$Scenario;Scenario=$Scenario;OutRoot=$root;Minutes=$Minutes}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $ErrorActionPreference='Continue'
        $console=@()
        try {$console=@(& (Join-Path $Source 'tools\validation\LoadTimes\Invoke-LoadTimes.ps1') @arguments 2>&1|ForEach-Object {[string]$_})}
        catch {$console+=('Invoke-LoadTimes stopped: '+($_|Out-String));Check $false ('scenario '+$Scenario+' could not run') $_.Exception.Message}
        $ErrorActionPreference='Stop'
        $console|Set-Content -LiteralPath (Join-Path $Evidence ('scenario-'+$Scenario+'-console.txt')) -Encoding UTF8
        $dir=Join-Path $root $Scenario
        $scenarioLog=Join-Path $dir $(if($Scenario -eq 'loadtimes'){'loadtimes.log'}else{$Scenario+'.log'})
        $done=Join-Path $dir $(if($Scenario -eq 'loadtimes'){'measure.done'}else{$Scenario+'.done'})
        $lines=@(if(Test-Path -LiteralPath $scenarioLog){Get-Content -LiteralPath $scenarioLog -Encoding UTF8})
        $passed=@($lines|Where-Object {$_ -cmatch '^\S+ PASS '}).Count
        $failed=@($lines|Where-Object {$_ -cmatch '^\S+ FAIL '}).Count
        $skipped=@($lines|Where-Object {$_ -cmatch '^\S+ SKIPPED '})
        $cleanup=@($lines|Where-Object {$_ -match 'CLEANUP NEEDED'})+@($console|Where-Object {$_ -match 'CLEANUP NEEDED'})
        $result=@($lines|Where-Object {$_ -match 'RESULT failures=(\d+)'})|Select-Object -Last 1
        foreach($line in $lines){
            if($line -cmatch '^\S+ (PASS|FAIL|SKIPPED) (.*)$'){$text=$Matches[2];$length=[Math]::Min(700,$text.Length);Log ($Matches[1]+' '+$text.Substring(0,$length))}
            elseif($line -cmatch '^\S+ NOT RUN (.*)$'){Log ('NOTE not run: '+$Matches[1])}
        }
        if($Scenario -eq 'loadtimes'){
            $rows=@(if(Test-Path -LiteralPath (Join-Path $dir 'loadtimes.csv')){Import-Csv -LiteralPath (Join-Path $dir 'loadtimes.csv')})
            $bad=@($rows|Where-Object {$_.note -match 'timeout|error'})
            Check ((Test-Path -LiteralPath $done) -and $rows.Count -gt 0 -and $bad.Count -eq 0) 'loadtimes finished and no page timed out or failed' ('rows='+$rows.Count+' bad='+$bad.Count+' '+(@($bad|Select-Object -First 3|ForEach-Object {$_.page+' '+$_.visit+' '+$_.note}) -join ' / '))
        } else {
            Check ((Test-Path -LiteralPath $done) -and $failed -eq 0 -and $passed -gt 0 -and $result -match 'RESULT failures=0') ('scenario '+$Scenario+': PASS '+$passed+' FAIL '+$failed+' SKIPPED '+$skipped.Count) ($(if($result){$result}else{'no RESULT line'})+$(if(-not (Test-Path -LiteralPath $done)){' (not finished)'}else{''}))
            Check ($skipped.Count -eq 0) ('scenario '+$Scenario+' skipped no check') (($skipped|Select-Object -First 3) -join ' / ')
        }
        Check ($cleanup.Count -eq 0) ('scenario '+$Scenario+' left nothing to clean up by hand') ($cleanup -join ' / ')
        Log ('scenario '+$Scenario+' took '+[Math]::Round($clock.Elapsed.TotalMinutes,1)+' min; evidence '+$dir)
    }
    'uninstall' {
        $before=@(Get-ChildItem -LiteralPath $app -Filter 'unins*.exe' -ErrorAction SilentlyContinue).Count
        $result=Uninstall-App
        Log ('uninstall: '+$result)
        Check ($before -ge 1 -and $result -match 'exit=0 appLeft=False') 'the installed app was uninstalled by its own uninstaller' $result
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
            $failed=@($lines|Where-Object {$_ -cmatch '^\S+ FAIL '}).Count
            $skipped=@($lines|Where-Object {$_ -cmatch '^\S+ SKIPPED '}).Count
            Check ((Test-Path -LiteralPath $file) -and $failed -eq 0 -and $skipped -eq 0 -and ($passLines.Count -gt 0 -or $name -eq 'preflight')) ('phase '+$name+': PASS '+$passLines.Count+' FAIL '+$failed+' SKIPPED '+$skipped) $(if(Test-Path -LiteralPath $file){$file}else{'no log was written'})
            foreach($needle in @($requiredChecks[$name])){
                $found=@($passLines|Where-Object {$_ -like ('*'+$needle+'*')}).Count
                Check ($found -ge 1) ('phase '+$name+' ran the check: '+$needle) ('passed '+$found+' time(s)')
            }
        }
    }
    'cleanup' {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($app+'\',[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object {Log ('stopped '+$_.Name+' from the install folder before the uninstall');Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
        Log ('uninstall: '+(Uninstall-App))
        $probeNames='RooIndustriesMigrationProbe','RooIndustriesLoadTimesProbe','RooIndustriesLauncherProbe','RooIndustriesProtectedLauncherProbe','RooIndustriesProtectedGameProbe','RooIndustriesEnvironmentControl','RooIndustriesGovernorProbe'
        Get-Process $probeNames -ErrorAction SilentlyContinue|ForEach-Object {Log ('stopped leftover probe '+$_.Name);Stop-Process -Id $_.Id -Force}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($app+'\',[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object {Log ('stopped leftover process '+$_.Name+' from the install folder');Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
        Start-Sleep -Milliseconds 500
        foreach($leftover in @($probeNames|ForEach-Object {$_+'.exe'})+@('roo-industries-migration-state.json')){$leftoverPath=Join-Path $env:TEMP $leftover;if(Test-Path -LiteralPath $leftoverPath){Remove-Item -LiteralPath $leftoverPath -Force -ErrorAction SilentlyContinue;Log ('removed '+$leftoverPath)}}
        $governorWork=Join-Path $env:TEMP 'roo-industries-governor-installed'
        if(Test-Path -LiteralPath $governorWork){Remove-Item -LiteralPath $governorWork -Recurse -Force -ErrorAction SilentlyContinue;Log ('removed '+$governorWork)}
        $tasksBefore=if(Test-Path -LiteralPath (Join-Path $backup 'machine-state.json')){@((Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json).tasks)}else{$null}
        foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*','RooIndustriesOptimizationSuite.GovernorSetupWatchdog','RooIndustries_LoadTimes','RooIndustries_EnvironmentControl','RooIndustries.Timer.*','Roo Industries Protected Session*' -ErrorAction SilentlyContinue)){
            if($null -eq $tasksBefore){Log ('kept task '+$task.TaskName+' (there is no record of the tasks before this run)');continue}
            if($tasksBefore -contains ($task.TaskPath+$task.TaskName)){Log ('kept task '+$task.TaskName+' (it existed before this run)');continue}
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false;Log ('removed task '+$task.TaskName)
        }
        $planted=(Get-ItemProperty -LiteralPath $userEnvironment -Name $plantedName -ErrorAction SilentlyContinue).$plantedName
        if($null -ne $planted){if($planted -ceq $plantedValue){Remove-ItemProperty -LiteralPath $userEnvironment -Name $plantedName;Log ('removed '+$plantedName+' (the harmless value the launcher scenarios plant) from the user environment')}else{Log ('CLEANUP NEEDED: '+$plantedName+' in the user environment is not the value the scenarios plant; left as it is')}}
        if(Test-Path -LiteralPath $backup){
            Restore-AppData
            $before=if(Test-Path -LiteralPath (Join-Path $backup 'machine-state.json')){Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json}
            if($before){
                if($before.enableTransparency -ne '<absent>' -and [string](Get-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency -ne [string]$before.enableTransparency){Set-ItemProperty $personalize -Name EnableTransparency -Value ([int]$before.enableTransparency) -Type DWord;Log ('EnableTransparency set back to '+$before.enableTransparency)}
                if(-not $before.ifeoProbeKey -and (Test-Path -LiteralPath $ifeoProbe)){Remove-Item -LiteralPath $ifeoProbe -Recurse -Force;Log 'removed the protected-session probe image key'}
                $now=Get-MachineState
                $now.tweakStateKey=Get-RegistryFingerprint $stateKey
                $now.rooHklmFingerprint=Get-RegistryFingerprint $rooHklm
                foreach($field in 'hypervisorlaunchtype','vbsStatus','vbsRunning','rebootPendingCbs','rebootRequiredUpdate','appFolder','tweakStateKey','rooHklmFingerprint','enableTransparency','ifeoProbeKey'){Check ([string]$now[$field] -eq [string]$before.$field) ('machine state unchanged: '+$field) ('before='+[string]$before.$field+' now='+[string]$now[$field])}
                $added=@(([string]$now.pendingFileRenames -split '\|')|Where-Object {$_ -and ([string]$before.pendingFileRenames).IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -lt 0})
                Check ($added.Count -eq 0) 'no pending file rename was added by this run (a restart may have processed older ones)' ('added='+($added -join '|'))
                foreach($field in 'tasks','productKeys','uninstallEntries','localSiblings','userEnvironmentNames'){Check ((@($now[$field])-join '|') -eq (@($before.$field)-join '|')) ('machine state unchanged: '+$field) ('before='+(@($before.$field)-join '|')+' now='+(@($now[$field])-join '|'))}
            }
            if($script:Failures -eq 0){Remove-Item -LiteralPath $backup -Recurse -Force;Log ('removed the backup at '+$backup+' after every restore check passed')}
            else{Log ('the backup is kept at '+$backup+' because a restore check failed')}
        }
    }
}
if($script:Failures){exit 1}
