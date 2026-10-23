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
function Modules([string]$path){'Import-Module Microsoft.PowerShell.Utility; $global:PSModuleAutoLoadingPreference=''None''; $env:PSModulePath='''+$path.Replace("'","''")+''''}
$hidden=Modules (Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-no-modules-'+[guid]::NewGuid().ToString('N')))
$guarded=[ordered]@{
 'Windows Firewall'=[ordered]@{kind='firewall-profile';target='Public';property='enabled'}
 'Exploit protection'=[ordered]@{kind='mitigations';target='system';property='policy'}
 'Microsoft Defender Antivirus'=[ordered]@{kind='defender';target='system';property='SubmitSamplesConsent'}
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
Write-Host ('PASS Windows versions without a setting''s PowerShell commands read all '+$features.Count+' command-backed kinds, Defender included, as not available')
$setters='Set-NetFirewallProfile','Set-MpPreference','Add-DnsClientDohServerAddress','Set-DnsClientDohServerAddress','Remove-DnsClientDohServerAddress','Set-NetTeredoConfiguration','Enable-MMAgent','Disable-MMAgent','Set-WindowsReservedStorageState','Enable-WindowsOptionalFeature','Disable-WindowsOptionalFeature','Enable-NetAdapterBinding','Disable-NetAdapterBinding','Set-NetAdapterLso','Set-NetAdapterRsc','Set-NetAdapterAdvancedProperty','Set-CimInstance'
$providers=$hidden+[Environment]::NewLine+(($setters|ForEach-Object {'function '+$_+' {[Console]::Out.WriteLine(''FIXTURE SETTER RAN'')}'}) -join [Environment]::NewLine)
foreach($feature in $features){
 $address=$guarded[$feature]
 $request=@{action='write';address=$address;before=@{address=$address;identity=$address.kind+':'+$address.target+':'+$address.property;binding=$address.kind+':'+$address.target;value=$null};after=1}
 $output=Run-Helper $source
 if($output -match 'FIXTURE SETTER RAN' -or ($output|ConvertFrom-Json).error -cne (Unavailable $feature)){throw ('An apply or undo without '+$feature+'''s getter must stop as not available before any setter runs: '+$output)}
}
Write-Host ('PASS applies and undos of all '+$features.Count+' command-backed kinds stop as not available before any setter runs')
$providers=$hidden+@'

$script:consent=1
function Get-MpPreference {[pscustomobject]@{SubmitSamplesConsent=$script:consent}}
function Set-MpPreference {param([int]$SubmitSamplesConsent) $script:consent=$SubmitSamplesConsent}
'@
$defender=$guarded['Microsoft Defender Antivirus']
$request=@{action='write';address=$defender;before=@{address=$defender;identity='defender:system:SubmitSamplesConsent';binding='defender:system';value=1};after=2}
$present=Run-Helper $source
$parsed=$present|ConvertFrom-Json
if($null -ne $parsed.error -or $parsed.value -ne 2){throw ('Windows with the Defender commands must still read and change the Defender row: '+$present)}
Write-Host 'PASS Windows with the Defender commands still reads and changes the Defender row'
$fixture=[IO.Directory]::CreateDirectory((Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-broken-module-'+[guid]::NewGuid().ToString('N')))).FullName
try{
 $module=[IO.Directory]::CreateDirectory((Join-Path $fixture 'BrokenDefender')).FullName
 [IO.File]::WriteAllText((Join-Path $module 'BrokenDefender.psd1'),"@{RootModule='BrokenDefender.psm1';ModuleVersion='1.0';FunctionsToExport=@('Get-MpPreference','Set-MpPreference')}")
 [IO.File]::WriteAllText((Join-Path $module 'BrokenDefender.psm1'),"throw 'The Defender provider dependency could not be loaded.'")
 $providers=Modules $fixture
 $request=@{action='read-batch';addresses=@($defender,[ordered]@{kind='defender';target='system';property='MAPSReporting'})}
 $failed=@((Run-Helper $source) -split "`r?`n" | Where-Object { $_ -match '^ROO_INDUSTRIES_CONTROL \d+ ' } | ForEach-Object { ($_ -replace '^ROO_INDUSTRIES_CONTROL \d+ ','')|ConvertFrom-Json })
 if($failed.Count -ne 2 -or @($failed|Where-Object {[string]$_.error -notlike '*The Defender provider dependency could not be loaded.*' -or [string]$_.error -ceq (Unavailable 'Microsoft Defender Antivirus')}).Count){throw ('Defender reads whose module is installed but fails to load must report the load error, not not available: '+($failed|ConvertTo-Json -Compress))}
 Write-Host 'PASS Defender reads report the load error, not not available, when Defender''s module is installed but fails to load'
}finally{[IO.Directory]::Delete($fixture,$true)}
$getters=@{'firewall-profile'='Get-NetFirewallProfile';'mitigations'='Get-ProcessMitigation';'defender'='Get-MpPreference';'device-power'='Get-PnpDevice';'dns-over-https'='Get-DnsClientDohServerAddress';'teredo'='Get-NetTeredoConfiguration';'memory'='Get-MMAgent';'reserved-storage'='Get-WindowsReservedStorageState';'network-adapter'='Get-NetAdapter'}
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
