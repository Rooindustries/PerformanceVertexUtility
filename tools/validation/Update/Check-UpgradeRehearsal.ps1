param([Parameter(Mandatory)][string]$OutRoot,[string]$ToolRoot=$PSScriptRoot,[string]$Source)
$ErrorActionPreference='Stop'
if($Source){. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1');Initialize-HarnessInvocation 'upgrade-file-checks' $OutRoot|Out-Null;Ensure-HarnessOutputDirectory $OutRoot}
if(-not$Source){[IO.Directory]::CreateDirectory($OutRoot)|Out-Null}
$rows=[Collections.Generic.List[object]]::new()
try{
 if(-not$Source){
 function Invoke-HarnessCheckpoint([string]$Name){}
 function Get-HarnessLongPath([string]$Path){$Path}
 function Get-HarnessToolPath([string]$Path){$Path}
 function Test-HarnessPath([string]$Path){[IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)}
 function Get-HarnessItem([string]$Path,[switch]$Force){$i=Get-Item -LiteralPath $Path -Force;[pscustomobject]@{FullName=$i.FullName;IsDirectory=$i.PSIsContainer;Attributes=$i.Attributes}}
 function Get-HarnessTree([string]$Path){Get-ChildItem -LiteralPath $Path -Recurse -Force|ForEach-Object {Get-HarnessItem $_.FullName}}
 function Get-HarnessFileSha256([string]$Path){$sha=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path);try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$sha.Dispose()}}
 }
 . (Join-Path $ToolRoot 'UpgradeRehearsal.State.ps1')
 function Set-RehearsalJournal($Entry,$State){[IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $OutRoot 'fixture-ledger.json')),(@{entry=$Entry;state=$State}|ConvertTo-Json -Depth 40))}
 function Refuses([string]$Name,[scriptblock]$Action){$refused=$false;try{& $Action}catch{$refused=$true};if(-not$refused){throw ('Did not refuse: '+$Name)};$rows.Add(@{check=$Name;status='pass'})}
 $fixture=Join-Path $OutRoot 'fixtures'
 if(Test-HarnessPath $fixture){throw 'Fixture output exists; retained.'}
 [IO.Directory]::CreateDirectory((Get-HarnessLongPath $fixture))|Out-Null
 $path=Join-Path $fixture 'data';[IO.Directory]::CreateDirectory((Get-HarnessLongPath (Join-Path $path 'empty')))|Out-Null
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $path 'settings.json')),'original settings')
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $path '.hidden')),'hidden history')
 $before=Get-RehearsalPathState $path
 $row=@{before=$before;saved=($path+'.saved');generated=($path+'.output');movePlanned=$true;archivePlanned=$false;output=$null}
 $entry=@{id='fixture';metadata=@{paths=@($row);outputsReady=$false}}
 Set-RehearsalJournal $entry $entry.metadata
 $entry=([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $OutRoot 'fixture-ledger.json')))|ConvertFrom-Json).entry;$row=$entry.metadata.paths[0]
 Move-RehearsalPath $path $row.saved
 Assert-RehearsalPathState $before $row.saved
 $rows.Add(@{check='move retains all files, hidden files and empty directories';status='pass'})
 [IO.Directory]::CreateDirectory((Get-HarnessLongPath $path))|Out-Null;[IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $path 'new-data')),'generated data')
 Refuses 'occupied restore destination without output proof' {Restore-RehearsalPaths $entry}
 if(-not(Test-HarnessPath $row.saved) -or -not(Test-HarnessPath $path)){throw 'Conflict refusal lost a side.'}
 $row.output=Get-RehearsalPathState $path;$entry.metadata.outputsReady=$true
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $path 'new-data')),'changed after snapshot')
 Refuses 'changed generated data retained' {Restore-RehearsalPaths $entry}
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $path 'new-data')),'generated data')
 $row.output=Get-RehearsalPathState $path
 Restore-RehearsalPaths $entry
 Assert-RehearsalPathState $before $path
 if([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $row.generated 'new-data'))) -cne 'generated data'){throw 'Generated data was lost.'}
 $rows.Add(@{check='restore original hashes and retain generated data';status='pass'})
 Restore-RehearsalPaths $entry
 $rows.Add(@{check='restore is repeatable after a completed rename';status='pass'})
 $absent=Join-Path $fixture 'fresh'
 $fresh=@{before=(Get-RehearsalPathState $absent);saved=($absent+'.saved');generated=($absent+'.output');movePlanned=$false;archivePlanned=$false;output=$null}
 [IO.Directory]::CreateDirectory((Get-HarnessLongPath $absent))|Out-Null;[IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $absent 'history')),'new history')
 $fresh.output=Get-RehearsalPathState $absent
 Restore-RehearsalPaths @{id='fresh';metadata=@{paths=@($fresh);outputsReady=$true}}
 if((Test-HarnessPath $absent) -or -not(Test-HarnessPath $fresh.generated)){throw 'Fresh root was not retained outside the app path.'}
 $rows.Add(@{check='fresh data root returns to absent without deleting its data';status='pass'})
 $deep=Join-Path $fixture 'deep';$nested=$deep
 foreach($number in 1..4){$nested=Join-Path $nested ('nested-'+('x'*60)+$number)}
 [IO.Directory]::CreateDirectory((Get-HarnessLongPath $nested))|Out-Null;[IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $nested 'history.json')),'deep undo history')
 $deepBefore=Get-RehearsalPathState $deep
 Move-RehearsalPath $deep ($deep+'.saved');Assert-RehearsalPathState $deepBefore ($deep+'.saved');Move-RehearsalPath ($deep+'.saved') $deep;Assert-RehearsalPathState $deepBefore $deep
 $rows.Add(@{check='data beyond 259 characters survives archive and restore';status='pass';windowsAclTested=[bool]$Source})
 $link=Join-Path $fixture 'shortcut.lnk';[IO.File]::WriteAllText((Get-HarnessLongPath $link),'shortcut bytes')
 $linkBefore=Get-RehearsalPathState $link;Move-RehearsalPath $link ($link+'.saved');Move-RehearsalPath ($link+'.saved') $link;Assert-RehearsalPathState $linkBefore $link
 $rows.Add(@{check='shortcut bytes restored exactly';status='pass'})
 Move-RehearsalPath $path $row.saved
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $row.saved 'settings.json')),'tampered')
 Refuses 'changed archived original refused before restore' {Restore-RehearsalPaths $entry}
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $row.saved 'settings.json')),'original settings')
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $row.saved 'extra')),'extra')
 Refuses 'extra archived original file refused' {Restore-RehearsalPaths $entry}
 $missing=Join-Path $fixture 'missing'
 Refuses 'missing both original and archive' {Restore-RehearsalPaths @{metadata=@{paths=@(@{before=$before;saved=$missing;movePlanned=$true});outputsReady=$false}}}
 Refuses 'existing archive destination' {Move-RehearsalPath $link $row.saved}
 Refuses 'cross-directory move' {Move-RehearsalPath $link (Join-Path $row.saved 'other')}
 $interrupted=Join-Path $fixture 'interrupted';[IO.File]::WriteAllText((Get-HarnessLongPath $interrupted),'before rename')
 $interruptedBefore=Get-RehearsalPathState $interrupted
 Restore-RehearsalPaths @{metadata=@{paths=@(@{before=$interruptedBefore;saved=($interrupted+'.saved');movePlanned=$true});outputsReady=$false}}
 $rows.Add(@{check='journal intent written before a rename that never happened';status='pass'})
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $OutRoot 'result.json')),(@{status='pass';checks=@($rows);windowsTasksAndRegistryTested=$false;windowsAclTested=[bool]$Source}|ConvertTo-Json -Depth 15))
 if($Source){Complete-HarnessInvocation 'pass' -Cleanup|Out-Null}
 Write-Output ('PASS '+$rows.Count+' rehearsal cases; real filesystem, fixture ledger, Windows tasks/registry deferred.')
}catch{
 [IO.File]::WriteAllText((Get-HarnessLongPath (Join-Path $OutRoot 'result.json')),(@{status='fail';checks=@($rows);error=$_.Exception.Message}|ConvertTo-Json -Depth 15));throw
}
