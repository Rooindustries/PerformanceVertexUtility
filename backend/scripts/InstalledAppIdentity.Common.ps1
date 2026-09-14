function Get-RooAppIdentityId {
    param([string]$Kind,[string[]]$Parts)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes((($Parts | ForEach-Object { $_.ToLowerInvariant() }) -join [char]0))
        return $Kind+':'+([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally {$hash.Dispose()}
}

function New-RooRegistryAppIdentity {
    param([ValidateSet('LocalMachine','CurrentUser')][string]$Hive,
        [ValidateSet('Registry32','Registry64')][string]$View,[string]$KeyName,[string]$UserSid)
    if ([string]::IsNullOrWhiteSpace($KeyName)) {throw 'Registry app identity requires an exact subkey name.'}
    if ($Hive -eq 'CurrentUser' -and [string]::IsNullOrWhiteSpace($UserSid)) {throw 'Per-user registry identity requires its Windows SID.'}
    # HKCU\Software\...\Uninstall is shared under WOW64. Use one canonical
    # view so querying it from a different process architecture cannot duplicate it.
    if ($Hive -eq 'CurrentUser') {$View='Registry32'}
    $owner=if ($Hive -eq 'CurrentUser') {$UserSid} else {''}
    $keyPath='Software\Microsoft\Windows\CurrentVersion\Uninstall\'+$KeyName
    return [pscustomobject]@{ kind='registry'; hive=$Hive; view=$View; keyPath=$keyPath; userSid=$owner;
        stableId=Get-RooAppIdentityId 'registry' @($Hive,$View,$keyPath,$owner) }
}

function New-RooAppxIdentity {
    param([string]$PackageFullName,[string]$PackageFamilyName,[string]$UserSid)
    if ($PackageFullName -notmatch '^[^_]+_[^_]+_[^_]+_[^_]*_[^_]+$' -or [string]::IsNullOrWhiteSpace($UserSid)) {
        throw 'Appx identity requires a full package name and the current Windows user SID.'
    }
    return [pscustomobject]@{ kind='appx'; scope='current-user'; packageFullName=$PackageFullName;
        packageFamilyName=$PackageFamilyName; userSid=$UserSid;
        stableId=Get-RooAppIdentityId 'appx' @($PackageFullName,$UserSid) }
}
