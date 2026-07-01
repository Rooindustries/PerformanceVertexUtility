param(
    [string]$CatalogPath,
    [string]$SamplePath,
    [string]$UtilityManifestPath,
    [string]$NipSourcePath,
    [string]$NvpiExecutablePath,
    [string]$ReferenceXmlPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $repoRoot 'backend\catalogs\nvidia-profile-inspector-nip-catalog.json' }
if ([string]::IsNullOrWhiteSpace($SamplePath)) { $SamplePath = Join-Path $repoRoot 'backend\samples\nvidia-profile-catalog.sample.json' }
if ([string]::IsNullOrWhiteSpace($UtilityManifestPath)) { $UtilityManifestPath = Join-Path $repoRoot 'modules\utilities_manifest.json' }

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

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure "$Label missing: $Path"
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Add-Pass "$Label JSON parsed"
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

function Test-Hash {
    param(
        [string]$Path,
        [string]$ExpectedSha256,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Pass "$Label source hash check skipped because no path was provided"
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure "$Label source path missing: $Path"
        return
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    $expected = ([string]$ExpectedSha256).ToUpperInvariant()
    Add-Check ($actual -eq $expected) "$Label source hash matches catalog" "$Label source hash drift: expected $expected actual $actual"
}

function Read-NipProfile {
    param([string]$Path)

    [xml]$doc = Get-Content -LiteralPath $Path -Raw
    $profiles = @($doc.ArrayOfProfile.Profile)
    if ($profiles.Count -ne 1) {
        Add-Failure "NIP source expected one Profile element, found $($profiles.Count)"
        return $null
    }

    $profile = $profiles[0]
    return [pscustomobject]@{
        Name = [string]$profile.ProfileName
        ExecutableCount = @($profile.Executeables.string | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
        Settings = @($profile.Settings.ProfileSetting)
    }
}

function Test-CatalogSettingShape {
    param([object]$Profile)

    $settings = @($Profile.settings)
    Add-Check ($settings.Count -eq [int]$Profile.settingCount) "Catalog settingCount matches settings array" "Catalog settingCount mismatch: declared=$($Profile.settingCount) actual=$($settings.Count)"

    $dupes = @($settings | Group-Object settingId | Where-Object { $_.Count -gt 1 })
    Add-Check ($dupes.Count -eq 0) "Catalog setting IDs are unique" "Catalog has duplicate setting IDs: $($dupes.Name -join ', ')"

    $dwordSettings = @($settings | Where-Object { $_.valueType -eq 'Dword' })
    $stringSettings = @($settings | Where-Object { $_.valueType -eq 'String' })
    $unknownTypes = @($settings | Where-Object { $_.valueType -notin @('Dword', 'String') })

    Add-Check ($unknownTypes.Count -eq 0) "Catalog uses only supported NIP value types" "Unsupported NIP value types found: $($unknownTypes.valueType -join ', ')"
    Add-Check ($dwordSettings.Count -eq [int]$Profile.valueTypeCounts.Dword) "Catalog DWORD count matches valueTypeCounts" "Catalog DWORD count mismatch"
    Add-Check ($stringSettings.Count -eq [int]$Profile.valueTypeCounts.String) "Catalog String count matches valueTypeCounts" "Catalog String count mismatch"
    Add-Check (@($stringSettings | Where-Object { $_.hardwareSpecific -eq $true }).Count -ge 1) "String settings carry hardware-specific warning metadata" "String settings are missing hardware-specific warning metadata"

    foreach ($setting in $dwordSettings) {
        $numeric = ([string]$setting.value) -match '^\d+$'
        Add-Check $numeric "DWORD setting $($setting.settingId) has numeric value" "DWORD setting $($setting.settingId) has non-numeric value"
        if ($numeric) {
            $expectedHex = ('0x{0:X8}' -f [uint32]$setting.value)
            Add-Check ([string]$setting.valueHex -eq $expectedHex) "DWORD setting $($setting.settingId) valueHex matches value" "DWORD setting $($setting.settingId) valueHex mismatch: expected $expectedHex actual $($setting.valueHex)"
        }
    }

    foreach ($setting in $stringSettings) {
        Add-Check ([string]::IsNullOrWhiteSpace([string]$setting.valueHex)) "String setting $($setting.settingId) does not pretend to have DWORD hex" "String setting $($setting.settingId) should not carry valueHex"
    }
}

function Test-NipSourceAgainstCatalog {
    param(
        [string]$Path,
        [object]$Profile
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Pass 'NIP source XML comparison skipped because no path was provided'
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure "NIP source path missing: $Path"
        return
    }

    try {
        $source = Read-NipProfile $Path
        if ($null -eq $source) { return }

        Add-Check ($source.Name -eq [string]$Profile.profileNameInNip) "NIP profile name matches catalog" "NIP profile name mismatch: source=$($source.Name) catalog=$($Profile.profileNameInNip)"
        Add-Check ($source.ExecutableCount -eq [int]$Profile.executableCount) "NIP executable count matches catalog" "NIP executable count mismatch: source=$($source.ExecutableCount) catalog=$($Profile.executableCount)"
        Add-Check ($source.Settings.Count -eq [int]$Profile.settingCount) "NIP setting count matches catalog" "NIP setting count mismatch: source=$($source.Settings.Count) catalog=$($Profile.settingCount)"

        foreach ($setting in @($Profile.settings)) {
            $sourceSetting = @($source.Settings | Where-Object { [string]$_.SettingID -eq [string]$setting.settingId })
            if ($sourceSetting.Count -ne 1) {
                Add-Failure "NIP setting $($setting.settingId) not found exactly once in source"
                continue
            }

            $sourceSetting = $sourceSetting[0]
            Add-Check ([string]$sourceSetting.SettingNameInfo -eq [string]$setting.name) "NIP setting $($setting.settingId) name matches catalog" "NIP setting $($setting.settingId) name mismatch"
            Add-Check ([string]$sourceSetting.ValueType -eq [string]$setting.valueType) "NIP setting $($setting.settingId) valueType matches catalog" "NIP setting $($setting.settingId) valueType mismatch"
            Add-Check ([string]$sourceSetting.SettingValue -eq [string]$setting.value) "NIP setting $($setting.settingId) value matches catalog" "NIP setting $($setting.settingId) value mismatch"
        }
    } catch {
        Add-Failure "NIP source XML comparison failed: $($_.Exception.Message)"
    }
}

function Test-ReferenceSourceAgainstCatalog {
    param(
        [string]$Path,
        [object]$Catalog
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Pass 'Reference.xml comparison skipped because no path was provided'
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Failure "Reference.xml path missing: $Path"
        return
    }

    try {
        [xml]$reference = Get-Content -LiteralPath $Path -Raw
        $referenceSettings = @($reference.CustomSettingNames.Settings.CustomSetting)
        Add-Check ($referenceSettings.Count -eq [int]$Catalog.referenceXml.customSettingCount) "Reference.xml setting count matches catalog" "Reference.xml setting count mismatch: source=$($referenceSettings.Count) catalog=$($Catalog.referenceXml.customSettingCount)"

        $referenceIds = @{}
        foreach ($setting in $referenceSettings) {
            if ($setting.HexSettingID) {
                $decimalId = [Convert]::ToInt64(([string]$setting.HexSettingID -replace '^0x',''), 16).ToString()
                $referenceIds[$decimalId] = $true
            }
        }

        foreach ($id in @($Catalog.referenceXml.matchedSettingIds)) {
            Add-Check ($referenceIds.ContainsKey([string]$id)) "Reference.xml contains matched setting ID $id" "Reference.xml does not contain matched setting ID $id"
        }
    } catch {
        Add-Failure "Reference.xml comparison failed: $($_.Exception.Message)"
    }
}

$catalog = Read-JsonFile $CatalogPath 'NVIDIA NIP catalog'
$sample = Read-JsonFile $SamplePath 'NVIDIA profile sample'
$manifest = Read-JsonFile $UtilityManifestPath 'Utilities manifest'

if ($catalog) {
    Add-Check ($catalog.productName -eq 'Roo Industries Optimization Suite') 'Catalog productName is correct' "Catalog productName is unexpected: $($catalog.productName)"
    Add-Check ($catalog.sourceBoundary.mode -eq 'metadata-only') 'Catalog is metadata-only' "Catalog mode is not metadata-only: $($catalog.sourceBoundary.mode)"
    Add-Check ($catalog.sourceBoundary.nvpiExecutionAllowed -eq $false) 'Catalog forbids NVPI execution' 'Catalog does not forbid NVPI execution'
    Add-Check ($catalog.sourceBoundary.nipImportAllowed -eq $false) 'Catalog forbids NIP import automation' 'Catalog does not forbid NIP import automation'
    Add-Check ($catalog.sourceBoundary.autoApplyAllowed -eq $false) 'Catalog forbids auto apply' 'Catalog does not forbid auto apply'
    Add-Check ($catalog.sourceBoundary.manualApplyRequired -eq $true) 'Catalog requires manual apply gate' 'Catalog does not require manual apply gate'
    Add-Check ($catalog.toolAsset.executionAllowedDuringCatalogValidation -eq $false) 'Tool asset is validation read-only' 'Tool asset permits execution during validation'

    $profiles = @($catalog.profiles)
    Add-Check ($profiles.Count -eq 1) 'Catalog has one seed profile' "Catalog expected one seed profile, found $($profiles.Count)"
    if ($profiles.Count -ge 1) {
        $profile = $profiles[0]
        Add-Check ($profile.profileId -eq 'base-profile') 'Seed profile ID is base-profile' "Unexpected seed profile ID: $($profile.profileId)"
        Add-Check ($profile.status -eq 'seed-profile') 'Seed profile status is not promoted' "Seed profile status is unexpectedly $($profile.status)"
        Add-Check ($profile.manualApplyRequired -eq $true) 'Seed profile requires manual apply' 'Seed profile does not require manual apply'
        Add-Check ($profile.benchmarkStatus -eq 'needs-local-benchmark') 'Seed profile requires local benchmark before recommendation' "Unexpected benchmarkStatus: $($profile.benchmarkStatus)"
        Add-Check (@($profile.supportedHardware) -contains 'PCI\VEN_10DE') 'Seed profile is NVIDIA hardware gated' 'Seed profile is missing PCI\VEN_10DE hardware gate'

        Test-CatalogSettingShape $profile
        Test-NipSourceAgainstCatalog $NipSourcePath $profile
        Test-Hash $NipSourcePath $profile.sourceSha256 'base-profile.nip'
    }

    Test-ReferenceSourceAgainstCatalog $ReferenceXmlPath $catalog
    Test-Hash $ReferenceXmlPath $catalog.referenceXml.sha256 'Reference.xml'
    Test-Hash $NvpiExecutablePath $catalog.toolAsset.sha256 'NVIDIA Profile Inspector executable'
}

if ($sample) {
    Add-Check ($sample.policy.autoApplyAllowed -eq $false) 'Sample policy forbids auto apply' 'Sample policy allows auto apply'
    Add-Check ($sample.policy.manualApplyRequiresNvidiaGpu -eq $true) 'Sample policy requires NVIDIA GPU' 'Sample policy does not require NVIDIA GPU'
    Add-Check ($sample.policy.manualApplyRequiresExportFirst -eq $true) 'Sample policy requires export first' 'Sample policy does not require export first'
    Add-Check ($sample.policy.benchmarkBeforeRecommend -eq $true) 'Sample policy requires benchmark before recommendation' 'Sample policy does not require benchmark before recommendation'
}

if ($manifest) {
    $tool = @($manifest.tools | Where-Object { $_.id -eq 'nvidia-profile-inspector' })
    Add-Check ($tool.Count -eq 1) 'Utilities manifest has one NVIDIA Profile Inspector entry' "Utilities manifest NVIDIA Profile Inspector entry count is $($tool.Count)"
    if ($tool.Count -eq 1) {
        $tool = $tool[0]
        Add-Check ($tool.autoRunAllowed -eq $false) 'Utilities manifest forbids NVPI auto-run' 'Utilities manifest allows NVPI auto-run'
        Add-Check ($tool.appRole -eq 'profile-import-and-test') 'Utilities manifest keeps NVPI as profile import/test tool' "Unexpected NVPI appRole: $($tool.appRole)"
        $profileFile = @($tool.profileFiles | Where-Object { $_.id -eq 'base-profile' })
        Add-Check ($profileFile.Count -eq 1) 'Utilities manifest has one base-profile profile file' "Utilities manifest base-profile profile file count is $($profileFile.Count)"
        if ($profileFile.Count -eq 1) {
            Add-Check ($profileFile[0].autoImportAllowed -eq $false) 'Utilities manifest forbids base-profile auto-import' 'Utilities manifest allows base-profile auto-import'
            Add-Check ($profileFile[0].manualApplyRequired -eq $true) 'Utilities manifest requires manual base-profile apply' 'Utilities manifest does not require manual base-profile apply'
            Add-Check ($profileFile[0].requiresExportFirst -eq $true) 'Utilities manifest requires export before base-profile import' 'Utilities manifest does not require export before base-profile import'
        }
    }
}

$stateEntries = Get-StateEntryCount
Add-Check ($stateEntries -eq 0) 'backend/state remains empty after NVIDIA NIP validation' "backend/state is not empty after NVIDIA NIP validation: $stateEntries item(s)"

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "PASS NVIDIA NIP catalog validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL NVIDIA NIP catalog validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
