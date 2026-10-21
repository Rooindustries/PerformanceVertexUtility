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
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms,WindowsBase
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
   $scenario=if($name.StartsWith('offline-')){'offline'}elseif($name -ceq 'online-sent'){'sent'}else{'failed'}
   $zip=Join-Path $DataRoot ($scenario+'\reports\outgoing\roo-industries-bug-report-20261021-010203.zip')
   $zipBytes=if($name -in @('offline-empty','online-sent')){0}else{(Get-HarnessItem $zip).Length}
   $expected=Assert-RooIndustriesCheckpoint $checkpoint $identity $name $view @($seenIds.ToArray()) $zipBytes
   if($view -ceq 'top'){$topHash=ConvertTo-RooIndustriesSha256 $checkpoint.stateSha256}else{Assert-RooIndustries ((ConvertTo-RooIndustriesSha256 $checkpoint.stateSha256) -ceq $topHash) 'Producer-carried state hash changed during top/bottom navigation.';Assert-RooIndustriesExact $checkpoint.state $expected 'bottom.State'}
   $immutable=Copy-HarnessFile $path (Join-Path $CaptureOut ($name+'-'+$view+'-checkpoint.json')) 'roo70-immutable-checkpoint' 'frame'
   Assert-RooIndustries ([RooIndustriesTour.Desktop]::Focus([IntPtr]::new([long]$checkpoint.windowHandle))) 'Owned window could not receive foreground focus.'
   Assert-RooIndustries ([RooIndustriesTour.Desktop]::VisibleOwner([IntPtr]::new([long]$checkpoint.windowHandle),$owned.Identity.pid)) 'Capture is not foreground owned window.'
   $recorder.Window([IntPtr]::new([long]$checkpoint.windowHandle),$owned.Identity.pid)
   $uia=New-Object System.Collections.Generic.List[object]
   if($view -ceq 'top'){
    foreach($field in @(@('BugDescription','Description'),@('BugContact','Contact'))){$elements=@(Find-RooIndustriesUi $window 'id' $field[0]);Assert-RooIndustries ($elements.Count -eq 1) 'Actual text field missing/ambiguous.';Assert-RooIndustriesVisible $elements[0];$value=$elements[0].GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value;Assert-RooIndustries ($value -ceq $expected.model[$field[1]]) 'Actual bound text differs.';$uia.Add(@{id=$field[0];value=$value;visible=$true})}
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
   $observed.Add(@{name=$name;view=$view;checkpointId=$checkpoint.checkpointId;windowHandle=$checkpoint.windowHandle;pid=$owned.Identity.pid;creation=$owned.Identity.creationTimeFileTimeUtc;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$binding.uiNonce;checkpointSha256=(ConvertTo-RooIndustriesSha256 $immutable.identity.hash);receiptSha256=(ConvertTo-RooIndustriesSha256 $checkpoint.receiptSha256);carriedProducerStateSha256=(ConvertTo-RooIndustriesSha256 $checkpoint.stateSha256);independentAllStateAndSpecsVerified=$true;screen=$shotEntry;dimensions=$dimensions;uia=@($uia.ToArray())})
   $seenIds.Add($checkpoint.checkpointId)
   Assert-RooIndustries ([DateTime]::UtcNow -lt $deadline) 'Checkpoint UIA/capture exceeded its bounded ack deadline.'
   $null=Publish-RooIndustriesText (Join-Path $UiOutput ('ack-'+$checkpoint.checkpointId+'.json')) (@{schemaVersion=1;nonce=$binding.uiNonce;checkpointId=$checkpoint.checkpointId;action='continue'}|ConvertTo-Json -Compress) 'roo70-checkpoint-ack'
  }
 }
 Assert-RooIndustries ($owned.process.WaitForExit(10000)) 'Owned fixture did not exit after twelve acknowledgments.'
 $recorder.Dispose();$frameCount=$recorder.Count;$seconds=$recorder.Seconds;$skipped=$recorder.Skipped;$recorder=$null
 Assert-RooIndustries ($frameCount -ge 150 -and $seconds -ge 10 -and @(Get-HarnessChildren $frames -File -Filter 'frame-*.jpg').Count -eq $frameCount) 'Insufficient actual owned-window recording frames/time.'
 $read=Read-RooIndustriesOwnedStreams $owned $stdout $stderr 'roo70-rendered-ui' $CaptureOut
 $text=$read.stdout;$errors=$read.stderr;$exit=$owned.process.ExitCode
 $null=New-HarnessText (Join-Path $CaptureOut 'ui-stdout.log') $text 'roo70-native-output' 'frame';$null=New-HarnessText (Join-Path $CaptureOut 'ui-stderr.log') $errors 'roo70-native-output' 'frame'
 Assert-RooIndustries ($exit -eq 0 -and -not(Test-HarnessPath (Join-Path $UiOutput 'failure.json'))) 'WinUI native failure or nonzero exit.'
 $finalPath=Join-Path $UiOutput 'final-result.json';$final=Get-Content -LiteralPath $finalPath -Raw|ConvertFrom-Json
 Assert-RooIndustries ($final.schemaVersion -eq 1 -and $final.sourceCommit -ceq $script:RooIndustriesCommit -and $final.Nonce -ceq $binding.uiNonce -and $final.native -eq $true -and $final.productionStartupProved -eq $false -and $final.positiveMarker -ceq 'ROO_INDUSTRIES_BUG_REPORT_RENDERED_6COMPLETE' -and ($final.seen -join ',') -ceq ($script:RooIndustriesScenes -join ',') -and $observed.Count -eq 12) 'No exact six-scene native completion.'
 Assert-RooIndustries (@(Get-HarnessChildren $UiOutput -File -Filter '*-checkpoint.json').Count -eq 12) 'Exactly twelve actual checkpoint files required.'
 $null=Copy-HarnessFile $finalPath (Join-Path $CaptureOut 'final-result.json') 'roo70-native-final' 'frame'
 $movie=Join-Path $CaptureOut 'bug-report-interaction.mp4'
 $video=Invoke-RooIndustriesOwnedCommand $ffmpeg.Source @('-n','-framerate','15','-i',(Join-Path $frames 'frame-%07d.jpg'),'-vf','pad=ceil(iw/2)*2:ceil(ih/2)*2','-c:v','libx264','-pix_fmt','yuv420p','-t','10',$movie) $CaptureOut $CaptureOut 'roo70-encode-video' 60
 Assert-RooIndustries ((Get-HarnessItem $movie).Length -gt 0) 'Encoded interaction video missing.'
 $movieEntry=Register-HarnessFile $movie 'roo70-owned-ui-video' 'frame'
 $metadata=Invoke-RooIndustriesOwnedCommand $ffmpeg.Source @('-v','info','-i',$movie,'-f','null','-') $CaptureOut $CaptureOut 'roo70-video-metadata' 30
 Assert-RooIndustries ($metadata.stderr -match 'Duration: 00:00:10\.' -and $metadata.stderr -match 'Video: h264' -and $metadata.stderr -match 'yuv420p') 'Actual encoded video metadata differs.'
 Assert-RooIndustries (@(Get-HarnessChildren $CaptureOut -File -Filter '*.png').Count -eq 12) 'Exactly twelve actual screenshots required.'
 $null=Register-RooIndustriesTree $frames 'roo70-actual-video-frame'
 Write-HarnessResult $CaptureOut 'rendered-proof.json' @{readerAdverse=$read.readerAdverse;sourceCommit=$script:RooIndustriesCommit;binaryFiles=$build.files;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;nativeExit=$exit;checkpoints=@($observed.ToArray());movie=$movieEntry;actualFrames=$frameCount;actualSeconds=$seconds;skipped=$skipped;actualNative=$true;productionStartupProved=$false;leadAndSolVision='PENDING';stateHash='carried producer hash; all model/spec fields independently compared, not PS reserialized'}|Out-Null
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
