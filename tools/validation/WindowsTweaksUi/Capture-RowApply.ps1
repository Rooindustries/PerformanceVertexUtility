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
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyExW(UIntPtr root,string path,int options,int access,out UIntPtr key);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueExW(UIntPtr key,string name,IntPtr reserved,out int type,byte[] data,ref int size);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegSetValueExW(UIntPtr key,string name,int reserved,int type,byte[] data,int size);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegDeleteValueW(UIntPtr key,string name);
 [DllImport("advapi32.dll")] static extern int RegCloseKey(UIntPtr key);
 static UIntPtr Root(string hive){if(hive=="CurrentUser")return new UIntPtr(0x80000001u);if(hive=="LocalMachine")return new UIntPtr(0x80000002u);throw new ArgumentException("Unsupported hive: "+hive);}
 static UIntPtr Open(string hive,string path,int access){UIntPtr key;int error=RegOpenKeyExW(Root(hive),path,0,access|0x0100,out key);if(error!=0)throw new Win32Exception(error);return key;}
 public static object[] Get(string hive,string path,string name){
  UIntPtr key;int error=RegOpenKeyExW(Root(hive),path,0,0x20019|0x0100,out key);
  if(error==2)return new object[]{false,false,0,null};
  if(error!=0)throw new Win32Exception(error);
  try{
   int type,size=0;error=RegQueryValueExW(key,name,IntPtr.Zero,out type,null,ref size);
   if(error==2)return new object[]{true,false,0,null};
   if(error!=0&&error!=234)throw new Win32Exception(error);
   byte[] data=new byte[size];error=RegQueryValueExW(key,name,IntPtr.Zero,out type,data,ref size);
   if(error!=0)throw new Win32Exception(error);
   Array.Resize(ref data,size);return new object[]{true,true,type,data};
  }finally{RegCloseKey(key);}
 }
 public static void Put(string hive,string path,string name,int type,byte[] data){UIntPtr key=Open(hive,path,0x20006);try{int error=RegSetValueExW(key,name,0,type,data,data.Length);if(error!=0)throw new Win32Exception(error);}finally{RegCloseKey(key);}}
 public static void Remove(string hive,string path,string name){UIntPtr key;int opened=RegOpenKeyExW(Root(hive),path,0,0x20006|0x0100,out key);if(opened==2)return;if(opened!=0)throw new Win32Exception(opened);try{int error=RegDeleteValueW(key,name);if(error!=0&&error!=2)throw new Win32Exception(error);}finally{RegCloseKey(key);}}
}
'@
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
function ReadValue($Address){$r=[RooIndustriesRowApply]::Get($Address.hive,$Address.keyPath,$Address.valueName);[ordered]@{keyExists=[bool]$r[0];exists=[bool]$r[1];type=$(if($r[1]){[int]$r[2]}else{$null});data=$(if($r[1]){[Convert]::ToBase64String([byte[]]$r[3])}else{$null})}}
function WriteValue($Address,$State){if($State.exists){[RooIndustriesRowApply]::Put($Address.hive,$Address.keyPath,$Address.valueName,[int]$State.type,[Convert]::FromBase64String([string]$State.data))}else{[RooIndustriesRowApply]::Remove($Address.hive,$Address.keyPath,$Address.valueName)}}
function Same($Left,$Right){$Left.exists -eq $Right.exists -and (-not$Left.exists -or ($Left.type -eq $Right.type -and $Left.data -ceq $Right.data))}
function Describe($State){if(-not$State.exists){return 'absent'};$bytes=[Convert]::FromBase64String([string]$State.data);switch([int]$State.type){4{if($bytes.Length -eq 4){return 'REG_DWORD '+[BitConverter]::ToUInt32($bytes,0)}};11{if($bytes.Length -eq 8){return 'REG_QWORD '+[BitConverter]::ToUInt64($bytes,0)}};{$_ -in 1,2}{return $(if($_ -eq 1){'REG_SZ '}else{'REG_EXPAND_SZ '})+'"'+[Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)+'"'}};return 'type '+$State.type+' '+[BitConverter]::ToString($bytes)}
function Snapshot([string]$Stage){$evidence.stages[$Stage]=[ordered]@{};foreach($value in $values){$state=ReadValue $value.address;$evidence.stages[$Stage][$value.address.valueName]=[ordered]@{state=$state;text=(Describe $state)}};return $evidence.stages[$Stage]}
function RegQuery([string]$Stage){$ErrorActionPreference='Continue';$lines=@(foreach($value in $values){$root=if($value.address.hive -eq 'CurrentUser'){'HKCU'}else{'HKLM'};& (Join-Path ([Environment]::SystemDirectory) 'reg.exe') query ($root+'\'+$value.address.keyPath) /v $value.address.valueName /reg:64 2>&1|ForEach-Object {[string]$_}});[IO.File]::WriteAllLines((Join-Path $directory ('reg-query-'+$Stage+'.txt')),$lines,[Text.UTF8Encoding]::new($false))}
function SettingsToggle([string]$Stage){
 if(-not$SettingsUri){return $null}
 if(@(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue).Count){throw 'Windows Settings is already open; this capture does not take over another window.'}
 $opened=[DateTime]::Now
 Start-Process $SettingsUri
 $settingsWindow=$null
 try{
  $settingsWindow=WaitFor {$A::RootElement.FindFirst($TS::Children,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::ClassNameProperty,'ApplicationFrameWindow'),[Windows.Automation.PropertyCondition]::new($A::NameProperty,'Settings')))} 60 'Windows Settings'
  $toggle=WaitFor {
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
  return $state
 }finally{
  if($settingsWindow){try{$settingsWindow.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}catch{}}
  Start-Sleep -Seconds 2
  foreach($process in @(Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue|Where-Object {$_.StartTime -ge $opened})){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
 }
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
if($TurnOff){
 $windows=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
 $build=[int]$windows.CurrentBuildNumber;$edition=[string]$windows.EditionID
 function Offered($Candidate){$gates=if($Candidate.availability){@($Candidate.availability)}else{@([pscustomobject]@{minimumBuild=$definition[0].minimumBuild;maximumBuild=$definition[0].maximumBuild;editions=$definition[0].editions})};@($gates|Where-Object {$build -ge $_.minimumBuild -and $build -le $_.maximumBuild -and @($_.editions|Where-Object {$edition -like $_}).Count}).Count -gt 0}
 $resets=@($definition[0].options|Where-Object {$_.name -in 'Remove this override','Windows default','Use Windows default','Not configured','source-default','Return to previous plan','Remove boot override' -and (Offered $_)})
 $resets=@($resets|Where-Object {$id=$_.id;-not@($definition[0].options|Where-Object {$_.replaces -ceq $id -and (Offered $_) -and -not@($_.availability|ForEach-Object {$_.editions}|Where-Object {$_ -eq '*'}).Count}).Count})
 if(-not$resets.Count -or $resets[0].id -cne $option[0].id){throw ('Switching this row off on '+$edition+' picks '+$(if($resets.Count){$resets[0].id}else{'no Windows default'})+', not '+$option[0].id)}
}
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
$parent='Software\RooIndustriesTweakTests';$fixture=$parent+'\'+[Guid]::NewGuid().ToString('N');$recovery=$fixture+'\Recovery'
$parentExisted=Test-Path -LiteralPath ('HKCU:\'+$parent)
$originals=@{}
$owned=@{}
$app=$null;$status='fail';$evidence.restored=$false
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this capture does not take over another window.'}
 foreach($value in $values){$state=ReadValue $value.address;$seed=$seeds[$value.address.valueName.ToUpperInvariant()];if(-not$state.keyExists -and ($value.expected.exists -or ($seed -and $seed.exists))){throw ('The key this choice writes is missing: '+$value.address.keyPath)};$originals[$value.address.valueName.ToUpperInvariant()]=$state}
 $evidence.values=@($values|ForEach-Object {[ordered]@{hive=$_.address.hive;keyPath=$_.address.keyPath;valueName=$_.address.valueName;expected=(Describe $_.expected)}})
 foreach($value in $values){$key=$value.address.valueName.ToUpperInvariant();$owned[$key]=@($value.expected)+@($seeds[$key]|Where-Object {$_});if($seeds.ContainsKey($key)){WriteValue $value.address $seeds[$key]}}
 $seeded=Snapshot 'seeded';RegQuery 'seeded'
 foreach($value in $values){$key=$value.address.valueName.ToUpperInvariant();if($seeds.ContainsKey($key)){Check (Same $seeded[$value.address.valueName].state $seeds[$key]) ('Seeded '+$value.address.valueName+' reads back as '+(Describe $seeds[$key]))}}
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
 (ById $window 'WindowsTweaksApply').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 $applied=WaitFor {$text=Status $window;if($text -in 'Windows settings saved','Profile saved' -or $text -like '*attention*' -or $text -like '*not confirmed*' -or $text -like '*failed*'){$text}} 180 'Apply to finish'
 Check ($applied -eq 'Windows settings saved') ('Apply finishes with Windows settings saved, saw: '+$applied)
 $current=WaitFor {$value=Current $window;if($value -ceq $Reads){$value}} 60 ('the row to read '+$Reads)
 Start-Sleep -Milliseconds 800
 $evidence.applied=[ordered]@{status=$applied;detail=(ById $window 'WindowsTweaksDetail').Current.Name;current=$current;texts=@(Texts (RowItem $window))}
 Shot $window 'applied'
 $after=Snapshot 'applied';RegQuery 'applied'
 foreach($value in $values){Check (Same $after[$value.address.valueName].state $value.expected) ('Windows reads '+$value.address.valueName+' as '+(Describe $value.expected)+' after Apply')}
 Start-Sleep -Seconds 10
 $held=Snapshot 'held'
 foreach($value in $values){Check (Same $held[$value.address.valueName].state $value.expected) ($value.address.valueName+' still reads '+(Describe $value.expected)+' ten seconds later')}
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
 (ById $window 'WindowsTweaksApply').GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 $undone=WaitFor {$text=Status $window;if($text -in 'Windows settings saved','Profile saved','Saved choices removed' -or $text -like '*attention*' -or $text -like '*not confirmed*' -or $text -like '*failed*'){$text}} 180 'Undo to finish'
 Check ($undone -eq 'Windows settings saved') ('Undo finishes with Windows settings saved, saw: '+$undone)
 $restoredCurrent=WaitFor {$value=Current $window;if($value -ceq $before){$value}} 60 ('the row to read '+$before+' again')
 Start-Sleep -Milliseconds 800
 $evidence.undone=[ordered]@{status=$undone;detail=(ById $window 'WindowsTweaksDetail').Current.Name;current=$restoredCurrent;undoAvailable=(ById $window 'WindowsTweaksRestore').Current.IsEnabled;texts=@(Texts (RowItem $window))}
 Shot $window 'undone'
 Check (-not$evidence.undone.undoAvailable) 'Nothing is left to undo after Undo'
 $back=Snapshot 'undone';RegQuery 'undone'
 foreach($value in $values){Check (Same $back[$value.address.valueName].state $seeded[$value.address.valueName].state) ('Undo puts '+$value.address.valueName+' back to '+$seeded[$value.address.valueName].text)}
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
  $evidence.restoreConflicts=@()
  $evidence.restoreErrors=@(foreach($value in $values){$key=$value.address.valueName.ToUpperInvariant();try{
   if(-not$originals.ContainsKey($key)){continue}
   $now=ReadValue $value.address
   if(Same $now $originals[$key]){continue}
   if(@($owned[$key]|Where-Object {Same $now $_}).Count){WriteValue $value.address $originals[$key]}else{$evidence.restoreConflicts+=@($value.address.valueName+' was changed by something else to '+(Describe $now)+'; left as it is')}
  }catch{$value.address.valueName+': '+$_.Exception.Message}})
  $evidence.restored=$evidence.restoreConflicts.Count -eq 0 -and @($values|Where-Object {$originals.ContainsKey($_.address.valueName.ToUpperInvariant()) -and -not(Same (ReadValue $_.address) $originals[$_.address.valueName.ToUpperInvariant()])}).Count -eq 0
  $evidence.originals=[ordered]@{};foreach($value in $values){$key=$value.address.valueName.ToUpperInvariant();if($originals.ContainsKey($key)){$evidence.originals[$value.address.valueName]=Describe $originals[$key]}}
  if(Test-Path -LiteralPath ('HKCU:\'+$fixture)){Remove-Item -LiteralPath ('HKCU:\'+$fixture) -Recurse -Force}
  if(-not$parentExisted -and (Test-Path -LiteralPath ('HKCU:\'+$parent))){$left=Get-Item -LiteralPath ('HKCU:\'+$parent);if($left.SubKeyCount -eq 0 -and $left.ValueCount -eq 0){Remove-Item -LiteralPath ('HKCU:\'+$parent) -Force}}
  $evidence.fixtureRemoved=-not(Test-Path -LiteralPath ('HKCU:\'+$fixture))
 }catch{$status='fail';$evidence.cleanupError=$_.Exception.Message;throw}finally{
  if(-not$evidence.restored -or $evidence.restoreErrors.Count -or -not$evidence.fixtureRemoved -or $evidence.leftoverProcesses.Count){$status='fail'}
  $evidence.status=$status
  Write-HarnessResult $directory 'capture.json' $evidence|Out-Null
  Write-Output ('ROO_INDUSTRIES_ROW_APPLY '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
