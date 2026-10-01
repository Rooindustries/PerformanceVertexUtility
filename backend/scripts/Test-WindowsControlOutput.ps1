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
function Run-Helper([string]$body){
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('$body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ROO_INDUSTRIES_OUTPUT_TEST)); & ([ScriptBlock]::Create($body))'))
 $start.EnvironmentVariables['ROO_INDUSTRIES_OUTPUT_TEST']=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($providers+[Environment]::NewLine+$body))
 $start.EnvironmentVariables['ROO_INDUSTRIES_CONTROL_REQUEST']=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Depth 10 -Compress)))
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start
 try{$process.Start()|Out-Null;$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit(15000)){$process.Kill();$process.WaitForExit();throw 'Helper fixture timed out'};[Threading.Tasks.Task]::WaitAll(@($stdout,$stderr));if($process.ExitCode -ne 0){throw $stderr.Result};return $stdout.Result}finally{$process.Dispose()}
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
