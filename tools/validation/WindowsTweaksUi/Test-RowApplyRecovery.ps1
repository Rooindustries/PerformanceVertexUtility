param([Parameter(Mandatory)][string]$Source)
# Runs the row capture's recovery on disposable HKCU values: one value can't be written back, so recovery stops part-way, another program then
# sets the values that were already put back, and the retry must leave those alone while it finishes the one it couldn't write.
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\WindowsTweaksUi\RowApplyJournal.ps1')
$parent='Software\RooIndustriesTweakTests';$parentExisted=Test-Path -LiteralPath ('HKCU:\'+$parent)
$fixture=$parent+'\'+[Guid]::NewGuid().ToString('N');$journal=$fixture+'\Journal';$open=$fixture+'\Open';$locked=$fixture+'\Locked'
$one=[ordered]@{exists=$true;type=4;data=[Convert]::ToBase64String([BitConverter]::GetBytes([uint32]1))}
$zero=[ordered]@{exists=$true;type=4;data=[Convert]::ToBase64String([BitConverter]::GetBytes([uint32]0))}
$failed=@()
function Check([bool]$Condition,[string]$Name){if($Condition){Write-Output ('PASS '+$Name)}else{Write-Output ('FAIL '+$Name);$script:failed+=$Name}}
function Saved{@((ConvertFrom-Json ([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($journal).GetValue('Record'))).values|ForEach-Object {$_.valueName})}
function Lock([bool]$Deny){
 $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($locked,[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Security.AccessControl.RegistryRights]::ReadPermissions -bor [Security.AccessControl.RegistryRights]::ChangePermissions)
 try{$acl=$key.GetAccessControl();$rule=[Security.AccessControl.RegistryAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.RegistryRights]::SetValue,[Security.AccessControl.AccessControlType]::Deny);if($Deny){$acl.AddAccessRule($rule)}else{[void]$acl.RemoveAccessRule($rule)};$key.SetAccessControl($acl)}finally{$key.Dispose()}
}
$denied=$false
try{
 if(Test-Path -LiteralPath ('HKCU:\'+$fixture)){throw 'The fixture key already exists.'}
 foreach($path in $open,$locked){[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path).Dispose()}
 # Written: the capture wrote 0. Pending: a write of 0 that may have happened. Back: the capture wrote 0 but the value already reads its original.
 $cases=@(@{path=$open;name='Written';now=$zero;written=$zero;pending=$null},@{path=$open;name='Pending';now=$zero;written=$null;pending=$zero},@{path=$open;name='Back';now=$one;written=$zero;pending=$null},@{path=$locked;name='Locked';now=$zero;written=$zero;pending=$null})
 $record=[ordered]@{parentExisted=$parentExisted;values=@(foreach($case in $cases){[ordered]@{hive='CurrentUser';keyPath=$case.path;valueName=$case.name;original=(State $one);written=(State $case.written);pending=(State $case.pending)}})}
 foreach($entry in $record.values){WriteValue $entry @{exists=$true;type=4;data=@($cases|Where-Object {$_.name -eq $entry.valueName})[0].now.data}}
 SaveJournal $record
 Lock $true;$denied=$true
 $first=Recover (ConvertFrom-Json ([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($journal).GetValue('Record')))
 Check ($first.restored.Count -eq 2 -and $first.errors.Count -eq 1 -and $first.errors[0] -like 'Locked:*') ('The first recovery puts back Written and Pending and stops on Locked, saw restored: '+($first.restored -join '; ')+' errors: '+($first.errors -join '; '))
 foreach($name in 'Written','Pending','Back'){Check (Same (ReadValue @{hive='CurrentUser';keyPath=$open;valueName=$name}) $one) ($name+' reads its original REG_DWORD 1 after the first recovery')}
 Check ((@(Saved) -join ',') -eq 'Locked') ('The saved record keeps only the value it could not write back, saw: '+(@(Saved) -join ','))
 foreach($name in 'Written','Pending','Back'){WriteValue @{hive='CurrentUser';keyPath=$open;valueName=$name} $zero}
 Lock $false;$denied=$false
 $second=Recover (ConvertFrom-Json ([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($journal).GetValue('Record')))
 foreach($name in 'Written','Pending','Back'){Check (Same (ReadValue @{hive='CurrentUser';keyPath=$open;valueName=$name}) $zero) ($name+' keeps the REG_DWORD 0 another program set after the first recovery')}
 Check (Same (ReadValue @{hive='CurrentUser';keyPath=$locked;valueName='Locked'}) $one) 'The retry puts Locked back to REG_DWORD 1'
 Check ($second.errors.Count -eq 0 -and $second.conflicts.Count -eq 0 -and (@($second.restored) -join ';') -eq 'Locked back to REG_DWORD 1') ('The retry restores only Locked, saw restored: '+($second.restored -join '; ')+' conflicts: '+($second.conflicts -join '; ')+' errors: '+($second.errors -join '; '))
 Check (@(Saved).Count -eq 0) 'The saved record is empty after the retry'
}catch{
 Write-Output ('FAIL '+$_.Exception.Message);$failed+='exception'
}finally{
 if($denied){Lock $false}
 if(Test-Path -LiteralPath ('HKCU:\'+$fixture)){Remove-Item -LiteralPath ('HKCU:\'+$fixture) -Recurse -Force}
 if(-not$parentExisted -and (Test-Path -LiteralPath ('HKCU:\'+$parent))){$left=Get-Item -LiteralPath ('HKCU:\'+$parent);if($left.SubKeyCount -eq 0 -and $left.ValueCount -eq 0){Remove-Item -LiteralPath ('HKCU:\'+$parent) -Force}}
 Check (-not(Test-Path -LiteralPath ('HKCU:\'+$fixture))) 'The fixture key is removed'
}
Write-Output ('ROO_INDUSTRIES_ROW_RECOVERY '+$(if($failed.Count){'fail'}else{'pass'}))
if($failed.Count){exit 1}
