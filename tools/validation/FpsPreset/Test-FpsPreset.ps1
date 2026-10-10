param(
    [Parameter(Mandatory=$true)][ValidateSet('apply','verify-on','undo','verify-off')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$HostPath,
    [Parameter(Mandatory=$true)][string]$ArtifactDir,
    [string]$ProfileId='fps-preset-e2e'
)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $ArtifactDir | Out-Null
function Invoke-Helper([string]$Command, [hashtable]$Request) {
    $file=Join-Path $ArtifactDir ([guid]::NewGuid().ToString('N')+'.request.json')
    [IO.File]::WriteAllText($file, ($Request|ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    if ($HostPath.EndsWith('.dll')) {
        $dotnet=if ($env:ROO_INDUSTRIES_DOTNET_EXE) { $env:ROO_INDUSTRIES_DOTNET_EXE } else { Join-Path $env:USERPROFILE '.dotnet\dotnet.exe' }
        $output=& $dotnet $HostPath $Command $file
    } else { $output=& $HostPath $Command $file }
    Remove-Item $file -Force
    ($output -join "`n") | ConvertFrom-Json
}
function Get-SecurityState {
    $guard=Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard
    $hvci=(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction SilentlyContinue).Enabled
    $memory=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction SilentlyContinue
    $launch=((bcdedit /enum '{current}' | Select-String 'hypervisorlaunchtype') -join '').Trim()
    [ordered]@{
        vbsStatus=[int]$guard.VirtualizationBasedSecurityStatus
        servicesRunning=@($guard.SecurityServicesRunning | ForEach-Object { [int]$_ })
        hvciEnabled=$hvci
        hypervisorLaunchType=$launch
        featureSettingsOverride=$memory.FeatureSettingsOverride
        featureSettingsOverrideMask=$memory.FeatureSettingsOverrideMask
        cfg=[string](Get-ProcessMitigation -System).CFG.Enable
    }
}
function Get-Boot { [long](Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc() }
function Read-Targets {
    $targets=Join-Path $ArtifactDir 'targets.json'
    if (-not(Test-Path $targets)) { return [ordered]@{} }
    $values=[ordered]@{}
    $list=Get-Content $targets -Raw | ConvertFrom-Json
    foreach ($target in @($list)) {
        $key=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$target.hive, [Microsoft.Win32.RegistryView]$target.view).OpenSubKey($target.keyPath)
        $name="$($target.hive)\$($target.keyPath)\$($target.valueName)"
        if ($null -eq $key) { $values[$name]='no-key'; continue }
        $raw=$key.GetValue($target.valueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $values[$name]=if ($null -eq $raw) { 'absent' } else { "$($key.GetValueKind($target.valueName)):$(if ($raw -is [byte[]]) { [BitConverter]::ToString($raw) } else { @($raw) -join '|' })" }
        $key.Dispose()
    }
    $values
}
function Get-Configured($Status) { $all=[ordered]@{}; foreach ($selection in @($preset.selections)) { $all[$selection.settingId]=(@(($Status.data.settings | Where-Object id -eq $selection.settingId).configuredChoices) | Sort-Object) -join ',' }; $all }
function Save([string]$Name, $Value) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ArtifactDir $Name) -Encoding UTF8 }
$status=Invoke-Helper 'tweak-status' @{schemaVersion=1;repoRoot=$RepoRoot}
$preset=(Invoke-Helper 'tweak-catalog' @{schemaVersion=1;repoRoot=$RepoRoot}).data.catalog.presets | Where-Object id -eq 'fps-boost'
if (-not $preset) { throw 'The shipped catalog has no fps-boost preset.' }
switch ($Phase) {
    'apply' {
        if (@($status.data.state.profiles | Where-Object id -eq $ProfileId).Count) { throw "Profile $ProfileId is already applied." }
        $preview=Join-Path $ArtifactDir 'apply-preview.json'
        $result=Invoke-Helper 'tweak-preview' @{schemaVersion=1;repoRoot=$RepoRoot;profileId=$ProfileId;presetId='fps-boost';outputPath=$preview}
        if ($result.status -ne 'completed') { throw "Preset preview failed: $($result.error.message)" }
        $plan=Get-Content $preview -Raw | ConvertFrom-Json
        ConvertTo-Json -Depth 5 -InputObject @($plan.changes | ForEach-Object { $_.before.address } | Where-Object kind -eq 'value' | Select-Object hive,view,keyPath,valueName) | Set-Content -LiteralPath (Join-Path $ArtifactDir 'targets.json') -Encoding UTF8
        Save 'before.json' ([ordered]@{boot=Get-Boot; security=Get-SecurityState; registry=Read-Targets; configured=Get-Configured $status; skipped=@($plan.skipped); profiles=@($status.data.state.profiles | ForEach-Object id)})
        $apply=Invoke-Helper 'tweak-apply' @{schemaVersion=1;repoRoot=$RepoRoot;previewPath=$preview;reviewHash=(Get-FileHash $preview -Algorithm SHA256).Hash;confirm=$true}
        if ($apply.status -ne 'completed') { throw "Preset apply failed: $($apply.error.message)" }
        $applied=Invoke-Helper 'tweak-status' @{schemaVersion=1;repoRoot=$RepoRoot}
        $selections=@(($applied.data.state.profiles | Where-Object id -eq $ProfileId).selections)
        Save 'apply.json' ([ordered]@{presetSelections=@($preset.selections).Count; profileSelections=$selections.Count; boot=Get-Boot; pass=($selections.Count -eq @($preset.selections).Count -and @($plan.skipped).Count -eq 0)})
    }
    'verify-on' {
        $state=Get-SecurityState
        $boot=Get-Boot; $rebooted=$boot -ne [long](Get-Content (Join-Path $ArtifactDir 'apply.json') -Raw | ConvertFrom-Json).boot
        $configured=@($preset.selections | Where-Object { $selection=$_; $setting=$status.data.settings | Where-Object id -eq $selection.settingId; @($setting.configuredChoices) -contains $selection.optionId })
        $pass=$rebooted -and $state.vbsStatus -eq 0 -and $state.hvciEnabled -eq 0 -and $state.hypervisorLaunchType -match 'Off' -and $state.featureSettingsOverride -eq 3 -and $state.featureSettingsOverrideMask -eq 3 -and $state.cfg -eq 'OFF' -and $configured.Count -eq @($preset.selections).Count
        Save 'verify-on.json' ([ordered]@{boot=$boot; rebootedSinceApply=$rebooted; security=$state; configured=$configured.Count; expected=@($preset.selections).Count; pass=$pass})
    }
    'undo' {
        $preview=Join-Path $ArtifactDir 'undo-preview.json'
        $result=Invoke-Helper 'tweak-preview' @{schemaVersion=1;repoRoot=$RepoRoot;profileId=$ProfileId;selections=@();outputPath=$preview}
        if ($result.status -ne 'completed') { throw "Undo preview failed: $($result.error.message)" }
        $left=@((Get-Content $preview -Raw | ConvertFrom-Json).leftAsChanged)
        $undo=Invoke-Helper 'tweak-apply' @{schemaVersion=1;repoRoot=$RepoRoot;previewPath=$preview;reviewHash=(Get-FileHash $preview -Algorithm SHA256).Hash;confirm=$true}
        $after=Invoke-Helper 'tweak-status' @{schemaVersion=1;repoRoot=$RepoRoot}
        $gone=@($after.data.state.profiles | Where-Object id -eq $ProfileId).Count -eq 0
        Save 'undo.json' ([ordered]@{status=$undo.status; leftAsChanged=$left; profileGone=$gone; boot=Get-Boot; pass=($undo.status -eq 'completed' -and $gone -and $left.Count -eq 0)})
    }
    'verify-off' {
        $before=Get-Content (Join-Path $ArtifactDir 'before.json') -Raw | ConvertFrom-Json
        $boot=Get-Boot; $rebooted=$boot -ne [long](Get-Content (Join-Path $ArtifactDir 'undo.json') -Raw | ConvertFrom-Json).boot
        $after=[ordered]@{security=Get-SecurityState; registry=Read-Targets; configured=Get-Configured $status}
        $differs=@(foreach ($part in 'security','registry','configured') { foreach ($field in $before.$part.PSObject.Properties) { $now=$after[$part][$field.Name]; if (($field.Value | ConvertTo-Json -Compress) -ne ($now | ConvertTo-Json -Compress)) { "$part.$($field.Name): $($field.Value | ConvertTo-Json -Compress) -> $($now | ConvertTo-Json -Compress)" } } })
        $counted=@($before.registry.PSObject.Properties).Count -eq $after.registry.Count -and $after.registry.Count -gt 0 -and @($before.configured.PSObject.Properties).Count -eq @($preset.selections).Count
        Save 'verify-off.json' ([ordered]@{boot=$boot; rebootedSinceUndo=$rebooted; before=$before; after=$after; differs=$differs; pass=($rebooted -and $counted -and $differs.Count -eq 0)})
    }
}
Get-ChildItem $ArtifactDir -Filter '*.json' | Where-Object Name -match '^(apply|verify-on|undo|verify-off)\.json$' | ForEach-Object { "$($_.BaseName): $((Get-Content $_.FullName -Raw | ConvertFrom-Json).pass)" }
