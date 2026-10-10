param([string]$ExpectedComputer='SERVI-WINDOWS-D')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ine $ExpectedComputer -or $ExpectedComputer -ine 'SERVI-WINDOWS-D'){throw 'Unexpected Windows target; audit stopped.'}
$cpu=@(Get-CimInstance Win32_Processor|ForEach-Object Name)
$gpu=@(Get-CimInstance Win32_VideoController|ForEach-Object Name)
if(($cpu -join '|') -notmatch 'i5-14600K' -or ($gpu -join '|') -notmatch 'RX 9070 XT'){throw 'Unexpected hardware; audit stopped.'}
$backup=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'roo-industries-backup'
$expectedFiles=@{
 'machine-state.json'='BE914AC3750C09734FE545DBB22C1346590E0DB0CD650B41B4FDC64E6653AF85'
 'hklm-roo-industries.reg'='CADE38C883749C74396FCA39F02C23E34F1373F8FAB8A749C509C4BD0E7ECD94'
 'RooIndustriesOptimizationSuite.fingerprint.txt'='4F1EFC03D883E46E3900A4C22F1F80D33D66BB39AA64E6A3E967005D337E8B50'
 'RooOptimizationSuite.fingerprint.txt'='EAA738F05AB54139118B4BBD15E101024B3337FE6723C39193A655AFCDCFF1ED'
 'tweak-state.reg'='9473FC0F440E8D9BE7A77123D2D05D587C62479C95AF08C7F09A98FDED89C316'
}
if((Get-Item -LiteralPath $backup -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The historical backup directory is a reparse point.'}
foreach($n in $expectedFiles.Keys){$p=Join-Path $backup $n;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw 'A required historical backup file is missing.'};if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A historical backup file is a reparse point.'};if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -cne $expectedFiles[$n]){throw 'A historical backup file hash changed; preserve both states.'}}

$backup=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'roo-industries-backup'
$local=[Environment]::GetFolderPath('LocalApplicationData')
function Hash-Text([string]$text){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','')}finally{$sha.Dispose()}}
function Get-RecoveryTree([string]$path,[string]$fingerprint){
 if(-not(Test-Path -LiteralPath $path)){return @{exists=$false}}
 $root=Get-Item -LiteralPath $path -Force
 $items=[Collections.Generic.List[object]]::new();$queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue($root)
 $reparse=0
 while($queue.Count){$item=$queue.Dequeue();$items.Add($item);if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$reparse++;continue};if($item.PSIsContainer){foreach($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)){$queue.Enqueue($child)}}}
 if($reparse){return @{exists=$true;reparseCount=$reparse;items=$items.Count;refused=$true}}
 $meta=@();$full=@();$byteCount=0;$files=0;$dirs=0;$latest=[DateTime]::MinValue
 foreach($item in $items){$rel=$item.FullName.Substring($root.FullName.Length);$acl=(Get-Acl -LiteralPath $item.FullName).Sddl;$auditAcl=(Get-Acl -LiteralPath $item.FullName -Audit).Sddl;if($auditAcl -ne $acl){throw 'SACL differs from historical metadata; keep both states for inspection.'};$body=if($item.PSIsContainer){$dirs++;'dir'}else{$files++;$byteCount+=$item.Length;if($item.LastWriteTimeUtc -gt $latest){$latest=$item.LastWriteTimeUtc};[string]$item.Length};$line=$rel+'|'+$body+'|'+$item.LastWriteTimeUtc.ToString('o')+'|'+[string]$item.Attributes+'|'+$acl;$meta+=$line;$full+=$line+$(if(-not$item.PSIsContainer){'|sha256='+(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}else{''})}
 $meta=@($meta|Sort-Object);$full=@($full|Sort-Object)
 $diff=if($fingerprint -and (Test-Path -LiteralPath $fingerprint)){@(Compare-Object @(Get-Content -LiteralPath $fingerprint -Encoding UTF8) $meta).Count}else{$null}
 @{exists=$true;reparseCount=0;files=$files;directories=$dirs;bytes=$byteCount;latestFileWriteUtc=$latest.ToString('o');metadataSha256=(Hash-Text ($meta -join "`n"));currentBytesAndMetadataSha256=(Hash-Text ($full -join "`n"));historicalMetadataDifferences=$diff;aclReadable=$true}
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$state=Get-Content -LiteralPath (Join-Path $backup 'machine-state.json') -Raw|ConvertFrom-Json

$trees=@{}
foreach($name in 'RooIndustriesOptimizationSuite','RooOptimizationSuite','RooIndustriesOptimizationSuite.Timer'){
 $trees[$name]=@{saved=(Get-RecoveryTree (Join-Path $backup $name) (Join-Path $backup ($name+'.fingerprint.txt')));live=(Get-RecoveryTree (Join-Path $local $name) (Join-Path $backup ($name+'.fingerprint.txt')))}
}
$backupFiles=@(Get-ChildItem -LiteralPath $backup -File -Force|ForEach-Object {if($_.Name -in @('machine-state.json','backup-machine-state.json','hklm-roo-industries.reg','tweak-state.reg','RooIndustriesOptimizationSuite.fingerprint.txt','RooOptimizationSuite.fingerprint.txt')){@{name=$_.Name;length=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash;lastWriteUtc=$_.LastWriteTimeUtc.ToString('o');reparse=[bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}}})
$app='C:\Program Files\Roo Industries\Optimization Suite'
$installed=@{}
foreach($relative in 'app\RooIndustries.OptimizationSuite.App.dll','backend\bin\optimizer\Optimizer.Host.dll','unins000.exe','unins000.dat','backend\bin\optimizer\hostpolicy.dll'){
 $p=Join-Path $app $relative;if(Test-Path -LiteralPath $p){$f=Get-Item -LiteralPath $p -Force;$installed[$relative]=@{sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash;length=$f.Length;lastWriteUtc=$f.LastWriteTimeUtc.ToString('o');reparse=[bool]($f.Attributes -band [IO.FileAttributes]::ReparsePoint);aclSha256=(Hash-Text (Get-Acl -LiteralPath $p).Sddl);signatureStatus=[string](Get-AuthenticodeSignature -LiteralPath $p).Status}}
}
$tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -match 'RooIndustries|OptimizationSuite|Protected Session'}|ForEach-Object {@{name=$_.TaskPath+$_.TaskName;state=[string]$_.State;xmlSha256=(Hash-Text (Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath));principalMatchesCurrentSid=($_.Principal.UserId -eq $identity.User.Value -or $_.Principal.UserId -eq $identity.Name);actions=@($_.Actions|ForEach-Object {@{execute=$_.Execute;argumentsSha256=(Hash-Text $_.Arguments)}})}})
$uninstall=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'|Where-Object {$_.PSChildName -like '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}*' -or $_.PSChildName -match 'RooIndustries|OptimizationSuite'}|ForEach-Object {$v=Get-ItemProperty -LiteralPath $_.PSPath;@{name=$_.PSChildName;displayName=$v.DisplayName;version=$v.DisplayVersion;installLocation=$v.InstallLocation;uninstallString=$v.UninstallString;quietUninstallString=$v.QuietUninstallString;installDate=$v.InstallDate}})
$timerPath=Join-Path $local 'RooIndustriesOptimizationSuite.Timer'
$probeKeys=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'|Where-Object {$_.PSChildName -like 'Roo*Probe*'}|ForEach-Object {@{name=$_.PSChildName;values=@($_.GetValueNames())}})
$processes=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^Roo|^Optimizer\.' -or ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($app,[StringComparison]::OrdinalIgnoreCase))}|ForEach-Object {@{name=$_.Name;pid=$_.ProcessId;createdUtc=$_.CreationDate.ToUniversalTime().ToString('o');image=$_.ExecutablePath;commandSha256=(Hash-Text $_.CommandLine)}})
$marker='HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots';$m=Get-Item -LiteralPath $marker -ErrorAction SilentlyContinue
$markers=@(if($m){foreach($n in $m.GetValueNames()){@{nameSha256=(Hash-Text $n);currentOrLegacyPath=($n -in @((Join-Path $local 'RooIndustriesOptimizationSuite').ToUpperInvariant(),(Join-Path $local 'RooOptimizationSuite').ToUpperInvariant()));valueMatchesCurrentSid=($m.GetValue($n) -eq $identity.User.Value);kind=[string]$m.GetValueKind($n)}}})
$tweakRoot=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustriesOptimizationSuite' -ErrorAction SilentlyContinue
$tweakNodes=@(if($tweakRoot){foreach($node in @($tweakRoot)+@(Get-ChildItem -LiteralPath $tweakRoot.PSPath -Recurse)){@{keySha256=(Hash-Text $node.Name);leafIsCurrentSid=($node.PSChildName -eq $identity.User.Value);valueNames=@($node.GetValueNames()|Sort-Object);values=@(foreach($n in $node.GetValueNames()){$v=$node.GetValue($n,$null,'DoNotExpandEnvironmentNames');$bytes=if($v -is [byte[]]){$v}else{[Text.Encoding]::UTF8.GetBytes((@($v)-join "`n"))};$sha=[Security.Cryptography.SHA256]::Create();try{@{name=$n;kind=[string]$node.GetValueKind($n);bytes=$bytes.Length;sha256=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}}finally{$sha.Dispose()}})}}})
$baselineNames=@('hypervisorlaunchtype','vbsStatus','vbsRunning','rebootPendingCbs','rebootRequiredUpdate','tasks','productKeys','uninstallEntries','appFolder','enableTransparency','ifeoProbeKey','downloadBlockerFolder','localSiblings','userEnvironmentNames','tweakStateKey')
$baseSafe=@{};foreach($n in $baselineNames){$baseSafe[$n]=$state.$n}
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$machineAudit=@{observedUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;currentSidSha256=(Hash-Text $identity.User.Value);admin=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);bootUtc=$boot;cpu=@(Get-CimInstance Win32_Processor|ForEach-Object Name);gpu=@(Get-CimInstance Win32_VideoController|ForEach-Object Name);baseline=$baseSafe;backupFiles=$backupFiles;trees=$trees;installed=$installed;uninstall=$uninstall;tasks=$tasks;processes=$processes;markers=$markers;tweakNodes=$tweakNodes;probeKeys=$probeKeys;enableTransparency=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency).EnableTransparency;blockerPresent=(Test-Path -LiteralPath 'C:\Program Files\LogiDownloadAssistant');environmentNames=@((Get-Item 'HKCU:\Environment').GetValueNames()|Sort-Object)}

function Hash-Bytes([byte[]]$b){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash($b)).Replace('-','')}finally{$h.Dispose()}}
function Summary($s){@{schema=$s.schemaVersion;profileCount=@($s.profiles).Count;historyCount=@($s.history).Count;heldCount=@($s.held).Count;revision=$s.revision;ownerCurrentSid=($s.context.owner.userSid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value);profileIdHashes=@($s.profiles|ForEach-Object {Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($_.id))});latestHistoryUtc=@($s.history|Sort-Object atUtc|Select-Object -Last 1|ForEach-Object atUtc)}}
$backup=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'roo-industries-backup'
$txt=[IO.File]::ReadAllText((Join-Path $backup 'tweak-state.reg'))
$keys=@([regex]::Matches($txt,'(?m)^\[([^\]]+)\]')|ForEach-Object {$_.Groups[1].Value})
$m=[regex]::Match($txt,'(?ms)^"State"=hex:(.*?)(?=\r?\n\r?\n|\z)')
if(-not$m.Success){throw 'State binary not found in saved export'}
$hex=[regex]::Replace($m.Groups[1].Value,'[,\\\s]','')
$bytes=[System.Runtime.Remoting.Metadata.W3cXsd2001.SoapHexBinary]::Parse($hex).Value
$old=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$key=Get-Item -LiteralPath ('HKLM:\SOFTWARE\RooIndustriesOptimizationSuite\Tweaks\'+$sid)
$livebytes=$key.GetValue('State',$null,'DoNotExpandEnvironmentNames');$live=[Text.Encoding]::UTF8.GetString($livebytes)|ConvertFrom-Json
$beforeIds=@($old.history|ForEach-Object operationId);$new=@($live.history|Where-Object {$_.operationId -notin $beforeIds})
$approved=@('roo-industries-cache-check','roo-industries-migration-check','roo-industries-migration-timer','roo-industries-migration-blocker')
$markerText=[IO.File]::ReadAllText((Join-Path $backup 'hklm-roo-industries.reg'))
$markKeys=@([regex]::Matches($markerText,'(?m)^\[([^\]]+)\]')|ForEach-Object {$_.Groups[1].Value})
$markNames=@([regex]::Matches($markerText,'(?m)^"((?:[^"\\]|\\.)*)"=')|ForEach-Object {$_.Groups[1].Value -replace '\\\\','\'})
$originalHistoryChanged=0
foreach($item in $old.history){$matching=@($live.history|Where-Object operationId -eq $item.operationId);if($matching.Count -ne 1 -or (Hash-Text ($item|ConvertTo-Json -Depth 100 -Compress)) -ne (Hash-Text ($matching[0]|ConvertTo-Json -Depth 100 -Compress))){$originalHistoryChanged++}}
$contextMatches=(Hash-Text ($old.context|ConvertTo-Json -Depth 100 -Compress)) -eq (Hash-Text ($live.context|ConvertTo-Json -Depth 100 -Compress))
$registryAudit=@{originalHistoryChangedCount=$originalHistoryChanged;contextMatches=$contextMatches;savedControlsCount=@($old.controls|ForEach-Object {$_}).Count;liveControlsCount=@($live.controls|ForEach-Object {$_}).Count;unclassifiedLiveProfilesCount=@($live.profiles|Where-Object id -NotIn $approved).Count;savedStateBytes=$bytes.Length;savedStateSha256=(Hash-Bytes $bytes);liveStateBytes=$livebytes.Length;liveStateSha256=(Hash-Bytes $livebytes);saved=(Summary $old);live=(Summary $live);newHistory=@($new|ForEach-Object {@{profileId=$(if($_.profileId -in $approved){$_.profileId}else{'unclassified:'+ (Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($_.profileId)))});atUtc=$_.atUtc;operationId=$_.operationId;changeCount=@($_.changes).Count;controlsCount=@($_.controls).Count}});oldHistoryMissingCount=@($beforeIds|Where-Object {$_ -notin @($live.history|ForEach-Object operationId)}).Count;savedRegistryKeys=@($keys|ForEach-Object {Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($_))});savedMarkerKeys=@($markKeys|ForEach-Object {Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($_))});savedMarkerNames=@($markNames|ForEach-Object {Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($_))});savedMarkerValueCount=$markNames.Count;livePending=($key.GetValueNames() -contains 'Pending')}

$timerName='RooIndustries.Timer.C5E5AE90ADD1387A'
$timerProvenance=@{exists=$false}
$timer=Get-ScheduledTask -TaskName $timerName -ErrorAction SilentlyContinue
if($timer){
 $control=Join-Path $local 'RooOptimizationSuite\operations\windows-timer'
 $receipt=Get-Content -LiteralPath (Join-Path $control 'startup.json') -Raw|ConvertFrom-Json
 $scheduler=New-Object -ComObject 'Schedule.Service'
 try {
  $scheduler.Connect();$registered=$scheduler.GetFolder('\').GetTask($timerName)
  Add-Type -AssemblyName System.Xml.Linq
  $x=[System.Xml.Linq.XDocument]::Parse($registered.Xml);$ns=$x.Root.Name.Namespace;$e=$x.Root.Element($ns+'Settings').Element($ns+'Enabled');if($e){$e.Remove()}
  $definition=Hash-Text ($x.ToString([System.Xml.Linq.SaveOptions]::DisableFormatting)+"`n"+$registered.GetSecurityDescriptor(7))
  $scriptHash=(Get-FileHash -LiteralPath (Join-Path $control 'startup.ps1') -Algorithm SHA256).Hash
  $account=$timer.Principal.UserId;$ownerSid=if($account -match '^S-'){$account}else{([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value}
  $timerProvenance=@{exists=$true;definitionHash=$definition;definitionMatchesReceipt=($definition -eq $receipt.definitionHash);scriptHash=$scriptHash;scriptMatchesReceipt=($scriptHash -eq $receipt.scriptHash);ownerMatches=($ownerSid -eq $sid -and $receipt.owner.userSid -eq $sid -and $receipt.owner.machine -eq $env:COMPUTERNAME);receiptPhase=$receipt.phase;receiptTaskNameMatches=($receipt.taskName -eq $timerName);receiptFileSha256=(Get-FileHash -LiteralPath (Join-Path $control 'startup.json') -Algorithm SHA256).Hash;logonType=[string]$timer.Principal.LogonType;runLevel=[string]$timer.Principal.RunLevel;state=[string]$timer.State}
 } finally {if($registered){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($registered)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($scheduler)}
}
$layout=@{originalMarkerValueCount=$markNames.Count;savedMarkerKeyCount=$markKeys.Count;knownOriginalMarkerKeys=(@($markKeys|Where-Object {$_ -notin @('HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustries','HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustries\OptimizationSuite','HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots')}).Count -eq 0);migrationProbeExists=(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'RooIndustriesMigrationProbe.exe'));migrationStateExists=(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-migration-state.json'));siblingCount=@(Get-ChildItem -LiteralPath $local -Directory -Force|Where-Object Name -match 'OptimizationSuite').Count}
$originalMetadataMatches=(@($state.localSiblings|Where-Object {-not$trees.ContainsKey($_) -or -not$trees[$_].saved.exists -or $trees[$_].saved.reparseCount -ne 0 -or $trees[$_].saved.historicalMetadataDifferences -ne 0}).Count -eq 0)
@{protocol='roo-industries-9070-historical-audit/v1';readOnly=$true;originalMetadataMatches=$originalMetadataMatches;machine=$machineAudit;registry=$registryAudit;timerProvenance=$timerProvenance;layout=$layout;restorationVerified=$false;historicalOriginalByteHashesAvailable=$false;historicalTaskDefinitionsAvailable=$false}|ConvertTo-Json -Depth 14
