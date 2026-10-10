param([Parameter(Mandatory=$true)][string]$Work)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$sid=$identity.User.Value
if($env:COMPUTERNAME -ine 'SERVI-WINDOWS-D' -or -not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Wrong machine or token'}
if((Get-CimInstance Win32_Processor).Name -notmatch '14600K' -or -not(@((Get-CimInstance Win32_VideoController).Name) -match 'RX 9070 XT')){throw 'Wrong hardware'}
if([IO.Path]::GetDirectoryName($Work) -ine (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp') -or (Get-Content -LiteralPath (Join-Path $Work 'fixture-owner.txt') -Raw) -cne 'setup-migration-f12'){throw 'Unowned work folder'}
$acl=Get-Acl -LiteralPath $Work
if(-not $acl.AreAccessRulesProtected -or @($acl.Access|Where-Object {$_.IdentityReference -notmatch 'SYSTEM|Administrators'}).Count){throw 'Work folder is not admin-only'}
$evidence=Join-Path $Work 'evidence'
foreach($name in @('evidence','setup-temp','hives','identities')){[IO.Directory]::CreateDirectory((Join-Path $Work $name))|Out-Null}
$env:TEMP=Join-Path $Work 'setup-temp';$env:TMP=$env:TEMP
$checks=New-Object System.Collections.Generic.List[object]
function Assert([bool]$Condition,[string]$Message){$checks.Add(@{passed=$Condition;message=$Message;utc=[DateTime]::UtcNow.ToString('o')});$checks|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $evidence 'checks.json') -Encoding UTF8;if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
function Save([string]$Name,$Value){ConvertTo-Json -InputObject $Value -Depth 40|Set-Content -LiteralPath (Join-Path $evidence ($Name+'.json')) -Encoding UTF8}
function HashText([string]$Value){$h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','')}finally{$h.Dispose()}}
function RegistrySnapshot {
    $rows=New-Object System.Collections.Generic.List[object]
    function Visit($Key,[string]$Path){
        if(-not $Key){return}
        foreach($name in @($Key.GetValueNames()|Sort-Object)){$value=$Key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$rows.Add(@{key=$Path;name=$name;kind=[string]$Key.GetValueKind($name);value=$value})}
        foreach($sub in @($Key.GetSubKeyNames()|Sort-Object)){$child=$Key.OpenSubKey($sub);try{Visit $child ($Path+'\'+$sub)}finally{$child.Dispose()}}
    }
    $machine=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries');try{Visit $machine 'HKLM\SOFTWARE\RooIndustries'}finally{if($machine){$machine.Dispose()}}
    foreach($path in @('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$sid))){$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path);try{Visit $key ('HKLM\'+$path)}finally{if($key){$key.Dispose()}}}
    foreach($path in @('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders','Environment','Volatile Environment')){$key=[Microsoft.Win32.Registry]::Users.OpenSubKey($sid+'\'+$path);try{Visit $key ('HKU\'+$sid+'\'+$path)}finally{if($key){$key.Dispose()}}}
    return @($rows.ToArray())
}
function TaskSnapshot {
    $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
    $rows=New-Object System.Collections.Generic.List[object]
    function VisitTasks($Folder){foreach($task in $Folder.GetTasks(1)){$rows.Add(@{path=$task.Path;xml=$task.Xml;sddl=$task.GetSecurityDescriptor(7)})};foreach($child in $Folder.GetFolders(0)){VisitTasks $child}}
    VisitTasks ($scheduler.GetFolder('\'))
    return @($rows.ToArray()|Sort-Object { $_.path })
}
function ProcessIdentity($Process){
    [void]$Process.Handle
    $created=$Process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {$native=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Process.Id);if($native -and $native.ExecutablePath){break};Start-Sleep -Milliseconds 50}while($clock.Elapsed.TotalSeconds -lt 2)
    if(-not $native -or -not $native.ExecutablePath){throw 'Process executable identity did not become available'}
    return @{processId=$Process.Id;created=$created;executable=[string]$native.ExecutablePath;commandLine=[string]$native.CommandLine;parentProcessId=$native.ParentProcessId}
}
function StopIdentity($Expected){$p=$null;try{$p=[Diagnostics.Process]::GetProcessById([int]$Expected.processId);[void]$p.Handle;if($p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -cne [string]$Expected.created -or $p.Path -ine [string]$Expected.executable){throw 'Cleanup identity mismatch'};$p.Kill();[void]$p.WaitForExit(10000)}catch [ArgumentException]{}finally{if($p){$p.Dispose()}}}
function WaitFor([scriptblock]$Check,[int]$Seconds){$clock=[Diagnostics.Stopwatch]::StartNew();do{if(& $Check){return $true};Start-Sleep -Milliseconds 100}while($clock.Elapsed.TotalSeconds -lt $Seconds);return $false}
$markersPath='SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots'
$suspendPath='SOFTWARE\RooIndustries\OptimizationSuite\SuspendedForMove'
$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($markersPath)
try{$existing=@(if($key){$key.GetValueNames()|Where-Object {$_ -notmatch '\|' -and (Split-Path $_ -Leaf) -in @('RooOptimizationSuite','RooIndustriesOptimizationSuite') -and $key.GetValue($_) -ceq $sid}});if($existing.Count){throw 'Existing same-SID protected roots prevent an isolated branded root'}}finally{if($key){$key.Dispose()}}
$beforeRegistry=RegistrySnapshot;$beforeTasks=TaskSnapshot
Save 'before-registry' $beforeRegistry;Save 'before-tasks' $beforeTasks
$repo=$Work
$taskName='';$probe=$null;$setup=$null;$createdTask=$false;$data='';$rules='';$markerValues=@{};$startupProcess=$null;$success=$false
try {
    $dotnet=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet\dotnet.exe'
    $iscc=Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData\Local\Programs\Inno Setup 6\ISCC.exe'
    Assert ((Test-Path -LiteralPath $dotnet) -and (Test-Path -LiteralPath $iscc)) 'Existing SDK and Inno compiler found'
    Save 'tool-identity' @{dotnet=$dotnet;dotnetVersion=(& $dotnet --version);iscc=$iscc;isccVersion=(Get-Item -LiteralPath $iscc).VersionInfo.FileVersion}
    $hostDirectory=Join-Path $repo 'backend\bin\optimizer'
    & $dotnet publish (Join-Path $repo 'tools\validation\SetupMigration\SetupMigration.Host.csproj') -c Debug -r win-x64 --self-contained true -p:GovernorTestHooks=true -o $hostDirectory *> (Join-Path $Work 'build-host.txt')
    Assert ($LASTEXITCODE -eq 0) 'Debug linked unmodified Host and Core built self-contained'
    $startupDirectory=Join-Path $Work 'startup'
    & $dotnet publish (Join-Path $repo 'tools\validation\SetupMigration\SetupMigration.Startup.csproj') -c Debug -r win-x64 --self-contained true -p:GovernorTestHooks=true -o $startupDirectory *> (Join-Path $Work 'build-startup.txt')
    Assert ($LASTEXITCODE -eq 0) 'Debug startup harness links the actual DataFolderGate'
    & $iscc /Q ('/DOutputDir='+$Work) (Join-Path $repo 'tools\release\SetupProcess.Test.iss') *> (Join-Path $Work 'build-inno.txt')
    Assert ($LASTEXITCODE -eq 0) 'Inno test compiles the actual RunBounded include'
    Add-Type -Path (Join-Path $repo 'tools\validation\SetupMigration\FixtureHive.cs') -OutputAssembly (Join-Path $Work 'FixtureHive.dll')
    Save 'binary-hashes' @(Get-ChildItem -LiteralPath $hostDirectory,$startupDirectory -File|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
    Copy-Item -LiteralPath (Join-Path $repo 'tools\validation\SetupMigration\Invoke-FixtureResume.ps1') -Destination $Work
    [Reflection.Assembly]::LoadFrom((Join-Path $Work 'FixtureHive.dll'))|Out-Null
    $local=[SetupMigrationHive]::TokenLocal()
    Save 'token-local' @{local=$local;workAcl=(Get-Acl -LiteralPath $Work).Sddl}
    $fixtureParent=Join-Path $local ('roo-industries-f12-'+[Guid]::NewGuid().ToString('N'))
    $fixtureLocal=Join-Path $fixtureParent 'Local';[IO.Directory]::CreateDirectory($fixtureLocal)|Out-Null
    $data=Join-Path $fixtureLocal 'RooOptimizationSuite';$rules=Join-Path $data 'process-rules'
    [IO.Directory]::CreateDirectory($data)|Out-Null
    $payload=@{'settings\keep.json'='{"f12":"original settings"}';'operations\keep.txt'='F12 original undo history';'transparency\keep.txt'='F12 fixture transparency'}
    foreach($name in $payload.Keys){$path=Join-Path $data $name;[IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllText($path,$payload[$name])}
    $probePath=Join-Path $Work 'F12MigrationProbe.exe'
    Add-Type -TypeDefinition 'public static class F12MigrationProbe { public static void Main() { System.Threading.Thread.Sleep(180000); } }' -OutputAssembly $probePath -OutputType ConsoleApplication
    $descriptor=@{work=$Work;local=$fixtureLocal;dataRoot=$data;repo=$repo;probe=$probePath}
    [IO.File]::WriteAllText((Join-Path $Work 'setup-migration-fixture.json'),($descriptor|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $Work 'setup-migration-fixture.json') -Destination $hostDirectory
    Save 'compiled-source-hashes' @(Get-ChildItem -LiteralPath (Join-Path $repo 'backend\native\Optimizer.Core') -Filter '*.cs' -File|ForEach-Object {@{path=$_.FullName;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
    Save 'entry-source-hashes' @((@('tools\release\SetupProcess.iss','tools\release\SetupProcess.Test.iss','backend\scripts\Invoke-GovernorSetup.ps1','backend\scripts\Invoke-ProcessPolicyWorker.ps1','backend\scripts\BrandCompatibility.Common.ps1','backend\native\Optimizer.Host\Program.cs','docs\internal\frontend\RooIndustries.OptimizationSuite.App\Services\DataFolderGate.cs')|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $repo $_)).Hash}}))
    [IO.File]::WriteAllText((Join-Path $Work 'diagnostic.flag'),'compiler')
    $diagnosticProcess=Start-Process -FilePath (Join-Path $Work 'SetupProcessCheck.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/migration=1',('/work="'+$Work+'"')) -PassThru
    Assert ($diagnosticProcess.WaitForExit(20000)) 'Actual RunBounded compiler diagnostic finishes'
    $diagnostics=[IO.File]::ReadAllText((Join-Path $Work 'diagnostic-addtype.json'))|ConvertFrom-Json
    Save 'compiler-diagnostic' $diagnostics;Save 'compiler-diagnostic-identity' ([IO.File]::ReadAllText((Join-Path $Work 'resume-wrapper-identity.json'))|ConvertFrom-Json);Save 'compiler-diagnostic-result' @{report=([IO.File]::ReadAllText((Join-Path $Work 'migration-report.txt')));compiler=(Get-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')).FullName}
    Assert ($diagnostics.Count -eq 2 -and @($diagnostics|Where-Object {-not $_.passed -or $_.pointerBits -ne 64 -or -not $_.cwdExists -or $_.cwd -ine [Environment]::SystemDirectory}).Count -eq 0) 'Native64 bounded child uses real System32 cwd and real compiler succeeds before and after private HKU'
    Remove-Item -LiteralPath (Join-Path $Work 'diagnostic.flag')
    Save 'fixture-binary-hashes' @((@('SetupProcessCheck.exe','FixtureHive.dll','F12MigrationProbe.exe','setup-migration-fixture.json')|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $Work $_)).Hash}}))
    $hostExe=Join-Path $hostDirectory 'Optimizer.Host.exe'
    & $hostExe --fixture-seed *> (Join-Path $Work 'seed.txt');Assert ($LASTEXITCODE -eq 0) 'Actual child rule root protected and pre-upgrade parent left unprotected'
    $dataMarker=$data.ToUpperInvariant();$rulesMarker=$rules.ToUpperInvariant()
    function Core([string]$Action){$request=@{schemaVersion=1;repoRoot=$repo;policyRoot=$rules;confirm=$true}|ConvertTo-Json -Compress;$text=@($request|& $hostExe $Action '-') -join "`n";$code=$LASTEXITCODE;$r=$text|ConvertFrom-Json;if($code -ne 0 -or $r.status -ne 'completed'){throw ($Action+': '+$text)};return $r.data}
    . (Join-Path $repo 'backend\scripts\BrandCompatibility.Common.ps1')
    $taskName='RooIndustriesOptimizationSuite.ProcessRules.'+(HashText ($sid+'|'+$rules.ToUpperInvariant())).Substring(0,20)
    Assert (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) 'Fixture task hash is unused'
    $action=New-RooIndustriesElevatedTaskAction $hostExe @('policy-run',(Join-Path $rules 'worker-request.json')) $hostDirectory
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $trigger=New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddHours(1))
    Register-ScheduledTask -TaskName $taskName -Description ('Roo Industries process rules | '+$sid+' | '+$rules) -Action $action -Principal $principal -Settings $settings -Trigger $trigger|Out-Null
    $createdTask=$true;Start-ScheduledTask -TaskName $taskName
    Assert (WaitFor {(Core 'policy-status').hostRunning -eq $true} 20) 'Valid enabled fixture governor task runs before upgrade'
    $pre=Core 'policy-status';Assert (@($pre.state.errors).Count -eq 0 -and (Core 'policy-summary').enabledRules -eq 1) 'Pre-upgrade governor reads exactly one valid enabled rule without errors';Save 'pre-upgrade-status' $pre;Save 'fixture-task-before' @(TaskSnapshot|Where-Object {$_.path -eq ('\'+$taskName)})
    $record=@{taskName=$taskName;taskPath='\';description=('Roo Industries process rules | '+$sid+' | '+$rules);userSid=$sid;policyRoot=$rules;enabled=$true;wasRunning=$true}
    [IO.File]::WriteAllText((Join-Path $Work 'setup-state.json'),(ConvertTo-Json -InputObject @($record)),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $Work 'pause.flag'),'copied')
    $setup=Start-Process -FilePath (Join-Path $Work 'SetupProcessCheck.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/migration=1',('/work="'+$Work+'"')) -PassThru
    $setupIdentity=ProcessIdentity $setup;Save 'setup-identity' $setupIdentity
    $observed=WaitFor {
        $stages=@(Get-ChildItem -LiteralPath $fixtureLocal -Directory|Where-Object {$_.Name -like 'RooOptimizationSuite.secure-*'})
        if($stages.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $stages[0].FullName '.migrating'))){return $false}
        foreach($name in $payload.Keys){if(-not (Test-Path -LiteralPath (Join-Path $stages[0].FullName $name))){return $false}}
        $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($suspendPath);try{$suspended=if($k){$k.GetValue($dataMarker)}else{$null}}finally{if($k){$k.Dispose()}}
        if(-not $suspended){return $false};$suspendedRecord=$suspended|ConvertFrom-Json
        if(@($suspendedRecord.tasks).Count -ne 1 -or $suspendedRecord.tasks[0] -cne ('\'+$taskName)){return $false}
        if((Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled'){return $false}
        $ownedLive=@(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'"|Where-Object {$_.ExecutablePath -ieq $hostExe})
        $copyWorkers=@($ownedLive|Where-Object {$_.CommandLine -match 'policy-run'})
        if($copyWorkers.Count -ne 0){return $false}
        $during=Core 'policy-status';if($during.hostRunning -ne $false){return $false}
        $live=@($ownedLive|Where-Object {$_.CommandLine -match 'policy-secure'})
        if($live.Count -ne 1){return $false}
        $liveProcess=[Diagnostics.Process]::GetProcessById($live[0].ProcessId)
        try{$script:pausedHost=ProcessIdentity $liveProcess}finally{$liveProcess.Dispose()}
        $script:interruption=@{stage=$stages[0].FullName;journal=(Get-Content -LiteralPath (Join-Path $stages[0].FullName '.migrating') -Raw|ConvertFrom-Json);suspended=$suspendedRecord;ownedWorkerCount=$copyWorkers.Count;statusDuringCopy=$during;taskState=[string](Get-ScheduledTask -TaskName $taskName).State;host=$script:pausedHost;sourceExists=(Test-Path -LiteralPath $data);payload=@($payload.Keys|Sort-Object|ForEach-Object {@{path=$_;originalHash=(Get-FileHash -LiteralPath (Join-Path $data $_)).Hash;stageHash=(Get-FileHash -LiteralPath (Join-Path $stages[0].FullName $_)).Hash}})}
        return $true
    } 10
    Assert $observed 'Resume reached actual policy-secure copied migration with source, journal and disabled recorded task'
    Save 'interruption' $interruption
    Assert (@($interruption.payload|Where-Object {$_.originalHash -cne $_.stageHash}).Count -eq 0) 'Actual copied stage preserves the exact original fixture payload'
    Assert ($setup.WaitForExit(15000)) 'Bounded setup returns within its test limit'
    Save 'setup-result' @{exit=$setup.ExitCode;report=([IO.File]::ReadAllText((Join-Path $Work 'migration-report.txt')))}
    Assert (([IO.File]::ReadAllText((Join-Path $Work 'migration-report.txt'))) -match 'migration ran=0 exit=258 ms=') 'Actual Inno RunBounded reports timed-out exit 258'
    $dead=WaitFor {$p=Get-Process -Id $pausedHost.processId -ErrorAction SilentlyContinue;if(-not $p){return $true};try{return $p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -cne $pausedHost.created}finally{$p.Dispose()}} 5
    Assert $dead 'The exact paused policy-secure child identity ended at timeout'
    $wrapper=Get-Content -LiteralPath (Join-Path $Work 'resume-wrapper-identity.json') -Raw|ConvertFrom-Json
    Assert ($pausedHost.parentProcessId -eq $wrapper.processId) 'Paused actual policy-secure is the native child of the observed Resume wrapper'
    Assert (-not (Get-Process -Id $wrapper.processId -ErrorAction SilentlyContinue)) 'The observed Resume wrapper ended at timeout'
    Assert ((Test-Path -LiteralPath $data) -and (Test-Path -LiteralPath (Join-Path $interruption.stage '.migrating'))) 'Original source and copied stage journal remain after timeout'
    Remove-Item -LiteralPath (Join-Path $Work 'pause.flag')
    $startupProcess=Start-Process -FilePath (Join-Path $startupDirectory 'SetupMigration.Startup.exe') -ArgumentList ('"'+$Work+'"') -RedirectStandardOutput (Join-Path $Work 'startup-output.txt') -RedirectStandardError (Join-Path $Work 'startup-error.txt') -PassThru
    $startupIdentity=ProcessIdentity $startupProcess;Save 'startup-identity' $startupIdentity
    if(-not $startupProcess.WaitForExit(60000)){StopIdentity $startupIdentity;throw 'Startup recovery exceeded60 seconds'}
    Assert ($startupProcess.ExitCode -eq 0) 'Linked actual startup DataFolderGate completes interrupted migration'
    $startup=(Get-Content -LiteralPath (Join-Path $Work 'startup-output.txt') -Raw)|ConvertFrom-Json
    Assert ($startup.opened -and $startup.secured -and -not $startup.deepProblem -and $startup.marker -and $startup.root -ieq $data) 'Fresh startup resolves and protects the same data root with a durable marker'
    foreach($name in $payload.Keys){Assert ((Get-FileHash -LiteralPath (Join-Path $data $name)).Hash -ceq @($interruption.payload|Where-Object {$_.path -ceq $name})[0].originalHash) ('Recovered exact payload '+$name)}
    Assert (WaitFor {(Core 'policy-status').hostRunning -eq $true -and (Get-ScheduledTask -TaskName $taskName).State -ne 'Disabled'} 20) 'Startup re-enables and resumes the fixture governor'
    $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($suspendPath);try{Assert (-not $k -or $null -eq $k.GetValue($dataMarker)) 'Successful resume consumes the exact SuspendedForMove record'}finally{if($k){$k.Dispose()}}
    $probe=Start-Process -FilePath $probePath -PassThru;$probeIdentity=ProcessIdentity $probe;Save 'probe-identity' $probeIdentity
    $initial=[string]$probe.PriorityClass;Assert ($initial -ceq 'Normal') 'Fresh post-recovery probe starts at Normal priority'
    Assert (WaitFor {$probe.Refresh();[string]$probe.PriorityClass -ceq 'AboveNormal'} 15) 'Recovered governor enforces configured AboveNormal priority on fresh probe'
    $workers=@(Get-CimInstance Win32_Process -Filter "Name='Optimizer.Host.exe'"|Where-Object {$_.ExecutablePath -ieq $hostExe -and $_.CommandLine -match 'policy-run'})
    Assert ($workers.Count -eq 1) 'Recovery leaves exactly one owned governor worker'
    Save 'recovered' @{startup=$startup;status=(Core 'policy-status');probeInitial=$initial;probeFinal=[string]$probe.PriorityClass;workers=$workers|Select-Object ProcessId,CreationDate,ExecutablePath,CommandLine;acl=(Get-Acl -LiteralPath $data).Sddl}
    Save 'fixture-task-after' @(TaskSnapshot|Where-Object {$_.path -eq ('\'+$taskName)})
    $success=$true
} catch {Save 'failure' @{message=$_.Exception.Message;stack=$_.ScriptStackTrace};throw}
finally {
    $cleanupErrors=New-Object System.Collections.Generic.List[string]
    try {
        if($startupProcess -and -not $startupProcess.HasExited){StopIdentity $startupIdentity}
        if($setup -and -not $setup.HasExited -and -not $setup.WaitForExit(30000)){throw 'Bounded setup did not end; retained fixture for owner'}
        if($createdTask){Disable-ScheduledTask -TaskName $taskName|Out-Null;try {Core 'policy-stop'|Out-Null;[void](WaitFor {(Core 'policy-status').hostRunning -ne $true} 10)}catch{}}
        if($probe){StopIdentity $probeIdentity;$probe.Dispose()}
        if($data){
            $hostPath=Join-Path $Work 'backend\bin\optimizer\Optimizer.Host.exe'
            foreach($p in @(Get-Process -Name 'Optimizer.Host' -ErrorAction SilentlyContinue)){try{if($p.Path -ieq $hostPath){$owned=ProcessIdentity $p;StopIdentity $owned}}finally{$p.Dispose()}}
            foreach($path in @($data,$rules)){
                $marker=$path.ToUpperInvariant();$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($markersPath,$true)
                try{if($key -and $null -ne $key.GetValue($marker)){if($key.GetValue($marker) -cne $sid){throw 'Marker owner changed; retained'};$key.DeleteValue($marker,$false);$key.DeleteValue($marker+'|protected-at',$false)}}finally{if($key){$key.Dispose()}}
            }
            $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($suspendPath,$true)
            try{if($key -and $null -ne $key.GetValue($data.ToUpperInvariant())){$record=$key.GetValue($data.ToUpperInvariant())|ConvertFrom-Json;if(@($record.tasks).Count -ne 1 -or $record.tasks[0] -cne ('\'+$taskName)){throw 'Suspended record ownership changed; retained'};$key.DeleteValue($data.ToUpperInvariant(),$false)}}finally{if($key){$key.Dispose()}}
        }
        if($createdTask){$t=Get-ScheduledTask -TaskName $taskName;if($t.Description -cne ('Roo Industries process rules | '+$sid+' | '+$rules) -or @($t.Actions).Count -ne 1 -or $t.Actions[0].Execute -ine $action.Execute -or $t.Actions[0].Arguments -cne $action.Arguments){throw 'Task ownership changed; retained'};Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    }catch{$cleanupErrors.Add($_.Exception.Message)}
    $afterRegistry=RegistrySnapshot;$afterTasks=TaskSnapshot
    Save 'after-registry' $afterRegistry;Save 'after-tasks' $afterTasks
    Save 'isolation' @{registryBeforeHash=(HashText (ConvertTo-Json -InputObject $beforeRegistry -Depth 40 -Compress));registryAfterHash=(HashText (ConvertTo-Json -InputObject $afterRegistry -Depth 40 -Compress));taskBeforeHash=(HashText (ConvertTo-Json -InputObject $beforeTasks -Depth 40 -Compress));taskAfterHash=(HashText (ConvertTo-Json -InputObject $afterTasks -Depth 40 -Compress));cleanupErrors=@($cleanupErrors.ToArray());retainedData=$data;work=$Work}
    Assert ($cleanupErrors.Count -eq 0) 'Exact owned cleanup completes without touching unrelated values'
    Assert ((ConvertTo-Json -InputObject $beforeRegistry -Depth 40 -Compress) -ceq (ConvertTo-Json -InputObject $afterRegistry -Depth 40 -Compress)) 'Unrelated HKLM and real HKU folders/environment are unchanged'
    Assert ((ConvertTo-Json -InputObject $beforeTasks -Depth 40 -Compress) -ceq (ConvertTo-Json -InputObject $afterTasks -Depth 40 -Compress)) 'All original task XML and SDDL are unchanged'
    Save 'result' @{passed=$success;checks=@($checks.ToArray());work=$Work;retainedData=$data}
}
