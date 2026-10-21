$script:RooIndustriesScenes=@('offline-empty','offline-attached','offline-saved','online-failed','online-fallback-saved','online-sent')
function Assert-RooIndustries([bool]$Ok,[string]$Message){if(-not$Ok){throw $Message}}
function ConvertTo-RooIndustriesSha256([string]$Value){
 Assert-RooIndustries ($Value -cmatch '^[a-fA-F0-9]{64}$') 'SHA256 must contain exactly 64 hexadecimal characters.'
 return $Value.ToLowerInvariant()
}
function Get-RooIndustriesFileSha256([string]$Path){
 return ConvertTo-RooIndustriesSha256 (Get-HarnessFileSha256 $Path)
}
function Get-RooIndustriesStringHash([string]$Value){$sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Assert-RooIndustriesRelative([string]$Name){Assert-RooIndustries ($Name -cmatch '^[A-Za-z0-9_./ -]+$' -and $Name -notmatch '(^|/)\.{1,2}(/|$)' -and -not$Name.StartsWith('/')) 'Relative input path is unsafe.'}
function Test-RooIndustriesBelow([string]$Path,[string]$Parent){
 if($Path -notmatch '^C:\\' -or $Path.Substring(2) -match '[:/]' -or $Path -match '(^|\\)\.{1,2}(\\|$)'){return $false}
 return $Path.StartsWith($Parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-RooIndustriesBinding([string]$Frame,[string]$FrameId,[string]$InvocationNonce,[string]$ReceiptFrameId,[string]$Data,[string]$Output,[string]$Capture,[int]$DataCount,[int]$OutputCount){
 Assert-RooIndustries ($FrameId -cmatch '^[0-9a-f]{32}$' -and $InvocationNonce -cmatch '^[0-9a-f]{32}$' -and $FrameId -ceq $ReceiptFrameId) 'Original frame/invocation nonce binding failed.'
 Assert-RooIndustries ($Frame -cmatch '^C:\\RooBuild\\roo-industries-[^\\/]+$' -and $Frame.EndsWith('-'+$FrameId,[StringComparison]::Ordinal)) 'UI nonce must equal original frame suffix.'
 foreach($path in @($Data,$Output,$Capture)){Assert-RooIndustries (Test-RooIndustriesBelow $path $Frame) 'UI/capture path escaped its original frame.'}
 foreach($pair in @(@($Data,$Output),@($Data,$Capture),@($Output,$Capture))){Assert-RooIndustries ($pair[0] -ine $pair[1] -and -not(Test-RooIndustriesBelow $pair[0] $pair[1]) -and -not(Test-RooIndustriesBelow $pair[1] $pair[0])) 'UI and capture leaves must be disjoint.'}
 Assert-RooIndustries ($DataCount -eq 0 -and $OutputCount -eq 0) 'UI input/output must remain empty until app validation.'
}
function Assert-RooIndustriesFileBinding([string]$Relative,[string]$Expected,[string]$Actual,[string]$LedgerHash,[int]$LedgerCount){
 Assert-RooIndustriesRelative $Relative
 Assert-RooIndustries ((ConvertTo-RooIndustriesSha256 $Expected) -ceq (ConvertTo-RooIndustriesSha256 $Actual) -and (ConvertTo-RooIndustriesSha256 $Expected) -ceq (ConvertTo-RooIndustriesSha256 $LedgerHash) -and $LedgerCount -eq 1) ('Original file identity/hash mismatch: '+$Relative)
}
function Assert-RooIndustriesSourceBinding([string]$Commit,[string]$FrameId,[string]$ExpectedFrameId,[string]$Hash,[string]$ExpectedHash){
 Assert-RooIndustries ($Commit -ceq $script:RooIndustriesCommit -and $FrameId -ceq $ExpectedFrameId -and (ConvertTo-RooIndustriesSha256 $Hash) -ceq (ConvertTo-RooIndustriesSha256 $ExpectedHash)) 'Original source commit/frame/manifest hash differs.'
}
function Get-RooIndustriesProperties($Value){if($Value -is [Collections.IDictionary]){return @($Value.Keys)};return @($Value.PSObject.Properties.Name)}
function Assert-RooIndustriesExact($Actual,$Expected,[string]$Field){
 if($null -eq $Expected){Assert-RooIndustries ($null -eq $Actual) ($Field+' must be null.');return}
 if($Expected -is [Collections.IDictionary]){
  $keys=@(Get-RooIndustriesProperties $Actual);Assert-RooIndustries ($keys.Count -eq $Expected.Count) ($Field+' field count differs.')
  foreach($key in $Expected.Keys){Assert-RooIndustries ($keys -ccontains $key) ($Field+' missing '+$key);Assert-RooIndustriesExact $Actual.$key $Expected[$key] ($Field+'.'+$key)};return
 }
 if($Expected -is [array]){Assert-RooIndustries (@($Actual).Count -eq $Expected.Count) ($Field+' item count differs.');for($i=0;$i -lt $Expected.Count;$i++){Assert-RooIndustriesExact $Actual[$i] $Expected[$i] ($Field+'['+$i+']')};return}
 if($Expected -is [bool]){Assert-RooIndustries ($Actual -is [bool] -and $Actual -eq $Expected) ($Field+' boolean differs.');return}
 if($Field -cin @('State.model.Description','receipt.State.Description','bottom.State.model.Description','UIA.BugDescription')){
  Assert-RooIndustries ($Actual -is [string] -and $Expected -is [string]) ($Field+' must be text.')
  Assert-RooIndustries ($Actual.Replace("`r`n","`n").Replace("`r","`n") -ceq $Expected.Replace("`r`n","`n").Replace("`r","`n")) ($Field+' differs.')
  return
 }
 Assert-RooIndustries ($null -ne $Actual -and [string]$Actual -ceq [string]$Expected) ($Field+' differs.')
}
function New-RooIndustriesExpectedState([string]$Name,[string]$Data,[long]$AttachedBytes){
 Assert-RooIndustries ($script:RooIndustriesScenes -ccontains $Name) 'Unknown scene.'
 $raw='C:\Users\'+"Zqx Bob O'Neil\AppData\x.log";$forward='C:/Users/'+'Zqxbob/AppData/x.log';$r9='C:/Users/\u003Cuser\u003E%USERPROFILE%\u003Cuser\u003EZqxbob/x'
 $empty=$Name -ceq 'offline-empty';$sent=$Name -ceq 'online-sent';$online=$Name.StartsWith('online-');$saved=$Name -in @('offline-saved','online-fallback-saved')
 $zip='roo-industries-bug-report-20261021-010203.zip';$savedName='roo-industries-bug-report-20261021-010203-saved-010203.zip'
 $scenario=if(-not$online){'offline'}elseif($sent){'sent'}else{'failed'}
 $path=$null;if($saved){$path=$Data+'\'+$scenario+'\reports\saved\'+$savedName}
 $bytes=[double]$AttachedBytes;$unit=0;$units=@('B','KB','MB','GB','TB');while($bytes -ge 1024 -and $unit -lt 4){$bytes/=1024;$unit++}
 $size=$bytes.ToString($(if($unit -ge 3){'0.0'}else{'0'}),[Globalization.CultureInfo]::InvariantCulture)+' '+$units[$unit]
 $attachment=if($empty -or $sent){'No logs attached yet.'}else{'Attached '+$zip+' ('+$size+')'}
 $status=if($saved){'Saved '+$savedName+'. Select Open folder, then send that file to the developers.'}elseif($Name -ceq 'online-failed'){"The report couldn't be delivered. Try again later, or save the report to a file and send it yourself."}elseif($sent){'Thanks! Your report was sent to the developers.'}else{''}
 $cpu=if($empty){'Fixture CPU'}else{$raw}
 $model=@{OnlineAvailable=$online;OfflineOnly=(-not$online);Busy=$false;LoadingSpecs=$false;CanAttach=$true;CanSend=(-not($empty -or $sent));ShowSave=(-not$sent);HasSavedReport=$saved;SavedPath=$path;Description=$(if($empty -or $sent){''}else{$raw+"`n"+$forward+"`n"+$r9});Contact=$(if($empty -or $sent){''}else{'retain-contact@example.com'});AttachmentText=$attachment;Status=$status;Cpu=$cpu;SpecCount=9}
 $specs=@(@{Key='windows';Label='Windows';Value='Fixture Windows'},@{Key='cpu';Label='Processor';Value=$cpu},@{Key='gpu';Label='Graphics and driver';Value='Unknown'},@{Key='ram';Label='Memory';Value='Unknown'},@{Key='motherboard';Label='Motherboard';Value='Unknown'},@{Key='bios';Label='BIOS version';Value='Unknown'},@{Key='drive';Label='System drive';Value='Unknown'},@{Key='display';Label='Main display';Value='Unknown'},@{Key='app';Label='App version';Value='0.10.0-beta fixture'})
 return @{model=$model;specs=$specs}
}
function Assert-RooIndustriesCheckpoint($Checkpoint,$Identity,[string]$Name,[string]$View,[string[]]$Seen,[long]$AttachedBytes){
 Assert-RooIndustries ($Checkpoint.schemaVersion -eq 1 -and $Checkpoint.native -is [bool] -and $Checkpoint.native -and $Checkpoint.sourceCommit -ceq $script:RooIndustriesCommit -and $Checkpoint.Nonce -ceq $Identity.Nonce -and $Checkpoint.positiveMarker -ceq 'ROO70_RENDERED_BUG_REPORT_CHECKPOINT') 'Checkpoint source/nonce/schema/marker differs.'
 Assert-RooIndustries ($Checkpoint.fixturePid -eq $Identity.Pid -and [string]$Checkpoint.creationTimeFileTimeUtc -ceq $Identity.Creation -and [string]$Checkpoint.windowHandle -ceq $Identity.Hwnd) 'Checkpoint PID/creation/HWND differs.'
 Assert-RooIndustries ($Checkpoint.checkpointId -cmatch '^[a-f0-9]{32}$' -and $Seen -cnotcontains $Checkpoint.checkpointId -and $Checkpoint.name -ceq $Name -and $Checkpoint.view -ceq $View) 'Checkpoint order/ID replay differs.'
 Assert-RooIndustries ((Get-RooIndustriesStringHash $Checkpoint.receipt) -ceq (ConvertTo-RooIndustriesSha256 $Checkpoint.receiptSha256) -and $Checkpoint.stateSha256 -cmatch '^[a-f0-9]{64}$') 'Checkpoint receipt/state hash differs.'
 $expected=New-RooIndustriesExpectedState $Name $Identity.Data $AttachedBytes
 Assert-RooIndustriesExact $Checkpoint.state $expected 'State'
 foreach($value in @($Checkpoint.state.model.Description,$Checkpoint.state.model.Contact,$Checkpoint.state.model.Cpu,$Checkpoint.state.model.AttachmentText,$Checkpoint.state.model.Status)){Assert-RooIndustriesScalars $value}
 $receipt=$Checkpoint.receipt|ConvertFrom-Json
 Assert-RooIndustries ($receipt.Name -ceq $Name -and $receipt.SenderCalls -eq $(if($Name.StartsWith('online-')){1}else{0}) -and $receipt.Scope -ceq 'Native planned: exact XAML/page handlers via ButtonAutomationPeer; VM input seeding is not UIA typing; isolated bootstrap') 'Receipt scene/sender/scope differs.'
 Assert-RooIndustriesExact $receipt.State $expected.model 'receipt.State'
 foreach($file in @($receipt.Evidence)){Assert-RooIndustries ($file.Sha256 -cmatch '^[a-f0-9]{64}$' -and $file.Bytes -gt 0) 'Invalid evidence file hash/size.'}
 if($View -ceq 'top'){Assert-RooIndustries ($Checkpoint.scrollOffset -eq 0) 'Top scroll is not zero.'}else{Assert-RooIndustries ($Checkpoint.scrollableHeight -gt 0 -and $Checkpoint.scrollOffset -gt 0 -and [Math]::Abs($Checkpoint.scrollOffset-$Checkpoint.scrollableHeight) -lt 2) 'Bottom scroll is not bounded at bottom.'}
 return $expected
}
function Assert-RooIndustriesScalars([string]$Value){
 for($i=0;$i -lt $Value.Length;$i++){
  if([char]::IsHighSurrogate($Value[$i])){Assert-RooIndustries ($i+1 -lt $Value.Length -and [char]::IsLowSurrogate($Value[$i+1])) 'Unpaired high surrogate.';$i++}
  elseif([char]::IsLowSurrogate($Value[$i])){throw 'Unpaired low surrogate.'}
 }
}
