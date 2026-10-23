param(
 [Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][string]$ActorExe,[Parameter(Mandatory)][string]$SourceCommit,
 [string]$OriginalSource='',
 [string]$ReviewedSource='',
 [string]$BeforeNoEffectSource='',
 [ValidateSet('profile','game','all')][string]$Kind='all',
 [ValidateSet('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority','all')][string]$Control='all',
 [ValidateSet('normal','native-before','native-after-read','protected-launcher','protected-game','governor','malformed','unknown-schema','sharing','mutex-busy','mutex-denied','mutex-type','mutex-abandoned','identity-unknown','identity-denied','identity-reused','identity-ended','release-error','setter-denied','readback-mismatch','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified','verified-external','original-after-preview','kept-changed-back','old-interleaving','failed-apply-readback','schema-records','duplicate-snapshot','image-alias','legacy-proposed-absent','legacy-applied-absent','legacy-proposed-empty','legacy-applied-empty','legacy-proposed-unmatched','legacy-applied-unmatched','confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch','legacy-proposed-absent-ended','legacy-applied-absent-ended','legacy-proposed-empty-ended','legacy-applied-empty-ended','legacy-proposed-unmatched-ended','legacy-applied-unmatched-ended','no-effect-original','no-effect-external','no-effect-after-preview','no-effect-applied-equal','no-effect-applied-conflict','no-effect-proposed-missing','no-effect-proposed-null','no-effect-proposed-invalid','no-effect-applied-invalid','no-effect-applied-null','no-effect-record-applied','no-effect-record-failed','no-effect-record-pending','no-effect-record-unknown','no-effect-changed-absent','no-effect-changed-empty','no-effect-changed-unmatched','no-effect-changed-absent-ended','no-effect-changed-empty-ended','no-effect-changed-unmatched-ended','no-effect-confirm-busy-retry','no-effect-confirm-busy-ended','no-effect-confirm-wrapper-retry','no-effect-confirm-wrapper-ended','no-effect-affinity-decimal','no-effect-affinity-hex','late-exit-restore','late-exit-original','late-exit-kept','late-exit-postwrite','late-exit-release-error')]
 [string[]]$Scenario=@(),
 [ValidateSet('default','harness-blocked')][string]$Group='default'
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
$scenarioGroups=@{'default'=@('normal','native-before','protected-launcher','protected-game','malformed','unknown-schema','sharing','mutex-busy','mutex-denied','mutex-type','mutex-abandoned','identity-unknown','identity-reused','identity-ended','failed-drift','failed-target','unknown-drift','missing-outcome','failed-ended','pending-drift','pending-target','pending-ended','late-unverified','verified-external','original-after-preview','kept-changed-back','schema-records','duplicate-snapshot','no-effect-original','no-effect-affinity-decimal','no-effect-affinity-hex');'harness-blocked'=@('native-after-read','governor','identity-denied','release-error','setter-denied','readback-mismatch','old-interleaving','failed-apply-readback','image-alias','legacy-proposed-absent','legacy-applied-absent','legacy-proposed-empty','legacy-applied-empty','legacy-proposed-unmatched','legacy-applied-unmatched','confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch','legacy-proposed-absent-ended','legacy-applied-absent-ended','legacy-proposed-empty-ended','legacy-applied-empty-ended','legacy-proposed-unmatched-ended','legacy-applied-unmatched-ended','no-effect-external','no-effect-after-preview','no-effect-applied-equal','no-effect-applied-conflict','no-effect-proposed-missing','no-effect-proposed-null','no-effect-proposed-invalid','no-effect-applied-invalid','no-effect-applied-null','no-effect-record-applied','no-effect-record-failed','no-effect-record-pending','no-effect-record-unknown','no-effect-changed-absent','no-effect-changed-empty','no-effect-changed-unmatched','no-effect-changed-absent-ended','no-effect-changed-empty-ended','no-effect-changed-unmatched-ended','no-effect-confirm-busy-retry','no-effect-confirm-busy-ended','no-effect-confirm-wrapper-retry','no-effect-confirm-wrapper-ended','late-exit-restore','late-exit-original','late-exit-kept','late-exit-postwrite','late-exit-release-error')}
$selectedGroup=if($Scenario.Count){'named'}else{$Scenario=$scenarioGroups[$Group];$Group}
$lateScenarios=@('late-exit-restore','late-exit-original','late-exit-kept','late-exit-postwrite','late-exit-release-error')
$priorityScenarios=@('image-alias','legacy-proposed-absent','legacy-applied-absent','legacy-proposed-empty','legacy-applied-empty','legacy-proposed-unmatched','legacy-applied-unmatched','confirm-name-mismatch','entry-pid-mismatch','entry-path-mismatch','entry-start-mismatch','legacy-proposed-absent-ended','legacy-applied-absent-ended','legacy-proposed-empty-ended','legacy-applied-empty-ended','legacy-proposed-unmatched-ended','legacy-applied-unmatched-ended')
if($Control -notin @('all','priorityClass') -and @($Scenario|Where-Object {$priorityScenarios -contains $_}).Count){throw 'The seventeen new scenarios are explicitly priorityClass-only; incompatible -Control is not a skipped case.'}
$noEffectScenarios=@('no-effect-original','no-effect-external','no-effect-after-preview','no-effect-applied-equal','no-effect-applied-conflict','no-effect-proposed-missing','no-effect-proposed-null','no-effect-proposed-invalid','no-effect-applied-invalid','no-effect-applied-null','no-effect-record-applied','no-effect-record-failed','no-effect-record-pending','no-effect-record-unknown','no-effect-changed-absent','no-effect-changed-empty','no-effect-changed-unmatched','no-effect-changed-absent-ended','no-effect-changed-empty-ended','no-effect-changed-unmatched-ended','no-effect-confirm-busy-retry','no-effect-confirm-busy-ended','no-effect-confirm-wrapper-retry','no-effect-confirm-wrapper-ended','no-effect-affinity-decimal','no-effect-affinity-hex')
$affinityScenarios=@('no-effect-affinity-decimal','no-effect-affinity-hex')
if($Control -notin @('all','affinityMask') -and @($Scenario|Where-Object {$affinityScenarios -contains $_}).Count){throw 'The two affinity representation scenarios require affinityMask; incompatible -Control is not skipped.'}
if($BeforeNoEffectSource -and ($Scenario.Count -ne 1 -or $Scenario[0] -cne 'no-effect-external' -or $Control -cne 'memoryPriority')){throw 'BeforeNoEffectSource requires exactly no-effect-external and memoryPriority, with profile/game/all.'}
if($BeforeNoEffectSource -and -not [IO.Directory]::Exists($BeforeNoEffectSource)){throw 'The exact preserved before-no-effect 861 source is required.'}
function Save([string]$path,$value){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null;[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 60),$utf8)}
function Require([bool]$ok,[string]$message){if(-not $ok){throw $message}}
function Get-CaseDirectoryName([string]$Kind,[string]$Control,[string]$Scenario){
 $hash=[Security.Cryptography.SHA256]::Create()
 try{return $Kind+'-'+([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Kind+'|'+$Control+'|'+$Scenario)))).Replace('-','').Substring(0,16).ToLowerInvariant()}
 finally{$hash.Dispose()}
}
function Read-Ast([string]$path){$e=$null;$t=$null;$a=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e);if($e.Count){throw ($e -join '; ')};return $a}
function New-BackendBlock([string]$Path,$Extent){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseInput(("`n"*($Extent.StartLineNumber-1))+$Extent.Text,$Path,[ref]$t,[ref]$e);if($e.Count){throw ($e -join '; ')};return $a.GetScriptBlock()}
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
function New-LateMutationGuard([object[]]$Originals, [string]$Nonce) {
 $slots=New-Object System.Collections.Generic.List[object]
 foreach($original in $Originals){
  Require ($null -ne $original -and $null -ne $original.process -and $null -ne $original.owned) 'MISSING original late mutation ownership.'
  $receipt=$original.owned
  $identity=$receipt.Identity
  Require ([object]::ReferenceEquals($original.process,$receipt.process)) 'Late mutation receipt owns another wrapper.'
  Require ($identity.pid -gt 0 -and $receipt.handle -ne [IntPtr]::Zero -and $original.process.Id -eq $identity.pid -and $original.process.Handle -eq $receipt.handle) 'Late mutation original handle/PID differs.'
  [long]$birth=0
  Require ([long]::TryParse([string]$identity.creationTimeFileTimeUtc,[ref]$birth) -and $birth -gt 0 -and -not[string]::IsNullOrWhiteSpace([string]$identity.imagePath)) 'MISSING late mutation original identity.'
  Require ([RooIndustriesValidationOwnership.Native]::Created($receipt.handle) -eq $birth -and [string]::Equals([RooIndustriesValidationOwnership.Native]::Image($receipt.handle),[string]$identity.imagePath,[StringComparison]::OrdinalIgnoreCase)) 'Late mutation original native identity differs.'
  Require (@($slots | Where-Object {$_.pid -eq $identity.pid}).Count -eq 0) 'Ambiguous late mutation original PID.'
  $slots.Add([pscustomobject]@{pid=[int]$identity.pid;birth=$birth;image=[string]$identity.imagePath;handle=[IntPtr]$receipt.handle;process=$original.process}) | Out-Null
 }
 Require ($slots.Count -gt 0 -and -not[string]::IsNullOrWhiteSpace($Nonce)) 'Empty late mutation ownership set.'
 return [pscustomobject]@{nonce=$Nonce;originals=$slots.ToArray();events=(New-Object System.Collections.Generic.List[object]);rejections=(New-Object System.Collections.Generic.List[object])}
}

function Invoke-Body([string]$backend,[string]$scriptName,[hashtable]$arguments,[string]$data,$MutationGuard=$null){
 & {
  . (Join-Path $backend 'backend\scripts\GameTuneSession.Common.ps1')
  $script:RestoreE2EData=$data
  function Get-RooIndustriesLocalDataRoot{return $script:RestoreE2EData}
  $scriptPath=Join-Path $backend ('backend\scripts\'+$scriptName)
  $ast=Read-Ast $scriptPath
  foreach($statement in $ast.EndBlock.Statements){
   if($statement -is [Management.Automation.Language.FunctionDefinitionAst]){. (New-BackendBlock $scriptPath $statement.Extent)}
   elseif($statement -is [Management.Automation.Language.AssignmentStatementAst]){. (New-BackendBlock $scriptPath $statement.Extent)}
  }
  foreach($parameter in @($ast.ParamBlock.Parameters)){$name=$parameter.Name.VariablePath.UserPath;if(-not $arguments.ContainsKey($name)){Set-Variable -Name $name -Value $(if($parameter.DefaultValue){& (New-BackendBlock $scriptPath $parameter.DefaultValue.Extent)}elseif($parameter.StaticType -eq [switch]){$false}) -Scope Local}}
  foreach($key in $arguments.Keys){Set-Variable -Name $key -Value $arguments[$key] -Scope Local}
  $body=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
  Require ($body.Count -eq 1) 'Expected one actual top-level backend body.'
  $lateGuardInstalled=$false
  $lateGuardPriorExists=$false
  $lateGuardPriorValue=$null
  try {
   if($null -ne $MutationGuard){
    Require ($MutationGuard.originals.Count -gt 0 -and $null -ne $MutationGuard.events -and $null -ne $MutationGuard.rejections) 'MISSING late mutation guard input.'
    $realMutator=Get-Command Invoke-RooIndustriesProcessControlChange -CommandType Function -ErrorAction Stop
    $realCommon=Join-Path $backend 'backend\scripts\ProcessProfile.Common.ps1'
    Require ([string]::Equals([IO.Path]::GetFullPath($realMutator.ScriptBlock.Ast.Extent.File),[IO.Path]::GetFullPath($realCommon),[StringComparison]::OrdinalIgnoreCase)) 'Late guard did not capture the actual backend mutator.'
    $prior=Get-Variable -Name RestoreE2ELateMutationGuard -Scope Script -ErrorAction SilentlyContinue
    $lateGuardPriorExists=$null -ne $prior
    if($lateGuardPriorExists){$lateGuardPriorValue=$prior.Value}
    $script:RestoreE2ELateMutationGuard=[pscustomobject]@{actual=$realMutator.ScriptBlock;input=$MutationGuard}
    $lateGuardInstalled=$true
    function Invoke-RooIndustriesProcessControlChange {
     param([Diagnostics.Process]$Process,[object]$Change)
     $guard=$script:RestoreE2ELateMutationGuard
     $selected=$null
     $backendHandle=[IntPtr]::Zero
     try {
      if($null -eq $guard -or $guard.actual -isnot [scriptblock] -or $null -eq $Process){throw 'MISSING armed late mutation guard.'}
      $guardMatches=@($guard.input.originals | Where-Object {$_.pid -eq $Process.Id})
      if($guardMatches.Count -ne 1){throw 'Late mutation refused an unowned process.'}
      $selected=$guardMatches[0]
      if($selected.process.Id -ne $selected.pid -or $selected.process.Handle -ne $selected.handle -or $selected.process.HasExited){throw 'Late mutation lost its retained original.'}
      if([RooIndustriesValidationOwnership.Native]::Created($selected.handle) -ne $selected.birth -or -not[string]::Equals([RooIndustriesValidationOwnership.Native]::Image($selected.handle),$selected.image,[StringComparison]::OrdinalIgnoreCase)){throw 'Late mutation retained identity changed.'}
      $backendHandle=$Process.Handle
      if($backendHandle -eq [IntPtr]::Zero -or [RooIndustriesValidationOwnership.Native]::Created($backendHandle) -ne $selected.birth -or -not[string]::Equals([RooIndustriesValidationOwnership.Native]::Image($backendHandle),$selected.image,[StringComparison]::OrdinalIgnoreCase) -or $Process.HasExited){throw 'Late mutation backend instance is not the original.'}
     } catch {
      if($null -ne $guard -and $null -ne $guard.input -and $null -ne $guard.input.rejections){$guard.input.rejections.Add([pscustomobject]@{nonce=$guard.input.nonce;reason=$_.Exception.ToString();control=[string]$Change.control;realMutatorInvoked=$false}) | Out-Null}
      throw
     }
     $guardEvent=[pscustomobject]@{nonce=$guard.input.nonce;pid=$selected.pid;birth=$selected.birth;image=$selected.image;retainedHandle=$selected.handle.ToInt64();backendHandle=$backendHandle.ToInt64();control=[string]$Change.control;action=[string]$Change.action;enteredRealMutator=$false;returned=$false;outcome=$null;error=$null}
     $guard.input.events.Add($guardEvent) | Out-Null
     try {
      $guardEvent.enteredRealMutator=$true
      & $guard.actual -Process $Process -Change $Change
      $guardEvent.returned=$true
     } catch {$guardEvent.error=$_.Exception.ToString();throw}
     finally {$guardEvent.outcome=[string]$Change.outcome}
    }
   }
   & (New-BackendBlock $scriptPath $body[0].Extent)
  } finally {
   if($lateGuardInstalled){
    if($lateGuardPriorExists){$script:RestoreE2ELateMutationGuard=$lateGuardPriorValue}
    else{Remove-Variable -Name RestoreE2ELateMutationGuard -Scope Script -ErrorAction Stop}
   }
  }

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
function Read-ActorReceipt($actor){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists($actor.output)){
  if($actor.process.HasExited){
   if(-not [IO.File]::Exists($actor.output)){throw 'Actor did not produce its original receipt.'}
   break
  }
  if($clock.Elapsed.TotalSeconds -gt 10){throw 'Actor did not produce its original receipt.'}
  Start-Sleep -Milliseconds 10
 }
 return (Get-Content -LiteralPath $actor.output -Raw|ConvertFrom-Json)
}
function Wait-Actor($actor,[switch]$Held){
 $record=Read-ActorReceipt $actor
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
function Undo($context,[string]$name,[string]$backend=$Source,$MutationGuard=$null){
 Assert-HarnessHostLease
 $arguments=@{BackupPath=$context.backup;OutputPath='';ConfirmApply=$true;SessionId='';SessionPath='';StateRoot=$context.state}
 if($context.kind -eq 'game'){$arguments.SessionPath=$context.session}
 $result=Invoke-Body $backend $(if($context.kind -eq 'game'){'Stop-GameTuneSession.ps1'}else{'Restore-ProcessProfileBackup.ps1'}) $arguments $context.data $MutationGuard
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
function New-Breakpoint($context,[string]$script,[string]$pattern,[scriptblock]$action,[string]$FunctionName=''){
 $lines=@(Select-String -LiteralPath $script -Pattern $pattern)
 if(-not [string]::IsNullOrEmpty($FunctionName)){
  $sourceAst=Read-Ast $script
  $functions=@($sourceAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $FunctionName})
  Require ($functions.Count -eq 1) ('Expected one actual top-level debugger function: '+$FunctionName)
  $functionBody=$functions[0].Body.Extent
  $lines=@($lines | Where-Object {$_.LineNumber -ge $functionBody.StartLineNumber -and $_.LineNumber -le $functionBody.EndLineNumber})
 }
 Require ($lines.Count -eq 1) ('Expected one actual debugger seam: '+$pattern)
 $bp=Set-PSBreakpoint -Script $script -Line $lines[0].LineNumber -Action $action
 $context.breakpoints.Add($bp)|Out-Null
 return $bp
}

function Invoke-NoEffectHistory($context,[string]$kind,[string]$field,[string]$mode){
 $directory=$context.directory
 $backend=if($BeforeNoEffectSource){$BeforeNoEffectSource}else{$Source}
 $backendCommit=if($BeforeNoEffectSource){'861de816a3ef8b1ee57491730dd09ec29be4a52b'}else{$SourceCommit}
 $common=Join-Path $backend 'backend\scripts\ProcessProfile.Common.ps1'
 $producerScript=Join-Path $backend ('backend\scripts\'+$(if($kind -eq 'game'){'Start-GameTuneSession.ps1'}else{'Apply-ProcessProfile.ps1'}))
 $restoreScript=Join-Path $backend ('backend\scripts\'+$(if($kind -eq 'game'){'Stop-GameTuneSession.ps1'}else{'Restore-ProcessProfileBackup.ps1'}))
 $changed=$mode -like 'no-effect-record-*' -or $mode -like 'no-effect-changed-*' -or $mode -like 'no-effect-confirm-*'
 $withPeer=$mode -notin @('no-effect-changed-absent','no-effect-changed-empty','no-effect-changed-absent-ended','no-effect-changed-empty-ended')
 $peer=if($field -eq 'priorityClass'){'memoryPriority'}else{'priorityClass'}
 $suffix=switch($field){'priorityClass'{'PriorityClass'};'affinityMask'{'AffinityMask'};'ioPriority'{'IoPriority'};'memoryPriority'{'MemoryPriority'};'gpuPriority'{'GpuPriority'}}
 $context.process.PriorityClass='Normal'
 Require ((Read-Actual $context.process 'priorityClass') -ceq 'Normal') 'MISSING owned CPU original precondition.'
 if($field -eq 'priorityClass' -and $withPeer){[RooIndustriesBackgroundOracle]::SetMemory($context.process,[uint32]2);Require ((Read-Actual $context.process 'memoryPriority') -eq 2) 'MISSING owned memory peer precondition.'}
 if($field -eq 'ioPriority'){
  $initialIo=if($changed){'Low'}else{'Normal'}
  [RooIndustriesBackgroundOracle]::SetIo($context.process,(Convert-RooIndustriesIoPriorityToValue $initialIo -Restoring))
  Require ((Read-Actual $context.process 'ioPriority') -ceq $initialIo) 'MISSING owned IO precondition.'
 }
 if($field -eq 'memoryPriority'){
  $initialMemory=if($changed){2}else{5}
  [RooIndustriesBackgroundOracle]::SetMemory($context.process,[uint32]$initialMemory)
  Require ((Read-Actual $context.process 'memoryPriority') -eq $initialMemory) 'MISSING owned memory precondition.'
 }
 if($field -eq 'gpuPriority'){Set-RooIndustriesProcessGpuPriority $context.process 'Normal';Require ((Read-Actual $context.process 'gpuPriority') -ceq 'Normal') 'MISSING owned GPU precondition.'}
 $original=Read-Actual $context.process $field
 $peerOriginal=Read-Actual $context.process $peer
 $desired=switch($field){'priorityClass'{'AboveNormal'};'affinityMask'{[long]($original -band (-$original))};'ioPriority'{'Normal'};'memoryPriority'{5};'gpuPriority'{'BelowNormal'}}
 $external=if($changed){switch($field){'priorityClass'{'BelowNormal'};'affinityMask'{$original -band (-bnot [long]$desired)};'ioPriority'{'VeryLow'};'memoryPriority'{3};'gpuPriority'{'High'}}}else{switch($field){'priorityClass'{'AboveNormal'};'affinityMask'{$desired};'ioPriority'{'Low'};'memoryPriority'{2};'gpuPriority'{'High'}}}
 $conflictingApplied=switch($field){'priorityClass'{'AboveNormal'};'affinityMask'{$desired};'ioPriority'{'Low'};'memoryPriority'{2};'gpuPriority'{'BelowNormal'}}
 if($field -eq 'affinityMask'){
  Require ($original -ne 0 -and $desired -ne 0 -and $desired -ne $original -and ($original -band (-bnot [long]$desired)) -ne 0) 'MISSING at least two actual allowed affinity bits.'
 }
 if($changed){Require (-not(Test-RooIndustriesControlValueEqual $field $original $desired) -and -not(Test-RooIndustriesControlValueEqual $field $external $original) -and -not(Test-RooIndustriesControlValueEqual $field $external $desired)) 'MISSING three distinct reachable changed values.'}
 $requested=if($changed){$desired}else{$original}
 Require (-not(Test-RooIndustriesControlValueEqual $field $original $external) -and
     ($changed -or -not(Test-RooIndustriesControlValueEqual $field $original $conflictingApplied))) 'MISSING distinct no-effect drift/conflict values.'
 $directSetter={param($value) switch($field){'priorityClass'{$context.process.PriorityClass=$value};'affinityMask'{$context.process.ProcessorAffinity=[IntPtr][long]$value};'ioPriority'{[RooIndustriesBackgroundOracle]::SetIo($context.process,(Convert-RooIndustriesIoPriorityToValue $value -Restoring))};'memoryPriority'{[RooIndustriesBackgroundOracle]::SetMemory($context.process,[uint32]$value)};'gpuPriority'{Set-RooIndustriesProcessGpuPriority $context.process $value}}}.GetNewClosure()
 $foreground=[ordered]@{ruleId='restore-e2e';processNames=@('RestoreTarget.exe');priorityClass=$(if($field -eq 'priorityClass'){$requested}elseif($withPeer){'AboveNormal'}else{'Normal'});reason='Restore E2E fixture';reasonCodes=@('LIVE_VALIDATION')}
 $foreground[$field]=$requested
 if($peer -eq 'memoryPriority' -and $withPeer){$foreground.memoryPriority=5}
 $profilePath=Join-Path $directory 'profile.json'
 Save $profilePath @{schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='restore-e2e';name='Restore E2E';profileKind='process-controls';risk='medium';protectedCatalogPath=(Join-Path $backend 'backend\profiles\protected-processes.json');foregroundGame=$foreground;targetGames=@();protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();rules=@();rollbackPolicy=@{supported=$true;scope='process-controls';stateRoot=$context.state;restoreOriginalPriorityClass=$true};safety=@{confirmedApplyChanges=@('PriorityClass','Affinity','IoPriority','MemoryPriority','GpuPriority');continuousEnforcement=$true;runtimeService=$false}}
 $before=Read-E2EControls $context.process
 $apply=Invoke-Body $backend $(if($kind -eq 'game'){'Start-GameTuneSession.ps1'}else{'Apply-ProcessProfile.ps1'}) @{ProfilePath=$profilePath;TargetGameProcessName='RestoreTarget.exe';StateRoot=$context.state;OutputPath='';ConfirmApply=$true;PollIntervalSeconds=1;MaxDurationSeconds=1;SessionId=''} $context.data
 Save (Join-Path $directory 'apply.json') $apply
 $context.backup=if($kind -eq 'game'){$apply.backupManifestPath}else{$apply.backup.location};$context.session=if($kind -eq 'game'){$apply.sessionPath}else{''}
 Require ([IO.File]::Exists($context.backup)) 'MISSING actual producer backup.'
 $producerArtifact=Join-Path $directory $(if($kind -eq 'profile'){'producer-profile-backup.json'}else{'producer-game-backup.json'})
 [IO.File]::WriteAllBytes($producerArtifact,[IO.File]::ReadAllBytes($context.backup))
 $producerHash=Get-HarnessFileSha256 $producerArtifact
 Require ((Get-HarnessFileSha256 $context.backup) -ceq $producerHash) 'Original producer copy differs.'
 $backup=Get-Content -LiteralPath $context.backup -Raw|ConvertFrom-Json
 $snapshots=@($backup.snapshots)
 Require ($snapshots.Count -eq 1 -and $snapshots[0].processId -eq $context.process.Id) 'MISSING exactly one original producer snapshot.'
 $snapshot=$snapshots[0]
 $nativeBirth=[RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString()
 $savedTime=[DateTime]::Parse([string]$snapshot.processStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
 Require ($nativeBirth -ceq $context.owned.Identity.creationTimeFileTimeUtc -and $savedTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $nativeBirth -and (Test-RooIndustriesProcessNameEquals $snapshot.processName $context.process.ProcessName) -and [RooIndustriesValidationOwnership.Native]::Canonical([string]$snapshot.executablePath) -ieq $context.owned.Identity.imagePath -and $context.process.SessionId -eq (Get-Process -Id $PID).SessionId) 'MISSING actual producer native identity/session.'
 Require ((Test-RooIndustriesControlValueEqual $field $snapshot.('original'+$suffix) $original) -and (Test-RooIndustriesControlValueEqual $field $snapshot.('proposed'+$suffix) $requested) -and (Test-RooIndustriesControlValueEqual $field (Read-Actual $context.process $field) $requested)) 'Producer target original/request/readback differs.'
 $expectedControls=@();if($changed){$expectedControls+=@($field)};if($withPeer){$expectedControls+=@($peer)}
 Require (@($snapshot.controlChanges).Count -eq $expectedControls.Count) 'Producer emitted an unexpected control count.'
 foreach($name in $expectedControls){
  $records=@($snapshot.controlChanges|Where-Object control -eq $name)
  $expected=if($name -eq $field){$requested}elseif($peer -eq 'memoryPriority'){5}else{'AboveNormal'}
  $expectedOriginal=if($name -eq $field){$original}else{$peerOriginal}
  $expectedSuffix=switch($name){'priorityClass'{'PriorityClass'};'affinityMask'{'AffinityMask'};'ioPriority'{'IoPriority'};'memoryPriority'{'MemoryPriority'};'gpuPriority'{'GpuPriority'}}
  Require ((Test-RooIndustriesControlValueEqual $name $snapshot.('original'+$expectedSuffix) $expectedOriginal) -and (Test-RooIndustriesControlValueEqual $name $snapshot.('proposed'+$expectedSuffix) $expected)) 'MISSING exact genuine producer flat original/request evidence.'
  Require ($records.Count -eq 1 -and $records[0].outcome -ceq 'applied' -and -not $records[0].blocked -and (Test-RooIndustriesControlValueEqual $name $records[0].currentValue $expectedOriginal) -and (Test-RooIndustriesControlValueEqual $name $records[0].proposedValue $expected) -and (Test-RooIndustriesControlValueEqual $name (Read-Actual $context.process $name) $expected)) 'MISSING exact genuine producer record/native evidence.'
 }
 Require (@($snapshot.controlChanges|Where-Object control -eq $field).Count -eq $(if($changed){1}else{0})) 'Producer no-effect/changed target shape differs.'
 $producerPeerText=if($withPeer){@($snapshot.controlChanges|Where-Object control -eq $peer)[0]|ConvertTo-Json -Depth 30 -Compress}else{$null}
 Save (Join-Path $directory 'producer-evidence.json') @{kind='ACTUAL PRODUCER BEFORE REPLAY/EXTERNAL/UNDO';fixtureInputCorrection=$true;sourceCommit=$backendCommit;producerRoot=$backend;producerScript=$producerScript;producerScriptSha256=(Get-HarnessFileSha256 $producerScript);commonSha256=(Get-HarnessFileSha256 $common);driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);engine=$PSVersionTable.PSVersion.ToString();originalProcess=$context.owned.Identity;targetSession=$context.process.SessionId;before=$before;after=(Read-E2EControls $context.process);original=$original;requested=$requested;external=$external;conflictingApplied=$conflictingApplied;expectedControls=$expectedControls;backupPath=$context.backup;producerArtifact=$producerArtifact;producerBackupSha256=$producerHash;wholeProfileContract=($kind -eq 'profile');snapshot=$snapshot}
 $replay=$mode -in @('no-effect-applied-equal','no-effect-applied-conflict','no-effect-proposed-missing','no-effect-proposed-null','no-effect-proposed-invalid','no-effect-applied-invalid','no-effect-applied-null','no-effect-affinity-decimal','no-effect-affinity-hex') -or $mode -like 'no-effect-record-*' -or $mode -like 'no-effect-changed-*'
 if($replay){
  if($mode -like 'no-effect-record-*'){
   $record=@($snapshot.controlChanges|Where-Object control -eq $field)[0]
   $record.proposedValue=$original;$record.outcome=$mode.Substring('no-effect-record-'.Length)
   $snapshot.('proposed'+$suffix)=$original
  }elseif($mode -like 'no-effect-changed-*'){
   if($mode -like '*-absent*'){$snapshot.PSObject.Properties.Remove('controlChanges')}
   elseif($mode -like '*-empty*'){$snapshot.controlChanges=@()}
   else{$snapshot.controlChanges=@($snapshot.controlChanges|Where-Object control -ne $field);Require ($snapshot.controlChanges.Count -eq 1 -and ($snapshot.controlChanges[0]|ConvertTo-Json -Depth 30 -Compress) -ceq $producerPeerText) 'Replay changed genuine unmatched peer record.'}
  }elseif($mode -eq 'no-effect-affinity-decimal'){$snapshot.originalAffinityMask=([long]$original).ToString([Globalization.CultureInfo]::InvariantCulture)}
  elseif($mode -eq 'no-effect-affinity-hex'){$bits=[BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$original),0);$snapshot.proposedAffinityMask='0x'+$bits.ToString('X16',[Globalization.CultureInfo]::InvariantCulture)}
  else{
   $appliedValue=if($mode -eq 'no-effect-applied-conflict'){$conflictingApplied}elseif($mode -eq 'no-effect-applied-invalid'){if($field -in @('affinityMask','memoryPriority')){$true}else{[pscustomobject]@{invalid=$true}}}elseif($mode -eq 'no-effect-applied-null'){$null}else{$original}
   $snapshot|Add-Member -NotePropertyName ('applied'+$suffix) -NotePropertyValue $appliedValue -Force
   if($mode -eq 'no-effect-proposed-missing'){$snapshot.PSObject.Properties.Remove('proposed'+$suffix)}
   elseif($mode -eq 'no-effect-proposed-null'){$snapshot.('proposed'+$suffix)=$null}
   elseif($mode -eq 'no-effect-proposed-invalid'){$snapshot.('proposed'+$suffix)=switch($field){'memoryPriority'{7};'affinityMask'{0};default{'not-an-allowed-value'}}}
  }
  Save $context.backup $backup
  Save (Join-Path $directory 'saved-format-replay.json') @{kind='CONSTRUCTED SAVED-RECORD/LEGACY/REPRESENTATION REPLAY AFTER REAL APPLY';scenario=$mode;producerBackupSha256=$producerHash;producerArtifact=$producerArtifact;operativeBackupSha256=(Get-HarnessFileSha256 $context.backup);rawProfileContract=$false;limitation='Only unmodified actual Profile producer bytes use processProfileBackupManifest. Game and reader-compatible replays are separate.'}
 }
 $context.backupHash=Get-HarnessFileSha256 $context.backup
 [IO.File]::WriteAllBytes((Join-Path $directory 'operative-backup.json'),[IO.File]::ReadAllBytes($context.backup))
 $baseline=Read-E2EControls $context.process
 $meter=@{setterAttempts=0;peerSetterAttempts=0;unlistedSetterAttempts=0;setterFailures=(New-Object System.Collections.Generic.List[object]);setters=@{};confirms=@{};phase='';phasePeer=0;hits=0;orderArmed=$false;orderHits=0;orderValue=$null;wrapperClosed=0;wrapperErrors=(New-Object System.Collections.Generic.List[object]);wrapperGuards=(New-Object System.Collections.Generic.List[object]);wrapperGuardFailure=$null}
 $patterns=@{priorityClass='^\s*\$Process.PriorityClass = \[System.Diagnostics.ProcessPriorityClass\]::\$priority';affinityMask='^\s*\$Process.ProcessorAffinity = \[IntPtr\]';ioPriority='^\s*Set-RooIndustriesProcessIoPriority \$Process \$priority';memoryPriority='^\s*Set-RooIndustriesProcessMemoryPriority \$Process \$value';gpuPriority='^\s*Set-RooIndustriesProcessGpuPriority \$Process \$priority'}
 foreach($name in $patterns.Keys){
  $meter.setters[$name]=0;$meter.confirms[$name]=0;$observedControl=$name
  $null=New-Breakpoint $context $common $patterns[$name] ({$meter.setters[$observedControl]++;if($observedControl -eq $field){$meter.setterAttempts++}elseif($withPeer -and $observedControl -eq $peer){$meter.peerSetterAttempts++}else{$meter.unlistedSetterAttempts++}}.GetNewClosure())
 }
 $orderingBreakpoint=New-Breakpoint $context $common '^\s*\$candidateConfirmed = \$false' ({
  $confirmedControl=[string](Get-Variable control -ErrorAction Stop).Value
  $meter.confirms[$confirmedControl]++
  if($mode -eq 'no-effect-after-preview' -and $meter.hits -eq 0){$meter.hits++;& $directSetter $external;Require (Test-RooIndustriesControlValueEqual $field (Read-Actual $context.process $field) $external) 'After-preview external write did not read back.';Save (Join-Path $directory 'after-preview-owned-external.json') @{kind='OWNED EXTERNAL FIXTURE WRITE AT FIRST CONFIRM';control=$field;value=$external;originalProcess=$context.owned.Identity}}
  if($meter.orderArmed -and $confirmedControl -eq $field){$meter.orderArmed=$false;$meter.orderHits++;& $directSetter $meter.orderValue;Require (Test-RooIndustriesControlValueEqual $field (Read-Actual $context.process $field) $meter.orderValue) 'Ordered target drift did not read back.';Save (Join-Path $directory 'ordered-owned-external.json') @{kind='OWNED EXTERNAL FIXTURE WRITE AFTER ALREADY-ORIGINAL PREVIEW';control=$field;value=$meter.orderValue;originalProcess=$context.owned.Identity}}
 }.GetNewClosure())
 function Set-NoEffectExternal($value,[string]$phase){
  $beforeValues=Read-E2EControls $context.process
  & $directSetter $value
  $afterValues=Read-E2EControls $context.process
  Save (Join-Path $directory ($phase+'-owned-external.json')) @{kind='OWNED EXTERNAL FIXTURE WRITE; OUTSIDE PRODUCT SETTERS';originalProcess=$context.owned.Identity;control=$field;requested=$value;before=$beforeValues;after=$afterValues}
  Require ($afterValues[$field].available -and (Test-RooIndustriesControlValueEqual $field $afterValues[$field].value $value)) 'Owned external write did not read back.'
 }
 function Invoke-NoEffectPhase([string]$phase){
  $meter.phase=$phase;$meter.phasePeer=$meter.peerSetterAttempts
  $result=Undo $context $phase $backend
  $ended=$context.process.HasExited
  $values=if($ended){$null}else{Read-E2EControls $context.process}
  $status=if($kind -eq 'game'){Get-Content -LiteralPath (Join-Path $directory ('status-'+$phase+'.json')) -Raw|ConvertFrom-Json}else{$null}
  $observation=@{phase=$phase;result=$result;pending=(Is-Pending $context $result);values=$values;ended=$ended;reopenedStatus=$status;setters=$meter.setters.Clone();confirms=$meter.confirms.Clone();peerWrites=($meter.peerSetterAttempts-$meter.phasePeer);originalProcess=$context.owned.Identity;producerRoot=$backend;productCommit=$backendCommit;producerScriptSha256=(Get-HarnessFileSha256 $producerScript);restoreScript=$restoreScript;restoreScriptSha256=(Get-HarnessFileSha256 $restoreScript);commonSha256=(Get-HarnessFileSha256 $common);driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);statusReaderRoot=$(if($kind -eq 'game'){$Source}else{$null});statusReaderCommit=$(if($kind -eq 'game'){$SourceCommit}else{$null});statusReaderSha256=$(if($kind -eq 'game'){Get-HarnessFileSha256 (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1')}else{$null});producerBackupSha256=(Get-HarnessFileSha256 $producerArtifact);operativeBackupSha256=(Get-HarnessFileSha256 $context.backup);engine=$PSVersionTable.PSVersion.ToString()}
  Save (Join-Path $directory ($phase+'-readback.json')) $observation
  Require ($observation.producerBackupSha256 -ceq $producerHash -and $observation.operativeBackupSha256 -ceq $context.backupHash -and (Get-HarnessFileSha256 (Join-Path $directory 'operative-backup.json')) -ceq $context.backupHash) 'Phase changed immutable producer/operative backup bytes.'
  Require ($meter.setterAttempts -eq 0 -and $meter.unlistedSetterAttempts -eq 0) 'Target or unlisted control reached a product setter.'
  if(-not $ended){
   Require ($context.process.Handle -eq $context.owned.handle -and [RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString() -ceq $context.owned.Identity.creationTimeFileTimeUtc -and [RooIndustriesValidationOwnership.Native]::Image($context.owned.handle) -ieq $context.owned.Identity.imagePath) 'Original retained process identity changed.'
   foreach($name in $patterns.Keys){
    if($name -eq $field){continue}
    $expected=if($withPeer -and $name -eq $peer -and $meter.peerSetterAttempts -gt 0){$peerOriginal}else{$baseline[$name].value}
    Require ($values[$name].available -eq $baseline[$name].available) ('Unrequested availability changed: '+$name)
    if($baseline[$name].available){Require (Test-RooIndustriesControlValueEqual $name $values[$name].value $expected) ('Unrequested/peer native value differs: '+$name)}
   }
  }
  $restored=@($result.result.changedItems|ForEach-Object {@($_.restoredControls)})
  Require (@($restored|Where-Object control -eq $field).Count -eq 0 -and $restored.Count -eq $observation.peerWrites -and $meter.peerSetterAttempts -le $(if($withPeer){1}else{0})) 'Restore record/peer write counts disagree or repeated.'
  $kept=@(Get-RooIndustriesPropertyArray $result 'leftAsSetItems')+@(Get-RooIndustriesPropertyArray $result.result 'leftAsSetItems')
  Require (@($kept|Where-Object {$_.control -ne $field}).Count -eq 0) 'Unrequested control received kept attribution.'
  if($kind -eq 'game'){
   $session=Get-Content -LiteralPath $context.session -Raw|ConvertFrom-Json
   Require ($status.sessionId -ceq $result.sessionId -and $status.sessionPath -ceq $context.session -and $status.backupManifestPath -ceq $context.backup -and $session.sessionId -ceq $result.sessionId -and $session.status -ceq $result.sessionStatus) 'Reopened/persisted Game identifiers/status differ.'
  }
  return $observation
 }
 function Assert-NoEffectPending($observation,$expected,[int]$peerTotal){
  Require ($observation.pending -and $meter.peerSetterAttempts -eq $peerTotal) 'Pending recovery/peer count differs.'
  Require ($observation.values[$field].available -and (Test-RooIndustriesControlValueEqual $field $observation.values[$field].value $expected)) 'Pending target was changed.'
  $result=$observation.result
  foreach($container in @($result,$result.result,$observation.reopenedStatus)){Require (@(Get-RooIndustriesPropertyArray $container 'leftAsSetItems'|Where-Object control -eq $field).Count -eq 0) 'Unverified/refused target was certified kept.'}
  $entries=@($result.preview)
  $target=@($entries|ForEach-Object {@($_.controlChanges)+@($_.alreadyOriginal)+@($_.leftAsSet)}|Where-Object control -eq $field)
  Require ($target.Count -eq 1) 'Uncertain target was omitted from preview groups.'
  $attempt=if($observation.peerWrites -gt 0){'partial'}else{'failed'}
  Require ($result.result.status -ceq $attempt) 'Pending attempt phase differs.'
  if($kind -eq 'game'){
   $envelope=if($attempt -ceq 'partial'){'completed'}else{'failed'}
   $reopened=if($attempt -ceq 'partial'){'restorable'}else{'failed'}
   Require ($result.restorable -and $result.status -ceq $envelope -and $result.sessionStatus -ceq $envelope -and $observation.reopenedStatus.restorable -and $observation.reopenedStatus.status -ceq $reopened) 'Pending Game attempt/envelope/public status tuple differs.'
  }else{Require ($result.status -ceq $attempt -and $result.result.restorePendingCount -eq 1 -and @($result.result.pendingItems).Count -eq 1) 'Expected exactly one pending Profile snapshot.'}
 }
 function Assert-NoEffectComplete($observation,$expected,[int]$peerTotal,[switch]$Excluded,[switch]$Kept){
  $result=$observation.result
  Require (-not $observation.pending -and $meter.peerSetterAttempts -eq $peerTotal) 'Terminal recovery/peer count differs.'
  if(-not $observation.ended){Require ($observation.values[$field].available -and (Test-RooIndustriesControlValueEqual $field $observation.values[$field].value $expected)) 'Terminal target readback differs.'}
  foreach($container in $(if($kind -eq 'game'){@($result,$result.result)}else{@($result.result)})){
   $targetKept=@(Get-RooIndustriesPropertyArray $container 'leftAsSetItems'|Where-Object control -eq $field)
   Require ($targetKept.Count -eq $(if($Kept){1}else{0})) 'Terminal kept attribution differs.'
  }
  if($Excluded){
   Require ($meter.confirms[$field] -eq 0) 'Excluded target entered live confirmation.'
   $target=@($result.preview|ForEach-Object {@($_.controlChanges)+@($_.alreadyOriginal)+@($_.leftAsSet)}|Where-Object control -eq $field)
   Require ($target.Count -eq 0) 'Excluded target retained a preview/change/kept/original record.'
  }
  if($kind -eq 'game'){Require ($result.result.status -ceq 'rolledBack' -and $result.status -ceq 'completed' -and $result.sessionStatus -ceq 'completed' -and -not $result.restorable -and $observation.reopenedStatus.status -ceq 'completed' -and -not $observation.reopenedStatus.restorable -and @($observation.reopenedStatus.leftAsSetItems|Where-Object control -eq $field).Count -eq $(if($Kept){1}else{0})) 'Terminal Game attempt/public status differs.'}
  else{Require ($result.status -ceq 'success' -and $result.result.restorePendingCount -eq 0 -and @($result.result.pendingItems).Count -eq 0) 'Terminal Profile status/pending differs.'}
 }
 $confirmAdverse=$mode -like 'no-effect-confirm-*'
 $busy=$mode -like 'no-effect-confirm-busy-*'
 $wrapper=$mode -like 'no-effect-confirm-wrapper-*'
 $wrapperBreakpoint=$null
 if($confirmAdverse){
  Set-NoEffectExternal $original 'before-adverse-original'
  if($busy){$actor=New-Actor $context 'busy' $desired (Join-Path $context.data 'operations\no-effect\journal.json');$null=Wait-Actor $actor -Held}
  if($wrapper){
   $wrapperBreakpoint=New-Breakpoint $context $common '^\s*if \(-not \[RooIndustriesNativeProcessControl\]::GetProcessTimes\(\$queryHandle,' ({
    if((Get-Variable control -ErrorAction Stop).Value -eq $field -and (Get-Variable pass -ErrorAction Stop).Value -eq 2 -and $meter.wrapperClosed -lt 2){
     try{
      $backendWrapper=(Get-Variable -Name 'Process' -ErrorAction Stop).Value
      Require ($backendWrapper -is [Diagnostics.Process]) 'Expected the actual backend Process wrapper.'
      Require (-not [object]::ReferenceEquals($backendWrapper,$context.process)) 'Refuse to close the original context process.'
      Require (-not [object]::ReferenceEquals($backendWrapper,$context.owned.process)) 'Refuse to close the original owned process wrapper.'
      $backendHandle=$backendWrapper.Handle
      Require ($context.process.Handle -eq $context.owned.handle) 'Original retained handle changed before injection.'
      Require ($backendHandle -ne [IntPtr]::Zero -and $backendHandle -ne $context.owned.handle) 'Refuse to close a wrapper sharing the original owned native handle.'
      Require ([RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString() -ceq $context.owned.Identity.creationTimeFileTimeUtc) 'Original handle/birth changed before injection.'
      $guard=@{phase=$meter.phase;control=$field;pass=2;guardPassed=$true;backendHandle=$backendHandle.ToInt64();originalHandle=$context.owned.handle.ToInt64();originalIdentity=$context.owned.Identity;closed=$false}
      $meter.wrapperGuards.Add($guard)|Out-Null
      $backendWrapper.Close()
      $guard.closed=$true;$meter.wrapperClosed++
      Require ($context.process.Handle -eq $context.owned.handle -and [RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString() -ceq $context.owned.Identity.creationTimeFileTimeUtc) 'Injection invalidated the original owned handle.'
     }catch{$meter.wrapperGuardFailure=$_.Exception.ToString();Save (Join-Path $directory 'wrapper-injection-MISSING.json') @{error=$meter.wrapperGuardFailure;guards=@($meter.wrapperGuards.ToArray())};throw}
    }
   }.GetNewClosure())
   $null=New-Breakpoint $context $common '^\s*\} catch \{ \$errors.Add\(\$_\.Exception.Message\)' ({
    if((Get-Variable control -ErrorAction Stop).Value -eq $field -and $meter.wrapperClosed -gt $meter.wrapperErrors.Count -and $null -eq $meter.wrapperGuardFailure){
     $failure=(Get-Variable -Name '_' -ErrorAction Stop).Value
     $exception=$failure.Exception;$types=New-Object System.Collections.Generic.List[string]
     while($exception){$types.Add($exception.GetType().FullName)|Out-Null;$exception=$exception.InnerException}
     $meter.wrapperErrors.Add(@{phase=$meter.phase;control=$field;error=$failure.ToString();errorId=$failure.FullyQualifiedErrorId;exceptionTypes=@($types.ToArray());position=$failure.InvocationInfo.PositionMessage;line=$failure.InvocationInfo.Line;originalIdentity=$context.owned.Identity;originalHandle=$context.owned.handle.ToInt64();originalBirth=[RooIndustriesValidationOwnership.Native]::Created($context.owned.handle).ToString()})|Out-Null
    }
   }.GetNewClosure()) -FunctionName 'Confirm-RooIndustriesRestoreControl'
  }
  $first=Invoke-NoEffectPhase 'adverse-original';Assert-NoEffectPending $first $original 0
  Require (@($first.result.preview|ForEach-Object {@($_.alreadyOriginal)}|Where-Object control -eq $field).Count -eq 1) 'Adverse original phase did not exercise alreadyOriginal preview.'
  Set-NoEffectExternal $external 'adverse-external'
  $second=Invoke-NoEffectPhase 'adverse-external';Assert-NoEffectPending $second $external 0
  Require (@($second.result.preview|ForEach-Object {@($_.leftAsSet)}|Where-Object control -eq $field).Count -eq 1) 'Adverse external phase did not exercise leftAsSet preview.'
  if($wrapper){
   Save (Join-Path $directory 'wrapper-adversary.json') @{kind='CONSTRUCTED DISTINCT BACKEND WRAPPER DISPOSAL; NOT SPONTANEOUS OS FAILURE';guards=@($meter.wrapperGuards.ToArray());getterErrors=@($meter.wrapperErrors.ToArray());guardFailure=$meter.wrapperGuardFailure}
   Require ($null -eq $meter.wrapperGuardFailure -and $meter.wrapperClosed -eq 2 -and $meter.wrapperErrors.Count -eq 2) 'MISSING both actual guarded getter failures.'
   foreach($failure in $meter.wrapperErrors){Require ($failure.exceptionTypes -contains 'System.InvalidOperationException' -and ($failure.errorId -like '*HasExited*' -or $failure.errorId -like '*ProcessName*' -or $failure.line -like '*$Process.HasExited*' -or $failure.position -like '*$Process.HasExited*') -and $failure.originalBirth -ceq $context.owned.Identity.creationTimeFileTimeUtc) 'MISSING genuine backend HasExited/name getter failure; guard failure is not evidence.'}
   Remove-PSBreakpoint $wrapperBreakpoint;$null=$context.breakpoints.Remove($wrapperBreakpoint)
  }
  if($mode.EndsWith('-ended',[StringComparison]::Ordinal)){Stop-OwnedProcess $context.owned;Require ($context.process.WaitForExit(5000)) 'Original target did not end.';$resolved=Invoke-NoEffectPhase 'adverse-ended';Assert-NoEffectComplete $resolved $original 0}
  else{
   if($busy){[IO.File]::WriteAllText($actor.release,'release');$receipt=Wait-Actor $actor;Require ($actor.process.ExitCode -eq 0) 'Original busy actor did not release.'}
   Set-NoEffectExternal $original 'adverse-retry-original'
   $resolved=Invoke-NoEffectPhase 'adverse-fresh-retry';Assert-NoEffectComplete $resolved $original 1
  }
 }elseif($mode -like 'no-effect-changed-*'){
  $peerTotal=if($withPeer){1}else{0}
  $first=Invoke-NoEffectPhase 'requested-first';Assert-NoEffectPending $first $desired $peerTotal
  $repeat=Invoke-NoEffectPhase 'requested-repeat';Assert-NoEffectPending $repeat $desired $peerTotal
  Set-NoEffectExternal $external 'later-drift'
  $late=Invoke-NoEffectPhase 'later-drift';Assert-NoEffectPending $late $external $peerTotal
  $repeat=Invoke-NoEffectPhase 'drift-repeat';Assert-NoEffectPending $repeat $external $peerTotal
  Set-NoEffectExternal $original 'before-ordered-original'
  $meter.orderValue=$desired;$meter.orderArmed=$true
  $ordered=Invoke-NoEffectPhase 'original-preview-changed-back';Assert-NoEffectPending $ordered $desired $peerTotal
  Require ($meter.orderHits -eq 1 -and @($ordered.result.preview|ForEach-Object {@($_.alreadyOriginal)}|Where-Object control -eq $field).Count -eq 1) 'Fresh changed-request confirmation ordering was not exercised.'
  Remove-PSBreakpoint -Breakpoint $orderingBreakpoint
  Require ($context.breakpoints.Remove($orderingBreakpoint)) 'Original ordering breakpoint was not tracked for removal.'
  if($mode.EndsWith('-ended',[StringComparison]::Ordinal)){Stop-OwnedProcess $context.owned;Require ($context.process.WaitForExit(5000)) 'Original pending target did not end.';$resolved=Invoke-NoEffectPhase 'ended-resolution'}
  else{Set-NoEffectExternal $original 'original-resolution';$resolved=Invoke-NoEffectPhase 'original-resolution'}
  Assert-NoEffectComplete $resolved $original $peerTotal
 }else{
  $pending=$mode -in @('no-effect-applied-conflict','no-effect-proposed-missing','no-effect-proposed-null','no-effect-proposed-invalid','no-effect-applied-invalid','no-effect-applied-null','no-effect-record-failed','no-effect-record-pending','no-effect-record-unknown')
  $kept=$mode -eq 'no-effect-record-applied'
  if($mode -notin @('no-effect-original','no-effect-after-preview')){Set-NoEffectExternal $external 'before-preview-external'}
  $expected=if($mode -eq 'no-effect-original'){$original}else{$external}
  $first=Invoke-NoEffectPhase 'first'
  if($pending){
   Assert-NoEffectPending $first $expected 1
   $repeat=Invoke-NoEffectPhase 'pending-repeat';Assert-NoEffectPending $repeat $expected 1
   Set-NoEffectExternal $original 'before-ordered-original'
   $meter.orderValue=$external;$meter.orderArmed=$true
   $ordered=Invoke-NoEffectPhase 'original-preview-drift';Assert-NoEffectPending $ordered $external 1
   Require ($meter.orderHits -eq 1 -and @($ordered.result.preview|ForEach-Object {@($_.alreadyOriginal)}|Where-Object control -eq $field).Count -eq 1) 'Unverified original-preview drift was not exercised.'
   Remove-PSBreakpoint -Breakpoint $orderingBreakpoint
   Require ($context.breakpoints.Remove($orderingBreakpoint)) 'Original ordering breakpoint was not tracked for removal.'
   Set-NoEffectExternal $original 'original-resolution'
   $resolved=Invoke-NoEffectPhase 'original-resolution';Assert-NoEffectComplete $resolved $original 1
  }else{
   Assert-NoEffectComplete $first $expected 1 -Excluded:(-not $kept) -Kept:$kept
   if($mode -eq 'no-effect-after-preview'){Require ($meter.hits -eq 1) 'After-preview external seam was not reached.'}
   $repeat=Invoke-NoEffectPhase 'completed-repeat';Assert-NoEffectComplete $repeat $expected 1 -Excluded:(-not $kept) -Kept:$kept
   if($kind -eq 'game'){
    $status=& (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1') -SessionPath $context.session|ConvertFrom-Json
    Save (Join-Path $directory 'status-completed-repeat-again.json') $status
    Require ($status.status -ceq 'completed' -and -not $status.restorable -and $status.sessionId -ceq $repeat.result.sessionId) 'Repeated public status is not stably completed.'
   }
  }
 }
 Save (Join-Path $directory 'observations.json') @{kind=$kind;control=$field;scenario=$mode;sourceCommit=$backendCommit;driverSourceCommit=$SourceCommit;producerBackupSha256=$producerHash;operativeBackupSha256=$context.backupHash;original=$original;requested=$requested;external=$external;conflictingApplied=$conflictingApplied;targetSetterAttempts=$meter.setterAttempts;peerSetterAttempts=$meter.peerSetterAttempts;unlistedSetterAttempts=$meter.unlistedSetterAttempts;confirms=$meter.confirms;wrapperGuards=@($meter.wrapperGuards.ToArray());wrapperErrors=@($meter.wrapperErrors.ToArray());counterSemantics='Attempts only; all phases require native readbacks, full results and immutable bytes';fixtureInputCorrection=$true;nativeBehaviorSimulated=$false}
 return $meter
}
function Assert-LateOriginal($original){
 Require ($null -ne $original.owned -and [object]::ReferenceEquals($original.process,$original.owned.process)) 'MISSING late original receipt.'
 Require ($original.process.Id -eq $original.owned.Identity.pid -and $original.process.Handle -eq $original.owned.handle -and -not $original.process.HasExited) 'Late original is not the retained live process.'
 Require ([RooIndustriesValidationOwnership.Native]::Created($original.owned.handle).ToString() -ceq $original.owned.Identity.creationTimeFileTimeUtc -and [RooIndustriesValidationOwnership.Native]::Image($original.owned.handle) -ieq $original.owned.Identity.imagePath) 'Late original native identity changed.'
}
function Set-LateFixtureValue($original,[string]$control,$value){
 Assert-LateOriginal $original
 switch($control){
  'priorityClass'{$original.process.PriorityClass=$value}
  'affinityMask'{$original.process.ProcessorAffinity=[IntPtr][long]$value}
  'ioPriority'{[RooIndustriesBackgroundOracle]::SetIo($original.process,(Convert-RooIndustriesIoPriorityToValue $value -Restoring))}
  'memoryPriority'{[RooIndustriesBackgroundOracle]::SetMemory($original.process,[uint32]$value)}
  'gpuPriority'{Set-RooIndustriesProcessGpuPriority $original.process $value}
 }
 Require (Test-RooIndustriesControlValueEqual $control (Read-Actual $original.process $control) $value) 'Late fixture value did not read back.'
}
function Get-LateBoundIdentity($process,$snapshot,$entry,$original,[string]$control){
 Assert-LateOriginal $original
 Require ($process.Id -eq $original.owned.Identity.pid -and $snapshot.processId -eq $process.Id -and $entry.processId -eq $snapshot.processId) 'Late seam selected another original.'
 $savedTime=[DateTime]::Parse([string]$snapshot.processStartTimeUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
 Require ($savedTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $original.owned.Identity.creationTimeFileTimeUtc -and [string]$entry.processStartTimeUtc -ceq [string]$snapshot.processStartTimeUtc) 'Late seam saved/entry native birth differs.'
 Require ((Test-RooIndustriesProcessNameEquals $snapshot.processName $entry.processName) -and (Test-RooIndustriesProcessNameEquals $snapshot.processName $original.process.ProcessName)) 'Late seam original name differs.'
 Require ([string]::Equals([string]$snapshot.executablePath,[string]$entry.executablePath,[StringComparison]::OrdinalIgnoreCase) -and [RooIndustriesValidationOwnership.Native]::Canonical([string]$snapshot.executablePath) -ieq $original.owned.Identity.imagePath) 'Late seam original path differs.'
 Require ([RooIndustriesValidationOwnership.Native]::Created($process.Handle).ToString() -ceq $original.owned.Identity.creationTimeFileTimeUtc -and [RooIndustriesValidationOwnership.Native]::Image($process.Handle) -ieq $original.owned.Identity.imagePath -and -not $process.HasExited) 'Late seam backend native identity differs.'
 return @{processId=$snapshot.processId;processName=$snapshot.processName;executablePath=$snapshot.executablePath;processStartTimeUtc=$snapshot.processStartTimeUtc;entryProcessId=$entry.processId;entryStart=$entry.processStartTimeUtc;entryPath=$entry.executablePath;control=$control;original=$original.owned.Identity;originalHandle=$original.owned.handle.ToInt64();backendHandle=$process.Handle.ToInt64();session=$original.process.SessionId;engine=$PSVersionTable.PSVersion.ToString()}
}
function Stop-LateOriginal($original,$meter,$binding){
 Require ($meter.stopHits -eq 0) 'Late original stop repeated.'
 $meter.beforeExit=Read-E2EControls $original.process
 $meter.stopBinding=$binding
 $meter.stopHits++
 Stop-OwnedProcess $original.owned
 Require ($original.process.WaitForExit(5000) -and $original.process.HasExited) 'Original late exit was not observed.'
 $meter.waitCompleted=$true
}
function Remove-LateBreakpoints($context,$breakpoints){
 foreach($breakpoint in @($breakpoints.ToArray())){
  Remove-PSBreakpoint -Breakpoint $breakpoint
  Require ($context.breakpoints.Remove($breakpoint)) 'Original late breakpoint was not tracked for removal.'
 }
 $breakpoints.Clear()
}
function Assert-LateProducerRecord($record,$original,[string]$control,[switch]$Applied){
 $expectedAction=switch($control){'priorityClass'{'setPriority'};'affinityMask'{'setAffinity'};'ioPriority'{'setIoPriority'};'memoryPriority'{'setMemoryPriority'};'gpuPriority'{'setGpuPriority'};default{throw 'Unsupported late producer control.'}}
 Require ($null -ne $record -and $record.control -is [string] -and $record.control -ceq $control -and $record.action -is [string] -and $record.action -ceq $expectedAction -and $record.blocked -is [bool] -and -not $record.blocked -and (Test-RooIndustriesControlValueEqual $control $record.currentValue $original.originalValues[$control]) -and (Test-RooIndustriesControlValueEqual $control $record.proposedValue $original.values[$control])) 'Late producer record does not bind its original plan.'
 if($control -in @('priorityClass','ioPriority','memoryPriority')){Require ($record.priorityDirection -is [string] -and $record.priorityDirection -ceq 'raise') 'Late producer lost the actual foreground raise policy.'}
 if($Applied){Require ($record.outcome -is [string] -and $record.outcome -ceq 'applied') 'Late producer record was not actually applied.'}
}
function Assert-LateProducerItems([object[]]$Items,[object[]]$Originals,[string]$Kind){
 Require ($Items.Count -eq $Originals.Count) 'Late producer changed-item count differs from the actual originals.'
 foreach($original in $Originals){
  $itemMatches=@($Items|Where-Object {$_.processId -eq $original.owned.Identity.pid})
  Require ($itemMatches.Count -eq 1) 'Late producer changed-item original is missing or duplicated.'
  $item=$itemMatches[0]
  Require (($item.processId -is [int] -or $item.processId -is [long]) -and $item.processName -is [string] -and (Test-RooIndustriesProcessNameEquals $item.processName $original.snapshot.processName) -and $item.ruleId -is [string] -and $item.ruleId -ceq $original.snapshot.ruleId) 'Late producer changed-item identity/rule differs.'
  if($Kind -ceq 'game'){Require ([RooIndustriesValidationOwnership.Native]::Canonical([string]$item.executablePath) -ieq $original.owned.Identity.imagePath) 'Late Game changed-item path differs from its original image.'}
  $applied=@($item.appliedControls)
  Require ($applied.Count -eq $original.expected.Count) 'Late producer applied-control set differs.'
  foreach($control in $original.expected){
   $suffix=switch($control){'priorityClass'{'PriorityClass'};'affinityMask'{'AffinityMask'};'ioPriority'{'IoPriority'};'memoryPriority'{'MemoryPriority'};'gpuPriority'{'GpuPriority'}}
   $saved=@($original.snapshot.controlChanges|Where-Object control -CEQ $control)
   $record=@($applied|Where-Object control -CEQ $control)
   Require ($saved.Count -eq 1 -and $record.Count -eq 1) 'Late applied/saved control is missing or duplicated.'
   Assert-LateProducerRecord $record[0] $original $control -Applied
   Require ($record[0].action -ceq $saved[0].action -and $record[0].outcome -ceq $saved[0].outcome -and (Test-RooIndustriesControlValueEqual $control $record[0].currentValue $saved[0].currentValue) -and (Test-RooIndustriesControlValueEqual $control $record[0].proposedValue $saved[0].proposedValue)) 'Late returned and saved applied records differ.'
   if($control -in @('priorityClass','ioPriority','memoryPriority')){Require ($record[0].priorityDirection -ceq $saved[0].priorityDirection) 'Late returned and saved directions differ.'}
   $native=$original.afterProducer[$control]
   Require ($native.available -is [bool] -and $native.available -and (Test-RooIndustriesControlValueEqual $control $item.('original'+$suffix) $original.originalValues[$control]) -and (Test-RooIndustriesControlValueEqual $control $item.('applied'+$suffix) $original.values[$control]) -and (Test-RooIndustriesControlValueEqual $control $item.('applied'+$suffix) $native.value)) 'Late producer flat values do not match the saved original and actual native readback.'
  }
 }
}
function Invoke-LateHistory($parent,[string]$kind,[string]$field,[string]$mode,$history){
 $legs=if($mode -ceq 'late-exit-postwrite'){@('before-aggregate','after-aggregate')}else{@('main')}
 foreach($legName in $legs){ & {
  $directory=Join-Path $parent.directory $legName
  $null=New-HarnessDirectory $directory 'restore-late-evidence' 'frame'
  $context=[pscustomobject]@{directory=$directory;nonce=([guid]::NewGuid().ToString('N'));kind=$kind;control=$field;process=$null;owned=$null;actors=(New-Object System.Collections.Generic.List[object]);breakpoints=(New-Object System.Collections.Generic.List[object]);data=(Join-Path $directory 'data');state=(Join-Path $directory 'state');backup='';backupHash='';session=''}
  $originals=New-Object System.Collections.Generic.List[object]
  $breakpoints=New-Object System.Collections.Generic.List[object]
  $cleanupErrors=New-Object System.Collections.Generic.List[string]
  $phaseResults=New-Object System.Collections.Generic.List[object]
  $legRecord=[pscustomobject]@{name=$legName;directory=$directory;cleanupPassed=$false;completed=$false;originals=$originals;errors=$cleanupErrors}
  $history.legs.Add($legRecord)|Out-Null
  $guard=$null;$bodyError=$null;$releaseKeep=$null;$releaseAcquired=$false
  $meter=@{stopHits=0;waitCompleted=$false;beforeExit=$null;stopBinding=$null;observerCalls=0;initializations=(New-Object System.Collections.Generic.List[object]);readbacks=(New-Object System.Collections.Generic.List[object]);returns=(New-Object System.Collections.Generic.List[object]);providerErrors=(New-Object System.Collections.Generic.List[object]);hardReturns=(New-Object System.Collections.Generic.List[object]);attempts=@{};injectionErrors=(New-Object System.Collections.Generic.List[string]);releaseFault=$false;phase='setup';undoGuardStart=0;afterAggregate=$null}
  $twoOriginalHistory=$mode -ceq 'late-exit-restore' -and $field -ceq 'priorityClass'
  $common=Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1'
  $fixtureName='RooIndustriesLate'+$context.nonce.Substring(0,12)+'.exe'
  $lateTarget=$null;$survivor=$null
  try{
   foreach($role in $(if($twoOriginalHistory){@('target','surviving-peer')}else{@('target')})){
    $fixtureDirectory=Join-Path $directory $(if($role -ceq 'target'){'a'}else{'b'})
    $original=[pscustomobject]@{role=$role;directory=$fixtureDirectory;directoryEntry=$null;image=(Join-Path $fixtureDirectory $fixtureName);imageCreationAttempted=$false;imageProbe=$null;imageEntry=$null;extraEntries=(New-Object System.Collections.Generic.List[object]);process=$null;owned=$null;processEntry=$null;before=$null;afterProducer=$null;snapshot=$null;expected=@();values=@{};originalValues=@{};stopVerified=$false;wrapperDisposed=$false;cleanupPassed=$false;cleanupError=$null}
    $originals.Add($original)|Out-Null
    if($role -ceq 'target'){$lateTarget=$original}else{$survivor=$original}
    $original.directoryEntry=New-HarnessDirectory $original.directory ('restore-late-'+$role) 'invocation'
    $original.imageCreationAttempted=$true
    if($field -ceq 'gpuPriority'){
     $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
     & $compiler /nologo ('/out:'+$original.image) (Join-Path $Source 'tools\validation\Background\LauncherFixture.cs') > (Join-Path $directory 'fixture-compile.stdout') 2> (Join-Path $directory 'fixture-compile.stderr')
     Require ($LASTEXITCODE -eq 0) 'Owned late GPU fixture compilation failed.'
     $original.imageEntry=Register-HarnessFile $original.image 'restore-late-image' 'invocation'
     $signal=Join-Path $original.directory 'never-signalled'
     $arguments='"'+$signal+'" "'+(Join-Path $original.directory 'never-child.exe')+'" --gpu'
    }else{
     try{$original.imageProbe=Copy-OwnedProbe (Join-Path $env:SystemRoot 'System32\PING.EXE') $original.image;$original.imageEntry=Add-HarnessEntry 'file' $original.imageProbe.Identity 'restore-late-image' 'invocation'}
     finally{if($null -ne $original.imageProbe){$original.imageProbe.Dispose();$original.imageProbe=$null}}
     $arguments='-t 127.0.0.1'
    }
    $original.process=Start-Process -FilePath $original.image -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $original.owned=New-OwnedProcess $original.process
    Require ($null -ne $original.owned -and $original.process.SessionId -eq (Get-Process -Id $PID).SessionId) 'MISSING original late fixture identity/session.'
    $original.processEntry=Add-HarnessEntry 'process' $original.owned.Identity 'restore-late-original' 'invocation' @{directoryEntryId=$original.directoryEntry.id;imageEntryId=$original.imageEntry.id}
    Assert-LateOriginal $original
    if($field -ceq 'gpuPriority'){
     $clock=[Diagnostics.Stopwatch]::StartNew()
     while(-not [IO.File]::Exists($signal+'.gpu-ready')){if($clock.Elapsed.TotalSeconds -gt 10){throw 'MISSING actual late GPU activation.'};Start-Sleep -Milliseconds 20}
     $original.extraEntries.Add((Register-HarnessFile ($signal+'.gpu-ready') 'restore-late-gpu-ready' 'invocation'))|Out-Null
    }
    Set-LateFixtureValue $original 'priorityClass' 'Normal'
    if($twoOriginalHistory){Set-LateFixtureValue $original 'memoryPriority' 5}
    elseif($field -in @('priorityClass','memoryPriority')){Set-LateFixtureValue $original 'memoryPriority' 2}
    if($field -ceq 'ioPriority'){Set-LateFixtureValue $original 'ioPriority' 'Low'}
    if($field -ceq 'gpuPriority'){Set-LateFixtureValue $original 'gpuPriority' 'Normal'}
    $original.before=Read-E2EControls $original.process
    $peer=if($field -ceq 'priorityClass'){'memoryPriority'}else{'priorityClass'}
    $original.expected=if($twoOriginalHistory){@('priorityClass')}else{@('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority')|Where-Object {$_ -eq $field -or $_ -eq $peer}}
    foreach($name in $original.expected){Require $original.before[$name].available ('MISSING actual late original '+$name);$original.originalValues[$name]=$original.before[$name].value;$original.values[$name]=switch($name){'priorityClass'{'AboveNormal'};'affinityMask'{[long]($original.before[$name].value -band (-[long]$original.before[$name].value))};'ioPriority'{'Normal'};'memoryPriority'{5};'gpuPriority'{'BelowNormal'}}}
    Save (Join-Path $directory ('original-'+$role+'.json')) @{original=$original.owned.Identity;handle=$original.owned.handle.ToInt64();session=$original.process.SessionId;directoryEntry=$original.directoryEntry;imageEntry=$original.imageEntry;processEntry=$original.processEntry;before=$original.before;expectedControls=$original.expected;originalValues=$original.originalValues;requestedValues=$original.values}
   }
   if($twoOriginalHistory){Require ($lateTarget.process.Id -ne $survivor.process.Id -and $lateTarget.owned.handle -ne $survivor.owned.handle -and -not [object]::ReferenceEquals($lateTarget.process,$survivor.process) -and $lateTarget.directoryEntry.id -cne $survivor.directoryEntry.id -and $lateTarget.imageEntry.id -cne $survivor.imageEntry.id) 'Two late originals share an identity/resource.'}
   else{$context.process=$lateTarget.process;$context.owned=$lateTarget.owned}
   $originalValue=$lateTarget.originalValues[$field];$desired=$lateTarget.values[$field]
   $external=switch($field){'priorityClass'{'BelowNormal'};'affinityMask'{$originalValue -band (-bnot [long]$desired)};'ioPriority'{'VeryLow'};'memoryPriority'{3};'gpuPriority'{'High'}}
   Require (-not(Test-RooIndustriesControlValueEqual $field $originalValue $desired) -and -not(Test-RooIndustriesControlValueEqual $field $originalValue $external) -and -not(Test-RooIndustriesControlValueEqual $field $desired $external) -and ($field -ne 'affinityMask' -or $external -ne 0)) 'MISSING three distinct actual late fixture values.'
   $guard=New-LateMutationGuard $(if($twoOriginalHistory){@($originals.ToArray())}else{@($context)}) $context.nonce
   $foreground=[ordered]@{ruleId='restore-late-e2e';processNames=@($fixtureName);priorityClass='AboveNormal';reason='Restore E2E fixture';reasonCodes=@('LIVE_VALIDATION')}
   foreach($name in $lateTarget.expected){$foreground[$name]=$lateTarget.values[$name]}
   if($twoOriginalHistory){$foreground.memoryPriority=5}
   $profilePath=Join-Path $directory 'profile.json'
   Save $profilePath @{schemaVersion=1;productName='Roo Industries Optimization Suite';profileId='restore-late-e2e';name='Restore E2E';profileKind='process-controls';risk='medium';protectedCatalogPath=(Join-Path $Source 'backend\profiles\protected-processes.json');foregroundGame=$foreground;targetGames=@();protectedCompanions=@();protectedPreviewProcessNames=@();safeCandidates=@();rules=@();rollbackPolicy=@{supported=$true;scope='process-controls';stateRoot=$context.state;restoreOriginalPriorityClass=$true};safety=@{confirmedApplyChanges=@('PriorityClass','Affinity','IoPriority','MemoryPriority','GpuPriority');continuousEnforcement=$true;runtimeService=$false}}
   $preview=Invoke-Body $Source 'Preview-ProcessProfile.ps1' @{ProfilePath=$profilePath;TargetGameProcessName=$fixtureName;Preset='lower';OutputPath=''} $context.data $guard
   Save (Join-Path $directory 'producer-preview.json') $preview
   $eligible=@($preview.preview|Where-Object {-not $_.blocked -and -not $_.protected -and @(Get-RooIndustriesPreviewControlChanges $_).Count -gt 0})
   Require ($eligible.Count -eq $originals.Count) 'MISSING exact owned late producer eligible set.'
   foreach($original in @($originals.ToArray())){
    $entry=@($eligible|Where-Object processId -eq $original.owned.Identity.pid)
    Require ($entry.Count -eq 1 -and $entry[0].classification -ceq 'gameTarget') 'Late producer preview selected another original/classification.'
    Require ($entry[0].ruleId -is [string] -and $entry[0].ruleId -ceq $foreground.ruleId) 'Late producer preview rule differs from the selected producer.'
    $null=Get-LateBoundIdentity $original.process $entry[0] $entry[0] $original $field
    $records=@(Get-RooIndustriesPreviewControlChanges $entry[0]);Require ($records.Count -eq $original.expected.Count) 'Late producer preview control set differs.'
    foreach($name in $original.expected){$record=@($records|Where-Object control -eq $name);Require ($record.Count -eq 1 -and -not $record[0].blocked -and (Test-RooIndustriesControlValueEqual $name $record[0].currentValue $original.originalValues[$name]) -and (Test-RooIndustriesControlValueEqual $name $record[0].proposedValue $original.values[$name])) 'Late producer preview original/request differs.';Assert-LateProducerRecord $record[0] $original $name}
   }
   $producerName=if($kind -ceq 'game'){'Start-GameTuneSession.ps1'}else{'Apply-ProcessProfile.ps1'}
   $producerArguments=@{ProfilePath=$profilePath;TargetGameProcessName=$fixtureName;StateRoot=$context.state;OutputPath='';ConfirmApply=$true}
   if($kind -ceq 'game'){$producerArguments.PollIntervalSeconds=1;$producerArguments.MaxDurationSeconds=1}else{$producerArguments.Preset='lower'}
   $apply=Invoke-Body $Source $producerName $producerArguments $context.data $guard
   Save (Join-Path $directory 'apply.json') $apply
   Require ($guard.rejections.Count -eq 0 -and @($apply.errors).Count -eq 0 -and $apply.result.status -ceq 'success') 'MISSING successful owned late producer.'
   $context.backup=if($kind -ceq 'game'){$apply.backupManifestPath}else{$apply.backup.location};$context.session=if($kind -ceq 'game'){$apply.sessionPath}else{''}
   Require ([IO.File]::Exists($context.backup)) 'MISSING whole actual late producer backup.'
   $producerArtifact=Join-Path $directory $(if($kind -ceq 'profile'){'producer-profile-backup.json'}else{'producer-game-backup.json'})
   [IO.File]::WriteAllBytes($producerArtifact,[IO.File]::ReadAllBytes($context.backup))
   $context.backupHash=Get-HarnessFileSha256 $context.backup
   Require ((Get-HarnessFileSha256 $producerArtifact) -ceq $context.backupHash) 'Whole original late producer copy differs.'
   $backup=Get-Content -LiteralPath $context.backup -Raw|ConvertFrom-Json
   Require (@($backup.snapshots).Count -eq $originals.Count -and $backup.actionId -ceq $(if($kind -ceq 'profile'){'performance.applyProfile'}else{'performance.gameTune.startSession'}) -and $backup.dryRun -is [bool] -and -not $backup.dryRun -and $backup.profileId -ceq 'restore-late-e2e' -and $backup.profilePath -ieq $profilePath) 'Whole actual late producer binding differs.'
   $producerWrites=0
   foreach($original in @($originals.ToArray())){
    $matches=@($backup.snapshots|Where-Object processId -eq $original.owned.Identity.pid);Require ($matches.Count -eq 1) 'Original late snapshot missing/duplicated.';$original.snapshot=$matches[0]
    $null=Get-LateBoundIdentity $original.process $original.snapshot $original.snapshot $original $field
    Require ($original.snapshot.profileId -is [string] -and $original.snapshot.profileId -ceq 'restore-late-e2e' -and $original.snapshot.ruleId -is [string] -and $original.snapshot.ruleId -ceq $foreground.ruleId) 'Late original snapshot profile/rule differs from the selected producer.'
    $records=@($original.snapshot.controlChanges);Require ($records.Count -eq $original.expected.Count) 'Actual late producer record set differs.'
    foreach($name in $original.expected){
     $suffix=switch($name){'priorityClass'{'PriorityClass'};'affinityMask'{'AffinityMask'};'ioPriority'{'IoPriority'};'memoryPriority'{'MemoryPriority'};'gpuPriority'{'GpuPriority'}}
     $record=@($records|Where-Object control -eq $name)
     Require ((Test-RooIndustriesControlValueEqual $name $original.snapshot.('original'+$suffix) $original.originalValues[$name]) -and (Test-RooIndustriesControlValueEqual $name $original.snapshot.('proposed'+$suffix) $original.values[$name])) 'MISSING exact original and peer producer flat values.'
     Require ($record.Count -eq 1 -and $record[0].outcome -ceq 'applied' -and -not $record[0].blocked -and (Test-RooIndustriesControlValueEqual $name $record[0].currentValue $original.originalValues[$name]) -and (Test-RooIndustriesControlValueEqual $name $record[0].proposedValue $original.values[$name]) -and (Test-RooIndustriesControlValueEqual $name (Read-Actual $original.process $name) $original.values[$name])) 'MISSING exact actual late producer record/native value.'
     Assert-LateProducerRecord $record[0] $original $name -Applied
     $events=@($guard.events|Where-Object {$_.pid -eq $original.owned.Identity.pid -and $_.control -ceq $name})
     Require ($events.Count -eq 1 -and $events[0].enteredRealMutator -and $events[0].returned -and $events[0].outcome -ceq 'applied') 'Producer did not execute the actual owned native mutator once.'
     $producerWrites++
    }
    if($twoOriginalHistory){Require ($original.snapshot.originalMemoryPriority -eq 5 -and $original.snapshot.proposedMemoryPriority -eq 5 -and (Read-Actual $original.process 'memoryPriority') -eq 5) 'Two-original no-effect memory evidence differs.'}
    if($kind -ceq 'game'){Require ($original.snapshot.sessionId -is [string] -and -not [string]::IsNullOrWhiteSpace($original.snapshot.sessionId) -and $backup.sessionId -is [string] -and -not [string]::IsNullOrWhiteSpace($backup.sessionId) -and $apply.sessionId -is [string] -and -not [string]::IsNullOrWhiteSpace($apply.sessionId) -and $original.snapshot.sessionId -ceq $apply.sessionId -and $backup.sessionId -ceq $apply.sessionId) 'Late original Game session differs.'}
    $original.afterProducer=Read-E2EControls $original.process
   }
   Require ($guard.events.Count -eq $producerWrites -and @($apply.result.changedItems).Count -eq $originals.Count) 'Actual producer write/process counts differ.'
   Require ($apply.actionId -is [string] -and $apply.actionId -ceq $(if($kind -ceq 'profile'){'performance.applyProfile'}else{'performance.gameTune.startSession'}) -and $apply.dryRun -is [bool] -and -not $apply.dryRun) 'Late actual producer action/dry-run binding differs.'
   Assert-LateProducerItems @($apply.result.changedItems) @($originals.ToArray()) $kind
   if($kind -ceq 'game'){
    [IO.File]::WriteAllBytes((Join-Path $directory 'producer-game-session.json'),[IO.File]::ReadAllBytes($context.session))
    $session=Get-Content -LiteralPath $context.session -Raw|ConvertFrom-Json
    Require ($session.sessionId -ceq $apply.sessionId -and $session.profileId -ceq $backup.profileId -and $session.backupManifestPath -ceq $context.backup -and @($session.changedItems).Count -eq $originals.Count) 'Single actual late Game session binding differs.'
    Require ($apply.profileId -is [string] -and $apply.profileId -ceq $backup.profileId -and [string]::Equals([string]$apply.profilePath,[string]$profilePath,[StringComparison]::OrdinalIgnoreCase)) 'Late Game producer profile binding differs.'
    Require ($session.sessionId -is [string] -and -not [string]::IsNullOrWhiteSpace($session.sessionId) -and $session.sessionId -ceq $apply.sessionId -and $session.profileId -is [string] -and $session.profileId -ceq $backup.profileId) 'Late Game persisted identity/profile differs.'
    Require ([string]::Equals([string]$session.profilePath,[string]$profilePath,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$session.profilePath,[string]$apply.profilePath,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$session.sessionPath,[string]$context.session,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$session.sessionPath,[string]$apply.sessionPath,[StringComparison]::OrdinalIgnoreCase)) 'Late Game actual profile/session paths differ.'
    Assert-LateProducerItems @($apply.changedItems) @($originals.ToArray()) $kind
    Assert-LateProducerItems @($session.changedItems) @($originals.ToArray()) $kind
   }
   Save (Join-Path $directory 'producer-evidence.json') @{sourceRoot=$Source;sourceCommit=$SourceCommit;producerScript=$producerName;producerScriptSha256=(Get-HarnessFileSha256 (Join-Path $Source ('backend\scripts\'+$producerName)));commonSha256=(Get-HarnessFileSha256 $common);driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);engine=$PSVersionTable.PSVersion.ToString();nonce=$context.nonce;producerArguments=$producerArguments;producerArtifact=$producerArtifact;producerBackupSha256=$context.backupHash;originals=@($originals|ForEach-Object {@{role=$_.role;identity=$_.owned.Identity;handle=$_.owned.handle.ToInt64();before=$_.before;after=$_.afterProducer;snapshot=$_.snapshot;directoryEntry=$_.directoryEntry;imageEntry=$_.imageEntry;processEntry=$_.processEntry}});rawProfileContract=($kind -ceq 'profile');singleActualProducer=$true;compoundReplay=$false}
   if($mode -ceq 'late-exit-original'){Set-LateFixtureValue $lateTarget $field $originalValue}
   if($mode -ceq 'late-exit-kept'){Set-LateFixtureValue $lateTarget $field $external}
   $meter.phase='undo';$meter.undoGuardStart=$guard.events.Count
   foreach($name in @('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority')){$meter.attempts[$name]=0}
   $patterns=@{priorityClass='^\s*\$Process.PriorityClass = \[System.Diagnostics.ProcessPriorityClass\]::\$priority';affinityMask='^\s*\$Process.ProcessorAffinity = \[IntPtr\]';ioPriority='^\s*Set-RooIndustriesProcessIoPriority \$Process \$priority';memoryPriority='^\s*Set-RooIndustriesProcessMemoryPriority \$Process \$value';gpuPriority='^\s*Set-RooIndustriesProcessGpuPriority \$Process \$priority'}
   foreach($name in $patterns.Keys){$observedControl=$name;$breakpoints.Add((New-Breakpoint $context $common $patterns[$name] ({$process=(Get-Variable Process -ErrorAction Stop).Value;$meter.attempts[$observedControl]++}.GetNewClosure()) -FunctionName 'Invoke-RooIndustriesProcessControlChange'))|Out-Null}
   $breakpoints.Add((New-Breakpoint $context $common '^\s*if \(-not \(Test-RooIndustriesControlValueEqual \$control \$actual \$value\)\)' ({
    try{
     $process=(Get-Variable Process -ErrorAction Stop).Value;$change=(Get-Variable Change -ErrorAction Stop).Value;$control=[string](Get-Variable control -ErrorAction Stop).Value;$actual=(Get-Variable actual -ErrorAction Stop).Value;$value=(Get-Variable value -ErrorAction Stop).Value
     $original=@($originals|Where-Object {$_.owned.Identity.pid -eq $process.Id});Require ($original.Count -eq 1) 'Native late readback selected another original.'
     Assert-LateOriginal $original[0]
     Require ((Test-RooIndustriesControlValueEqual $control $actual $value) -and (Test-RooIndustriesControlValueEqual $control $actual $original[0].originalValues[$control]) -and $change.action -like 'restore*') 'Actual late setter readback did not restore the original.'
     $meter.readbacks.Add(@{pid=$process.Id;control=$control;actual=$actual;requested=$value;change=$change;identity=$original[0].owned.Identity;phase=$meter.phase;stack=@(Get-PSCallStack|ForEach-Object {@{command=$_.Command;script=$_.ScriptName;line=$_.ScriptLineNumber}})})|Out-Null
    }catch{$meter.injectionErrors.Add($_.Exception.ToString())|Out-Null;throw}
   }.GetNewClosure()) -FunctionName 'Invoke-RooIndustriesProcessControlChange'))|Out-Null
   $breakpoints.Add((New-Breakpoint $context $common '^\s*return \[pscustomobject\]@\{ confirmed = \$candidateConfirmed;' ({
    $process=(Get-Variable Process -ErrorAction Stop).Value;$control=[string](Get-Variable control -ErrorAction Stop).Value
    $meter.returns.Add(@{pid=$process.Id;control=$control;confirmed=(Get-Variable candidateConfirmed -ErrorAction Stop).Value;restored=(Get-Variable candidateRestored -ErrorAction Stop).Value;cleanupFailed=(Get-Variable cleanupFailed -ErrorAction Stop).Value})|Out-Null
   }.GetNewClosure()) -FunctionName 'Confirm-RooIndustriesRestoreControl'))|Out-Null
   $breakpoints.Add((New-Breakpoint $context $common '^\s*if \(\$errors.Count -gt 0\)' ({
    if((Get-Variable errors -ErrorAction Stop).Value.Count -gt 0){$meter.hardReturns.Add(@{control=(Get-Variable control -ErrorAction Stop).Value;cleanupFailed=(Get-Variable cleanupFailed -ErrorAction Stop).Value;reasons=@((Get-Variable errors -ErrorAction Stop).Value.ToArray());candidateEnded=(Get-Variable candidateEnded -ErrorAction Stop).Value;evidenceKind='Actual error-return locals; raw caller result retained'})|Out-Null}
   }.GetNewClosure()) -FunctionName 'Confirm-RooIndustriesRestoreControl'))|Out-Null
   $breakpoints.Add((New-Breakpoint $context $common '^\s*if \(\$failure.GetType\(\) -ne \[ArgumentException\]\)' ({
    $failure=(Get-Variable failure -ErrorAction Stop).Value;$savedId=(Get-Variable savedId -ErrorAction Stop).Value
    $meter.providerErrors.Add(@{exceptionType=$failure.GetType().FullName;errorRecord=(Get-Variable -Name '_' -ErrorAction Stop).Value.ToString();savedId=$savedId;savedBirth=(Get-Variable savedBirth -ErrorAction Stop).Value;engine=$PSVersionTable.PSVersion.ToString();source=$common;stack=@(Get-PSCallStack|ForEach-Object {@{command=$_.Command;script=$_.ScriptName;line=$_.ScriptLineNumber}})})|Out-Null
   }.GetNewClosure()) -FunctionName 'Test-RooIndustriesRestoreInstanceEnded'))|Out-Null
   if($mode -in @('late-exit-restore','late-exit-original','late-exit-kept')){
    $breakpoints.Add((New-Breakpoint $context $common '^\s*\$candidateConfirmed = \$false' ({
     try{
      $process=(Get-Variable Process -ErrorAction Stop).Value;$snapshot=(Get-Variable Snapshot -ErrorAction Stop).Value;$entry=(Get-Variable Entry -ErrorAction Stop).Value;$control=[string](Get-Variable control -ErrorAction Stop).Value;$check=(Get-Variable Check -ErrorAction Stop).Value
      if($control -ceq $field -and $snapshot.processId -eq $lateTarget.owned.Identity.pid -and $meter.stopHits -eq 0){
       $binding=Get-LateBoundIdentity $process $snapshot $entry $lateTarget $control
       $binding.check=$check;$binding.stack=@(Get-PSCallStack|ForEach-Object {@{command=$_.Command;script=$_.ScriptName;line=$_.ScriptLineNumber}})
       $meter.initializations.Add($binding)|Out-Null
       Stop-LateOriginal $lateTarget $meter $binding
      }
     }catch{$meter.injectionErrors.Add($_.Exception.ToString())|Out-Null;throw}
    }.GetNewClosure()) -FunctionName 'Confirm-RooIndustriesRestoreControl'))|Out-Null
   }elseif($legName -ceq 'after-aggregate'){
    $breakpoints.Add((New-Breakpoint $context $common '^\s*\$ended = \$false' ({
     try{
      $snapshot=(Get-Variable Snapshot -ErrorAction Stop).Value;$entry=(Get-Variable Entry -ErrorAction Stop).Value
      if($snapshot.processId -eq $lateTarget.owned.Identity.pid -and $meter.stopHits -eq 0){
       $meter.observerCalls++
       if($meter.observerCalls -eq $lateTarget.expected.Count+2){
        $pair=(Get-Variable pair -ErrorAction Stop).Value;$after=(Get-Variable afterControls -ErrorAction Stop).Value;$applied=(Get-Variable appliedControls -ErrorAction Stop).Value;$verification=(Get-Variable verification -ErrorAction Stop).Value;$workItems=(Get-Variable workItems -ErrorAction Stop).Value
        $stack=@(Get-PSCallStack)
        Require (@($stack|Where-Object Command -eq 'Confirm-RooIndustriesRestoreControl').Count -eq 0 -and $pair.executionMatched -and -not $pair.failed -and -not $pair.closed -and [object]::ReferenceEquals($pair.snapshot,$snapshot) -and [object]::ReferenceEquals($pair.entry,$entry)) 'MISSING actual post-aggregate caller scope/order.'
        Require ($workItems.Count -eq $lateTarget.expected.Count -and $applied.Count -eq $lateTarget.expected.Count -and $verification.confirmed -is [bool] -and $verification.confirmed -and $verification.restored -and -not $verification.cleanupFailed -and -not $verification.instanceEnded -and $after.exists -is [bool] -and $after.exists) 'MISSING actual successful post-aggregate controls/return.'
        foreach($name in $lateTarget.expected){Require ((Test-RooIndustriesControlValueEqual $name $after.$name $lateTarget.originalValues[$name]) -and @($meter.readbacks|Where-Object {$_.pid -eq $snapshot.processId -and $_.control -ceq $name -and $_.change.outcome -ceq 'applied'}).Count -eq 1 -and @($meter.returns|Where-Object {$_.pid -eq $snapshot.processId -and $_.control -ceq $name -and $_.confirmed -and $_.restored -and -not $_.cleanupFailed}).Count -eq 1) 'MISSING actual native/return/aggregate readback for every prior write.'}
        foreach($name in $lateTarget.expected){$appliedMatch=@($applied.ToArray()|Where-Object control -CEQ $name);$workMatch=@($workItems.ToArray()|Where-Object {$_.change.control -ceq $name});$readbackMatch=@($meter.readbacks|Where-Object {$_.pid -eq $snapshot.processId -and $_.control -ceq $name});Require ($appliedMatch.Count -eq 1 -and $workMatch.Count -eq 1 -and $readbackMatch.Count -eq 1 -and [object]::ReferenceEquals($appliedMatch[0],$workMatch[0].change) -and [object]::ReferenceEquals($appliedMatch[0],$readbackMatch[0].change)) 'Actual post-aggregate work/change/readback references differ.'}
        $aggregateEvidence=@{exists=$after.exists};foreach($name in $lateTarget.expected){$aggregateEvidence[$name]=$after.$name;$aggregateEvidence[($name+'Available')]=Get-RooIndustriesPropertyValue $after ($name+'Available') $null}
        $meter.afterAggregate=@{observedAggregate=$aggregateEvidence;appliedControls=@($applied.ToArray());verification=$verification;workItemCount=$workItems.Count;stack=@($stack|ForEach-Object {@{command=$_.Command;script=$_.ScriptName;line=$_.ScriptLineNumber}})}
        $binding=Get-LateBoundIdentity $lateTarget.process $snapshot $entry $lateTarget $field
        Stop-LateOriginal $lateTarget $meter $binding
       }
      }
     }catch{$meter.injectionErrors.Add($_.Exception.ToString())|Out-Null;throw}
    }.GetNewClosure()) -FunctionName 'Test-RooIndustriesRestoreInstanceEnded'))|Out-Null
   }else{
    $lastControl=if($mode -ceq 'late-exit-release-error'){$field}else{@($lateTarget.expected)[-1]}
    $breakpoints.Add((New-Breakpoint $context $common '^\s*if \(\$instanceHeld\)' ({
     try{
      $process=(Get-Variable Process -ErrorAction Stop).Value;$snapshot=(Get-Variable Snapshot -ErrorAction Stop).Value;$entry=(Get-Variable Entry -ErrorAction Stop).Value;$control=[string](Get-Variable control -ErrorAction Stop).Value
      if($control -ceq $lastControl -and $snapshot.processId -eq $lateTarget.owned.Identity.pid -and $meter.stopHits -eq 0){
       $change=(Get-Variable Change -ErrorAction Stop).Value
       Require ((Get-Variable candidateConfirmed -ErrorAction Stop).Value -and (Get-Variable candidateRestored -ErrorAction Stop).Value -and (Get-Variable instanceHeld -ErrorAction Stop).Value -and $change.outcome -ceq 'applied') 'MISSING actual last successful Confirm/setter/held mutex.'
       $expectedPrior=if($mode -ceq 'late-exit-release-error' -and $field -ceq 'priorityClass'){@($field)}else{@($lateTarget.expected)}
       foreach($name in $expectedPrior){Require (@($meter.readbacks|Where-Object {$_.pid -eq $snapshot.processId -and $_.control -ceq $name -and $_.change.outcome -ceq 'applied'}).Count -eq 1) 'MISSING prior actual native write/readback.'}
       $binding=Get-LateBoundIdentity $process $snapshot $entry $lateTarget $control
       $binding.change=$change;$binding.stack=@(Get-PSCallStack|ForEach-Object {@{command=$_.Command;script=$_.ScriptName;line=$_.ScriptLineNumber}})
       if($mode -ceq 'late-exit-release-error'){$releaseKeep=[Threading.Mutex]::OpenExisting((Get-Variable name -ErrorAction Stop).Value);$meter.releaseKeep=$releaseKeep}
       Stop-LateOriginal $lateTarget $meter $binding
       if($mode -ceq 'late-exit-release-error'){(Get-Variable instanceMutex -ErrorAction Stop).Value.ReleaseMutex();$meter.releaseFault=$true}
      }
     }catch{$meter.injectionErrors.Add($_.Exception.ToString())|Out-Null;throw}
    }.GetNewClosure()) -FunctionName 'Confirm-RooIndustriesRestoreControl'))|Out-Null
   }
   $first=Undo $context 'first' $Source $guard
   $status=if($kind -ceq 'game'){Get-Content -LiteralPath (Join-Path $directory 'status-first.json') -Raw|ConvertFrom-Json}else{$null}
   Require ($meter.injectionErrors.Count -eq 0 -and $meter.stopHits -eq 1 -and $meter.waitCompleted -and $lateTarget.process.HasExited -and $guard.rejections.Count -eq 0) 'MISSING exact owned late-exit ordering/guard proof.'
   $targetPid=$lateTarget.owned.Identity.pid
   $closed=if($kind -ceq 'game'){@($first.skippedItems|Where-Object {$_.processId -eq $targetPid -and $_.outcome -ceq 'alreadyClosed'})}else{@($first.result.alreadyClosedItems|Where-Object processId -eq $targetPid)}
   $restored=@($first.result.changedItems|ForEach-Object {@($_.restoredControls)})
   Require (@($first.result.changedItems|Where-Object processId -eq $targetPid).Count -eq 0 -and @($first.result.leftAsSetItems|Where-Object processId -eq $targetPid).Count -eq 0 -and @($first.leftAsSetItems|Where-Object processId -eq $targetPid).Count -eq 0) 'Ended target received current restored/kept attribution.'
   foreach($original in @($originals.ToArray())){foreach($name in @('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority')){
    $expectedWrites=0
    if($original.role -ceq 'surviving-peer'){$expectedWrites=if($name -ceq 'priorityClass'){1}else{0}}
    elseif($mode -ceq 'late-exit-postwrite'){$expectedWrites=if($original.expected -contains $name){1}else{0}}
    elseif($mode -ceq 'late-exit-release-error'){$expectedWrites=if($name -ceq $field -or ($field -cne 'priorityClass' -and $name -ceq 'priorityClass')){1}else{0}}
    elseif($mode -ceq 'late-exit-restore' -and $field -cne 'priorityClass' -and $name -ceq 'priorityClass'){$expectedWrites=1}
    $events=@($guard.events|Select-Object -Skip $meter.undoGuardStart|Where-Object {$_.pid -eq $original.owned.Identity.pid -and $_.control -ceq $name})
    $readbacks=@($meter.readbacks|Where-Object {$_.pid -eq $original.owned.Identity.pid -and $_.control -ceq $name})
    Require ($events.Count -eq $expectedWrites -and $readbacks.Count -eq $expectedWrites) 'Actual late per-original/control write/readback count differs.'
    foreach($event in $events){Require ($event.enteredRealMutator -and $event.returned -and $event.outcome -ceq 'applied' -and $null -eq $event.error) 'Prior late native mutator did not actually succeed.'}
   }}
   foreach($name in $meter.attempts.Keys){Require ($meter.attempts[$name] -eq @($guard.events|Select-Object -Skip $meter.undoGuardStart|Where-Object control -CEQ $name).Count) 'Late setter attempt and actual guard identity counts differ.'}
   if($twoOriginalHistory){Assert-LateOriginal $survivor;Require ((Read-Actual $survivor.process 'priorityClass') -ceq 'Normal' -and @($first.result.changedItems|Where-Object processId -eq $survivor.process.Id).Count -eq 1 -and $restored.Count -eq 1) 'Independent surviving original did not restore once.'}
   else{Require ($restored.Count -eq 0) 'Closed/refused original counted a prior write as current restored.'}
   Save (Join-Path $directory 'first-readback.json') @{result=$first;reopenedStatus=$status;targetEnded=$true;targetValues=$null;beforeExit=$meter.beforeExit;survivorValues=$(if($twoOriginalHistory){Read-E2EControls $survivor.process}else{$null});stopBinding=$meter.stopBinding;observerCalls=$meter.observerCalls;readbacks=@($meter.readbacks.ToArray());confirmReturnSites=@($meter.returns.ToArray());hardReturns=@($meter.hardReturns.ToArray());providerErrors=@($meter.providerErrors.ToArray());afterAggregate=$meter.afterAggregate;backendRoot=$Source;backendCommit=$SourceCommit;restoreScriptSha256=(Get-HarnessFileSha256 (Join-Path $Source ('backend\scripts\'+$(if($kind -ceq 'game'){'Stop-GameTuneSession.ps1'}else{'Restore-ProcessProfileBackup.ps1'}))));driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);statusReaderRoot=$(if($kind -ceq 'game'){$Source}else{$null});statusReaderSha256=$(if($kind -ceq 'game'){Get-HarnessFileSha256 (Join-Path $Source 'backend\scripts\Get-GameTuneSessionStatus.ps1')}else{$null});sourceCommit=$SourceCommit;engine=$PSVersionTable.PSVersion.ToString();backupSha256=$context.backupHash;oldF4Red='MISSING: no old backend run or transplanted observer'}
   if($mode -ceq 'late-exit-release-error'){
    Require ($meter.releaseFault -and $closed.Count -eq 0 -and (Is-Pending $context $first) -and @($meter.hardReturns|Where-Object {$_.cleanupFailed -is [bool] -and $_.cleanupFailed -and ($_.reasons -join '; ') -like '*Instance release:*'}).Count -ge 1 -and ($first.result.skippedItems.reason -join '; ') -like '*Instance release:*') 'Actual release failure did not remain hard/pending.'
    if($kind -ceq 'profile'){Require ($first.status -ceq 'failed' -and $first.result.restorePendingCount -eq 1) 'Release failure Profile phase differs.'}
    else{Require ($first.result.status -ceq 'failed' -and $first.status -ceq 'failed' -and $first.restorable -and $status.status -ceq 'failed' -and -not $status.completed) 'Release failure Game tuple differs.'}
   }else{
    Require ($closed.Count -eq 1 -and -not(Is-Pending $context $first) -and @($meter.providerErrors|Where-Object {$_.savedId -eq $targetPid -and $_.exceptionType -ceq 'System.ArgumentException' -and $_.savedBirth.ToString() -ceq $lateTarget.owned.Identity.creationTimeFileTimeUtc}).Count -ge 1) 'MISSING actual exact GetProcessById ArgumentException/closed original.'
    if($kind -ceq 'profile'){Require ($first.status -ceq 'success' -and $first.result.restorePendingCount -eq 0 -and @($first.result.pendingItems).Count -eq 0 -and @($first.result.changedItems).Count -eq $(if($twoOriginalHistory){1}else{0}) -and $first.result.summary -like ('*for '+$(if($twoOriginalHistory){1}else{0})+' app(s).*')) 'Positive late Profile counts differ.'}
    else{Require ($first.result.status -ceq 'rolledBack' -and $first.status -ceq 'completed' -and $first.sessionStatus -ceq 'completed' -and -not $first.restorable -and $status.status -ceq 'completed' -and $status.completed -and -not $status.restorable -and $status.restoreAttempted -and $status.summary.changedItemCount -eq $originals.Count -and $status.summary.restoredItemCount -eq $(if($twoOriginalHistory){1}else{0}) -and $status.summary.skippedItemCount -eq 1) 'Positive late Game raw/persisted/public counts differ.'}
   }
   if($mode -ceq 'late-exit-original'){Require (@($first.preview|Where-Object processId -eq $targetPid|ForEach-Object {@($_.alreadyOriginal)}|Where-Object control -CEQ $field).Count -eq 1) 'Late original case did not enter the actual no-write original lane.'}
   if($mode -ceq 'late-exit-kept'){Require (@($first.preview|Where-Object processId -eq $targetPid|ForEach-Object {@($_.leftAsSet)}|Where-Object control -CEQ $field).Count -eq 1) 'Late kept case did not enter the actual verified-kept lane.'}
   Remove-LateBreakpoints $context $breakpoints
   if($mode -ceq 'late-exit-release-error'){
    $releaseKeep=$meter.releaseKeep
    $releaseAcquired=$releaseKeep.WaitOne(0)
    Require $releaseAcquired 'Original release-error mutex obligation did not settle.'
    $releaseKeep.ReleaseMutex();$releaseAcquired=$false;$releaseKeep.Dispose();$releaseKeep=$null;$meter.releaseKeep=$null
   }
   $eventsBeforeRepeat=$guard.events.Count
   $repeat=Undo $context $(if($mode -ceq 'late-exit-release-error'){'fresh-ended-retry'}else{'repeat'}) $Source $guard
   Require (-not(Is-Pending $context $repeat) -and $guard.events.Count -eq $eventsBeforeRepeat -and $guard.rejections.Count -eq 0 -and @($repeat.result.changedItems).Count -eq 0 -and @($repeat.result.leftAsSetItems).Count -eq 0) 'Fresh ended/repeated Undo wrote or certified a current target.'
   if($kind -ceq 'game'){$phase=if($mode -ceq 'late-exit-release-error'){'fresh-ended-retry'}else{'repeat'};$again=Get-Content -LiteralPath (Join-Path $directory ('status-'+$phase+'.json')) -Raw|ConvertFrom-Json;Require ($repeat.sessionId -ceq $apply.sessionId -and $again.sessionId -ceq $apply.sessionId -and $again.status -ceq 'completed' -and $again.completed -and -not $again.restorable -and $again.summary.changedItemCount -eq $originals.Count -and $again.summary.restoredItemCount -eq 0 -and $again.summary.skippedItemCount -eq 1) 'Repeated/fresh-ended Game status differs.'}
   if($twoOriginalHistory){Require ((Read-Actual $survivor.process 'priorityClass') -ceq 'Normal') 'Repeated Undo changed the surviving original.'}
   Require ((Get-HarnessFileSha256 $context.backup) -ceq $context.backupHash -and (Get-HarnessFileSha256 $producerArtifact) -ceq $context.backupHash) 'Late phase changed immutable original producer bytes.'
   $phaseResults.Add($first)|Out-Null;$phaseResults.Add($repeat)|Out-Null
   $legRecord.completed=$true
  }catch{$bodyError=$_;Save (Join-Path $directory 'failure.json') @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace}}
  finally{
   foreach($bp in @($context.breakpoints.ToArray())){try{Remove-PSBreakpoint -Breakpoint $bp;$null=$context.breakpoints.Remove($bp)}catch{$cleanupErrors.Add($_.Exception.ToString())|Out-Null}}
   if($meter.ContainsKey('releaseKeep') -and $null -ne $meter.releaseKeep -and $null -eq $releaseKeep){$releaseKeep=$meter.releaseKeep}
   try{if($null -ne $releaseKeep){if($releaseAcquired){$releaseKeep.ReleaseMutex();$releaseAcquired=$false};$releaseKeep.Dispose();$releaseKeep=$null}}catch{$cleanupErrors.Add($_.Exception.ToString())|Out-Null}
   foreach($original in @($originals.ToArray())){
    try{
     if($null -ne $original.imageProbe){$original.imageProbe.Dispose();$original.imageProbe=$null}
     if($null -ne $original.process){Require ($null -ne $original.owned -and $null -ne $original.processEntry) 'Original late process lacks ownership/ledger proof; dependencies retained.';Stop-OwnedProcess $original.owned;Require ($original.process.WaitForExit(5000) -and $original.process.HasExited) 'Original late fixture did not exit.';$original.stopVerified=$true;Remove-HarnessEntry $original.processEntry;$original.process.Dispose();$original.wrapperDisposed=$true}else{$original.stopVerified=$true}
     if($original.imageCreationAttempted -and $null -eq $original.imageEntry -and (Test-HarnessPath $original.image)){throw 'Unregistered late original image retained with its directory.'}
     foreach($extra in @($original.extraEntries.ToArray())){Remove-HarnessEntry $extra}
     if($null -ne $original.imageEntry){Remove-HarnessEntry $original.imageEntry}
     if($null -ne $original.directoryEntry){Require (@([IO.Directory]::EnumerateFileSystemEntries($original.directory)).Count -eq 0) 'Late original directory is not empty; retained.';Remove-HarnessEntry $original.directoryEntry}elseif(Test-HarnessPath $original.directory){throw 'Unregistered late original directory retained.'}
     $finalEntries=New-Object System.Collections.Generic.List[object]
     foreach($entry in @($original.processEntry,$original.imageEntry,$original.directoryEntry)+@($original.extraEntries.ToArray())){if($null -eq $entry){continue};$actual=@(Get-HarnessEntries|Where-Object id -CEQ $entry.id);Require ($actual.Count -eq 1 -and [string]::IsNullOrWhiteSpace([string]$actual[0].cleanupError)) 'Original late cleanup ledger ID failed.';if($entry.kind -ceq 'process'){Require ($actual[0].state -in @('removed','absent') -and $actual[0].identity.pid -eq $entry.identity.pid -and $actual[0].identity.creationTimeFileTimeUtc -ceq $entry.identity.creationTimeFileTimeUtc -and $actual[0].identity.imagePath -ieq $entry.identity.imagePath) 'Original late process ledger identity differs.'}elseif($entry.kind -ceq 'file'){Require ($actual[0].state -ceq 'removed' -and $actual[0].identity.id -ceq $entry.identity.id -and $actual[0].identity.hash -ceq $entry.identity.hash -and $actual[0].identity.path -ieq $entry.identity.path) 'Original late file ledger identity differs.'}else{Require ($actual[0].state -ceq 'removed' -and $actual[0].identity.creationTimeFileTimeUtc -ceq $entry.identity.creationTimeFileTimeUtc -and $actual[0].identity.path -ieq $entry.identity.path) 'Original late directory ledger identity differs.'};$finalEntries.Add($actual[0])|Out-Null}
     Require (-not(Test-HarnessPath $original.directory)) 'Original late directory still exists.'
     $original.cleanupPassed=$true
     Save (Join-Path $directory ('cleanup-'+$original.role+'.json')) @{original=$original.owned.Identity;originalHandle=$original.owned.handle.ToInt64();stopVerified=$original.stopVerified;wrapperDisposed=$original.wrapperDisposed;originalProcessEntry=$original.processEntry;originalImageEntry=$original.imageEntry;originalDirectoryEntry=$original.directoryEntry;finalSameIdEntries=@($finalEntries.ToArray());cleanupPassed=$true}
    }catch{$original.cleanupError=$_.Exception.ToString();$cleanupErrors.Add($original.role+': '+$original.cleanupError)|Out-Null}
   }
   $legRecord.cleanupPassed=$cleanupErrors.Count -eq 0 -and @($originals|Where-Object {-not $_.cleanupPassed}).Count -eq 0
   Save (Join-Path $directory 'mutation-guard.json') @{nonce=$context.nonce;armed=($null -ne $guard);backendRoot=$Source;sourceCommit=$SourceCommit;commonPath=$common;commonSha256=(Get-HarnessFileSha256 $common);driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);originals=$(if($null -ne $guard){@($guard.originals|ForEach-Object {@{pid=$_.pid;birth=$_.birth;image=$_.image;handle=$_.handle.ToInt64()}})}else{@()});events=$(if($null -ne $guard){@($guard.events.ToArray())}else{@()});rejections=$(if($null -ne $guard){@($guard.rejections.ToArray())}else{@()});fixtureProtection='Pass-through actual backend mutator; no inventory/producer/native simulation'}
   Save (Join-Path $directory 'cleanup.json') @{cleanupPassed=$legRecord.cleanupPassed;errors=@($cleanupErrors.ToArray());originals=@($originals|ForEach-Object {@{role=$_.role;identity=$(if($null -ne $_.owned){$_.owned.Identity}else{$null});processEntry=$_.processEntry;imageEntry=$_.imageEntry;directoryEntry=$_.directoryEntry;imageCreationAttempted=$_.imageCreationAttempted;stopVerified=$_.stopVerified;wrapperDisposed=$_.wrapperDisposed;cleanupPassed=$_.cleanupPassed;cleanupError=$_.cleanupError}});guardRejections=$(if($null -ne $guard){@($guard.rejections.ToArray())}else{@()});injectionErrors=@($meter.injectionErrors.ToArray());nativeBehaviorSimulated=$false}
  }
  if($bodyError){throw $bodyError}
  Require ($legRecord.completed -and $legRecord.cleanupPassed -and $cleanupErrors.Count -eq 0) 'Original late leg cleanup/completion failed.'
  Save (Join-Path $directory 'done.json') @{passed=$true;kind=$kind;control=$field;scenario=$mode;leg=$legName;cleanupPassed=$true;sourceCommit=$SourceCommit;oldRed='MISSING/UNRUN'}
 }}
 Require ($history.legs.Count -eq $legs.Count -and @($history.legs|Where-Object {-not $_.completed -or -not $_.cleanupPassed}).Count -eq 0) 'Composite late history lacks every original leg.'
 Save (Join-Path $parent.directory 'observations.json') @{kind=$kind;control=$field;scenario=$mode;sourceCommit=$SourceCommit;legs=@($history.legs|ForEach-Object {@{name=$_.name;directory=$_.directory;completed=$_.completed;cleanupPassed=$_.cleanupPassed}});actualProducerLegs=$history.legs.Count;nativeBehaviorSimulated=$false;oldF4Red='MISSING/UNRUN; no transplanted new observer or source comparison interface'}
 return $history
}

function Run-Scenario([string]$kind,[string]$field,[string]$mode){ & {
 $directory=Join-Path $root (Get-CaseDirectoryName $kind $field $mode)
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
 $lateScenario=$lateScenarios -contains $mode
 $lateHistory=[pscustomobject]@{legs=(New-Object System.Collections.Generic.List[object]);setterFailures=(New-Object System.Collections.Generic.List[object])}
 try{
  . (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
  $script:RestoreE2EData=$context.data
  function Get-RooIndustriesLocalDataRoot{return $script:RestoreE2EData}
  if($lateScenario){$meter=Invoke-LateHistory $context $kind $field $mode $lateHistory}else{
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
  if($noEffectScenarios -contains $mode){
   $meter=Invoke-NoEffectHistory $context $kind $field $mode
  }else{
  $context.process.PriorityClass='Normal'
  Require ((Read-Actual $context.process 'priorityClass') -ceq 'Normal') 'Owned CPU original precondition failed.'
  if($field -eq 'ioPriority'){
   [RooIndustriesBackgroundOracle]::SetIo($context.process,(Convert-RooIndustriesIoPriorityToValue 'Low' -Restoring))
   Require ((Read-Actual $context.process 'ioPriority') -ceq 'Low') 'Owned IO original precondition failed.'
  }
  if($field -eq 'memoryPriority' -or ($field -eq 'priorityClass' -and -not $priorityOnly)){
   [RooIndustriesBackgroundOracle]::SetMemory($context.process,[uint32]2)
   Require ((Read-Actual $context.process 'memoryPriority') -eq 2) 'Owned memory original/peer precondition failed.'
  }
  if($field -eq 'gpuPriority'){
   Set-RooIndustriesProcessGpuPriority $context.process 'Normal'
   Require ((Read-Actual $context.process 'gpuPriority') -ceq 'Normal') 'Owned GPU original precondition failed.'
  }
  $original=Read-Actual $context.process $field
  $desired=switch($field){'priorityClass'{'AboveNormal'};'affinityMask'{[long]($context.process.ProcessorAffinity.ToInt64() -band (-$context.process.ProcessorAffinity.ToInt64()))};'ioPriority'{'Normal'};'memoryPriority'{5};'gpuPriority'{'BelowNormal'}}
  Require ($original.ToString() -ne $desired.ToString()) 'Fixture needs a different original to prove Undo.'
  $peer=if($field -eq 'priorityClass'){'memoryPriority'}else{'priorityClass'}
  $peerOriginal=Read-Actual $context.process $peer
  $foreground=[ordered]@{ruleId='restore-e2e';processNames=@('RestoreTarget.exe');priorityClass='AboveNormal';reason='Restore E2E fixture';reasonCodes=@('LIVE_VALIDATION')}
  $foreground[$field]=$desired
  if($peer -eq 'memoryPriority' -and -not $priorityOnly){$foreground.memoryPriority=5}
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
  if($kind -eq 'profile'){
   [IO.File]::WriteAllBytes((Join-Path $directory 'producer-profile-backup.json'),[IO.File]::ReadAllBytes($context.backup))
   Save (Join-Path $directory 'producer-profile-evidence.json') @{kind='UNMODIFIED ACTUAL PROFILE PRODUCER BEFORE REPLAY';sourceRoot=$Source;sourceCommit=$SourceCommit;producerScriptSha256=(Get-HarnessFileSha256 (Join-Path $Source 'backend\scripts\Apply-ProcessProfile.ps1'));commonSha256=(Get-HarnessFileSha256 (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1'));driverPath=$driverSourcePath;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);engine=$PSVersionTable.PSVersion.ToString();backupPath=$context.backup;producerBackupSha256=(Get-HarnessFileSha256 (Join-Path $directory 'producer-profile-backup.json'));originalProcess=$context.owned.Identity}
  }
  $expectedProducerControls=@($field)
  if(-not $priorityOnly){$expectedProducerControls+=@($peer)}
  Require (@($snapshot[0].controlChanges).Count -eq $expectedProducerControls.Count) 'Producer emitted an unexpected control count.'
  foreach($expectedControl in $expectedProducerControls){
   $actualRecord=@($snapshot[0].controlChanges|Where-Object control -eq $expectedControl)
   Require ($actualRecord.Count -eq 1) 'Producer control identity/count differs.'
   $expectedValue=if($expectedControl -eq $field){$desired}else{if($peer -eq 'memoryPriority'){5}else{'AboveNormal'}}
   Require (Test-RooIndustriesControlValueEqual $expectedControl $actualRecord[0].proposedValue $expectedValue) 'Producer filtered or changed the intended request.'
   if($mode -ne 'failed-apply-readback' -or $expectedControl -ne $field){
    Require ($actualRecord[0].outcome -ceq 'applied' -and (Test-RooIndustriesControlValueEqual $expectedControl (Read-Actual $context.process $expectedControl) $expectedValue)) 'Genuine producer/readback evidence is missing.'
   }
  }
  if($legacyReplay -or $mode -eq 'image-alias'){
   [IO.File]::WriteAllBytes((Join-Path $directory 'producer-backup.json'),[IO.File]::ReadAllBytes($context.backup))
   $producerHash=Get-HarnessFileSha256 $context.backup
  }
  if($priorityOnly){Require (@($snapshot[0].controlChanges).Count -eq 1 -and @($snapshot[0].controlChanges|Where-Object control -eq 'memoryPriority').Count -eq 0) 'Priority-only producer secretly retained a peer apply.'}
  if($legacyReplay){
   $beforeIdentity=[pscustomobject]@{processId=$snapshot[0].processId;processName=$snapshot[0].processName;executablePath=$snapshot[0].executablePath;processStartTimeUtc=$snapshot[0].processStartTimeUtc;nativeBirth=$context.owned.Identity.creationTimeFileTimeUtc;originalPriorityClass=$snapshot[0].originalPriorityClass}
   if($unmatchedReplay){
    $peerRecord=@($snapshot[0].controlChanges|Where-Object control -eq 'memoryPriority')
    Require ($peerRecord.Count -eq 1 -and $peerRecord[0].outcome -ceq 'applied' -and (Read-Actual $context.process 'memoryPriority') -eq 5) 'Missing genuine producer peer evidence.'
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
  }
  }
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
   if($lateScenario){Require ($lateHistory.legs.Count -gt 0 -and @($lateHistory.legs|Where-Object {-not $_.cleanupPassed}).Count -eq 0) 'Original late fixture cleanup is incomplete.';$targetCleanupSucceeded=$true}
   elseif($context.owned){
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
 $results.Add(@{kind=$kind;control=$field;scenario=$mode;directoryName=(Get-CaseDirectoryName $kind $field $mode);passed=$true;aliasRedReproduced=$aliasRedReproduced})|Out-Null
}}
$kinds=if($Kind -eq 'all'){@('profile','game')}else{@($Kind)}
$controls=if($Control -eq 'all'){@('priorityClass','affinityMask','ioPriority','memoryPriority','gpuPriority')}else{@($Control)}
$selected=New-Object System.Collections.Generic.List[object]
foreach($body in $kinds){foreach($field in $controls){foreach($case in $Scenario){
 if($case -eq 'protected-game' -and $field -ne 'gpuPriority'){continue}
 if($case -eq 'protected-launcher' -and $field -ne 'memoryPriority'){continue}
 if($priorityScenarios -contains $case -and $field -ne 'priorityClass'){continue}
 if($affinityScenarios -contains $case -and $field -ne 'affinityMask'){continue}
 $selected.Add(@{kind=$body;control=$field;scenario=$case;directoryName=(Get-CaseDirectoryName $body $field $case)})|Out-Null
}}}
$uniqueTriples=@{}
$uniqueDirectories=@{}
foreach($case in $selected){$key=$case.kind+'|'+$case.control+'|'+$case.scenario;Require (-not $uniqueTriples.ContainsKey($key)) 'Duplicate selected history.';Require (-not $uniqueDirectories.ContainsKey($case.directoryName)) 'Selected history directory collision.';$uniqueTriples[$key]=$true;$uniqueDirectories[$case.directoryName]=$true}
Save (Join-Path $root 'selection.json') @{sourceCommit=$SourceCommit;group=$selectedGroup;driverSha256=(Get-HarnessFileSha256 $driverSourcePath);scope='Authored selected triples; actual success requires each assertion and cleanup';expectedCaseCount=$selected.Count;cases=@($selected.ToArray())}
foreach($case in $selected){Run-Scenario $case.kind $case.control $case.scenario}
Require ($results.Count -eq $selected.Count) 'Actual completed triples differ from the selected source grid.'
foreach($case in $selected){$casePath=Join-Path $root $case.directoryName;$done=Get-Content -LiteralPath (Join-Path $casePath 'done.json') -Raw|ConvertFrom-Json;$cleanup=Get-Content -LiteralPath (Join-Path $casePath 'cleanup.json') -Raw|ConvertFrom-Json;Require ($done.kind -ceq $case.kind -and $done.control -ceq $case.control -and $done.scenario -ceq $case.scenario -and $done.passed -and $done.cleanupPassed -and $cleanup.targetCleanupSucceeded -and @($cleanup.errors).Count -eq 0) 'Selected history lacks its matching done/original cleanup proof.'}

Save (Join-Path $root 'serialization-summary.json') @{sourceCommit=$SourceCommit;group=$selectedGroup;cases=@($results.ToArray());expectedCaseCount=$selected.Count;actualCaseCount=$results.Count;selectedTriples=@($selected.ToArray());engine=$PSVersionTable.PSVersion.ToString();nativeBehaviorSimulated=$false;passed=$true}
'ROO_INDUSTRIES_RESTORE_SERIALIZATION_E2E_COMPLETE'
