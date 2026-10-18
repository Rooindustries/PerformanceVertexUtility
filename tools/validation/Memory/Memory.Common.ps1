. (Get-HarnessToolPath (Join-Path $PSScriptRoot '..\Update\Harness.Common.ps1'))
. (Get-HarnessToolPath (Join-Path $PSScriptRoot '..\..\..\backend\scripts\BrandCompatibility.Common.ps1'))
if(-not('RooIndustriesMemoryRegistry' -as [type])){
 Add-Type @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;
public static class RooIndustriesMemoryRegistry {
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryValueEx(IntPtr key,string name,IntPtr reserved,out uint type,byte[] data,ref uint size);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegSetValueEx(IntPtr key,string name,uint reserved,uint type,byte[] data,uint size);
 public static byte[] Read(RegistryKey key,string name){uint type,size=0;int error=RegQueryValueEx(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out type,null,ref size);if(error!=0)throw new System.ComponentModel.Win32Exception(error);var bytes=new byte[size];error=RegQueryValueEx(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out type,bytes,ref size);if(error!=0)throw new System.ComponentModel.Win32Exception(error);return bytes;}
 public static void Write(RegistryKey key,string name,uint type,byte[] bytes){int error=RegSetValueEx(key.Handle.DangerousGetHandle(),name,0,type,bytes,(uint)bytes.Length);if(error!=0)throw new System.ComponentModel.Win32Exception(error);}
}
'@
}
function Get-MemoryRawRegistry{
 $rows=[Collections.Generic.List[object]]::new()
 foreach($root in 'Software\RooIndustriesOptimizationSuite\Tweaks','Software\RooOptimizationSuite\Tweaks'){
  $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($root)
  while($pending.Count){
   $path=$pending.Pop();$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path)
   if(-not$key){$rows.Add(@{hive='LocalMachine';path=$path;exists=$false;values=@()});continue}
   try{$values=@(foreach($name in @($key.GetValueNames()|Sort-Object)){@{name=$name;kind=[int]$key.GetValueKind($name);rawBase64=[Convert]::ToBase64String([RooIndustriesMemoryRegistry]::Read($key,$name))}});$rows.Add(@{hive='LocalMachine';path=$path;exists=$true;values=$values});foreach($name in @($key.GetSubKeyNames()|Sort-Object)){$pending.Push($path+'\'+$name)}}finally{$key.Dispose()}
  }
 }
 $path='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
 try{$values=@(if($key -and $key.GetValueNames() -contains 'EnableTransparency'){@{name='EnableTransparency';kind=[int]$key.GetValueKind('EnableTransparency');rawBase64=[Convert]::ToBase64String([RooIndustriesMemoryRegistry]::Read($key,'EnableTransparency'))}});$rows.Add(@{hive='CurrentUser';path=$path;exists=[bool]$key;values=$values})}finally{if($key){$key.Dispose()}}
 return @($rows)
}
function Get-MemorySnapshot{
 $install=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite';$local=Get-RooIndustriesLocalAppData
 $roots=@(foreach($name in 'RooOptimizationSuite','RooIndustriesOptimizationSuite'){
  $path=Join-Path $local $name
  @{path=$path;exists=(Test-HarnessPath $path);folders=@(if(Test-HarnessPath $path){Get-HarnessTree $path|Where-Object IsDirectory|ForEach-Object {@{path=$_.FullName;creationTimeFileTimeUtc=$_.CreationTimeUtc.ToFileTimeUtc().ToString()}}});files=@(if(Test-HarnessPath $path){Get-HarnessTree $path -FilesOnly|ForEach-Object {@{path=$_.FullName;relative=$_.FullName.Substring($path.Length+1);bytes=$_.Length;sha256=Get-HarnessFileSha256 $_.LongPath;attributes=[string]$_.Attributes;creationTimeFileTimeUtc=$_.CreationTimeUtc.ToFileTimeUtc().ToString()}}})}
 })
 $payload=@(foreach($part in 'app','backend'){$path=Join-Path $install $part;if(Test-HarnessPath $path){Get-HarnessTree $path -FilesOnly|ForEach-Object {@{path=$_.FullName.Substring($install.Length+1);sha256=Get-HarnessFileSha256 $_.LongPath}}}})
 $tasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -notlike 'RooIndustries_Verify_*'}|ForEach-Object {@{name=$_.TaskName;path=$_.TaskPath;enabled=$_.Settings.Enabled;state=[string]$_.State;xml=Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath}})
 $certs=@(foreach($location in 'CurrentUser','LocalMachine'){foreach($name in 'My','Root'){$store=[Security.Cryptography.X509Certificates.X509Store]::new($name,[Security.Cryptography.X509Certificates.StoreLocation]$location);try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly);foreach($cert in $store.Certificates|Where-Object Subject -like '*Roo Industries Test Signing*'){@{store=$location+'/'+$name;subject=$cert.Subject;thumbprint=$cert.Thumbprint}}}finally{$store.Close()}}})
 $processes=@(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -ne $PID -and ($_.ExecutablePath -like ($install+'\*') -or $_.ExecutablePath -like 'C:\RooBuild\*' -or $_.CommandLine -like '*C:\RooBuild\*')}|Select-Object ProcessId,CreationDate,ExecutablePath,CommandLine)
 $key='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'
 @{machine=$env:COMPUTERNAME;takenAtUtc=[DateTime]::UtcNow.ToString('o');takenAtFileTimeUtc=[DateTime]::UtcNow.ToFileTimeUtc().ToString();installedVersion=$(if(Test-HarnessPath $key){(Get-ItemProperty $key).DisplayVersion}else{$null});install=$install;payload=$payload;dataRoots=$roots;rawRegistry=@(Get-MemoryRawRegistry);tasks=$tasks;frames=@(Get-HarnessChildren 'C:\RooBuild' -Directory|ForEach-Object {@{path=$_.FullName;creationTimeFileTimeUtc=$_.CreationTimeUtc.ToFileTimeUtc().ToString();ledger=(Test-HarnessPath (Join-Path $_.FullName 'ledger.json'))}});processes=$processes;lease=Test-HarnessPath 'C:\RooBuild\host-lease.json';hostsBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-HarnessLongPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'))));firewall=@(Get-NetFirewallRule|Where-Object {$_.Name -like 'RooTest-*' -or $_.Description -like '*RooShipped*'}|Select-Object Name,Description);certificates=$certs}
}
function Restore-MemoryData($Before,$Current,$Archives){
 Assert-HarnessHostLease
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $changes=[Collections.Generic.List[object]]::new()
 foreach($root in $Before.dataRoots){
  $now=@($Current.dataRoots|Where-Object path -CEQ $root.path);if($now.Count -ne 1){throw 'Data root snapshot differs'};$now=$now[0]
  $old=@{};foreach($file in $root.files){$old[$file.path]=$file}
  foreach($file in $now.files){
   if($old.ContainsKey($file.path)){continue}
   if([long]$file.creationTimeFileTimeUtc -lt [long]$Before.takenAtFileTimeUtc){throw ('New data file predates this run; retained: '+$file.path)}
   if((Get-HarnessFileSha256 $file.path) -cne $file.sha256 -or [IO.File]::GetCreationTimeUtc((Get-HarnessLongPath $file.path)).ToFileTimeUtc().ToString() -cne $file.creationTimeFileTimeUtc){throw 'Data file changed after snapshot; retained'}
   $entry=Register-HarnessFile $file.path 'memory-data-output';Remove-HarnessEntry $entry;$changes.Add(@{action='removed';path=$file.path;sha256=$file.sha256})
  }
  if($root.exists){
   $archive=$Archives.PSObject.Properties[$root.path].Value;$zip=[IO.Compression.ZipFile]::OpenRead((Get-HarnessLongPath $archive))
   try{foreach($file in $root.files){
    $actual=@($now.files|Where-Object path -CEQ $file.path);if($actual.Count -and $actual[0].sha256 -ceq $file.sha256){continue}
    if($actual.Count){if((Get-HarnessFileSha256 $file.path) -cne $actual[0].sha256){throw 'Data changed after snapshot; retained'}}elseif(Test-HarnessPath $file.path){throw 'Missing data file reappeared; retained'}
    $entry=$zip.GetEntry($file.relative.Replace('\','/'));if(-not$entry){throw 'As-found archive member missing'};$input=$entry.Open();$buffer=[IO.MemoryStream]::new()
    try{$input.CopyTo($buffer);$bytes=$buffer.ToArray()}finally{$input.Dispose();$buffer.Dispose()}
    $hash=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','')}finally{$hash.Dispose()};if($digest -cne $file.sha256){throw 'As-found archive member hash differs'}
    if(-not(Test-HarnessPath ([IO.Path]::GetDirectoryName($file.path)))){throw 'Original data parent disappeared; retained'}
    [IO.File]::WriteAllBytes((Get-HarnessLongPath $file.path),$bytes);[IO.File]::SetAttributes((Get-HarnessLongPath $file.path),[IO.FileAttributes]$file.attributes)
    if((Get-HarnessFileSha256 $file.path) -cne $file.sha256){throw 'Restored data hash differs'};$changes.Add(@{action='restored';path=$file.path;sha256=$digest})
   }}finally{$zip.Dispose()}
  }
  $oldFolders=@($root.folders|ForEach-Object {$_.path})
  foreach($folder in @($now.folders|Where-Object {$_.path -notin $oldFolders}|Sort-Object {$_.path.Length} -Descending)){
   if([long]$folder.creationTimeFileTimeUtc -lt [long]$Before.takenAtFileTimeUtc){throw 'New data directory predates the run; retained'}
   if((Get-HarnessFolderIdentity $folder.path).creationTimeFileTimeUtc -cne $folder.creationTimeFileTimeUtc){throw 'Data directory identity changed; retained'}
   $entry=Add-HarnessEntry 'folder' (Get-HarnessFolderIdentity $folder.path) 'memory-data-output' 'run' @{emptyOnly=$true};Remove-HarnessEntry $entry
  }
  if(-not$root.exists -and $now.exists){$identity=Get-HarnessFolderIdentity $root.path;if([long]$identity.creationTimeFileTimeUtc -lt [long]$Before.takenAtFileTimeUtc){throw 'New data root predates this run; retained'};$entry=Add-HarnessEntry 'folder' $identity 'memory-data-output' 'run' @{emptyOnly=$true};Remove-HarnessEntry $entry}
 }
 return @($changes)
}
function Restore-MemoryRegistry($Before,$Current){
 Assert-HarnessHostLease
 $changes=[Collections.Generic.List[object]]::new()
 if(@($Current|Where-Object {$_.exists -and $_.path -notin @($Before|Where-Object exists|ForEach-Object path)}).Count){throw 'Unexpected registry key appeared; retained for review'}
 foreach($row in $Before|Where-Object exists){
  $base=if($row.hive -eq 'LocalMachine'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::CurrentUser}
  $key=$base.OpenSubKey($row.path,$true);if(-not$key){throw 'As-found registry key disappeared; retained for review'}
  try{
   $now=@($Current|Where-Object {$_.hive -ceq $row.hive -and $_.path -ceq $row.path})[0]
   if(@($now.values|Where-Object {$_.name -notin @($row.values|ForEach-Object name)}).Count){throw 'Unexpected registry value appeared; retained for review'}
   foreach($value in $row.values){
    $actual=@($now.values|Where-Object name -CEQ $value.name);if($actual.Count -ne 1){throw 'As-found registry value disappeared; retained for review'}
    if($actual[0].rawBase64 -ceq $value.rawBase64 -and $actual[0].kind -eq $value.kind){continue}
    if([Convert]::ToBase64String([RooIndustriesMemoryRegistry]::Read($key,$value.name)) -cne $actual[0].rawBase64 -or [int]$key.GetValueKind($value.name) -ne $actual[0].kind){throw 'Registry changed after snapshot; retained'}
    [RooIndustriesMemoryRegistry]::Write($key,$value.name,[uint32]$value.kind,[Convert]::FromBase64String($value.rawBase64));$changes.Add(@{hive=$row.hive;path=$row.path;name=$value.name})
   }
  }finally{$key.Dispose()}
 }
 return @($changes)
}
