param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutDir,[Parameter(Mandatory)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong handoff proof machine'}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\LoadTimesHandoff.Common.ps1')
Assert-HandoffProtected (Split-Path $OutDir -Parent)
if(Test-Path -LiteralPath $OutDir){throw 'Existing handoff proof retained'}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$checks=[Collections.Generic.List[object]]::new();$owned=$null;$task=$null;$foreign=$null;$ledgerCopy=$null;$workerFile=$null
function Check([bool]$Ok,[string]$Name){$checks.Add(@{passed=$Ok;check=$Name});if(-not$Ok){throw $Name};'PASS '+$Name}
function Refuses([scriptblock]$Body,[string]$Name){$refused=$false;try{& $Body|Out-Null}catch{$refused=$true};Check $refused $Name}
function New-PrivateProcessLedger($Identity,[string]$Name){
 $case=Join-Path $OutDir $Name;[IO.Directory]::CreateDirectory($case)|Out-Null
 $caseEpoch=Join-Path $case 'epoch-installed';$caseScenarios=Join-Path $case 'scenarios';[IO.Directory]::CreateDirectory($caseEpoch)|Out-Null;[IO.Directory]::CreateDirectory($caseScenarios)|Out-Null
 $caseLease=Join-Path $caseEpoch 'lease.json';Save-HandoffJson $caseLease @{label='installed';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;startUtc=[DateTime]::UtcNow.ToString('o');baselineHash=('A'*64)} -Create
 $caseContext=New-HandoffContext $caseScenarios $caseLease;Initialize-HandoffLedger $caseContext
 $caseProducer=Join-Path $caseScenarios 'migration-timer-on';[IO.Directory]::CreateDirectory($caseProducer)|Out-Null
 $caseResources=Join-Path $case 'fixture-resources.json';Save-HandoffJson $caseResources @{scenario='migration-timer-on';tasks=@();processes=@($Identity)} -Create
 $caseRequest=New-HandoffProducerRequest $caseContext 'migration-timer-on' $caseProducer $fixture @{OutDir=$caseProducer;ResourcePath=$caseResources} $task
 $casePsi=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $Source 'tools\validation\LoadTimes\Invoke-LoadTimesProducer.ps1')+'" -RequestPath "'+$caseRequest+'" -Minutes 2'));$casePsi.UseShellExecute=$false;$casePsi.CreateNoWindow=$true
 $caseWrapper=[Diagnostics.Process]::Start($casePsi);$caseWrapperReceipt=New-OwnedProcess $caseWrapper
 try{if(-not$caseWrapper.WaitForExit(180000)){Stop-OwnedProcess $caseWrapperReceipt;throw 'Own private process producer timeout'};if($caseWrapper.ExitCode -ne 0){throw 'Native private process producer failed'}}finally{$caseWrapper.Dispose()}
 $caseCompleted=Get-HandoffProducer $caseContext 'migration-timer-on'
 $caseLedger=[ordered]@{protocol='roo-loadtimes-ledger/v1';leaseHash=$caseContext.leaseHash;entries=@([ordered]@{producer='migration-timer-on';childReceiptHash=$caseCompleted.receiptHash;kind='process';index=0;resource=$caseCompleted.resources.processes[0]})}
 Save-HandoffJson $caseContext.ledgerPath $caseLedger
 Initialize-HandoffLedger $caseContext
 $caseContext
}
try{
 $epoch=Join-Path $OutDir 'epoch-installed';$scenarios=Join-Path $OutDir 'scenarios';[IO.Directory]::CreateDirectory($epoch)|Out-Null;[IO.Directory]::CreateDirectory($scenarios)|Out-Null
 $lease=Join-Path $epoch 'lease.json';@{label='installed';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;startUtc=[DateTime]::UtcNow.ToString('o');baselineHash=('A'*64)}|ConvertTo-Json|Set-Content -LiteralPath $lease
 $context=New-HandoffContext $scenarios $lease;Initialize-HandoffLedger $context
 $workerFile=Copy-OwnedProbe (Join-Path ([Environment]::SystemDirectory) 'PING.EXE') (Join-Path $OutDir 'Optimizer.Host.exe')
 $p=[Diagnostics.Process]::Start($workerFile.Identity.path,'-n 300 127.0.0.1');$owned=New-OwnedProcess $p
 $task=Register-OwnedProbeTask ('RooIndustries.Timer.proof-'+[Guid]::NewGuid().ToString('N')) (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') '/d /c exit 0' $OutDir ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 5
 $producer=Join-Path $scenarios 'migration-timer-on';[IO.Directory]::CreateDirectory($producer)|Out-Null
 $resources=Join-Path $OutDir 'fixture-resources.json';@{scenario='migration-timer-on';tasks=@($task);processes=@($owned.Identity)}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $resources
 $fixture=Join-Path $OutDir 'fixture-producer.ps1'
 @'
param([string]$OutDir,[string]$ResourcePath)
Copy-Item -LiteralPath $ResourcePath -Destination (Join-Path $OutDir 'persistent-resources.json')
'00:00:00Z PASS private timer producer'|Set-Content (Join-Path $OutDir 'migration-timer-on.log')
'00:00:01Z RESULT failures=0'|Add-Content (Join-Path $OutDir 'migration-timer-on.log')
'x'|Set-Content (Join-Path $OutDir 'migration-timer-on.done')
'@|Set-Content -LiteralPath $fixture
 $request=New-HandoffProducerRequest $context 'migration-timer-on' $producer $fixture @{OutDir=$producer;ResourcePath=$resources} $task
 $psi=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $Source 'tools\validation\LoadTimes\Invoke-LoadTimesProducer.ps1')+'" -RequestPath "'+$request+'" -Minutes 2'));$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
 $wrapper=[Diagnostics.Process]::Start($psi);$wrapperReceipt=New-OwnedProcess $wrapper
 try{if(-not$wrapper.WaitForExit(180000)){Stop-OwnedProcess $wrapperReceipt;throw 'Own producer wrapper timeout'};if($wrapper.ExitCode -ne 0){throw 'Native producer wrapper failed'}}finally{$wrapper.Dispose()}
 Add-HandoffProducer $context 'migration-timer-on' $producer
 $ledger=Read-HandoffLedger $context
 Check (Test-HandoffProcess $ledger $p) 'next scenario accepts timer-on worker with exact live native identity'
 Check (Test-HandoffTask $ledger $task.name $task.path) 'next scenario accepts exact timer task XML/security/action'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source 'tools\validation\LoadTimes\Invoke-LoadTimes.ps1'),[ref]$tokens,[ref]$errors)
 $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Report-UnownedLoadTimesResources'},$true)
 if($errors -or -not$function){throw 'Actual consumer function missing or malformed'};Invoke-Expression $function.Extent.Text
 $script:HandoffContext=$context;$script:ChildCompleted=$false;$script:PersistentResources=$null;$Scenario='permissions';$appDir=$OutDir;$probeDirectory=$OutDir;$ifeoProbe='HKLM:\SOFTWARE\RooIndustriesHandoffAbsent-'+[Guid]::NewGuid().ToString('N');$ruleTasksBefore=@();$sessionTasksBefore=@()
 $report=@(Report-UnownedLoadTimesResources);$report|Set-Content -LiteralPath (Join-Path $OutDir 'consumer-before.txt')
 Check (@(Get-Process Optimizer.Host -ErrorAction Stop|Where-Object Id -EQ $p.Id).Count -eq 1) 'private installed-image worker is present in the actual consumer process enumeration'
 Check (@($report|Where-Object {$_ -like ('*retained installed process '+$p.Id+' *') -or $_ -like ('*retained task '+$task.path+$task.name+' *')}).Count -eq 0) 'actual next-scenario consumer accepts completed producer worker and task'
 $foreign=Register-OwnedProbeTask ('RooIndustries.Timer.foreign-'+[Guid]::NewGuid().ToString('N')) (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') '/d /c exit 0' $OutDir ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 5
 Refuses {Test-HandoffTask $ledger $foreign.name $foreign.path -Require} 'foreign timer task refused'
 Check ([bool](@(Report-UnownedLoadTimesResources)|Where-Object {$_ -like ('*CLEANUP NEEDED*'+$foreign.name+'*')})) 'actual consumer names foreign timer task and refuses it'
 Remove-OwnedTask $foreign;$foreign=$null
 $bad=$owned.Identity|ConvertTo-Json|ConvertFrom-Json;$bad.creationTimeFileTimeUtc=([long]$bad.creationTimeFileTimeUtc-1).ToString()
 Check ((Get-HandoffResourceState 'process' $bad) -ceq 'gone') 'live reused PID with different creation means recorded process is gone'
 $reuseContext=New-PrivateProcessLedger $bad 'reused-pid';$reuseLedger=Read-HandoffLedger $reuseContext -Prune
 Check (@($reuseLedger.entries).Count -eq 0 -and @((Read-HandoffJson $reuseContext.ledgerPath).value.entries).Count -eq 0) 'different-creation process row is pruned from the retained ledger'
 Check (-not(Test-HandoffProcess $reuseLedger $p) -and (Get-HandoffResourceState 'process' $owned.Identity) -ceq 'live') 'reused PID is neither adopted nor stopped'
 $imageChanged=$owned.Identity|ConvertTo-Json|ConvertFrom-Json;$imageChanged.imagePath=[RooIndustriesValidationOwnership.Native]::Canonical((Join-Path $PSHOME 'powershell.exe'))
 Refuses {Get-HandoffResourceState 'process' $imageChanged} 'same-creation process with different image is refused'
 $imageContext=New-PrivateProcessLedger $imageChanged 'changed-image'
 Refuses {Read-HandoffLedger $imageContext -Prune} 'same-creation different-image ledger row is refused at the boundary'
 Check ((Get-HandoffResourceState 'process' $owned.Identity) -ceq 'live' -and (Test-HandoffProcess (Read-HandoffLedger $context -Prune) $p)) 'unchanged PID creation and image remain live and owned'
 $ledgerCopy=[IO.File]::ReadAllBytes($context.ledgerPath);$tampered=$ledger|ConvertTo-Json -Depth 30|ConvertFrom-Json;$tampered.entries[0].childReceiptHash='0'*64;$tampered|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $context.ledgerPath
 Refuses {Read-HandoffLedger $context} 'tampered ledger refused'
 '{broken'|Set-Content -LiteralPath $context.ledgerPath
 Refuses {Read-HandoffLedger $context} 'malformed ledger refused'
 [IO.File]::WriteAllBytes($context.ledgerPath,$ledgerCopy)
 $completed=Join-Path $producer 'completed-child.json';$renamed=Rename-OwnedFile $completed ($completed+'.held')
 try{Refuses {Read-HandoffLedger $context} 'missing producer completed receipt refused'}finally{Restore-OwnedFile $renamed}
 $folder=Get-OwnedTaskFolder $task.path;$liveTask=$folder.GetTask($task.name);$definition=$liveTask.Definition;$definition.Actions.Item(1).Arguments='/d /c exit 1'
 $null=$folder.RegisterTaskDefinition($task.name,$definition,6,[Security.Principal.WindowsIdentity]::GetCurrent().User.Value,$null,3,$task.sddl)
 $task=Get-OwnedTaskReceipt $task.name $task.path
 Initialize-HandoffLedger $context
 Check $true 'legitimate task transition does not block scenario initialization'
 Refuses {Read-HandoffLedger $context} 'changed task remains refused at resource acceptance boundary'
 Remove-OwnedTask $task;$task=$null
 $afterTransition=Read-HandoffLedger $context -Prune
 Check (@($afterTransition.entries|Where-Object kind -CEQ 'task').Count -eq 0 -and (Test-HandoffProcess $afterTransition $p)) 'removed transitioned task is pruned while unchanged worker remains owned'
 Stop-OwnedProcess $owned
 $pruned=Read-HandoffLedger $context -Prune
 Check (@($pruned.entries).Count -eq 0) 'gone resources dropped from ledger'
 Check (-not(Test-HandoffProcess $pruned $p)) 'gone worker is not adopted'
}catch{$checks.Add(@{passed=$false;check=$_.Exception.Message});'FAIL '+($_|Out-String)}
finally{
 foreach($r in @($task,$foreign)){if($r){try{Remove-OwnedTask $r}catch{$checks.Add(@{passed=$false;check='Private task cleanup: '+$_.Exception.Message})}}}
 if($owned){try{Stop-OwnedProcess $owned;$owned.process.Dispose()}catch{$checks.Add(@{passed=$false;check='Private process cleanup: '+$_.Exception.Message})}}
 if($workerFile){$workerFile.Dispose()}
 $result=@{phase='loadtimes-handoff-private';machine=$env:COMPUTERNAME;passed=($checks.Count -ge 20 -and @($checks|Where-Object {-not$_.passed}).Count -eq 0);checks=$checks.ToArray()}
 $result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $OutDir 'result.json')
}
if(-not$result.passed){exit 1}
