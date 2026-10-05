param([Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')][string]$ExpectedSha256,[string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateRange(1,45)][int]$Minutes=45)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'CS2-GEN4'){throw 'Blackwell-only interactive check'}
if((Get-FileHash -LiteralPath $Installer).Hash -cne $ExpectedSha256.ToUpperInvariant()){throw 'Sealed new installer hash differs'}
if(Test-Path -LiteralPath $Evidence){throw 'Evidence exists; choose a new path'}
[IO.Directory]::CreateDirectory($Evidence)|Out-Null
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,Accessibility,System.Drawing,System.Windows.Forms,System.Web.Extensions
function Assert-PlainAncestry([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while($p){$i=Get-Item -LiteralPath $p -Force;$i.Refresh();if(-not$i.Exists -or $i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Unstable or reparse ancestry: '+$p)};$p=[IO.Path]::GetDirectoryName($p)}
}
$nativeProbePath=Join-Path $root 'tools\validation\Release\BlackwellHarness\NativeProbe.cs'
Assert-PlainAncestry $nativeProbePath
Add-Type -Path $nativeProbePath -ReferencedAssemblies 'System.dll','System.Core.dll','System.Web.Extensions.dll'
Add-Type @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class BlackwellReadmeDesktop {
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr h,int index,StringBuilder value,int bytes,out int needed);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
 public static string Name(){var h=OpenInputDesktop(0,false,1);if(h==IntPtr.Zero)return "unavailable:"+Marshal.GetLastWin32Error();try{var b=new StringBuilder(256);int n;if(!GetUserObjectInformation(h,2,b,512,out n))return "unavailable:"+Marshal.GetLastWin32Error();return b.ToString();}finally{CloseDesktop(h);}}
}
'@
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Accessibility;
public static class BlackwellReadmeControls {
 [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd,uint id,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out IAccessible value);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent,IntPtr child);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hwnd);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder value,int count);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CommandLineToArgvW(string command,out int count);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
 public static string[] Args(string command){int count;var pointer=CommandLineToArgvW(command,out count);if(pointer==IntPtr.Zero)throw new InvalidOperationException("Native argument parsing failed");try{var result=new string[count];for(int i=0;i<count;i++)result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer,i*IntPtr.Size));return result;}finally{LocalFree(pointer);}}
 public static void AssertControl(int window,int control,int pid,string expectedClass) {
  var parent=new IntPtr(window);var child=new IntPtr(control);uint a,b;GetWindowThreadProcessId(parent,out a);GetWindowThreadProcessId(child,out b);
  var name=new StringBuilder(256);GetClassName(child,name,name.Capacity);
  if(a!=pid||b!=pid||!IsChild(parent,child)||!IsWindowVisible(child)||!IsWindowEnabled(child)||name.ToString()!=expectedClass)throw new InvalidOperationException("Native wizard control identity differs");
 }
 public static object[] ReadChecks(int window,int control,int pid) {
  AssertControl(window,control,pid,"TNewCheckListBox");IAccessible value=null;
  try {var iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");int hr=AccessibleObjectFromWindow(new IntPtr(control),0xfffffffc,ref iid,out value);if(hr!=0||value==null)Marshal.ThrowExceptionForHR(hr);
   int n=value.accChildCount;if(n<1||n>20)throw new InvalidOperationException("Unexpected accessible checklist count");
   var rows=new List<object>();for(int i=1;i<=n;i++){rows.Add(new {index=i,name=value.get_accName(i),state=Convert.ToInt32(value.get_accState(i)),role=Convert.ToInt32(value.get_accRole(i))});}return rows.ToArray();
  }finally{if(value!=null&&Marshal.IsComObject(value))Marshal.ReleaseComObject(value);}
 }
 public static void Click(int window,int control,int pid) {
  AssertControl(window,control,pid,"TNewButton");if(!PostMessage(new IntPtr(control),0x00f5,IntPtr.Zero,IntPtr.Zero))throw new InvalidOperationException("Native wizard button post failed");
 }
 public static void SetChecked(int window,int control,int pid,int index,bool expected) {
  AssertControl(window,control,pid,"TNewCheckListBox");IAccessible value=null;
  try {var iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");int hr=AccessibleObjectFromWindow(new IntPtr(control),0xfffffffc,ref iid,out value);if(hr!=0||value==null)Marshal.ThrowExceptionForHR(hr);
   if(index<1||index>value.accChildCount)throw new InvalidOperationException("Accessible checklist index differs");
   if(Convert.ToInt32(value.get_accRole(index))!=44)throw new InvalidOperationException("Accessible item is not a checkbox");
   int state=Convert.ToInt32(value.get_accState(index));if((state&(1|0x8000|0x10000))!=0)throw new InvalidOperationException("Accessible checklist item unavailable");
   if(((state&16)!=0)!=expected)value.accDoDefaultAction(index);
   if(((Convert.ToInt32(value.get_accState(index))&16)!=0)!=expected)throw new InvalidOperationException("Accessible checklist toggle not confirmed");
  }finally{if(value!=null&&Marshal.IsComObject(value))Marshal.ReleaseComObject(value);}
 }
}

public sealed class BlackwellNotepadStarts : System.IDisposable {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct ProcessEntry {public uint size,usage,pid;public IntPtr heap;public uint module,threads,parent;public int priority;public uint flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string image;}
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint pid);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Process32First(IntPtr snapshot,ref ProcessEntry row);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Process32Next(IntPtr snapshot,ref ProcessEntry row);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle,out long creation,out long exit,out long kernel,out long user);
 [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle,int kind,IntPtr buffer,int size,out int returned);
 readonly object gate=new object();readonly System.Threading.ManualResetEvent stop=new System.Threading.ManualResetEvent(false);
 readonly System.Collections.Generic.List<System.Diagnostics.Process> held=new System.Collections.Generic.List<System.Diagnostics.Process>();
 readonly System.Collections.Generic.List<object> rows=new System.Collections.Generic.List<object>();readonly System.Collections.Generic.HashSet<string> seen=new System.Collections.Generic.HashSet<string>();
 readonly string image,document;readonly int session;System.Threading.Thread thread;bool disposed;
 public BlackwellNotepadStarts(string expectedImage,string expectedDocument,int expectedSession){image=expectedImage;document=expectedDocument;session=expectedSession;}
 public void Start(){lock(gate){if(disposed||thread!=null)throw new InvalidOperationException("Native observer already started or disposed");Sample();thread=new System.Threading.Thread(Observe);thread.IsBackground=true;thread.Start();}}
 static string Command(IntPtr handle){int needed;NtQueryInformationProcess(handle,60,IntPtr.Zero,0,out needed);if(needed<16||needed>131072)throw new InvalidOperationException("Native notepad command length unavailable");IntPtr buffer=Marshal.AllocHGlobal(needed);try{if(NtQueryInformationProcess(handle,60,buffer,needed,out needed)!=0)throw new InvalidOperationException("Native notepad command unavailable");return Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer,IntPtr.Size==8?8:4),(ushort)Marshal.ReadInt16(buffer)/2);}finally{Marshal.FreeHGlobal(buffer);}}
 void Observe(){var timer=System.Diagnostics.Stopwatch.StartNew();try{while(timer.Elapsed.TotalSeconds<30&&!stop.WaitOne(5)){Sample();}}catch(Exception error){lock(gate){rows.Add(new {pid=0,observedUtc=DateTime.UtcNow.ToString("o"),commandLine="",nativeJson="",parentNativeJson="",error=error.GetBaseException().Message});}}}
 void Sample(){var snapshot=CreateToolhelp32Snapshot(2,0);if(snapshot==new IntPtr(-1))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());try{var entry=new ProcessEntry();entry.size=(uint)Marshal.SizeOf(typeof(ProcessEntry));if(Process32First(snapshot,ref entry)){do{if(String.Equals(entry.image,"notepad.exe",StringComparison.OrdinalIgnoreCase))Capture((int)entry.pid);}while(Process32Next(snapshot,ref entry));}}finally{CloseHandle(snapshot);}}
 void Capture(int pid){System.Diagnostics.Process process=null;try{process=System.Diagnostics.Process.GetProcessById(pid);var handle=process.Handle;long creation,exit,kernel,user;if(!GetProcessTimes(handle,out creation,out exit,out kernel,out user))return;string key=pid+":"+creation;if(!seen.Add(key)||process.SessionId!=session)return;string command=Command(handle);string[] args=BlackwellReadmeControls.Args(command);if(args.Length!=2||!String.Equals(args[0],image,StringComparison.OrdinalIgnoreCase)||!String.Equals(args[1],document,StringComparison.OrdinalIgnoreCase))return;
  Type probe=null;foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()){probe=assembly.GetType("BlackwellNativeProbe",false);if(probe!=null)break;}if(probe==null)throw new InvalidOperationException("Native identity probe was not loaded");var method=probe.GetMethod("Inspect");string native=(string)method.Invoke(null,new object[]{pid});var json=new System.Web.Script.Serialization.JavaScriptSerializer();var row=json.Deserialize<System.Collections.Generic.Dictionary<string,object>>(native);if((string)row["creationTimeFileTimeUtc"]!=creation.ToString()||(int)row["pid"]!=pid)throw new InvalidOperationException("Notepad PID identity changed during capture");string parentNative="";try{var parent=(System.Collections.Generic.Dictionary<string,object>)row["parent"];if(parent.ContainsKey("creationTimeFileTimeUtc")){string value=(string)method.Invoke(null,new object[]{Convert.ToInt32(parent["pid"])});var details=json.Deserialize<System.Collections.Generic.Dictionary<string,object>>(value);if((string)details["creationTimeFileTimeUtc"]==(string)parent["creationTimeFileTimeUtc"])parentNative=value;}}catch{}
  lock(gate){rows.Add(new {pid=pid,observedUtc=DateTime.UtcNow.ToString("o"),commandLine=command,nativeJson=native,parentNativeJson=parentNative,error=""});held.Add(process);process=null;}
 }catch(Exception error){lock(gate){rows.Add(new {pid=pid,observedUtc=DateTime.UtcNow.ToString("o"),commandLine="",nativeJson="",parentNativeJson="",error=error.GetBaseException().Message});}}finally{if(process!=null)process.Dispose();}}
 public string Read(){lock(gate){return new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(rows);}}
 public void Dispose(){stop.Set();if(thread!=null&&!thread.Join(2000))throw new InvalidOperationException("Bounded native observer did not exit; handles retained");lock(gate){if(disposed)return;disposed=true;foreach(var process in held)process.Dispose();held.Clear();}stop.Dispose();}
}
'@ -ReferencedAssemblies 'Accessibility.dll','System.dll','System.Core.dll','System.Web.Extensions.dll'
if(-not$DotNetPath){$DotNetPath=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet\dotnet.exe'}
$fixture=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AppData\Local\Temp\roo-blackwell-readme-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $fixture){throw 'Fixture already exists'}
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$callerReports=[Collections.Generic.List[object]]::new();$readLeases=[Collections.Generic.List[object]]::new();$owned=[Collections.Generic.List[object]]::new();$copies=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new();$deadline=[DateTime]::UtcNow.AddMinutes($Minutes).AddSeconds(-30);$session=(Get-Process -Id $PID).SessionId;$failure=$null
$app='C:\Program Files\Roo Industries\Optimization Suite';$readme=Join-Path $app 'README-BETA.txt';$system=[Environment]::SystemDirectory
$result=[ordered]@{machine=$env:COMPUTERNAME;installer=$Installer;installerSha256=(Get-FileHash -LiteralPath $Installer).Hash;expectedInstallerSha256=$ExpectedSha256.ToUpperInvariant();maximumMinutes=$Minutes;cases=@();passed=$false;cleanupPassed=$false;error='';restore='Runner phases must restore this installed epoch after the check';fixture=$fixture;ownedFiles=@();ownedProcesses=@()}
function Save-Result {$result.cases=@($rows);$result|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $Evidence 'interactive-readme.json') -Encoding UTF8}
function Assert-Wizard($Window) {
    $receipts=@($owned|Where-Object {$_.Identity.pid -eq $Window.Current.ProcessId -and -not$_.process.HasExited})
    if($receipts.Count -ne 1){throw 'Native wizard has no unique owned process receipt'}
    $receipt=$receipts[0];$handle=$receipt.process.Handle
    if($receipt.process.HasExited -or [RooValidationOwnership.Native]::Created($handle).ToString() -cne $receipt.Identity.creationTimeFileTimeUtc -or [RooValidationOwnership.Native]::Image($handle) -cne $receipt.Identity.imagePath){throw 'Native wizard identity changed; refuse input'}
}
function Button($Window,[string]$Pattern) {
    $buttons=@($Window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {($_.Current.ControlType -eq [Windows.Automation.ControlType]::Button -or $_.Current.ClassName -ceq 'TNewButton') -and $_.Current.IsEnabled -and -not$_.Current.IsOffscreen -and $_.Current.Name -match $Pattern})
    if($buttons.Count -gt 1){throw 'Ambiguous wizard button; refuse input'}
    $buttons|Select-Object -First 1
}
function Invoke-Button($Window,$Button) {
    Assert-Wizard $Window
    $pattern=$null
    if($Button.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}
    else{[BlackwellReadmeControls]::Click($Window.Current.NativeWindowHandle,$Button.Current.NativeWindowHandle,$Window.Current.ProcessId)}
}
function Select-Readme($Window) {
    Assert-Wizard $Window
    $boxes=@($Window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::CheckBox)))
    $readmeBox=@($boxes|Where-Object {$_.Current.Name -match 'beta tester guide'})
    if($readmeBox.Count -eq 1){
        $toggle=$readmeBox[0].GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$toggle.Toggle()}
        foreach($box in @($boxes|Where-Object {$_.Current.Name -match '^(Launch|Open) '})){$t=$box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if($t.Current.ToggleState -eq [Windows.Automation.ToggleState]::On){$t.Toggle()}}
        return $toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On
    }
    if($readmeBox.Count -gt 1){throw 'README checkbox ambiguous'}
    $lists=@($Window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.ClassName -ceq 'TNewCheckListBox' -and $_.Current.IsEnabled -and -not$_.Current.IsOffscreen})
    if($lists.Count -ne 1){throw 'Native README checklist missing or ambiguous'}
    $hwnd=$lists[0].Current.NativeWindowHandle;$windowHandle=$Window.Current.NativeWindowHandle;$processId=$Window.Current.ProcessId
    $items=@([BlackwellReadmeControls]::ReadChecks($windowHandle,$hwnd,$processId));$guide=@($items|Where-Object {$_.role -eq 44 -and $_.name -match '^Read the beta tester guide$'})
    if($guide.Count -ne 1 -or @($items|Where-Object {$_.role -ne 44 -or ($_.name -notmatch '^Read the beta tester guide$' -and $_.name -notmatch '^(Launch|Open) Roo Industries ')}).Count){throw 'Native README checklist differs; refuse input'}
    foreach($item in $items){Assert-Wizard $Window;[BlackwellReadmeControls]::SetChecked($windowHandle,$hwnd,$processId,$item.index,($item.index -eq $guide[0].index))}
    $after=@([BlackwellReadmeControls]::ReadChecks($windowHandle,$hwnd,$processId))
    $steps.Add(@{action='native README checklist confirmed';items=$after;observedUtc=[DateTime]::UtcNow.ToString('o')})
    return @($after|Where-Object {$_.index -eq $guide[0].index -and ($_.state -band 16)}).Count -eq 1 -and @($after|Where-Object {$_.index -ne $guide[0].index -and ($_.state -band 16)}).Count -eq 0
}
function Read-NotepadStarts($Watcher) { $decoded=ConvertFrom-Json -InputObject $Watcher.Read();foreach($row in @($decoded)){$row} }
function Is-NotepadImage([string]$Image) { $Image -ieq ('\\?\'+(Join-Path ([Environment]::SystemDirectory) 'notepad.exe')) -or $Image -match '^\\\\\?\\C:\\Program Files\\WindowsApps\\Microsoft\.WindowsNotepad_[^\\]+\\Notepad\\Notepad\.exe$' }
function Get-NotepadTabs {
    $windows=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.Name -match 'Notepad'})
    @(foreach($window in $windows){$p=Get-Process -Id $window.Current.ProcessId;$h=$p.Handle;try{if(-not(Is-NotepadImage ([RooValidationOwnership.Native]::Image($h)))){continue};$tabs=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::TabItem))|ForEach-Object {$selected=$false;$pattern=$null;if($_.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$selected=$pattern.Current.IsSelected};@{key=($_.GetRuntimeId() -join ':');name=$_.Current.Name;selected=$selected}});@{pid=$p.Id;created=[RooValidationOwnership.Native]::Created($h).ToString();image=[RooValidationOwnership.Native]::Image($h);tabs=$tabs}}finally{$p.Dispose()}})
}
function Restore-NotepadTabs($Before) {
    $closed=[Collections.Generic.List[object]]::new()
    $windows=@([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.Name -match 'Notepad'})
    $candidates=[Collections.Generic.List[object]]::new()
    foreach($window in $windows){
        $p=Get-Process -Id $window.Current.ProcessId;$h=$p.Handle
        try{
            $created=[RooValidationOwnership.Native]::Created($h).ToString();$image=[RooValidationOwnership.Native]::Image($h);if(-not(Is-NotepadImage $image)){continue};$old=@($Before|Where-Object {$_.pid -eq $p.Id -and $_.created -ceq $created -and $_.image -ceq $image})
            $tabs=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::TabItem)))
            $matches=@($tabs|Where-Object {$key=$_.GetRuntimeId() -join ':';$_.Current.Name -match '^README-BETA\.txt(?:\. Unmodified\.)?$' -and @($old.tabs|Where-Object {$_.key -ceq $key}).Count -eq 0})
            if($matches.Count -gt 1){throw 'README tab ambiguous; existing Notepad retained'}
            foreach($tab in $matches){$candidates.Add(@{window=$window;tab=$tab;pid=$p.Id;created=$created;image=$image})}
            $after=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::TabItem)))
            foreach($original in @($old.tabs)){$same=@($after|Where-Object {($_.GetRuntimeId() -join ':') -ceq $original.key -and $_.Current.Name -ceq $original.name});if($same.Count -ne 1){throw 'An original Notepad tab changed; preserve window and report'};if($original.selected){$same[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}}
        }finally{$p.Dispose()}
    }
    if($candidates.Count -gt 1){throw 'README tab ownership ambiguous across windows; retain all'}
    foreach($candidate in $candidates){
        $p=Get-Process -Id $candidate.pid;$h=$p.Handle
        try{
            if($p.HasExited -or [RooValidationOwnership.Native]::Created($h).ToString() -cne $candidate.created -or [RooValidationOwnership.Native]::Image($h) -cne $candidate.image){throw 'README tab window identity differs; retain'}
            $tab=$candidate.tab;$buttons=@($tab.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button))|Where-Object {$_.Current.Name -ceq 'Close Tab' -and $_.Current.AutomationId -ceq 'CloseButton'})
            if($buttons.Count -ne 1 -or $tab.Current.Name -notmatch '^README-BETA\.txt(?:\. Unmodified\.)?$'){throw 'README tab close identity differs; retained'}
            $tabKey=$tab.GetRuntimeId() -join ':';$tabName=$tab.Current.Name;$buttons[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();$closed.Add(@{pid=$p.Id;created=$candidate.created;image=$candidate.image;tabKey=$tabKey;name=$tabName});Start-Sleep -Milliseconds 200
            $after=@($candidate.window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::TabItem)))
            $old=@($Before|Where-Object {$_.pid -eq $p.Id -and $_.created -ceq $candidate.created -and $_.image -ceq $candidate.image})
            foreach($original in @($old.tabs)){$same=@($after|Where-Object {($_.GetRuntimeId() -join ':') -ceq $original.key -and $_.Current.Name -ceq $original.name});if($same.Count -ne 1){throw 'An original Notepad tab changed; preserve window and report'};if($original.selected){$same[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}}
        }finally{$p.Dispose()}
    }
    @{passed=$true;closedOnlyNewReadmeTabs=@($closed);existingNotepadProcessesStopped=0}
}
function Assert-KvmApproval($Request,$Approval,[string]$EvidenceRoot) {
    if($Approval.screenshotFile -cne 'normal-uac-kvm-details.png'){throw 'KVM screenshot name differs'}
    $shot=Join-Path $EvidenceRoot $Approval.screenshotFile;Assert-PlainAncestry $shot
    $verified=[DateTimeOffset]::MinValue;$pressed=[DateTimeOffset]::MinValue
    $validTimes=[DateTimeOffset]::TryParse([string]$Approval.verifiedUtc,[ref]$verified) -and [DateTimeOffset]::TryParse([string]$Approval.yesPressedUtc,[ref]$pressed)
    if($Approval.machine -cne $Request.machine -or $Approval.kvmTarget -cne $Request.kvmTarget -or $Approval.protocol -cne $Request.protocol -or $Approval.requestedUtc -cne $Request.requestedUtc -or $Approval.expectedSha256 -cne $Request.expectedSha256 -or $Approval.expectedPath -cne $Request.expectedPath -or $Approval.programName -cnotin $Request.expectedProgramNames -or $Approval.publisher -cne $Request.expectedPublisher -or $Approval.detailsAvailable -isnot [bool] -or ($Approval.detailsAvailable -and $Approval.observedPath -cne $Request.expectedPath) -or $Approval.screenshotSha256 -cnotmatch '\A[A-F0-9]{64}\z' -or -not(Test-Path -LiteralPath $shot) -or (Get-FileHash -LiteralPath $shot).Hash -cne $Approval.screenshotSha256 -or $Approval.decision -cne 'approved' -or $Approval.yesPressCount -isnot [int] -or $Approval.yesPressCount -ne 1 -or -not$validTimes -or $verified -lt [DateTimeOffset]::Parse($Request.requestedUtc) -or $pressed -lt $verified -or $pressed -gt [DateTimeOffset]::Parse($Request.expiresUtc) -or $pressed -gt [DateTimeOffset]::UtcNow){throw 'KVM consent proof differs from the exact sealed installer criteria'}
}
function Capture([string]$Label) {$bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$bitmap.Save((Join-Path $Evidence ($Label+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}
function Own($Process) {$receipt=New-OwnedProcess $Process;if($receipt){$owned.Add($receipt);$result.ownedProcesses=@($owned|ForEach-Object Identity);Save-Result};$receipt}
function Own-Reported($Identity,[string]$ExpectedImage) {
    $creation=0L
    if(-not$Identity -or $Identity.pid -isnot [int] -or $Identity.pid -le 0 -or -not[long]::TryParse([string]$Identity.creationTimeFileTimeUtc,[ref]$creation) -or $creation -le 0 -or $Identity.imagePath -ine $ExpectedImage){throw 'Incomplete or different reported process identity; retained'}
    $process=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue
    if(-not$process){return $null}
    $receipt=$null
    try{
        $receipt=New-OwnedProcess $process
        if(-not$receipt){$process.Dispose();return $null}
        if($receipt.Identity.creationTimeFileTimeUtc -cne [string]$Identity.creationTimeFileTimeUtc -or $receipt.Identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($ExpectedImage)){throw 'Reported process identity changed; retained'}
        $existing=@($owned|Where-Object {$_.Identity.pid -eq $receipt.Identity.pid -and $_.Identity.creationTimeFileTimeUtc -ceq $receipt.Identity.creationTimeFileTimeUtc -and $_.Identity.imagePath -ceq $receipt.Identity.imagePath})
        if($existing.Count){$process.Dispose();return $existing[0]}
        $owned.Add($receipt);$result.ownedProcesses=@($owned|ForEach-Object Identity);Save-Result;return $receipt
    }catch{if(-not$receipt -or -not$owned.Contains($receipt)){$process.Dispose()};throw}
}
function Own-Copy($Receipt) {
    try{$identity=$Receipt.Identity;$copies.Add($identity);$result.ownedFiles=@($copies);Save-Result;return $identity}finally{$Receipt.Dispose()}
}
function Seal-Readable($Identity) {
    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'ReadAndExecute','Allow'));Set-Acl -LiteralPath $Identity.path -AclObject $acl
    $readLeases.Add([IO.File]::Open($Identity.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 /reference:System.Web.Extensions.dll /main:BlackwellReadmeLaunch ('/out:'+(Join-Path $fixture 'compiled-launcher.exe')) (Join-Path $PSScriptRoot 'BlackwellReadmeLaunch.cs') $nativeProbePath > (Join-Path $Evidence 'build-launcher.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'Normal-launcher build failed'}
    foreach($variant in 'already-elevated','normal-uac'){
        if([DateTime]::UtcNow -ge $deadline){throw 'Overall45-minute bound reached'}
        $started=[DateTime]::UtcNow;$caseDeadline=$started.AddMinutes(20);if($caseDeadline -gt $deadline){$caseDeadline=$deadline}
        $case=[ordered]@{name=$variant;startedUtc=$started.ToString('o');status='missing-proof';caller=$null;setupPid=$null;wizardProcess=$null;readmeChecked=$false;finishInvoked=$false;notepad=$null;notepadCommandLine=$null;expectedNotepadIntegrity=$(if($variant -ceq 'normal-uac'){'Medium'}else{'High'});notepadParentContext=$null;notepadStartCaptures=@();notepadUiCleanup=$null;uacCriteria=$null;uacApproval=$null;steps=@();error=''}
        $steps=[Collections.Generic.List[object]]::new();$before=@(Get-Process -ErrorAction SilentlyContinue|ForEach-Object {$_.Id});$setup=$null;$launcher=$null;$dir=$null;$lastAction='';$lastActionUtc=[DateTime]::MinValue;$notepadStarts=$null;$uacRequest=$null;$uacWaitUntil=$null;$uacReceipt=$null;$uacReceiptUntil=$null;$tabsBefore=Get-NotepadTabs
        $notepadStarts=[BlackwellNotepadStarts]::new((Join-Path $system 'notepad.exe'),$readme,$session)
        if($variant -ceq 'normal-uac'){
            $dir=Join-Path $fixture $variant;[IO.Directory]::CreateDirectory($dir)|Out-Null;$exe=Join-Path $dir 'IntegrityProbe.exe'
            $sealedInstaller=Join-Path $dir ([IO.Path]::GetFileName($Installer));$installerIdentity=Own-Copy (Copy-OwnedProbe $Installer $sealedInstaller)
            if($installerIdentity.hash -cne $ExpectedSha256.ToUpperInvariant()){throw 'Readable installer copy differs'}
            Seal-Readable $installerIdentity
            $exeIdentity=Own-Copy (Copy-OwnedProbe (Join-Path $fixture 'compiled-launcher.exe') $exe);Seal-Readable $exeIdentity
            $pathIdentity=Own-Copy (New-OwnedTextFile (Join-Path $dir 'installer-path.txt') $sealedInstaller);Seal-Readable $pathIdentity
            $shaIdentity=Own-Copy (New-OwnedTextFile (Join-Path $dir 'expected-sha256.txt') $ExpectedSha256.ToUpperInvariant());Seal-Readable $shaIdentity
            $metadata=Join-Path $Evidence 'normal-caller.json';$callerReports.Add(@{metadata=$metadata;image=$exe})
            & $DotNetPath (Join-Path $root 'tools\validation\Release\BlackwellHarness\bin\Release\net8.0-windows\BlackwellHarness.dll') direct $exe $metadata > (Join-Path $Evidence 'normal-caller.log') 2>&1
            if($LASTEXITCODE -ne 0){throw 'Normal caller did not prove Medium shell handoff'}
            $native=(Get-Content -Raw -LiteralPath $metadata|ConvertFrom-Json).probe;$case.caller=$native
            $ownedLauncher=Own-Reported $native $exe;$launcher=if($ownedLauncher){$ownedLauncher.process}else{$null}
        }else{$setup=Start-Process -FilePath $Installer -PassThru;$null=Own $setup;$case.setupPid=$setup.Id;$case.caller=[BlackwellNativeProbe]::Inspect($PID)|ConvertFrom-Json}
        while([DateTime]::UtcNow -lt $caseDeadline){
            if($variant -ceq 'normal-uac' -and -not$setup -and (Test-Path -LiteralPath (Join-Path $dir 'setup-started.json'))){$request=Get-Content -Raw -LiteralPath (Join-Path $dir 'setup-started.json')|ConvertFrom-Json;$setupReceipt=Own-Reported $request $sealedInstaller;if($setupReceipt){$setup=$setupReceipt.process;$case.setupPid=$setup.Id}}
            $desktop=[BlackwellReadmeDesktop]::Name()
            if($desktop -ne 'Default'){
                if($variant -cne 'normal-uac'){$case.error='Unexpected secure desktop in elevated case; no input sent.';break}
                if(-not$uacRequest){
                    $signature=Get-AuthenticodeSignature -LiteralPath $sealedInstaller
                    if($signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned){$case.error='UAC publisher criteria require the sealed unsigned beta installer.';break}
                    $names=@([IO.Path]::GetFileName($sealedInstaller),[Diagnostics.FileVersionInfo]::GetVersionInfo($sealedInstaller).FileDescription)|Where-Object {$_}|Select-Object -Unique
                    $uacWaitUntil=[DateTime]::UtcNow.AddSeconds(180);if($uacWaitUntil -gt $caseDeadline){$uacWaitUntil=$caseDeadline}
                    $uacRequest=[ordered]@{protocol='roo-blackwell-uac-approval/v1';machine=$env:COMPUTERNAME;kvmTarget='https://glkvm-gaming-9950x3d.tail9fe6d9.ts.net';case='normal-uac';requestedUtc=[DateTime]::UtcNow.ToString('o');expiresUtc=$uacWaitUntil.ToString('o');expectedProgramNames=@($names);expectedPublisher='Unknown publisher';expectedPath=$sealedInstaller;expectedSha256=$ExpectedSha256.ToUpperInvariant();installerIdentity=$installerIdentity;caller=$case.caller;setupPid=$case.setupPid;criteria='Capture KVM; require exact expected program name and Unknown publisher, expand more details when available and require exact sealed path there; press Yes once only on a match. Any mismatch cancels and remains missing proof.'}
                    $case.uacCriteria=$uacRequest;$uacRequest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $Evidence 'normal-uac-kvm-request.json') -Encoding UTF8;Save-Result
                    $steps.Add(@{action='await visible KVM consent verification';observedUtc=[DateTime]::UtcNow.ToString('o')})
                }
                if([DateTime]::UtcNow -ge $uacWaitUntil){$case.error='Bounded KVM approval receipt missing; no secure-desktop automation attempted.';break}
                Start-Sleep -Milliseconds 200;continue
            }
            if($uacRequest -and -not$uacReceipt){
                $approvalPath=Join-Path $Evidence 'normal-uac-kvm-approval.json'
                if(-not$uacReceiptUntil){$uacReceiptUntil=[DateTime]::UtcNow.AddSeconds(10)}
                $approval=$null;if(Test-Path -LiteralPath $approvalPath){Assert-PlainAncestry $approvalPath;$approval=Get-Content -Raw -LiteralPath $approvalPath|ConvertFrom-Json}
                if(-not$approval -or $approval.decision -ceq 'verified'){
                    if([DateTime]::UtcNow -lt $uacReceiptUntil){Start-Sleep -Milliseconds 100;continue}
                    $case.error='Secure desktop ended without an explicit verified KVM Yes receipt.';break
                }
                try{Assert-KvmApproval $uacRequest $approval $Evidence}catch{$case.error=$_.Exception.Message;break}
                $uacReceipt=$approval;$case.uacApproval=$approval
            }
            $case.notepadStartCaptures=@(Read-NotepadStarts $notepadStarts)
            $notepads=@($case.notepadStartCaptures|Where-Object {$_.nativeJson -and -not$_.error})
            if($case.finishInvoked -and $notepads.Count -eq 1){
                $case.notepad=$notepads[0].nativeJson|ConvertFrom-Json;$case.notepadCommandLine=$notepads[0].commandLine
                $args=@([BlackwellReadmeControls]::Args($case.notepadCommandLine));$native=$case.notepad
                $case.notepadParentContext=if($notepads[0].parentNativeJson){$notepads[0].parentNativeJson|ConvertFrom-Json}else{$null}
                $case.status=if($native.integrity -ceq $case.expectedNotepadIntegrity -and [bool]$native.elevated -eq ($variant -ceq 'already-elevated') -and $native.session -eq $session -and $native.imagePath -ieq (Join-Path $system 'notepad.exe') -and $args.Count -eq 2 -and $args[0] -ieq (Join-Path $system 'notepad.exe') -and $args[1] -ieq $readme -and [DateTime]::FromFileTimeUtc([long]$native.creationTimeFileTimeUtc) -ge $started -and ($variant -ceq 'already-elevated' -or $uacReceipt)){'passed'}else{'failed'}
                if(-not$native.parent.imagePath){$known=@($owned|Where-Object {$_.Identity.pid -eq $native.parent.pid});if($known.Count -eq 1){$native.parent|Add-Member -NotePropertyName imagePath -NotePropertyValue $known[0].Identity.imagePath;$native.parent|Add-Member -NotePropertyName imageEvidence -NotePropertyValue 'owned setup receipt captured before its exit'}}
                Capture ($variant+'-readme');$case.notepadUiCleanup=Restore-NotepadTabs $tabsBefore;break
            }
            if($case.finishInvoked -and $notepads.Count -gt 1){$case.error='Ambiguous matching native README starts; refuse ownership.';break}
            if($case.finishInvoked){Start-Sleep -Milliseconds 50;continue}
            $desktopRoot=[Windows.Automation.AutomationElement]::RootElement
            $windows=@($desktopRoot.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.ProcessId -gt 0 -and $before -notcontains $_.Current.ProcessId -and $_.Current.Name -match 'Roo Industries' -and $_.Current.Name -match 'Setup'})
            if($windows.Count -gt 1){throw 'Ambiguous installer windows; refuse input'}
            if($windows.Count -eq 1){
                $window=$windows[0];$wp=Get-Process -Id $window.Current.ProcessId -ErrorAction Stop
                if($wp.SessionId -ne $session -or $wp.StartTime.ToUniversalTime() -lt $started){throw 'Wizard process not from this desktop attempt'}
                $snapshot=@(Get-CimInstance Win32_Process);$cursor=@($snapshot|Where-Object ProcessId -eq $wp.Id);$seen=[Collections.Generic.HashSet[int]]::new();$belongs=$false
                while($cursor.Count -eq 1 -and $seen.Add([int]$cursor[0].ProcessId)){
                    $ancestor=@($owned|Where-Object {$_.Identity.pid -eq $cursor[0].ProcessId -and [DateTime]::FromFileTimeUtc([long]$_.Identity.creationTimeFileTimeUtc) -eq $cursor[0].CreationDate.ToUniversalTime()})
                    if($ancestor.Count -eq 1){$belongs=$true;break}
                    $cursor=@($snapshot|Where-Object ProcessId -eq $cursor[0].ParentProcessId)
                }
                if(-not$belongs){throw 'Wizard lacks an owned native caller/setup ancestry; refuse input'}
                if(-not$case.wizardProcess){$null=Own $wp;$case.wizardProcess=[BlackwellNativeProbe]::Inspect($wp.Id)|ConvertFrom-Json;Capture ($variant+'-wizard')}
                $radios=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::RadioButton))|Where-Object {$_.Current.Name -match 'accept.*agreement' -and $_.Current.Name -notmatch 'not accept'})
                foreach($radio in $radios){$radio.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}
                $finish=Button $window '^&?Finish$'
                if($finish){
                    $case.readmeChecked=Select-Readme $window;if(-not$case.readmeChecked){throw 'README selection not confirmed'}
                    Capture ($variant+'-finish-checked');$notepadStarts.Start();$case.finishInvoked=$true;Invoke-Button $window $finish;$steps.Add(@{action='Finish with README checked';observedUtc=[DateTime]::UtcNow.ToString('o')});Start-Sleep -Milliseconds 100;continue
                }
                $button=Button $window '^(&?Next\s*>?|&?Install|&?OK)$'
                if($button){$identity=$window.Current.ProcessId.ToString()+'|'+$button.Current.Name+'|'+(@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text)))|ForEach-Object {$_.Current.Name}) -join '|';if($identity -cne $lastAction -or ([DateTime]::UtcNow-$lastActionUtc).TotalSeconds -ge 5){Invoke-Button $window $button;$lastAction=$identity;$lastActionUtc=[DateTime]::UtcNow;$steps.Add(@{action=$button.Current.Name;observedUtc=$lastActionUtc.ToString('o')})}}
            }
            Start-Sleep -Milliseconds 200
        }
        if(-not$case.error -and $case.status -ceq 'missing-proof'){$case.error='The wizard/README evidence did not complete within the per-case/overall bound.'}
        if($case.finishInvoked -and -not$case.notepadUiCleanup){try{$case.notepadUiCleanup=Restore-NotepadTabs $tabsBefore}catch{$case.notepadUiCleanup=@{passed=$false;error=$_.Exception.Message}}}
        if($notepadStarts){$case.notepadStartCaptures=@(Read-NotepadStarts $notepadStarts);$notepadStarts.Dispose();$notepadStarts=$null}
        $case.steps=@($steps);$rows.Add($case);Save-Result
        foreach($receipt in $owned){Stop-OwnedProcess $receipt}
        if($variant -ceq 'normal-uac' -and [BlackwellReadmeDesktop]::Name() -ne 'Default'){Start-Sleep -Seconds 3;if([BlackwellReadmeDesktop]::Name() -ne 'Default'){throw 'Own Medium caller stopped, but UAC input desktop remains; retained evidence, no arbitrary consent process was killed'}}
    }
    $result.passed=@($rows).Count -eq 2 -and @($rows|Where-Object {$_.status -cne 'passed'}).Count -eq 0
}catch{$failure=$_;$result.error=$_.Exception.Message;$result.passed=$false}
finally {
    $clean=@($rows|Where-Object {$_.finishInvoked -and (-not$_.notepadUiCleanup -or -not$_.notepadUiCleanup.passed)}).Count -eq 0
    if($notepadStarts){try{$notepadStarts.Dispose()}catch{$clean=$false;$result.error+='; native start watcher cleanup: '+$_.Exception.Message}}
    foreach($report in $callerReports){
        try{if(Test-Path -LiteralPath $report.metadata){Assert-PlainAncestry $report.metadata;$identity=(Get-Content -Raw -LiteralPath $report.metadata|ConvertFrom-Json).probe;$null=Own-Reported $identity $report.image}}
        catch{$clean=$false;$result.error+='; reported caller cleanup: '+$_.Exception.Message}
    }
    $result.ownedProcesses=@($owned|ForEach-Object Identity)
    foreach($receipt in $owned){try{Stop-OwnedProcess $receipt;$receipt.process.Dispose()}catch{$clean=$false;$result.error+='; exact process cleanup: '+$_.Exception.Message}}
    foreach($lease in $readLeases){$lease.Dispose()}
    foreach($identity in $copies){try{$copy=Open-OwnedProbe $identity;try{Remove-OwnedProbe $copy}finally{$copy.Dispose()}}catch{$clean=$false;$result.error+='; exact file cleanup: '+$_.Exception.Message}}
    $filesDeadline=[DateTime]::UtcNow.AddSeconds(5);while([DateTime]::UtcNow -lt $filesDeadline -and @($copies|Where-Object {Test-Path -LiteralPath $_.path}).Count){Start-Sleep -Milliseconds 100}
    try{if(@(Get-ChildItem -LiteralPath $fixture -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Reparse fixture retained'};$unknown=@(Get-ChildItem -LiteralPath $fixture -File -Recurse -Force|Where-Object {$_.Name -notin 'compiled-launcher.exe','probe-report.json','probe-report.json.tmp','setup-started.json','setup-started.json.tmp','setup-error.json','probe-error.txt'});if($unknown.Count){throw 'Unknown fixture entries retained'};Remove-Item -LiteralPath $fixture -Recurse -Force}catch{$clean=$false;$result.error+='; fixture cleanup: '+$_.Exception.Message}
    $result.cleanupPassed=$clean;Save-Result
}
if($failure){Write-Output ('FAIL interactive README check: '+$result.error);throw $failure}
if(@($rows|Where-Object {$_.status -ceq 'failed'}).Count){Write-Output ('FAIL native interactive README identity or integrity: '+(Join-Path $Evidence 'interactive-readme.json'));exit 1}
if(-not$result.passed){Write-Output ('MISSING PROOF interactive README: '+(Join-Path $Evidence 'interactive-readme.json'));exit 2}
Write-Output ('PASS both native interactive installer README checks: '+(Join-Path $Evidence 'interactive-readme.json'))
