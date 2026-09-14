$ErrorActionPreference='Stop'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};Write-Host "PASS $Message"}
function Read-Result($Lines){return ($Lines -join [Environment]::NewLine)|ConvertFrom-Json}
$path=Join-Path $PSScriptRoot '..\catalogs\upstream-settings-inventory.json'
$catalog=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
Assert ($catalog.settings.Count -eq 376 -and $catalog.applications.Count -eq 267 -and $catalog.playbookActions.Count -eq 1319) 'Pinned upstream inventory retains its independently recorded setting, package and action counts'
foreach($name in @('settings','applications','playbookActions')) {
    $items=@($catalog.$name)
    Assert (@($items.id|Select-Object -Unique).Count -eq $items.Count) "Every $name record has a distinct identity"
    Assert (@($items|Where-Object {$_.automaticApply -ne $false}).Count -eq 0) "No $name record permits automatic execution"
}
Assert (-not $catalog.safetyPolicy.executablePayloadsIncluded -and -not $catalog.safetyPolicy.copiedUpstreamImplementationIncluded) 'Research catalog contains factual metadata without upstream execution bodies'
$script=Join-Path $PSScriptRoot 'Get-UpstreamSettingsCatalog.ps1'
$first=Read-Result (& $script -Source winutil -Limit 7)
$second=Read-Result (& $script -Source winutil -Offset 7 -Limit 7)
Assert ($first.totalCount -eq 164 -and $first.entries.Count -eq 7 -and $second.entries.Count -eq 7 -and @($second.entries|Where-Object {$_.id -in $first.entries.id}).Count -eq 0) 'Catalog pagination is stable and preserves the filtered total'
$search=Read-Result (& $script -Search 'CPU' -Limit 500)
Assert ($search.entries.Count -gt 0 -and $search.dryRun -and $search.status -eq 'detected') 'Literal catalog search returns read-only evidence'
$apps=Read-Result (& $script -Collection applications -Limit 500)
Assert ($apps.totalCount -eq 267 -and $apps.entries.Count -eq 267) 'Installable applications remain separate from system settings'
$pastEnd=Read-Result (& $script -Offset 100000 -Limit 1)
Assert ($pastEnd.entries.Count -eq 0 -and $pastEnd.totalCount -eq 376) 'Pagination beyond the end returns an empty array with an accurate total'
