param(
    [string]$HarnessPath = (Join-Path $PSScriptRoot '..\..\LeanClientOptimizer.ps1'),
    [ValidateSet('All','Selection','Drift','PreviewBinding','Dependents','BackupWrite','Services','Registry','Recovery','SnapshotSafety','ApplyComparison')][string]$Scenario = 'All',
    [ValidateSet('All','Signed','LegacyEvidence','Preflight','RegistryFailure','ServiceFailure','ServiceRuntime','OriginalEvidence','ServiceExistence','SourceEvidence','JsonNumbers','LegacyNames')][string]$RecoveryCase = 'All',
    [string]$BaseHarnessPath = $env:ROO_INDUSTRIES_LEGACY_BASE_HARNESS,
    [string]$BaseHarnessSha256 = $env:ROO_INDUSTRIES_LEGACY_BASE_HARNESS_SHA256
)
$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-legacy-rollback-' + [guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
function Invoke-ReviewedApply {
    $ConfirmApply=$false
    $PreviewPath=(Invoke-ApplyModule).previewPath
    $ConfirmApply=$true
    Invoke-ApplyModule
}
$legacyQwordCases=@(
    @{label='signed number';data=[long]-1;raw=[long]-1;encoded='18446744073709551615'},
    @{label='signed text';data='-1';raw=[long]-1;encoded='18446744073709551615'},
    @{label='signed minimum';data='-9223372036854775808';raw=[long]::MinValue;encoded='9223372036854775808'},
    @{label='unsigned maximum';data='18446744073709551615';raw=[long]-1;encoded='18446744073709551615'}
)
$legacyDwordCases=@(
    @{label='signed number';data=[int]-1;raw=[int]-1;encoded=[uint32]::MaxValue},
    @{label='signed text';data='-1';raw=[int]-1;encoded=[uint32]::MaxValue},
    @{label='signed minimum';data=[int]::MinValue;raw=[int]::MinValue;encoded=[uint32]2147483648},
    @{label='unsigned maximum';data='4294967295';raw=[int]-1;encoded=[uint32]::MaxValue}
)
$invalidOriginalCases=@(
    foreach ($kind in 'String','ExpandString','MultiString','DWord','QWord','Binary') {
        @{label=($kind+' null');entry=@{kind=$kind;oldValue=$null}}
        @{label=($kind+' missing');entry=@{kind=$kind}}
        @{label=($kind+' case');entry=@{kind=$kind.ToLowerInvariant();oldValue=1}}
    }
    @{label='DWord hex text';entry=@{kind='DWord';oldValue='0x10'}}
    @{label='DWord decimal text';entry=@{kind='DWord';oldValue='16'}}
    @{label='DWord floating number';entry=@{kind='DWord';oldValue=[double]16.5}}
    @{label='DWord Boolean';entry=@{kind='DWord';oldValue=$true}}
    @{label='DWord soft hyphen';entry=@{kind=('D'+[char]0x00ad+'Word');oldValue=1}}
    @{label='QWord hex text';entry=@{kind='QWord';oldValue='0x10'}}
    @{label='QWord leading zero';entry=@{kind='QWord';oldValue='016'}}
    @{label='QWord number';entry=@{kind='QWord';oldValue=16}}
    @{label='QWord signed text';entry=@{kind='QWord';oldValue='-1'}}
    @{label='String number';entry=@{kind='String';oldValue=7}}
    @{label='ExpandString array';entry=@{kind='ExpandString';oldValue=@('text')}}
    @{label='MultiString scalar';entry=@{kind='MultiString';oldValue='one'}}
    @{label='MultiString numeric element';entry=@{kind='MultiString';oldValue=@('one',2)}}
    @{label='MultiString null element';entry=@{kind='MultiString';oldValue=@('one',$null)}}
    @{label='MultiString nested arrays';entry=@{kind='MultiString';oldValue=@(@('one','two'),@('three'))}}
    @{label='Binary whitespace';entry=@{kind='Binary';oldValue="Zg==`n"}}
    @{label='Binary padding bits';entry=@{kind='Binary';oldValue='Zh=='}}
    @{label='Binary array';entry=@{kind='Binary';oldValue=@()}}
)
function Get-FixtureRegistryBytes {
    param([string]$Kind,[object]$Value)
    if ($Kind -ceq 'DWord') { return ,([BitConverter]::GetBytes([int]$Value)) }
    if ($Kind -ceq 'QWord') { return ,([BitConverter]::GetBytes([long]$Value)) }
    if ($Kind -ceq 'Binary') { return ,([byte[]]$Value) }
    $text=if ($Kind -ceq 'MultiString') { ((@($Value)|ForEach-Object {$_+[char]0}) -join '')+[char]0 } else { [string]$Value+[char]0 }
    return ,([byte[]]@(foreach ($character in $text.ToCharArray()) { [BitConverter]::GetBytes([uint16]$character) }))
}
$unsafeSnapshotCases=@(
    foreach ($kind in 'String','ExpandString','MultiString') {
        foreach ($unit in 0xd800,0xdc00) {
            $text='A'+[char]$unit+'B'
            $raw=$text
            if ($kind -ceq 'MultiString') { $raw=[string[]]@('One',$text) }
            @{label=($kind+' lone '+$unit.ToString('X4'));kind=$kind;raw=$raw;bytes=(Get-FixtureRegistryBytes $kind $raw)}
        }
    }
    foreach ($kind in 'DWord','QWord') {
        $width=if ($kind -ceq 'DWord') {4} else {8}
        foreach ($length in 0..($width-1)) {
            $raw=if ($length -eq 0) {0} else {1}
            $bytes=New-Object byte[] $length
            if ($length) { $bytes[0]=1 }
            @{label=($kind+' short '+$length);kind=$kind;raw=$(if($kind -ceq 'QWord'){[long]$raw}else{[int]$raw});bytes=$bytes}
        }
    }
    @{label='DWord oversized small';kind='DWord';raw=[long]1;bytes=[byte[]]@(1,0,0,0,0,0,0,0)}
    @{label='DWord oversized large';kind='DWord';raw=[long]4294967296;bytes=[byte[]]@(0,0,0,0,1,0,0,0)}
    @{label='QWord oversized';kind='QWord';raw=[byte[]]@(1,0,0,0,0,0,0,0,0);bytes=[byte[]]@(1,0,0,0,0,0,0,0,0)}
    @{label='DWord raw kind changed';kind='DWord';raw=[int]1;bytes=[byte[]]@(1,0,0,0);nativeKind=3}
    @{label='DWord raw data changed';kind='DWord';raw=[int]1;bytes=[byte[]]@(2,0,0,0)}
)
$unsafeTextSnapshotCases=@(
    foreach ($kind in 'String','ExpandString') {
        @{label=($kind+' missing terminator');kind=$kind;raw='A';bytes=[byte[]]@(65,0)}
        @{label=($kind+' odd byte length');kind=$kind;raw='A';bytes=[byte[]]@(65,0,0)}
        @{label=($kind+' zero bytes');kind=$kind;raw='';bytes=[byte[]]@()}
    }
    @{label='MultiString missing terminators';kind='MultiString';raw=[string[]]@('A');bytes=[byte[]]@(65,0)}
    @{label='MultiString single terminator';kind='MultiString';raw=[string[]]@('A');bytes=[byte[]]@(65,0,0,0)}
    @{label='MultiString odd byte length';kind='MultiString';raw=[string[]]@('A');bytes=[byte[]]@(65,0,0)}
    @{label='MultiString zero bytes';kind='MultiString';raw=[string[]]@();bytes=[byte[]]@()}
)
$rawQueryFailureCases=@(
    @{label='String raw kind changed';kind='String';raw='A';bytes=[byte[]]@(65,0,0,0);nativeKind=3}
    @{label='String raw data changed';kind='String';raw='A';bytes=[byte[]]@(66,0,0,0)}
    foreach ($failure in 'first query error 5','second query error 234','kind changed between queries','size shrank between queries','size grew between queries') {
        @{label=('String native '+$failure);kind='String';raw='A';bytes=[byte[]]@(65,0,0,0);nativeError=$failure}
    }
)
$canonicalTextCases=@(
    @{label='String empty';kind='String';raw='';bytes=[byte[]]@(0,0)}
    @{label='ExpandString empty';kind='ExpandString';raw='';bytes=[byte[]]@(0,0)}
    @{label='MultiString empty array';kind='MultiString';raw=[string[]]@();bytes=[byte[]]@(0,0)}
    @{label='MultiString empty element';kind='MultiString';raw=[string[]]@('');bytes=[byte[]]@(0,0,0,0)}
    foreach ($kind in 'String','ExpandString') {
        @{label=($kind+' embedded NUL');kind=$kind;raw=('A'+[char]0+'B');bytes=[byte[]]@(65,0,0,0,66,0,0,0)}
        @{label=($kind+' extra terminator');kind=$kind;raw=('A'+[char]0);bytes=[byte[]]@(65,0,0,0,0,0)}
    }
    @{label='MultiString interior empty';kind='MultiString';raw=[string[]]@('A','','B');bytes=[byte[]]@(65,0,0,0,0,0,66,0,0,0,0,0)}
    @{label='MultiString trailing empty';kind='MultiString';raw=[string[]]@('A','');bytes=[byte[]]@(65,0,0,0,0,0,0,0)}
    @{label='MultiString leading empty';kind='MultiString';raw=[string[]]@('','A');bytes=[byte[]]@(0,0,65,0,0,0,0,0)}
    @{label='MultiString empty elements';kind='MultiString';raw=[string[]]@('','');bytes=[byte[]]@(0,0,0,0,0,0)}
    @{label='String long text';kind='String';raw=('A'*65);bytes=(Get-FixtureRegistryBytes 'String' ('A'*65))}
)
$numericLayoutCases=@($unsafeSnapshotCases|Where-Object {$_.label -match '^(DWord|QWord) (short|oversized)'})
$nullStringElement=[string[]]::new(1)
$coherenceCases=@(
    @{label='Binary native None';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,2);nativeKind=0}
    @{label='Binary native big endian';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,2);nativeKind=5}
    @{label='Binary changed to DWord';kind='Binary';raw=[int]5;bytes=[byte[]]@(5,0,0,0);nativeKind=4}
    @{label='Binary changed to QWord';kind='Binary';raw=[long]7;bytes=[byte[]]@(7,0,0,0,0,0,0,0);nativeKind=11}
    @{label='Binary changed to String';kind='Binary';raw='12';bytes=[byte[]]@(49,0,50,0,0,0);nativeKind=1}
    @{label='Binary changed to MultiString';kind='Binary';raw=[string[]]@('1','2');bytes=[byte[]]@(49,0,0,0,50,0,0,0,0,0);nativeKind=7}
    @{label='Binary managed DWord';kind='Binary';raw=[int]5;bytes=[byte[]]@(5)}
    @{label='Binary managed object array';kind='Binary';raw=[object[]]@(1,2);bytes=[byte[]]@(1,2)}
    @{label='Binary raw data changed';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,3)}
    @{label='Binary native query error';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,2);nativeError='first query error 5'}
    @{label='Binary native null result';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,2);nativeNull=$true}
    @{label='Binary native null data';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,2);nativeData=$null;overrideNativeData=$true}
    @{label='Binary native object data';kind='Binary';raw=[byte[]]@(1,2);bytes=[byte[]]@(1,2);nativeData=[object[]]@(1,2);overrideNativeData=$true}
    @{label='String managed number';kind='String';raw=[int]12;bytes=[byte[]]@(49,0,50,0,0,0)}
    @{label='ExpandString managed number';kind='ExpandString';raw=[int]12;bytes=[byte[]]@(49,0,50,0,0,0)}
    @{label='MultiString managed object array';kind='MultiString';raw=[object[]]@('A');bytes=[byte[]]@(65,0,0,0,0,0)}
    @{label='MultiString managed null element';kind='MultiString';raw=$nullStringElement;bytes=[byte[]]@(0,0,0,0)}
    @{label='DWord managed QWord';kind='DWord';raw=[long]1;bytes=[byte[]]@(1,0,0,0)}
    @{label='QWord managed DWord';kind='QWord';raw=[int]1;bytes=[byte[]]@(1,0,0,0,0,0,0,0)}
)
$canonicalRawCases=$canonicalTextCases+@(
    @{label='Binary empty';kind='Binary';raw=[byte[]]@();bytes=[byte[]]@()}
    @{label='Binary full byte range';kind='Binary';raw=[byte[]]@(0,127,128,255);bytes=[byte[]]@(0,127,128,255)}
)
$unsafeSnapshotCases += $unsafeTextSnapshotCases + $rawQueryFailureCases + $coherenceCases
$legacyDefaultNames=@($null,'','(default)','(Default)','(DEFAULT)',('(def'+[char]0x00ad+'ault)'))
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fixtureManifest = Join-Path $tempRoot 'manifest.json'
    @{ protected = @{ services = @(); registryPathPatterns = @() }; modules = @(@{
        id = 'fixture'; name = 'Fixture'; registryValues = @(@{ path = 'HKCU\Fixture'; name = 'Value'; type = 'REG_DWORD'; data = 2 }); services = @()
    }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifest -Encoding UTF8
    if ($Scenario -in 'All','SnapshotSafety') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        $ManifestPath=Join-Path $tempRoot 'snapshot-manifest.json'
        $manifest=Get-Content $fixtureManifest -Raw|ConvertFrom-Json
        $manifest.modules[0].registryValues=@(@{path='HKCU\Fixture';name='First';type='REG_DWORD';data=2},@{path='HKCU\Fixture';name='Second';type='REG_DWORD';data=2})
        $manifest.modules[0].services=@(@{name='FixtureSvc';startup='Disabled';targetState='Stopped'})
        Write-JsonFile $manifest $ManifestPath
        function Open-RegistryKey {
            param($Path,[switch]$Writable,[switch]$Create)
            $key=[pscustomobject]@{}
            $key|Add-Member ScriptMethod GetValueNames { [string[]]@('First','Second') }
            $key|Add-Member ScriptMethod GetValueKind {param($Name) [Microsoft.Win32.RegistryValueKind]$script:safetyValues[$Name].kind}
            $key|Add-Member ScriptMethod GetValue {param($Name,$Default,$Options) return ,$script:safetyValues[$Name].raw}
            $key|Add-Member ScriptMethod Dispose {} -PassThru
        }
        function Get-RegistryRawValue {
            param($Key,$Name)
            if ($Name -ceq 'Second' -and $script:safetyLateCase) {
                $script:safetyLateReads++
                if ($script:safetyLateReads -eq 2) {
                    $case=$script:safetyLateCase
                    $script:safetyValues.Second=@{kind=$case.kind;raw=$case.raw;bytes=$case.bytes;nativeKind=$(if($case.ContainsKey('nativeKind')){$case.nativeKind}else{[int][Microsoft.Win32.RegistryValueKind]$case.kind});nativeError=$case.nativeError}
                }
            }
            if ($script:safetyValues[$Name].nativeError) { throw $script:safetyValues[$Name].nativeError }
            if ($script:safetyValues[$Name].nativeNull) { return $null }
            $data=if ($script:safetyValues[$Name].overrideNativeData) { ,$script:safetyValues[$Name].nativeData } else { ,$script:safetyValues[$Name].bytes }
            [pscustomobject]@{Kind=$script:safetyValues[$Name].nativeKind;Data=$data}
        }
        function Set-RegistrySnapshotData {
            param($Key,$Name,$Snapshot)
            $script:safetyRegistryWrites++
            $raw=Convert-RegistrySnapshotData $Snapshot
            $script:safetyValues[$Name]=@{kind=$Snapshot.kind;raw=$raw;bytes=(Get-FixtureRegistryBytes $Snapshot.kind $raw);nativeKind=[int][Microsoft.Win32.RegistryValueKind]$Snapshot.kind}
        }
        function Get-ServiceSnapshot {param($Name) [pscustomobject]@{name=$Name;exists=$true;startType=$script:safetyStartup;status='Running'}}
        function Set-ServiceFromManifest {param($Item) $script:safetyServiceWrites++;$script:safetyStartup=$Item.startup}
        function Restore-ServiceSnapshot {param($Snapshot) $script:safetyServiceWrites++;$script:safetyStartup=$Snapshot.startType}
        function Get-BenchmarkSnapshot {param($Label) @{label=$Label}}
        function Invoke-SmokeTest {@()}
        function Reset-SafetyFixture {
            param($Case)
            $script:safetyValues=@{
                First=@{kind='DWord';raw=[int]1;bytes=[byte[]]@(1,0,0,0);nativeKind=4}
                Second=@{kind=$Case.kind;raw=$Case.raw;bytes=$Case.bytes;nativeKind=$(if($Case.ContainsKey('nativeKind')){$Case.nativeKind}else{[int][Microsoft.Win32.RegistryValueKind]$Case.kind});nativeError=$Case.nativeError;nativeNull=$Case.nativeNull;nativeData=$Case.nativeData;overrideNativeData=$Case.overrideNativeData}
            }
            $script:safetyRegistryWrites=0;$script:safetyServiceWrites=0;$script:safetyStartup='Automatic'
            $script:safetyLateCase=$null;$script:safetyLateReads=0
        }
        $rows=New-Object System.Collections.Generic.List[object]
        foreach ($case in $unsafeSnapshotCases) {
            Reset-SafetyFixture $case
            $before=[Convert]::ToBase64String($case.bytes)
            $ConfirmApply=$false
            $preview=Invoke-ApplyModule
            $previewSafe=$preview.dryRun -and -not $preview.backupPath -and $script:safetyRegistryWrites -eq 0 -and $script:safetyServiceWrites -eq 0
            $ConfirmApply=$true
            $refused=$false;$message='';$applied=$null;$restored=$null
            $PreviewPath=$preview.previewPath;try { $applied=Invoke-ApplyModule } catch {$refused=$true;$message=$_.Exception.Message}
            if ($applied) { $BackupPath=$applied.backupPath;$restored=Invoke-RollbackModule }
            $rows.Add([pscustomobject]@{label=$case.label;managedType=$case.raw.GetType().FullName;beforeKind=$(if($case.ContainsKey('nativeKind')){$case.nativeKind}else{[int][Microsoft.Win32.RegistryValueKind]$case.kind});afterKind=$script:safetyValues.Second.nativeKind;beforeBytes=$before;afterBytes=[Convert]::ToBase64String($script:safetyValues.Second.bytes);previewSafe=$previewSafe;refused=$refused;error=$message;registryWrites=$script:safetyRegistryWrites;serviceWrites=$script:safetyServiceWrites;first=$script:safetyValues.First.raw;rollbackSuccess=$restored.success})
        }
        Write-Output ('SNAPSHOT_SAFETY_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 5 -Compress))
        $applyRows=$rows
        $rows=New-Object System.Collections.Generic.List[object]
        $layoutCases=@($unsafeTextSnapshotCases)+@($numericLayoutCases)
        $failureCases=@($rawQueryFailureCases)+@($coherenceCases)+@($unsafeSnapshotCases|Where-Object {$_.label -match ' lone '})
        foreach ($case in $layoutCases+$failureCases) {
            $expectLeft=$case.label -in @($layoutCases|ForEach-Object {$_.label})
            Reset-SafetyFixture $case
            $script:safetyValues.First.raw=[int]2
            $script:safetyValues.First.bytes=[byte[]]@(2,0,0,0)
            $script:safetyStartup='Disabled'
            $BackupPath=Join-Path $tempRoot 'raw-current-backup.json'
            Write-JsonFile @{moduleId='fixture';registry=@(
                @{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;valueExists=$true;kind='DWord';oldValue=1},
                @{path='HKCU\Fixture';name='Second';type='REG_SZ';desiredData='A';valueExists=$true;kind='String';oldValue='Original'}
            );services=@(@{name='FixtureSvc';exists=$true;startType='Automatic';status='Running';appliedStartup='Disabled'})} $BackupPath
            $hash=(Get-FileHash $BackupPath).Hash
            $before=[Convert]::ToBase64String($case.bytes)
            $ConfirmApply=$false
            $preview=Invoke-RollbackModule
            $previewSafe=$script:safetyRegistryWrites -eq 0 -and $script:safetyServiceWrites -eq 0 -and $(if($expectLeft){$preview.success -and $preview.restoredRegistry -eq 1 -and $preview.restoredServices -eq 1 -and $preview.leftAsChanged.Count -eq 1 -and $preview.leftAsChanged[0].name -ceq 'Second'}else{-not $preview.success -and $preview.failures[0].phase -ceq 'preflight' -and $preview.restoredRegistry -eq 0 -and $preview.restoredServices -eq 0})
            $ConfirmApply=$true
            $result=Invoke-RollbackModule
            $retry=Invoke-RollbackModule
            $outcomeSafe=if($expectLeft){$result.success -and -not $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 1 -and $result.leftAsChanged.Count -eq 1 -and $result.leftAsChanged[0].name -ceq 'Second' -and $script:safetyRegistryWrites -eq 1 -and $script:safetyServiceWrites -eq 1 -and $script:safetyValues.First.raw -eq 1 -and $script:safetyStartup -ceq 'Automatic' -and $retry.success -and $retry.restoredRegistry -eq 0 -and $retry.restoredServices -eq 0 -and $retry.leftAsChanged.Count -eq 1 -and @($retry.alreadyAtOriginal|Where-Object {$_.name -ceq 'Second'}).Count -eq 0}else{-not $result.success -and -not $result.partial -and $result.failures[0].phase -ceq 'preflight' -and -not $result.failures[0].mayHaveChanged -and $script:safetyRegistryWrites -eq 0 -and $script:safetyServiceWrites -eq 0 -and $script:safetyValues.First.raw -eq 2 -and $script:safetyStartup -ceq 'Disabled' -and -not $retry.success}
            $rows.Add([pscustomobject]@{label=$case.label;expectLeft=$expectLeft;previewSafe=$previewSafe;outcomeSafe=$outcomeSafe;success=$result.success;partial=$result.partial;phase=$result.failures[0].phase;restoredRegistry=$result.restoredRegistry;restoredServices=$result.restoredServices;left=@($result.leftAsChanged);alreadyAtOriginal=@($result.alreadyAtOriginal);retryLeft=@($retry.leftAsChanged);retryAlreadyAtOriginal=@($retry.alreadyAtOriginal);registryWrites=$script:safetyRegistryWrites;serviceWrites=$script:safetyServiceWrites;first=$script:safetyValues.First.raw;beforeKind=$(if($case.ContainsKey('nativeKind')){$case.nativeKind}else{[int][Microsoft.Win32.RegistryValueKind]$case.kind});afterKind=$script:safetyValues.Second.nativeKind;beforeBytes=$before;afterBytes=[Convert]::ToBase64String($script:safetyValues.Second.bytes);backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
        }
        Write-Output ('RAW_CURRENT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 5 -Compress))
        $currentRows=$rows
        $rows=New-Object System.Collections.Generic.List[object]
        foreach ($late in @($unsafeTextSnapshotCases|Select-Object -First 1)+@($rawQueryFailureCases)) {
            Reset-SafetyFixture @{kind='String';raw='A';bytes=[byte[]]@(65,0,0,0)}
            $script:safetyValues.First.raw=[int]2;$script:safetyValues.First.bytes=[byte[]]@(2,0,0,0);$script:safetyStartup='Disabled'
            $script:safetyLateCase=$late
            $hash=(Get-FileHash $BackupPath).Hash
            $ConfirmApply=$true
            $result=Invoke-RollbackModule
            $expectLeft=$late.label -ceq 'String missing terminator'
            $failureSafe=if($expectLeft){$result.success -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 1 -and $result.leftAsChanged.Count -eq 1 -and $result.actions[1].status -ceq 'leftAsChanged' -and $script:safetyServiceWrites -eq 1}else{-not $result.success -and $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 0 -and $result.failures[0].phase -ceq 'restore' -and -not $result.failures[0].mayHaveChanged -and $result.pending.Count -eq 1 -and $result.pending[0].type -ceq 'service' -and $script:safetyServiceWrites -eq 0}
            $afterFailure=[Convert]::ToBase64String($script:safetyValues.Second.bytes)
            $retry=Invoke-RollbackModule
            $retrySafe=if($expectLeft){$retry.success -and $retry.leftAsChanged.Count -eq 1 -and $retry.restoredRegistry -eq 0 -and $retry.restoredServices -eq 0}else{-not $retry.success -and -not $retry.partial -and $retry.failures[0].phase -ceq 'preflight' -and $retry.restoredRegistry -eq 0 -and $retry.restoredServices -eq 0}
            $rows.Add([pscustomobject]@{label=$late.label;expectLeft=$expectLeft;outcomeSafe=$failureSafe;retrySafe=$retrySafe;success=$result.success;partial=$result.partial;restoredRegistry=$result.restoredRegistry;restoredServices=$result.restoredServices;failure=@($result.failures);pending=@($result.pending);left=@($result.leftAsChanged);retryAlreadyAtOriginal=@($retry.alreadyAtOriginal);registryWrites=$script:safetyRegistryWrites;serviceWrites=$script:safetyServiceWrites;first=$script:safetyValues.First.raw;expectedBytes=[Convert]::ToBase64String($late.bytes);afterBytes=$afterFailure;afterRetryBytes=[Convert]::ToBase64String($script:safetyValues.Second.bytes);backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
        }
        Write-Output ('RAW_LATE_CURRENT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 7 -Compress))
        $lateRows=$rows
        $pair='A'+[char]0xd83c+[char]0xdfae+'B'
        $valid=@(
            @{kind='String';raw=''},@{kind='String';raw=$pair},@{kind='ExpandString';raw='%PATH%\fixture'},@{kind='ExpandString';raw=$pair},
            @{kind='MultiString';raw=[string[]]@()},@{kind='MultiString';raw=[string[]]@($pair,'One')},
            @{kind='DWord';raw=[int]0},@{kind='DWord';raw=[int]::MinValue},@{kind='DWord';raw=[int]-1},
            @{kind='QWord';raw=[long]0},@{kind='QWord';raw=[long]::MinValue},@{kind='QWord';raw=[long]-1}
        )
        foreach ($case in @($valid)+@($canonicalRawCases)) {
            if (-not $case.ContainsKey('bytes')) { $case.bytes=Get-FixtureRegistryBytes $case.kind $case.raw }
            Reset-SafetyFixture $case
            $before=[Convert]::ToBase64String($case.bytes)
            $ConfirmApply=$true
            $applied=Invoke-ReviewedApply
            $BackupPath=$applied.backupPath
            $hash=(Get-FileHash $BackupPath).Hash
            $result=Invoke-RollbackModule
            Assert ($result.success -and $result.restoredRegistry -eq 2 -and $result.restoredServices -eq 1 -and $script:safetyValues.Second.kind -ceq $case.kind -and [Convert]::ToBase64String($script:safetyValues.Second.bytes) -ceq $before -and (Get-FileHash $BackupPath).Hash -ceq $hash) ($case.kind+' valid Unicode or fixed-width original survives actual backup and rollback')
        }
        Assert (@($applyRows|Where-Object {-not $_.previewSafe}).Count -eq 0) 'Unsafe original data previews without writes or a backup'
        Assert (@($applyRows|Where-Object {-not $_.refused -or $_.registryWrites -ne 0 -or $_.serviceWrites -ne 0 -or $_.first -ne 1 -or $_.beforeKind -ne $_.afterKind -or $_.beforeBytes -cne $_.afterBytes}).Count -eq 0) 'Non-round-trippable originals and incoherent managed/native reads refuse apply before any setting write'
        Assert (@($currentRows|Where-Object {-not $_.previewSafe}).Count -eq 0) 'Rollback preview distinguishes later physical-layout drift from unreadable evidence without writes'
        Assert (@($currentRows|Where-Object {-not $_.outcomeSafe -or $_.beforeKind -ne $_.afterKind -or $_.beforeBytes -cne $_.afterBytes -or -not $_.backupUnchanged}).Count -eq 0) 'Later physical-layout drift preserves bytes and backup while independent undo continues; read failures stop safely'
        Assert (@($lateRows|Where-Object {-not $_.outcomeSafe -or -not $_.retrySafe -or $_.registryWrites -ne 1 -or $_.first -ne 1 -or $_.expectedBytes -cne $_.afterBytes -or $_.afterBytes -cne $_.afterRetryBytes -or -not $_.backupUnchanged}).Count -eq 0) 'Runtime physical-layout drift continues independent undo while late read failures retain truthful partial and retry results'
    } }
    if ($Scenario -in 'All','Recovery') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        $sourceServiceReader=${function:Get-ServiceSnapshot}
        $sourceServiceRestorer=${function:Restore-ServiceSnapshot}
        function Open-RegistryKey {
            param($Path,[switch]$Writable,[switch]$Create)
            $key=[pscustomobject]@{}
            $key | Add-Member ScriptMethod DeleteValue { param($Name,$ThrowOnMissing) $script:recoveryWrites++;$script:recoveryValues[$Name]=[pscustomobject]@{valueExists=$false;kind=$null;oldValue=$null} }
            $key | Add-Member ScriptMethod Dispose {} -PassThru
        }
        function Get-RegistryValueSnapshot { param($Item) $script:recoveryReads++;$script:recoveryValues[[string]$Item.name] }
        function Set-RegistrySnapshotData {
            param($Key,$Name,$Snapshot)
            $raw=Convert-RegistrySnapshotData $Snapshot
            $script:recoveryWrites++
            if ($Name -ceq $script:failureName -and $script:failureMode -eq 'throw') { throw 'Fixture registry write failed' }
            $kind=[string][Microsoft.Win32.RegistryValueKind]$Snapshot.kind
            $stored=$raw
            switch ($kind) {
                'DWord' { $stored=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$raw),0) }
                'QWord' { $stored=[BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$raw),0).ToString([Globalization.CultureInfo]::InvariantCulture) }
                'Binary' { $stored=[Convert]::ToBase64String([byte[]]$raw) }
                'MultiString' { $stored=[string[]]$raw }
            }
            $script:recoveryValues[$Name]=[pscustomobject]@{valueExists=$Snapshot.valueExists;kind=$kind;oldValue=$stored}
            if ($Name -ceq $script:failureName -and $script:failureMode -eq 'readback') { $script:recoveryValues[$Name]=[pscustomobject]@{valueExists=$true;kind='String';oldValue='Later'} }
        }
        function Get-ServiceSnapshot { param($Name) [pscustomobject]@{name=$Name;exists=$true;startType=$script:recoveryServices[$Name];status='Running'} }
        function Restore-ServiceSnapshot {
            param($Snapshot)
            $script:serviceWrites++
            if ($Snapshot.name -ceq $script:failureName -and $script:failureMode -eq 'throw') { throw 'Fixture service write failed' }
            $script:recoveryServices[$Snapshot.name]=$Snapshot.startType
            if ($Snapshot.name -ceq $script:failureName -and $script:failureMode -eq 'readback') { $script:recoveryServices[$Snapshot.name]='Manual' }
        }
        function Reset-RecoveryFixture {
            $script:recoveryValues=@{
                First=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=2}
                Second=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=2}
            }
            $script:recoveryServices=@{FixtureSvc='Disabled';SecondSvc='Disabled'}
            $script:recoveryWrites=0;$script:serviceWrites=0;$script:recoveryReads=0;$script:failureName='';$script:failureMode=''
        }
        $first=@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;oldValue=1;kind='DWord';valueExists=$true}
        $second=@{path='HKCU\Fixture';name='Second';type='REG_DWORD';desiredData=2;oldValue=0;kind='DWord';valueExists=$true}
        $service=@{name='FixtureSvc';exists=$true;startType='Automatic';status='Running';appliedStartup='Disabled'}
        $BackupPath=Join-Path $tempRoot 'recovery-backup.json'
        if ($RecoveryCase -in 'All','JsonNumbers') {
            $number=($invalidOriginalCases|Where-Object {$_.label -ceq 'DWord floating number'}).entry.oldValue
            $fullClrNumber=([double]$number).ToString('r',[Globalization.CultureInfo]::InvariantCulture)
            $actual=ConvertTo-Json -InputObject @{whole=[double]16;fraction=$number} -Compress
            Write-Output ('NUMBER_ENGINE_FIXTURE_JSON '+(ConvertTo-Json -InputObject @{engine=$PSVersionTable.PSVersion.ToString();actual=$actual;fullClrNumber=$fullClrNumber;parsedWholeType=(('{"n":16}'|ConvertFrom-Json).n.GetType().FullName);parsedFractionType=(('{"n":16.5}'|ConvertFrom-Json).n.GetType().FullName)} -Compress))
            Assert ($fullClrNumber -ceq '16.5' -and ($actual|ConvertFrom-Json).fraction -eq 16.5) 'The malformed fractional DWORD fixture remains fractional in both JSON serializer shapes'
            foreach ($token in '16','16.5','16.0') {
                Reset-RecoveryFixture
                $json='{"moduleId":"fixture","registry":[{"path":"HKCU\\Fixture","name":"Second","type":"REG_DWORD","desiredData":2,"valueExists":true,"kind":"DWord","oldValue":'+$token+'}],"services":[{"name":"FixtureSvc","exists":true,"startType":"Automatic","status":"Running","appliedStartup":"Disabled"}]}'
                [IO.File]::WriteAllText($BackupPath,$json)
                $hash=(Get-FileHash $BackupPath).Hash
                $ConfirmApply=$false
                $preview=Invoke-RollbackModule
                $previewSafe=$script:recoveryWrites -eq 0 -and $script:serviceWrites -eq 0
                $ConfirmApply=$true
                $result=Invoke-RollbackModule
                $safe=if ($token -ceq '16') { $preview.success -and $result.success -and $script:recoveryValues.Second.oldValue -eq 16 -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 1 } else { -not $preview.success -and -not $result.success -and $result.failures[0].phase -ceq 'preflight' -and $script:recoveryWrites -eq 0 -and $script:serviceWrites -eq 0 }
                Assert ($safe -and $previewSafe -and (Get-FileHash $BackupPath).Hash -ceq $hash) ('Raw JSON '+$token+' has the supported integer or invalid fractional disposition')
            }
        }
        if ($RecoveryCase -in 'All','LegacyNames') {
            $rows=New-Object System.Collections.Generic.List[object]
            foreach ($name in $legacyDefaultNames) {
                foreach ($existed in $false,$true) {
                    foreach ($literalPresent in $false,$true) {
                        Reset-RecoveryFixture
                        $script:recoveryValues['']=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=2}
                        if ([string]$name) { $script:recoveryValues[$name]=[pscustomobject]@{valueExists=$literalPresent;kind='DWord';oldValue=2} }
                        Write-JsonFile @{moduleId='fixture';registry=@(@{path='HKCU\Fixture';name=$name;type='REG_DWORD';desiredData=2;valueExists=$existed;oldValue=1});services=@($service)} $BackupPath
                        $hash=(Get-FileHash $BackupPath).Hash
                        $ConfirmApply=$false
                        $preview=Invoke-RollbackModule
                        $previewSafe=$preview.restoredRegistry -eq 0 -and @($preview.leftAsChanged).Count -eq 1 -and $preview.leftAsChanged[0].reason -like '*original existence evidence*' -and $script:recoveryWrites -eq 0
                        $ConfirmApply=$true
                        $result=Invoke-RollbackModule
                        $rows.Add([pscustomobject]@{name=$name;originalExists=$existed;literalPresent=$literalPresent;previewSafe=$previewSafe;success=$result.success;reason=$result.leftAsChanged[0].reason;alreadyOriginal=@($result.alreadyAtOriginal).Count;registryReads=$script:recoveryReads;registryWrites=$script:recoveryWrites;serviceWrites=$script:serviceWrites;default=$script:recoveryValues[''];backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
                    }
                }
            }
            Write-Output ('LEGACY_DEFAULT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 5 -Compress))
            Assert (@($rows|Where-Object {-not $_.previewSafe -or -not $_.success -or $_.alreadyOriginal -ne 0 -or $_.reason -notlike '*original existence evidence*' -or $_.registryReads -ne 0 -or $_.registryWrites -ne 0 -or $_.serviceWrites -ne 1 -or -not $_.default.valueExists -or $_.default.oldValue -ne 2 -or -not $_.backupUnchanged}).Count -eq 0) 'Kindless legacy default aliases never grant original existence evidence'
            foreach ($name in '','(default)','(DEFAULT)','Named') {
                foreach ($existed in $false,$true) {
                    Reset-RecoveryFixture
                    $script:recoveryValues[$name]=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=2}
                    Write-JsonFile @{moduleId='fixture';registry=@(@{path='HKCU\Fixture';name=$name;type='REG_DWORD';desiredData=2;valueExists=$existed;kind=$(if($existed){'DWord'}else{$null});oldValue=1});services=@()} $BackupPath
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    Assert ($result.success -and $result.restoredRegistry -eq 1 -and $script:recoveryValues[$name].valueExists -eq $existed -and (-not $existed -or $script:recoveryValues[$name].oldValue -eq 1)) ('New-format '+$name+' retains exact original existence '+$existed)
                }
            }
            Reset-RecoveryFixture
            $script:recoveryValues.Named=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=2}
            Write-JsonFile @{moduleId='fixture';registry=@(@{path='HKCU\Fixture';name='Named';type='REG_DWORD';desiredData=2;valueExists=$false});services=@()} $BackupPath
            $result=Invoke-RollbackModule
            Assert ($result.success -and $result.restoredRegistry -eq 1 -and -not $script:recoveryValues.Named.valueExists) 'Kindless legacy known-create evidence remains valid for an ordinary named value'
        }
        if ($RecoveryCase -in 'All','OriginalEvidence') {
            $rows=New-Object System.Collections.Generic.List[object]
            foreach ($case in $invalidOriginalCases) {
                Reset-RecoveryFixture
                $entry=@{path='HKCU\Fixture';name='Second';type='REG_DWORD';desiredData=2;valueExists=$true}+$case.entry
                Write-JsonFile @{moduleId='fixture';registry=@($first,$entry);services=@($service)} $BackupPath
                $hash=(Get-FileHash $BackupPath).Hash
                $ConfirmApply=$false
                $preview=Invoke-RollbackModule
                $previewSafe=-not $preview.success -and $preview.restoredRegistry -eq 0 -and $preview.restoredServices -eq 0 -and $preview.failures[0].phase -ceq 'preflight' -and $script:recoveryWrites -eq 0 -and $script:serviceWrites -eq 0
                $ConfirmApply=$true
                $result=Invoke-RollbackModule
                $rows.Add([pscustomobject]@{label=$case.label;previewSafe=$previewSafe;success=$result.success;partial=$result.partial;phase=$result.failures[0].phase;error=$result.failures[0].error;registryWrites=$script:recoveryWrites;serviceWrites=$script:serviceWrites;first=$script:recoveryValues.First;second=$script:recoveryValues.Second;pending=@($result.pending).Count;backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
            }
            Write-Output ('ORIGINAL_EVIDENCE_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 7 -Compress))
            Assert (@($rows|Where-Object {-not $_.previewSafe}).Count -eq 0) 'Malformed original evidence fails preview before any setting write'
            Assert (@($rows|Where-Object {$_.success -or $_.partial -or $_.phase -cne 'preflight' -or $_.error -notlike '*original*evidence*' -or $_.registryWrites -ne 0 -or $_.serviceWrites -ne 0 -or $_.first.oldValue -ne 2 -or $_.second.oldValue -ne 2 -or $_.pending -ne 2 -or -not $_.backupUnchanged}).Count -eq 0) 'Malformed original evidence blocks all writes including the independent service and retains backup bytes'
            $valid=@(
                @{kind='String';oldValue=''},@{kind='String';oldValue='7'},
                @{kind='ExpandString';oldValue=''},@{kind='ExpandString';oldValue='%PATH%\fixture'},
                @{kind='MultiString';oldValue=@()},@{kind='MultiString';oldValue=@('')},@{kind='MultiString';oldValue=@('One','two')},
                @{kind='DWord';oldValue=0},@{kind='DWord';oldValue=[uint32]2147483648},@{kind='DWord';oldValue=[uint32]::MaxValue},
                @{kind='QWord';oldValue='0'},@{kind='QWord';oldValue='9007199254740993'},@{kind='QWord';oldValue='9223372036854775808'},@{kind='QWord';oldValue='18446744073709551615'},
                @{kind='Binary';oldValue=''},@{kind='Binary';oldValue='AH+A/w=='}
            )
            foreach ($case in $valid) {
                Reset-RecoveryFixture
                $entry=@{path='HKCU\Fixture';name='Second';type='REG_DWORD';desiredData=2;valueExists=$true}+$case
                Write-JsonFile @{moduleId='fixture';registry=@($first,$entry);services=@($service)} $BackupPath
                $hash=(Get-FileHash $BackupPath).Hash
                $ConfirmApply=$false
                $preview=Invoke-RollbackModule
                Assert ($preview.success -and $preview.restoredRegistry -eq 2 -and $preview.restoredServices -eq 1 -and $script:recoveryWrites -eq 0 -and $script:serviceWrites -eq 0) ($case.kind+' canonical original previews without writes')
                $ConfirmApply=$true
                $result=Invoke-RollbackModule
                Assert ($result.success -and $result.restoredRegistry -eq 2 -and $result.restoredServices -eq 1 -and $script:recoveryValues.Second.kind -ceq $case.kind -and (ConvertTo-Json -InputObject $script:recoveryValues.Second.oldValue -Compress) -ceq (ConvertTo-Json -InputObject $case.oldValue -Compress) -and (Get-FileHash $BackupPath).Hash -ceq $hash) ($case.kind+' canonical original restores exact data without changing backup bytes')
            }
        }
        if ($RecoveryCase -in 'All','ServiceExistence') {
            $rows=New-Object System.Collections.Generic.List[object]
            foreach ($case in @(@{label='missing'},@{label='null';value=$null},@{label='text false';value='false'},@{label='text true';value='true'},@{label='number zero';value=0},@{label='number one';value=1},@{label='empty array';value=@()})) {
                Reset-RecoveryFixture
                $entry=@{name='SecondSvc';startType='Automatic';status='Running';appliedStartup='Disabled'}
                if ($case.ContainsKey('value')) { $entry.exists=$case.value }
                Write-JsonFile @{moduleId='fixture';registry=@();services=@($entry,$service)} $BackupPath
                $hash=(Get-FileHash $BackupPath).Hash
                $ConfirmApply=$false
                $preview=Invoke-RollbackModule
                $previewSafe=$preview.success -and $preview.restoredServices -eq 1 -and @($preview.leftAsChanged).Count -eq 1 -and $preview.leftAsChanged[0].reason -like '*existence*evidence*' -and $script:serviceWrites -eq 0
                $ConfirmApply=$true
                $result=Invoke-RollbackModule
                $rows.Add([pscustomobject]@{label=$case.label;previewSafe=$previewSafe;success=$result.success;restoredServices=$result.restoredServices;leftCount=@($result.leftAsChanged).Count;reason=$result.leftAsChanged[0].reason;serviceWrites=$script:serviceWrites;second=$script:recoveryServices.SecondSvc;backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
            }
            Write-Output ('SERVICE_EXISTENCE_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 5 -Compress))
            Assert (@($rows|Where-Object {-not $_.previewSafe -or -not $_.success -or $_.restoredServices -ne 1 -or $_.leftCount -ne 1 -or $_.reason -notlike '*existence*evidence*' -or $_.serviceWrites -ne 1 -or $_.second -cne 'Disabled' -or -not $_.backupUnchanged}).Count -eq 0) 'Missing or invalid service existence is reported without blocking the independent proven service'
            Reset-RecoveryFixture
            Write-JsonFile @{moduleId='fixture';registry=@();services=@(@{name='SecondSvc';exists=$false;startType='Automatic';status='Running';appliedStartup='Disabled'},$service)} $BackupPath
            $hash=(Get-FileHash $BackupPath).Hash
            $ConfirmApply=$false
            $preview=Invoke-RollbackModule
            $ConfirmApply=$true
            $result=Invoke-RollbackModule
            Assert ($preview.restoredServices -eq 1 -and $result.success -and $result.restoredServices -eq 1 -and @($result.leftAsChanged).Count -eq 0 -and @($result.actions).Count -eq 1 -and $script:serviceWrites -eq 1 -and $script:recoveryServices.SecondSvc -ceq 'Disabled' -and (Get-FileHash $BackupPath).Hash -ceq $hash) 'Boolean false records an absent original service and grants no action'
        }
        if ($RecoveryCase -in 'All','SourceEvidence') { & {
            $ManifestPath=Join-Path $tempRoot 'source-manifest.json'
            $DataRoot=Join-Path $tempRoot 'source-evidence'
            $manifest=Get-Content $fixtureManifest -Raw | ConvertFrom-Json
            $manifest.modules[0].registryValues=@()
            $manifest.modules[0].services=@(foreach ($name in 'FixtureSvc','NoCimFixtureSvc','MissingFixtureSvc') { @{name=$name;startup='Disabled';targetState='Stopped'} })
            Write-JsonFile $manifest $ManifestPath
            $script:sourceTypes=@{FixtureSvc='Automatic';NoCimFixtureSvc='Manual'}
            function Get-Service {
                param($Name)
                if ($script:sourceTypes.ContainsKey($Name)) { [pscustomobject]@{Name=$Name;DisplayName=($Name+' display');Status='Running';StartType=$script:sourceTypes[$Name];ServicesDependedOn=@([pscustomobject]@{Name='FixtureDependency'})} }
            }
            function Get-CimInstance { param($ClassName,$Filter) if ($Filter -ceq "Name='FixtureSvc'") { [pscustomobject]@{StartMode='Auto';ProcessId=0;PathName='C:\OwnedFixture\service.exe'} } }
            function Get-ServiceSnapshot { param($Name) & $sourceServiceReader $Name }
            function Set-Service { param($Name,$StartupType) $script:sourceTypes[$Name]=$StartupType }
            function Stop-Service { param($Name,[switch]$Force) }
            function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
            function Invoke-SmokeTest { @() }
            $ConfirmApply=$true
            $applied=Invoke-ReviewedApply
            $backup=Get-Content $applied.backupPath -Raw | ConvertFrom-Json
            $run=@(Get-ChildItem (Join-Path $DataRoot 'runs') -File | Where-Object { (Get-Content $_.FullName -Raw|ConvertFrom-Json).backupPath -ceq $applied.backupPath })
            Assert (@($backup.services).Count -eq 3 -and $backup.services[0].exists -is [bool] -and $backup.services[0].exists -and $backup.services[0].appliedStartup -ceq 'Disabled' -and $backup.services[0].startType -ceq 'Automatic' -and $backup.services[0].dependsOn[0] -ceq 'FixtureDependency' -and $null -eq $backup.services[1].pathName -and $backup.services[1].processId -eq 0 -and $backup.services[2].exists -is [bool] -and -not $backup.services[2].exists) 'Real backup producer saves populated and absent service fields from OS boundary fixtures'
            Assert ($run.Count -eq 1 -and @($applied.actions).Count -eq 3 -and -not $applied.dryRun -and $applied.after.label -ceq 'post-fixture') 'Real apply producer saves reachable run fields and the exact backup reference'
            Write-Output ('SERVICE_BACKUP_FIXTURE_JSON '+(ConvertTo-Json -InputObject ([IO.File]::ReadAllText($applied.backupPath)) -Compress))
            Write-Output ('APPLY_RUN_FIXTURE_JSON '+(ConvertTo-Json -InputObject ([IO.File]::ReadAllText($run[0].FullName)) -Compress))
        } }
        if ($RecoveryCase -in 'All','Signed') {
            foreach ($case in $legacyDwordCases) {
                Reset-RecoveryFixture
                $snapshot=[pscustomobject]@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;oldValue=$case.data;valueExists=$true}
                Restore-RegistryValue $snapshot
                Assert ($script:recoveryValues.First.kind -ceq 'DWord' -and $script:recoveryValues.First.oldValue -eq $case.encoded) ('Legacy DWORD '+$case.label+' helper preserves the provider integer bits')
            }
            foreach ($type in 'REG_DWORD','REG_QWORD') {
                $refused=$false
                try { Get-ManifestRegistrySnapshot ([pscustomobject]@{type=$type;data='-1'}) | Out-Null } catch { $refused=$true }
                Assert $refused ($type+' manifest conversion remains strict')
            }
            & {
                Reset-RecoveryFixture
                $ModuleId='M6-svchost-grouping'
                $oldFirst=@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;oldValue=0;valueExists=$true}
                $oldSecond=@{path='HKCU\Fixture';name='Second';type='REG_DWORD';desiredData=4294967295;oldValue=[int]-1;valueExists=$true}
                $script:recoveryValues.Second=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=[uint32]::MaxValue}
                Write-JsonFile @{moduleId=$ModuleId;registry=@($oldFirst,$oldSecond);services=@($service)} $BackupPath
                $ConfirmApply=$true
                $result=Invoke-RollbackModule
                Assert ($result.success -and $result.restoredRegistry -eq 0 -and @($result.leftAsChanged).Count -eq 2 -and $result.restoredServices -eq 1 -and $script:recoveryWrites -eq 0) 'An M6-shaped signed legacy backup preserves unproven values without blocking the independent service'
            }
        }
        if ($RecoveryCase -in 'All','LegacyEvidence') {
            foreach ($history in 'DWord/QWord','String/ExpandString') {
                $left=if ($history -eq 'String/ExpandString') { '0' } else { [int]0 }
                $right=if ($history -eq 'String/ExpandString') { '0' } else { [long]0 }
                $a=[ordered]@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=1;oldValue=$left;valueExists=$true}
                $b=[ordered]@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=1;oldValue=$right;valueExists=$true}
                $jsonA=ConvertTo-Json -InputObject $a -Compress
                $jsonB=ConvertTo-Json -InputObject $b -Compress
                Assert ([string]::Equals($jsonA,$jsonB,[StringComparison]::Ordinal)) ($history+' histories have identical kindless JSON')
                $historyRows=New-Object System.Collections.Generic.List[object]
                foreach ($entry in @($a,$b)) {
                    Reset-RecoveryFixture
                    $script:recoveryValues.First=[pscustomobject]@{valueExists=$true;kind=$(if ($history -eq 'String/ExpandString') {'String'} else {'DWord'});oldValue=$(if ($history -eq 'String/ExpandString') {'1'} else {1})}
                    Write-JsonFile @{moduleId='fixture';registry=@($entry);services=@($service)} $BackupPath
                    $hash=(Get-FileHash $BackupPath).Hash
                    $ConfirmApply=$false
                    $preview=Invoke-RollbackModule
                    $previewSafe=$preview.restoredRegistry -eq 0 -and @($preview.leftAsChanged).Count -eq 1 -and $preview.leftAsChanged[0].reason -like '*kind*evidence*' -and $script:recoveryWrites -eq 0
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    $historyRows.Add([pscustomobject]@{history=$history;oldValueType=($jsonA|ConvertFrom-Json).oldValue.GetType().FullName;previewSafe=$previewSafe;registryWrites=$script:recoveryWrites;currentValue=$script:recoveryValues.First.oldValue;restoredRegistry=$result.restoredRegistry;restoredServices=$result.restoredServices;leftCount=@($result.leftAsChanged).Count;reason=$result.leftAsChanged[0].reason;backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
                }
                Write-Output ('LEGACY_EVIDENCE_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($historyRows.ToArray()) -Depth 5 -Compress))
                Assert (@($historyRows|Where-Object {-not $_.previewSafe}).Count -eq 0) ($history+' preview refuses to infer applied kind')
                Assert (@($historyRows|Where-Object {$_.restoredRegistry -ne 0 -or $_.leftCount -ne 1 -or $_.registryWrites -ne 0 -or $_.restoredServices -ne 1 -or -not $_.backupUnchanged}).Count -eq 0) ($history+' confirmed rollback preserves both histories and restores the independent service')
            }
            Reset-RecoveryFixture
            Write-JsonFile @{moduleId='fixture';registry=@(@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;valueExists=$false});services=@()} $BackupPath
            $ConfirmApply=$true
            $result=Invoke-RollbackModule
            Assert ($result.success -and $result.restoredRegistry -eq 1 -and -not $script:recoveryValues.First.valueExists) 'A legacy known-create contract removes only the unchanged applied value'
            Reset-RecoveryFixture
            Write-JsonFile @{moduleId='fixture';registry=@(@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;kind='DWord';oldValue=1});services=@()} $BackupPath
            $result=Invoke-RollbackModule
            Assert ($result.restoredRegistry -eq 0 -and $script:recoveryWrites -eq 0 -and $result.leftAsChanged[0].reason -like '*existence*evidence*') 'Missing original-existence evidence cannot be treated as an absent-before value'
        }
        if ($RecoveryCase -in 'All','Preflight') {
            foreach ($invalid in 'binary','service') {
                Reset-RecoveryFixture
                $bad=if ($invalid -eq 'binary') { @{path='HKCU\Fixture';name='Second';type='REG_DWORD';desiredData=2;kind='Binary';oldValue='%%%';valueExists=$true} } else { $second }
                $svc=if ($invalid -eq 'service') { @{name='FixtureSvc';exists=$true;startType='Invalid';status='Running';appliedStartup='Disabled'} } else { $service }
                Write-JsonFile @{moduleId='fixture';registry=@($first,$bad);services=@($svc)} $BackupPath
                $ConfirmApply=$true
                $threw=$false;$result=$null
                try { $result=Invoke-RollbackModule } catch { $threw=$true }
                Assert (-not $threw -and -not $result.success -and $null -ne $result.failures -and @($result.failures).Count -eq 1 -and $result.failures[0].phase -ceq 'preflight' -and $script:recoveryWrites -eq 0 -and $script:serviceWrites -eq 0 -and $script:recoveryValues.First.oldValue -eq 2) ($invalid+' failure is reported before any setting write')
            }
        }
        if ($RecoveryCase -in 'All','RegistryFailure') {
            foreach ($mode in 'throw','readback','external') {
                Reset-RecoveryFixture
                $script:failureName='Second';$script:failureMode=if ($mode -eq 'readback') {'readback'} else {'throw'}
                Write-JsonFile @{moduleId='fixture';registry=@($first,$second);services=@($service)} $BackupPath
                $hash=(Get-FileHash $BackupPath).Hash
                $ConfirmApply=$true
                $threw=$false;$result=$null
                try { $result=Invoke-RollbackModule } catch { $threw=$true }
                Assert (-not $threw -and -not $result.success -and $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 0 -and @($result.failures).Count -eq 1 -and $result.failures[0].name -ceq 'Second' -and @($result.pending).Count -eq 1 -and $script:recoveryValues.First.oldValue -eq 1 -and (Get-FileHash $BackupPath).Hash -ceq $hash) ($mode+' registry failure reports verified writes and untouched service with the backup retained')
                $script:failureMode=''
                if ($mode -eq 'external') { $script:recoveryValues.First=[pscustomobject]@{valueExists=$true;kind='DWord';oldValue=9} }
                $retry=Invoke-RollbackModule
                if ($mode -eq 'external') {
                    Assert ($retry.success -and $script:recoveryValues.First.oldValue -eq 9 -and @($retry.leftAsChanged).Count -eq 1 -and @($retry.alreadyAtOriginal).Count -eq 0 -and $retry.restoredRegistry -eq 1 -and $retry.restoredServices -eq 1) 'Retry preserves an external edit to a previously restored value'
                } else {
                    Assert ($retry.success -and @($retry.alreadyAtOriginal).Count -eq 1 -and $retry.alreadyAtOriginal[0].name -ceq 'First' -and $retry.restoredRegistry -eq $(if ($mode -eq 'readback') {0} else {1}) -and $retry.restoredServices -eq 1 -and @($retry.leftAsChanged).Count -eq $(if ($mode -eq 'readback') {1} else {0})) ($mode+' retry identifies already-original values and safely finishes independent work')
                }
            }
        }
        if ($RecoveryCase -in 'All','ServiceFailure') {
            foreach ($mode in 'throw','readback') {
                Reset-RecoveryFixture
                $script:failureName='FixtureSvc';$script:failureMode=$mode
                Write-JsonFile @{moduleId='fixture';registry=@($first);services=@($service,@{name='SecondSvc';exists=$true;startType='Automatic';status='Running';appliedStartup='Disabled'})} $BackupPath
                $ConfirmApply=$true
                $threw=$false;$result=$null
                try { $result=Invoke-RollbackModule } catch { $threw=$true }
                Assert (-not $threw -and -not $result.success -and $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 0 -and @($result.failures).Count -eq 1 -and @($result.pending).Count -eq 1 -and $script:recoveryServices.SecondSvc -ceq 'Disabled') ($mode+' service failure reports the failed and pending services after verified registry restoration')
                $script:failureMode=''
                $retry=Invoke-RollbackModule
                Assert ($retry.success -and @($retry.alreadyAtOriginal).Count -eq 1 -and $retry.restoredServices -eq $(if ($mode -eq 'readback') {1} else {2}) -and @($retry.leftAsChanged).Count -eq $(if ($mode -eq 'readback') {1} else {0})) ($mode+' service retry preserves drift and accurately reports the completed registry value')
            }
        }
        if ($RecoveryCase -in 'All','ServiceRuntime') { & {
            $savedManifestBytes=[IO.File]::ReadAllBytes($fixtureManifest)
            $runtimeRegistryWriter=${function:Set-RegistrySnapshotData}
            $rows=New-Object System.Collections.Generic.List[object]
            function Get-ServiceSnapshot { param($Name) & $sourceServiceReader $Name }
            function Restore-ServiceSnapshot { param($Snapshot) & $sourceServiceRestorer $Snapshot }
            function Get-Service {
                [CmdletBinding()]param([string]$Name)
                if ($script:runtimeQueryFailure) { throw 'Fixture service query failed' }
                if ($script:runtimeServices.ContainsKey($Name) -and $script:runtimeServices[$Name].exists) {
                    $state=$script:runtimeServices[$Name]
                    [pscustomobject]@{Name=$Name;DisplayName=$Name;StartType=$state.startup;Status=$state.status;ServicesDependedOn=@()}
                }
            }
            function Get-CimInstance { param($ClassName,$Filter) $null }
            function Add-RuntimeWrite {
                param($Operation,$Name)
                $script:runtimeCalls.Add([pscustomobject]@{operation=$Operation;name=$Name;errorAction=[string]$ErrorActionPreference}) | Out-Null
                if ($script:runtimeApplying) {
                    $files=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups\fixture') -Filter backup.json -Recurse -File)
                    $saved=if ($files.Count -eq 1) { Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json } else { $null }
                    $script:runtimeBackupBeforeWrites=$script:runtimeBackupBeforeWrites -and $null -ne $saved -and $saved.applyRequested -eq $true -and $saved.services[0].startType -ceq 'Automatic' -and $saved.services[0].status -ceq $script:runtimeOriginalStatus
                    if (@($saved.registry).Count) { $script:runtimeBackupBeforeWrites=$script:runtimeBackupBeforeWrites -and $saved.registry[0].oldValue -eq 1 }
                }
            }
            function Set-Service {
                [CmdletBinding()]param($Name,$StartupType)
                Add-RuntimeWrite 'set' $Name
                $script:runtimeServices[$Name].startup=[string]$StartupType
            }
            function Stop-Service {
                [CmdletBinding()]param($Name,[switch]$Force)
                Add-RuntimeWrite 'stop' $Name
                $script:runtimeServices[$Name].status='Stopped'
            }
            function Start-Service {
                [CmdletBinding()]param($Name)
                Add-RuntimeWrite 'start' $Name
                if ($Name -ceq 'FixtureSvc') {
                    switch ($script:runtimeMode) {
                        'nonterminating' { Write-Error 'Fixture service start rejected'; return }
                        'throw' { throw 'Fixture service start threw' }
                        'silent' { return }
                        'Stopped' { $script:runtimeServices[$Name].status='Stopped'; return }
                        'Paused' { $script:runtimeServices[$Name].status='Paused'; return }
                        'StartPending' { $script:runtimeServices[$Name].status='StartPending'; return }
                        'missing' { $script:runtimeServices[$Name].exists=$false; return }
                        'query' { $script:runtimeQueryFailure=$true }
                    }
                }
                $script:runtimeServices[$Name].status='Running'
            }
            function Get-RegistryValueSnapshot {
                param($Item,[switch]$AllowChangedLayout)
                $value=$script:recoveryValues[[string]$Item.name]
                [pscustomobject]@{path=$Item.path;name=$Item.name;type=$Item.type;desiredData=$Item.data;valueExists=$value.valueExists;kind=$value.kind;oldValue=$value.oldValue}
            }
            function Set-RegistrySnapshotData {
                param($Key,$Name,$Snapshot)
                Add-RuntimeWrite 'registry' $Name
                & $runtimeRegistryWriter $Key $Name $Snapshot
                if (-not $script:runtimeApplying -and $Name -ceq 'First' -and $script:runtimeLateState) {
                    $script:runtimeServices.FixtureSvc.startup=$script:runtimeLateState.startup
                    $script:runtimeServices.FixtureSvc.status=$script:runtimeLateState.status
                    $script:runtimeServices.FixtureSvc.exists=$script:runtimeLateState.exists
                }
            }
            function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
            function Invoke-SmokeTest { [pscustomobject]@{pass=$true} }
            function New-ServiceRuntimeFixture {
                param([string]$AppliedStartup='Disabled',[object]$OriginalStatus='Running',[switch]$ServicesOnly,[switch]$SingleService)
                Reset-RecoveryFixture
                $script:recoveryValues.First.oldValue=1
                $script:runtimeServices=@{
                    FixtureSvc=@{startup='Automatic';status=$OriginalStatus;exists=$true}
                    SecondSvc=@{startup='Automatic';status='Running';exists=$true}
                }
                $script:runtimeCalls=New-Object System.Collections.Generic.List[object]
                $script:runtimeMode='success';$script:runtimeQueryFailure=$false;$script:runtimeLateState=$null
                $script:runtimeOriginalStatus=[string]$OriginalStatus;$script:runtimeBackupBeforeWrites=$true
                $DataRoot=Join-Path $tempRoot ('service-runtime-'+[guid]::NewGuid().ToString('N'))
                $registry=@()
                if (-not $ServicesOnly) { $registry=@(@{path='HKCU\Fixture';name='First';type='REG_DWORD';data=2}) }
                $services=@(@{name='FixtureSvc';startup=$AppliedStartup;targetState='Stopped'})
                if (-not $SingleService) { $services+=@{name='SecondSvc';startup='Disabled';targetState='Stopped'} }
                Write-JsonFile @{protected=@{services=@();registryPathPatterns=@()};modules=@(@{id='fixture';name='Fixture';registryValues=@($registry);services=$services})} $fixtureManifest
                $ConfirmApply=$true;$script:runtimeApplying=$true
                $applied=Invoke-ReviewedApply
                $script:runtimeApplying=$false
                $bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($applied.backupPath))
                $saved=Get-Content -LiteralPath $applied.backupPath -Raw | ConvertFrom-Json
                $producerSafe=$script:runtimeBackupBeforeWrites -and $saved.services[0].appliedStartup -ceq $AppliedStartup -and $saved.services[0].status -ceq [string]$OriginalStatus -and $script:runtimeServices.FixtureSvc.status -ceq 'Stopped'
                $script:runtimeCalls.Clear()
                [pscustomobject]@{root=$DataRoot;path=$applied.backupPath;bytes=$bytes;producerSafe=$producerSafe}
            }
            function Test-RuntimeBackup { param($Operation) [Convert]::ToBase64String([IO.File]::ReadAllBytes($Operation.path)) -ceq $Operation.bytes }
            try {
                foreach ($selection in 'explicit','latest') {
                    foreach ($mode in 'nonterminating','throw','silent','Stopped','Paused','StartPending','missing','query','success') {
                        $operation=New-ServiceRuntimeFixture
                        $DataRoot=$operation.root;$BackupPath=if ($selection -ceq 'explicit') {$operation.path} else {''}
                        $ConfirmApply=$false;$preview=Invoke-RollbackModule
                        $previewSafe=$preview.success -and $preview.dryRun -and -not $preview.partial -and $preview.restoredRegistry -eq 1 -and $preview.restoredServices -eq 2 -and $script:runtimeCalls.Count -eq 0 -and (Test-RuntimeBackup $operation)
                        $script:runtimeMode=$mode;$ConfirmApply=$true
                        $result=Invoke-RollbackModule
                        $calls=@($script:runtimeCalls.ToArray())
                        $after=[pscustomobject]@{startup=$script:runtimeServices.FixtureSvc.startup;status=$script:runtimeServices.FixtureSvc.status;exists=$script:runtimeServices.FixtureSvc.exists}
                        $failureSafe=if ($mode -ceq 'success') {
                            $result.success -and -not $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 2 -and $result.failures.Count -eq 0 -and $result.pending.Count -eq 0 -and $after.status -ceq 'Running'
                        } else {
                            -not $result.success -and $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 0 -and $result.failures.Count -eq 1 -and $result.failures[0].name -ceq 'FixtureSvc' -and $result.failures[0].phase -ceq 'restore' -and $result.failures[0].mayHaveChanged -and $result.actions[1].status -ceq 'failed' -and $result.pending.Count -eq 1 -and $result.pending[0].name -ceq 'SecondSvc' -and $script:runtimeServices.SecondSvc.startup -ceq 'Disabled' -and @($calls|Where-Object {$_.name -ceq 'SecondSvc'}).Count -eq 0
                        }
                        $script:runtimeMode='success';$script:runtimeQueryFailure=$false;$script:runtimeCalls.Clear()
                        $retry=Invoke-RollbackModule
                        $retrySafe=if ($mode -ceq 'success') {
                            $retry.success -and $retry.restoredRegistry -eq 0 -and $retry.restoredServices -eq 0 -and $retry.alreadyAtOriginal.Count -eq 3 -and $script:runtimeCalls.Count -eq 0
                        } elseif ($mode -ceq 'query') {
                            $retry.success -and -not $retry.partial -and $retry.restoredServices -eq 1 -and $retry.alreadyAtOriginal.Count -eq 2 -and $retry.leftAsChanged.Count -eq 0 -and @($script:runtimeCalls|Where-Object {$_.name -ceq 'FixtureSvc'}).Count -eq 0
                        } else {
                            $retry.success -and -not $retry.partial -and $retry.restoredRegistry -eq 0 -and $retry.restoredServices -eq 1 -and $retry.alreadyAtOriginal.Count -eq 1 -and $retry.alreadyAtOriginal[0].name -ceq 'First' -and $retry.leftAsChanged.Count -eq 1 -and $retry.leftAsChanged[0].name -ceq 'FixtureSvc' -and ($mode -ceq 'missing' -or $retry.leftAsChanged[0].reason -like '*runtime ownership*') -and @($script:runtimeCalls|Where-Object {$_.name -ceq 'FixtureSvc'}).Count -eq 0
                        }
                        $rows.Add([pscustomobject]@{family='failure';selection=$selection;mode=$mode;producerSafe=$operation.producerSafe;previewSafe=$previewSafe;outcomeSafe=$failureSafe;retrySafe=$retrySafe;after=$after;result=$result;retry=$retry;calls=$calls;retryCalls=@($script:runtimeCalls.ToArray());backupUnchanged=(Test-RuntimeBackup $operation)}) | Out-Null
                    }
                }
                foreach ($state in 'Stopped','Running') {
                    $operation=New-ServiceRuntimeFixture -AppliedStartup Automatic
                    $DataRoot=$operation.root;$BackupPath=$operation.path
                    $script:runtimeServices.FixtureSvc.status=$state
                    $ConfirmApply=$false;$preview=Invoke-RollbackModule
                    $previewSafe=$preview.success -and $preview.restoredServices -eq 1 -and $script:runtimeCalls.Count -eq 0
                    $ConfirmApply=$true;$result=Invoke-RollbackModule
                    $safe=$result.success -and $result.restoredServices -eq 1 -and @($script:runtimeCalls|Where-Object {$_.name -ceq 'FixtureSvc'}).Count -eq 0
                    $safe=$safe -and $(if ($state -ceq 'Stopped') {$result.leftAsChanged.Count -eq 1 -and $result.leftAsChanged[0].name -ceq 'FixtureSvc' -and $result.leftAsChanged[0].reason -like '*runtime ownership*' -and $result.alreadyAtOriginal.Count -eq 0 -and $script:runtimeServices.FixtureSvc.status -ceq 'Stopped'} else {$result.alreadyAtOriginal.Count -eq 1 -and $result.alreadyAtOriginal[0].name -ceq 'FixtureSvc' -and $result.leftAsChanged.Count -eq 0})
                    $rows.Add([pscustomobject]@{family='sameStartup';state=$state;producerSafe=$operation.producerSafe;previewSafe=$previewSafe;outcomeSafe=$safe;result=$result;calls=@($script:runtimeCalls.ToArray());backupUnchanged=(Test-RuntimeBackup $operation)}) | Out-Null
                }
                foreach ($late in @(@{startup='Automatic';status='Stopped';exists=$true},@{startup='Automatic';status='Running';exists=$true},@{startup='Manual';status='Stopped';exists=$true},@{startup='Disabled';status='Stopped';exists=$false})) {
                    $operation=New-ServiceRuntimeFixture
                    $DataRoot=$operation.root;$BackupPath=$operation.path;$script:runtimeLateState=$late
                    $ConfirmApply=$false;$preview=Invoke-RollbackModule
                    $previewSafe=$preview.success -and $preview.restoredRegistry -eq 1 -and $preview.restoredServices -eq 2 -and $script:runtimeCalls.Count -eq 0
                    $ConfirmApply=$true;$result=Invoke-RollbackModule
                    $safe=$result.success -and -not $result.partial -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 1 -and @($script:runtimeCalls|Where-Object {$_.name -ceq 'FixtureSvc'}).Count -eq 0
                    $safe=$safe -and $(if ($late.status -ceq 'Running') {$result.alreadyAtOriginal.Count -eq 1 -and $result.alreadyAtOriginal[0].name -ceq 'FixtureSvc' -and $result.actions[1].status -ceq 'alreadyAtOriginal' -and $result.leftAsChanged.Count -eq 0} else {$result.alreadyAtOriginal.Count -eq 0 -and $result.leftAsChanged.Count -eq 1 -and $result.leftAsChanged[0].name -ceq 'FixtureSvc' -and $result.actions[1].status -ceq 'leftAsChanged'})
                    $rows.Add([pscustomobject]@{family='late';input=$late;producerSafe=$operation.producerSafe;previewSafe=$previewSafe;outcomeSafe=$safe;result=$result;calls=@($script:runtimeCalls.ToArray());backupUnchanged=(Test-RuntimeBackup $operation)}) | Out-Null
                }
                foreach ($state in 'Stopped','Paused','StartPending','StopPending','PausePending','ContinuePending','') {
                    $operation=New-ServiceRuntimeFixture -OriginalStatus $state
                    $DataRoot=$operation.root;$BackupPath=$operation.path
                    if ($state -ceq '') {
                        $saved=Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
                        $saved.services[0].PSObject.Properties.Remove('status')
                        Write-JsonFile $saved $BackupPath
                        $operation.bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($BackupPath))
                    }
                    $ConfirmApply=$false;$preview=Invoke-RollbackModule
                    $previewSafe=$preview.success -and $preview.restoredServices -eq 2 -and $script:runtimeCalls.Count -eq 0
                    $ConfirmApply=$true;$result=Invoke-RollbackModule
                    $calls=@($script:runtimeCalls.ToArray());$script:runtimeCalls.Clear()
                    $retry=Invoke-RollbackModule
                    $safe=$result.success -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 2 -and $script:runtimeServices.FixtureSvc.startup -ceq 'Automatic' -and $script:runtimeServices.FixtureSvc.status -ceq 'Stopped' -and @($calls|Where-Object {$_.name -ceq 'FixtureSvc' -and $_.operation -in 'start','stop'}).Count -eq 0 -and $retry.success -and $retry.restoredServices -eq 0 -and $retry.alreadyAtOriginal.Count -eq 3 -and $script:runtimeCalls.Count -eq 0
                    $rows.Add([pscustomobject]@{family='nonRunning';originalStatus=$state;producerSafe=$operation.producerSafe;previewSafe=$previewSafe;outcomeSafe=$safe;result=$result;retry=$retry;calls=$calls;backupUnchanged=(Test-RuntimeBackup $operation)}) | Out-Null
                }
                $operation=New-ServiceRuntimeFixture -ServicesOnly -SingleService
                $DataRoot=$operation.root;$BackupPath=$operation.path;$ConfirmApply=$true;$script:runtimeMode='nonterminating'
                $failed=Invoke-RollbackModule
                $firstCurrent=ConvertTo-Json -InputObject $script:runtimeServices.FixtureSvc -Compress
                $script:runtimeMode='success';$script:runtimeCalls.Clear()
                $firstRetry=Invoke-RollbackModule;$firstCalls=@($script:runtimeCalls.ToArray())
                $script:runtimeServices.FixtureSvc.startup='Disabled';$script:runtimeServices.FixtureSvc.status='Stopped'
                $complete=Invoke-RollbackModule
                $script:runtimeServices.FixtureSvc.status='Stopped'
                $secondCurrent=ConvertTo-Json -InputObject $script:runtimeServices.FixtureSvc -Compress
                $script:runtimeCalls.Clear();$secondRetry=Invoke-RollbackModule
                $safe=-not $failed.success -and $failed.partial -and $complete.success -and $firstCurrent -ceq $secondCurrent -and $firstCalls.Count -eq 0 -and $script:runtimeCalls.Count -eq 0
                foreach ($observed in $firstRetry,$secondRetry) { $safe=$safe -and $observed.success -and $observed.restoredServices -eq 0 -and $observed.alreadyAtOriginal.Count -eq 0 -and $observed.leftAsChanged.Count -eq 1 -and $observed.leftAsChanged[0].reason -like '*runtime ownership*' }
                $rows.Add([pscustomobject]@{family='histories';producerSafe=$operation.producerSafe;outcomeSafe=$safe;firstCurrent=$firstCurrent;secondCurrent=$secondCurrent;backupBytes=$operation.bytes;failure=$failed;complete=$complete;firstRetry=$firstRetry;secondRetry=$secondRetry;firstCalls=$firstCalls;secondCalls=@($script:runtimeCalls.ToArray());backupUnchanged=(Test-RuntimeBackup $operation)}) | Out-Null
                & {
                    $operation=New-ServiceRuntimeFixture -ServicesOnly -SingleService
                    $DataRoot=$operation.root;$BackupPath=$operation.path;$script:runtimeMode='nonterminating'
                    $cliServices=$script:runtimeServices;$cliCalls=$script:runtimeCalls
                    Set-Item Function:\Get-Service -Value {
                        [CmdletBinding()]param([string]$Name)
                        if ($cliServices.ContainsKey($Name) -and $cliServices[$Name].exists) {
                            $state=$cliServices[$Name]
                            [pscustomobject]@{Name=$Name;DisplayName=$Name;StartType=$state.startup;Status=$state.status;ServicesDependedOn=@()}
                        }
                    }.GetNewClosure()
                    Set-Item Function:\Set-Service -Value {
                        [CmdletBinding()]param($Name,$StartupType)
                        $cliCalls.Add([pscustomobject]@{operation='set';name=$Name;errorAction=[string]$ErrorActionPreference}) | Out-Null
                        $cliServices[$Name].startup=[string]$StartupType
                    }.GetNewClosure()
                    Set-Item Function:\Start-Service -Value {
                        [CmdletBinding()]param($Name)
                        $cliCalls.Add([pscustomobject]@{operation='start';name=$Name;errorAction=[string]$ErrorActionPreference}) | Out-Null
                        Write-Error 'Fixture service start rejected'
                    }.GetNewClosure()
                    $emitted=New-Object System.Collections.Generic.List[object]
                    $caught=$null
                    try { & $HarnessPath -Action RollbackModule -ModuleId fixture -ManifestPath $fixtureManifest -DataRoot $DataRoot -BackupPath $BackupPath -ConfirmApply | ForEach-Object {$emitted.Add($_) | Out-Null} } catch { $caught=$_.Exception }
                    $detail=if ($caught) {$caught.Data['RollbackResult']} else {$null}
                    $safe=$null -ne $caught -and $caught -is [InvalidOperationException] -and $emitted.Count -eq 1 -and -not $emitted[0].success -and $emitted[0].partial -and $emitted[0].restoredServices -eq 0 -and $emitted[0].failures[0].mayHaveChanged -and $null -ne $detail -and -not $detail.success -and $detail.backupPath -ceq $operation.path
                    $rows.Add([pscustomobject]@{family='cli';producerSafe=$operation.producerSafe;outcomeSafe=$safe;thrown=($null -ne $caught);exceptionType=$(if($caught){$caught.GetType().FullName}else{$null});emitted=@($emitted.ToArray());detail=$detail;calls=@($script:runtimeCalls.ToArray());backupUnchanged=(Test-RuntimeBackup $operation);native=$false}) | Out-Null
                }
                Write-Output ('SERVICE_RUNTIME_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 12 -Compress))
                Assert (@($rows|Where-Object {-not $_.producerSafe -or -not $_.backupUnchanged}).Count -eq 0) 'Service runtime cases use complete pre-write backups and retain exact backup bytes'
                Assert (@($rows|Where-Object {$_.PSObject.Properties['previewSafe'] -and -not $_.previewSafe}).Count -eq 0) 'Service runtime previews classify original and ambiguous state without writes'
                Assert (@($rows|Where-Object {$_.family -ceq 'failure' -and -not $_.outcomeSafe}).Count -eq 0) 'Start and Running readback failures report verified counts partial failures and untouched pending services'
                Assert (@($rows|Where-Object {$_.family -ceq 'failure' -and -not $_.retrySafe}).Count -eq 0) 'Service retries preserve unproven runtime changes while independent restoration continues'
                Assert (@($rows|Where-Object {$_.family -ceq 'sameStartup' -and -not $_.outcomeSafe}).Count -eq 0) 'Matching original and applied startup never grants an unproven restart'
                Assert (@($rows|Where-Object {$_.family -ceq 'late' -and -not $_.outcomeSafe}).Count -eq 0) 'Late original startup distinguishes verified Running from ambiguous runtime without service writes'
                Assert (@($rows|Where-Object {$_.family -ceq 'nonRunning' -and -not $_.outcomeSafe}).Count -eq 0) 'Non-Running original services retain startup-only semantics and retry without new runtime commands'
                Assert (@($rows|Where-Object {$_.family -ceq 'histories' -and -not $_.outcomeSafe}).Count -eq 0) 'Identical failed-start and external-stop evidence receives the same conservative retry disposition'
                Assert (@($rows|Where-Object {$_.family -ceq 'cli' -and -not $_.outcomeSafe}).Count -eq 0) 'The whole service rollback CLI emits its failed result throws with structured details and retains the backup'
            } finally { [IO.File]::WriteAllBytes($fixtureManifest,$savedManifestBytes) }
        } }
    } }
    if ($Scenario -in 'All','Selection','Drift') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        if ($Scenario -ne 'Selection') { & {
            function Open-RegistryKey {
                param($Path,[switch]$Writable,[switch]$Create)
                $key=[pscustomobject]@{}
                $key | Add-Member -MemberType ScriptMethod -Name Dispose -Value {} -PassThru
            }
            function Set-RegistrySnapshotData { param($Key,$Name,$Snapshot) $script:legacyQwordValue=[string]$Snapshot.oldValue }
            function Get-RegistryValueSnapshot { param($Item) [pscustomobject]@{valueExists=$true;kind='QWord';oldValue=$script:legacyQwordValue} }
            $ConfirmApply=$true
            $BackupPath=Join-Path $tempRoot 'legacy-qword-stub.json'
            foreach ($case in $legacyQwordCases) {
                $script:legacyQwordValue='2'
                $backup=@{moduleId='fixture';timestamp=(Get-Date).ToString('o');registry=@(@{path='HKCU\Fixture';name='Value';type='REG_QWORD';desiredData=2;oldValue=$case.data;valueExists=$true});services=@()}
                Write-JsonFile $backup $BackupPath
                Restore-RegistryValue ([pscustomobject]$backup.registry[0])
                Assert ($script:legacyQwordValue -ceq $case.encoded) ('Legacy QWORD '+$case.label+' helper preserves the provider integer bits')
            }
        } }
        # Only operating-system calls are replaced; backup selection and apply/rollback execute the real harness.
        $script:value = 1
        function Get-RegistryValueSnapshot { param($Item) [pscustomobject]@{ path=$Item.path; name=$Item.name; type='REG_DWORD'; desiredData=2; kind='DWord'; oldValue=$script:value; pathExists=$true; valueExists=$true } }
        function Set-RegistryValueFromManifest { param($Item) $script:value = $Item.data }
        function Restore-RegistryValue { param($Snapshot) $script:value = $Snapshot.oldValue }
        function Get-BenchmarkSnapshot { param($Label) @{ label = $Label } }
        function Invoke-SmokeTest { @() }
        $ConfirmApply = $false
        $preview = Invoke-ApplyModule
        Assert ($null -eq $preview.backupPath) 'Preview creates no rollback snapshot'
        Assert ($script:value -eq 1) 'Preview leaves original state intact'
        $ConfirmApply = $true
        $PreviewPath = $preview.previewPath; $applied = Invoke-ApplyModule
        Assert ($script:value -eq 2 -and (Test-Path $applied.backupPath)) 'Confirmed apply persists the original state before changing it'
        $ConfirmApply = $false
        Invoke-ApplyModule | Out-Null
        $ConfirmApply = $true
        $restored = Invoke-RollbackModule
        Assert ($script:value -eq 1 -and $restored.backupPath -eq $applied.backupPath) 'Apply then preview then rollback restores the pre-apply value'
        $strayRoot = Join-Path $tempRoot 'backups\fixture\99999999-preview'
        New-Item -ItemType Directory -Path $strayRoot | Out-Null
        @{ moduleId='fixture'; timestamp='2099-01-01T00:00:00Z'; registry=@(@{oldValue=99}); services=@() } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $strayRoot 'backup.json')
        $script:value = 2
        Invoke-RollbackModule | Out-Null
        Assert ($script:value -eq 1) 'Unproven legacy preview snapshots cannot displace an applied operation'
        $second = Invoke-ReviewedApply
        Assert ($second.backupPath -ne $applied.backupPath) 'Repeated operations have distinct backup paths'
        $BackupPath = $applied.backupPath
        $ConfirmApply = $false
        $preview = Invoke-RollbackModule
        Assert ($script:value -eq 2 -and $preview.dryRun) 'Rollback preview does not restore an unchanged value'
        $ConfirmApply = $true
        Invoke-RollbackModule | Out-Null
        Assert ($script:value -eq 1) 'Explicit backup selection restores the requested operation'
        $BackupPath = Join-Path $tempRoot 'wrong-module.json'
        @{moduleId='other'; registry=@(); services=@()} | ConvertTo-Json | Set-Content $BackupPath
        $rejected = $false
        try { Invoke-RollbackModule | Out-Null } catch { $rejected = $_.Exception.Message -like '*different module*' }
        Assert $rejected 'Rollback rejects a backup for another module'
        if ($Scenario -ne 'Selection') {
            $BackupPath = $applied.backupPath
            $script:value = 3
            $ConfirmApply = $false
            $preview = Invoke-RollbackModule
            Assert ($script:value -eq 3 -and @($preview.leftAsChanged).Count -eq 1 -and $preview.restoredRegistry -eq 0) 'Rollback preview identifies later registry changes'
            $ConfirmApply = $true
            $restored = Invoke-RollbackModule
            Assert ($script:value -eq 3 -and @($restored.leftAsChanged).Count -eq 1 -and $restored.leftAsChanged[0].path -eq 'HKCU\Fixture' -and $restored.leftAsChanged[0].name -eq 'Value') 'Confirmed rollback preserves and identifies later registry changes'
            function Get-ServiceSnapshot { param($Name) [pscustomobject]@{ name=$Name; exists=$script:serviceExists; startType=$script:startup; status='Running' } }
            function Set-ServiceFromManifest { param($Item) $script:startup=$Item.startup }
            function Restore-ServiceSnapshot { param($Snapshot) $script:startup=$Snapshot.startType; $script:serviceRestores++ }
            $manifest = Get-Content $fixtureManifest -Raw | ConvertFrom-Json
            $manifest.modules[0].registryValues = @()
            $manifest.modules[0].services = @(@{name='FixtureSvc';startup='Disabled';targetState='Stopped'})
            $manifest | ConvertTo-Json -Depth 8 | Set-Content $fixtureManifest
            $script:serviceExists=$true
            $script:startup='Automatic'
            $script:serviceRestores=0
            $applied = Invoke-ReviewedApply
            $BackupPath=$applied.backupPath
            $manifest.modules[0].services[0].startup='Manual'
            $manifest | ConvertTo-Json -Depth 8 | Set-Content $fixtureManifest
            $ConfirmApply=$false
            $preview=Invoke-RollbackModule
            Assert ($preview.restoredServices -eq 1 -and $script:startup -eq 'Disabled') 'Service preview uses saved applied startup despite a later manifest edit'
            $ConfirmApply=$true
            $restored=Invoke-RollbackModule
            Assert ($script:startup -eq 'Automatic' -and $restored.restoredServices -eq 1) 'An unchanged service restores its original startup'
            $script:startup='Manual'
            $before=$script:serviceRestores
            $ConfirmApply=$false
            $preview=Invoke-RollbackModule
            Assert ($preview.restoredServices -eq 0 -and $preview.leftAsChanged[0].name -eq 'FixtureSvc') 'Service preview identifies later startup changes'
            $ConfirmApply=$true
            $restored=Invoke-RollbackModule
            Assert ($script:startup -eq 'Manual' -and $script:serviceRestores -eq $before -and $restored.restoredServices -eq 0) 'Service drift never restores startup or restarts a service'
            $script:serviceExists=$false
            $restored=Invoke-RollbackModule
            Assert (@($restored.leftAsChanged).Count -eq 1 -and $script:serviceRestores -eq $before) 'A removed service is left alone'
            $script:serviceExists=$true
            $legacy=Get-Content $BackupPath -Raw | ConvertFrom-Json
            $legacy.services[0].PSObject.Properties.Remove('appliedStartup')
            Write-JsonFile $legacy $BackupPath
            $script:startup='Disabled'
            $restored=Invoke-RollbackModule
            Assert ($script:serviceRestores -eq $before -and @($restored.leftAsChanged).Count -eq 1) 'A legacy service backup without applied startup is left for review'
            & {
                $script:instanceTypes=@{FixtureSvc_a='Disabled';FixtureSvc_b='Manual'}
                function Get-ServiceSnapshot { param($Name) [pscustomobject]@{name=$Name;exists=$true;startType=$script:instanceTypes[$Name]} }
                function Restore-ServiceSnapshot { param($Snapshot) $script:instanceTypes[$Snapshot.name]=$Snapshot.startType }
                $instances=[pscustomobject]@{ moduleId='fixture';timestamp=(Get-Date).ToString('o');registry=@();services=@(
                    @{name='FixtureSvc_a';exists=$true;startType='Automatic';appliedStartup='Disabled'},
                    @{name='FixtureSvc_b';exists=$true;startType='Automatic';appliedStartup='Disabled'}
                ) }
                Write-JsonFile $instances $BackupPath
                $restored=Invoke-RollbackModule
                Assert ($script:instanceTypes.FixtureSvc_a -eq 'Automatic' -and $script:instanceTypes.FixtureSvc_b -eq 'Manual' -and $restored.restoredServices -eq 1 -and $restored.leftAsChanged[0].name -eq 'FixtureSvc_b') 'Service instances restore independently and preserve the instance with drift'
                function Get-ServiceSnapshot { param($Name) [pscustomobject]@{name='FixtureSvc_new';exists=$true;startType='Disabled'} }
                $restored=Invoke-RollbackModule
                Assert ($restored.restoredServices -eq 0 -and @($restored.leftAsChanged).Count -eq 2) 'A newly resolved service instance cannot replace an original target'
            }
            & {
                $shipped=Get-Content (Join-Path (Split-Path $HarnessPath -Parent) 'modules\tweak_manifest.json') -Raw | ConvertFrom-Json
                $manifest=Get-Content $fixtureManifest -Raw | ConvertFrom-Json
                $manifest.protected=$shipped.protected
                $manifest.modules[0].services=@()
                $targets=@(
                    @{path='HKLM\Software\Policies\Microsoft\Windows\AppPrivacy';name='LetAppsAccessPhone'},
                    @{path='HKLM/SOFTWARE/Microsoft/Windows/CurrentVersion/CapabilityAccessManager/ConsentStore/bluetooth';name='Value'},
                    @{path='HKEY_LOCAL_MACHINE\Software\Policies\Microsoft\Windows\AppPrivacy';name='LetAppsAccessPhone'},
                    @{path='HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\bluetooth\';name='Value'}
                )
                $script:registryWrites=0
                $script:registryRestores=0
                $script:registryReads=0
                function Get-RegistryValueSnapshot { param($Item) $script:registryReads++; [pscustomobject]@{path=$Item.path;name=$Item.name;type='REG_DWORD';desiredData=2;kind='DWord';oldValue=$script:value;valueExists=$true} }
                function Set-RegistryValueFromManifest { param($Item) $script:registryWrites++; $script:value=$Item.data }
                function Restore-RegistryValue { param($Snapshot) $script:registryRestores++; $script:value=$Snapshot.oldValue }
                foreach ($target in $targets) {
                    $manifest.modules[0].registryValues=@(@{path=$target.path;name=$target.name;type='REG_DWORD';data=2})
                    Write-JsonFile $manifest $fixtureManifest
                    $script:value=1
                    $ConfirmApply=$false
                    $preview=Invoke-ApplyModule
                    Assert ($preview.actions[0].blocked -and $script:value -eq 1) ('Apply preview protects the normalized full target ' + $target.name)
                    $ConfirmApply=$true
                    $PreviewPath=$preview.previewPath;$applied=Invoke-ApplyModule
                    $saved=Get-Content $applied.backupPath -Raw | ConvertFrom-Json
                    Assert (@($saved.registry).Count -eq 0 -and $script:registryWrites -eq 0 -and $script:value -eq 1) ('Confirmed apply excludes the normalized protected target ' + $target.name)
                    $legacy=[pscustomobject]@{moduleId='fixture';timestamp=(Get-Date).ToString('o');registry=@(@{path=$target.path;name=$target.name;type='REG_DWORD';desiredData=2;oldValue=1;valueExists=$true});services=@()}
                    $BackupPath=$applied.backupPath
                    Write-JsonFile $legacy $BackupPath
                    $script:value=2
                    $ConfirmApply=$false
                    $preview=Invoke-RollbackModule
                    Assert ($preview.restoredRegistry -eq 0 -and @($preview.leftAsChanged).Count -eq 1) ('Rollback preview protects the legacy full target ' + $target.name)
                    $ConfirmApply=$true
                    $restored=Invoke-RollbackModule
                    Assert ($script:value -eq 2 -and $script:registryRestores -eq 0 -and $restored.leftAsChanged[0].path -ceq $target.path -and $restored.leftAsChanged[0].name -ceq $target.name) ('Confirmed rollback leaves the legacy full target ' + $target.name)
                }
                Assert ($script:registryReads -eq 0) 'Protected targets never reach the registry OS calls'
            }
        }
    } }
    if ($Scenario -in 'All','PreviewBinding') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        $ManifestPath=Join-Path $tempRoot 'binding-manifest.json'
        $bindingFailures=New-Object System.Collections.Generic.List[string]
        function Test-BindingCase([bool]$Condition,[string]$Message) {
            if ($Condition) { Write-Host "PASS $Message" } else { Write-Host "FAIL $Message"; $bindingFailures.Add($Message) }
        }
        function Open-RegistryKey {
            param($Path,[switch]$Writable,[switch]$Create)
            $key=[pscustomobject]@{}
            $key|Add-Member ScriptMethod DeleteValue {param($Name,$Throw) $script:bindingWrites.Add('delete '+$Name);$script:bindingValues.Remove([string]$Name)}
            $key|Add-Member ScriptMethod Dispose {} -PassThru
        }
        function Get-RegistryValueSnapshot {
            param($Item,[switch]$AllowChangedLayout)
            $current=$script:bindingValues[[string]$Item.name]
            [pscustomobject]@{path=$Item.path;name=[string]$Item.name;type=$Item.type;desiredData=$Item.data;pathExists=$true;valueExists=($null -ne $current);kind=$(if($current){$current.kind});oldValue=$(if($current){$current.value})}
        }
        function Set-RegistrySnapshotData {
            param($Key,$Name,$Snapshot)
            $script:bindingWrites.Add([string]$Name+'='+$Snapshot.kind+':'+(@($Snapshot.oldValue) -join ','))
            $script:bindingValues[[string]$Name]=@{kind=$Snapshot.kind;value=$Snapshot.oldValue}
        }
        function Get-ServiceSnapshot { param($Name) [pscustomobject]@{name=$Name;exists=$true;startType=$script:bindingStartup;status='Stopped'} }
        function Set-ServiceFromManifest { param($Item) $script:bindingWrites.Add('service='+$Item.startup);$script:bindingStartup=$Item.startup }
        function Restore-ServiceSnapshot { param($Snapshot) $script:bindingWrites.Add('service='+$Snapshot.startType);$script:bindingStartup=$Snapshot.startType }
        function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
        function Invoke-SmokeTest { @() }
        function Reset-BindingFixture {
            param([string]$Label)
            $script:bindingValues=@{First=@{kind='DWord';value=1};Second=@{kind='String';value='One'};'Split\Name'=@{kind='DWord';value=1};Third=@{kind='DWord';value=1};Fourth=@{kind='DWord';value=1}}
            $script:bindingWrites=New-Object System.Collections.Generic.List[string]
            $script:bindingStartup='Automatic'
            $registry=@(
                @{path='HKCU\Fixture';name='First';type='REG_DWORD';data=2},
                @{path='HKCU\Fixture';name='Second';type='REG_SZ';data='Two'},
                @{path='HKCU\Fixture';name='Split\Name';type='REG_DWORD';data=2},
                @{path='HKCU\Fixture\Protected';name='Third';type='REG_DWORD';data=2}
            )
            $services=@(@{name='FixtureSvc';startup='Disabled';targetState='Stopped'})
            Write-JsonFile @{protected=@{services=@();registryPathPatterns=@('Fixture\\Protected')};modules=@(
                @{id='fixture';name='Fixture';registryValues=$registry;services=$services},
                @{id='other';name='Other';registryValues=$registry;services=$services}
            )} $ManifestPath
            return (Join-Path $tempRoot ('binding-'+$Label+'-'+[guid]::NewGuid().ToString('N')))
        }
        function Edit-BindingManifest {
            param([scriptblock]$Edit)
            $manifest=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
            & $Edit $manifest
            Write-JsonFile $manifest $ManifestPath
        }
        function Get-BindingState {
            $runs=@(if (Test-Path -LiteralPath (Join-Path $DataRoot 'runs')) { Get-ChildItem -LiteralPath (Join-Path $DataRoot 'runs') -Filter 'apply-*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } })
            [pscustomobject]@{
                writes=$script:bindingWrites.Count
                backups=@(if (Test-Path -LiteralPath (Join-Path $DataRoot 'backups')) { Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups') -Recurse -Force }).Count
                applied=@($runs|Where-Object {$_.dryRun -eq $false}).Count
                previews=@($runs|Where-Object {$_.dryRun -eq $true}).Count
            }
        }
        function Test-BindingRefusal {
            param([string]$Label,[string]$Expect)
            $ConfirmApply=$true
            $message=$null
            try { Invoke-ApplyModule|Out-Null } catch { $message=$_.Exception.Message }
            $state=Get-BindingState
            Test-BindingCase ($null -ne $message -and $message.Contains($Expect) -and $message.Contains('Nothing was changed') -and $state.writes -eq 0 -and $state.backups -eq 0 -and $state.applied -eq 0) ('Confirmed apply refuses '+$Label+' before any backup or write')
            if ($null -ne $message -and -not $message.Contains($Expect)) { Write-Host "  message: $message" }
        }

        $DataRoot=Reset-BindingFixture 'gates'
        $ConfirmApply=$false
        $reviewed=Invoke-ApplyModule
        $record=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'runs') -Filter 'apply-*.json' -File)[0].FullName
        Test-BindingCase ($reviewed.dryRun -and $reviewed.previewHash -cmatch '^[0-9a-f]{64}$' -and [string]$reviewed.previewPath -ceq $record -and (Get-BindingState).writes -eq 0) 'A preview saves its plan hash in the preview file it names'
        $ModuleId='other'
        $otherPreview=(Invoke-ApplyModule).previewPath
        $ModuleId='fixture'
        $saved=Get-Content -LiteralPath $record -Raw|ConvertFrom-Json
        $applied=Join-Path $tempRoot 'binding-applied-record.json'
        $saved.dryRun=$false
        Write-JsonFile $saved $applied
        $earlier=Join-Path $tempRoot 'binding-earlier-preview.json'
        $saved=Get-Content -LiteralPath $record -Raw|ConvertFrom-Json
        foreach ($name in 'previewHash','previewPath','plan') { $saved.PSObject.Properties.Remove($name) }
        Write-JsonFile $saved $earlier
        $edited=Join-Path $tempRoot 'binding-edited-hash.json'
        $saved=Get-Content -LiteralPath $record -Raw|ConvertFrom-Json
        $saved | Add-Member -NotePropertyName previewHash -NotePropertyValue ('A'*64) -Force
        Write-JsonFile $saved $edited
        $malformed=Join-Path $tempRoot 'binding-malformed-preview.json'
        Set-Content -LiteralPath $malformed -Value 'not json' -Encoding UTF8
        foreach ($gate in @(
            @{label='without a preview';path='';expect='-PreviewPath'},
            @{label='a missing preview file';path=(Join-Path $tempRoot 'binding-missing.json');expect='Cannot read the preview'},
            @{label='an unreadable preview file';path=$malformed;expect='Cannot read the preview'},
            @{label='a confirmed run record as its preview';path=$applied;expect='is not a preview'},
            @{label="another module's preview";path=$otherPreview;expect="is for module 'other'"},
            @{label='a preview from an earlier version';path=$earlier;expect='no plan hash'},
            @{label='a preview with an edited hash';path=$edited;expect='no plan hash'}
        )) {
            $PreviewPath=$gate.path
            Test-BindingRefusal $gate.label $gate.expect
        }
        $PreviewPath=$reviewed.previewPath
        $ConfirmApply=$true
        $result=$null
        try { $result=Invoke-ApplyModule } catch { Write-Host "  error: $($_.Exception.Message)" }
        Test-BindingCase ($null -ne $result -and $null -ne $reviewed.previewHash -and $result.previewHash -ceq $reviewed.previewHash -and $result.previewPath -ceq $reviewed.previewPath -and $script:bindingValues.First.value -eq 2 -and $script:bindingValues.Second.value -ceq 'Two' -and $script:bindingValues.Third.value -eq 1 -and $script:bindingStartup -ceq 'Disabled') 'The reviewed preview applies its exact plan and records which preview it used'
        $BackupPath=$result.backupPath
        $restored=Invoke-RollbackModule
        $again=$null
        try { $again=Invoke-ApplyModule } catch { Write-Host "  error: $($_.Exception.Message)" }
        Test-BindingCase ($restored.success -and $null -ne $again -and $script:bindingValues.First.value -eq 2) 'The same reviewed preview applies again after an undo'

        foreach ($edit in @(
            @{label='changed DWORD data';expect='HKCU\Fixture\First: REG_DWORD 2 -> REG_DWORD 3';edit={param($m) $m.modules[0].registryValues[0].data=3}},
            @{label='changed registry type';expect='HKCU\Fixture\First: REG_DWORD 2 -> REG_QWORD 2';edit={param($m) $m.modules[0].registryValues[0].type='REG_QWORD'}},
            @{label='changed text case';expect='HKCU\Fixture\Second: REG_SZ Two -> REG_SZ two';edit={param($m) $m.modules[0].registryValues[1].data='two'}},
            @{label='added setting';expect='added HKCU\Fixture\Fourth (REG_DWORD 4)';edit={param($m) $m.modules[0].registryValues+=[pscustomobject]@{path='HKCU\Fixture';name='Fourth';type='REG_DWORD';data=4}}},
            @{label='removed setting';expect='removed HKCU\Fixture\Second (REG_SZ Two)';edit={param($m) $m.modules[0].registryValues=@($m.modules[0].registryValues|Where-Object {$_.name -cne 'Second'})}},
            @{label='moved key and value boundary';expect='added HKCU\Fixture\Split\Name (REG_DWORD 2)';edit={param($m) $m.modules[0].registryValues[2].path='HKCU\Fixture\Split';$m.modules[0].registryValues[2].name='Name'}},
            @{label='lifted protection';expect='HKCU\Fixture\Protected\Third: protected, skipped -> REG_DWORD 2';edit={param($m) $m.protected.registryPathPatterns=@()}},
            @{label='changed service startup';expect='service FixtureSvc: startup=Disabled, state=Stopped -> startup=Manual, state=Stopped';edit={param($m) $m.modules[0].services[0].startup='Manual'}},
            @{label='added service';expect='added service OtherSvc (startup=Disabled, state=Stopped)';edit={param($m) $m.modules[0].services+=[pscustomobject]@{name='OtherSvc';startup='Disabled';targetState='Stopped'}}},
            @{label='reordered settings';expect='different order';edit={param($m) $r=@($m.modules[0].registryValues);$m.modules[0].registryValues=@($r[1],$r[0],$r[2],$r[3])}},
            @{label='unsupported type';expect="Unsupported registry type 'REG_EXPAND_SZ' for HKCU\Fixture\Second";edit={param($m) $m.modules[0].registryValues[1].type='REG_EXPAND_SZ'}},
            @{label='unwritable DWORD data';expect='Cannot write HKCU\Fixture\Second as REG_DWORD';edit={param($m) $m.modules[0].registryValues[1].type='REG_DWORD';$m.modules[0].registryValues[1].data=-1}}
        )) {
            $DataRoot=Reset-BindingFixture 'edit'
            $ConfirmApply=$false
            $PreviewPath=(Invoke-ApplyModule).previewPath
            Edit-BindingManifest $edit.edit
            Test-BindingRefusal ('a stale preview ('+$edit.label+')') $edit.expect
        }

        foreach ($same in @(
            @{label='DWORD data written as text';edit={param($m) $m.modules[0].registryValues[0].data='2'}},
            @{label='another module edited';edit={param($m) $m.modules[1].registryValues[0].data=9}},
            @{label='module description added';edit={param($m) $m.modules[0]|Add-Member -NotePropertyName description -NotePropertyValue 'Same plan' -Force}}
        )) {
            $DataRoot=Reset-BindingFixture 'same'
            $ConfirmApply=$false
            $PreviewPath=(Invoke-ApplyModule).previewPath
            Edit-BindingManifest $same.edit
            $ConfirmApply=$true
            $result=$null
            try { $result=Invoke-ApplyModule } catch { Write-Host "  error: $($_.Exception.Message)" }
            Test-BindingCase ($null -ne $result -and $script:bindingValues.First.kind -ceq 'DWord' -and $script:bindingValues.First.value -eq 2) ('A manifest edit that keeps the plan ('+$same.label+') still applies')
        }
        $DataRoot=Reset-BindingFixture 'drift'
        $ConfirmApply=$false
        $PreviewPath=(Invoke-ApplyModule).previewPath
        $script:bindingValues.First.value=5
        $copy=Join-Path $tempRoot 'binding-copied-manifest.json'
        Copy-Item -LiteralPath $ManifestPath -Destination $copy
        $ManifestPath=$copy
        $ConfirmApply=$true
        $result=$null
        try { $result=Invoke-ApplyModule } catch { Write-Host "  error: $($_.Exception.Message)" }
        $ManifestPath=Join-Path $tempRoot 'binding-manifest.json'
        $saved=if ($result) { Get-Content -LiteralPath $result.backupPath -Raw|ConvertFrom-Json }
        Test-BindingCase ($null -ne $result -and @($saved.registry|Where-Object {$_.name -ceq 'First' -and $_.oldValue -eq 5}).Count -eq 1 -and $script:bindingValues.First.value -eq 2) 'A value changed by another program after the preview is backed up as it is at apply time'

        foreach ($case in @(
            @{type='REG_EXPAND_SZ';data='%TEMP%\fixture';shown="'REG_EXPAND_SZ'"},
            @{type='REG_MULTI_SZ';data=@('One','Two');shown="'REG_MULTI_SZ'"},
            @{type='REG_BINARY';data='AQI=';shown="'REG_BINARY'"},
            @{type='REG_NONE';data='';shown="'REG_NONE'"},
            @{type='REG_DWORD_BIG_ENDIAN';data=2;shown="'REG_DWORD_BIG_ENDIAN'"},
            @{type='REG_LINK';data='HKCU\Fixture';shown="'REG_LINK'"},
            @{type=' REG_DWORD';data=2;shown="' REG_DWORD'"},
            @{type='';data='x';shown="''"},
            @{type=$null;data='x';shown='none'},
            @{missing=$true;data='x';shown='none'},
            @{type=4;data='x';shown='4'},
            @{type=@('REG_SZ');data='x';shown='["REG_SZ"]'}
        )) {
            $label=if ($case.missing) { 'a missing type' } else { 'type '+(ConvertTo-Json -InputObject $case.type -Compress) }
            $expect='Unsupported registry type '+$case.shown
            $change={
                param($m)
                $m.modules[0].registryValues[1].data=$case.data
                if ($case.missing) { $m.modules[0].registryValues[1].PSObject.Properties.Remove('type') } else { $m.modules[0].registryValues[1].type=$case.type }
            }
            $DataRoot=Reset-BindingFixture 'type'
            Edit-BindingManifest $change
            $ConfirmApply=$false
            $message=$null
            try { Invoke-ApplyModule|Out-Null } catch { $message=$_.Exception.Message }
            $state=Get-BindingState
            Test-BindingCase ($null -ne $message -and $message.Contains($expect) -and $message.Contains('HKCU\Fixture\Second') -and $state.previews -eq 0 -and $state.writes -eq 0) ('Preview refuses a mixed manifest with '+$label+' and names the setting')
            $DataRoot=Reset-BindingFixture 'type'
            $PreviewPath=(Invoke-ApplyModule).previewPath
            Edit-BindingManifest $change
            Test-BindingRefusal ('a mixed manifest with '+$label) $expect
        }
        $DataRoot=Reset-BindingFixture 'protected-type'
        Edit-BindingManifest {param($m) $m.modules[0].registryValues[3].type='REG_BINARY'}
        $ConfirmApply=$false
        $message=$null
        try { Invoke-ApplyModule|Out-Null } catch { $message=$_.Exception.Message }
        Test-BindingCase ($null -ne $message -and $message.Contains("Unsupported registry type 'REG_BINARY' for HKCU\Fixture\Protected\Third") -and (Get-BindingState).previews -eq 0) 'Preview refuses an unsupported type even on a protected setting'
        foreach ($case in @(
            @{label='negative DWORD';type='REG_DWORD';data=-1},
            @{label='DWORD above 32 bits';type='REG_DWORD';data=4294967296},
            @{label='DWORD text';type='REG_DWORD';data='many'},
            @{label='negative QWORD';type='REG_QWORD';data=-1}
        )) {
            $change={param($m) $m.modules[0].registryValues[1].type=$case.type;$m.modules[0].registryValues[1].data=$case.data}
            $expect='Cannot write HKCU\Fixture\Second as '+$case.type
            $DataRoot=Reset-BindingFixture 'data'
            Edit-BindingManifest $change
            $ConfirmApply=$false
            $message=$null
            try { Invoke-ApplyModule|Out-Null } catch { $message=$_.Exception.Message }
            Test-BindingCase ($null -ne $message -and $message.Contains($expect) -and (Get-BindingState).previews -eq 0) ('Preview refuses '+$case.label+' data and names the setting')
            $DataRoot=Reset-BindingFixture 'data'
            $PreviewPath=(Invoke-ApplyModule).previewPath
            Edit-BindingManifest $change
            Test-BindingRefusal ('a mixed manifest with '+$case.label+' data') $expect
        }
        $DataRoot=Reset-BindingFixture 'case'
        Edit-BindingManifest {param($m) $m.modules[0].registryValues[0].type='reg_dword';$m.modules[0].registryValues[1].type='Reg_Sz';$m.modules[0].registryValues[2].type='reg_QWORD'}
        $ConfirmApply=$false
        $PreviewPath=(Invoke-ApplyModule).previewPath
        $ConfirmApply=$true
        $result=$null
        try { $result=Invoke-ApplyModule } catch { Write-Host "  error: $($_.Exception.Message)" }
        Test-BindingCase ($null -ne $result -and $script:bindingValues.First.kind -ceq 'DWord' -and $script:bindingValues.Second.kind -ceq 'String' -and $script:bindingValues['Split\Name'].kind -ceq 'QWord' -and [string]$script:bindingValues['Split\Name'].value -ceq '2') 'Supported types in any letter case still apply with their declared kinds'
        $DataRoot=Reset-BindingFixture 'original-kind'
        $script:bindingValues.Second=@{kind='None';value=$null}
        $ConfirmApply=$false
        $PreviewPath=(Invoke-ApplyModule).previewPath
        $ConfirmApply=$true
        $message=$null
        try { Invoke-ApplyModule|Out-Null } catch { $message=$_.Exception.Message }
        $state=Get-BindingState
        Test-BindingCase ($null -ne $message -and $message.Contains('Unsupported registry value kind') -and $state.backups -eq 0 -and $state.writes -eq 0) 'An unsupported original kind refuses apply without leaving a partial backup'
        $DataRoot=Reset-BindingFixture 'legacy'
        $legacyDir=Join-Path $DataRoot 'backups\fixture\20260101-000000000-legacy'
        New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
        Write-JsonFile @{moduleId='fixture';timestamp='2026-01-01T00:00:00Z';applyRequested=$true;registry=@(
            @{path='HKCU\Fixture';name='Second';type='REG_EXPAND_SZ';desiredData='%TEMP%\fixture';pathExists=$true;valueExists=$true;kind='String';oldValue='One'},
            @{path='HKCU\Fixture';name='First';type='REG_MULTI_SZ';desiredData=@('One','Two');pathExists=$true;valueExists=$true;kind='DWord';oldValue=1}
        );services=@()} (Join-Path $legacyDir 'backup.json')
        $script:bindingValues.Second=@{kind='String';value='%TEMP%\fixture'}
        $script:bindingValues.First=@{kind='String';value='One Two'}
        $BackupPath=''
        $PreviewPath=''
        $ConfirmApply=$true
        $restored=Invoke-RollbackModule
        Test-BindingCase ($restored.success -and $restored.restoredRegistry -eq 2 -and $script:bindingValues.Second.kind -ceq 'String' -and $script:bindingValues.Second.value -ceq 'One' -and $script:bindingValues.First.kind -ceq 'DWord' -and $script:bindingValues.First.value -eq 1) 'Rollback still undoes an apply made before unsupported types were refused'
        Assert ($bindingFailures.Count -eq 0) ('Every preview-binding case holds ('+$bindingFailures.Count+' failed)')
    } }
    if ($Scenario -in 'All','Dependents') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        $ManifestPath=Join-Path $tempRoot 'dependents-manifest.json'
        $dependentFailures=New-Object System.Collections.Generic.List[string]
        function Test-DependentCase([bool]$Condition,[string]$Message) {
            if ($Condition) { Write-Host "PASS $Message" } else { Write-Host "FAIL $Message"; $dependentFailures.Add($Message) }
        }
        function Get-FakeDependents {
            param([string]$Name)
            foreach ($other in @($script:fakeServices.Keys | Sort-Object)) {
                if ($script:fakeServices[$other].dependsOn -contains $Name) { Get-FakeDependents $other; $other }
            }
        }
        function Get-Service {
            [CmdletBinding()]param([string]$Name)
            if ($Name.Contains('*') -or -not $script:fakeServices.ContainsKey($Name) -or -not $script:fakeServices[$Name].exists) { return }
            $state=$script:fakeServices[$Name]
            $controller=[pscustomobject]@{Name=$Name;DisplayName=$Name;StartType=$state.startup;Status=$state.status;ServicesDependedOn=@(foreach ($required in $state.dependsOn) {[pscustomobject]@{Name=$required}})}
            $controller|Add-Member ScriptProperty DependentServices {@(Get-FakeDependents $this.Name|Select-Object -Unique|ForEach-Object {$s=$script:fakeServices[$_];[pscustomobject]@{Name=$_;Status=$s.status;StartType=$s.startup}})}
            $controller
        }
        function Get-CimInstance { param($ClassName,$Filter) $null }
        function Set-Service { [CmdletBinding()]param($Name,$StartupType) $script:serviceCalls.Add('set '+$Name+' '+$StartupType);$script:fakeServices[$Name].startup=[string]$StartupType }
        function Stop-Service {
            [CmdletBinding()]param($Name,[switch]$Force)
            foreach ($dependent in @(Get-FakeDependents $Name|Select-Object -Unique)) {
                if ($script:fakeServices[$dependent].status -eq 'Running') {
                    if (-not $Force) { throw "Fixture service $Name has running dependents" }
                    $script:serviceCalls.Add('stop '+$dependent);$script:fakeServices[$dependent].status='Stopped'
                }
            }
            $script:serviceCalls.Add('stop '+$Name);$script:fakeServices[$Name].status='Stopped'
        }
        function Start-Service {
            [CmdletBinding()]param($Name)
            $state=$script:fakeServices[$Name]
            if ($state.startup -eq 'Disabled') { throw "Fixture service $Name is disabled" }
            if ($script:failStart -ceq $Name) { $script:failStart=$null; throw "Fixture start failure for $Name" }
            foreach ($required in $state.dependsOn) { if ($script:fakeServices[$required].status -ne 'Running') { Start-Service -Name $required } }
            $script:serviceCalls.Add('start '+$Name);$state.status='Running'
        }
        function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
        function Invoke-SmokeTest { [pscustomobject]@{pass=$true} }
        function Reset-DependentFixture {
            param([object[]]$Services=@(@{name='Probe';startup='Disabled';targetState='Stopped'}))
            $script:fakeServices=@{
                Probe=@{startup='Automatic';status='Running';exists=$true;dependsOn=@()}
                ProbeDep=@{startup='Manual';status='Running';exists=$true;dependsOn=@('Probe')}
                ProbeDepChild=@{startup='Manual';status='Running';exists=$true;dependsOn=@('ProbeDep')}
                ProbeIdle=@{startup='Manual';status='Stopped';exists=$true;dependsOn=@('Probe')}
            }
            $script:serviceCalls=New-Object System.Collections.Generic.List[string]
            $script:failStart=$null
            Write-JsonFile @{protected=@{services=@();registryPathPatterns=@()};modules=@(@{id='fixture';name='Fixture';registryValues=@();services=$Services})} $ManifestPath
            return (Join-Path $tempRoot ('dependents-'+[guid]::NewGuid().ToString('N')))
        }
        function Get-FakeStatus { (@('Probe','ProbeDep','ProbeDepChild','ProbeIdle')|ForEach-Object {$_+'='+$script:fakeServices[$_].startup+'/'+$script:fakeServices[$_].status}) -join ' ' }
        $restoredState='Probe=Automatic/Running ProbeDep=Manual/Running ProbeDepChild=Manual/Running ProbeIdle=Manual/Stopped'

        $DataRoot=Reset-DependentFixture
        $applied=Invoke-ReviewedApply
        Test-DependentCase ((Get-FakeStatus) -ceq 'Probe=Disabled/Stopped ProbeDep=Manual/Stopped ProbeDepChild=Manual/Stopped ProbeIdle=Manual/Stopped') 'Apply stops the service and the dependents running on it'
        $saved=Get-Content -LiteralPath $applied.backupPath -Raw|ConvertFrom-Json
        $recorded=@($saved.services[0].dependents|ForEach-Object {$_.name+'='+$_.startType+'/'+$_.status}) -join ' '
        Test-DependentCase ($recorded -ceq 'ProbeDepChild=Manual/Running ProbeDep=Manual/Running ProbeIdle=Manual/Stopped') ('The backup records each dependent''s state before the stop ('+$recorded+')')
        $BackupPath=$applied.backupPath
        $ConfirmApply=$false
        $calls=$script:serviceCalls.Count
        $preview=Invoke-RollbackModule
        Test-DependentCase ($preview.success -and $preview.restoredServices -eq 3 -and @($preview.actions|Where-Object {$_.type -eq 'dependent'}).Count -eq 2 -and $script:serviceCalls.Count -eq $calls) 'Undo preview plans the dependent restarts without changing anything'
        $ConfirmApply=$true
        $restored=Invoke-RollbackModule
        Test-DependentCase ($restored.success -and $restored.restoredServices -eq 3 -and (Get-FakeStatus) -ceq $restoredState) ('Undo restarts the dependents that were running and leaves the idle one stopped ('+(Get-FakeStatus)+')')
        $again=Invoke-RollbackModule
        Test-DependentCase ($again.success -and $again.restoredServices -eq 0 -and @($again.alreadyAtOriginal|Where-Object {$_.type -eq 'dependent'}).Count -eq 2) 'A repeated undo reports the dependents as already running'

        $DataRoot=Reset-DependentFixture
        $applied=Invoke-ReviewedApply
        $BackupPath=$applied.backupPath
        $script:failStart='ProbeDep'
        $failed=Invoke-RollbackModule
        $afterFailure=Get-FakeStatus
        $retry=Invoke-RollbackModule
        Test-DependentCase (-not $failed.success -and $failed.partial -and $failed.failures[0].name -ceq 'ProbeDep' -and $failed.failures[0].phase -ceq 'restore' -and @($failed.pending|Where-Object {$_.name -ceq 'ProbeDepChild'}).Count -eq 1 -and $afterFailure -ceq 'Probe=Automatic/Running ProbeDep=Manual/Stopped ProbeDepChild=Manual/Stopped ProbeIdle=Manual/Stopped' -and $retry.success -and (Get-FakeStatus) -ceq $restoredState) 'A failed dependent start stops undo safely and a retry finishes it'

        $DataRoot=Reset-DependentFixture
        $applied=Invoke-ReviewedApply
        $BackupPath=$applied.backupPath
        $script:fakeServices.ProbeDep.startup='Disabled'
        $restored=Invoke-RollbackModule
        $left=@($restored.leftAsChanged|Where-Object {$_.type -eq 'dependent'}|ForEach-Object {$_.name}) -join ','
        Test-DependentCase ($restored.success -and $left -ceq 'ProbeDep,ProbeDepChild' -and (Get-FakeStatus) -ceq 'Probe=Automatic/Running ProbeDep=Disabled/Stopped ProbeDepChild=Manual/Stopped ProbeIdle=Manual/Stopped') ('A dependent another program changed is left alone, with what depends on it ('+$left+')')

        $DataRoot=Reset-DependentFixture
        $applied=Invoke-ReviewedApply
        $BackupPath=$applied.backupPath
        $script:fakeServices.Probe.startup='Manual'
        $calls=$script:serviceCalls.Count
        $restored=Invoke-RollbackModule
        $left=@($restored.leftAsChanged|ForEach-Object {$_.name}) -join ','
        Test-DependentCase ($restored.success -and $left -ceq 'Probe,ProbeDep,ProbeDepChild' -and $script:serviceCalls.Count -eq $calls) ('Dependents stay stopped when their service is left as another program set it ('+$left+')')

        $DataRoot=Reset-DependentFixture @(@{name='Probe';startup='Disabled';targetState='Stopped'},@{name='ProbeDep';startup='Disabled';targetState='Stopped'})
        $applied=Invoke-ReviewedApply
        $BackupPath=$applied.backupPath
        $calls=$script:serviceCalls.Count
        $restored=Invoke-RollbackModule
        $starts=@($script:serviceCalls|Select-Object -Skip $calls|Where-Object {$_ -like 'start *'}) -join ','
        Test-DependentCase ($restored.success -and $starts -ceq 'start Probe,start ProbeDep,start ProbeDepChild' -and (Get-FakeStatus) -ceq $restoredState) ('A dependent the module also lists is restored once by its own entry ('+$starts+')')

        $DataRoot=Reset-DependentFixture
        $applied=Invoke-ReviewedApply
        $BackupPath=$applied.backupPath
        $legacy=Get-Content -LiteralPath $BackupPath -Raw|ConvertFrom-Json
        $legacy.services[0].PSObject.Properties.Remove('dependents')
        Write-JsonFile $legacy $BackupPath
        $restored=Invoke-RollbackModule
        Test-DependentCase ($restored.success -and $restored.restoredServices -eq 1 -and (Get-FakeStatus) -ceq 'Probe=Automatic/Running ProbeDep=Manual/Stopped ProbeDepChild=Manual/Stopped ProbeIdle=Manual/Stopped') 'A backup made before dependents were recorded still undoes its own service'
        Assert ($dependentFailures.Count -eq 0) ('Every dependent-service case holds ('+$dependentFailures.Count+' failed)')
    } }
    if ($Scenario -in 'All','BackupWrite') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        $writeFailures=New-Object System.Collections.Generic.List[string]
        function Test-WriteCase([bool]$Condition,[string]$Message) {
            if ($Condition) { Write-Host "PASS $Message" } else { Write-Host "FAIL $Message"; $writeFailures.Add($Message) }
        }
        $folder=Join-Path $tempRoot 'backup-write'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $existing=Join-Path $folder 'backup.json'
        Write-JsonFile @{moduleId='fixture';generation='old'} $existing
        $oldBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($existing))
        & {
            function Set-Content { param($LiteralPath,$Encoding) $text=@($input) -join "`n"; [IO.File]::WriteAllText($LiteralPath,$text.Substring(0,[int]($text.Length/2))); throw 'Simulated crash mid-write' }
            $message=$null
            try { Write-JsonFile @{moduleId='fixture';generation='new';padding=('x'*200)} $existing } catch { $message=$_.Exception.Message }
            Test-WriteCase ($message -ceq 'Simulated crash mid-write' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($existing)) -ceq $oldBytes -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 1) 'A crash while replacing a backup keeps the old backup intact'
            $fresh=Join-Path $folder 'fresh.json'
            try { Write-JsonFile @{moduleId='fixture';padding=('x'*200)} $fresh } catch {}
            Test-WriteCase (-not (Test-Path -LiteralPath $fresh) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 1) 'A crash while writing a new backup leaves no backup rather than a torn one'
        }
        Write-JsonFile @{moduleId='fixture';generation='new'} $existing
        $saved=Get-Content -LiteralPath $existing -Raw|ConvertFrom-Json
        Test-WriteCase ($saved.generation -ceq 'new' -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 1) 'A completed write replaces the backup and leaves no temporary file'
        $DataRoot=Join-Path $tempRoot 'backup-write-apply'
        function Get-RegistryValueSnapshot { param($Item,[switch]$AllowChangedLayout) [pscustomobject]@{path=$Item.path;name=$Item.name;type=$Item.type;desiredData=$Item.data;pathExists=$true;valueExists=$true;kind='DWord';oldValue=1} }
        function Set-RegistryValueFromManifest { param($Item) $script:writeRegistryWrites++ }
        function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
        function Invoke-SmokeTest { @() }
        $script:writeRegistryWrites=0
        $ConfirmApply=$false
        $PreviewPath=(Invoke-ApplyModule).previewPath
        & {
            function Set-Content { param($LiteralPath,$Encoding) $text=@($input) -join "`n"; [IO.File]::WriteAllText($LiteralPath,$text.Substring(0,[int]($text.Length/2))); throw 'Simulated crash mid-write' }
            $ConfirmApply=$true
            $message=$null
            try { Invoke-ApplyModule|Out-Null } catch { $message=$_.Exception.Message }
            $torn=@(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'backups') -Recurse -Force -File -ErrorAction SilentlyContinue)
            Test-WriteCase ($message -ceq 'Simulated crash mid-write' -and $script:writeRegistryWrites -eq 0 -and $torn.Count -eq 0) ('A crash while saving the backup changes nothing and leaves no torn backup ('+$torn.Count+' files)')
        }
        Assert ($writeFailures.Count -eq 0) ('Every backup-write case holds ('+$writeFailures.Count+' failed)')
    } }
    if ($Scenario -in 'All','Services') { & {
        if ($env:OS -ne 'Windows_NT') { throw 'The real service regression requires Windows.' }
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Output 'SKIP Real service checks need administrator rights to create disposable probe services'; return }
        $suffix=[guid]::NewGuid().ToString('N').Substring(0,12)
        $probe='RooIndustriesProbe'+$suffix
        $dependent='RooIndustriesProbeDep'+$suffix
        $child='RooIndustriesProbeKid'+$suffix
        $exe=Join-Path $tempRoot 'probe-service.exe'
        Add-Type -TypeDefinition 'using System.ServiceProcess; public class RooIndustriesProbeService : ServiceBase { public RooIndustriesProbeService() { ServiceName = "RooIndustriesProbe"; } public static void Main() { ServiceBase.Run(new RooIndustriesProbeService()); } }' -ReferencedAssemblies System.ServiceProcess -OutputAssembly $exe -OutputType ConsoleApplication
        function Get-ProbeState {
            (@($probe,$dependent,$child) | ForEach-Object { $s=Get-Service -Name $_; $s.Refresh(); [string]$s.StartType+'/'+[string]$s.Status }) -join ' '
        }
        try {
            New-Service -Name $probe -BinaryPathName ('"'+$exe+'"') -StartupType Automatic -DisplayName 'Roo Industries test probe' | Out-Null
            New-Service -Name $dependent -BinaryPathName ('"'+$exe+'"') -StartupType Manual -DependsOn $probe -DisplayName 'Roo Industries test probe dependent' | Out-Null
            New-Service -Name $child -BinaryPathName ('"'+$exe+'"') -StartupType Manual -DependsOn $dependent -DisplayName 'Roo Industries test probe second dependent' | Out-Null
            Start-Service -Name $child
            Assert ((Get-ProbeState) -ceq 'Automatic/Running Manual/Running Manual/Running') 'The disposable probe service and its two-level dependents are running'
            $servicesManifest=Join-Path $tempRoot 'services-manifest.json'
            Write-JsonFile @{protected=@{services=@();registryPathPatterns=@()};modules=@(@{id='fixture';name='Fixture';registryValues=@();services=@(@{name=$probe;startup='Disabled';targetState='Stopped'})})} $servicesManifest
            . $HarnessPath -Action ListModules -ManifestPath $servicesManifest -DataRoot (Join-Path $tempRoot 'services') -ModuleId 'fixture' | Out-Null
            function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
            function Invoke-SmokeTest { [pscustomobject]@{pass=$true} }
            $applied=Invoke-ReviewedApply
            Assert ((Get-ProbeState) -ceq 'Disabled/Stopped Manual/Stopped Manual/Stopped') 'Apply stops the real probe service and the dependents running on it'
            $saved=Get-Content -LiteralPath $applied.backupPath -Raw | ConvertFrom-Json
            $recorded=@($saved.services[0].dependents | ForEach-Object { $_.name+'='+$_.startType+'/'+$_.status }) -join ' '
            Assert ($recorded -ceq ($child+'=Manual/Running '+$dependent+'=Manual/Running')) ('The backup records both real dependents as running, in stop order, before the stop ('+$recorded+')')
            $BackupPath=$applied.backupPath
            $ConfirmApply=$false
            $preview=Invoke-RollbackModule
            Assert ($preview.success -and $preview.restoredServices -eq 3 -and (Get-ProbeState) -ceq 'Disabled/Stopped Manual/Stopped Manual/Stopped') 'Undo preview plans the real service and dependent restarts without changing them'
            $ConfirmApply=$true
            $restored=Invoke-RollbackModule
            Write-Output ('REAL_SERVICE_UNDO_JSON '+(ConvertTo-Json -InputObject @{state=(Get-ProbeState);success=$restored.success;restoredServices=$restored.restoredServices;actions=@($restored.actions)} -Depth 5 -Compress))
            Assert ($restored.success -and $restored.restoredServices -eq 3 -and (Get-ProbeState) -ceq 'Automatic/Running Manual/Running Manual/Running') 'Undo restores the real probe service and restarts both dependents'
        } finally {
            foreach ($name in @($child,$dependent,$probe)) {
                if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
                    Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                    & sc.exe delete $name | Out-Null
                }
            }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            for ($wait=0; $wait -lt 40 -and @(Get-Service -Name $probe,$dependent,$child -ErrorAction SilentlyContinue).Count; $wait++) { Start-Sleep -Milliseconds 250 }
        }
        Assert (@(Get-Service -Name $probe,$dependent,$child -ErrorAction SilentlyContinue).Count -eq 0) 'The disposable probe services are removed'
    } }
    if ($Scenario -in 'All','Registry') { & {
        if ($env:OS -ne 'Windows_NT') { throw 'The real-registry regression requires Windows.' }
        $subkey='Software\RooIndustriesFixture-' + [guid]::NewGuid().ToString('N')
        $regPath='HKCU\' + $subkey
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subkey)
        $key.Dispose()
        try {
            @{ protected=@{services=@();registryPathPatterns=@()}; modules=@(@{
                id='fixture';name='Fixture';registryValues=@(@{path=$regPath;name='Value';type='REG_DWORD';data=2});services=@()
            }) } | ConvertTo-Json -Depth 8 | Set-Content $fixtureManifest
            . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
            function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
            function Invoke-SmokeTest { @() }
            if (-not ('RooIndustriesLegacyFixtureRaw' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
public sealed class RooIndustriesLegacyFixtureValue { public uint Kind; public byte[] Data; }
public static class RooIndustriesLegacyFixtureRaw {
    [DllImport("advapi32.dll", EntryPoint="RegQueryValueExW", CharSet=CharSet.Unicode)] static extern int Query(IntPtr key,string name,IntPtr reserved,out uint kind,byte[] data,ref uint length);
    [DllImport("advapi32.dll", EntryPoint="RegSetValueExW", CharSet=CharSet.Unicode)] static extern int Set(IntPtr key,string name,uint reserved,uint kind,byte[] data,uint length);
    public static RooIndustriesLegacyFixtureValue Read(RegistryKey key,string name) {
        uint kind,length=0;int error=Query(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out kind,null,ref length);
        if(error!=0)throw new Win32Exception(error);byte[] data=new byte[length];uint actual=length;
        error=Query(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out kind,data,ref actual);
        if(error!=0)throw new Win32Exception(error);if(actual!=length)throw new InvalidOperationException("Fixture value changed during read");
        return new RooIndustriesLegacyFixtureValue{Kind=kind,Data=data};
    }
    public static void Write(RegistryKey key,string name,uint kind,byte[] data) {
        byte[] backing=new byte[checked(data.Length+4)];
        Buffer.BlockCopy(data,0,backing,0,data.Length);
        backing[data.Length]=0x42;
        int error=Set(key.Handle.DangerousGetHandle(),name,0,kind,backing,(uint)data.Length);
        if(error!=0)throw new Win32Exception(error);
        RooIndustriesLegacyFixtureValue observed=Read(key,name);
        bool exact=observed.Kind==kind&&observed.Data.Length==data.Length;
        for(int index=0;exact&&index<data.Length;index++)exact=observed.Data[index]==data[index];
        if(!exact)throw new InvalidOperationException(String.Format(
            "Fixture producer mismatch: requested kind={0} bytes={1}; observed kind={2} bytes={3}",
            kind,Convert.ToBase64String(data),observed.Kind,Convert.ToBase64String(observed.Data)));
    }
}
'@
            }
            & {
                $ManifestPath=Join-Path $tempRoot 'raw-manifest.json'
                $manifest=Get-Content $fixtureManifest -Raw|ConvertFrom-Json
                $manifest.modules[0].registryValues=@(@{path=$regPath;name='First';type='REG_DWORD';data=2},@{path=$regPath;name='Value';type='REG_DWORD';data=2})
                $manifest.modules[0].services=@(@{name='FixtureSvc';startup='Disabled';targetState='Stopped'})
                Write-JsonFile $manifest $ManifestPath
                function Get-ServiceSnapshot {param($Name) [pscustomobject]@{name=$Name;exists=$true;startType=$script:rawStartup;status='Running'}}
                function Set-ServiceFromManifest {param($Item) $script:rawServiceWrites++;$script:rawStartup=$Item.startup}
                function Restore-ServiceSnapshot {param($Snapshot) $script:rawServiceWrites++;$script:rawStartup=$Snapshot.startType}
                $rows=New-Object System.Collections.Generic.List[object]
                foreach ($case in $unsafeSnapshotCases|Where-Object {$_.label -notlike '*raw*changed' -and -not $_.nativeError -and $coherenceCases -notcontains $_}) {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try {
                        $key.SetValue('First',1,[Microsoft.Win32.RegistryValueKind]::DWord)
                        [RooIndustriesLegacyFixtureRaw]::Write($key,'Value',[uint32][Microsoft.Win32.RegistryValueKind]$case.kind,$case.bytes)
                        $before=[RooIndustriesLegacyFixtureRaw]::Read($key,'Value')
                    } finally {$key.Dispose()}
                    $script:rawServiceWrites=0;$script:rawStartup='Automatic'
                    $ConfirmApply=$false
                    $preview=Invoke-ApplyModule
                    $ConfirmApply=$true
                    $refused=$false;$message=''
                    $PreviewPath=$preview.previewPath;try {Invoke-ApplyModule|Out-Null} catch {$refused=$true;$message=$_.Exception.Message}
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {
                        $after=[RooIndustriesLegacyFixtureRaw]::Read($key,'Value')
                        $rows.Add([pscustomobject]@{label=$case.label;kind=$before.Kind;beforeBytes=[Convert]::ToBase64String($before.Data);afterBytes=[Convert]::ToBase64String($after.Data);afterKind=$after.Kind;first=$key.GetValue('First');refused=$refused;error=$message;previewSafe=($preview.dryRun -and -not $preview.backupPath);serviceWrites=$script:rawServiceWrites})
                    } finally {$key.Dispose()}
                }
                Write-Output ('REAL_RAW_SNAPSHOT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 5 -Compress))
                Assert (@($rows|Where-Object {-not $_.refused -or -not $_.previewSafe -or $_.first -ne 1 -or $_.serviceWrites -ne 0 -or $_.kind -ne $_.afterKind -or $_.beforeBytes -cne $_.afterBytes}).Count -eq 0) 'Unsafe raw registry data refuses confirmed apply without changing any original bytes'
                $rows=New-Object System.Collections.Generic.List[object]
                foreach ($case in $canonicalRawCases) {
                    $script:rawServiceWrites=0;$script:rawStartup='Automatic'
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try {
                        $key.SetValue('First',1,[Microsoft.Win32.RegistryValueKind]::DWord)
                        [RooIndustriesLegacyFixtureRaw]::Write($key,'Value',[uint32][Microsoft.Win32.RegistryValueKind]$case.kind,$case.bytes)
                    } finally {$key.Dispose()}
                    $ConfirmApply=$true
                    $applied=Invoke-ReviewedApply
                    $BackupPath=$applied.backupPath
                    $hash=(Get-FileHash $BackupPath).Hash
                    $result=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {
                        $after=[RooIndustriesLegacyFixtureRaw]::Read($key,'Value')
                        $rows.Add([pscustomobject]@{label=$case.label;success=$result.success;restored=$result.restoredRegistry;restoredServices=$result.restoredServices;serviceWrites=$script:rawServiceWrites;startup=$script:rawStartup;kind=$after.Kind;expectedKind=[int][Microsoft.Win32.RegistryValueKind]$case.kind;beforeBytes=[Convert]::ToBase64String($case.bytes);afterBytes=[Convert]::ToBase64String($after.Data);backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
                    } finally {$key.Dispose()}
                }
                Write-Output ('REAL_CANONICAL_TEXT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 5 -Compress))
                Assert (@($rows|Where-Object {-not $_.success -or $_.restored -ne 2 -or $_.restoredServices -ne 1 -or $_.serviceWrites -ne 2 -or $_.startup -cne 'Automatic' -or $_.kind -ne $_.expectedKind -or $_.beforeBytes -cne $_.afterBytes -or -not $_.backupUnchanged}).Count -eq 0) 'Canonical raw text and Binary including empty payloads restore byte-for-byte'
                $rows=New-Object System.Collections.Generic.List[object]
                foreach ($case in @($unsafeTextSnapshotCases)+@($numericLayoutCases)) {
                    $script:rawServiceWrites=0;$script:rawStartup='Disabled'
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try {
                        $key.SetValue('First',2,[Microsoft.Win32.RegistryValueKind]::DWord)
                        [RooIndustriesLegacyFixtureRaw]::Write($key,'Value',[uint32][Microsoft.Win32.RegistryValueKind]$case.kind,$case.bytes)
                    } finally {$key.Dispose()}
                    $BackupPath=Join-Path $tempRoot 'raw-current-real.json'
                    Write-JsonFile @{moduleId='fixture';registry=@(
                        @{path=$regPath;name='First';type='REG_DWORD';desiredData=2;valueExists=$true;kind='DWord';oldValue=1},
                        @{path=$regPath;name='Value';type='REG_SZ';desiredData='A';valueExists=$true;kind='String';oldValue='Original'}
                    );services=@(@{name='FixtureSvc';exists=$true;startType='Automatic';status='Running';appliedStartup='Disabled'})} $BackupPath
                    $hash=(Get-FileHash $BackupPath).Hash
                    $ConfirmApply=$false
                    $preview=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {$previewSafe=$preview.success -and $preview.restoredRegistry -eq 1 -and $preview.restoredServices -eq 1 -and $preview.leftAsChanged.Count -eq 1 -and $key.GetValue('First') -eq 2 -and $script:rawServiceWrites -eq 0} finally {$key.Dispose()}
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    $retry=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {
                        $after=[RooIndustriesLegacyFixtureRaw]::Read($key,'Value')
                        $rows.Add([pscustomobject]@{label=$case.label;previewSafe=$previewSafe;success=$result.success;partial=$result.partial;restored=$result.restoredRegistry;restoredServices=$result.restoredServices;left=@($result.leftAsChanged);retryLeft=@($retry.leftAsChanged);retryRestored=$retry.restoredRegistry;retryRestoredServices=$retry.restoredServices;retryAlreadyAtOriginal=@($retry.alreadyAtOriginal);first=$key.GetValue('First');serviceWrites=$script:rawServiceWrites;startup=$script:rawStartup;kind=$after.Kind;expectedKind=[int][Microsoft.Win32.RegistryValueKind]$case.kind;beforeBytes=[Convert]::ToBase64String($case.bytes);afterBytes=[Convert]::ToBase64String($after.Data);backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
                    } finally {$key.Dispose()}
                }
                Write-Output ('REAL_RAW_CURRENT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 7 -Compress))
                Assert (@($rows|Where-Object {-not $_.previewSafe -or -not $_.success -or $_.partial -or $_.restored -ne 1 -or $_.restoredServices -ne 1 -or $_.left.Count -ne 1 -or $_.left[0].name -cne 'Value' -or $_.retryLeft.Count -ne 1 -or $_.retryRestored -ne 0 -or $_.retryRestoredServices -ne 0 -or @($_.retryAlreadyAtOriginal|Where-Object {$_.name -ceq 'Value'}).Count -ne 0 -or $_.first -ne 1 -or $_.serviceWrites -ne 1 -or $_.startup -cne 'Automatic' -or $_.kind -ne $_.expectedKind -or $_.beforeBytes -cne $_.afterBytes -or -not $_.backupUnchanged}).Count -eq 0) 'Later noncanonical raw text and numeric layouts stay intact while independent registry and fake service undo completes'
                & {
                    $sourceRawReader=${function:Get-RegistryRawValue}
                    $script:lateRealReads=0
                    function Get-RegistryRawValue {
                        param($Key,$Name)
                        if ($Name -ceq 'Value') {
                            $script:lateRealReads++
                            if ($script:lateRealReads -eq 2) {
                                $writer=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                                try {[RooIndustriesLegacyFixtureRaw]::Write($writer,'Value',1,[byte[]]@(65,0))} finally {$writer.Dispose()}
                            }
                        }
                        & $sourceRawReader $Key $Name
                    }
                    $script:rawServiceWrites=0;$script:rawStartup='Disabled'
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try {$key.SetValue('First',2,[Microsoft.Win32.RegistryValueKind]::DWord);$key.SetValue('Value','A',[Microsoft.Win32.RegistryValueKind]::String)} finally {$key.Dispose()}
                    $hash=(Get-FileHash $BackupPath).Hash
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    $retry=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {
                        $after=[RooIndustriesLegacyFixtureRaw]::Read($key,'Value')
                        Assert ($result.success -and $result.restoredRegistry -eq 1 -and $result.restoredServices -eq 1 -and $result.leftAsChanged.Count -eq 1 -and $result.actions[1].status -ceq 'leftAsChanged' -and $retry.success -and $retry.leftAsChanged.Count -eq 1 -and $retry.restoredRegistry -eq 0 -and $retry.restoredServices -eq 0 -and @($retry.alreadyAtOriginal|Where-Object {$_.name -ceq 'Value'}).Count -eq 0 -and $key.GetValue('First') -eq 1 -and $script:rawServiceWrites -eq 1 -and $after.Kind -eq 1 -and [Convert]::ToBase64String($after.Data) -ceq 'QQA=' -and (Get-FileHash $BackupPath).Hash -ceq $hash) 'A real raw edit between preflight and runtime is preserved while independent undo continues'
                    } finally {$key.Dispose()}
                }
            }
            & {
                $BackupPath=Join-Path $tempRoot 'legacy-default-real.json'
                $rows=New-Object System.Collections.Generic.List[object]
                foreach ($name in $legacyDefaultNames) {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try {$key.SetValue('',2,[Microsoft.Win32.RegistryValueKind]::DWord);$key.SetValue('(default)',2,[Microsoft.Win32.RegistryValueKind]::DWord)} finally {$key.Dispose()}
                    Write-JsonFile @{moduleId='fixture';registry=@(@{path=$regPath;name=$name;type='REG_DWORD';desiredData=2;valueExists=$false});services=@()} $BackupPath
                    $hash=(Get-FileHash $BackupPath).Hash
                    $ConfirmApply=$false
                    $preview=Invoke-RollbackModule
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {$rows.Add([pscustomobject]@{name=$name;previewCount=$preview.restoredRegistry;reason=$result.leftAsChanged[0].reason;restored=$result.restoredRegistry;default=$key.GetValue('');literal=$key.GetValue('(default)');backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})} finally {$key.Dispose()}
                }
                Write-Output ('REAL_LEGACY_DEFAULT_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 4 -Compress))
                Assert (@($rows|Where-Object {$_.previewCount -ne 0 -or $_.restored -ne 0 -or $_.default -ne 2 -or $_.literal -ne 2 -or $_.reason -notlike '*original existence evidence*' -or -not $_.backupUnchanged}).Count -eq 0) 'Kindless legacy default aliases preserve actual default and literal values with missing-existence notices'
            }
            & {
                $BackupPath=Join-Path $tempRoot 'malformed-original.json'
                $rows=New-Object System.Collections.Generic.List[object]
                function Get-ServiceSnapshot { param($Name) [pscustomobject]@{name=$Name;exists=$true;startType='Disabled';status='Running'} }
                function Restore-ServiceSnapshot { param($Snapshot) $script:malformedServiceWrites++ }
                foreach ($case in $invalidOriginalCases) {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try { foreach ($name in 'First','Second') { $key.SetValue($name,2,[Microsoft.Win32.RegistryValueKind]::DWord) } } finally { $key.Dispose() }
                    $firstEntry=@{path=$regPath;name='First';type='REG_DWORD';desiredData=2;valueExists=$true;kind='DWord';oldValue=1}
                    $badEntry=@{path=$regPath;name='Second';type='REG_DWORD';desiredData=2;valueExists=$true}+$case.entry
                    Write-JsonFile @{moduleId='fixture';registry=@($firstEntry,$badEntry);services=@(@{name='FixtureSvc';exists=$true;startType='Automatic';status='Running';appliedStartup='Disabled'})} $BackupPath
                    $hash=(Get-FileHash $BackupPath).Hash
                    $script:malformedServiceWrites=0
                    $ConfirmApply=$false
                    $preview=Invoke-RollbackModule
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try {
                        $rows.Add([pscustomobject]@{label=$case.label;previewSafe=(-not $preview.success -and $preview.restoredRegistry -eq 0 -and $preview.restoredServices -eq 0);success=$result.success;phase=$result.failures[0].phase;firstKind=[string]$key.GetValueKind('First');first=$key.GetValue('First');secondKind=[string]$key.GetValueKind('Second');second=$key.GetValue('Second');serviceWrites=$script:malformedServiceWrites;backupUnchanged=((Get-FileHash $BackupPath).Hash -ceq $hash)})
                    } finally { $key.Dispose() }
                }
                Write-Output ('REAL_ORIGINAL_EVIDENCE_FIXTURE_JSON '+(ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 6 -Compress))
                Assert (@($rows|Where-Object {-not $_.previewSafe -or $_.success -or $_.phase -cne 'preflight' -or $_.firstKind -cne 'DWord' -or $_.first -ne 2 -or $_.secondKind -cne 'DWord' -or $_.second -ne 2 -or $_.serviceWrites -ne 0 -or -not $_.backupUnchanged}).Count -eq 0) 'Malformed originals leave real registry values and the independent fake service untouched'
            }
            $cases=@(
                @{label='String numeric';kind='String';data='7';expected='7'},
                @{label='DWORD max';kind='DWord';data=[int]-1;expected=[uint32]::MaxValue},
                @{label='DWORD high bit';kind='DWord';data=[int]::MinValue;expected=[uint32]2147483648},
                @{label='DWORD signed max';kind='DWord';data=[int]::MaxValue;expected=[uint32]2147483647},
                @{label='String empty';kind='String';data='';expected=''},
                @{label='ExpandString raw';kind='ExpandString';data='%PATH%\fixture';expected='%PATH%\fixture'},
                @{label='MultiString';kind='MultiString';data=[string[]]@('One','two');expected=@('One','two')},
                @{label='MultiString singleton';kind='MultiString';data=[string[]]@('One');expected=@('One')},
                @{label='MultiString empty';kind='MultiString';data=[string[]]@();expected=@()},
                @{label='QWORD max';kind='QWord';data=[long]-1;expected='18446744073709551615'},
                @{label='QWORD high bit';kind='QWord';data=[long]::MinValue;expected='9223372036854775808'},
                @{label='QWORD precision';kind='QWord';data=[long]9007199254740993;expected='9007199254740993'},
                @{label='Binary';kind='Binary';data=[byte[]]@(0,127,128,255);expected='AH+A/w=='},
                @{label='Binary empty';kind='Binary';data=[byte[]]@();expected=''}
            )
            foreach ($case in $cases) {
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('Value',$case.data,[Microsoft.Win32.RegistryValueKind]$case.kind) } finally { $key.Dispose() }
                $ConfirmApply=$true
                $applied=Invoke-ReviewedApply
                $BackupPath=$applied.backupPath
                $saved=Get-Content $BackupPath -Raw | ConvertFrom-Json
                if ($case.label -eq 'String numeric') { Write-Output ('BACKUP_FIXTURE_JSON ' + (ConvertTo-Json -InputObject ([IO.File]::ReadAllText($BackupPath)) -Compress)) }
                $restored=Invoke-RollbackModule
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try {
                    $kind=[string]$key.GetValueKind('Value')
                    $raw=$key.GetValue('Value',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $wanted=$case.data | ConvertTo-Json -Compress
                    $actual=$raw | ConvertTo-Json -Compress
                    Assert ($kind -ceq $case.kind -and $actual -ceq $wanted) ($case.label + ' restores the exact kind and raw data through backup.json')
                } finally { $key.Dispose() }
                Assert ($saved.registry[0].kind -ceq $case.kind -and (ConvertTo-Json -InputObject $saved.registry[0].oldValue -Compress) -ceq (ConvertTo-Json -InputObject $case.expected -Compress)) ($case.label + ' has a lossless JSON encoding')
                Assert ($restored.restoredRegistry -eq 1 -and @($restored.leftAsChanged).Count -eq 0) ($case.label + ' is reported as restored')
            }
            foreach ($drift in 'data','kind','deleted-value','deleted-key','missing-before','new-key','new-changed','case') {
                $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subkey)
                try {
                    $key.SetValue('Value',[int]1,[Microsoft.Win32.RegistryValueKind]::DWord)
                    if ($drift -in 'missing-before','new-changed') { $key.DeleteValue('Value') }
                } finally { $key.Dispose() }
                if ($drift -eq 'new-key') { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subkey) }
                $ConfirmApply=$true
                $applied=Invoke-ReviewedApply
                $BackupPath=$applied.backupPath
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try {
                    switch ($drift) {
                        'data' { $key.SetValue('Value',3,[Microsoft.Win32.RegistryValueKind]::DWord) }
                        'kind' { $key.SetValue('Value','2',[Microsoft.Win32.RegistryValueKind]::String) }
                        'deleted-value' { $key.DeleteValue('Value') }
                        'new-changed' { $key.SetValue('Value',3,[Microsoft.Win32.RegistryValueKind]::DWord) }
                        'case' { $key.SetValue('Value','TWO',[Microsoft.Win32.RegistryValueKind]::String) }
                    }
                } finally { $key.Dispose() }
                if ($drift -eq 'deleted-key') { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subkey) }
                $ConfirmApply=$false
                $preview=Invoke-RollbackModule
                $expectedLeft=if ($drift -in 'missing-before','new-key') { 0 } else { 1 }
                Assert (@($preview.leftAsChanged).Count -eq $expectedLeft) ($drift + ' preview reports ownership accurately')
                $ConfirmApply=$true
                $restored=Invoke-RollbackModule
                Assert (@($restored.leftAsChanged).Count -eq $expectedLeft -and $restored.restoredRegistry -eq (1-$expectedLeft)) ($drift + ' rollback reports what it restored or left')
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try {
                    if ($drift -eq 'deleted-key') { Assert ($null -eq $key) 'Rollback keeps a subsequently deleted key absent' }
                    elseif ($drift -in 'deleted-value','missing-before','new-key') { Assert ('Value' -notin $key.GetValueNames()) ($drift + ' stays absent') }
                    else {
                        $actual=$key.GetValue('Value',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        $wanted=if ($drift -in 'data','new-changed') { 3 } elseif ($drift -eq 'case') { 'TWO' } else { '2' }
                        Assert ($actual -ceq $wanted) ($drift + ' keeps the later value')
                    }
                } finally { if ($key) { $key.Dispose() } }
            }
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
            try { $key.SetValue('Value',1,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
            $applied=Invoke-ReviewedApply
            $BackupPath=$applied.backupPath
            $legacy=Get-Content $BackupPath -Raw | ConvertFrom-Json
            $legacy.registry[0].PSObject.Properties.Remove('kind')
            $originalBackup=[IO.File]::ReadAllText($BackupPath)
            $legacy.PSObject.Properties.Remove('applyRequested')
            Write-JsonFile $legacy $BackupPath
            $BackupPath=''
            $restored=Invoke-RollbackModule
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
            try { Assert ($key.GetValue('Value') -eq 2 -and $restored.backupPath -eq $applied.backupPath -and $restored.restoredRegistry -eq 0 -and $restored.leftAsChanged[0].reason -like '*kind*evidence*') 'Legacy latest selection preserves an existing value without applied-kind evidence' } finally { $key.Dispose() }
            & {
                $BackupPath=Join-Path $tempRoot 'legacy-qword-real.json'
                foreach ($case in $legacyQwordCases) {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try { $key.SetValue('Value',[long]2,[Microsoft.Win32.RegistryValueKind]::QWord) } finally { $key.Dispose() }
                    $backup=@{moduleId='fixture';timestamp=(Get-Date).ToString('o');registry=@(@{path=$regPath;name='Value';type='REG_QWORD';desiredData=2;oldValue=$case.data;valueExists=$true});services=@()}
                    Write-JsonFile $backup $BackupPath
                    Restore-RegistryValue ([pscustomobject]$backup.registry[0])
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try { Assert ($key.GetValueKind('Value') -eq [Microsoft.Win32.RegistryValueKind]::QWord -and $key.GetValue('Value') -eq $case.raw) ('Legacy QWORD '+$case.label+' helper preserves its bits in the real registry') } finally { $key.Dispose() }
                }
                foreach ($case in $legacyDwordCases) {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try { $key.SetValue('Value',2,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
                    $snapshot=[pscustomobject]@{path=$regPath;name='Value';type='REG_DWORD';desiredData=2;oldValue=$case.data;valueExists=$true}
                    Restore-RegistryValue $snapshot
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try { Assert ($key.GetValueKind('Value') -eq [Microsoft.Win32.RegistryValueKind]::DWord -and $key.GetValue('Value') -eq $case.raw) ('Legacy DWORD '+$case.label+' helper preserves its bits in the real registry') } finally { $key.Dispose() }
                }
            }
            [IO.File]::WriteAllText($applied.backupPath,$originalBackup)
            & {
                $BackupPath=Join-Path $tempRoot 'real-recovery.json'
                foreach ($history in 'String/ExpandString','DWord/QWord') {
                    $legacyValue=if ($history -eq 'String/ExpandString') { '0' } else { 0 }
                    $entry=@{path=$regPath;name='Value';type='REG_DWORD';desiredData=1;oldValue=$legacyValue;valueExists=$true}
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try {
                        if ($history -eq 'String/ExpandString') { $key.SetValue('Value','1',[Microsoft.Win32.RegistryValueKind]::String) }
                        else { $key.SetValue('Value',1,[Microsoft.Win32.RegistryValueKind]::DWord) }
                    } finally { $key.Dispose() }
                    Write-JsonFile @{moduleId='fixture';registry=@($entry);services=@()} $BackupPath
                    $ConfirmApply=$false
                    $preview=Invoke-RollbackModule
                    $ConfirmApply=$true
                    $result=Invoke-RollbackModule
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try { Assert ($preview.restoredRegistry -eq 0 -and $result.restoredRegistry -eq 0 -and $result.leftAsChanged[0].reason -like '*kind*evidence*' -and $key.GetValue('Value') -eq 1) ($history+' indistinguishable legacy histories are preserved in the real registry') } finally { $key.Dispose() }
                }
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('Value',2,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
                Write-JsonFile @{moduleId='fixture';registry=@(@{path=$regPath;name='Value';type='REG_DWORD';desiredData=2;valueExists=$false});services=@()} $BackupPath
                $result=Invoke-RollbackModule
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try { Assert ($result.restoredRegistry -eq 1 -and 'Value' -notin $key.GetValueNames()) 'A legacy absent-before value uses the explicit old-create kind and is removed' } finally { $key.Dispose() }
                $entries=@(
                    @{path=$regPath;name='First';type='REG_DWORD';desiredData=2;kind='DWord';oldValue=1;valueExists=$true},
                    @{path=$regPath;name='Second';type='REG_DWORD';desiredData=2;kind='Binary';oldValue='%%%';valueExists=$true}
                )
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { foreach ($name in 'First','Second') { $key.SetValue($name,2,[Microsoft.Win32.RegistryValueKind]::DWord) } } finally { $key.Dispose() }
                Write-JsonFile @{moduleId='fixture';registry=$entries;services=@()} $BackupPath
                $result=Invoke-RollbackModule
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try { Assert (-not $result.success -and $result.failures[0].phase -ceq 'preflight' -and $key.GetValue('First') -eq 2 -and $key.GetValue('Second') -eq 2) 'Real-registry preflight failure leaves every value untouched' } finally { $key.Dispose() }
                $cliFailed=$false
                try { & $HarnessPath -Action RollbackModule -ModuleId fixture -ManifestPath $fixtureManifest -DataRoot $tempRoot -BackupPath $BackupPath -ConfirmApply | Out-Null } catch { $cliFailed=$_.Exception.Data['RollbackResult'].success -eq $false }
                Assert $cliFailed 'The RollbackModule CLI exposes the failed result and raises an error'
                $entries[1].kind='DWord';$entries[1].oldValue=0
                Write-JsonFile @{moduleId='fixture';registry=$entries;services=@()} $BackupPath
                $hash=(Get-FileHash $BackupPath).Hash
                & {
                    $realWriter=${function:Set-RegistrySnapshotData}
                    function Set-RegistrySnapshotData { param($Key,$Name,$Snapshot) if ($Name -cne 'Second') { & $realWriter $Key $Name $Snapshot } }
                    $result=Invoke-RollbackModule
                    Assert (-not $result.success -and $result.partial -and $result.restoredRegistry -eq 1 -and $result.failures[0].name -ceq 'Second' -and (Get-FileHash $BackupPath).Hash -ceq $hash) 'A real readback failure reports the verified first restore and retains its backup'
                }
                $retry=Invoke-RollbackModule
                Assert ($retry.success -and $retry.restoredRegistry -eq 1 -and $retry.alreadyAtOriginal[0].name -ceq 'First') 'Real-registry retry distinguishes an already-original value from later drift'
            }
            $BackupPath=$applied.backupPath
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
            try { $key.SetValue('Value',2,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
            & $HarnessPath -Action RollbackModule -ModuleId fixture -ManifestPath $fixtureManifest -DataRoot $tempRoot -BackupPath $BackupPath | Out-Null
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
            try { Assert ($key.GetValue('Value') -eq 2) 'The RollbackModule CLI defaults to preview' } finally { $key.Dispose() }
            & $HarnessPath -Action RollbackModule -ModuleId fixture -ManifestPath $fixtureManifest -DataRoot $tempRoot -BackupPath $BackupPath -ConfirmApply | Out-Null
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
            try { Assert ($key.GetValue('Value') -eq 1) 'The RollbackModule CLI restores the explicit backup only when confirmed' } finally { $key.Dispose() }
            & {
                $cliRoot=Join-Path $tempRoot 'cli-binding'
                $cliManifest=Join-Path $tempRoot 'cli-binding-manifest.json'
                $cliArgs=@{Action='ApplyModule';ModuleId='fixture';ManifestPath=$cliManifest;DataRoot=$cliRoot}
                Write-JsonFile @{protected=@{services=@();registryPathPatterns=@()};modules=@(@{id='fixture';name='Fixture';registryValues=@(
                    @{path=$regPath;name='First';type='REG_DWORD';data=2},
                    @{path=$regPath;name='Value';type='REG_SZ';data='Two'}
                );services=@()})} $cliManifest
                function Get-CliState {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                    try { [pscustomobject]@{first=$key.GetValue('First');firstKind=[string]$key.GetValueKind('First');value=$key.GetValue('Value');valueKind=[string]$key.GetValueKind('Value');backups=@(Get-ChildItem -LiteralPath (Join-Path $cliRoot 'backups\fixture') -Directory -ErrorAction SilentlyContinue).Count} } finally { $key.Dispose() }
                }
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('First',1,[Microsoft.Win32.RegistryValueKind]::DWord);$key.SetValue('Value','Original',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                $refused=$null
                try { & $HarnessPath @cliArgs -ConfirmApply | Out-Null } catch { $refused=$_.Exception.Message }
                $state=Get-CliState
                Assert ($refused -like '*-PreviewPath*' -and $state.first -eq 1 -and $state.value -ceq 'Original' -and $state.backups -eq 0) 'The ApplyModule CLI refuses a confirmed apply without a reviewed preview'
                $preview=& $HarnessPath @cliArgs
                Assert ($preview.dryRun -and (Test-Path -LiteralPath $preview.previewPath) -and (Get-CliState).first -eq 1) 'The ApplyModule CLI preview saves the plan it shows'
                $manifest=Get-Content -LiteralPath $cliManifest -Raw | ConvertFrom-Json
                $manifest.modules[0].registryValues[1].data='Three'
                Write-JsonFile $manifest $cliManifest
                $refused=$null
                try { & $HarnessPath @cliArgs -ConfirmApply -PreviewPath $preview.previewPath | Out-Null } catch { $refused=$_.Exception.Message }
                Write-Output ('CLI_STALE_PREVIEW_REFUSAL '+(ConvertTo-Json -InputObject $refused -Compress))
                $state=Get-CliState
                Assert ($refused -like ('*'+$regPath+'\Value: REG_SZ Two -> REG_SZ Three*') -and $state.first -eq 1 -and $state.value -ceq 'Original' -and $state.backups -eq 0) 'The ApplyModule CLI refuses and names a manifest edit made after the preview'
                $manifest.modules[0].registryValues[1].data='Two'
                Write-JsonFile $manifest $cliManifest
                $applied=& $HarnessPath @cliArgs -ConfirmApply -PreviewPath $preview.previewPath
                $state=Get-CliState
                Assert ($state.first -eq 2 -and $state.firstKind -ceq 'DWord' -and $state.value -ceq 'Two' -and $state.valueKind -ceq 'String' -and $applied.previewHash -ceq $preview.previewHash -and $state.backups -eq 1) 'The ApplyModule CLI applies the exact reviewed plan'
                & $HarnessPath -Action RollbackModule -ModuleId fixture -ManifestPath $cliManifest -DataRoot $cliRoot -BackupPath $applied.backupPath -ConfirmApply | Out-Null
                $state=Get-CliState
                Assert ($state.first -eq 1 -and $state.value -ceq 'Original' -and $state.valueKind -ceq 'String') 'The ApplyModule CLI apply undoes to the exact originals'
                $manifest.modules[0].registryValues[1].type='REG_EXPAND_SZ'
                $manifest.modules[0].registryValues[1].data='%TEMP%\fixture'
                Write-JsonFile $manifest $cliManifest
                $previewRefused=$null
                try { & $HarnessPath @cliArgs | Out-Null } catch { $previewRefused=$_.Exception.Message }
                $refused=$null
                try { & $HarnessPath @cliArgs -ConfirmApply -PreviewPath $preview.previewPath | Out-Null } catch { $refused=$_.Exception.Message }
                Write-Output ('CLI_UNSUPPORTED_TYPE_REFUSAL '+(ConvertTo-Json -InputObject $refused -Compress))
                $state=Get-CliState
                $expected="*Unsupported registry type 'REG_EXPAND_SZ' for $regPath\Value*"
                Assert ($previewRefused -like $expected -and $refused -like $expected -and $state.first -eq 1 -and $state.value -ceq 'Original' -and $state.valueKind -ceq 'String' -and $state.backups -eq 1) 'The ApplyModule CLI refuses a mixed manifest with an unsupported type before any write'
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.DeleteValue('First',$false);$key.SetValue('Value',1,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
            }
            & {
                function Set-RegistrySnapshotData { param($Key,$Name,$Snapshot) }
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('Value',2,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
                $refused=$false
                try { Restore-RegistryValue $legacy.registry[0] } catch { $refused=$_.Exception.Message -like '*restore verification failed*' }
                Assert $refused 'Restore refuses to report success when registry readback differs'
            }
            foreach ($nameMode in 'empty','reserved','null','missing','literal-default') {
                $name=if ($nameMode -eq 'reserved') { 'PSPath' } elseif ($nameMode -eq 'literal-default') { '(default)' } else { '' }
                $manifest=Get-Content $fixtureManifest -Raw | ConvertFrom-Json
                $manifest.modules[0].registryValues[0] | Add-Member -NotePropertyName name -NotePropertyValue $name -Force
                if ($nameMode -eq 'null') { $manifest.modules[0].registryValues[0].name=$null }
                if ($nameMode -eq 'missing') { $manifest.modules[0].registryValues[0].PSObject.Properties.Remove('name') }
                $manifest.modules[0].registryValues[0].type='REG_SZ'
                $manifest.modules[0].registryValues[0].data='Two'
                Write-JsonFile $manifest $fixtureManifest
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try {
                    if ($nameMode -eq 'literal-default') { $key.SetValue('','Default sibling',[Microsoft.Win32.RegistryValueKind]::String) }
                    $key.SetValue($name,'Original',[Microsoft.Win32.RegistryValueKind]::String)
                } finally { $key.Dispose() }
                $applied=Invoke-ReviewedApply
                $BackupPath=$applied.backupPath
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue($name,'two',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                $restored=Invoke-RollbackModule
                Assert (@($restored.leftAsChanged).Count -eq 1) ('String comparison is case sensitive for ' + $nameMode + ' value names')
                $later='Tw'+[char]0xAD+'o'
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue($name,$later,[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                $restored=Invoke-RollbackModule
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try { Assert (@($restored.leftAsChanged).Count -eq 1 -and [string]::Equals($key.GetValue($name),$later,[StringComparison]::Ordinal)) ('Unicode soft-hyphen drift is preserved for ' + $nameMode + ' value names') } finally { $key.Dispose() }
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue($name,'Two',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                Invoke-RollbackModule | Out-Null
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try {
                    Assert ($key.GetValue($name) -ceq 'Original') ('The original is restored for ' + $nameMode + ' value names')
                    if ($nameMode -eq 'literal-default') { Assert ($key.GetValue('') -ceq 'Default sibling') 'A new-format literal (default) value never aliases the actual default value' }
                } finally { $key.Dispose() }
            }
            & {
                function Set-RegistrySnapshotData { param($Key,$Name,$Snapshot) }
                foreach ($kind in 'String','ExpandString','MultiString') {
                    $later='Tw'+[char]0xAD+'o'
                    $data=if ($kind -eq 'MultiString') { ,([string[]]@($later)) } else { $later }
                    $original=if ($kind -eq 'MultiString') { ,([string[]]@('Two')) } else { 'Two' }
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                    try { $key.SetValue('Value',$data,[Microsoft.Win32.RegistryValueKind]$kind) } finally { $key.Dispose() }
                    $snapshot=[pscustomobject]@{path=$regPath;name='Value';valueExists=$true;kind=$kind;oldValue=$original}
                    $refused=$false
                    try { Restore-RegistryValue $snapshot } catch { $refused=$_.Exception.Message -like '*restore verification failed*' }
                    Assert $refused ($kind + ' readback rejects an ignorable Unicode character difference')
                }
            }
            $manifest.modules[0].registryValues[0] | Add-Member -NotePropertyName name -NotePropertyValue 'Value' -Force
            $manifest.modules[0].registryValues[0].path=$regPath.Replace('\','/')
            $manifest.protected.registryPathPatterns=@([regex]::Escape($regPath+'\Value'))
            Write-JsonFile $manifest $fixtureManifest
            $applied=Invoke-ReviewedApply
            $saved=Get-Content $applied.backupPath -Raw | ConvertFrom-Json
            Assert (@($saved.registry).Count -eq 0) 'Protected settings are excluded from the rollback backup'
            & {
                $manifest.protected.services=@('FixtureProtectedSvc')
                Write-JsonFile $manifest $fixtureManifest
                $script:protectedRestores=0
                function Get-ServiceSnapshot { param($Name) [pscustomobject]@{name=$Name;exists=$true;startType='Disabled'} }
                function Restore-ServiceSnapshot { param($Snapshot) $script:protectedRestores++ }
                $legacy=[pscustomobject]@{moduleId='fixture';timestamp=(Get-Date).ToString('o');registry=@(@{path=$regPath.Replace('\','/');name='Value';type='REG_SZ';desiredData='Two';oldValue='Original';valueExists=$true});services=@(@{name='FixtureProtectedSvc';exists=$true;startType='Automatic';appliedStartup='Disabled'})}
                $BackupPath=$applied.backupPath
                Write-JsonFile $legacy $BackupPath
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('Value','Two',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                $ConfirmApply=$false
                $preview=Invoke-RollbackModule
                Assert ($preview.restoredRegistry -eq 0 -and $preview.restoredServices -eq 0 -and @($preview.leftAsChanged).Count -eq 2) 'Legacy protected targets are left in the rollback preview'
                $ConfirmApply=$true
                $restored=Invoke-RollbackModule
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try { Assert ($key.GetValue('Value') -ceq 'Two' -and $script:protectedRestores -eq 0 -and @($restored.leftAsChanged).Count -eq 2) 'Legacy backups never restore protected registry values or services' } finally { $key.Dispose() }
            }
            $manifest.protected.services=@()
            $manifest.protected.registryPathPatterns=@()
            $manifest.modules[0].registryValues[0].path=$regPath
            Write-JsonFile $manifest $fixtureManifest
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
            try { $key.SetValue('Value',[byte[]]@(1,2),[Microsoft.Win32.RegistryValueKind]::None) } finally { $key.Dispose() }
            $refused=$false
            try { Invoke-ReviewedApply | Out-Null } catch { $refused=$_.Exception.Message -like '*Unsupported registry value kind*' }
            Assert $refused 'An unsupported original registry kind refuses apply before changing it'
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
            try { $key.SetValue('Value','Original',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
            $applied=Invoke-ReviewedApply
            $BackupPath=$applied.backupPath
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
            try { $key.SetValue('Value',[byte[]]@(1,2),[Microsoft.Win32.RegistryValueKind]::None) } finally { $key.Dispose() }
            $restored=Invoke-RollbackModule
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
            try { Assert (@($restored.leftAsChanged).Count -eq 1 -and $key.GetValueKind('Value') -eq [Microsoft.Win32.RegistryValueKind]::None) 'A later unsupported registry kind is left untouched' } finally { $key.Dispose() }
            $elsewhere=Join-Path $tempRoot 'elsewhere'
            & $HarnessPath -Action RollbackModule -ModuleId fixture -ManifestPath $fixtureManifest -DataRoot $elsewhere -BackupPath $BackupPath | Out-Null
            Assert (Test-Path $BackupPath) 'An explicit backup works independently of the default backup directory'
            & {
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('Value','Original',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                function Set-RegistryValueFromManifest { param($Item) throw 'Fixture apply failure before write' }
                $failed=$false
                try { Invoke-ReviewedApply | Out-Null } catch { $failed=$_.Exception.Message -eq 'Fixture apply failure before write' }
                Assert $failed 'An apply failure leaves its prior backup available'
                $BackupPath=''
                $restored=Invoke-RollbackModule
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
                try { Assert ($key.GetValue('Value') -ceq 'Original' -and $restored.restoredRegistry -eq 0) 'Rollback of a failed apply leaves unwritten settings intact' } finally { $key.Dispose() }
            }
        } finally {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subkey,$false)
        }
        Assert ($null -eq [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)) 'The real-registry fixture is removed'
    } }
    if ($Scenario -eq 'ApplyComparison' -or ($Scenario -eq 'All' -and $BaseHarnessPath)) { & {
        if ($env:OS -ne 'Windows_NT') { throw 'The base/new apply comparison requires Windows.' }
        if (-not $BaseHarnessPath -or $BaseHarnessSha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $BaseHarnessPath).Hash -ine $BaseHarnessSha256) { throw 'The exact base harness source receipt is required.' }
        $comparisonSubkey='Software\RooIndustriesFixture-'+[guid]::NewGuid().ToString('N')
        $comparisonPath='HKCU\'+$comparisonSubkey
        $rows=New-Object System.Collections.Generic.List[object]
        try {
            foreach ($case in 'absent UInt32 max','present UInt32 max','existing String') {
                foreach ($flavor in 'base','new') { & {
                    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($comparisonSubkey)
                    try {
                        $key.DeleteValue('Value',$false)
                        if ($case -eq 'present UInt32 max') { $key.SetValue('Value',[int]-1,[Microsoft.Win32.RegistryValueKind]::DWord) }
                        if ($case -eq 'existing String') { $key.SetValue('Value','7',[Microsoft.Win32.RegistryValueKind]::String) }
                    } finally { $key.Dispose() }
                    $desired=if ($case -eq 'existing String') { 2 } else { [uint32]::MaxValue }
                    $comparisonManifest=Join-Path $tempRoot 'apply-comparison-manifest.json'
                    @{protected=@{services=@();registryPathPatterns=@()};modules=@(@{id='fixture';name='Fixture';registryValues=@(@{path=$comparisonPath;name='Value';type='REG_DWORD';data=$desired});services=@()})}|ConvertTo-Json -Depth 8|Set-Content $comparisonManifest
                    $candidate=if ($flavor -eq 'base') {$BaseHarnessPath} else {$HarnessPath}
                    . $candidate -Action ListModules -ManifestPath $comparisonManifest -DataRoot (Join-Path $tempRoot ('compare-'+$flavor)) -ModuleId fixture | Out-Null
                    function Get-BenchmarkSnapshot { param($Label) @{label=$Label} }
                    function Invoke-SmokeTest { @() }
                    $ConfirmApply=$true
                    $failure=$null
                    try { Invoke-ReviewedApply | Out-Null } catch { $failure=$_.Exception.Message }
                    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($comparisonSubkey)
                    try {
                        $exists='Value' -in $key.GetValueNames()
                        $kind=if ($exists) {[string]$key.GetValueKind('Value')} else {$null}
                        $data=if (-not $exists) {$null} elseif ($kind -eq 'DWord') {[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$key.GetValue('Value')),0).ToString([Globalization.CultureInfo]::InvariantCulture)} else {[string]$key.GetValue('Value')}
                    } finally { $key.Dispose() }
                    $rows.Add([pscustomobject]@{case=$case;flavor=$flavor;error=$failure;exists=$exists;kind=$kind;data=$data})
                    if ($flavor -eq 'new') { Assert ($null -eq $failure -and $kind -ceq 'DWord' -and $data -ceq ([string]$desired)) ('New apply writes exact DWORD data for '+$case) }
                    elseif ($case -eq 'existing String') { Assert ($null -eq $failure -and $kind -ceq 'String' -and $data -ceq '2') 'The actual base provider keeps an existing String kind on DWORD apply' }
                    else { Assert (($null -eq $failure -and $kind -ceq 'DWord' -and $data -ceq '4294967295') -or ($failure -and (($case -eq 'absent UInt32 max' -and -not $exists) -or ($case -eq 'present UInt32 max' -and $kind -ceq 'DWord' -and $data -ceq '4294967295')))) ('Actual base UInt32-max outcome is captured for '+$case) }
                } }
            }
            Write-Output ('BASE_NEW_APPLY_FIXTURE_JSON '+(ConvertTo-Json -InputObject @{baseHarnessSha256=$BaseHarnessSha256;results=@($rows.ToArray())} -Depth 6 -Compress))
        } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($comparisonSubkey,$false) }
        Assert ($null -eq [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($comparisonSubkey)) 'The apply-comparison fixture is removed'
    } }
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
