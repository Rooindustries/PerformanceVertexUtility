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
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath
    $protectedCatalogPath = Resolve-RooProcessGovernorProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooJsonFile $protectedCatalogPath
    $previewState = Get-RooProcessGovernorPreview `
        -Profile $profile `
        -ProfilePath $resolvedProfilePath `
        -ProtectedCatalog $protectedCatalog `
        -SampleIntervalMilliseconds $SampleIntervalMilliseconds `
        -ForegroundProcessId $ForegroundProcessId `
        -IncludeCommandLine:$IncludeCommandLine

    $warnings = New-Object System.Collections.Generic.List[object]
    $warnings.Add((New-RooIssue 'PROCESS_GOVERNOR_PREVIEW_ONLY' 'Process governor preview sampled CPU pressure without applying process changes.' 'info' 'performance.governor' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Run Start-ProcessGovernorSession.ps1 with -ConfirmApply only after reviewing the preview.' $null)) | Out-Null
    if (@(Get-RooPropertyArray $previewState 'preview').Count -eq 0) {
        $warnings.Add((New-RooIssue 'NO_GOVERNOR_CANDIDATES' 'No running processes matched the governor profile or crossed CPU thresholds during the preview sample.' 'warning' 'performance.governor' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Run the workload, increase sample duration, or review profile selectors.' $null)) | Out-Null
    }

    $sample = Get-RooPropertyValue $previewState 'sample' $null
    $config = Get-RooPropertyValue $previewState 'config' $null
    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.governor.preview' `
        -DryRun $true `
        -Risk ([string](Get-RooPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status 'preview' `
        -Preview @(Get-RooPropertyArray $previewState 'preview') `
        -Backup $null `
        -Result $null `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooLog "Process governor preview sampled total CPU $([double](Get-RooPropertyValue $sample 'totalCpuPercent' 0))%."))

    $envelope | Add-Member -NotePropertyName profileId -NotePropertyValue ([string](Get-RooPropertyValue $profile 'profileId' ''))
    $envelope | Add-Member -NotePropertyName profilePath -NotePropertyValue $resolvedProfilePath
    $envelope | Add-Member -NotePropertyName protectedCatalogPath -NotePropertyValue $protectedCatalogPath
    $envelope | Add-Member -NotePropertyName foregroundProcessId -NotePropertyValue (Get-RooPropertyValue $previewState 'foregroundProcessId' $null)
    $envelope | Add-Member -NotePropertyName sample -NotePropertyValue $sample
    $envelope | Add-Member -NotePropertyName governor -NotePropertyValue $config

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.governor.preview' `
        -DryRun $true `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIssue 'PROCESS_GOVERNOR_PREVIEW_FAILED' $_.Exception.Message 'error' 'performance.governor' $ProfilePath $true 'Check the governor profile path and process inventory permissions.' $null)) `
        -Logs @((New-RooLog 'Process governor preview failed.' 'error'))
    Write-RooJsonOutput $envelope $OutputPath
    exit 1
}
