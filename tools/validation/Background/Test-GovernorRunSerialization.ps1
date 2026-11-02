param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[string]$Worker='',[string]$GateName='',[switch]$Unserialized)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'backend/scripts/ProcessGovernor.Common.ps1')
$utf8=[Text.UTF8Encoding]::new($false)
function Save([string]$Name,$Value){[IO.File]::WriteAllText((Join-Path $OutRoot ($Name+'.json')),($Value|ConvertTo-Json -Depth 20),$utf8)}
function Stamp([string]$Name){[IO.File]::WriteAllText((Join-Path $OutRoot $Name),[DateTime]::UtcNow.Ticks.ToString(),$utf8)}
function Wait-File([string]$Name,[int]$Milliseconds){$clock=[Diagnostics.Stopwatch]::StartNew();while(-not[IO.File]::Exists((Join-Path $OutRoot $Name)) -and $clock.ElapsedMilliseconds -lt $Milliseconds){Start-Sleep -Milliseconds 20}}
if($Worker){
 function Get-RooIndustriesFileStamp {'fixed-second'}
 $action={
  if($Worker -eq 'crash'){Stamp 'owner-entered';Start-Sleep -Seconds 30;return}
  $gate=$null;$held=$false
  $id=New-RooIndustriesProcessGovernorSessionId 'fixture';$sessionDirectory=Join-Path $OutRoot $id;[IO.Directory]::CreateDirectory($sessionDirectory)|Out-Null
  Stamp ($Worker+'-created')
  if($Worker -eq 'first'){Wait-File 'second-written' 800}
  $before=[IO.File]::ReadAllText((Join-Path $OutRoot 'value'))
  [IO.File]::WriteAllText((Join-Path $sessionDirectory 'backup.json'),(@{original=$before;owner=$Worker}|ConvertTo-Json),$utf8)
  [IO.File]::WriteAllText((Join-Path $OutRoot 'value'),$Worker,$utf8)
  Stamp ($Worker+'-written')
  Save $Worker @{sessionId=$id;original=$before;value=$Worker}
 }
 if($Worker -eq 'denied-holder'){
  $everyone=[Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::WorldSid,$null)
  $security=[Security.AccessControl.MutexSecurity]::new();$security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($everyone,[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Deny))
  $created=$false;$denied=New-Object Threading.Mutex($true,$GateName,[ref]$created,$security)
  try{if(-not$created){throw 'The denied gate already existed.'};Stamp 'denied-held';Start-Sleep -Seconds 3;Stamp 'denied-releasing'}finally{$denied.ReleaseMutex();$denied.Dispose()}
  exit 0
 }
 if(-not$Unserialized -and (Get-Command Invoke-RooIndustriesProcessGovernorRun -ErrorAction SilentlyContinue)){Invoke-RooIndustriesProcessGovernorRun -Action $action -ConfirmApply -GateName $GateName}
 else{& $action}
 exit 0
}
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
if([IO.File]::Exists((Join-Path $OutRoot 'value'))){throw 'Use a new owned output directory.'}
[IO.File]::WriteAllText((Join-Path $OutRoot 'value'),'original',$utf8)
if(-not$Unserialized){
 $parseErrors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source 'backend/scripts/Start-ProcessGovernorSession.ps1'),[ref]$tokens,[ref]$parseErrors)
 $body=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
 if($parseErrors.Count -or $body.Count -ne 1 -or $body[0].Body.Statements.Count -ne 1){throw 'The live Start body must execute inside one run boundary.'}
 $command=$body[0].Body.Statements[0].PipelineElements[0]
 $confirmation=@($command.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ConfirmApply'})
 if($command.GetCommandName() -ne 'Invoke-RooIndustriesProcessGovernorRun' -or $confirmation.Count -ne 1 -or $confirmation[0].Argument.VariablePath.UserPath -ne 'ConfirmApply'){throw 'The live Start entry must use the same confirmed run boundary as this journey.'}
}
$GateName='RooIndustriesGovernorSerializationFixture-'+[Guid]::NewGuid().ToString('N')
$workers=New-Object System.Collections.Generic.List[object]
$pwsh=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
function Launch([string]$Name){
 $arguments=@('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Source',$Source,'-OutRoot',$OutRoot,'-Worker',$Name,'-GateName',$GateName)
 if($Unserialized){$arguments+='-Unserialized'}
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$pwsh;$start.UseShellExecute=$false
 $start.Arguments=(@($arguments|ForEach-Object {ConvertTo-RooIndustriesWindowsArgument $_}) -join ' ')
 $process=[Diagnostics.Process]::Start($start);$workers.Add($process)|Out-Null;return $process
}
try{
 $first=Launch 'first';Wait-File 'first-created' 10000
 if(-not[IO.File]::Exists((Join-Path $OutRoot 'first-created'))){throw 'The first worker did not reach session creation.'}
 $second=Launch 'second'
 foreach($process in $workers){if(-not$process.WaitForExit(20000)){throw 'The owned worker did not finish.'};if($process.ExitCode -ne 0){throw 'An owned worker failed.'}}
 $a=Get-Content -Raw (Join-Path $OutRoot 'first.json')|ConvertFrom-Json;$b=Get-Content -Raw (Join-Path $OutRoot 'second.json')|ConvertFrom-Json
 $createdSecond=[long][IO.File]::ReadAllText((Join-Path $OutRoot 'second-created'));$writtenFirst=[long][IO.File]::ReadAllText((Join-Path $OutRoot 'first-written'))
 $ordered=$createdSecond -gt $writtenFirst -and $a.original -eq 'original' -and $b.original -eq 'first'
 $unique=$a.sessionId -ne $b.sessionId
 $backupA=Get-Content -Raw (Join-Path (Join-Path $OutRoot $a.sessionId) 'backup.json')|ConvertFrom-Json
 $backupB=Get-Content -Raw (Join-Path (Join-Path $OutRoot $b.sessionId) 'backup.json')|ConvertFrom-Json
 $owned=$backupA.owner -eq 'first' -and $backupB.owner -eq 'second'
 if($owned){[IO.File]::WriteAllText((Join-Path $OutRoot 'value'),[string]$backupB.original,$utf8);[IO.File]::WriteAllText((Join-Path $OutRoot 'value'),[string]$backupA.original,$utf8)}
 $restored=[IO.File]::ReadAllText((Join-Path $OutRoot 'value')) -eq 'original'
 Save 'summary' @{proof='Two-process governor run protocol with disk fixtures; not native Windows process proof';ordered=$ordered;unique=$unique;owned=$owned;restored=$restored;first=$a;second=$b}
 if(-not$ordered -or -not$unique -or -not$owned -or -not$restored){throw 'Concurrent runs did not preserve unique, ordered original-value journals.'}
 $GateName+='-recovery';$owner=Launch 'crash';Wait-File 'owner-entered' 10000
 if(-not[IO.File]::Exists((Join-Path $OutRoot 'owner-entered'))){throw 'The owned crash worker did not enter its run.'}
 Invoke-RooIndustriesProcessGovernorRun -GateName $GateName -Action {Stamp 'preview'}
 $preview=[IO.File]::Exists((Join-Path $OutRoot 'preview')) -and -not$owner.HasExited
 $owner.Kill();$owner.WaitForExit(5000)|Out-Null
 $afterCrash=Launch 'after-crash';if(-not$afterCrash.WaitForExit(10000) -or $afterCrash.ExitCode -ne 0){throw 'The next run could not recover an abandoned gate.'}
 try{Invoke-RooIndustriesProcessGovernorRun -GateName $GateName -ConfirmApply -Action {throw 'Owned fixture failure'}}catch{if($_.Exception.Message -notmatch 'Owned fixture failure'){throw}}
 $afterFailure=Launch 'after-failure';if(-not$afterFailure.WaitForExit(10000) -or $afterFailure.ExitCode -ne 0){throw 'The next run could not acquire the gate after failure.'}
 $GateName=$GateName.Replace('-recovery','-busy');Remove-Item -LiteralPath (Join-Path $OutRoot 'owner-entered');$holder=Launch 'crash';Wait-File 'owner-entered' 10000
 $busyRan=$false;$actionRan=$false
 Invoke-RooIndustriesProcessGovernorRun -GateName $GateName -ConfirmApply -Wait ([TimeSpan]::FromSeconds(1)) -Busy {$script:busyRan=$true} -Action {$script:actionRan=$true}
 $holder.Kill();$holder.WaitForExit(5000)|Out-Null
 $busy=$busyRan -and -not$actionRan
 $deniedChecked=$false;$deniedWaited=$false
 if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
  $GateName=$GateName.Replace('-busy','-denied');$deniedHolder=Launch 'denied-holder';Wait-File 'denied-held' 10000
  if(-not[IO.File]::Exists((Join-Path $OutRoot 'denied-held'))){throw 'The denied gate holder did not start.'}
  Invoke-RooIndustriesProcessGovernorRun -GateName $GateName -ConfirmApply -Wait ([TimeSpan]::FromSeconds(30)) -Busy {throw 'A gate the current token cannot open was reported busy instead of waited for.'} -Action {Stamp 'denied-acquired'}
  if(-not$deniedHolder.WaitForExit(10000)){throw 'The denied gate holder did not finish.'}
  $deniedChecked=$true
  $deniedWaited=[long][IO.File]::ReadAllText((Join-Path $OutRoot 'denied-acquired')) -ge [long][IO.File]::ReadAllText((Join-Path $OutRoot 'denied-releasing'))
 }
 Save 'recovery' @{previewDoesNotWait=$preview;abandonedOwnerReleased=$afterCrash.HasExited;failedActionReleased=$afterFailure.HasExited;busyReported=$busy;deniedGateChecked=$deniedChecked;deniedGateWaited=$deniedWaited}
 if(-not$preview){throw 'A preview waited for the confirmed run.'}
 if(-not$busy){throw 'A run that could not get the gate in time did not report busy, or ran anyway.'}
 if($deniedChecked -and -not$deniedWaited){throw 'A gate the current token could not open was not waited for.'}
 'PASS Concurrent runs preserve unique journals and actual write order; newest-first restore returns the original.'
}finally{
 foreach($process in $workers){if(-not$process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null}}
 Save 'cleanup' @{allWorkersExited=(@($workers|Where-Object {-not$_.HasExited}).Count -eq 0)}
}
