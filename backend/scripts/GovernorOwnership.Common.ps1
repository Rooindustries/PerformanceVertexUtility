. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$script:RooIndustriesGovernorManaged='Managed by the governor'
$script:RooIndustriesGovernorOwnership=$null
$script:RooIndustriesGovernorOwnershipFailedAtUtc=[DateTime]::MinValue
$script:RooIndustriesGovernorOwnershipLoggedAtUtc=[DateTime]::MinValue
$script:RooIndustriesGovernorAllControls=@('cpuPriority','affinity','cpuSets','ioPriority','gpuPriority','memoryPriority','executionQoS','priorityBoost')

function Write-RooIndustriesGovernorOwnershipLog([string]$Message) {
    $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
    if(-not (Test-Path -LiteralPath $root)){return}
    for($attempt=0;$attempt -lt 5;$attempt++){
        try {
            $directory=Join-Path $root 'logs'
            [IO.Directory]::CreateDirectory($directory)|Out-Null
            $path=Join-Path $directory 'governor.log'
            if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 262144){Move-Item -LiteralPath $path -Destination ($path+'.1') -Force}
            [IO.File]::AppendAllText($path,[DateTime]::UtcNow.ToString('o')+' '+$Message+[Environment]::NewLine)
            return
        } catch {Start-Sleep -Milliseconds 20}
    }
}

function Get-RooIndustriesGovernorOwnership {
    $now=[DateTime]::UtcNow
    $cached=$script:RooIndustriesGovernorOwnership
    if($null -ne $cached -and ($now-$cached.readAtUtc).TotalMilliseconds -lt 1000 -and ($now-$cached.readAtUtc).TotalMilliseconds -ge 0){return $cached}
    $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
    $sinceFailure=($now-$script:RooIndustriesGovernorOwnershipFailedAtUtc).TotalMilliseconds
    $budget=if($sinceFailure -ge 0 -and $sinceFailure -lt 10000){0}else{3000}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $attempts=0
    while($true){
    $attempts++
    $readAtUtc=[DateTime]::UtcNow
    $rules=New-Object System.Collections.Generic.List[object]
    $instances=New-Object System.Collections.Generic.List[object]
    $failure=$null
    try {
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
                $fields=if($instance.PSObject.Properties['field'] -and $instance.field){@([string]$instance.field)}else{@((Read-RooIndustriesOperationJson ([string]$instance.previewPath)).data.desired.PSObject.Properties|ForEach-Object {$_.Name})}
                $instances.Add([pscustomobject]@{processId=[int]$instance.process.processId;creationTimeFileTimeUtc=[string]$instance.process.creationTimeFileTimeUtc;controls=$fields})
            }
        }
    } catch {$failure=if($_.Exception.Message){$_.Exception.Message}else{$_.Exception.GetType().FullName}}
    if(-not $failure -or $clock.ElapsedMilliseconds -ge $budget){break}
    Start-Sleep -Milliseconds 100
    }
    $ownership=[pscustomobject]@{readAtUtc=$readAtUtc;rules=@($rules.ToArray());instances=@($instances.ToArray());failure=$failure}
    if($failure){
        $script:RooIndustriesGovernorOwnershipFailedAtUtc=[DateTime]::UtcNow
        $sinceLog=([DateTime]::UtcNow-$script:RooIndustriesGovernorOwnershipLoggedAtUtc).TotalSeconds
        if($sinceLog -lt 0 -or $sinceLog -ge 60){
            $script:RooIndustriesGovernorOwnershipLoggedAtUtc=[DateTime]::UtcNow
            Write-RooIndustriesGovernorOwnershipLog ('Could not read the saved rules in '+$root+' after '+$attempts+' attempts over '+$clock.ElapsedMilliseconds+' ms, so this change treats every process setting as managed by the governor: '+$failure)}
        return $ownership
    }
    $script:RooIndustriesGovernorOwnership=$ownership
    return $ownership
}

function Enter-RooIndustriesGovernorGate([double]$Seconds=30) {
    $name='Global\RooIndustriesGovernorGate-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        $mutex=$null
        try {$mutex=[Threading.Mutex]::new($false,$name)}
        catch {
            $failure=$_.Exception
            while($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException){$failure=$failure.InnerException}
            if($failure -isnot [UnauthorizedAccessException]){throw}
            if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null}
            Start-Sleep -Milliseconds 100
            continue
        }
        $held=$false
        try {$held=$mutex.WaitOne([TimeSpan]::FromSeconds([Math]::Max(0,$Seconds-$clock.Elapsed.TotalSeconds)))}
        catch {
            $failure=$_.Exception
            while($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException){$failure=$failure.InnerException}
            if($failure -isnot [Threading.AbandonedMutexException]){$mutex.Dispose();throw}
            $held=$true
        }
        if(-not $held){$mutex.Dispose();return $null}
        $script:RooIndustriesGovernorOwnership=$null
        return $mutex
    }
}

function Exit-RooIndustriesGovernorGate($Gate) {
    if($null -eq $Gate){return}
    try {$Gate.ReleaseMutex()} finally {$Gate.Dispose()}
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
