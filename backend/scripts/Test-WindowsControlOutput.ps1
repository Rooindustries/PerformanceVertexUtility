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
