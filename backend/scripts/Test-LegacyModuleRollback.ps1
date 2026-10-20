param(
    [string]$HarnessPath = (Join-Path $PSScriptRoot '..\..\LeanClientOptimizer.ps1'),
    [ValidateSet('All','Selection','Drift','Registry')][string]$Scenario = 'All'
)
$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-legacy-rollback-' + [guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host "PASS $Message"
}
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fixtureManifest = Join-Path $tempRoot 'manifest.json'
    @{ protected = @{ services = @(); registryPathPatterns = @() }; modules = @(@{
        id = 'fixture'; name = 'Fixture'; registryValues = @(@{ path = 'HKCU\Fixture'; name = 'Value'; type = 'REG_DWORD'; data = 2 }); services = @()
    }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifest -Encoding UTF8
    if ($Scenario -ne 'Registry') { & {
        . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
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
            $legacy.PSObject.Properties.Remove('applyRequested')
            Write-JsonFile $legacy $BackupPath
            $BackupPath=''
            $restored=Invoke-RollbackModule
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
            try { Assert ($key.GetValue('Value') -eq 1 -and $restored.backupPath -eq $applied.backupPath) 'Legacy backups retain restore behavior and latest selection through a confirmed run' } finally { $key.Dispose() }
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
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
