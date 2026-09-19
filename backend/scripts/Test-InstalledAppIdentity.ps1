$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'InstalledAppIdentity.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallOutcome.Common.ps1')
. (Join-Path $PSScriptRoot 'UninstallCleanup.Common.ps1')
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
function Assert([bool]$Condition,[string]$Message) {if(-not $Condition){throw $Message}; Write-Host "PASS $Message"}
function Read-Result($Lines) {return ($Lines -join [Environment]::NewLine)|ConvertFrom-Json}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-app-identities-'+[guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $identities=@(
        (New-RooIndustriesRegistryAppIdentity LocalMachine Registry64 SameKey ''),
        (New-RooIndustriesRegistryAppIdentity LocalMachine Registry32 SameKey ''),
        (New-RooIndustriesRegistryAppIdentity CurrentUser Registry64 SameKey 'S-1-5-21-1'),
        (New-RooIndustriesRegistryAppIdentity CurrentUser Registry64 SameKey 'S-1-5-21-2')
    )
    Assert (@($identities.stableId|Select-Object -Unique).Count -eq 4) 'Registry app IDs distinguish hive, view and Windows owner even for identical names and subkeys'
    Assert ((New-RooIndustriesRegistryAppIdentity LocalMachine Registry64 samekey '').stableId -ceq $identities[0].stableId) 'Registry case changes do not change the identity'
    Assert ((New-RooIndustriesRegistryAppIdentity CurrentUser Registry32 SameKey 'S-1-5-21-1').stableId -ceq $identities[2].stableId) 'The shared HKCU uninstall key has one identity across WOW64 views'
    $pkg='RooIndustries.Fixture_1.2.3.4_x64__abc123'
    $first=New-RooIndustriesAppxIdentity $pkg 'RooIndustries.Fixture_abc123' 'S-1-5-21-1'
    $second=New-RooIndustriesAppxIdentity $pkg 'RooIndustries.Fixture_abc123' 'S-1-5-21-2'
    Assert ($first.stableId -ne $second.stableId -and $first.packageFullName -eq $pkg) 'Appx selection retains full package identity and separates users'
    Assert (Test-RooIndustriesAppMatch ([pscustomobject]@{packageId=$pkg;packageFamilyName='RooIndustries.Fixture_abc123'}) ([pscustomobject]@{packageIdPatterns=@('RooIndustries.Fixture_abc123')})) 'Family-based dependency rules still match after removal identity uses the full package name'
    $duplicateRejected=$false;try {Find-RooIndustriesInstalledApp ([pscustomobject]@{apps=@([pscustomobject]@{appId='duplicate'},[pscustomobject]@{appId='duplicate'})}) 'duplicate'|Out-Null} catch {$duplicateRejected=$true}
    Assert $duplicateRejected 'Imported inventory with duplicate app IDs cannot silently select the first record'
    $savedApp=[pscustomobject]@{sourceIdentity=@{kind='registry'};displayName='Previous version';sourceType='registry'}
    $bindingRejected=$false;try {Assert-RooIndustriesBulkInventoryBinding $savedApp ([pscustomobject]@{displayValues=@{DisplayName='New version'}})} catch {$bindingRejected=$true}
    Assert $bindingRejected 'A saved inventory cannot authorize an old remover against a newer registration snapshot'
    $apps=@(
        @{appId=$first.stableId; displayName='Roo Industries Fixture'; sourceType='appx'; sourceIdentity=$first; packageId=$pkg; risk='low'; protected=$false},
        @{appId='msi:fixture'; displayName='Roo Industries MSI Fixture'; sourceType='msi'; packageId='{11111111-2222-3333-4444-555555555555}'; uninstallString='MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'; risk='low'; protected=$false}
    )
    $inventory=Join-Path $root 'inventory.json'
    @{schemaVersion=1; apps=$apps}|ConvertTo-Json -Depth 12|Set-Content $inventory -Encoding UTF8
    $preview=Read-Result (& (Join-Path $PSScriptRoot 'Preview-OfficialUninstall.ps1') -AppId @($first.stableId,'msi:fixture') -InventoryPath $inventory)
    Assert ($preview.commands.Count -eq 2 -and $preview.commands[0].metadata.packageFullName -eq $pkg -and $preview.commands[0].rawCommand -like "*'$pkg'") 'Appx removal preview binds the exact full name, not the family name'
    Assert ($preview.commands[1].arguments -match '(?i)/x ' -and $preview.commands[1].arguments -match '(?i)/norestart' -and $preview.commands[1].arguments -notmatch '(?i)/i') 'MSI preview derives uninstall from ProductCode and prevents automatic restart'
    foreach($code in @(3010,1641,1605,1614)) {
        Assert ((Get-RooIndustriesUninstallOutcome windows-installer $code).success -and -not (Get-RooIndustriesUninstallOutcome generic $code).success) "MSI exit $code is interpreted only for Windows Installer"
    }
    Assert ((Get-RooIndustriesUninstallOutcome windows-installer 1618).state -eq 'installer-busy' -and (Get-RooIndustriesUninstallOutcome windows-installer 1602).state -eq 'canceled') 'Installer busy and user cancellation remain distinct from success'
    $live=Read-Result (& (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1'))
    Assert ($live.apps.Count -gt 0 -and @($live.apps.appId|Select-Object -Unique).Count -eq $live.apps.Count) 'Read-only live inventory yields unique app selections'
    Assert (@($live.apps|Where-Object {$_.sourceType -eq 'appx' -and $_.packageId -cne $_.sourceIdentity.packageFullName}).Count -eq 0) 'Every live Appx record uses its full package name for removal'
    Assert (@($live.apps|Where-Object {$_.sourceType -in @('msi','registry') -and $null -eq $_.sourceIdentity}).Count -eq 0) 'Every live registry record retains hive, view and ownership evidence'
    Assert (@($live.apps|Where-Object {$_.protectionReasons -isnot [array]}).Count -eq 0) 'Live inventory keeps protection reasons as JSON arrays'
    $records=Read-Result (& {
        . (Join-Path $PSScriptRoot 'Get-InstalledAppInventory.ps1') | Out-Null
        $identity=New-RooIndustriesRegistryAppIdentity CurrentUser Registry32 'RooIndustriesArrayFixture' 'S-1-5-21-1'
        @(
            (New-AppRecord ([pscustomobject]@{DisplayName='Roo Industries Note Editor';Publisher='Roo Industries';PSChildName='RooIndustriesArrayFixture'}) 'registry' $identity),
            (New-AppRecord ([pscustomobject]@{DisplayName='Roo Industries Windows Desktop Runtime';Publisher='Roo Industries';PSChildName='RooIndustriesArrayFixture'}) 'registry' $identity)
        ) | ConvertTo-Json -Depth 12
    })
    Assert ($records[0].protectionReasons -is [array] -and $records[0].protectionReasons.Count -eq 0) 'An ordinary app round-trips with an empty protection-reason array'
    Assert ($records[1].protectionReasons -is [array] -and $records[1].protectionReasons.Count -eq 1 -and $records[1].risk -eq 'advanced') 'A dependency round-trips with one review reason without becoming a scalar'
} finally {if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force}}
