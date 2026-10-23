param([string]$Source='',[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,[string]$DriverPath='',[switch]$ExpectOldRace,[switch]$Producer,[ValidateSet('gate','ready','missing','malformed')][string]$ProducerMode='gate',[string]$Nonce='')
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
if($Producer){
 $receipt=Join-Path $OutRoot 'receipt.json'
 $release=Join-Path $OutRoot 'release.txt'
 [IO.File]::WriteAllText((Join-Path $OutRoot 'ready.txt'),$Nonce,$utf8)
 if($ProducerMode -ceq 'missing'){return}
 if($ProducerMode -ceq 'gate'){
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not[IO.File]::Exists($release)){if($clock.Elapsed.TotalSeconds -gt 20){throw 'Receipt producer release timed out.'};Start-Sleep -Milliseconds 10}
 }
 $text=if($ProducerMode -ceq 'malformed'){'{'}else{@{nonce=$Nonce;sourceCommit=$SourceCommit;producerPid=$PID;payload='receipt-fixture'}|ConvertTo-Json -Compress}
 $temporary=$receipt+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllText($temporary,$text,$utf8)
 [IO.File]::Move($temporary,$receipt)
 return
}
if([string]::IsNullOrWhiteSpace($Source)){throw 'Source is required for the receipt consumer E2E.'}
$Source=[IO.Path]::GetFullPath($Source);$OutRoot=[IO.Path]::GetFullPath($OutRoot)
if([IO.Directory]::Exists($OutRoot) -or [IO.File]::Exists($OutRoot)){throw 'Receipt E2E requires a new owned evidence directory.'}
$null=[IO.Directory]::CreateDirectory($OutRoot)
function Check([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
function Save([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),$utf8)}
function Function-Source([string]$Path,[string]$Name){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ('Source parse failed: '+$Path)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
 Check ($nodes.Count -eq 1) ('Expected one actual function: '+$Name)
 return $nodes[0].Extent.Text
}
if(-not$DriverPath){$DriverPath=Join-Path $Source 'tools/validation/Background/Test-RestoreSerialization.ps1'}
$DriverPath=[IO.Path]::GetFullPath($DriverPath)
$functionName=if($ExpectOldRace){'Wait-Actor'}else{'Read-ActorReceipt'}
$actualFunction=Function-Source $DriverPath $functionName
. ([scriptblock]::Create($actualFunction))
$quotePath=Join-Path $Source 'backend/scripts/ProcessProfile.Common.ps1'
. ([scriptblock]::Create((Function-Source $quotePath 'ConvertTo-RooIndustriesWindowsArgument')))
. ([scriptblock]::Create((Function-Source $quotePath 'Join-RooIndustriesWindowsArguments')))
$binaryProcess=[Diagnostics.Process]::GetCurrentProcess()
try{$binary=$binaryProcess.MainModule.FileName}finally{$binaryProcess.Dispose()}
$cases=New-Object System.Collections.Generic.List[object]
$names=if($ExpectOldRace){@('publication-at-exit')}else{@('publication-at-exit','already-published','missing-on-exit','timeout','malformed')}
foreach($name in $names){
 $directory=Join-Path $OutRoot $name;$null=[IO.Directory]::CreateDirectory($directory)
 $nonce=[guid]::NewGuid().ToString('N');$receiptPath=Join-Path $directory 'receipt.json';$releasePath=Join-Path $directory 'release.txt'
 $mode=switch($name){'already-published'{'ready'};'missing-on-exit'{'missing'};'malformed'{'malformed'};default{'gate'}}
 $process=$null;$breakpoint=$null;$stdout=$null;$stderr=$null;$record=$null;$observedError=$null;$bodyError=$null
 $cleanupErrors=New-Object System.Collections.Generic.List[Exception]
 $state=[pscustomobject]@{reads=0;released=$false;missingBeforeRelease=$false;exitedBeforeProperty=$false;publishedBeforeProperty=$false;error=$null;process=$null;receipt=$receiptPath;release=$releasePath;nonce=$nonce}
 $elapsed=[Diagnostics.Stopwatch]::new();$childId=0;$childStart='';$ended=$false;$casePassed=$false
 try{
  $info=[Diagnostics.ProcessStartInfo]::new($binary);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.Arguments=Join-RooIndustriesWindowsArguments @('-NoLogo','-NoProfile','-File',$PSCommandPath,'-Producer','-OutRoot',$directory,'-SourceCommit',$SourceCommit,'-ProducerMode',$mode,'-Nonce',$nonce)
  $process=[Diagnostics.Process]::Start($info);$state.process=$process;$childId=$process.Id;$childStart=$process.StartTime.ToUniversalTime().ToString('o')
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  Save (Join-Path $directory 'owned-process.json') @{processId=$childId;startTimeUtc=$childStart;image=$binary;arguments=$info.Arguments}
  $readyClock=[Diagnostics.Stopwatch]::StartNew()
  while(-not[IO.File]::Exists((Join-Path $directory 'ready.txt'))){
   if($process.HasExited){if(-not[IO.File]::Exists((Join-Path $directory 'ready.txt'))){throw 'Receipt producer did not become ready.'};break}
   if($readyClock.Elapsed.TotalSeconds -gt 5){throw 'Receipt producer did not become ready.'}
   Start-Sleep -Milliseconds 10
  }
  Check ([IO.File]::ReadAllText((Join-Path $directory 'ready.txt')) -ceq $nonce) 'Ready receipt nonce changed.'
  if($mode -cne 'gate'){Check ($process.WaitForExit(10000)) 'Receipt producer did not exit before the selected case.'}
  $receiptActor=[pscustomobject]@{process=$process;output=$receiptPath}
  if($name -ceq 'publication-at-exit'){
   Check (-not[IO.File]::Exists($receiptPath) -and -not$process.HasExited) 'Race producer was not waiting with no receipt.'
   $breakpoint=Set-PSBreakpoint -Variable actor -Mode Read -Action ({
    $state.reads=$state.reads+1
    if($state.reads -eq 2){
     try{
      $state.missingBeforeRelease=-not[IO.File]::Exists($state.receipt)
      [IO.File]::WriteAllText($state.release,$state.nonce)
      $state.released=$true
      if(-not$state.process.WaitForExit(10000)){throw 'Race producer did not exit.'}
      $state.exitedBeforeProperty=$state.process.HasExited
      $state.publishedBeforeProperty=[IO.File]::Exists($state.receipt)
     }catch{$state.error=$_.Exception.ToString()}
    }
   }.GetNewClosure())
  }
  $elapsed.Start()
  try{
   $record=if($ExpectOldRace){Wait-Actor $receiptActor}else{Read-ActorReceipt $receiptActor}
  }catch{$observedError=$_}
  finally{$elapsed.Stop();if($breakpoint){Remove-PSBreakpoint $breakpoint;$breakpoint=$null}}
  if($name -ceq 'publication-at-exit'){
   Check ($null -eq $state.error -and $state.released -and $state.missingBeforeRelease -and $state.exitedBeforeProperty -and $state.publishedBeforeProperty) 'The exact publication-between-existence-and-exit ordering is missing.'
  }
  if($ExpectOldRace){Check ($null -ne $observedError -and $observedError.Exception.Message -ceq 'Actor did not produce its original receipt.' -and $null -eq $record) 'Old source did not expose the precise lost-receipt failure.'}
  elseif($name -in @('publication-at-exit','already-published')){
   Check ($null -eq $observedError -and $null -ne $record) 'A completed producer receipt was refused.'
   Check ($record.nonce -ceq $nonce -and $record.sourceCommit -ceq $SourceCommit -and $record.producerPid -eq $childId -and $record.payload -ceq 'receipt-fixture') 'The actual producer receipt differs from its original inputs/process.'
  }elseif($name -eq 'malformed'){
   Check ($null -ne $observedError -and $null -eq $record -and $observedError.Exception.Message -cne 'Actor did not produce its original receipt.') 'Malformed completed JSON was not refused by its actual parser.'
  }else{
   Check ($null -ne $observedError -and $observedError.Exception.Message -ceq 'Actor did not produce its original receipt.' -and $null -eq $record -and -not[IO.File]::Exists($receiptPath)) 'Missing receipt did not refuse completion.'
   if($name -ceq 'timeout'){Check ($elapsed.Elapsed.TotalSeconds -ge 10 -and $elapsed.Elapsed.TotalSeconds -lt 15 -and -not$process.HasExited) 'The real ten-second timeout was not observed with a live producer.'}
  }
  $casePassed=$true
 }catch{$bodyError=$_.Exception}
 finally{
  if($breakpoint){try{Remove-PSBreakpoint $breakpoint}catch{$cleanupErrors.Add($_.Exception)|Out-Null}}
  if($process){
   try{
    if(-not$process.HasExited){[IO.File]::WriteAllText($releasePath,$nonce,$utf8)}
    if(-not$process.WaitForExit(30000)){throw 'Owned receipt producer remains live; no process was signalled.'}
    $ended=$process.HasExited
    Check ($ended -and $process.Id -eq $childId -and $process.StartTime.ToUniversalTime().ToString('o') -ceq $childStart) 'Original producer identity/end receipt changed.'
    Check ($process.ExitCode -eq 0) 'The owned producer failed.'
    [IO.File]::WriteAllText((Join-Path $directory 'stdout.log'),$stdout.GetAwaiter().GetResult(),$utf8)
    [IO.File]::WriteAllText((Join-Path $directory 'stderr.log'),$stderr.GetAwaiter().GetResult(),$utf8)
   }catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   finally{if($ended){$process.Dispose()}}
  }
  $observation=@{name=$name;passed=($casePassed -and -not$ExpectOldRace -and $cleanupErrors.Count -eq 0);validOldRegression=([bool]$ExpectOldRace -and $casePassed -and $cleanupErrors.Count -eq 0);elapsedMs=$elapsed.Elapsed.TotalMilliseconds;ordering=@{variableReads=$state.reads;released=$state.released;missingBeforeRelease=$state.missingBeforeRelease;exitedBeforeProperty=$state.exitedBeforeProperty;publishedBeforeProperty=$state.publishedBeforeProperty;error=$state.error};record=$record;error=$(if($observedError){$observedError.Exception.ToString()}else{$null});bodyError=$(if($bodyError){$bodyError.ToString()}else{$null});cleanupErrors=@($cleanupErrors|ForEach-Object {$_.ToString()});originalProcessId=$childId;originalStartTimeUtc=$childStart;originalProcessEnded=$ended;liveProcessRetained=(-not$ended -and $null -ne $process)}
  Save (Join-Path $directory 'case.json') $observation;$cases.Add($observation)|Out-Null
  Save (Join-Path $OutRoot 'summary.json') @{scope='Real child/file receipt-consumer E2E only; no native actor, Windows ownership, restore or native API proof';sourceCommit=$SourceCommit;driverPath=$DriverPath;driverSha256=(Get-FileHash -LiteralPath $DriverPath -Algorithm SHA256).Hash;function=$functionName;engine=$PSVersionTable.PSVersion.ToString();expectedCases=$names.Count;actualCases=$cases.Count;cases=@($cases.ToArray());passed=(-not$ExpectOldRace -and $cases.Count -eq $names.Count -and @($cases|Where-Object {-not$_.passed}).Count -eq 0);validOldRegression=([bool]$ExpectOldRace -and $cases.Count -eq 1 -and $cases[0].validOldRegression);expectedOldRegression=[bool]$ExpectOldRace;forceKillUsed=$false;ownedProcessesRemaining=@($cases|Where-Object liveProcessRetained).Count}
 }
 if($bodyError -or $cleanupErrors.Count){$errors=New-Object System.Collections.Generic.List[Exception];if($bodyError){$errors.Add($bodyError)|Out-Null};foreach($cleanupError in $cleanupErrors){$errors.Add($cleanupError)|Out-Null};throw [AggregateException]::new('Receipt E2E failed; original failure is first when present.',$errors.ToArray())}
}
if($ExpectOldRace){exit 1}
'ROO_INDUSTRIES_RESTORE_ACTOR_RECEIPT_E2E_COMPLETE'
