param([string]$OutputPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')
. (Join-Path $PSScriptRoot 'BackgroundPlacement.Common.ps1')
try {
    Write-RooIndustriesJsonOutput (Read-RooIndustriesBackgroundPlacement) $OutputPath
} catch {
    Write-RooIndustriesJsonOutput ([pscustomobject]@{available=$false;kind='';mask=0;label='Background apps on E-cores or CCD1, normal priority';reason="Couldn't read the CPU topology. $($_.Exception.Message)"}) $OutputPath
}
