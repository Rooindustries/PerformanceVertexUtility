param(
    [string]$ProfilePath = '',
    [string]$OutputPath = '',
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\persistent-policy.profile.json'
    $resolvedProfilePath = Resolve-RooPath $ProfilePath $defaultProfilePath
    $profile = Read-RooJsonFile $resolvedProfilePath
    $protectedCatalogPath = Resolve-RooProcessPolicyProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooJsonFile $protectedCatalogPath
    $previewState = Get-RooProcessPolicyPreview `
        -Profile $profile `
        -ProfilePath $resolvedProfilePath `
        -ProtectedCatalog $protectedCatalog `
        -IncludeCommandLine:$IncludeCommandLine

    $warnings = New-Object System.Collections.Generic.List[object]
    $warnings.Add((New-RooIssue 'PROCESS_POLICY_PREVIEW_ONLY' 'Persistent process policy preview inspected running processes without applying changes.' 'info' 'performance.policy' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Run Start-ProcessPolicySession.ps1 with -ConfirmApply only after reviewing the preview and safety gates.' $null)) | Out-Null
    if (@(Get-RooPropertyArray $previewState 'preview').Count -eq 0) {
        $warnings.Add((New-RooIssue 'NO_PROCESS_POLICY_MATCHES' 'No running processes matched the persistent policy profile during preview.' 'warning' 'performance.policy' ([string](Get-RooPropertyValue $profile 'profileId' '')) $false 'Start a matching workload or review policy selectors.' $null)) | Out-Null
    }

    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.policy.preview' `
        -DryRun $true `
        -Risk ([string](Get-RooPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status 'preview' `
        -Preview @(Get-RooPropertyArray $previewState 'preview') `
        -Backup $null `
        -Result $null `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooLog "Persistent policy preview scanned $([int](Get-RooPropertyValue $previewState 'processCount' 0)) running process(es)."))

    $envelope | Add-Member -NotePropertyName profileId -NotePropertyValue ([string](Get-RooPropertyValue $profile 'profileId' ''))
    $envelope | Add-Member -NotePropertyName profilePath -NotePropertyValue $resolvedProfilePath
    $envelope | Add-Member -NotePropertyName protectedCatalogPath -NotePropertyValue $protectedCatalogPath
    $envelope | Add-Member -NotePropertyName capturedAtUtc -NotePropertyValue (Get-RooPropertyValue $previewState 'capturedAtUtc' $null)
    $envelope | Add-Member -NotePropertyName processCount -NotePropertyValue ([int](Get-RooPropertyValue $previewState 'processCount' 0))

    Write-RooJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooActionEnvelope `
        -ActionId 'performance.policy.preview' `
        -DryRun $true `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIssue 'PROCESS_POLICY_PREVIEW_FAILED' $_.Exception.Message 'error' 'performance.policy' $ProfilePath $true 'Check the policy profile path and process inventory permissions.' $null)) `
        -Logs @((New-RooLog 'Persistent policy preview failed.' 'error'))
    Write-RooJsonOutput $envelope $OutputPath
    exit 1
}
