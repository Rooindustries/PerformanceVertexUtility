param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidateRange(3000,10000)][int]$PauseMs=10000)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1'))
. (Get-HarnessToolPath (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'theme-keeps-work' $OutRoot
Assert-HarnessHostLease;Ensure-HarnessOutputDirectory $OutRoot
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type -Path (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Tour\TourCapture.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,Accessibility
[RooIndustriesTour.Desktop]::SetProcessDPIAware()|Out-Null
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System.Drawing;using System.Drawing.Imaging;using System.Runtime.InteropServices;
public static class RooIndustriesThemePixels {
 public static int[] Count(Bitmap bitmap,int[][] groups,int tolerance){
  var counts=new int[groups.Length];var data=bitmap.LockBits(new Rectangle(0,0,bitmap.Width,bitmap.Height),ImageLockMode.ReadOnly,PixelFormat.Format24bppRgb);
  try{var row=new byte[data.Stride];for(int y=0;y<data.Height;y++){Marshal.Copy(data.Scan0+y*data.Stride,row,0,data.Stride);for(int x=0;x<data.Width;x++){int b=row[x*3],g=row[x*3+1],r=row[x*3+2];
   for(int i=0;i<groups.Length;i++){bool hit=false;foreach(var c in groups[i]){if(System.Math.Abs(r-((c>>16)&255))<=tolerance&&System.Math.Abs(g-((c>>8)&255))<=tolerance&&System.Math.Abs(b-(c&255))<=tolerance){hit=true;break;}}if(hit)counts[i]++;}}}}
  finally{bitmap.UnlockBits(data);}return counts;
 }
}
'@
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$evidence=New-HarnessEvidenceDirectory $OutRoot 'theme'
$checks=[Collections.Generic.List[object]]::new();$shots=[Collections.Generic.List[object]]::new();$hidden=[Collections.Generic.List[object]]::new()
$private=@($env:USERPROFILE,$env:USERNAME,$env:COMPUTERNAME)|Where-Object {$_}
$accents=[int[][]]@(@(0xE8B94A,0xFFD76E,0xFFE9A8,0xC9962E,0xE8C97A),@(0x22D3EE,0x67D9EE,0x38BDF8,0x67E8F9,0x0284C7))
$pages='Home','Games','Remove apps','Graphics drivers','Memory','Windows tweaks','Tools','Undo changes','Report a bug','Settings'
$goldKeys='SystemAccentColor','SystemAccentColorLight1','SystemAccentColorLight2','SystemAccentColorLight3','SystemAccentColorDark1','SystemAccentColorDark2','SystemAccentColorDark3'
$keysFile=Join-Path $evidence 'theme-keys.tsv';$script:keysSeen=0
$script:app=$null;$script:window=$null;$fixture=$null;$recorder=$null;$frames=$null;$failure=$null;$settingsPath=$null;$settingsBytes=$null;$settingsTouched=$false;$pickId=$null

function Say([string]$text){[Console]::Out.WriteLine($text)}
function Scrub([string]$text){foreach($value in $private){$text=$text -ireplace [regex]::Escape($value),'<private>'};$text}
function Check([string]$name,[bool]$passed,$observed=$null){$checks.Add([ordered]@{check=$name;passed=$passed;observed=$observed});Say ($(if($passed){'PASS '}else{'FAIL '})+$name)}
function WaitFor([scriptblock]$probe,[double]$seconds,[string]$what){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);while([DateTime]::UtcNow -lt $deadline){try{$v=&$probe}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds 100};throw ('Timed out: '+$what)}
function Pattern($element,$type){$element.GetCurrentPattern($type::Pattern)}
function Of($type){[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$type)}
function ById([string]$id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$id))}
function Named($root,[string]$name,$type){$root.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),(Of $type)))}
function Alive{$script:app -and -not$script:app.process.HasExited}
function AppWindow{@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$script:app.Identity.pid))|Where-Object {$_.Current.ControlType -eq $CT::Window -and -not$_.Current.IsOffscreen})|Select-Object -First 1}
function Attach{
 $script:window=Register-HarnessWindow (WaitFor {AppWindow} 120 'app window')
 $hwnd=[IntPtr]$script:window.Current.NativeWindowHandle;[RooIndustriesTour.Desktop]::Focus($hwnd)|Out-Null
 $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea;[RooIndustriesTour.Desktop]::Center($hwnd,1600,1000,($area.Left+[int](($area.Width-1600)/2)),($area.Top+[int](($area.Height-1000)/2)))
 if($recorder){$recorder.Window($hwnd,[int]$script:app.Identity.pid)}
 [long]$hwnd
}
function Launch{
 Assert-HarnessHostLease
 if(@(Get-Process RooIndustries.OptimizationSuite.App -ErrorAction SilentlyContinue|Where-Object {-not(Get-HarnessProcess $_.Id)}).Count){throw 'Another app window is open that this run did not start; retained.'}
 $script:app=Start-OwnedProcess -FilePath $exe -WindowStyle Normal -WorkingDirectory ([IO.Path]::GetDirectoryName($exe)) -Purpose 'theme-app'
 $hwnd=Attach;WaitFor {Named (ById 'Nav') 'Home' $CT::ListItem} 120 'navigation'|Out-Null;$hwnd
}
function Close{if(Alive){$script:app.process.CloseMainWindow()|Out-Null;if(-not$script:app.process.WaitForExit(20000)){Stop-HarnessProcess $script:app}};$script:app=$null;$script:window=$null}
function Nav([string]$name){$nav=WaitFor {ById 'Nav'} 60 'navigation';(Pattern (WaitFor {Named $nav $name $CT::ListItem} 30 ('nav '+$name)) ([Windows.Automation.SelectionItemPattern])).Select();Start-Sleep -Milliseconds 1500}
function Tab([string]$id){(Pattern (WaitFor {ById $id} 60 $id) ([Windows.Automation.SelectionItemPattern])).Select();Start-Sleep -Milliseconds 800}
function Press([string]$id){(Pattern (WaitFor {$e=ById $id;if($e -and $e.Current.IsEnabled){$e}} 120 $id) ([Windows.Automation.InvokePattern])).Invoke()}
function Choose([string]$id,[string]$like){
 (Pattern (WaitFor {$c=ById $id;if($c -and $c.Current.IsEnabled){$c}} 120 $id) ([Windows.Automation.ExpandCollapsePattern])).Expand()
 $item=$null
 for($page=0;-not$item -and $page -lt 40;$page++){
  Start-Sleep -Milliseconds 250;$combo=ById $id
  $item=@($combo.FindAll($TS::Descendants,(Of $CT::ListItem))|Where-Object {$_.Current.Name -like $like})|Select-Object -First 1
  if(-not$item){$scroll=@($combo.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {try{(Pattern $_ ([Windows.Automation.ScrollPattern])).Current.VerticallyScrollable}catch{$false}})|Select-Object -First 1;if(-not$scroll){break};(Pattern $scroll ([Windows.Automation.ScrollPattern])).Scroll([Windows.Automation.ScrollAmount]::NoAmount,[Windows.Automation.ScrollAmount]::LargeIncrement)}
 }
 if(-not$item){throw ('Choice missing: '+$like)}
 (Pattern $item ([Windows.Automation.SelectionItemPattern])).Select();Start-Sleep -Milliseconds 500
 try{(Pattern (ById $id) ([Windows.Automation.ExpandCollapsePattern])).Collapse()}catch{}
}
function Theme([string]$name){Nav 'Settings';Choose 'ThemePicker' $name;Start-Sleep -Seconds 3}
function Text([string]$id){$e=ById $id;if($e){Scrub $e.Current.Name}else{'missing'}}
function Private{
 $bounds=[RooIndustriesTour.Desktop]::Bounds([IntPtr]$script:window.Current.NativeWindowHandle);$rows=[Collections.Generic.List[object]]::new()
 foreach($e in @($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))){
  $text=$e.Current.Name;$value=$null;if($e.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$value)){$text+=' '+$value.Current.Value}
  if(-not@($private|Where-Object {$text.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0}).Count){continue}
  $r=$e.Current.BoundingRectangle;if($r.Width -gt 0 -and $r.Height -gt 0){$rows.Add(@(([int]($r.X-$bounds.Left)-2),([int]($r.Y-$bounds.Top)-2),([int][Math]::Ceiling($r.Width)+4),([int][Math]::Ceiling($r.Height)+4)))}
 }
 ,$rows.ToArray()
}
function Shot([string]$pass,[string]$page){
 $hwnd=[IntPtr]$script:window.Current.NativeWindowHandle;[RooIndustriesTour.Desktop]::Focus($hwnd)|Out-Null;Start-Sleep -Milliseconds 300
 $mask=Private;$bitmap=[RooIndustriesTour.Desktop]::Capture($hwnd,$false)
 try{
  $g=[Drawing.Graphics]::FromImage($bitmap);try{foreach($r in $mask){$g.FillRectangle([Drawing.Brushes]::Black,$r[0],$r[1],$r[2],$r[3])}}finally{$g.Dispose()}
  $counts=[RooIndustriesThemePixels]::Count($bitmap,$accents,8)
  $file=('{0}-{1:00}-{2}.png' -f $pass,$shots.Count,($page.ToLowerInvariant() -replace '[^a-z0-9]+','-'));$stream=[IO.FileStream]::new((Get-HarnessLongPath (Join-Path $evidence $file)),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)}finally{$stream.Dispose()}
 }finally{$bitmap.Dispose()}
 $shots.Add([ordered]@{pass=$pass;page=$page;file=$file;sha256=Get-HarnessFileSha256 (Join-Path $evidence $file);masked=$mask.Count;gold=$counts[0];blue=$counts[1]})
}
function Pass([string]$pass){foreach($page in $pages){Nav $page;Start-Sleep -Milliseconds 1000;Shot $pass $page}}
function Removal{Nav 'Remove apps';$list=WaitFor {ById 'RemovalApps'} 60 'app list';[ordered]@{picked=@((Pattern $list ([Windows.Automation.SelectionPattern])).Current.GetSelection()|ForEach-Object {Scrub ((@($_.FindAll($TS::Descendants,(Of $CT::Text))|ForEach-Object {$_.Current.Name})) -join ' | ')});review=Text 'RemovalSelection';apply=Text 'RemovalApply'}}
function Tweaks{Nav 'Windows tweaks';$search=WaitFor {ById 'WindowsTweaksSearch'} 60 'tweak search';$pick=if($pickId){ById $pickId}else{$null};[ordered]@{search=(Pattern $search ([Windows.Automation.ValuePattern])).Current.Value;pick=$pickId;picked=$(if($pick){[string](Pattern $pick ([Windows.Automation.TogglePattern])).Current.ToggleState}else{'missing'})}}
function ProcessState{Nav 'Games';[ordered]@{status=Text 'ProcessStatus';review=Text 'ProcessReview';restore=$(if($e=ById 'ProcessRestore'){$e.Current.IsEnabled}else{$false})}}
function Priority{[string](Get-Process -Id $fixture.Identity.pid).PriorityClass}
function Same($before,$after){($before|ConvertTo-Json -Depth 5 -Compress) -ceq ($after|ConvertTo-Json -Depth 5 -Compress)}
function AccentKeys([string]$label,[string]$when,[string]$theme){
 $path=Get-HarnessLongPath $keysFile;$lines=@(if([IO.File]::Exists($path)){[IO.File]::ReadAllLines($path)})
 $last=if($lines.Count -gt $script:keysSeen){$lines[-1] -split "`t"}else{@('none','none','')};$script:keysSeen=$lines.Count
 $found=@($last[2] -split ','|Where-Object {$_ -like 'SystemAccentColor*'}|Sort-Object);$want=@($(if($theme -eq 'black-gold'){$goldKeys})|Sort-Object)
 Check $label ($last[0] -eq $when -and $last[1] -eq $theme -and ($found -join ',') -ceq ($want -join ',')) @{when=$last[0];theme=$last[1];accentKeys=$found}
}
function Kept([string]$when,$removal,$tweaks){
 if(-not(Alive)){Check ('The app is still running '+$when) $false;return}
 $now=Removal;Check ('Remove apps keeps both picks and the open review '+$when) ((Same $removal $now) -and $now.picked.Count -eq 2) @{before=$removal;after=$now}
 $now=Tweaks;Check ('Windows tweaks keeps the search and the picked change '+$when) ((Same $tweaks $now) -and $now.picked -eq 'On') @{before=$tweaks;after=$now}
}

try{
 $root=Get-RooIndustriesLocalDataRoot
 if(-not[IO.Directory]::Exists((Get-HarnessLongPath $root))){throw 'This PC has no app data folder; open the installed app once before running this check.'}
 $settingsPath=Join-Path $root 'settings.json';if([IO.File]::Exists((Get-HarnessLongPath $settingsPath))){$settingsBytes=[IO.File]::ReadAllBytes((Get-HarnessLongPath $settingsPath))}
 Initialize-HarnessBuildFolders $Source
 $helper=Join-Path $Source 'backend\bin\optimizer';New-HarnessDirectory $helper 'theme-helper-build'|Out-Null
 $env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:RooIndustriesTestHooks='';$env:GovernorTestHooks='';$env:RooIndustriesRelease='';$env:ROO_INDUSTRIES_UPDATE_FEED='';$env:ROO_INDUSTRIES_BUG_WEBHOOK=''
 $dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe';$flags=' -c Release --disable-build-servers -p:UseSharedCompilation=false -p:RooIndustriesTestHooks=true -p:GovernorTestHooks=true'
 Invoke-HarnessProcess (Get-HarnessToolPath $dotnet) ('publish "'+(Get-HarnessToolPath (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj'))+'" --self-contained false -o "'+(Get-HarnessToolPath $helper)+'"'+$flags) 'theme-helper-build'|Out-Null
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 $wasdk=Join-Path $OutRoot 'wasdk';New-HarnessDirectory $wasdk 'generated-build'|Out-Null
 $build=Invoke-HarnessProcess (Get-HarnessToolPath $dotnet) ('build "'+(Get-HarnessToolPath $project)+'" -p:Platform=x64 -p:RuntimeIdentifier=win-x64 -p:SelfContained=false -p:WindowsAppSDKSelfContained=true -p:SelfContainedIntermediateOutputPath='+(Get-HarnessToolPath $wasdk)+'\'+$flags) 'theme-app-build'
 Check 'The WinUI app builds with zero warnings' ($build -match '0 Warning\(s\)' -and $build -match '0 Error\(s\)')
 $exe=@(Get-HarnessTree (Join-Path ([IO.Path]::GetDirectoryName($project)) 'bin') -FilesOnly|Where-Object {[IO.Path]::GetFileName($_.FullName) -ieq 'RooIndustries.OptimizationSuite.App.exe'}|ForEach-Object {$_.FullName})
 if($exe.Count -ne 1){throw ('Expected one built app, found '+$exe.Count)};$exe=$exe[0]

 $fixtureFolder=Join-Path $OutRoot ('fixture-'+$nonce);New-HarnessDirectory $fixtureFolder 'theme-fixture'|Out-Null
 $fixturePath=Join-Path $fixtureFolder 'ThemeFixture.exe';Copy-HarnessFile (Join-Path $env:SystemRoot 'System32\PING.EXE') $fixturePath|Out-Null
 $fixture=Start-OwnedProcess -FilePath $fixturePath -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -Purpose 'theme-fixture'
 (Get-Process -Id $fixture.Identity.pid).PriorityClass='Normal'
 Check 'The fixture starts at Normal priority' ((Priority) -eq 'Normal') (Priority)

 $values=[ordered]@{};if($settingsBytes){([Text.Encoding]::UTF8.GetString($settingsBytes)|ConvertFrom-Json).PSObject.Properties|ForEach-Object {$values[$_.Name]=[string]$_.Value}}
 $values['themeId']='roo-industries-blue';$settingsTouched=$true;[IO.File]::WriteAllText((Get-HarnessLongPath $settingsPath),($values|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
 $env:DOTNET_ROOT=Join-Path $env:USERPROFILE '.dotnet';$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:ROO_INDUSTRIES_TEST_APPLY_PAUSE_MS=[string]$PauseMs;$env:ROO_INDUSTRIES_TEST_THEME_KEYS=$keysFile
 $first=Launch
 AccentKeys 'A restart with Blue saved keeps none of the Blackout Gold accent colors' 'start' 'roo-industries-blue'
 Pass 'fresh-blue'

 Nav 'Remove apps';Tab 'RemovalTab'
 $list=WaitFor {$l=ById 'RemovalApps';if($l -and $l.Current.IsEnabled -and @($l.FindAll($TS::Children,(Of $CT::ListItem))).Count -ge 2){$l}} 240 'installed apps'
 foreach($item in @($list.FindAll($TS::Children,(Of $CT::ListItem)))[0..1]){(Pattern $item ([Windows.Automation.SelectionItemPattern])).AddToSelection();Start-Sleep -Milliseconds 300}
 Press 'RemovalPreview';WaitFor {(Text 'RemovalSelection') -match 'in this plan'} 120 'removal review'|Out-Null
 $removal=Removal

 Nav 'Windows tweaks';$search=WaitFor {$s=ById 'WindowsTweaksSearch';if($s -and $s.Current.IsEnabled){$s}} 300 'tweak search'
 (Pattern $search ([Windows.Automation.ValuePattern])).SetValue('Copilot');Start-Sleep -Seconds 2
 $toggle=WaitFor {@($script:window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.AutomationId -like '*.select' -and $_.Current.IsEnabled -and [string](Pattern $_ ([Windows.Automation.TogglePattern])).Current.ToggleState -eq 'Off'})|Select-Object -First 1} 60 'a change to pick'
 $pickId=$toggle.Current.AutomationId;(Pattern $toggle ([Windows.Automation.TogglePattern])).Toggle();Start-Sleep -Milliseconds 800
 $tweaks=Tweaks

 Nav 'Games';Tab 'ProcessesTab'
 Choose 'ProcessPicker' '*ThemeFixture*';WaitFor {$c=ById 'cpuPriority';$c -and $c.Current.IsEnabled} 90 'process controls'|Out-Null
 Choose 'cpuPriority' 'Above normal';Press 'ProcessPreview';WaitFor {$e=ById 'ProcessApply';$e -and $e.Current.IsEnabled} 120 'process review'|Out-Null
 $review=Text 'ProcessReview';Shot 'review' 'Games'

 $frames=Join-Path $evidence 'video-frames';New-HarnessDirectory $frames 'theme-video-frames'|Out-Null
 $recorder=[RooIndustriesTour.Recorder]::new((Get-HarnessLongPath $frames));$recorder.Window([IntPtr]$first,[int]$script:app.Identity.pid);Start-Sleep -Seconds 2
 Press 'ProcessApply';$applied=[DateTime]::UtcNow;Start-Sleep -Milliseconds 1200
 $start=$recorder.Count;Theme 'Blackout Gold';$switched=[DateTime]::UtcNow;$during=Priority
 Check 'The theme changed while the process change was still running' ($during -eq 'Normal' -and ($switched-$applied).TotalMilliseconds -lt $PauseMs) @{priorityAtSwitch=$during;secondsAfterApply=($switched-$applied).TotalSeconds}
 AccentKeys 'Switching Blue to Blackout Gold adds all seven Gold accent colors' 'switch' 'black-gold'
 $second=if(Alive){Attach}else{0};$rects=if(Alive){Private}else{@()}
 Check 'The window stays the same window after the theme change' ($second -eq $first) @{before=$first;after=$second}
 if(Alive){
  Nav 'Games';$hidden.Add([ordered]@{from=$start;to=$recorder.Count+15;rects=$rects});try{WaitFor {(Text 'ProcessStatus') -like 'Done.*'} ($PauseMs/1000+30) 'apply result'|Out-Null}catch{}
  Start-Sleep -Seconds 2;$process=ProcessState
  Check 'Games still shows the change that was running, with Undo' ($process.status -like 'Done.*' -and $process.restore) $process
 }
 Check 'The running change really finished' ((Priority) -eq 'AboveNormal') (Priority)
 Kept 'after Blue to Blackout Gold' $removal $tweaks
 $recorder.Dispose();$video=[ordered]@{folder='video-frames';frames=$recorder.Count;wallSeconds=$recorder.Seconds;fps=15};$recorder=$null
 if(Alive){Pass 'switched-gold'}

 if(Alive){
  Theme 'Blue';$third=Attach
  AccentKeys 'Switching Blackout Gold to Blue removes all seven Gold accent colors' 'switch' 'roo-industries-blue'
  Check 'The window stays the same after switching back to Blue' ($third -eq $first) @{before=$first;after=$third}
  Kept 'after switching back to Blue' $removal $tweaks
  $process=ProcessState;Check 'Games still shows the finished change after switching back' ($process.status -like 'Done.*' -and $process.restore) $process
  Pass 'switched-blue'
  Nav 'Games';if(($e=ById 'ProcessRestore') -and $e.Current.IsEnabled){Press 'ProcessRestore';try{WaitFor {(Text 'ProcessStatus') -eq 'Original controls restored.'} 60 'undo'|Out-Null}catch{}}
 }
 Check 'Undo on the Games page restores the fixture' ((Priority) -eq 'Normal') (Priority)

 if(-not(Alive)){$first=Launch}
 Theme 'Blackout Gold';Close
 $saved=([IO.File]::ReadAllText((Get-HarnessLongPath $settingsPath))|ConvertFrom-Json).themeId
 Check 'The chosen theme is saved' ($saved -eq 'black-gold') $saved
 Launch|Out-Null;AccentKeys 'A restart with Blackout Gold saved keeps all seven Gold accent colors' 'start' 'black-gold';Nav 'Settings';$picked=(Pattern (WaitFor {ById 'ThemePicker'} 30 'theme picker') ([Windows.Automation.SelectionPattern])).Current.GetSelection()[0].Current.Name
 Check 'A restart opens in the chosen theme' ($picked -eq 'Blackout Gold') $picked
 Pass 'fresh-gold'
 Close
 foreach($shot in @($shots|Where-Object {$_.pass -like 'switched-*'})){
  $theme=$shot.pass.Substring(9);$fresh=@($shots|Where-Object {$_.pass -eq 'fresh-'+$theme -and $_.page -eq $shot.page})[0];$foreign=if($theme -eq 'gold'){'blue'}else{'gold'}
  Check ('No '+$foreign+' accent left on '+$shot.page+' after switching to '+$theme) ($fresh -and $shot[$foreign] -le $fresh[$foreign]+200) @{switched=$shot[$foreign];fresh=$(if($fresh){$fresh[$foreign]})}
 }
}catch{$failure=Scrub ($_|Out-String);Say ('ERROR '+$failure)}
finally{
 $cleanup=[Collections.Generic.List[string]]::new()
 if($recorder){try{$recorder.Dispose();$video=[ordered]@{folder='video-frames';frames=$recorder.Count;wallSeconds=$recorder.Seconds;fps=15}}catch{$cleanup.Add($_.Exception.Message)}}
 try{Close}catch{$cleanup.Add('App: '+$_.Exception.Message)}
 try{if($fixture){Stop-HarnessProcess $fixture}}catch{$cleanup.Add('Fixture: '+$_.Exception.Message)}
 try{if($settingsTouched){$path=Get-HarnessLongPath $settingsPath;if($settingsBytes){[IO.File]::WriteAllBytes($path,$settingsBytes)}elseif([IO.File]::Exists($path)){[IO.File]::Delete($path)}}}catch{$cleanup.Add('Settings: '+$_.Exception.Message)}
 $passed=-not$failure -and -not$cleanup.Count -and $checks.Count -and -not@($checks|Where-Object {-not$_.passed}).Count
 Write-HarnessResult $evidence 'summary.json' ([ordered]@{status=$(if($passed){'pass'}else{'fail'});checks=$checks;shots=$shots;video=$video;privateFrames=$hidden;review=$review;failure=$failure;cleanupErrors=$cleanup})|Out-Null
 Write-HarnessResult $OutRoot 'receipt.json' @{status=$(if($passed){'pass'}else{'fail'});evidence=$evidence;checks=$checks.Count;failed=@($checks|Where-Object {-not$_.passed}).Count}|Out-Null
 Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
}
