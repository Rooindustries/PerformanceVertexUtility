$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Add-Pass {
    param([string]$Message)
    $passes.Add($Message) | Out-Null
    Write-Host "PASS $Message"
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "FAIL $Message"
}

function ConvertFrom-ScriptJson {
    param([object[]]$Output)
    return ($Output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-StateEntryCount {
    $stateRoot = Join-Path $repoRoot 'backend\state'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return 0 }
    return @(Get-ChildItem -LiteralPath $stateRoot -Force -Recurse -ErrorAction SilentlyContinue).Count
}

function Write-OfficialPreview {
    param(
        [string]$Path,
        [string]$Executable,
        [object[]]$Arguments
    )
    ([pscustomobject]@{
        actionId = 'apps.previewOfficialUninstall'
        schemaVersion = 1
        productName = 'Roo Industries Optimization Suite'
        capturedAtUtc = '2026-07-02T00:00:00Z'
        dryRun = $true
        status = 'preview'
        commands = @(
            [pscustomobject]@{
                appId = 'fixture:harmless-runner'
                displayName = 'Harmless Runner'
                commandType = 'harmless-shim'
                rawCommand = 'harmless shim command'
                executable = $Executable
                arguments = @($Arguments)
                protected = $false
                blocked = $false
                executionAllowed = $false
            }
        )
        summary = [pscustomobject]@{ requestedCount = 1; commandPreviewCount = 1; blockedCount = 0; executionAllowedCount = 0; willRunUninstallers = $false }
        warnings = @()
        errors = @()
        logs = @()
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $Path -Encoding UTF8
}

$requiredFiles = @(
    'backend\scripts\BackendExecutor.Common.ps1',
    'backend\scripts\Invoke-OfficialUninstallCommandRunner.ps1'
)
foreach ($relative in $requiredFiles) {
    $path = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $path) {
        Add-Pass "Required file exists: $relative"
    } else {
        Add-Failure "Required file missing: $relative"
    }
}

$stateBefore = Get-StateEntryCount
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "roo-industries-official-runner-$([guid]::NewGuid().ToString('N'))"
$cleanupDone = $false
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $shim = Join-Path $tempRoot 'runner.ps1'
    $sleepShim = Join-Path $tempRoot 'sleep-runner.ps1'
    $previewPath = Join-Path $tempRoot 'official-preview.json'
    $sleepPreviewPath = Join-Path $tempRoot 'sleep-preview.json'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    @'
param([string]$First, [string]$Second)
[pscustomobject]@{
  cwd = (Get-Location).Path
  first = $First
  second = $Second
} | ConvertTo-Json -Compress
Write-Error 'harmless stderr capture'
exit 0
'@ | Set-Content -LiteralPath $shim -Encoding UTF8
    @'
Start-Sleep -Seconds 5
exit 0
'@ | Set-Content -LiteralPath $sleepShim -Encoding UTF8
    Write-OfficialPreview $previewPath $powershellPath @('-NoProfile','-ExecutionPolicy','Bypass','-File',$shim,'two words','quoted=value')
    Write-OfficialPreview $sleepPreviewPath $powershellPath @('-NoProfile','-ExecutionPolicy','Bypass','-File',$sleepShim)

    $preview = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-OfficialUninstallCommandRunner.ps1') -OfficialPreviewPath $previewPath -AllowedExecutablePath $powershellPath -WorkingDirectory $tempRoot)
    if ($preview.status -eq 'preview' -and $preview.summary.processStarted -eq $false -and $preview.summary.willRunRealUninstaller -eq $false) {
        Add-Pass 'Official uninstall command runner defaults to preview without process start'
    } else {
        Add-Failure 'Official uninstall command runner default call was not preview-only'
    }

    $success = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-OfficialUninstallCommandRunner.ps1') -OfficialPreviewPath $previewPath -AllowedExecutablePath $powershellPath -WorkingDirectory $tempRoot -ConfirmApply -AllowHarmlessShimExecution -UserApproved)
    $stdout = $success.result.stdout | ConvertFrom-Json
    if ($success.status -eq 'success' -and $success.summary.processStarted -eq $true -and $success.summary.exitCode -eq 0 -and $success.summary.stdoutCaptured -eq $true -and $success.summary.stderrCaptured -eq $true -and $success.summary.focusStealPrevented -eq $true -and $success.capabilities.realProcessRunnerImplemented -eq $true -and $success.capabilities.realAppUninstallBlocked -eq $true -and $stdout.cwd -eq $tempRoot -and $stdout.first -eq 'two words' -and $stdout.second -eq 'quoted=value') {
        Add-Pass 'Official uninstall harmless runner proves quoting, working directory, stdout/stderr, exit code, and hidden process execution'
    } else {
        Add-Failure 'Official uninstall harmless runner did not prove process-runner behavior'
    }

    $timeout = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-OfficialUninstallCommandRunner.ps1') -OfficialPreviewPath $sleepPreviewPath -AllowedExecutablePath $powershellPath -WorkingDirectory $tempRoot -ConfirmApply -AllowHarmlessShimExecution -UserApproved -TimeoutSeconds 1)
    if ($timeout.status -eq 'failed' -and $timeout.summary.timedOut -eq $true -and $timeout.summary.willRunRealUninstaller -eq $false) {
        Add-Pass 'Official uninstall harmless runner proves timeout cancellation'
    } else {
        Add-Failure 'Official uninstall harmless runner did not prove timeout cancellation'
    }

    $cancelPath = Join-Path $tempRoot 'cancel.signal'
    Set-Content -LiteralPath $cancelPath -Value 'cancel' -Encoding UTF8
    $canceled = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-OfficialUninstallCommandRunner.ps1') -OfficialPreviewPath $previewPath -AllowedExecutablePath $powershellPath -WorkingDirectory $tempRoot -CancellationSignalPath $cancelPath -ConfirmApply -AllowHarmlessShimExecution -UserApproved)
    if ($canceled.status -eq 'canceled' -and $canceled.summary.processStarted -eq $false -and $canceled.summary.cancellationRequested -eq $true) {
        Add-Pass 'Official uninstall harmless runner honors cancellation signal before process start'
    } else {
        Add-Failure 'Official uninstall harmless runner did not honor cancellation signal'
    }

    $blocked = ConvertFrom-ScriptJson (& (Join-Path $PSScriptRoot 'Invoke-OfficialUninstallCommandRunner.ps1') -OfficialPreviewPath $previewPath -AllowedExecutablePath (Join-Path $tempRoot 'not-the-runner.exe') -WorkingDirectory $tempRoot -ConfirmApply -AllowHarmlessShimExecution -UserApproved)
    $allowGate = @($blocked.gates | Where-Object { $_.gateId -eq 'executable-allowlist-match' }) | Select-Object -First 1
    if ($blocked.status -eq 'blocked' -and $allowGate.blocking -eq $true -and $blocked.summary.processStarted -eq $false) {
        Add-Pass 'Official uninstall harmless runner blocks commands that do not match the exact executable allowlist'
    } else {
        Add-Failure 'Official uninstall harmless runner did not block non-allowlisted executable'
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force
    $cleanupDone = $true
    if (-not (Test-Path -LiteralPath $tempRoot)) {
        Add-Pass 'Official uninstall runner disposable fixtures were cleaned up'
    } else {
        Add-Failure 'Official uninstall runner disposable fixtures remain'
    }
} catch {
    Add-Failure "Official uninstall runner validation failed: $($_.Exception.Message)"
} finally {
    if (-not $cleanupDone -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$stateAfter = Get-StateEntryCount
if ($stateBefore -eq $stateAfter -and $stateAfter -eq 0) {
    Add-Pass 'backend/state remains empty after official uninstall runner validation'
} else {
    Add-Failure "backend/state is not empty or changed during official uninstall runner validation: before=$stateBefore after=$stateAfter"
}

Add-Pass 'Official uninstall runner validation did not launch real uninstallers, Revo, registry, service, task, or cleanup tools'

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "PASS Official uninstall command runner validation completed. $($passes.Count) checks passed."
    exit 0
}

Write-Host "FAIL Official uninstall command runner validation failed. $($failures.Count) failure(s), $($passes.Count) pass(es)."
exit 1
