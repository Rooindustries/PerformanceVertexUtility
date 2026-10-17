param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$ExpectedVersion,[int]$HoldSeconds=4,[ValidateSet('A','B','C')][string[]]$Passes=@('A','B','C'))
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Memory\Memory.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'app-tour' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms,WindowsBase
Add-Type -Path (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Tour\TourCapture.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,Accessibility
[RooIndustriesTour.Desktop]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$exe=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
$script:shots=[Collections.Generic.List[object]]::new();$script:actions=[Collections.Generic.List[object]]::new();$script:missing=[Collections.Generic.List[object]]::new();$script:window=$null;$script:recorder=$null;$script:screenNumber=0
$directory=Join-Path $OutRoot ('capture-'+$nonce);New-HarnessDirectory $directory 'tour-media'|Out-Null
$script:screensDir=Join-Path $directory 'screens';New-HarnessDirectory $script:screensDir 'app-screens'|Out-Null
function Unique($Parent,[string]$Id,[string]$Name,$Type=$null,[string]$Class='',[switch]$Optional,[switch]$Children){
 $conditions=[Collections.Generic.List[Windows.Automation.Condition]]::new()
 $conditions.Add([Windows.Automation.PropertyCondition]::new($(if($Id){$A::AutomationIdProperty}else{$A::NameProperty}),$(if($Id){$Id}else{$Name})))
 if($Type){$conditions.Add([Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$Type))}
 if($Class){$conditions.Add([Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,$Class))}
 $condition=if($conditions.Count -eq 1){$conditions[0]}else{[Windows.Automation.AndCondition]::new($conditions.ToArray())}
 $raw=@($Parent.FindAll($(if($Children){$TS::Children}else{$TS::Descendants}),$condition));$distinct=[Collections.Generic.List[Windows.Automation.AutomationElement]]::new()
 foreach($candidate in $raw){$same=@($distinct|Where-Object {($_.GetRuntimeId() -join ',') -ceq ($candidate.GetRuntimeId() -join ',') -and [Windows.Automation.Automation]::Compare($_,$candidate)});if(-not$same.Count){$distinct.Add($candidate)}}
 $matches=@($distinct)
 if($raw.Count -gt $matches.Count){Write-HarnessResult $directory 'identity-duplicates.json' @{id=$Id;name=$Name;parentRuntimeId=($Parent.GetRuntimeId() -join ',');returned=$raw.Count;distinct=$matches.Count;runtimeIds=@($raw|ForEach-Object {$_.GetRuntimeId() -join ','});result='Identical UIA elements collapsed; distinct identities still refused'}|Out-Null}
 if($matches.Count -eq 0 -and $Optional){return $null}
 if($matches.Count -ne 1){throw ('Target identity missing or ambiguous: id='+$Id+', name='+$Name+', count='+$matches.Count)}
 return $matches[0]
}
function FindId([string]$id,[switch]$Optional){if($id -eq 'ThemePicker'){return Unique (Unique $script:window 'SettingsScroller' '' $CT::Pane) $id '' $CT::ComboBox -Optional:$Optional};Unique $script:window $id '' -Optional:$Optional}
function NavParent([string]$name){FindId $(if($name -in 'Report a bug','Settings'){'FooterItemsScrollViewer'}else{'MenuItemsScrollViewer'})}
function NavItem([string]$name,[switch]$Optional){Unique (NavParent $name) '' $name $CT::ListItem -Optional:$Optional}
function WaitFor([scriptblock]$test,[int]$seconds,[string]$label){$limit=[DateTime]::UtcNow.AddSeconds($seconds);do{$answer=& $test;if($answer){return $answer};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $limit);throw ('Timed out: '+$label)}
function WindowTree{@($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {@{name=$_.Current.Name;id=$_.Current.AutomationId;type=$_.Current.ControlType.ProgrammaticName;class=$_.Current.ClassName;offscreen=$_.Current.IsOffscreen;enabled=$_.Current.IsEnabled;bounds=$_.Current.BoundingRectangle.ToString()}})}
function AttachWindow($win){$script:window=Register-HarnessWindow $win;[RooIndustriesTour.Desktop]::Focus([IntPtr]$win.Current.NativeWindowHandle)|Out-Null;if($script:recorder){$script:recorder.Window([IntPtr]$win.Current.NativeWindowHandle,[int]$win.Current.ProcessId)}}
function FitApp{
 $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
 if($area.Width -lt 1600 -or $area.Height -lt 1000){throw ('Desktop working area cannot contain 1600x1000: '+$area)}
 [RooIndustriesTour.Desktop]::Center([IntPtr]$script:window.Current.NativeWindowHandle,1600,1000,($area.Left+[int](($area.Width-1600)/2)),($area.Top+[int](($area.Height-1000)/2)))
}
function AppWindow{
 $matches=@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$script:app.Identity.pid))|Where-Object {$_.Current.ControlType -eq $CT::Window -and -not$_.Current.IsOffscreen})
 if($matches.Count -gt 1){throw 'Owned app has ambiguous main windows.'};if($matches.Count){return $matches[0]}
}
function EnsureForeground{
 $hwnd=[IntPtr]$script:window.Current.NativeWindowHandle
 if(-not[RooIndustriesTour.Desktop]::IsWindow($hwnd)){$win=WaitFor {AppWindow} 15 'recreated owned app window';AttachWindow $win;FitApp;$hwnd=[IntPtr]$script:window.Current.NativeWindowHandle}
 $owner=[int]$script:window.Current.ProcessId
 if([RooIndustriesTour.Desktop]::VisibleOwner($hwnd,$owner)){return}
 $before=[RooIndustriesTour.Desktop]::ForegroundPid();[RooIndustriesTour.Desktop]::Focus($hwnd)|Out-Null
 WaitFor {[RooIndustriesTour.Desktop]::VisibleOwner($hwnd,$owner)} 5 ('owned foreground, previous PID '+$before)|Out-Null
 Write-HarnessResult $directory 'foreground.json' @{timeUtc=[DateTime]::UtcNow.ToString('o');previousPid=$before;ownerPid=$owner;hwnd=$hwnd.ToInt64();result='owned window focused'}|Out-Null
}
function Action([string]$Kind,[string]$Selector,$Element=$null,[double]$Value=0){
 Assert-HarnessHostLease;EnsureForeground
 $parent=$script:window;$patternName='';$target=$null
 switch($Kind){
  'navigation' {if($Selector -notin 'Home','Games','Remove apps','Graphics drivers','Windows tweaks','Tools','Undo changes','Report a bug','Settings','Startup & services','Memory','Timer & cache'){throw 'Navigation is not allowed'};$parent=NavParent $Selector;$target=Unique $parent '' $Selector $CT::ListItem;$patternName='SelectionItemPattern.Select'}
  'tab' {if($Selector -notin 'GamesTab','ProcessesTab','BackgroundTab','RemovalTab','LeftoversTab'){throw 'Tab is not allowed'};$parent=FindId $(if($Selector -in 'RemovalTab','LeftoversTab'){'CleanupTabs'}else{'ProcessTabs'});$target=Unique $parent $Selector '';$patternName='SelectionItemPattern.Select'}
  'section' {$parent=FindId 'WindowsTweakSections';$target=Unique $parent '' $Selector $CT::ListItem;$patternName='SelectionItemPattern.Select'}
  'simple' {if($Selector -cne 'SimpleModeToggle'){throw 'Toggle is not allowed'};$target=FindId $Selector;$patternName='TogglePattern.Toggle'}
  'theme' {if($Selector -cne 'ThemePicker'){throw 'ComboBox is not allowed'};$target=FindId $Selector;$patternName='ExpandCollapsePattern.Expand'}
  'theme-choice' {if($Selector -notin 'Roo Industries Blue','Blackout Gold'){throw 'Theme is not allowed'};$parent=FindId 'ThemePicker';$target=Unique $parent '' $Selector $CT::ListItem;$patternName='SelectionItemPattern.Select'}
  'firmware' {if($Selector -cne 'OpenFirmware'){throw 'Button is not allowed'};$target=FindId $Selector;$patternName='InvokePattern.Invoke'}
  'back' {if($Selector -cne ([string][char]0x2190+' Tools')){throw 'Button is not allowed'};$target=Unique $parent '' $Selector $CT::Button;$patternName='InvokePattern.Invoke'}
  'scroll' {
   if(-not$Element -or ($Element.Current.ClassName -ne 'ScrollViewer' -and $Element.Current.AutomationId -notin 'WindowsTweaksList','RemovalApps','AppsCleanupInstalledAppsList')){throw 'Only a page ScrollViewer or its named list viewport may scroll'}
   $parent=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($Element)
   $target=Unique $parent $Element.Current.AutomationId $Element.Current.Name $Element.Current.ControlType $Element.Current.ClassName -Children
   $patternName='ScrollPattern.SetScrollPercent'
  }
  'expander' {if(-not$Element -or $Element.Current.ClassName -ne 'Expander'){throw 'Only a read-only Expander may expand'};$parent=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($Element);$target=Unique $parent $Element.Current.AutomationId $Element.Current.Name $Element.Current.ControlType 'Expander' -Children;$patternName='ExpandCollapsePattern.Expand'}
  default {throw ('Action is outside the allowed list: '+$Kind)}
 }
 if($target.Current.ProcessId -ne $script:window.Current.ProcessId -or -not(Test-OwnedDescendant ([int]$target.Current.ProcessId))){throw 'Target is not owned by this app'}
 $ready=[Diagnostics.Stopwatch]::StartNew()
 if($target.Current.IsOffscreen -or -not$target.Current.IsEnabled){try{WaitFor {-not$target.Current.IsOffscreen -and $target.Current.IsEnabled} 30 ('allowed target ready: '+$Kind+' '+$Selector)|Out-Null}catch{Write-HarnessResult $directory 'refused-action.json' @{timeUtc=[DateTime]::UtcNow.ToString('o');kind=$Kind;selector=$Selector;id=$target.Current.AutomationId;name=$target.Current.Name;pattern=$patternName;enabled=$target.Current.IsEnabled;offscreen=$target.Current.IsOffscreen;mouseClick=$false;invoked=$false;result='refused';reason=$_.Exception.Message}|Out-Null;throw}}
 $ready.Stop()
 $bounds=$target.Current.BoundingRectangle
 $record=@{timeUtc=[DateTime]::UtcNow.ToString('o');kind=$Kind;selector=$Selector;id=$target.Current.AutomationId;name=$target.Current.Name;parentId=$parent.Current.AutomationId;parentName=$parent.Current.Name;parentRuntimeId=($parent.GetRuntimeId() -join ',');runtimeId=($target.GetRuntimeId() -join ',');pattern=$patternName;readyWaitSeconds=$ready.Elapsed.TotalSeconds;bounds=$bounds.ToString();mouseClick=$false;result='failed'}
 try{
  [RooIndustriesTour.Desktop]::Move([int]($bounds.Left+$bounds.Width/2),[int]($bounds.Top+$bounds.Height/2))
  $record.cursor=[RooIndustriesTour.Desktop]::Position()
  switch($patternName){
   'SelectionItemPattern.Select' {$p=$target.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern);$p.Select();if($Kind -eq 'theme-choice'){Start-Sleep -Seconds 2;$win=WaitFor {AppWindow} 15 'theme window';AttachWindow $win;FitApp;Nav Settings;$record.selected=(FindId 'ThemePicker').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name -ceq $Selector;$record.readback='Selected theme on recreated owned window';$record.readbackHwnd=$win.Current.NativeWindowHandle}else{$record.selected=$p.Current.IsSelected};if(-not$record.selected){throw 'Selection readback failed'}}
   'InvokePattern.Invoke' {$target.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
   'TogglePattern.Toggle' {$p=$target.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);$record.before=$p.Current.ToggleState.ToString();$p.Toggle();$record.after=$p.Current.ToggleState.ToString();if($record.before -ceq $record.after){throw 'Toggle readback unchanged'}}
   'ExpandCollapsePattern.Expand' {$p=$target.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern);$p.Expand();$record.after=$p.Current.ExpandCollapseState.ToString()}
   'ScrollPattern.SetScrollPercent' {$p=$target.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern);$from=$p.Current.VerticalScrollPercent;$record.before=$from;$record.requested=$Value;for($i=1;$i -le 12;$i++){$p.SetScrollPercent(-1,($from+($Value-$from)*$i/12));Start-Sleep -Milliseconds 80};$record.after=$p.Current.VerticalScrollPercent}
  }
  $record.result='success'
 }catch{$record.error=$_.Exception.Message;throw}finally{
  $script:actions.Add($record)
  Write-HarnessResult $directory 'action.json' $record|Out-Null
 }
 Start-Sleep -Milliseconds 250
}
function Nav([string]$name){Action navigation $name;Start-Sleep -Seconds 2}
function Tab([string]$id){$item=FindId $id -Optional;if(-not$item -or $item.Current.IsOffscreen){$script:missing.Add(@{pass=$script:pass;state=$id;reason='The app hides this tab in this mode.'});return $false};Action tab $id;Start-Sleep -Seconds 2;return $true}
function ScrollPage{
 $frame=[RooIndustriesTour.Desktop]::Bounds([IntPtr]$script:window.Current.NativeWindowHandle)
 $candidates=@(foreach($item in $script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)){
  if($item.Current.IsOffscreen -or ($item.Current.ClassName -ne 'ScrollViewer' -and $item.Current.AutomationId -notin 'WindowsTweaksList','RemovalApps','AppsCleanupInstalledAppsList')){continue};$r=$item.Current.BoundingRectangle
  if($r.Left -lt $frame.Left+220 -or $r.Width -lt 400 -or $r.Height -lt 180){continue}
  $pattern=$null;if($item.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern,[ref]$pattern) -and $pattern.Current.VerticallyScrollable){[pscustomobject]@{element=$item;pattern=$pattern;area=$r.Width*$r.Height}}
 });return $candidates|Sort-Object area -Descending|Select-Object -First 1
}
function SetScroll($scroll,[double]$to){Action scroll '' $scroll.element $to;Start-Sleep -Milliseconds 400}
function Shot([string]$page,[string]$tab,[int]$part=0){
 $tab=$tab.Substring(0,[Math]::Min(90,$tab.Length));$script:screenNumber++;$name=$script:pass+'-'+('{0:D3}'-f$script:screenNumber)+'-'+$page+'-'+$tab+$(if($part){'-part'+$part}else{''})+'.png';$path=Join-Path $script:screensDir $name
 EnsureForeground
 $hwnd=[IntPtr]$script:window.Current.NativeWindowHandle
 if(-not[RooIndustriesTour.Desktop]::VisibleOwner($hwnd,[int]$script:window.Current.ProcessId)){throw 'Owned capture window is not in front'}
 [RooIndustriesTour.Desktop]::Shot($hwnd,(Get-HarnessLongPath $path));$bounds=[RooIndustriesTour.Desktop]::Bounds($hwnd)
 $script:shots.Add(@{file=$name;pass=$script:pass;page=$page;tab=$tab;part=$part;path=$path;sha256=Get-HarnessFileSha256 $path;width=$bounds.Width;height=$bounds.Height;bounds=$bounds;timeUtc=[DateTime]::UtcNow.ToString('o')})
 Write-HarnessResult $directory ($name+'.uia.json') @{screen=$name;elements=@(WindowTree)}|Out-Null
 Write-Output ('SCREEN '+$name)
}
function CapturePage([string]$page,[string]$tab='main',[switch]$TopOnly){
 $scroll=ScrollPage;if($scroll){SetScroll $scroll 0};Start-Sleep -Seconds $HoldSeconds
 if($TopOnly -or $script:pass -eq 'C' -or -not$scroll){Shot $page $tab;return}
 $part=1;Shot $page $tab $part
 for($guard=0;$guard -lt 500 -and $scroll.pattern.Current.VerticalScrollPercent -lt 99.8;$guard++){
  $current=$scroll.pattern.Current.VerticalScrollPercent;$view=$scroll.pattern.Current.VerticalViewSize;$step=if($view -ge 100){100}else{80*$view/(100-$view)};$next=[Math]::Min(100.0,$current+[Math]::Max(0.01,$step))
  SetScroll $scroll $next;Start-Sleep -Seconds $HoldSeconds;$part++;Shot $page $tab $part
  if($scroll.pattern.Current.VerticalScrollPercent -le $current){throw 'Page scroll made no progress'}
 }
 if($scroll.pattern.Current.VerticalScrollPercent -lt 99.8){throw 'Page scroll did not reach the bottom'};SetScroll $scroll 0
}
function Simple([bool]$value){Nav Settings;$toggle=FindId 'SimpleModeToggle';$old=$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On;if($old -ne $value){Action simple 'SimpleModeToggle';WaitFor {((FindId 'SimpleModeToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On) -eq $value} 10 'simple mode'|Out-Null}}
function Theme([string]$value){
 Nav Settings;$picker=FindId 'ThemePicker';$selected=$picker.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name;if($selected -ceq $value){return}
 Action theme 'ThemePicker';Write-HarnessResult $directory 'theme-expanded.json' @{elements=@(WindowTree);matches=@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'ThemePicker'))|ForEach-Object {$parent=[Windows.Automation.TreeWalker]::RawViewWalker.GetParent($_);@{id=$_.Current.AutomationId;name=$_.Current.Name;class=$_.Current.ClassName;runtimeId=($_.GetRuntimeId() -join ',');parentId=$parent.Current.AutomationId;parentName=$parent.Current.Name;parentClass=$parent.Current.ClassName;parentRuntimeId=($parent.GetRuntimeId() -join ',')}})}|Out-Null;Action theme-choice $value
 if((FindId 'ThemePicker').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name -cne $value){throw 'Theme readback failed'}
}
function Sections{
 $list=FindId 'WindowsTweakSections';$items=@($list.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))
 if(-not$items.Count){throw 'No tweak sections realized'}
 $names=@($items|ForEach-Object {$_.Current.Name});if(@($names|Sort-Object -Unique).Count -ne $names.Count){throw 'Duplicate tweak section names'}
 foreach($section in $names){Action section $section;Start-Sleep -Seconds 2;CapturePage 'windows-tweaks' ([regex]::Replace($section.ToLowerInvariant(),'[^a-z0-9]+','-').Trim('-')) -TopOnly:($section -ne 'All tweaks')}
}
function CapturePass([string]$value){
 $script:pass=$value;$script:screenNumber=0
 $pages=@('Home','Games','Remove apps')+$(if($value -ne 'A'){@('Startup & services')}else{@()})+@('Graphics drivers')+$(if(NavItem 'Memory' -Optional){@('Memory')}else{@()})+@('Windows tweaks')+$(if($value -ne 'A'){@('Timer & cache')}else{@()})+@('Tools','Undo changes','Report a bug','Settings')
 foreach($name in $pages){
  Nav $name;$slug=$name.ToLowerInvariant().Replace(' & ','-').Replace(' ','-')
  if($name -eq 'Games'){foreach($tab in @(@('GamesTab','games'),@('ProcessesTab','processes'),@('BackgroundTab','background-apps'))){if(Tab $tab[0]){CapturePage $slug $tab[1]}}}
  elseif($name -eq 'Remove apps'){foreach($tab in @(@('RemovalTab','remove-apps'),@('LeftoversTab','leftover-cleanup'))){if(Tab $tab[0]){CapturePage $slug $tab[1]}}}
  elseif($name -eq 'Windows tweaks'){Sections}
  else{CapturePage $slug;if($name -eq 'Tools'){Action firmware 'OpenFirmware';Start-Sleep -Seconds 3;CapturePage 'bios';Action back ([string][char]0x2190+' Tools');Start-Sleep -Seconds 2}}
 }
}
$status='fail';$tourMovie=$null
try{
 $display=(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1').DisplayVersion
 if($display -cne $ExpectedVersion -or (Get-HarnessItem $exe).VersionInfo.ProductVersion.TrimEnd(' ') -cne $ExpectedVersion){throw 'Candidate version differs after install'}
 Assert-HarnessHostLease;Assert-NoForeignInstance $exe;Start-ProcessTrace|Out-Null
 $script:app=Start-OwnedProcess -FilePath (Get-HarnessToolPath $exe) -WindowStyle Normal -WorkingDirectory (Get-HarnessToolPath ([IO.Path]::GetDirectoryName($exe))) -Purpose tour-app
 $win=WaitFor {AppWindow} 30 'app window';AttachWindow $win;FitApp
 $tourFrames=Join-Path $directory 'tour-frames';New-HarnessDirectory $tourFrames 'tour-video-frames'|Out-Null;$script:recorder=[RooIndustriesTour.Recorder]::new((Get-HarnessLongPath $tourFrames));AttachWindow $win;Nav Settings
 $originalSimple=(FindId 'SimpleModeToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::On
 $originalTheme=(FindId 'ThemePicker').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()[0].Current.Name
 try{foreach($requestedPass in $Passes){Simple ($requestedPass -eq 'A');if($requestedPass -eq 'C'){Theme 'Blackout Gold'};CapturePass $requestedPass}}
 finally{Theme $originalTheme;Simple $originalSimple}
 $script:recorder.Dispose();$tourMovie=@{folder=$tourFrames;frames=$script:recorder.Count;skippedTicks=$script:recorder.Skipped;wallSeconds=$script:recorder.Seconds;fps=15};$script:recorder=$null
 $script:missing.Add(@{state='BIOS inventory/session states';reason='Loading a firmware package/session, review or restart is outside the read-only tour.'})
 $script:missing.Add(@{state='Operation-dependent dialogs and results';reason='Apply, restore, remove, restart, download, report submission and tweak/game/process setting controls are forbidden.'})
 $actionsPath=Write-HarnessResult $directory 'actions.json' @{actions=@($script:actions)}
 Write-HarnessResult $OutRoot 'receipt.json' @{status='pass';nonce=$nonce;passes=$Passes;version=$display;originalTheme=$originalTheme;originalSimple=$originalSimple;appearanceRestored=$true;app=$script:app.Identity;screens=@($script:shots);actions=@($script:actions);actionLog=@{path=$actionsPath;sha256=Get-HarnessFileSha256 $actionsPath};notCaptured=@($script:missing);movies=@{tour=$tourMovie}}|Out-Null
 $status='pass'
}finally{
 if($script:recorder){$script:recorder.Dispose();$tourMovie=@{folder=$tourFrames;frames=$script:recorder.Count;skippedTicks=$script:recorder.Skipped;wallSeconds=$script:recorder.Seconds;fps=15};$script:recorder=$null}
 if($status -ne 'pass'){Write-HarnessResult $OutRoot 'failure.json' @{status='fail';version=$display;originalTheme=$originalTheme;originalSimple=$originalSimple;screens=@($script:shots);actions=@($script:actions);notCaptured=@($script:missing);movies=@{tour=$tourMovie}}|Out-Null}
 Receive-ProcessTrace
 foreach($entry in @(Get-HarnessEntries|Where-Object {$_.kind -eq 'trace' -and $_.nonce -ceq $nonce})){if(Get-Process -Id $entry.identity.processId -ErrorAction SilentlyContinue){Test-OwnedDescendant ([int]$entry.identity.processId)|Out-Null}}
 Complete-HarnessInvocation $status -Cleanup|Out-Null
}
