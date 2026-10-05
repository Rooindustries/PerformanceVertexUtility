param(
 [Parameter(Mandatory=$true)][string]$Script,
 [Parameter(Mandatory=$true)][string]$OutDir,
 [ValidateSet('All','StaleLeftover','StaleOtherUser','MatchingLeftover','Arguments')][string]$Scenario='All'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$work=Join-Path $OutDir ('fixture-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Script,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The setup script does not parse'}
$functions=@('Get-GovernorArguments','Get-Workers','Stop-Leftovers','Test-Alive','Stop-Governor','Stop-GovernorIdentity')
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object {$_.Name -in $functions}){
 Invoke-Expression $function.Extent.Text
}
$nativeWorkers=(Get-Command Get-Workers).ScriptBlock
$nativeAlive=(Get-Command Test-Alive).ScriptBlock
$AppRoot=Join-Path $work 'app'
$hostExe=Join-Path $AppRoot 'backend\bin\optimizer\Optimizer.Host.exe'
$me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$results=[Collections.Generic.List[object]]::new()
function Write-Log([string]$Text){Add-Content -LiteralPath (Join-Path $OutDir 'identity.log') -Value $Text}
function Check([bool]$Passed,[string]$Name){$results.Add([pscustomobject]@{check=$Name;passed=$Passed});Write-Output ($(if($Passed){'PASS '}else{'FAIL '})+$Name)}
function Invoke-Host {return [pscustomobject]@{secured=$true}}
function Probe {
 Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'PING.EXE') -ArgumentList '-n','400','127.0.0.1' -WindowStyle Hidden -PassThru
}
function Stop-Probe($Process){if(-not$Process.HasExited){$Process.Kill();$Process.WaitForExit()};$Process.Dispose()}
try {
 foreach($case in 'StaleLeftover','MatchingLeftover'){
  if($Scenario -notin @('All',$case)){continue}
  $probe=Probe
  $previousHost=$hostExe
  try {
   $created=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$probe.Id)).CreationDate
   if($case -eq 'StaleLeftover'){$created=$created.AddTicks(-10)}
   $script:WorkerRow=[pscustomobject]@{ProcessId=$probe.Id;CreationDate=$created;ExecutablePath=$probe.Path;CommandLine='fixture policy-run'}
   $script:WorkerReads=0
   $script:SnapshotProbeId=$probe.Id
   $hostExe=$probe.Path
   function Get-Process {[CmdletBinding()]param([string]$Name) if($Name -ne 'Optimizer.Host'){throw 'Unexpected fixture process query'};[Diagnostics.Process]::GetProcessById($script:SnapshotProbeId)}
   function Get-Workers {$script:WorkersKnown=$true;if($script:WorkerReads++ -eq 0){$script:WorkerRow}}
   Stop-Leftovers @()
   Start-Sleep -Milliseconds 100
   Check ($probe.HasExited -eq ($case -eq 'MatchingLeftover')) ($case+': creation identity controls the final process stop')
  } finally {Remove-Item Function:Get-Process -ErrorAction SilentlyContinue;$hostExe=$previousHost;Stop-Probe $probe}
 }
 if($Scenario -in @('All','StaleOtherUser')){
  $probe=Probe
  try {
   $root=Join-Path $work 'other-user-rules';[IO.Directory]::CreateDirectory($root)|Out-Null
   $state=@{owner=@{machine=$env:COMPUTERNAME;userSid='S-1-5-18'};host=@{processId=$probe.Id;creationTimeFileTimeUtc=$probe.StartTime.ToUniversalTime().AddTicks(-1).ToFileTimeUtc().ToString()}}
   $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'host.json') -Encoding UTF8
   $script:AliveReads=0
   function Test-Alive {$script:AliveReads++;return $script:AliveReads -ne 2}
   try{Stop-Governor ([pscustomobject]@{userSid='S-1-5-18';policyRoot=$root;taskName='unused';taskPath='\'})|Out-Null}
   catch{if($_.Exception.Message -ne 'The governor did not stop and its process identity could not be confirmed for termination.'){throw};Write-Log $_.Exception.Message}
   Start-Sleep -Milliseconds 100
   Check (-not$probe.HasExited -and $script:AliveReads -ge 3) 'StaleOtherUser: a PID reused after the liveness checks survives the final stop'
  } finally {Stop-Probe $probe}
 }
 if($Scenario -in @('All','Arguments')){
  Set-Item Function:Get-Workers $nativeWorkers
  $request=Join-Path $OutDir 'rules\worker-request.json'
  $script:Rows=@(
   [pscustomobject]@{ProcessId=101;ExecutablePath=$hostExe;CommandLine=('"'+$hostExe+'" policy-run "'+$request+'"')},
   [pscustomobject]@{ProcessId=102;ExecutablePath=$hostExe;CommandLine=('"'+$hostExe+'" not-policy-run "'+$request+'"')},
   [pscustomobject]@{ProcessId=103;ExecutablePath=$hostExe;CommandLine=('"'+$hostExe+'" policy-status "'+$request+'-policy-run"')},
   [pscustomobject]@{ProcessId=104;ExecutablePath=$hostExe;CommandLine=('"'+$hostExe+'" policy-run "'+$request+'" extra')},
   [pscustomobject]@{ProcessId=105;ExecutablePath=($hostExe+'-other');CommandLine=('"'+$hostExe+'-other" policy-run "'+$request+'"')}
  )
  function Get-CimInstance {return $script:Rows}
  $selected=@(Get-Workers)
  Check ($script:WorkersKnown -and $selected.Count -eq 1 -and $selected[0].ProcessId -eq 101) 'Arguments: only the exact executable and complete policy-run command select a leftover worker'
 }
} finally {
 Set-Item Function:Get-Workers $nativeWorkers
 Set-Item Function:Test-Alive $nativeAlive
 $results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutDir 'checks.json') -Encoding UTF8
}
if($results.Count -eq 0 -or @($results|Where-Object {-not$_.passed}).Count){exit 1}
