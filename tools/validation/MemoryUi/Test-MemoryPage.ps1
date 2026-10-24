param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[ValidatePattern('^[a-z][a-z0-9-]{0,30}$')][string]$Label='memory')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('memory-page-'+$Label) $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('memory-page-'+$Label)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class RooIndustriesMemoryPage {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
}
'@
[RooIndustriesMemoryPage]::SetProcessDPIAware()|Out-Null
$A=[Windows.Automation.AutomationElement];$TS=[Windows.Automation.TreeScope];$CT=[Windows.Automation.ControlType]
$words=[IO.File]::ReadAllText((Join-Path $Source 'tools\validation\MemoryUi\plain-words.json'))|ConvertFrom-Json
$banned=@($words.banned|ForEach-Object {
 $options=if($_.caseSensitive){[Text.RegularExpressions.RegexOptions]::None}else{[Text.RegularExpressions.RegexOptions]::IgnoreCase}
 [pscustomobject]@{regex=[regex]::new($_.pattern,$options);why=$_.why}
})
$appSource=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App'
$guideTitles=@(([IO.File]::ReadAllText((Join-Path $appSource 'Assets\Guides\memory-guides.json'))|ConvertFrom-Json).guides|ForEach-Object {$_.title})
$toolTitles=@([regex]::Matches([IO.File]::ReadAllText((Join-Path $appSource 'ViewModels\MemoryLatencyViewModel.cs')),'DiagnosticRows\.Add\(new\("([^"]+)"')|ForEach-Object {$_.Groups[1].Value})
$fault="[Console]::Error.WriteLine('Get-CimInstance : Access denied (HRESULT 0x80070005)')`r`nexit 5`r`n"
$rawParts=@('Access denied','HRESULT','0x80070005','(code 5)')
$evidence=[ordered]@{label=$Label;checks=@();shots=@();shown=[ordered]@{}}
function Check([bool]$Ok,[string]$Name,[string]$Detail=''){$script:evidence.checks+=@([ordered]@{pass=$Ok;name=$Name;detail=$Detail})}
function WaitFor([scriptblock]$Probe,[double]$Limit){$deadline=[DateTime]::UtcNow.AddSeconds($Limit);while([DateTime]::UtcNow -lt $deadline){try{$value=& $Probe}catch{$value=$null};if($value){return $value};Start-Sleep -Milliseconds 200};return $null}
function ById([string]$Id){$script:window.FindFirst($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,$Id))}
function Visible($Element){$Element -and -not $Element.Current.IsOffscreen}
function Shown{
 $kinds=[Windows.Automation.OrCondition]::new([Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Text),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Button),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::Group))
 @($script:window.FindAll($TS::Descendants,$kinds)|Where-Object {$_.Current.AutomationId -ne 'MemoryAppName'}|ForEach-Object {$_.Current.Name}|Where-Object {$_}|Select-Object -Unique)
}
function HasText([string]$Text){@(Shown) -contains $Text}
function Scan([string]$When){
 $texts=@(Shown);$script:evidence.shown[$When]=$texts
 $found=@(foreach($text in $texts){foreach($rule in $banned){if($rule.regex.IsMatch($text)){'"'+$text+'" shows '+$rule.why}}})
 Check ($found.Count -eq 0) ('the Memory screen shows no jargon, raw values or raw errors '+$When) (($found|Select-Object -First 10) -join ' | ')
}
function Shot([string]$Name){
 [RooIndustriesMemoryPage]::SetForegroundWindow($script:hwnd)|Out-Null;Start-Sleep -Milliseconds 700
 $r=$script:window.Current.BoundingRectangle
 $bitmap=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen([int]$r.X,[int]$r.Y,0,0,$bitmap.Size);$bitmap.Save((Join-Path $directory ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 $script:evidence.shots+=@($Name+'.png')
}
function Guide([string]$Title){$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$Title),[Windows.Automation.PropertyCondition]::new($A::IsExpandCollapsePatternAvailableProperty,$true)))}
function Scrolls($Element){[bool]$Element.GetCurrentPropertyValue($A::IsScrollPatternAvailableProperty) -and $Element.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.VerticallyScrollable}
function Scroller{$e=Guide $guideTitles[0];$walker=[Windows.Automation.TreeWalker]::ControlViewWalker;while($e -and -not (Scrolls $e)){$e=$walker.GetParent($e)};$e}
function ScrollTo([double]$Percent){$s=Scroller;if(-not$s){return $null};$p=$s.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern);$p.SetScrollPercent(-1,$Percent);Start-Sleep -Milliseconds 600;$p.Current.VerticalScrollPercent}
function Expanders{@($guideTitles|ForEach-Object {Guide $_}|Where-Object {$_})}
function SetExpanded($Element,[bool]$Open){$p=$Element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern);if($Open -and $p.Current.ExpandCollapseState -ne [Windows.Automation.ExpandCollapseState]::Expanded){$p.Expand()};if(-not$Open -and $p.Current.ExpandCollapseState -ne [Windows.Automation.ExpandCollapseState]::Collapsed){$p.Collapse()}}
function Loaded{(Visible (Guide $guideTitles[0])) -and -not (Visible (ById 'MemoryRetry'))}
$scripts=Join-Path $Source 'backend\scripts'
$inventory=Join-Path $scripts 'Get-ProcessInventory.ps1';$classification=Join-Path $scripts 'Get-ProcessClassification.ps1'
function Kept([string]$Path){$Path+'.roo-industries-test-off'}
function Mend([string]$Path){
 $kept=Kept $Path
 if(-not [IO.File]::Exists($kept)){return}
 if([IO.File]::Exists($Path)){
  if([IO.File]::ReadAllText($Path) -cne $fault){throw ('An earlier run kept the original '+(Split-Path $Path -Leaf)+', but the script has changed since; both were left for review.')}
  [IO.File]::Delete($Path)
 }
 [IO.File]::Move($kept,$Path)
}
function Fault([string]$Path){Mend $Path;[IO.File]::Move($Path,(Kept $Path));[IO.File]::WriteAllText($Path,$fault)}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$status='fail'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this check does not take over another window.'}
 foreach($path in @($inventory,$classification)){Mend $path}
 Initialize-HarnessBuildFolders $Source
 Ensure-HarnessOutputDirectory (Join-Path $Source 'backend\bin')
 $env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
 $build=Join-Path $directory 'build.log'
 & $dotnet publish (Join-Path $Source 'backend\native\Optimizer.Host\Optimizer.Host.csproj') --configuration Debug --self-contained false -o (Join-Path $Source 'backend\bin\optimizer') --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *> $build
 if($LASTEXITCODE -ne 0){throw 'The helper test build failed; see build.log.'}
 $project=Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj'
 & $dotnet build $project --configuration Debug -p:Platform=x64 -p:WindowsAppSDKSelfContained=true --disable-build-servers -p:RooIndustriesTestHooks=true -p:UseSharedCompilation=false *>> $build
 if($LASTEXITCODE -ne 0){throw 'The app test build failed; see build.log.'}
 $exe=@(Get-ChildItem -LiteralPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\bin\x64\Debug') -Recurse -Filter 'RooIndustries.OptimizationSuite.App.exe'|Sort-Object LastWriteTimeUtc -Descending)
 if(-not$exe.Count){throw 'The app test build produced no executable.'}
 foreach($path in @($inventory,$classification)){Fault $path}
 $env:DOTNET_ROOT=Split-Path $dotnet -Parent;$env:ROO_INDUSTRIES_DOTNET_EXE=$dotnet;$env:ROO_INDUSTRIES_INITIAL_NAV='memory'
 $app=Start-OwnedProcess -FilePath $exe[0].FullName -WindowStyle Normal -Purpose 'suite-test-build' -Lifetime invocation
 $script:window=WaitFor {$w=$A::RootElement.FindFirst($TS::Children,[Windows.Automation.PropertyCondition]::new($A::ProcessIdProperty,[int]$app.Identity.pid));if($w -and $w.Current.NativeWindowHandle -ne 0){$w}} 180
 if(-not$script:window){throw 'The app window never opened.'}
 $script:hwnd=[IntPtr]::new([long]$script:window.Current.NativeWindowHandle)
 [RooIndustriesMemoryPage]::SetWindowPos($script:hwnd,[IntPtr]::new(-1),0,0,1600,1000,0x0040)|Out-Null

 $retry=WaitFor {$b=ById 'MemoryRetry';if(Visible $b){$b}} 120
 Check ($null -ne $retry) 'when both memory reads fail the Memory page shows its error panel with Retry'
 $panel=ById 'MemoryError';$errorText=if($panel){$panel.Current.Name}else{''}
 Check ($errorText -ceq 'Click Retry. If it keeps failing, use Report a bug to send us the details.') 'the error panel says what to do in plain words' $errorText
 Check (-not (@($rawParts|Where-Object {(@(Shown) -join ' | ').Contains($_)}).Count)) 'the raw backend error stays in the app log, off the screen' $errorText
 Check (HasText "Couldn't check your memory") 'the error panel title is plain'
 Scan 'when both reads fail'
 Shot 'memory-error'

 Mend $inventory
 if($retry){$retry.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
 $partial=WaitFor {if((Loaded) -and @(Shown|Where-Object {$_ -like "Couldn't see which apps*" -or $_ -like 'Memory by process is unavailable*'}).Count){$true}} 120
 Check ([bool]$partial) 'when only the app list fails the page loads and says so'
 Check (HasText "Couldn't see which apps use the most RAM right now.") 'the app list note is plain'
 $again=ById 'MemoryTopRetry'
 Check (Visible $again) 'the app list note offers Try again'
 Check (-not (@($rawParts|Where-Object {(@(Shown) -join ' | ').Contains($_)}).Count)) 'the app list note keeps the raw backend error off the screen'
 Scan 'when the app list fails'
 Shot 'memory-partial'

 Mend $classification
 if(Visible $again){$again.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
 else{
  foreach($name in @('Home','Memory')){$item=WaitFor {$script:window.FindFirst($TS::Descendants,[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new($A::NameProperty,$name),[Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty,$CT::ListItem)))} 30;$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select();Start-Sleep 2}
 }
 $full=WaitFor {if((Loaded) -and -not @(Shown|Where-Object {$_ -like "Couldn't see which apps*" -or $_ -like 'Memory by process is unavailable*'}).Count -and -not (Visible (ById 'MemoryTopRetry'))){$true}} 120
 Check ([bool]$full) 'after the reads work again the full page loads'
 Start-Sleep 2
 Check (@(Shown|Where-Object {$_ -cmatch '^\d+% of your RAM in use$'}).Count -eq 1) 'the headline says how much RAM is in use in plain words'
 foreach($text in @("See what's using your RAM and how to free it up for games.",'Apps using the most RAM','Tools to check your PC')){Check (HasText $text) ('the page shows "'+$text+'"')}
 Check ((ScrollTo 0) -eq 0) 'the Memory page scrolls to its top';Shot 'memory-loaded-top'
 Check ((ScrollTo 100) -ge 99) 'the Memory page scrolls to its bottom';Shot 'memory-loaded-bottom'
 Check ($toolTitles.Count -and -not @($toolTitles|Where-Object {-not (HasText ('Go to Tools for '+$_))}).Count) ('every tool has a "Go to Tools" button that names its tool ('+($toolTitles -join ', ')+')')
 $guides=@(Expanders)
 Check ($guides.Count -eq $guideTitles.Count) ('every memory guide can be opened ('+$guides.Count+' of '+$guideTitles.Count+')')
 foreach($guide in $guides){SetExpanded $guide $true}
 Start-Sleep 1
 Scan 'with every guide open'
 Check (HasText '1. Close what you don''t need before you start a game.') 'opened guides show their numbered steps'
 foreach($guide in $guides){SetExpanded $guide $false}
 $open=@($guides|Where-Object {$_.Current.Name -eq 'Calm background apps while you play'})
 if($open.Count){SetExpanded $open[0] $true;Start-Sleep -Milliseconds 800;$null=ScrollTo 0;$top=$script:window.Current.BoundingRectangle.Top;$s=Scroller;if($s){$p=$s.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern);for($i=0;$i -lt 40 -and $open[0].Current.BoundingRectangle.Top -gt $top+260;$i++){$p.ScrollVertical([Windows.Automation.ScrollAmount]::SmallIncrement);Start-Sleep -Milliseconds 120}};Shot 'memory-guide-open'}
 [RooIndustriesMemoryPage]::SetWindowPos($script:hwnd,[IntPtr]::new(-2),0,0,0,0,0x0003)|Out-Null
 $script:window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
 if(-not$app.process.WaitForExit(20000)){Stop-HarnessProcess $app};$app=$null
 $status=if(@($evidence.checks|Where-Object {-not $_.pass}).Count){'fail'}else{'pass'}
}catch{
 $evidence.error=$_.Exception.Message
 throw
}finally{
 try{
  try{if($app){Stop-HarnessProcess $app}}finally{foreach($path in @($inventory,$classification)){Mend $path}}
 }catch{
  $status='fail';$evidence.cleanupError=$_.Exception.Message
  throw
 }finally{
  $evidence.status=$status
  Write-HarnessResult $directory 'memory-page.json' $evidence|Out-Null
  foreach($check in $evidence.checks){Write-Output ('CHECK '+$(if($check.pass){'PASS '}else{'FAIL '})+$check.name+$(if($check.detail){' :: '+$check.detail}else{''}))}
  Write-Output ('ROO_INDUSTRIES_MEMORY_PAGE '+$status+' '+$directory)
 }
}
if($status -ne 'pass'){exit 1}
