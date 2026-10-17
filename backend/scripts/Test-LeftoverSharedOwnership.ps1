param([string]$EvidencePath = '')

$ErrorActionPreference = 'Stop'
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
