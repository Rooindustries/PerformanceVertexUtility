param(
    [string]$NvpiExecutablePath,
    [string]$ExportPath,
    [int]$TimeoutSeconds = 10,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

# This helper is intentionally a normal script: the caller decides whether to
# launch it from an elevated host. It keeps the read-only NVPI probe path exact.
& (Join-Path $PSScriptRoot 'Invoke-NvidiaNipCapabilityProbe.ps1') `
    -NvpiExecutablePath $NvpiExecutablePath `
    -ExportPath $ExportPath `
    -TimeoutSeconds $TimeoutSeconds `
    -OutputPath $OutputPath `
    -AllowReadOnlyNvpiProbe
