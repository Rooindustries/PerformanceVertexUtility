if(-not ('RooIndustriesValidationOwnership.Native' -as [type])) {
Add-Type @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
namespace RooIndustriesValidationOwnership {
 public static class Native {
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long c,out long e,out long k,out long u);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr h,int f,StringBuilder p,ref int n);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint exit);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h,uint ms);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFullPathNameW(string lpFileName, uint nBufferLength, StringBuilder lpBuffer, IntPtr lpFilePart);
  public static string FullPath(string path) {
   var buffer = new StringBuilder(32768);
   var length = GetFullPathNameW(path, (uint)buffer.Capacity, buffer, IntPtr.Zero);
   if (length == 0 || length >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not normalize the path: " + path);
   return buffer.ToString();
  }
  public static int StreamOffset(string path){int colon=path.IndexOf(':',path.LastIndexOf('\\')+1);return colon==1&&char.IsLetter(path[0])?path.IndexOf(':',2):colon;}
  public static string Long(string path){if(path.StartsWith(@"\\?\",StringComparison.Ordinal))return path;string p=path.Replace('/', '\\'),stream="";int offset=StreamOffset(p);if(offset>=0){stream=p.Substring(offset);if(!System.Text.RegularExpressions.Regex.IsMatch(stream.Substring(1),@"^[^\\/:*?""<>|]+(:\$DATA)?$"))throw new InvalidOperationException("Invalid stream name; refused: "+path);p=p.Substring(0,offset);}p=FullPath(p);return (p.StartsWith(@"\\",StringComparison.Ordinal)?@"\\?\UNC\"+p.Substring(2):@"\\?\"+p)+stream;}
  public static string Plain(string path){string p=Long(path);return p.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase)?@"\\"+p.Substring(8):p.Substring(4);}
  public static string Tool(string path){string p=Plain(path);if(StreamOffset(p)>=0)throw new InvalidOperationException("stream paths are .NET-only; cmdlets take -Stream separately");if(p.Length>=260)throw new InvalidOperationException("Path reaches the 260-character tool limit; use a shorter frame: "+p);return p;}
  [DllImport("shell32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CommandLineToArgvW(string command,out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  static string Quote(string value){if(value.Length>0&&value.IndexOfAny(new[]{' ', '\t', '"'})<0)return value;var b=new StringBuilder("\"");int slashes=0;foreach(char c in value){if(c=='\\'){slashes++;continue;}if(c=='"'){b.Append('\\',slashes*2+1);b.Append(c);}else{b.Append('\\',slashes);b.Append(c);}slashes=0;}b.Append('\\',slashes*2);return b.Append('"').ToString();}
  public static string ToolArguments(string arguments){int count;IntPtr memory=CommandLineToArgvW("tool "+arguments,out count);if(memory==IntPtr.Zero)throw new Win32Exception();try{bool changed=false;var result=new string[count-1];for(int i=1;i<count;i++){string token=Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,i*IntPtr.Size));var m=System.Text.RegularExpressions.Regex.Match(token,@"(?:^|=|^/[A-Za-z]+)(?<path>(?:[A-Za-z]:[\\/]|\\\\).*)$");if(m.Success){int offset=m.Groups["path"].Index;string plain=token.Substring(0,offset)+Tool(token.Substring(offset));changed|=plain!=token;token=plain;}else if(token.Contains(@"\\?\"))throw new InvalidOperationException("Extended path inside a tool argument is ambiguous; refused");result[i-1]=Quote(token);}return changed?string.Join(" ",result):arguments;}finally{LocalFree(memory);}}
  public static SafeFileHandle CreateFile(string p,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template){return CreateFileW(Long(p),access,share,security,creation,flags,template);}
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle h,uint code,IntPtr input,uint inputSize,byte[] output,uint outputSize,out uint written,IntPtr overlapped);
  public static string JunctionTarget(string path){using(var h=CreateFile(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)){Check(!h.IsInvalid);var data=new byte[16384];uint size;Check(DeviceIoControl(h,0x900A8,IntPtr.Zero,0,data,(uint)data.Length,out size,IntPtr.Zero));if(size<16||BitConverter.ToUInt32(data,0)!=0xA0000003)throw new InvalidOperationException("Unsupported reparse identity; retained");int offset=16+BitConverter.ToUInt16(data,8),length=BitConverter.ToUInt16(data,10);if(length%2!=0||offset+length>size)throw new InvalidOperationException("Invalid reparse identity; retained");string target=Encoding.Unicode.GetString(data,offset,length);if(target.StartsWith(@"\??\UNC\",StringComparison.OrdinalIgnoreCase))target=@"\\"+target.Substring(8);else if(target.StartsWith(@"\??\"))target=target.Substring(4);return Plain(target);}}
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder p,uint n,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int kind,ref byte data,uint size);
  [StructLayout(LayoutKind.Sequential,Pack=4)] struct Info {public uint attrs; public long created; public long accessed; public long written; public uint volume; public uint high;public uint low;public uint links;public uint idHigh;public uint idLow;}
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct RenameInfo {public uint flags;public IntPtr root;public uint length;public char fileName;}
  static void Check(bool ok){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
  public static long Created(IntPtr h){long c,e,k,u;Check(GetProcessTimes(h,out c,out e,out k,out u));return c;}
  public static string Path(SafeFileHandle h){StringBuilder b=new StringBuilder(32768);uint n=GetFinalPathNameByHandle(h,b,(uint)b.Capacity,0);Check(n>0&&n<b.Capacity);return b.ToString();}
  public static string Canonical(string p){using(SafeFileHandle h=CreateFile(p,0,7,IntPtr.Zero,3,0,IntPtr.Zero)){Check(!h.IsInvalid);return Path(h);}}
  public static string Image(IntPtr h){StringBuilder b=new StringBuilder(32768);int n=b.Capacity;Check(QueryFullProcessImageName(h,0,b,ref n));return Canonical(b.ToString());}
  public static void Stop(IntPtr h,long created,string image){if(Created(h)!=created||!String.Equals(Image(h),image,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Process identity changed; retained");if(WaitForSingleObject(h,0)==0)return;Check(TerminateProcess(h,1));Check(WaitForSingleObject(h,5000)==0);}
  public static string FileId(SafeFileHandle h){Info i;Check(GetFileInformationByHandle(h,out i));if((i.attrs&0x400)!=0)throw new InvalidOperationException("Reparse probe refused");return i.volume.ToString("X8")+i.idHigh.ToString("X8")+i.idLow.ToString("X8")+":"+i.created;}
  public static void Delete(SafeFileHandle h){byte yes=1;Check(SetFileInformationByHandle(h,4,ref yes,1));}
  public static void Rename(SafeFileHandle h,string path){byte[] name=Encoding.Unicode.GetBytes(Native.Plain(path));int offset=Marshal.OffsetOf(typeof(RenameInfo),"fileName").ToInt32();byte[] data=new byte[offset+name.Length];Buffer.BlockCopy(BitConverter.GetBytes(name.Length),0,data,Marshal.OffsetOf(typeof(RenameInfo),"length").ToInt32(),4);Buffer.BlockCopy(name,0,data,offset,name.Length);Check(SetFileInformationByHandle(h,3,ref data[0],(uint)data.Length));}
 }
 public sealed class ProbeIdentity {public string path;public string id;public string hash;}
 public sealed class ProbeFile : IDisposable {
  FileStream stream; string movedPath; public ProbeIdentity Identity {get;private set;}
  ProbeFile(string path, ProbeIdentity expected){SafeFileHandle h=Native.CreateFile(path,0x80010000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());try{stream=new FileStream(h,FileAccess.Read);Identity=new ProbeIdentity{path=Native.Plain(path),id=Native.FileId(h),hash=Hash(stream)};if(expected!=null&&(Identity.id!=expected.id||Identity.hash!=expected.hash||!String.Equals(Native.Path(h),Native.Canonical(expected.path),StringComparison.OrdinalIgnoreCase)))throw new InvalidOperationException("Probe file identity changed; retained");}catch{if(stream!=null)stream.Dispose();else h.Dispose();throw;}}
  static string Hash(FileStream s){s.Position=0;using(var sha=SHA256.Create()){string h=BitConverter.ToString(sha.ComputeHash(s)).Replace("-","");s.Position=0;return h;}}
  static ProbeFile Create(byte[] bytes,string path){string id;using(var s=new FileStream(Native.Long(path),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read)){s.Write(bytes,0,bytes.Length);s.Flush(true);id=Native.FileId(s.SafeFileHandle);}string hash;using(var sha=SHA256.Create()){hash=BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","");}return new ProbeFile(path,new ProbeIdentity{path=path,id=id,hash=hash});}
  public static ProbeFile Copy(string source,string path){return Create(File.ReadAllBytes(Native.Long(source)),path);}
  public static ProbeFile Text(string path,string text){return Create(new UTF8Encoding(false).GetBytes(text),path);}
  public static ProbeFile Rename(string path,string destination){var receipt=new ProbeFile(path,(ProbeIdentity)null);try{receipt.CheckIdentity();Native.Rename(receipt.stream.SafeFileHandle,destination);receipt.movedPath=Native.Plain(destination);return receipt;}catch{receipt.Dispose();throw;}}
  public static ProbeFile Open(string path,string id,string hash){return new ProbeFile(path,new ProbeIdentity{path=path,id=id,hash=hash});}
  void CheckIdentity(){if(stream==null)throw new InvalidOperationException("Probe receipt is closed");if(Native.FileId(stream.SafeFileHandle)!=Identity.id||Hash(stream)!=Identity.hash)throw new InvalidOperationException("Probe bytes changed; retained");}
  public void Restore(){CheckIdentity();if(movedPath==null)throw new InvalidOperationException("Rename receipt absent; retained");if(!String.Equals(Native.Path(stream.SafeFileHandle),Native.Canonical(movedPath),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Disabled path identity changed; retained");Native.Rename(stream.SafeFileHandle,Identity.path);CheckIdentity();Dispose();}
  public void Remove(){CheckIdentity();if(movedPath!=null)throw new InvalidOperationException("Disabled original must be restored; retained");Native.Delete(stream.SafeFileHandle);Dispose();}
  public string ReadText(){CheckIdentity();stream.Position=0;using(var reader=new StreamReader(stream,new UTF8Encoding(false),true,4096,true)){return reader.ReadToEnd();}}
  public void Dispose(){if(stream!=null){stream.Dispose();stream=null;}}
 }
}
'@
}
function Copy-OwnedProbe([string]$Source,[string]$Path) { [RooIndustriesValidationOwnership.ProbeFile]::Copy($Source,$Path) }
function New-OwnedTextFile([string]$Path,[string]$Text) { [RooIndustriesValidationOwnership.ProbeFile]::Text($Path,$Text) }
function Rename-OwnedFile([string]$Path,[string]$Destination) { [RooIndustriesValidationOwnership.ProbeFile]::Rename($Path,$Destination) }
function Restore-OwnedFile($Receipt) { if($Receipt){$Receipt.Restore()} }
function Open-OwnedProbe($Identity) { [RooIndustriesValidationOwnership.ProbeFile]::Open($Identity.path,$Identity.id,$Identity.hash) }
function Remove-OwnedProbe($Receipt) { if($Receipt){$Receipt.Remove()} }
function New-OwnedProcess($Process) {
    if($Process.HasExited){return $null}
    try {
        $handle=$Process.Handle
        [pscustomobject]@{process=$Process;handle=$handle;Identity=[pscustomobject]@{pid=$Process.Id;creationTimeFileTimeUtc=[RooIndustriesValidationOwnership.Native]::Created($handle).ToString();imagePath=[RooIndustriesValidationOwnership.Native]::Image($handle)}}
    } catch {if($Process.HasExited){return $null};throw}
}

function Stop-OwnedProcess($Receipt) {
    if(-not$Receipt){return}
    if($Receipt.process.HasExited){return}
    [RooIndustriesValidationOwnership.Native]::Stop($Receipt.handle,[long]$Receipt.Identity.creationTimeFileTimeUtc,$Receipt.Identity.imagePath)
}
function Stop-OwnedProcessIdentity($Identity) {
    if(-not$Identity -or -not$Identity.creationTimeFileTimeUtc -or -not$Identity.imagePath){throw 'Incomplete process ownership receipt; retained'}
    try {$p=Get-Process -Id $Identity.pid -ErrorAction Stop}
    catch {if($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId,*'){return};throw}
    if(-not$p){return}
    try{
        try {$handle=$p.Handle} catch {if($p.HasExited){return};throw}
        if($null -eq $handle -or $handle -eq [IntPtr]::Zero){if($p.HasExited){return};throw 'Live process has no native handle; retained'}
        [RooIndustriesValidationOwnership.Native]::Stop($handle,[long]$Identity.creationTimeFileTimeUtc,$Identity.imagePath)
    }finally{$p.Dispose()}
}
function Get-OwnedRegistryField($Key,[string]$Name) {
    if($Key.GetValueNames() -notcontains $Name){return 'absent'}
    ConvertTo-Json -InputObject ([ordered]@{kind=[int]$Key.GetValueKind($Name);value=$Key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}) -Depth 10 -Compress
}
function New-OwnedRegistryFieldIntent($Key,[string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind) {
    $before=Get-OwnedRegistryField $Key $Name
    $original=$null;$originalKind=$null
    if($before -ne 'absent') {
        $captured=$before|ConvertFrom-Json;$originalKind=[Microsoft.Win32.RegistryValueKind][int]$captured.kind
        $original=switch($originalKind){
            String {[string]$captured.value}
            ExpandString {[string]$captured.value}
            DWord {[int]$captured.value}
            QWord {[long]$captured.value}
            Binary {,[byte[]]$captured.value}
            None {,[byte[]]$captured.value}
            MultiString {,[string[]]$captured.value}
            default {throw 'Original registry kind cannot round-trip; retained before mutation'}
        }
    }
    if($before -ne 'absent' -and ($originalKind -eq [Microsoft.Win32.RegistryValueKind]::Unknown -or $null -eq $original)){throw 'Original registry kind cannot round-trip; retained before mutation'}
    if((Get-OwnedRegistryField $Key $Name) -cne $before){throw 'Registry field changed before write; retained'}
    $receipt=[pscustomobject]@{key=$Key;name=$Name;before=$before;original=$original;originalKind=$originalKind;after=(ConvertTo-Json -InputObject ([ordered]@{kind=[int]$Kind;value=$Value}) -Depth 10 -Compress)}
    $receipt
}
function Set-OwnedRegistryField($Key,[string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind) {
    $receipt=New-OwnedRegistryFieldIntent $Key $Name $Value $Kind
    $Key.SetValue($Name,$Value,$Kind);$Key.Flush()
    if((Get-OwnedRegistryField $Key $Name) -cne $receipt.after){throw 'Registry write readback changed; retained'}
    $receipt
}
function Assert-OwnedRegistryFieldCurrent($Receipt) {
    $current=Get-OwnedRegistryField $Receipt.key $Receipt.name
    if($current -cne $Receipt.before -and $current -cne $Receipt.after){throw ('Registry field changed; retained '+$Receipt.name)}
    $current
}
function Restore-OwnedRegistryField($Receipt) {
    if(-not$Receipt){return}
    $current=Assert-OwnedRegistryFieldCurrent $Receipt
    if($current -ceq $Receipt.before){return}
    if($Receipt.before -ceq 'absent'){$Receipt.key.DeleteValue($Receipt.name,$false)}else{$Receipt.key.SetValue($Receipt.name,$Receipt.original,$Receipt.originalKind)}
    $Receipt.key.Flush()
    if((Get-OwnedRegistryField $Receipt.key $Receipt.name) -cne $Receipt.before){throw 'Registry restoration readback differs'}
}
function Get-OwnedTaskFolder([string]$Path) {$service=New-Object -ComObject Schedule.Service;$service.Connect();$service.GetFolder($Path)}
function Assert-OwnedTaskAbsent([string]$Name,[string]$Path='\') {
    $folder=Get-OwnedTaskFolder $Path
    try{$existing=$folder.GetTask($Name)}catch{if($_.Exception.HResult -ne -2147024894){throw};return}
    if($existing){throw ('Task already exists; retained '+$Path+$Name)}
}
function Get-OwnedTaskReceipt([string]$Name,[string]$Path='\') {
    $folder=Get-OwnedTaskFolder $Path;$task=$folder.GetTask($Name)
    [pscustomobject]@{name=$Name;path=$Path;xml=$task.Xml;sddl=$task.GetSecurityDescriptor(7)}
}
function Remove-OwnedTask($Receipt) {
    if(-not$Receipt){return}
    $folder=Get-OwnedTaskFolder $Receipt.path
    try{$task=$folder.GetTask($Receipt.name)}catch{if($_.Exception.HResult -ne -2147024894){throw};return}
    if($task.Xml -cne $Receipt.xml -or $task.GetSecurityDescriptor(7) -cne $Receipt.sddl){throw ('Task definition changed; retained '+$Receipt.path+$Receipt.name)}
    $task.Stop(0)
    if($task.Xml -cne $Receipt.xml -or $task.GetSecurityDescriptor(7) -cne $Receipt.sddl){throw 'Task changed while stopping; retained'}
    $folder.DeleteTask($Receipt.name,0)
}

function Register-OwnedProbeTask([string]$Name,[string]$Execute,[string]$Arguments,[string]$Directory,[string]$UserId,[int]$Minutes,[int]$LogonType=3) {
    $service=New-Object -ComObject Schedule.Service;$service.Connect();$folder=$service.GetFolder('\')
    $definition=$service.NewTask(0)
    $definition.RegistrationInfo.Description='Roo Industries validation ownership '+[Guid]::NewGuid().ToString('N')
    $definition.Principal.UserId=$UserId;$definition.Principal.LogonType=$LogonType;$definition.Principal.RunLevel=1
    $definition.Settings.ExecutionTimeLimit='PT'+$Minutes+'M';$definition.Settings.DisallowStartIfOnBatteries=$false;$definition.Settings.StopIfGoingOnBatteries=$false
    $action=$definition.Actions.Create(0);$action.Path=[RooIndustriesValidationOwnership.Native]::Tool($Execute);$action.Arguments=[RooIndustriesValidationOwnership.Native]::ToolArguments($Arguments);$action.WorkingDirectory=[RooIndustriesValidationOwnership.Native]::Tool($Directory)
    $task=$folder.RegisterTaskDefinition($Name,$definition,2,$UserId,$null,$LogonType,$null)
    [pscustomobject]@{name=$Name;path='\';xml=$task.Xml;sddl=$task.GetSecurityDescriptor(7)}
}
function Assert-OwnedTaskUnchanged($Receipt) {
    if(-not$Receipt){throw 'CLEANUP NEEDED: task has no ownership receipt; retained'}
    $actual=Get-OwnedTaskReceipt $Receipt.name $Receipt.path
    if($actual.xml -cne $Receipt.xml -or $actual.sddl -cne $Receipt.sddl){throw ('CLEANUP NEEDED: task definition changed; retained '+$Receipt.path+$Receipt.name)}
}

function Assert-NoUnownedAppProcess {
    if(@(Get-Process RooIndustries.OptimizationSuite.* -ErrorAction SilentlyContinue).Count){throw 'CLEANUP NEEDED: an app process remains without this entry ownership; retained'}
}
function Stop-OwnedValidationApp($Process,$Receipt) {
    if($Process -and -not $Process.HasExited){
        if(-not $Receipt){throw 'CLEANUP NEEDED: app has no ownership receipt; retained'}
        $Process.CloseMainWindow() | Out-Null
        if(-not $Process.WaitForExit(20000)){Stop-OwnedProcess $Receipt}
    }
    Assert-NoUnownedAppProcess
}
