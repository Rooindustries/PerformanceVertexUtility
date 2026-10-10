param([string[]]$Scenario=@('all'),[string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[string]$EvidencePath='',[string]$HostDirectory='',[switch]$List,[switch]$ContinueAfterFailure)
$ErrorActionPreference='Stop'
$script:continueAfterFailure=[bool]$ContinueAfterFailure
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
. (Join-Path $PSScriptRoot 'GovernorScenarios\Scenario.Common.ps1')
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'GovernorScenarios') -Filter '*.ps1' -File|Where-Object {$_.Name -ne 'Scenario.Common.ps1'}|Sort-Object Name)){. $file.FullName}
$available=@(Get-Command -CommandType Function -Name 'Test-Scenario*'|ForEach-Object {$_.Name.Substring(13)}|Sort-Object)
if($List){$available;return}
$selected=if($Scenario -contains 'all'){$available}else{@($Scenario|ForEach-Object {$_ -split ','}|Where-Object {$_})}
foreach($name in $selected){if($available -notcontains $name){throw ('Unknown scenario '+$name+'. Known: '+($available -join ', '))}}
if(-not $DotNetPath){$DotNetPath=(Get-Command dotnet.exe -ErrorAction Stop).Source}
$env:DOTNET_ROOT=Split-Path $DotNetPath -Parent
$scriptsRoot=$PSScriptRoot
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$work=Join-Path (Get-RooIndustriesLocalAppData) ('rgs-'+[Guid]::NewGuid().ToString('N').Substring(0,16))
[IO.Directory]::CreateDirectory($work)|Out-Null
$workAcl=[Security.AccessControl.DirectorySecurity]::new()
$workAcl.SetAccessRuleProtection($true,$false)
$workAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach($sid in @('S-1-5-32-544','S-1-5-18')){$workAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
$workAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
(Get-Item -LiteralPath $work).SetAccessControl($workAcl)
[IO.File]::WriteAllText((Join-Path $work 'fixture.marker'),$work)
if(-not $HostDirectory){
    $HostDirectory=Join-Path $work 'host'
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.Host\Optimizer.Host.csproj') -c Release --self-contained false -p:GovernorTestHooks=true -o $HostDirectory | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Policy host publish failed.'}
    & $DotNetPath publish (Join-Path $repoRoot 'backend\native\Optimizer.SessionHost\Optimizer.SessionHost.csproj') -c Release -r win-x64 --self-contained true -p:GovernorTestHooks=true -o (Join-Path $HostDirectory 'session') | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Session host publish failed.'}
}
$hostDirectory=$HostDirectory
$probeDirectory=Join-Path $work 'probe'
Initialize-ScenarioFixtures
$sourceHashes=[ordered]@{}
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $scriptsRoot 'GovernorScenarios') -File)+@(Get-Item -LiteralPath $PSCommandPath,(Join-Path $scriptsRoot 'BrandCompatibility.Common.ps1'),(Join-Path $hostDirectory 'Optimizer.Host.dll'),(Join-Path $hostDirectory 'Optimizer.Core.dll'))){$sourceHashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
$evidence=[ordered]@{sourceHashes=$sourceHashes;startedAtUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;scenarios=[ordered]@{}}
$failed=0
try {
    foreach($name in $selected){
        $script:current=[ordered]@{passed=$true;error=$null;checks=New-Object System.Collections.Generic.List[object];measurements=[ordered]@{};startedAtUtc=[DateTime]::UtcNow.ToString('o')}
        $evidence.scenarios[$name]=$script:current
        Write-Output ('SCENARIO '+$name)
        Enter-Scenario $name
        try {& ('Test-Scenario'+$name)}
        catch {
            $script:current.passed=$false;$script:current.error=$_.Exception.Message
            Write-Output ('FAIL '+$name+': '+$_.Exception.Message)
            Write-Output ($_.ScriptStackTrace -split "`n"|Select-Object -First 3)
        }
        finally {
            try {Exit-Scenario} catch {$script:current.passed=$false;Write-Output ('FAIL cleanup of '+$name+': '+$_.Exception.Message)}
        }
        if(-not $script:current.passed){$failed++}
        Write-Output ('RESULT '+$name+' '+$(if($script:current.passed){'PASSED'}else{'FAILED'}))
    }
} finally {
    $evidence.finishedAtUtc=[DateTime]::UtcNow.ToString('o')
    if($EvidencePath){[IO.File]::WriteAllText($EvidencePath,($evidence|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
    foreach($task in @(Get-ScheduledTask -TaskName 'Roo Industries Protected Session *' -ErrorAction SilentlyContinue|Where-Object {@($_.Actions|Where-Object {([string]$_.Execute).StartsWith($work,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0})){Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $work){Remove-ScenarioTree $work}
}
Write-Output ('SUMMARY '+($selected.Count-$failed)+' of '+$selected.Count+' scenarios passed')
if($failed -gt 0){exit 1}
