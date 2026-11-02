param(
 [Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label,
 [Parameter(Mandatory)][string]$Search,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$SettingId,[Parameter(Mandatory)][string]$Choice,
 [string]$Seed='',[string]$SettingsUri='',[string]$SettingsGroup='',[string]$SettingsToggle='',[ValidateSet('','On','Off')][string]$SettingsApplied='',[ValidateSet('','On','Off')][string]$SettingsRestored='',[switch]$ReadOnly,[switch]$TurnOff,[string]$Reads=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('row-apply-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('row-apply-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.ComponentModel; using System.Runtime.InteropServices;
public static class RooIndustriesRowApply {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
. (Join-Path $Source 'tools\validation\WindowsTweaksUi\RowApplyJournal.ps1')
[RooIndustriesRowApply]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$evidence=[ordered]@{label=$Label;settingId=$SettingId;choice=$Choice;seed=$Seed;values=@();stages=[ordered]@{};settings=[ordered]@{};checks=@()}
function WaitFor([scriptblock]$Probe,[double]$Limit,[string]$What,$Dump=$null){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};if($Dump){Tree $Dump}else{foreach($w in @($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$(if($app){$app.Identity.pid}else{0}))))){Tree $w}};throw ('Timed out waiting for '+$What)}
function Tree($Root){$items=@(foreach($element in @($Root.FindAll($TS::Descendants,[Windows.Automation.Condition]::TrueCondition))){try{[ordered]@{type=$element.Current.ControlType.ProgrammaticName;name=$element.Current.Name;id=$element.Current.AutomationId;offscreen=$element.Current.IsOffscreen;patterns=@($element.GetSupportedPatterns()|ForEach-Object {$_.ProgrammaticName})}}catch{}});[IO.File]::WriteAllText((Join-Path $directory ('tree-'+[DateTime]::UtcNow.ToString('HHmmss')+'.json')),(ConvertTo-Json -InputObject $items -Depth 5),[Text.UTF8Encoding]::new($false))}
function ById($Root,[string]$Id){$Root.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Texts($Root){@($Root.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text))|ForEach-Object {$_.Current.Name}|Where-Object {$_})}
function RowItem($Window){
 $item=ById $Window ($SettingId+'.details');if(-not$item){return $null}
 $walker=[Windows.Automation.TreeWalker]::ControlViewWalker
 while($item -and $item.Current.ControlType -ne $CT::ListItem){$item=$walker.GetParent($item)}
 return $item
}
function Current($Window){$item=RowItem $Window;if(-not$item){return $null};$text=@(Texts $item|Where-Object {$_ -like '*: current value *'}|Select-Object -First 1);if(-not$text.Count){return $null};return $text[0].Substring($text[0].IndexOf(': current value ')+16)}
function Status($Window){(ById $Window 'WindowsTweaksStatus').Current.Name}
function ReviewLines($Window){$review=ById $Window 'WindowsTweaksReview';if(-not$review){return @()};@(Texts $review|Where-Object {$_ -ne 'Review changes'})}
function Shot($Window,[string]$Name){
 $r=$Window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $directory ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
}
function Check([bool]$Condition,[string]$Name){$evidence.checks+=@([ordered]@{name=$Name;passed=$Condition});if(-not$Condition){throw ('Check failed: '+$Name)};Write-Output ('PASS '+$Name)}
function Snapshot([string]$Stage){$evidence.stages[$Stage]=[ordered]@{};foreach($value in $values){$state=ReadValue $value.address;$evidence.stages[$Stage][(AddressKey $value.address)]=[ordered]@{state=$state;text=(Describe $state)}};return $evidence.stages[$Stage]}
function RegQuery([string]$Stage){$ErrorActionPreference='Continue';$lines=@(foreach($value in $values){$root=if($value.address.hive -eq 'CurrentUser'){'HKCU'}else{'HKLM'};& (Join-Path ([Environment]::SystemDirectory) 'reg.exe') query ($root+'\'+$value.address.keyPath) /v $value.address.valueName /reg:64 2>&1|ForEach-Object {[string]$_}});[IO.File]::WriteAllLines((Join-Path $directory ('reg-query-'+$Stage+'.txt')),$lines,[Text.UTF8Encoding]::new($false))}
function SystemErrors{@($A::RootElement.FindAll($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'#32770'))|Where-Object {$_.Current.Name -like '* - System Error'}|ForEach-Object {$_.Current.Name})}
function SettingsPopups($Since){@(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Application Popup';Id=26;StartTime=$Since} -ErrorAction SilentlyContinue|Where-Object {$_.Message -like '*SystemSettings.exe*'}|ForEach-Object {$_.TimeCreated.ToString('HH:mm:ss')+' '+($_.Message -replace '\s+',' ')})}
function SettingsToggle([string]$Stage){
 if(-not$SettingsUri){return $null}
 if(@(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue).Count){throw 'Windows Settings is already open; this capture does not take over another window.'}
 # Settings starts through the shell rather than as a child of this script, so every SystemSettings that starts after the launch belongs to this capture.
 $opened=[DateTime]::Now;$owned=@{};$settingsWindow=$null;$state=$null;$popups=@()
 function Own{foreach($process in @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue|Where-Object {$_.StartTime -ge $opened})){$owned[$process.Id]=$process}}
 try{
  Start-Process $SettingsUri
  $settingsWindow=WaitFor {Own;$A::RootElement.FindFirst($TS::Children,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'ApplicationFrameWindow'),[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings')))} 60 'Windows Settings'
  $toggle=WaitFor {
   Own
   $found=@($settingsWindow.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::IsTogglePatternAvailableProperty,$true))|Where-Object {$_.Current.Name -like $SettingsToggle})
   if($found.Count){$found[0]}else{
    if($SettingsGroup){foreach($group in @($settingsWindow.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::IsExpandCollapsePatternAvailableProperty,$true))|Where-Object {$_.Current.Name -like $SettingsGroup})){$pattern=$group.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern);if($pattern.Current.ExpandCollapseState -eq [Windows.Automation.ExpandCollapseState]::Collapsed){$pattern.Expand()}}}
    foreach($pane in @($settingsWindow.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::IsScrollPatternAvailableProperty,$true)))){$scroll=$pane.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern);if($scroll.Current.VerticallyScrollable){$scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll,100)}}
    $null
   }
  } 60 ('the Windows Settings switch named like '+$SettingsToggle) $settingsWindow
  try{$toggle.GetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()}catch{}
  $state=[string]$toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
  $settingsHandle=[IntPtr]::new([long]$settingsWindow.Current.NativeWindowHandle)
  [RooIndustriesRowApply]::SetForegroundWindow($settingsHandle)|Out-Null
  Start-Sleep -Milliseconds 1200
  Shot $settingsWindow ('settings-'+$Stage)
  $evidence.settings[$Stage]=[ordered]@{switch=$toggle.Current.Name;state=$state}
 }finally{
  Own
  if($settingsWindow){try{$settingsWindow.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}catch{}}
  $deadline=[DateTime]::UtcNow.AddSeconds(20);while(@($owned.Values|Where-Object {-not$_.HasExited}).Count -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
  foreach($process in @($owned.Values|Where-Object {-not$_.HasExited})){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
  $reports=@(if($owned.Count){Get-CimInstance Win32_Process -Filter "Name='WerFault.exe' or Name='WerFaultSecure.exe'"|Where-Object {$_.CommandLine -match ('\s-p\s+('+(@($owned.Keys) -join '|')+')(\s|$)')}})
  foreach($report in $reports){Stop-Process -Id $report.ProcessId -Force -ErrorAction SilentlyContinue}
  # Windows itself (csrss) shows a system error that Settings raises, and this capture can't close it, so the run reports it and fails.
  $popups=@(SettingsPopups $opened)
  $evidence.settings[$Stage+'-cleanup']=[ordered]@{processes=@($owned.Keys);errorReports=@($reports|ForEach-Object {$_.ProcessId});systemErrors=$popups}
 }
 Check (-not$popups.Count) ('Windows Settings opens without a system error, saw: '+($popups -join '; '))|Out-Host
 return $state
}
$catalog=Get-Content -Raw -LiteralPath (Join-Path $Source 'backend\catalogs\windows-tweaks.json')|ConvertFrom-Json
$definition=@($catalog.settings|Where-Object {$_.id -ceq $SettingId})
if($definition.Count -ne 1){throw ('Unknown setting: '+$SettingId)}
$option=@($definition[0].options|Where-Object {$_.id -ceq $Choice -or $_.name -ceq $Choice})
if($option.Count -ne 1){throw ('The setting has no single choice with this ID or name: '+$Choice)}
$shown=if($option[0].name -in 'Remove this override','Not configured'){'Use Windows default'}else{$option[0].name}
if(-not$Reads){$Reads=$shown}
$values=@(foreach($change in $option[0].changes){
 if($change.address.kind -ne 'value' -or $change.address.view -ne 'Registry64' -or $change.selector -or $change.token -or $change.bits -or $change.formula){throw 'This capture covers plain registry values only.'}
 $expected=if($change.value){[ordered]@{keyExists=$true;exists=$true;type=[int]$change.value.type;data=[string]$change.value.bytes}}elseif($null -ne $change.dword){[ordered]@{keyExists=$true;exists=$true;type=4;data=[Convert]::ToBase64String([BitConverter]::GetBytes([uint32]$change.dword))}}else{[ordered]@{keyExists=$true;exists=$false;type=$null;data=$null}}
 [pscustomobject]@{address=$change.address;expected=$expected}
})
$seeds=@{}
foreach($part in @($Seed.Split(';')|ForEach-Object {$_.Trim()}|Where-Object {$_})){
 $name,$spec=$part.Split('=',2)
 if(-not@($values|Where-Object {$_.address.valueName -ieq $name}).Count){throw ('The seed names a value this choice does not write: '+$name)}
 $seeds[$name.ToUpperInvariant()]=switch -Regex($spec){
  '^absent$'{[ordered]@{exists=$false;type=$null;data=$null}}
  '^dword:(\d+)$'{[ordered]@{exists=$true;type=4;data=[Convert]::ToBase64String([BitConverter]::GetBytes([uint32]$Matches[1]))}}
  '^sz:(.*)$'{[ordered]@{exists=$true;type=1;data=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Matches[1]+[char]0))}}
  default{throw ('Unknown seed: '+$part)}
 }
}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$parent='Software\RooIndustriesTweakTests';$fixture=$parent+'\'+[Guid]::NewGuid().ToString('N');$recovery=$fixture+'\Recovery';$journal=$parent+'\RowApplyRecovery'
function DropJournal([bool]$OwnsParent){
 if(Test-Path -LiteralPath ('HKCU:\'+$journal)){Remove-Item -LiteralPath ('HKCU:\'+$journal) -Force}
 if($OwnsParent -and (Test-Path -LiteralPath ('HKCU:\'+$parent))){$left=Get-Item -LiteralPath ('HKCU:\'+$parent);if($left.SubKeyCount -eq 0 -and $left.ValueCount -eq 0){Remove-Item -LiteralPath ('HKCU:\'+$parent) -Force}}
}
$parentExisted=Test-Path -LiteralPath ('HKCU:\'+$parent)
$originals=@{}
$record=$null
$app=$null;$status='fail';$evidence.restored=$false
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this capture does not take over another window.'}
 if(@(SystemErrors).Count){throw ('A system error dialog is open and would cover the screenshots: '+((SystemErrors) -join '; '))}
 $previous=Get-ItemProperty -LiteralPath ('HKCU:\'+$journal) -Name 'Record' -ErrorAction SilentlyContinue
 if($previous){
  $left=ConvertFrom-Json $previous.Record
  $evidence.previousRun=Recover $left
  if($evidence.previousRun.errors.Count){throw ('A stopped capture left values this run could not restore: '+($evidence.previousRun.errors -join '; '))}
  $parentExisted=[bool]$left.parentExisted
  DropJournal $false
 }
 foreach($value in $values){$state=ReadValue $value.address;$seed=$seeds[$value.address.valueName.ToUpperInvariant()];if(-not$state.keyExists -and ($value.expected.exists -or ($seed -and $seed.exists))){throw ('The key this choice writes is missing: '+$value.address.keyPath)};$originals[(AddressKey $value.address)]=$state}
 $evidence.values=@($values|ForEach-Object {[ordered]@{hive=$_.address.hive;keyPath=$_.address.keyPath;valueName=$_.address.valueName;expected=(Describe $_.expected)}})
 $record=[ordered]@{parentExisted=$parentExisted;values=@(foreach($value in $values){[ordered]@{hive=$value.address.hive;keyPath=$value.address.keyPath;valueName=$value.address.valueName;original=(State $originals[(AddressKey $value.address)]);written=$null;pending=$null}})}
 $entries=@{};foreach($entry in $record.values){$entries[(AddressKey $entry)]=$entry}
 SaveJournal $record
 foreach($value in $values){$name=$value.address.valueName.ToUpperInvariant();$key=AddressKey $value.address;if($seeds.ContainsKey($name)){Mark $entries[$key] $seeds[$name];SaveJournal $record;WriteValue $value.address $seeds[$name];Mark $entries[$key] $seeds[$name] -Done;SaveJournal $record}}
 $seeded=Snapshot 'seeded';RegQuery 'seeded'
 foreach($value in $values){$key=$value.address.valueName.ToUpperInvariant();if($seeds.ContainsKey($key)){Check (Same $seeded[(AddressKey $value.address)].state $seeds[$key]) ('Seeded '+$value.address.valueName+' reads back as '+(Describe $seeds[$key]))}}
 if($SettingsRestored){Check ((SettingsToggle 'seeded') -eq $SettingsRestored) ('Windows Settings shows '+$SettingsToggle+' '+$SettingsRestored+' before the change')}
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin\optimizer')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 $env:ROO_INDUSTRIES_TEST_TWEAK_RECOVERY=$recovery;$env:ROO_INDUSTRIES_INITIAL_NAV='windows';$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:DOTNET_ROOT=Split-Path $dotnet -Parent
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $window=WaitFor {$w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid));if($w -and (ById $w 'WindowsTweaksSearch')){$w}} 180 'the Windows tweaks page'
 $hwnd=[IntPtr]::new([long]$window.Current.NativeWindowHandle)
 WaitFor {ById $window 'WindowsTweaksList'} 120 'the Windows tweaks list'|Out-Null
 $advanced=WaitFor {$window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,'Show advanced options'),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::CheckBox)))} 60 'the advanced options switch'
 $toggle=$advanced.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$toggle.Toggle()}
 (ById $window 'WindowsTweaksSearch').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Search)
 $before=WaitFor {$value=Current $window;if($value -and $value -notlike 'Checking*' -and $value -notin 'Not checked','Not read'){$value}} 240 'the row to finish loading'
 if(-not$ReadOnly){Check ($before -notin "Couldn't check",'Not available here') ('The row reads its value on this PC, saw: '+$before)}
 # The page keeps every row's controls disabled until it finishes reading Windows features.
 WaitFor {$switch=ById $window ($SettingId+'.select');$picker=ById $window ($SettingId+'.value');$switch -and $switch.Current.IsEnabled -and (-not$picker -or $picker.Current.IsOffscreen -or $picker.Current.IsEnabled)} 240 'the row to accept changes'|Out-Null
 WaitFor {$text=Status $window;if($text -and $text -notlike '*checking Windows features*'){$text}} 240 'the page to finish reading Windows features'|Out-Null
 [RooIndustriesRowApply]::SetWindowPos($hwnd,[IntPtr]::new(-1),0,0,0,0,0x0003)|Out-Null
 [RooIndustriesRowApply]::SetForegroundWindow($hwnd)|Out-Null
 Start-Sleep -Milliseconds 1500
 $row=RowItem $window
 $evidence.before=[ordered]@{current=$before;texts=@(Texts $row)}
 Shot $window 'row-before'
 if($ReadOnly){$window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null;$status='pass';return}
 $picker=ById $window ($SettingId+'.value')
 $select=(ById $window ($SettingId+'.select')).GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
 if($TurnOff){Check ($select.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) ('The row reads as on before it is switched off, saw: '+$before);$select.Toggle()}
 elseif($picker -and -not$picker.Current.IsOffscreen){
  $picker.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
  $item=WaitFor {@($picker.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem))|Where-Object {$_.Current.Name -ceq $shown -or (Texts $_) -contains $shown})[0]} 20 ('the '+$shown+' choice')
  $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
  try{$picker.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()}catch{}
 }else{Check ((Texts $row) -contains $shown) ('The row offers '+$shown+' on this PC')}
 if(-not$TurnOff -and $select.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$select.Toggle()}
 Start-Sleep -Milliseconds 800
 (ById $window 'WindowsTweaksPreview').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 $approval=WaitFor {$box=ById $window 'WindowsTweaksApproval';if($box -and $box.Current.IsEnabled -and -not$box.Current.IsOffscreen -and (ReviewLines $window).Count){$box}} 120 'the review of the change'
 $evidence.reviewApply=[ordered]@{status=(Status $window);lines=@(ReviewLines $window)}
 Shot $window 'review-apply'
 $approval.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
 foreach($value in $values){Mark $entries[(AddressKey $value.address)] $value.expected};SaveJournal $record
 (ById $window 'WindowsTweaksApply').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 $applied=WaitFor {$text=Status $window;if($text -in 'Windows settings saved','Profile saved' -or $text -like '*attention*' -or $text -like '*not confirmed*' -or $text -like '*failed*'){$text}} 180 'Apply to finish'
 Check ($applied -eq 'Windows settings saved') ('Apply finishes with Windows settings saved, saw: '+$applied)
 $current=WaitFor {$value=Current $window;if($value -ceq $Reads){$value}} 60 ('the row to read '+$Reads)
 Start-Sleep -Milliseconds 800
 $evidence.applied=[ordered]@{status=$applied;detail=(ById $window 'WindowsTweaksDetail').Current.Name;current=$current;texts=@(Texts (RowItem $window))}
 Shot $window 'applied'
 $after=Snapshot 'applied';RegQuery 'applied'
 foreach($value in $values){Check (Same $after[(AddressKey $value.address)].state $value.expected) ('Windows reads '+$value.address.valueName+' as '+(Describe $value.expected)+' after Apply')}
 foreach($value in $values){Mark $entries[(AddressKey $value.address)] $value.expected -Done};SaveJournal $record
 Start-Sleep -Seconds 10
 $held=Snapshot 'held'
 foreach($value in $values){Check (Same $held[(AddressKey $value.address)].state $value.expected) ($value.address.valueName+' still reads '+(Describe $value.expected)+' ten seconds later')}
 [RooIndustriesRowApply]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 if($SettingsApplied){Check ((SettingsToggle 'applied') -eq $SettingsApplied) ('Windows Settings shows '+$SettingsToggle+' '+$SettingsApplied+' after Apply')}
 [RooIndustriesRowApply]::SetWindowPos($hwnd,[IntPtr]::new(-1),0,0,0,0,0x0003)|Out-Null
 [RooIndustriesRowApply]::SetForegroundWindow($hwnd)|Out-Null
 (ById $window 'WindowsTweaksRestore').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 $approval=WaitFor {$box=ById $window 'WindowsTweaksApproval';if($box -and $box.Current.IsEnabled -and -not$box.Current.IsOffscreen -and (ReviewLines $window).Count){$box}} 120 'the review of Undo'
 Start-Sleep -Milliseconds 800
 $evidence.reviewUndo=[ordered]@{status=(Status $window);lines=@(ReviewLines $window)}
 Shot $window 'review-undo'
 $approval.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
 foreach($value in $values){Mark $entries[(AddressKey $value.address)] $seeded[(AddressKey $value.address)].state};SaveJournal $record
 (ById $window 'WindowsTweaksApply').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 $undone=WaitFor {$text=Status $window;if($text -in 'Windows settings saved','Profile saved','Saved choices removed' -or $text -like '*attention*' -or $text -like '*not confirmed*' -or $text -like '*failed*'){$text}} 180 'Undo to finish'
 Check ($undone -eq 'Windows settings saved') ('Undo finishes with Windows settings saved, saw: '+$undone)
 $restoredCurrent=WaitFor {$value=Current $window;if($value -ceq $before){$value}} 60 ('the row to read '+$before+' again')
 Start-Sleep -Milliseconds 800
 $evidence.undone=[ordered]@{status=$undone;detail=(ById $window 'WindowsTweaksDetail').Current.Name;current=$restoredCurrent;undoAvailable=(ById $window 'WindowsTweaksRestore').Current.IsEnabled;texts=@(Texts (RowItem $window))}
 Shot $window 'undone'
 Check (-not$evidence.undone.undoAvailable) 'Nothing is left to undo after Undo'
 $back=Snapshot 'undone';RegQuery 'undone'
 foreach($value in $values){Check (Same $back[(AddressKey $value.address)].state $seeded[(AddressKey $value.address)].state) ('Undo puts '+$value.address.valueName+' back to '+$seeded[(AddressKey $value.address)].text)}
 foreach($value in $values){Mark $entries[(AddressKey $value.address)] $seeded[(AddressKey $value.address)].state -Done};SaveJournal $record
 [RooIndustriesRowApply]::SetWindowPos($hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 if($SettingsRestored){Check ((SettingsToggle 'undone') -eq $SettingsRestored) ('Windows Settings shows '+$SettingsToggle+' '+$SettingsRestored+' after Undo')}
 $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 $status='pass'
}catch{
 $evidence.error=$_.Exception.Message
 throw
}finally{
 try{
  if($app){Stop-HarnessProcess $app}
  $deadline=[DateTime]::UtcNow.AddSeconds(90)
  do{$left=@(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -ne $PID -and (($_.ExecutablePath -and $_.ExecutablePath.StartsWith($Source+'\',[StringComparison]::OrdinalIgnoreCase)) -or ($_.CommandLine -and $_.CommandLine.IndexOf($Source,[StringComparison]::OrdinalIgnoreCase) -ge 0))});if($left.Count){Start-Sleep -Seconds 2}}while($left.Count -and [DateTime]::UtcNow -lt $deadline)
  $evidence.leftoverProcesses=@($left|ForEach-Object {$_.Name+' '+$_.ProcessId})
  $evidence.restoreConflicts=@();$evidence.restoreErrors=@()
  if($record){$cleanup=Recover $record;$evidence.restoreConflicts=@($cleanup.conflicts);$evidence.restoreErrors=@($cleanup.errors);$evidence.restoredByCleanup=@($cleanup.restored)}
  $evidence.restored=$null -ne $record -and $evidence.restoreConflicts.Count -eq 0 -and $evidence.restoreErrors.Count -eq 0 -and @($record.values|Where-Object {-not(Same (ReadValue $_) $_.original)}).Count -eq 0
  $evidence.originals=[ordered]@{};foreach($value in $values){$key=AddressKey $value.address;if($originals.ContainsKey($key)){$evidence.originals[$key]=Describe $originals[$key]}}
  if(Test-Path -LiteralPath ('HKCU:\'+$fixture)){Remove-Item -LiteralPath ('HKCU:\'+$fixture) -Recurse -Force}
  if($record -and -not$evidence.restoreErrors.Count){DropJournal (-not$parentExisted)}
  $evidence.fixtureRemoved=-not(Test-Path -LiteralPath ('HKCU:\'+$fixture))
 }catch{$status='fail';$evidence.cleanupError=$_.Exception.Message;throw}finally{
  if(-not$evidence.restored -or $evidence.restoreErrors.Count -or ($evidence.previousRun -and $evidence.previousRun.conflicts.Count) -or -not$evidence.fixtureRemoved -or $evidence.leftoverProcesses.Count){$status='fail'}
  $evidence.status=$status
  Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
  Write-Output ('ROO_INDUSTRIES_ROW_APPLY '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
