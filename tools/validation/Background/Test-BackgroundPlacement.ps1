param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'backend\scripts\BackgroundPlacement.Common.ps1')
function Topology([int]$Count,[scriptblock]$Efficiency,[scriptblock]$Cache) {
    @(0..($Count-1)|ForEach-Object {[pscustomobject]@{group=0;logicalProcessorIndex=$_;efficiencyClass=(& $Efficiency $_);lastLevelCacheIndex=(& $Cache $_)}})
}
$intel=Topology 20 {param($i) if($i -lt 12){1}else{0}} {0}
$meteor=Topology 16 {param($i) if($i -lt 8){2}elseif($i -lt 12){1}else{0}} {0}
$amd=Topology 32 {0} {param($i) if($i -lt 16){0}else{1}}
$single=Topology 16 {0} {0}
$four=Topology 64 {0} {param($i) [int][Math]::Floor($i/16)}
$cases=@(
    @{name='i5-14600K';topology=$intel;groups=1;mask=[long]1044480;kind='e-cores';available=$true},
    @{name='Meteor-Lake';topology=$meteor;groups=1;mask=[long]65280;kind='e-cores';available=$true},
    @{name='9950X3D';topology=$amd;groups=1;mask=[long]4294901760;kind='ccd';available=$true},
    @{name='7800X3D';topology=$single;groups=1;mask=[long]0;kind='';available=$false},
    @{name='four-caches-bit-63';topology=$four;groups=1;mask=[long]-65536;kind='ccd';available=$true},
    @{name='two-groups';topology=$amd;groups=2;mask=[long]0;kind='';available=$false},
    @{name='restricted-system-mask';topology=$amd;groups=1;system=[long]16777215;mask=[long]16711680;kind='ccd';available=$true},
    @{name='empty-intersection';topology=$amd;groups=1;system=[long]65535;mask=[long]0;kind='ccd';available=$false},
    @{name='missing-cpu-zero';topology=@($amd|Where-Object {$_.logicalProcessorIndex -ne 0});groups=1;mask=[long]0;kind='';available=$false},
    @{name='duplicate-logical-cpu';topology=@($amd)+@($amd[0]);groups=1;mask=[long]0;kind='';available=$false},
    @{name='empty-topology';topology=@();groups=1;mask=[long]0;kind='';available=$false}
)
$results=@()
foreach($case in $cases) {
    $arguments=@{Topology=$case.topology;ProcessorGroupCount=$case.groups}
    if($case.ContainsKey('system')){$arguments.SystemAffinityMask=$case.system}
    $actual=Get-RooIndustriesBackgroundPlacement @arguments
    $passed=($actual.available -eq $case.available -and [long]$actual.mask -eq $case.mask -and $actual.kind -ceq $case.kind)
    $results+=@{case=$case.name;input=$case;observed=$actual;passed=$passed}
}
[IO.File]::WriteAllText($OutputPath,($results|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
if(@($results|Where-Object {-not$_.passed}).Count){throw 'Background placement contract failed; inspect the result JSON'}
'Background placement cases passed: '+$results.Count
