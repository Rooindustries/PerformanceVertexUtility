param([switch]$AfterFixtures,[Parameter(Mandatory)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong recovery target'}
$local=[Environment]::GetFolderPath('LocalApplicationData')
$programData=[Environment]::GetFolderPath('CommonApplicationData')
$backup=Join-Path $local 'roo-industries-backup'
$app='C:\Program Files\Roo Industries\Optimization Suite'
$frame=Join-Path $programData 'RooRecovery9070'
$trusted=@('S-1-5-18','S-1-5-32-544')
function Hash-Text([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','')}finally{$h.Dispose()}}
function Save-Json([string]$p,$v){[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
function Protected-Directory([string]$p){
 if(Test-Path -LiteralPath $p){
  $i=Get-Item -LiteralPath $p -Force
  if(-not$i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Recovery parent is not an ordinary directory'}
  $a=Get-Acl -LiteralPath $p
  if($trusted -notcontains $a.GetOwner([Security.Principal.SecurityIdentifier]).Value){throw 'Recovery parent has an unexpected owner'}
  $writers=@($a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $trusted -notcontains $_.IdentityReference.Value -and ([int64]$_.FileSystemRights -band 0x500D0156) -ne 0})
  if($writers.Count){throw 'Recovery parent has a non-administrator writer'}
  return
 }
 $a=[Security.AccessControl.DirectorySecurity]::new();$a.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'));$a.SetAccessRuleProtection($true,$false)
 foreach($s in $trusted){$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($s),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 $a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-4'),'ReadPermissions','ContainerInherit,ObjectInherit','None','Allow'))
 [IO.Directory]::CreateDirectory($p,$a)|Out-Null
}
function Tree([string]$p){
 $base=Get-Item -LiteralPath $p -Force
 $q=[Collections.Generic.Queue[object]]::new();$q.Enqueue($base)
 $rows=[Collections.Generic.List[object]]::new()
 while($q.Count){
  $i=$q.Dequeue();if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A captured tree contains a reparse point'}
  $s=(Get-Acl -LiteralPath $i.FullName -Audit).Sddl
  $rows.Add([pscustomobject][ordered]@{relative=$i.FullName.Substring($base.FullName.Length);directory=[bool]$i.PSIsContainer;length=$(if($i.PSIsContainer){0}else{$i.Length});lastWriteUtc=$i.LastWriteTimeUtc.ToString('o');attributes=[int]$i.Attributes;sddl=$s;sha256=$(if($i.PSIsContainer){''}else{(Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256).Hash})})
  if($i.PSIsContainer){foreach($c in @(Get-ChildItem -LiteralPath $i.FullName -Force)){$q.Enqueue($c)}}
 }
 @($rows|Sort-Object relative)
}
function Content-Lines($rows){@($rows|ForEach-Object {$_.relative+'|'+$_.directory+'|'+$_.length+'|'+$_.lastWriteUtc+'|'+$_.attributes+'|'+$_.sha256})}
function Copy-Verified([string]$name,[string]$source){
 if(-not(Test-Path -LiteralPath $source -PathType Container)){throw ('Capture source absent: '+$name)}
 $target=Join-Path $frame $name
 $before=@(Tree $source)
 if(@($before|Where-Object {($target+$_.relative).Length -ge 248}).Count){throw ('Recovery destination exceeds the manifest reader path limit: '+$name)}
 if(Test-Path -LiteralPath $target){Protected-Directory $target}else{
  Protected-Directory $target
  $copy=@(& (Join-Path $env:SystemRoot 'System32\robocopy.exe') $source $target /E /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>&1)
  $code=$LASTEXITCODE
  [IO.File]::WriteAllText((Join-Path $frame ($name+'.robocopy.log')),($copy -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
  if($code -ge 8){throw ('Recovery copy failed: '+$name+' exit '+$code)}
  $sourceItem=Get-Item -LiteralPath $source -Force;$targetItem=Get-Item -LiteralPath $target -Force
  $targetItem.Attributes=$sourceItem.Attributes;$targetItem.LastWriteTimeUtc=$sourceItem.LastWriteTimeUtc
 }
 $after=@(Tree $source);$copied=@(Tree $target)
 if((Hash-Text ($before|ConvertTo-Json -Depth 5 -Compress)) -ne (Hash-Text ($after|ConvertTo-Json -Depth 5 -Compress))){throw ('Capture source changed: '+$name)}
 if(@(Compare-Object (Content-Lines $before) (Content-Lines $copied)).Count){throw ('Recovery content or metadata differs: '+$name)}
 foreach($row in $copied){$p=Join-Path $target $row.relative.TrimStart('\');$a=Get-Acl -LiteralPath $p;$writers=@($a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $trusted -notcontains $_.IdentityReference.Value -and ([int64]$_.FileSystemRights -band 0x500D0156) -ne 0});if($writers.Count){throw ('Recovery copy has a non-administrator writer: '+$name)};if(@($a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -eq 'S-1-3-4' -and $_.AccessControlType -eq 'Allow' -and ([int64]$_.FileSystemRights -band 0xFFEFFFFF) -eq [int64][Security.AccessControl.FileSystemRights]::ReadPermissions}).Count -eq 0){throw ('Recovery copy does not limit implicit owner rights: '+$name)}}
 Save-Json (Join-Path $frame ($name+'.source-manifest.json')) $before
 Save-Json (Join-Path $frame ($name+'.capture-manifest.json')) $copied
 @{name=$name;items=$before.Count;sha256=(Hash-Text ($before|ConvertTo-Json -Depth 5 -Compress));source=$source;destination=$target;bytesAndMetadataVerified=$true;sourcePermissionsSaved=$true}
}
if($AfterFixtures){
 Protected-Directory $frame
 $original=Get-Content -LiteralPath (Join-Path $frame 'current-RooOptimizationSuite.source-manifest.json') -Raw|ConvertFrom-Json
 $temp=@($original|Where-Object relative -ceq '\temp')
 if($temp.Count -ne 1 -or $temp[0].lastWriteUtc -cne '2026-10-01T22:06:45.3098267Z'){throw 'Original temp capture is not the audited identity'}
 $temp[0].lastWriteUtc='2026-10-04T20:50:33.1859804Z'
 $source=Join-Path $local 'RooOptimizationSuite'
 $actual=@(Tree $source)
 if((Hash-Text ($original|ConvertTo-Json -Depth 5 -Compress)) -ne (Hash-Text ($actual|ConvertTo-Json -Depth 5 -Compress))){throw 'Live legacy data changed beyond the audited temp directory timestamp'}
 $capture=Copy-Verified 'post-fixture-legacy' $source
 Save-Json (Join-Path $frame 'post-fixture-capture.json') $capture
 [pscustomobject]$capture|ConvertTo-Json -Depth 4
 exit 0
}
if(Test-Path -LiteralPath $frame){
 Protected-Directory $frame
 $phase=Get-Content -LiteralPath (Join-Path $frame 'phase.json') -Raw|ConvertFrom-Json
 if($phase.phase -ne 'capture-failed'){throw 'Historical recovery frame is not a failed capture; inspect it before resuming'}
 $allowed=@('original-backup','installed-app','current-RooOptimizationSuite','current-RooIndustriesOptimizationSuite','current-RooIndustriesOptimizationSuite.Timer','migration-archive')
 if(@(Get-ChildItem -LiteralPath $frame -Directory -Force|Where-Object {$_.Name -notin $allowed}).Count){throw 'Historical recovery frame has an unexpected directory'}
}
if((Get-FileHash (Join-Path $backup 'machine-state.json') -Algorithm SHA256).Hash -cne 'BE914AC3750C09734FE545DBB22C1346590E0DB0CD650B41B4FDC64E6653AF85'){throw 'Backup baseline identity changed'}
$processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($app,[StringComparison]::OrdinalIgnoreCase)})
if($processes.Count){throw 'An installed product process is running'}
Protected-Directory $frame
Save-Json (Join-Path $frame 'phase.json') @{phase='capturing';startedUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME}
$captures=@()
try {
 $captures+=Copy-Verified 'original-backup' $backup
 $captures+=Copy-Verified 'installed-app' $app
 foreach($n in 'RooOptimizationSuite','RooIndustriesOptimizationSuite','RooIndustriesOptimizationSuite.Timer'){$captures+=Copy-Verified ('current-'+$n) (Join-Path $local $n)}
 $archives=@(Get-ChildItem -LiteralPath $local -Directory -Force|Where-Object {$_.Name -like 'RooOptimizationSuite.untrusted-*'})
 if($archives.Count -ne 1){throw 'Expected exactly one known migration archive'}
 $captures+=Copy-Verified 'migration-archive' $archives[0].FullName
 foreach($pair in @(@('HKLM\SOFTWARE\RooIndustries','current-markers.reg'),@('HKLM\SOFTWARE\RooIndustriesOptimizationSuite','current-tweaks.reg'))){& (Join-Path $env:SystemRoot 'System32\reg.exe') export $pair[0] (Join-Path $frame $pair[1]) /y|Out-Null;if($LASTEXITCODE -ne 0){throw 'Registry capture failed'}}
 $tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'RooIndustriesCS2_*' -or $_.TaskName -eq 'RooIndustries.Timer.C5E5AE90ADD1387A'})
 $sc=New-Object -ComObject Schedule.Service;$sc.Connect();$rows=@()
 try {foreach($t in $tasks){$task=$sc.GetFolder($t.TaskPath).GetTask($t.TaskName);$xml=$task.Xml;$sd=$task.GetSecurityDescriptor(7);[IO.File]::WriteAllText((Join-Path $frame ($t.TaskName+'.xml')),$xml,[Text.Encoding]::Unicode);$rows+=@{name=$t.TaskPath+$t.TaskName;xmlSha256=(Hash-Text $xml);sddl=$sd};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)}} finally {[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($sc)}
 Save-Json (Join-Path $frame 'tasks.json') $rows
 Save-Json (Join-Path $frame 'captures.json') $captures
 Save-Json (Join-Path $frame 'phase.json') @{phase='captured';finishedUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME;captures=$captures.Count}
 $captures|ForEach-Object {[pscustomobject]$_}|Select-Object name,items,sha256,bytesAndMetadataVerified,sourcePermissionsSaved|ConvertTo-Json -Depth 4
} catch {Save-Json (Join-Path $frame 'phase.json') @{phase='capture-failed';message=$_.Exception.Message;completedCaptures=$captures;atUtc=[DateTime]::UtcNow.ToString('o')};throw}
