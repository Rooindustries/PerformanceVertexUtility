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
 @{path=$Path;exists=$exists;items=@($rows|Sort-Object relative)}
}
function Assert-RehearsalPathState($Expected,[string]$Path){
 $actual=Get-RehearsalPathState $Path
 if($actual.exists -ne $Expected.exists -or ($actual.items|ConvertTo-Json -Depth 10 -Compress) -cne ($Expected.items|ConvertTo-Json -Depth 10 -Compress)){throw ('Rehearsal state hash or metadata mismatch; retained: '+$Path)}
}
function Move-RehearsalPath([string]$From,[string]$To){
 if(Test-HarnessPath $To){throw ('Rehearsal destination exists; retained: '+$To)}
 if([IO.Path]::GetDirectoryName($From) -ine [IO.Path]::GetDirectoryName($To)){throw 'Rehearsal moves must stay in the same directory.'}
 if((Get-HarnessItem $From -Force).IsDirectory){[IO.Directory]::Move((Get-HarnessLongPath $From),(Get-HarnessLongPath $To))}else{[IO.File]::Move((Get-HarnessLongPath $From),(Get-HarnessLongPath $To))}
}
function Get-RehearsalTasks{
 $service=New-Object -ComObject Schedule.Service;$service.Connect()
 @(Get-ScheduledTask|Where-Object {$_.TaskName -match '^(RooIndustriesOptimizationSuite|RooOptimizationSuite)\.|^Roo Protected Session '}|ForEach-Object {
  $task=$service.GetFolder($_.TaskPath).GetTask($_.TaskName)
  if($task.Definition.Principal.LogonType -notin 3,5){throw 'A product task needs credentials; retained.'}
  @{name=$_.TaskName;folder=$_.TaskPath;xml=$task.Xml;security=$task.GetSecurityDescriptor(7);enabled=$task.Enabled;user=$task.Definition.Principal.UserId;logonType=[int]$task.Definition.Principal.LogonType}
 })
}
function Get-RehearsalMarkers([string[]]$Roots){
 $keys=@('SOFTWARE\RooIndustries','SOFTWARE\RooIndustries\OptimizationSuite','SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots')
 $parents=@(foreach($path in $keys){$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path);try{@{path=$path;exists=($null -ne $key)}}finally{if($key){$key.Dispose()}}})
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keys[-1])
 try{
  $values=@(if($key){foreach($name in $key.GetValueNames()){
   if(@($Roots|Where-Object {$name -ieq $_ -or $name.StartsWith($_+'|',[StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){
    @{name=$name;kind=[string]$key.GetValueKind($name);value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
   }
  }})
  @{parents=$parents;values=@($values|Sort-Object name)}
 }finally{if($key){$key.Dispose()}}
}
function Set-RehearsalJournal($Entry,$State){
 Invoke-HarnessLedger {param($ledger) $row=@($ledger.entries|Where-Object id -CEQ $Entry.id);if($row.Count -ne 1){throw 'Rehearsal journal is missing.'};$row[0].metadata=$State}|Out-Null
}
function Save-RehearsalState([string[]]$Paths,[string[]]$Roots){
 $pathsState=@(foreach($path in $Paths){
  for($ancestor=$path;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){
   if((Test-HarnessPath $ancestor) -and ((Get-HarnessItem $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked rehearsal ancestry retained.'}
  }
  $saved=$path+'.rehearsal-'+$script:Harness.Nonce
  $generated=$path+'.rehearsal-output-'+$script:Harness.Nonce
  if((Test-HarnessPath $saved) -or (Test-HarnessPath $generated)){throw 'Rehearsal archive exists; retained.'}
  @{before=(Get-RehearsalPathState $path);saved=$saved;generated=$generated;movePlanned=$false;archivePlanned=$false;output=$null}
 })
 $state=@{paths=$pathsState;roots=$Roots;tasks=@(Get-RehearsalTasks);markers=(Get-RehearsalMarkers $Roots);taskFolder=('\PerformanceVertexRehearsal_'+$script:Harness.Nonce);started=$false;outputsReady=$false;generatedMarkers=$null;restored=$false}
 Add-HarnessEntry 'rehearsal-state' @{path=$script:Harness.Root} 'upgrade-state' 'retained' $state
}
function Suspend-RehearsalState($Entry){
 $state=$Entry.metadata
 foreach($value in $state.markers.values){if($value.kind -notin 'String','ExpandString','MultiString','Binary','None','DWord','QWord'){throw 'Unsupported protected-folder value kind; retained.'}}
 $state.started=$true;Set-RehearsalJournal $Entry $state
 $service=New-Object -ComObject Schedule.Service;$service.Connect()
 if($state.tasks.Count){$backup=$service.GetFolder('\').CreateFolder($state.taskFolder.Trim('\'),$null)}
 for($i=0;$i -lt $state.tasks.Count;$i++){
  $task=$state.tasks[$i];$backupName='original-'+$i
  Set-RehearsalJournal $Entry $state
  $current=$service.GetFolder($task.folder).GetTask($task.name)
  if($current.State -in 2,4 -or $current.Xml -cne $task.xml -or $current.GetSecurityDescriptor(7) -cne $task.security){throw 'Product task changed after review; retained.'}
  $null=$backup.RegisterTask($backupName,$task.xml,58,$task.user,$null,$task.logonType,$task.security)
  if($backup.GetTask($backupName).Enabled){throw 'Task archive is enabled; retained.'}
  $service.GetFolder($task.folder).DeleteTask($task.name,0)
 }
 foreach($row in $state.paths){
  Assert-RehearsalPathState $row.before $row.before.path
  if($row.before.exists){$row.movePlanned=$true;Set-RehearsalJournal $Entry $state;Move-RehearsalPath $row.before.path $row.saved;Assert-RehearsalPathState $row.before $row.saved}
 }
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots',$true)
 try{if($key){foreach($value in $state.markers.values){$key.DeleteValue($value.name,$false)}}}finally{if($key){$key.Dispose()}}
}
function Restore-RehearsalState($Entry){
 $state=$Entry.metadata
 if(-not$state.started){return}
 Restore-RehearsalPaths $Entry
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots',$true)
 try{
  if($key){$fresh=Get-RehearsalMarkers $state.roots
   $state.generatedMarkers=$fresh;Set-RehearsalJournal $Entry $state
   foreach($value in $fresh.values){$key.DeleteValue($value.name,$false)}
   foreach($value in $state.markers.values){$kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],$value.kind);$data=$value.value;if($kind -eq 'QWord'){$data=[long]$data}elseif($kind -eq 'DWord'){$data=[int]$data}elseif($kind -in 'Binary','None'){$data=[byte[]]$data}elseif($kind -eq 'MultiString'){$data=[string[]]$data};$key.SetValue($value.name,$data,$kind)}
  }elseif($state.markers.values.Count){throw 'Protected-folder registration key disappeared; retained.'}
 }finally{if($key){$key.Dispose()}}
 $parents=@($state.markers.parents);[array]::Reverse($parents)
 foreach($parent in $parents){if(-not$parent.exists){
  $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($parent.path)
  try{$empty=$key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0}finally{if($key){$key.Dispose()}}
  if($empty){[Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey($parent.path,$false)}
 }}
 $markers=Get-RehearsalMarkers $state.roots
 if(($markers|ConvertTo-Json -Depth 15 -Compress) -cne ($state.markers|ConvertTo-Json -Depth 15 -Compress)){throw 'Protected-folder registration restore differs; retained.'}
 $service=New-Object -ComObject Schedule.Service;$service.Connect()
 for($i=0;$i -lt $state.tasks.Count;$i++){
  $task=$state.tasks[$i];$folder=$service.GetFolder($task.folder)
  $found=@($folder.GetTasks(1)|Where-Object Name -CEQ $task.name)
  if($found.Count -and $found[0].Xml -cne $task.xml){throw 'Product task restore destination changed; retained.'}
  if(-not$found.Count){$null=$folder.RegisterTask($task.name,$task.xml,50,$task.user,$null,$task.logonType,$task.security)}
  $restored=$folder.GetTask($task.name)
  if($restored.Xml -cne $task.xml -or $restored.GetSecurityDescriptor(7) -cne $task.security -or $restored.Enabled -ne $task.enabled){throw 'Product task restore differs; retained.'}
 }
 if(((Get-RehearsalTasks)|Sort-Object folder,name|ConvertTo-Json -Depth 15 -Compress) -cne ($state.tasks|Sort-Object folder,name|ConvertTo-Json -Depth 15 -Compress)){throw 'Restored product tasks differ; retained.'}
 foreach($row in $state.paths){Assert-RehearsalPathState $row.before $row.before.path}
 $state.restored=$true;Set-RehearsalJournal $Entry $state;Set-HarnessEntryState $Entry.id 'restored'
}

function Restore-RehearsalPaths($Entry){
 $state=$Entry.metadata
 foreach($row in $state.paths){
  if($row.movePlanned -and (Test-HarnessPath $row.saved)){Assert-RehearsalPathState $row.before $row.saved}
  elseif($row.before.exists){Assert-RehearsalPathState $row.before $row.before.path}
 }
 foreach($row in $state.paths){
  $path=$row.before.path
  if($row.movePlanned -and -not(Test-HarnessPath $row.saved)){continue}
  if(Test-HarnessPath $path){
   if($row.before.exists -and -not$row.movePlanned){continue}
   if(-not$state.outputsReady -or -not$row.output){throw 'Restore destination is occupied without a recorded output snapshot; retained.'}
   Assert-RehearsalPathState $row.output $path
   $row.archivePlanned=$true;Set-RehearsalJournal $Entry $state
   Move-RehearsalPath $path $row.generated
  }
  if($row.before.exists -and (Test-HarnessPath $row.saved)){Move-RehearsalPath $row.saved $path}
  Assert-RehearsalPathState $row.before $path
 }
 foreach($row in $state.paths){if($row.archivePlanned){Assert-RehearsalPathState $row.output $row.generated}}
}
