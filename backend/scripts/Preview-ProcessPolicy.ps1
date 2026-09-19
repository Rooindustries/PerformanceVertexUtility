param(
    [string]$ProfilePath = '',
    [string]$OutputPath = '',
    [switch]$IncludeCommandLine
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProcessPolicy.Common.ps1')

try {
    $defaultProfilePath = Join-Path $PSScriptRoot '..\profiles\persistent-policy.profile.json'
    $resolvedProfilePath = Resolve-RooIndustriesPath $ProfilePath $defaultProfilePath
    $profile = Read-RooIndustriesJsonFile $resolvedProfilePath
    $protectedCatalogPath = Resolve-RooIndustriesProcessPolicyProtectedCatalog $profile $resolvedProfilePath
    $protectedCatalog = Read-RooIndustriesJsonFile $protectedCatalogPath
    $previewState = Get-RooIndustriesProcessPolicyPreview `
        -Profile $profile `
        -ProfilePath $resolvedProfilePath `
        -ProtectedCatalog $protectedCatalog `
        -IncludeCommandLine:$IncludeCommandLine

    $warnings = New-Object System.Collections.Generic.List[object]
    $warnings.Add((New-RooIndustriesIssue 'PROCESS_POLICY_PREVIEW_ONLY' 'Persistent process policy preview inspected running processes without applying changes.' 'info' 'performance.policy' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Run Start-ProcessPolicySession.ps1 with -ConfirmApply only after reviewing the preview and safety gates.' $null)) | Out-Null
    if (@(Get-RooIndustriesPropertyArray $previewState 'preview').Count -eq 0) {
        $warnings.Add((New-RooIndustriesIssue 'NO_PROCESS_POLICY_MATCHES' 'No running processes matched the persistent policy profile during preview.' 'warning' 'performance.policy' ([string](Get-RooIndustriesPropertyValue $profile 'profileId' '')) $false 'Start a matching workload or review policy selectors.' $null)) | Out-Null
    }

    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.policy.preview' `
        -DryRun $true `
        -Risk ([string](Get-RooIndustriesPropertyValue $profile 'risk' 'medium')) `
        -RequiresElevation $false `
        -Status 'preview' `
        -Preview @(Get-RooIndustriesPropertyArray $previewState 'preview') `
        -Backup $null `
        -Result $null `
        -Warnings @($warnings.ToArray()) `
        -Errors @() `
        -Logs @((New-RooIndustriesLog "Persistent policy preview scanned $([int](Get-RooIndustriesPropertyValue $previewState 'processCount' 0)) running process(es)."))

    $envelope | Add-Member -NotePropertyName profileId -NotePropertyValue ([string](Get-RooIndustriesPropertyValue $profile 'profileId' ''))
    $envelope | Add-Member -NotePropertyName profilePath -NotePropertyValue $resolvedProfilePath
    $envelope | Add-Member -NotePropertyName protectedCatalogPath -NotePropertyValue $protectedCatalogPath
    $envelope | Add-Member -NotePropertyName capturedAtUtc -NotePropertyValue (Get-RooIndustriesPropertyValue $previewState 'capturedAtUtc' $null)
    $envelope | Add-Member -NotePropertyName processCount -NotePropertyValue ([int](Get-RooIndustriesPropertyValue $previewState 'processCount' 0))

    Write-RooIndustriesJsonOutput $envelope $OutputPath
} catch {
    $envelope = New-RooIndustriesActionEnvelope `
        -ActionId 'performance.policy.preview' `
        -DryRun $true `
        -Risk 'medium' `
        -RequiresElevation $false `
        -Status 'failed' `
        -Preview @() `
        -Backup $null `
        -Result $null `
        -Warnings @() `
        -Errors @((New-RooIndustriesIssue 'PROCESS_POLICY_PREVIEW_FAILED' $_.Exception.Message 'error' 'performance.policy' $ProfilePath $true 'Check the policy profile path and process inventory permissions.' $null)) `
        -Logs @((New-RooIndustriesLog 'Persistent policy preview failed.' 'error'))
    Write-RooIndustriesJsonOutput $envelope $OutputPath
    exit 1
}
