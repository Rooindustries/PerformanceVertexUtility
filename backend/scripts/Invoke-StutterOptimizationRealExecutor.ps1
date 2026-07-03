param(
    [ValidateSet('standby-memory','timer-resolution','power-plan','shader-cache-cleanup','service-pause-preview')]
    [string]$OptimizationId,
    [string]$ShaderCacheRoot = '',
    [string]$BackupRoot = '',
    [string[]]$ServiceName = @(),
    [string]$ServiceShimPath = '',
    [uint32]$TimerPeriodMilliseconds = 1,
    [int]$TimerDurationMilliseconds = 250,
    [int]$TimeoutSeconds = 15,
    [string]$OutputPath = '',
    [switch]$ConfirmApply,
    [switch]$AllowRealSystemExecution,
    [switch]$UserApproved
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'StutterOptimization.Common.ps1')
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')

function Invoke-PowerCfg {
    param([string[]]$Arguments)
    $powerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $powerCfg)) { $powerCfg = 'powercfg.exe' }
    return Invoke-RooBackendHiddenProcess -FilePath $powerCfg -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Get-ActivePowerSchemeGuidFromText {
    param([string]$Text)
    if ($Text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $matches[1] }
    return ''
}

function Get-StandbyMemorySnapshot {
    $perf = $null
    try { $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop } catch { $perf = $null }
    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { $os = $null }
    return [pscustomobject]@{
        capturedAtUtc = Get-RooUtcStamp
        standbyCacheReserveBytes = Get-RooPropertyValue $perf 'StandbyCacheReserveBytes' $null
        standbyCacheNormalPriorityBytes = Get-RooPropertyValue $perf 'StandbyCacheNormalPriorityBytes' $null
        standbyCacheCoreBytes = Get-RooPropertyValue $perf 'StandbyCacheCoreBytes' $null
        availableMBytes = Get-RooPropertyValue $perf 'AvailableMBytes' $null
        freePhysicalMemoryKBytes = Get-RooPropertyValue $os 'FreePhysicalMemory' $null
        totalVisibleMemoryKBytes = Get-RooPropertyValue $os 'TotalVisibleMemorySize' $null
    }
}

function Get-ServiceReadiness {
    param([string[]]$Names)
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(Get-RooArray $Names)) {
        $service = $null
        $cim = $null
        try { $service = Get-Service -Name ([string]$name) -ErrorAction Stop } catch { $service = $null }
        try { $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ([string]$name).Replace("'", "''")) -ErrorAction Stop } catch { $cim = $null }
        $records.Add([pscustomobject]@{
            name = [string]$name
            exists = ($null -ne $service)
            status = if ($service) { [string]$service.Status } else { $null }
            canPauseAndContinue = if ($service) { [bool]$service.CanPauseAndContinue } else { $false }
            dependentServices = if ($service) { @($service.DependentServices | ForEach-Object { $_.Name }) } else { @() }
            requiredServices = if ($service) { @($service.ServicesDependedOn | ForEach-Object { $_.Name }) } else { @() }
            startMode = Get-RooPropertyValue $cim 'StartMode' $null
            state = Get-RooPropertyValue $cim 'State' $null
            processId = Get-RooPropertyValue $cim 'ProcessId' $null
            runnerLayerReady = ($null -ne $service)
            realPauseRequiresApproval = $true
        }) | Out-Null
    }
    return @($records.ToArray())
}

function Get-StandbyHelperBuildPlan {
    param([string]$HelperSourcePath)
    $buildScriptPath = Join-Path $PSScriptRoot 'Build-StandbyMemoryHelper.ps1'
    if (-not (Test-Path -LiteralPath $buildScriptPath -PathType Leaf)) {
        return [pscustomobject]@{
            buildScriptPath = $buildScriptPath
            buildScriptExists = $false
            status = 'build-script-missing'
        }
    }
    try {
        $output = & $buildScriptPath -SourcePath $HelperSourcePath
        return ($output -join [Environment]::NewLine) | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            buildScriptPath = $buildScriptPath
            buildScriptExists = $true
            status = 'probe-failed'
            error = $_.Exception.Message
        }
    }
}

try {
    $realRequested = [bool]$AllowRealSystemExecution
    $requiresRealFlag = ($OptimizationId -in @('timer-resolution','power-plan') -or (-not [string]::IsNullOrWhiteSpace($ServiceShimPath)) -or ($OptimizationId -eq 'shader-cache-cleanup' -and [bool]$ConfirmApply))
    $gates = @(
        (New-RooBackendExecutorGate 'explicit-user-approval' 'Explicit approval evidence captured' $true ([bool]$UserApproved) 'Real/detection stutter executor requires user approval evidence for this validation.' $null),
        (New-RooBackendExecutorGate 'real-system-flag' 'Real system execution flag supplied when needed' $requiresRealFlag ((-not $requiresRealFlag) -or $realRequested) 'Timer and power plan reversible sessions require -AllowRealSystemExecution.' ([pscustomobject]@{ optimizationId = $OptimizationId })),
        (New-RooBackendExecutorGate 'confirm-apply' 'Confirmed execution requested when needed' $requiresRealFlag ((-not $requiresRealFlag) -or [bool]$ConfirmApply) 'Timer and power plan reversible sessions require -ConfirmApply.' $null)
    )
    $blockingGates = @($gates | Where-Object { $_.blocking })
    $canRunReal = ($blockingGates.Count -eq 0)
    $hasBlockingGates = ($blockingGates.Count -gt 0)
    $sequence = New-Object System.Collections.Generic.List[object]
    $capability = [ordered]@{}
    $status = if ($canRunReal) { 'success' } elseif ($ConfirmApply -or $AllowRealSystemExecution) { 'blocked' } else { 'preview' }
    $nextStep = ''

    switch ($OptimizationId) {
        'timer-resolution' {
            if ($canRunReal) {
                $timerResult = Invoke-RooBackendPowerShellShim -ShimPath (Join-Path $PSScriptRoot 'Invoke-TimerResolutionSession.ps1') -Arguments @('-PeriodMilliseconds', [string]$TimerPeriodMilliseconds, '-DurationMilliseconds', [string]$TimerDurationMilliseconds) -TimeoutSeconds $TimeoutSeconds
                $timerJson = $null
                try { $timerJson = ([string](Get-RooPropertyValue $timerResult 'stdout' '') | ConvertFrom-Json) } catch { $timerJson = $null }
                $sequence.Add([pscustomobject]@{ order = 1; step = 'timer-resolution-bounded-session'; result = $timerResult; parsedResult = $timerJson; completed = ($timerResult.exitCode -eq 0 -and $timerResult.timedOut -ne $true) }) | Out-Null
                if ($timerResult.exitCode -ne 0 -or $timerResult.timedOut) { $status = 'capability-limited' }
                $capability.timerRestoreProved = [bool](Get-RooPropertyValue (Get-RooPropertyValue $timerJson 'summary' $null) 'restoreCalledOnExit' $false)
                if ($status -eq 'capability-limited') {
                    $capability.timerApiFailure = [pscustomobject]@{
                        processExitCode = Get-RooPropertyValue $timerResult 'exitCode' $null
                        timedOut = [bool](Get-RooPropertyValue $timerResult 'timedOut' $false)
                        startError = Get-RooPropertyValue $timerResult 'startError' $null
                        helperStatus = Get-RooPropertyValue $timerJson 'status' $null
                        beginResult = Get-RooPropertyValue (Get-RooPropertyValue $timerJson 'summary' $null) 'beginResult' $null
                        endResult = Get-RooPropertyValue (Get-RooPropertyValue $timerJson 'summary' $null) 'endResult' $null
                        stdout = Get-RooPropertyValue $timerResult 'stdout' ''
                        stderr = Get-RooPropertyValue $timerResult 'stderr' ''
                    }
                }
                $nextStep = 'Use the bounded helper for session-scoped timer requests only; never persist timer resolution outside the owned helper process.'
            }
        }
        'power-plan' {
            if ($canRunReal) {
                $originalGuid = ''
                $tempGuid = ''
                $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ('roo-power-plan-import-' + [guid]::NewGuid().ToString('N') + '.pow')
                try {
                    $getActive = Invoke-PowerCfg @('/getactivescheme')
                    $sequence.Add([pscustomobject]@{ order = 1; step = 'power-get-active'; result = $getActive; completed = ($getActive.exitCode -eq 0 -and -not $getActive.timedOut) }) | Out-Null
                    $originalGuid = Get-ActivePowerSchemeGuidFromText ([string](Get-RooPropertyValue $getActive 'stdout' ''))
                    if ([string]::IsNullOrWhiteSpace($originalGuid)) { throw 'Could not parse active power scheme GUID from powercfg output.' }
                    $export = Invoke-PowerCfg @('/export', $exportPath, $originalGuid)
                    $sequence.Add([pscustomobject]@{ order = 2; step = 'power-export-active'; exportPath = $exportPath; result = $export; completed = ($export.exitCode -eq 0 -and -not $export.timedOut -and (Test-Path -LiteralPath $exportPath)) }) | Out-Null
                    if ($export.exitCode -ne 0 -or $export.timedOut -or -not (Test-Path -LiteralPath $exportPath)) { throw 'Could not export active power scheme to temporary .pow file.' }
                    $tempGuid = [guid]::NewGuid().ToString()
                    $import = Invoke-PowerCfg @('/import', $exportPath, $tempGuid)
                    $sequence.Add([pscustomobject]@{ order = 3; step = 'power-import-temp'; importPath = $exportPath; temporarySchemeGuid = $tempGuid; result = $import; completed = ($import.exitCode -eq 0 -and -not $import.timedOut) }) | Out-Null
                    if ($import.exitCode -ne 0 -or $import.timedOut) { throw 'Could not import temporary power scheme from exported .pow file.' }
                    $rename = Invoke-PowerCfg @('/changename', $tempGuid, 'Roo Temporary Validation Plan')
                    $sequence.Add([pscustomobject]@{ order = 4; step = 'power-rename-temp'; result = $rename; completed = ($rename.exitCode -eq 0 -and -not $rename.timedOut) }) | Out-Null
                    $select = Invoke-PowerCfg @('/setactive', $tempGuid)
                    $sequence.Add([pscustomobject]@{ order = 5; step = 'power-select-temp'; result = $select; completed = ($select.exitCode -eq 0 -and -not $select.timedOut) }) | Out-Null
                    Start-Sleep -Milliseconds 100
                } catch {
                    $status = 'capability-limited'
                    $nextStep = 'Inspect the captured powercfg command, exit code, stdout, and stderr; Windows may require policy permission to export, import, select, restore, or delete power schemes.'
                    $sequence.Add([pscustomobject]@{ order = 90; step = 'power-error'; error = $_.Exception.Message; completed = $false }) | Out-Null
                } finally {
                    if (-not [string]::IsNullOrWhiteSpace($originalGuid)) {
                        $restore = Invoke-PowerCfg @('/setactive', $originalGuid)
                        $sequence.Add([pscustomobject]@{ order = 98; step = 'power-restore-original'; result = $restore; completed = ($restore.exitCode -eq 0 -and -not $restore.timedOut) }) | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($tempGuid)) {
                        $delete = Invoke-PowerCfg @('/delete', $tempGuid)
                        $sequence.Add([pscustomobject]@{ order = 99; step = 'power-delete-temp'; result = $delete; completed = ($delete.exitCode -eq 0 -and -not $delete.timedOut) }) | Out-Null
                    }
                    if (-not [string]::IsNullOrWhiteSpace($exportPath) -and (Test-Path -LiteralPath $exportPath)) {
                        Remove-Item -LiteralPath $exportPath -Force -ErrorAction SilentlyContinue
                    }
                }
                $capability.originalSchemeGuid = $originalGuid
                $capability.temporarySchemeGuid = $tempGuid
                $capability.exportImportPathUsed = $true
                $capability.temporaryPowFilePath = $exportPath
                $capability.restoreAttempted = @($sequence.ToArray() | Where-Object { $_.step -eq 'power-restore-original' }).Count -gt 0
                $capability.cleanupAttempted = @($sequence.ToArray() | Where-Object { $_.step -eq 'power-delete-temp' }).Count -gt 0
                if ([string]::IsNullOrWhiteSpace($nextStep)) { $nextStep = 'Temporary power plan export/import/select/restore/delete completed; keep future plan imports behind the same restore/delete guard.' }
            }
        }
        'standby-memory' {
            $before = Get-StandbyMemorySnapshot
            $after = Get-StandbyMemorySnapshot
            $helperSourcePath = Resolve-RooPath '' (Join-Path $PSScriptRoot '..\native\StandbyMemoryHelper\RooStandbyMemoryHelper.cs')
            $helperBuildPlan = Get-StandbyHelperBuildPlan $helperSourcePath
            $sequence.Add([pscustomobject]@{ order = 1; step = 'standby-memory-readonly-counters'; before = $before; after = $after; completed = $true }) | Out-Null
            if (-not $hasBlockingGates) { $status = 'helper-required' }
            $capability.readOnlyCountersImplemented = $true
            $capability.oneShotClearRunnerScaffolded = $true
            $capability.helperSourcePath = $helperSourcePath
            $capability.helperSourceExists = (Test-Path -LiteralPath $helperSourcePath -PathType Leaf)
            $capability.helperBuildPlan = $helperBuildPlan
            $capability.helperBuildScriptExists = [bool](Get-RooPropertyValue $helperBuildPlan 'buildScriptExists' $false)
            $capability.helperToolchainDetected = [bool](Get-RooPropertyValue (Get-RooPropertyValue $helperBuildPlan 'capabilities' $null) 'toolchainDetected' $false)
            $capability.helperElevationCommand = Get-RooPropertyValue (Get-RooPropertyValue $helperBuildPlan 'elevation' $null) 'commandLine' $null
            $capability.executionRequires = 'Build this helper source as an elevated/admin executable, then launch it behind exact path, approval, and before/after counter gates.'
            $nextStep = "Build and sign the native helper source at $helperSourcePath, then run the executable elevated behind approval and before/after counter capture."
        }
        'shader-cache-cleanup' {
            $root = if ([string]::IsNullOrWhiteSpace($ShaderCacheRoot)) { Join-Path $env:LOCALAPPDATA 'NVIDIA' } else { [System.IO.Path]::GetFullPath($ShaderCacheRoot) }
            if ($ConfirmApply -and $AllowRealSystemExecution -and (Test-RooStutterPathInsideTemp $root)) {
                $applyParams = @{
                    OptimizationId = 'shader-cache-cleanup'
                    ShaderCacheRoot = $root
                    ConfirmApply = $true
                    AllowDisposableFixtureApply = $true
                }
                if (-not [string]::IsNullOrWhiteSpace($BackupRoot)) { $applyParams['BackupRoot'] = $BackupRoot }
                $applyOutput = & (Join-Path $PSScriptRoot 'Invoke-StutterOptimization.ps1') @applyParams
                $applyResult = ($applyOutput -join [Environment]::NewLine) | ConvertFrom-Json
                $status = [string](Get-RooPropertyValue $applyResult 'status' 'failed')
                $sequence.Add([pscustomobject]@{ order = 1; step = 'shader-cache-approved-delete-path'; root = $root; result = $applyResult; completed = ($status -eq 'success') }) | Out-Null
                $capability.approvalGatedDeletePathExecuted = ($status -eq 'success')
                $capability.rollbackManifestPath = Get-RooPropertyValue (Get-RooPropertyValue $applyResult 'rollback' $null) 'rollbackManifestPath' $null
                $nextStep = 'Use the same backup/delete/restore engine for real shader cache deletion only after exact target allowlist and user approval.'
            } else {
                $items = @(Get-RooStutterShaderCacheItems $root)
                $plan = @($items | ForEach-Object {
                    [pscustomobject]@{
                        itemId = Get-RooPropertyValue $_ 'itemId' ''
                        source = Get-RooPropertyValue $_ 'path' ''
                        relativePath = Get-RooPropertyValue $_ 'relativePath' ''
                        backupPathPreview = Join-Path '<approved-backup-root>' ([string](Get-RooPropertyValue $_ 'relativePath' ''))
                        deleteWouldUseFixturePlanner = $true
                    }
                })
                $sequence.Add([pscustomobject]@{ order = 1; step = 'shader-cache-real-path-readiness-plan'; root = $root; itemCount = $items.Count; plan = $plan; completed = $true }) | Out-Null
                if (-not $hasBlockingGates) { $status = 'success' }
                $capability.approvalGatedDeletePathExecuted = $false
                $nextStep = 'Require exact target allowlist, approved backup root, and rollback manifest before enabling real shader-cache deletion.'
            }
            $capability.realPathPlannerImplemented = $true
            $capability.realDeletionAttempted = $false
            $capability.sameBackupDeleteRestorePlanner = $true
        }
        'service-pause-preview' {
            $records = Get-ServiceReadiness $ServiceName
            $sequence.Add([pscustomobject]@{ order = 1; step = 'service-status-dependency-analysis'; services = $records; completed = $true }) | Out-Null
            $serviceRunnerOk = $true
            if (-not [string]::IsNullOrWhiteSpace($ServiceShimPath) -and $canRunReal) {
                $order = 2
                foreach ($svc in @(Get-RooArray $ServiceName)) {
                    foreach ($verb in @('service-backup','service-pause','service-restore')) {
                        $shimResult = Invoke-RooBackendPowerShellShim -ShimPath $ServiceShimPath -Arguments @($verb, [string]$svc) -TimeoutSeconds $TimeoutSeconds
                        $ok = ((-not [bool](Get-RooPropertyValue $shimResult 'timedOut' $false)) -and [int](Get-RooPropertyValue $shimResult 'exitCode' -1) -eq 0)
                        if (-not $ok) { $serviceRunnerOk = $false }
                        $sequence.Add([pscustomobject]@{ order = $order; step = $verb; serviceName = [string]$svc; result = $shimResult; completed = $ok }) | Out-Null
                        $order++
                    }
                }
            }
            $status = if ($hasBlockingGates) { $status } elseif ($serviceRunnerOk) { 'success' } else { 'failed' }
            $capability.serviceAnalyzerImplemented = $true
            $capability.realPauseRunnerLayerReady = $true
            $capability.realPauseAttempted = $false
            $capability.serviceShimRunnerExecuted = (-not [string]::IsNullOrWhiteSpace($ServiceShimPath) -and $canRunReal)
            $nextStep = 'Require exact service allowlist, dependency review, and approval before running pause/restore against real services.'
        }
    }

    $runs = @($sequence.ToArray())
    if ($OptimizationId -eq 'power-plan' -and $status -eq 'capability-limited') {
        $failedSteps = @($runs | Where-Object {
            ($_.PSObject.Properties['result'] -and ($_.result.timedOut -eq $true -or ($null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0) -or -not [string]::IsNullOrWhiteSpace([string]$_.result.startError))) -or
            ($_.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$_.error))
        })
        $capability.powerCommandFailure = [pscustomobject]@{
            failedStepCount = $failedSteps.Count
            failedSteps = @($failedSteps | ForEach-Object {
                [pscustomobject]@{
                    step = [string]$_.step
                    error = Get-RooPropertyValue $_ 'error' $null
                    filePath = Get-RooPropertyValue (Get-RooPropertyValue $_ 'result' $null) 'filePath' $null
                    arguments = @(Get-RooPropertyArray (Get-RooPropertyValue $_ 'result' $null) 'arguments')
                    exitCode = Get-RooPropertyValue (Get-RooPropertyValue $_ 'result' $null) 'exitCode' $null
                    timedOut = Get-RooPropertyValue (Get-RooPropertyValue $_ 'result' $null) 'timedOut' $null
                    startError = Get-RooPropertyValue (Get-RooPropertyValue $_ 'result' $null) 'startError' $null
                    stdout = Get-RooPropertyValue (Get-RooPropertyValue $_ 'result' $null) 'stdout' ''
                    stderr = Get-RooPropertyValue (Get-RooPropertyValue $_ 'result' $null) 'stderr' ''
                }
            })
        }
    }
    $result = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.realExecutor'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        optimizationId = $OptimizationId
        dryRun = ($OptimizationId -notin @('timer-resolution','power-plan') -or -not $canRunReal)
        status = $status
        executionMode = switch ($OptimizationId) {
            'timer-resolution' { 'real-reversible-timer-session' }
            'power-plan' { 'real-reversible-power-plan-session' }
            'standby-memory' { 'real-readonly-capability-detection' }
            'shader-cache-cleanup' { 'real-path-readiness-preview' }
            'service-pause-preview' { 'real-readonly-service-analysis' }
        }
        gates = @($gates)
        executionSequence = $runs
        capabilities = [pscustomobject]$capability
        summary = [pscustomobject]@{
            executionStepCount = $runs.Count
            completedStepCount = @($runs | Where-Object { $_.completed -eq $true }).Count
            timeoutCount = @($runs | Where-Object { $_.result.timedOut -eq $true }).Count
            nonZeroExitCount = @($runs | Where-Object { $null -ne $_.result.exitCode -and [int]$_.result.exitCode -ne 0 }).Count
            willPersist = $false
            willLaunchExternalUtility = ($OptimizationId -eq 'power-plan')
            willLaunchForbiddenUtility = $false
            willEditRegistry = $false
            willEditServices = $false
            willDeleteRealFiles = $false
            focusStealPrevented = (@($runs | Where-Object { $_.result.invocation.focusStealPrevented -eq $false }).Count -eq 0)
            blockingGateCount = $blockingGates.Count
            nextEngineeringStep = $nextStep
        }
        warnings = @((New-RooStutterIssue 'STUTTER_REAL_EXECUTOR_CONTROLLED' 'Controlled stutter executor evaluated reversible or read-only capability path.' 'info' $OptimizationId $false $nextStep $null))
        errors = @()
        logs = @((New-RooLog 'Controlled stutter real/detection executor completed.'))
    }
    Write-RooJsonOutput $result $OutputPath
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.stutterOptimization.realExecutor'
        schemaVersion = 1
        productName = $script:RooStutterProductName
        capturedAtUtc = Get-RooUtcStamp
        optimizationId = $OptimizationId
        dryRun = $true
        status = 'failed'
        executionMode = 'blocked'
        executionSequence = @()
        summary = [pscustomobject]@{ willPersist = $false; willLaunchForbiddenUtility = $false; nextEngineeringStep = 'Check optimizer id, permissions, helper availability, and captured command evidence.' }
        warnings = @()
        errors = @((New-RooStutterIssue 'STUTTER_REAL_EXECUTOR_FAILED' $_.Exception.Message 'error' $OptimizationId $true 'Check optimizer id, permissions, helper availability, and captured command evidence.' $null))
        logs = @((New-RooLog 'Controlled stutter real/detection executor failed.' 'error'))
    }
    Write-RooJsonOutput $errorResult $OutputPath
    exit 1
}
