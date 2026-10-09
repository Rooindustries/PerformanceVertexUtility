function Get-RooIndustriesBackgroundPlacement {
    param([object[]]$Topology,[int]$ProcessorGroupCount=1,[object]$SystemAffinityMask=$null)
    $result=[pscustomobject]@{available=$false;kind='';label='Background apps on E-cores or CCD1, normal priority';reason='This CPU has no E-cores or second CCD.';mask=[long]0}
    if($ProcessorGroupCount -ne 1 -or @($Topology|Where-Object {$_.group -ne 0}).Count) {
        $result.reason='This preset needs a CPU with one processor group.'
        return $result
    }
    $seen=New-Object 'System.Collections.Generic.HashSet[int]'
    foreach($cpu in $Topology) {
        if($null -eq $cpu.logicalProcessorIndex -or $null -eq $cpu.efficiencyClass -or $null -eq $cpu.lastLevelCacheIndex -or
            [int]$cpu.logicalProcessorIndex -lt 0 -or [int]$cpu.logicalProcessorIndex -gt 63 -or
            [int]$cpu.efficiencyClass -lt 0 -or [int]$cpu.lastLevelCacheIndex -lt 0 -or
            -not$seen.Add([int]$cpu.logicalProcessorIndex)) {
            $result.reason='Windows returned an incomplete CPU topology.'
            return $result
        }
    }
    if(-not$seen.Contains(0)){ $result.reason='Windows did not report logical CPU 0.'; return $result }
    $classes=@($Topology|ForEach-Object {[int]$_.efficiencyClass}|Sort-Object -Unique)
    $caches=@($Topology|ForEach-Object {[int]$_.lastLevelCacheIndex}|Sort-Object -Unique)
    $selected=@()
    if($classes.Count -gt 1) {
        $result.kind='e-cores'
        $result.label='Background apps on E-cores, normal priority'
        $highest=($classes|Measure-Object -Maximum).Maximum
        $selected=@($Topology|Where-Object {[int]$_.efficiencyClass -lt $highest})
    } elseif($caches.Count -ge 2) {
        $result.kind='ccd'
        $result.label=if($caches.Count -eq 2){'Background apps on CCD1, normal priority'}else{'Background apps on the other CCDs, normal priority'}
        $first=($Topology|Where-Object {$_.logicalProcessorIndex -eq 0}|Select-Object -First 1).lastLevelCacheIndex
        $selected=@($Topology|Where-Object {$_.lastLevelCacheIndex -ne $first})
    } else { return $result }
    [long]$mask=0
    foreach($cpu in $selected){$mask=$mask -bor ([long]1 -shl [int]$cpu.logicalProcessorIndex)}
    if($null -ne $SystemAffinityMask){$mask=$mask -band [long]$SystemAffinityMask}
    $result.mask=$mask
    $result.available=$mask -ne 0
    $result.reason=if($result.available){''}else{'Windows does not allow this app on any of the selected CPUs.'}
    return $result
}

function Read-RooIndustriesBackgroundPlacement {
    Ensure-RooIndustriesNativeProcessControl
    if($null -eq ('RooIndustries.Optimization.CpuSets.Target' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot '..\native\CpuSets\RooIndustriesCpuSets.cs')
    }
    $target=[RooIndustries.Optimization.CpuSets.Target]::new($PID,$false)
    try {
        Get-RooIndustriesBackgroundPlacement -Topology @($target.Topology()) -ProcessorGroupCount ([RooIndustriesNativeProcessControl]::GetActiveProcessorGroupCount())
    } finally { $target.Dispose() }
}

function Test-RooIndustriesBackgroundPlacementCandidate {
    param([object]$Process,[object]$Profile,[object]$ProtectedCatalog,[string]$TargetGameProcessName)
    if([int]$Process.pid -le 4 -or [bool]$Process.protected -or [bool]$Process.blocked -or
        [string]$Process.protection -eq 'protected' -or
        [string]$Process.category -in @('windowsCore','security','network','networkService','audio','audioInput','audioService','foregroundGame')){return $false}
    if((Get-RooIndustriesProtectedCatalogMatch $Process $ProtectedCatalog).matched -or
        (Get-RooIndustriesProtectedCompanionMatch $Process $Profile).matched -or
        (Get-RooIndustriesTargetGameMatch $Process $Profile $TargetGameProcessName).matched){return $false}
    $match=Get-RooIndustriesRuleMatch $Process $Profile @('setPriority')
    if(-not$match.matched -or [string]$match.rule.action.priorityClass -notin @('BelowNormal','Idle')){return $false}
    $live=Get-Process -Id ([int]$Process.pid) -ErrorAction SilentlyContinue
    return $null -ne $live -and @(Get-RooIndustriesGovernorProcessControls $live).Count -eq 0
}
