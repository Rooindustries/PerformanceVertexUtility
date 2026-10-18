param([Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$Helper,[switch]$Before,[Parameter(Mandatory)][string]$ExpectedMachine,[Parameter(Mandatory)][string]$ExpectedUserSid)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($env:COMPUTERNAME -cne $ExpectedMachine -or $identity.User.Value -cne $ExpectedUserSid -or -not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Fixture identity differs'}
if($Frame -cnotmatch '^C:\\RooBuild\\policy-permission-[a-f0-9]{32}$'){throw 'Private frame differs'}
foreach($p in @('C:\RooBuild',$Frame)){$i=Get-Item -LiteralPath $p;if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse frame'};$a=Get-Acl -LiteralPath $p;if($a.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-32-544','S-1-5-18'){throw 'Frame owner differs'};foreach($r in $a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -notin 'S-1-5-32-544','S-1-5-18' -and ([long]$r.FileSystemRights -band 0x500D0156)){throw 'Frame has an untrusted writer'}}}
$env:TEMP=$Frame;$env:TMP=$Frame
. $Helper
$probe=@([IO.File]::ReadAllLines($Script)|Where-Object {$_ -cmatch '^\$result.changePermissions=Attempt \{.+\}$'})
if($probe.Count -ne 1){throw 'Expected one actual permission probe'}
$operation=$probe[0].Substring('$result.changePermissions=Attempt '.Length)
$sid=$identity.User.Value
function FixtureDirectory([string]$Path,[string]$Rights){
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;RC;;;OW)')
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$Rights,'ContainerInherit,ObjectInherit','None','Allow'))
 if(Test-Path -LiteralPath $Path){throw 'Fixture destination exists'};[IO.Directory]::CreateDirectory($Path,$acl)|Out-Null
}
$output=Join-Path $Frame 'result'
$open=Join-Path $Frame 'writable'
$sealed=Join-Path $Frame 'sealed'
FixtureDirectory $output 'FullControl';FixtureDirectory $open 'FullControl';FixtureDirectory $sealed 'ReadAndExecute'
[IO.Directory]::CreateDirectory((Join-Path $open 'rules'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $sealed 'rules'))|Out-Null
$sealedBefore=(Get-Acl -LiteralPath (Join-Path $sealed 'rules')).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group')
$reply=Join-Path $output 'result.json';$ready=Join-Path $output 'ready.json';$release=Join-Path $output 'release.txt'
$child=@'
$ErrorActionPreference='Stop'
$result=[ordered]@{}
$result.user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$result.elevated=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Attempt([scriptblock]$Block){try{& $Block|Out-Null;[pscustomobject]@{allowed=$true;message='';id='';command=''}}catch{[pscustomobject]@{allowed=$false;message=$_.Exception.Message;id=$_.FullyQualifiedErrorId;command=$_.InvocationInfo.MyCommand.Name}}}
$process=[Diagnostics.Process]::GetCurrentProcess()
[IO.File]::WriteAllText('READY',(@{pid=$PID;creationTimeFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();image=$process.MainModule.FileName}|ConvertTo-Json -Compress))
$result.control=Attempt CONTROL
$result.protected=Attempt SEALED
[IO.File]::WriteAllText('REPLY',($result|ConvertTo-Json -Depth 8))
$clock=[Diagnostics.Stopwatch]::StartNew()
while(-not [IO.File]::Exists('RELEASE') -and $clock.Elapsed.TotalSeconds -lt 20){Start-Sleep -Milliseconds 25}
if(-not [IO.File]::Exists('RELEASE')){exit 2}
'@
$child=$child.Replace('CONTROL',$operation.Replace('ROOT',$open)).Replace('SEALED',$operation.Replace('ROOT',$sealed)).Replace('READY',$ready).Replace('REPLY',$reply).Replace('RELEASE',$release)
$system=[Environment]::SystemDirectory
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
$arguments='/trustlevel:0x20000 "'+(Join-Path $system 'conhost.exe')+' --headless '+(Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe')+' -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded+'"'
$runas=$null;$launchReceipt=$null;$process=$null;$owned=$null;$passed=$false
try{
 $born=[DateTime]::UtcNow.ToFileTimeUtc()
 $runas=Start-Process -FilePath (Join-Path $system 'runas.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru;$launchReceipt=New-OwnedProcess $runas
 $clock=[Diagnostics.Stopwatch]::StartNew();while(-not(Test-Path -LiteralPath $reply) -and $clock.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 50}
 if(-not(Test-Path -LiteralPath $reply)){throw 'Restricted child did not report'}
 $native=[IO.File]::ReadAllText($ready)|ConvertFrom-Json;$process=Get-Process -Id $native.pid -ErrorAction Stop;$candidate=New-OwnedProcess $process;$row=Get-CimInstance Win32_Process -Filter ('ProcessId='+$native.pid)
 if(-not$candidate -or -not$row -or -not([string]$row.CommandLine).EndsWith(' -EncodedCommand '+$encoded,[StringComparison]::Ordinal) -or [long]$candidate.Identity.creationTimeFileTimeUtc -lt $born -or $candidate.Identity.creationTimeFileTimeUtc -cne $native.creationTimeFileTimeUtc -or $candidate.Identity.imagePath -cne [RooIndustriesValidationOwnership.Native]::Canonical((Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'))){throw 'Restricted child native identity differs'}
 $owned=$candidate
 $observed=[IO.File]::ReadAllText($reply)|ConvertFrom-Json
 if($observed.elevated -or $observed.user -cne $sid){throw 'Restricted token differs'}
 if($Before){$passed=-not$observed.control.allowed -and $observed.control.message -like '*identity references could not be translated*' -and -not$observed.protected.allowed -and $observed.protected.message -like '*identity references could not be translated*'}
 else{$passed=$observed.control.allowed -and -not$observed.protected.allowed -and $observed.protected.command -ceq 'Set-Acl' -and $observed.protected.id -like '*UnauthorizedAccess*'}
 if((Get-Acl -LiteralPath (Join-Path $sealed 'rules')).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group') -cne $sealedBefore){throw 'Protected descriptor changed'}
 [IO.File]::WriteAllText($release,'complete')
 if(-not$process.WaitForExit(5000)){throw 'Owned child did not finish'};$process.Refresh();if($process.ExitCode -ne 0){throw 'Owned child failed'}
 $proof=[ordered]@{passed=$passed;before=[bool]$Before;machine=$env:COMPUTERNAME;sid=$sid;sourceSha256=(Get-FileHash -LiteralPath $Script).Hash;testSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;child=$owned.Identity;observed=$observed;sealedDescriptorUnchanged=$true;childExit=$process.ExitCode}
 $proof|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $Frame 'proof.json') -Encoding UTF8
 $proof|ConvertTo-Json -Depth 10
 if(-not$passed){throw 'Exact permission-probe contract failed'}
 if($Before){'PASS reproduced the old permission probe rejecting a writable control before Set-Acl'}else{'PASS actual standard-token permission probe distinguishes writable from sealed state'}
}finally{
 if($owned){Stop-OwnedProcess $owned};if($launchReceipt){Stop-OwnedProcess $launchReceipt};if($process){$process.Dispose()};if($runas){$runas.Dispose()}
}
