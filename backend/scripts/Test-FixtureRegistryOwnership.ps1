param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateSet('registry','discovery','cleanup','batch')][string[]]$Area=@('registry','discovery','cleanup','batch'))
$ErrorActionPreference='Stop'
$script:Failed=0
function Check([bool]$Passed,[string]$Message){if($Passed){Write-Output ('PASS '+$Message)}else{$script:Failed++;Write-Output ('FAIL '+$Message)}}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesFixtureParent {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyEx(IntPtr key, string subKey, int reserved, string className, int options, int access, IntPtr security, out IntPtr result, out int disposition);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
    public static bool CreateNew(string path) {
        IntPtr key; int disposition;
        int status = RegCreateKeyEx(new IntPtr(unchecked((int)0x80000001)), path, 0, null, 0, 0x20019 | 0x100, IntPtr.Zero, out key, out disposition);
        if (status != 0) throw new System.ComponentModel.Win32Exception(status);
        RegCloseKey(key);
        return disposition == 1;
    }
}
'@
$areaParents=@{registry=@('RooIndustriesCleanupTests');discovery=@('RooIndustriesDiscoveryTests','RooIndustriesPublishedPathTests');cleanup=@('RooIndustriesApplicationCleanupTests','RooIndustriesExclusionTests');batch=@('RooIndustriesCleanupBatchTests')}
$parents=@($areaParents.Values|ForEach-Object {$_})
$hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
function Read-Parent([string]$Name){$key=$hive.OpenSubKey('Software\'+$Name);if(-not $key){return 'absent'};try{return ('{0} subkeys, {1} values' -f $key.SubKeyCount,$key.ValueCount)}finally{$key.Dispose()}}
function Invoke-Area([string]$Run){& (Join-Path $PSScriptRoot 'Test-OptimizerCore.ps1') -DotNetPath $DotNetPath -Area $Run|Out-Host;Check ($LASTEXITCODE -eq 0) ('Optimizer core '+$Run+' checks pass')}
$existing=@($parents|Where-Object {(Read-Parent $_) -ne 'absent'})
if($existing.Count){Write-Output ('SKIP These fixture parents already exist, so they cannot stand in for another program''s keys: '+($existing -join ', '));return}
foreach($run in $Area){
    Invoke-Area $run
    foreach($name in $areaParents[$run]){Check ((Read-Parent $name) -eq 'absent') ('The '+$run+' checks remove the '+$name+' key they created')}
}
$created=New-Object System.Collections.Generic.List[string]
try {
    foreach($name in $parents){if([RooIndustriesFixtureParent]::CreateNew('Software\'+$name)){$created.Add($name)}}
    Check ($created.Count -eq $parents.Count) 'Every empty stand-in parent key is created by this test'
    foreach($run in $Area){
        Invoke-Area $run
        foreach($name in $created){$state=Read-Parent $name;Check ($state -eq '0 subkeys, 0 values') ('An empty '+$name+' key that existed before the '+$run+' checks is kept ('+$state+')')}
    }
} finally {
    foreach($name in $created){if((Read-Parent $name) -eq '0 subkeys, 0 values'){$hive.DeleteSubKey('Software\'+$name,$false)}}
}
Check (@($created|Where-Object {(Read-Parent $_) -ne 'absent'}).Count -eq 0) 'The test removes the stand-in keys it created'
$hive.Dispose()
if($script:Failed -gt 0){throw ($script:Failed.ToString()+' fixture registry ownership checks failed')}
