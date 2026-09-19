$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'InstalledAppIdentity.Common.ps1')
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
function Assert([bool]$condition,[string]$name){if(-not $condition){throw $name};Write-Host ('PASS '+$name)}
function Reject([scriptblock]$action,[string]$name){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Assert $failed $name}
$current=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$other='S-1-5-21-111-222-333-1002'
$full='RooIndustries.ScopeFixture_1.0.0.0_x64__abc123'
$package=[pscustomobject]@{PackageFullName=$full;PackageFamilyName='RooIndustries.ScopeFixture_abc123';IsFramework=$false;IsResourcePackage=$false;IsBundle=$false;NonRemovable=$false;InstallLocation='C:\Fixtures\Scope';Dependencies=@();PackageUserInformation=@(
    [pscustomobject]@{UserSecurityId=[pscustomobject]@{Sid=$current};InstallState='Installed'},
    [pscustomobject]@{UserSecurityId=[pscustomobject]@{Sid=$other};InstallState='Installed'},
    [pscustomobject]@{UserSecurityId=[pscustomobject]@{Sid='S-1-5-21-111-222-333-1003'};InstallState='Staged'})}
$ids=@(Get-RooIndustriesAppxInstalledSids $package)
Assert ($ids.Count -eq 2 -and $ids -contains $current -and $ids -contains $other) 'All-user inventory includes proven registrations and excludes staged-only entries'
$unknown=$package|Select-Object *;$unknown.PackageUserInformation=@([pscustomobject]@{UserSecurityId=[pscustomobject]@{Sid=$other};InstallState=$null})
Reject {Get-RooIndustriesAppxInstalledSids $unknown} 'A missing user install state remains unknown'
$first=New-RooIndustriesAppxIdentity $full $package.PackageFamilyName $current
$second=New-RooIndustriesAppxIdentity $full $package.PackageFamilyName $other 'registered-user'
Assert ($first.stableId -ne $second.stableId) 'One package registered for two accounts has two exact removal identities'
$bad=New-RooIndustriesAppxIdentity $full $package.PackageFamilyName $other
Reject {Assert-RooIndustriesBulkIdentity $bad} 'Current-user scope cannot silently target another account'
$script:registrations=@{};$script:registrations[$current]=@($package);$script:registrations[$other]=@($package)
function Get-AppxPackage {
    [CmdletBinding()]param([string]$User,[string[]]$PackageTypeFilter)
    if($User -eq 'S-1-5-21-111-222-333-9999'){throw 'Controlled provider query failure'}
    return $script:registrations[$User]
}
Assert (Test-RooIndustriesBulkAppPresent $first) 'Presence queries retain the captured current-user SID'
$script:registrations[$current]=@()
Assert (-not (Test-RooIndustriesBulkAppPresent $first) -and (Test-RooIndustriesBulkAppPresent $second)) 'Absence for one account cannot become all-users removal success'
$denied=New-RooIndustriesAppxIdentity $full $package.PackageFamilyName 'S-1-5-21-111-222-333-9999' 'registered-user'
Reject {Test-RooIndustriesBulkAppPresent $denied} 'A failed provider query cannot prove package absence'
$command=Get-RooIndustriesAppxRemoveCommand $second
Assert ($command -like "*-User '$other' -Package '$full' -ErrorAction Stop" -and $command -notlike '*-AllUsers*') 'Removal command freezes the exact reviewed SID and package name'
$before=Get-RooIndustriesBulkRegistrationState $second
$app=[pscustomobject]@{sourceIdentity=$second;packageFacts=$before.displayValues}
$package.Dependencies=@([pscustomobject]@{PackageFullName='RooIndustries.Dependency_2.0.0.0_x64__abc123'})
$after=Get-RooIndustriesBulkRegistrationState $second
Assert ($before.fingerprint -ne $after.fingerprint) 'A changed dependency set invalidates the package registration fingerprint'
Reject {Assert-RooIndustriesBulkInventoryBinding $app $after} 'Dependency changes require a new removal review'
$package.NonRemovable=$true
Reject {Assert-RooIndustriesBulkInventoryBinding $app (Get-RooIndustriesBulkRegistrationState $second)} 'Windows package protection blocks dispatch even with favorable registration presence'

$main=[pscustomobject]@{IsBundle=$false;PackageFamilyName='RooIndustries.Bundle_abc123';Version='1.0.0.0'}
$bundle=[pscustomobject]@{IsBundle=$true;PackageFamilyName=$main.PackageFamilyName;Version='1.0.0.0';PackageUserInformation=@()}
Assert ($null -ne (Get-RooIndustriesAppxParentBundle $main @($main,$bundle) $current)) 'A current-user query collapses its bundle and main package even when per-user metadata is omitted'
Assert ($null -eq (Get-RooIndustriesAppxParentBundle $main @($main,$bundle) $current -AllUsers)) 'An all-users query cannot infer bundle registration from empty account metadata'
$bundle.PackageUserInformation=@([pscustomobject]@{UserSecurityId=[pscustomobject]@{Sid=$other};InstallState='Installed'})
Assert ($null -eq (Get-RooIndustriesAppxParentBundle $main @($main,$bundle) $current -AllUsers)) 'Another account bundle cannot hide the current account package'
Assert ($null -ne (Get-RooIndustriesAppxParentBundle $main @($main,$bundle) $other -AllUsers)) 'The matching account and version share one bundle removal choice'
$bundle.Version='2.0.0.0'
Assert ($null -eq (Get-RooIndustriesAppxParentBundle $main @($main,$bundle) $other -AllUsers)) 'A different bundle version cannot hide another installed package'
$bundle.Version='1.0.0.0'
Reject {Get-RooIndustriesAppxParentBundle $main @($main,$bundle,$bundle) $other -AllUsers} 'Ambiguous parent bundles require review instead of choosing one arbitrarily'
