param([Parameter(Mandatory=$true)][string]$Runner,[Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$ExpectedMachine,[switch]$Before)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne $ExpectedMachine -or $Frame -cnotmatch '^C:\\RooBuild\\task-discovery-[a-f0-9]{32}$'){throw 'Fixture scope differs'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner parse failed'}
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$backup=$Frame;$local=$Frame;$app=Join-Path $Frame 'absent-app';$baseline=@{tasks=@()}
$scope=@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
$all=@(Get-ScheduledTask -ErrorAction Stop);$nested=@($all|Where-Object {$_.TaskPath -cne '\'})
if($nested.Count -eq 0){throw 'The actual nested-folder input is absent'}
$sample=$nested|Select-Object -First 1
$service=New-Object -ComObject Schedule.Service;$service.Connect()
$folder=$service.GetFolder($sample.TaskPath.TrimEnd([char]'\'));$task=$folder.GetTask($sample.TaskName)
$xml=[string]$task.Xml;$sddl=[string]$task.GetSecurityDescriptor(7)
$failed=$null;$found=@()
try{$found=@(Get-RecoveryTasks $scope)}catch{$failed=$_}
$after=$folder.GetTask($sample.TaskName)
$unchanged=$xml -ceq [string]$after.Xml -and $sddl -ceq [string]$after.GetSecurityDescriptor(7)
$passed=$unchanged -and $(if($Before){$failed -and $failed.Exception.HResult -eq -2147024773}else{-not$failed -and $found.Count -eq 0})
$result=[ordered]@{passed=[bool]$passed;before=[bool]$Before;machine=$env:COMPUTERNAME;sid=$scope.sid;nativeTaskCount=$all.Count;nativeNestedCount=$nested.Count;nestedSample=($sample.TaskPath+$sample.TaskName);sampleXmlSha256='';foreignTaskUnchanged=$unchanged;ownedTasks=$found.Count;failure=$(if($failed){$failed.Exception.Message}else{''});hresult=$(if($failed){$failed.Exception.HResult}else{0});runnerSha256=(Get-FileHash -LiteralPath $Runner).Hash;testSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash}
$sha=[Security.Cryptography.SHA256]::Create();try{$result.sampleXmlSha256=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($xml)))).Replace('-','')}finally{$sha.Dispose()}
$result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Frame 'proof.json') -Encoding UTF8
foreach($com in @($after,$task,$folder,$service)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com)}
$result|ConvertTo-Json -Depth 5
if(-not$passed){throw 'Task discovery contract failed'}
if($Before){'PASS reproduced native trailing-folder refusal'}else{'PASS native task discovery preserves unrelated nested tasks'}
