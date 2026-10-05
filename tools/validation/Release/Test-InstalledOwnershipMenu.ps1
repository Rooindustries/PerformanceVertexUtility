param(
    [Parameter(Mandatory=$true)][string]$ExpectedMachine,
    [Parameter(Mandatory=$true)][string]$RunRoot,
    [Parameter(Mandatory=$true)][string]$BackupRoot,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [string]$InstallRoot='C:\Program Files\Roo Industries\Optimization Suite'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$checks=New-Object 'Collections.Generic.List[object]'
$started=[DateTime]::UtcNow
$deadline=$started.AddMinutes(10)
$profile='rf3-'+[Guid]::NewGuid().ToString('N')
$filesId='windows.13b6c0d8fb231462'
$foldersId='windows.c26219e8cf004354'
$choice='choice-9bcf07ce29d33486'
$menu='Software\Classes\*\shell\RooIndustries.TakeOwnership'
$commandKey=$menu+'\command'
$applyAttempted=$false
$undoCompleted=$false
$stateRestored=$false
$originalFailure=$null
$cleanupFailure=$null
$beforeBytes=$null
$ownedBytes=$null
$result=[ordered]@{phase='rf3-installed-ownership';machine=$env:COMPUTERNAME;profileId=$profile;checks=$null}
function Check([bool]$Passed,[string]$Name,[string]$Detail='') {
    $checks.Add([pscustomobject]@{passed=$Passed;check=$Name;detail=$Detail})
    $(if($Passed){'PASS '}else{'FAIL '})+$Name+' :: '+$Detail
    if(-not$Passed){throw $Name}
}
function Assert-Plain([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while($p){$i=Get-Item -LiteralPath $p -Force;if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked path refused'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Assert-Protected([string]$Path,[switch]$Installed) {
    Assert-Plain $Path
    $a=Get-Acl -LiteralPath $Path
    $trusted=@('S-1-5-18','S-1-5-32-544')
    if($Installed){$trusted+='S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'}
    if($a.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Unprotected owner refused'}
    foreach($r in $a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($Installed -and $r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -ceq 'S-1-3-0' -and ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
        if($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -notin $trusted -and ([long]$r.FileSystemRights -band 0x500D0156)){throw 'Unprotected writer refused'}
    }
}
function New-Protected([string]$Path) {
    if(Test-Path -LiteralPath $Path){throw 'Existing proof directory retained'}
    Assert-Protected ([IO.Path]::GetDirectoryName($Path))
    $a=[Security.AccessControl.DirectorySecurity]::new();$a.SetAccessRuleProtection($true,$false);$a.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($s in 'S-1-5-18','S-1-5-32-544'){$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($s),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    [IO.Directory]::CreateDirectory($Path,$a)|Out-Null
}
Add-Type @'
using System;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
public static class RooInstalledOwnershipProof {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegQueryValueEx(IntPtr key,string name,IntPtr reserved,out uint type,byte[] data,ref uint size);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegOpenKeyEx(IntPtr key,string name,uint options,uint access,out IntPtr result);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegOpenKeyTransacted(IntPtr key,string name,uint options,uint access,out IntPtr result,IntPtr transaction,IntPtr reserved);
    [DllImport("ktmw32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateTransaction(IntPtr attributes,IntPtr id,uint options,uint isolation,uint flags,uint timeout,string description);
    [DllImport("ktmw32.dll", SetLastError=true)] static extern bool CommitTransaction(IntPtr transaction);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static byte[] Read(RegistryKey key,string name,out uint type) {
        uint size=0;int error=RegQueryValueEx(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out type,null,ref size);
        if(error==2){type=0;return null;}if(error!=0)throw new Win32Exception(error);
        if(size>8*1024*1024)throw new InvalidOperationException("Registry proof value exceeds its bound.");
        var bytes=new byte[size];error=RegQueryValueEx(key.Handle.DangerousGetHandle(),name,IntPtr.Zero,out type,bytes,ref size);
        if(error!=0)throw new Win32Exception(error);Array.Resize(ref bytes,(int)size);return bytes;
    }
    public static string Hash(byte[] bytes) {using(var h=SHA256.Create())return BitConverter.ToString(h.ComputeHash(bytes)).Replace("-","");}
    public static RegistryKey Open(RegistryHive hive,string path) {
        RegistryKey key=RegistryKey.OpenBaseKey(hive,RegistryView.Registry64);
        try {
            foreach(var part in path.Split('\\')) {
                IntPtr handle;int error=RegOpenKeyEx(key.Handle.DangerousGetHandle(),part,8,0x20119,out handle);
                if(error==2){key.Dispose();return null;}if(error!=0)throw new Win32Exception(error);
                var next=RegistryKey.FromHandle(new SafeRegistryHandle(handle,true),RegistryView.Registry64);key.Dispose();key=next;
                uint type;Read(key,"SymbolicLinkValue",out type);if(type==6)throw new InvalidOperationException("Registry link refused.");
            }
            return key;
        } catch {key.Dispose();throw;}
    }
    public static string OtherValues(RegistryKey key) {
        var rows=key.GetValueNames().Where(n=>!string.Equals(n,"State",StringComparison.OrdinalIgnoreCase)).OrderBy(n=>n,StringComparer.Ordinal).Select(n=>{uint t;var b=Read(key,n,out t);return n+"|"+t+"|"+b.Length+"|"+Hash(b);});
        return Hash(System.Text.Encoding.UTF8.GetBytes(string.Join("\n",rows)));
    }
    public static void RestoreState(string path,byte[] expected,byte[] original,string descriptor,string otherValues) {
        IntPtr transaction=CreateTransaction(IntPtr.Zero,IntPtr.Zero,0,0,0,30000,"Roo Industries RF-3 proof cleanup");
        if(transaction==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr handle;int error=RegOpenKeyTransacted(new IntPtr(unchecked((int)0x80000002)),path,0,0x20103,out handle,transaction,IntPtr.Zero);
            if(error!=0)throw new Win32Exception(error);
            using(var key=RegistryKey.FromHandle(new SafeRegistryHandle(handle,true),RegistryView.Registry64)) {
                uint type;var current=Read(key,"State",out type);
                if(type!=3||current==null||!current.SequenceEqual(expected))throw new InvalidOperationException("Foreign State drift retained.");
                if(key.GetAccessControl(AccessControlSections.Access|AccessControlSections.Owner|AccessControlSections.Group).GetSecurityDescriptorSddlForm(AccessControlSections.Access|AccessControlSections.Owner|AccessControlSections.Group)!=descriptor||OtherValues(key)!=otherValues)throw new InvalidOperationException("State key neighbors or permissions changed; retained.");
                key.SetValue("State",original,RegistryValueKind.Binary);
                if(!Read(key,"State",out type).SequenceEqual(original))throw new InvalidOperationException("State cleanup readback differs.");
                if(!CommitTransaction(transaction))throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        } finally {CloseHandle(transaction);}
    }
}
'@
function State-Bytes {
    $k=[RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::LocalMachine,$stateKey)
    if(-not$k){throw 'State key missing'}
    try{[uint32]$t=0;$b=[RooInstalledOwnershipProof]::Read($k,'State',[ref]$t);if($t -ne 3 -or $null -eq $b){throw 'State is not binary'};return ,$b}finally{$k.Dispose()}
}
function Stamp([byte[]]$Bytes) {[ordered]@{type='Binary';length=$Bytes.Length;sha256=[RooInstalledOwnershipProof]::Hash($Bytes)}}
function State-Object([byte[]]$Bytes) {[Text.Encoding]::UTF8.GetString($Bytes)|ConvertFrom-Json}
function Same-Object($A,$B) {(ConvertTo-Json -InputObject $A -Depth 100 -Compress) -ceq (ConvertTo-Json -InputObject $B -Depth 100 -Compress)}
function Menu-Rows {
    $rows=New-Object 'Collections.Generic.List[object]'
    function Visit([string]$Path,[int]$Depth) {
        if($Depth -gt 16 -or $rows.Count -gt 10000){throw 'Menu snapshot exceeds its bound'}
        $k=[RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::CurrentUser,$Path)
        if(-not$k){$rows.Add([ordered]@{path=$Path;missing=$true});return}
        try {
            $values=@(foreach($n in $k.GetValueNames()|Sort-Object){[uint32]$t=0;$b=[RooInstalledOwnershipProof]::Read($k,$n,[ref]$t);[ordered]@{name=$n;type=$t;length=$b.Length;sha256=[RooInstalledOwnershipProof]::Hash($b)}})
            $rows.Add([ordered]@{path=$Path;missing=$false;descriptor=$k.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group');values=$values})
            foreach($n in $k.GetSubKeyNames()|Sort-Object){$child=$Path+'\'+$n;if($child -ine $menu){Visit $child ($Depth+1)}}
        }finally{$k.Dispose()}
    }
    foreach($p in @('Software\Classes\*\shell','Software\Classes\Directory\shell','Software\Classes\Directory\Background\shell','Software\Classes\Drive\shell','Software\Classes\Folder\shell','Software\Classes\AllFilesystemObjects\shell')){Visit $p 0}
    return ,$rows.ToArray()
}
function Other-Menus-DuringApply($Now,$AllowedParents) {
    $absent=@($menus|Where-Object missing|ForEach-Object path)
    foreach($row in $Now|Where-Object {$_.path -in $absent}){if(-not$row.missing -and ($row.path -notin $AllowedParents -or @($row.values).Count -ne 0)){return $false}}
    return Same-Object @($menus|Where-Object {$_.path -notin $absent}) @($Now|Where-Object {$_.path -notin $absent})
}
function Menu-Absent {
    $k=[RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::CurrentUser,$menu)
    try{return $null -eq $k}finally{if($k){$k.Dispose()}}
}
function Call-Host([string]$Action,[hashtable]$Extra=@{}) {
    if([DateTime]::UtcNow -ge $deadline){throw 'RF-3 overall deadline reached'}
    if((Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash -cne $hostHash){throw 'Installed Host changed; retained'}
    $request=@{schemaVersion=1;repoRoot=$InstallRoot;confirm=$true};foreach($n in $Extra.Keys){$request[$n]=$Extra[$n]}
    $psi=[Diagnostics.ProcessStartInfo]::new($hostExe,$Action+' -');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($n in @($psi.EnvironmentVariables.Keys)){if($n -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'){$psi.EnvironmentVariables.Remove($n)}}
    $p=[Diagnostics.Process]::Start($psi)
    try {
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        $p.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 12 -Compress));$p.StandardInput.Close()
        if(-not$p.WaitForExit(90000)){$p.Kill();$p.WaitForExit();throw ('Owned Host call timed out: '+$Action)}
        $reply=$stdout.Result|ConvertFrom-Json
        if($p.ExitCode -ne 0 -or $reply.status -cne 'completed'){throw ('Installed Host refused '+$Action)}
        return $reply.data
    }finally{$p.Dispose()}
}
function Check-Status([string]$When) {
    $s=Call-Host 'tweak-status'
    $rows=@(foreach($id in $filesId,$foldersId){$r=@($s.settings|Where-Object id -CEQ $id);Check ($r.Count -eq 1 -and $r[0].supported -eq $true -and $null -eq $r[0].error -and $r[0].availableChoices -contains $choice) ('Installed setting '+$id+' is checkable '+$When);[ordered]@{id=$id;supported=[bool]$r[0].supported;error=$r[0].error;availableChoices=@($r[0].availableChoices)}})
    $result['status-'+$When]=@($rows|Where-Object {$_ -isnot [string]})
    return $s.context
}
function Observe-OwnedState($Reply,$Plan) {
    $b=State-Bytes;$s=State-Object $b
    if($s.revision -cne $Plan.afterRevision -or -not(Same-Object $s $Reply.state) -or @($s.history|Where-Object {$_.operationId -ceq $Plan.operationId -and $_.reviewHash -ceq $Plan.reviewHash -and $_.profileId -ceq $profile}).Count -ne 1){throw 'Owned Host outcome and live State disagree; retained'}
    return ,$b
}
function Undo-OwnProfile {
    $liveBytes=State-Bytes
    if($ownedBytes -and [RooInstalledOwnershipProof]::Hash($liveBytes) -cne [RooInstalledOwnershipProof]::Hash($ownedBytes)){throw 'Foreign State drift retained before Host undo'}
    $live=State-Object $liveBytes
    if(@($live.profiles|Where-Object id -CEQ $profile).Count -eq 0){return}
    $path=Join-Path $private ('undo-'+[Guid]::NewGuid().ToString('N')+'.json')
    $plan=Call-Host 'tweak-preview' @{profileId=$profile;selections=@();outputPath=$path}
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if($plan.profileId -cne $profile -or @($plan.selections).Count -ne 0 -or @($plan.changes).Count -ne 1 -or $plan.changes[0].before.address.hive -cne 'CurrentUser' -or $plan.changes[0].before.address.view -cne 'Registry64' -or $plan.changes[0].before.address.keyPath -cne $commandKey -or $plan.changes[0].before.address.valueName -cne '' -or $plan.changes[0].before.value.type -ne 1 -or [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($plan.changes[0].before.value.bytes)).TrimEnd([char]0) -cne $expected -or $null -ne $plan.changes[0].after -or @($plan.controls.changes|Where-Object {$null -ne $_}).Count -ne 0){throw 'Undo review exceeds the owned file-menu value; retained'}
    $reply=Call-Host 'tweak-restore' @{previewPath=$path;reviewHash=$hash;acceptEarlierVersion=$true}
    $plan|Add-Member -NotePropertyName reviewHash -NotePropertyValue $hash
    $script:ownedBytes=Observe-OwnedState $reply $plan
    $result.undo=[ordered]@{operationId=$plan.operationId;reviewHash=$hash;state=(Stamp $ownedBytes)}
    $script:undoCompleted=$true
}
try {
    if($env:COMPUTERNAME -ine $ExpectedMachine -or [IntPtr]::Size -ne 8){throw 'Wrong machine or registry view'}
    $who=[Security.Principal.WindowsIdentity]::GetCurrent();$sid=$who.User.Value
    if(-not([Security.Principal.WindowsPrincipal]::new($who).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Administrator token required'}
    if([IO.Path]::GetFullPath($InstallRoot) -ine 'C:\Program Files\Roo Industries\Optimization Suite'){throw 'Unexpected installed root'}
    Assert-Protected $RunRoot;Assert-Protected $BackupRoot
    if([IO.Path]::GetFullPath($BackupRoot) -ine (Join-Path ([IO.Path]::GetFullPath($RunRoot)) 'recovery')){throw 'Recovery root differs'}
    $epoch=Join-Path $BackupRoot 'epoch-installed';Assert-Protected $epoch
    $lease=Get-Content -LiteralPath (Join-Path $epoch 'lease.json') -Raw|ConvertFrom-Json
    if($lease.label -cne 'installed' -or $lease.sid -cne $sid -or (Test-Path -LiteralPath (Join-Path $epoch 'restore-complete.json'))){throw 'Active installed recovery epoch required'}
    if(-not([IO.Path]::GetFullPath($OutDir).StartsWith([IO.Path]::GetFullPath($RunRoot).TrimEnd('\')+'\evidence\',[StringComparison]::OrdinalIgnoreCase))){throw 'Evidence path differs'}
    New-Protected $OutDir
    $private=Join-Path $RunRoot ('rf3-private-'+[Guid]::NewGuid().ToString('N'));New-Protected $private
    $hostExe=Join-Path $InstallRoot 'backend\bin\optimizer\Optimizer.Host.exe';$uiExe=Join-Path $InstallRoot 'app\RooIndustries.OptimizationSuite.App.exe'
    foreach($p in $InstallRoot,(Split-Path $uiExe),$uiExe,(Split-Path $hostExe),$hostExe){Assert-Protected $p -Installed}
    $hostHash=(Get-FileHash -LiteralPath $hostExe -Algorithm SHA256).Hash
    $versions=@(foreach($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'){Get-ChildItem -LiteralPath $root|ForEach-Object {Get-ItemProperty -LiteralPath $_.PSPath}|Where-Object DisplayName -like '*Optimization Suite*'|ForEach-Object DisplayVersion})
    Check ($versions.Count -eq 1 -and $versions[0] -ceq '0.10.0-beta') 'Production 0.10.0-beta is installed in Program Files'
    $stateKey='SOFTWARE\RooIndustriesOptimizationSuite\Tweaks\'+$sid
    $beforeBytes=State-Bytes;$before=State-Object $beforeBytes
    $k=[RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::LocalMachine,$stateKey)
    try{$stateDescriptor=$k.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group');$stateOther=[RooInstalledOwnershipProof]::OtherValues($k);[uint32]$t=0;if($null -ne [RooInstalledOwnershipProof]::Read($k,'Pending',[ref]$t)){throw 'Pending tweak operation retained'}}finally{$k.Dispose()}
    $menus=Menu-Rows
    Check (Menu-Absent) 'The file ownership menu is absent before the step'
    Check (@($before.profiles|ForEach-Object {$_.selections}|Where-Object settingId -CEQ $filesId).Count -eq 0) 'No existing profile owns setting 693'
    $context=Check-Status 'before'
    if($context.owner.machine -ine $ExpectedMachine -or $context.owner.userSid -cne $sid -or $context.storeId -notmatch '^windows-registry:[A-Fa-f0-9]{64}$' -or $context.storeId -cne $before.context.storeId){throw 'Installed tweak store identity differs'}
    Check ((Stamp (State-Bytes)).sha256 -ceq (Stamp $beforeBytes).sha256) 'Read-only status preserves the pre-step State binary'
    $result.before=[ordered]@{state=(Stamp $beforeBytes);otherMenus=$menus};$result.hostSha256=$hostHash;$result.uiSha256=(Get-FileHash -LiteralPath $uiExe -Algorithm SHA256).Hash
    $expected='"'+$uiExe+'" --ownership-review "%1"'
    $path=Join-Path $private 'apply.json'
    $plan=Call-Host 'tweak-preview' @{profileId=$profile;selections=@(@{settingId=$filesId;optionId=$choice});outputPath=$path}
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if($plan.profileId -cne $profile -or @($plan.selections).Count -ne 1 -or $plan.selections[0].settingId -cne $filesId -or @($plan.changes).Count -ne 1 -or @($plan.controls.changes|Where-Object {$null -ne $_}).Count -ne 0){throw 'Apply review includes other settings'}
    $change=$plan.changes[0]
    if($change.before.address.hive -cne 'CurrentUser' -or $change.before.address.view -cne 'Registry64' -or $change.before.address.keyPath -cne $commandKey -or $change.before.address.valueName -cne '' -or $null -ne $change.before.value -or $change.after.type -ne 1 -or [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($change.after.bytes)).TrimEnd([char]0) -cne $expected){throw 'Apply review is not the exact installed ownership command'}
    $result.apply=[ordered]@{operationId=$plan.operationId;reviewHash=$hash};$result.privatePreviews=$private
    $result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $OutDir 'receipt.json') -Encoding UTF8
    $applyAttempted=$true
    $reply=Call-Host 'tweak-apply' @{previewPath=$path;reviewHash=$hash;acceptEarlierVersion=$true}
    $plan|Add-Member -NotePropertyName reviewHash -NotePropertyValue $hash
    $ownedBytes=Observe-OwnedState $reply $plan
    $k=[RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::CurrentUser,$commandKey)
    try{[uint32]$t=0;$raw=[RooInstalledOwnershipProof]::Read($k,'',[ref]$t);$actual=[Text.Encoding]::Unicode.GetString($raw).TrimEnd([char]0)}finally{if($k){$k.Dispose()}}
    Check ($reply.changed -eq $true -and $reply.replayed -eq $false -and $t -eq 1 -and $actual -ceq $expected) 'Setting 693 applies the exact installed app ownership-review command' $actual
    Check (Other-Menus-DuringApply (Menu-Rows) @($change.before.missingKeys|ForEach-Object {if($_.StartsWith($sid+'_Classes\',[StringComparison]::OrdinalIgnoreCase)){'Software\Classes\'+$_.Substring(($sid+'_Classes\').Length)}else{$_}})) 'Applying setting 693 preserves every other menu key'
    Undo-OwnProfile
    Check $undoCompleted 'The installed Host undoes the reviewed GUID profile'
    Check (Menu-Absent) 'The Host undo removes the file ownership menu keys'
    $afterUndo=State-Object (State-Bytes)
    Check (@($afterUndo.profiles|Where-Object id -CEQ $profile).Count -eq 0 -and (Same-Object $afterUndo.profiles $before.profiles) -and (Same-Object $afterUndo.held $before.held) -and (Same-Object $afterUndo.controls $before.controls)) 'Host undo restores the pre-step profiles and held settings'
    Check (Same-Object (Menu-Rows) $menus) 'Host undo preserves every other menu key'
} catch {$originalFailure=$_.Exception.Message}
finally {
    if($applyAttempted -and -not$undoCompleted){try{Undo-OwnProfile}catch{$cleanupFailure='Host undo: '+$_.Exception.Message}}
    if($undoCompleted -and $ownedBytes -and $beforeBytes){
        $mutex=$null;$locked=$false
        try {
            if(-not(Menu-Absent) -or -not(Same-Object (Menu-Rows) $menus)){throw 'Menu drift retained before State cleanup'}
            $clean=State-Object $ownedBytes
            if(-not(Same-Object $clean.profiles $before.profiles) -or -not(Same-Object $clean.held $before.held) -or -not(Same-Object $clean.controls $before.controls) -or -not(Same-Object $clean.createdKeys $before.createdKeys) -or -not(Same-Object $clean.context $before.context) -or $clean.schemaVersion -ne $before.schemaVersion){throw 'Other profiles or held values changed; State retained'}
            $allowedHistory=@($before.history|ForEach-Object operationId)+@($result.apply.operationId,$result.undo.operationId)
            if(@($clean.history|Where-Object {$_.operationId -notin $allowedHistory}).Count -ne 0){throw 'Foreign history entry retained'}
            $mutex=[Threading.Mutex]::new($false,('Global\RooIndustriesWindowsSettings-'+$context.storeId.Split(':')[1]))
            try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
            if(-not$locked){throw 'Another Windows settings operation is in progress'}
            [RooInstalledOwnershipProof]::RestoreState($stateKey,$ownedBytes,$beforeBytes,$stateDescriptor,$stateOther)
            $stateRestored=$true
        }catch{$cleanupFailure='State fixture cleanup: '+$_.Exception.Message}
        finally{if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
    }
}
if(-not$originalFailure -and -not$cleanupFailure){
    try {
        Check $stateRestored 'Audited fixture cleanup restores the exact pre-step State bytes'
        $after=State-Bytes
        Check ((Stamp $after).sha256 -ceq (Stamp $beforeBytes).sha256 -and $after.Length -eq $beforeBytes.Length) 'The final State binary length and SHA256 equal the pre-step values'
        $null=Check-Status 'after'
        Check ((Stamp (State-Bytes)).sha256 -ceq (Stamp $beforeBytes).sha256 -and (Menu-Absent) -and (Same-Object (Menu-Rows) $menus)) 'Final status leaves State and all menu keys at their pre-step values'
        $result.after=[ordered]@{state=(Stamp (State-Bytes));otherMenus=(Menu-Rows)}
    }catch{$originalFailure=$_.Exception.Message}
}
$result.passed=(-not$originalFailure -and -not$cleanupFailure -and $checks.Count -gt 0)
$result.checks=$checks.ToArray();$result.originalFailure=$originalFailure;$result.cleanupFailure=$cleanupFailure;$result.stateRestored=$stateRestored;$result.durationSeconds=([DateTime]::UtcNow-$started).TotalSeconds
if(Test-Path -LiteralPath $OutDir){$result|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8}
if($originalFailure){'FAIL original failure: '+$originalFailure};if($cleanupFailure){'FAIL cleanup state: '+$cleanupFailure}
exit [int](-not$result.passed)
