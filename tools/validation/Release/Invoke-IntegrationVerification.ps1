param(
    [Parameter(Mandatory=$true)][ValidateSet('preflight','validators','release-build','install-old','upgrade','static-checks','setup-fallbacks','cleanup')][string]$Phase,
    [string]$Source=(Join-Path $env:TEMP 'roo-industries-integration-src'),
    [string]$Evidence=(Join-Path $env:TEMP 'roo-industries-integration-evidence'),
    [string]$OldInstaller='',
    [string]$NewInstaller=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$app='C:\Program Files\Roo Industries\Optimization Suite'
$local=[Environment]::GetFolderPath('LocalApplicationData')
$markerKey='HKLM\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$backup=Join-Path $Evidence 'backup'
$dotnet=@((Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'))|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
New-Item -ItemType Directory -Force -Path $Evidence|Out-Null
$log=Join-Path $Evidence ($Phase+'.log')
function Log([string]$Text){$line=[DateTime]::UtcNow.ToString('o')+' '+$Text;Add-Content -LiteralPath $log -Value $line -Encoding UTF8;$line}
function Check([bool]$Ok,[string]$Name,[string]$Detail=''){Log ($(if($Ok){'PASS '}else{'FAIL '})+$Name+' :: '+$Detail)}
function Run([string]$Name,[scriptblock]$Body){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $ErrorActionPreference='Continue'
    $global:LASTEXITCODE=0
    $output=@()
    try {$output=@(& $Body 2>&1|ForEach-Object {[string]$_});$code=$LASTEXITCODE}
    catch {$output+=($_|Out-String);$code=1}
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

switch($Phase){
    'preflight' {
        if(@(Get-Process cs2 -ErrorAction SilentlyContinue).Count){throw 'CS2 is running.'}
        $busy=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object {$_.TaskName -like '*OptimizationSuite.ProcessRules.*' -or $_.TaskName -like 'RooIndustries_Governor*' -or ($_.TaskName -like 'Roo Industries Protected Session*' -and [string]$_.State -eq 'Running')})
        if($busy.Count){throw ('Other Roo Industries test tasks exist: '+(($busy|ForEach-Object TaskName) -join ', '))}
        if(Test-Path -LiteralPath $backup){throw "A backup from an earlier run is still at $backup; restore it with -Phase cleanup first."}
        New-Item -ItemType Directory -Force -Path $backup|Out-Null
        foreach($name in 'RooIndustriesOptimizationSuite','RooOptimizationSuite'){
            $path=Join-Path $local $name
            if(Test-Path -LiteralPath $path){& robocopy.exe $path (Join-Path $backup $name) /E /COPYALL /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NP|Out-Null;Log ("backed up $path (robocopy exit $LASTEXITCODE)")}
        }
        & reg.exe export $markerKey (Join-Path $backup 'markers.reg') /y 2>$null|Out-Null
        Log ('marker export exit '+$LASTEXITCODE)
        Log ('installed='+(Test-Path -LiteralPath (Join-Path $app 'app'))+' dotnet='+$dotnet)
    }
    'validators' {
        $env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet
        Run 'optimizer-core' {& (Join-Path $Source 'backend\scripts\Test-OptimizerCore.ps1') -DotNetPath $dotnet}
        Run 'tweaks' {& (Join-Path $Source 'backend\scripts\Test-Tweaks.ps1') -DotNetPath $dotnet}
        Run 'process-policy-worker' {& (Join-Path $Source 'backend\scripts\Test-ProcessPolicyWorker.ps1') -DotNetPath $dotnet}
        Run 'protected-sessions' {& (Join-Path $Source 'backend\scripts\Test-ProtectedGameSessions.ps1') -DotNetPath $dotnet}
        Run 'tool-launcher' {& (Join-Path $Source 'tools\scripts\Test-ToolLauncher.ps1') -DotNetPath $dotnet}
        Run 'frontend' {& (Join-Path $Source 'tools\scripts\Test-Frontend.ps1') -DotNetPath $dotnet}
    }
    'release-build' {
        Run 'build-release' {& (Join-Path $Source 'tools\scripts\Build-Release.ps1')}
    }
    'install-old' {
        Log ('previous install removed: '+(Uninstall-App))
        Run 'install-old' {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $OldInstaller -OutDir (Join-Path $Evidence 'install-old')}
    }
    'upgrade' {
        Run 'upgrade' {& (Join-Path $Source 'tools\validation\Governor\Measure-SetupTempAcl.ps1') -Installer $NewInstaller -OutDir (Join-Path $Evidence 'upgrade')}
    }
    'static-checks' {
        foreach($file in @(Get-ChildItem -LiteralPath $app -Recurse -Filter '*.runtimeconfig.json')){
            $value=(Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json).runtimeOptions.configProperties.'System.StartupHookProvider.IsSupported'
            Check ($value -eq $false) ('startup hooks are off in '+$file.FullName.Substring($app.Length+1)) ([string]$value)
        }
        foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue)){
            $xml=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            $xml|Set-Content -LiteralPath (Join-Path $Evidence ('task-'+$task.TaskName+'.xml')) -Encoding UTF8
            $exec=([xml]$xml).Task.Actions.Exec
            Check ($exec.Command -like '*\conhost.exe' -and $exec.Arguments -match '^--headless ".*\\cmd.exe" /d /s /c "set DOTNET_STARTUP_HOOKS=&' -and $exec.Arguments -match 'Optimizer.Host.exe" policy-run') ('governor task '+$task.TaskName+' starts through the cleaning launcher') ($exec.Command+' '+$exec.Arguments)
        }
        $hostExe=Join-Path $app 'backend\bin\optimizer\Optimizer.Host.exe'
        $previous=$env:DOTNET_STARTUP_HOOKS
        try {
            $env:DOTNET_STARTUP_HOOKS='C:\RooIndustriesNoSuchFolder\hook.dll'
            $ErrorActionPreference='Continue'
            $text=@(('{"schemaVersion":1,"repoRoot":"'+$app.Replace('\','\\')+'"}')|& $hostExe tweak-catalog '-' 2>&1|ForEach-Object {[string]$_}) -join "`n"
            Check ($LASTEXITCODE -ne 0 -and $text -match 'will not run with these \.NET settings in its environment: DOTNET_STARTUP_HOOKS') 'the elevated helper refuses to run with DOTNET_STARTUP_HOOKS set' $text
        } finally {$env:DOTNET_STARTUP_HOOKS=$previous}
        $markers=Get-Item -LiteralPath ('Registry::'+$markerKey) -ErrorAction SilentlyContinue
        Log ('markers: '+(@($markers.GetValueNames())|ForEach-Object {$_+'='+$markers.GetValue($_)}) -join ' ; ')
    }
    'setup-fallbacks' {
        Run 'setup-fallbacks' {& (Join-Path $Source 'tools\validation\Governor\Test-GovernorSetupFallbacks.ps1') -Script (Join-Path $Source 'backend\scripts\Invoke-GovernorSetup.ps1') -OutDir (Join-Path $Evidence 'setup-fallbacks')}
    }
    'cleanup' {
        Log ('uninstall: '+(Uninstall-App))
        foreach($task in @(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*','RooIndustriesOptimizationSuite.GovernorSetupWatchdog','RooIndustries_LoadTimes' -ErrorAction SilentlyContinue)){Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false;Log ('removed task '+$task.TaskName)}
        if(Test-Path -LiteralPath $backup){
            foreach($name in 'RooIndustriesOptimizationSuite','RooOptimizationSuite'){
                $path=Join-Path $local $name
                if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force;Log "removed $path"}
                if(Test-Path -LiteralPath (Join-Path $backup $name)){& robocopy.exe (Join-Path $backup $name) $path /E /COPYALL /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NP|Out-Null;Log ("restored $path (robocopy exit $LASTEXITCODE)")}
            }
            foreach($leftover in @(Get-ChildItem -LiteralPath $local -Directory -Filter '*OptimizationSuite.*' -ErrorAction SilentlyContinue)){Log ('leftover next to the data folder: '+$leftover.Name)}
            & reg.exe delete $markerKey /f 2>$null|Out-Null
            if(Test-Path -LiteralPath (Join-Path $backup 'markers.reg')){& reg.exe import (Join-Path $backup 'markers.reg') 2>$null|Out-Null;Log ('markers restored, exit '+$LASTEXITCODE)}
            Rename-Item -LiteralPath $backup -NewName ('backup-restored-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
        }
    }
}
