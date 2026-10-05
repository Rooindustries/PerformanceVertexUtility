function Initialize-HistoricalBlackwell([string]$Frame,[string]$Runner) {
    if($env:COMPUTERNAME -cne 'CS2-GEN4' -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-21-1846494563-3099854232-4004002307-1001'){throw 'Wrong historical machine or SID'}
    if(-not[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Recovery requires administrator token'}
    $script:backup=[IO.Path]::GetFullPath($Frame)
    if($backup -cnotmatch '^C:\\ProgramData\\RooRecoveryBlackwell-[a-f0-9]{32}$'){throw 'Unexpected historical frame'}
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Recovery runner snapshot does not parse'}
    $names=@('Initialize-RecoveryNative','Assert-PlainRecoveryPath','Assert-RecoveryEvidenceParent','New-SealedDirectory','Assert-SealedRecovery','Save-RecoveryJson','Get-RecoveryRows','Recovery-Lines','Assert-RecoveryEqual','Get-TreeFingerprint','Copy-VerifiedTree','Restore-RecoveryDescriptors','Invoke-Native','Log')
    foreach($name in $names){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($nodes.Count -ne 1){throw ('Native recovery helper missing/duplicated: '+$name)};. ([scriptblock]::Create($nodes[0].Extent.Text));Set-Item -Path ('Function:script:'+ $name) -Value (Get-Item ('Function:'+ $name)).ScriptBlock}
    Assert-PlainRecoveryPath $backup;Assert-SealedRecovery $backup
    $env:PATH=[Environment]::GetFolderPath('System')+';'+[Environment]::GetFolderPath('Windows')+';'+$PSHOME
    $script:log=Join-Path $backup ('native-'+[Guid]::NewGuid().ToString('N')+'.log')
    if(-not('RooHistoricalBlackwell.Raw' -as [type])){
        $compiler=Join-Path $backup ('compiler-'+[Guid]::NewGuid().ToString('N'));New-SealedDirectory $compiler
        $oldTemp=$env:TEMP;$oldTmp=$env:TMP
        try{$env:TEMP=$compiler;$env:TMP=$compiler;Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
namespace RooHistoricalBlackwell {
 public sealed class Value { public uint Kind; public byte[] Bytes; }
 public static class Raw {
  [DllImport("advapi32.dll",EntryPoint="RegQueryValueExW",CharSet=CharSet.Unicode)] static extern int Query(IntPtr key,string name,IntPtr reserved,out uint type,byte[] data,ref uint size);
  [DllImport("advapi32.dll",EntryPoint="RegSetValueExW",CharSet=CharSet.Unicode)] static extern int Set(IntPtr key,string name,uint reserved,uint type,byte[] data,uint size);
  public static Value Read(RegistryKey key,string name) {
   uint type,size=0;int e=Query(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out type,null,ref size);
   if(e!=0)throw new Win32Exception(e);if(size>67108864)throw new InvalidOperationException("Registry value exceeds capture bound");
   byte[] bytes=new byte[size];uint actual=size,kind; e=Query(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out kind,bytes,ref actual);
   if(e!=0)throw new Win32Exception(e);if(actual!=size||kind!=type)throw new InvalidOperationException("Registry value changed during raw read");
   return new Value{Kind=type,Bytes=bytes};
  }
  public static void Write(RegistryKey key,string name,uint kind,byte[] bytes) { int e=Set(key.Handle.DangerousGetHandle(),name,0,kind,bytes,(uint)bytes.Length);if(e!=0)throw new Win32Exception(e);key.Flush(); }
 }
 public static class Export {
  public static byte[] State(string path,string key) {
   if(new FileInfo(path).Length>67108864)throw new InvalidDataException("Export exceeds bound");
   bool section=false,found=false,continuing=false;var result=new MemoryStream();string line;
   using(var reader=new StreamReader(path,Encoding.Unicode,true)) {
    while((line=reader.ReadLine())!=null) {
     if(line.StartsWith("[",StringComparison.Ordinal)){if(section&&continuing)throw new InvalidDataException("Unterminated State continuation");section=line=="["+key+"]";continue;}
     if(!section)continue;
     if(!continuing){if(!line.StartsWith("\"State\"=hex:",StringComparison.Ordinal))continue;if(found)throw new InvalidDataException("Duplicate State");found=true;line=line.Substring(12);}
     line=line.Trim();continuing=line.EndsWith("\\",StringComparison.Ordinal);if(continuing)line=line.Substring(0,line.Length-1);
     foreach(string part in line.Split(',')){string token=part.Trim();if(token.Length==0)continue;if(token.Length!=2)throw new InvalidDataException("Invalid State hex");result.WriteByte(Convert.ToByte(token,16));}
     if(!continuing)break;
    }
   }
   if(!found||continuing)throw new InvalidDataException("Missing or incomplete original State");return result.ToArray();
  }
 }
}
'@}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
    }
}
function Hash-HistoricalBytes([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}}
function Hash-HistoricalText([string]$Text){Hash-HistoricalBytes ([Text.Encoding]::UTF8.GetBytes($Text))}
function Read-HistoricalJson([string]$Path){$value=[IO.File]::ReadAllText($Path)|ConvertFrom-Json;return $value}
function Save-HistoricalBinary([string]$Path,[byte[]]$Bytes){Assert-SealedRecovery $backup;$f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes,0,$Bytes.Length);$f.Flush($true)}finally{$f.Dispose()};Assert-SealedRecovery $Path}
function Get-HistoricalRegistry([string[]]$Roots,[string]$Destination='',[Microsoft.Win32.RegistryKey]$Hive=[Microsoft.Win32.Registry]::LocalMachine) {
    $rows=[Collections.Generic.List[object]]::new();$index=0
    foreach($root in $Roots){
        $q=[Collections.Generic.Queue[string]]::new();$q.Enqueue($root)
        while($q.Count){
            $path=$q.Dequeue();$k=$Hive.OpenSubKey($path,$false)
            if(-not$k){$rows.Add([pscustomobject][ordered]@{key=$path;name=$null;kind='<absent-key>'});continue}
            try{
                $rows.Add([pscustomobject][ordered]@{key=$path;name=$null;kind='<key>';sddl=$k.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')})
                foreach($sub in @($k.GetSubKeyNames()|Sort-Object)){$q.Enqueue($path+'\'+$sub)}
                foreach($name in @($k.GetValueNames()|Sort-Object)){
                    $v=[RooHistoricalBlackwell.Raw]::Read($k,$name);$file=('value-'+$index.ToString('D4')+'.bin');$index++
                    if($Destination){Save-HistoricalBinary (Join-Path $Destination $file) $v.Bytes}
                    $rows.Add([pscustomobject][ordered]@{key=$path;name=$name;kind=[int]$v.Kind;length=$v.Bytes.Length;sha256=(Hash-HistoricalBytes $v.Bytes);file=$file})
                }
            }finally{$k.Dispose()}
        }
    }
    @($rows.ToArray())
}
function Historical-RegistryLines($Rows){@($Rows|ForEach-Object {$row=ConvertTo-Json -InputObject $_ -Compress|ConvertFrom-Json;$row.PSObject.Properties.Remove('file');ConvertTo-Json -InputObject $row -Compress})}
function Get-HistoricalTasks {
    $rows=[Collections.Generic.List[object]]::new();$service=New-Object -ComObject Schedule.Service;$service.Connect()
    try{foreach($task in @(Get-ScheduledTask|Sort-Object TaskPath,TaskName)){$taskFolder=if($task.TaskPath -ceq '\'){'\'}else{$task.TaskPath.TrimEnd('\')};$folder=$service.GetFolder($taskFolder);$t=$null;try{$t=$folder.GetTask($task.TaskName);$rows.Add([pscustomobject][ordered]@{name=$task.TaskName;path=$task.TaskPath;xml=[string]$t.Xml;sddl=[string]$t.GetSecurityDescriptor(7);enabled=[bool]$t.Enabled})}finally{if($t){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($t)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($folder)}}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}
    @($rows.ToArray())
}
function Historical-TaskLines($Rows){@($Rows|ForEach-Object {$_.path+$_.name+'|'+(Hash-HistoricalText $_.xml)+'|'+$_.sddl+'|'+$_.enabled})}
function Assert-HistoricalIdle {
    $app='C:\Program Files\Roo Industries\Optimization Suite\'
    $processes=@(Get-CimInstance Win32_Process|Where-Object {($_.ExecutablePath -and $_.ExecutablePath.StartsWith($app,[StringComparison]::OrdinalIgnoreCase)) -or $_.Name -in 'RooIndustries.OptimizationSuite.App.exe','RooOptimizationSuite.App.exe'})
    if($processes.Count){throw 'Product process exists; retained without stopping'}
    foreach($t in @(Get-ScheduledTask)){foreach($a in $t.Actions){if(([string]$a.Execute).StartsWith($app,[StringComparison]::OrdinalIgnoreCase) -or ([string]$a.Arguments).IndexOf($app,[StringComparison]::OrdinalIgnoreCase) -ge 0){throw 'Product task exists; retained without changing'}}}
    $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software',$false);try{if($k.GetValueNames() -ccontains 'State'){throw 'Unexpected HKCU Software State; retained'}}finally{$k.Dispose()}
}
function Assert-HistoricalMetadata([string]$Path,[string]$Fingerprint) {
    $rows=@(Get-RecoveryRows $Path)
    $lines=@($rows|ForEach-Object {$_.relative+'|'+$(if($_.directory){'dir'}else{[string]$_.length})+'|'+[DateTime]::new([long]$_.write,[DateTimeKind]::Utc).ToString('o')+'|'+[string][IO.FileAttributes][int]$_.attributes+'|'+$_.sddl}|Sort-Object)
    Assert-RecoveryEqual @([IO.File]::ReadAllLines($Fingerprint,[Text.Encoding]::UTF8)) $lines 'historical saved metadata'
    return ,$rows
}
