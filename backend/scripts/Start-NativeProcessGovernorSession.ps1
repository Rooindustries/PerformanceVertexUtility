param(
    [string]$PolicyPath,
    [string]$WorkerPath = '',
    [string]$OutputPath = '',
    [switch]$ForceBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
        throw 'PolicyPath is required.'
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $resolvedPolicyPath = Resolve-RooPath $PolicyPath (Join-Path (Get-Location) $PolicyPath)
    if (-not (Test-Path -LiteralPath $resolvedPolicyPath)) {
        throw "Native governor policy JSON was not found: $resolvedPolicyPath"
    }

    $defaultWorkerPath = Join-Path $repoRoot 'backend\bin\RooProcessGovernor.exe'
    $resolvedWorkerPath = Resolve-RooPath $WorkerPath $defaultWorkerPath
    if ($ForceBuild -or -not (Test-Path -LiteralPath $resolvedWorkerPath)) {
        $build = & (Join-Path $PSScriptRoot 'Build-NativeProcessGovernor.ps1') -OutputPath $resolvedWorkerPath -Force:$ForceBuild | ConvertFrom-Json
        if ($build.status -notin @('built','upToDate')) {
            throw "Native process governor build failed with status '$($build.status)'."
        }
    }

    $args = @('--policy', $resolvedPolicyPath)
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
