param([Parameter(Mandatory)][string]$OutRoot,[string]$ToolRoot,
 [ValidateSet('All','Journey','JourneyEmpty','Recover','Compare','Untouched','TasksReady','TasksRunning','ForeignAccount','ForeignRoot','Atomic','Verify','Conflict','Reordered','ChangedField','BeforeOutput','Unsupported','Runner','ReplacedRoot','SelectedRoot','PreviousJournal','ReplaceError','ForeignJournal','CorruptPrimary')][string]$Case='All',
 [int]$KillAt=0,[switch]$SkipCrashMatrix,[switch]$MatrixOnly,[int]$MatrixParts=1,[int]$MatrixPart=0,[ValidateSet('Both','Journey','JourneyEmpty')][string]$MatrixVariant='Both')
$ErrorActionPreference='Stop'
if(-not$ToolRoot){$ToolRoot=$PSScriptRoot}
if($env:OS -eq 'Windows_NT'){throw 'Run the recovery fault-injection scenario on Linux PowerShell.'}
$env:COMPUTERNAME='fixture-machine'
function Read-Fixture([string]$Name){[IO.File]::ReadAllText((Join-Path $OutRoot $Name))|ConvertFrom-Json}
function Write-Fixture([string]$Name,$Value){[IO.File]::WriteAllText((Join-Path $OutRoot $Name),($Value|ConvertTo-Json -Depth 60))}
function Get-HarnessLongPath([string]$Path){$Path}
function Test-HarnessPath([string]$Path,[string]$PathType='Any'){if($PathType -eq 'Leaf'){return [IO.File]::Exists($Path)};[IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)}
function Get-HarnessItem([string]$Path,[switch]$Force){$i=Get-Item -LiteralPath $Path -Force;[pscustomobject]@{FullName=$i.FullName;IsDirectory=$i.PSIsContainer;Attributes=$i.Attributes}}
function Get-HarnessTree([string]$Path){Get-ChildItem -LiteralPath $Path -Recurse -Force|ForEach-Object {Get-HarnessItem $_.FullName}}
function Get-HarnessFileSha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ToolRoot 'Harness.Common.ps1'),[ref]$tokens,[ref]$errors)
foreach($name in 'Invoke-HarnessCheckpoint','Read-HarnessLedger','Get-HarnessLedgerGeneration','Invoke-HarnessLedger','Add-HarnessEntry','Get-HarnessEntries','Get-HarnessEntryById','Set-HarnessEntryState'){
 $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if($definition){Invoke-Expression $definition.Extent.Text}
}
if(-not(Get-Command Invoke-HarnessCheckpoint -ErrorAction SilentlyContinue)){function Invoke-HarnessCheckpoint([string]$Name){if($script:HarnessCheckpoint){& $script:HarnessCheckpoint $Name}}}
. (Join-Path $ToolRoot 'UpgradeRehearsal.State.ps1')
function Get-RehearsalCurrentSid{'fixture-user'}
function Get-RehearsalAccountSid([string]$User){$User}
function New-FixtureTask($Row){
 $task=[pscustomobject]@{Name=$Row.name;Xml=$Row.xml;Enabled=$Row.enabled;State=$Row.state;security=$Row.security;Definition=[pscustomobject]@{Principal=[pscustomobject]@{UserId=$Row.user;LogonType=$Row.logonType}}}
 $task|Add-Member ScriptMethod GetSecurityDescriptor {param($Flags) $this.security};return $task
}
function New-FixtureFolder([string]$Path){
 $folder=[pscustomobject]@{Path=$Path}
 $folder|Add-Member ScriptMethod GetTask {param($Name) $row=@((Read-Fixture 'scheduler.json').tasks|Where-Object {$_.folder -ceq $this.Path -and $_.name -ceq $Name});if($row.Count -ne 1){throw 'Fixture task missing.'};New-FixtureTask $row[0]}
 $folder|Add-Member ScriptMethod GetTasks {param($Flags) foreach($row in @((Read-Fixture 'scheduler.json').tasks|Where-Object folder -CEQ $this.Path)){New-FixtureTask $row}}
 $folder|Add-Member ScriptMethod CreateFolder {param($Name,$Security) $path='\'+$Name;$s=Read-Fixture 'scheduler.json';$s.folders=@($s.folders)+@($path);Write-Fixture 'scheduler.json' $s;New-FixtureFolder $path}
 $folder|Add-Member ScriptMethod RegisterTask {param($Name,$Xml,$Flags,$User,$Password,$Logon,$Security)
  $s=Read-Fixture 'scheduler.json';if(@($s.tasks|Where-Object {$_.folder -ceq $this.Path -and $_.name -ceq $Name}).Count){throw 'Fixture task collision.'}
  $enabled=([xml]$Xml).Task.Enabled -eq 'true';if($Flags -band 8){$enabled=$false}
  $row=@{name=$Name;folder=$this.Path;xml=$Xml;enabled=$enabled;user=$User;logonType=$Logon;security=$Security;state=3};$s.tasks=@($s.tasks)+@($row);Write-Fixture 'scheduler.json' $s;New-FixtureTask $row
 }
 $folder|Add-Member ScriptMethod DeleteTask {param($Name,$Flags) $s=Read-Fixture 'scheduler.json';$s.tasks=@($s.tasks|Where-Object {-not($_.folder -ceq $this.Path -and $_.name -ceq $Name)});Write-Fixture 'scheduler.json' $s}
 return $folder
}
function Get-RehearsalTaskService{
 $service=[pscustomobject]@{};$service|Add-Member ScriptMethod GetFolder {param($Path) New-FixtureFolder $Path};$service|Add-Member ScriptMethod Connect {};return $service
}
function New-Object([string]$ComObject){if($ComObject -cne 'Schedule.Service'){throw 'Unexpected fixture COM class.'};Get-RehearsalTaskService}
function Get-ScheduledTask{foreach($row in (Read-Fixture 'scheduler.json').tasks){[pscustomobject]@{TaskName=$row.name;TaskPath=$row.folder}}}
function Get-RehearsalMarkers([string[]]$Roots,[switch]$All){
 $markers=Read-Fixture 'markers.json'
 if(-not$All){$markers.values=@($markers.values|Where-Object {$name=$_.name;@($Roots|Where-Object {$name -ceq $_ -or $name.StartsWith($_+'|')}).Count})}
 return $markers
}
function Remove-RehearsalMarker([string]$Name){$markers=Read-Fixture 'markers.json';$markers.values=@($markers.values|Where-Object name -CNE $Name);Write-Fixture 'markers.json' $markers}
function Set-RehearsalMarker($Value){Remove-RehearsalMarker $Value.name;$markers=Read-Fixture 'markers.json';$markers.values=@($markers.values)+@($Value)|Sort-Object name;Write-Fixture 'markers.json' $markers}
function Remove-RehearsalEmptyMarkerParent([string]$Path){
 $markers=Read-Fixture 'markers.json'
 if($markers.values.Count){throw 'Fixture marker parent is not empty.'}
 foreach($parent in $markers.parents){if($parent.path -ceq $Path){$parent.exists=$false}}
 Write-Fixture 'markers.json' $markers
}
function Get-CimInstance([string]$Class){if($Class -cne 'Win32_Process'){throw 'Unexpected fixture query.'};@()}
function Launch{
 Add-HarnessEntry 'process' @{pid=999999;creationTimeFileTimeUtc='fixture-birth';imagePath='fixture-app'} 'app'|Out-Null
 [IO.File]::WriteAllText((Join-Path $OutRoot 'data/settings.json'),'generated app settings')
 [IO.File]::WriteAllText((Join-Path $OutRoot 'fresh/history.json'),'generated undo history')
 if($Case -eq 'JourneyEmpty'){
  $markers=Read-Fixture 'markers.json';foreach($parent in $markers.parents){$parent.exists=$true}
  $markers.values=@(@{name=(Join-Path $OutRoot 'data');kind='String';value='generated owner'});Write-Fixture 'markers.json' $markers
 }
}
function Remove-HarnessEntry($Entry){Set-HarnessEntryState $Entry.id 'absent'}
function Initialize-Fixture{
 if(Test-HarnessPath $OutRoot){throw 'Fixture output exists; retained.'}
 [IO.Directory]::CreateDirectory((Join-Path $OutRoot 'data/empty'))|Out-Null
 [IO.File]::WriteAllText((Join-Path $OutRoot 'data/settings.json'),'original settings')
 [IO.File]::WriteAllText((Join-Path $OutRoot 'data/.hidden'),'original hidden undo')
 [IO.File]::WriteAllText((Join-Path $OutRoot 'shortcut.lnk'),'original shortcut bytes')
 $tasks=@(foreach($name in 'Roo Industries Protected Session fixture','RooIndustries.Timer.fixture'){@{name=$name;folder='\';xml=('<Task><Name>'+$name+'</Name><Enabled>true</Enabled></Task>');security='fixture-owner-group-dacl';enabled=$true;user='fixture-user';logonType=3;state=3}})
 Write-Fixture 'scheduler.json' @{tasks=$tasks;folders=@('\')}
 Write-Fixture 'markers.json' @{parents=@(@{path='fixture-parent';exists=$true});values=@(@{name=(Join-Path $OutRoot 'data');kind='String';value='fixture-user'},@{name=((Join-Path $OutRoot 'data')+'|binary');kind='Binary';value=@(0,255,7)})}
 if($Case -eq 'JourneyEmpty'){Write-Fixture 'markers.json' @{parents=@(@{path='fixture-parent';exists=$false});values=@()}}
 Write-Fixture 'ledger.json' @{frameId='fixture';manifestSha256='fixture-hash';machine=$env:COMPUTERNAME;entries=@();invocations=@()}
 Write-Fixture 'before.json' @{paths=@(foreach($name in 'data','fresh','shortcut.lnk'){Get-RehearsalPathState (Join-Path $OutRoot $name)});tasks=$tasks;markers=(Read-Fixture 'markers.json')}
}
function Assert-FixtureRestored{
 $before=Read-Fixture 'before.json'
 foreach($path in $before.paths){Assert-RehearsalPathState $path $path.path}
 $tasks=@((Read-Fixture 'scheduler.json').tasks|Where-Object folder -CEQ '\'|Sort-Object name)
 if(-not(Test-RehearsalSnapshot @($before.tasks|Sort-Object name) $tasks)){throw 'Original fixture tasks differ.'}
 $markers=Read-Fixture 'markers.json'
 if(-not(Test-RehearsalSnapshot $before.markers $markers)){throw 'Original fixture markers differ.'}
 foreach($entry in @((Read-Fixture 'ledger.json').entries|Where-Object kind -EQ 'rehearsal-state')){if($entry.state -cne 'restored' -or -not$entry.metadata.restored){throw 'Recovery reported success without persisted completion.'}}
}
function Child([string]$Mode,[string]$Root,[int]$FailAt=0){
 $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'));$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-ToolRoot',$ToolRoot,'-OutRoot',$Root,'-Case',$Mode,'-KillAt',[string]$FailAt)){$info.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$code=$process.ExitCode
 $output=$stdout.Result+$stderr.Result;[IO.File]::WriteAllText(($Root+'.'+$Mode+'.log'),$output);$process.Dispose()
 if($code -ne 0){throw ('Child '+$Mode+' exited '+$code+': '+$output)}
}
$script:Harness=@{Root=$OutRoot;Nonce='fixture';LedgerPath=(Join-Path $OutRoot 'ledger.json');FrameId='fixture';Manifest='fixture-hash';ReadOnly=$false}
if($Case -eq 'All'){
 [IO.Directory]::CreateDirectory($OutRoot)|Out-Null;$results=[Collections.Generic.List[object]]::new()
 foreach($mode in @($(if(-not$MatrixOnly){'Compare','Untouched','TasksReady','TasksRunning','ForeignAccount','ForeignRoot','Atomic','Conflict','Reordered','ChangedField','BeforeOutput','Unsupported','Runner','ReplacedRoot','SelectedRoot','PreviousJournal','ReplaceError','ForeignJournal','CorruptPrimary'}))){
  try{Child $mode (Join-Path $OutRoot $mode);$results.Add(@{check=$mode;status='pass'})}catch{$results.Add(@{check=$mode;status='fail';error=$_.Exception.Message})}
 }
 if(-not$SkipCrashMatrix){
  foreach($journey in @($(if($MatrixVariant -eq 'Both'){'Journey','JourneyEmpty'}else{$MatrixVariant}))){
  $traceRoot=Join-Path $OutRoot ('trace-'+$journey);Child $journey $traceRoot
  $steps=@([IO.File]::ReadAllLines((Join-Path $traceRoot 'checkpoints.txt')))
  for($index=1;$index -le $steps.Count;$index++){
   if(($index-1)%$MatrixParts -ne $MatrixPart){continue}
   $root=Join-Path $OutRoot ($journey+'-kill-'+$index)
   $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'));$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
   foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-ToolRoot',$ToolRoot,'-OutRoot',$root,'-Case',$journey,'-KillAt',[string]$index)){$info.ArgumentList.Add($arg)}
   $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$code=$process.ExitCode;$process.Dispose()
   try{
    if($code -ne 137){throw ('Expected SIGKILL exit 137, received '+$code+': '+$stdout.Result+$stderr.Result)}
    if(@([IO.File]::ReadAllLines((Join-Path $root 'checkpoints.txt'))).Count -ne $index){throw ($stdout.Result+$stderr.Result+'; wrong termination boundary.')}
    [IO.File]::ReadAllText((Join-Path $root 'ledger.json'))|ConvertFrom-Json|Out-Null
    Child 'Recover' $root
    $ledger=Get-HarnessFileSha256 (Join-Path $root 'ledger.json');$scheduler=Get-HarnessFileSha256 (Join-Path $root 'scheduler.json');$markers=Get-HarnessFileSha256 (Join-Path $root 'markers.json')
    Child 'Recover' $root
    if($ledger -cne (Get-HarnessFileSha256 (Join-Path $root 'ledger.json')) -or $scheduler -cne (Get-HarnessFileSha256 (Join-Path $root 'scheduler.json')) -or $markers -cne (Get-HarnessFileSha256 (Join-Path $root 'markers.json'))){throw 'Second recovery wrote state.'}
    $results.Add(@{check=($journey+'-kill-'+$index);boundary=$steps[$index-1];status='pass'})
   }catch{$results.Add(@{check=($journey+'-kill-'+$index);boundary=$steps[$index-1];status='fail';error=$_.Exception.Message})}
   if($index%20 -eq 0){Write-Output ('Checked '+$index+'/'+$steps.Count+' termination boundaries')}
  }
  }
 }
 Write-Fixture 'result.json' @{checks=@($results);status=$(if(@($results|Where-Object status -NE 'pass').Count){'fail'}else{'pass'});nativeWindowsTested=$false}
 if(@($results|Where-Object status -NE 'pass').Count){throw ((@($results|Where-Object status -NE 'pass')|ConvertTo-Json -Depth 8))}
 Write-Output ('PASS '+$results.Count+' fresh-process recovery cases');return
}
if($Case -notin 'Recover','Verify'){Initialize-Fixture}
$script:CheckpointIndex=0
$script:HarnessCheckpoint={param($Name)
 $script:CheckpointIndex++;[IO.File]::AppendAllText((Join-Path $OutRoot 'checkpoints.txt'),($Name+"`n"))
 if($KillAt -gt 0 -and $script:CheckpointIndex -eq $KillAt){[Diagnostics.Process]::GetCurrentProcess().Kill();[Threading.Thread]::Sleep(10000)}
}
$paths=@(foreach($name in 'data','fresh','shortcut.lnk'){Join-Path $OutRoot $name});$roots=@($paths[0],$paths[1])
switch($Case){
 'SelectedRoot'{
  Write-Fixture 'markers.json' @{parents=@(@{path='fixture-parent';exists=$true});values=@()}
  $local=Join-Path $OutRoot 'local'
  $productRoots=@((Join-Path $local 'RooOptimizationSuite'),(Join-Path $local 'RooIndustriesOptimizationSuite'))
  [IO.Directory]::CreateDirectory($productRoots[0])|Out-Null
  [IO.File]::WriteAllText((Join-Path $productRoots[0] 'original.json'),'original legacy data')
  $entry=Save-RehearsalState $productRoots $productRoots;Suspend-RehearsalState $entry
  Initialize-RehearsalRoots $entry $productRoots[1]
  . (Join-Path $ToolRoot '../../../backend/scripts/BrandCompatibility.Common.ps1')
  function Test-RooIndustriesDataRootMarked([string]$Root){$false}
  function Test-RooIndustriesDataRootMigrationInFlight([string]$Parent,[string]$Name){$false}
  $selected=Get-RooIndustriesLocalDataRoot -LocalData $local
  if($selected -cne $productRoots[1] -or (Test-HarnessPath $productRoots[0])){throw 'The actual product selector uses another root from the rehearsal cache.'}
  [IO.File]::WriteAllText((Join-Path $selected 'generated.json'),'app output')
  Restore-RehearsalState $entry
  if([IO.File]::ReadAllText((Join-Path $productRoots[0] 'original.json')) -cne 'original legacy data' -or -not(Test-HarnessPath (Join-Path $entry.metadata.paths[1].generated 'generated.json'))){throw 'Selected-root recovery lost original or generated data.'}
 }
 'PreviousJournal'{
  $entry=Save-RehearsalState $paths $roots;Suspend-RehearsalState $entry;Initialize-RehearsalRoots $entry
  Invoke-HarnessLedger {param($ledger) $null}|Out-Null
  [IO.File]::Delete((Join-Path $OutRoot 'ledger.json'))
  Child 'Recover' $OutRoot;Child 'Recover' $OutRoot
  Assert-FixtureRestored
 }
 'ReplaceError'{
  $entry=Save-RehearsalState $paths $roots;Suspend-RehearsalState $entry;Initialize-RehearsalRoots $entry
  $ledger=Join-Path $OutRoot 'ledger.json';$committed=Get-HarnessFileSha256 $ledger
  $script:HarnessCheckpoint={param($Name)
   if($Name -cne 'journal:before-replace'){return}
   $script:HarnessCheckpoint=$null
   $path=$script:Harness.LedgerPath;[IO.File]::Delete($path+'.previous');[IO.File]::Move($path,$path+'.previous')
   throw [IO.IOException]::new('Unable to move the replacement file to the file to be replaced.',-2147023719)
  }
  $failed=$false;try{Start-RehearsalApp $entry}catch{$failed=$true}
  if(-not$failed -or (Test-HarnessPath $ledger) -or [IO.Directory]::GetFiles($OutRoot,'ledger.json.*.tmp').Count -or (Get-HarnessFileSha256 ($ledger+'.previous')) -cne $committed){throw 'A failed journal replacement kept its uncommitted generation or lost the committed one.'}
  Child 'Recover' $OutRoot;Child 'Recover' $OutRoot
  Assert-FixtureRestored
 }
 'ForeignJournal'{
  $entry=Save-RehearsalState $paths $roots;Suspend-RehearsalState $entry
  $saved=[IO.File]::ReadAllText((Join-Path $OutRoot 'ledger.json'))
  foreach($field in 'frameId','machine','manifestSha256'){
   $foreign=$saved|ConvertFrom-Json;$foreign.$field='foreign'
   Write-Fixture 'ledger.json.previous' $foreign
   [IO.File]::Delete((Join-Path $OutRoot 'ledger.json'))
   $before=Get-HarnessFileSha256 (Join-Path $OutRoot 'ledger.json.previous');$refused=$false
   try{Get-HarnessEntries|Out-Null}catch{$refused=$true}
   if(-not$refused -or (Test-HarnessPath (Join-Path $OutRoot 'ledger.json')) -or $before -cne (Get-HarnessFileSha256 (Join-Path $OutRoot 'ledger.json.previous'))){throw ('Foreign committed generation was accepted or changed: '+$field)}
  }
 }
 'CorruptPrimary'{
  Add-HarnessEntry 'file' @{path='fixture'} 'fixture'|Out-Null
  $previous=Get-HarnessFileSha256 (Join-Path $OutRoot 'ledger.json.previous')
  [IO.File]::WriteAllText((Join-Path $OutRoot 'ledger.json'),'{broken')
  $refused=$false;try{Get-HarnessEntries|Out-Null}catch{$refused=$true}
  if(-not$refused -or $previous -cne (Get-HarnessFileSha256 (Join-Path $OutRoot 'ledger.json.previous')) -or [IO.File]::ReadAllText((Join-Path $OutRoot 'ledger.json')) -cne '{broken'){throw 'Malformed primary silently selected or changed another generation.'}
 }
 'Compare'{Child 'Verify' $OutRoot}
 'Verify'{foreach($path in (Read-Fixture 'before.json').paths){Assert-RehearsalPathState $path $path.path}}
 'Untouched'{
  $entry=Save-RehearsalState $paths $roots;Restore-RehearsalState $entry
  $persisted=Get-HarnessEntryById $entry.id
  if($persisted.state -cne 'restored' -or -not$persisted.metadata.restored){throw 'Untouched recovery leaves an active journal.'}
  Child 'Recover' $OutRoot
 }
 'TasksReady'{
  $tasks=@(Get-RehearsalTasks);if($tasks.Count -ne 2){throw 'Current protected-session and timer tasks escape discovery.'}
  $entry=Save-RehearsalState $paths $roots;Suspend-RehearsalState $entry
  if(@(Get-RehearsalTasks).Count){throw 'Original tasks were not suspended.'}
  Child 'Recover' $OutRoot
 }
 'TasksRunning'{
  foreach($name in @((Read-Fixture 'scheduler.json').tasks.name)){
   $scheduler=Read-Fixture 'scheduler.json';foreach($task in $scheduler.tasks){$task.state=$(if($task.name -ceq $name){4}else{3})};Write-Fixture 'scheduler.json' $scheduler
   $refused=$false;try{Save-RehearsalState $paths $roots|Out-Null}catch{$refused=$true}
   if(-not$refused -or @((Read-Fixture 'ledger.json').entries).Count -or (Test-HarnessPath ($paths[0]+'.rehearsal-fixture'))){throw ('Running task was not refused before mutation: '+$name)}
  }
 }
 'Unsupported'{
  foreach($name in @((Read-Fixture 'scheduler.json').tasks.name)){
   foreach($variant in 'queued','unknown','credentials','subfolder'){
    $scheduler=Read-Fixture 'scheduler.json'
    foreach($task in $scheduler.tasks){$task.state=3;$task.logonType=3;$task.folder='\';if($task.name -ceq $name){if($variant -eq 'queued'){$task.state=2}elseif($variant -eq 'unknown'){$task.state=0}elseif($variant -eq 'subfolder'){$task.folder='\PerformanceVertexFixture\'}else{$task.logonType=1}}}
    Write-Fixture 'scheduler.json' $scheduler
    $refused=$false;try{Save-RehearsalState $paths $roots|Out-Null}catch{$refused=$true}
    if(-not$refused -or @((Read-Fixture 'ledger.json').entries).Count){throw ('Unsupported task was accepted: '+$name+' '+$variant)}
   }
  }
 }
 'ForeignAccount'{
  $scheduler=Read-Fixture 'scheduler.json';$scheduler.tasks[1].user='another-fixture-user';Write-Fixture 'scheduler.json' $scheduler
  $refused=$false;try{Save-RehearsalState $paths $roots|Out-Null}catch{$refused=$true};if(-not$refused -or @((Read-Fixture 'ledger.json').entries).Count){throw 'Foreign timer principal was accepted.'}
 }
 'ForeignRoot'{
  $markers=Read-Fixture 'markers.json';$markers.values+=@(@{name=(Join-Path $OutRoot 'another-account/data');kind='String';value='another-fixture-user'});Write-Fixture 'markers.json' $markers
  $refused=$false;try{Save-RehearsalState $paths $roots|Out-Null}catch{$refused=$true};if(-not$refused -or @((Read-Fixture 'ledger.json').entries).Count){throw 'Foreign registered root was accepted.'}
 }
 'Atomic'{
  $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'));$info.UseShellExecute=$false;$info.RedirectStandardError=$true
  foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-ToolRoot',$ToolRoot,'-OutRoot',($OutRoot+'-child'),'-Case','Journey','-KillAt','3')){$info.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($info);$process.WaitForExit();$process.Dispose()
  $ledger=[IO.File]::ReadAllText((Join-Path ($OutRoot+'-child') 'ledger.json'))|ConvertFrom-Json
  if(-not$ledger.frameId){throw 'Interrupted persistence destroyed the last complete generation.'}
 }
 {$_ -in 'Journey','JourneyEmpty'}{
  $entry=Save-RehearsalState $paths $roots
  Suspend-RehearsalState $entry;Initialize-RehearsalRoots $entry
  Start-RehearsalApp $entry;Stop-RehearsalWriters $entry;Save-RehearsalOutputs $entry
  Restore-RehearsalState $entry;Assert-FixtureRestored
 }
 'Recover'{
  $entries=@(Get-HarnessEntries|Where-Object kind -EQ 'rehearsal-state')
  if($entries.Count){Restore-RehearsalState $entries[0]}
  Assert-FixtureRestored
 }
 'Conflict'{
  $entry=Save-RehearsalState $paths $roots;Suspend-RehearsalState $entry
  [IO.Directory]::CreateDirectory($paths[0])|Out-Null;[IO.File]::WriteAllText((Join-Path $paths[0] 'foreign'),'unproved output')
  $refused=$false;try{Restore-RehearsalState $entry}catch{$refused=$true};if(-not$refused -or -not(Test-HarnessPath ($paths[0]+'.rehearsal-fixture'))){throw 'Unproved destination was overwritten.'}
 }
 'BeforeOutput'{
  $entry=Save-RehearsalState $paths $roots;$row=$entry.metadata.paths[0]
  $entry.metadata.started=$true;$row.movePlanned=$true;Set-RehearsalJournal $entry $entry.metadata
  Move-RehearsalPath $paths[0] $row.saved
  $staging=$paths[0]+'.owned';[IO.Directory]::CreateDirectory($staging)|Out-Null
  $row['claim']=(& stat -c '%d:%i:%W' -- $staging);Set-RehearsalJournal $entry $entry.metadata
  Move-RehearsalPath $staging $paths[0];[IO.File]::WriteAllText((Join-Path $paths[0] 'generated'),'old app wrote before the output checkpoint')
  Restore-RehearsalPaths $entry
  Child 'Recover' $OutRoot
  if([IO.File]::ReadAllText((Join-Path $row.generated 'generated')) -cne 'old app wrote before the output checkpoint'){throw 'Pre-checkpoint app output was lost.'}
 }
 'Reordered'{
  $entry=Save-RehearsalState $paths $roots
  function Reverse-Properties($Value){
   if($null -eq $Value){return $null}
   if($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]){$r=[ordered]@{};$names=@($(if($Value -is [Collections.IDictionary]){$Value.Keys}else{$Value.PSObject.Properties.Name})|Sort-Object -Descending);foreach($name in $names){$r[$name]=Reverse-Properties $Value.$name};return $r}
   if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){return ,@(foreach($item in $Value){Reverse-Properties $item})};return $Value
  }
  Write-Fixture 'ledger.json' (Reverse-Properties (Read-Fixture 'ledger.json'));Child 'Recover' $OutRoot
 }
 'ChangedField'{
  $entry=Save-RehearsalState $paths $roots
  $original=[IO.File]::ReadAllText((Join-Path $OutRoot 'ledger.json'))
  foreach($field in 'relative','directory','attributes','created','written','security','sha256','task.xml','task.security','task.enabled','task.user','task.logonType','marker.kind','marker.value','marker.name','parent.exists'){
   $ledger=$original|ConvertFrom-Json;$state=$ledger.entries[0].metadata
   switch -Regex ($field){
    '^task\.'{$name=$field.Substring(5);$state.tasks[0].$name=$(if($name -eq 'enabled'){-not$state.tasks[0].enabled}elseif($name -eq 'logonType'){5}else{'changed'});break}
    '^marker\.'{$state.markers.values[0].($field.Substring(7))='changed';break}
    '^parent\.'{$state.markers.parents[0].exists=$false;break}
    default{$item=$state.paths[0].before.items[0];$item.$field=$(if($field -eq 'directory'){-not$item.directory}elseif($field -in 'created','written','attributes'){[long]$item.$field+1}else{'changed'})}
   }
   Write-Fixture 'ledger.json' $ledger
   $refused=$false;try{Restore-RehearsalState $entry}catch{$refused=$true};if(-not$refused){throw ('A changed snapshot field was ignored: '+$field)}
  }
 }
 'Runner'{
  $entry=Save-RehearsalState $paths $roots
  $runner=Add-HarnessEntry 'process' @{pid=999998;creationTimeFileTimeUtc='fixture-runner';imagePath='fixture-wrapper'} 'interactive-wrapper' 'runner'
  Suspend-RehearsalState $entry;Restore-RehearsalState $entry
  if((Get-HarnessEntryById $runner.id).state -cne 'active'){throw 'Recovery stopped the supervising runner.'}
 }
 'ReplacedRoot'{
  $entry=Save-RehearsalState $paths $roots;Suspend-RehearsalState $entry;Initialize-RehearsalRoots $entry
  Move-RehearsalPath $paths[0] ($paths[0]+'.replaced');[IO.Directory]::CreateDirectory($paths[0])|Out-Null
  foreach($action in @({Save-RehearsalOutputs $entry},{Restore-RehearsalState $entry})){
   $refused=$false;try{& $action}catch{$refused=$true};if(-not$refused){throw 'A replacement root was accepted as owned output.'}
  }
  if(-not(Test-HarnessPath $entry.metadata.paths[0].saved)){throw 'Original archive was lost.'}
 }
}
