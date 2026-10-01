$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
function Check([bool]$Passed,[string]$Message){if(-not $Passed){throw $Message};Write-Output ('PASS '+$Message)}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Write-Output 'SKIP Data folder marker lookups need administrator rights to write their own marker value';return}
$markerKey='SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$hklm=[Microsoft.Win32.Registry]::LocalMachine
$created=$null
foreach($level in 'SOFTWARE\RooIndustries','SOFTWARE\RooIndustries\OptimizationSuite',$markerKey){
    $existing=$hklm.OpenSubKey($level)
    if($existing){$existing.Dispose()}elseif(-not $created){$created=$level}
}
$long=Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp') ('roo-industries-marker-paths-'+[Guid]::NewGuid().ToString('N'))
$names=@($long.ToUpperInvariant(),($long+'\ghost').ToUpperInvariant(),($long+'\inner').ToUpperInvariant(),($long+'\bare').ToUpperInvariant())
try {
    [IO.Directory]::CreateDirectory($long)|Out-Null
    $short=(New-Object -ComObject Scripting.FileSystemObject).GetFolder($long).ShortPath
    if($short -eq $long -or $short -notmatch '~'){Write-Output 'SKIP This volume has no 8.3 short names, so a short path cannot be produced here';return}
    $key=$hklm.CreateSubKey($markerKey,$true)
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $key.SetValue($names[0]+'|protected-at',[DateTime]::UtcNow.ToFileTimeUtc(),[Microsoft.Win32.RegistryValueKind]::QWord)
    $key.SetValue($names[0],$user,[Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue($names[1],$user,[Microsoft.Win32.RegistryValueKind]::String)
    $key.Dispose()
    Start-Sleep -Milliseconds 200
    $later=Join-Path $long 'later\written.txt'
    [IO.Directory]::CreateDirectory((Split-Path $later))|Out-Null
    [IO.File]::WriteAllText($later,'after protection')
    $earlier=Join-Path $long 'earlier.txt'
    [IO.File]::WriteAllText($earlier,'before protection')
    (Get-Item -LiteralPath $earlier).CreationTimeUtc=[DateTime]::UtcNow.AddHours(-1)
    $shortLater=Join-Path $short 'later\written.txt'
    $shortEarlier=Join-Path $short 'earlier.txt'
    Check ($short -ne $long -and (Test-Path -LiteralPath $shortLater -PathType Leaf)) 'The 8.3 form of the folder differs from its long path and reaches the same files'
    Check (Test-RooIndustriesDataRootMarked $long) 'The long folder path finds the marker the app wrote'
    Check (Test-RooIndustriesDataRootMarked $short) 'The 8.3 folder path finds the same marker'
    Check (Test-RooIndustriesDataRootMarked ($short.ToLowerInvariant()+'\')) 'A lower case 8.3 path with a trailing backslash finds the same marker'
    Check (Test-RooIndustriesDataRootMarked (Join-Path $short 'ghost')) 'A marker for a folder that does not exist yet is found through the nearest existing 8.3 ancestor'
    Check (-not (Test-RooIndustriesDataRootMarked (Join-Path $short 'later'))) 'A folder inside a marked folder is not marked by that marker'
    Check (Test-RooIndustriesWrittenAfterProtection $shortLater) 'A file written after protection is recognized through the 8.3 path'
    Check (-not (Test-RooIndustriesWrittenAfterProtection $shortEarlier)) 'A file older than the protection is still refused through the 8.3 path'
    Check (-not (Test-RooIndustriesWrittenAfterProtection (Join-Path $short 'missing.txt'))) 'A missing file is never recognized as written after protection'
    $key=$hklm.OpenSubKey($markerKey,$true)
    $key.SetValue($names[2]+'|protected-at',[DateTime]::UtcNow.AddHours(-1).ToFileTimeUtc(),[Microsoft.Win32.RegistryValueKind]::QWord)
    $key.SetValue($names[2],$user,[Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue($names[3],$user,[Microsoft.Win32.RegistryValueKind]::String)
    $key.Dispose()
    $carried=Join-Path $long 'inner\carried.txt'
    [IO.Directory]::CreateDirectory((Split-Path $carried))|Out-Null
    [IO.File]::WriteAllText($carried,'copied in when the outer folder was protected')
    (Get-Item -LiteralPath $carried).CreationTimeUtc=[DateTime]::UtcNow.AddMinutes(-30)
    $bare=Join-Path $long 'bare\later.txt'
    [IO.Directory]::CreateDirectory((Split-Path $bare))|Out-Null
    [IO.File]::WriteAllText($bare,'inside a folder whose marker has no protection time')
    Check (-not (Test-RooIndustriesWrittenAfterProtection $carried)) 'A file newer than a nested marker but older than the outer marker is not recognized as written after protection'
    Check (-not (Test-RooIndustriesWrittenAfterProtection $bare)) 'A file inside a folder whose marker has no protection time is not recognized as written after protection'
    $outside=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-marker-paths-outside-'+[Guid]::NewGuid().ToString('N')+'.txt')
    [IO.File]::WriteAllText($outside,'outside every marked folder')
    $workingFolder=[Environment]::CurrentDirectory
    try {
        [Environment]::CurrentDirectory=$long
        Check ((Get-RooIndustriesDataRootMarkerName ([IO.Path]::GetPathRoot($long))) -eq [IO.Path]::GetPathRoot($long).TrimEnd('\').ToUpperInvariant()) 'A drive root never resolves to the current folder of the process'
        Check (-not (Test-RooIndustriesWrittenAfterProtection $outside)) 'A file outside every marked folder is not recognized when the process runs inside a marked folder'
    } finally {[Environment]::CurrentDirectory=$workingFolder;Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue}
} finally {
    $key=$hklm.OpenSubKey($markerKey,$true)
    if($key){
        foreach($name in $names){$key.DeleteValue($name,$false);$key.DeleteValue($name+'|protected-at',$false)}
        $key.Dispose()
    }
    if($created){
        foreach($level in @('SOFTWARE\RooIndustries','SOFTWARE\RooIndustries\OptimizationSuite',$markerKey)|Where-Object{$_.Length -ge $created.Length}|Sort-Object Length -Descending){
            $remaining=$hklm.OpenSubKey($level)
            if(-not $remaining){continue}
            $empty=($remaining.ValueCount+$remaining.SubKeyCount) -eq 0
            $remaining.Dispose()
            if(-not $empty){break}
            $hklm.DeleteSubKey($level)
        }
    }
    if(Test-Path -LiteralPath $long){Remove-Item -LiteralPath $long -Recurse -Force}
}
Check (-not (Test-Path -LiteralPath $long)) 'Marker path validation removes its folder'
$left=$hklm.OpenSubKey($markerKey)
Check (-not $left -or -not @($left.GetValueNames()|Where-Object{$names -contains ($_ -replace '\|protected-at$','')}).Count) 'Marker path validation removes its own marker values'
if($left){$left.Dispose()}
