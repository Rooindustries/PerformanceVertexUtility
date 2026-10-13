param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$Sha256,[Parameter(Mandatory)][string]$ExpectedVersion,[int]$HoldSeconds=4)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Memory\Memory.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'app-tour' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms,WindowsBase
Add-Type -Path (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Tour\TourCapture.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms
[RooTour.Desktop]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$exe=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
$script:shots=[Collections.Generic.List[object]]::new();$script:actions=[Collections.Generic.List[object]]::new();$script:missing=[Collections.Generic.List[object]]::new();$script:window=$null;$script:recorder=$null;$script:screenNumber=0
$directory=Join-Path $OutRoot ('capture-'+$nonce);New-HarnessDirectory $directory 'tour-media'|Out-Null
$script:installDir=Join-Path $directory 'installer';$script:screensDir=Join-Path $directory 'screens';New-HarnessDirectory $script:installDir 'installer-screens'|Out-Null;New-HarnessDirectory $script:screensDir 'app-screens'|Out-Null
function FindId([string]$id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function FindName([string]$name,$type){$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$type)))}
function WizardButton([string]$name){@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$name))|Where-Object {$_.Current.ClassName -in 'TNewButton','Button' -and -not$_.Current.IsOffscreen})|Select-Object -First 1}
function WaitFor([scriptblock]$test,[int]$seconds,[string]$label){$limit=[DateTime]::UtcNow.AddSeconds($seconds);do{$answer=& $test;if($answer){return $answer};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $limit);throw ('Timed out: '+$label)}
function WindowTree{ @($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;type=$_.Current.ControlType.ProgrammaticName;class=$_.Current.ClassName;offscreen=$_.Current.IsOffscreen;enabled=$_.Current.IsEnabled;bounds=$_.Current.BoundingRectangle.ToString()}}) }
function AttachWindow($win){$script:window=Register-HarnessWindow $win;[RooTour.Desktop]::Focus([IntPtr]$win.Current.NativeWindowHandle)|Out-Null;if($script:recorder){$script:recorder.Window([IntPtr]$win.Current.NativeWindowHandle,[int]$win.Current.ProcessId)}}
function StartMovie([string]$name){$folder=Join-Path $directory $name;New-HarnessDirectory $folder 'tour-video-frames'|Out-Null;$script:recorder=[RooTour.Recorder]::new((Get-HarnessLongPath $folder));return $folder}
function StopMovie{$script:recorder.Dispose();$info=@{frames=$script:recorder.Count;skippedTicks=$script:recorder.Skipped;wallSeconds=$script:recorder.Seconds;fps=15};$script:recorder=$null;return $info}
function Shot([string]$pass,[string]$page,[string]$tab,[int]$part=0){
 $tab=$tab.Substring(0,[Math]::Min(90,$tab.Length));$script:screenNumber++;$name=$pass+'-'+('{0:D3}'-f$script:screenNumber)+'-'+$page+'-'+$tab+$(if($part){'-part'+$part}else{''})+'.png'
 $folder=if($pass -eq 'installer'){$script:installDir}else{$script:screensDir};$path=Join-Path $folder $name
 $hwnd=[IntPtr]$script:window.Current.NativeWindowHandle
 if(-not[RooTour.Desktop]::VisibleOwner($hwnd,[int]$script:window.Current.ProcessId)){throw ('Capture window is covered; expected PID '+$script:window.Current.ProcessId+', foreground PID '+[RooTour.Desktop]::ForegroundPid()+', title '+$script:window.Current.Name+', offscreen '+$script:window.Current.IsOffscreen)}
 [RooTour.Desktop]::Shot($hwnd,(Get-HarnessLongPath $path));$bounds=[RooTour.Desktop]::Bounds($hwnd)
 $script:shots.Add(@{file=$name;pass=$pass;page=$page;tab=$tab;part=$part;path=$path;sha256=Get-HarnessFileSha256 $path;width=$bounds.Width;height=$bounds.Height;bounds=$bounds;timeUtc=[DateTime]::UtcNow.ToString('o')})
 Write-HarnessResult $directory ($name+'.uia.json') @{screen=$name;elements=@(WindowTree)}|Out-Null
 Write-Output ('SCREEN '+$name)
}
function MouseAction($element,[string]$kind){
 if(-not$element -or $element.Current.IsOffscreen -or -not$element.Current.IsEnabled){throw ('Allowed target unavailable: '+$kind)}
 $allowed=$false;$id=$element.Current.AutomationId;$name=$element.Current.Name
 switch($kind){
  'navigation' {$allowed=$element.Current.ControlType -eq $CT::ListItem -and $name -in 'Home','Games','Remove apps','Graphics drivers','Windows tweaks','Tools','Undo changes','Report a bug','Settings','Startup & services','Memory','Timer & cache'}
  'tab' {$allowed=$id -in 'GamesTab','ProcessesTab','BackgroundTab','RemovalTab','LeftoversTab'}
  'section' {$allowed=$element.Current.ControlType -eq $CT::ListItem -and (FindId 'WindowsTweakSections')}
  'simple' {$allowed=$id -eq 'SimpleModeToggle'}
  'theme' {$allowed=$id -eq 'ThemePicker'}
  'theme-choice' {$allowed=$name -in 'Roo Industries Blue','Blackout Gold'}
  'firmware' {$allowed=$id -eq 'OpenFirmware'}
  'back' {$allowed=$name -eq '← Tools'}
  'expander' {$allowed=$element.Current.ClassName -eq 'Expander'}
  'wizard' {$allowed=$name -in 'Next >','Next','Install','Finish','Run','Yes','OK' -and $script:window.Current.ClassName -in 'TWizardForm','#32770'}
 }
 if($kind -in 'simple','theme','theme-choice','wizard'){Assert-HarnessHostLease}
 if(-not$allowed){throw ('Action refused by tour whitelist: '+$kind+' '+$id+' '+$name)}
 $r=$element.Current.BoundingRectangle;$record=@{kind=$kind;id=$id;name=$name;timeUtc=[DateTime]::UtcNow.ToString('o');bounds=$r.ToString();method='cursor';verified=$false;checks=@()}
 foreach($fraction in @(.5,.25,.75)){
  $x=[int]($r.Left+$r.Width*$fraction);$y=[int]($r.Top+$r.Height*.5);[RooTour.Desktop]::Move($x,$y)
  $hit=$A::FromPoint([Windows.Point]::new($x,$y));$match=$hit.Current.ProcessId -eq $element.Current.ProcessId -and (($id -and $hit.Current.AutomationId -ceq $id) -or ($name -and $hit.Current.Name -ceq $name))
  $record.checks+=@(@{x=$x;y=$y;name=$hit.Current.Name;id=$hit.Current.AutomationId;pid=$hit.Current.ProcessId;matched=$match})
  if($match){$record.verified=$true;[RooTour.Desktop]::Click();break}
 }
 if(-not$record.verified){if($kind -eq 'navigation'){$element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();$record.method='SelectionItemPattern.Select fallback'}else{$script:actions.Add($record);throw ('Cursor target verification failed: '+$kind+' '+$name)}}
 $script:actions.Add($record);Start-Sleep -Milliseconds 250
}
function Nav([string]$name){MouseAction (WaitFor {FindName $name $CT::ListItem} 20 ('nav '+$name)) navigation;Start-Sleep -Seconds 2}
function Tab([string]$id){$item=FindId $id;if(-not$item -or $item.Current.IsOffscreen){$script:missing.Add(@{pass=$script:pass;state=$id;reason='The app hides this tab in this mode.'});return $false};MouseAction $item tab;WaitFor {(FindId $id).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected} 10 ('tab '+$id)|Out-Null;Start-Sleep -Seconds 2;return $true}
function ScrollPage{
 $frame=[RooTour.Desktop]::Bounds([IntPtr]$script:window.Current.NativeWindowHandle)
 $candidates=@(foreach($item in $script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)){
  if($item.Current.IsOffscreen){continue};$r=$item.Current.BoundingRectangle
  if($r.Left -lt $frame.Left+220 -or $r.Width -lt 400 -or $r.Height -lt 180){continue}
  $pattern=$null;if($item.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern,[ref]$pattern)){
   if($pattern.Current.VerticallyScrollable){[pscustomobject]@{element=$item;pattern=$pattern;area=$r.Width*$r.Height;class=$item.Current.ClassName}}
  }
 });return $candidates|Sort-Object @{Expression={if($_.class -eq 'ScrollViewer'){1}else{0}};Descending=$true},@{Expression='area';Descending=$true}|Select-Object -First 1
}
function SetScroll($scroll,[double]$to){$from=$scroll.pattern.Current.VerticalScrollPercent;for($i=1;$i -le 12;$i++){$scroll.pattern.SetScrollPercent(-1,($from+($to-$from)*$i/12));Start-Sleep -Milliseconds 80};Start-Sleep -Milliseconds 400}
function CapturePage([string]$page,[string]$tab='main'){
 $scroll=ScrollPage;if($scroll){SetScroll $scroll 0}
 Start-Sleep -Seconds $HoldSeconds
 if($script:pass -eq 'C' -or -not$scroll){Shot $script:pass $page $tab;return}
 $part=1;Shot $script:pass $page $tab $part
 for($guard=0;$guard -lt 40 -and $scroll.pattern.Current.VerticalScrollPercent -lt 99.8;$guard++){
  $current=$scroll.pattern.Current.VerticalScrollPercent;$view=$scroll.pattern.Current.VerticalViewSize;$step=if($view -ge 100){100}else{80*$view/(100-$view)};$next=[Math]::Min(100,$current+[Math]::Max(2,$step))
  SetScroll $scroll $next;Start-Sleep -Seconds $HoldSeconds;$part++;Shot $script:pass $page $tab $part
  if($scroll.pattern.Current.VerticalScrollPercent -le $current){throw 'Page scroll made no progress.'}
 }
 if($scroll.pattern.Current.VerticalScrollPercent -lt 99.8){throw 'Page scroll did not reach the bottom.'}
 SetScroll $scroll 0
}
function FitApp{
 $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
 if($area.Width -lt 1600 -or $area.Height -lt 1000){throw ('Desktop working area cannot contain 1600x1000: '+$area)}
 [RooTour.Desktop]::Center([IntPtr]$script:window.Current.NativeWindowHandle,1600,1000,($area.Left+[int](($area.Width-1600)/2)),($area.Top+[int](($area.Height-1000)/2)))
}
function Simple([bool]$value){Nav Settings;$toggle=FindId 'SimpleModeToggle';$old=$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On;if($old -ne $value){MouseAction $toggle simple;WaitFor {((FindId 'SimpleModeToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On) -eq $value} 10 'simple mode'|Out-Null}}
function Theme([string]$value){
 Nav Settings;$picker=FindId 'ThemePicker';$selected=$picker.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name
 if($selected -ceq $value){return}
 MouseAction $picker theme
 $choice=WaitFor {$A::RootElement.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$value),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 10 ('theme '+$value)
 if($choice.Current.ProcessId -ne $script:window.Current.ProcessId){throw 'Theme item belongs to another process.'};MouseAction $choice theme-choice
 $appPid=$script:window.Current.ProcessId;Start-Sleep -Seconds 2
 $win=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$appPid))} 15 'theme window';AttachWindow $win;FitApp
}
function CapturePass([string]$value){
 $script:pass=$value;$script:screenNumber=0
 foreach($name in @('Home','Games','Remove apps')+$(if($value -ne 'A'){@('Startup & services')}else{@()})+@('Graphics drivers')+$(if(FindName 'Memory' $CT::ListItem){@('Memory')}else{@()})+@('Windows tweaks')+$(if($value -ne 'A'){@('Timer & cache')}else{@()})+@('Tools','Undo changes','Report a bug','Settings')){
  Nav $name;$slug=$name.ToLowerInvariant().Replace(' & ','-').Replace(' ','-')
  if($name -eq 'Games'){foreach($tab in @(@('GamesTab','games'),@('ProcessesTab','processes'),@('BackgroundTab','background-apps'))){if(Tab $tab[0]){CapturePage $slug $tab[1]}}}
  elseif($name -eq 'Remove apps'){foreach($tab in @(@('RemovalTab','remove-apps'),@('LeftoversTab','leftover-cleanup'))){if(Tab $tab[0]){CapturePage $slug $tab[1]}}}
  elseif($name -eq 'Windows tweaks'){
   $list=WaitFor {FindId 'WindowsTweakSections'} 40 'tweak section list'
   $names=[Collections.Generic.List[string]]::new();$container=$null
   if($list.TryGetCurrentPattern([Windows.Automation.ItemContainerPattern]::Pattern,[ref]$container)){
    $previous=$null;for($guard=0;$guard -lt 100;$guard++){$item=$container.FindItemByProperty($previous,$null,$null);if(-not$item){break};$virtual=$null;if($item.TryGetCurrentPattern([Windows.Automation.VirtualizedItemPattern]::Pattern,[ref]$virtual)){$virtual.Realize()};$names.Add($item.Current.Name);$previous=$item}
   }else{
    $pattern=$null;$canScroll=$list.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern,[ref]$pattern) -and $pattern.Current.VerticallyScrollable
    if($canScroll){$pattern.SetScrollPercent(-1,0)}
    for($guard=0;$guard -lt 100;$guard++){
     foreach($item in @($list.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))){if(-not$names.Contains($item.Current.Name)){$names.Add($item.Current.Name)}}
     if(-not$canScroll -or $pattern.Current.VerticalScrollPercent -ge 99.8){break}
     $pattern.Scroll([Windows.Automation.ScrollAmount]::NoAmount,[Windows.Automation.ScrollAmount]::LargeIncrement);Start-Sleep -Milliseconds 250
    }
   }
   if(-not$names.Count){throw 'No tweak sections realized.'}
   foreach($section in $names){
    $item=if($container){$container.FindItemByProperty($null,$A::NameProperty,$section)}else{$list.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::NameProperty,$section))}
    if(-not$item){throw ('Tweak section could not be re-found: '+$section)}
    $virtual=$null;if($item.TryGetCurrentPattern([Windows.Automation.VirtualizedItemPattern]::Pattern,[ref]$virtual)){$virtual.Realize()}
    $p=$null;if($item.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern,[ref]$p)){$p.ScrollIntoView()};MouseAction $item section;Start-Sleep -Seconds 2;CapturePage $slug ([regex]::Replace($section.ToLowerInvariant(),'[^a-z0-9]+','-').Trim('-'))
   }
  }
  else{CapturePage $slug;if($name -eq 'Tools'){MouseAction (FindId 'OpenFirmware') firmware;Start-Sleep -Seconds 3;CapturePage 'bios';MouseAction (FindName '← Tools' $CT::Button) back;Start-Sleep -Seconds 2}}
 }
}
$installerMovie=$null;$tourMovie=$null;$status='fail'
try{
 if((Get-HarnessFileSha256 $Installer) -cne $Sha256){throw 'Candidate installer SHA-256 differs.'}
 $desktop=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
 if($desktop.Width -lt 1600 -or $desktop.Height -lt 1000){throw ('Desktop working area cannot contain 1600x1000: '+$desktop)}
 Assert-HarnessInstallStart $exe;Start-ProcessTrace|Out-Null
 $foreign=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '(?i)setup.*\.(exe|tmp)$' -and -not(Get-HarnessProcess ([int]$_.ProcessId))});if($foreign.Count){throw 'Another setup is running.'}
 $existing=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.NativeWindowHandle})
 $log=Get-HarnessOutputPath $directory 'candidate-setup.log';$launchResult=Get-HarnessOutputPath $directory 'shell-result.json'
 $launchArguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Get-HarnessToolPath (Join-Path $Source 'tools\validation\Tour\Invoke-TourLauncher.ps1'))+'" -Source "'+(Get-HarnessToolPath $Source)+'" -FrameRoot "'+(Get-HarnessToolPath $script:Harness.Root)+'" -FrameId "'+$script:Harness.FrameId+'" -Manifest "'+$script:Harness.Manifest+'" -Nonce "'+$nonce+'" -Installer "'+(Get-HarnessToolPath $Installer)+'" -Log "'+(Get-HarnessToolPath $log)+'" -Result "'+(Get-HarnessToolPath $launchResult)+'"'
 $shell=Start-OwnedProcess -FilePath powershell.exe -ArgumentList $launchArguments -WindowStyle Normal -Purpose tour-shell
 $installerFrames=StartMovie 'installer-frames';$seen=[Collections.Generic.HashSet[string]]::new();$end=[DateTime]::UtcNow.AddMinutes(10);$finished=$false
 while([DateTime]::UtcNow -lt $end){
  Receive-ProcessTrace
  foreach($win in @($A::RootElement.FindAll($TS::Children,[Windows.Automation.Condition]::TrueCondition))){
   if($win.Current.NativeWindowHandle -notin $existing){Assert-HarnessSmartScreen $win $directory}
   if($win.Current.ClassName -eq 'TWizardForm' -and -not$win.Current.IsOffscreen){
    if(-not(Test-OwnedDescendant ([int]$win.Current.ProcessId) -Ancestor $shell -PassThru)){throw 'Wizard ownership failed.'};AttachWindow $win
    $tree=@(WindowTree);$button=$null;foreach($name in 'Finish','Install','Next >','Next'){$test=WizardButton $name;if($test -and $test.Current.IsEnabled){$button=$test;break}}
    $key=if($button){$tree.name -join '|'}else{'installing'}
    if($seen.Add($key)){Start-Sleep -Seconds $HoldSeconds;Shot 'installer' 'wizard' $(if($button){$button.Current.Name.ToLowerInvariant().Replace(' >','')}else{'installing'});if($button){$finished=$button.Current.Name -eq 'Finish';MouseAction $button wizard}}
   }elseif($win.Current.ClassName -eq '#32770' -and $win.Current.ProcessId -eq $shell.Identity.pid){
    AttachWindow $win;Start-Sleep -Seconds $HoldSeconds;Shot 'installer' 'wizard' 'security-warning';$run=WizardButton 'Run';if(-not$run){throw 'Unexpected launcher dialog.'};MouseAction $run wizard
   }elseif($win.Current.ClassName -eq '#32770' -and (Test-OwnedDescendant ([int]$win.Current.ProcessId) -Ancestor $shell)){
    AttachWindow $win;Shot 'installer' 'wizard' 'dialog';throw 'Installer raised an unplanned dialog; retained.'
   }
  }
  if(Test-HarnessPath $launchResult){$result=Read-HarnessResult $launchResult $nonce;if($result.status -eq 'failed' -or $result.exitCode -ne 0){throw 'Shell setup failed.'};if(-not$finished){throw 'Setup ended without the Finish page.'};break}
  Start-Sleep -Milliseconds 150
 }
 if(-not(Test-HarnessPath $launchResult)){throw 'Wizard timed out.'}
 $installerMovie=StopMovie;$installerMovie.folder=$installerFrames
 Register-HarnessFile $log 'candidate-setup-log'|Out-Null
 $display=(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1').DisplayVersion
 if($display -cne $ExpectedVersion -or (Get-HarnessItem $exe).VersionInfo.ProductVersion.TrimEnd(' ') -cne $ExpectedVersion){throw 'Candidate version differs after install.'}
 $app=WaitFor {@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -IEQ $exe|ForEach-Object {Test-OwnedDescendant ([int]$_.ProcessId) -Ancestor $shell -PassThru})|Select-Object -First 1} 45 'Finish-launched owned app'
 $win=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid))} 30 'app window';AttachWindow $win;FitApp
 $tourFrames=StartMovie 'tour-frames';AttachWindow $win;Nav Settings
 $toggle=FindId 'SimpleModeToggle';$originalSimple=$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On
 $originalTheme=(FindId 'ThemePicker').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name
 try{Simple $true;CapturePass A;Simple $false;CapturePass B;Theme 'Blackout Gold';CapturePass C}
 finally{Theme $originalTheme;Simple $originalSimple}
 $tourMovie=StopMovie;$tourMovie.folder=$tourFrames
 $script:missing.Add(@{state='Operation-dependent dialogs and results';reason='Apply, restore, remove, restart, download, report submission and system-setting controls are outside the read-only tour.'})
 Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';nonce=$nonce;version=$display;desktop=$desktop.ToString();originalTheme=$originalTheme;originalSimple=$originalSimple;appearanceRestored=$true;app=$app.Identity;screens=@($script:shots);actions=@($script:actions);notCaptured=@($script:missing);movies=@{installer=$installerMovie;tour=$tourMovie}}|Out-Null
 $status='pass'
}finally{
 if($script:recorder){$script:recorder.Dispose();$script:recorder=$null}
 if($status -ne 'pass'){Write-HarnessResult $OutRoot 'failure.json' @{status='fail';screens=@($script:shots);actions=@($script:actions);notCaptured=@($script:missing)}|Out-Null}
 Complete-HarnessInvocation $status -Cleanup|Out-Null
}
