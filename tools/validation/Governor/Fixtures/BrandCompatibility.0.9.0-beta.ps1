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
