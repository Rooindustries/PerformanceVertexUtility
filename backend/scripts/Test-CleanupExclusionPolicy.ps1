$ErrorActionPreference='Stop'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-exclusion-policy-'+[Guid]::NewGuid().ToString('N'))
try {
    $scripts=Join-Path $root 'scripts'
    [IO.Directory]::CreateDirectory($scripts)|Out-Null
    foreach($name in 'UninstallCleanup.Common.ps1','BrandCompatibility.Common.ps1'){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts}
    $calls=Join-Path $root 'calls.log'
    [IO.File]::WriteAllText((Join-Path $scripts 'Invoke-CleanupExclusions.ps1'),"param([string]`$Action,[string[]]`$FileTarget)`n[IO.File]::AppendAllText('$calls',(`$FileTarget -join ';')+[Environment]::NewLine)`n")
    . (Join-Path $scripts 'UninstallCleanup.Common.ps1')

    $localData=Join-Path $root 'local'
    [IO.Directory]::CreateDirectory($localData)|Out-Null
    Assert ((Get-RooIndustriesLocalDataRoot -LocalData $localData) -eq (Join-Path $localData 'RooIndustriesOptimizationSuite')) 'Without a legacy folder the current data folder holds cleanup exclusions'
    $legacyData=Join-Path $localData $script:RooIndustriesLegacyIdentity.dataFolder
    [IO.Directory]::CreateDirectory($legacyData)|Out-Null
    Assert ((Get-RooIndustriesLocalDataRoot -LocalData $localData) -eq $legacyData) 'An existing legacy folder holds cleanup exclusions like the native host'

    $dataRoot=Get-RooIndustriesLocalDataRoot -LocalData $localData
    $policy=Join-Path $dataRoot 'cleanup-exclusions.json'
    $owner=@{machine=$env:COMPUTERNAME;userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
    function Save-Policy($Document){if($null -eq $Document){if(Test-Path -LiteralPath $policy){Remove-Item -LiteralPath $policy}}elseif($Document -is [string]){[IO.File]::WriteAllText($policy,$Document)}else{[IO.File]::WriteAllText($policy,($Document|ConvertTo-Json -Depth 8))}}
    function Get-CheckCount{if(Test-Path -LiteralPath $calls){@(Get-Content -LiteralPath $calls).Count}else{0}}
    $cases=@(
        @{name='no saved list';document=$null;checked=$false},
        @{name='an empty list saved by this user';document=@{schemaVersion=1;owner=$owner;exclusions=@{paths=@();registry=@()}};checked=$false},
        @{name='an empty list saved by another user';document=@{schemaVersion=1;owner=@{machine=$env:COMPUTERNAME;userSid='S-1-5-21-1-2-3-1001'};exclusions=@{paths=@();registry=@()}};checked=$true},
        @{name='a list with an excluded path';document=@{schemaVersion=1;owner=$owner;exclusions=@{paths=@('C:\Keep\data.txt');registry=@()}};checked=$true},
        @{name='an unreadable list';document='{"schemaVersion":1';checked=$true},
        @{name='a list without its registry section';document=@{schemaVersion=1;owner=$owner;exclusions=@{paths=@()}};checked=$true}
    )
    foreach($case in $cases){
        Save-Policy $case.document
        $before=Get-CheckCount
        Assert-RooIndustriesCleanupExclusions -Targets @('C:\Cleanup\target.txt') -DataRoot $dataRoot
        $checked=(Get-CheckCount) -gt $before
        Assert ($checked -eq $case.checked) ("Cleanup "+$(if($case.checked){'asks the exclusion host'}else{'skips the exclusion host'})+" for "+$case.name)
    }
    Save-Policy @{schemaVersion=1;owner=$owner;exclusions=@{paths=@('C:\Keep\data.txt');registry=@()}}
    $before=Get-CheckCount
    Assert-RooIndustriesCleanupExclusions -Targets @() -DataRoot $dataRoot
    Assert ((Get-CheckCount) -eq $before) 'Cleanup with no targets needs no exclusion check'
} finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
Assert (-not(Test-Path -LiteralPath $root)) 'Exclusion policy validation removes its fixture'
