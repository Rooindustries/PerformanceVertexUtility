. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$script:RooIndustriesGovernorManaged='Managed by the governor'
$script:RooIndustriesGovernorOwnership=$null
$script:RooIndustriesGovernorAllControls=@('cpuPriority','affinity','cpuSets','ioPriority','gpuPriority','memoryPriority','executionQoS','priorityBoost')

function Get-RooIndustriesGovernorOwnership {
    $now=[DateTime]::UtcNow
    $cached=$script:RooIndustriesGovernorOwnership
    if($null -ne $cached -and ($now-$cached.readAtUtc).TotalMilliseconds -lt 1000 -and ($now-$cached.readAtUtc).TotalMilliseconds -ge 0){return $cached}
    $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
    $rules=New-Object System.Collections.Generic.List[object]
    $instances=New-Object System.Collections.Generic.List[object]
    $failure=$null
    try {
        $paused=$false
        $settingsPath=Join-Path $root 'governor.json'
        if(Test-Path -LiteralPath $settingsPath){$paused=[bool](Read-RooIndustriesOperationJson $settingsPath).data.paused}
        if(-not $paused){
            $rulesPath=Join-Path $root 'rules'
            if(Test-Path -LiteralPath $rulesPath){
                foreach($file in @(Get-ChildItem -LiteralPath $rulesPath -Filter '*.json' -File)){
                    $rule=(Read-RooIndustriesOperationJson $file.FullName).data
                    if($rule.enabled -isnot [bool]){throw ('The saved rule '+$file.Name+' has no enabled state.')}
                    if(-not $rule.enabled){continue}
                    $controls=@($rule.controls.PSObject.Properties|ForEach-Object {$_.Name})
                    if($null -ne $rule.cpuSelection){$controls+='cpuSets'}
                    $rules.Add([pscustomobject]@{matchMode=[string]$rule.matchMode;executablePath=[string]$rule.executablePath;controls=$controls})
                }
            }
            $statePath=Join-Path $root 'host.json'
            if(Test-Path -LiteralPath $statePath){
                foreach($instance in @((Read-RooIndustriesOperationJson $statePath).data.instances)){
                    if([string]$instance.status -notin @('applying','active')){continue}
                    $preview=(Read-RooIndustriesOperationJson ([string]$instance.previewPath)).data
                    $instances.Add([pscustomobject]@{processId=[int]$instance.process.processId;creationTimeFileTimeUtc=[string]$instance.process.creationTimeFileTimeUtc;controls=@($preview.desired.PSObject.Properties|ForEach-Object {$_.Name})})
                }
            }
        }
    } catch {$failure=$_.Exception.Message}
    $script:RooIndustriesGovernorOwnership=[pscustomobject]@{readAtUtc=$now;rules=@($rules.ToArray());instances=@($instances.ToArray());failure=$failure}
    return $script:RooIndustriesGovernorOwnership
}

function Get-RooIndustriesGovernorOwnedControls {
    param([int]$ProcessId,[string]$ExecutablePath,[string]$ImageName,[string]$CreationTimeFileTimeUtc)
    $ownership=Get-RooIndustriesGovernorOwnership
    if($ownership.failure){return $script:RooIndustriesGovernorAllControls}
    $owned=New-Object 'System.Collections.Generic.HashSet[string]'
    if(-not $ImageName -and $ExecutablePath){$ImageName=[IO.Path]::GetFileName($ExecutablePath)}
    foreach($rule in $ownership.rules){
        $ruleName=[IO.Path]::GetFileName($rule.executablePath)
        $match=if($rule.matchMode -eq 'filename' -or -not $ExecutablePath){$ruleName -ieq $ImageName}else{$rule.executablePath -ieq $ExecutablePath}
        if($match){foreach($control in $rule.controls){[void]$owned.Add([string]$control)}}
    }
    foreach($instance in $ownership.instances){
        if($instance.processId -eq $ProcessId -and (-not $CreationTimeFileTimeUtc -or $instance.creationTimeFileTimeUtc -eq $CreationTimeFileTimeUtc)){
            foreach($control in $instance.controls){[void]$owned.Add([string]$control)}
        }
    }
    return @($owned)
}

function Get-RooIndustriesGovernorProcessControls {
    param([System.Diagnostics.Process]$Process)
    if($null -eq $Process){return @()}
    $path=$null;try{$path=$Process.Path}catch{}
    $created=$null;try{$created=[string]$Process.StartTime.ToUniversalTime().ToFileTimeUtc()}catch{}
    $image=$null;try{$image=$Process.ProcessName+'.exe'}catch{}
    return @(Get-RooIndustriesGovernorOwnedControls -ProcessId $Process.Id -ExecutablePath $path -ImageName $image -CreationTimeFileTimeUtc $created)
}

function Test-RooIndustriesGovernorOwnsControl {
    param([System.Diagnostics.Process]$Process,[string]$Control)
    if($null -eq $Process){return $false}
    $native=switch($Control){'priorityClass'{'cpuPriority'} 'affinityMask'{'affinity'} default{$Control}}
    return @(Get-RooIndustriesGovernorProcessControls $Process) -contains $native
}
