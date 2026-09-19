param(
    [string]$ProfilePath = '',
    [int]$SampleIntervalMilliseconds = 500,
    [int]$ForegroundProcessId = 0,
    [string]$OutputPath = '',
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessGovernor.Common.ps1')

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\probalance-governor.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $protectedCatalogPath = Resolve-RooIndustriesProcessGovernorProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath
    $previewState = Get-RooIndustriesProcessGovernorPreview `
        -Profile $profile `
        -ProfilePath $resolvedProfilePath `
        -ProtectedCatalog $protectedCatalog `
        -SampleIntervalMilliseconds $SampleIntervalMilliseconds `
        -ForegroundProcessId $ForegroundProcessId `
        -IncludeCommandLine:$IncludeCommandLine

    $warnings = New-Object System.Collections.Generic.List[object]
    $warnings.Add((New-RooIndustriesIssue 'PROCESS_GOVERNOR_PREVIEW_ONLY' 'Process governor preview sampled CPU pressure without applying process changes.' 'info' 'performance.governor' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Run Start-ProcessGovernorSession.ps1 with -ConfirmApply only after reviewing the preview.' $null)) | Out-Null
    if (@(Get-RooIndustriesPropertyArray $previewState 'preview').Count -eq 0) {
        $warnings.Add((New-RooIndustriesIssue 'NO_GOVERNOR_CANDIDATES' 'No running processes matched the governor profile or crossed CPU thresholds during the preview sample.' 'warning' 'performance.governor' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Run the workload, increase sample duration, or review profile selectors.' $null)) | Out-Null
    }

    $sample = Get-RooIndustriesPropertyValue $previewState 'sample' $null
    $config = Get-RooIndustriesPropertyValue $previewState 'config' $null
    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.governor.preview' `
        -DryRun $true `
        -Risk ([string](Get-RooIndustriesPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status 'preview' `
        -Preview @(Get-RooIndustriesPropertyArray $previewState 'preview') `
        -Backup $null `
        -Result $null `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooIndustriesLog "Process governor preview sampled total CPU $([double](Get-RooIndustriesPropertyValue $sample 'totalCpuPercent' 0))%."))

    $envelope | Add-Member -NotePropertyName profileId -NotePropertyValue ([string](Get-RooIndustriesPropertyValue $profile 'profileId' ''))
    $envelope | Add-Member -NotePropertyName profilePath -NotePropertyValue $resolvedProfilePath
    $envelope | Add-Member -NotePropertyName protectedCatalogPath -NotePropertyValue $protectedCatalogPath
    $envelope | Add-Member -NotePropertyName foregroundProcessId -NotePropertyValue (Get-RooIndustriesPropertyValue $previewState 'foregroundProcessId' $null)
    $envelope | Add-Member -NotePropertyName sample -NotePropertyValue $sample
    $envelope | Add-Member -NotePropertyName governor -NotePropertyValue $config

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.governor.preview' `
        -DryRun $true `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIndustriesIssue 'PROCESS_GOVERNOR_PREVIEW_FAILED' $_.Exception.Message 'error' 'performance.governor' $ProfilePath $true 'Check the governor profile path and process inventory permissions.' $null)) `
        -Logs @((New-RooIndustriesLog 'Process governor preview failed.' 'error'))
    Write-RooIndustriesJsonOutput $envelope $OutputPath
    exit 1
}
