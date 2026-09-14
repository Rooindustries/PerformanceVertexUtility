param(
    [string]$PolicyPath,
    [ValidateSet('start','status','restore')]
    [string]$Mode = 'start',
    [string]$SessionPath = '',
    [string]$BackupPath = '',
    [string]$WorkerPath = '',
    [string]$OutputPath = '',
    [switch]$ForceBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

try {
    if ($Mode -eq 'start' -and [string]::IsNullOrWhiteSpace($PolicyPath)) {
        throw 'PolicyPath is required.'
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $resolvedPolicyPath = $null
    if ($Mode -eq 'start') {
        $resolvedPolicyPath = Resolve-RooPath $PolicyPath (Join-Path (Get-Location) $PolicyPath)
        if (-not (Test-Path -LiteralPath $resolvedPolicyPath)) {
            throw "Native governor policy JSON was not found: $resolvedPolicyPath"
        }
    }

    $defaultWorkerPath = Join-Path $repoRoot 'backend\bin\RooProcessGovernor.exe'
    $resolvedWorkerPath = Resolve-RooPath $WorkerPath $defaultWorkerPath
    if ($ForceBuild -or -not (Test-Path -LiteralPath $resolvedWorkerPath)) {
        $build = & (Join-Path $PSScriptRoot 'Build-NativeProcessGovernor.ps1') -OutputPath $resolvedWorkerPath -Force:$ForceBuild | ConvertFrom-Json
        if ($build.status -notin @('built','upToDate')) {
            throw "Native process governor build failed with status '$($build.status)'."
        }
    }

    $args = @()
    if ($Mode -eq 'status') {
        if ([string]::IsNullOrWhiteSpace($SessionPath)) { throw 'SessionPath is required for native governor status.' }
        $args += @('--status', (Resolve-RooPath $SessionPath (Join-Path (Get-Location) $SessionPath)))
    } elseif ($Mode -eq 'restore') {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) { throw 'BackupPath is required for native governor restore.' }
        $args += @('--restore', (Resolve-RooPath $BackupPath (Join-Path (Get-Location) $BackupPath)))
    } else {
        $args += @('--policy', $resolvedPolicyPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-RooPath $OutputPath (Join-Path (Get-Location) $OutputPath)
        $args += @('--output', $resolvedOutputPath)
    }

    $output = & $resolvedWorkerPath @args
    if ($LASTEXITCODE -ne 0) {
        if ($output) { $output | Write-Output }
        exit $LASTEXITCODE
    }
    if ($output) { $output | Write-Output }
} catch {
    $errorResult = [pscustomobject]@{
        actionId = 'performance.nativeGovernor.startSession'
        schemaVersion = 1
        productName = $script:RooProcessProductName
        status = 'failed'
        policyPath = $PolicyPath
        errors = @((New-RooIssue 'NATIVE_GOVERNOR_WRAPPER_FAILED' $_.Exception.Message 'error' 'performance.nativeGovernor' $PolicyPath $true 'Check policy path, worker build, and output path.' $null))
    }
    Write-RooJsonOutput $errorResult ''
    exit 1
}
