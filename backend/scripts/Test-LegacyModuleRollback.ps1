param([string]$HarnessPath = (Join-Path $PSScriptRoot '..\..\LeanClientOptimizer.ps1'))
$ErrorActionPreference = 'Stop'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('roo-legacy-rollback-' + [guid]::NewGuid().ToString('N'))
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
    . $HarnessPath -Action ListModules -ManifestPath $fixtureManifest -DataRoot $tempRoot -ModuleId 'fixture' | Out-Null
    # Only operating-system calls are replaced; backup selection and apply/rollback execute the real harness.
    $script:value = 1
    function Get-RegistryValueSnapshot { param($Item) [pscustomobject]@{ oldValue = $script:value; valueExists = $true } }
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
    @{ moduleId = 'fixture'; timestamp = '2099-01-01T00:00:00Z'; registry = @(@{oldValue = 99}); services = @() } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $strayRoot 'backup.json')
    $script:value = 2
    Invoke-RollbackModule | Out-Null
    Assert ($script:value -eq 1) 'Unproven legacy preview snapshots cannot displace an applied operation'
    $second = Invoke-ApplyModule
    Assert ($second.backupPath -ne $applied.backupPath) 'Repeated operations have distinct backup paths'
    $BackupPath = $applied.backupPath
    Invoke-RollbackModule | Out-Null
    Assert ($script:value -eq 1) 'Explicit backup selection restores the requested operation'
    $BackupPath = Join-Path $tempRoot 'wrong-module.json'
    @{moduleId='other'; registry=@(); services=@()} | ConvertTo-Json | Set-Content $BackupPath
    $rejected = $false
    try { Invoke-RollbackModule | Out-Null } catch { $rejected = $_.Exception.Message -like '*different module*' }
    Assert $rejected 'Rollback rejects a backup for another module'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
