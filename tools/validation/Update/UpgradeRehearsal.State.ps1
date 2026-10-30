function ConvertTo-RehearsalValue($Value){
 if($null -eq $Value){return $null}
 if($Value -is [string] -or $Value.GetType().IsValueType){return $Value}
 if($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]){
  $result=[ordered]@{};$names=[string[]]@($(if($Value -is [Collections.IDictionary]){$Value.Keys}else{$Value.PSObject.Properties.Name}));[Array]::Sort($names,[StringComparer]::Ordinal)
  foreach($name in $names){$result[$name]=ConvertTo-RehearsalValue $Value.$name}
  return $result
 }
 if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){return ,@(foreach($item in $Value){ConvertTo-RehearsalValue $item})}
 return $Value
}
function Test-RehearsalSnapshot($Expected,$Actual){
 (ConvertTo-Json -InputObject (ConvertTo-RehearsalValue $Expected) -Depth 60 -Compress) -ceq (ConvertTo-Json -InputObject (ConvertTo-RehearsalValue $Actual) -Depth 60 -Compress)
}
function Get-RehearsalPathState([string]$Path){
 $exists=Test-HarnessPath $Path
 $rows=@(if($exists){
  $items=@(Get-HarnessItem $Path -Force)
  if($items[0].IsDirectory){$items+=@(Get-HarnessTree $Path)}
  foreach($item in $items){
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Linked rehearsal state retained: '+$item.FullName)}
   $security=if($env:OS -eq 'Windows_NT'){$acl=if($item.IsDirectory){[IO.Directory]::GetAccessControl((Get-HarnessLongPath $item.FullName))}else{[IO.File]::GetAccessControl((Get-HarnessLongPath $item.FullName))};$acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access,Owner,Group')}else{''}
   @{relative=$item.FullName.Substring($Path.Length);directory=$item.IsDirectory;attributes=[int]$item.Attributes;created=[IO.File]::GetCreationTimeUtc((Get-HarnessLongPath $item.FullName)).Ticks;written=[IO.File]::GetLastWriteTimeUtc((Get-HarnessLongPath $item.FullName)).Ticks;security=$security;sha256=$(if(-not$item.IsDirectory){Get-HarnessFileSha256 $item.FullName}else{''})}
  }
 })
 @{path=$Path;exists=$exists;items=@($rows|Sort-Object {$_.relative})}
}
function Assert-RehearsalPathState($Expected,[string]$Path){
 $actual=Get-RehearsalPathState $Path
 if($actual.exists -ne $Expected.exists -or -not(Test-RehearsalSnapshot $Expected.items $actual.items)){throw ('Rehearsal state hash or metadata mismatch; retained: '+$Path)}
}
function Move-RehearsalPath([string]$From,[string]$To){
 if(Test-HarnessPath $To){throw ('Rehearsal destination exists; retained: '+$To)}
 if([IO.Path]::GetDirectoryName($From) -ine [IO.Path]::GetDirectoryName($To)){throw 'Rehearsal moves must stay in the same directory.'}
 if((Get-HarnessItem $From -Force).IsDirectory){[IO.Directory]::Move((Get-HarnessLongPath $From),(Get-HarnessLongPath $To))}else{[IO.File]::Move((Get-HarnessLongPath $From),(Get-HarnessLongPath $To))}
}
function Get-RehearsalTaskService{$service=New-Object -ComObject Schedule.Service;$service.Connect();return $service}
function Get-RehearsalAccountSid([string]$User){
 try{return [Security.Principal.SecurityIdentifier]::new($User).Value}catch [ArgumentException]{return ([Security.Principal.NTAccount]::new($User).Translate([Security.Principal.SecurityIdentifier])).Value}
}
function Get-RehearsalCurrentSid{[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
function Get-RehearsalTasks{
 $service=Get-RehearsalTaskService
 @(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.|^Roo Protected Session |^Roo Industries Protected Session |^RooIndustries\.Timer\.'}|ForEach-Object {
  if($_.TaskPath -cne '\'){throw 'A product task outside the Task Scheduler root folder cannot be preserved; retained.'}
  $task=$service.GetFolder($_.TaskPath).GetTask($_.TaskName)
  if($task.State -notin 1,3){throw 'A product task is running, queued or has an unknown state; retained.'}
  $principal=$task.Definition.Principal
  if($principal.LogonType -notin 3,5){throw 'A product task needs credentials; retained.'}
  if($principal.LogonType -eq 3 -and (Get-RehearsalAccountSid $principal.UserId) -cne (Get-RehearsalCurrentSid)){throw 'A product task belongs to another account; retained.'}
  @{name=$_.TaskName;folder=$_.TaskPath;xml=$task.Xml;security=$task.GetSecurityDescriptor(7);enabled=$task.Enabled;user=$principal.UserId;logonType=[int]$principal.LogonType}
 })
}
function Get-RehearsalMarkers([string[]]$Roots,[switch]$All){
 $keys=@('SOFTWARE\RooIndustries','SOFTWARE\RooIndustries\OptimizationSuite','SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots')
 $parents=@(foreach($path in $keys){$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path);try{@{path=$path;exists=($null -ne $key)}}finally{if($key){$key.Dispose()}}})
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keys[-1])
 try{
  $values=@(if($key){foreach($name in $key.GetValueNames()){
   if($All -or @($Roots|Where-Object {$name -ieq $_ -or $name.StartsWith($_+'|',[StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){
    @{name=$name;kind=[string]$key.GetValueKind($name);value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
   }
  }})
  @{parents=$parents;values=@($values|Sort-Object {$_.name})}
 }finally{if($key){$key.Dispose()}}
}
function Remove-RehearsalMarker([string]$Name){
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots',$true)
 try{if($key){$key.DeleteValue($Name,$false)}}finally{if($key){$key.Dispose()}}
}
function Set-RehearsalMarker($Value){
 $key=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots')
 try{
  $kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$Value.kind);$data=$Value.value
  if($kind -eq 'QWord'){$data=[long]$data}elseif($kind -eq 'DWord'){$data=[int]$data}elseif($kind -in 'Binary','None'){$data=[byte[]]$data}elseif($kind -eq 'MultiString'){$data=[string[]]$data}
  $key.SetValue($Value.name,$data,$kind)
 }finally{$key.Dispose()}
}
function Remove-RehearsalEmptyMarkerParent([string]$Path){
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Path)
 try{$empty=$key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0}finally{if($key){$key.Dispose()}}
 if($empty){[Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey($Path,$false)}
}
function Assert-RehearsalBoundary([string[]]$Roots){
 $all=Get-RehearsalMarkers $Roots -All;$scoped=Get-RehearsalMarkers $Roots
 if(-not(Test-RehearsalSnapshot $all $scoped)){throw 'A foreign protected root cannot be preserved; retained.'}
 foreach($value in $scoped.values){if($value.kind -notin 'String','ExpandString','MultiString','Binary','None','DWord','QWord'){throw 'Unsupported protected-folder value kind; retained.'}}
}
function Set-RehearsalJournal($Entry,$State,[switch]$Restored){
 Invoke-HarnessLedger {param($ledger)
  $row=@($ledger.entries|Where-Object id -CEQ $Entry.id);if($row.Count -ne 1){throw 'Rehearsal journal is missing.'}
  $row[0].metadata=$State;if($Restored){$row[0].state='restored'}
 }|Out-Null
 if($Restored){$Entry.state='restored'}
}
function Invoke-RehearsalMutation($Entry,[string]$Name,[scriptblock]$Action){
 $state=$Entry.metadata
 if($state -isnot [Collections.IDictionary] -and -not$state.PSObject.Properties['operations']){$state|Add-Member operations @()}
 $operation=@($state.operations|Where-Object name -CEQ $Name)
 if(-not$operation.Count){$operation=@(@{name=$Name;complete=$false});$state.operations=@($state.operations)+$operation}
 if($operation[0].complete){return}
 Set-RehearsalJournal $Entry $state
 Invoke-HarnessCheckpoint ($Name+':before-mutation')
 & $Action|Out-Null
 Invoke-HarnessCheckpoint ($Name+':after-mutation')
 $operation[0].complete=$true;Set-RehearsalJournal $Entry $state
}
function Save-RehearsalState([string[]]$Paths,[string[]]$Roots,[string]$Image){
 Assert-RehearsalBoundary $Roots
 $tasks=@(Get-RehearsalTasks)
 $pathsState=@(foreach($path in $Paths){
  for($ancestor=$path;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){
   if((Test-HarnessPath $ancestor) -and ((Get-HarnessItem $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked rehearsal ancestry retained.'}
  }
  $saved=$path+'.rehearsal-'+$script:Harness.Nonce;$generated=$path+'.rehearsal-output-'+$script:Harness.Nonce;$staging=$path+'.rehearsal-owned-'+$script:Harness.Nonce
  if((Test-HarnessPath $saved) -or (Test-HarnessPath $generated) -or (Test-HarnessPath $staging)){throw 'Rehearsal archive exists; retained.'}
  @{before=(Get-RehearsalPathState $path);saved=$saved;generated=$generated;staging=$staging;claim=$null;movePlanned=$false;archivePlanned=$false;output=$null}
 })
 $state=@{paths=$pathsState;roots=$Roots;image=$Image;tasks=$tasks;markers=(Get-RehearsalMarkers $Roots);taskFolder=('\PerformanceVertexRehearsal_'+$script:Harness.Nonce);operations=@();started=$false;outputsReady=$false;generatedMarkers=$null;restored=$false}
 Add-HarnessEntry 'rehearsal-state' @{path=$script:Harness.Root} 'upgrade-state' 'retained' $state
}
function Suspend-RehearsalState($Entry){
 $state=$Entry.metadata
 Assert-RehearsalBoundary $state.roots
 if(-not(Test-RehearsalSnapshot $state.tasks @(Get-RehearsalTasks)) -or -not(Test-RehearsalSnapshot $state.markers (Get-RehearsalMarkers $state.roots))){throw 'Product state changed before suspension; retained.'}
 foreach($row in $state.paths){Assert-RehearsalPathState $row.before $row.before.path}
 $state.started=$true;Set-RehearsalJournal $Entry $state
 $service=Get-RehearsalTaskService
 if($state.tasks.Count){Invoke-RehearsalMutation $Entry 'task-folder' {$null=$service.GetFolder('\').CreateFolder($state.taskFolder.Trim('\'),$null)}}
 for($i=0;$i -lt $state.tasks.Count;$i++){
  $task=$state.tasks[$i];$backupName='original-'+$i;$folder=$service.GetFolder($task.folder)
  $current=$folder.GetTask($task.name)
  if($current.State -in 2,4 -or $current.Xml -cne $task.xml -or $current.GetSecurityDescriptor(7) -cne $task.security -or $current.Enabled -ne $task.enabled){throw 'Product task changed after review; retained.'}
  Invoke-RehearsalMutation $Entry ('task-backup:'+ $i) {
   $backup=$service.GetFolder($state.taskFolder);$null=$backup.RegisterTask($backupName,$task.xml,58,$task.user,$null,$task.logonType,$task.security)
   if($backup.GetTask($backupName).Enabled){throw 'Task archive is enabled; retained.'}
  }
  Invoke-RehearsalMutation $Entry ('task-delete:'+ $i) {$folder.DeleteTask($task.name,0)}
 }
 for($i=0;$i -lt $state.paths.Count;$i++){
  $row=$state.paths[$i]
  if($row.before.exists){$row.movePlanned=$true;Invoke-RehearsalMutation $Entry ('root-move:'+ $i) {Move-RehearsalPath $row.before.path $row.saved;Assert-RehearsalPathState $row.before $row.saved}}
 }
 for($i=0;$i -lt $state.markers.values.Count;$i++){$value=$state.markers.values[$i];Invoke-RehearsalMutation $Entry ('marker-hide:'+ $i) {Remove-RehearsalMarker $value.name}}
}
function Get-RehearsalRootIdentity([string]$Path){
 $item=Get-HarnessItem $Path -Force
 if(-not$item.IsDirectory -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Generated root identity changed; retained.'}
 if($env:OS -eq 'Windows_NT'){
  $handle=[RooIndustriesValidationOwnership.Native]::CreateFile((Get-HarnessLongPath $Path),[uint32]2147483648,7,[IntPtr]::Zero,3,0x02200000,[IntPtr]::Zero)
  try{return [RooIndustriesValidationOwnership.Native]::FileId($handle)}finally{$handle.Dispose()}
 }
 return (& stat -c '%d:%i:%W' -- $Path)
}
function Initialize-RehearsalRoots($Entry,[string]$ActiveRoot){
 $state=$Entry.metadata
 if($ActiveRoot -and $ActiveRoot -notin $state.roots){throw 'The active data root is outside the saved rehearsal scope.'}
 for($i=0;$i -lt $state.paths.Count;$i++){
  $row=$state.paths[$i]
  if($row.before.path -notin $state.roots){continue}
  if($ActiveRoot -and $row.before.path -ine $ActiveRoot){continue}
  Invoke-RehearsalMutation $Entry ('root-prepare:'+ $i) {
   if(Test-HarnessPath $row.staging){throw 'Generated staging root exists without an identity; retained.'}
   if($env:OS -eq 'Windows_NT'){
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'));$security.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-3-4',(Get-RehearsalCurrentSid))){
     $rights=[Security.AccessControl.FileSystemRights]$(if($sid -in 'S-1-5-18','S-1-5-32-544'){'FullControl'}else{'ReadAndExecute,Synchronize'})
     $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
    }
    [IO.DirectoryInfo]::new((Get-HarnessLongPath $row.staging)).Create($security)
   }else{[IO.Directory]::CreateDirectory((Get-HarnessLongPath $row.staging))|Out-Null}
   $row.claim=Get-RehearsalRootIdentity $row.staging
  }
  Invoke-RehearsalMutation $Entry ('root-claim:'+ $i) {Move-RehearsalPath $row.staging $row.before.path}
 }
}
function Stop-RehearsalWriters($Entry){
 $state=$Entry.metadata
 if($state.image){
  foreach($process in @(Get-CimInstance Win32_Process|Where-Object ExecutablePath -IEQ $state.image)){
   $receipt=Get-HarnessProcess ([int]$process.ProcessId)
   if(-not$receipt -or $receipt.Nonce -cne $Entry.nonce){throw 'An unproved app writer is running; retained.'}
  }
 }
 foreach($process in @(Get-HarnessEntries|Where-Object {$_.kind -eq 'process' -and $_.nonce -ceq $Entry.nonce -and $_.lifetime -ne 'runner' -and $_.state -in 'active','error' -and $_.identity.pid -ne $PID})){
  Invoke-RehearsalMutation $Entry ('writer-stop:'+ $process.id) {Remove-HarnessEntry $process}
 }
 if($state.image -and @(Get-CimInstance Win32_Process|Where-Object ExecutablePath -IEQ $state.image).Count){throw 'An app writer remains; retained.'}
}
function Start-RehearsalApp($Entry){
 $index=@($Entry.metadata.operations|Where-Object {$_.name -like 'app-start:*'}).Count
 Invoke-RehearsalMutation $Entry ('app-start:'+ $index) {Launch}
}
function Save-RehearsalOutputs($Entry){
 Invoke-RehearsalMutation $Entry 'outputs-record' {
  foreach($row in $Entry.metadata.paths){
   if($row.claim -and (Test-HarnessPath $row.before.path) -and (Get-RehearsalRootIdentity $row.before.path) -cne $row.claim){throw 'Generated root was replaced; retained.'}
   $row.output=Get-RehearsalPathState $row.before.path
  }
  $Entry.metadata.outputsReady=$true
 }
}
function Assert-RehearsalRestored($Entry){
 foreach($row in $Entry.metadata.paths){Assert-RehearsalPathState $row.before $row.before.path}
 if(-not(Test-RehearsalSnapshot $Entry.metadata.markers (Get-RehearsalMarkers $Entry.metadata.roots))){throw 'Protected-folder registration restore differs; retained.'}
 if(-not(Test-RehearsalSnapshot @($Entry.metadata.tasks|Sort-Object {$_.folder},{$_.name}) @((Get-RehearsalTasks)|Sort-Object {$_.folder},{$_.name}))){throw 'Restored product tasks differ; retained.'}
}
function Restore-RehearsalState($Entry){
 $Entry=Get-HarnessEntryById $Entry.id;$state=$Entry.metadata
 if($state.restored -and $Entry.state -eq 'restored'){Assert-RehearsalRestored $Entry;return}
 if($state.started){
  Stop-RehearsalWriters $Entry
  Restore-RehearsalPaths $Entry
  if(-not$state.generatedMarkers){$state.generatedMarkers=Get-RehearsalMarkers $state.roots;Set-RehearsalJournal $Entry $state}
  for($i=0;$i -lt $state.generatedMarkers.values.Count;$i++){$value=$state.generatedMarkers.values[$i];Invoke-RehearsalMutation $Entry ('marker-remove:'+ $i) {Remove-RehearsalMarker $value.name}}
  for($i=0;$i -lt $state.markers.values.Count;$i++){$value=$state.markers.values[$i];Invoke-RehearsalMutation $Entry ('marker-restore:'+ $i) {Set-RehearsalMarker $value}}
  $parents=@($state.markers.parents);[array]::Reverse($parents)
  for($i=0;$i -lt $parents.Count;$i++){$parent=$parents[$i];if(-not$parent.exists){Invoke-RehearsalMutation $Entry ('marker-parent:'+ $i) {Remove-RehearsalEmptyMarkerParent $parent.path}}}
  $service=Get-RehearsalTaskService
  for($i=0;$i -lt $state.tasks.Count;$i++){
   $task=$state.tasks[$i];$folder=$service.GetFolder($task.folder)
   $found=@($folder.GetTasks(1)|Where-Object Name -CEQ $task.name)
   if($found.Count -and ($found[0].Xml -cne $task.xml -or $found[0].GetSecurityDescriptor(7) -cne $task.security -or $found[0].Enabled -ne $task.enabled)){throw 'Product task restore destination changed; retained.'}
   if(-not$found.Count){Invoke-RehearsalMutation $Entry ('task-restore:'+ $i) {$null=$folder.RegisterTask($task.name,$task.xml,50,$task.user,$null,$task.logonType,$task.security)}}
  }
 }
 Assert-RehearsalRestored $Entry
 $state.restored=$true;Set-RehearsalJournal $Entry $state -Restored
 $persisted=Get-HarnessEntryById $Entry.id
 if(-not$persisted.metadata.restored -or $persisted.state -cne 'restored'){throw 'Rehearsal completion was not persisted; retained.'}
}
function Restore-RehearsalPaths($Entry){
 $state=$Entry.metadata
 foreach($row in $state.paths){
  if($row.movePlanned -and (Test-HarnessPath $row.saved)){Assert-RehearsalPathState $row.before $row.saved}
  elseif($row.before.exists){Assert-RehearsalPathState $row.before $row.before.path}
 }
 for($i=0;$i -lt $state.paths.Count;$i++){
  $row=$state.paths[$i];$path=$row.before.path
  if($row.movePlanned -and -not(Test-HarnessPath $row.saved)){continue}
  if(Test-HarnessPath $path){
   if($row.before.exists -and -not$row.movePlanned){continue}
   if($row.claim -and (Get-RehearsalRootIdentity $path) -cne $row.claim){throw 'Generated root was replaced; retained.'}
   if(-not$row.output){
    if(-not$row.claim -or (Get-RehearsalRootIdentity $path) -cne $row.claim){throw 'Restore destination is occupied without a recorded output snapshot or root identity; retained.'}
    $row.output=Get-RehearsalPathState $path;Set-RehearsalJournal $Entry $state
   }
   Assert-RehearsalPathState $row.output $path
   $row.archivePlanned=$true
   Invoke-RehearsalMutation $Entry ('root-archive:'+ $i) {Move-RehearsalPath $path $row.generated}
  }
  if($row.before.exists -and (Test-HarnessPath $row.saved)){Invoke-RehearsalMutation $Entry ('root-restore:'+ $i) {Move-RehearsalPath $row.saved $path}}
  Assert-RehearsalPathState $row.before $path
 }
 foreach($row in $state.paths){if($row.archivePlanned){Assert-RehearsalPathState $row.output $row.generated}}
}
