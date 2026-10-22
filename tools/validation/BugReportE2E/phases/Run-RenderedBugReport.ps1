param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$BuildOut,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)][string]$UiOutput,[Parameter(Mandatory)][string]$CaptureOut)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Phase.Common.ps1')
$binding=Enter-RooIndustriesPhase $Source $FixtureRoot $BuildOut $OutRoot
Assert-RooIndustries ($DataRoot -ieq (Join-Path $script:Harness.Root 'ui-data') -and $UiOutput -ieq (Join-Path $script:Harness.Root 'ui-output') -and $CaptureOut -ieq (Join-Path $script:Harness.Root 'capture')) 'Fixed UI/capture roots differ.'
foreach($path in @($DataRoot,$UiOutput,$CaptureOut)){$null=Assert-RooIndustriesOwnedDirectory $path;foreach($other in @($Source,$FixtureRoot,$BuildOut,$OutRoot)){Assert-RooIndustries ($path -ine $other -and -not(Test-RooIndustriesBelow $path $other) -and -not(Test-RooIndustriesBelow $other $path)) 'UI/capture roots overlap source/fixture/build/result.'}}
Assert-RooIndustriesBinding $script:Harness.Root $script:Harness.FrameId $script:Harness.Nonce $binding.manifest.frameId $DataRoot $UiOutput $CaptureOut @(Get-HarnessTree $DataRoot).Count @(Get-HarnessTree $UiOutput).Count
Assert-RooIndustries (@(Get-HarnessTree $CaptureOut).Count -eq 0) 'Capture directory must be fresh.'
$buildFile=Join-Path $OutRoot 'build-desktop-binding.json';$build=Get-RooIndustriesBuild $BuildOut $OutRoot 'desktop'
$ffmpeg=Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue
Assert-RooIndustries ($null -ne $ffmpeg) 'Existing ffmpeg/libx264 required; install nothing.'
$encoders=Invoke-RooIndustriesOwnedCommand $ffmpeg.Source @('-hide_banner','-encoders') $CaptureOut $CaptureOut 'roo70-ffmpeg-prerequisite' 10
Assert-RooIndustries ($encoders.stdout -match '\blibx264\b') 'Existing libx264 encoder unavailable.'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms,WindowsBase,System.IO.Compression,System.IO.Compression.FileSystem
Add-Type -Path (Join-Path $Source 'tools\validation\Tour\TourCapture.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms,Accessibility
. (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
function Find-RooIndustriesUi($Root,[string]$Property,[string]$Value){$id=if($Property -ceq 'id'){[Windows.Automation.AutomationElement]::AutomationIdProperty}else{[Windows.Automation.AutomationElement]::NameProperty};return @($Root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new($id,$Value)))}
function Assert-RooIndustriesVisible($Element){Assert-RooIndustries (-not$Element.Current.IsOffscreen -and $Element.Current.BoundingRectangle.Width -gt 0 -and $Element.Current.BoundingRectangle.Height -gt 0) 'Required UIA element is not actually visible.'}
function Assert-RooIndustriesText($Window,[string]$Value){$matches=@(Find-RooIndustriesUi $Window 'name' $Value|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::Text -and -not$_.Current.IsOffscreen});Assert-RooIndustries ($matches.Count -ge 1) 'Required status/attachment text is not visible in bottom view.';Assert-RooIndustriesVisible $matches[0];return @{text=$matches[0].Current.Name;visible=$true;matchingTextElements=$matches.Count}}
function Assert-RooIndustriesButton($Window,[string]$Id,[bool]$Visible,[bool]$Enabled){
 $elements=@(Find-RooIndustriesUi $Window 'id' $Id);$visibleElements=@($elements|Where-Object {-not$_.Current.IsOffscreen})
 if($Visible){Assert-RooIndustries ($visibleElements.Count -eq 1) ('Actual button missing/ambiguous: '+$Id);Assert-RooIndustriesVisible $visibleElements[0];Assert-RooIndustries ($visibleElements[0].Current.IsEnabled -eq $Enabled) ('Actual button enabled state differs: '+$Id)}else{Assert-RooIndustries ($visibleElements.Count -eq 0) ('Collapsed control unexpectedly visible: '+$Id)}
 return @{id=$Id;presentCount=$elements.Count;visibleCount=$visibleElements.Count;enabled=$(if($Visible){$visibleElements[0].Current.IsEnabled}else{$null});expectedVisible=$Visible;expectedEnabled=$Enabled}
}
function Assert-RooIndustriesPrivateText([string]$Text){
 foreach($private in @("Zqx Bob O'Neil",'Zqxbob','Alice','GAMER-PC','S-1-5-21-11-22-33-44')){Assert-RooIndustries ($Text.IndexOf($private,[StringComparison]::OrdinalIgnoreCase) -lt 0) 'Private token remained in raw attachment evidence.'}
 Assert-RooIndustriesScalars $Text
}
function Get-RooIndustriesRefreshEvidence($File,[string]$Name){
 Assert-RooIndustries (@(Get-RooIndustriesProperties $File).Count -eq 3 -and $File.File -ceq $Name -and $File.Bytes -gt 0 -and $File.Sha256 -cmatch '^[a-f0-9]{64}$') 'Refresh raw evidence reference differs.'
 Assert-RooIndustriesRelative $File.File
 $path=Join-Path $UiOutput $File.File;$entry=Get-RooIndustriesOriginalFile $path
 Assert-RooIndustries ((Get-HarnessItem $path).Length -eq $File.Bytes -and (ConvertTo-RooIndustriesSha256 $entry.identity.hash) -ceq $File.Sha256 -and (Get-RooIndustriesFileSha256 $path) -ceq $File.Sha256) 'Refresh raw evidence length/hash differs.'
 $copy=Copy-HarnessFile $path (Join-Path $CaptureOut $Name) 'roo70-attachment-refresh-raw' 'frame'
 Assert-RooIndustries ((ConvertTo-RooIndustriesSha256 $copy.identity.hash) -ceq $File.Sha256 -and (Get-HarnessItem $copy.identity.path).Length -eq $File.Bytes) 'Refresh immutable copy differs.'
 $null=Get-RooIndustriesOriginalFile $path;$null=Get-RooIndustriesOriginalFile $copy.identity.path
 return @{path=$copy.identity.path;bytes=$File.Bytes;sha256=$File.Sha256;original=$entry;capture=$copy}
}
function Get-RooIndustriesRedactedSpecs([string]$Cpu){
 return @{windows='Fixture Windows';cpu=$Cpu;gpu='Unknown';ram='Unknown';motherboard='Unknown';bios='Unknown';drive='Unknown';display='Unknown';app='0.10.0-beta fixture'}
}
function Get-RooIndustriesRedactedDescription{return 'C:\Users\<user>\AppData\x.log'+"`n"+'C:/Users/<user>/AppData/x.log'+"`n"+'C:/Users/<user>/x'}
function Assert-RooIndustriesRefreshZip([string]$Path,[string]$Cpu,[bool]$Report){
 $original=Get-RooIndustriesOriginalFile $Path
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $Path),$original.identity.id,$original.identity.hash)
 try{
 $stream=[IO.File]::Open((Get-HarnessLongPath $Path),[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
 try{
  $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
  try{
   $wanted=@('specs.json','tweak-state.json','logs/app.log');if($Report){$wanted+=@('report.txt')}
   Assert-RooIndustries ($zip.Entries.Count -eq $wanted.Count -and @($zip.Entries.FullName|Sort-Object -Unique).Count -eq $wanted.Count) 'Raw ZIP entry count/uniqueness differs.'
   $texts=@{}
   foreach($name in $wanted){$entry=$zip.GetEntry($name);Assert-RooIndustries ($null -ne $entry) ('Raw ZIP entry missing: '+$name);$reader=[IO.StreamReader]::new($entry.Open(),[Text.UTF8Encoding]::new($false,$true));try{$texts[$name]=$reader.ReadToEnd()}finally{$reader.Dispose()};Assert-RooIndustriesPrivateText $texts[$name]}
   $specs=$texts['specs.json']|ConvertFrom-Json
   Assert-RooIndustriesExact $specs @{schemaVersion=1;specs=(Get-RooIndustriesRedactedSpecs $Cpu)} 'raw.specs'
   Assert-RooIndustriesPrivateText ($specs|ConvertTo-Json -Depth 10 -Compress)
   $summary=$texts['tweak-state.json']|ConvertFrom-Json
   Assert-RooIndustriesExact $summary @{schemaVersion=1;appliedProfiles=@();pendingRecovery=$null;pendingPhase=$null;lastErrors=@('C:\Users\<user>\AppData\recovery.log','C:\Users\<user>\AppData\prior.log')} 'raw.summary'
   $log=(Get-RooIndustriesRedactedDescription)+"`n"+'%USERPROFILE%\AppData\x.log'+"`n"+'<user> <pc-name> <sid>'+"`n"
   Assert-RooIndustries ($texts['logs/app.log'] -ceq $log) 'Raw ZIP log differs.'
   if($Report){
    $nl=[Environment]::NewLine
    $reportText='Performance Vertex Utility 0.10.0-beta fixture'+$nl+'Discord or email: retain-contact@example.com'+$nl+$nl
    foreach($field in @(@('Windows','Fixture Windows'),@('Processor',$Cpu),@('Graphics and driver','Unknown'),@('Memory','Unknown'),@('Motherboard','Unknown'),@('BIOS version','Unknown'),@('System drive','Unknown'),@('Main display','Unknown'),@('App version','0.10.0-beta fixture'))){$reportText+=$field[0]+': '+$field[1]+$nl}
    $reportText+=$nl+'What went wrong:'+$nl+(Get-RooIndustriesRedactedDescription)+$nl
    Assert-RooIndustries ($texts['report.txt'] -ceq $reportText) 'Raw saved report/current CPU/contact/description differs.'
   }
  }finally{$zip.Dispose()}
 }finally{$stream.Dispose()}
 }finally{$probe.Dispose()}
 $null=Get-RooIndustriesOriginalFile $Path
}
function Assert-RooIndustriesRefreshPayload([string]$Path,[string]$Cpu){
 $null=Get-RooIndustriesOriginalFile $Path
 $text=Read-HarnessInputText $Path;$payload=$text|ConvertFrom-Json
 Assert-RooIndustriesPrivateText $text;Assert-RooIndustriesPrivateText ($payload|ConvertTo-Json -Depth 20 -Compress)
 Assert-RooIndustries (@($payload.embeds).Count -eq 1 -and @($payload.attachments).Count -eq 1 -and @($payload.allowed_mentions.parse).Count -eq 0) 'Raw payload embed/attachment/mention count differs.'
 Assert-RooIndustriesExact $payload.attachments[0] @{id=0;filename='roo-industries-bug-report-20261021-010203.zip'} 'raw.payload.attachment'
 $embed=$payload.embeds[0]
 Assert-RooIndustries ($embed.title -ceq 'Bug report: Performance Vertex Utility 0.10.0-beta fixture' -and $embed.color -eq 3113197) 'Raw payload title/color differs.'
 Assert-RooIndustries ($embed.description.Replace("`r`n","`n").Replace("`r","`n") -ceq (Get-RooIndustriesRedactedDescription)) 'Raw payload description differs.'
 $fields=@(@{name='Windows';value='Fixture Windows';inline=$false},@{name='Processor';value=$Cpu;inline=$false},@{name='Graphics and driver';value='Unknown';inline=$false},@{name='Memory';value='Unknown';inline=$false},@{name='Motherboard';value='Unknown';inline=$false},@{name='BIOS version';value='Unknown';inline=$false},@{name='System drive';value='Unknown';inline=$false},@{name='Main display';value='Unknown';inline=$false},@{name='App version';value='0.10.0-beta fixture';inline=$false},@{name='Discord or email';value='retain-contact@example.com';inline=$false})
 Assert-RooIndustriesExact @($embed.fields) $fields 'raw.payload.fields'
 $null=Get-RooIndustriesOriginalFile $Path
}
function Assert-RooIndustriesAttachmentRefresh($Final){
 Assert-RooIndustries ($Final.attachmentRefreshMarker -ceq 'ROO_INDUSTRIES_BUG_REPORT_ATTACHMENT_REFRESH_COMPLETE' -and @($Final.attachmentRefresh).Count -eq 4) 'Exactly four attachment refresh receipts required.'
 $cases=@(
  @{Outcome='RateLimited';Scene='online-rate-limited';Suffix=' | rate-limited';Code=429;Retry=120;Throws=$false;Advance=0;Utc='2026-10-21T01:02:03.0000000Z'},
  @{Outcome='Offline';Scene='online-offline';Suffix=' | offline';Code=$null;Retry=$null;Throws=$true;Advance=121;Utc='2026-10-21T01:04:04.0000000Z'},
  @{Outcome='Rejected';Scene='online-failed';Suffix=' | rejected';Code=404;Retry=$null;Throws=$false;Advance=0;Utc='2026-10-21T01:04:04.0000000Z'},
  @{Outcome='Sent';Scene='online-sent';Suffix=' | later';Code=200;Retry=$null;Throws=$false;Advance=61;Utc='2026-10-21T01:05:05.0000000Z'}
 )
 $path=Join-Path $DataRoot 'failed\reports\outgoing\roo-industries-bug-report-20261021-010203.zip'
 $rawCpu='C:\Users\<user>\AppData\x.log';$prior=$null;$originalHash=$null;$priorTime=$null;$proof=New-Object System.Collections.Generic.List[object]
 for($i=0;$i -lt 4;$i++){
  $row=$Final.attachmentRefresh[$i];$case=$cases[$i];$cpu=$rawCpu+$case.Suffix
  $fields=@('Outcome','SenderIndex','FixtureUtc','FixtureAdvanceSeconds','Before','After','BeforeIsOriginal','BeforeIsPreviousRetained','AfterIsDifferent','SavePreservedPreviousRecord','BeforeActualBytes','SenderActualBytes','RetainedActualBytes','OriginalSha256','SourceSha256','SenderSha256','RetainedSha256','SenderPath','WebhookUrl','StatusCode','RetryAfterSeconds','ThrewHttpRequestException','ExpectedCpu','ActualStatus','ActualLabel','OutgoingExists','AfterState','BeforeZip','SentZip','Payload')
  $keys=@(Get-RooIndustriesProperties $row);Assert-RooIndustries ($keys.Count -eq $fields.Count) 'Attachment refresh record field count differs.'
  foreach($field in $fields){Assert-RooIndustries ($keys -ccontains $field) ('Attachment refresh record missing '+$field)}
  Assert-RooIndustries ($row.Outcome -ceq $case.Outcome -and $row.SenderIndex -eq $i+1 -and $row.FixtureAdvanceSeconds -eq $case.Advance -and $row.ExpectedCpu -ceq $cpu) 'Attachment outcome/order/fixture time/CPU differs.'
  Assert-RooIndustries ($row.FixtureUtc -is [string] -or $row.FixtureUtc -is [DateTime]) 'Fixture UTC must be an exact timestamp.'
  $time=if($row.FixtureUtc -is [DateTime]){$row.FixtureUtc.ToUniversalTime()}else{[DateTime]::ParseExact($row.FixtureUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}
  Assert-RooIndustries ($time.Kind -eq [DateTimeKind]::Utc -and $time.ToString('o',[Globalization.CultureInfo]::InvariantCulture) -ceq $case.Utc) 'Exact fixture UTC differs.'
  if($null -ne $priorTime){Assert-RooIndustries (($time-$priorTime).TotalSeconds -eq $case.Advance) 'Fixture clock delta differs; Offline retry must be immediate.'};$priorTime=$time
  Assert-RooIndustriesExact $row.StatusCode $case.Code 'refresh.StatusCode';Assert-RooIndustriesExact $row.RetryAfterSeconds $case.Retry 'refresh.RetryAfterSeconds';Assert-RooIndustriesExact $row.ThrewHttpRequestException $case.Throws 'refresh.ThrewHttpRequestException'
  Assert-RooIndustriesExact $row.BeforeIsOriginal ($i -eq 0) 'refresh.BeforeIsOriginal';Assert-RooIndustriesExact $row.BeforeIsPreviousRetained ($i -gt 0) 'refresh.BeforeIsPreviousRetained';Assert-RooIndustriesExact $row.SavePreservedPreviousRecord ($i -eq 3) 'refresh.SavePreservedPreviousRecord'
  Assert-RooIndustries ($row.SenderPath -ceq $path -and $row.WebhookUrl -ceq 'https://discord.com/api/webhooks/123/fixture-token') 'Actual sender path/URL differs.'
  $before=Get-RooIndustriesRefreshEvidence $row.BeforeZip ($case.Scene+'.before.zip');$sent=Get-RooIndustriesRefreshEvidence $row.SentZip ($case.Scene+'.zip');$payload=Get-RooIndustriesRefreshEvidence $row.Payload ($case.Scene+'.payload.json')
  Assert-RooIndustriesExact $row.Before @{FilePath=$path;FileName='roo-industries-bug-report-20261021-010203.zip';Bytes=$before.bytes} 'refresh.Before'
  Assert-RooIndustries ($row.BeforeActualBytes -eq $before.bytes -and $row.SenderActualBytes -eq $sent.bytes -and $row.SourceSha256 -ceq $before.sha256 -and $row.SenderSha256 -ceq $sent.sha256 -and $before.sha256 -cne $sent.sha256) 'Pre-send/wire raw sizes/hashes differ or CPU was not refreshed.'
  if($i -eq 0){$originalHash=$before.sha256}else{Assert-RooIndustries ($before.sha256 -ceq $prior.RetainedSha256 -and $row.Before.Bytes -eq $prior.After.Bytes) 'Retry did not keep the prior refreshed record bytes.'}
  Assert-RooIndustries ($row.OriginalSha256 -ceq $originalHash -and $sent.sha256 -cne $originalHash) 'Sender reused original attachment bytes.'
  for($j=0;$j -lt $i;$j++){Assert-RooIndustries ($sent.sha256 -cne $Final.attachmentRefresh[$j].SenderSha256) 'Sender reused a prior outcome CPU archive.'}
  $beforeCpu=if($i -eq 0){$rawCpu}else{$rawCpu+$cases[$i-1].Suffix}
  Assert-RooIndustriesRefreshZip $before.path $beforeCpu $false;Assert-RooIndustriesRefreshZip $sent.path $cpu $false;Assert-RooIndustriesRefreshPayload $payload.path $cpu
  $expected=New-RooIndustriesExpectedState $case.Scene $DataRoot $sent.bytes
  Assert-RooIndustriesExact $row.AfterState $expected.model 'receipt.State'
  Assert-RooIndustries ($row.ActualStatus -ceq $expected.model.Status -and $row.ActualLabel -ceq $expected.model.AttachmentText) 'Actual outcome label/status differs.'
  $views=@($observed.ToArray()|Where-Object {$_.name -ceq $case.Scene});Assert-RooIndustries ($views.Count -eq 2) 'Outcome lacks both actual checkpoints.'
  foreach($view in $views){
   $checkpointPath=Join-Path $CaptureOut ($case.Scene+'-'+$view.view+'-checkpoint.json');$null=Get-RooIndustriesOriginalFile $checkpointPath
   $checkpoint=Read-HarnessInputText $checkpointPath|ConvertFrom-Json;Assert-RooIndustriesExact $checkpoint.state.model $expected.model 'State.model'
   $receipt=$checkpoint.receipt|ConvertFrom-Json
   Assert-RooIndustries ($receipt.SenderCalls -eq $i+1) 'Actual checkpoint sender count differs.'
   foreach($file in @($row.BeforeZip,$row.SentZip,$row.Payload)){$matching=@($receipt.Evidence|Where-Object {$_.File -ceq $file.File});Assert-RooIndustries ($matching.Count -eq 1) 'Refresh raw file missing from bound checkpoint receipt.';Assert-RooIndustriesExact $matching[0] @{File=$file.File;Sha256=$file.Sha256;Bytes=$file.Bytes} 'refresh.checkpoint.evidence'}
   if($i -lt 3){Assert-RooIndustries ($view.actualOutgoingPath -ceq $path -and $view.actualOutgoingBytes -eq $sent.bytes -and $view.actualOutgoingSha256 -ceq $sent.sha256) 'Retained ZIP differs from actual checkpoint bytes/hash.'}else{Assert-RooIndustries ($null -eq $view.actualOutgoingPath -and $view.actualOutgoingBytes -eq 0 -and $null -eq $view.actualOutgoingSha256) 'Sent checkpoint retained an outgoing ZIP.'}
  }
  if($i -lt 3){
   Assert-RooIndustriesExact $row.After @{FilePath=$path;FileName='roo-industries-bug-report-20261021-010203.zip';Bytes=$sent.bytes} 'refresh.After'
   Assert-RooIndustriesExact $row.AfterIsDifferent $true 'refresh.AfterIsDifferent';Assert-RooIndustriesExact $row.OutgoingExists $true 'refresh.OutgoingExists'
   Assert-RooIndustries ($row.RetainedActualBytes -eq $sent.bytes -and $row.RetainedSha256 -ceq $sent.sha256) 'Retained evidence does not equal captured wire bytes.'
  }else{
   foreach($field in 'After','AfterIsDifferent','RetainedActualBytes','RetainedSha256'){Assert-RooIndustries ($null -eq $row.$field) ('Sent must have null '+$field)}
   Assert-RooIndustriesExact $row.OutgoingExists $false 'refresh.OutgoingExists'
   Assert-RooIndustries (-not(Test-HarnessPath $path) -and @(Get-HarnessChildren (Split-Path -Parent $path) -File -Filter '*.zip').Count -eq 0) 'Sent outgoing file still exists.'
  }
  $proof.Add(@{receipt=$row;before=$before;sent=$sent;payload=$payload;independentRawVerified=$true});$prior=$row
 }
 $fallbackName='online-fallback-saved';$fallback=New-RooIndustriesExpectedState $fallbackName $DataRoot $Final.attachmentRefresh[2].SenderActualBytes
 $savedPath=$fallback.model.SavedPath;$savedEntry=Get-RooIndustriesOriginalFile $savedPath
 $semanticPath=Join-Path $UiOutput ($fallbackName+'.semantic.json');$null=Get-RooIndustriesOriginalFile $semanticPath
 $semantic=Read-HarnessInputText $semanticPath|ConvertFrom-Json
 $savedFiles=@($semantic.Evidence|Where-Object {$_.File -ceq $fallbackName+'.zip'});Assert-RooIndustries ($savedFiles.Count -eq 1) 'One immutable fallback saved ZIP required.'
 $savedEvidence=Get-RooIndustriesRefreshEvidence $savedFiles[0] ($fallbackName+'.zip')
 Assert-RooIndustries ((Get-HarnessItem $savedPath).Length -eq $savedEvidence.bytes -and (ConvertTo-RooIndustriesSha256 $savedEntry.identity.hash) -ceq $savedEvidence.sha256) 'Actual fallback saved file differs from immutable raw ZIP.'
 Assert-RooIndustriesRefreshZip $savedEvidence.path ($rawCpu+' | rejected') $true
 $fallbackViews=@($observed.ToArray()|Where-Object {$_.name -ceq $fallbackName});Assert-RooIndustries ($fallbackViews.Count -eq 2 -and $semantic.SenderCalls -eq 3 -and $semantic.Name -ceq $fallbackName) 'Fallback saved scene/call count differs.'
 Assert-RooIndustriesExact $semantic.State $fallback.model 'receipt.State'
 foreach($view in $fallbackViews){
  Assert-RooIndustries ($view.actualOutgoingPath -ceq $path -and $view.actualOutgoingBytes -eq $Final.attachmentRefresh[2].SenderActualBytes -and $view.actualOutgoingSha256 -ceq $Final.attachmentRefresh[2].RetainedSha256) 'Save changed the original retained ZIP.'
  $checkpointPath=Join-Path $CaptureOut ($fallbackName+'-'+$view.view+'-checkpoint.json');$null=Get-RooIndustriesOriginalFile $checkpointPath
  $checkpoint=Read-HarnessInputText $checkpointPath|ConvertFrom-Json
  Assert-RooIndustries ((Get-RooIndustriesFileSha256 $semanticPath) -ceq $checkpoint.receiptSha256) 'Saved semantic receipt differs from immutable checkpoint receipt.'
 }
 $null=Get-RooIndustriesOriginalFile $semanticPath;$null=Get-RooIndustriesOriginalFile $savedPath
 foreach($file in @($savedEvidence.original,$savedEvidence.capture)){$null=Get-RooIndustriesOriginalFile $file.identity.path}
 $fallbackProofPath=Write-HarnessResult $CaptureOut 'attachment-fallback-proof.json' @{sourceCommit=$script:RooIndustriesCommit;uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;saved=$savedEntry;raw=$savedEvidence;cpu=($rawCpu+' | rejected');senderCalls=3;independentRawVerified=$true}
 $proof[3].fallbackProof=Get-RooIndustriesOriginalFile $fallbackProofPath
 return @($proof.ToArray())
}
$owned=$null;$stdout=$null;$stderr=$null;$recorder=$null;$seenIds=New-Object System.Collections.Generic.List[string];$observed=New-Object System.Collections.Generic.List[object];$timer=[Diagnostics.Stopwatch]::StartNew();$done=$false
$frames=Join-Path $CaptureOut 'video-frames';$null=New-HarnessDirectory $frames 'roo70-owned-window-video' 'frame'
try{
 $exe=Join-Path $BuildOut 'desktop\Roo70.RenderedBugReportFixture.exe';$null=Get-RooIndustriesOriginalFile $exe;Assert-HarnessInstallStart $exe
 $start=[Diagnostics.ProcessStartInfo]::new($exe);$start.UseShellExecute=$false;$start.WorkingDirectory=(Join-Path $BuildOut 'desktop');$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Arguments=Join-RooIndustriesWindowsArguments @('--owned-root',$DataRoot,'--nonce',$binding.uiNonce,'--output',$UiOutput)
 Set-RooIndustriesReaderEnvironment $start 'roo70-rendered-ui'
 $owned=Start-OwnedProcess -StartInfo $start -Purpose 'roo70-isolated-rendered-bug-report'
 $stdout=$owned.process.StandardOutput.ReadToEndAsync();$stderr=$owned.process.StandardError.ReadToEndAsync()
 Write-HarnessResult $CaptureOut 'owned-ui.json' @{ledgerId=$owned.LedgerId;identity=$owned.Identity;uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;sourceCommit=$script:RooIndustriesCommit;buildReceiptSha256=(Get-RooIndustriesFileSha256 $buildFile)}|Out-Null
 $recorder=[RooIndustriesTour.Recorder]::new((Get-HarnessLongPath $frames))
 foreach($name in $script:RooIndustriesScenes){
 $topHash=$null
  foreach($view in 'top','bottom'){
   Assert-HarnessHostLease;Assert-RooIndustries ($timer.Elapsed.TotalSeconds -lt 300) 'Total native UI lifetime exceeded five minutes.'
   $deadline=[DateTime]::UtcNow.AddSeconds(20);$checkpoint=$null;$path=Join-Path $UiOutput ($name+'-'+$view+'-checkpoint.json')
   do{
    Assert-RooIndustries (-not$owned.process.HasExited) 'Owned fixture exited before next checkpoint.'
    Assert-RooIndustries (-not(Test-HarnessPath (Join-Path $UiOutput 'failure.json'))) 'Fixture reported failure.'
    if(Test-HarnessPath $path){$candidate=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;if($candidate.name -ceq $name -and $candidate.view -ceq $view -and $seenIds -cnotcontains $candidate.checkpointId){$checkpoint=$candidate;break}}
    Start-Sleep -Milliseconds 40
   }while([DateTime]::UtcNow -lt $deadline)
   Assert-RooIndustries ($null -ne $checkpoint) ('Ordered checkpoint missing: '+$name+'/'+$view)
   Assert-RooIndustries ([RooIndustriesValidationOwnership.Native]::Created($owned.handle).ToString() -ceq $owned.Identity.creationTimeFileTimeUtc) 'Original live process creation changed.'
   $identity=@{Pid=$owned.Identity.pid;Creation=$owned.Identity.creationTimeFileTimeUtc;Hwnd=[string]$checkpoint.windowHandle;Nonce=$binding.uiNonce;Data=$DataRoot}
   $window=[Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new([long]$checkpoint.windowHandle))
   Assert-RooIndustries ($window.Current.ProcessId -eq $owned.Identity.pid -and $window.Current.NativeWindowHandle -eq [long]$checkpoint.windowHandle -and [long]$checkpoint.windowHandle -ne 0) 'HWND/UIA process differs from original owned process.'
   if($observed.Count){Assert-RooIndustries ($checkpoint.windowHandle -ceq $observed[0].windowHandle) 'Fixture changed its bound HWND.'}
   $null=Register-HarnessWindow $window
   $scenario=if($name.StartsWith('offline-')){'offline'}else{'failed'}
   $zip=Join-Path $DataRoot ($scenario+'\reports\outgoing\roo-industries-bug-report-20261021-010203.zip')
   $zipBytes=if($name -in @('offline-empty','online-sent')){0}else{(Get-HarnessItem $zip).Length}
   $zipHash=if($zipBytes){Get-RooIndustriesFileSha256 $zip}else{$null}
   if($name -ceq 'online-sent'){Assert-RooIndustries (-not(Test-HarnessPath $zip)) 'Successful scene still has its outgoing ZIP.'}
   $expected=Assert-RooIndustriesCheckpoint $checkpoint $identity $name $view @($seenIds.ToArray()) $zipBytes
   if($view -ceq 'top'){$topHash=ConvertTo-RooIndustriesSha256 $checkpoint.stateSha256}else{Assert-RooIndustries ((ConvertTo-RooIndustriesSha256 $checkpoint.stateSha256) -ceq $topHash) 'Producer-carried state hash changed during top/bottom navigation.';Assert-RooIndustriesExact $checkpoint.state $expected 'bottom.State'}
   $immutable=Copy-HarnessFile $path (Join-Path $CaptureOut ($name+'-'+$view+'-checkpoint.json')) 'roo70-immutable-checkpoint' 'frame'
   Assert-RooIndustries ([RooIndustriesTour.Desktop]::Focus([IntPtr]::new([long]$checkpoint.windowHandle))) 'Owned window could not receive foreground focus.'
   Assert-RooIndustries ([RooIndustriesTour.Desktop]::VisibleOwner([IntPtr]::new([long]$checkpoint.windowHandle),$owned.Identity.pid)) 'Capture is not foreground owned window.'
   $recorder.Window([IntPtr]::new([long]$checkpoint.windowHandle),$owned.Identity.pid)
   $uia=New-Object System.Collections.Generic.List[object]
   if($view -ceq 'top'){
    foreach($field in @(@('BugDescription','Description'),@('BugContact','Contact'))){$elements=@(Find-RooIndustriesUi $window 'id' $field[0]);Assert-RooIndustries ($elements.Count -eq 1) 'Actual text field missing/ambiguous.';Assert-RooIndustriesVisible $elements[0];$value=$elements[0].GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value;if($field[0] -ceq 'BugDescription'){Assert-RooIndustriesExact $value $expected.model[$field[1]] 'UIA.BugDescription'}else{Assert-RooIndustries ($value -ceq $expected.model[$field[1]]) 'Actual bound text differs.'};$uia.Add(@{id=$field[0];value=$value;visible=$true})}
    $cpu=@(Find-RooIndustriesUi $window 'name' 'Processor'|Where-Object {$_.Current.ControlType -eq [Windows.Automation.ControlType]::Edit});Assert-RooIndustries ($cpu.Count -eq 1) 'Actual Processor binding not exposed uniquely as expected by exact XAML.';Assert-RooIndustriesVisible $cpu[0];$cpuValue=$cpu[0].GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value;Assert-RooIndustries ($cpuValue -ceq $expected.model.Cpu) 'Processor field binding differs.';$uia.Add(@{name=$cpu[0].Current.Name;value=$cpuValue;visible=$true})
   }else{
    $uia.Add((Assert-RooIndustriesButton $window 'BugAttachLogs' $true $expected.model.CanAttach))
    $uia.Add((Assert-RooIndustriesButton $window 'BugSave' $expected.model.ShowSave $expected.model.CanSend))
    $uia.Add((Assert-RooIndustriesButton $window 'BugSend' $expected.model.OnlineAvailable $expected.model.CanSend))
    $uia.Add((Assert-RooIndustriesButton $window 'BugOpenFolder' $expected.model.HasSavedReport $true))
    foreach($field in 'AttachmentText','Status'){if($expected.model[$field].Length){$uia.Add((Assert-RooIndustriesText $window $expected.model[$field]))}}
   }
   Start-Sleep -Milliseconds 1100
   Assert-RooIndustries ([RooIndustriesTour.Desktop]::VisibleOwner([IntPtr]::new([long]$checkpoint.windowHandle),$owned.Identity.pid)) 'Foreground ownership lost before screenshot.'
   $shot=Join-Path $CaptureOut ($name+'-'+$view+'.png');[RooIndustriesTour.Desktop]::Shot([IntPtr]::new([long]$checkpoint.windowHandle),(Get-HarnessLongPath $shot));$shotEntry=Register-HarnessFile $shot 'roo70-rendered-screenshot' 'frame'
   $image=[Drawing.Image]::FromFile((Get-HarnessLongPath $shot));try{$dimensions=@{width=$image.Width;height=$image.Height};Assert-RooIndustries ($image.Width -gt 0 -and $image.Height -gt 0) 'Screenshot dimensions invalid.'}finally{$image.Dispose()}
   Assert-RooIndustries ((Get-RooIndustriesFileSha256 $path) -ceq (ConvertTo-RooIndustriesSha256 $immutable.identity.hash)) 'Checkpoint changed during UIA/capture before ack.'
   $observed.Add(@{name=$name;view=$view;checkpointId=$checkpoint.checkpointId;windowHandle=$checkpoint.windowHandle;pid=$owned.Identity.pid;creation=$owned.Identity.creationTimeFileTimeUtc;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$binding.uiNonce;checkpointSha256=(ConvertTo-RooIndustriesSha256 $immutable.identity.hash);receiptSha256=(ConvertTo-RooIndustriesSha256 $checkpoint.receiptSha256);carriedProducerStateSha256=(ConvertTo-RooIndustriesSha256 $checkpoint.stateSha256);independentAllStateAndSpecsVerified=$true;actualOutgoingPath=$(if($zipBytes){$zip}else{$null});actualOutgoingBytes=$zipBytes;actualOutgoingSha256=$zipHash;screen=$shotEntry;dimensions=$dimensions;uia=@($uia.ToArray())})
   $seenIds.Add($checkpoint.checkpointId)
   Assert-RooIndustries ([DateTime]::UtcNow -lt $deadline) 'Checkpoint UIA/capture exceeded its bounded ack deadline.'
   $null=Publish-RooIndustriesText (Join-Path $UiOutput ('ack-'+$checkpoint.checkpointId+'.json')) (@{schemaVersion=1;nonce=$binding.uiNonce;checkpointId=$checkpoint.checkpointId;action='continue'}|ConvertTo-Json -Compress) 'roo70-checkpoint-ack'
  }
 }
 Assert-RooIndustries ($owned.process.WaitForExit(10000)) 'Owned fixture did not exit after sixteen acknowledgments.'
 $recorder.Dispose();$frameCount=$recorder.Count;$seconds=$recorder.Seconds;$skipped=$recorder.Skipped;$recorder=$null
 Assert-RooIndustries ($frameCount -ge 150 -and $seconds -ge 10 -and @(Get-HarnessChildren $frames -File -Filter 'frame-*.jpg').Count -eq $frameCount) 'Insufficient actual owned-window recording frames/time.'
 $read=Read-RooIndustriesOwnedStreams $owned $stdout $stderr 'roo70-rendered-ui' $CaptureOut
 $text=$read.stdout;$errors=$read.stderr;$exit=$owned.process.ExitCode
 $null=New-HarnessText (Join-Path $CaptureOut 'ui-stdout.log') $text 'roo70-native-output' 'frame';$null=New-HarnessText (Join-Path $CaptureOut 'ui-stderr.log') $errors 'roo70-native-output' 'frame'
 Assert-RooIndustries ($exit -eq 0 -and -not(Test-HarnessPath (Join-Path $UiOutput 'failure.json'))) 'WinUI native failure or nonzero exit.'
 $null=Register-RooIndustriesTree $UiOutput 'roo70-native-raw-proof';$null=Register-RooIndustriesTree $DataRoot 'roo70-native-report-file'
 $finalPath=Join-Path $UiOutput 'final-result.json';$null=Get-RooIndustriesOriginalFile $finalPath
 $finalEntry=Copy-HarnessFile $finalPath (Join-Path $CaptureOut 'final-result.json') 'roo70-native-final' 'frame'
 $null=Get-RooIndustriesOriginalFile $finalEntry.identity.path;$final=Read-HarnessInputText $finalEntry.identity.path|ConvertFrom-Json
 Assert-RooIndustries ($final.schemaVersion -eq 1 -and $final.sourceCommit -ceq $script:RooIndustriesCommit -and $final.Nonce -ceq $binding.uiNonce -and $final.native -eq $true -and $final.productionStartupProved -eq $false -and $final.positiveMarker -ceq 'ROO_INDUSTRIES_BUG_REPORT_RENDERED_8COMPLETE' -and ($final.seen -join ',') -ceq ($script:RooIndustriesScenes -join ',') -and $observed.Count -eq 16) 'No exact eight-scene native completion.'
 Assert-RooIndustries ($final.fixturePid -eq $owned.Identity.pid -and [string]$final.creationTimeFileTimeUtc -ceq $owned.Identity.creationTimeFileTimeUtc -and [string]$final.windowHandle -ceq $observed[0].windowHandle) 'Final refresh evidence lost original process/HWND binding.'
 Assert-RooIndustries (@(Get-HarnessChildren $UiOutput -File -Filter '*-checkpoint.json').Count -eq 16 -and @(Get-HarnessChildren $UiOutput -File -Filter 'ack-*.json').Count -eq 16 -and @($seenIds.ToArray()|Sort-Object -Unique).Count -eq 16) 'Exactly sixteen unique actual checkpoint/ack pairs required.'
 foreach($checkpointId in $seenIds.ToArray()){
  $ackPath=Join-Path $UiOutput ('ack-'+$checkpointId+'.json');$null=Get-RooIndustriesOriginalFile $ackPath
  Assert-RooIndustriesExact (Read-HarnessInputText $ackPath|ConvertFrom-Json) @{schemaVersion=1;nonce=$binding.uiNonce;checkpointId=$checkpointId;action='continue'} 'ack'
 }
 $refreshProof=@(Assert-RooIndustriesAttachmentRefresh $final)
 $null=Get-RooIndustriesOriginalFile $finalPath;$null=Get-RooIndustriesOriginalFile $finalEntry.identity.path
 $movie=Join-Path $CaptureOut 'bug-report-interaction.mp4'
 $video=Invoke-RooIndustriesOwnedCommand $ffmpeg.Source @('-n','-framerate','15','-i',(Join-Path $frames 'frame-%07d.jpg'),'-vf','pad=ceil(iw/2)*2:ceil(ih/2)*2','-c:v','libx264','-pix_fmt','yuv420p','-t','10',$movie) $CaptureOut $CaptureOut 'roo70-encode-video' 60
 Assert-RooIndustries ((Get-HarnessItem $movie).Length -gt 0) 'Encoded interaction video missing.'
 $movieEntry=Register-HarnessFile $movie 'roo70-owned-ui-video' 'frame'
 $metadata=Invoke-RooIndustriesOwnedCommand $ffmpeg.Source @('-v','info','-i',$movie,'-f','null','-') $CaptureOut $CaptureOut 'roo70-video-metadata' 30
 Assert-RooIndustries ($metadata.stderr -match 'Duration: 00:00:10\.' -and $metadata.stderr -match 'Video: h264' -and $metadata.stderr -match 'yuv420p') 'Actual encoded video metadata differs.'
 Assert-RooIndustries (@(Get-HarnessChildren $CaptureOut -File -Filter '*.png').Count -eq 16) 'Exactly sixteen actual screenshots required.'
 $null=Register-RooIndustriesTree $frames 'roo70-actual-video-frame'
 Write-HarnessResult $CaptureOut 'rendered-proof.json' @{readerAdverse=$read.readerAdverse;sourceCommit=$script:RooIndustriesCommit;binaryFiles=$build.files;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;nativeExit=$exit;checkpoints=@($observed.ToArray());nativeFinal=$finalEntry;attachmentRefreshMarker=$final.attachmentRefreshMarker;attachmentRefresh=$refreshProof;fallbackProof=$refreshProof[3].fallbackProof;movie=$movieEntry;actualFrames=$frameCount;actualSeconds=$seconds;skipped=$skipped;actualNative=$true;productionStartupProved=$false;leadAndSolVision='PENDING';stateHash='carried producer hash; all model/spec fields independently compared, not PS reserialized'}|Out-Null
 $done=$true
}catch{
 Write-HarnessResult $CaptureOut 'rendered-failure.json' @{error=$_.Exception.ToString();stack=$_.ScriptStackTrace;sourceCommit=$script:RooIndustriesCommit;observed=@($observed.ToArray())}|Out-Null
 throw
}finally{
 try{if($recorder){$recorder.Dispose()}}finally{
  if($owned){
   Stop-OwnedProcess $owned
   Assert-RooIndustries ($owned.process.WaitForExit(5000)) 'Original owned UI process failed to end.'
   Set-HarnessEntryState $owned.LedgerId 'absent'
   foreach($stream in @(@($stdout,'stdout'),@($stderr,'stderr'))){$logPath=Join-Path $CaptureOut ('ui-'+$stream[1]+'.log');if($stream[0] -and $stream[0].Wait(3000) -and -not(Test-HarnessPath $logPath)){$null=New-HarnessText $logPath ($stream[0].GetAwaiter().GetResult()) 'roo70-retained-ui-output' 'frame'}}
  }
 }
 foreach($root in @($DataRoot,$UiOutput,$CaptureOut)){if(Test-HarnessPath $root){$null=Register-RooIndustriesTree $root 'roo70-retained-native-resource'}}
 Write-HarnessResult $OutRoot 'rendered-phase-end.json' @{completed=$done;sourceCommit=$script:RooIndustriesCommit;observed=@($observed.ToArray());processEnded=($null -eq $owned -or $owned.process.HasExited);vision='PENDING'}|Out-Null
 $null=Assert-RooIndustriesSource $Source;Assert-HarnessHostLease
}
