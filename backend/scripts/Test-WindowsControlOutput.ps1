$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=[IO.File]::ReadAllText((Join-Path $root 'backend/native/Optimizer.Core/WindowsControls.ps1'))
$address=[ordered]@{kind='dns-over-https';target='203.0.113.253';property='configuration'}
$request=@{action='write';address=$address;before=@{address=$address;identity='dns-over-https:203.0.113.253:configuration';binding='dns-over-https:203.0.113.253';value=$null};after=@{template='https://fixture.invalid/dns-query';allowFallback=$false;autoUpgrade=$true}}
$providers=@'
$script:entry=$null
function Get-DnsClientDohServerAddress {if($null -ne $script:entry){$script:entry}}
function Add-DnsClientDohServerAddress {
 param($ServerAddress,$DohTemplate,$AllowFallbackToUdp,$AutoUpgrade)
 $script:entry=[pscustomobject]@{ServerAddress=$ServerAddress;DohTemplate=$DohTemplate;AllowFallbackToUdp=$AllowFallbackToUdp;AutoUpgrade=$AutoUpgrade}
 $script:entry
}
'@
function Run-Helper([string]$body,[int]$timeout=15000){
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('$body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ROO_INDUSTRIES_OUTPUT_TEST)); & ([ScriptBlock]::Create($body))'))
 $start.EnvironmentVariables['ROO_INDUSTRIES_OUTPUT_TEST']=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($providers+[Environment]::NewLine+$body))
 $start.EnvironmentVariables['ROO_INDUSTRIES_CONTROL_REQUEST']=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Depth 10 -Compress)))
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start
 try{$process.Start()|Out-Null;$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit($timeout)){$process.Kill();$process.WaitForExit();throw 'Helper fixture timed out'};[Threading.Tasks.Task]::WaitAll(@($stdout,$stderr));if($process.ExitCode -ne 0){throw $stderr.Result};return $stdout.Result}finally{$process.Dispose()}
}
$fixed=Run-Helper $source
$parsed=$fixed|ConvertFrom-Json
if($null -ne $parsed.error -or $parsed.value.template -cne $request.after.template -or $parsed.value.autoUpgrade -ne $true -or $parsed.value.allowFallback -ne $false){throw ('Setter output changed the reviewed helper result: '+$fixed)}
Write-Host 'PASS native setter output cannot contaminate the structured readback'
$wrong=$source.Replace('$null=Write-Control $request.address $request.after','Write-Control $request.address $request.after')
if($wrong -ceq $source){throw 'Negative control did not modify the output boundary'}
$rejected=$false
try{$null=(Run-Helper $wrong)|ConvertFrom-Json}catch{$rejected=$true}
if(-not $rejected){throw 'Negative control accepted mixed formatter output and JSON'}
Write-Host 'PASS the original mixed-output behavior fails the same JSON boundary'
$providers=@'
function Get-DnsClientDohServerAddress {[pscustomobject]@{ServerAddress='203.0.113.253';DohTemplate='https://fixture.invalid/dns-query';AllowFallbackToUdp=$false;AutoUpgrade=$true}}
function Get-NetTeredoConfiguration {param($PolicyStore) [Console]::Out.WriteLine('fixture output from the second read'); [pscustomobject]@{Type='Default'}}
'@
$request=@{action='read-batch';addresses=@([ordered]@{kind='dns-over-https';target='203.0.113.253';property='configuration'},[ordered]@{kind='teredo';target='system';property='type'},[ordered]@{kind='dns-over-https';target='203.0.113.254';property='configuration'})}
$lines=@((Run-Helper $source) -split "`r?`n" | Where-Object { $_ })
$results=@($lines | Where-Object { $_ -match '^ROO_INDUSTRIES_CONTROL \d+ ' })
if($results.Count -ne 3 -or $results[0] -notmatch '^ROO_INDUSTRIES_CONTROL 0 ' -or $results[1] -notmatch '^ROO_INDUSTRIES_CONTROL 1 ' -or $results[2] -notmatch '^ROO_INDUSTRIES_CONTROL 2 '){throw ('Batch results are not framed in request order: '+($lines -join ' | '))}
$first=($results[0] -replace '^ROO_INDUSTRIES_CONTROL 0 ','')|ConvertFrom-Json;$third=($results[2] -replace '^ROO_INDUSTRIES_CONTROL 2 ','')|ConvertFrom-Json
if($first.value.template -cne 'https://fixture.invalid/dns-query' -or $null -ne $third.value -or $third.binding -cne 'dns-over-https:203.0.113.254'){throw ('Batch reads changed the per-address values: '+($results -join ' | '))}
$firstIndex=[array]::IndexOf($lines,$results[0]);$secondIndex=[array]::IndexOf($lines,$results[1])
$stray=@($lines | Where-Object { $_ -notmatch '^ROO_INDUSTRIES_CONTROL \d+ ' })
if($stray.Count -lt 1){throw ('The fixture output line did not reach standard output: '+($lines -join ' | '))}
if(@($stray | Where-Object { [array]::IndexOf($lines,$_) -lt $firstIndex -or [array]::IndexOf($lines,$_) -gt $secondIndex }).Count){throw ('Output from one batch read leaked next to another address: '+($lines -join ' | '))}
Write-Host ('PASS batched reads keep request order and keep each read''s stray output before its own result ('+$stray.Count+' stray lines before the second result)')
function Modules([string]$path){'Import-Module Microsoft.PowerShell.Utility,CimCmdlets; $global:PSModuleAutoLoadingPreference=''None''; $env:PSModulePath='''+$path.Replace("'","''")+''''}
$hidden=Modules (Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-no-modules-'+[guid]::NewGuid().ToString('N')))
$guarded=[ordered]@{
 'Windows Firewall'=[ordered]@{kind='firewall-profile';target='Public';property='enabled'}
 'Exploit protection'=[ordered]@{kind='mitigations';target='system';property='policy'}
 'Device power management'=[ordered]@{kind='device-power';target='non-network';property='enabled'}
 'Encrypted DNS'=[ordered]@{kind='dns-over-https';target='203.0.113.253';property='configuration'}
 'Teredo'=[ordered]@{kind='teredo';target='system';property='type'}
 'Memory compression'=[ordered]@{kind='memory';target='system';property='compression'}
 'Reserved storage'=[ordered]@{kind='reserved-storage';target='system';property='enabled'}
 'Windows feature servicing'=[ordered]@{kind='windows-feature';target='Microsoft-Hyper-V-All';property='enabled'}
 'Network adapter configuration'=[ordered]@{kind='network-adapter';target='primary';property='ipv6-binding'}
}
function Unavailable([string]$feature){$feature+' is not available with this Windows version.'}
$providers=$hidden
$request=@{action='read-batch';addresses=@($guarded.Values)}
$missing=@((Run-Helper $source) -split "`r?`n" | Where-Object { $_ -match '^ROO_INDUSTRIES_CONTROL \d+ ' } | ForEach-Object { ($_ -replace '^ROO_INDUSTRIES_CONTROL \d+ ','')|ConvertFrom-Json })
$features=@($guarded.Keys)
$wrong=@(for($index=0;$index -lt $features.Count;$index++){if($missing.Count -le $index -or $missing[$index].error -cne (Unavailable $features[$index])){$features[$index]+': '+$(if($missing.Count -gt $index){[string]$missing[$index].error}else{'no result'})}})
if($missing.Count -ne $features.Count -or $wrong.Count){throw ('A Windows version without a setting''s PowerShell commands must read that row as not available: '+($wrong -join ' | '))}
Write-Host ('PASS Windows versions without a setting''s PowerShell commands read all '+$features.Count+' command-backed kinds as not available')
$setters='Set-NetFirewallProfile','Add-DnsClientDohServerAddress','Set-DnsClientDohServerAddress','Remove-DnsClientDohServerAddress','Set-NetTeredoConfiguration','Enable-MMAgent','Disable-MMAgent','Set-WindowsReservedStorageState','Enable-WindowsOptionalFeature','Disable-WindowsOptionalFeature','Enable-NetAdapterBinding','Disable-NetAdapterBinding','Set-NetAdapterLso','Set-NetAdapterRsc','Set-NetAdapterAdvancedProperty','Set-CimInstance','Invoke-CimMethod'
$providers=$hidden+[Environment]::NewLine+(($setters|ForEach-Object {'function '+$_+' {[Console]::Out.WriteLine(''FIXTURE SETTER RAN'')}'}) -join [Environment]::NewLine)
foreach($feature in $features){
 $address=$guarded[$feature]
 $request=@{action='write';address=$address;before=@{address=$address;identity=$address.kind+':'+$address.target+':'+$address.property;binding=$address.kind+':'+$address.target;value=$null};after=1}
 $output=Run-Helper $source
 if($output -match 'FIXTURE SETTER RAN' -or ($output|ConvertFrom-Json).error -cne (Unavailable $feature)){throw ('An apply or undo without '+$feature+'''s getter must stop as not available before any setter runs: '+$output)}
}
Write-Host ('PASS applies and undos of all '+$features.Count+' command-backed kinds stop as not available before any setter runs')
$defender=[ordered]@{kind='defender';target='system';property='SubmitSamplesConsent'}
$notInstalled='Microsoft Defender Antivirus is not installed.'
$stopped='Microsoft Defender Antivirus is not available with its service stopped. Windows stops it when another antivirus takes over.'
$service=Get-Service -Name WinDefend -ErrorAction SilentlyContinue
$real=if($null -eq $service){$notInstalled}elseif($service.Status -eq 'Stopped'){$stopped}else{[string][int](Get-MpPreference).SubmitSamplesConsent}
function DefenderRead([int]$timeout=60000){$read=(Run-Helper $source $timeout)|ConvertFrom-Json;if($null -ne $read.error){[string]$read.error}else{[string]$read.value}}
$fixture=[IO.Directory]::CreateDirectory((Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-broken-module-'+[guid]::NewGuid().ToString('N')))).FullName
$state=Join-Path $fixture 'defender.json'
try{
 $module=[IO.Directory]::CreateDirectory((Join-Path $fixture 'BrokenDefender')).FullName
 [IO.File]::WriteAllText((Join-Path $module 'BrokenDefender.psd1'),"@{RootModule='BrokenDefender.psm1';ModuleVersion='1.0';FunctionsToExport=@('Get-MpPreference','Set-MpPreference')}")
 [IO.File]::WriteAllText((Join-Path $module 'BrokenDefender.psm1'),"throw 'The Defender provider dependency could not be loaded.'")
 $broken=Modules $fixture
 $request=@{action='read';address=$defender}
 $providers=$hidden;$withoutCommands=DefenderRead
 $providers=$broken;$withBrokenModule=DefenderRead
 if($withoutCommands -cne $real -or $withBrokenModule -cne $real){throw ('The Defender row must read this PC''s real state ('+$real+') through Windows'' Defender provider when Defender''s PowerShell commands are missing or fail to load: '+$withoutCommands+' | '+$withBrokenModule)}
 Write-Host ('PASS the Defender row reads this PC''s real state ('+$real+') through Windows'' Defender provider when Defender''s PowerShell commands are missing and when their module fails to load')
 $cim=@'
function Get-CimInstance {
 param([string]$Namespace,[string]$ClassName,[string]$Filter)
 $fixture=[IO.File]::ReadAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER)|ConvertFrom-Json
 if($ClassName -ceq 'Win32_Service' -and $Filter -ceq "Name='WinDefend'"){if($fixture.service){[pscustomobject]@{Name='WinDefend';State=[string]$fixture.service}};return}
 if($Namespace -cne 'root/Microsoft/Windows/Defender' -or $ClassName -cne 'MSFT_MpPreference'){throw ('Unexpected CIM read: '+$Namespace+' '+$ClassName+' '+$Filter)}
 if($fixture.provider){throw [string]$fixture.provider}
 [pscustomobject]@{SubmitSamplesConsent=[byte]$fixture.consent}
}
function Invoke-CimMethod {
 param([string]$Namespace,[string]$ClassName,[string]$MethodName,[hashtable]$Arguments)
 $fixture=[IO.File]::ReadAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER)|ConvertFrom-Json
 $fixture.calls=[string]$fixture.calls+$Namespace+' '+$ClassName+'.'+$MethodName+' '+(@($Arguments.Keys|Sort-Object|ForEach-Object {$_+'='+$Arguments[$_]+':'+$Arguments[$_].GetType().Name}) -join ',')+';'
 if([int]$fixture.result -le 0 -and -not $fixture.stuck){$fixture.consent=[int]$Arguments['SubmitSamplesConsent']}
 [IO.File]::WriteAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER,($fixture|ConvertTo-Json -Compress))
 if([int]$fixture.result -lt 0){[pscustomobject]@{PSComputerName=$null}}else{[pscustomobject]@{ReturnValue=[uint32]$fixture.result}}
}
'@
 $env:ROO_INDUSTRIES_FIXTURE_DEFENDER=$state
 function Defender($provider,$service,[int]$consent=1,[int]$result=-1,[bool]$stuck=$false){[IO.File]::WriteAllText($state,([ordered]@{consent=$consent;provider=$provider;service=$service;result=$result;stuck=$stuck;calls=''}|ConvertTo-Json -Compress))}
 function Saved{[IO.File]::ReadAllText($state)|ConvertFrom-Json}
 function Change([int]$before,[int]$after){$script:request=@{action='write';address=$defender;before=@{address=$defender;identity='defender:system:SubmitSamplesConsent';binding='defender:system';value=$before};after=$after};(Run-Helper $source)|ConvertFrom-Json}
 $set='root/Microsoft/Windows/Defender MSFT_MpPreference.Set SubmitSamplesConsent='
 $providers=$hidden+[Environment]::NewLine+$cim
 Defender $null 'Running' 1
 $applied=Change 1 2;$afterApply=Saved
 $providers=$broken+[Environment]::NewLine+$cim
 $undone=Change 2 1;$afterUndo=Saved
 if($null -ne $applied.error -or $applied.value -ne 2 -or $afterApply.consent -ne 2 -or $afterApply.calls -cne ($set+'2:Byte;') -or $null -ne $undone.error -or $undone.value -ne 1 -or $afterUndo.consent -ne 1 -or $afterUndo.calls -cne ($set+'2:Byte;'+$set+'1:Byte;')){throw ('Without Defender''s PowerShell commands, the Defender row must apply and undo through MSFT_MpPreference.Set and read back the result: '+($applied|ConvertTo-Json -Compress)+' '+($afterApply|ConvertTo-Json -Compress)+' | '+($undone|ConvertTo-Json -Compress)+' '+($afterUndo|ConvertTo-Json -Compress))}
 Write-Host 'PASS without Defender''s PowerShell commands the Defender row applies and undoes through MSFT_MpPreference.Set, one byte value each, and reads back the result'
 Defender $null 'Running' 1 2
 $refused=Change 1 2;$afterRefusal=Saved
 if([string]$refused.error -notlike '*Microsoft Defender Antivirus refused the change*' -or $afterRefusal.consent -ne 1 -or $afterRefusal.calls -cne ($set+'2:Byte;')){throw ('A Defender change the provider refuses must fail with its result: '+($refused|ConvertTo-Json -Compress)+' '+($afterRefusal|ConvertTo-Json -Compress))}
 Write-Host 'PASS a Defender change the provider refuses fails with its result'
 Defender $null 'Running' 1 -1 $true
 $kept=Change 1 2;$afterKept=Saved
 if([string]$kept.error -notlike '*Microsoft Defender Antivirus kept its previous sample-submission choice*' -or $afterKept.consent -ne 1){throw ('A Defender change Windows does not take must fail instead of reporting success: '+($kept|ConvertTo-Json -Compress)+' '+($afterKept|ConvertTo-Json -Compress))}
 Write-Host 'PASS a Defender change Windows does not take fails instead of reporting success'
 $providers=$hidden+[Environment]::NewLine+$cim
 $lacking=@(
  @{name='Defender removed';provider='Invalid namespace';service=$null;expected=$notInstalled},
  @{name='Defender service stopped';provider='Operation failed with the following error: 0x800106ba';service='Stopped';expected=$stopped},
  @{name='Defender running with a failing provider';provider='The Defender provider failed: 0x80004005';service='Running';expected='The Defender provider failed: 0x80004005'}
 )
 foreach($case in $lacking){
  Defender $case.provider $case.service 1
  $request=@{action='read';address=$defender};$read=DefenderRead
  $write=Change 1 2;$after=Saved
  if($read -cne $case.expected -or [string]$write.error -cne $case.expected -or $after.calls -or $after.consent -ne 1){throw ($case.name+' must read and stop every change with "'+$case.expected+'" before any Defender write: '+$read+' | '+($write|ConvertTo-Json -Compress)+' | '+($after|ConvertTo-Json -Compress))}
 }
 Write-Host 'PASS a PC whose Defender is removed reads not installed, a stopped Defender service reads not available, a running Defender whose provider fails keeps its own error, and none of them reaches a Defender write'
}finally{$env:ROO_INDUSTRIES_FIXTURE_DEFENDER=$null;[IO.Directory]::Delete($fixture,$true)}
$getters=@{'firewall-profile'='Get-NetFirewallProfile';'mitigations'='Get-ProcessMitigation';'device-power'='Get-PnpDevice';'dns-over-https'='Get-DnsClientDohServerAddress';'teredo'='Get-NetTeredoConfiguration';'memory'='Get-MMAgent';'reserved-storage'='Get-WindowsReservedStorageState';'network-adapter'='Get-NetAdapter'}
$providers=''
$local=@($guarded.Values|Where-Object { $_.kind -ne 'windows-feature' })
$request=@{action='read-batch';addresses=$local}
$reads=@((Run-Helper $source 120000) -split "`r?`n" | Where-Object { $_ -match '^ROO_INDUSTRIES_CONTROL \d+ ' } | ForEach-Object { ($_ -replace '^ROO_INDUSTRIES_CONTROL \d+ ','')|ConvertFrom-Json })
if($reads.Count -ne $local.Count){throw ('Every read-only check on this PC must return a result: '+$reads.Count+' of '+$local.Count)}
$wrong=@(for($index=0;$index -lt $local.Count;$index++){
 $kind=$local[$index].kind;$read=$reads[$index]
 Write-Host ('  '+$kind+': '+$(if($null -ne $read.error){'error '+$read.error}else{'read'}))
 if((Get-Command $getters[$kind] -ErrorAction SilentlyContinue) -and [string]$read.error -like '* is not available with this Windows version.'){$kind}
})
if($wrong.Count){throw ('A PC that has a setting''s PowerShell commands must not read it as not available: '+($wrong -join ', '))}
Write-Host ('PASS this PC reads every command-backed kind whose commands it has, without calling it not available ('+$local.Count+' read-only reads)')
