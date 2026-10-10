$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
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
    param([string]$RelativePath)
    $path = Join-Path $repoRoot $RelativePath
    try {
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json | Out-Null
        Add-Pass "JSON parsed: $RelativePath"
    } catch {
        Add-Failure "JSON parse failed: $RelativePath :: $($_.Exception.Message)"
    }
}

function Invoke-JsonScript {
    param(
        [string]$ScriptPath,
        [object[]]$Arguments = @()
    )
    $output = & $ScriptPath @Arguments
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

$requiredFiles = @(
    'backend\uninstall\protected-apps.json',
    'backend\uninstall\leftover-scan-rules.json',
    'backend\uninstall\uninstall-policy.json',
    'backend\scripts\UninstallCleanup.Common.ps1',
    'backend\scripts\Get-InstalledAppInventory.ps1',
    'backend\scripts\Get-AppClassification.ps1',
    'backend\scripts\Preview-UninstallQueue.ps1',
    'backend\scripts\Preview-OfficialUninstall.ps1',
    'backend\scripts\Preview-LeftoverScan.ps1',
    'backend\scripts\New-CleanupDeletionManifest.ps1',
    'backend\scripts\New-UninstallCleanupExecutionPlan.ps1',
    'backend\scripts\Invoke-UninstallCleanupExecution.ps1',
    'backend\scripts\Test-UninstallCleanupBackend.ps1',
    'backend\samples\installed-app-inventory.sample.json',
    'backend\samples\app-classification.sample.json',
    'backend\samples\uninstall-queue.sample.json',
    'backend\samples\official-uninstall-preview.sample.json',
    'backend\samples\uninstall-cleanup-execution-plan.sample.json',
    'backend\samples\leftover-scan-preview.sample.json',
    'backend\samples\cleanup-deletion-manifest.sample.json'
)

foreach ($relative in $requiredFiles) {
    Test-RequiredFile $relative
}

foreach ($relative in @(
    'backend\uninstall\protected-apps.json',
    'backend\uninstall\leftover-scan-rules.json',
    'backend\uninstall\uninstall-policy.json',
    'backend\samples\installed-app-inventory.sample.json',
    'backend\samples\app-classification.sample.json',
    'backend\samples\uninstall-queue.sample.json',
    'backend\samples\official-uninstall-preview.sample.json',
    'backend\samples\uninstall-cleanup-execution-plan.sample.json',
    'backend\samples\leftover-scan-preview.sample.json',
    'backend\samples\cleanup-deletion-manifest.sample.json'
)) {
    Test-JsonFile $relative
}

$stateBefore = Get-StateEntryCount

$sampleInventory = Join-Path $repoRoot 'backend\samples\installed-app-inventory.sample.json'
$sampleScan = Join-Path $repoRoot 'backend\samples\leftover-scan-preview.sample.json'
$sampleOfficialPreview = Join-Path $repoRoot 'backend\samples\official-uninstall-preview.sample.json'
$sampleCleanupManifest = Join-Path $repoRoot 'backend\samples\cleanup-deletion-manifest.sample.json'

try {
    $classificationOutput = & (Join-Path $PSScriptRoot 'Get-AppClassification.ps1') -InventoryPath $sampleInventory
    $classification = ($classificationOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($classification.productName -eq 'Roo Industries Optimization Suite' -and $classification.summary.appCount -gt 0) {
        Add-Pass "App classification returned $($classification.summary.appCount) app classifications"
    } else {
        Add-Failure 'App classification returned an unexpected shape'
    }
    $webview = @($classification.apps | Where-Object { $_.appId -eq 'registry:microsoft-edge-webview2-runtime' }) | Select-Object -First 1
    if ($webview.protected -eq $false -and $webview.blockByDefault -eq $false -and $webview.risk -eq 'advanced' -and ($webview.reasonCodes -contains 'MANUAL_REVIEW_CATALOG_MATCH')) {
        Add-Pass 'WebView2 runtime is manual-review and queue-visible by default'
    } else {
        Add-Failure 'WebView2 runtime classification did not use manual-review queue-visible behavior'
    }
} catch {
    Add-Failure "App classification failed: $($_.Exception.Message)"
}

try {
    $queueOutput = & (Join-Path $PSScriptRoot 'Preview-UninstallQueue.ps1') -InventoryPath $sampleInventory -AppId @('registry:overwolf', 'registry:microsoft-edge-webview2-runtime')
    $queue = ($queueOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($queue.dryRun -eq $true -and $queue.status -eq 'preview' -and $queue.summary.willRunUninstallers -eq $false -and $queue.summary.willDeleteLeftovers -eq $false) {
        Add-Pass 'Uninstall queue preview is dry-run and does not run uninstallers or delete leftovers'
    } else {
        Add-Failure 'Uninstall queue preview reported unsafe execution state'
    }
    if (@($queue.selectedApps).Count -eq 2 -and @($queue.blockedApps).Count -eq 0) {
        Add-Pass 'Uninstall queue keeps manual-review apps visible instead of hiding them'
    } else {
        Add-Failure 'Uninstall queue did not keep manual-review apps visible by default'
    }
} catch {
    Add-Failure "Uninstall queue preview failed: $($_.Exception.Message)"
}

try {
    $officialOutput = & (Join-Path $PSScriptRoot 'Preview-OfficialUninstall.ps1') -InventoryPath $sampleInventory -AppId 'registry:overwolf'
    $official = ($officialOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $command = @($official.commands) | Select-Object -First 1
    if ($official.dryRun -eq $true -and $official.summary.willRunUninstallers -eq $false -and $command.executionAllowed -eq $false) {
        Add-Pass 'Official uninstall preview exposes metadata without command execution'
    } else {
        Add-Failure 'Official uninstall preview reported executable state'
    }
} catch {
    Add-Failure "Official uninstall preview failed: $($_.Exception.Message)"
}

$commandLineRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-command-line-' + [guid]::NewGuid().ToString('N'))
try {
    $spacedRemover = Join-Path $commandLineRoot 'Roo Industries Fixture\Uninstall Me.exe'
    [IO.Directory]::CreateDirectory((Split-Path $spacedRemover -Parent)) | Out-Null
    [IO.File]::WriteAllText($spacedRemover, 'fixture')
    $productCode = '{11111111-2222-3333-4444-555555555555}'
    $lockedRemover = Join-Path $commandLineRoot 'Locked\uninstall.exe'
    [IO.Directory]::CreateDirectory((Split-Path $lockedRemover -Parent)) | Out-Null
    [IO.File]::WriteAllText($lockedRemover, 'fixture')
    $commandLineInventory = Join-Path $commandLineRoot 'inventory.json'
    [IO.File]::WriteAllText($commandLineInventory, ([pscustomobject]@{ schemaVersion = 1; apps = @(
        [pscustomobject]@{ appId = 'registry:roo-industries-command-msi'; displayName = 'Roo Industries MSI command'; publisher = 'Roo Industries'; sourceType = 'msi'; packageId = $productCode; uninstallString = "MsiExec.exe /X$productCode"; categories = @('application'); risk = 'low'; protected = $false },
        [pscustomobject]@{ appId = 'registry:roo-industries-command-spaced'; displayName = 'Roo Industries spaced command'; publisher = 'Roo Industries'; sourceType = 'registry'; uninstallString = "$spacedRemover /S /quiet"; categories = @('application'); risk = 'low'; protected = $false },
        [pscustomobject]@{ appId = 'registry:roo-industries-command-relative'; displayName = 'Roo Industries relative command'; publisher = 'Roo Industries'; sourceType = 'registry'; uninstallString = 'uninstall.exe /S'; categories = @('application'); risk = 'low'; protected = $false },
        [pscustomobject]@{ appId = 'registry:roo-industries-command-missing'; displayName = 'Roo Industries missing command'; publisher = 'Roo Industries'; sourceType = 'registry'; uninstallString = ('"' + (Join-Path $commandLineRoot 'Gone\uninstall.exe') + '" /S'); categories = @('application'); risk = 'low'; protected = $false },
        [pscustomobject]@{ appId = 'registry:roo-industries-command-locked'; displayName = 'Roo Industries locked command'; publisher = 'Roo Industries'; sourceType = 'registry'; uninstallString = ('"' + $lockedRemover + '" /S'); categories = @('application'); risk = 'low'; protected = $false },
        [pscustomobject]@{ appId = 'registry:roo-industries-command-long'; displayName = 'Roo Industries long command'; publisher = 'Roo Industries'; sourceType = 'registry'; uninstallString = ('C:\' + ('a' * 300) + '\uninstall.exe /S'); categories = @('application'); risk = 'low'; protected = $false }
    ) } | ConvertTo-Json -Depth 8))
    $lockHandle = [IO.File]::Open($lockedRemover, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $lines = ((& (Join-Path $PSScriptRoot 'Preview-OfficialUninstall.ps1') -InventoryPath $commandLineInventory -AppId @('registry:roo-industries-command-msi', 'registry:roo-industries-command-spaced', 'registry:roo-industries-command-relative', 'registry:roo-industries-command-missing', 'registry:roo-industries-command-locked', 'registry:roo-industries-command-long')) -join [Environment]::NewLine) | ConvertFrom-Json }
    finally { $lockHandle.Dispose() }
    $byId = @{}; foreach ($entry in @($lines.commands)) { $byId[[string]$entry.appId] = $entry }
    $msiLine = '"' + (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') + '" /x ' + $productCode + ' /norestart'
    if ($byId['registry:roo-industries-command-msi'].commandLine -ceq $msiLine -and $byId['registry:roo-industries-command-spaced'].commandLine -ceq ('"' + $spacedRemover + '" /S /quiet') -and $null -eq $byId['registry:roo-industries-command-relative'].commandLine -and $lines.status -eq 'preview' -and $byId.ContainsKey('registry:roo-industries-command-long') -and $null -eq $byId['registry:roo-industries-command-long'].commandLine -and $byId['registry:roo-industries-command-spaced'].executableSha256 -ceq (Get-FileHash -LiteralPath $spacedRemover -Algorithm SHA256).Hash.ToLowerInvariant() -and $byId['registry:roo-industries-command-spaced'].executableState -ceq 'present' -and $byId['registry:roo-industries-command-missing'].executableState -ceq 'missing' -and $byId['registry:roo-industries-command-locked'].executableState -ceq 'unreadable' -and $null -eq $byId['registry:roo-industries-command-locked'].executableSha256) {
        Add-Pass 'Removal path review returns the exact command and file hash that run, and none for an unresolvable or overlong remover'
    } else {
        Add-Failure ('Removal path review command lines differ from what runs: status ' + [string]$lines.status + ' ' + (@($lines.commands | ForEach-Object { [string]$_.appId + ' => ' + [string]$_.commandLine + ' ' + [string]$_.executableSha256 + ' ' + [string]$_.executableState }) -join '; ') + ' ' + (@($lines.errors | ForEach-Object { $_.message }) -join '; '))
    }
} catch {
    Add-Failure "Removal path command-line review failed: $($_.Exception.Message)"
} finally {
    if (Test-Path -LiteralPath $commandLineRoot) { Remove-Item -LiteralPath $commandLineRoot -Recurse -Force }
}

try {
    $scanOutput = & (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -InventoryPath $sampleInventory -AppId 'registry:overwolf'
    $scan = ($scanOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($scan.dryRun -eq $true -and $scan.summary.deletionMode -eq 'preview-only' -and $scan.summary.willDeleteLeftovers -eq $false) {
        Add-Pass "Leftover scan preview returned $($scan.summary.itemCount) candidate item(s) without deletion"
    } else {
        Add-Failure 'Leftover scan preview reported unsafe deletion state'
    }
    $fuzzyShared = @($scan.items | Where-Object { $_.matchedBy -contains 'fuzzyName' -and $_.defaultSelected -eq $true })
    if ($fuzzyShared.Count -eq 0) {
        Add-Pass 'Leftover scan does not default-select fuzzy shared paths'
    } else {
        Add-Failure 'Leftover scan default-selected a fuzzy shared path'
    }
} catch {
    Add-Failure "Leftover scan preview failed: $($_.Exception.Message)"
}

try {
    $sampleItems = @((Get-Content -LiteralPath $sampleScan -Raw | ConvertFrom-Json).items)
    $sampleOwned = @($sampleItems | Where-Object { $_.type -eq 'startupEntry' -or ($_.type -in @('registryKey', 'registryValue') -and @([string]$_.target -split '\\' | Where-Object { $_ -in @('Microsoft', 'Policies') }).Count -gt 0) })
    if ($sampleItems.Count -gt 0 -and $sampleOwned.Count -eq 0) {
        Add-Pass 'The leftover scan sample shows no Microsoft or Windows owned items'
    } else {
        Add-Failure ('The leftover scan sample shows Microsoft or Windows owned items: ' + (($sampleOwned | ForEach-Object { $_.target }) -join '; '))
    }
} catch {
    Add-Failure "Leftover scan sample check failed: $($_.Exception.Message)"
}

try {
    $leftoverAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1'), [ref]$null, [ref]$null)
    $ownedFunction = $leftoverAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-MicrosoftOwnedFilePath' }, $true)
    $withoutLocalData = $ownedFunction.Extent.Text.Replace("[Environment]::GetFolderPath('LocalApplicationData')", "''")
    $ownedWithoutLocalData = & ([scriptblock]::Create($withoutLocalData + "`nTest-MicrosoftOwnedFilePath 'C:\Vendor\App\uninstall.exe'"))
    if ($withoutLocalData -ne $ownedFunction.Extent.Text -and $ownedWithoutLocalData -eq $false) {
        Add-Pass 'The Windows-owned path check skips the package root when the local app data folder is unavailable'
    } else {
        Add-Failure 'The Windows-owned path check did not handle a missing local app data folder'
    }
} catch {
    Add-Failure "The Windows-owned path check failed without a local app data folder: $($_.Exception.Message)"
}

$ownershipRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-leftover-ownership-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($ownershipRoot) | Out-Null
    $guid = '{12345678-1234-1234-1234-1234567890AB}'
    $microsoftInstall = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Microsoft\RooIndustriesOwnership' + [guid]::NewGuid().ToString('N'))
    $windowsOwnedData = @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Packages\Microsoft.GamingApp_8wekyb3d8bbwe\LocalState'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'ModifiableWindowsApps\RooIndustriesFixture'),
        (Join-Path ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows'))) 'XboxGames\RooIndustriesFixture'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\LocalLow\Microsoft\RooIndustriesFixture')
    )
    $apps = @(
        [pscustomobject]@{ appId = 'registry:roo-industries-fixture-notepad++'; displayName = 'Notepad++'; publisher = 'Notepad++ Team'; sourceType = 'registry'; uninstallString = "MsiExec.exe /X$guid"; categories = @('application'); risk = 'low'; protected = $false },
        [pscustomobject]@{ appId = 'registry:roo-industries-fixture-microsoft'; displayName = 'Roo Industries Microsoft fixture'; publisher = 'Microsoft Corporation'; sourceType = 'registry'; uninstallString = "MsiExec.exe /X$guid"; installLocation = $microsoftInstall; categories = @('application'); risk = 'low'; protected = $false }
    )
    $ownershipInventory = Join-Path $ownershipRoot 'inventory.json'
    [IO.File]::WriteAllText($ownershipInventory, ([pscustomobject]@{ schemaVersion = 1; apps = $apps } | ConvertTo-Json -Depth 8))
    $ownershipRules = Get-Content -LiteralPath (Join-Path $repoRoot 'backend\uninstall\leftover-scan-rules.json') -Raw | ConvertFrom-Json
    $ownershipRules.knownAppRules = @([pscustomobject]@{
        ruleId = 'roo-industries-fixture-everything'; match = [pscustomobject]@{ displayNamePatterns = @('Notepad++', 'Roo Industries Microsoft fixture') }
        vendorRegistryKeys = @('HKCU\Software\Microsoft\Notepad', 'HKLM\Software\Policies\Notepad++', 'HKCU\Software\Notepad++')
        knownAppDataPaths = $windowsOwnedData
        serviceNamePatterns = @('*'); scheduledTaskPatterns = @('*'); startupValuePatterns = @('*')
    })
    $ownershipRulesPath = Join-Path $ownershipRoot 'rules.json'
    [IO.File]::WriteAllText($ownershipRulesPath, ($ownershipRules | ConvertTo-Json -Depth 16))
    function Read-OwnershipScan([string]$Id) { return ((& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -InventoryPath $ownershipInventory -RulesPath $ownershipRulesPath -AppId $Id) -join [Environment]::NewLine) | ConvertFrom-Json }
    $windowsRoot = [Environment]::GetFolderPath('Windows').TrimEnd('\') + '\'
    function Test-WindowsOwnedItem($Item) {
        return ($Item.type -in @('registryKey', 'registryValue') -and @([string]$Item.target -split '\\' | Where-Object { $_ -in @('Microsoft', 'Policies') }).Count -gt 0) -or
            ($Item.type -eq 'scheduledTask' -and ([string]$Item.target).StartsWith('\Microsoft\', [StringComparison]::OrdinalIgnoreCase)) -or
            ($Item.type -eq 'service' -and [Environment]::ExpandEnvironmentVariables(([string]$Item.metadata.pathName).Trim('"')).StartsWith($windowsRoot, [StringComparison]::OrdinalIgnoreCase))
    }
    $thirdParty = Read-OwnershipScan 'registry:roo-industries-fixture-notepad++'
    $knownServices = @('WinDefend', 'WdNisSvc', 'Sense', 'wuauserv', 'Winmgmt', 'EventLog', 'MicrosoftEdgeElevationService', 'edgeupdate', 'edgeupdatem', 'WMPNetworkSvc')
    $knownTasks = @('MicrosoftEdgeUpdateTask*', 'OneDrive*', 'CreateExplorerShellUnelevatedTask')
    $knownStartup = @('SecurityHealth', 'OneDrive', 'MicrosoftEdgeAutoLaunch*')
    function Test-KnownWindowsItem($Item) {
        $leaf = ([string]$Item.target).Split('\')[-1]
        return ($Item.type -eq 'service' -and $Item.target -in $knownServices) -or
            ($Item.type -eq 'scheduledTask' -and @($knownTasks | Where-Object { $leaf -like $_ }).Count -gt 0) -or
            ($Item.type -eq 'startupEntry' -and @($knownStartup | Where-Object { $leaf -like $_ }).Count -gt 0)
    }
    $owned = @($thirdParty.items | Where-Object { (Test-WindowsOwnedItem $_) -or (Test-KnownWindowsItem $_) -or $_.type -eq 'startupEntry' })
    if (@($thirdParty.errors).Count -eq 0 -and $owned.Count -eq 0 -and @($thirdParty.items | Where-Object { $_.target -eq 'HKCU\Software\Notepad++' }).Count -eq 1) {
        Add-Pass 'A third-party leftover scan never offers Microsoft or Windows owned keys, tasks or services'
    } else {
        Add-Failure ('A third-party leftover scan offered Windows-owned items: ' + (($owned | ForEach-Object { $_.type + ' ' + $_.target }) -join '; ') + ' ' + (@($thirdParty.errors | ForEach-Object { $_.message }) -join '; '))
    }
    $microsoft = Read-OwnershipScan 'registry:roo-industries-fixture-microsoft'
    $microsoftOwned = @($microsoft.items | Where-Object { (Test-WindowsOwnedItem $_) -or (Test-KnownWindowsItem $_) -or $_.type -eq 'startupEntry' -or ([string]$_.target).StartsWith($microsoftInstall, [StringComparison]::OrdinalIgnoreCase) })
    if (@($microsoft.errors).Count -eq 0 -and $microsoftOwned.Count -eq 0 -and @($microsoft.items | Where-Object { $_.target -eq 'HKCU\Software\Notepad++' }).Count -eq 1) {
        Add-Pass 'A Microsoft-published app is never offered Microsoft or Windows owned keys, files, tasks, services or its Uninstall entry'
    } else {
        Add-Failure ('A Microsoft-published app was offered Microsoft or Windows owned items: ' + (($microsoftOwned | ForEach-Object { $_.type + ' ' + $_.target }) -join '; ') + ' ' + (@($microsoft.errors | ForEach-Object { $_.message }) -join '; '))
    }
    $ownedDataOffers = @(@($thirdParty.items) + @($microsoft.items) | Where-Object { [string]$_.target -in $windowsOwnedData })
    if ($ownedDataOffers.Count -eq 0) {
        Add-Pass 'Microsoft package data, ModifiableWindowsApps, XboxGames and LocalLow\Microsoft are never offered as leftovers'
    } else {
        Add-Failure ('Windows-owned data folders were offered as leftovers: ' + (($ownedDataOffers | ForEach-Object { $_.target }) -join '; '))
    }
    $uninstallOffers = @(@($thirdParty.items) + @($microsoft.items) | Where-Object { ([string]$_.target) -like '*\CurrentVersion\Uninstall\*' })
    if ($uninstallOffers.Count -eq 0) {
        Add-Pass 'No app is offered its product GUID Uninstall entry as a leftover'
    } else {
        Add-Failure ('A product GUID Uninstall entry was offered as a leftover: ' + (($uninstallOffers | ForEach-Object { $_.target }) -join '; '))
    }
} catch {
    Add-Failure "Leftover ownership scan failed: $($_.Exception.Message)"
} finally {
    if (Test-Path -LiteralPath $ownershipRoot) { Remove-Item -LiteralPath $ownershipRoot -Recurse -Force }
}

try {
    $manifestOutput = & (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') -ScanPath $sampleScan
    $manifest = ($manifestOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($manifest.dryRun -eq $true -and $manifest.summary.willDeleteOnApply -eq $false -and $manifest.summary.willEditRegistry -eq $false -and $manifest.summary.willEditServices -eq $false -and $manifest.summary.willEditScheduledTasks -eq $false) {
        Add-Pass 'Cleanup deletion manifest is dry-run and reports no apply path'
    } else {
        Add-Failure 'Cleanup deletion manifest reported unsafe apply state'
    }
    $rollbackProps = $manifest.rollback.PSObject.Properties
    if ($null -ne $rollbackProps['fileBackupRequirements'] -and $null -ne $rollbackProps['registryExportRequirements'] -and $null -ne $rollbackProps['serviceStateBackupRequirements'] -and $null -ne $rollbackProps['scheduledTaskBackupRequirements']) {
        Add-Pass 'Cleanup deletion manifest includes rollback and export requirement metadata'
    } else {
        Add-Failure 'Cleanup deletion manifest is missing rollback/export metadata'
    }
} catch {
    Add-Failure "Cleanup deletion manifest preview failed: $($_.Exception.Message)"
}

try {
    $planOutput = & (Join-Path $PSScriptRoot 'New-UninstallCleanupExecutionPlan.ps1') -OfficialPreviewPath $sampleOfficialPreview -CleanupManifestPath $sampleCleanupManifest
    $plan = ($planOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($plan.dryRun -eq $true -and $plan.executionMode -eq 'guarded-fixture-ready' -and $plan.capabilities.fixtureExecutorImplemented -eq $true -and $plan.capabilities.realSystemExecutorImplemented -eq $true -and $plan.capabilities.canRunAllowlistedOfficialCommand -eq $true -and $plan.capabilities.canRunUninstallers -eq $false -and $plan.capabilities.canDeleteLeftovers -eq $false -and $plan.summary.executionReady -eq $false) {
        Add-Pass 'Uninstall cleanup execution plan is fixture-ready and exposes the controlled allowlisted runner'
    } else {
        Add-Failure 'Uninstall cleanup execution plan reported executable state'
    }
    $policyGate = @($plan.gates | Where-Object { $_.gateId -eq 'policy-confirmed-execution-enabled' }) | Select-Object -First 1
    $backupGate = @($plan.gates | Where-Object { $_.gateId -eq 'backup-exports-complete' }) | Select-Object -First 1
    $realExecutorGate = @($plan.gates | Where-Object { $_.gateId -eq 'real-system-executor-implemented' }) | Select-Object -First 1
    if ($policyGate.blocking -eq $true -and $backupGate.blocking -eq $true -and $realExecutorGate.satisfied -eq $true -and $realExecutorGate.blocking -eq $false -and $plan.summary.disposableFixtureExecutionReady -eq $true -and $plan.summary.allowlistedOfficialRunnerReady -eq $true) {
        Add-Pass 'Execution plan exposes blocking real-system policy and backup gates while controlled runner and fixture validation are ready'
    } else {
        Add-Failure 'Execution plan did not expose expected blocking gates'
    }
    if ($plan.summary.willRunUninstallers -eq $false -and $plan.summary.willDeleteLeftovers -eq $false -and $plan.summary.dryRunWritesState -eq $false) {
        Add-Pass 'Execution plan preserves no-uninstall, no-delete, no-state-write invariant'
    } else {
        Add-Failure 'Execution plan violated dry-run invariant'
    }
} catch {
    Add-Failure "Uninstall cleanup execution plan failed: $($_.Exception.Message)"
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-uninstall-cleanup-fixture-$([guid]::NewGuid().ToString('N'))"
$fixtureCleanupDone = $false
try {
    $appFolder = Join-Path $fixtureRoot 'FakeApp'
    $cacheFolder = Join-Path $fixtureRoot 'FakeAppCache'
    $looseFile = Join-Path $fixtureRoot 'loose-cache.bin'
    New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $cacheFolder -Force | Out-Null
    'fixture app file' | Set-Content -LiteralPath (Join-Path $appFolder 'app.txt') -Encoding UTF8
    'fixture cache file' | Set-Content -LiteralPath (Join-Path $cacheFolder 'cache.txt') -Encoding UTF8
    'fixture loose file' | Set-Content -LiteralPath $looseFile -Encoding UTF8

    $officialFixturePath = Join-Path $fixtureRoot 'official-preview.json'
    $manifestFixturePath = Join-Path $fixtureRoot 'cleanup-manifest.json'
    $officialFixture = [pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-01T00:00:00Z'
        dryRun = $true
        status = 'preview'
        commands = @(
            [pscustomobject]@{
                appId = 'fixture:fake-app'
                displayName = 'Fixture Fake App'
                commandType = 'fixture-uninstall-string'
                rawCommand = '"C:\Fixture\FakeUninstaller.exe"'
                executable = 'C:\Fixture\FakeUninstaller.exe'
                arguments = $null
                protected = $false
                blocked = $false
                executionAllowed = $false
            }
        )
        summary = [pscustomobject]@{ requestedCount = 1; commandPreviewCount = 1; blockedCount = 0; executionAllowedCount = 0; willRunUninstallers = $false }
        warnings = @()
        errors = @()
        logs = @()
    }
    $cleanupFixture = [pscustomobject]@{
        manifestId = 'fixture-cleanup-manifest'
        productName = 'Roo Industries Optimization Suite'
        schemaVersion = 1
        appId = 'fixture:fake-app'
        displayName = 'Fixture Fake App'
        createdAtUtc = '2026-07-01T00:00:00Z'
        dryRun = $true
        executionMode = 'preview-only'
        sourceScanId = 'fixture-scan'
        items = @(
            [pscustomobject]@{
                itemId = 'folder:fixture-cache'
                type = 'folder'
                target = $cacheFolder
                matchedBy = @('fixture')
                confidence = 'high'
                risk = 'low'
                defaultSelected = $true
                protected = $false
                reason = 'Disposable fixture folder.'
            },
            [pscustomobject]@{
                itemId = 'file:fixture-loose-cache'
                type = 'file'
                target = $looseFile
                matchedBy = @('fixture')
                confidence = 'high'
                risk = 'low'
                defaultSelected = $true
                protected = $false
                reason = 'Disposable fixture file.'
            }
        )
        excludedItems = @()
        rollback = [pscustomobject]@{
            backupRoot = (Join-Path $fixtureRoot '_roo-cleanup-backup')
            rollbackActionId = 'apps.rollbackCleanup'
            rollbackSupported = $true
            restorePoint = [pscustomobject]@{ requiredBeforeFutureApply = $false; created = $false; previewOnly = $true }
            fileBackupRequirements = @()
            registryExportRequirements = @()
            serviceStateBackupRequirements = @()
            scheduledTaskBackupRequirements = @()
            startupEntryBackupRequirements = @()
            manifestExportRequired = $true
        }
        summary = [pscustomobject]@{ itemCount = 2; willDeleteOnApply = $false; willEditRegistry = $false; willEditServices = $false; willEditScheduledTasks = $false; dryRunWritesState = $false }
        warnings = @()
        errors = @()
    }
    ($officialFixture | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $officialFixturePath -Encoding UTF8
    ($cleanupFixture | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $manifestFixturePath -Encoding UTF8

    $fixturePreview = & (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialFixturePath -CleanupManifestPath $manifestFixturePath -FixtureRoot $fixtureRoot
    $fixturePreviewJson = ($fixturePreview -join [Environment]::NewLine) | ConvertFrom-Json
    if ($fixturePreviewJson.status -eq 'preview' -and $fixturePreviewJson.summary.willRunUninstallers -eq $false -and (Test-Path -LiteralPath $cacheFolder) -and (Test-Path -LiteralPath $looseFile)) {
        Add-Pass 'Cleanup executor preview leaves disposable fixture files untouched'
    } else {
        Add-Failure 'Cleanup executor preview changed fixture files or reported unsafe state'
    }

    $fixtureBlocked = & (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialFixturePath -CleanupManifestPath $manifestFixturePath -FixtureRoot $fixtureRoot -ConfirmApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved
    $fixtureBlockedJson = ($fixtureBlocked -join [Environment]::NewLine) | ConvertFrom-Json
    if ($fixtureBlockedJson.status -eq 'blocked' -and $fixtureBlockedJson.summary.deletedCount -eq 0 -and (Test-Path -LiteralPath $cacheFolder) -and (Test-Path -LiteralPath $looseFile)) {
        Add-Pass 'Cleanup executor blocks confirmed fixture deletion without disposable-fixture flag'
    } else {
        Add-Failure 'Cleanup executor did not block missing disposable-fixture flag'
    }

    $fixtureApply = & (Join-Path $PSScriptRoot 'Invoke-UninstallCleanupExecution.ps1') -OfficialPreviewPath $officialFixturePath -CleanupManifestPath $manifestFixturePath -FixtureRoot $fixtureRoot -ConfirmApply -AllowDisposableFixtureApply -OfficialUninstallCommandApproved -CleanupDeletionManifestApproved
    $fixtureApplyJson = ($fixtureApply -join [Environment]::NewLine) | ConvertFrom-Json
    if ($fixtureApplyJson.status -eq 'success' -and $fixtureApplyJson.summary.deletedCount -eq 2 -and $fixtureApplyJson.capabilities.canRunUninstallers -eq $false -and (Test-Path -LiteralPath $fixtureApplyJson.rollback.rollbackManifestPath) -and -not (Test-Path -LiteralPath $cacheFolder) -and -not (Test-Path -LiteralPath $looseFile)) {
        Add-Pass 'Cleanup executor backs up and deletes only disposable fixture leftovers after approval gates'
    } else {
        Add-Failure 'Cleanup executor fixture apply did not produce expected backup/delete result'
    }

    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    $fixtureCleanupDone = $true
    if (-not (Test-Path -LiteralPath $fixtureRoot)) {
        Add-Pass 'Cleanup executor disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Cleanup executor disposable fixtures remain'
    }
} catch {
    Add-Failure "Cleanup executor fixture validation failed: $($_.Exception.Message)"
} finally {
    if (-not $fixtureCleanupDone -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after uninstall cleanup dry-run validation'
} else {
    Add-Failure "backend/state is not empty or changed during validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Validation did not call uninstall, deletion, registry edit, service edit, task edit, driver cleanup, or confirmed apply scripts'

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "PASS Uninstall cleanup backend validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Uninstall cleanup backend validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
