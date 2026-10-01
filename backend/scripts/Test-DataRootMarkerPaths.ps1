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
$names=@($long.ToUpperInvariant(),($long+'\ghost').ToUpperInvariant())
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
