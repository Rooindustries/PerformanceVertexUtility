$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.Common.ps1')
Set-RooIndustriesValidationNormalPriority

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $PSScriptRoot 'ResidentSessionHost.Common.ps1')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
    Write-Host "PASS $Message"
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "FAIL $Message"
}

function Test-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $RelativePath"
    } else {
        Add-Failure "Required file missing: $RelativePath"
    }
}

function Test-JsonFile {
    param([string]$Path)
    try {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json | Out-Null
        Add-Pass "JSON parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } catch {
        Add-Failure "JSON parse failed: $Path :: $($_.Exception.Message)"
    }
}

function Test-PowerShellParser {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) {
        Add-Pass "PowerShell parsed: $((Resolve-Path -LiteralPath $Path).Path.Substring($repoRoot.Path.Length + 1))"
    } else {
        Add-Failure "PowerShell parse failed: $Path :: $(($errors | ForEach-Object { $_.Message }) -join '; ')"
    }
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Get-FrontendProcessIds {
    $items = New-Object System.Collections.Generic.List[int]
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ([string]$proc.ProcessName -like 'RooIndustries.OptimizationSuite*' -or [string]$proc.ProcessName -like 'RooIndustriesOptimizationSuite*') {
            $items.Add([int]$proc.Id) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Get-ExternalProcessLassoIds {
    $items = New-Object System.Collections.Generic.List[int]
    foreach ($proc in @(Get-Process -Name 'ProcessLasso' -ErrorAction SilentlyContinue)) {
        $items.Add([int]$proc.Id) | Out-Null
    }
    return @($items.ToArray())
}

function Get-BackendScriptHostProcesses {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $commandLine = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }
        if ([int]$proc.ProcessId -eq $PID) { continue }
        if ($commandLine -like '*LeanClientOptimizer*backend*scripts*' -or $commandLine -like '*PerformanceVertexUtility*backend*scripts*') {
            $items.Add([pscustomobject]@{
                processId = [int]$proc.ProcessId
                name = [string]$proc.Name
            }) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Get-NewIds {
    param(
        [int[]]$Before,
        [int[]]$After
    )
    $beforeSet = @{}
    foreach ($id in @(Get-RooIndustriesArray $Before)) { $beforeSet[[int]$id] = $true }
    return @(@(Get-RooIndustriesArray $After) | Where-Object { -not $beforeSet.ContainsKey([int]$_) })
}

function Stop-ValidationProbe {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try { $Process.Refresh() } catch { }
    if (-not $Process.HasExited) {
        Stop-RooIndustriesValidationProcess $Process
    }
}

function Remove-TempRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $full = [System.IO.Path]::GetFullPath($Path)
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $full.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove non-temp native governor root: $full"
    }
    if (-not (Test-Path -LiteralPath $full)) { return $true }
    Remove-Item -LiteralPath $full -Recurse -Force
    return (-not (Test-Path -LiteralPath $full))
}

function Write-NativeGovernorPolicy {
    param(
        [string]$Path,
        [string[]]$CandidateNames,
        [string]$ProtectedName = '',
        [bool]$ConfirmApply = $false,
        [bool]$AllowLiveApply = $false,
        [int]$ForegroundProcessId = 0,
        [string]$StateRoot = '',
        [int]$MaxDurationSeconds = 1,
        [int]$PollIntervalMilliseconds = 500,
        [int64]$AffinityMask = 1,
        [string]$IoPriority = 'Low',
        [string]$GpuPriority = '',
        [string[]]$DisposableNamePatterns = @('RooIndustriesNativeGovernor*Probe.exe')
    )
    $protected = @()
    if (-not [string]::IsNullOrWhiteSpace($ProtectedName)) {
        $protected = @(
            [pscustomobject]@{
                itemId = 'native-validation-protected-probe'
                names = @($ProtectedName)
                reason = 'Disposable protected validation probe is excluded from native governor restraint.'
                reasonCodes = @('NATIVE_VALIDATION_PROTECTED_PROBE')
            }
        )
    }
    $policy = [pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        policyId = 'native-governor-validation'
        confirmApply = $ConfirmApply
        session = [pscustomobject]@{
            maxDurationSeconds = $MaxDurationSeconds
            pollIntervalMilliseconds = $PollIntervalMilliseconds
            foregroundProcessId = $ForegroundProcessId
            stateRoot = $StateRoot
            restoreOnExit = $true
        }
        safety = [pscustomobject]@{
            allowLiveApply = $AllowLiveApply
            requireDisposableTargets = $true
            protectForegroundProcess = $true
            protectGameObsDiscord = $true
            disposableNamePatterns = @($DisposableNamePatterns)
        }
        restraint = [pscustomobject]@{
            priorityClass = 'BelowNormal'
            affinityMask = $AffinityMask
            ioPriority = $IoPriority
            gpuPriority = $GpuPriority
        }
        protectedProcesses = @($protected)
        candidateSelectors = @(
            [pscustomobject]@{
                ruleId = 'native-validation-probes'
                enabled = $true
                match = [pscustomobject]@{
                    processNames = @($CandidateNames)
                }
                reason = 'Disposable validation probe matched native governor candidate selector.'
                reasonCodes = @('NATIVE_VALIDATION_GOVERNOR_CANDIDATE')
            }
        )
    }
    ($policy | ConvertTo-Json -Depth 24) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$requiredFiles = @(
    'backend\native\ProcessGovernor\RooIndustriesProcessGovernor.cs',
    'backend\scripts\Get-NativeProcessGovernorToolchain.ps1',
    'backend\scripts\Build-NativeProcessGovernor.ps1',
    'backend\scripts\Start-NativeProcessGovernorSession.ps1'
)
foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

foreach ($root in @(
    (Join-Path $repoRoot 'backend\contracts'),
    (Join-Path $repoRoot 'backend\samples'),
    (Join-Path $repoRoot 'backend\profiles'),
    (Join-Path $repoRoot 'backend\catalogs'),
    (Join-Path $repoRoot 'modules')
)) {
    if (Test-Path -LiteralPath $root) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File) {
            Test-JsonFile $file.FullName
        }
    }
}

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'backend\scripts') -Filter '*.ps1' -File) {
    Test-PowerShellParser $file.FullName
}

try {
    $toolchain = & (Join-Path $PSScriptRoot 'Get-NativeProcessGovernorToolchain.ps1') | ConvertFrom-Json
    $expectedDotnet = $env:ROO_INDUSTRIES_DOTNET_EXE
    if ([string]::IsNullOrWhiteSpace($expectedDotnet)) { $expectedDotnet = (Get-Command dotnet.exe -ErrorAction Stop).Source }
    $actualVersions = @(& $expectedDotnet --list-sdks | ForEach-Object { if ($_ -match '^([0-9]+\.[0-9]+\.[0-9]+)') { $Matches[1] } })
    $candidate = @($toolchain.dotnetCandidates | Where-Object { [string]$_.path -eq $expectedDotnet }) | Select-Object -First 1
    if ($candidate -and $candidate.exists -and $candidate.hasSdks -and @($actualVersions | Where-Object { $_ -notin $candidate.sdkVersions }).Count -eq 0) {
        Add-Pass 'Toolchain probe discovers the configured SDK and reports independently measured versions'
    } else { Add-Failure "Toolchain probe missed the configured SDK: $expectedDotnet" }
    $expectedHighest = @($toolchain.dotnetCandidates | Where-Object { $_.hasSdks } | ForEach-Object { $_.sdkVersions } | Sort-Object { [version]$_ } -Descending)[0]
    if ($toolchain.dotnetSdkAvailable -and $toolchain.selectedDotnetSdkHost.highestSdkVersion -eq $expectedHighest) {
        Add-Pass 'Toolchain probe selects the highest installed SDK deterministically'
    } else { Add-Failure 'Toolchain probe did not select the highest installed SDK' }
    if ($toolchain.cscFrameworkCompilerAvailable -eq $true -and $toolchain.workerClassification -eq 'managed-csc' -and $toolchain.workerIsTrueNative -eq $false -and $toolchain.selectedApproach -eq 'managed-csc-fallback') {
        Add-Pass "Toolchain probe kept managed csc fallback; C++ Win32=$($toolchain.cxxWin32Available), NativeAOT=$($toolchain.dotnetNativeAotAvailable), worker=$($toolchain.workerClassification)"
    } else {
        Add-Failure "Toolchain probe had unexpected worker classification: approach=$($toolchain.selectedApproach), worker=$($toolchain.workerClassification), trueNative=$($toolchain.workerIsTrueNative), NativeAOT=$($toolchain.dotnetNativeAotAvailable), csc=$($toolchain.cscFrameworkCompilerAvailable)"
    }
} catch {
    Add-Failure "Native governor toolchain probe failed: $($_.Exception.Message)"
}

$stateBefore = Get-StateEntryCount
$frontendBefore = @(Get-FrontendProcessIds)
$processLassoBefore = @(Get-ExternalProcessLassoIds)
$backendHostsBefore = @(Get-BackendScriptHostProcesses)
$previousManagedCscBaseline = [pscustomobject]@{
    elapsedRuntimeSeconds = 4.094
    cpuTimeDeltaSeconds = 0.4375
    averageCpuPercent = 0.6679
    workingSetBytes = 35971072
    privateBytes = 29257728
    handleCount = 286
    processCountBefore = 289
    processCountAfter = 281
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-native-governor-runtime-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
$probes = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $workerPath = Join-Path $tempRoot 'RooIndustriesProcessGovernor.exe'
    $build = & (Join-Path $PSScriptRoot 'Build-NativeProcessGovernor.ps1') -OutputPath $workerPath -Force | ConvertFrom-Json
    if ($build.status -eq 'built' -and $build.workerClassification -eq 'managed-csc' -and $build.workerIsTrueNative -eq $false -and (Test-Path -LiteralPath $workerPath)) {
        Add-Pass "Managed csc process governor worker built with $($build.toolchain): $workerPath"
    } else {
        Add-Failure "Managed csc process governor worker did not build with expected classification: status=$($build.status), worker=$($build.workerClassification), trueNative=$($build.workerIsTrueNative)"
    }

    $busyName = 'RooIndustriesNativeGovernorBusyProbe.exe'
    $protectedName = 'RooIndustriesNativeGovernorProtectedProbe.exe'
    $obsName = 'RooIndustriesNativeGovernorObsProbe.exe'
    $discordName = 'RooIndustriesNativeGovernorDiscordProbe.exe'
    $gameName = 'RooIndustriesNativeGovernorOverwatchProbe.exe'
    $antiCheatName = 'RooIndustriesNativeGovernorEasyAntiCheatProbe.exe'
    $networkName = 'RooIndustriesNativeGovernorTailscaleProbe.exe'
    $audioName = 'RooIndustriesNativeGovernorAudiodgProbe.exe'
    $inputName = 'RooIndustriesNativeGovernorInputAppProbe.exe'
    $securityName = 'RooIndustriesNativeGovernorSecurityHealthProbe.exe'
    $gpuDriverName = 'RooIndustriesNativeGovernorNvcontainerProbe.exe'
    $regularName = 'NativeGovernorRegularTarget.exe'
    $launchName = 'RooIndustriesNativeGovernorLaunchProbe.exe'
    $probeNames = @($busyName, $protectedName, $obsName, $discordName, $gameName, $antiCheatName, $networkName, $audioName, $inputName, $securityName, $gpuDriverName, $regularName, $launchName)
    foreach ($name in $probeNames) {
        Copy-Item -LiteralPath $workerPath -Destination (Join-Path $tempRoot $name) -Force
    }

    $busyProbe = Start-Process -FilePath (Join-Path $tempRoot $busyName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','busy-then-sleep','8','120')) -WindowStyle Hidden -PassThru
    $protectedProbe = Start-Process -FilePath (Join-Path $tempRoot $protectedName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $obsProbe = Start-Process -FilePath (Join-Path $tempRoot $obsName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $discordProbe = Start-Process -FilePath (Join-Path $tempRoot $discordName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $gameProbe = Start-Process -FilePath (Join-Path $tempRoot $gameName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $antiCheatProbe = Start-Process -FilePath (Join-Path $tempRoot $antiCheatName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $networkProbe = Start-Process -FilePath (Join-Path $tempRoot $networkName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $audioProbe = Start-Process -FilePath (Join-Path $tempRoot $audioName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $inputProbe = Start-Process -FilePath (Join-Path $tempRoot $inputName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $securityProbe = Start-Process -FilePath (Join-Path $tempRoot $securityName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $gpuDriverProbe = Start-Process -FilePath (Join-Path $tempRoot $gpuDriverName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    foreach ($probe in @($busyProbe, $protectedProbe, $obsProbe, $discordProbe, $gameProbe, $antiCheatProbe, $networkProbe, $audioProbe, $inputProbe, $securityProbe, $gpuDriverProbe)) { $probes.Add($probe) | Out-Null }
    Start-Sleep -Milliseconds 800

    $beforeBusy = Get-RooIndustriesProcessControlState $busyProbe.Id $null -ReadGpu
    $beforeProtected = Get-RooIndustriesProcessControlState $protectedProbe.Id $null
    $affinityTarget = if ([Environment]::ProcessorCount -gt 1) { [int64]1 } else { [int64]$beforeBusy.affinityMask }
    $gpuTarget = if ([string]$beforeBusy.gpuPriority -eq 'BelowNormal') { 'Normal' } else { 'BelowNormal' }
    if ([bool](Get-RooIndustriesPropertyValue $beforeBusy 'gpuPriorityAvailable' $false)) {
        Add-Pass "Disposable busy probe GPU priority is readable for native validation: original=$($beforeBusy.gpuPriority), target=$gpuTarget, status=$($beforeBusy.gpuPriorityStatus)"
    } else {
        Add-Failure "Disposable busy probe GPU priority is not readable for native validation: status=$($beforeBusy.gpuPriorityStatus)"
    }

    $previewPolicy = Join-Path $tempRoot 'preview-policy.json'
    Write-NativeGovernorPolicy `
        -Path $previewPolicy `
        -CandidateNames @($busyName, $protectedName, $obsName, $discordName, $gameName, $antiCheatName, $networkName, $audioName, $inputName, $securityName, $gpuDriverName) `
        -ProtectedName $protectedName `
        -ConfirmApply:$false `
        -AllowLiveApply:$false `
        -ForegroundProcessId $protectedProbe.Id `
        -StateRoot (Join-Path $tempRoot 'preview-state') `
        -AffinityMask $affinityTarget `
        -GpuPriority $gpuTarget

    $preview = & (Join-Path $PSScriptRoot 'Start-NativeProcessGovernorSession.ps1') -PolicyPath $previewPolicy -WorkerPath $workerPath | ConvertFrom-Json
    $afterPreviewBusy = Get-RooIndustriesProcessControlState $busyProbe.Id $null -ReadGpu
    $previewBusy = @($preview.preview | Where-Object { $_.processId -eq $busyProbe.Id }) | Select-Object -First 1
    $previewProtected = @($preview.preview | Where-Object { $_.processId -eq $protectedProbe.Id }) | Select-Object -First 1
    $previewObs = @($preview.preview | Where-Object { $_.processId -eq $obsProbe.Id }) | Select-Object -First 1
    $previewDiscord = @($preview.preview | Where-Object { $_.processId -eq $discordProbe.Id }) | Select-Object -First 1
    $previewGame = @($preview.preview | Where-Object { $_.processId -eq $gameProbe.Id }) | Select-Object -First 1
    $previewProtectedCategories = @(
        @($preview.preview | Where-Object { $_.processId -eq $antiCheatProbe.Id }) | Select-Object -First 1
        @($preview.preview | Where-Object { $_.processId -eq $networkProbe.Id }) | Select-Object -First 1
        @($preview.preview | Where-Object { $_.processId -eq $audioProbe.Id }) | Select-Object -First 1
        @($preview.preview | Where-Object { $_.processId -eq $inputProbe.Id }) | Select-Object -First 1
        @($preview.preview | Where-Object { $_.processId -eq $securityProbe.Id }) | Select-Object -First 1
        @($preview.preview | Where-Object { $_.processId -eq $gpuDriverProbe.Id }) | Select-Object -First 1
    )
    $previewBusyControls = @($previewBusy.controlChanges | ForEach-Object { $_.control })

    if ($preview.dryRun -eq $true -and $null -eq $preview.sessionPath -and $previewBusy.requiresConfirmation -eq $true -and $previewBusyControls -contains 'priorityClass' -and $previewBusyControls -contains 'affinityMask' -and $previewBusyControls -contains 'ioPriority' -and $previewBusyControls -contains 'gpuPriority' -and $afterPreviewBusy.priorityClass -eq $beforeBusy.priorityClass) {
        Add-Pass "Native dry-run preview proposed disposable busy-probe priority, affinity, I/O, and GPU controls without applying: priority=$($afterPreviewBusy.priorityClass)"
    } else {
        Add-Failure 'Native dry-run preview did not prove no-apply behavior or did not propose all native controls for disposable busy probe'
    }
    if ($previewProtected.blocked -eq $true -and ($previewProtected.reasonCodes -contains 'NATIVE_VALIDATION_PROTECTED_PROBE') -and ($previewProtected.reasonCodes -contains 'FOREGROUND_PROCESS_EXCLUDED') -and $beforeProtected.priorityClass -eq (Get-RooIndustriesProcessControlState $protectedProbe.Id $null).priorityClass) {
        Add-Pass "Native manual-review foreground probe skipped with reason codes: $($previewProtected.reasonCodes -join ',')"
    } else {
        Add-Failure 'Native manual-review foreground probe was not skipped with review and foreground proof'
    }
    if ($previewObs.blocked -eq $true -and ($previewObs.reasonCodes -contains 'GAME_OBS_DISCORD_PROTECTED') -and $previewDiscord.blocked -eq $true -and ($previewDiscord.reasonCodes -contains 'GAME_OBS_DISCORD_PROTECTED') -and $previewGame.blocked -eq $true -and ($previewGame.reasonCodes -contains 'GAME_OBS_DISCORD_PROTECTED')) {
        Add-Pass 'Managed csc worker left OBS, Discord, and foreground-game category probes alone'
    } else {
        Add-Failure 'Managed csc worker did not protect OBS, Discord, and foreground-game category probes'
    }
    $protectedCategorySkipCount = @($previewProtectedCategories | Where-Object { $_.blocked -eq $true -and ($_.reasonCodes -contains 'PROTECTED_CATEGORY') }).Count
    if ($protectedCategorySkipCount -eq 6) {
        Add-Pass 'Managed csc worker protected anti-cheat, network, audio, input, security, and GPU-driver category probes'
    } else {
        Add-Failure "Managed csc worker did not protect all extended protected category probes: protected=$protectedCategorySkipCount of 6"
    }
    $nativeControls = @($preview.engineCapabilities.nativeWorkerControls | ForEach-Object { [string]$_.control })
    $fallbackControls = @($preview.engineCapabilities.powerShellFallbackControls | ForEach-Object { [string]$_.control })
    $unsupportedGpu = @($preview.engineCapabilities.unsupportedControls | Where-Object { [string]$_.control -eq 'gpuPriority' -and [string]$_.status -eq 'fallback-only' }) | Select-Object -First 1
    $nativeGpuCapability = @($preview.engineCapabilities.nativeWorkerControls | Where-Object { [string]$_.control -eq 'gpuPriority' -and $_.applySupported -eq $true -and $_.restoreSupported -eq $true }) | Select-Object -First 1
    if ($nativeControls -contains 'priorityClass' -and $nativeControls -contains 'affinityMask' -and $nativeControls -contains 'ioPriority' -and $nativeControls -contains 'gpuPriority' -and $fallbackControls -contains 'gpuPriority' -and $nativeGpuCapability -and -not $unsupportedGpu -and $preview.engineCapabilities.trueNativeStatus.workerIsTrueNative -eq $false -and $preview.engineCapabilities.processLassoDependencyStatus.processLassoRequired -eq $false) {
        Add-Pass 'Native engine capability report marks GPU priority native-worker-supported while keeping PowerShell fallback and Process Lasso dependency status clear'
    } else {
        Add-Failure 'Native engine capability report did not expose expected control/fallback/dependency statuses'
    }

    $confirmPolicy = Join-Path $tempRoot 'confirm-policy.json'
    $stateRoot = Join-Path $tempRoot 'native-state'
    Write-NativeGovernorPolicy `
        -Path $confirmPolicy `
        -CandidateNames @($busyName) `
        -ConfirmApply:$true `
        -AllowLiveApply:$true `
        -StateRoot $stateRoot `
        -MaxDurationSeconds 2 `
        -PollIntervalMilliseconds 500 `
        -AffinityMask $affinityTarget `
        -GpuPriority $gpuTarget

    $session = & (Join-Path $PSScriptRoot 'Start-NativeProcessGovernorSession.ps1') -PolicyPath $confirmPolicy -WorkerPath $workerPath | ConvertFrom-Json
    $afterSessionBusy = Get-RooIndustriesProcessControlState $busyProbe.Id $null -ReadGpu
    $changedBusy = @($session.changedItems | Where-Object { $_.processId -eq $busyProbe.Id }) | Select-Object -First 1
    $restoredBusy = @($session.restoredItems | Where-Object { $_.processId -eq $busyProbe.Id }) | Select-Object -First 1
    $affinityRestored = ([int64]$afterSessionBusy.affinityMask -eq [int64]$beforeBusy.affinityMask)
    $ioExpected = ([bool](Get-RooIndustriesPropertyValue $beforeBusy 'ioPriorityAvailable' $false) -and [string]$beforeBusy.ioPriority -ne 'Low')
    $ioApplied = if ($ioExpected) { [string]$changedBusy.appliedIoPriority -eq 'Low' } else { $true }
    $ioRestored = if ($ioExpected) { [string]$afterSessionBusy.ioPriority -eq [string]$beforeBusy.ioPriority } else { $true }
    $gpuApplied = ([string]$changedBusy.appliedGpuPriority -eq [string]$gpuTarget)
    $gpuRestored = ([string]$afterSessionBusy.gpuPriority -eq [string]$beforeBusy.gpuPriority)
    if ($session.dryRun -eq $false -and $changedBusy -and $restoredBusy -and $changedBusy.appliedPriorityClass -eq 'BelowNormal' -and $afterSessionBusy.priorityClass -eq $beforeBusy.priorityClass -and $affinityRestored -and $ioApplied -and $ioRestored -and $gpuApplied -and $gpuRestored) {
        Add-Pass "Native confirmed apply/restore changed disposable probe then restored priority/affinity/I/O/GPU: appliedPriority=$($changedBusy.appliedPriorityClass), appliedAffinity=$($changedBusy.appliedAffinityMask), appliedIo=$($changedBusy.appliedIoPriority), appliedGpu=$($changedBusy.appliedGpuPriority)"
    } else {
        Add-Failure "Native confirmed apply/restore failed: changed=$([bool]$changedBusy), restored=$([bool]$restoredBusy), priority=$($afterSessionBusy.priorityClass)/$($beforeBusy.priorityClass), affinity=$($afterSessionBusy.affinityMask)/$($beforeBusy.affinityMask), io=$($afterSessionBusy.ioPriority)/$($beforeBusy.ioPriority), gpu=$($afterSessionBusy.gpuPriority)/$($beforeBusy.gpuPriority), gpuTarget=$gpuTarget"
    }
    $busyChangeCount = @($session.changedItems | Where-Object { $_.processId -eq $busyProbe.Id }).Count
    if ($busyChangeCount -eq 1 -and $session.residentPolicy.duplicateApplySuppressedCount -ge 0) {
        Add-Pass "Native resident policy avoided duplicate apply spam for already-controlled probe: changeCount=$busyChangeCount duplicateSuppressed=$($session.residentPolicy.duplicateApplySuppressedCount)"
    } else {
        Add-Failure "Native resident policy repeatedly applied the same probe: changeCount=$busyChangeCount duplicateSuppressed=$($session.residentPolicy.duplicateApplySuppressedCount)"
    }
    if ($session.sessionPath -like "$([System.IO.Path]::GetFullPath($stateRoot))*" -and (Test-Path -LiteralPath $session.sessionPath) -and (Test-Path -LiteralPath $session.backupManifestPath)) {
        Add-Pass 'Native confirmed session wrote session state and backup under the disposable temp state root'
    } else {
        Add-Failure 'Native confirmed session did not write session state and backup under the temp state root'
    }

    $regularProbe = Start-Process -FilePath (Join-Path $tempRoot $regularName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $probes.Add($regularProbe) | Out-Null
    Start-Sleep -Milliseconds 500
    $beforeRegular = Get-RooIndustriesProcessControlState $regularProbe.Id $null
    $blockedPolicy = Join-Path $tempRoot 'blocked-policy.json'
    Write-NativeGovernorPolicy `
        -Path $blockedPolicy `
        -CandidateNames @($regularName) `
        -ConfirmApply:$true `
        -AllowLiveApply:$true `
        -StateRoot (Join-Path $tempRoot 'blocked-state') `
        -MaxDurationSeconds 1 `
        -DisposableNamePatterns @('RooIndustriesNativeGovernor*Probe.exe') `
        -AffinityMask $affinityTarget
    $blocked = & (Join-Path $PSScriptRoot 'Start-NativeProcessGovernorSession.ps1') -PolicyPath $blockedPolicy -WorkerPath $workerPath | ConvertFrom-Json
    $afterRegular = Get-RooIndustriesProcessControlState $regularProbe.Id $null
    $blockedRegular = @($blocked.skippedItems | Where-Object { $_.processId -eq $regularProbe.Id -and ($_.reasonCodes -contains 'NON_DISPOSABLE_TARGET') }) | Select-Object -First 1
    if ($blockedRegular -and @($blocked.changedItems).Count -eq 0 -and $afterRegular.priorityClass -eq $beforeRegular.priorityClass) {
        Add-Pass 'Native confirmed apply refused a non-disposable validation target'
    } else {
        Add-Failure 'Native confirmed apply did not refuse the non-disposable validation target'
    }

    $launchPolicy = Join-Path $tempRoot 'launch-policy.json'
    $launchOutput = Join-Path $tempRoot 'launch-session-output.json'
    Write-NativeGovernorPolicy `
        -Path $launchPolicy `
        -CandidateNames @($launchName) `
        -ConfirmApply:$true `
        -AllowLiveApply:$true `
        -StateRoot (Join-Path $tempRoot 'launch-state') `
        -MaxDurationSeconds 5 `
        -PollIntervalMilliseconds 500 `
        -AffinityMask $affinityTarget
    $launchSessionProc = Start-Process -FilePath $workerPath -ArgumentList (Join-RooIndustriesWindowsArguments @('--policy', $launchPolicy, '--output', $launchOutput)) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1200
    $launchProbe = Start-Process -FilePath (Join-Path $tempRoot $launchName) -ArgumentList (Join-RooIndustriesWindowsArguments @('--probe','sleep','0','120')) -WindowStyle Hidden -PassThru
    $probes.Add($launchProbe) | Out-Null
    Wait-RooIndustriesValidationProcess $launchSessionProc 15
    $launchSessionProc.Refresh()
    $launchSessionExit = $launchSessionProc.ExitCode
    $launchSession = Get-Content -LiteralPath $launchOutput -Raw | ConvertFrom-Json
    $launchChanged = @($launchSession.changedItems | Where-Object { $_.processId -eq $launchProbe.Id }) | Select-Object -First 1
    $launchRestored = @($launchSession.restoredItems | Where-Object { $_.processId -eq $launchProbe.Id }) | Select-Object -First 1
    if ($launchSessionExit -eq 0 -and $launchChanged -and $launchRestored -and [string]$launchChanged.appliedPriorityClass -eq 'BelowNormal' -and [string]$launchChanged.detectionKind -eq 'newlySpawnedDuringSession' -and $launchSession.residentPolicy.launchWatcherEnabled -eq $true -and $launchSession.residentPolicy.newlyDetectedProcessCount -ge 1) {
        Add-Pass "Native launch watcher applied and restored policy to newly spawned disposable probe: pid=$($launchProbe.Id) detection=$($launchChanged.detectionKind) newCount=$($launchSession.residentPolicy.newlyDetectedProcessCount)"
    } else {
        Add-Failure "Native launch watcher did not apply to newly spawned disposable probe: exit=$launchSessionExit changed=$([bool]$launchChanged) restored=$([bool]$launchRestored) detection=$($launchChanged.detectionKind) newCount=$($launchSession.residentPolicy.newlyDetectedProcessCount)"
    }

    $measurePolicy = Join-Path $tempRoot 'measure-policy.json'
    Write-NativeGovernorPolicy `
        -Path $measurePolicy `
        -CandidateNames @('NoSuchNativeGovernorProbe.exe') `
        -ConfirmApply:$false `
        -AllowLiveApply:$false `
        -StateRoot (Join-Path $tempRoot 'measure-state') `
        -MaxDurationSeconds 4 `
        -PollIntervalMilliseconds 1000 `
        -AffinityMask $affinityTarget
    $nativeMeasure = & (Join-Path $PSScriptRoot 'Start-NativeProcessGovernorSession.ps1') -PolicyPath $measurePolicy -WorkerPath $workerPath | ConvertFrom-Json
    if ($nativeMeasure.footprint.privateBytes -gt 0 -and $nativeMeasure.footprint.workingSetBytes -gt 0 -and $nativeMeasure.footprint.cpuTimeDeltaSeconds -ge 0 -and $nativeMeasure.footprint.averageCpuPercent -ge 0 -and $nativeMeasure.footprint.handleCount -ge 0 -and $nativeMeasure.footprint.processCount.after -gt 0 -and $nativeMeasure.footprint.elapsedRuntimeSeconds -gt 0) {
        Add-Pass "Managed csc worker footprint measured private=$($nativeMeasure.footprint.privateBytes), workingSet=$($nativeMeasure.footprint.workingSetBytes), cpuDelta=$($nativeMeasure.footprint.cpuTimeDeltaSeconds), avgCpu=$($nativeMeasure.footprint.averageCpuPercent), handles=$($nativeMeasure.footprint.handleCount), processCount=$($nativeMeasure.footprint.processCount.after), elapsed=$($nativeMeasure.footprint.elapsedRuntimeSeconds)"
    } else {
        Add-Failure 'Managed csc worker footprint did not include the required measurement fields'
    }
    if ($nativeMeasure.fullEnumerationPollCount -eq 0 -and $nativeMeasure.targetedEnumerationPollCount -ge 1 -and $nativeMeasure.engineCapabilities.scanStrategy.avoidsFullEnumerationWhenExactProcessNamesAreAvailable -eq $true) {
        Add-Pass "Managed csc worker used targeted process-name enumeration for exact-name policy: targetedPolls=$($nativeMeasure.targetedEnumerationPollCount) fullPolls=$($nativeMeasure.fullEnumerationPollCount)"
    } else {
        Add-Failure "Managed csc worker did not prove targeted enumeration for exact-name policy: targetedPolls=$($nativeMeasure.targetedEnumerationPollCount) fullPolls=$($nativeMeasure.fullEnumerationPollCount)"
    }
    $cscCpuRate = [math]::Round([double]$nativeMeasure.footprint.cpuTimeDeltaSeconds / [double]$nativeMeasure.footprint.elapsedRuntimeSeconds, 4)
    $baselineCpuRate = [math]::Round([double]$previousManagedCscBaseline.cpuTimeDeltaSeconds / [double]$previousManagedCscBaseline.elapsedRuntimeSeconds, 4)
    if ($cscCpuRate -le $baselineCpuRate -and [double]$nativeMeasure.footprint.cpuTimeDeltaSeconds -le [double]$previousManagedCscBaseline.cpuTimeDeltaSeconds) {
        Add-Pass "Managed csc worker CPU overhead improved versus previous baseline: CPU seconds per second $cscCpuRate <= $baselineCpuRate, cpuDelta $($nativeMeasure.footprint.cpuTimeDeltaSeconds) <= $($previousManagedCscBaseline.cpuTimeDeltaSeconds)"
    } else {
        Add-Failure "Managed csc worker CPU overhead regressed versus previous baseline: CPU seconds per second $cscCpuRate > $baselineCpuRate or cpuDelta $($nativeMeasure.footprint.cpuTimeDeltaSeconds) > $($previousManagedCscBaseline.cpuTimeDeltaSeconds)"
    }

    $residentOut = Join-Path $tempRoot 'powershell-resident-output.json'
    $residentErr = Join-Path $tempRoot 'powershell-resident-error.txt'
    $residentArgs = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'Start-RooIndustriesResidentSessionHost.ps1'),
        '-MaxDurationSeconds',
        '4',
        '-PollIntervalMilliseconds',
        '1000',
        '-BudgetProfilePath',
        (Join-Path $repoRoot 'backend\profiles\lightweight-governor-budget.profile.json')
    )
    $residentProc = Start-Process -FilePath 'powershell.exe' -ArgumentList (Join-RooIndustriesWindowsArguments $residentArgs) -WindowStyle Hidden -RedirectStandardOutput $residentOut -RedirectStandardError $residentErr -Wait -PassThru
    $resident = Get-Content -LiteralPath $residentOut -Raw | ConvertFrom-Json
    if ($residentProc.ExitCode -eq 0 -and $resident.actionId -eq 'backend.residentHost.start' -and $resident.footprint.privateBytes -gt 0 -and $resident.footprint.workingSetBytes -gt 0 -and $resident.footprint.cpuTimeDeltaSeconds -ge 0 -and $resident.footprint.averageCpuPercent -ge 0 -and $resident.footprint.handleCount -ge 0 -and $resident.footprint.processCount.after -gt 0 -and $resident.footprint.elapsedRuntimeSeconds -gt 0) {
        Add-Pass "PowerShell resident host footprint measured private=$($resident.footprint.privateBytes), workingSet=$($resident.footprint.workingSetBytes), cpuDelta=$($resident.footprint.cpuTimeDeltaSeconds), avgCpu=$($resident.footprint.averageCpuPercent), handles=$($resident.footprint.handleCount), processCount=$($resident.footprint.processCount.after), elapsed=$($resident.footprint.elapsedRuntimeSeconds)"
    } else {
        $errText = if (Test-Path -LiteralPath $residentErr) { Get-Content -LiteralPath $residentErr -Raw } else { '' }
        Add-Failure "PowerShell resident host footprint comparison failed: exit=$($residentProc.ExitCode) $errText"
    }
    if ($nativeMeasure.footprint.privateBytes -lt $resident.footprint.privateBytes -and $nativeMeasure.footprint.workingSetBytes -lt $resident.footprint.workingSetBytes) {
        Add-Pass "Managed csc worker memory footprint is lower than PowerShell resident host: private $($nativeMeasure.footprint.privateBytes) < $($resident.footprint.privateBytes), workingSet $($nativeMeasure.footprint.workingSetBytes) < $($resident.footprint.workingSetBytes)"
    } else {
        Add-Failure "Managed csc worker memory footprint was not lower than PowerShell resident host: csc private=$($nativeMeasure.footprint.privateBytes), ps private=$($resident.footprint.privateBytes), csc ws=$($nativeMeasure.footprint.workingSetBytes), ps ws=$($resident.footprint.workingSetBytes)"
    }

    foreach ($probe in @($probes.ToArray())) {
        Stop-ValidationProbe $probe
    }
    $probes.Clear()
    Start-Sleep -Milliseconds 500
    $leftoverProbeNames = @($probeNames | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) })
    $leftovers = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $leftoverProbeNames -contains [string]$_.ProcessName })
    if ($leftovers.Count -eq 0) {
        Add-Pass 'Native validation left no disposable probe processes behind'
    } else {
        Add-Failure "Native validation left disposable probe process(es): $(@($leftovers | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', ')"
    }

    $cleanupDone = Remove-TempRoot $tempRoot
    if ($cleanupDone) {
        Add-Pass 'Native validation temp worker, policies, and temp state were cleaned up'
    } else {
        Add-Failure "Native validation temp root remained: $tempRoot"
    }
} catch {
    Add-Failure "Native process governor validation failed: $($_.Exception.Message)"
} finally {
    foreach ($probe in @($probes.ToArray())) {
        Stop-ValidationProbe $probe
    }
    if (-not $cleanupDone) {
        try { Remove-TempRoot $tempRoot | Out-Null } catch { }
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after native process governor validation'
} else {
    Add-Failure "backend/state is not empty or changed during native validation: before=$stateBefore after=$stateAfter"
}

$frontendAfter = @(Get-FrontendProcessIds)
$newFrontendIds = @(Get-NewIds $frontendBefore $frontendAfter)
if ($newFrontendIds.Count -eq 0) {
    Add-Pass 'Native process governor validation launched no frontend process'
} else {
    Add-Failure "Native process governor validation launched frontend process id(s): $($newFrontendIds -join ', ')"
}

$processLassoAfter = @(Get-ExternalProcessLassoIds)
$newProcessLassoIds = @(Get-NewIds $processLassoBefore $processLassoAfter)
if ($newProcessLassoIds.Count -eq 0) {
    Add-Pass 'Native process governor validation launched no Process Lasso process'
} else {
    Add-Failure "Native process governor validation launched Process Lasso process id(s): $($newProcessLassoIds -join ', ')"
}

$backendHostsAfter = @(Get-BackendScriptHostProcesses)
$backendHostBeforeIds = @($backendHostsBefore | ForEach-Object { [int]$_.processId })
$backendHostAfterIds = @($backendHostsAfter | ForEach-Object { [int]$_.processId })
$newBackendHostIds = @(Get-NewIds $backendHostBeforeIds $backendHostAfterIds)
if ($newBackendHostIds.Count -eq 0) {
    Add-Pass 'Native process governor validation left no backend script host process behind'
} else {
    Add-Failure "Native process governor validation left backend script host process id(s): $($newBackendHostIds -join ', ')"
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Native process governor runtime validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Native process governor runtime validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
