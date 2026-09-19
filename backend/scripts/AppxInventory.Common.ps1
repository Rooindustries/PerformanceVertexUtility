function Get-RooIndustriesAppxFacts {
    param($Package)
    foreach($name in @('IsFramework','IsResourcePackage','IsBundle','NonRemovable')){
        if($null -eq $Package.PSObject.Properties[$name] -or $Package.$name -isnot [bool]){throw ('Appx protection metadata is incomplete: '+$name)}
    }
    if($null -eq $Package.PSObject.Properties['Dependencies']){throw 'Appx dependency metadata is missing.'}
    $dependencies=@($Package.Dependencies|Where-Object {$null -ne $_}|ForEach-Object {
        if(-not $_.PackageFullName){throw 'An Appx dependency has no full identity.'}
        [string]$_.PackageFullName
    }|Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        packageFullName=[string]$Package.PackageFullName;packageFamilyName=[string]$Package.PackageFamilyName
        packageType=$(if($Package.IsBundle){'Bundle'}elseif($Package.IsFramework){'Framework'}elseif($Package.IsResourcePackage){'Resource'}else{'Main'})
        nonRemovable=[bool]$Package.NonRemovable;isFramework=[bool]$Package.IsFramework;isResource=[bool]$Package.IsResourcePackage
        installLocation=[string]$Package.InstallLocation;dependencies=$dependencies
    }
}

function Get-RooIndustriesAppxInstalledSids {
    param($Package)
    if($null -eq $Package.PSObject.Properties['PackageUserInformation']){throw 'Appx user installation evidence is missing.'}
    $result=New-Object System.Collections.Generic.List[string]
    foreach($user in @($Package.PackageUserInformation)){
        if($null -eq $user -or $null -eq $user.InstallState){throw 'Appx user installation state is missing.'}
        $state=[string]$user.InstallState
        if($state -notin @('Installed','Staged','NotInstalled','Paused')){throw ('Unknown Appx user installation state: '+$state)}
        if($state -ne 'Installed'){continue}
        $sid=if($user.UserSecurityId -is [string]){[string]$user.UserSecurityId}else{[string]$user.UserSecurityId.Sid}
        if($sid -notmatch '^S-1-\d+(?:-\d+)+$'){throw 'Appx installation has no exact Windows SID.'}
        $result.Add($sid)
    }
    return @($result.ToArray()|Sort-Object -Unique)
}

function Get-RooIndustriesAppxParentBundle {
    param($Package,[object[]]$Packages,[string]$UserSid,[switch]$AllUsers)
    if($Package.IsBundle){return $null}
    $parents=@($Packages|Where-Object {$_.IsBundle -and $_.PackageFamilyName -ceq $Package.PackageFamilyName -and [string]$_.Version -ceq [string]$Package.Version -and
        (-not $AllUsers -or $UserSid -in @(Get-RooIndustriesAppxInstalledSids $_))})
    if($parents.Count -gt 1){throw ('Multiple installed parent bundles require review: '+$Package.PackageFamilyName)}
    if($parents.Count -eq 1){return $parents[0]}
    return $null
}

function Get-RooIndustriesExactAppxPackage {
    param($Identity)
    $matches=@(Get-AppxPackage -User $Identity.userSid -PackageTypeFilter Main,Bundle,Framework,Resource -ErrorAction Stop|Where-Object {$_.PackageFullName -ceq $Identity.packageFullName})
    if($matches.Count -gt 1){throw 'The Appx identity resolved to multiple package records.'}
    if($matches.Count -eq 0){return $null}
    return $matches[0]
}

function Get-RooIndustriesAppxRemoveCommand {
    param($Identity)
    $package=([string]$Identity.packageFullName).Replace("'","''");$sid=([string]$Identity.userSid).Replace("'","''")
    return "Remove-AppxPackage -User '"+$sid+"' -Package '"+$package+"' -ErrorAction Stop"
}
