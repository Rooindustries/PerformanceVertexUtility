param([ValidateSet('Stage','Restore','Finalize','Verify')][string]$Phase='Stage',[Parameter(Mandatory)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong historical recovery target'}
$local=[Environment]::GetFolderPath('LocalApplicationData')
$frame='C:\ProgramData\RooRecovery9070'
$backup=Join-Path $local 'roo-industries-backup'
$archivedBackup=Join-Path $frame 'as-found-original-backup'
if(-not(Test-Path -LiteralPath $backup) -and (Test-Path -LiteralPath $archivedBackup)){$backup=$archivedBackup}
$app='C:\Program Files\Roo Industries\Optimization Suite'
$timer='RooIndustries.Timer.C5E5AE90ADD1387A'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$registryState='HKLM:\SOFTWARE\RooIndustriesOptimizationSuite\Tweaks\'+$sid
$markerPath='HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$journal=Join-Path $frame 'recovery.json'
$names=@('RooOptimizationSuite','RooIndustriesOptimizationSuite')
$stages=@{RooOptimizationSuite=(Join-Path $local 'roo-restore-legacy');RooIndustriesOptimizationSuite=(Join-Path $local 'roo-restore-current')}
$installerHash='80C81A4E13C3980D74E8A5BE10847D2E0235F1DCFC56F1D6EEED8337AA71108C'
$oldStateHash='3E83144CD3269C9000E8F36F935CE9FBEE4CABDC0E1F929E347DEA12E5ED924F'
$liveStateHash='8F824A8F943DB3DC624D265FB0866313ED37132BB9096949D84399EE7A01D5E9'
$migrationFixture=Join-Path $local 'Temp\roo-industries-migration-state.json'
$migrationFixtureHash='0F11D359A7942D6928D8DBBE05BF8E07E8A3BC1DCCB8B17639C642341FBA088A'
function Get-RegistryFingerprint([string]$Key) {
    $item=Get-Item -LiteralPath ('Registry::'+$Key) -ErrorAction SilentlyContinue
    if(-not $item){return '<absent>'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        foreach($node in @($item)+@(Get-ChildItem -LiteralPath ('Registry::'+$Key) -Recurse -ErrorAction SilentlyContinue)){
            $bytes=[Text.Encoding]::UTF8.GetBytes($node.Name+"`n");[void]$sha.TransformBlock($bytes,0,$bytes.Length,$null,0)
            foreach($name in @($node.GetValueNames()|Sort-Object)){
                $value=$node.GetValue($name,$null,'DoNotExpandEnvironmentNames')
                $bytes=if($value -is [byte[]]){$value}else{[Text.Encoding]::UTF8.GetBytes((@($value) -join "`n"))}
                $head=[Text.Encoding]::UTF8.GetBytes($name+'|'+$node.GetValueKind($name)+'|'+$bytes.Length+"`n");[void]$sha.TransformBlock($head,0,$head.Length,$null,0)
                [void]$sha.TransformBlock($bytes,0,$bytes.Length,$null,0)
            }
        }
        [void]$sha.TransformFinalBlock([byte[]]@(),0,0)
        return [BitConverter]::ToString($sha.Hash).Replace('-','')
    } finally {$sha.Dispose()}
}
function Hash-Bytes([byte[]]$b){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash($b)).Replace('-','')}finally{$h.Dispose()}}
function Hash-Text([string]$s){Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($s))}
function Save-Json([string]$p,$v){[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
function Read-Json([string]$p){Get-Content -LiteralPath $p -Raw|ConvertFrom-Json}
function Record([string]$step){Save-Json $journal @{phase=$step;atUtc=[DateTime]::UtcNow.ToString('o');machine=$env:COMPUTERNAME}}
function Rows([string]$p){
 $base=Get-Item -LiteralPath $p -Force;$q=[Collections.Generic.Queue[object]]::new();$q.Enqueue($base);$rows=[Collections.Generic.List[object]]::new()
 while($q.Count){$i=$q.Dequeue();if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Recovery tree contains a reparse point'};$rows.Add([pscustomobject][ordered]@{relative=$i.FullName.Substring($base.FullName.Length);directory=[bool]$i.PSIsContainer;length=$(if($i.PSIsContainer){0}else{$i.Length});lastWriteUtc=$i.LastWriteTimeUtc.ToString('o');attributes=[int]$i.Attributes;sddl=(Get-Acl -LiteralPath $i.FullName -Audit).Sddl;sha256=$(if($i.PSIsContainer){''}else{(Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256).Hash})});if($i.PSIsContainer){foreach($c in @(Get-ChildItem -LiteralPath $i.FullName -Force)){$q.Enqueue($c)}}};@($rows|Sort-Object relative)
}
function Lines($r){@($r|ForEach-Object {$_.relative+'|'+$_.directory+'|'+$_.length+'|'+$_.lastWriteUtc+'|'+$_.attributes+'|'+$_.sddl+'|'+$_.sha256})}
function Same($a,$b,[string]$label){if(@(Compare-Object (Lines $a) (Lines $b)).Count){throw ('Recovery identity changed: '+$label)}}
function Assert-Capture([string]$name,[string]$path){$manifest=if($name -eq 'current-RooOptimizationSuite'){'post-fixture-legacy'}else{$name};$saved=Read-Json (Join-Path $frame ($manifest+'.source-manifest.json'));Same $saved @(Rows $path) $name}
function Assert-NoAppProcess {
 $p=@(Get-CimInstance Win32_Process|Where-Object {($_.ExecutablePath -and $_.ExecutablePath.StartsWith($app+'\',[StringComparison]::OrdinalIgnoreCase)) -or ([string]$_.CommandLine -match '(--timer-worker|--timer-autostart)' -and [string]$_.CommandLine -like ('*'+$local+'\RooOptimizationSuite*'))})
 if($p.Count){throw 'A matching installed product or timer process is running'}
}
function Task-Rows {
 $service=New-Object -ComObject Schedule.Service;$service.Connect();$result=@()
 try {foreach($t in @(Get-ScheduledTask|Where-Object {$_.TaskName -like 'RooIndustriesCS2_*' -or $_.TaskName -eq $timer})){$task=$service.GetFolder($t.TaskPath).GetTask($t.TaskName);try{$result+=@{name=$t.TaskPath+$t.TaskName;xmlSha256=(Hash-Text $task.Xml);sddl=$task.GetSecurityDescriptor(7)}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)}}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service)}
 $result
}
function Assert-Tasks([bool]$TimerPresent){
 $saved=Read-Json (Join-Path $frame 'tasks.json');$expected=@($saved|Where-Object {$TimerPresent -or $_.name -ne ('\'+$timer)});$actual=@(Task-Rows)
 $a=@($expected|ForEach-Object {$_.name+'|'+$_.xmlSha256+'|'+$_.sddl});$b=@($actual|ForEach-Object {$_.name+'|'+$_.xmlSha256+'|'+$_.sddl})
 if(@(Compare-Object $a $b).Count){throw 'A captured task definition changed'}
 if(@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*' -ErrorAction SilentlyContinue).Count){throw 'An unexpected governor task exists'}
}
function Assert-Original([string]$name,[string]$target){
 $manifest=Read-Json (Join-Path $frame 'original-backup.source-manifest.json');$prefix='\'+$name
 $source=@($manifest|Where-Object {$_.relative -ceq $prefix -or $_.relative.StartsWith($prefix+'\',[StringComparison]::Ordinal)}|ForEach-Object {[pscustomobject]@{relative=$_.relative.Substring($prefix.Length);directory=$_.directory;length=$_.length;lastWriteUtc=$_.lastWriteUtc;attributes=$_.attributes;sddl=$_.sddl;sha256=$_.sha256}})
 if($source.Count -eq 0){throw 'Original tree is absent from the sealed manifest'}
 Same $source @(Rows $target) $name
 $old=@(Get-Content -LiteralPath (Join-Path $backup ($name+'.fingerprint.txt')) -Encoding UTF8)
 $now=@($source|ForEach-Object {$_.relative+'|'+$(if($_.directory){'dir'}else{[string]$_.length})+'|'+$_.lastWriteUtc+'|'+[string][IO.FileAttributes][int]$_.attributes+'|'+$_.sddl}|Sort-Object)
 if(@(Compare-Object $old $now).Count){throw 'Historical source metadata changed'}
}
function Assert-Sealed([string]$path){
 $acl=Get-Acl -LiteralPath $path
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544') -or -not $acl.AreAccessRulesProtected -or @($rules|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ([int64]$_.FileSystemRights -band 0x500D0156) -ne 0}).Count -or @($rules|Where-Object {$_.IdentityReference.Value -eq 'S-1-3-4' -and $_.AccessControlType -eq 'Allow' -and ([int64]$_.FileSystemRights -band 0xFFEFFFFF) -eq [int64][Security.AccessControl.FileSystemRights]::ReadPermissions}).Count -ne 1){throw 'Preserved tree is not sealed'}
}
function Preserve-MovedTree([string]$manifestName,[string]$path,[bool]$seal){
 $expected=Read-Json (Join-Path $frame ($manifestName+'.source-manifest.json'));$actual=@(Rows $path)
 $by=@{};foreach($r in $expected){$by[$r.relative]=$r}
 if($actual.Count -ne @($expected).Count){throw 'Preserved tree item count changed'}
 foreach($a in $actual){
  $e=$by[$a.relative];if(-not $e){throw 'Preserved tree has an unknown item'}
  foreach($field in 'directory','length','lastWriteUtc','attributes','sha256'){if([string]$a.$field -cne [string]$e.$field){throw ('Preserved tree '+$field+' changed')}}
  $item=Join-Path $path $a.relative.TrimStart('\')
  if(-not $seal){Assert-Sealed $item;continue}
  if($a.sddl -cne $e.sddl){
   $converted=[Security.AccessControl.RawSecurityDescriptor]::new($e.sddl);$converted.SetFlags($converted.ControlFlags -bor [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)
   foreach($ace in $converted.DiscretionaryAcl){$ace.AceFlags=[Security.AccessControl.AceFlags]([int]$ace.AceFlags -band 239)}
   if($a.relative -cne '' -or $a.sddl -cne $converted.GetSddlForm([Security.AccessControl.AccessControlSections]::All)){Assert-Sealed $item}
  }
 }
 if(-not $seal){return}
 $before=Join-Path $frame ($manifestName+'.before-seal.json');if(-not(Test-Path -LiteralPath $before)){Save-Json $before $actual}
 foreach($a in $actual){
  $security=if($a.directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
  $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'));$security.SetAccessRuleProtection($true,$false)
  foreach($owner in 'S-1-5-18','S-1-5-32-544'){$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($owner),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))}
  $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-4'),[Security.AccessControl.FileSystemRights]::ReadPermissions,[Security.AccessControl.AccessControlType]::Allow))
  Set-Acl -LiteralPath (Join-Path $path $a.relative.TrimStart('\')) -AclObject $security
 }
 Preserve-MovedTree $manifestName $path $false
 Save-Json (Join-Path $frame ($manifestName+'.sealed-manifest.json')) @(Rows $path)
}
function Restore-OriginalAcl([string]$source,[string]$target){
 if(-not ('RooIndustriesHistoricalRecovery.Security' -as [type])){
  $temp=Join-Path $frame 'native-probe-temp';[IO.Directory]::CreateDirectory($temp)|Out-Null;$oldTemp=$env:TEMP;$oldTmp=$env:TMP
  try{$env:TEMP=$temp;$env:TMP=$temp;Add-Type -Namespace RooIndustriesHistoricalRecovery -Name Security -MemberDefinition '[System.Runtime.InteropServices.DllImport("advapi32.dll",EntryPoint="SetFileSecurityW",CharSet=System.Runtime.InteropServices.CharSet.Unicode,SetLastError=true)] public static extern bool Restore(string file,uint info,byte[] descriptor);'}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
 }
 $expected=@(Rows $source);$actual=@(Rows $target);$by=@{};foreach($r in $actual){$by[$r.relative]=$r}
 if($expected.Count -ne $actual.Count){throw 'Staged tree has an unexpected item count'}
 foreach($r in $expected){
  $a=$by[$r.relative];if(-not$a){throw 'Staged item is missing'}
  foreach($field in 'directory','length','lastWriteUtc','attributes','sha256'){if([string]$a.$field -cne [string]$r.$field){throw ('Staged '+$field+' changed')}}
  if($a.sddl -cne $r.sddl -and $a.sddl -cne $r.sddl.Replace('D:','D:AI')){throw 'Staged permissions changed beyond the known auto-inheritance flag'}
 }
 foreach($r in $expected){$from=Join-Path $source $r.relative.TrimStart('\');$to=Join-Path $target $r.relative.TrimStart('\');$acl=Get-Acl -LiteralPath $from -Audit;if(@($acl.GetAuditRules($true,$true,[Security.Principal.SecurityIdentifier])).Count){throw 'Original has an unexpected audit ACL'};if(-not[RooIndustriesHistoricalRecovery.Security]::Restore($to,7,$acl.GetSecurityDescriptorBinaryForm())){throw ('Could not restore original descriptor: '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}}
}
function Read-OriginalState {
 $txt=[IO.File]::ReadAllText((Join-Path $frame 'original-backup\tweak-state.reg'));$m=[regex]::Match($txt,'(?ms)^"State"=hex:(.*?)(?=\r?\n\r?\n|\z)');if(-not$m.Success){throw 'Saved State binary missing'}
 $b=[System.Runtime.Remoting.Metadata.W3cXsd2001.SoapHexBinary]::Parse([regex]::Replace($m.Groups[1].Value,'[,\\\s]','')).Value
 if((Hash-Bytes $b) -cne $oldStateHash){throw 'Original State bytes changed'}
 return ,$b
}
function Assert-Registry([string]$StateHash){$k=Get-Item -LiteralPath $registryState;if($k.GetValueKind('State') -ne 'Binary' -or (Hash-Bytes $k.GetValue('State')) -cne $StateHash -or $k.GetValueNames() -contains 'Pending'){throw 'Registry State changed or recovery is pending'}}
function Assert-BootMarker {
 $boot=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustriesOptimizationSuite\BootMarker' -ErrorAction SilentlyContinue
 if($boot -and (@($boot.GetValueNames()).Count -ne 1 -or @($boot.GetSubKeyNames()).Count -ne 0 -or $boot.GetValueKind('Id') -ne 'String' -or (Hash-Text ([string]$boot.GetValue('Id'))) -cne 'E0088E6ACA3CDCD2001EC3EB2A64AB02F220494F648486D3F1A14AA952B80549')){throw 'BootMarker changed'}
}
function Uninstall-Entries {@(foreach($base in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'){Get-ChildItem -LiteralPath $base|Where-Object {$_.PSChildName -eq '{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}_is1'}})}
if((Get-FileHash -LiteralPath (Join-Path $backup 'machine-state.json') -Algorithm SHA256).Hash -cne 'BE914AC3750C09734FE545DBB22C1346590E0DB0CD650B41B4FDC64E6653AF85'){throw 'Historical baseline identity changed'}
$capture=Read-Json (Join-Path $frame 'phase.json')
if($capture.phase -ne 'captured' -or $capture.machine -ne $env:COMPUTERNAME -or $capture.captures -ne 6){throw 'Protected capture is incomplete'}
$acl=Get-Acl -LiteralPath $frame
if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or -not$acl.AreAccessRulesProtected -or @(($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ([int64]$_.FileSystemRights -band 0x500D0156) -ne 0}).Count){throw 'Recovery frame is not protected'}
Assert-NoAppProcess
if($Phase -eq 'Finalize' -and (Read-Json $journal).phase -notin @('preserving-original-backup','sealing-preserved')){throw 'Recovery is not awaiting preserved-tree verification'}
if($Phase -eq 'Stage'){
 if((Test-Path -LiteralPath $journal) -and (Read-Json $journal).phase -ne 'staging-originals'){throw 'Recovery journal is not an unfinished staging operation'}
 Assert-Capture 'original-backup' $backup
 Assert-Capture 'installed-app' $app
 foreach($n in $names){Assert-Capture ('current-'+$n) (Join-Path $local $n)}
 Assert-Tasks $true
 Assert-Registry $liveStateHash
 [void](Read-OriginalState)
 $installer=Join-Path $local 'Temp\roo-industries-release\RooIndustries-OptimizationSuite-0.9.0-beta-setup.exe'
 if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -cne $installerHash){throw 'Rollback installer differs from the installed test build'}
 $rollback=Join-Path $frame 'rollback-setup.exe';if(-not(Test-Path -LiteralPath $rollback)){[IO.File]::Copy($installer,$rollback)}
 if((Get-FileHash -LiteralPath $rollback -Algorithm SHA256).Hash -cne $installerHash){throw 'Rollback installer copy differs'}
 Record 'staging-originals'
 foreach($n in $names){
  $source=Join-Path $backup $n;$target=$stages[$n]
  if(-not(Test-Path -LiteralPath $target)){
   $output=@(& (Join-Path $env:SystemRoot 'System32\robocopy.exe') $source $target /E /COPYALL /DCOPY:DAT /XJ /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>&1);$code=$LASTEXITCODE
   [IO.File]::WriteAllText((Join-Path $frame ($n+'.stage.log')),($output -join [Environment]::NewLine))
   if($code -ge 8){throw 'Original staging copy failed'}
   $from=Get-Item -LiteralPath $source -Force;$to=Get-Item -LiteralPath $target -Force;$to.Attributes=$from.Attributes;$to.LastWriteTimeUtc=$from.LastWriteTimeUtc
  }
  Restore-OriginalAcl $source $target
  Assert-Original $n $target
 }
 Assert-Capture 'original-backup' $backup
 Record 'staged'
 'PASS Original trees staged with verified bytes, historical metadata and ACLs; rollback installer preserved'
 exit 0
}
if($Phase -eq 'Restore'){
 if((Read-Json $journal).phase -ne 'staged'){throw 'Original trees are not at the staged recovery phase'}
 if((Get-FileHash -LiteralPath $migrationFixture -Algorithm SHA256).Hash -cne $migrationFixtureHash -or (Test-Path -LiteralPath (Join-Path $local 'Temp\RooIndustriesMigrationProbe.exe'))){throw 'Historical migration fixture changed'}
 Save-Json (Join-Path $frame 'migration-fixture-manifest.json') @{sha256=$migrationFixtureHash;sddl=(Get-Acl -LiteralPath $migrationFixture -Audit).Sddl}
 foreach($n in $names){Assert-Original $n $stages[$n];Assert-Capture ('current-'+$n) (Join-Path $local $n)}
 Assert-Capture 'original-backup' $backup;Assert-Capture 'installed-app' $app
 Assert-Capture 'current-RooIndustriesOptimizationSuite.Timer' (Join-Path $local 'RooIndustriesOptimizationSuite.Timer')
 $caps=Read-Json (Join-Path $frame 'captures.json');$archive=[string]@($caps|Where-Object name -eq 'migration-archive')[0].source
 Assert-Capture 'migration-archive' $archive
 $archiveFiles=@(Rows $archive|Where-Object {-not$_.directory});if($archiveFiles.Count -ne 6){throw 'Migration archive no longer has six original files'}
 foreach($row in $archiveFiles){if((Get-FileHash -LiteralPath (Join-Path (Join-Path $backup 'RooOptimizationSuite') $row.relative.TrimStart('\')) -Algorithm SHA256).Hash -cne $row.sha256){throw 'A preserved firmware file differs from its original'}}
 Assert-Tasks $true;Assert-Registry $liveStateHash
 Assert-BootMarker
 if((Get-FileHash -LiteralPath (Join-Path $frame 'rollback-setup.exe') -Algorithm SHA256).Hash -cne $installerHash){throw 'Rollback installer changed'}
 if((Get-FileHash -LiteralPath (Join-Path $app 'unins000.exe') -Algorithm SHA256).Hash -cne '484A5E4F7D642BF21EF86806409DEA8BA3526F50DAC57626D749FC2E7F6BBC74' -or (Get-FileHash -LiteralPath (Join-Path $app 'unins000.dat') -Algorithm SHA256).Hash -cne '225B85416ABE058B343533805386977FF8A04D4C9E46E4F0E4F252FCB9CE016F'){throw 'Installed uninstaller identity changed'}
 if((Uninstall-Entries).Count -ne 1){throw 'Expected exactly the audited test installation'}
 $markers=Get-Item -LiteralPath $markerPath;$markerNames=@(foreach($r in @((Join-Path $local 'RooOptimizationSuite'),(Join-Path $local 'RooOptimizationSuite\process-rules'),(Join-Path $local 'RooOptimizationSuite\operations'))){$r.ToUpperInvariant();$r.ToUpperInvariant()+'|protected-at'})
 if(@(Compare-Object $markerNames @($markers.GetValueNames())).Count){throw 'Governor markers changed'}
 $markerValues=@(foreach($n in $markerNames){@{name=$n;kind=[string]$markers.GetValueKind($n);value=$markers.GetValue($n)}})
 foreach($v in $markerValues){if($v.name.EndsWith('|protected-at')){if($v.kind -ne 'QWord' -or [DateTime]::FromFileTimeUtc([long]$v.value).ToString('yyyy-MM-dd') -ne '2026-10-01'){throw 'Marker timestamp is not from the test run'}}elseif($v.kind -ne 'String' -or $v.value -cne $sid){throw 'Marker owner changed'}}
 Save-Json (Join-Path $frame 'markers-to-restore.json') $markerValues
 Record 'removing-test-timer'
 Unregister-ScheduledTask -TaskName $timer -TaskPath '\' -Confirm:$false
 Assert-Tasks $false
 Record 'uninstalling-test-build'
 $u=Start-Process -FilePath (Join-Path $app 'unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="'+(Join-Path $frame 'uninstall.log')+'"')) -PassThru
 if(-not$u.WaitForExit(180000)){throw 'Test uninstaller did not finish; original data and rollback versions retained'}
 if($u.ExitCode -ne 0 -or (Uninstall-Entries).Count -ne 0 -or (Test-Path -LiteralPath (Join-Path $app 'app\RooIndustries.OptimizationSuite.App.dll')) -or (Test-Path -LiteralPath (Join-Path $app 'backend\bin\optimizer\Optimizer.Host.dll'))){throw 'Test uninstall did not complete'}
 Assert-NoAppProcess;Assert-Tasks $false;Assert-Registry $liveStateHash
 foreach($n in $names){
  $live=Join-Path $local $n;$old=Join-Path $frame ('as-found-'+$n);if(Test-Path -LiteralPath $old){throw 'Recovery quarantine already exists'}
  Assert-Capture ('current-'+$n) $live;Assert-Original $n $stages[$n]
  Record ('swapping-'+$n);[IO.Directory]::Move($live,$old)
  try{[IO.Directory]::Move($stages[$n],$live)}catch{if(-not(Test-Path -LiteralPath $live)){[IO.Directory]::Move($old,$live)};throw}
  Assert-Original $n $live
 }
 foreach($pair in @(@('current-RooIndustriesOptimizationSuite.Timer',(Join-Path $local 'RooIndustriesOptimizationSuite.Timer')),@('migration-archive',$archive))){$destination=Join-Path $frame ('as-found-'+$pair[0]);if(Test-Path -LiteralPath $destination){throw 'Recovery quarantine already exists'};Assert-Capture $pair[0] $pair[1];Record ('preserving-'+$pair[0]);[IO.Directory]::Move($pair[1],$destination)}
 if((Get-FileHash -LiteralPath $migrationFixture -Algorithm SHA256).Hash -cne $migrationFixtureHash){throw 'Historical migration fixture changed during recovery'}
 $migrationDestination=Join-Path $frame 'as-found-migration-state.json'
 Record 'preserving-migration-fixture'
 [IO.File]::Move($migrationFixture,$migrationDestination)
 $fileSecurity=[Security.AccessControl.FileSecurity]::new()
 $fileSecurity.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'));$fileSecurity.SetAccessRuleProtection($true,$false)
 foreach($owner in 'S-1-5-18','S-1-5-32-544'){$fileSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($owner),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))}
 $fileSecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-4'),[Security.AccessControl.FileSystemRights]::ReadPermissions,[Security.AccessControl.AccessControlType]::Allow))
 Set-Acl -LiteralPath $migrationDestination -AclObject $fileSecurity
 if((Get-FileHash -LiteralPath $migrationDestination -Algorithm SHA256).Hash -cne $migrationFixtureHash){throw 'Preserved migration fixture differs'}
 Assert-Registry $liveStateHash
 Record 'restoring-registry'
 $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($registryState.Substring(6),$true)
 try{$k.SetValue('State',(Read-OriginalState),[Microsoft.Win32.RegistryValueKind]::Binary)}finally{$k.Dispose()}
 Assert-Registry $oldStateHash
 $markers=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($markerPath.Substring(6),$true)
 try{
  foreach($v in $markerValues){if([string]$markers.GetValueKind($v.name) -cne $v.kind -or [string]$markers.GetValue($v.name) -cne [string]$v.value){throw 'A marker changed during recovery'}}
  foreach($v in $markerValues){$markers.DeleteValue($v.name)}
 }finally{$markers.Dispose()}
 Assert-BootMarker
 $boot=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustriesOptimizationSuite\BootMarker',$true)
 if($boot){
  try{$boot.DeleteValue('Id')}finally{$boot.Dispose()}
  $parent=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustriesOptimizationSuite',$true)
  try{$parent.DeleteSubKey('BootMarker')}finally{$parent.Dispose()}
 }
 Record 'restored-pending-verification'
}
foreach($n in $names){Assert-Original $n (Join-Path $local $n)}
Assert-Registry $oldStateHash;Assert-Tasks $false;Assert-NoAppProcess
if((Uninstall-Entries).Count -ne 0 -or (Test-Path -LiteralPath (Join-Path $app 'app\RooIndustries.OptimizationSuite.App.dll'))){throw 'Test installation remains'}
if(@((Get-Item -LiteralPath $markerPath).GetValueNames()).Count -ne 0){throw 'Test markers remain'}
if((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency).EnableTransparency -ne 0){throw 'Transparency differs from baseline'}
if(Test-Path -LiteralPath (Join-Path $local 'RooIndustriesOptimizationSuite.Timer')){throw 'Test timer state remains at the live path'}
if(Test-Path -LiteralPath $migrationFixture){throw 'Test migration state remains at the live path'}
if((Get-RegistryFingerprint 'HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustries') -cne '9576DB0FAF492CC39A455A9EF997B35B4D446B34668D0131E74E44B513E83B64'){throw 'Product registry tree differs from the original baseline'}
if((Get-RegistryFingerprint 'HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustriesOptimizationSuite') -cne 'B24BE4C4ED5FC5B5721A085D56C472FD538F54BE7C937743F60E90F4C5EC5089'){throw 'Tweak registry tree differs from the original baseline'}
if($backup -ne $archivedBackup){
 if($Phase -ne 'Restore'){throw 'Original backup remains live; Verify will not move it'}
 if(Test-Path -LiteralPath $archivedBackup){throw 'The original backup archive already exists'}
 Assert-Capture 'original-backup' $backup
 Record 'preserving-original-backup'
 [IO.Directory]::Move($backup,$archivedBackup);$backup=$archivedBackup
}
if($Phase -in 'Restore','Finalize'){Record 'sealing-preserved'}
foreach($pair in @(@('original-backup',$archivedBackup),@('post-fixture-legacy',(Join-Path $frame 'as-found-RooOptimizationSuite')),@('current-RooIndustriesOptimizationSuite',(Join-Path $frame 'as-found-RooIndustriesOptimizationSuite')),@('current-RooIndustriesOptimizationSuite.Timer',(Join-Path $frame 'as-found-current-RooIndustriesOptimizationSuite.Timer')),@('migration-archive',(Join-Path $frame 'as-found-migration-archive')))){Preserve-MovedTree $pair[0] $pair[1] ($Phase -in 'Restore','Finalize')}
if($Phase -in 'Restore','Finalize'){
 Record 'restored'
 Save-Json (Join-Path $frame 'restoration-result.json') @{restored=$true;machine=$env:COMPUTERNAME;originalTrees=$names;originalStateSha256=$oldStateHash;preservedTaskCount=6;rollbackInstallerSha256=$installerHash;allAsFoundTreesRetained=$true;historicalByteHashesAvailable=$false;historicalTaskXmlAvailable=$false;finishedUtc=[DateTime]::UtcNow.ToString('o')}
}
'PASS Historical trees, ACLs and State restored; test install, timer and marker values removed; six original tasks and every rollback copy preserved'
