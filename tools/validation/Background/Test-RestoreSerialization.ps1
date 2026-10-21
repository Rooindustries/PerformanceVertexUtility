param(
 [Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][string]$ActorExe,[Parameter(Mandatory)][string]$SourceCommit,
 [string]$OriginalSource='',
 [string]$ReviewedSource='',
 [ValidateSet('profile','game','all')][string]$Kind='all',
 [ValidateSet('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority','all')][string]$Control='all',
 [ValidateSet('normal','native-before','native-after-read','protected-launcher','protected-game','governor','malformed','unknown-schema','sharing','mutex-busy','mutex-denied','mutex-type','mutex-abandoned','identity-unknown','identity-denied','identity-reused','identity-ended','release-error','setter-denied','readback-mismatch','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified','verified-external','original-after-preview','kept-changed-back','old-interleaving','failed-apply-readback','schema-records','duplicate-snapshot','image-alias','legacy-proposed-absent','legacy-applied-absent','legacy-proposed-empty','legacy-applied-empty','legacy-proposed-unmatched','legacy-applied-unmatched','confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch','legacy-proposed-absent-ended','legacy-applied-absent-ended','legacy-proposed-empty-ended','legacy-applied-empty-ended','legacy-proposed-unmatched-ended','legacy-applied-unmatched-ended')]
 [string[]]$Scenario=@('normal','native-before','native-after-read','protected-launcher','protected-game','governor','malformed','unknown-schema','sharing','mutex-busy','mutex-denied','mutex-type','mutex-abandoned','identity-unknown','identity-denied','identity-reused','identity-ended','release-error','setter-denied','readback-mismatch','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified','verified-external','original-after-preview','kept-changed-back','old-interleaving','failed-apply-readback','schema-records','duplicate-snapshot','image-alias','legacy-proposed-absent','legacy-applied-absent','legacy-proposed-empty','legacy-applied-empty','legacy-proposed-unmatched','legacy-applied-unmatched','confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch','legacy-proposed-absent-ended','legacy-applied-absent-ended','legacy-proposed-empty-ended','legacy-applied-empty-ended','legacy-proposed-unmatched-ended','legacy-applied-unmatched-ended')
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess){throw 'Real Windows PowerShell5.1 x64 is required.'}
foreach($command in 'Assert-HarnessHostLease','Get-HarnessFileSha256','New-HarnessDirectory','Get-HarnessToolPath','Get-HarnessItem','Add-HarnessEntry','Remove-HarnessEntry','Get-HarnessEntries','Test-HarnessPath'){
 if(-not(Get-Command $command -ErrorAction SilentlyContinue)){throw ('The original owned Harness must already provide '+$command+'.')}
}
Assert-HarnessHostLease
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
if(-not ('RooIndustriesBackgroundOracle' -as [type])){Add-Type -Path (Join-Path $Source 'tools\validation\Background\Oracle.cs')}
$utf8=[Text.UTF8Encoding]::new($false)
$root=[IO.Path]::GetFullPath($OutRoot).TrimEnd('\')
if(-not [IO.Directory]::Exists($root) -or (Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Expected an original owned output directory.'}
$results=New-Object System.Collections.Generic.List[object]
$driverSourcePath=$PSCommandPath
$priorityScenarios=@('image-alias','legacy-proposed-absent','legacy-applied-absent','legacy-proposed-empty','legacy-applied-empty','legacy-proposed-unmatched','legacy-applied-unmatched','confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch','legacy-proposed-absent-ended','legacy-applied-absent-ended','legacy-proposed-empty-ended','legacy-applied-empty-ended','legacy-proposed-unmatched-ended','legacy-applied-unmatched-ended')
if($Control -notin @('all','priorityClass') -and @($Scenario|Where-Object {$priorityScenarios -contains $_}).Count){throw 'The seventeen new scenarios are explicitly priorityClass-only; incompatible -Control is not a skipped case.'}
function Save([string]$path,$value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 60),$utf8)}
function Require([bool]$ok,[string]$message){if(-not $ok){throw $message}}
function Read-Ast([string]$path){$e=$null;$t=$null;$a=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e);if($e.Count){throw ($e -join '; ')};return $a}
function Read-Actual($process,[string]$field){
 $process.Refresh()
 switch($field){
  'priorityClass'{return [string]$process.PriorityClass}
  'affinityMask'{return $process.ProcessorAffinity.ToInt64()}
  'ioPriority'{return @('VeryLow','Low','Normal','High')[[RooIndustriesBackgroundOracle]::Io($process)]}
  'memoryPriority'{return [int][RooIndustriesBackgroundOracle]::Memory($process)}
  'gpuPriority'{return @('Idle','BelowNormal','Normal','AboveNormal','High','Realtime')[[RooIndustriesBackgroundOracle]::Gpu($process)]}
 }
}
function Read-E2EControls($process){
 $values=[ordered]@{}
 foreach($name in 'priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority'){
  try{$value=Read-Actual $process $name;$values[$name]=@{available=$true;value=$value;error=$null}}
  catch{$values[$name]=@{available=$false;value=$null;error=$_.Exception.ToString()}}
 }
 return $values
}
function Invoke-Body([string]$backend,[string]$scriptName,[hashtable]$arguments,[string]$data){
 & {
  . (Join-Path $backend 'backend\scripts\GameTuneSession.Common.ps1')
  $script:RestoreE2EData=$data
  function Get-RooIndustriesLocalDataRoot{return $script:RestoreE2EData}
  $ast=Read-Ast (Join-Path $backend ('backend\scripts\'+$scriptName))
  foreach($statement in $ast.EndBlock.Statements){
   if($statement -is [Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create($statement.Extent.Text))}
   elseif($statement -is [Management.Automation.Language.AssignmentStatementAst]){. ([scriptblock]::Create($statement.Extent.Text))}
  }
  foreach($key in $arguments.Keys){Set-Variable -Name $key -Value $arguments[$key] -Scope Local}
  $body=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
  Require ($body.Count -eq 1) 'Expected one actual top-level backend body.'
  & ([scriptblock]::Create($body[0].Extent.Text))
 } | ConvertFrom-Json
}
function New-Actor($context,[string]$mode,$value,[string]$journal){
 $request=Join-Path $context.directory ('actor-'+[guid]::NewGuid().ToString('N')+'.json')
 $output=$request+'.out.json';$release=$request+'.release'
 $ledgerImage=[string]$context.owned.Identity.imagePath
 $plainImage=[RooIndustriesValidationOwnership.Native]::Plain($ledgerImage)
 Require ([string]::Equals([RooIndustriesValidationOwnership.Native]::Canonical($plainImage),$ledgerImage,[StringComparison]::OrdinalIgnoreCase)) 'Plain request image is not the original canonical ledger image.'
 $imageHash=Get-HarnessFileSha256 $plainImage
 Require ($imageHash -ceq (Get-HarnessFileSha256 $ledgerImage)) 'Canonical/plain fixture bytes differ.'
 Save ($request+'.image-binding.json') @{originalLedgerImage=$ledgerImage;requestPlainImage=$plainImage;sha256=$imageHash;originalIdentity=$context.owned.Identity}
 Save $request @{ownedRoot=$context.directory;nonce=$context.nonce;sourceCommit=$SourceCommit;mode=$mode;processId=$context.process.Id;nativeBirth=$context.owned.Identity.creationTimeFileTimeUtc;executablePath=$plainImage;imageSha256=$imageHash;restoreSessionId=(Get-Process -Id $PID).SessionId;control=$context.control;value=$value;previewPath=($journal+'.preview.json');journalPath=$journal;outputPath=$output;releasePath=$release}
 $start=[Diagnostics.ProcessStartInfo]::new($ActorExe)
 $start.Arguments='"'+$request+'" '+(Get-FileHash -LiteralPath $request -Algorithm SHA256).Hash
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::Start($start)
 $owned=New-OwnedProcess $process
 $actor=[pscustomobject]@{process=$process;owned=$owned;output=$output;release=$release;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync();mode=$mode;nonce=$context.nonce;target=$context.owned.Identity}
 $context.actors.Add($actor)|Out-Null
 Save ($request+'.identity.json') @{actor=$owned.Identity;actorSession=$process.SessionId;restoreSession=(Get-Process -Id $PID).SessionId;targetSession=$context.process.SessionId;executableHash=(Get-FileHash -LiteralPath $ActorExe -Algorithm SHA256).Hash}
 Require ($process.SessionId -eq (Get-Process -Id $PID).SessionId -and $context.process.SessionId -eq $process.SessionId) 'Actor/restore/target Local mutex sessions differ.'
 return $actor
}
function Wait-Actor($actor,[switch]$Held){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists($actor.output)){
  if($actor.process.HasExited -or $clock.Elapsed.TotalSeconds -gt 10){throw 'Actor did not produce its original receipt.'};Start-Sleep -Milliseconds 10
 }
 $record=Get-Content -LiteralPath $actor.output -Raw|ConvertFrom-Json
 Require ($record.sourceCommit -ceq $SourceCommit -and $record.nonce -ceq $actor.nonce -and $record.actorPid -eq $actor.owned.Identity.pid -and $record.actorBirth -ceq $actor.owned.Identity.creationTimeFileTimeUtc -and $record.targetPid -eq $actor.target.pid -and $record.nativeBirth -ceq $actor.target.creationTimeFileTimeUtc -and $record.executablePath -ieq [RooIndustriesValidationOwnership.Native]::Plain([string]$actor.target.imagePath)) 'Actor receipt does not bind its original actor/target/frame identities.'
 Require ($record.actorSessionId -eq (Get-Process -Id $PID).SessionId -and $record.restoreSessionId -eq $record.actorSessionId -and $record.targetSessionId -eq $record.actorSessionId) 'Actor receipt has another terminal session.'
 if(-not $Held){
  Require ($actor.process.WaitForExit(10000)) 'Actor did not exit.'
  [IO.File]::WriteAllText(($actor.output+'.stdout.log'),$actor.stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText(($actor.output+'.stderr.log'),$actor.stderr.GetAwaiter().GetResult())
  if($actor.process.ExitCode -eq 10){Require ($record.outcome -ceq 'instance-busy' -and $record.result.exceptionType -ceq 'RooIndustries.Optimizer.InstanceBusyException') 'Non-specific refusal is not instance exclusion.'}
  else{Require ($actor.process.ExitCode -eq 0 -and $record.outcome -in @('applied','restored','held','wrong-type-held')) 'Native actor failed.'}
 }
 return $record
}
function Undo($context,[string]$name,[string]$backend=$Source){
 Assert-HarnessHostLease
 $arguments=@{BackupPath=$context.backup;OutputPath='';ConfirmApply=$true;SessionId='';SessionPath='';StateRoot=$context.state}
 if($context.kind -eq 'game'){$arguments.SessionPath=$context.session}
 $result=Invoke-Body $backend $(if($context.kind -eq 'game'){'Stop-GameTuneSession.ps1'}else{'Restore-ProcessProfileBackup.ps1'}) $arguments $context.data
 Save (Join-Path $context.directory ($name+'.json')) $result
 Require ((Get-FileHash -LiteralPath $context.backup -Algorithm SHA256).Hash -ceq $context.backupHash) 'Undo changed original backup bytes.'
 if($context.kind -eq 'game'){
  $status=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $context.session|ConvertFrom-Json
  Save (Join-Path $context.directory ('status-'+$name+'.json')) $status
  Require ($status.restorable -eq $result.restorable) 'Reopened Game Tune recovery disagrees.'
 }
 return $result
}
function Is-Pending($context,$result){if($context.kind -eq 'game'){return [bool]$result.restorable};return $result.result.restorePendingCount -gt 0}
function Assert-Pending($context,$result,$value){
 Require (Is-Pending $context $result) 'Uncertain control lost recovery.'
 Require (@($result.result.leftAsSetItems|Where-Object control -eq $context.control).Count -eq 0) 'Uncertain control was certified kept.'
 Require ((Read-Actual $context.process $context.control).ToString() -eq $value.ToString()) 'Uncertain control was written.'
}
function New-Breakpoint($context,[string]$script,[string]$pattern,[scriptblock]$action){
 $lines=@(Select-String -LiteralPath $script -Pattern $pattern)
 Require ($lines.Count -eq 1) ('Expected one actual debugger seam: '+$pattern)
 $bp=Set-PSBreakpoint -Script $script -Line $lines[0].LineNumber -Action $action
 $context.breakpoints.Add($bp)|Out-Null
 return $bp
}
function Run-Scenario([string]$kind,[string]$field,[string]$mode){ & {
 $directory=Join-Path $root ($kind+'-'+$field+'-'+$mode)
 Require (-not [IO.Directory]::Exists($directory)) 'Case output already exists; no automatic repeat.'
 [IO.Directory]::CreateDirectory($directory)|Out-Null
 $nonce=[guid]::NewGuid().ToString('N');Save (Join-Path $directory 'owner.json') @{nonce=$nonce;sourceCommit=$SourceCommit}
 $context=[pscustomobject]@{directory=$directory;nonce=$nonce;kind=$kind;control=$field;process=$null;owned=$null;actors=(New-Object System.Collections.Generic.List[object]);breakpoints=(New-Object System.Collections.Generic.List[object]);data=(Join-Path $directory 'data');state=(Join-Path $directory 'state');backup='';backupHash='';session=''}
 $held=$null;$mutexKeep=$null;$meter=$null;$bodyError=$null;$cleanups=New-Object System.Collections.Generic.List[string]
 $denial=@{acl=$null;applied=$false;restored=$false;injectionPhase=$null;restorePhase=$null}
 $legacyReplay=$mode -like 'legacy-*'
 $legacyShape=$mode -replace '-ended$',''
 $legacyEnds=$legacyReplay -and $mode.EndsWith('-ended',[StringComparison]::Ordinal)
 $unmatchedReplay=$legacyReplay -and $legacyShape -in @('legacy-proposed-unmatched','legacy-applied-unmatched')
 $priorityOnly=($priorityScenarios -contains $mode) -and -not $unmatchedReplay
 $aliasEntries=New-Object System.Collections.Generic.List[object]
 $aliasProbe=$null;$aliasCreationAttempted=$false;$aliasRegistered=$false;$aliasImageCreationAttempted=$false
 $alias=$null;$real=$null;$realImage=$null;$aliasEntry=$null;$imageEntry=$null;$targetCleanupSucceeded=$false
 $identityTrace=New-Object System.Collections.Generic.List[object]
 $producerHash=$null;$producerPeerText=$null;$aliasRedReproduced=$null
 try{
  . (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
  $script:RestoreE2EData=$context.data
  function Get-RooIndustriesLocalDataRoot{return $script:RestoreE2EData}
  $image=Join-Path $directory 'RestoreTarget.exe'
  if($mode -eq 'image-alias'){
   $real=Join-Path $directory 'real';$alias=Join-Path $directory 'alias'
   $realEntry=New-HarnessDirectory $real 'restore-alias-real' 'invocation';$aliasEntries.Add($realEntry)|Out-Null
   Save (Join-Path $directory 'original-alias-ledger.json') @($aliasEntries.ToArray())
   $realImage=Join-Path $real 'RestoreTarget.exe'
   $aliasImageCreationAttempted=$true
   $aliasProbe=Copy-OwnedProbe (Join-Path $env:SystemRoot 'System32\PING.EXE') $realImage
   $imageEntry=Add-HarnessEntry 'file' $aliasProbe.Identity 'restore-alias-image' 'invocation';$aliasEntries.Add($imageEntry)|Out-Null
   Save (Join-Path $directory 'original-alias-ledger.json') @($aliasEntries.ToArray())
   $aliasProbe.Dispose();$aliasProbe=$null
   Require (-not(Test-HarnessPath $alias)) 'Alias already exists; retained.'
   Save (Join-Path $directory 'alias-creation-intent.json') @{path=$alias;target=$real;originalEntries=@($aliasEntries.ToArray());image=$realImage}
   $aliasCreationAttempted=$true
   New-Item -ItemType Junction -Path (Get-HarnessToolPath $alias) -Target (Get-HarnessToolPath $real)|Out-Null
   $aliasItem=Get-HarnessItem $alias -Force
   $aliasEntry=Add-HarnessEntry 'folder' @{path=$alias;creationTimeFileTimeUtc=$aliasItem.CreationTimeUtc.ToFileTimeUtc().ToString()} 'restore-alias-junction' 'invocation' @{reparseTarget=$real}
   $aliasEntries.Add($aliasEntry)|Out-Null
   Save (Join-Path $directory 'original-alias-ledger.json') @($aliasEntries.ToArray())
   $aliasRegistered=$true
   Require (($aliasItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and @($aliasItem.Target).Count -eq 1 -and $aliasItem.Target[0] -ieq $real) 'Original junction target differs.'
   $image=Join-Path $alias 'RestoreTarget.exe';$arguments='-t 127.0.0.1'
  }elseif($field -eq 'gpuPriority'){
   $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
   & $compiler /nologo ('/out:'+$image) (Join-Path $Source 'tools\validation\Background\LauncherFixture.cs')
   Require ($LASTEXITCODE -eq 0) 'Owned GPU fixture compilation failed.'
   $signal=Join-Path $directory 'never-signalled';$arguments='"'+$signal+'" "'+(Join-Path $directory 'never-child.exe')+'" --gpu'
  }else{Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $image;$arguments='-t 127.0.0.1'}
  $context.process=Start-Process -FilePath $image -ArgumentList $arguments -PassThru -WindowStyle Hidden
  $context.owned=New-OwnedProcess $context.process;Save (Join-Path $directory 'original-process.json') $context.owned.Identity
  Require ($null -ne $context.owned -and $context.process.SessionId -eq (Get-Process -Id $PID).SessionId) 'Owned fixture identity/session missing.'
  if($mode -eq 'image-alias'){
   $canonicalImage=[RooIndustriesValidationOwnership.Native]::Image($context.owned.handle)
   $canonicalHash=Get-HarnessFileSha256 $canonicalImage
   Save (Join-Path $directory 'original-alias-image-binding.json') @{originalProcess=$context.owned.Identity;originalImageEntry=$imageEntry;realCanonical=[RooIndustriesValidationOwnership.Native]::Canonical($realImage);canonicalImage=$canonicalImage;canonicalSha256=$canonicalHash;actorSha256=(Get-HarnessFileSha256 $ActorExe)}
   Require ($canonicalImage -ieq $context.owned.Identity.imagePath -and [RooIndustriesValidationOwnership.Native]::Canonical($realImage) -ieq $canonicalImage -and $canonicalHash -ieq $imageEntry.identity.hash -and (Get-HarnessFileSha256 $realImage) -ceq $canonicalHash) 'Owned alias image identity/hash differs before apply.'
  }

  if($field -eq 'gpuPriority'){$clock=[Diagnostics.Stopwatch]::StartNew();while(-not [IO.File]::Exists($signal+'.gpu-ready')){if($clock.Elapsed.TotalSeconds -gt 10){throw 'GPU initialization is missing proof.'};Start-Sleep -Milliseconds 20}}
  $original=Read-Actual $context.process $field
  $desired=switch($field){'priorityClass'{'AboveNormal'};'affinityMask'{[long]($context.process.ProcessorAffinity.ToInt64() -band (-$context.process.ProcessorAffinity.ToInt64()))};'ioPriority'{'Low'};'memoryPriority'{2};'gpuPriority'{'BelowNormal'}}
  Require ($original.ToString() -ne $desired.ToString()) 'Fixture needs a different original to prove Undo.'
  $peer=if($field -eq 'priorityClass'){'memoryPriority'}else{'priorityClass'}
  $peerOriginal=Read-Actual $context.process $peer
  $foreground=[ordered]@{ruleId='restore-e2e';processNames=@('RestoreTarget.exe');priorityClass='AboveNormal';reason='Restore E2E fixture';reasonCodes=@('LIVE_VALIDATION')}
  $foreground[$field]=$desired
  if($peer -eq 'memoryPriority' -and -not $priorityOnly){$foreground.memoryPriority=2}
  Save (Join-Path $directory 'profile.json') @{schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='restore-e2e';name='Restore E2E';profileKind='process-controls';risk='medium';protectedCatalogPath=(Join-Path $Source 'backend\profiles\protected-processes.json');foregroundGame=$foreground;targetGames=@();protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();rules=@();rollbackPolicy=@{supported=$true;scope='process-controls';stateRoot=$context.state;restoreOriginalPriorityClass=$true};safety=@{confirmedApplyChanges=@('PriorityClass','Affinity','IoPriority','MemoryPriority','GpuPriority');continuousEnforcement=$true;runtimeService=$false}}
  $external=switch($field){'priorityClass'{'BelowNormal'};'affinityMask'{$original -band (-bnot [long]$desired)};'ioPriority'{'VeryLow'};'memoryPriority'{3};'gpuPriority'{'High'}}
  Require ($external.ToString() -ne $original.ToString() -and $external.ToString() -ne $desired.ToString() -and ($field -ne 'affinityMask' -or $external -ne 0)) 'Three distinct real values are required for this control.'
  $directSetter={param($value) switch($field){'priorityClass'{$context.process.PriorityClass=$value};'affinityMask'{$context.process.ProcessorAffinity=[IntPtr][long]$value};'ioPriority'{[RooIndustriesBackgroundOracle]::SetIo($context.process,(Convert-RooIndustriesIoPriorityToValue $value -Restoring))};'memoryPriority'{[RooIndustriesBackgroundOracle]::SetMemory($context.process,[uint32]$value)};'gpuPriority'{Set-RooIndustriesProcessGpuPriority $context.process $value}}}.GetNewClosure()
  $initialOrder=@{hits=0}
  $initialBreakpoint=$null
  if($mode -eq 'failed-apply-readback'){
   $initialBreakpoint=New-Breakpoint $context (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1') '^\s*\$actual = Get-RooIndustriesProcessControlReadback \$Process \$control' ({
    if($initialOrder.hits -eq 0 -and (Get-Variable control -ErrorAction Stop).Value -eq $field){$initialOrder.hits++;& $directSetter $external}
   }.GetNewClosure())
  }
  $apply=Invoke-Body $Source $(if($kind -eq 'game'){'Start-GameTuneSession.ps1'}else{'Apply-ProcessProfile.ps1'}) @{ProfilePath=(Join-Path $directory 'profile.json');TargetGameProcessName='RestoreTarget.exe';StateRoot=$context.state;OutputPath='';ConfirmApply=$true;PollIntervalSeconds=1;MaxDurationSeconds=1;SessionId=''} $context.data
  if($initialBreakpoint){Remove-PSBreakpoint $initialBreakpoint;$null=$context.breakpoints.Remove($initialBreakpoint);Require ($initialOrder.hits -eq 1) 'Actual apply readback seam did not run'}
  Save (Join-Path $directory 'apply.json') $apply
  $context.backup=if($kind -eq 'game'){$apply.backupManifestPath}else{$apply.backup.location};$context.session=if($kind -eq 'game'){$apply.sessionPath}else{''}
  Require ([IO.File]::Exists($context.backup) -and (Read-Actual $context.process $field).ToString() -eq $(if($mode -eq 'failed-apply-readback'){$external.ToString()}else{$desired.ToString()})) 'Real apply or backup is missing.'
  $backup=Get-Content -LiteralPath $context.backup -Raw|ConvertFrom-Json
  $snapshot=@($backup.snapshots|Where-Object processId -eq $context.process.Id)
  Require ($snapshot.Count -eq 1) 'Expected exactly one immutable original snapshot.'
  $record=@($snapshot[0].controlChanges|Where-Object control -eq $field)
  Require ($record.Count -eq 1 -and $record[0].outcome -ceq $(if($mode -eq 'failed-apply-readback'){'failed'}else{'applied'})) 'Real apply did not verify target.'
  if($legacyReplay -or $mode -eq 'image-alias'){
   [IO.File]::WriteAllBytes((Join-Path $directory 'producer-backup.json'),[IO.File]::ReadAllBytes($context.backup))
   $producerHash=Get-HarnessFileSha256 $context.backup
  }
  if($priorityOnly){Require (@($snapshot[0].controlChanges).Count -eq 1 -and @($snapshot[0].controlChanges|Where-Object control -eq 'memoryPriority').Count -eq 0) 'Priority-only producer secretly retained a peer apply.'}
  if($legacyReplay){
   $beforeIdentity=[pscustomobject]@{processId=$snapshot[0].processId;processName=$snapshot[0].processName;executablePath=$snapshot[0].executablePath;processStartTimeUtc=$snapshot[0].processStartTimeUtc;nativeBirth=$context.owned.Identity.creationTimeFileTimeUtc;originalPriorityClass=$snapshot[0].originalPriorityClass}
   if($unmatchedReplay){
    $peerRecord=@($snapshot[0].controlChanges|Where-Object control -eq 'memoryPriority')
    Require ($peerRecord.Count -eq 1 -and $peerRecord[0].outcome -ceq 'applied' -and (Read-Actual $context.process 'memoryPriority') -eq 2) 'Missing genuine producer peer evidence.'
    $producerPeerText=$peerRecord[0]|ConvertTo-Json -Depth 30 -Compress
    $snapshot[0].controlChanges=@($snapshot[0].controlChanges|Where-Object control -ne 'priorityClass')
   }elseif($legacyShape -in @('legacy-proposed-empty','legacy-applied-empty')){$snapshot[0].controlChanges=@()}
   else{$snapshot[0].PSObject.Properties.Remove('controlChanges')}
   if($legacyShape -like 'legacy-applied-*'){
    $snapshot[0].PSObject.Properties.Remove('proposedPriorityClass')
    $snapshot[0]|Add-Member -NotePropertyName appliedPriorityClass -NotePropertyValue $desired -Force
   }else{$snapshot[0].PSObject.Properties.Remove('appliedPriorityClass')}
   Save $context.backup $backup
   Save (Join-Path $directory 'saved-format-replay.json') @{kind='SAVED-FORMAT REPLAY from an actual verified producer; not a historical backup or failed transport';sourceCommit=$SourceCommit;scenario=$mode;legacyShape=$legacyShape;terminal=$(if($legacyEnds){'ended'}else{'original'});producerBackupSha256=$producerHash;producerArtifact='producer-backup.json';originalIdentity=$beforeIdentity;readerCompatibilityOnly=($legacyShape -like 'legacy-applied-*');rawBackupSchemaLimitation='Applied-field-only is not processProfileBackupManifest schema-valid; restore/status envelopes are validated separately.'}
   $backup=Get-Content -LiteralPath $context.backup -Raw|ConvertFrom-Json
   $snapshot=@($backup.snapshots|Where-Object processId -eq $context.process.Id)
   Require ($snapshot.Count -eq 1) 'Replay lost original snapshot identity.'
   foreach($name in 'processId','processName','executablePath','processStartTimeUtc','originalPriorityClass'){Require ([string]$snapshot[0].$name -ceq [string]$beforeIdentity.$name) ('Replay changed original identity/value: '+$name)}
   $savedTime=[DateTime]::Parse([string]$snapshot[0].processStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
   Require ($savedTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $beforeIdentity.nativeBirth -and [RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString() -ceq $beforeIdentity.nativeBirth) 'Replay differs from original native birth.'
   if($unmatchedReplay){
    Require (@($snapshot[0].controlChanges).Count -eq 1 -and @($snapshot[0].controlChanges|Where-Object control -eq 'priorityClass').Count -eq 0) 'Replay unmatched shape differs.'
    Require (($snapshot[0].controlChanges[0]|ConvertTo-Json -Depth 30 -Compress) -ceq $producerPeerText) 'Replay changed genuine peer record bytes.'
   }elseif($legacyShape -in @('legacy-proposed-empty','legacy-applied-empty')){Require ($null -ne $snapshot[0].PSObject.Properties['controlChanges'] -and @($snapshot[0].controlChanges).Count -eq 0) 'Replay empty array differs.'}
   else{Require ($null -eq $snapshot[0].PSObject.Properties['controlChanges']) 'Replay did not remove the controlChanges property.'}
   if($legacyShape -like 'legacy-applied-*'){Require ($null -eq $snapshot[0].PSObject.Properties['proposedPriorityClass'] -and $snapshot[0].appliedPriorityClass -ceq $desired) 'Applied-only compatibility shape differs.'}
   else{Require ($null -eq $snapshot[0].PSObject.Properties['appliedPriorityClass'] -and $snapshot[0].proposedPriorityClass -ceq $desired) 'Proposed-only shape differs.'}
   Require ((Get-HarnessFileSha256 (Join-Path $directory 'producer-backup.json')) -ceq $producerHash) 'Original producer artifact changed.'
  }
  $journal=Join-Path $context.data 'operations\process-e2e\journal.json'
  if($mode -in @('failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified')){
   $record[0].outcome=if($mode -in @('pending-drift','pending-target','pending-ended')){'pending'}else{'failed'}
   if($mode -eq 'unknown-drift'){$record[0].outcome='unknown'}
   if($mode -eq 'missing-outcome'){$record[0].PSObject.Properties.Remove('outcome')}
   Save $context.backup $backup
   Save (Join-Path $directory 'saved-record-replay.json') @{kind='Saved outcome replay after verified real apply; not transport/crash injection';outcome=$record[0].outcome;original=$original;requested=$desired}
  }
  if($mode -eq 'schema-records' -and $field -in @('affinityMask','memoryPriority')){
   $originalField=if($field -eq 'affinityMask'){'originalAffinityMask'}else{'originalMemoryPriority'}
   $snapshot[0].$originalField=[string]$snapshot[0].$originalField
   $record[0].proposedValue=[string]$record[0].proposedValue
   Save $context.backup $backup
  }
  if($mode -eq 'duplicate-snapshot'){
   $duplicate=$snapshot[0]|ConvertTo-Json -Depth 40|ConvertFrom-Json
   $snapshot[0].ruleId='first-original-snapshot';$duplicate.ruleId='second-original-snapshot'
   $backup.snapshots=@($snapshot[0],$duplicate)
   Save $context.backup $backup
  }
  $context.backupHash=(Get-FileHash -LiteralPath $context.backup -Algorithm SHA256).Hash
  $setActual={param($value) $change=New-RooIndustriesControlChange $field (Read-Actual $context.process $field) $value 'restoreMemoryPriority' 'Owned fixture ordering';$change.action=switch($field){'priorityClass'{'restorePriority'};'affinityMask'{'restoreAffinity'};'ioPriority'{'restoreIoPriority'};'gpuPriority'{'restoreGpuPriority'};default{'restoreMemoryPriority'}};Invoke-RooIndustriesProcessControlChange $context.process $change}
  $meter=@{setterAttempts=0;peerSetterAttempts=0;unlistedSetterAttempts=0;setterFailures=(New-Object System.Collections.Generic.List[object]);releases=0;abandoned=0;actor=$null;hits=0;releaseFault=$false}
  $common=Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1'
  $setterPattern=switch($field){'priorityClass'{'^\s*\$Process.PriorityClass = \[System.Diagnostics.ProcessPriorityClass\]::\$priority'};'affinityMask'{'^\s*\$Process.ProcessorAffinity = \[IntPtr\]'};'ioPriority'{'^\s*Set-RooIndustriesProcessIoPriority \$Process \$priority'};'memoryPriority'{'^\s*Set-RooIndustriesProcessMemoryPriority \$Process \$value'};'gpuPriority'{'^\s*Set-RooIndustriesProcessGpuPriority \$Process \$priority'}}
  $null=New-Breakpoint $context $common $setterPattern ({
   $meter.setterAttempts++
   if($mode -eq 'setter-denied'){
    Require (-not $denial.applied) 'Denied target setter was attempted more than once.'
    $denial.acl=[RooIndustriesBackgroundOracle]::DenySetInformation($context.process)
    $denial.applied=$true
    $denial.injectionPhase='target-setter-after-prerequisite-reads'
   }
  }.GetNewClosure())
  $peerPattern=if($peer -eq 'priorityClass'){'^\s*\$Process.PriorityClass = \[System.Diagnostics.ProcessPriorityClass\]::\$priority'}else{'^\s*Set-RooIndustriesProcessMemoryPriority \$Process \$value'}
  $null=New-Breakpoint $context $common $peerPattern ({$meter.peerSetterAttempts++}.GetNewClosure())
  if($priorityScenarios -contains $mode){
   foreach($pattern in '^\s*\$Process.ProcessorAffinity = \[IntPtr\]','^\s*Set-RooIndustriesProcessIoPriority \$Process \$priority','^\s*Set-RooIndustriesProcessGpuPriority \$Process \$priority'){
    $null=New-Breakpoint $context $common $pattern ({$meter.unlistedSetterAttempts++}.GetNewClosure())
   }
  }

  if($mode -in @('setter-denied','readback-mismatch')){
   $null=New-Breakpoint $context $common '^\s*\$Change.outcome = ''failed''' ({
    if((Get-Variable control -ErrorAction Stop).Value -eq $field){
     $failure=(Get-Variable -Name '_' -ErrorAction Stop).Value.Exception
     $types=New-Object System.Collections.Generic.List[string];$codes=New-Object System.Collections.Generic.List[int]
     $message=$failure.Message
     while($failure){$types.Add($failure.GetType().FullName)|Out-Null;if($failure -is [ComponentModel.Win32Exception]){$codes.Add($failure.NativeErrorCode)|Out-Null};$failure=$failure.InnerException}
     $meter.setterFailures.Add(@{control=$field;message=$message;exceptionTypes=@($types.ToArray());nativeCodes=@($codes.ToArray())})|Out-Null
     if($mode -eq 'setter-denied' -and $denial.acl){
      [RooIndustriesBackgroundOracle]::RestoreDacl($context.process,$denial.acl)
      $denial.acl=$null
      $denial.restored=$true
      $denial.restorePhase='target-failure-observer-before-peer'
     }
    }
   }.GetNewClosure())
  }
  if($mode -ne 'old-interleaving'){
   $null=New-Breakpoint $context $common '^\s*try \{ \$instanceMutex.ReleaseMutex\(\)' ({$meter.releases++}.GetNewClosure())
   $null=New-Breakpoint $context $common '^\s*\$instanceHeld = \$true' ({$meter.abandoned++}.GetNewClosure())
  }
  if($mode -in @('native-before','protected-launcher','protected-game')){
   if($mode -eq 'protected-launcher'){$journal=Join-Path $context.data 'operations\game-session-e2e\session\launcher-journal.json'}
   if($mode -eq 'protected-game'){$journal=Join-Path $context.data ('operations\game-session-e2e\session\games\'+$context.process.Id+'-'+$context.owned.Identity.creationTimeFileTimeUtc+'\'+$(if($field -eq 'priorityClass'){'cpuPriority'}elseif($field -eq 'affinityMask'){'affinity'}else{$field})+'\journal.json')}
   $actor=New-Actor $context 'apply' $external $journal;$null=Wait-Actor $actor
  }elseif($mode -in @('schema-records','verified-external','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified') -and $mode -notin @('failed-target','pending-target','missing-outcome')){& $setActual $external}
  elseif($mode -in @('malformed','unknown-schema','sharing')){
   [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($journal))|Out-Null
   if($mode -eq 'malformed'){[IO.File]::WriteAllText($journal,'{broken')}
   else{Save $journal @{schemaVersion=2;status='applied'}}
   if($mode -eq 'sharing'){$held=[IO.File]::Open($journal,'Open','ReadWrite','None')}
  }elseif($mode -eq 'governor'){
   Save (Join-Path $context.data 'process-rules\rules\owned.json') @{enabled=$true;matchMode='path';executablePath=$context.owned.Identity.imagePath;controls=@{$(if($field -eq 'priorityClass'){'cpuPriority'}elseif($field -eq 'affinityMask'){'affinity'}else{$field})=$desired}}
   Save (Join-Path $directory 'owner-shape.json') @{kind='Actual reader of an owned saved-rule record; no live governor/watchdog is claimed'}
  }elseif($mode -eq 'identity-denied'){
   $actor=New-Actor $context 'identity-denied' $desired $journal;$null=Wait-Actor $actor -Held
  }elseif($mode -like 'mutex-*'){
   $actorMode=switch($mode){'mutex-busy'{'busy'};'mutex-denied'{'denied'};'mutex-type'{'wrong-type'};default{'abandoned'}}
   $actor=New-Actor $context $actorMode $desired $journal;$receipt=Wait-Actor $actor -Held
   if($mode -eq 'mutex-abandoned'){$mutexKeep=[Threading.Mutex]::OpenExisting($receipt.mutexName);Stop-OwnedProcess $actor.owned;$actor.process.WaitForExit()}
  }elseif($mode -eq 'identity-unknown'){$snapshot[0].processStartTimeUtc=$null;Save $context.backup $backup;$context.backupHash=(Get-FileHash $context.backup).Hash}
  elseif($mode -eq 'identity-reused'){$snapshot[0].processStartTimeUtc=[DateTime]::FromFileTimeUtc(([long]$context.owned.Identity.creationTimeFileTimeUtc+10000000)).ToString('o');Save $context.backup $backup;$context.backupHash=(Get-FileHash $context.backup).Hash}
  elseif($mode -eq 'identity-ended'){Stop-OwnedProcess $context.owned;$context.process.WaitForExit()}
  if($mode -in @('native-after-read','old-interleaving')){
   $seamSource=if($mode -eq 'old-interleaving'){Require ([IO.Directory]::Exists($OriginalSource)) 'Original b0 export is required for the exact old interleaving.';$OriginalSource}else{$Source}
   $null=New-Breakpoint $context (Join-Path $seamSource 'backend\scripts\ProcessProfile.Common.ps1') $setterPattern ({
    if($meter.hits -eq 0){$meter.hits++;$meter.actor=New-Actor $context 'apply' $external $journal;$meter.receipt=Wait-Actor $meter.actor}
   }.GetNewClosure())
  }
  if($mode -eq 'release-error'){
   $null=New-Breakpoint $context $common '^\s*if \(\$instanceHeld\)' ({
    if(-not $meter.releaseFault -and (Get-Variable control -ErrorAction Stop).Value -eq $field){$meter.releaseFault=$true;(Get-Variable instanceMutex -ErrorAction Stop).Value.ReleaseMutex()}
   }.GetNewClosure())
  }
  if($mode -eq 'readback-mismatch'){
   $null=New-Breakpoint $context $common '^\s*\$actual = Get-RooIndustriesProcessControlReadback \$Process \$control' ({if($meter.hits -eq 0 -and (Get-Variable control -ErrorAction Stop).Value -eq $field){$meter.hits++;& $directSetter $external}}.GetNewClosure())
  }
  if($mode -in @('original-after-preview','kept-changed-back')){
   & $setActual $(if($mode -eq 'original-after-preview'){$original}else{$external})
   $scriptPath=Join-Path $Source ('backend\scripts\'+$(if($kind -eq 'game'){'Stop-GameTuneSession.ps1'}else{'Restore-ProcessProfileBackup.ps1'}))
   $bp=Set-PSBreakpoint -Command Confirm-RooIndustriesRestoreControl -Action ({if($meter.hits -eq 0){$meter.hits++;& $setActual $desired}}.GetNewClosure())
   $context.breakpoints.Add($bp)|Out-Null
  }
  $baselineAttempts=$meter.setterAttempts;$baselinePeer=$meter.peerSetterAttempts
  $newControlsBefore=if($priorityScenarios -contains $mode){Read-E2EControls $context.process}else{$null}
  function Save-NewPhase([string]$phase,$result,[string]$backend=$Source,[string]$backendCommit=$SourceCommit){
   $ended=$context.process.HasExited
   $values=if($ended){$null}else{Read-E2EControls $context.process}
   $status=if($kind -eq 'game'){Get-Content -LiteralPath (Join-Path $directory ('status-'+$phase+'.json')) -Raw|ConvertFrom-Json}else{$null}
   $restoreScriptPath=Join-Path $backend ('backend\scripts\'+$(if($kind -eq 'game'){'Stop-GameTuneSession.ps1'}else{'Restore-ProcessProfileBackup.ps1'}))
   $statusReaderRoot=if($kind -eq 'game'){$Source}else{$null}
   $statusReaderCommit=if($kind -eq 'game'){$SourceCommit}else{$null}
   $statusReaderPath=if($kind -eq 'game'){Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1'}else{$null}
   $statusReaderSha256=if($kind -eq 'game'){Get-HarnessFileSha256 $statusReaderPath}else{$null}
   $observation=@{phase=$phase;productCommit=$backendCommit;restoreBackendPath=$backend;restoreScriptPath=$restoreScriptPath;restoreScriptSha256=(Get-HarnessFileSha256 $restoreScriptPath);driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);statusReaderRoot=$statusReaderRoot;statusReaderCommit=$statusReaderCommit;statusReaderPath=$statusReaderPath;statusReaderSha256=$statusReaderSha256;restorePid=$PID;restoreSession=(Get-Process -Id $PID).SessionId;originalProcess=$context.owned.Identity;ended=$ended;values=$values;pending=(Is-Pending $context $result);result=$result;reopenedStatus=$status;backupSha256=(Get-HarnessFileSha256 $context.backup);targetSetterAttempts=($meter.setterAttempts-$baselineAttempts);peerSetterAttempts=($meter.peerSetterAttempts-$baselinePeer);unlistedSetterAttempts=$meter.unlistedSetterAttempts}
   Save (Join-Path $directory ($phase+'-readback.json')) $observation
   Require ($observation.backupSha256 -ceq $context.backupHash) 'Phase changed original saved backup.'
   if($producerHash){Require ((Get-HarnessFileSha256 (Join-Path $directory 'producer-backup.json')) -ceq $producerHash) 'Phase changed real producer bytes.'}
   return $observation
  }
  function Assert-NewControls($observation){
   Require ($meter.unlistedSetterAttempts -eq 0) 'An unlisted control reached its setter.'
   if(-not $observation.ended){
    foreach($name in 'affinityMask','ioPriority','gpuPriority'){
     if($newControlsBefore[$name].available){Require ($observation.values[$name].available -and (Test-RooIndustriesControlValueEqual $name $observation.values[$name].value $newControlsBefore[$name].value)) ('Unrequested live control changed or became unreadable: '+$name)}
    }
    Require ($observation.values.memoryPriority.available -and (Test-RooIndustriesControlValueEqual 'memoryPriority' $observation.values.memoryPriority.value $peerOriginal)) 'Independent or unrequested memory control differs from its original.'
   }
   $kept=@(Get-RooIndustriesPropertyArray $observation.result 'leftAsSetItems')+@(Get-RooIndustriesPropertyArray $observation.result.result 'leftAsSetItems')
   Require (@($kept|Where-Object {$_.control -ne 'priorityClass' -and (-not $unmatchedReplay -or $_.control -ne 'memoryPriority')}).Count -eq 0) 'Unrequested control received kept attribution.'
   Require ($meter.peerSetterAttempts -eq $baselinePeer+$(if($unmatchedReplay){1}else{0})) 'Genuine peer was omitted/repeated or an unrequested peer was written.'
   $peerRestored=@($observation.result.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq 'memoryPriority')
   Require ($peerRestored.Count -eq $(if($unmatchedReplay -and $observation.phase -eq 'requested-first'){1}else{0})) 'Repeated or unrequested result counted a peer restore.'

  }
  function Assert-NewPending($observation,$expected){
   Assert-Pending $context $observation.result $expected
   if($kind -eq 'game'){
    $attemptStatus=[string]$observation.result.result.status
    Require ($attemptStatus -in @('partial','failed') -and $observation.result.restorable -and $observation.reopenedStatus.restorable) 'Pending Game Tune result or persisted recovery is inconsistent.'
    $expectedEnvelope=if($attemptStatus -ceq 'partial'){'completed'}else{'failed'}
    $expectedReopened=if($attemptStatus -ceq 'partial'){'restorable'}else{'failed'}
    Require ($observation.result.status -ceq $expectedEnvelope -and $observation.result.sessionStatus -ceq $expectedEnvelope -and $observation.reopenedStatus.status -ceq $expectedReopened) 'Pending Game Tune attempt/session/reopened status mapping differs.'
   }else{
    Require ($observation.result.status -in @('partial','failed') -and $observation.result.result.restorePendingCount -eq 1) 'Expected one pending profile snapshot with a partial or failed result.'
   }
   $selected=@($observation.result.preview|ForEach-Object {@($_.controlChanges)}|Where-Object control -eq 'priorityClass')
   Require ($selected.Count -eq 1 -and $selected[0].blocked) 'Missing-record target was omitted or not blocked in the preview.'
   $restored=@($observation.result.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq 'priorityClass')
   Require ($restored.Count -eq 0 -and @($observation.result.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Unverified target was counted restored/kept.'
   if($kind -eq 'game'){Require ($observation.reopenedStatus.restorable -and @($observation.reopenedStatus.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Reopened pending status lost recovery or attributed the target.'}
   Require ($meter.setterAttempts -eq $baselineAttempts) 'Unverified requested or drift value reached a target setter.'
   Assert-NewControls $observation
  }
  function Set-NewExternal($value,[string]$phase){
   $before=Read-E2EControls $context.process
   & $directSetter $value
   $after=Read-E2EControls $context.process
   Save (Join-Path $directory ($phase+'-owned-external.json')) @{kind='OWNED EXTERNAL FIXTURE WRITE; outside product setter breakpoint';originalProcess=$context.owned.Identity;before=$before;after=$after;requested=$value}
   Require ($after.priorityClass.available -and (Test-RooIndustriesControlValueEqual 'priorityClass' $after.priorityClass.value $value)) 'Owned external fixture write did not read back.'
  }
  if($legacyReplay){
   $first=Undo $context 'requested-first';$observation=Save-NewPhase 'requested-first' $first;$readback=$observation.values.priorityClass.value
   Assert-NewPending $observation $desired
   $repeat=Undo $context 'requested-repeat';$observation=Save-NewPhase 'requested-repeat' $repeat;Assert-NewPending $observation $desired
   Set-NewExternal $external 'later-drift'
   $late=Undo $context 'later-drift';$observation=Save-NewPhase 'later-drift' $late;Assert-NewPending $observation $external
   if($legacyEnds){
    Stop-OwnedProcess $context.owned;Require ($context.process.WaitForExit(5000) -and $context.process.HasExited) 'Original pending fixture did not end.'
    $resolved=Undo $context 'ended-resolution';$observation=Save-NewPhase 'ended-resolution' $resolved
   }else{
    Set-NewExternal $original 'original-resolution'
    $resolved=Undo $context 'original-resolution';$observation=Save-NewPhase 'original-resolution' $resolved
    Require ($observation.values.priorityClass.available -and (Test-RooIndustriesControlValueEqual 'priorityClass' $observation.values.priorityClass.value $original)) 'Actual original did not resolve without writing.'
   }
   Require (-not $observation.pending -and $meter.setterAttempts -eq $baselineAttempts) 'Selected terminal legacy history did not finish without a target setter.'
   Require (@($resolved.result.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0 -and @($resolved.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Terminal original/ended target received external attribution.'
   Require (@($resolved.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq 'priorityClass').Count -eq 0) 'Terminal legacy resolution counted a target write.'
   if($kind -eq 'game'){Require (-not $observation.reopenedStatus.restorable -and @($observation.reopenedStatus.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Actual reopened terminal status differs.'}
   Assert-NewControls $observation
  }elseif($mode -eq 'image-alias'){
   $timesOk=$false;$pathOk=$false;$timesError=$null;$pathError=$null;$cimError=$null;$moduleError=$null;$cim=@();$modulePath=$null
   $builder=[Text.StringBuilder]::new(32768);[uint32]$length=$builder.Capacity
   [long]$birth=0;[long]$exitBits=0;[long]$kernelBits=0;[long]$userBits=0
   $timesOk=[RooIndustriesNativeProcessControl]::GetProcessTimes($context.owned.handle,[ref]$birth,[ref]$exitBits,[ref]$kernelBits,[ref]$userBits)
   $timesError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
   $pathOk=[RooIndustriesNativeProcessControl]::QueryFullProcessImageName($context.owned.handle,0,$builder,[ref]$length)
   $pathError=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
   try{$cim=@(Get-CimInstance Win32_Process -Filter ('ProcessId = '+$context.process.Id) -ErrorAction Stop)}catch{$cimError=$_.Exception.ToString()}
   try{$modulePath=$context.process.MainModule.FileName}catch{$moduleError=$_.Exception.ToString()}
   $savedPath=[string]$snapshot[0].executablePath;$rawPath=if($pathOk){$builder.ToString()}else{$null}
   $representationsDiffer=$pathOk -and -not [string]::IsNullOrWhiteSpace($savedPath) -and -not [string]::Equals($savedPath,$rawPath,[StringComparison]::OrdinalIgnoreCase)
   Save (Join-Path $directory 'alias-observations.json') @{sourceCommit=$SourceCommit;reviewedSourceCommit='c50c8c8c9a0c8bd2d9103dc0059d088f79a85964';launchPath=$image;realPath=$realImage;originalProcess=$context.owned.Identity;canonicalImage=$canonicalImage;imageSha256=$canonicalHash;canonicalObservationPhase="original-alias-image-binding";actorSha256=(Get-HarnessFileSha256 $ActorExe);cimExecutablePath=@($cim|ForEach-Object ExecutablePath);cimError=$cimError;mainModulePath=$modulePath;mainModuleError=$moduleError;producerSavedPath=$savedPath;queryFullProcessImageName=$rawPath;pathQuerySucceeded=$pathOk;pathQueryWin32Error=$pathError;timesSucceeded=$timesOk;timesWin32Error=$timesError;nativeCreation=$birth;liveHasExited=$context.process.HasExited;actualName=$context.process.ProcessName;undefinedLiveExitTime=$exitBits;kernelTime=$kernelBits;userTime=$userBits;representationsDiffer=$representationsDiffer;engine=$PSVersionTable.PSVersion.ToString();restorePid=$PID;restoreSession=(Get-Process -Id $PID).SessionId;targetSession=$context.process.SessionId}
   Require ($timesOk -and $birth -gt 0 -and $birth.ToString() -ceq $context.owned.Identity.creationTimeFileTimeUtc -and -not $context.process.HasExited -and $context.process.ProcessName -ieq 'RestoreTarget') 'Original live native creation/name differs.'
   Require ($pathOk -and -not [string]::IsNullOrWhiteSpace($rawPath) -and $cim.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$cim[0].ExecutablePath) -and $null -eq $cimError -and $null -eq $moduleError -and -not [string]::IsNullOrWhiteSpace($modulePath) -and -not [string]::IsNullOrWhiteSpace($savedPath)) 'MISSING ALIAS OBSERVATION: native/CIM/MainModule/producer paths must be successful and nonempty.'
   Require ([RooIndustriesValidationOwnership.Native]::Canonical($realImage) -ieq $context.owned.Identity.imagePath -and (Get-HarnessFileSha256 $realImage) -ceq (Get-HarnessFileSha256 $context.owned.Identity.imagePath) -and $context.process.SessionId -eq (Get-Process -Id $PID).SessionId) 'Original alias canonical image/hash/session differs.'
   if($representationsDiffer){
    Require ([IO.Directory]::Exists($ReviewedSource)) 'The independently bound reviewed c50 export is required for observed differing spellings.'
    $oldAttempts=@{count=0}
    $oldBreakpoint=New-Breakpoint $context (Join-Path $ReviewedSource 'backend\scripts\ProcessProfile.Common.ps1') $setterPattern ({$oldAttempts.count++}.GetNewClosure())
    $old=Undo $context 'c50-alias-comparison' $ReviewedSource;$oldObservation=Save-NewPhase 'c50-alias-comparison' $old $ReviewedSource 'c50c8c8c9a0c8bd2d9103dc0059d088f79a85964'
    Assert-Pending $context $old $desired
    Require ($oldAttempts.count -eq 0 -and @($old.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq 'priorityClass').Count -eq 0 -and @($old.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Observed differing spelling did not reproduce the specific c50 refusal; missing F1 red.'
    $aliasRedReproduced=$true
    Save (Join-Path $directory 'c50-alias-red.json') @{reproduced=$true;productCommit='c50c8c8c9a0c8bd2d9103dc0059d088f79a85964';observation=$oldObservation;setterAttempts=$oldAttempts.count;rawPaths='alias-observations.json'}
    Remove-PSBreakpoint $oldBreakpoint;$null=$context.breakpoints.Remove($oldBreakpoint)
   }else{
    $aliasRedReproduced=$false
    Save (Join-Path $directory 'c50-alias-red.json') @{reproduced=$false;reason='F1 NOT REPRODUCED: actual producer/query spellings agree';missingRed=$true;rawPaths='alias-observations.json'}
   }
   $null=New-Breakpoint $context $common '^\s*if \(\$pass -eq 1\)' ({
    if((Get-Variable control -ErrorAction Stop).Value -eq 'priorityClass'){
     $handle=(Get-Variable queryHandle -ErrorAction Stop).Value;$process=(Get-Variable Process -ErrorAction Stop).Value
     $identityTrace.Add(@{pass=(Get-Variable pass -ErrorAction Stop).Value;created=(Get-Variable created -ErrorAction Stop).Value;undefinedLiveExitTime=(Get-Variable exited -ErrorAction Stop).Value;kernel=(Get-Variable kernel -ErrorAction Stop).Value;user=(Get-Variable user -ErrorAction Stop).Value;savedBirth=(Get-Variable savedBirth -ErrorAction Stop).Value;pid=$process.Id;name=$process.ProcessName;hasExited=$process.HasExited;queryHandle=$handle.ToInt64();queryNativeBirth=[RooIndustriesValidationOwnership.Native]::Created($handle);queryCanonicalImage=[RooIndustriesValidationOwnership.Native]::Image($handle)})|Out-Null
    }
   }.GetNewClosure())
   $first=Undo $context 'current-green';$observation=Save-NewPhase 'current-green' $first;$readback=$observation.values.priorityClass.value
   Save (Join-Path $directory 'identity-trace.json') @($identityTrace.ToArray())
   Require (-not $observation.pending -and (Test-RooIndustriesControlValueEqual 'priorityClass' $readback $original) -and $meter.setterAttempts -eq $baselineAttempts+1) 'Current actual alias apply/Undo did not restore and verify original.'
   Require ($identityTrace.Count -eq 2 -and $identityTrace[0].pass -eq 1 -and $identityTrace[1].pass -eq 2) 'Actual priority confirmation did not observe both native birth passes.'
   foreach($trace in $identityTrace){Require ($trace.created -gt 0 -and $trace.created.ToString() -ceq $context.owned.Identity.creationTimeFileTimeUtc -and $trace.queryNativeBirth -eq $trace.created -and $trace.savedBirth -eq $trace.created -and -not $trace.hasExited -and $trace.pid -eq $context.process.Id -and $trace.name -ieq 'RestoreTarget') 'Actual two-pass original native identity differs.'}
   Require (@($first.result.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0 -and @($first.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Original alias target received kept attribution.'
   Require ([RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString() -ceq $context.owned.Identity.creationTimeFileTimeUtc -and [RooIndustriesValidationOwnership.Native]::Image($context.owned.handle) -ieq $context.owned.Identity.imagePath) 'Alias original process handle identity changed.'
   Assert-NewControls $observation
   Save (Join-Path $directory 'current-green.json') @{productCommit=$SourceCommit;observation=$observation;aliasRedReproduced=$aliasRedReproduced;identityTrace=@($identityTrace.ToArray());passed=$true}
  }elseif($mode -in @('confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch')){
   $identityBreakpoint=New-Breakpoint $context $common '^\s*\$candidateConfirmed = \$false' ({
    if($meter.hits -eq 0 -and (Get-Variable control -ErrorAction Stop).Value -eq $field){
     $meter.hits++
     $boundEntry=(Get-Variable Entry -ErrorAction Stop).Value;$boundSnapshot=(Get-Variable Snapshot -ErrorAction Stop).Value
     $before=@{entryId=$boundEntry.processId;entryPath=$boundEntry.executablePath;entryStart=$boundEntry.processStartTimeUtc;savedName=$boundSnapshot.processName}
     switch($mode){
      'confirm-name-mismatch'{$boundSnapshot.processName='DifferentOwnedFixture.exe'}
      'entry-pid-mismatch'{$boundEntry.processId=[int]$context.process.Id+1}
      'entry-path-mismatch'{$boundEntry.executablePath=[string]$boundSnapshot.executablePath+'.different'}
      'entry-start-mismatch'{$boundEntry.processStartTimeUtc=[DateTime]::FromFileTimeUtc(([long]$context.owned.Identity.creationTimeFileTimeUtc+10000000)).ToString('o')}
     }
     Save (Join-Path $directory 'constructed-input-mutation.json') @{kind='CONSTRUCTED in-memory Confirm input mutation after real preview; not actual PID reuse or outside tampering';scenario=$mode;before=$before;after=@{entryId=$boundEntry.processId;entryPath=$boundEntry.executablePath;entryStart=$boundEntry.processStartTimeUtc;savedName=$boundSnapshot.processName};originalProcess=$context.owned.Identity}
    }
   }.GetNewClosure())
   $first=Undo $context 'constructed-refusal';$observation=Save-NewPhase 'constructed-refusal' $first;$readback=$observation.values.priorityClass.value
   Assert-Pending $context $first $desired
   Require ($meter.hits -eq 1 -and $meter.setterAttempts -eq $baselineAttempts -and @($first.result.skippedItems|Where-Object {$_.reason -like '*priorityClass*'}).Count -gt 0) 'Constructed coherence input did not yield one captured refusal without setter.'
   Require (@($first.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq 'priorityClass').Count -eq 0 -and @($first.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Constructed refusal was counted restored/kept.'
   Assert-NewControls $observation
   Remove-PSBreakpoint $identityBreakpoint;$null=$context.breakpoints.Remove($identityBreakpoint)
   $positive=Undo $context 'fresh-backup-positive';$observation=Save-NewPhase 'fresh-backup-positive' $positive
   Require (-not $observation.pending -and (Test-RooIndustriesControlValueEqual 'priorityClass' $observation.values.priorityClass.value $original) -and $meter.setterAttempts -eq $baselineAttempts+1) 'Fresh unchanged-backup positive control failed.'
   Require (@($positive.result.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0 -and @($positive.leftAsSetItems|Where-Object control -eq 'priorityClass').Count -eq 0) 'Fresh positive original was attributed to another writer.'
   Assert-NewControls $observation
  }else{

  $first=Undo $context 'first' $(if($mode -eq 'old-interleaving'){$OriginalSource}else{$Source})
  if($mode -eq 'mutex-abandoned'){Require ($meter.abandoned -eq 1) 'A genuine abandoned mutex acquisition was not observed.'}
  if($mode -in @('mutex-busy','mutex-denied','mutex-type')){Require ($meter.releases -eq 0) 'Unacquired instance mutex was released.'}
  $readback=if($context.process.HasExited){$null}else{Read-Actual $context.process $field}
  if(-not $context.process.HasExited -and $meter.peerSetterAttempts -gt $baselinePeer){Require (Test-RooIndustriesControlValueEqual $peer (Read-Actual $context.process $peer) $peerOriginal) 'Attempted peer restore did not actually read back its original.'}
  $uncertain=$mode -in @('native-before','protected-launcher','protected-game','governor','malformed','unknown-schema','sharing','mutex-busy','mutex-denied','mutex-type','identity-unknown','identity-denied','release-error','setter-denied','readback-mismatch','failed-apply-readback','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified','original-after-preview','kept-changed-back')
  if($mode -eq 'old-interleaving'){
   Require ($meter.hits -eq 1 -and $meter.receipt.outcome -ceq 'applied') 'Old source did not run the real successful competing Core actor.'
   Require ($readback.ToString() -eq $original.ToString() -and -not (Is-Pending $context $first)) 'Original b0 did not reproduce native actor overwrite/closed recovery.'
   Save (Join-Path $directory 'old-bug.json') @{reproduced=$true;nativeApplied=$external;undoOverwrote=$readback;expectedNewOracle='Competing successful native apply is never overwritten'}
   $nativeJournal=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
   $nativeName=switch($field){'priorityClass'{'cpuPriority'};'affinityMask'{'affinity'};default{$field}}
   $nativeChange=@($nativeJournal.changes|Where-Object name -CEQ $nativeName)
   Require ($nativeChange.Count -eq 1 -and $nativeJournal.preview.identity.processId -eq $context.process.Id -and $nativeJournal.preview.identity.creationTimeFileTimeUtc -ceq $context.owned.Identity.creationTimeFileTimeUtc) 'Post-red cleanup journal is not the original native fixture change.'
   $nativeOriginal=switch($field){
    'priorityClass'{if($nativeChange[0].original -ceq 'Realtime'){'RealTime'}else{[string]$nativeChange[0].original}}
    'affinityMask'{
     Require ($nativeChange[0].original.group -eq 0) 'Unexpected original native affinity group.'
     $mask=[string]$nativeChange[0].original.mask
     $unsigned=if($mask.StartsWith('0x',[StringComparison]::OrdinalIgnoreCase)){[uint64]::Parse($mask.Substring(2),[Globalization.NumberStyles]::HexNumber,[Globalization.CultureInfo]::InvariantCulture)}else{[uint64]::Parse($mask,[Globalization.CultureInfo]::InvariantCulture)}
     [BitConverter]::ToInt64([BitConverter]::GetBytes($unsigned),0)
    }

    'ioPriority'{@('VeryLow','Low','Normal','High')[[int]$nativeChange[0].original]}
    'gpuPriority'{@('Idle','BelowNormal','Normal','AboveNormal','High','Realtime')[[int]$nativeChange[0].original]}
    'memoryPriority'{[int]$nativeChange[0].original}
   }
   Require (Test-RooIndustriesControlValueEqual $field $nativeOriginal $desired) 'Native saved original differs from the pre-actor desired fixture value; no guessed cleanup authority.'
   & $setActual $nativeOriginal
   Require (Test-RooIndustriesControlValueEqual $field (Read-Actual $context.process $field) $nativeOriginal) 'Post-red owned fixture cleanup did not verify native original.'
   Save (Join-Path $directory 'post-red-owned-fixture-cleanup.json') @{kind='POST-RED OWNED FIXTURE CLEANUP; not Undo proof';journalOriginal=$nativeChange[0].original;mappedOriginal=$nativeOriginal;readback=(Read-Actual $context.process $field);originalIdentity=$context.owned.Identity}
   $actor=New-Actor $context 'restore' $desired $journal;$cleanupReceipt=Wait-Actor $actor
   Save (Join-Path $directory 'post-red-native-journal-cleanup.json') $cleanupReceipt
  }elseif($mode -eq 'native-after-read'){
   Require ($meter.hits -eq 1 -and $meter.receipt.outcome -ceq 'instance-busy' -and $meter.actor.process.ExitCode -eq 10) 'Held restore lease did not produce exact InstanceBusyException.'
   Require ($readback.ToString() -eq $original.ToString() -and -not (Is-Pending $context $first)) 'Restore-held lease did not restore and verify original.'
  }elseif($mode -in @('verified-external','schema-records')){
   Require ($readback.ToString() -eq $external.ToString() -and -not (Is-Pending $context $first)) 'Verified external control was not kept.'
   Require (@($first.result.leftAsSetItems|Where-Object {$_.control -eq $field -and $_.currentValue.ToString() -eq $external.ToString()}).Count -eq 1) 'Verified kept record missing.'
  }elseif($uncertain){
   Require (Is-Pending $context $first) 'Failure/uncertainty lost recovery.'
   Require (@($first.result.leftAsSetItems|Where-Object control -eq $field).Count -eq 0) 'Failure/uncertainty was certified kept.'
   if($mode -eq 'release-error'){
    Require ($meter.releaseFault -and $readback.ToString() -eq $original.ToString()) 'Real release failure did not follow a verified original readback.'
    $counted=@($first.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq $field)
    Require ($counted.Count -eq 0) 'Release failure was counted as a restored control.'
   }
   if($mode -in @('native-before','protected-launcher','protected-game','governor')){Require ($meter.peerSetterAttempts -eq $baselinePeer+1) 'Independent peer did not restore exactly once.'}
   if($mode -in @('setter-denied','readback-mismatch')){
    Require ($meter.setterAttempts -eq $baselineAttempts+1 -and $meter.setterFailures.Count -eq 1) 'Expected exactly one actual target setter attempt and its captured failure.'
    $failedChange=@($first.preview|ForEach-Object {@($_.controlChanges)}|Where-Object {$_.control -eq $field -and $_.outcome -ceq 'failed'})
    $refusal=@($first.result.skippedItems|Where-Object {$_.processId -eq $context.process.Id -and $_.reason -like ('*'+$field+'*')})
    $counted=@($first.result.changedItems|ForEach-Object {@($_.restoredControls)}|Where-Object control -eq $field)
    Require ($failedChange.Count -eq 1 -and $refusal.Count -gt 0 -and $counted.Count -eq 0) 'Setter failure lacks target failed outcome/refusal or was counted restored.'
    if($mode -eq 'setter-denied'){
     Require ($meter.setterFailures[0].nativeCodes -contains 5 -and $readback.ToString() -eq $desired.ToString()) 'Target setter did not actually fail with access denied and preserve the applied value.'
     Require ($denial.applied -and $denial.restored -and $null -eq $denial.acl -and $denial.restorePhase -ceq 'target-failure-observer-before-peer') 'Target denial was not injected and restored at the shared setter/failure boundaries.'
     Require ($meter.peerSetterAttempts -eq $baselinePeer+1 -and (Test-RooIndustriesControlValueEqual $peer (Read-Actual $context.process $peer) $peerOriginal)) 'Independent peer must attempt once and actually restore its original after denial is removed.'
    }else{
     Require ($meter.hits -eq 1 -and $readback.ToString() -eq $external.ToString() -and $meter.setterFailures[0].message -like ('*Windows kept a different value for '+$field+'*')) 'Intended setter/readback mismatch was not actually observed.'
    }
   }
   if($mode -notin @('setter-denied','readback-mismatch','release-error')){Require ($meter.setterAttempts -eq $baselineAttempts) 'Unapproved target setter attempt ran.'}
   if($mode -in @('failed-apply-readback','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified')){
    $unverifiedCurrent=if($mode -in @('failed-target','pending-target','missing-outcome')){$desired}else{$external}
    Assert-Pending $context $first $unverifiedCurrent
    $repeat=Undo $context 'repeat';Assert-Pending $context $repeat $unverifiedCurrent
    & $setActual $external;$late=Undo $context 'late';Assert-Pending $context $late $external
    Require ($meter.peerSetterAttempts -eq $baselinePeer+1) 'Independent peer setter attempts were not exactly one.'
    if($mode -in @('failed-ended','pending-ended')){
     Stop-OwnedProcess $context.owned;$context.process.WaitForExit()
     $resolved=Undo $context 'ended-resolution'
     Require (-not (Is-Pending $context $resolved)) 'Ended uncertain original instance did not resolve without writing.'
     Require ($meter.setterAttempts -eq $baselineAttempts+1) 'Unverified Undo attempted a target setter before ended resolution.'
    }else{
     & $setActual $original;$resolved=Undo $context 'original-resolution';Require (-not (Is-Pending $context $resolved)) 'Actual original did not resolve without an uncertain write.'
     Require ($meter.setterAttempts -eq $baselineAttempts+2) 'Unverified Undo attempted the target setter.'
    }
   }
  }elseif($mode -eq 'identity-reused'){
   Require (-not (Is-Pending $context $first)) 'Known ended saved instance did not close recovery.'
   Require ($meter.setterAttempts -eq $baselineAttempts -and $readback.ToString() -eq $desired.ToString()) 'Undo retargeted the different live instance.'
  }else{
   Require (-not (Is-Pending $context $first)) 'Supported original/ended restore remains pending.'
   if(-not $context.process.HasExited){Require ($readback.ToString() -eq $original.ToString()) 'Exact original was not restored.'}
  }
  if($mode -in @('native-before','protected-launcher','protected-game')){
   $actor=New-Actor $context 'restore' $desired $journal;$null=Wait-Actor $actor
   $retry=Undo $context 'released-retry';Require (-not(Is-Pending $context $retry) -and (Read-Actual $context.process $field).ToString() -eq $original.ToString()) 'Release/retry failed to restore saved original.'
   Require ($meter.peerSetterAttempts -eq $baselinePeer+1) 'Native release/retry restored an independent peer twice.'
  }
  if($mode -eq 'duplicate-snapshot'){
   Require (@($first.preview).Count -eq 2 -and $first.preview[0].ruleId -ceq 'first-original-snapshot' -and $first.preview[1].ruleId -ceq 'second-original-snapshot') 'Duplicate immutable snapshot order was lost.'
  }
  if($mode -eq 'schema-records' -and $kind -eq 'game'){
   $sessionBytes=[IO.File]::ReadAllBytes($context.session)
   try{
    $legacy=Get-Content -LiteralPath $context.session -Raw|ConvertFrom-Json
    Require (@($legacy.leftAsSetItems).Count -gt 0) 'Real kept result is required before legacy metadata replay.'
    foreach($item in @($legacy.leftAsSetItems)){$item.appliedValue=$null;$item.originalValue=$null}
    Save $context.session $legacy
    $legacyStatus=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $context.session|ConvertFrom-Json
    Save (Join-Path $directory 'status-legacy-null.json') $legacyStatus
    Save (Join-Path $directory 'legacy-metadata-kind.json') @{kind='Nullable persisted metadata replay on a genuine verified kept record; actual GetStatus producer, not new OS attribution'}
   }finally{[IO.File]::WriteAllBytes($context.session,$sessionBytes)}
  }
  }
  Require ((Get-FileHash -LiteralPath $context.backup -Algorithm SHA256).Hash -ceq $context.backupHash) 'Post-case fixture/journal cleanup changed original backup bytes.'
  Save (Join-Path $directory 'observations.json') @{sourceCommit=$SourceCommit;kind=$kind;control=$field;scenario=$mode;original=$original;requested=$desired;external=$external;firstReadback=$readback;targetSetterAttempts=($meter.setterAttempts-$baselineAttempts);peerSetterAttempts=($meter.peerSetterAttempts-$baselinePeer);counterSemantics='Breakpoint before setter: attempts only; successful OS writes require actual readback, not this counter';unlistedSetterAttempts=$meter.unlistedSetterAttempts;aliasRedReproduced=$aliasRedReproduced;identityTrace=@($identityTrace.ToArray());producerBackupSha256=$producerHash;denialPhases=@{injected=$denial.applied;restored=$denial.restored;originalAclPending=($null -ne $denial.acl);injectionPhase=$denial.injectionPhase;restorePhase=$denial.restorePhase;ownedIdentity=$context.owned.Identity};setterFailures=@($meter.setterFailures.ToArray());breakpointHits=$meter.hits;restoreSessionId=(Get-Process -Id $PID).SessionId;nativeBirth=$context.owned.Identity.creationTimeFileTimeUtc;backupSha256=$context.backupHash;engine=$PSVersionTable.PSVersion.ToString()}
 }catch{$bodyError=$_;Save (Join-Path $directory 'failure.json') @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace}}
 finally{
  foreach($bp in $context.breakpoints){try{Remove-PSBreakpoint $bp}catch{$cleanups.Add($_.Exception.ToString())|Out-Null}}
  try{if($held){$held.Dispose()}}catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
  try{if($mutexKeep){$mutexKeep.Dispose()}}catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
  try{
   if($denial.acl -and $context.owned -and $context.process -and -not $context.process.HasExited){
    [RooIndustriesBackgroundOracle]::RestoreDacl($context.process,$denial.acl)
    $denial.acl=$null
    $denial.restored=$true
    $denial.restorePhase='finally-fallback'
   }
  }catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
  foreach($actor in $context.actors){
   try{
    [IO.File]::WriteAllText($actor.release,'release')
    if(-not$actor.process.HasExited -and -not$actor.process.WaitForExit(3000)){Stop-OwnedProcess $actor.owned;$actor.process.WaitForExit();throw 'Actor did not release its original resources in time.'}
    [IO.File]::WriteAllText(($actor.output+'.final-stdout.log'),$actor.stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText(($actor.output+'.final-stderr.log'),$actor.stderr.GetAwaiter().GetResult())
    if($actor.mode -in @('busy','denied','identity-denied','wrong-type')){Require ($actor.process.ExitCode -eq 0) 'Actor ACL/mutex cleanup failed.'}
   }catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
   finally{$actor.process.Dispose()}
  }
  try{
   if($context.owned){
    Stop-OwnedProcess $context.owned
    Require ($context.process.WaitForExit(5000) -and $context.process.HasExited) 'Original fixture did not exit.'
    $context.process.Dispose()
    $targetCleanupSucceeded=$true
   }elseif($null -eq $context.process){$targetCleanupSucceeded=$true}
   else{throw 'Original target lacks ownership proof; handle and alias dependencies retained.'}
  }catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
  $aliasRemovalFailed=-not $targetCleanupSucceeded
  try{if($aliasProbe){$aliasProbe.Dispose();$aliasProbe=$null}}catch{$aliasRemovalFailed=$true;$cleanups.Add($_.Exception.ToString())|Out-Null}
  if($aliasCreationAttempted -and -not $aliasRegistered){$aliasRemovalFailed=$true;$cleanups.Add('Attempted unregistered alias retained with original target dependencies: '+$alias)|Out-Null}
  if($aliasImageCreationAttempted -and $null -eq $imageEntry){$aliasRemovalFailed=$true;$cleanups.Add('Unregistered owned image creation retained with original real folder: '+$realImage)|Out-Null}
  $originalAliasEntries=@($aliasEntries.ToArray());[array]::Reverse($originalAliasEntries)
  foreach($ownedEntry in $originalAliasEntries){
   if($aliasRemovalFailed){$cleanups.Add('Retained original alias target dependency: '+$ownedEntry.id)|Out-Null;continue}
   try{
    if($ownedEntry.kind -eq 'folder' -and -not $ownedEntry.metadata.reparseTarget){Require (@([IO.Directory]::EnumerateFileSystemEntries($ownedEntry.identity.path)).Count -eq 0) 'Original real folder is not empty; no recursive dependency cleanup.'}
    Remove-HarnessEntry $ownedEntry
   }catch{$aliasRemovalFailed=$true;$cleanups.Add($_.Exception.ToString())|Out-Null}

  }
  $aliasFinalEntries=New-Object System.Collections.Generic.List[object]
  foreach($ownedEntry in @($aliasEntries.ToArray())){
   try{
    $same=@(Get-HarnessEntries|Where-Object id -CEQ $ownedEntry.id)
    Require ($same.Count -eq 1) 'Original alias ledger ID missing or ambiguous.'
    $aliasFinalEntries.Add($same[0])|Out-Null
    Require ($same[0].state -ceq 'removed' -and [string]::IsNullOrWhiteSpace([string]$same[0].cleanupError) -and -not(Test-HarnessPath $ownedEntry.identity.path)) ('Original alias resource not removed: '+$ownedEntry.id)
   }catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
  }
  if($mode -eq 'image-alias'){
   try{Save (Join-Path $directory 'alias-cleanup.json') @{targetCleanupSucceeded=$targetCleanupSucceeded;aliasCreationAttempted=$aliasCreationAttempted;aliasRegistered=$aliasRegistered;originalProcess=$context.owned.Identity;originalEntries=@($aliasEntries.ToArray());finalSameIdEntries=@($aliasFinalEntries.ToArray());aliasPath=$alias;realImage=$realImage;realFolder=$real;errors=@($cleanups.ToArray())}}catch{$cleanups.Add($_.Exception.ToString())|Out-Null}
  }

  Save (Join-Path $directory 'cleanup.json') @{ownedProcess=$context.owned.Identity;denialPhases=@{injected=$denial.applied;restored=$denial.restored;originalAclPending=($null -ne $denial.acl);injectionPhase=$denial.injectionPhase;restorePhase=$denial.restorePhase;ownedIdentity=$context.owned.Identity};originalSetterFailures=$(if($null -ne $meter){@($meter.setterFailures.ToArray())}else{@()});errors=@($cleanups.ToArray());breakpointsRemoved=@($context.breakpoints).Count;ownedOnly=$true;nativeBehaviorSimulated=$false;targetCleanupSucceeded=$targetCleanupSucceeded;aliasCreationAttempted=$aliasCreationAttempted;aliasRegistered=$aliasRegistered;aliasOriginalEntries=@($aliasEntries.ToArray());aliasFinalEntries=@($aliasFinalEntries.ToArray())}
 }
 if($bodyError){throw $bodyError};Require ($cleanups.Count -eq 0) 'Original-identity cleanup failed.'
 Save (Join-Path $directory 'done.json') @{passed=$true;sourceCommit=$SourceCommit;kind=$kind;control=$field;scenario=$mode;cleanupPassed=$true}
 $results.Add(@{kind=$kind;control=$field;scenario=$mode;passed=$true;aliasRedReproduced=$aliasRedReproduced})|Out-Null
}}
$kinds=if($Kind -eq 'all'){@('profile','game')}else{@($Kind)}
$controls=if($Control -eq 'all'){@('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority')}else{@($Control)}
$selected=New-Object System.Collections.Generic.List[object]
foreach($body in $kinds){foreach($field in $controls){foreach($case in $Scenario){
 if($case -eq 'protected-game' -and $field -ne 'gpuPriority'){continue}
 if($case -eq 'protected-launcher' -and $field -ne 'memoryPriority'){continue}
 if($priorityScenarios -contains $case -and $field -ne 'priorityClass'){continue}
 $selected.Add(@{kind=$body;control=$field;scenario=$case})|Out-Null
}}}
Save (Join-Path $root 'selection.json') @{sourceCommit=$SourceCommit;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);scope='Authored selected triples; actual success requires each assertion and cleanup';expectedCaseCount=$selected.Count;cases=@($selected.ToArray())}
foreach($case in $selected){Run-Scenario $case.kind $case.control $case.scenario}
Require ($results.Count -eq $selected.Count) 'Actual completed triples differ from the selected source grid.'

Save (Join-Path $root 'serialization-summary.json') @{sourceCommit=$SourceCommit;cases=@($results.ToArray());expectedCaseCount=$selected.Count;actualCaseCount=$results.Count;selectedTriples=@($selected.ToArray());engine=$PSVersionTable.PSVersion.ToString();nativeBehaviorSimulated=$false;passed=$true}
'ROO_INDUSTRIES_RESTORE_SERIALIZATION_E2E_COMPLETE'
