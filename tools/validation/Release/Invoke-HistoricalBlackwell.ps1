param([Parameter(Mandatory=$true)][ValidateSet('Capture','Stage','Restore','Verify','Diagnose')][string]$Phase,[Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$Runner,[string]$CaptureHash='',[string]$StageHash='',[switch]$ExecuteRestoration)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'HistoricalBlackwell.Common.ps1')
Initialize-HistoricalBlackwell $Frame $Runner
$local=[Environment]::GetFolderPath('LocalApplicationData')
$app='C:\Program Files\Roo Industries\Optimization Suite'
$original=Join-Path $local 'Temp\roo-industries-integration-evidence\backup'
$sid='S-1-5-21-1846494563-3099854232-4004002307-1001'
$stateRoot='SOFTWARE\RooIndustriesOptimizationSuite'
$roots=@($stateRoot,'SOFTWARE\RooIndustries','SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1','SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1')
function Assert-FileHash([string]$Path,[string]$Hash){Assert-PlainRecoveryPath $Path;if($Hash -cnotmatch '^[A-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Path).Hash -cne $Hash){throw ('Bound file hash differs: '+$Path)}}
function Read-Capture {
    Assert-FileHash (Join-Path $Frame 'capture.json') $CaptureHash
    $c=Read-HistoricalJson (Join-Path $Frame 'capture.json')
    if($c.protocol -cne 'blackwell-historical-capture/v1' -or $c.machine -cne $env:COMPUTERNAME -or $c.sid -cne $sid -or $c.frame -cne $Frame){throw 'Capture scope changed'}
    return $c
}
function Assert-CapturedTrees($Capture) {
    foreach($c in $Capture.trees){Assert-FileHash ($c.destination+'.manifest.json') $c.manifestHash;$rows=Read-HistoricalJson ($c.destination+'.manifest.json');Assert-RecoveryEqual (Recovery-Lines $rows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $c.destination) -DataOnly) ('retained '+$c.name);Assert-SealedRecovery $c.destination}
    Assert-FileHash (Join-Path $Frame 'rollback-installer\RooIndustries-OptimizationSuite-0.9.0-beta-setup.exe') $Capture.rollbackInstaller.hash
    foreach($v in $Capture.registry|Where-Object {$_.kind -is [long] -or $_.kind -is [int]}){Assert-FileHash (Join-Path (Join-Path $Frame 'registry-asnow') $v.file) $v.sha256}
    Assert-FileHash (Join-Path $Frame 'original-state.bin') $Capture.originalState.hash
    Assert-FileHash (Join-Path $Frame 'tasks.json') $Capture.tasksHash
}
function Assert-AsNow($Capture) {
    Assert-HistoricalIdle
    foreach($c in $Capture.trees|Where-Object {$_.name -ne 'original-backup'}){$rows=Read-HistoricalJson ($c.destination+'.manifest.json');Assert-RecoveryEqual (Recovery-Lines $rows) (Recovery-Lines @(Get-RecoveryRows $c.source)) ('live '+$c.name)}
    Assert-RecoveryEqual @($Capture.siblings) @(Get-ChildItem -LiteralPath $local -Directory -Force|Where-Object Name -Match 'OptimizationSuite'|Sort-Object Name|ForEach-Object Name) 'siblings remain exact'
    Assert-RecoveryEqual (Historical-RegistryLines $Capture.registry) (Historical-RegistryLines @(Get-HistoricalRegistry $roots)) 'typed registry remains exact'
    $beforeTasks=Read-HistoricalJson (Join-Path $Frame 'tasks.json');$nowTasks=@(Get-HistoricalTasks)
    $originalNames=@($Capture.historicalTaskNames)
    $expected=@($beforeTasks|Where-Object {($_.path+$_.name) -cin $originalNames})
    $observed=@($nowTasks|Where-Object {($_.path+$_.name) -cin $originalNames})
    if($expected.Count -ne 4 -or $observed.Count -ne 4){throw 'A required historical CS2 task is absent'}
    Assert-RecoveryEqual (Historical-TaskLines $expected) (Historical-TaskLines $observed) 'four unrelated CS2 task XML SDDL enabled remain exact'
    $taskDelta=@(Compare-Object (Historical-TaskLines $beforeTasks) (Historical-TaskLines $nowTasks) -CaseSensitive)
    Save-RecoveryJson (Join-Path $Frame ('observed-tasks-'+[Guid]::NewGuid().ToString('N')+'.json')) @{tasks=$nowTasks;foreignDelta=$taskDelta;cs2Exact=$true;tasksMutated=$false}
}
function Assert-HistoricalRemovedInstallation {
    if(Test-Path -LiteralPath $app){throw 'Lead must remove the captured installed tree before Restore; rollback installer is retained'}
    foreach($key in $roots|Where-Object {$_ -like '*\Uninstall\*'}){$k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($key,$false);if($k){$k.Dispose();throw 'Captured uninstall entry still exists'}}
}
function Assert-HistoricalState([string]$ExpectedHash,[long]$Length) {
    $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(($stateRoot+'\Tweaks\'+$sid),$false)
    if(-not$k){throw 'Original State key is missing; retained'}
    try{if($k.GetValueNames() -ccontains 'Pending'){throw 'Pending State exists; retained'};$value=[RooIndustriesHistoricalBlackwell.Raw]::Read($k,'State');if($value.Kind -ne 3 -or $value.Bytes.Length -ne $Length -or (Hash-HistoricalBytes $value.Bytes) -cne $ExpectedHash){throw 'Exact typed State differs; retained'}}finally{$k.Dispose()}
}
function Assert-HistoricalPreservedTasks($Capture) {
    $old=Read-HistoricalJson (Join-Path $Frame 'tasks.json');$now=@(Get-HistoricalTasks);$names=@($Capture.historicalTaskNames)
    $expected=@($old|Where-Object {($_.path+$_.name) -cin $names});$observed=@($now|Where-Object {($_.path+$_.name) -cin $names})
    if($expected.Count -ne 4 -or $observed.Count -ne 4){throw 'A historical CS2 task is missing'}
    Assert-RecoveryEqual (Historical-TaskLines $expected) (Historical-TaskLines $observed) 'preserved historical CS2 tasks'
}
function Get-HistoricalExpectedRegistry($Capture,[switch]$Restored) {
    $registry=@($Capture.registry|Where-Object {$_.key -ceq $stateRoot -or $_.key.StartsWith($stateRoot+'\',[StringComparison]::Ordinal) -or $_.key -ceq 'SOFTWARE\RooIndustries' -or $_.key.StartsWith('SOFTWARE\RooIndustries\',[StringComparison]::Ordinal)})
    $markerKey='SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
    $markers=@(New-HistoricalMarkerPlan $registry (Join-Path $local 'RooIndustriesOptimizationSuite') $markerKey $sid)
    $plan=@{RegistryRows=$registry;MarkerKey=$markerKey;MarkerRows=$markers;StateKey=($stateRoot+'\Tweaks\'+$sid);OriginalState=$Capture.originalState}
    Get-HistoricalActivationRegistry $plan -Restored:$Restored
}
function New-HistoricalMarkerPlan($RegistryRows,[string]$Live,[string]$MarkerKey,[string]$Sid) {
    $root=[IO.Path]::GetFullPath($Live).TrimEnd('\').ToUpperInvariant()
    $ticks=@([long]134353323197027994,[long]134353323197116043,[long]134353323355184875)
    $expected=@();$i=0
    foreach($suffix in @('','\PROCESS-RULES','\OPERATIONS')){
        foreach($value in @(@{name=($root+$suffix);kind=1;bytes=[Text.Encoding]::Unicode.GetBytes($Sid+[char]0)},@{name=($root+$suffix+'|protected-at');kind=11;bytes=[BitConverter]::GetBytes($ticks[$i])})){
            $rows=@($RegistryRows|Where-Object {$_.key -ceq $MarkerKey -and $_.name -ceq $value.name})
            if($rows.Count -ne 1 -or $rows[0].kind -ne $value.kind -or $rows[0].length -ne $value.bytes.Length -or $rows[0].sha256 -cne (Hash-HistoricalBytes $value.bytes)){throw 'Captured current-root marker differs from reviewed SID/kind/FILETIME bytes'}
            $expected+=$rows[0]
        };$i++
    }
    $current=@($RegistryRows|Where-Object {$_.key -ceq $MarkerKey -and $null -ne $_.name -and ($_.name.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $_.name.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or $_.name.StartsWith($root+'|',[StringComparison]::OrdinalIgnoreCase))})
    Assert-RecoveryEqual (Historical-RegistryLines $expected) (Historical-RegistryLines $current) 'only the six reviewed current-root markers may be removed'
    return $expected
}
function Get-HistoricalActivationRegistry($Plan,[switch]$Restored) {
    foreach($value in $Plan.RegistryRows){
        if($Restored -and $value.key -ceq $Plan.MarkerKey -and $value.name -cin @($Plan.MarkerRows|ForEach-Object name)){continue}
        $row=ConvertTo-Json -InputObject $value -Compress|ConvertFrom-Json
        if($Restored -and $row.key -ceq $Plan.StateKey -and $row.name -ceq 'State'){$row.sha256=$Plan.OriginalState.hash;$row.length=$Plan.OriginalState.length}
        $row
    }
}
function Assert-HistoricalActivationState($Plan,[Microsoft.Win32.RegistryKey]$Hive,$Expected) {
    $k=$Hive.OpenSubKey($Plan.StateKey,$false)
    if(-not$k){throw 'Original State key is missing; retained'}
    try{if($k.GetValueNames() -contains 'Pending'){throw 'Pending State exists; retained'};$value=[RooIndustriesHistoricalBlackwell.Raw]::Read($k,'State');$hash=if($Expected.sha256){$Expected.sha256}else{$Expected.hash};if($value.Kind -ne 3 -or $value.Bytes.Length -ne $Expected.length -or (Hash-HistoricalBytes $value.Bytes) -cne $hash){throw 'Exact typed State differs; retained'}}finally{$k.Dispose()}
}
function Invoke-HistoricalActivation($Plan,[Microsoft.Win32.RegistryKey]$Hive,[scriptblock]$AssertIdle={}) {
    $frame=$Plan.Frame;$live=$Plan.Live
    if(Test-Path -LiteralPath (Join-Path $frame 'restore-intent.json')){throw 'An earlier Restore intent exists; retained partial state requires lead inspection, no automatic retry'}
    & $AssertIdle
    Assert-PlainRecoveryPath $frame;Assert-SealedRecovery $frame
    Assert-FileHash $Plan.OriginalStateFile $Plan.OriginalState.hash
    if((Get-Item -LiteralPath $Plan.OriginalStateFile).Length -ne $Plan.OriginalState.length){throw 'Original State length differs'}
    Assert-HistoricalActivationState $Plan $Hive $Plan.ExpectedState
    Assert-RecoveryEqual (Historical-RegistryLines $Plan.RegistryRows) (Historical-RegistryLines @(Get-HistoricalRegistry $Plan.RegistryRoots -Hive $Hive)) 'typed registry immediately before restore'
    $markers=@(New-HistoricalMarkerPlan $Plan.RegistryRows $live $Plan.MarkerKey ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    Assert-RecoveryEqual (Historical-RegistryLines $Plan.MarkerRows) (Historical-RegistryLines $markers) 'marker plan identity'
    Assert-RecoveryEqual (Recovery-Lines $Plan.NowRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'post-uninstall live root must match capture'
    $activation=Join-Path $frame ('activation-'+[Guid]::NewGuid().ToString('N'))
    Copy-VerifiedTree $Plan.Stage $activation -OriginalRows $Plan.StageRows -SealTarget|Out-Null
    $quarantine=Join-Path $frame 'asnow-live-quarantine'
    if(Test-Path -LiteralPath $quarantine){throw 'Live quarantine already exists'}
    Save-RecoveryJson (Join-Path $frame 'restore-intent.json') @{captureHash=$Plan.CaptureHash;stageHash=$Plan.StageHash;live=$live;activation=$activation;quarantine=$quarantine;originalState=$Plan.OriginalState;expectedState=$Plan.ExpectedState;removedMarkers=$markers;unknownArchiveAndOtherMarkersRetained=$true;atUtc=[DateTime]::UtcNow.ToString('o')}
    & $AssertIdle
    Assert-HistoricalActivationState $Plan $Hive $Plan.ExpectedState
    Assert-RecoveryEqual (Historical-RegistryLines $Plan.RegistryRows) (Historical-RegistryLines @(Get-HistoricalRegistry $Plan.RegistryRoots -Hive $Hive)) 'typed registry immediately before quarantine'
    Assert-RecoveryEqual (Recovery-Lines $Plan.NowRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'live immediately before quarantine'
    [IO.Directory]::Move($live,$quarantine)
    Restore-RecoveryDescriptors $Plan.NowRows $quarantine -Seal
    Assert-RecoveryEqual (Recovery-Lines $Plan.NowRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $quarantine) -DataOnly) 'live quarantine exact'
    Save-RecoveryJson (Join-Path $frame 'restore-live-quarantined.json') @{path=$quarantine;captureHash=$Plan.CaptureHash;atUtc=[DateTime]::UtcNow.ToString('o')}
    Assert-RecoveryEqual (Recovery-Lines $Plan.StageRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $activation) -DataOnly) 'activation immediately before move'
    Save-RecoveryJson (Join-Path $frame 'restore-activation-intent.json') @{live=$live;activation=$activation;stageHash=$Plan.StageHash}
    if(Test-Path -LiteralPath $live){throw 'Live path was recreated; foreign tree retained'}
    [IO.Directory]::Move($activation,$live)
    Restore-RecoveryDescriptors $Plan.StageRows $live
    Assert-RecoveryEqual (Recovery-Lines $Plan.StageRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'activated historical root'
    Save-RecoveryJson (Join-Path $frame 'restore-data-activated.json') @{live=$live;stageHash=$Plan.StageHash;atUtc=[DateTime]::UtcNow.ToString('o')}
    & $AssertIdle
    Save-RecoveryJson (Join-Path $frame 'restore-state-intent.json') @{key=$Plan.StateKey;name='State';kind=3;expectedHash=$Plan.ExpectedState.sha256;originalHash=$Plan.OriginalState.hash}
    Assert-PlainRecoveryPath $Plan.OriginalStateFile;Assert-SealedRecovery $Plan.OriginalStateFile
    $originalFile=[IO.File]::Open($Plan.OriginalStateFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($originalFile.Length -ne $Plan.OriginalState.length){throw 'Original State changed immediately before write; retained'}
        $originalBytes=New-Object byte[] ([int]$originalFile.Length);$offset=0
        while($offset -lt $originalBytes.Length){$read=$originalFile.Read($originalBytes,$offset,$originalBytes.Length-$offset);if($read -le 0){throw 'Original State read ended early'};$offset+=$read}
        if((Hash-HistoricalBytes $originalBytes) -cne $Plan.OriginalState.hash){throw 'Original State changed immediately before write; retained'}
        $remaining=@($Plan.RegistryRows);$i=0
        $key=$Hive.OpenSubKey($Plan.MarkerKey,$true)
        if(-not$key){throw 'Marker key disappeared; retained'}
        try{
            foreach($marker in $markers){
                Save-RecoveryJson (Join-Path $frame ('restore-marker-'+$i+'-intent.json')) @{key=$marker.key;name=$marker.name;expected=$marker;desired='<absent-value>'}
                Assert-HistoricalActivationState $Plan $Hive $Plan.ExpectedState
                Assert-RecoveryEqual (Historical-RegistryLines $remaining) (Historical-RegistryLines @(Get-HistoricalRegistry $Plan.RegistryRoots -Hive $Hive)) 'untargeted registry immediately before marker removal'
                $value=[RooIndustriesHistoricalBlackwell.Raw]::Read($key,$marker.name)
                if($value.Kind -ne $marker.kind -or $value.Bytes.Length -ne $marker.length -or (Hash-HistoricalBytes $value.Bytes) -cne $marker.sha256){throw 'Current-root marker changed immediately before removal; retained'}
                $key.DeleteValue($marker.name,$true);$key.Flush()
                $remaining=@($remaining|Where-Object {-not($_.key -ceq $marker.key -and $_.name -ceq $marker.name)});$i++
            }
        }finally{$key.Dispose()}
        $key=$Hive.OpenSubKey($Plan.StateKey,$true)
        if(-not$key){throw 'State key disappeared; retained'}
        try{
            Assert-RecoveryEqual (Historical-RegistryLines $remaining) (Historical-RegistryLines @(Get-HistoricalRegistry $Plan.RegistryRoots -Hive $Hive)) 'registry immediately before State write'
            if($key.GetValueNames() -contains 'Pending'){throw 'Pending State appeared; retained'}
            $state=[RooIndustriesHistoricalBlackwell.Raw]::Read($key,'State')
            if($state.Kind -ne 3 -or $state.Bytes.Length -ne $Plan.ExpectedState.length -or (Hash-HistoricalBytes $state.Bytes) -cne $Plan.ExpectedState.sha256){throw 'State changed immediately before write; retained'}
            [RooIndustriesHistoricalBlackwell.Raw]::Write($key,'State',3,$originalBytes)
        }finally{$key.Dispose()}
    }finally{$originalFile.Dispose()}
    Assert-HistoricalActivationState $Plan $Hive $Plan.OriginalState
    Assert-RecoveryEqual (Historical-RegistryLines @(Get-HistoricalActivationRegistry $Plan -Restored)) (Historical-RegistryLines @(Get-HistoricalRegistry $Plan.RegistryRoots -Hive $Hive)) 'exact original State six absent and all untargeted fields/keys'
    Assert-RecoveryEqual (Recovery-Lines $Plan.StageRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'final historical root'
}
function Assert-RestoredHistorical($Capture,$Rows) {
    Assert-HistoricalIdle;Assert-HistoricalRemovedInstallation
    Assert-RecoveryEqual (Recovery-Lines $Rows) (Recovery-Lines @(Get-RecoveryRows (Join-Path $local 'RooIndustriesOptimizationSuite'))) 'restored original root'
    Assert-HistoricalState $Capture.originalState.hash $Capture.originalState.length
    Assert-HistoricalPreservedTasks $Capture
    Assert-RecoveryEqual (Historical-RegistryLines @(Get-HistoricalExpectedRegistry $Capture -Restored)) (Historical-RegistryLines @(Get-HistoricalRegistry @($stateRoot,'SOFTWARE\RooIndustries'))) 'untargeted registry fields and exact original State'
    foreach($tree in $Capture.trees|Where-Object {$_.name -like 'current-*' -and $_.name -cne 'current-RooIndustriesOptimizationSuite'}){$rows=Read-HistoricalJson ($tree.destination+'.manifest.json');Assert-RecoveryEqual (Recovery-Lines $rows) (Recovery-Lines @(Get-RecoveryRows $tree.source)) 'unknown live sibling retained'}
}
Assert-HistoricalIdle
if($Phase -ceq 'Diagnose'){
    $sw=[Diagnostics.Stopwatch]::StartNew();$r=@(Get-HistoricalRegistry $roots)
    $proof=@{phase='Diagnose';machine=$env:COMPUTERNAME;rows=$r.Count;binaryValues=@($r|Where-Object kind -EQ 3|Select-Object key,name,length,sha256);elapsedMs=$sw.ElapsedMilliseconds;workingSet=(Get-Process -Id $PID).WorkingSet64;liveMutation=$false}
    Save-RecoveryJson (Join-Path $Frame ('diagnose-'+[Guid]::NewGuid().ToString('N')+'.json')) $proof
    $proof|ConvertTo-Json -Depth 5;exit 0
}
if($Phase -ceq 'Capture'){
    if(Test-Path -LiteralPath (Join-Path $Frame 'capture.json')){throw 'Capture already exists; retained'}
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $tasks=@(Get-HistoricalTasks);Save-RecoveryJson (Join-Path $Frame 'tasks.json') $tasks
    $regDest=Join-Path $Frame 'registry-asnow';New-SealedDirectory $regDest
    $registry=@(Get-HistoricalRegistry $roots $regDest)
    $siblings=@(Get-ChildItem -LiteralPath $local -Directory -Force|Where-Object Name -Match 'OptimizationSuite'|Sort-Object Name|ForEach-Object Name)
    $expected=@{
        'app\RooIndustries.OptimizationSuite.App.dll'='927B5D9ED5446735F1C3BF39A323EBCEBF220667594E65BFD1C5EC2F5514EE31'
        'backend\bin\optimizer\Optimizer.Host.dll'='14D0356BCFA3F888DA2A25C4FD2E212B412AAFB8CD0D15ED0C3241B758CEB38E'
        'backend\bin\optimizer\Optimizer.Core.dll'='1B73C38DC657008078B829CC68D3F874E4CC28A6D6884FA5253100A5F2D0D8F8'
        'unins000.exe'='484A5E4F7D642BF21EF86806409DEA8BA3526F50DAC57626D749FC2E7F6BBC74'
        'unins000.dat'='ECBD34F43C2EDE97B0FC8CE62A76B7D3DDE471DD94719BEC1704EDF910345C29'
    }
    foreach($relative in $expected.Keys){Assert-FileHash (Join-Path $app $relative) $expected[$relative]}
    $installer=Join-Path $local 'Temp\roo-industries-integration-src\artifacts\release\RooIndustries-OptimizationSuite-0.9.0-beta-setup.exe'
    $installerHash='70F81AE032E9BEFF9791CD5FC190B129684C43361DBFD26E7292A81AE675BA5C'
    Assert-FileHash $installer $installerHash
    if((Get-Item -LiteralPath $installer).Length -ne 109923513){throw 'Rollback installer length differs'}
    $installedRows=@(Get-RecoveryRows $installer)
    $rollback=Join-Path $Frame 'rollback-installer';New-SealedDirectory $rollback
    $result=Invoke-Native (Join-Path ([Environment]::SystemDirectory) 'robocopy.exe') @([IO.Path]::GetDirectoryName($installer),$rollback,[IO.Path]::GetFileName($installer),'/COPY:DAT','/R:0','/W:0','/NFL','/NDL','/NP')
    if($result.Exit -lt 0 -or $result.Exit -ge 8){throw 'Rollback installer copy failed'}
    $savedInstaller=Join-Path $rollback ([IO.Path]::GetFileName($installer))
    Assert-RecoveryEqual (Recovery-Lines $installedRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $savedInstaller) -DataOnly) 'installer exact bytes metadata'
    Restore-RecoveryDescriptors $installedRows $savedInstaller -Seal
    Assert-SealedRecovery $savedInstaller
    Save-RecoveryJson (Join-Path $Frame 'rollback-installer.manifest.json') $installedRows
    $sources=@(@{name='installed-app';source=$app},@{name='original-backup';source=$original})
    foreach($name in $siblings){$sources+=@{name=('current-'+$name);source=(Join-Path $local $name)}}
    $trees=@()
    foreach($s in $sources){$target=Join-Path $Frame $s.name;$rows=@(Get-RecoveryRows $s.source);Copy-VerifiedTree $s.source $target -SealTarget|Out-Null;$trees+=[pscustomobject]@{name=$s.name;source=$s.source;destination=$target;items=@($rows).Count;manifestHash=(Get-FileHash -LiteralPath ($target+'.manifest.json')).Hash}}
    $baseline=Read-HistoricalJson (Join-Path $original 'machine-state.json')
    if($baseline.appFolder -ne $false -or @($baseline.uninstallEntries).Count -ne 0 -or @($baseline.productKeys).Count -ne 0 -or $baseline.tweakStateKey -cne 'C90311CD2646AC0DCF74272CDF80B271621BBE19F04DE8BF4E0E57D0DDFA2687'){throw 'Historical baseline contradicts reviewed identity'}
    $metadataMatches=$true;try{$metadata=Assert-HistoricalMetadata (Join-Path $original 'RooIndustriesOptimizationSuite') (Join-Path $original 'RooIndustriesOptimizationSuite.fingerprint.txt')}catch{$metadataMatches=$false;$metadata=@([IO.File]::ReadAllLines((Join-Path $original 'RooIndustriesOptimizationSuite.fingerprint.txt'),[Text.Encoding]::UTF8))}
    $old=[RooIndustriesHistoricalBlackwell.Export]::State((Join-Path $Frame 'original-backup\tweak-state.reg'),('HKEY_LOCAL_MACHINE\'+$stateRoot+'\Tweaks\'+$sid))
    Save-HistoricalBinary (Join-Path $Frame 'original-state.bin') $old
    $manifests=@(foreach($name in '.migrated','.migrating'){$path=Join-Path (Join-Path $Frame 'current-RooIndustriesOptimizationSuite') $name;if(Test-Path -LiteralPath $path){@{name=$name;hash=(Get-FileHash -LiteralPath $path).Hash;manifest=(Read-HistoricalJson $path)}}})
    $capture=[ordered]@{protocol='blackwell-historical-capture/v1';machine=$env:COMPUTERNAME;sid=$sid;frame=$Frame;atUtc=[DateTime]::UtcNow.ToString('o');trees=$trees;registry=$registry;siblings=$siblings;tasksHash=(Get-FileHash -LiteralPath (Join-Path $Frame 'tasks.json')).Hash;taskCount=$tasks.Count;historicalTaskNames=@($baseline.tasks);historicalTaskDefinitionsAvailable=$false;historicalEarliestByteHashesAvailable=$false;originalMetadataMatches=$metadataMatches;originalItems=$metadata.Count;baselineHash=(Get-FileHash -LiteralPath (Join-Path $original 'machine-state.json')).Hash;exportHash=(Get-FileHash -LiteralPath (Join-Path $original 'tweak-state.reg')).Hash;originalState=@{hash=(Hash-HistoricalBytes $old);length=$old.Length;kind=3};migrationManifests=$manifests;rollbackInstaller=@{source=$installer;hash=$installerHash;length=109923513};installedHashes=$expected;elapsedMs=$sw.ElapsedMilliseconds}
    Assert-CapturedTrees $capture
    Assert-AsNow $capture
    Save-RecoveryJson (Join-Path $Frame 'capture.json') $capture
    @{phase='captured';frame=$Frame;captureHash=(Get-FileHash -LiteralPath (Join-Path $Frame 'capture.json')).Hash;taskCount=$tasks.Count;trees=@($trees|Select-Object name,items,manifestHash);originalItems=$metadata.Count;originalState=$capture.originalState;elapsedMs=$sw.ElapsedMilliseconds;liveMutation=$false}|ConvertTo-Json -Depth 6
    exit 0
}
$c=Read-Capture
Assert-CapturedTrees $c
if($Phase -ceq 'Stage'){
    Assert-AsNow $c
    $archive=Join-Path $Frame 'current-RooIndustriesOptimizationSuite.untrusted-7a584bc7aea0469aa8dd9c16378890ee'
    $archiveRows=Read-HistoricalJson ($archive+'.manifest.json')
    $stage=Join-Path $Frame 'stage-original'
    . (Join-Path $PSScriptRoot 'Stage-HistoricalBlackwell.ps1')
        $fallback=Join-Path $Frame 'original-backup\RooIndustriesOptimizationSuite'
    $fullBackupRows=Read-HistoricalJson (Join-Path $Frame 'original-backup.manifest.json');$prefix='\RooIndustriesOptimizationSuite'
    $fallbackRows=@($fullBackupRows|Where-Object {$_.relative -ceq $prefix -or $_.relative.StartsWith($prefix+'\',[StringComparison]::Ordinal)}|ForEach-Object {$v=ConvertTo-Json -InputObject $_ -Compress|ConvertFrom-Json;$v.relative=$v.relative.Substring($prefix.Length);$v})
    $assembly=New-HistoricalStage $archive $archiveRows (Join-Path $Frame 'original-backup\RooIndustriesOptimizationSuite.fingerprint.txt') $stage (Join-Path $Frame 'stage-extra-quarantine') $fallback $fallbackRows
    $rows=$assembly.rows
    if($rows.Count -ne $c.originalItems){throw 'Historical assembly count differs'}
    Restore-RecoveryDescriptors $rows $stage -Seal
    Assert-SealedRecovery $stage
    Assert-RecoveryEqual (Recovery-Lines $rows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $stage) -DataOnly) 'sealed historical assembly'
    Save-RecoveryJson ($stage+'.historical-manifest.json') $rows
    Assert-AsNow $c
    $proof=@{protocol='blackwell-historical-stage/v1';captureHash=$CaptureHash;frame=$Frame;stage=$stage;manifestHash=(Get-FileHash -LiteralPath ($stage+'.historical-manifest.json')).Hash;assemblyHash=(Get-FileHash -LiteralPath ($stage+'.assembled.json')).Hash;items=$rows.Count;originalState=$c.originalState;liveMutation=$false;restorationExecuted=$false;registryDecision='requires exact history/provenance approval';archiveDecision='preserve unknown archive in place';installationDecision='lead must uninstall bound retained installation'}
    Save-RecoveryJson (Join-Path $Frame 'stage.json') $proof
    @{phase='staged';frame=$Frame;stageHash=(Get-FileHash -LiteralPath (Join-Path $Frame 'stage.json')).Hash;items=$rows.Count;restorationExecuted=$false}|ConvertTo-Json -Compress;exit 0
}
Assert-FileHash (Join-Path $Frame 'stage.json') $StageHash
$s=Read-HistoricalJson (Join-Path $Frame 'stage.json')
if($s.protocol -cne 'blackwell-historical-stage/v1' -or $s.captureHash -cne $CaptureHash -or $s.stage -cne (Join-Path $Frame 'stage-original')){throw 'Stage scope differs'}
Assert-FileHash ($s.stage+'.historical-manifest.json') $s.manifestHash
$stageRows=Read-HistoricalJson ($s.stage+'.historical-manifest.json')
Assert-RecoveryEqual (Recovery-Lines $stageRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $s.stage) -DataOnly) 'stage before activation'
Assert-SealedRecovery $s.stage
if($Phase -ceq 'Verify'){
    if(Test-Path -LiteralPath (Join-Path $Frame 'restore-complete.json')){
        $done=Read-HistoricalJson (Join-Path $Frame 'restore-complete.json')
        if($done.captureHash -cne $CaptureHash -or $done.stageHash -cne $StageHash){throw 'Restored journal belongs to another plan'}
        Assert-RestoredHistorical $c $stageRows
        @{phase='verified-restoration';frame=$Frame;restorationExecuted=$true}|ConvertTo-Json -Compress;exit 0
    }
    Assert-AsNow $c
    $proof=@{phase='verified-preparation';captureHash=$CaptureHash;stageHash=$StageHash;frame=$Frame;cs2TasksExact=$true;allTasksSnapshotsRetained=$true;liveTreesExact=$true;registryExact=$true;hkcuSoftwareStateAbsent=$true;rollbackInstallerRetained=$true;originalStageExact=$true;restorationExecuted=$false}
    Save-RecoveryJson (Join-Path $Frame ('verify-'+[Guid]::NewGuid().ToString('N')+'.json')) $proof
    $proof|ConvertTo-Json -Compress;exit 0
}
if($Phase -ceq 'Restore'){
    if(-not$ExecuteRestoration){throw 'Restore remains unexecuted; lead must review and explicitly execute the bound plan'}
    Assert-HistoricalRemovedInstallation
    if(Test-Path -LiteralPath (Join-Path $Frame 'restore-intent.json')){throw 'An earlier Restore intent exists; retained partial state requires lead inspection, no automatic retry'}
    Assert-HistoricalPreservedTasks $c
    $asnow=@($c.registry|Where-Object {$_.key -ceq ($stateRoot+'\Tweaks\'+$sid) -and $_.name -ceq 'State'})
    if($asnow.Count -ne 1 -or $asnow[0].kind -ne 3 -or $c.originalState.hash -cne '71B282CD2E17350580AF59E58932BF2BFDCEA24E8E3CAC6581A49C7525A635DC' -or $asnow[0].sha256 -cne '7A045E71ED86E7B59E9778AA43962A99A62A30219E128F50A5E3888309C09994'){throw 'State delta is outside the audited historical pair'}
    Assert-HistoricalState $asnow[0].sha256 $asnow[0].length
    Assert-RecoveryEqual (Historical-RegistryLines @(Get-HistoricalExpectedRegistry $c)) (Historical-RegistryLines @(Get-HistoricalRegistry @($stateRoot,'SOFTWARE\RooIndustries'))) 'post-uninstall untargeted registry fields'
    $current=@($c.trees|Where-Object name -CEQ 'current-RooIndustriesOptimizationSuite');if($current.Count -ne 1){throw 'Current root identity is missing'}
    $nowRows=Read-HistoricalJson ($current[0].destination+'.manifest.json')
    $live=Join-Path $local 'RooIndustriesOptimizationSuite'
    Assert-RecoveryEqual (Recovery-Lines $nowRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'post-uninstall live root must match capture'
    Assert-FileHash (Join-Path $Frame 'original-backup\machine-state.json') $c.baselineHash
    $baseline=Read-HistoricalJson (Join-Path $Frame 'original-backup\machine-state.json')
    if(@($baseline.productKeys).Count -ne 0){throw 'Historical product-key absence is unproved; marker fields retained'}
    $registry=@(Get-HistoricalExpectedRegistry $c)
    $markerKey='SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
    $markers=@(New-HistoricalMarkerPlan $registry $live $markerKey $sid)
    $plan=@{Frame=$Frame;Live=$live;Stage=$s.stage;StageRows=$stageRows;NowRows=$nowRows;RegistryRoots=@($stateRoot,'SOFTWARE\RooIndustries');StateKey=($stateRoot+'\Tweaks\'+$sid);MarkerKey=$markerKey;RegistryRows=$registry;MarkerRows=$markers;OriginalStateFile=(Join-Path $Frame 'original-state.bin');OriginalState=$c.originalState;ExpectedState=$asnow[0];CaptureHash=$CaptureHash;StageHash=$StageHash}
    Assert-HistoricalIdle
    Invoke-HistoricalActivation $plan ([Microsoft.Win32.Registry]::LocalMachine) {Assert-HistoricalIdle}
    Assert-RestoredHistorical $c $stageRows
    Save-RecoveryJson (Join-Path $Frame 'restore-complete.json') @{captureHash=$CaptureHash;stageHash=$StageHash;atUtc=[DateTime]::UtcNow.ToString('o');unknownArchiveAndOtherMarkersRetained=$true;removedCurrentRootMarkers=6;fullEarliestMachineRestoration=$false}
    @{phase='restored-data-and-state';restorationExecuted=$true;unknownArchiveAndOtherMarkersRetained=$true;removedCurrentRootMarkers=6;fullEarliestMachineRestoration=$false}|ConvertTo-Json -Compress
}
