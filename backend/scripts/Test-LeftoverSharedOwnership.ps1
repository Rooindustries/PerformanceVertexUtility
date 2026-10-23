param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]
$evidence = [ordered]@{ schemaVersion = 1; test = 'leftover-shared-ownership'; scans = [ordered]@{} }
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = Join-Path $repoRoot 'artifacts\validation\leftover-shared-ownership.json' }

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

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Read-OwnershipScan {
    param([string]$Id, [string]$Name)
    $path = Join-Path $tempRoot ($Name + '-scan.json')
    $result = ((& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -AppId $Id -InventoryPath $inventoryPath -RulesPath $rulesPath -OutputPath $path) -join [Environment]::NewLine) | ConvertFrom-Json
    $evidence.scans[$Name] = $result
    return $result
}

$stateBefore = Get-StateEntryCount
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-leftover-shared-' + [guid]::NewGuid().ToString('N'))
try {
    $shared = Join-Path $tempRoot 'shared'
    $plugin = Join-Path $shared 'plugin'
    $distinct = Join-Path $tempRoot 'distinct'
    $distinctCache = Join-Path $distinct 'cache'
    $appData = Join-Path $tempRoot 'a-data'
    $quotedPeer = Join-Path $tempRoot 'quotedpeer'
    $quotedChild = Join-Path $quotedPeer 'sub'
    foreach ($folder in @($shared, $plugin, $distinctCache, $appData, $quotedChild)) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
    $peerFile = Join-Path $shared 'app-b-data.txt'
    [IO.File]::WriteAllText($peerFile, 'App B data must survive App A cleanup.')
    $peerHash = (Get-FileHash -LiteralPath $peerFile -Algorithm SHA256).Hash
    $environmentPath = Join-Path '%ProgramFiles%' 'RooIndustriesSharedOwnershipFixture'
    $apps = @(
        [pscustomobject]@{ appId = 'fixture:a'; displayName = 'App A'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $shared },
        [pscustomobject]@{ appId = 'fixture:b'; displayName = 'App B'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $shared },
        [pscustomobject]@{ appId = 'fixture:c'; displayName = 'App C'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $plugin },
        [pscustomobject]@{ appId = 'fixture:d'; displayName = 'App D'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $distinct },
        [pscustomobject]@{ appId = 'fixture:h'; displayName = 'App H'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = ('"' + $quotedPeer + [IO.Path]::DirectorySeparatorChar + '"') },
        [pscustomobject]@{ appId = 'fixture:i'; displayName = 'App I'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $quotedChild },
        [pscustomobject]@{ appId = 'fixture:g'; displayName = 'App G'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = ($tempRoot + [char]0 + 'invalid') },
        [pscustomobject]@{ appId = 'fixture:j'; displayName = 'App J'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $environmentPath }
    )
    $inventoryPath = Join-Path $tempRoot 'inventory.json'
    $inventory = [pscustomobject]@{ schemaVersion = 1; productName = 'Roo Industries Optimization Suite'; capturedAtUtc = [DateTime]::UtcNow.ToString('o'); summary = [pscustomobject]@{ appCount = $apps.Count }; apps = $apps }
    $inventory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $inventoryPath -Encoding UTF8
    $rules = Get-Content -LiteralPath (Join-Path $repoRoot 'backend\uninstall\leftover-scan-rules.json') -Raw | ConvertFrom-Json
    $rules.knownAppRules = @([pscustomobject]@{
        ruleId = 'roo-industries-shared-ownership'; match = [pscustomobject]@{ displayNamePatterns = @('App A') }
        knownAppDataPaths = @($distinctCache, $appData, $environmentPath)
        vendorRegistryKeys = @(); serviceNamePatterns = @(); scheduledTaskPatterns = @(); startupValuePatterns = @()
    })
    $rulesPath = Join-Path $tempRoot 'rules.json'
    $rules | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $rulesPath -Encoding UTF8
    $policy = Get-Content -LiteralPath (Join-Path $repoRoot 'backend\uninstall\uninstall-policy.json') -Raw | ConvertFrom-Json
    $policy.cleanupDeletion.backupRoot = Join-Path $tempRoot 'planned-backup'
    $policyPath = Join-Path $tempRoot 'policy.json'
    $policy | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $policyPath -Encoding UTF8
    $evidence.inventory = $inventory
    $evidence.scriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -Algorithm SHA256).Hash

    $incompleteInventoryPath = Join-Path $tempRoot 'incomplete-inventory.json'
    $incompleteScanPath = Join-Path $tempRoot 'incomplete-scan.json'
    $incompleteInventory = [pscustomobject]@{ schemaVersion = 1; complete = $false; errors = @('appx failed'); apps = @($apps[0]) }
    $incompleteInventory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $incompleteInventoryPath -Encoding UTF8
    $incompleteScan = ((& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -AppId 'fixture:a' -InventoryPath $incompleteInventoryPath -RulesPath $rulesPath -OutputPath $incompleteScanPath) -join [Environment]::NewLine) | ConvertFrom-Json
    $savedIncompleteScan = Get-Content -LiteralPath $incompleteScanPath -Raw | ConvertFrom-Json
    $incompleteManifest = ((& (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') -AppId 'fixture:a' -InventoryPath $incompleteInventoryPath -PolicyPath $policyPath) -join [Environment]::NewLine) | ConvertFrom-Json
    $evidence.scans['incomplete-inventory'] = $incompleteScan
    $evidence.incompleteInventory = $incompleteInventory
    $evidence.incompleteManifest = $incompleteManifest
    if (@($incompleteScan.errors).Count -eq 1 -and $incompleteScan.errors[0].code -eq 'LEFTOVER_SCAN_PREVIEW_FAILED' -and
        $incompleteScan.errors[0].message -eq 'The installed app list could not be read completely, so folders shared with other apps cannot be ruled out. Nothing was scanned. appx failed' -and
        @($incompleteScan.items).Count -eq 0 -and @($savedIncompleteScan.items).Count -eq 0 -and $savedIncompleteScan.summary.defaultSelectedCount -eq 0 -and
        @($incompleteManifest.errors).Count -eq 0 -and @($incompleteManifest.items).Count -eq 0 -and @($incompleteManifest.rollback.fileBackupRequirements).Count -eq 0 -and
        (Get-FileHash -LiteralPath $peerFile -Algorithm SHA256).Hash -eq $peerHash) {
        Add-Pass 'Incomplete inventory refuses direct scans and manifest rescans without writing a cleanup selection or changing peer bytes'
    } else { Add-Failure 'Incomplete inventory must refuse direct scans and manifest rescans without writing a cleanup selection or changing peer bytes' }

    foreach ($invalidComplete in @(
        [pscustomobject]@{ name = 'null'; value = $null },
        [pscustomobject]@{ name = 'string'; value = 'true' },
        [pscustomobject]@{ name = 'number'; value = 1 }
    )) {
        $invalidCompletePath = Join-Path $tempRoot ('complete-' + $invalidComplete.name + '-inventory.json')
        $invalidCompleteScanPath = Join-Path $tempRoot ('complete-' + $invalidComplete.name + '-scan.json')
        [pscustomobject]@{ schemaVersion = 1; complete = $invalidComplete.value; errors = @(); apps = @($apps[0]) } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $invalidCompletePath -Encoding UTF8
        $invalidCompleteScan = ((& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -AppId 'fixture:a' -InventoryPath $invalidCompletePath -OutputPath $invalidCompleteScanPath) -join [Environment]::NewLine) | ConvertFrom-Json
        $savedInvalidCompleteScan = Get-Content -LiteralPath $invalidCompleteScanPath -Raw | ConvertFrom-Json
        $evidence.scans['complete-' + $invalidComplete.name] = $invalidCompleteScan
        if (@($invalidCompleteScan.errors).Count -eq 1 -and
            $invalidCompleteScan.errors[0].message -eq 'The installed app list could not be read completely, so folders shared with other apps cannot be ruled out. Nothing was scanned.' -and
            @($invalidCompleteScan.items).Count -eq 0 -and @($savedInvalidCompleteScan.items).Count -eq 0 -and $savedInvalidCompleteScan.summary.defaultSelectedCount -eq 0) {
            Add-Pass "Inventory complete=$($invalidComplete.name) is refused without writing a cleanup selection"
        } else { Add-Failure "Inventory complete=$($invalidComplete.name) must be refused without writing a cleanup selection" }
    }

    $scanA = Read-OwnershipScan 'fixture:a' 'a'
    $sharedItem = @($scanA.items | Where-Object { $_.target -eq $shared })
    if ($sharedItem.Count -eq 1 -and $sharedItem[0].protected -and -not $sharedItem[0].defaultSelected -and
        @($sharedItem[0].metadata.sharedOwners) -contains 'App B' -and @($sharedItem[0].metadata.sharedOwners) -contains 'App C' -and
        @($sharedItem[0].metadata.sharedOwners) -notcontains 'App A' -and $sharedItem[0].reason.StartsWith('Also used by')) {
        Add-Pass 'Scan A protects the shared folder with B and C as owners and excludes A itself'
    } else { Add-Failure 'Scan A must protect the shared folder with B and C as owners and exclude A itself' }
    $cacheItem = @($scanA.items | Where-Object { $_.target -eq $distinctCache })
    if ($cacheItem.Count -eq 1 -and $cacheItem[0].protected -and -not $cacheItem[0].defaultSelected -and @($cacheItem[0].metadata.sharedOwners) -contains 'App D') {
        Add-Pass 'Scan A protects a known data path inside D installation'
    } else { Add-Failure 'Scan A must protect a known data path inside D installation' }
    $dataItem = @($scanA.items | Where-Object { $_.target -eq $appData })
    if ($dataItem.Count -eq 1 -and -not $dataItem[0].protected -and $dataItem[0].defaultSelected -and @($dataItem[0].metadata.sharedOwners | Where-Object { $null -ne $_ }).Count -eq 0) {
        Add-Pass 'Scan A keeps its unshared data folder default selected'
    } else { Add-Failure 'Scan A must keep its unshared data folder default selected' }
    if (@($scanA.errors).Count -eq 0) { Add-Pass 'Scan A completes without errors with the invalid G peer present' }
    else { Add-Failure 'Scan A must complete without errors with the invalid G peer present' }
    $environmentItem = @($scanA.items | Where-Object { $_.target -like '*RooIndustriesSharedOwnershipFixture' })
    if ($environmentItem.Count -eq 1 -and $environmentItem[0].protected -and -not $environmentItem[0].defaultSelected -and
        @($environmentItem[0].metadata.sharedOwners) -contains 'App J' -and $environmentItem[0].target -notlike '*%ProgramFiles%*') {
        Add-Pass 'Scan A expands the ProgramFiles peer before checking shared ownership'
    } else { Add-Failure 'Scan A must expand the ProgramFiles peer before checking shared ownership' }

    $manifest = ((& (Join-Path $PSScriptRoot 'New-CleanupDeletionManifest.ps1') -ScanPath (Join-Path $tempRoot 'a-scan.json') -ItemId $sharedItem[0].itemId -PolicyPath $policyPath) -join [Environment]::NewLine) | ConvertFrom-Json
    $evidence.manifest = $manifest
    $evidence.peerHashBefore = $peerHash
    $evidence.peerHashAfter = (Get-FileHash -LiteralPath $peerFile -Algorithm SHA256).Hash
    if (@($manifest.errors).Count -eq 0 -and @($manifest.items).Count -eq 0 -and @($manifest.rollback.fileBackupRequirements).Count -eq 0 -and
        $evidence.peerHashAfter -eq $peerHash) {
        Add-Pass 'Explicitly selecting the shared item creates no cleanup or backup entry and preserves B bytes'
    } else { Add-Failure 'Explicitly selecting the shared item must create no cleanup or backup entry and preserve B bytes' }

    $scanC = Read-OwnershipScan 'fixture:c' 'c'
    $pluginItem = @($scanC.items | Where-Object { $_.target -eq $plugin })
    if (@($scanC.errors).Count -eq 0 -and $pluginItem.Count -eq 1 -and $pluginItem[0].protected -and -not $pluginItem[0].defaultSelected -and
        @($pluginItem[0].metadata.sharedOwners) -contains 'App A' -and @($pluginItem[0].metadata.sharedOwners) -contains 'App B') {
        Add-Pass 'Scan C protects its folder inside the A and B installation'
    } else { Add-Failure 'Scan C must protect its folder inside the A and B installation' }
    $scanI = Read-OwnershipScan 'fixture:i' 'i'
    $quotedItem = @($scanI.items | Where-Object { $_.target -eq $quotedChild })
    if (@($scanI.errors).Count -eq 0 -and $quotedItem.Count -eq 1 -and $quotedItem[0].protected -and -not $quotedItem[0].defaultSelected -and
        @($quotedItem[0].metadata.sharedOwners) -contains 'App H') {
        Add-Pass 'Scan I protects its folder under the quoted trailing-separator H peer'
    } else { Add-Failure 'Scan I must protect its folder under the quoted trailing-separator H peer' }
    $scanD = Read-OwnershipScan 'fixture:d' 'd'
    $distinctItem = @($scanD.items | Where-Object { $_.target -eq $distinct })
    if (@($scanD.errors).Count -eq 0 -and $distinctItem.Count -eq 1 -and -not $distinctItem[0].protected -and $distinctItem[0].defaultSelected -and
        @($distinctItem[0].metadata.sharedOwners | Where-Object { $null -ne $_ }).Count -eq 0) {
        Add-Pass 'Scan D keeps its distinct folder default selected with the invalid G peer present'
    } else { Add-Failure 'Scan D must keep its distinct folder default selected with the invalid G peer present' }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $realRoot = Join-Path $tempRoot 'real'
        $realShared = Join-Path $realRoot 'Shared'
        $aliasRoot = Join-Path $tempRoot 'alias'
        [IO.Directory]::CreateDirectory($realShared) | Out-Null
        $junctionCreated = $false
        try {
            New-Item -ItemType Junction -Path $aliasRoot -Target $realRoot -ErrorAction Stop | Out-Null
            $junctionCreated = $true
            $junctionInventoryPath = Join-Path $tempRoot 'junction-inventory.json'
            [pscustomobject]@{ schemaVersion = 1; complete = $true; apps = @(
                [pscustomobject]@{ appId = 'fixture:a'; displayName = 'App A'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $realShared },
                [pscustomobject]@{ appId = 'fixture:b'; displayName = 'App B'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = (Join-Path $aliasRoot 'Shared') }
            ) } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $junctionInventoryPath -Encoding UTF8
            $junctionScan = ((& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -AppId 'fixture:a' -InventoryPath $junctionInventoryPath -RulesPath $rulesPath) -join [Environment]::NewLine) | ConvertFrom-Json
            $junctionItem = @($junctionScan.items | Where-Object { $_.target -eq $realShared })
            $evidence.scans['junction-alias'] = $junctionScan
            if (@($junctionScan.errors).Count -eq 0 -and $junctionItem.Count -eq 1 -and $junctionItem[0].protected -and
                -not $junctionItem[0].defaultSelected -and @($junctionItem[0].metadata.sharedOwners) -contains 'App B') {
                Add-Pass 'A peer installed through a junction protects the real shared folder from default selection'
            } else { Add-Failure 'A peer installed through a junction must protect the real shared folder from default selection' }
        } finally {
            if ($junctionCreated) { [IO.Directory]::Delete($aliasRoot) }
        }

        $spellingApps = Join-Path $tempRoot 'Long Spelling Apps'
        $protectedRoot = Join-Path $tempRoot 'Protected Spelling Root'
        $protectedData = Join-Path $protectedRoot 'Vendor Spelling Data'
        foreach ($folder in @($spellingApps, $protectedData)) { [IO.Directory]::CreateDirectory($folder) | Out-Null }
        $fileSystem = New-Object -ComObject Scripting.FileSystemObject
        foreach ($pair in @(@($spellingApps, 'LONGSP~1'), @($protectedRoot, 'PROTEC~1'), @($protectedData, 'VENDOR~1'))) {
            if ([IO.Path]::GetFileName($fileSystem.GetFolder($pair[0]).ShortPath) -ieq [IO.Path]::GetFileName($pair[0])) { & fsutil.exe file setshortname $pair[0] $pair[1] | Out-Null }
        }
        $appsShort = $fileSystem.GetFolder($spellingApps).ShortPath
        $protectedShort = $fileSystem.GetFolder($protectedData).ShortPath
        if ([IO.Path]::GetFileName($appsShort) -ine [IO.Path]::GetFileName($spellingApps) -and [IO.Path]::GetFileName($protectedShort) -ine [IO.Path]::GetFileName($protectedData)) {
            Add-Pass 'Disposable spelling fixtures have actual 8.3 aliases'
        } else { Add-Failure 'Disposable spelling fixtures must have actual 8.3 aliases' }
        $spellingRules = $rules | ConvertTo-Json -Depth 16 | ConvertFrom-Json
        $spellingRules.protectedPaths = @($spellingRules.protectedPaths) + @([pscustomobject]@{ pathPattern = (Get-RooIndustriesFinalPath $protectedRoot) + '*'; reason = 'Disposable protected fixture.' })
        $missingLong = Join-Path $spellingApps 'Missing Spelling Peer\cache'
        $spellingRules.knownAppRules[0].knownAppDataPaths = @($protectedShort, $missingLong)
        $spellingRulesPath = Join-Path $tempRoot 'spelling-rules.json'
        $spellingRules | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $spellingRulesPath -Encoding UTF8
        $spellingInventoryPath = Join-Path $tempRoot 'spelling-inventory.json'
        [pscustomobject]@{ schemaVersion = 1; complete = $true; apps = @(
            [pscustomobject]@{ appId = 'fixture:a'; displayName = 'App A'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = $appData },
            [pscustomobject]@{ appId = 'fixture:k'; displayName = 'App K'; sourceType = 'registry'; risk = 'low'; protected = $false; installLocation = (Join-Path $appsShort 'Missing Spelling Peer') }
        ) } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $spellingInventoryPath -Encoding UTF8
        $spellingScan = ((& (Join-Path $PSScriptRoot 'Preview-LeftoverScan.ps1') -AppId 'fixture:a' -InventoryPath $spellingInventoryPath -RulesPath $spellingRulesPath) -join [Environment]::NewLine) | ConvertFrom-Json
        $evidence.scans['short-name-spelling'] = $spellingScan
        $protectedItem = @($spellingScan.items | Where-Object { $_.target -eq $protectedShort })
        $missingItem = @($spellingScan.items | Where-Object { $_.target -eq $missingLong })
        if (@($spellingScan.errors).Count -eq 0 -and $protectedItem.Count -eq 1 -and $protectedItem[0].protected -and -not $protectedItem[0].defaultSelected) {
            Add-Pass 'A protected folder given by its 8.3 short name stays protected'
        } else { Add-Failure 'A protected folder given by its 8.3 short name must stay protected' }
        if ($missingItem.Count -eq 1 -and $missingItem[0].protected -and -not $missingItem[0].defaultSelected -and @($missingItem[0].metadata.sharedOwners) -contains 'App K') {
            Add-Pass 'A missing peer folder recorded through a short parent keeps its long-named folder shared'
        } else { Add-Failure 'A missing peer folder recorded through a short parent must keep its long-named folder shared' }
    } else {
        Write-Host 'SKIP Shared-folder junction resolution requires Windows.'
    }

    $peerName = 'App B shared ownership fixture ' + [guid]::NewGuid().ToString('N')
    $peerKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + [guid]::NewGuid().ToString('N')
    $peerRegistered = $false
    try {
        $peerKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($peerKeyPath)
        $peerRegistered = $true
        try {
            $peerKey.SetValue('DisplayName', $peerName, [Microsoft.Win32.RegistryValueKind]::String)
            $peerKey.SetValue('InstallLocation', $shared, [Microsoft.Win32.RegistryValueKind]::String)
        } finally { $peerKey.Dispose() }
        $journalPath = Join-Path $tempRoot 'removal-journal.json'
        Write-RooIndustriesOperationJson @{
            schemaVersion = 1; kind = 'bulk-uninstall-journal'
            plan = @{
                owner = Get-RooIndustriesOperationOwner; fixtureRoot = $tempRoot
                entries = @(@{ appId = 'fixture:a'; displayName = 'App A'; protected = $false; appSnapshot = $apps[0]
                    identity = @{ kind = 'fixture'; presencePath = (Join-Path $tempRoot 'removed-a.present') } })
            }
            entries = @(@{ appId = 'fixture:a'; state = 'removed'; registrationAbsent = $true })
        } $journalPath
        $removalScan = ((& (Join-Path $PSScriptRoot 'Invoke-RemovalLeftovers.ps1') -Action Scan -QueueJournalPath $journalPath -AppId 'fixture:a') -join [Environment]::NewLine) | ConvertFrom-Json
        $removalItem = @($removalScan.data.items | Where-Object { $_.target -eq $shared })
        $evidence.scans['post-removal-live-peer'] = $removalScan
        $evidence.removalScriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Invoke-RemovalLeftovers.ps1') -Algorithm SHA256).Hash
        if ($removalScan.status -eq 'preview' -and @($removalScan.errors).Count -eq 0 -and $removalItem.Count -eq 1 -and
            $removalItem[0].protected -and -not $removalItem[0].defaultSelected -and
            @($removalItem[0].metadata.sharedOwners) -contains $peerName -and (Get-FileHash -LiteralPath $peerFile -Algorithm SHA256).Hash -eq $peerHash) {
            Add-Pass 'Post-removal scan protects the removed app folder shared with a currently installed HKCU peer'
        } else { Add-Failure 'Post-removal scan must protect the removed app folder shared with a currently installed HKCU peer' }
    } finally { if ($peerRegistered) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($peerKeyPath, $false) } }
} catch {
    Add-Failure "Leftover shared ownership validation failed: $($_.Exception.Message)"
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

if (-not (Test-Path -LiteralPath $tempRoot)) { Add-Pass 'Leftover shared ownership disposable fixtures were cleaned up' }
else { Add-Failure 'Leftover shared ownership disposable fixtures remain' }
$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) { Add-Pass 'backend/state remains empty after leftover shared ownership validation' }
else { Add-Failure "backend/state changed during leftover shared ownership validation: before=$stateBefore after=$stateAfter" }
$evidence.passes = @($passes.ToArray())
$evidence.failures = @($failures.ToArray())
$evidence.stateBefore = $stateBefore
$evidence.stateAfter = $stateAfter
$evidence.fixturesRemoved = -not (Test-Path -LiteralPath $tempRoot)
[IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($EvidencePath)) -Parent)) | Out-Null
$evidence | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
Write-Host "Evidence: $EvidencePath"
if ($failures.Count -eq 0) {
    Write-Host "PASS Leftover shared ownership validation completed. $($passes.Count) checks passed."
    exit 0
}
Write-Host "FAIL Leftover shared ownership validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
