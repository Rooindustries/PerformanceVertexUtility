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
Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices; using System.Text;
public static class RooIndustriesMemoryUser {
 [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
 [StructLayout(LayoutKind.Sequential)] struct ProcessInformation { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr existing, uint flags, uint disableCount, SidAndAttributes[] disable, uint deleteCount, IntPtr delete, uint restrictCount, IntPtr restrict, out IntPtr token);
 [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool ConvertStringSidToSid(string text, out IntPtr sid);
 [DllImport("advapi32.dll")] static extern int GetLengthSid(IntPtr sid);
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr token, int infoClass, ref SidAndAttributes info, int length);
 [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr token, string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation info);
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetTokenInformation(IntPtr token, int infoClass, ref IntPtr info, int length);
 [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, IntPtr size);
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, out bool present, out IntPtr dacl, out bool defaulted);
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetKernelObjectSecurity(IntPtr handle, uint information, IntPtr descriptor);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
 [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 static IntPtr Sid(string text) { IntPtr sid; if (!ConvertStringSidToSid(text, out sid)) throw new Win32Exception(); return sid; }
 public static int Run(string command, string directory, uint milliseconds) {
  string me = System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
  IntPtr own = IntPtr.Zero, user = IntPtr.Zero, descriptor = IntPtr.Zero, owner = Sid(me), admins = Sid("S-1-5-32-544"), localAdmin = Sid("S-1-5-114"), medium = Sid("S-1-16-8192");
  ProcessInformation info = new ProcessInformation();
  try {
   if (!OpenProcessToken(GetCurrentProcess(), 0x0001 | 0x0002 | 0x0008 | 0x0080 | 0x00040000 | 0x00080000, out own)) throw new Win32Exception();
   SidAndAttributes[] disable = { new SidAndAttributes { Sid = admins }, new SidAndAttributes { Sid = localAdmin } };
   if (!CreateRestrictedToken(own, 0x1 | 0x4, (uint)disable.Length, disable, 0, IntPtr.Zero, 0, IntPtr.Zero, out user)) throw new Win32Exception();
   if (!ConvertStringSecurityDescriptorToSecurityDescriptor("D:(A;;GA;;;" + me + ")(A;;GA;;;SY)S:(ML;;NW;;;ME)", 1, out descriptor, IntPtr.Zero)) throw new Win32Exception();
   if (!SetKernelObjectSecurity(user, 0x4 | 0x10, descriptor)) throw new Win32Exception();
   SidAndAttributes label = new SidAndAttributes { Sid = medium, Attributes = 0x20 };
   if (!SetTokenInformation(user, 25, ref label, Marshal.SizeOf(typeof(SidAndAttributes)) + GetLengthSid(medium))) throw new Win32Exception();
   if (!SetTokenInformation(user, 4, ref owner, IntPtr.Size)) throw new Win32Exception();
   bool present, defaulted; IntPtr dacl; if (!GetSecurityDescriptorDacl(descriptor, out present, out dacl, out defaulted)) throw new Win32Exception();
   if (!SetTokenInformation(user, 6, ref dacl, IntPtr.Size)) throw new Win32Exception();
   StartupInfo startup = new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)) };
   if (!CreateProcessAsUser(user, null, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, directory, ref startup, out info)) throw new Win32Exception();
   if (WaitForSingleObject(info.hProcess, milliseconds) != 0) return -2;
   uint code; GetExitCodeProcess(info.hProcess, out code); return (int)code;
  } finally {
   if (info.hThread != IntPtr.Zero) CloseHandle(info.hThread); if (info.hProcess != IntPtr.Zero) CloseHandle(info.hProcess);
   if (user != IntPtr.Zero) CloseHandle(user); if (own != IntPtr.Zero) CloseHandle(own);
   if (descriptor != IntPtr.Zero) LocalFree(descriptor); LocalFree(owner); LocalFree(admins); LocalFree(localAdmin); LocalFree(medium);
  }
 }
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
function MendAll{$failed=@(foreach($path in @($inventory,$classification)){try{Mend $path}catch{$_.Exception.Message}});if($failed.Count){throw ($failed -join ' ')}}
function LimitedRead([string]$Script){
 $work=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-memory-'+[Guid]::NewGuid().ToString('N'))
 [IO.Directory]::CreateDirectory($work)|Out-Null
 try{
  $json=Join-Path $work 'read.json';$who=Join-Path $work 'who.txt'
  $command="[IO.File]::WriteAllText('"+$who+"',[string]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)+' '+(whoami /groups /fo csv|ConvertFrom-Csv|Where-Object {`$_.'Group Name' -like 'Mandatory Label\*'}).'Group Name');`$text=(& '"+$Script+"' 2>`$null|Out-String);[IO.File]::WriteAllText('"+$json+"',`$text);exit `$LASTEXITCODE"
  $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $code=[RooIndustriesMemoryUser]::Run('"'+$shell+'" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)),$work,240000)
  $parsed=$null;try{$parsed=[IO.File]::ReadAllText($json)|ConvertFrom-Json}catch{}
  [pscustomobject]@{exit=[string]$code;who=$(if([IO.File]::Exists($who)){[IO.File]::ReadAllText($who)}else{''});json=$parsed}
 }finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}
function Named($Read){@($Read.json.processes|Where-Object {$_.fileDescription}|ForEach-Object {[int]$_.pid})}
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)
if(-not$dotnet){throw 'No .NET SDK was found for the test build.'}
$dotnet=$dotnet[0]
$app=$null;$status='fail'
try{
 if(@(Get-Process -Name 'RooIndustries.OptimizationSuite.App' -ErrorAction SilentlyContinue).Count){throw 'The Suite is already open; this check does not take over another window.'}
 MendAll
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
 $total=LimitedRead $inventory
 Check ($total.who -ceq 'False Mandatory Label\Medium Mandatory Level') 'the normal-user reads run without admin rights, like an app opened normally' $total.who
 Check ($total.exit -eq '0' -and [long]$total.json.summary.processCount -gt 0 -and [long]$total.json.summary.availableMemoryBytes -gt 0) 'without admin rights the RAM totals still read' ('exit '+$total.exit+', '+$total.json.summary.processCount+' tasks, '+$total.json.summary.availableMemoryBytes+' bytes free')
 $list=LimitedRead $classification
 Check ($list.exit -eq '0' -and @($list.json.processes).Count -gt 0 -and -not @($list.json.errors).Count) 'without admin rights the list of apps using the most RAM still reads' ('exit '+$list.exit+', '+@($list.json.processes).Count+' tasks, '+((@($list.json.errors)|ForEach-Object {$_.code+': '+$_.message}) -join ' | '))
 $named=$null;try{$named=& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $classification 2>$null|Out-String|ConvertFrom-Json}catch{}
 $limitedNamed=@(Named $list);$limitedSeen=@($list.json.processes|ForEach-Object {[int]$_.pid})
 $unnamed=@($named.processes|Where-Object {$_.fileDescription -and $limitedNamed -notcontains [int]$_.pid -and $limitedSeen -contains [int]$_.pid}|ForEach-Object {$_.name})
 Check ($null -ne $named -and @(Named $named).Count -gt 0 -and -not $unnamed.Count) 'without admin rights every app keeps the name Windows has for it' (($unnamed|Select-Object -Unique -First 12) -join ', ')
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
 $rawNamed=@($named.processes|Where-Object {$_.fileDescription -and $_.fileDescription -ne [IO.Path]::GetFileNameWithoutExtension([string]$_.name)}|ForEach-Object {[IO.Path]::GetFileNameWithoutExtension([string]$_.name)})
 $shownApps=@($script:window.FindAll($TS::Descendants,[Windows.Automation.PropertyCondition]::new($A::AutomationIdProperty,'MemoryAppName'))|ForEach-Object {$_.Current.Name})
 Check ($shownApps.Count -gt 0 -and -not @($shownApps|Where-Object {$rawNamed -contains $_}).Count) 'the app list shows the name Windows has for each app, not its raw program name' ($shownApps -join ', ')
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
  try{if($app){Stop-HarnessProcess $app}}finally{MendAll}
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
