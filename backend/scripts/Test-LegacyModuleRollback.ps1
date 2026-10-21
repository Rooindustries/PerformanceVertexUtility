param(
    [string]$HarnessPath = (Join-Path $PSScriptRoot '..\..\LeanClientOptimizer.ps1'),
    [ValidateSet('All','Selection','Drift','Registry','Recovery','ApplyComparison')][string]$Scenario = 'All',
    [ValidateSet('All','Signed','LegacyEvidence','Preflight','RegistryFailure','ServiceFailure','OriginalEvidence','ServiceExistence','SourceEvidence')][string]$RecoveryCase = 'All',
    [string]$BaseHarnessPath = $env:ROO_INDUSTRIES_LEGACY_BASE_HARNESS,
    [string]$BaseHarnessSha256 = $env:ROO_INDUSTRIES_LEGACY_BASE_HARNESS_SHA256
)
$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-legacy-rollback-' + [guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
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
    @{label='DWord floating number';entry=@{kind='DWord';oldValue=[double]16}}
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
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fixtureManifest = Join-Path $tempRoot 'manifest.json'
    @{ protected = @{ services = @(); registryPathPatterns = @() }; modules = @(@{
        id = 'fixture'; name = 'Fixture'; registryValues = @(@{ path = 'HKCU\Fixture'; name = 'Value'; type = 'REG_DWORD'; data = 2 }); services = @()
    }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifest -Encoding UTF8
    if ($Scenario -in 'All','Recovery') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
        $sourceServiceReader=${function:Get-ServiceSnapshot}
        function Open-RegistryKey {
            param($Path,[switch]$Writable,[switch]$Create)
            $key=[pscustomobject]@{}
            $key | Add-Member ScriptMethod DeleteValue { param($Name,$ThrowOnMissing) $script:recoveryWrites++;$script:recoveryValues[$Name]=[pscustomobject]@{valueExists=$false;kind=$null;oldValue=$null} }
            $key | Add-Member ScriptMethod Dispose {} -PassThru
        }
        function Get-RegistryValueSnapshot { param($Item) $script:recoveryValues[$Item.name] }
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
            $script:recoveryWrites=0;$script:serviceWrites=0;$script:failureName='';$script:failureMode=''
        }
        $first=@{path='HKCU\Fixture';name='First';type='REG_DWORD';desiredData=2;oldValue=1;kind='DWord';valueExists=$true}
        $second=@{path='HKCU\Fixture';name='Second';type='REG_DWORD';desiredData=2;oldValue=0;kind='DWord';valueExists=$true}
        $service=@{name='FixtureSvc';exists=$true;startType='Automatic';status='Running';appliedStartup='Disabled'}
        $BackupPath=Join-Path $tempRoot 'recovery-backup.json'
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
            $applied=Invoke-ApplyModule
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
        $applied = Invoke-ApplyModule
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
        $second = Invoke-ApplyModule
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
            $applied = Invoke-ApplyModule
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
                    $applied=Invoke-ApplyModule
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
                $applied=Invoke-ApplyModule
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
                $applied=Invoke-ApplyModule
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
            $applied=Invoke-ApplyModule
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
                function Set-RegistrySnapshotData { param($Key,$Name,$Snapshot) }
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue('Value',2,[Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
                $refused=$false
                try { Restore-RegistryValue $legacy.registry[0] } catch { $refused=$_.Exception.Message -like '*restore verification failed*' }
                Assert $refused 'Restore refuses to report success when registry readback differs'
            }
            foreach ($nameMode in 'empty','reserved','null','missing') {
                $name=if ($nameMode -eq 'reserved') { 'PSPath' } else { '' }
                $manifest=Get-Content $fixtureManifest -Raw | ConvertFrom-Json
                $manifest.modules[0].registryValues[0].name=$name
                if ($nameMode -eq 'null') { $manifest.modules[0].registryValues[0].name=$null }
                if ($nameMode -eq 'missing') { $manifest.modules[0].registryValues[0].PSObject.Properties.Remove('name') }
                $manifest.modules[0].registryValues[0].type='REG_SZ'
                $manifest.modules[0].registryValues[0].data='Two'
                Write-JsonFile $manifest $fixtureManifest
                $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
                try { $key.SetValue($name,'Original',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
                $applied=Invoke-ApplyModule
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
                try { Assert ($key.GetValue($name) -ceq 'Original') ('The original is restored for ' + $nameMode + ' value names') } finally { $key.Dispose() }
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
            $applied=Invoke-ApplyModule
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
            try { Invoke-ApplyModule | Out-Null } catch { $refused=$_.Exception.Message -like '*Unsupported registry value kind*' }
            Assert $refused 'An unsupported original registry kind refuses apply before changing it'
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey,$true)
            try { $key.SetValue('Value','Original',[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
            $applied=Invoke-ApplyModule
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
                try { Invoke-ApplyModule | Out-Null } catch { $failed=$_.Exception.Message -eq 'Fixture apply failure before write' }
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
                    try { Invoke-ApplyModule | Out-Null } catch { $failure=$_.Exception.Message }
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
