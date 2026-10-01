$script:RooIndustriesLegacyIdentity = @{
    policyTask = 'RooOptimizationSuite.ProcessRules.'
    policyDescription = 'Roo process rules | '
    gameTask = 'Roo Protected Session '
    gameDescription = 'Roo protected game session | '
    dataFolder = 'RooOptimizationSuite'
}

function Find-RooIndustriesCompatibleTask {
    param([string]$Name,[string]$LegacyName,[string]$Description,[string]$LegacyDescription)
    $found=@(Get-ScheduledTask -TaskName $Name,$LegacyName -ErrorAction SilentlyContinue)
    if($found.Count -gt 1){throw 'Both current and legacy worker tasks exist. Stop and reconcile the existing workers before starting another.'}
    if($found.Count -eq 0){return $null}
    $task=$found[0]
    $expected=if($task.TaskName -ceq $Name){$Description}else{$LegacyDescription}
    if($task.Description -cne $expected){throw 'The worker task belongs to another user or state folder.'}
    return $task
}

function Get-RooIndustriesLocalDataRoot {
    param([string]$LocalData=[Environment]::GetFolderPath('LocalApplicationData'))
    $legacy=Join-Path $LocalData $script:RooIndustriesLegacyIdentity.dataFolder
    if(Test-Path -LiteralPath $legacy -PathType Container){return $legacy}
    return Join-Path $localData 'RooIndustriesOptimizationSuite'
}

$script:RooIndustriesCodeLoadingVariables=@('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_ARM64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')

function New-RooIndustriesElevatedTaskAction {
    param([Parameter(Mandatory=$true)][string]$Executable,[string]$Arguments='',[Parameter(Mandatory=$true)][string]$WorkingDirectory)
    $system=[Environment]::GetFolderPath('System')
    $clear=($script:RooIndustriesCodeLoadingVariables|ForEach-Object {'set '+$_+'='}) -join '&'
    $command='"'+$clear+'&"'+$Executable+'" '+$Arguments+'"'
    return New-ScheduledTaskAction -Execute (Join-Path $system 'conhost.exe') -Argument ('--headless "'+(Join-Path $system 'cmd.exe')+'" /d /s /c '+$command) -WorkingDirectory $WorkingDirectory
}
