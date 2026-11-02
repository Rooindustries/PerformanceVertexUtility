# Registry reads and writes for the row capture, and its recovery journal. The caller sets $journal, the HKCU key path that holds the record.
Add-Type @'
using System; using System.ComponentModel; using System.Runtime.InteropServices;
public static class RooIndustriesRowRegistry {
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
function ReadValue($Address){$r=[RooIndustriesRowRegistry]::Get($Address.hive,$Address.keyPath,$Address.valueName);[ordered]@{keyExists=[bool]$r[0];exists=[bool]$r[1];type=$(if($r[1]){[int]$r[2]}else{$null});data=$(if($r[1]){[Convert]::ToBase64String([byte[]]$r[3])}else{$null})}}
function WriteValue($Address,$State){if($State.exists){[RooIndustriesRowRegistry]::Put($Address.hive,$Address.keyPath,$Address.valueName,[int]$State.type,[Convert]::FromBase64String([string]$State.data))}else{[RooIndustriesRowRegistry]::Remove($Address.hive,$Address.keyPath,$Address.valueName)}}
function AddressKey($Address){($Address.hive+'\'+$Address.keyPath+'\'+$Address.valueName).ToUpperInvariant()}
function Same($Left,$Right){$Left.exists -eq $Right.exists -and (-not$Left.exists -or ($Left.type -eq $Right.type -and $Left.data -ceq $Right.data))}
function Describe($State){if(-not$State.exists){return 'absent'};$bytes=[Convert]::FromBase64String([string]$State.data);switch([int]$State.type){4{if($bytes.Length -eq 4){return 'REG_DWORD '+[BitConverter]::ToUInt32($bytes,0)}};11{if($bytes.Length -eq 8){return 'REG_QWORD '+[BitConverter]::ToUInt64($bytes,0)}};{$_ -in 1,2}{return $(if($_ -eq 1){'REG_SZ '}else{'REG_EXPAND_SZ '})+'"'+[Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)+'"'}};return 'type '+$State.type+' '+[BitConverter]::ToString($bytes)}
# The journal outlives a run: it holds each value's original kind and bytes, the last value the capture or the app wrote, and a write that may have happened.
# A later run restores a value only while it still reads as one of those writes; anything else was changed by another program and is left as it is.
function State($Item){if($null -eq $Item){return $null};[ordered]@{exists=[bool]$Item.exists;type=$(if($Item.exists){[int]$Item.type}else{$null});data=$(if($Item.exists){[string]$Item.data}else{$null})}}
function SaveJournal($Record){$key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($journal);try{$key.SetValue('Record',(ConvertTo-Json -InputObject $Record -Depth 6 -Compress),[Microsoft.Win32.RegistryValueKind]::String)}finally{$key.Dispose()}}
function Mark($Entry,$Target,[switch]$Done){if($Done){$Entry.written=State $Target;$Entry.pending=$null}else{$Entry.pending=State $Target}}
# Once a value reads as its original, is put back, or was changed by another program, the saved record drops it before recovery moves on, so a retry never writes over it again.
function Release($Record,$Entry){$Record.values=@(@($Record.values)|Where-Object {-not($_.hive -eq $Entry.hive -and $_.keyPath -eq $Entry.keyPath -and $_.valueName -eq $Entry.valueName)});SaveJournal $Record}
function Recover($Record){
 $result=[ordered]@{restored=@();conflicts=@();errors=@()}
 foreach($entry in @($Record.values)){try{
  $now=ReadValue $entry
  if(Same $now $entry.original){Release $Record $entry;continue}
  if(@(@($entry.written,$entry.pending)|Where-Object {$_ -and (Same $now $_)}).Count){WriteValue $entry $entry.original;if(-not(Same (ReadValue $entry) $entry.original)){throw 'the restored value does not read back'};Release $Record $entry;$result.restored+=@($entry.valueName+' back to '+(Describe $entry.original))}
  else{Release $Record $entry;$result.conflicts+=@($entry.valueName+' was changed by something else to '+(Describe $now)+'; left as it is')}
 }catch{$result.errors+=@($entry.valueName+': '+$_.Exception.Message)}}
 return $result
}
