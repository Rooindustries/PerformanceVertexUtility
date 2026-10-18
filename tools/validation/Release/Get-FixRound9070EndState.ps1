param([Parameter(Mandatory)][string]$ExpectedMachine,[Parameter(Mandatory)][string]$ExpectedUserSid)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne $ExpectedMachine){throw 'Wrong machine for this retained audit'}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($sid -cne $ExpectedUserSid){throw 'Wrong SID for this retained audit'}
function Hash([byte[]]$Bytes){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash($Bytes)).Replace('-','')}finally{$h.Dispose()}}
$expected=@'
[{"xmlSha256":"C8539679C48C4CFCE7B7BFB5048F8481439108A20008387D37E98050237D77E2","path":"\\","name":"RooIndustriesCS2_cs2-exact-repro","state":"Ready"},{"xmlSha256":"1E897E925E7B633BBE05C7DFCF224B88DFB4BCA804E3CE265B20C576A89025D0","path":"\\","name":"RooIndustriesCS2_cs2-fix1","state":"Ready"},{"xmlSha256":"87CA392070907073F36BB4C1C44B6DFA7953CD842C1340E0AE58EDFFFE2FA94C","path":"\\","name":"RooIndustriesCS2_Echo","state":"Ready"},{"xmlSha256":"52A5211211DFAB21E6652D6610DD4787852FC093E4686CEADC2E1DB460E746A4","path":"\\","name":"RooIndustriesCS2_Guard","state":"Ready"},{"xmlSha256":"B9601570A1364AFE32000B8337843AAC8F8A4B5BC9DE11862B0576637C7902C0","path":"\\","name":"RooIndustriesCS2_Trial","state":"Ready"},{"xmlSha256":"94FB152C5502046B0231028C2A78F223AFEFC5597636A6AB9F70DFA979BB3823","path":"\\","name":"RooIndustriesCS2_UserLaunch","state":"Ready"}]
'@|ConvertFrom-Json
$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustriesOptimizationSuite\Tweaks\'+$sid)
try{$bytes=$key.GetValue('State',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$state=@{kind=[string]$key.GetValueKind('State');length=$bytes.Length;sha256=(Hash ([byte[]]$bytes))}}finally{$key.Dispose()}
$tasks=@(Get-ScheduledTask -TaskName 'RooIndustriesCS2_*'|Sort-Object TaskName|ForEach-Object {@{name=$_.TaskName;path=$_.TaskPath;state=[string]$_.State;xmlSha256=(Hash ([Text.Encoding]::UTF8.GetBytes((Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath))))}})
$taskSet=@($tasks|ForEach-Object {$_.path+$_.name+'|'+$_.xmlSha256}|Sort-Object)
$expectedSet=@($expected|ForEach-Object {$_.path+$_.name+'|'+$_.xmlSha256}|Sort-Object)
$app='C:\Program Files\Roo Industries\Optimization Suite'
$uninstall=@(foreach($view in 'Registry64','Registry32'){$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]$view);try{$key=$base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall');try{foreach($name in $key.GetSubKeyNames()){$entry=$key.OpenSubKey($name);try{if($name -ceq '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1' -or [string]$entry.GetValue('DisplayName') -match '^(Performance Vertex Utility|Roo Industries Optimization Suite|Roo Optimization Suite)$'){@{name=$name;view=$view;version=[string]$entry.GetValue('DisplayVersion')}}}finally{$entry.Dispose()}}}finally{$key.Dispose()}}finally{$base.Dispose()}})
$processes=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -in @('Optimizer.Host.exe','RooIndustries.SessionHost.exe','RooIndustries.OptimizationSuite.App.exe','RooIndustriesProcessGovernor.exe','RooOptimizationSuite.App.exe') -or $_.CommandLine -match '(^|[\\ /"])(?:Optimizer\.Host|RooIndustries\.SessionHost)\.dll([ " ]|$)' -or ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($app+'\',[StringComparison]::OrdinalIgnoreCase))}|ForEach-Object {@{pid=$_.ProcessId;image=$_.ExecutablePath;name=$_.Name}})
$verificationTasks=@(Get-ScheduledTask|Where-Object {$_.TaskName -like 'RooIndustries_Verify_*'}|ForEach-Object {@{name=$_.TaskName;state=[string]$_.State}})
$checks=@(
 @{passed=($state.kind -ceq 'Binary' -and $state.length -eq 7529986 -and $state.sha256 -ceq '3E83144CD3269C9000E8F36F935CE9FBEE4CABDC0E1F929E347DEA12E5ED924F');check='The real HKLM State has exact binary kind length and SHA256'},
 @{passed=($tasks.Count -eq 6 -and ($taskSet -join '|') -ceq ($expectedSet -join '|'));check='All six CS2 task XML hashes are unchanged'},
 @{passed=(-not(Test-Path -LiteralPath $app) -and $uninstall.Count -eq 0);check='No product installation folder or uninstall entry exists'},
 @{passed=($processes.Count -eq 0);check='No product processes remain'},
 @{passed=($verificationTasks.Count -eq 0);check='No verification tasks remain'}
)
@{machine=$env:COMPUTERNAME;sid=$sid;atUtc=[DateTime]::UtcNow.ToString('o');state=$state;tasks=$tasks;expectedTasks=$expected;appExists=(Test-Path -LiteralPath $app);uninstallEntries=$uninstall;processes=$processes;verificationTasks=$verificationTasks;checks=$checks;passed=(@($checks|Where-Object {-not $_.passed}).Count -eq 0)}|ConvertTo-Json -Depth 8
