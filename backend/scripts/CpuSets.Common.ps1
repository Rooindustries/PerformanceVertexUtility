. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Initialize-RooIndustriesCpuSets {
    if ($null -eq ('RooIndustries.Optimization.CpuSets.Target' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot '..\native\CpuSets\RooIndustriesCpuSets.cs')
    }
}

function Test-RooIndustriesCpuSetIdsEqual {
    param($Left, $Right)
    return ((@($Left | Sort-Object) -join ',') -ceq (@($Right | Sort-Object) -join ','))
}

function Assert-RooIndustriesCpuSetIdentity {
    param($Expected, $Actual)
    if ($null -eq $Expected -or [int]$Expected.processId -ne $Actual.processId -or
        [string]$Expected.creationTimeFileTimeUtc -cne $Actual.creationTimeFileTimeUtc -or
        [string]$Expected.executablePath -ine $Actual.executablePath) {
        throw 'Target identity changed; a process ID alone does not authorize a change.'
    }
}

function Get-RooIndustriesCpuSetProtection {
    param($Identity, $NativeProtection)
    $catalog = Read-RooIndustriesJsonFile (Join-Path $PSScriptRoot '..\profiles\protected-processes.json')
    $process = [pscustomobject]@{ name=[IO.Path]::GetFileName($Identity.executablePath); executablePath=$Identity.executablePath; category='' }
    $match = Get-RooIndustriesProtectedCatalogMatch $process $catalog
    return [pscustomobject]@{
        protected=($match.matched -or ($NativeProtection.known -and $NativeProtection.protectedProcess))
        catalogMatch=if ($match.matched) { $match.item.itemId } else { $null }
        protectionLevel=$NativeProtection
        queryAccess='0x1000'; changeAccess='0x3000'
        targetOpenUsesRestrictedPrivileges=$true
        setAccessVerified=$false
        gameCompatibility='unverified'
        limits=@('Windows may deny access; no privileged fallback is attempted.',
            'Thread-selected CPU Sets and restrictive hard affinity can override process defaults.',
            'A readable protection level does not establish anti-cheat compatibility.',
            'Assignment readback proves Windows state, not performance or ban safety.')
    }
}

function New-RooIndustriesCpuSetPreview {
    param([int]$TargetProcessId, [uint32[]]$CpuSetId)
    $target = [RooIndustries.Optimization.CpuSets.Target]::new($TargetProcessId,$false)
    try {
        $identity = $target.Identity()
        $topology = @($target.Topology())
        $compatibility = Get-RooIndustriesCpuSetProtection $identity ($target.Protection())
        if ($compatibility.protected) { throw 'The protected-process catalog or Windows protection level excludes this target.' }
        $available = @($topology | Where-Object { -not $_.allocated -or $_.allocatedToTargetProcess } | ForEach-Object { $_.id })
        if (@($CpuSetId | Select-Object -Unique).Count -ne $CpuSetId.Count) { throw 'Duplicate CPU Set IDs are invalid.' }
        foreach ($id in $CpuSetId) { if ($available -notcontains $id) { throw "CPU Set ID $id is unavailable or reserved for another process." } }
        return [pscustomobject]@{
            schemaVersion=1; kind='cpu-set-preview'; operationId=[guid]::NewGuid().ToString('N')
            createdAtUtc=Get-RooIndustriesUtcStamp; owner=Get-RooIndustriesOperationOwner; identity=$identity
            originalCpuSetIds=@($target.Read()); desiredCpuSetIds=@($CpuSetId | Sort-Object)
            topology=$topology; compatibility=$compatibility
        }
    } finally { $target.Dispose() }
}

function Get-RooIndustriesCpuSetError {
    param($Exception)
    while ($null -ne $Exception.InnerException) { $Exception=$Exception.InnerException }
    $nativeType='RooIndustries.Optimization.CpuSets.NativeFailure' -as [type]
    $native = $null -ne $nativeType -and $nativeType.IsInstanceOfType($Exception)
    return [pscustomobject]@{
        code=if ($native) { 'WINDOWS_API_REJECTED' } else { 'CPU_SET_OPERATION_REJECTED' }
        message=$Exception.Message
        api=if ($native) { $Exception.Api } else { $null }
        win32Error=if ($native) { $Exception.NativeErrorCode } else { $null }
        requestedAccess=if ($native) { '0x'+$Exception.RequestedAccess.ToString('X4') } else { $null }
        nextAction=if ($native -and $Exception.NativeErrorCode -eq 5) {
            'Keep this target unchanged. Check its protection and access policy; use an allowed background process or vendor-supported setting.'
        } else { 'Inspect the target, reviewed preview and operation journal before retrying.' }
    }
}
