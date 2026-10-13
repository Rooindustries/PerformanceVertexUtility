param([Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][string]$ExpectedMachine,
 [Parameter(Mandatory)][DateTimeOffset]$StartUtc,
 [Parameter(Mandatory)][DateTimeOffset]$EndUtc)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne $ExpectedMachine){throw 'Wrong evidence machine.'}
if($EndUtc -le $StartUtc -or ($EndUtc-$StartUtc).TotalHours -gt 1){throw 'Supply an increasing evidence window no longer than one hour.'}
. (Join-Path $PSScriptRoot 'Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'restart-evidence' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
$OutRoot=New-HarnessEvidenceDirectory $OutRoot 'restart-evidence'
$utf8=[Text.UTF8Encoding]::new($false)
function Save([string]$name,$value){Write-HarnessResult $OutRoot $name $value|Out-Null}
function Record($event){
 $xml=[xml]$event.ToXml();$fields=@{}
 foreach($field in @($xml.Event.EventData.Data)){if($field.Name){$fields[[string]$field.Name]=[string]$field.'#text'}}
 @{id=$event.Id;recordId=$event.RecordId;provider=$event.ProviderName;utc=$event.TimeCreated.ToUniversalTime().ToString('o');level=$event.LevelDisplayName;processId=$event.ProcessId;userId=[string]$event.UserId;fields=$fields;message=try{$event.Message}catch{$_.Exception.Message};xml=$event.ToXml()}
}
function Query([string]$log,[int[]]$ids=@()){
 try{$info=Get-WinEvent -ListLog $log -ErrorAction Stop}catch{return @{log=$log;status='unavailable';error=$_.Exception.Message;events=@()}}
 $result=@{log=$log;enabled=$info.IsEnabled;recordCount=$info.RecordCount;maximumBytes=$info.MaximumSizeInBytes;status='read';events=@()}
 try{$result.oldest=(Get-WinEvent -LogName $log -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated.ToUniversalTime().ToString('o')}catch{$result.oldest=$null}
 try{$result.newest=(Get-WinEvent -LogName $log -MaxEvents 1 -ErrorAction Stop).TimeCreated.ToUniversalTime().ToString('o')}catch{$result.newest=$null}
 $start=$StartUtc.UtcDateTime.ToString('o');$end=$EndUtc.UtcDateTime.ToString('o')
 $condition="TimeCreated[@SystemTime >= '$start' and @SystemTime <= '$end']"
 if($ids.Count){$condition='('+(@($ids|ForEach-Object {'EventID='+$_}) -join ' or ')+') and '+$condition}
 $result.query='*[System['+$condition+']]'
 try{$result.events=@(Get-WinEvent -LogName $log -FilterXPath $result.query -ErrorAction Stop|Sort-Object TimeCreated,RecordId|ForEach-Object {Record $_})}
 catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){$result.status='no matching events'}else{$result.status='query failed';$result.error=$_.Exception.Message}}
 return $result
}
$tz=[TimeZoneInfo]::Local
$logs=@();$windowLines=@();$restartLines=@()
foreach($root in 'RooOptimizationSuite','RooIndustriesOptimizationSuite'){
 $folder=Join-Path $env:LOCALAPPDATA ($root+'\logs')
 foreach($file in @(Get-ChildItem $folder -File -ErrorAction SilentlyContinue|Where-Object Name -like 'app*')){
  $destination=Get-HarnessOutputPath $OutRoot ($root+'-'+$file.Name)
  Copy-HarnessFile $file.FullName $destination 'log-copy'|Out-Null
  $logs+=@(@{root=$root;path=$file.FullName;copy=$destination;bytes=$file.Length;sha256=(Get-HarnessFileSha256 $destination)})
  $lineNumber=0;$stamp=$null
  foreach($line in [IO.File]::ReadLines($destination)){
   $lineNumber++
   if($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) '){
    $local=[DateTime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
    $stamp=[TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($local,[DateTimeKind]::Unspecified),$tz)
   }
   $row=@{path=$file.FullName;copy=$destination;line=$lineNumber;utc=if($stamp){$stamp.ToString('o')}else{$null};text=$line}
   if($stamp -and $stamp -ge $StartUtc.UtcDateTime -and $stamp -le $EndUtc.UtcDateTime){$windowLines+=@($row)}
   if($line -match '(?i)restart'){$restartLines+=@($row)}
  }
 }
}
Save 'app-log-files.json' $logs
Save 'app-window-lines.json' $windowLines
Save 'app-restart-lines.json' $restartLines
$system=Query 'System' @(1074,1076,6006,6008,41,109);Save 'system-events.json' $system
$security=Query 'Security' @(4688);Save 'security-4688-window.json' $security
$shutdown=@($security.events|Where-Object {$_.fields.NewProcessName -match '(?i)\\shutdown\.exe$'})
$parents=@($shutdown|ForEach-Object {$_.fields.ProcessId})
Save 'security-shutdown-and-parent.json' @{shutdown=$shutdown;parents=@($security.events|Where-Object {$_.fields.NewProcessId -in $parents})}
$audit=Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\auditpol.exe') '/get /category:* /r' 'audit-policy';$auditExit=0
New-HarnessText (Get-HarnessOutputPath $OutRoot 'audit-policy.csv') $audit 'audit-evidence'|Out-Null
$task=Query 'Microsoft-Windows-TaskScheduler/Operational';Save 'task-scheduler-events.json' $task
$ssh=Query 'OpenSSH/Operational';Save 'openssh-operational-events.json' $ssh
$sshAdmin=Query 'OpenSSH/Admin';Save 'openssh-admin-events.json' $sshAdmin
$powershell=Query 'Microsoft-Windows-PowerShell/Operational' @(4103,4104)
$matching=@($powershell.events|Where-Object {($_.message+' '+$_.xml) -match '(?i)shutdown|restart'})
Save 'powershell-shutdown-restart-events.json' @{log=$powershell.log;enabled=$powershell.enabled;oldest=$powershell.oldest;newest=$powershell.newest;status=$powershell.status;error=$powershell.error;windowEventCount=@($powershell.events).Count;events=$matching}
Save 'receipt.json' @{machine=$env:COMPUTERNAME;collectedAtUtc=[DateTime]::UtcNow.ToString('o');startUtc=$StartUtc.ToUniversalTime().ToString('o');endUtc=$EndUtc.ToUniversalTime().ToString('o');timeZone=@{id=$tz.Id;baseUtcOffset=[string]$tz.BaseUtcOffset;displayName=$tz.DisplayName};auditPolicyExit=$auditExit;appFiles=$logs.Count;appWindowLines=$windowLines.Count;appRestartLines=$restartLines.Count;systemEvents=@($system.events).Count;securityEvents=@($security.events).Count;shutdownEvents=$shutdown.Count;taskEvents=@($task.events).Count;sshEvents=@($ssh.events).Count;sshAdminEvents=@($sshAdmin.events).Count;powerShellWindowEvents=@($powershell.events).Count;powerShellMatchingEvents=$matching.Count}

Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
