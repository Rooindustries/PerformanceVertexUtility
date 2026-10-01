param([string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference='Stop'
function Check([bool]$Passed,[string]$Message){if(-not $Passed){throw $Message};Write-Output ('PASS '+$Message)}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Write-Output 'SKIP Protecting a folder needs administrator rights to write its own marker value';return}
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$local=[Environment]::GetFolderPath('LocalApplicationData')
$data=Join-Path $local ('RooDataFix-gate-'+$id)
$operations=Join-Path $data 'operations'
$hostDirectory=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-gate-host-'+$id)
$markerKey='SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
function Invoke-Host([string]$Action,[hashtable]$Fields){
    $request=@{schemaVersion=1;repoRoot=$repoRoot}
    foreach($key in $Fields.Keys){$request[$key]=$Fields[$key]}
    $text=@(($request|ConvertTo-Json -Depth 8 -Compress)|& $DotNetPath (Join-Path $hostDirectory 'Optimizer.Host.dll') $Action '-') -join "`n"
    $result=$text|ConvertFrom-Json
    return [pscustomobject]@{ok=($result.status -eq 'completed');message=[string]$result.error.message}
}
try {
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -o $hostDirectory|Out-Null
    if($LASTEXITCODE -ne 0){throw 'Optimizer host publish failed'}
    foreach($file in @('process-1\journal.json','game-session-1\session\session.json','cleanup-batch-1\journal.json')){
        $path=Join-Path $operations $file
        [IO.Directory]::CreateDirectory((Split-Path $path))|Out-Null
        [IO.File]::WriteAllText($path,'{}')
    }
    Start-Sleep -Milliseconds 300
    $secured=Invoke-Host 'operations-secure' @{operationsRoot=$operations;confirm=$true}
    Check $secured.ok ('The earlier recovery folder is protected and its journals are carried: '+$secured.message)
    $earlier='saved by an older version'
    $requests=@(
        @{label='process-restore';action='process-restore';fields=@{journalPath=(Join-Path $operations 'process-1\journal.json');confirm=$true}},
        @{label='protected-session-recover';action='protected-session-recover';fields=@{sessionRoot=(Join-Path $operations 'game-session-1\session');operationId='gate';confirm=$true}},
        @{label='cleanup-batch-apply';action='cleanup-batch-apply';fields=@{previewPath=(Join-Path $operations 'cleanup-batch-1\preview.json');reviewHash='00';journalPath=(Join-Path $operations 'cleanup-batch-1\journal.json');confirm=$true}}
    )
    foreach($item in $requests){
        $refused=Invoke-Host $item.action $item.fields
        Check ((-not $refused.ok) -and $refused.message -like ('*'+$earlier+'*')) ($item.label+' refuses a journal carried from before protection and says why: '+$refused.message)
        $accepted=Invoke-Host $item.action ($item.fields+@{acceptEarlierVersion=$true})
        Check ($accepted.message -notlike ('*'+$earlier+'*')) ($item.label+' goes past the confirmation once the user confirmed it: '+$accepted.message)
    }
    Start-Sleep -Milliseconds 300
    $freshPath=Join-Path $operations 'process-2\journal.json'
    [IO.Directory]::CreateDirectory((Split-Path $freshPath))|Out-Null
    [IO.File]::WriteAllText($freshPath,'{}')
    $fresh=Invoke-Host 'process-restore' @{journalPath=$freshPath;confirm=$true}
    Check ($fresh.message -notlike ('*'+$earlier+'*')) ('A journal written after protection needs no confirmation: '+$fresh.message)
} finally {
    $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($markerKey,$true)
    if($key){
        foreach($path in @($data,$operations)){$name=Get-RooIndustriesDataRootMarkerName $path;$key.DeleteValue($name,$false);$key.DeleteValue($name+'|protected-at',$false)}
        $key.Dispose()
    }
    foreach($path in @($data,$hostDirectory)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
    foreach($leftover in @(Get-ChildItem -LiteralPath $local -Directory -Filter ('RooDataFix-gate-'+$id+'*') -ErrorAction SilentlyContinue)){Remove-Item -LiteralPath $leftover.FullName -Recurse -Force}
}
Check (-not(Test-Path -LiteralPath $data) -and -not(Test-Path -LiteralPath $hostDirectory)) 'The scenario removes its folders and marker values'
