param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$AppSweepExe)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Real Windows PowerShell5.1 is required.'}
foreach($command in 'Assert-HarnessHostLease','New-OwnedProcess','Stop-OwnedProcess','Get-HarnessFolderIdentity','Get-HarnessTree','Assert-PlainAncestry'){
 if(-not(Get-Command $command -ErrorAction SilentlyContinue)){throw ('The verified manual gate must provide '+$command+'.')}
}
Assert-HarnessHostLease
$utf8=[Text.UTF8Encoding]::new($false)
function Save-OutputEvidence([string]$path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 30),$utf8)}
function Require-Output([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Assert-OutputFolder($identity){
 Assert-PlainAncestry $identity.path
 $current=Get-HarnessFolderIdentity $identity.path
 Require-Output ($current.path -ieq $identity.path -and $current.creationTimeFileTimeUtc -ceq $identity.creationTimeFileTimeUtc) ('Owned output directory identity changed; retained: '+$identity.path)
}
function New-StreamCapture($reader){
 $capture=[pscustomobject]@{reader=$reader;buffer=(New-Object char[] 4096);pending=$null;text=[Text.StringBuilder]::new();ended=$false;failed=$false}
 $capture.pending=$reader.ReadAsync($capture.buffer,0,$capture.buffer.Length)
 return $capture
}
function Receive-OutputStream($capture){
 if(-not $capture -or $capture.failed){return}
 while(-not $capture.ended -and $capture.pending.IsCompleted){
  $length=$capture.pending.GetAwaiter().GetResult()
  if($length -eq 0){$capture.ended=$true;break}
  $null=$capture.text.Append($capture.buffer,0,$length)
  $capture.pending=$capture.reader.ReadAsync($capture.buffer,0,$capture.buffer.Length)
 }
}
function Capture-GeneratedOutput($state){
 Assert-OutputFolder $state.tempIdentity
 foreach($item in @(Get-HarnessTree $state.temp -Depth 1)){
  Require-Output ($item.IsDirectory -and [IO.Path]::GetFileName($item.FullName) -like 'restore-summary-*') ('Unknown temporary resource retained: '+$item.FullName)
  $identity=Get-HarnessFolderIdentity $item.FullName
  Require-Output ($state.owned -and [long]$identity.creationTimeFileTimeUtc -ge [long]$state.owned.Identity.creationTimeFileTimeUtc) ('Generated leaf predates the original owned process; retained: '+$item.FullName)
  if($state.leaves.ContainsKey($identity.path)){
   Require-Output ($state.leaves[$identity.path].creationTimeFileTimeUtc -ceq $identity.creationTimeFileTimeUtc) ('Generated leaf identity changed; retained: '+$item.FullName)
  }else{$state.leaves.Add($identity.path,$identity)}
 }
}
$root=[IO.Path]::GetFullPath($OutRoot)
Assert-PlainAncestry $root
$rootIdentity=Get-HarnessFolderIdentity $root
$directory=Join-Path $root ('output-e2e-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory)|Out-Null
$results=New-Object System.Collections.Generic.List[object]
foreach($mode in 'success','body','setup','cleanup','body-cleanup'){
 foreach($explicit in $false,$true){
  Assert-HarnessHostLease;Assert-OutputFolder $rootIdentity
  $case=Join-Path $directory ($mode+'-'+$explicit)
  Require-Output (-not [IO.Directory]::Exists($case)) 'Case directory already exists.'
  [IO.Directory]::CreateDirectory($case)|Out-Null
  $state=[pscustomobject]@{process=$null;launchedPid=$null;owned=$null;stdout=$null;stderr=$null;temp=(Join-Path $case 'temp');tempIdentity=$null;leaves=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);exit=$null;tempRemoved=$false}
  $bodyError=$null;$cleanupErrors=New-Object System.Collections.Generic.List[Exception]
  $output=Join-Path $case 'explicit'
  try{
   [IO.Directory]::CreateDirectory($state.temp)|Out-Null;$state.tempIdentity=Get-HarnessFolderIdentity $state.temp
   Require-Output (@(Get-HarnessTree $state.temp).Count -eq 0) 'New temporary parent is not empty.'
   [IO.Directory]::CreateDirectory($output)|Out-Null
   [IO.File]::WriteAllText((Join-Path $output 'foreign-sentinel'),'keep')
   $start=[Diagnostics.ProcessStartInfo]::new($AppSweepExe)
   $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
   $start.EnvironmentVariables['TMP']=$state.temp;$start.EnvironmentVariables['TEMP']=$state.temp
   $start.Arguments='restore-summary'+$(if($mode -ne 'success'){'-'+$mode+'-failure'}else{''})+$(if($explicit){' "'+$output+'"'}else{''})
   $state.process=[Diagnostics.Process]::Start($start)
   $state.launchedPid=$state.process.Id
   $state.owned=New-OwnedProcess $state.process
   Require-Output ($null -ne $state.owned) 'AppSweep exited before original native ownership could be captured.'
   $state.stdout=New-StreamCapture $state.process.StandardOutput;$state.stderr=New-StreamCapture $state.process.StandardError
   Save-OutputEvidence (Join-Path $case 'original-process.json') $state.owned.Identity
   Require-Output ($state.process.SessionId -eq (Get-Process -Id $PID).SessionId) 'Output fixture ran in another terminal session.'
   $clock=[Diagnostics.Stopwatch]::StartNew()
   while(-not $state.process.HasExited){
    Receive-OutputStream $state.stdout;Receive-OutputStream $state.stderr
    if($clock.Elapsed.TotalSeconds -gt 30){throw 'AppSweep output E2E exceeded30s.'}
    Start-Sleep -Milliseconds 10
   }
   $state.exit=$state.process.ExitCode
   $drain=[Diagnostics.Stopwatch]::StartNew()
   while((-not $state.stdout.ended -or -not $state.stderr.ended) -and $drain.Elapsed.TotalSeconds -lt 2){Receive-OutputStream $state.stdout;Receive-OutputStream $state.stderr;Start-Sleep -Milliseconds 10}
   $stdout=$state.stdout.text.ToString();$stderr=$state.stderr.text.ToString()
   [IO.File]::WriteAllText((Join-Path $case 'stdout.log'),$stdout,$utf8)
   [IO.File]::WriteAllText((Join-Path $case 'stderr.log'),$stderr,$utf8)
   Require-Output ($state.stdout.ended -and $state.stderr.ended) 'AppSweep output streams did not close within the bounded drain.'
   Capture-GeneratedOutput $state
   Require-Output ($stdout -match 'ROO_INDUSTRIES_RESTORE_SUMMARY_CLEANUP:(\d+):(\d+):(\d+)') 'Missing App.Live cleanup receipt; raw output retained.'
   $captured=[int]$matches[1];$restored=[int]$matches[2];$cleanupCount=[int]$matches[3]
   Require-Output ($captured -eq $restored -and ($mode -eq 'setup' -or $captured -gt 0)) 'Captured App.Live properties were not all restored, or no properties were exercised.'
   Require-Output ($(if($mode -in @('cleanup','body-cleanup')){$cleanupCount -gt 0}else{$cleanupCount -eq 0})) 'Cleanup error count does not match the actual filesystem case.'
   Require-Output (($mode -eq 'success') -eq ($state.exit -eq 0)) 'Output E2E exit did not match its actual filesystem outcome.'
   Require-Output ($mode -eq 'success' -or $stdout -notmatch 'Completed \d+ restore summary') 'Failed output fixture emitted completion.'
   Require-Output ([IO.File]::ReadAllText((Join-Path $output 'foreign-sentinel')) -ceq 'keep') 'Caller sentinel was changed.'
   Require-Output (-not $explicit -or [IO.File]::Exists((Join-Path $output 'receipts.json'))) 'Explicit receipts were not retained, including early setup.'
   Require-Output (@(Get-HarnessTree $state.temp -Depth 1).Count -eq 0) 'Generated output survived recovered cleanup.'
   if($mode -eq 'body-cleanup'){
    Require-Output ($stderr -match 'AggregateException' -and $stderr.IndexOf('missing-body.json',[StringComparison]::Ordinal) -ge 0 -and $stderr.IndexOf('cleanup-held',[StringComparison]::Ordinal) -gt $stderr.IndexOf('missing-body.json',[StringComparison]::Ordinal)) 'Original body error must precede the retained cleanup error.'
   }
   if($mode -eq 'setup'){Require-Output ($stderr -match 'fixtures-') 'Setup failure did not occur after output creation.'}
   if($mode -eq 'body'){Require-Output ($stderr -match 'missing-body.json') 'Expected actual body failure is missing.'}
   if($mode -eq 'cleanup'){Require-Output ($stderr -match 'cleanup-held') 'Actual cleanup failure is missing.'}
   $results.Add(@{mode=$mode;explicit=$explicit;identity=$state.owned.Identity;sessionId=$state.process.SessionId;exit=$state.exit;captured=$captured;restored=$restored;cleanupErrors=$cleanupCount;generatedRemaining=0;passed=$true})|Out-Null
  }catch{$bodyError=$_.Exception}
  finally{
   try{if($state.process -and -not $state.owned -and -not $state.process.HasExited){throw ('Launched process lacks an original ownership receipt; retained PID '+$state.launchedPid)};if($state.owned){Stop-OwnedProcess $state.owned;Require-Output ($state.process.WaitForExit(5000)) 'Original owned AppSweep did not exit.'}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   try{
    $drain=[Diagnostics.Stopwatch]::StartNew()
    while((($state.stdout -and -not $state.stdout.ended -and -not $state.stdout.failed) -or ($state.stderr -and -not $state.stderr.ended -and -not $state.stderr.failed)) -and $drain.Elapsed.TotalSeconds -lt 2){
     try{Receive-OutputStream $state.stdout}catch{$cleanupErrors.Add($_.Exception)|Out-Null;$state.stdout.failed=$true}
     try{Receive-OutputStream $state.stderr}catch{$cleanupErrors.Add($_.Exception)|Out-Null;$state.stderr.failed=$true}
     Start-Sleep -Milliseconds 10
    }
   }catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   foreach($channel in 'stdout','stderr'){
    try{if($state.$channel){[IO.File]::WriteAllText((Join-Path $case ($channel+'.log')),$state.$channel.text.ToString(),$utf8);Require-Output $state.$channel.ended ('Bounded '+$channel+' capture is incomplete.')}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
    try{if($state.$channel){$state.$channel.reader.Dispose()}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   }
   try{if($state.tempIdentity -and $state.owned){Capture-GeneratedOutput $state}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   foreach($identity in @($state.leaves.Values)){
    try{
     Require-Output ($state.process -and $state.process.HasExited) 'Original AppSweep remains live; generated resource retained.'
     Assert-OutputFolder $state.tempIdentity
     if([IO.Directory]::Exists($identity.path)){Assert-OutputFolder $identity;$null=@(Get-HarnessTree $identity.path);[IO.Directory]::Delete($identity.path,$true)}
    }catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   }
   try{if($state.tempIdentity){Require-Output (-not $state.process -or $state.process.HasExited) 'Live original process still owns its temporary parent; retained.';Assert-OutputFolder $state.tempIdentity;Require-Output (@(Get-HarnessTree $state.temp -Depth 1).Count -eq 0) 'Owned generated resources remain; exact identities retained in cleanup receipt.';[IO.Directory]::Delete($state.temp,$false);$state.tempRemoved=$true}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   try{if($state.process){$state.process.Dispose()}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
   try{Save-OutputEvidence (Join-Path $case 'cleanup.json') @{launchedPid=$state.launchedPid;tempRemoved=$state.tempRemoved;originalProcess=$(if($state.owned){$state.owned.Identity}else{$null});tempIdentity=$state.tempIdentity;generatedIdentities=@($state.leaves.Values);bodyError=$(if($bodyError){$bodyError.ToString()}else{$null});cleanupErrors=@($cleanupErrors|ForEach-Object {$_.ToString()})}}catch{$cleanupErrors.Add($_.Exception)|Out-Null}
  }
  if($bodyError -and $cleanupErrors.Count -eq 0){[Runtime.ExceptionServices.ExceptionDispatchInfo]::Capture($bodyError).Throw()}
  if($bodyError){$cleanupErrors.Insert(0,$bodyError)}
  if($cleanupErrors.Count){throw [AggregateException]::new($cleanupErrors.ToArray())}
 }
}
Save-OutputEvidence (Join-Path $directory 'summary.json') @{cases=@($results.ToArray());source=$Source;engine=$PSVersionTable.PSVersion.ToString();passed=$true}
'ROO_INDUSTRIES_RESTORE_OUTPUT_E2E_COMPLETE'
