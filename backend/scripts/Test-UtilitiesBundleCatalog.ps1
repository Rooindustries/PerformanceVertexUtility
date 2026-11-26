param(
    [string]$CatalogPath,
    [string]$ManifestPath,
    [string]$SamplePath,
    [string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$passes = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $repoRoot 'backend\catalogs\utilities-bundle-catalog.json' }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $repoRoot 'modules\utilities_manifest.json' }
if ([string]::IsNullOrWhiteSpace($SamplePath)) { $SamplePath = Join-Path $repoRoot 'backend\samples\utilities-bundle-inventory.sample.json' }

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

function Add-Check {
    param(
        [bool]$Condition,
        [string]$PassMessage,
        [string]$FailureMessage
    )

    if ($Condition) {
        Add-Pass $PassMessage
    } else {
        Add-Failure $FailureMessage
    }
}

function Has-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if (-not (Has-Property $Object $Name)) { return $Default }
    return $Object.PSObject.Properties[$Name].Value
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "$Label missing: $Path"
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Add-Pass "$Label parses as JSON"
        return $json
    } catch {
        Add-Failure "$Label JSON parse failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Get-OptionalArchivePath {
    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        return [System.IO.Path]::GetFullPath($ArchivePath)
    }

    $repoArchive = Join-Path $repoRoot 'vendor\Utilities.zip'
    if (Test-Path -LiteralPath $repoArchive -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($repoArchive)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ROO_INDUSTRIES_UTILITIES_ARCHIVE)) {
        return [System.IO.Path]::GetFullPath($env:ROO_INDUSTRIES_UTILITIES_ARCHIVE)
    }

    return ''
}

function Test-ManifestDecision {
    param(
        [object]$Manifest,
        [string]$Id,
        [string]$ExpectedClass,
        [bool]$ExpectedAutoRun,
        [string]$ExpectedArchivePath
    )

    $tools = @((Get-PropertyValue $Manifest 'tools' @()) | Where-Object { [string](Get-PropertyValue $_ 'id' '') -eq $Id })
    Add-Check ($tools.Count -eq 1) "Utilities manifest contains $Id" "Utilities manifest missing or duplicates $Id"
    if ($tools.Count -ne 1) { return }

    $tool = $tools[0]
    Add-Check ([string](Get-PropertyValue $tool 'executionClass' '') -eq $ExpectedClass) "$Id executionClass is $ExpectedClass" "$Id executionClass expected $ExpectedClass actual $([string](Get-PropertyValue $tool 'executionClass' ''))"
    Add-Check ((Get-PropertyValue $tool 'autoRunAllowed' $null) -eq $ExpectedAutoRun) "$Id autoRunAllowed is $ExpectedAutoRun" "$Id autoRunAllowed expected $ExpectedAutoRun actual $((Get-PropertyValue $tool 'autoRunAllowed' $null))"
    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tool 'integrationPlan' ''))) "$Id has integrationPlan" "$Id missing integrationPlan"
    Add-Check (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $tool 'risk' ''))) "$Id has risk" "$Id missing risk"

    if (-not [string]::IsNullOrWhiteSpace($ExpectedArchivePath)) {
        $archivePaths = @((Get-PropertyValue $tool 'archivePaths' @()) | ForEach-Object { [string]$_ })
        Add-Check ($archivePaths -contains $ExpectedArchivePath) "$Id covers expected archive path" "$Id missing archive path $ExpectedArchivePath"
    }
}

function Test-CatalogTool {
    param(
        [object[]]$Entries,
        [string]$ToolId,
        [int]$MinimumCount,
        [string]$ExpectedClass
    )

    $matches = @($Entries | Where-Object { [string](Get-PropertyValue $_ 'toolId' '') -eq $ToolId })
    Add-Check ($matches.Count -ge $MinimumCount) "Catalog covers $ToolId with $($matches.Count) entry/entries" "Catalog expected at least $MinimumCount entry/entries for $ToolId, found $($matches.Count)"
    $badClassMatches = @($matches | Where-Object { [string](Get-PropertyValue $_ 'executionClass' '') -ne $ExpectedClass })
    Add-Check ($badClassMatches.Count -eq 0) "Catalog $ToolId entries use executionClass $ExpectedClass" "Catalog $ToolId executionClass mismatch at $((@($badClassMatches | ForEach-Object { [string](Get-PropertyValue $_ 'archivePath' '') })) -join ', ')"
}

function Test-ArchiveExecutableCoverage {
    param(
        [string]$ResolvedArchivePath,
        [object]$Catalog
    )

    if ([string]::IsNullOrWhiteSpace($ResolvedArchivePath) -or -not (Test-Path -LiteralPath $ResolvedArchivePath -PathType Leaf)) {
        Add-Pass 'Live Utilities.zip comparison skipped because no archive path was available'
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ResolvedArchivePath)
    try {
        $fileEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        $execExts = @('.exe', '.msi', '.msu', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.js', '.reg')
        $archiveExecutablePaths = @($fileEntries |
            Where-Object { $execExts -contains ([System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant()) } |
            ForEach-Object { $_.FullName -replace '/', '\' } |
            Sort-Object)
        $catalogExecutablePaths = @((Get-PropertyValue $Catalog 'catalogEntries' @()) |
            Where-Object { [string](Get-PropertyValue $_ 'entryKind' '') -eq 'executable-script' } |
            ForEach-Object { [string](Get-PropertyValue $_ 'archivePath' '') } |
            Sort-Object)

        Add-Check ((Get-Item -LiteralPath $ResolvedArchivePath).Length -eq [uint64](Get-PropertyValue $Catalog 'sourceArchiveSizeBytes' 0)) 'Catalog sourceArchiveSizeBytes matches live archive' 'Catalog sourceArchiveSizeBytes does not match live archive'
        Add-Check ($fileEntries.Count -eq [int](Get-PropertyValue $Catalog 'entryCount' 0)) 'Catalog entryCount matches live archive' "Catalog entryCount mismatch: live=$($fileEntries.Count) catalog=$([int](Get-PropertyValue $Catalog 'entryCount' 0))"
        Add-Check ($archiveExecutablePaths.Count -eq [int](Get-PropertyValue $Catalog 'executableScriptCount' 0)) 'Catalog executableScriptCount matches live archive' "Catalog executableScriptCount mismatch: live=$($archiveExecutablePaths.Count) catalog=$([int](Get-PropertyValue $Catalog 'executableScriptCount' 0))"

        $diff = @(Compare-Object -ReferenceObject $archiveExecutablePaths -DifferenceObject $catalogExecutablePaths)
        Add-Check ($diff.Count -eq 0) 'Catalog covers every executable/script archive path exactly' "Executable/script catalog path mismatch: $((@($diff | ForEach-Object { $_.SideIndicator + ':' + $_.InputObject })) -join ', ')"
    } finally {
        $zip.Dispose()
    }
}

$stateBefore = Get-StateEntryCount
Add-Check ($stateBefore -eq 0) 'backend/state is absent or empty before utilities catalog validation' "backend/state is not empty before utilities catalog validation: $stateBefore item(s)"

$catalog = Read-JsonFile $CatalogPath 'Utilities bundle catalog'
$manifest = Read-JsonFile $ManifestPath 'Utilities manifest'
$sample = Read-JsonFile $SamplePath 'Utilities bundle inventory sample'

if ($null -ne $catalog) {
    $entries = @((Get-PropertyValue $catalog 'catalogEntries' @()))
    $requiredEntryFields = @(
        'archivePath',
        'normalizedId',
        'toolId',
        'displayName',
        'category',
        'risk',
        'productRole',
        'executionClass',
        'allowedExecutionMode',
        'hardwareGates',
        'restoreBackupRequirement',
        'integrationPlan'
    )
    $allowedExecutionClasses = @('native-replacement', 'manual-launcher', 'read-only-detector', 'controlled-reversible-executor', 'dangerous-manual-only', 'excluded')

    Add-Check ([string](Get-PropertyValue $catalog 'sourceArchive' '') -eq 'vendor\Utilities.zip') 'Catalog sourceArchive is repo-relative' 'Catalog sourceArchive is not repo-relative'
    Add-Check ((Get-PropertyValue (Get-PropertyValue $catalog 'sourceBoundary' $null) 'archiveMetadataOnly' $false) -eq $true) 'Catalog boundary is archive metadata only' 'Catalog boundary does not state metadata-only inventory'
    Add-Check ((Get-PropertyValue (Get-PropertyValue $catalog 'sourceBoundary' $null) 'utilityExecutionAllowed' $true) -eq $false) 'Catalog forbids utility execution' 'Catalog does not forbid utility execution'
    Add-Check ((Get-PropertyValue (Get-PropertyValue $catalog 'sourceBoundary' $null) 'fullExtractionAllowed' $true) -eq $false) 'Catalog forbids full extraction' 'Catalog does not forbid full extraction'
    Add-Check ([uint64](Get-PropertyValue $catalog 'sourceArchiveSizeBytes' 0) -eq [uint64]3734508425) 'Catalog records expected Utilities.zip size' 'Catalog source archive size drifted from captured Utilities.zip'
    Add-Check ([int](Get-PropertyValue $catalog 'entryCount' 0) -eq 770) 'Catalog records 770 archive entries' "Catalog entryCount expected 770 actual $([int](Get-PropertyValue $catalog 'entryCount' 0))"
    Add-Check ([int](Get-PropertyValue $catalog 'executableScriptCount' 0) -eq 55) 'Catalog records 55 executable/script entries' "Catalog executableScriptCount expected 55 actual $([int](Get-PropertyValue $catalog 'executableScriptCount' 0))"
    Add-Check ([int](Get-PropertyValue $catalog 'catalogedEntryCount' 0) -eq $entries.Count) 'Catalog catalogedEntryCount matches entries array' 'Catalog catalogedEntryCount does not match entries array'
    Add-Check ($entries.Count -gt 55) 'Catalog includes executable/script plus config/payload metadata entries' 'Catalog only covers executable/script entries'

    $missingFieldHits = New-Object System.Collections.Generic.List[string]
    $invalidExecutionClassHits = New-Object System.Collections.Generic.List[string]
    $autoRunRiskHits = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        $path = [string](Get-PropertyValue $entry 'archivePath' '')
        foreach ($field in $requiredEntryFields) {
            $value = Get-PropertyValue $entry $field $null
            $hasValue = $null -ne $value
            if ($value -is [string]) { $hasValue = -not [string]::IsNullOrWhiteSpace($value) }
            if ($field -eq 'hardwareGates') { $hasValue = @($value).Count -gt 0 }
            if (-not $hasValue) {
                $missingFieldHits.Add("$path missing $field") | Out-Null
            }
        }

        $executionClass = [string](Get-PropertyValue $entry 'executionClass' '')
        if ($allowedExecutionClasses -notcontains $executionClass) {
            $invalidExecutionClassHits.Add("$path invalid executionClass $executionClass") | Out-Null
        }
        if ([string](Get-PropertyValue $entry 'risk' '') -in @('high', 'critical')) {
            $mode = [string](Get-PropertyValue $entry 'allowedExecutionMode' '')
            if ($mode -in @('auto-run', 'automatic', 'silent-auto-run')) {
                $autoRunRiskHits.Add("$path allowedExecutionMode=$mode") | Out-Null
            }
        }
    }

    Add-Check ($missingFieldHits.Count -eq 0) "All $($entries.Count) catalog entries carry required fields" "Catalog entries missing required fields: $($missingFieldHits -join '; ')"
    Add-Check ($invalidExecutionClassHits.Count -eq 0) "All $($entries.Count) catalog entries use allowed executionClass values" "Catalog entries with invalid executionClass values: $($invalidExecutionClassHits -join '; ')"
    Add-Check ($autoRunRiskHits.Count -eq 0) 'No high-risk or critical catalog entry is auto-runnable' "High-risk or critical entries appear auto-runnable: $($autoRunRiskHits -join '; ')"

    Test-CatalogTool $entries 'afftool-intpolicy' 3 'read-only-detector'
    Test-CatalogTool $entries 'msi-util-v3' 1 'read-only-detector'
    Test-CatalogTool $entries 'inspectre' 1 'read-only-detector'
    Test-CatalogTool $entries 'unparkcpu' 1 'native-replacement'
    Test-CatalogTool $entries 'latencymon' 1 'read-only-detector'
    Test-CatalogTool $entries 'msi-kombustor' 1 'dangerous-manual-only'
    Test-CatalogTool $entries 'scewin' 1 'dangerous-manual-only'
    Test-CatalogTool $entries 'driver-booster' 1 'excluded'
    Test-CatalogTool $entries 'amd-graphics-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'amd-chipset-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'intel-chipset-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'nvidia-59579-no-app' 1 'manual-launcher'
    Test-CatalogTool $entries 'nvidia-59579-with-app' 1 'manual-launcher'
    Test-CatalogTool $entries 'realtek-network-driver' 1 'manual-launcher'
    Test-CatalogTool $entries 'directx-runtime' 1 'manual-launcher'
    Test-CatalogTool $entries 'vcredist-runtime' 1 'manual-launcher'
    Test-CatalogTool $entries 'intel-proset-setupbd' 1 'manual-launcher'
    Test-CatalogTool $entries 'intel-proset-prounstl' 1 'dangerous-manual-only'

    Test-ArchiveExecutableCoverage (Get-OptionalArchivePath) $catalog
}

if ($null -ne $manifest) {
    $allowedManifestClasses = @('native-replacement', 'manual-launcher', 'read-only-detector', 'controlled-reversible-executor', 'dangerous-manual-only', 'excluded')
    foreach ($tool in @((Get-PropertyValue $manifest 'tools' @()))) {
        $id = [string](Get-PropertyValue $tool 'id' '<missing>')
        $class = [string](Get-PropertyValue $tool 'executionClass' '')
        Add-Check ($allowedManifestClasses -contains $class) "Manifest $id uses allowed executionClass" "Manifest $id has invalid executionClass $class"
        Add-Check (@((Get-PropertyValue $tool 'archivePaths' @())).Count -gt 0) "Manifest $id has archive path coverage" "Manifest $id missing archivePaths"
        if ($class -in @('dangerous-manual-only', 'excluded')) {
            Add-Check ((Get-PropertyValue $tool 'autoRunAllowed' $null) -eq $false) "Manifest $id cannot auto-run" "Manifest $id is dangerous/excluded but autoRunAllowed is not false"
        }
    }

    Test-ManifestDecision $manifest 'afftool-intpolicy' 'read-only-detector' $false 'Utilities/AffTool/intPolicy_x64.exe'
    Test-ManifestDecision $manifest 'msi-util-v3' 'read-only-detector' $false 'Utilities/Stock Only (otherwise not necessary)/MSI_util_v3.exe'
    Test-ManifestDecision $manifest 'inspectre' 'read-only-detector' $false 'Utilities/Stock Only (otherwise not necessary)/InSpectre.exe'
    Test-ManifestDecision $manifest 'unparkcpu' 'native-replacement' $false 'Utilities/Stock Only (otherwise not necessary)/UnparkCpu.exe'
    Test-ManifestDecision $manifest 'latencymon' 'read-only-detector' $false 'Utilities/LatencyMon.exe'
    Test-ManifestDecision $manifest 'msi-kombustor' 'dangerous-manual-only' $false 'Utilities/MSI_Kombustor4_Setup_v4.1.36_x64.exe'
    Test-ManifestDecision $manifest 'scewin' 'dangerous-manual-only' $false 'Utilities/DL_SCEWIN.exe'
    Test-ManifestDecision $manifest 'driver-booster' 'excluded' $false 'Utilities/Drivers/driver_booster_setup.exe'
    Test-ManifestDecision $manifest 'amd-graphics-26-2-2' 'manual-launcher' $false 'Utilities/Drivers/Graphics/AMD 26.2.2.exe'
    Test-ManifestDecision $manifest 'amd-chipset-8-02-18-557' 'manual-launcher' $false 'Utilities/Drivers/Chipset/AMD CHIPSET 8.02.18.557.exe'
    Test-ManifestDecision $manifest 'intel-chipset' 'manual-launcher' $false 'Utilities/Drivers/Chipset/Intel Chipset.exe'
    Test-ManifestDecision $manifest 'nvidia-59579-no-app' 'manual-launcher' $false 'Utilities/Drivers/Graphics/NVIDIA_595.79_NO_Nvidia_App.exe'
    Test-ManifestDecision $manifest 'nvidia-59579-with-app' 'manual-launcher' $false 'Utilities/Drivers/Graphics/NVIDIA_595.79_With_Nvidia_App.exe'
    Test-ManifestDecision $manifest 'intel-network' 'manual-launcher' $false 'Utilities/Drivers/Network/Intel Network/SetupBD.exe'
    Test-ManifestDecision $manifest 'realtek-network' 'manual-launcher' $false 'Utilities/Drivers/Network/Realtek Network/Install_PCIE_Win11_11027_20_0920_DMAROFF_11282025.exe'
    Test-ManifestDecision $manifest 'intel-proset-setupbd' 'manual-launcher' $false 'Utilities/Drivers/Network/Intel Network/SetupBD.exe'
    Test-ManifestDecision $manifest 'intel-proset-prounstl' 'dangerous-manual-only' $false 'Utilities/Drivers/Network/Intel Network/PRO1000/Winx64/NDIS65/PROUnstl.exe'
    Test-ManifestDecision $manifest 'directx-runtime' 'manual-launcher' $false 'Utilities/Prerequisites/DX/DXSETUP.exe'
    Test-ManifestDecision $manifest 'vcredist-runtime' 'manual-launcher' $false 'Utilities/Prerequisites/VCRedist/install_all.bat'
}

if ($null -ne $sample) {
    $sampleText = Get-Content -LiteralPath $SamplePath -Raw
    Add-Check ($sampleText -notmatch 'C:\\Users\\') 'Utilities sample contains no private absolute user paths' 'Utilities sample contains a private absolute user path'
    Add-Check ([string](Get-PropertyValue $sample 'sourceArchive' '') -eq 'vendor\Utilities.zip') 'Utilities sample sourceArchive is repo-relative' 'Utilities sample sourceArchive is not repo-relative'
    Add-Check ([int](Get-PropertyValue $sample 'entryCount' 0) -eq 770) 'Utilities sample entryCount matches captured archive' 'Utilities sample entryCount mismatch'
    Add-Check ([int](Get-PropertyValue $sample 'executableScriptCount' 0) -eq 55) 'Utilities sample executableScriptCount matches captured archive' 'Utilities sample executableScriptCount mismatch'
}

$stateAfter = Get-StateEntryCount
Add-Check ($stateAfter -eq 0) 'backend/state is absent or empty after utilities catalog validation' "backend/state is not empty after utilities catalog validation: $stateAfter item(s)"
Add-Check ($stateBefore -eq $stateAfter) "backend/state item count unchanged at $stateAfter" "backend/state item count changed: before=$stateBefore after=$stateAfter"

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Utilities bundle catalog validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Utilities bundle catalog validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
