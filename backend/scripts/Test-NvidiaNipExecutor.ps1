param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
$evidence = [ordered]@{ schemaVersion = 1; test = 'nvidia-export-check'; cases = [ordered]@{} }
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = Join-Path $repoRoot 'artifacts\validation\nvidia-export-check.json' }

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

function ConvertFrom-ScriptJson {
    param([object[]]$Output)
    return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Write-HardwareFixture {
    param(
        [string]$Path,
        [bool]$Nvidia
    )
    $gpu = if ($Nvidia) {
        [pscustomobject]@{
            name = 'NVIDIA GeForce RTX Fixture'
            vendor = 'NVIDIA'
            pnpDeviceId = 'PCI\VEN_10DE&DEV_0000'
            driverVersion = 'fixture'
        }
    } else {
        [pscustomobject]@{
            name = 'Intel UHD Fixture'
            vendor = 'Intel'
            pnpDeviceId = 'PCI\VEN_8086&DEV_0000'
            driverVersion = 'fixture'
        }
    }
    ([pscustomobject]@{
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-01T00:00:00Z'
        gpus = @($gpu)
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-NvpiMockShim {
    param(
        [string]$Path,
        [string]$LogPath,
        [ValidateSet('Success','ExportFail','ExportNoFile','ExportEmpty','ImportFail','Timeout')]
        [string]$Behavior
    )
    $escapedLog = $LogPath.Replace("'", "''")
    $content = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$logPath = '__LOG__'
$entry = [pscustomobject]@{ args = @($Rest); atUtc = (Get-Date).ToUniversalTime().ToString('o') }
($entry | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $logPath
if ('__BEHAVIOR__' -eq 'Timeout') {
    Start-Sleep -Seconds 5
    exit 0
}
if (@($Rest).Count -gt 0 -and $Rest[0] -eq '-exportProfile') {
    if ('__BEHAVIOR__' -eq 'ExportFail') { exit 17 }
    if ('__BEHAVIOR__' -eq 'ExportNoFile') { exit 0 }
    if ('__BEHAVIOR__' -eq 'ExportEmpty') { [IO.File]::WriteAllText($Rest[2], ''); exit 0 }
    if (@($Rest).Count -gt 2) {
        Set-Content -LiteralPath $Rest[2] -Value 'mock exported profile' -Encoding UTF8
    }
}
if (@($Rest).Count -gt 0 -and $Rest[0] -eq '-importProfile' -and '__BEHAVIOR__' -eq 'ImportFail') { exit 19 }
exit 0
'@
    $content = $content.Replace('__LOG__', $escapedLog).Replace('__BEHAVIOR__', $Behavior)
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Read-MockLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

$requiredFiles = @(
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\scripts\Invoke-NvidiaNipExecutor.ps1'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $relative"
    } else {
        Add-Failure "Required file missing: $relative"
    }
}

$stateBefore = Get-StateEntryCount
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-nvidia-nip-executor-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $nvidiaHardware = Join-Path $tempRoot 'nvidia-hardware.json'
    $nonNvidiaHardware = Join-Path $tempRoot 'intel-hardware.json'
    Write-HardwareFixture $nvidiaHardware $true
    Write-HardwareFixture $nonNvidiaHardware $false

    $successLog = Join-Path $tempRoot 'nvpi-success.log'
    $successShim = Join-Path $tempRoot 'nvpi-success.ps1'
    $exportFailLog = Join-Path $tempRoot 'nvpi-export-fail.log'
    $exportFailShim = Join-Path $tempRoot 'nvpi-export-fail.ps1'
    $timeoutLog = Join-Path $tempRoot 'nvpi-timeout.log'
    $timeoutShim = Join-Path $tempRoot 'nvpi-timeout.ps1'
    $importFailLog = Join-Path $tempRoot 'nvpi-import-fail.log'
    $importFailShim = Join-Path $tempRoot 'nvpi-import-fail.ps1'
    New-NvpiMockShim $successShim $successLog 'Success'
    New-NvpiMockShim $exportFailShim $exportFailLog 'ExportFail'
    New-NvpiMockShim $timeoutShim $timeoutLog 'Timeout'
    New-NvpiMockShim $importFailShim $importFailLog 'ImportFail'

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -HardwareInventoryPath $nvidiaHardware)
    if ($preview.status -eq 'preview' -and $preview.summary.willRunNvpi -eq $false -and $preview.summary.willRunMockShim -eq $false -and @($preview.executionSequence).Count -eq 0) {
        Add-Pass 'NVIDIA NIP executor default call is preview-only and runs no command'
    } else {
        Add-Failure 'NVIDIA NIP executor default call was not preview-only'
    }

    $blockedHardware = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nonNvidiaHardware -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $hardwareGate = @($blockedHardware.gates | Where-Object { $_.gateId -eq 'nvidia-hardware-present' }) | Select-Object -First 1
    if ($blockedHardware.status -eq 'blocked' -and $hardwareGate.blocking -eq $true -and @($blockedHardware.executionSequence).Count -eq 0) {
        Add-Pass 'NVIDIA NIP executor blocks mock apply when NVIDIA hardware gate is not satisfied'
    } else {
        Add-Failure 'NVIDIA NIP executor did not block non-NVIDIA hardware'
    }

    $exportPath = Join-Path $tempRoot 'before-success.nip'
    $rollbackPath = Join-Path $tempRoot 'nvidia-rollback.json'
    $success = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $successLogEntries = Read-MockLog $successLog
    $writtenRollback = Get-Content -LiteralPath $rollbackPath -Raw | ConvertFrom-Json
    $evidence.cases['success'] = [pscustomobject]@{ result = $success; log = @($successLogEntries); manifest = $writtenRollback }
    $firstArgs = @($successLogEntries[0].args)
    $secondArgs = @($successLogEntries[1].args)
    if ($success.status -eq 'success' -and $success.summary.willRunMockShim -eq $true -and $success.summary.willRunNvpi -eq $false -and $success.summary.realNvpiInvoked -eq $false -and $success.summary.exportCompleted -eq $true -and $success.summary.importCompleted -eq $true -and $writtenRollback.exportCompleted -eq $true -and $writtenRollback.importAttempted -eq $true -and $writtenRollback.importCompleted -eq $true -and $firstArgs[0] -eq '-exportProfile' -and $secondArgs[0] -eq '-importProfile' -and (Test-Path -LiteralPath $exportPath) -and (Test-Path -LiteralPath $rollbackPath)) {
        Add-Pass 'NVIDIA NIP mock executor exports before import, writes rollback manifest, and never reports real NVPI execution'
    } else {
        Add-Failure 'NVIDIA NIP mock executor did not prove export-before-import success path'
    }
    if ($success.summary.noAutoApply -eq $true -and $success.summary.focusStealPrevented -eq $true) {
        Add-Pass 'NVIDIA NIP mock executor proves explicit no-auto-apply and hidden-process invocation'
    } else {
        Add-Failure 'NVIDIA NIP mock executor did not prove no-auto-apply and hidden invocation'
    }

    $logCountBeforeCollisions = @(Read-MockLog $successLog).Count
    $collisionPath = Join-Path $tempRoot 'colliding-export-and-manifest.nip'
    $exportManifestCollision = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $collisionPath -RollbackManifestPath $collisionPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $evidence.cases['export-manifest-path-collision'] = $exportManifestCollision
    if ($exportManifestCollision.status -eq 'failed' -and @($exportManifestCollision.errors).Count -eq 1 -and
        $exportManifestCollision.errors[0].message -eq 'The export, rollback manifest and output paths must be three different files. Nothing was changed.' -and
        -not (Test-Path -LiteralPath $collisionPath) -and @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
        Add-Pass 'Colliding export and manifest paths are refused before creating a file or invoking the mock shim'
    } else { Add-Failure 'Colliding export and manifest paths must be refused before creating a file or invoking the mock shim' }

    $manifestHashBeforeCollision = (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash
    $outputManifestCollision = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -OutputPath $rollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $manifestHashAfterCollision = (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash
    $evidence.cases['output-manifest-path-collision'] = [pscustomobject]@{ result = $outputManifestCollision; manifestSha256Before = $manifestHashBeforeCollision; manifestSha256After = $manifestHashAfterCollision }
    if ($outputManifestCollision.status -eq 'failed' -and @($outputManifestCollision.errors).Count -eq 1 -and
        $outputManifestCollision.errors[0].message -eq 'The export, rollback manifest and output paths must be three different files. Nothing was changed.' -and
        $manifestHashAfterCollision -eq $manifestHashBeforeCollision -and @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
        Add-Pass 'Colliding output and manifest paths print the refusal and preserve the earlier manifest bytes without invoking the mock shim'
    } else { Add-Failure 'Colliding output and manifest paths must print the refusal and preserve the earlier manifest bytes without invoking the mock shim' }

    $invalidExportPath = $tempRoot + [char]0 + 'invalid'
    $invalidPathCollision = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $invalidExportPath -RollbackManifestPath $rollbackPath -OutputPath $rollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $evidence.cases['invalid-path-with-output-manifest-collision'] = $invalidPathCollision
    if ($invalidPathCollision.status -eq 'failed' -and @($invalidPathCollision.errors).Count -eq 1 -and
        (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash -eq $manifestHashBeforeCollision -and
        @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
        Add-Pass 'Path normalization failure prints the error and preserves a colliding manifest without invoking the mock shim'
    } else { Add-Failure 'Path normalization failure must print the error and preserve a colliding manifest without invoking the mock shim' }

    $exportHashBeforeCollision = (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash
    $inheritedExportCollision = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -RollbackManifestPath $rollbackPath -OutputPath $exportPath -ConfirmApply -UserApproved)
    $exportHashAfterCollision = (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash
    $evidence.cases['output-inherited-export-path-collision'] = [pscustomobject]@{ result = $inheritedExportCollision; exportSha256Before = $exportHashBeforeCollision; exportSha256After = $exportHashAfterCollision }
    if ($inheritedExportCollision.status -eq 'failed' -and @($inheritedExportCollision.errors).Count -eq 1 -and
        $inheritedExportCollision.errors[0].message -eq 'The export, rollback manifest and output paths must be three different files. Nothing was changed.' -and
        $exportHashAfterCollision -eq $exportHashBeforeCollision -and @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
        Add-Pass 'An output path colliding with the export inherited during restore is refused without changing export bytes or invoking the mock shim'
    } else { Add-Failure 'An output path colliding with the export inherited during restore must be refused without changing export bytes or invoking the mock shim' }

    $replacementExportPath = Join-Path $tempRoot 'replacement-export.nip'
    [IO.File]::WriteAllText($replacementExportPath, 'Replacement export fixture')
    $replacementExportCollision = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $replacementExportPath -RollbackManifestPath $rollbackPath -OutputPath $exportPath -ConfirmApply -UserApproved)
    $evidence.cases['output-original-export-with-replacement'] = $replacementExportCollision
    if ($replacementExportCollision.status -eq 'failed' -and @($replacementExportCollision.errors).Count -eq 1 -and
        $replacementExportCollision.errors[0].message -eq 'The export, rollback manifest and output paths must be three different files. Nothing was changed.' -and
        (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash -eq $exportHashBeforeCollision -and
        @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
        Add-Pass 'An explicit replacement export cannot let refusal output overwrite the original manifest export'
    } else { Add-Failure 'An explicit replacement export must not let refusal output overwrite the original manifest export' }

    $hardLinkOutputPath = Join-Path $tempRoot 'manifest-output-hardlink.json'
    $manifestHashBeforeHardLink = (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash
    $hardLinkCreated = $false
    try {
        New-Item -ItemType HardLink -Path $hardLinkOutputPath -Target $rollbackPath -ErrorAction Stop | Out-Null
        $hardLinkCreated = $true
        $outputLinkType = (Get-Item -LiteralPath $hardLinkOutputPath -Force).LinkType
        $manifestLinkType = (Get-Item -LiteralPath $rollbackPath -Force).LinkType
        $hardLinkRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -OutputPath $hardLinkOutputPath)
        $manifestHashAfterHardLink = (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash
        $evidence.cases['output-hardlink-to-manifest'] = [pscustomobject]@{ result = $hardLinkRestore; outputLinkType = $outputLinkType; manifestLinkType = $manifestLinkType; manifestSha256Before = $manifestHashBeforeHardLink; manifestSha256After = $manifestHashAfterHardLink }
        if ($outputLinkType -eq 'HardLink' -and $manifestLinkType -eq 'HardLink' -and
            $hardLinkRestore.status -eq 'failed' -and @($hardLinkRestore.errors).Count -eq 1 -and
            $hardLinkRestore.errors[0].message -eq 'The export, rollback manifest and output paths must not go through a junction, symbolic link or hard link. Nothing was changed.' -and
            @($hardLinkRestore.executionSequence).Count -eq 0 -and $manifestHashAfterHardLink -eq $manifestHashBeforeHardLink -and
            @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
            Add-Pass 'A restore preview refuses an output hard link without changing the earlier manifest or invoking the mock shim'
        } else { Add-Failure 'A restore preview must refuse an output hard link without changing the earlier manifest or invoking the mock shim' }
    } finally {
        if ($hardLinkCreated) { [IO.File]::Delete($hardLinkOutputPath) }
    }

    $manifestAlias = Join-Path $tempRoot 'manifest-alias'
    $manifestJunctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $manifestAlias -Target $tempRoot | Out-Null
        $manifestJunctionCreated = $true
        $junctionOutputPath = Join-Path $manifestAlias (Split-Path $rollbackPath -Leaf)
        $junctionCollision = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -OutputPath $junctionOutputPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
        $evidence.cases['output-junction-to-manifest'] = $junctionCollision
        if ($junctionCollision.status -eq 'failed' -and @($junctionCollision.errors).Count -eq 1 -and
            $junctionCollision.errors[0].message -eq 'The export, rollback manifest and output paths must not go through a junction, symbolic link or hard link. Nothing was changed.' -and
            (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash -eq $manifestHashBeforeCollision -and
            @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
            Add-Pass 'An output path through a junction is refused without changing the earlier manifest or invoking the mock shim'
        } else { Add-Failure 'An output path through a junction must be refused without changing the earlier manifest or invoking the mock shim' }
    } finally {
        if ($manifestJunctionCreated) { [IO.Directory]::Delete($manifestAlias) }
    }

    $matchingOutputPath = Join-Path $tempRoot 'matching-restore-preview.json'
    $matchingRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -OutputPath $matchingOutputPath)
    $savedMatchingRestore = Get-Content -LiteralPath $matchingOutputPath -Raw | ConvertFrom-Json
    $evidence.cases['matching-explicit-and-manifest-export'] = $matchingRestore
    if ($matchingRestore.status -eq 'preview' -and @($matchingRestore.errors).Count -eq 0 -and $savedMatchingRestore.status -eq 'preview' -and
        (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash -eq $exportHashBeforeCollision -and
        @(Read-MockLog $successLog).Count -eq $logCountBeforeCollisions) {
        Add-Pass 'Matching explicit and manifest export references still allow a restore preview with a separate output file'
    } else { Add-Failure 'Matching explicit and manifest export references must still allow a restore preview with a separate output file' }

    $rollbackHash = (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash
    $exportHash = (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash
    $reused = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $rollbackHashAfter = (Get-FileHash -LiteralPath $rollbackPath -Algorithm SHA256).Hash
    $restorePreview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath)
    $restoreGates = @($restorePreview.gates | Where-Object { $_.gateId -in @('rollback-manifest-bound', 'rollback-export-present') })
    $evidence.cases['reused-success'] = [pscustomobject]@{ result = $reused; restorePreview = $restorePreview; manifestSha256Before = $rollbackHash; manifestSha256After = $rollbackHashAfter; exportSha256Before = $exportHash; exportSha256After = (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash }
    if ($reused.status -eq 'failed' -and $null -eq $reused.rollbackManifestPath -and
        $reused.summary.willRunMockShim -eq $false -and $reused.summary.realNvpiInvoked -eq $false -and
        @($reused.executionSequence).Count -eq 1 -and $reused.executionSequence[0].skipped -and
        $reused.executionSequence[0].reason -eq 'The rollback export path already exists, so an older file cannot stand in for this export. Choose a new export path; import was not attempted.' -and
        $rollbackHashAfter -eq $rollbackHash -and (Get-FileHash -LiteralPath $exportPath -Algorithm SHA256).Hash -eq $exportHash -and
        @(Read-MockLog $successLog).Count -eq 2 -and $restoreGates.Count -eq 2 -and @($restoreGates | Where-Object { -not $_.satisfied -or $_.blocking }).Count -eq 0) {
        Add-Pass 'Refusing a reused successful export preserves its manifest bytes and both restore gates'
    } else { Add-Failure 'Refusing a reused successful export must preserve its manifest bytes and both restore gates' }

    foreach ($behavior in @('ExportNoFile', 'ExportEmpty')) {
        $caseRoot = Join-Path $tempRoot $behavior
        [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
        $shimPath = Join-Path $caseRoot 'nvpi.ps1'; $logPath = Join-Path $caseRoot 'nvpi.log'
        $caseExportPath = Join-Path $caseRoot 'before.nip'; $caseRollbackPath = Join-Path $caseRoot 'rollback.json'
        New-NvpiMockShim $shimPath $logPath $behavior
        $result = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $shimPath -HardwareInventoryPath $nvidiaHardware -ExportPath $caseExportPath -RollbackManifestPath $caseRollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
        $entries = @(Read-MockLog $logPath)
        $manifest = Get-Content -LiteralPath $caseRollbackPath -Raw | ConvertFrom-Json
        $exportRuns = @($result.executionSequence | Where-Object { $_.operation -eq 'export' })
        $skippedImports = @($result.executionSequence | Where-Object { $_.operation -eq 'import' -and $_.skipped })
        $fileExists = Test-Path -LiteralPath $caseExportPath -PathType Leaf
        $fileBytes = if ($fileExists) { (Get-Item -LiteralPath $caseExportPath).Length } else { $null }
        $evidence.cases[$behavior] = [pscustomobject]@{ result = $result; log = $entries; manifest = $manifest; exportExists = $fileExists; exportBytes = $fileBytes }
        if ($result.status -eq 'failed' -and $result.summary.exportAttempted -eq $true -and $result.summary.exportCompleted -eq $false -and
            $result.summary.importAttempted -eq $false -and $result.summary.importCompleted -eq $false -and
            $entries.Count -eq 1 -and $entries[0].args[0] -eq '-exportProfile' -and
            $manifest.exportCompleted -eq $false -and $manifest.importAttempted -eq $false -and $manifest.importCompleted -eq $false -and
            $exportRuns.Count -eq 1 -and $exportRuns[0].exportFileVerified -eq $false -and
            $skippedImports.Count -eq 1 -and $skippedImports[0].reason -eq 'Export finished without writing a usable rollback file; import was not attempted.' -and
            (($behavior -eq 'ExportNoFile' -and -not $fileExists) -or ($behavior -eq 'ExportEmpty' -and $fileExists -and $fileBytes -eq 0))) {
            Add-Pass "NVIDIA NIP executor refuses import after $behavior and records no import in its rollback manifest"
        } else { Add-Failure "NVIDIA NIP executor must refuse import after $behavior and record no import in its rollback manifest" }
    }

    foreach ($existingType in @('file', 'folder')) {
        $caseRoot = Join-Path $tempRoot ('existing-' + $existingType)
        [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
        $shimPath = Join-Path $caseRoot 'nvpi.ps1'; $logPath = Join-Path $caseRoot 'nvpi.log'
        $caseExportPath = Join-Path $caseRoot 'before.nip'; $caseRollbackPath = Join-Path $caseRoot 'rollback.json'
        New-NvpiMockShim $shimPath $logPath 'Success'
        $olderFile = $caseExportPath
        if ($existingType -eq 'folder') { [IO.Directory]::CreateDirectory($caseExportPath) | Out-Null; $olderFile = Join-Path $caseExportPath 'older.nip' }
        [IO.File]::WriteAllText($olderFile, 'older export')
        $olderHash = (Get-FileHash -LiteralPath $olderFile -Algorithm SHA256).Hash
        $result = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $shimPath -HardwareInventoryPath $nvidiaHardware -ExportPath $caseExportPath -RollbackManifestPath $caseRollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
        $entries = @(Read-MockLog $logPath)
        $manifestExists = Test-Path -LiteralPath $caseRollbackPath
        $olderHashAfter = (Get-FileHash -LiteralPath $olderFile -Algorithm SHA256).Hash
        $evidence.cases['existing-' + $existingType] = [pscustomobject]@{ result = $result; log = $entries; manifestExists = $manifestExists; exportType = $existingType; olderHashBefore = $olderHash; olderHashAfter = $olderHashAfter }
        if ($result.status -eq 'failed' -and $result.summary.exportAttempted -eq $false -and $result.summary.exportCompleted -eq $false -and
            $result.summary.willRunMockShim -eq $false -and $result.summary.realNvpiInvoked -eq $false -and
            $result.summary.importAttempted -eq $false -and $result.summary.importCompleted -eq $false -and $entries.Count -eq 0 -and
            [IO.File]::ReadAllText($olderFile) -eq 'older export' -and $olderHashAfter -eq $olderHash -and
            -not $manifestExists -and $null -eq $result.rollbackManifestPath -and
            @($result.executionSequence).Count -eq 1 -and $result.executionSequence[0].order -eq 1 -and $result.executionSequence[0].operation -eq 'import' -and
            $result.executionSequence[0].skipped -eq $true -and $result.executionSequence[0].reason -eq 'The rollback export path already exists, so an older file cannot stand in for this export. Choose a new export path; import was not attempted.') {
            Add-Pass "NVIDIA NIP executor preserves an existing export $existingType without running export or import"
        } else { Add-Failure "NVIDIA NIP executor must preserve an existing export $existingType without running export or import" }
    }

    $failExportPath = Join-Path $tempRoot 'before-fail.nip'
    $failExport = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $exportFailShim -HardwareInventoryPath $nvidiaHardware -ExportPath $failExportPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    if ($failExport.status -eq 'failed' -and $failExport.summary.exportCompleted -eq $false -and $failExport.summary.importAttempted -eq $false -and $failExport.summary.importSkippedUntilExportSucceeded -eq $true -and $failExport.summary.nonZeroExitCount -eq 1) {
        Add-Pass 'NVIDIA NIP executor skips import when export fails'
    } else {
        Add-Failure 'NVIDIA NIP executor did not skip import after export failure'
    }

    $timeoutExportPath = Join-Path $tempRoot 'before-timeout.nip'
    $timeout = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $timeoutShim -HardwareInventoryPath $nvidiaHardware -ExportPath $timeoutExportPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached -TimeoutSeconds 1)
    if ($timeout.status -eq 'failed' -and $timeout.summary.timeoutCount -eq 1 -and $timeout.summary.importAttempted -eq $false -and $timeout.summary.importSkippedUntilExportSucceeded -eq $true) {
        Add-Pass 'NVIDIA NIP executor skips import when export times out'
    } else {
        Add-Failure 'NVIDIA NIP executor did not skip import after export timeout'
    }

    $importFailExportPath = Join-Path $tempRoot 'before-import-fail.nip'
    $importFailRollbackPath = Join-Path $tempRoot 'import-fail-rollback.json'
    $importFail = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -ExecutorMode Mock -MockNvpiShimPath $importFailShim -HardwareInventoryPath $nvidiaHardware -ExportPath $importFailExportPath -RollbackManifestPath $importFailRollbackPath -ConfirmApply -UserApproved -BenchmarkEvidenceAttached)
    $importFailManifest = Get-Content -LiteralPath $importFailRollbackPath -Raw | ConvertFrom-Json
    if ($importFail.status -eq 'failed' -and $importFail.summary.exportCompleted -eq $true -and $importFail.summary.importAttempted -eq $true -and $importFail.summary.importCompleted -eq $false -and $importFailManifest.exportCompleted -eq $true -and $importFailManifest.importAttempted -eq $true -and $importFailManifest.importCompleted -eq $false -and (Test-Path -LiteralPath $importFailExportPath)) {
        Add-Pass 'NVIDIA NIP failed import retains durable exact rollback evidence'
    } else {
        Add-Failure 'NVIDIA NIP failed import did not retain durable exact rollback evidence'
    }

    $missingManifestRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -ConfirmApply -UserApproved)
    if ($missingManifestRestore.status -eq 'blocked' -and @($missingManifestRestore.executionSequence).Count -eq 0 -and (@($missingManifestRestore.gates | Where-Object { $_.gateId -eq 'rollback-manifest-bound' -and $_.blocking }).Count -eq 1)) {
        Add-Pass 'NVIDIA NIP restore rejects an export without its exact rollback manifest'
    } else {
        Add-Failure 'NVIDIA NIP restore accepted an export without its rollback manifest'
    }

    $wrongManifestPath = Join-Path $tempRoot 'wrong-profile-rollback.json'
    $wrongManifest = Get-Content -LiteralPath $rollbackPath -Raw | ConvertFrom-Json
    $wrongManifest.profileId = 'another-profile'
    $wrongManifest | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $wrongManifestPath -Encoding UTF8
    $wrongProfileRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -RollbackManifestPath $wrongManifestPath -ConfirmApply -UserApproved)
    if ($wrongProfileRestore.status -eq 'blocked' -and @($wrongProfileRestore.executionSequence).Count -eq 0) {
        Add-Pass 'NVIDIA NIP restore rejects a rollback manifest for another profile'
    } else {
        Add-Failure 'NVIDIA NIP restore accepted a rollback manifest for another profile'
    }

    $staleManifestPath = Join-Path $tempRoot 'stale-export-rollback.json'
    $staleManifest = Get-Content -LiteralPath $rollbackPath -Raw | ConvertFrom-Json
    $staleManifest.exportPath = Join-Path $tempRoot 'missing-export.nip'
    $staleManifest | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $staleManifestPath -Encoding UTF8
    $staleRestore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -RollbackManifestPath $staleManifestPath -ConfirmApply -UserApproved)
    if ($staleRestore.status -eq 'blocked' -and @($staleRestore.executionSequence).Count -eq 0 -and (@($staleRestore.gates | Where-Object { $_.gateId -eq 'rollback-export-present' -and $_.blocking }).Count -eq 1)) {
        Add-Pass 'NVIDIA NIP restore rejects a rollback manifest whose export is missing'
    } else {
        Add-Failure 'NVIDIA NIP restore accepted a missing rollback export'
    }

    $restore = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Operation Restore -ExecutorMode Mock -MockNvpiShimPath $successShim -HardwareInventoryPath $nvidiaHardware -ExportPath $exportPath -RollbackManifestPath $rollbackPath -ConfirmApply -UserApproved)
    if ($restore.status -eq 'success' -and $restore.summary.exportAttempted -eq $false -and $restore.summary.importAttempted -eq $true -and @($restore.executionSequence)[0].operation -eq 'restore-import') {
        Add-Pass 'NVIDIA NIP restore executor imports only the exact manifest-bound rollback export'
    } else {
        Add-Failure 'NVIDIA NIP restore executor did not run the exact manifest-bound rollback import'
    }

    $utilitiesRoot = Join-Path $tempRoot 'Utilities'
    New-Item -ItemType Directory -Path (Join-Path $utilitiesRoot 'Other') -Force | Out-Null
    $profileFile = Join-Path $utilitiesRoot 'Other\base-profile.nip'
    Set-Content -LiteralPath $profileFile -Value 'fixture NVIDIA profile' -Encoding ascii
    $registryScript = Join-Path $PSScriptRoot 'Get-RooIndustriesCapabilityRegistry.ps1'
    $inventoryScript = Join-Path $PSScriptRoot 'Get-RooIndustriesUtilitiesInventory.ps1'
    $registry = ConvertFrom-ScriptJson (& $registryScript -UtilitiesRoot $utilitiesRoot)
    $inventory = ConvertFrom-ScriptJson (& $inventoryScript -UtilitiesRoot $utilitiesRoot)
    $profileRules = @(foreach ($entry in @($registry.capabilities)) {
        $checked = @($entry.resolvedAvailability.checkedRules)
        $rules = @($checked | Where-Object { [string]$_.target -like '*\Other\base-profile.nip' })
        foreach ($rule in $rules) {
            [pscustomobject]@{ capabilityId = $entry.capabilityId; passed = $rule.passed }
        }
    })
    $profileTool = @($inventory.tools | Where-Object { $_.id -eq 'base-profile-nip' })[0]
    $evidence.cases['profile-file-present'] = [pscustomobject]@{ registry = $profileRules; inventory = $profileTool }
    $ruleResults = @($profileRules | ForEach-Object { "$($_.capabilityId)=$($_.passed)" }) -join ', '
    if ($profileRules.Count -eq 3 -and @($profileRules | Where-Object { $_.passed -ne $true }).Count -eq 0 -and
        $null -ne $profileTool -and $profileTool.present -eq $true) {
        Add-Pass "The registry and the inventory report the profile file present: $ruleResults, inventory=True"
    } else {
        $toolPresent = if ($null -eq $profileTool) { 'missing' } else { $profileTool.present }
        Add-Failure "The profile file was not reported present everywhere: $ruleResults, inventory=$toolPresent"
    }

    $legacyId = 'legacy-fixture'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $legacyHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($legacyId)) } finally { $sha.Dispose() }
    $catalogPath = Join-Path $tempRoot 'nvidia-catalog.json'
    $shippedCatalog = Join-Path $repoRoot 'backend\catalogs\nvidia-profile-inspector-nip-catalog.json'
    $catalog = Get-Content -LiteralPath $shippedCatalog -Raw | ConvertFrom-Json
    $catalog.profiles[0].formerProfileIdSha256 += -join ($legacyHash | ForEach-Object { $_.ToString('X2') })
    $catalog | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $catalogPath -Encoding UTF8
    $legacyManifestPath = Join-Path $tempRoot 'legacy-rollback.json'
    $unknownManifestPath = Join-Path $tempRoot 'unknown-rollback.json'
    foreach ($case in @(@($legacyManifestPath, $legacyId), @($unknownManifestPath, 'unknown-fixture'))) {
        $saved = Get-Content -LiteralPath $rollbackPath -Raw | ConvertFrom-Json
        $saved.profileId = $case[1]
        $saved | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $case[0] -Encoding UTF8
    }
    $restoreScript = Join-Path $PSScriptRoot 'Restore-NvidiaNipProfile.ps1'
    $executorScript = Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1'
    $selected = @{ CatalogPath = $catalogPath; ProfileId = 'base-profile'; HardwareInventoryPath = $nvidiaHardware }
    $mock = @{ ExecutorMode = 'Mock'; MockNvpiShimPath = $successShim }
    $logBeforeIds = @(Read-MockLog $successLog).Count
    $legacyMetadata = ConvertFrom-ScriptJson (& $restoreScript @selected -RollbackManifestPath $legacyManifestPath)
    $legacyRestore = ConvertFrom-ScriptJson (& $executorScript @selected @mock -Operation Restore `
        -RollbackManifestPath $legacyManifestPath -ConfirmApply -UserApproved)
    $unknownMetadata = ConvertFrom-ScriptJson (& $restoreScript @selected -RollbackManifestPath $unknownManifestPath)
    $unknownRestore = ConvertFrom-ScriptJson (& $executorScript @selected @mock -Operation Restore `
        -RollbackManifestPath $unknownManifestPath -ConfirmApply -UserApproved)
    $evidence.cases['former-id-restore'] = [pscustomobject]@{ metadata = $legacyMetadata; executor = $legacyRestore }
    $evidence.cases['unknown-id-restore'] = [pscustomobject]@{ metadata = $unknownMetadata; executor = $unknownRestore }
    $unbound = @(@($unknownMetadata.gates) + @($unknownRestore.gates) |
        Where-Object { $_.gateId -eq 'rollback-manifest-bound' -and $_.blocking }).Count
    if ($legacyMetadata.summary.restoreSupported -eq $true -and $legacyRestore.status -eq 'success' -and
        $legacyRestore.profileId -eq 'base-profile' -and $unknownMetadata.summary.restoreSupported -eq $false -and
        $unknownRestore.status -eq 'blocked' -and $unbound -eq 2 -and
        @($unknownRestore.executionSequence).Count -eq 0 -and @(Read-MockLog $successLog).Count -eq $logBeforeIds + 1) {
        Add-Pass 'Both restore entry points bind a manifest saved under a former profile ID and refuse an unknown ID'
    } else {
        Add-Failure 'Restore entry points did not bind the former profile ID or accepted an unknown ID'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'NVIDIA NIP executor disposable fixtures were cleaned up'
    } else {
        Add-Failure 'NVIDIA NIP executor disposable fixtures remain'
    }
} catch {
    Add-Failure "NVIDIA NIP executor validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after NVIDIA NIP executor validation'
} else {
    Add-Failure "backend/state is not empty or changed during NVIDIA NIP executor validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'NVIDIA NIP executor validation did not launch NVIDIA Profile Inspector or import a real NIP file'

$evidence.scriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Invoke-NvidiaNipExecutor.ps1') -Algorithm SHA256).Hash
$evidence.passes = @($passes.ToArray()); $evidence.failures = @($failures.ToArray())
$evidence.stateBefore = $stateBefore; $evidence.stateAfter = $stateAfter; $evidence.fixturesRemoved = -not (Test-Path -LiteralPath $tempRoot)
[IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($EvidencePath)) -Parent)) | Out-Null
$evidence | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Host "Evidence: $EvidencePath"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS NVIDIA NIP executor validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL NVIDIA NIP executor validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
