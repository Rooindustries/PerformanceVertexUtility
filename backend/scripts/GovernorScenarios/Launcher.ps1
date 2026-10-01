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
    Note 'directLaunchEnvironment' @($directNames|Where-Object {Test-ClearedName $_})
    Assert ($directNames -contains 'CORECLR_ENABLE_PROFILING' -and $directNames -contains 'CORECLR_PROFILER_PATH' -and $directNames -contains 'DOTNET_DiagnosticPorts') 'Without the launcher a task started for this user inherits the profiler and diagnostic port settings'
    $launcherProcess=Start-ProbeTask 'launcher' (New-RooIndustriesElevatedTaskAction $viaLauncher @('900') (Split-Path $viaLauncher -Parent)) $viaLauncher
    $launcherNames=@([RooIndustriesGovernorEnvOracle]::Names($launcherProcess.Handle))
    Note 'launcherEnvironment' @($launcherNames|Where-Object {Test-ClearedName $_})
    $launcherEntries=@([RooIndustriesGovernorEnvOracle]::Entries($launcherProcess.Handle))
    Note 'launcherPinned' @($launcherEntries|Where-Object {$_ -like '*EnableDiagnostics*'})
    Assert (@($launcherNames|Where-Object {Test-ClearedName $_}).Count -eq 0 -and $launcherNames -contains 'PATH') 'Through the launcher the same task starts the program with no variable that starts with a .NET prefix (apart from the pinned diagnostics switches), and the rest of its environment is intact'
    Assert (@($script:RooIndustriesPinnedVariables|Where-Object {$launcherEntries -notcontains ($_+'=0')}).Count -eq 0) 'Through the launcher diagnostics are switched off for the program under both name prefixes'
    $path=Copy-Probe
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Environment')
    Assert ($synced.worker.hostRunning -eq $true) 'The governor starts while the profiler settings are set for the user'
    $worker=Get-Process -Id $synced.worker.state.host.processId
    $workerNames=@([RooIndustriesGovernorEnvOracle]::Names($worker.Handle))
    Note 'workerEnvironment' @($workerNames|Where-Object {Test-ClearedName $_})
    $workerEntries=@([RooIndustriesGovernorEnvOracle]::Entries($worker.Handle))
    Assert (@($workerNames|Where-Object {Test-ClearedName $_}).Count -eq 0 -and $workerNames -contains 'PATH') 'The running governor process has no variable that starts with a .NET prefix in its environment, apart from the pinned diagnostics switches'
    Assert (@($script:RooIndustriesPinnedVariables|Where-Object {$workerEntries -notcontains ($_+'=0')}).Count -eq 0) 'The running governor process has diagnostics switched off'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'And it still enforces the rule'
    $env:CORECLR_ENABLE_PROFILING='1'
    try {$text=(@('{"schemaVersion":1,"repoRoot":"'+$repoRoot.Replace('\','\\')+'"}'|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') policy-status '-' 2>&1|ForEach-Object {[string]$_}) -join "`n");$code=$LASTEXITCODE}
    finally {Remove-Item -LiteralPath 'Env:\CORECLR_ENABLE_PROFILING' -ErrorAction SilentlyContinue}
    Note 'hostWithProfilerSetting' ([ordered]@{exit=$code;text=$text})
    Assert ($code -ne 0 -and $text -match 'will not run with these \.NET settings in its environment: CORECLR_ENABLE_PROFILING') 'A helper started with the profiler setting still in its environment refuses to run, so the clearing is what lets the governor start'
    $env:COREHOST_TRACE='0'
    try {$tracing=(@('{"schemaVersion":1,"repoRoot":"'+$repoRoot.Replace('\','\\')+'"}'|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') policy-status '-' 2>&1|ForEach-Object {[string]$_}) -join "`n");$tracingCode=$LASTEXITCODE}
    finally {Remove-Item -LiteralPath 'Env:\COREHOST_TRACE' -ErrorAction SilentlyContinue}
    Assert ($tracingCode -ne 0 -and $tracing -match 'will not run with these \.NET settings in its environment: COREHOST_TRACE\.') 'A helper started with a host tracing switch, which the app clears but no profiler setting, refuses to run too'
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

function Test-ClearedName([string]$Name) {
    if($script:RooIndustriesPinnedVariables -contains $Name){return $false}
    foreach($prefix in $script:RooIndustriesClearedPrefixes){if($Name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $true}}
    return $false
}

function Initialize-EnvironmentBroadcast {
    if('RooIndustriesGovernorEnvBroadcast' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesGovernorEnvBroadcast {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wparam, string lparam, uint flags, uint timeout, out UIntPtr result);
    public static void Send() { UIntPtr result; SendMessageTimeout((IntPtr)0xFFFF, 0x1A, UIntPtr.Zero, "Environment", 2, 5000, out result); }
}
'@
}

function Use-UserEnvironment {
    Initialize-EnvironmentBroadcast
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $saved=New-Object System.Collections.Generic.List[object]
    foreach($name in $key.GetValueNames()){$saved.Add([pscustomobject]@{name=$name;kind=$key.GetValueKind($name);value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)})}
    $key.Close()
    $script:userEnvironmentNames=@($saved|ForEach-Object {$_.name})
    $script:cleanups.Add({
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
        $wanted=@($saved|ForEach-Object {$_.name})
        foreach($name in @($key.GetValueNames()|Where-Object {$wanted -cnotcontains $_})){$key.DeleteValue($name)}
        foreach($entry in $saved){$key.SetValue($entry.name,$entry.value,$entry.kind)}
        $key.Close()
        [RooIndustriesGovernorEnvBroadcast]::Send()
    }.GetNewClosure())
}

function Set-UserEnvironment([System.Collections.IDictionary]$Values,[string[]]$Remove=@()) {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    foreach($name in $Remove){if($null -ne $key.GetValue($name,$null)){$key.DeleteValue($name)}}
    foreach($name in $Values.Keys){$key.SetValue([string]$name,[string]$Values[$name],[Microsoft.Win32.RegistryValueKind]::String)}
    $key.Close()
    [RooIndustriesGovernorEnvBroadcast]::Send()
}

function Get-PrefixedUserNames {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $names=@($key.GetValueNames()|Where-Object {Test-ClearedName $_})
    $key.Close()
    return $names
}

function Start-ScenarioTask([string]$Name,$Action) {
    $task='RooIndustries_GovernorScenarioEnv_'+$Name+'_'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $principal=New-ScheduledTaskPrincipal -UserId (Get-RooIndustriesOperationOwner).userSid -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $task -Action $Action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10)) -Force|Out-Null
    $script:tasks.Add($task)
    $script:taskStarted=(Get-ScheduledTaskInfo -TaskName $task).LastRunTime
    Start-ScheduledTask -TaskName $task
    return $task
}

function Wait-ScenarioTaskFinished([string]$Task,[double]$Seconds=90) {
    return Wait-Until {$info=Get-ScheduledTaskInfo -TaskName $Task;(Get-ScheduledTask -TaskName $Task).State -eq 'Ready' -and $info.LastRunTime -ne $script:taskStarted -and $info.LastTaskResult -ne 267009} $Seconds 250
}

function Wait-ProbeProcess([string]$Path,[double]$Seconds=20) {
    $script:foundProbe=$null
    $null=Wait-Until {$script:foundProbe=@(Get-Process -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $Path})[0];$null -ne $script:foundProbe} $Seconds 200
    if($null -ne $script:foundProbe){$script:probes.Add($script:foundProbe)}
    return $script:foundProbe
}

function New-ElevatedLauncherAction([string]$Launcher,[string]$Executable,[string[]]$ArgumentList=@()) {
    $saved=$script:RooIndustriesScriptsRoot
    $script:RooIndustriesScriptsRoot=Split-Path $Launcher -Parent
    try {return New-RooIndustriesElevatedTaskAction $Executable $ArgumentList (Split-Path $Executable -Parent)} finally {$script:RooIndustriesScriptsRoot=$saved}
}

function Get-TrapFiles([string]$Folder) {
    return @(Get-ChildItem -LiteralPath $Folder -Force -Recurse -ErrorAction SilentlyContinue|ForEach-Object {$_.FullName.Substring($Folder.Length).TrimStart('\')})
}

function Get-AwkwardEnvironment([string]$Trap) {
    return [ordered]@{
        'DOTNET_GCConfigLogEnabled'='1'
        'DOTNET_GCConfigLogFile'=(Join-Path $Trap 'gc-config.log')
        'COMPlus_JitTimeLogFile'=(Join-Path $Trap 'jit-time.log')
        'DOTNET_JitFuncInfoLogFile'=(Join-Path $Trap 'jit-func-info.log')
        'DOTNET_JitTimeLogCsv'=(Join-Path $Trap 'jit-time.csv')
        'DOTNET_MultiCoreJitProfile'=(Join-Path $Trap 'multicore.profile')
        'DOTNET_ROO_INDUSTRIES_UNKNOWN_KNOB'='1'
        'complus_x'='1'
        'CORECLR_ENABLE_PROFILING'='1'
        'CORECLR_PROFILER_PATH'=(Join-Path $Trap 'no-such-profiler.dll')
        'COR_ENABLE_PROFILING'='1'
        'COREHOST_TRACE'='1'
        'COREHOST_TRACEFILE'=(Join-Path $Trap 'host-trace.log')
        'DOTNET_ROO_INDUSTRIES_VALUE_NEWLINE'=("first line`r`nsecond line`r`nPATH`r`nDOTNET_ROO_INDUSTRIES_FAKE_LINE=1")
        'DOTNET_ROO_INDUSTRIES_VALUE_SPECIAL'='"quoted" & amp | pipe ^ caret % percent ! bang < less > greater'
        'DOTNET_ROO_INDUSTRIES_VALUE_SEMICOLON'=';starts with the end-of-line character'
        'DOTNET_ROO_INDUSTRIES NAME WITH SPACES'='1'
        'DOTNET_ROO_INDUSTRIES&NAME(WITH)SPECIALS'='1'
        'DOTNET_ROO_INDUSTRIES_NAME_WITH_QUOTE"'=(Join-Path $Trap 'quote.txt')
        ('DOTNET_ROO_INDUSTRIES_REDIRECT" >'+(Join-Path $Trap 'injected-by-name.txt')+' &rem "')='1'
        ('COMPlus_ROO_INDUSTRIES_REDIRECT>'+(Join-Path $Trap 'injected-by-second-name.txt'))='1'
        'DOTNET_ROO_INDUSTRIES_LAST_PLAIN'='1'
        'RANDOM'='1'
        'ERRORLEVEL'='0'
    }
}

function Test-ScenarioLauncherClearsByPrefix {
    . (Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')
    Initialize-EnvironmentOracle
    $trap=Join-Path $script:scenarioRoot 'trap'
    [IO.Directory]::CreateDirectory($trap)|Out-Null
    Use-UserEnvironment
    $planted=Get-AwkwardEnvironment $trap
    Set-UserEnvironment $planted
    $plantedPrefixed=@($planted.Keys|Where-Object {Test-ClearedName $_})
    Note 'plantedPrefixedCount' $plantedPrefixed.Count
    $conhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
    $direct=Copy-Probe 'RooIndustriesGovernorEnvDirect.exe' 'env'
    $viaLauncher=Copy-Probe 'RooIndustriesGovernorEnvLauncher.exe' 'env'
    $null=Start-ScenarioTask 'direct' (New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$direct+'" 900') -WorkingDirectory (Split-Path $direct -Parent))
    $directProcess=Wait-ProbeProcess $direct
    if($null -eq $directProcess){throw 'The direct probe did not start.'}
    $directNames=@([RooIndustriesGovernorEnvOracle]::Names($directProcess.Handle))
    $missing=@($plantedPrefixed|Where-Object {$directNames -cnotcontains $_})
    Note 'plantedButNotDeliveredWithoutLauncher' @($missing|ForEach-Object {if($_.Length -gt 50){$_.Substring(0,50)+'...'}else{$_}})
    Assert ($missing.Count -eq 0) 'Without the launcher the task hands the program every planted variable that starts with a .NET prefix, so the checks below can fail'
    $null=Start-ScenarioTask 'launcher' (New-RooIndustriesElevatedTaskAction $viaLauncher @('900') (Split-Path $viaLauncher -Parent))
    $launcherProcess=Wait-ProbeProcess $viaLauncher
    if($null -eq $launcherProcess){throw 'The probe did not start through the launcher.'}
    $launcherEntries=@([RooIndustriesGovernorEnvOracle]::Entries($launcherProcess.Handle))
    $launcherNames=@([RooIndustriesGovernorEnvOracle]::Names($launcherProcess.Handle))
    Note 'launcherRemainingPrefixedNames' @($launcherNames|Where-Object {Test-ClearedName $_})
    Assert (@($launcherNames|Where-Object {Test-ClearedName $_}).Count -eq 0) 'Through the launcher the program has no variable whose name starts with DOTNET_, COMPlus_, CORECLR_, COR_ or COREHOST_, whatever the name or value'
    Assert (@($script:RooIndustriesPinnedVariables|Where-Object {$launcherEntries -cnotcontains ($_+'=0')}).Count -eq 0) 'Through the launcher all eight diagnostics switches are present and hold 0'
    Note 'launcherNamesLostToLineBreakValue' @('PATH','SystemRoot','ComSpec','TEMP'|Where-Object {$launcherNames -notcontains $_})
    Assert ($launcherNames -notcontains 'DOTNET_ROO_INDUSTRIES_FAKE_LINE' -and $launcherNames -notcontains 'DOTNET_ROO_INDUSTRIES_VALUE_NEWLINE') 'A value with line breaks cannot make the launcher keep or create a variable'
    $created=@(Get-TrapFiles $trap)
    Note 'filesCreatedByLauncher' $created
    Assert ($created.Count -eq 0) 'The launcher created no file at any path named by a planted variable name or value'
    Assert (@(Get-ChildItem -LiteralPath $scriptsRoot -Filter 'RooIndustriesHelperEnvironment-*' -ErrorAction SilentlyContinue).Count -eq 0) 'The launcher leaves no listing file in its folder'
    $wrapper=Join-Path $script:scenarioRoot 'host-status.cmd'
    $request=Join-Path $script:scenarioRoot 'host-status-request.json'
    $output=Join-Path $script:scenarioRoot 'host-status-output.txt'
    [IO.File]::WriteAllText($request,(@{schemaVersion=1;repoRoot=$repoRoot;policyRoot=$script:policyRoot}|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText($wrapper,("@echo off`r`n`""+$DotNetPath+"`" `""+(Join-Path $hostDirectory 'Optimizer.Host.dll')+"`" policy-status - < `""+$request+"`" > `""+$output+"`" 2>&1`r`nexit /b`r`n"),[Text.Encoding]::ASCII)
    $hostTask=Start-ScenarioTask 'host' (New-RooIndustriesElevatedTaskAction $wrapper @() $script:scenarioRoot)
    Assert ($null -ne (Wait-ScenarioTaskFinished $hostTask 120)) 'The real Host, started through the launcher by Task Scheduler, runs to completion'
    $text=if(Test-Path -LiteralPath $output){[IO.File]::ReadAllText($output)}else{''}
    Note 'hostOutput' $(if($text.Length -gt 300){$text.Substring(0,300)}else{$text})
    Assert ($text -match '"status"\s*:') 'The real Host answered (it printed its JSON status), so it did start'
    $files=@(Get-TrapFiles $trap)
    Note 'filesCreatedByRealHost' $files
    Assert ($files.Count -eq 0) 'The real Host created no file at any path named by a planted runtime setting (GC config log, JIT time log, JIT function log, JIT time CSV, multicore JIT profile, host trace)'
    $path=Copy-Probe
    $probe=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Prefix')
    Assert ($synced.worker.hostRunning -eq $true) 'The governor starts while the awkward variables are set for the user'
    $worker=Get-Process -Id $synced.worker.state.host.processId
    $workerNames=@([RooIndustriesGovernorEnvOracle]::Names($worker.Handle))
    Note 'workerRemainingPrefixedNames' @($workerNames|Where-Object {Test-ClearedName $_})
    Assert (@($workerNames|Where-Object {Test-ClearedName $_}).Count -eq 0) 'The running governor has no variable whose name starts with a .NET prefix'
    Assert ($null -ne (Wait-Field $probe 'cpuPriority' 'AboveNormal')) 'And it still enforces the rule'
    $running=@(Get-TrapFiles $trap)
    Note 'filesCreatedByRunningHost' $running
    Assert ($running.Count -eq 0) 'The running governor Host created no file at any path named by a planted runtime setting'
}

function Test-ScenarioLauncherFailsClosed {
    . (Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')
    Use-UserEnvironment
    $folder=Join-Path $script:scenarioRoot 'locked-launcher'
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    $launcher=Join-Path $folder 'Start-RooIndustriesHelper.cmd'
    Copy-Item -LiteralPath (Join-Path $scriptsRoot 'Start-RooIndustriesHelper.cmd') -Destination $launcher
    $dirty=Copy-Probe 'RooIndustriesGovernorEnvClosedDirty.exe' 'env'
    $clean=Copy-Probe 'RooIndustriesGovernorEnvClosedClean.exe' 'env'
    $conhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
    $cmd=Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    function New-WrappedAction([string]$Name,[string]$Probe){
        $code=Join-Path $script:scenarioRoot ($Name+'-exit-code.txt')
        $wrapper=Join-Path $script:scenarioRoot ($Name+'-wrapper.cmd')
        [IO.File]::WriteAllText($wrapper,("@echo off`r`ncall `""+$launcher+"`" `" ?"+$Probe+"?900`"`r`necho %ERRORLEVEL%> `""+$code+"`"`r`n"),[Text.Encoding]::ASCII)
        return [pscustomobject]@{code=$code;action=(New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "'+$cmd+'" /d /v:off /c call "'+$wrapper+'"') -WorkingDirectory $script:scenarioRoot)}
    }
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $folder /deny ($user+':(WD,AD)')|Out-Null
    if($LASTEXITCODE -ne 0){throw 'The launcher folder could not be made unwritable for the check.'}
    $script:cleanups.Add({& icacls.exe $folder /remove:d $user|Out-Null}.GetNewClosure())
    $writable=$true
    try {[IO.File]::WriteAllText((Join-Path $folder 'write-test.txt'),'x')} catch {$writable=$false}
    Assert (-not $writable) 'The launcher folder cannot be written for the check'
    Set-UserEnvironment ([ordered]@{'DOTNET_ROO_INDUSTRIES_UNKNOWN_KNOB'='1'})
    $wrapped=New-WrappedAction 'dirty' $dirty
    $null=Start-ScenarioTask 'closed' $wrapped.action
    $null=Wait-Until {Test-Path -LiteralPath $wrapped.code} 60 250
    Assert (Test-Path -LiteralPath $wrapped.code) 'The launcher returned to its caller with a .NET-prefixed variable set and an unwritable folder'
    $exit=([IO.File]::ReadAllText($wrapped.code)).Trim()
    Note 'failClosedExitCode' $exit
    Assert ($exit -eq '91') 'The launcher exits with its own code 91 when it cannot clear a prefixed variable'
    Assert ($null -eq @(Get-Process -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $dirty})[0]) 'The helper was not started'
    Assert (@(Get-ChildItem -LiteralPath $folder -Filter 'RooIndustriesHelperEnvironment-*' -ErrorAction SilentlyContinue).Count -eq 0) 'No listing file is left behind'
    $names=@(Get-PrefixedUserNames)
    Set-UserEnvironment ([ordered]@{}) -Remove $names
    $machine=@([Environment]::GetEnvironmentVariables('Machine').Keys|Where-Object {Test-ClearedName $_})
    Note 'machineLevelPrefixedNames' $machine
    if($machine.Count -eq 0){
        $wrappedClean=New-WrappedAction 'clean' $clean
        $null=Start-ScenarioTask 'closed-clean' $wrappedClean.action
        Assert ($null -ne (Wait-ProbeProcess $clean 30)) 'With no prefixed variable at all the launcher needs no file and starts the helper even though its folder cannot be written'
    }
}

function Test-ScenarioLauncherOwnEnvironment {
    . (Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')
    Initialize-EnvironmentOracle
    $marker=Join-Path $script:scenarioRoot 'env-markers'
    foreach($folder in @($marker,(Join-Path $marker 'temp'),(Join-Path $marker 'profile'),(Join-Path $marker 'local'),(Join-Path $marker 'roaming'))){[IO.Directory]::CreateDirectory($folder)|Out-Null}
    Use-UserEnvironment
    $userKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $userPath=[string]$userKey.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $userKey.Close()
    $planted=[ordered]@{TEMP=(Join-Path $marker 'temp');TMP=(Join-Path $marker 'temp');windir=$marker;SystemRoot=$marker;Path=($marker+';'+$userPath);ComSpec=(Join-Path $marker 'cmd.exe');PATHEXT='.MARK';USERPROFILE=(Join-Path $marker 'profile');LOCALAPPDATA=(Join-Path $marker 'local');APPDATA=(Join-Path $marker 'roaming')}
    Set-UserEnvironment $planted
    $conhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
    $probePath=Copy-Probe 'RooIndustriesGovernorEnvOwn.exe' 'env'
    $null=Start-ScenarioTask 'own-probe' (New-RooIndustriesElevatedTaskAction $probePath @('900') (Split-Path $probePath -Parent))
    $probeProcess=Wait-ProbeProcess $probePath
    if($null -eq $probeProcess){throw 'The probe did not start through the launcher.'}
    $probeEntries=@([RooIndustriesGovernorEnvOracle]::Entries($probeProcess.Handle))
    $probeValues=@{};foreach($entry in $probeEntries){$split=$entry.IndexOf('=',1);$probeValues[$entry.Substring(0,$split)]=$entry.Substring($split+1)}
    $delivered=@($planted.Keys|Where-Object {$probeValues.ContainsKey($_) -and [string]$probeValues[$_] -ceq [string]$planted[$_]})
    Note 'markerNamesTheTaskDelivers' $delivered
    Note 'markerNamesWindowsSetItself' @($planted.Keys|Where-Object {$delivered -cnotcontains $_})
    Assert (@('windir','SystemRoot','ComSpec','PATHEXT'|Where-Object {$delivered -cnotcontains $_}).Count -eq 0) 'The task hands a program the marker values for windir, SystemRoot, ComSpec and PATHEXT (so the check below can fail)'
    $windows=[Environment]::GetFolderPath('Windows')
    $system=[Environment]::GetFolderPath('System')
    $profile=[Environment]::GetFolderPath('UserProfile')
    $expected=[ordered]@{windir=$windows;SystemRoot=$windows;ComSpec=(Join-Path $system 'cmd.exe');PATH=($system+';'+$windows+';'+(Join-Path $system 'Wbem')+';'+(Join-Path $system 'WindowsPowerShell\v1.0'));PATHEXT='.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC';USERPROFILE=$profile;LOCALAPPDATA=(Join-Path $profile 'AppData\Local');APPDATA=(Join-Path $profile 'AppData\Roaming')}
    $dataTemp=Join-Path (Get-RooIndustriesLocalDataRoot) 'temp'
    function Assert-OwnEnvironment([string]$Who,$Process){
        $values=@{};foreach($entry in @([RooIndustriesGovernorEnvOracle]::Entries($Process.Handle))){$split=$entry.IndexOf('=',1);$values[$entry.Substring(0,$split)]=$entry.Substring($split+1)}
        $wrong=@($expected.Keys|Where-Object {-not $values.ContainsKey($_) -or [string]$values[$_] -ine [string]$expected[$_]})
        Note ($Who+'WrongOwnValues') $wrong
        Assert ($wrong.Count -eq 0) ('The '+$Who+' process reports the Windows API values for '+(($expected.Keys) -join ', ')+', not the values the user set')
        $tempOk=@('TEMP','TMP')|Where-Object {$values.ContainsKey($_) -and (@((Join-Path $windows 'Temp'),$dataTemp) -contains [string]$values[$_])}
        Assert (@($tempOk).Count -eq 2) ('The '+$Who+' process uses the Windows temp folder or the protected data folder temp, not the TEMP and TMP the user set')
        $markers=@($values.Keys|Where-Object {[string]$values[$_] -like ('*'+$marker+'*')})
        Assert ($markers.Count -eq 0) ('No marker value is left anywhere in the '+$Who+' process environment')
        Assert (@($values.Keys|Where-Object {Test-ClearedName $_ }).Count -eq 0) ('The '+$Who+' process has no .NET-prefixed variable')
    }
    $realRoot=Get-RooIndustriesLocalDataRoot
    foreach($poison in @(@{USERPROFILE=(Join-Path $marker 'profile');LOCALAPPDATA=(Join-Path $marker 'local')},@{USERPROFILE=(Join-Path $marker 'no-such-profile');LOCALAPPDATA=(Join-Path $marker 'no-such-local')},@{USERPROFILE='';LOCALAPPDATA=''})){
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '''+(Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1')+'''; Get-RooIndustriesLocalDataRoot"'))
        $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
        foreach($name in $poison.Keys){$info.EnvironmentVariables[$name]=[string]$poison[$name]}
        $child=[Diagnostics.Process]::Start($info)
        $answer=$child.StandardOutput.ReadToEnd().Trim();$problem=$child.StandardError.ReadToEnd().Trim();$child.WaitForExit()
        Assert ($answer -ieq $realRoot) ('An elevated script resolves the real app data folder with USERPROFILE='+$(if($poison.USERPROFILE -eq ''){'(empty)'}else{Split-Path $poison.USERPROFILE -Leaf})+' set for it: '+$answer+' '+$problem)
    }
    $path=Copy-Probe
    $rule=Start-Probe $path
    $synced=Use-Rule (New-Rule $path @{cpuPriority='AboveNormal'} 'Own environment')
    Assert ($synced.worker.hostRunning -eq $true) 'The governor starts while the user environment holds the marker values'
    Assert-OwnEnvironment 'governor Host' (Get-Process -Id $synced.worker.state.host.processId)
    $context=New-GameContext
    $session=New-GameSession $context
    Start-GameSession $session|Out-Null
    $sessionRequest=Join-Path $session.root 'worker-request.json'
    $sessionHost=$null
    $null=Wait-Until {$script:sessionHostProcess=@(Get-CimInstance Win32_Process -Filter "Name='RooIndustries.SessionHost.exe'"|Where-Object {$_.CommandLine.Contains($sessionRequest)})[0];$null -ne $script:sessionHostProcess} 30 250
    if($null -eq $script:sessionHostProcess){throw 'The protected session helper did not start.'}
    Assert-OwnEnvironment 'protected session helper' (Get-Process -Id $script:sessionHostProcess.ProcessId)
    $stopped=& (Join-Path $scriptsRoot 'Invoke-ProtectedGameSession.ps1') -Action Stop -SessionRoot $session.root -HostDirectory $hostDirectory -DotNetPath $DotNetPath -ConfirmApply
}
