param(
    [ValidateSet('settings','applications','playbookActions')][string]$Collection='settings',
    [string]$Source='', [string]$Category='', [string]$Search='',
    [ValidateRange(0,2147483647)][int]$Offset=0,
    [ValidateRange(1,500)][int]$Limit=100,
    [string]$OutputPath=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$catalog=(Read-RooIndustriesOperationJson (Join-Path $PSScriptRoot '..\catalogs\upstream-settings-inventory.json')).data
$entries=@($catalog.$Collection)
if($Source){$entries=@($entries|Where-Object {$_.sourceId -ceq $Source})}
if($Category){$entries=@($entries|Where-Object {$_.category -ieq $Category})}
if($Search){$literal=[regex]::Escape($Search);$entries=@($entries|Where-Object {($_|ConvertTo-Json -Depth 20 -Compress) -match $literal})}
$result=[pscustomobject]@{schemaVersion=1;actionId='settings.upstreamCatalog';status='detected';dryRun=$true;
    catalogId=$catalog.catalogId;capturedDate=$catalog.capturedDate;sourceSnapshots=$catalog.sourceSnapshots;safetyPolicy=$catalog.safetyPolicy;
    collection=$Collection;totalCount=$entries.Count;offset=$Offset;limit=$Limit;entries=@($entries|Select-Object -Skip $Offset -First $Limit);
    catalogSummary=$catalog.summary}
if($OutputPath){Write-RooIndustriesOperationJson $result $OutputPath}
$result|ConvertTo-Json -Depth 32
