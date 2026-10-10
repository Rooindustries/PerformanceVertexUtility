param([Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$Runner,[switch]$PreparedPrivateOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HistoricalBlackwell.Common.ps1')
Initialize-HistoricalBlackwell $Frame $Runner
$parent='C:\Windows\Temp\roo-industries-percent-folders'
$test=Join-Path $parent ('historical-blackwell-'+[Guid]::NewGuid().ToString('N'))
$savedBackup=$backup;$backup=$test;try{Assert-RecoveryEvidenceParent}finally{$backup=$savedBackup}
New-SealedDirectory $test
if(-not$PreparedPrivateOnly){
$source=Join-Path $test 'source%';New-SealedDirectory $source
[IO.File]::WriteAllBytes((Join-Path $source 'payload.bin'),[byte[]](0,1,2,3,255))
$item=Get-Item -LiteralPath (Join-Path $source 'payload.bin');$item.CreationTimeUtc=[DateTime]'2020-01-02T03:04:05Z';$item.LastWriteTimeUtc=[DateTime]'2021-02-03T04:05:06Z'
$before=@(Get-RecoveryRows $source)
$copy=Join-Path $test 'capture%'
Copy-VerifiedTree $source $copy -SealTarget|Out-Null
$stage=Join-Path $test 'stage%'
Copy-VerifiedTree $copy $stage -OriginalRows $before|Out-Null
Assert-RecoveryEqual (Recovery-Lines $before) (Recovery-Lines @(Get-RecoveryRows $stage)) 'private stage exact bytes metadata descriptors'
[IO.File]::WriteAllBytes((Join-Path $stage 'payload.bin'),[byte[]](9,9,9))
$refused=$false;try{Assert-RecoveryEqual (Recovery-Lines $before) (Recovery-Lines @(Get-RecoveryRows $stage)) 'damaged stage'}catch{$refused=$true}
if(-not$refused){throw 'Damaged stage was accepted'}
$reg=Join-Path $test 'original.reg'
[IO.File]::WriteAllText($reg,"Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SOFTWARE\wrong]`r`n`"State`"=hex:09,09`r`n`r`n[HKEY_LOCAL_MACHINE\SOFTWARE\expected]`r`n`"State`"=hex:00,01,02,\`r`n  03,ff`r`n`"After`"=dword:00000001`r`n",[Text.Encoding]::Unicode)
$bytes=[RooHistoricalBlackwell.Export]::State($reg,'HKEY_LOCAL_MACHINE\SOFTWARE\expected')
if((Hash-HistoricalBytes $bytes) -cne (Hash-HistoricalBytes ([byte[]](0,1,2,3,255)))){throw 'Section boundary/continued binary parser failed'}
$missing=$false;try{[RooHistoricalBlackwell.Export]::State($reg,'HKEY_LOCAL_MACHINE\SOFTWARE\absent')|Out-Null}catch{$missing=$true}
if(-not$missing){throw 'Missing section was accepted'}
Assert-RecoveryEqual (Recovery-Lines $before) (Recovery-Lines @(Get-RecoveryRows $source)) 'private source unchanged'
$proof=@{protocol='blackwell-private-recovery-check/v1';frame=$test;exactClone=$true;damagedStageRefused=$true;wrongSectionRefused=$true;continuedBinaryExact=$true;sourceUnchanged=$true;liveMutation=$false}
Save-RecoveryJson (Join-Path $test 'proof.json') $proof
$proof|ConvertTo-Json -Compress

$assembly=Join-Path $test 'assembly-source%';Copy-VerifiedTree $source $assembly|Out-Null
$originalRows=@(Get-RecoveryRows $assembly)
$fingerprint=Join-Path $test 'original.fingerprint.txt'
$lines=@($originalRows|ForEach-Object {$_.relative+'|'+$(if($_.directory){'dir'}else{[string]$_.length})+'|'+[DateTime]::new([long]$_.write,[DateTimeKind]::Utc).ToString('o')+'|'+[string][IO.FileAttributes][int]$_.attributes+'|'+$_.sddl}|Sort-Object)
[IO.File]::WriteAllLines($fingerprint,$lines,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllBytes((Join-Path $assembly 'extra-owned-copy.bin'),[byte[]](11,12,13))
$assemblyRows=@(Get-RecoveryRows $assembly);Restore-RecoveryDescriptors $assemblyRows $assembly -Seal
. (Join-Path $PSScriptRoot 'Stage-HistoricalBlackwell.ps1')
$result=New-HistoricalStage $assembly $assemblyRows $fingerprint (Join-Path $test 'assembled%') (Join-Path $test 'quarantine%')
Copy-VerifiedTree $result.stage (Join-Path $test 'activation-check%') -OriginalRows $result.rows|Out-Null
Assert-HistoricalMetadata (Join-Path $test 'activation-check%') $fingerprint|Out-Null
Restore-RecoveryDescriptors $result.rows (Join-Path $test 'activation-check%') -Seal
if(-not(Test-Path -LiteralPath (Join-Path $result.quarantine 'extra-owned-copy.bin'))){throw 'Extra copied data was not quarantined'}
if((Hash-HistoricalBytes ([IO.File]::ReadAllBytes((Join-Path $result.stage 'payload.bin')))) -cne (Hash-HistoricalBytes ([byte[]](0,1,2,3,255)))){throw 'Assembled original byte content differs'}
Restore-RecoveryDescriptors @(Get-RecoveryRows $result.stage) $result.stage -Seal
Save-RecoveryJson (Join-Path $test 'assembly-proof.json') @{exactMetadata=$true;extraCopyQuarantined=$true;originalBytesMatch=$true;liveMutation=$false}
'PASS private historical assembly preserves extra copied data and historical metadata'

$fallback=Join-Path $test 'fallback%';Copy-VerifiedTree $source $fallback -SealTarget|Out-Null
$fallbackRows=Read-HistoricalJson ($fallback+'.manifest.json')
$damaged=Join-Path $test 'archive-different%';Copy-VerifiedTree $source $damaged|Out-Null
[IO.File]::WriteAllBytes((Join-Path $damaged 'payload.bin'),[byte[]](22,23,24))
$damagedRows=@(Get-RecoveryRows $damaged);Restore-RecoveryDescriptors $damagedRows $damaged -Seal
$rebuilt=New-HistoricalStage $damaged $damagedRows $fingerprint (Join-Path $test 'fallback-assembled%') (Join-Path $test 'fallback-quarantine%') $fallback $fallbackRows
Copy-VerifiedTree $rebuilt.stage (Join-Path $test 'fallback-activation%') -OriginalRows $rebuilt.rows|Out-Null
Assert-HistoricalMetadata (Join-Path $test 'fallback-activation%') $fingerprint|Out-Null
Restore-RecoveryDescriptors $rebuilt.rows (Join-Path $test 'fallback-activation%') -Seal
Save-RecoveryJson (Join-Path $test 'fallback-proof.json') @{wrongArchiveVersionQuarantined=$true;metadataMatchedFallbackUsed=$true;liveMutation=$false}
'PASS historical assembly uses exact fallback metadata and keeps the different archive version'

$privateKey='Software\RooHistoricalBlackwellValidation-'+[Guid]::NewGuid().ToString('N')
$key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($privateKey)
try{
    $security=[Security.AccessControl.RegistrySecurity]::new();$security.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;KA;;;SY)(A;;KA;;;BA)');$key.SetAccessControl($security)
    $large=New-Object byte[] 6879461;$large[0]=1;$large[$large.Length-1]=255
    [RooHistoricalBlackwell.Raw]::Write($key,'Binary',3,$large)
    $raw=[RooHistoricalBlackwell.Raw]::Read($key,'Binary');if($raw.Kind -ne 3 -or $raw.Bytes.Length -ne $large.Length -or (Hash-HistoricalBytes $raw.Bytes) -cne (Hash-HistoricalBytes $large)){throw 'Large private raw binary roundtrip differs'}
    Save-HistoricalBinary (Join-Path $test 'large-registry.bin') $raw.Bytes
    [RooHistoricalBlackwell.Raw]::Write($key,'None',0,[byte[]]::new(0));$none=[RooHistoricalBlackwell.Raw]::Read($key,'None');if($none.Kind -ne 0 -or $none.Bytes.Length -ne 0){throw 'Empty REG_NONE differs'}
    $expand=[Text.Encoding]::Unicode.GetBytes('%ROO_HISTORICAL_ABSENT%'+[char]0);[RooHistoricalBlackwell.Raw]::Write($key,'Expand',2,$expand)
    $roundtrip=[RooHistoricalBlackwell.Raw]::Read($key,'Expand');if($roundtrip.Kind -ne 2 -or (Hash-HistoricalBytes $roundtrip.Bytes) -cne (Hash-HistoricalBytes $expand)){throw 'Literal expandable string bytes differ'}
    if($key.GetValue('Expand',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne '%ROO_HISTORICAL_ABSENT%'){throw 'Literal expandable string changed'}
    Save-RecoveryJson (Join-Path $test 'registry-proof.json') @{privateKey=$privateKey;largeBinaryExact=$true;emptyNoneExact=$true;expandRawExact=$true;privateProductKeysUntouched=$true}
}finally{$key.Dispose()}
'PASS private Windows raw registry capture and restoration preserve large binary, empty None and literal ExpandString'

$ambiguous=Join-Path $test 'ambiguous%';Copy-VerifiedTree $source $ambiguous|Out-Null
$target=Join-Path $ambiguous 'payload.bin';[IO.File]::WriteAllBytes($target,[byte[]](5,4,3,2,1));$item=Get-Item -LiteralPath $target;$item.CreationTimeUtc=[DateTime]'2020-01-02T03:04:05Z';$item.LastWriteTimeUtc=[DateTime]'2021-02-03T04:05:06Z'
$ambiguousRows=@(Get-RecoveryRows $ambiguous);Restore-RecoveryDescriptors $ambiguousRows $ambiguous -Seal
$ambiguityRefused=$false;try{New-HistoricalStage $ambiguous $ambiguousRows $fingerprint (Join-Path $test 'ambiguous-stage%') (Join-Path $test 'ambiguous-quarantine%') $fallback $fallbackRows|Out-Null}catch{if($_.Exception.Message -like '*Conflicting retained file hashes*'){$ambiguityRefused=$true}else{throw}}
if(-not$ambiguityRefused){throw 'Equal metadata with different source bytes was accepted'}
Save-RecoveryJson (Join-Path $test 'ambiguity-proof.json') @{sameMetadataDifferentBytesRefused=$true;liveMutation=$false}
'PASS equal historical metadata with different retained source bytes is refused'

}

$tokens=$null;$errors=$null
$restoreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-HistoricalBlackwell.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Restore source does not parse'}
foreach($name in 'Assert-FileHash','New-HistoricalMarkerPlan','Get-HistoricalActivationRegistry','Assert-HistoricalActivationState','Invoke-HistoricalActivation'){
    $nodes=@($restoreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw ('Shared restore body unavailable: '+$name)}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$nativeSave=(Get-Item Function:Save-RecoveryJson).ScriptBlock
if(-not$PreparedPrivateOnly){
function Save-RecoveryJson([string]$Path,$Value){
    & $nativeSave $Path $Value
    $leaf=[IO.Path]::GetFileName($Path)
    if($leaf -ceq 'restore-live-quarantined.json' -and $case -ceq 'recreated-root'){
        [IO.Directory]::CreateDirectory($plan.Live)|Out-Null
        [IO.File]::WriteAllText((Join-Path $plan.Live 'foreign.txt'),'foreign recreated root')
        $script:foreignRows=@(Get-RecoveryRows $plan.Live)
    }
    if(($case -ceq 'interrupt-quarantine' -and $leaf -ceq 'restore-live-quarantined.json') -or ($case -ceq 'interrupt-activation' -and $leaf -ceq 'restore-data-activated.json')){throw ('Injected interruption: '+$case)}
    if($case -ceq 'changed-original-state' -and $leaf -ceq 'restore-state-intent.json'){[IO.File]::WriteAllBytes($plan.OriginalStateFile,[byte[]](99,98,97,96,95))}
}
$cases=@('success','changed-sid','changed-kind','changed-qword','same-name-foreign','extra-marker','interrupt-quarantine','interrupt-activation','recreated-root','changed-original-state')
$results=@()
foreach($case in $cases){
    $caseRoot=Join-Path $test ($case+'-'+[Guid]::NewGuid().ToString('N'));New-SealedDirectory $caseRoot
    $original=Join-Path $caseRoot 'original';New-SealedDirectory $original
    [IO.File]::WriteAllText((Join-Path $original 'payload.bin'),'original root')
    $acl=Get-Acl -LiteralPath $original;$acl.SetAccessRuleProtection($false,$true);Set-Acl -LiteralPath $original -AclObject $acl
    $originalRows=@(Get-RecoveryRows $original)
    if([int]$originalRows[0].control -band 4096){throw 'Original fixture root is protected'}
    $originalStage=Join-Path $caseRoot 'stage';Copy-VerifiedTree $original $originalStage -SealTarget|Out-Null
    $live=Join-Path $caseRoot 'RooIndustriesOptimizationSuite';New-SealedDirectory $live
    [IO.File]::WriteAllText((Join-Path $live 'payload.bin'),'as-now root')
    $liveRows=@(Get-RecoveryRows $live)
    $asnowCopy=Join-Path $caseRoot 'asnow-copy';Copy-VerifiedTree $live $asnowCopy -SealTarget|Out-Null
    $originalFile=Join-Path $caseRoot 'original-state.bin';Save-HistoricalBinary $originalFile ([byte[]](0,1,2,3,255))
    $privateRoot='Software\RooHistoricalBlackwellRestore-'+[Guid]::NewGuid().ToString('N')
    $markerKey=$privateRoot+'\GovernorRoots';$stateKey=$privateRoot+'\Tweaks\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $hive=[Microsoft.Win32.Registry]::CurrentUser
    $k=$hive.CreateSubKey($markerKey)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ticks=@([long]134353323197027994,[long]134353323197116043,[long]134353323355184875)
    $markerNames=@();$i=0
    foreach($suffix in @('','\PROCESS-RULES','\OPERATIONS')){
        $name=$live.ToUpperInvariant()+$suffix;$markerNames+=$name;$markerNames+=($name+'|protected-at')
        [RooHistoricalBlackwell.Raw]::Write($k,$name,1,[Text.Encoding]::Unicode.GetBytes($sid+[char]0))
        [RooHistoricalBlackwell.Raw]::Write($k,($name+'|protected-at'),11,[BitConverter]::GetBytes($ticks[$i]));$i++
    }
    for($i=0;$i -lt 42;$i++){
        $name=(Join-Path $caseRoot ('foreign-fixture-'+$i+'\operations')).ToUpperInvariant()
        [RooHistoricalBlackwell.Raw]::Write($k,$name,1,[Text.Encoding]::Unicode.GetBytes($sid+[char]0))
        [RooHistoricalBlackwell.Raw]::Write($k,($name+'|protected-at'),11,[BitConverter]::GetBytes([long](134353323197027994+$i)))
    }
    [RooHistoricalBlackwell.Raw]::Write($k,($live.ToUpperInvariant()+'.SIBLING'),3,[byte[]](7,8,9))
    [RooHistoricalBlackwell.Raw]::Write($k,'OTHER-SID',1,[Text.Encoding]::Unicode.GetBytes('S-1-5-18'+[char]0));$k.Dispose()
    $empty=$hive.CreateSubKey($markerKey+'\empty');$empty.Dispose()
    $k=$hive.CreateSubKey($stateKey);[RooHistoricalBlackwell.Raw]::Write($k,'State',3,[byte[]](5,6,7,8,255));$k.Dispose()
    $registry=@(Get-HistoricalRegistry @($privateRoot) -Hive $hive)
    $markerRows=@(New-HistoricalMarkerPlan $registry $live $markerKey $sid)
    $state=@($registry|Where-Object {$_.key -ceq $stateKey -and $_.name -ceq 'State'})[0]
    $plan=[pscustomobject]@{Frame=$caseRoot;Live=$live;Stage=$originalStage;StageRows=$originalRows;NowRows=$liveRows;RegistryRoots=@($privateRoot);StateKey=$stateKey;MarkerKey=$markerKey;RegistryRows=$registry;MarkerRows=$markerRows;OriginalStateFile=$originalFile;OriginalState=@{kind=3;hash=(Hash-HistoricalBytes ([byte[]](0,1,2,3,255)));length=5};ExpectedState=$state;CaptureHash=('A'*64);StageHash=('B'*64)}
    $k=$hive.OpenSubKey($markerKey,$true)
    switch($case){
        'changed-sid' {[RooHistoricalBlackwell.Raw]::Write($k,$markerNames[0],1,[Text.Encoding]::Unicode.GetBytes('S-1-5-18'+[char]0))}
        'changed-kind' {[RooHistoricalBlackwell.Raw]::Write($k,$markerNames[0],2,[Text.Encoding]::Unicode.GetBytes($sid+[char]0))}
        'changed-qword' {[RooHistoricalBlackwell.Raw]::Write($k,$markerNames[1],11,[BitConverter]::GetBytes([long]134353323197027995))}
        'same-name-foreign' {[RooHistoricalBlackwell.Raw]::Write($k,$markerNames[0],3,[byte[]](99,0,255))}
        'extra-marker' {[RooHistoricalBlackwell.Raw]::Write($k,($live.ToUpperInvariant()+'\UNKNOWN'),1,[Text.Encoding]::Unicode.GetBytes($sid+[char]0))}
    };$k.Dispose()
    $beforeRegistry=@(Get-HistoricalRegistry @($privateRoot) -Hive $hive)
    $failure='';try{Invoke-HistoricalActivation $plan $hive}catch{$failure=$_.Exception.Message}
    if($case -ceq 'success'){
        if($failure){throw $failure}
        Assert-RecoveryEqual (Recovery-Lines $originalRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'success original root raw descriptors'
        Assert-HistoricalActivationState $plan $hive $plan.OriginalState
        Assert-RecoveryEqual (Historical-RegistryLines @(Get-HistoricalActivationRegistry $plan -Restored)) (Historical-RegistryLines @(Get-HistoricalRegistry @($privateRoot) -Hive $hive)) 'six absent and foreign84 sibling otherSID empty child exact'
        $k=$hive.OpenSubKey($markerKey,$false)
        try{
            foreach($name in $markerNames){if($k.GetValueNames() -contains $name){throw 'Target marker remains'}}
            $candidateRoots=@($k.GetValueNames()|Where-Object {$_ -notlike '*|*' -and [IO.Path]::GetFileName($_) -in 'RooIndustriesOptimizationSuite','RooOptimizationSuite' -and $k.GetValue($_) -ceq $sid})
            if($candidateRoots.Count){throw 'Retained marker still participates in DefaultDataRoot'}
            $legacy=Join-Path $caseRoot 'RooOptimizationSuite';if(Test-Path -LiteralPath $legacy){throw 'Private legacy root unexpected'}
        }finally{$k.Dispose()}
    }else{
        if(-not$failure){throw ('Adverse case accepted: '+$case)}
        $expectedFailure=switch($case){
            {$_ -in @('changed-sid','changed-kind','changed-qword','same-name-foreign','extra-marker')} {'*typed registry immediately before restore*'}
            {$_ -in @('interrupt-quarantine','interrupt-activation')} {('Injected interruption: '+$case)}
            'recreated-root' {'Live path was recreated; foreign tree retained'}
            'changed-original-state' {'Original State changed immediately before write; retained'}
        }
        if($failure -notlike $expectedFailure){throw ('Wrong refusal for '+$case+': '+$failure)}
        Assert-RecoveryEqual (Historical-RegistryLines $beforeRegistry) (Historical-RegistryLines @(Get-HistoricalRegistry @($privateRoot) -Hive $hive)) ('adverse registry unchanged '+$case)
        if($case -in @('changed-sid','changed-kind','changed-qword','same-name-foreign','extra-marker')){
            Assert-RecoveryEqual (Recovery-Lines $liveRows) (Recovery-Lines @(Get-RecoveryRows $live)) ('refused before root move '+$case)
            if(Test-Path -LiteralPath (Join-Path $caseRoot 'restore-intent.json')){throw 'Marker drift reached destructive intent'}
        }else{
            if(-not(Test-Path -LiteralPath (Join-Path $caseRoot 'restore-intent.json'))){throw 'Interrupted restore lost intent'}
            if($case -ceq 'recreated-root'){Assert-RecoveryEqual (Recovery-Lines $foreignRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'foreign recreated root exact'}
            elseif($case -in @('interrupt-activation','changed-original-state')){Assert-RecoveryEqual (Recovery-Lines $originalRows) (Recovery-Lines @(Get-RecoveryRows $live)) 'activated root preserved after interruption'}
            elseif(Test-Path -LiteralPath $live){throw 'Quarantine interruption unexpectedly activated root'}
            $replay='';try{Invoke-HistoricalActivation $plan $hive}catch{$replay=$_.Exception.Message}
            if($replay -notlike '*earlier Restore intent*'){throw ('Automatic replay not refused: '+$replay)}
        }
    }
    $quarantine=Join-Path $caseRoot 'asnow-live-quarantine'
    if(Test-Path -LiteralPath $quarantine){Assert-RecoveryEqual (Recovery-Lines $liveRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $quarantine) -DataOnly) 'as-now quarantine preserved'}
    Assert-RecoveryEqual (Recovery-Lines $liveRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $asnowCopy) -DataOnly) 'as-now retained copy unchanged'
    Assert-RecoveryEqual (Recovery-Lines $originalRows) (Recovery-Lines @(Get-RecoveryRows $original)) 'original source unchanged'
    Assert-RecoveryEqual (Recovery-Lines $originalRows -DataOnly) (Recovery-Lines @(Get-RecoveryRows $originalStage) -DataOnly) 'immutable original stage unchanged'
    $result=@{case=$case;passed=$true;failure=$failure;frame=$caseRoot;privateHive=$privateRoot;targetMarkerCount=6;foreignMarkerCount=84;retainedCopiesExact=$true;liveProductMutation=$false}
    & $nativeSave (Join-Path $caseRoot 'restore-case-proof.json') $result
    $results+=$result;'PASS shared native restore '+$case
}
& $nativeSave (Join-Path $test 'restore-scenarios-proof.json') @{protocol='blackwell-private-restore-scenarios/v1';cases=$results;count=$results.Count;liveProductMutation=$false}

}
Set-Item -Path Function:Save-RecoveryJson -Value $nativeSave

$prepared='C:\ProgramData\RooRecoveryBlackwell-'+[Guid]::NewGuid().ToString('N');New-SealedDirectory $prepared
$capturedHash='E2D2CAE5ED6619C01FFEE71C953D757C0556C354F08022AEF55EEFBFD4DC5637'
$stagedHash='8011FF1710980DA04CC4B2B3E3F864292DC78F81B22C9BA5394AFFE8525FE215'
Assert-FileHash (Join-Path $Frame 'capture.json') $capturedHash
Assert-FileHash (Join-Path $Frame 'stage.json') $stagedHash
$capture=Read-HistoricalJson (Join-Path $Frame 'capture.json');$staged=Read-HistoricalJson (Join-Path $Frame 'stage.json')
Assert-FileHash (Join-Path $Frame 'original-backup\machine-state.json') $capture.baselineHash
$baseline=Read-HistoricalJson (Join-Path $Frame 'original-backup\machine-state.json')
if(@($baseline.productKeys).Count -ne 0){throw 'Prepared marker absence is unproved'}
Assert-FileHash ($staged.stage+'.historical-manifest.json') $staged.manifestHash
$originalRows=Read-HistoricalJson ($staged.stage+'.historical-manifest.json')
$current=@($capture.trees|Where-Object name -CEQ 'current-RooIndustriesOptimizationSuite')[0]
Assert-FileHash ($current.destination+'.manifest.json') $current.manifestHash
$nowRows=Read-HistoricalJson ($current.destination+'.manifest.json')
$privateLiveParent='C:\ProgramData\RooHistoricalLive-'+[Guid]::NewGuid().ToString('N');New-SealedDirectory $privateLiveParent
$live=Join-Path $privateLiveParent 'RooIndustriesOptimizationSuite'
Copy-VerifiedTree $current.destination $live -OriginalRows $nowRows|Out-Null
$privateRoot='Software\RooHistoricalBlackwellPrepared-'+[Guid]::NewGuid().ToString('N')
$hive=[Microsoft.Win32.Registry]::CurrentUser
$map=@{'SOFTWARE\RooIndustriesOptimizationSuite'=($privateRoot+'\StateStore');'SOFTWARE\RooIndustries'=($privateRoot+'\ProductStore')}
$originalMarkerKey='SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$markerKey=$map['SOFTWARE\RooIndustries']+'\OptimizationSuite\GovernorRoots'
$stateKey=$map['SOFTWARE\RooIndustriesOptimizationSuite']+'\Tweaks\'+$capture.sid
$actualMarkerRoot=$current.source.ToUpperInvariant();$privateMarkerRoot=$live.ToUpperInvariant()
$expectedPrivate=@()
foreach($row in @($capture.registry|Where-Object {($_.key -ceq 'SOFTWARE\RooIndustriesOptimizationSuite' -or $_.key.StartsWith('SOFTWARE\RooIndustriesOptimizationSuite\',[StringComparison]::Ordinal) -or $_.key -ceq 'SOFTWARE\RooIndustries' -or $_.key.StartsWith('SOFTWARE\RooIndustries\',[StringComparison]::Ordinal))})){
    $copy=ConvertTo-Json -InputObject $row -Compress|ConvertFrom-Json
    $base=if($row.key.StartsWith('SOFTWARE\RooIndustriesOptimizationSuite',[StringComparison]::Ordinal)){'SOFTWARE\RooIndustriesOptimizationSuite'}else{'SOFTWARE\RooIndustries'}
    $copy.key=$map[$base]+$row.key.Substring($base.Length)
    if($row.key -ceq $originalMarkerKey -and $row.name -and ($row.name -ceq $actualMarkerRoot -or $row.name.StartsWith($actualMarkerRoot+'\',[StringComparison]::Ordinal) -or $row.name.StartsWith($actualMarkerRoot+'|',[StringComparison]::Ordinal))){$copy.name=$privateMarkerRoot+$row.name.Substring($actualMarkerRoot.Length)}
    if($row.kind -ceq '<absent-key>'){throw 'Prepared product key is unexpectedly absent'}
    $key=$hive.CreateSubKey($copy.key)
    try{
        if($row.kind -ceq '<key>'){$security=[Security.AccessControl.RegistrySecurity]::new();$security.SetSecurityDescriptorSddlForm($row.sddl);$key.SetAccessControl($security);$copy.sddl=$key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')}
        else{$rawFile=Join-Path (Join-Path $Frame 'registry-asnow') $row.file;Assert-FileHash $rawFile $row.sha256;$bytes=[IO.File]::ReadAllBytes($rawFile);if($bytes.Length -ne $row.length){throw 'Prepared raw registry value length differs'};[RooHistoricalBlackwell.Raw]::Write($key,$copy.name,[uint32]$row.kind,$bytes)}
    }finally{$key.Dispose()}
    $expectedPrivate+=$copy
}
$registryRoots=@($map['SOFTWARE\RooIndustriesOptimizationSuite'],$map['SOFTWARE\RooIndustries'])
$registry=@(Get-HistoricalRegistry $registryRoots -Hive $hive)
Save-RecoveryJson (Join-Path $test 'prepared-private-inputs.json') @{frame=$prepared;privateHive=$privateRoot;expected=$expectedPrivate;observed=$registry;delta=@(Compare-Object (Historical-RegistryLines $expectedPrivate) (Historical-RegistryLines $registry) -CaseSensitive)}
Assert-RecoveryEqual (Historical-RegistryLines $expectedPrivate) (Historical-RegistryLines $registry) 'private exact captured registry projection'
$markers=@(New-HistoricalMarkerPlan $registry $live $markerKey $capture.sid)
$expectedState=@($registry|Where-Object {$_.key -ceq $stateKey -and $_.name -ceq 'State'})[0]
if($expectedState.sha256 -cne '7A045E71ED86E7B59E9778AA43962A99A62A30219E128F50A5E3888309C09994' -or $capture.originalState.hash -cne '71B282CD2E17350580AF59E58932BF2BFDCEA24E8E3CAC6581A49C7525A635DC'){throw 'Prepared exact State pair differs'}
$privateOriginalState=Join-Path $prepared 'original-state.bin'
Assert-FileHash (Join-Path $Frame 'original-state.bin') $capture.originalState.hash
Save-HistoricalBinary $privateOriginalState ([IO.File]::ReadAllBytes((Join-Path $Frame 'original-state.bin')))
$plan=@{Frame=$prepared;Live=$live;Stage=$staged.stage;StageRows=$originalRows;NowRows=$nowRows;RegistryRoots=$registryRoots;StateKey=$stateKey;MarkerKey=$markerKey;RegistryRows=$registry;MarkerRows=$markers;OriginalStateFile=$privateOriginalState;OriginalState=$capture.originalState;ExpectedState=$expectedState;CaptureHash=$capturedHash;StageHash=$stagedHash}
$sourceBefore=@(Get-RecoveryRows $staged.stage);$asnowBefore=@(Get-RecoveryRows $current.destination)
Invoke-HistoricalActivation $plan $hive
$activatedRows=@(Get-RecoveryRows $live)
Assert-RecoveryEqual (Recovery-Lines $originalRows) (Recovery-Lines $activatedRows) 'private prepared299 exact activated root'
Assert-RecoveryEqual @($originalRows|ForEach-Object {$_.relative+'|'+$_.descriptor}) @($activatedRows|ForEach-Object {$_.relative+'|'+$_.descriptor}) 'private prepared299 exact native raw descriptors'
Assert-HistoricalActivationState $plan $hive $capture.originalState
Assert-RecoveryEqual (Historical-RegistryLines @(Get-HistoricalActivationRegistry $plan -Restored)) (Historical-RegistryLines @(Get-HistoricalRegistry $registryRoots -Hive $hive)) 'private prepared six absences foreign84 typed bytes and key structure exact'
Assert-RecoveryEqual (Recovery-Lines $sourceBefore) (Recovery-Lines @(Get-RecoveryRows $staged.stage)) 'real immutable original stage unchanged'
Assert-RecoveryEqual (Recovery-Lines $asnowBefore) (Recovery-Lines @(Get-RecoveryRows $current.destination)) 'real immutable as-now capture unchanged'
$key=$hive.OpenSubKey($markerKey,$false)
try{$candidates=@($key.GetValueNames()|Where-Object {$_ -notlike '*|*' -and [IO.Path]::GetFileName($_) -in 'RooIndustriesOptimizationSuite','RooOptimizationSuite'});if($candidates.Count){throw 'Prepared retained marker participates in DefaultDataRoot'}}finally{$key.Dispose()}
$preparedProof=@{protocol='blackwell-exact-prepared-private-restore/v1';frame=$prepared;privateHive=$privateRoot;captureHash=$capturedHash;stageHash=$stagedHash;originalItems=$originalRows.Count;asnowItems=$nowRows.Count;originalState=$capture.originalState;asnowState=$expectedState;targetMarkersAbsent=6;foreignMarkersPreserved=84;registryBytesKindsKeysExact=$true;originalDescriptorsExact=$true;immutableCopiesUnchanged=$true;defaultDataRootCandidateCount=0;liveRestorationExecuted=$false}
& $nativeSave (Join-Path $test 'prepared-private-proof.json') $preparedProof
$preparedProof|ConvertTo-Json -Depth 6
'PASS exact prepared private299 root/6874821-byte State six absent foreign84 unchanged'
