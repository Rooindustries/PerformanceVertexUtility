param(
    [Parameter(Mandatory=$true)][ValidateSet('preflight','validators','release-build','install-old','upgrade','install-other','static-checks','scenario','setup-fallbacks','summary','cleanup')][string]$Phase,
    [ValidateSet('loadtimes','invalidation','modes','migration-before','migration-after','permissions','hardware','launchers','override','incomplete','incomplete-before')][string]$Scenario='',
    [string]$Source=(Join-Path $env:TEMP 'roo-industries-integration-src'),
    [string]$Evidence=(Join-Path $env:TEMP 'roo-industries-integration-evidence'),
    [string]$OldInstaller='',
    [string]$NewInstaller='',
    [string]$OtherInstaller='',
    [string]$Label='other',
    [int]$Minutes=45,
    [string[]]$Only=@(),
    [string[]]$Expect=@('preflight','validators','release-build','install-old','scenario-migration-before','upgrade','scenario-migration-after','static-checks','scenario-permissions','scenario-launchers','scenario-override','scenario-incomplete','scenario-invalidation','scenario-modes','setup-fallbacks','scenario-hardware','scenario-loadtimes'),
    [switch]$TestHooks,
    [string]$BuildOutput=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$app='C:\Program Files\Roo Industries\Optimization Suite'
$local=[Environment]::GetFolderPath('LocalApplicationData')
$markerKey='HKLM\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$stateKey='HKLM\SOFTWARE\RooIndustriesOptimizationSuite'
$personalize='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$ifeoProbe='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooProtectedGameProbe.exe'
$productKeys=@('HKLM:\SOFTWARE\RooIndustries\OptimizationSuite','HKLM:\SOFTWARE\RooIndustries')
$backup=Join-Path $Evidence 'backup'
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
function Run([string]$Name,[scriptblock]$Body){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $ErrorActionPreference='Continue'
    $global:LASTEXITCODE=0
    $output=[Collections.Generic.List[string]]::new()
    try {& $Body 2>&1|ForEach-Object {$output.Add([string]$_)};$code=$LASTEXITCODE}
    catch {$output.Add(($_|Out-String));$code=1}
    $output|Set-Content -LiteralPath (Join-Path $Evidence ($Phase+'-'+$Name+'.txt')) -Encoding UTF8
    Check ($code -eq 0) ($Name+' exit '+$code+' in '+[Math]::Round($clock.Elapsed.TotalSeconds)+' s') (@($output|Where-Object {$_ -match 'FAIL|error|Exception'}|Select-Object -First 3) -join ' / ')
}
function Uninstall-App {
    $uninstaller=Get-ChildItem -LiteralPath $app -Filter 'unins*.exe' -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $uninstaller){return 'not installed'}
    Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue|Stop-Process -Force
    $p=Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
    for($i=0;$i -lt 60 -and (Test-Path -LiteralPath (Join-Path $app 'app'));$i++){Start-Sleep 1}
    'exit='+$p.ExitCode+' appLeft='+(Test-Path -LiteralPath (Join-Path $app 'app'))
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
        tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -match 'Roo'}|ForEach-Object {$_.TaskPath+$_.TaskName}|Sort-Object)
        productKeys=@($productKeys|Where-Object {Test-Path -LiteralPath $_})
        uninstallEntries=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue|Where-Object {$_.PSChildName -match 'Roo' -or $_.PSChildName -like '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}*'}|ForEach-Object PSChildName)
        appFolder=(Test-Path -LiteralPath 'C:\Program Files\Roo Industries')
        enableTransparency=$(if($null -ne $transparency){[string]$transparency}else{'<absent>'})
        ifeoProbeKey=(Test-Path -LiteralPath $ifeoProbe)
    }
}
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
    $items=@(Get-Item -LiteralPath $Path -Force)+@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)
    @($items|ForEach-Object {
        $acl=Get-Acl -LiteralPath $_.FullName
        $_.FullName.Substring($Path.Length)+'|'+$(if($_.PSIsContainer){'dir'}else{$_.Length})+'|'+$_.LastWriteTimeUtc.ToString('o')+'|'+[string]$_.Attributes+'|'+$acl.Sddl
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

function Restore-AppData {
    foreach($name in 'RooIndustriesOptimizationSuite','RooOptimizationSuite'){
        $path=Join-Path $local $name
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force;Log "removed $path"}
        if(Test-Path -LiteralPath (Join-Path $backup $name)){
            $copy=Invoke-Native robocopy.exe @((Join-Path $backup $name),$path,'/E','/COPYALL','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NP');Log ("restored $path (robocopy exit "+$copy.Exit+')')
            $expected=@(Get-Content -LiteralPath (Join-Path $backup ($name+'.fingerprint.txt')) -Encoding UTF8)
            $actual=@(Get-TreeFingerprint $path)
            $difference=@(Compare-Object $expected $actual)
            Check ($difference.Count -eq 0) ('restored '+$name+' matches the backup (names, sizes, times, attributes, permissions)') ($expected.Count.ToString()+' items; '+$difference.Count+' differ'+$(if($difference.Count){': '+(($difference|Select-Object -First 3|ForEach-Object {$_.SideIndicator+' '+$_.InputObject}) -join ' // ')}else{''}))
        }
        else {Check (-not (Test-Path -LiteralPath $path)) ($name+' did not exist before this run and is gone now') $path}
    }
    foreach($leftover in @(Get-ChildItem -LiteralPath $local -Directory -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'OptimizationSuite\.'})){Log ('leftover next to the data folder: '+$leftover.Name)}
    Invoke-Native reg.exe @('delete',$markerKey,'/f')|Out-Null
    $stateBefore=if(Test-Path -LiteralPath (Join-Path $backup 'machine-state.json')){(Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json).tweakStateKey}
    if(Test-Path -LiteralPath (Join-Path $backup 'tweak-state.reg')){
        Invoke-Native reg.exe @('delete',$stateKey,'/f')|Out-Null
        $stateImport=Invoke-Native reg.exe @('import',(Join-Path $backup 'tweak-state.reg'));Log ('Windows tweak state restored, exit '+$stateImport.Exit)
    }
    elseif($stateBefore -eq '<absent>'){Invoke-Native reg.exe @('delete',$stateKey,'/f')|Out-Null;Log 'Windows tweak state did not exist before this run; removed'}
    else{Log 'Windows tweak state was not backed up by this run; left as it is'}
    if(Test-Path -LiteralPath (Join-Path $backup 'markers.reg')){$import=Invoke-Native reg.exe @('import',(Join-Path $backup 'markers.reg'));Log ('markers restored, exit '+$import.Exit)}
}

switch($Phase){
    'preflight' {
        if(@(Get-Process cs2 -ErrorAction SilentlyContinue).Count){throw 'CS2 is running.'}
        $busy=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like '*OptimizationSuite.ProcessRules.*' -or $_.TaskName -like 'RooIndustries_Governor*' -or ($_.TaskName -like 'Roo Industries Protected Session*' -and [string]$_.State -eq 'Running')})
        if($busy.Count){throw ('Other Roo Industries test tasks exist: '+(($busy|ForEach-Object TaskName) -join ', '))}
        if(Test-Path -LiteralPath $backup){throw "A backup from an earlier run is still at $backup; restore it with -Phase cleanup first."}
        New-Item -ItemType Directory -Force -Path $backup|Out-Null
        foreach($name in 'RooIndustriesOptimizationSuite','RooOptimizationSuite'){
            $path=Join-Path $local $name
            if(Test-Path -LiteralPath $path){$copy=Invoke-Native robocopy.exe @($path,(Join-Path $backup $name),'/E','/COPYALL','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NP');Log ("backed up $path (robocopy exit "+$copy.Exit+')');if($copy.Exit -ge 8){throw ('The backup of '+$path+' failed (robocopy exit '+$copy.Exit+'); nothing was changed.')}
                $source=@(Get-TreeFingerprint $path);$saved=@(Get-TreeFingerprint (Join-Path $backup $name))
                if(@(Compare-Object $source $saved).Count){throw ('The backup of '+$path+' does not match it; nothing was changed.')}
                $source|Set-Content -LiteralPath (Join-Path $backup ($name+'.fingerprint.txt')) -Encoding UTF8}
        }
        $export=Invoke-Native reg.exe @('export',$markerKey,(Join-Path $backup 'markers.reg'),'/y')
        Log ('marker export exit '+$export.Exit+$(if($export.Exit -ne 0){' (no marker key before this run)'}else{''}))
        $state=Get-MachineState
        $state.tweakStateKey=Get-RegistryFingerprint $stateKey
        if($state.tweakStateKey -ne '<absent>'){$tweakExport=Invoke-Native reg.exe @('export',$stateKey,(Join-Path $backup 'tweak-state.reg'),'/y');Log ('Windows tweak state export exit '+$tweakExport.Exit)}
        $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Encoding UTF8
        Log ('machine state before: '+($state|ConvertTo-Json -Depth 5 -Compress))
        Log ('installed='+(Test-Path -LiteralPath (Join-Path $app 'app'))+' dotnet='+$dotnet)
    }
    'validators' {
        $env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
        $all=[ordered]@{
            'optimizer-core'={& (Join-Path $Source 'backend\scripts\Test-OptimizerCore.ps1') -DotNetPath $dotnet}
            'build-host'={& (Join-Path $Source 'backend\scripts\Build-OptimizerHost.ps1') -DotNetPath $dotnet}
            'tweaks'={& (Join-Path $Source 'backend\scripts\Test-Tweaks.ps1') -DotNetPath $dotnet}
            'process-policy-worker'={& (Join-Path $Source 'backend\scripts\Test-ProcessPolicyWorker.ps1') -DotNetPath $dotnet}
            'protected-sessions'={& (Join-Path $Source 'backend\scripts\Test-ProtectedGameSessions.ps1') -DotNetPath $dotnet}
            'tool-launcher'={& (Join-Path $Source 'tools\scripts\Test-ToolLauncher.ps1') -DotNetPath $dotnet}
            'frontend'={& (Join-Path $Source 'tools\scripts\Test-Frontend.ps1') -DotNetPath $dotnet}
            'client-cleanup-boundary'={& (Join-Path $Source 'backend\scripts\Test-ClientCleanupBoundary.ps1') -DotNetPath $dotnet}
        }
        $Only=@($Only|ForEach-Object {$_ -split ','}|Where-Object {$_})
        foreach($name in $all.Keys){if($Only.Count -eq 0 -or $Only -contains $name){Run $name $all[$name]}}
        if(Test-Path -LiteralPath $backup){Restore-AppData}
    }
    'release-build' {
        $buildArguments=@{}
        if($TestHooks){$buildArguments.TestHooks=$true}
        if($BuildOutput){$buildArguments.OutputRoot=$BuildOutput}
        Run ('build-release'+$(if($TestHooks){'-test-hooks'}else{''})) {& (Join-Path $Source 'tools\scripts\Build-Release.ps1') @buildArguments}
    }
    'install-old' {
        Log ('previous install removed: '+(Uninstall-App))
        Run 'install-old' {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $OldInstaller -OutDir (Join-Path $Evidence 'install-old')}
        $fingerprint=Get-InstalledFingerprint
        $fingerprint|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence 'installed-old.json') -Encoding UTF8
        Log ('installed after install-old: '+($fingerprint|ConvertTo-Json -Compress)+' installer sha256='+(Get-FileHash -LiteralPath $OldInstaller -Algorithm SHA256).Hash)
    }
    'upgrade' {
        $old=if(Test-Path -LiteralPath (Join-Path $Evidence 'installed-old.json')){Get-Content -LiteralPath (Join-Path $Evidence 'installed-old.json') -Raw|ConvertFrom-Json}
        Run 'upgrade' {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $NewInstaller -OutDir (Join-Path $Evidence 'upgrade')}
        $fingerprint=Get-InstalledFingerprint
        $fingerprint|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence 'installed-new.json') -Encoding UTF8
        Log ('installed after upgrade: '+($fingerprint|ConvertTo-Json -Compress)+' installer sha256='+(Get-FileHash -LiteralPath $NewInstaller -Algorithm SHA256).Hash)
        Check ($null -ne $old -and $old.app -ne $fingerprint.app -and $old.host -ne $fingerprint.host) 'the upgrade replaced the app and the helper assemblies (their hashes differ from the earlier install)' ('app '+$old.app+' -> '+$fingerprint.app+', host '+$old.host+' -> '+$fingerprint.host)
    }
    'install-other' {
        Log ('previous install removed: '+(Uninstall-App))
        Run ('install-'+$Label) {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $OtherInstaller -OutDir (Join-Path $Evidence ('install-'+$Label))}
        $fingerprint=Get-InstalledFingerprint
        $fingerprint|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence ('installed-'+$Label+'.json')) -Encoding UTF8
        Log ('installed '+$Label+': '+($fingerprint|ConvertTo-Json -Compress)+' installer sha256='+(Get-FileHash -LiteralPath $OtherInstaller -Algorithm SHA256).Hash)
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
        $skipped=@($lines|Where-Object {$_ -cmatch '^\S+ SKIPPED '}).Count
        $cleanup=@($lines|Where-Object {$_ -match 'CLEANUP NEEDED'})+@($console|Where-Object {$_ -match 'CLEANUP NEEDED'})
        $result=@($lines|Where-Object {$_ -match 'RESULT failures=(\d+)'})|Select-Object -Last 1
        if($Scenario -eq 'loadtimes'){
            $rows=@(if(Test-Path -LiteralPath (Join-Path $dir 'loadtimes.csv')){Import-Csv -LiteralPath (Join-Path $dir 'loadtimes.csv')})
            $bad=@($rows|Where-Object {$_.note -match 'timeout|error'})
            Check ((Test-Path -LiteralPath $done) -and $rows.Count -gt 0 -and $bad.Count -eq 0) 'loadtimes finished and no page timed out or failed' ('rows='+$rows.Count+' bad='+$bad.Count+' '+(@($bad|Select-Object -First 3|ForEach-Object {$_.page+' '+$_.visit+' '+$_.note}) -join ' / '))
        } else {
            Check ((Test-Path -LiteralPath $done) -and $failed -eq 0 -and $passed -gt 0 -and $result -match 'RESULT failures=0') ('scenario '+$Scenario+': PASS '+$passed+' FAIL '+$failed+' SKIPPED '+$skipped) ($(if($result){$result}else{'no RESULT line'})+$(if(-not (Test-Path -LiteralPath $done)){' (not finished)'}else{''}))
        }
        Check ($cleanup.Count -eq 0) ('scenario '+$Scenario+' left nothing to clean up by hand') ($cleanup -join ' / ')
        Log ('scenario '+$Scenario+' took '+[Math]::Round($clock.Elapsed.TotalMinutes,1)+' min; evidence '+$dir)
    }
    'setup-fallbacks' {
        Run 'setup-fallbacks' {& (Join-Path $Source 'tools\validation\Governor\Test-GovernorSetupFallbacks.ps1') -Script (Join-Path $Source 'backend\scripts\Invoke-GovernorSetup.ps1') -OutDir (Join-Path $Evidence 'setup-fallbacks')}
    }
    'summary' {
        foreach($name in $Expect){
            $file=Join-Path $Evidence ($name+'.log')
            $lines=@(if(Test-Path -LiteralPath $file){Get-Content -LiteralPath $file -Encoding UTF8})
            $passed=@($lines|Where-Object {$_ -cmatch '^\S+ PASS '}).Count
            $failed=@($lines|Where-Object {$_ -cmatch '^\S+ FAIL '}).Count
            Check ((Test-Path -LiteralPath $file) -and $failed -eq 0 -and ($passed -gt 0 -or $name -eq 'preflight')) ('phase '+$name+': PASS '+$passed+' FAIL '+$failed) $(if(Test-Path -LiteralPath $file){$file}else{'no log was written'})
        }
    }
    'cleanup' {
        Log ('uninstall: '+(Uninstall-App))
        Get-Process RooMigrationProbe,RooLoadTimesProbe,RooLauncherProbe,RooProtectedLauncherProbe -ErrorAction SilentlyContinue|ForEach-Object {Log ('stopped leftover probe '+$_.Name);Stop-Process -Id $_.Id -Force}
        Start-Sleep -Milliseconds 500
        foreach($leftover in 'RooMigrationProbe.exe','RooLoadTimesProbe.exe','RooLauncherProbe.exe','RooProtectedLauncherProbe.exe','RooProtectedGameProbe.exe','roo-industries-migration-state.json'){$leftoverPath=Join-Path $env:TEMP $leftover;if(Test-Path -LiteralPath $leftoverPath){Remove-Item -LiteralPath $leftoverPath -Force -ErrorAction SilentlyContinue;Log ('removed '+$leftoverPath)}}
        $tasksBefore=if(Test-Path -LiteralPath (Join-Path $backup 'machine-state.json')){@((Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json).tasks)}else{$null}
        foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*','RooIndustriesOptimizationSuite.GovernorSetupWatchdog','RooIndustries_LoadTimes','Roo Industries Protected Session*' -ErrorAction SilentlyContinue)){
            if($null -ne $tasksBefore -and $tasksBefore -contains ($task.TaskPath+$task.TaskName)){Log ('kept task '+$task.TaskName+' (it existed before this run)');continue}
            if($null -eq $tasksBefore -and $task.TaskName -like 'Roo Industries Protected Session*'){Log ('kept task '+$task.TaskName+' (no record of the tasks before this run)');continue}
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false;Log ('removed task '+$task.TaskName)
        }
        if(Test-Path -LiteralPath $backup){
            Restore-AppData
            $before=if(Test-Path -LiteralPath (Join-Path $backup 'machine-state.json')){Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json}
            if($before){
                foreach($key in $productKeys){
                    $item=Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
                    if($item -and @($before.productKeys) -notcontains $key -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0){Remove-Item -LiteralPath $key -Force;Log ('removed empty registry key '+$key+' created by this run')}
                }
                if($before.enableTransparency -ne '<absent>' -and [string](Get-ItemProperty $personalize -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency -ne [string]$before.enableTransparency){Set-ItemProperty $personalize -Name EnableTransparency -Value ([int]$before.enableTransparency) -Type DWord;Log ('EnableTransparency set back to '+$before.enableTransparency)}
                if(-not $before.ifeoProbeKey -and (Test-Path -LiteralPath $ifeoProbe)){Remove-Item -LiteralPath $ifeoProbe -Recurse -Force;Log 'removed the protected-session probe image key'}
                $now=Get-MachineState
                $now.tweakStateKey=Get-RegistryFingerprint $stateKey
                foreach($field in 'hypervisorlaunchtype','vbsStatus','vbsRunning','rebootPendingCbs','rebootRequiredUpdate','pendingFileRenames','appFolder','tweakStateKey','enableTransparency','ifeoProbeKey'){Check ([string]$now[$field] -eq [string]$before.$field) ('machine state unchanged: '+$field) ('before='+[string]$before.$field+' now='+[string]$now[$field])}
                foreach($field in 'tasks','productKeys','uninstallEntries'){Check ((@($now[$field])-join '|') -eq (@($before.$field)-join '|')) ('machine state unchanged: '+$field) ('before='+(@($before.$field)-join '|')+' now='+(@($now[$field])-join '|'))}
            }
            Rename-Item -LiteralPath $backup -NewName ('backup-restored-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
        }
    }
}
if($script:Failures){exit 1}
