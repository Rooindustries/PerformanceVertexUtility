param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{1,40}$')][string]$Label,[ValidateSet('A1','S1')][string[]]$Rows=@('A1','S1'))
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Get-HarnessToolPath (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1'))
$nonce=Initialize-HarnessInvocation 'license-rows' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type -Namespace RooIndustriesLicenseRows -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);'
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$out=Join-Path $OutRoot $Label
if(Test-HarnessPath $out){throw 'The output folder already exists; use a new label.'}
Enter-HarnessHostLease
New-HarnessDirectory $out 'evidence'|Out-Null
$productName='Performance Vertex Utility'
$copyright='Copyright Roo Industries. Free and open source under the GNU General Public License, version 3. It comes with no warranty.'
$sourceLine='Source code and license: github.com/Rooindustries/PerformanceVertexUtility'
$installKey='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
$installDir=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite'
$results=[ordered]@{A1=[ordered]@{result='not run'};S1=[ordered]@{result='not run'}}
$steps=[Collections.Generic.List[object]]::new()

function Note([string]$Row,[string]$Step,$Detail){
 $steps.Add([ordered]@{row=$Row;step=$Step;timeUtc=[DateTime]::UtcNow.ToString('o');detail=$Detail})
 [Console]::Out.WriteLine($Row+' '+$Step+' :: '+(ConvertTo-Json $Detail -Compress -Depth 6))
}
function Poll([scriptblock]$Probe,[double]$Seconds){$until=[DateTime]::UtcNow.AddSeconds($Seconds);do{$value=& $Probe;if($value){return $value};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow -lt $until);$null}
function Children($Element){$walker=[Windows.Automation.TreeWalker]::ControlViewWalker;$child=$walker.GetFirstChild($Element);while($child){$child;$child=$walker.GetNextSibling($child)}}
function Visible($Root){@($Root.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {-not$_.Current.IsOffscreen})}
function Lines([string]$Text){($Text -replace "`r`n","`n" -replace "`r","`n").TrimEnd("`n")}
function TextOf($Element){
 $pattern=$null
 if($Element.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern,[ref]$pattern)){return $pattern.DocumentRange.GetText(-1)}
 ''
}
function Invoke($Element,[int]$ProcessId){
 if($Element.Current.ProcessId -ne $ProcessId){throw 'The control belongs to another process.'}
 $pattern=$null
 if($Element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke();return}
 if(-not[RooIndustriesLicenseRows.Native]::PostMessage([IntPtr]::new($Element.Current.NativeWindowHandle),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)){throw 'The button press could not be sent.'}
}
function Selection($Element){$pattern=$null;if($Element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern}}
function Installed{[ordered]@{uninstallKey=(Test-Path -LiteralPath $installKey);installFolder=(Test-HarnessPath $installDir)}}

function Build{
 $copy=Join-Path (Split-Path $Source) ('b-'+$Label)
 if(Test-HarnessPath $copy){throw 'The build copy already exists; use a new label.'}
 New-HarnessDirectory $copy 'build-source'|Out-Null
 foreach($file in Get-HarnessTree $Source -FilesOnly|Where-Object {Test-HarnessVisiblePath $_ $Source}){
  $relative=$file.FullName.Substring($Source.Length).TrimStart('\')
  if($relative -match '(^|\\)(obj|bin|artifacts|\.git)(\\|$)' -or $relative -eq 'source-verification.json'){continue}
  $destination=Join-Path $copy $relative
  [IO.Directory]::CreateDirectory((Get-HarnessLongPath ([IO.Path]::GetDirectoryName($destination))))|Out-Null
  [IO.File]::Copy($file.LongPath,(Get-HarnessLongPath $destination),$true)
 }
 $project=Join-Path $copy 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 $text=[IO.File]::ReadAllText((Get-HarnessLongPath $project))
 $found=[regex]::Matches($text,'<Version>(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?</Version>')
 if($found.Count -ne 1){throw 'Expected exactly one Version element in the app project.'}
 $headVersion=$found[0].Value.Substring(9).Replace('</Version>','')
 $version='{0}.{1}.{2}-licensecheck' -f $found[0].Groups[1].Value,$found[0].Groups[2].Value,([int]$found[0].Groups[3].Value+1)
 [IO.File]::WriteAllText((Get-HarnessLongPath $project),$text.Replace($found[0].Value,'<Version>'+$version+'</Version>'),[Text.UTF8Encoding]::new($false))
 Initialize-HarnessBuildFolders $copy
 $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $script=Join-Path $copy 'tools\scripts\Build-Release.ps1'
 $log=Invoke-HarnessProcess (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') ('-NoProfile -ExecutionPolicy Bypass -Command "& '''+$script+''' -UpdateFeedUrl ''''"') 'release-build'
 [IO.File]::WriteAllText((Join-Path $out 'release-build.log'),$log,[Text.UTF8Encoding]::new($false))
 $release=Join-Path $copy 'artifacts\release'
 $installer=Join-Path $release ('RooIndustries-OptimizationSuite-'+$version+'-setup.exe')
 $stage=Join-Path $release ('work-'+$version+'\stage')
 if(-not(Test-HarnessPath $installer) -or -not(Test-HarnessPath $stage)){throw 'The release build left no installer or layout.'}
 $layout=@(Get-HarnessTree $stage -FilesOnly|ForEach-Object {[ordered]@{path=$_.FullName.Substring($stage.Length+1);bytes=$_.Length}})
 [IO.File]::WriteAllText((Join-Path $out 'layout.json'),(ConvertTo-Json $layout -Depth 4),[Text.UTF8Encoding]::new($false))
 $build=[ordered]@{headVersion=$headVersion;buildVersion=$version;changedFromHead=@('the app project Version line');installer=$installer;sha256=(Get-HarnessFileSha256 $installer);stage=$stage;layoutFiles=$layout.Count}
 Note 'build' 'release built by Build-Release.ps1' $build
 $build
}

function RowA1($Build){
 $row=$results.A1;$exe=Join-Path $Build.stage ('app\RooIndustries.OptimizationSuite.App.exe')
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'Another app window is open; this run left it alone.'}
 $owned=Start-OwnedProcess -FilePath $exe -WindowStyle Normal -Purpose 'license-app' -WorkingDirectory (Split-Path $exe)
 $app=$owned.process
 try{
  $window=Poll {
   if($app.HasExited){throw ('The app exited during startup with code '+$app.ExitCode)}
   $w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id))
   if($w -and @($w.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {$_.Current.Name -ceq 'Settings'}).Count){$w}
  } 180
  if(-not$window){$row.result='invalid';$row.reason='The app window with its navigation never appeared.';return}
  $navItems=@($window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {Selection $_})
  $first=@($navItems|Where-Object {(Selection $_).Current.IsSelected}|ForEach-Object {$_.Current.Name})
  $settings=@($navItems|Where-Object {$_.Current.Name -ceq 'Settings'})
  $row.start=[ordered]@{pid=$app.Id;title=$window.Current.Name;selectedPage=$first;settingsItems=$settings.Count}
  Note 'A1' 'start' $row.start
  if($first.Count -ne 1 -or $first[0] -ceq 'Settings' -or $settings.Count -ne 1){$row.result='invalid';$row.reason='The app did not open on a first page other than Settings.';return}
  if($settings[0].Current.ProcessId -ne $app.Id){throw 'The Settings item belongs to another process.'}
  (Selection $settings[0]).Select()
  $about=Poll {@($window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'About'))|Where-Object {$_.Current.ControlType -eq $CT::Text})[0]} 30
  $selected=(Selection $settings[0]).Current.IsSelected
  $row.delivery=[ordered]@{settingsSelected=$selected;aboutFound=[bool]$about}
  Note 'A1' 'open Settings' $row.delivery
  if(-not$selected -or -not$about){$row.result='invalid';$row.reason='Settings did not open or its About panel could not be read.';return}
  $siblings=@(Children ([Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($about)))
  $index=-1;for($i=0;$i -lt $siblings.Count;$i++){if([Windows.Automation.Automation]::Compare($siblings[$i],$about)){$index=$i;break}}
  $after=@($siblings|Select-Object -Skip ($index+1)|Select-Object -First 4)
  $shown=@($after|ForEach-Object {[string]$_.Current.Name})
  $selectable=if($after.Count -ge 4){$pattern=$null;$after[3].TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern,[ref]$pattern)}else{$false}
  $row.observation=[ordered]@{afterAbout=$shown;fourthLineSelectable=$selectable}
  Note 'A1' 'About panel' $row.observation
  if($index -lt 0 -or $shown.Count -lt 4 -or -not$shown[0]){$row.result='invalid';$row.reason='The About panel lines could not be read.';return}
  $passed=$shown[0] -ceq $productName -and $shown[1] -cmatch '^Version \d+\.\d+\.\d+' -and $shown[2] -ceq $copyright -and $shown[3] -ceq $sourceLine
  $row.result=if($passed){'passed'}else{'failed'}
 }finally{
  if(-not$app.HasExited){
   try{$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,$app.Id)).GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}catch{}
   if(-not$app.WaitForExit(20000)){Stop-HarnessProcess $owned}
  }
 }
}

function WizardWindow($Owned){
 @($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'TWizardForm'))|Where-Object {Test-OwnedDescendant ([int]$_.Current.ProcessId) -Ancestor $Owned})
}
function Page($Window,[string]$License){
 $visible=Visible $Window
 $buttons=@($visible|Where-Object {$_.Current.ControlType -eq $CT::Button -or $_.Current.ClassName -ceq 'TNewButton'}|ForEach-Object {[ordered]@{name=[string]$_.Current.Name;enabled=$_.Current.IsEnabled;element=$_}})
 $viewers=@($visible|Where-Object {$_.Current.ClassName -match 'RichEdit'})
 $texts=@($viewers|ForEach-Object {Lines (TextOf $_)})
 [ordered]@{
  heading=@($visible|Where-Object {$_.Current.ControlType -eq $CT::Text -or $_.Current.ClassName -ceq 'TNewStaticText'}|ForEach-Object {[string]$_.Current.Name}|Where-Object {$_}|Select-Object -First 2)
  buttons=@($buttons|ForEach-Object {$_.name})
  next=@($buttons|Where-Object {$_.enabled -and $_.name -match '^&?Next\s*>?$'}|ForEach-Object {$_.element})|Select-Object -First 1
  install=@($buttons|Where-Object {$_.enabled -and $_.name -match '^&?Install$'}).Count -gt 0
  cancel=@($buttons|Where-Object {$_.enabled -and $_.name -match '^&?Cancel$'}|ForEach-Object {$_.element})|Select-Object -First 1
  choices=@($visible|Where-Object {$_.Current.ControlType -eq $CT::RadioButton -or $_.Current.ControlType -eq $CT::CheckBox -or $_.Current.ClassName -match '^TNew(RadioButton|CheckBox|CheckListBox)$'}|ForEach-Object {[string]$_.Current.Name})
  viewerChars=@($texts|ForEach-Object {$_.Length})
  license=@($texts|Where-Object {$_ -ceq $License}).Count -gt 0
  unread=@($texts|Where-Object {-not$_}).Count
 }
}

function RowS1($Build){
 $row=$results.S1
 $license=Lines ([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'LICENSE'))))
 if(@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '(?i)setup.*\.(exe|tmp)$'}).Count){throw 'Another setup is running; this run left it alone.'}
 $before=Installed
 $owned=Start-OwnedProcess -FilePath $Build.installer -WindowStyle Normal -Purpose 'hand-run-setup'
 $pages=[Collections.Generic.List[object]]::new()
 try{
  $window=Poll {@(WizardWindow $owned)[0]} 120
  $row.start=[ordered]@{installer=$Build.installer;sha256=$Build.sha256;arguments='';wizard=if($window){$window.Current.Name}else{$null};installedBefore=$before}
  Note 'S1' 'start' $row.start
  if(-not$window){$row.result='invalid';$row.reason='The setup wizard never appeared.';return}
  $previous=$null;$reached=$false
  for($n=1;$n -le 12 -and -not$reached;$n++){
   $page=Poll {$p=Page $window $license;$key=($p.heading+$p.buttons) -join '|';if($key -cne $previous -and ($p.next -or $p.install)){$p}} 30
   if(-not$page){Note 'S1' ('page '+$n+' controls') @($window.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition)|ForEach-Object {$_.Current.ControlType.ProgrammaticName+'|'+$_.Current.Name+'|'+$_.Current.ClassName+'|offscreen='+$_.Current.IsOffscreen+'|enabled='+$_.Current.IsEnabled});$row.result='invalid';$row.reason=('Page '+$n+' could not be read or offered neither Next nor Install.');return}
   $previous=($page.heading+$page.buttons) -join '|';$row.cancel=$page.cancel
   $record=[ordered]@{number=$n;heading=$page.heading;buttons=$page.buttons;choices=$page.choices;viewerChars=$page.viewerChars;showsLicense=$page.license;install=$page.install}
   $pages.Add($record);Note 'S1' ('page '+$n) $record
   if($page.unread){$row.pages=@($pages);$row.result='invalid';$row.reason=('The text on page '+$n+' could not be read.');return}
   if($page.install){$reached=$true;break}
   Invoke $page.next ([int]$window.Current.ProcessId)
  }
  $row.pages=@($pages)
  if(-not$reached){$row.result='invalid';$row.reason='The wizard never reached the page with Install.';return}
  $licensePages=@($pages|Where-Object {$_.showsLicense -and -not$_.install -and $_.buttons -match '^&?Next\s*>?$' -and $_.choices.Count -eq 0})
  $row.observation=[ordered]@{pagesBeforeInstall=$pages.Count-1;licensePages=@($licensePages|ForEach-Object {$_.number});licenseChars=$license.Length}
  Note 'S1' 'wizard observed' $row.observation
  $row.result=if($licensePages.Count -ge 1){'passed'}else{'failed'}
 }finally{
  $cancel=$row['cancel'];$row.Remove('cancel')
  if($cancel -and -not$owned.process.HasExited){
   Invoke $cancel ([int]$cancel.Current.ProcessId)
   $yes=Poll {@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'#32770'))|Where-Object {Test-OwnedDescendant ([int]$_.Current.ProcessId) -Ancestor $owned}|ForEach-Object {$_.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Yes'))}|Where-Object {$_})[0]} 15
   if($yes){Invoke $yes ([int]$yes.Current.ProcessId)}
  }
  if(-not$owned.process.WaitForExit(30000)){Stop-HarnessProcess $owned}
  $row.installedAfter=Installed
  Note 'S1' 'setup closed' @{exited=$owned.process.HasExited;installedBefore=$before;installedAfter=$row.installedAfter}
  if(($row.installedAfter|ConvertTo-Json) -cne ($before|ConvertTo-Json)){$row.result='invalid';$row.reason='Setup changed the install state.'}
 }
}

try{
 $build=Build
 foreach($name in $Rows){
  try{if($name -eq 'A1'){RowA1 $build}else{RowS1 $build}}
  catch{$results[$name].result='invalid';$results[$name].reason=$_.Exception.Message;Note $name 'error' $_.ScriptStackTrace}
 }
}catch{
 Note 'build' 'error' $_.Exception.Message
}finally{
 [IO.File]::WriteAllText((Join-Path $out 'results.json'),(ConvertTo-Json @{label=$Label;rows=$results;steps=$steps} -Depth 10),[Text.UTF8Encoding]::new($false))
 foreach($name in 'A1','S1'){Write-Output ('ROW '+$name+' '+$results[$name].result+$(if($results[$name].reason){' :: '+$results[$name].reason}))}
 Complete-HarnessInvocation $(if(@($Rows|Where-Object {$results[$_].result -ne 'passed'}).Count){'fail'}else{'pass'}) -Cleanup|Out-Null
}
$notPassed=@('A1','S1'|Where-Object {$results[$_].result -ne 'passed'})
if($notPassed.Count){throw ('Rows not passed: '+($notPassed -join ', '))}
