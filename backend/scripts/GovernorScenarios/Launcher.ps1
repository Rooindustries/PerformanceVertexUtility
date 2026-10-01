function Get-SpecialName([string]$Suffix='') {return 'a (b) & caf'+[char]0xE9+' '+[char]0x65E5+[char]0x672C+$Suffix}

function Use-SpecialFolders {
    $special=Get-SpecialName
    $script:savedHostDirectory=$script:hostDirectory
    $copy=Join-Path $script:scenarioRoot ('h '+$special)
    Copy-Item -LiteralPath $script:savedHostDirectory -Destination $copy -Recurse
    $script:hostDirectory=$copy
    $script:cleanups.Add({$script:hostDirectory=$script:savedHostDirectory})
    $script:policyParent=Join-Path $script:scenarioRoot ('d '+(Get-SpecialName ' 5%'))
    $script:policyRoot=Join-Path $script:policyParent 'process-rules'
    [IO.Directory]::CreateDirectory($script:policyParent)|Out-Null
    return $special
}

function Initialize-EnvironmentOracle {
    if('RooIndustriesGovernorEnvOracle' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class RooIndustriesGovernorEnvOracle {
    [StructLayout(LayoutKind.Sequential)] struct Basic { public IntPtr Exit, Peb, Affinity, Priority, Id, Parent; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, ref Basic info, int size, out int length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
    static byte[] Read(IntPtr process, long address, int size) { var buffer=new byte[size]; IntPtr read; if(!ReadProcessMemory(process,(IntPtr)address,buffer,(IntPtr)size,out read)) throw new System.ComponentModel.Win32Exception(); return buffer; }
    public static string[] Entries(IntPtr process) {
        var basic=new Basic(); int length;
        if(NtQueryInformationProcess(process,0,ref basic,Marshal.SizeOf(basic),out length)!=0) throw new InvalidOperationException("The process block could not be read.");
        var parameters=BitConverter.ToInt64(Read(process,(long)basic.Peb+0x20,8),0);
        var block=BitConverter.ToInt64(Read(process,parameters+0x80,8),0);
        var size=(int)BitConverter.ToInt64(Read(process,parameters+0x3F0,8),0);
        var entries=new List<string>();
        foreach(var entry in Encoding.Unicode.GetString(Read(process,block,size)).Split('\0')) if(entry.Length>1 && entry.IndexOf('=',1)>0) entries.Add(entry);
        return entries.ToArray();
    }
    public static string[] Names(IntPtr process) {
        var names=new List<string>();
        foreach(var entry in Entries(process)) names.Add(entry.Substring(0,entry.IndexOf('=',1)));
        return names.ToArray();
    }
}
'@
}

function Test-ScenarioLauncherSpaces {
    . (Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')
    $special=Use-SpecialFolders
    Note 'specialNames' ([ordered]@{host=(Split-Path $hostDirectory -Leaf);data=(Split-Path $script:policyParent -Leaf)})
    $path=Copy-Probe
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Special paths')
    Assert ($synced.worker.hostRunning -eq $true) 'The governor starts when its host folder and rules folder contain spaces, parentheses, an ampersand, a percent sign and non-ASCII letters (in the host folder and the rules folder)'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'The rule is applied to a running process from those folders'
    $second=Start-Probe $path
    $seconds=Wait-Field $second 'cpuPriority' 'AboveNormal'
    Note 'newProcessSecondsFromSpecialFolders' $seconds
    Assert ($null -ne $seconds) 'A process started later gets the rule too'
    $task=Get-ScheduledTask -TaskName $synced.taskName
    $expected=New-RooIndustriesElevatedTaskAction $DotNetPath @((Join-Path $hostDirectory 'Optimizer.Host.dll'),'policy-run',(Join-Path $script:policyRoot 'worker-request.json')) $hostDirectory
    Assert ($task.Actions[0].Execute -eq $expected.Execute -and $task.Actions[0].Arguments -ceq $expected.Arguments -and $task.Actions[0].WorkingDirectory -eq $expected.WorkingDirectory) 'The task action is the one the clean launcher function builds for those folders'
    $worker=Get-CimInstance Win32_Process -Filter ('ProcessId='+$synced.worker.state.host.processId)
    $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$worker.ParentProcessId)
    $console=Get-CimInstance Win32_Process -Filter ('ProcessId='+$parent.ParentProcessId)
    Note 'workerChain' ([ordered]@{worker=$worker.CommandLine;parent=$parent.CommandLine;console=$console.CommandLine;session=$worker.SessionId})
    Assert ($worker.CommandLine.Contains((Join-Path $hostDirectory 'Optimizer.Host.dll')) -and $worker.CommandLine.Contains((Join-Path $script:policyRoot 'worker-request.json'))) 'The governor process received its exact host path and request path'
    Assert ($parent.Name -eq 'cmd.exe' -and $parent.CommandLine -like '*/d /v:off /c call *Start-RooIndustriesHelper.cmd*' -and $console.Name -eq 'conhost.exe' -and $console.CommandLine -like '*--headless*') 'The governor runs under the launcher in a headless console'
    $context=New-GameContext
    $session=New-GameSession $context
    Start-GameSession $session|Out-Null
    $sessionTask=@(Get-ScheduledTask -TaskName 'Roo Industries Protected Session *' -ErrorAction SilentlyContinue|Where-Object {$_.Description.EndsWith(' | '+$session.root)})
    Assert ($sessionTask.Count -eq 1) 'The protected game session registered its task for a session folder with those characters'
    $sessionExpected=New-RooIndustriesElevatedTaskAction (Join-Path $hostDirectory 'session\RooIndustries.SessionHost.exe') @('run',(Join-Path $session.root 'worker-request.json')) (Join-Path $hostDirectory 'session')
    Assert ($sessionTask[0].Actions[0].Arguments -ceq $sessionExpected.Arguments) 'The session task action is the one the clean launcher function builds'
    $sessionWorker=@(Get-CimInstance Win32_Process -Filter "Name='RooIndustries.SessionHost.exe'"|Where-Object {$_.CommandLine.Contains((Join-Path $session.root 'worker-request.json'))})
    Note 'sessionWorker' @($sessionWorker|ForEach-Object {$_.CommandLine})
    Assert ($sessionWorker.Count -eq 1) 'The protected session helper is running with its exact request path'
    $stopped=& (Join-Path $scriptsRoot 'Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot $session.root -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply
    Assert ($null -eq (Get-ScheduledTask -TaskName $sessionTask[0].TaskName -ErrorAction SilentlyContinue)) 'Stopping the session removes its task'
}

function Test-ScenarioLauncherCleansEnvironment {
    . (Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')
    Initialize-EnvironmentOracle
    $own=[RooIndustriesGovernorEnvOracle]::Names([Diagnostics.Process]::GetCurrentProcess().Handle)
    Assert ($own -contains 'PATH' -and $own -contains 'SystemRoot') 'The environment reader sees the names of a known process'
    $names=@($script:RooIndustriesCodeLoadingVariables)
    $profiler=Join-Path $script:scenarioRoot 'no-such-profiler.dll'
    $saved=@{}
    foreach($name in @('CORECLR_ENABLE_PROFILING','CORECLR_PROFILER_PATH','DOTNET_DiagnosticPorts')){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'User')}
    $pipe='roo-industries-no-listener-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $script:cleanups.Add({foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'User')}}.GetNewClosure())
    [Environment]::SetEnvironmentVariable('CORECLR_ENABLE_PROFILING','1','User')
    [Environment]::SetEnvironmentVariable('CORECLR_PROFILER_PATH',$profiler,'User')
    [Environment]::SetEnvironmentVariable('DOTNET_DiagnosticPorts',($pipe+',connect,nosuspend'),'User')
    $conhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
    $principal=New-ScheduledTaskPrincipal -UserId (Get-RooIndustriesOperationOwner).userSid -LogonType Interactive -RunLevel Highest
    function Start-ProbeTask([string]$Name,$Action,[string]$Path){
        $task='RooIndustries_GovernorScenarioEnv_'+$Name+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        Register-ScheduledTask -TaskName $task -Action $Action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10)) -Force|Out-Null
        $script:tasks.Add($task)
        Start-ScheduledTask -TaskName $task
        $found=$null
        $null=Wait-Until {$script:envProcess=@(Get-Process -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $Path})[0];$null -ne $script:envProcess} 20 200
        if($null -eq $script:envProcess){throw ('The '+$Name+' probe did not start.')}
        $script:probes.Add($script:envProcess)
        return $script:envProcess
    }
    $direct=Copy-Probe 'RooIndustriesGovernorEnvDirect.exe' 'env'
    $viaLauncher=Copy-Probe 'RooIndustriesGovernorEnvLauncher.exe' 'env'
    $directProcess=Start-ProbeTask 'direct' (New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$direct+'" 900') -WorkingDirectory (Split-Path $direct -Parent)) $direct
    $directNames=@([RooIndustriesGovernorEnvOracle]::Names($directProcess.Handle))
    Note 'directLaunchEnvironment' @($directNames|Where-Object {$names -contains $_})
    Assert ($directNames -contains 'CORECLR_ENABLE_PROFILING' -and $directNames -contains 'CORECLR_PROFILER_PATH' -and $directNames -contains 'DOTNET_DiagnosticPorts') 'Without the launcher a task started for this user inherits the profiler and diagnostic port settings'
    $launcherProcess=Start-ProbeTask 'launcher' (New-RooIndustriesElevatedTaskAction $viaLauncher @('900') (Split-Path $viaLauncher -Parent)) $viaLauncher
    $launcherNames=@([RooIndustriesGovernorEnvOracle]::Names($launcherProcess.Handle))
    Note 'launcherEnvironment' @($launcherNames|Where-Object {$names -contains $_})
    $launcherEntries=@([RooIndustriesGovernorEnvOracle]::Entries($launcherProcess.Handle))
    Note 'launcherPinned' @($launcherEntries|Where-Object {$_ -like '*EnableDiagnostics*'})
    Assert (@($launcherNames|Where-Object {$names -contains $_}).Count -eq 0 -and $launcherNames -contains 'PATH') 'Through the launcher the same task starts the program with none of the code-loading names, and the rest of its environment is intact'
    Assert (@($script:RooIndustriesPinnedVariables|Where-Object {$launcherEntries -notcontains ($_+'=0')}).Count -eq 0) 'Through the launcher diagnostics are switched off for the program under both name prefixes'
    $path=Copy-Probe
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Environment')
    Assert ($synced.worker.hostRunning -eq $true) 'The governor starts while the profiler settings are set for the user'
    $worker=Get-Process -Id $synced.worker.state.host.processId
    $workerNames=@([RooIndustriesGovernorEnvOracle]::Names($worker.Handle))
    Note 'workerEnvironment' @($workerNames|Where-Object {$names -contains $_})
    $workerEntries=@([RooIndustriesGovernorEnvOracle]::Entries($worker.Handle))
    Assert (@($workerNames|Where-Object {$names -contains $_}).Count -eq 0 -and $workerNames -contains 'PATH') 'The running governor process has none of the code-loading names in its environment'
    Assert (@($script:RooIndustriesPinnedVariables|Where-Object {$workerEntries -notcontains ($_+'=0')}).Count -eq 0) 'The running governor process has diagnostics switched off'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'And it still enforces the rule'
    $env:CORECLR_ENABLE_PROFILING='1'
    try {$text=(@('{"schemaVersion":1,"repoRoot":"'+$repoRoot.Replace('\','\\')+'"}'|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') policy-status '-' 2>&1|ForEach-Object {[string]$_}) -join "`n");$code=$LASTEXITCODE}
    finally {Remove-Item -LiteralPath 'Env:\CORECLR_ENABLE_PROFILING' -ErrorAction SilentlyContinue}
    Note 'hostWithProfilerSetting' ([ordered]@{exit=$code;text=$text})
    Assert ($code -ne 0 -and $text -match 'will not run with these \.NET settings in its environment: CORECLR_ENABLE_PROFILING') 'A helper started with the profiler setting still in its environment refuses to run, so the clearing is what lets the governor start'
    $env:DOTNET_EnableDiagnostics='1'
    try {$diagnostics=(@('{"schemaVersion":1,"repoRoot":"'+$repoRoot.Replace('\','\\')+'"}'|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') policy-status '-' 2>&1|ForEach-Object {[string]$_}) -join "`n");$diagnosticsCode=$LASTEXITCODE}
    finally {Remove-Item -LiteralPath 'Env:\DOTNET_EnableDiagnostics' -ErrorAction SilentlyContinue}
    Assert ($diagnosticsCode -ne 0 -and $diagnostics -match 'DOTNET_EnableDiagnostics') 'A helper started with diagnostics switched on refuses to run, while the value 0 the launcher sets is accepted'
    Assert (-not (Test-Path -LiteralPath $profiler) -and -not (Test-Path -LiteralPath ('\\.\pipe\'+$pipe))) 'The profiler path and the diagnostic pipe used for the check were never created'
}

function Test-ScenarioLauncherRefusals {
    . (Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')
    $exe=Join-Path $env:SystemRoot 'System32\whoami.exe'
    $directory=Split-Path $exe -Parent
    function Refusal([string[]]$ArgumentList,[string]$Executable=$exe){
        try {New-RooIndustriesElevatedTaskAction $Executable $ArgumentList $directory|Out-Null;return $null} catch {return $_.Exception.Message}
    }
    Assert ($null -eq (Refusal @('policy-run','C:\Users\Public\100%\worker-request.json'))) 'One percent sign in the paths is passed through'
    $undefined=Refusal @('policy-run','C:\Users\Public\%zzz%\worker-request.json')
    Note 'undefinedPair' $undefined
    Assert ($undefined -like '*more than one % character*') 'A path with a percent pair is refused even when no variable of that name exists yet, because the name could be defined for the user later'
    Assert ($null -ne (Refusal @('policy-run','C:\Users\Public\%TEMP%\worker-request.json'))) 'A percent pair naming a defined variable is refused'
    $across=Refusal @('a%b','c%d')
    Assert ($across -like '*more than one % character*') 'One percent sign in each of two arguments is refused, because together they could name a variable'
    foreach($bad in @('a^b','a?b','a"b','a*b','a<b','a|b')){Assert ($null -ne (Refusal @('policy-run',('C:\x\'+$bad)))) ('The character in '+$bad+' is refused')}
    Assert ($null -ne (Refusal @('a','b','c','d'))) 'More than three arguments are refused'
    Assert ($null -eq (Refusal @('policy-run',('C:\Users\J'+[char]0xFC+'rgen '+[char]0x65E5+[char]0x672C+'\r & s (1)\worker-request.json')))) 'Spaces, parentheses, an ampersand and non-ASCII letters are passed through'
}
