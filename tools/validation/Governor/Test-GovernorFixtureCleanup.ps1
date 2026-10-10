param([Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir -Force|Out-Null
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Script,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture source does not parse'}
$stop=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'leftover'},$true))
$children=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.DoWhileStatementAst] -and $node.Extent.Text.Contains('$children') -and $node.Extent.Text.Contains('$owned')},$true))
if($stop.Count -ne 1 -or $children.Count -ne 1){throw 'Fixture cleanup entry points were not uniquely found'}
foreach($node in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-FixtureRow'},$true)){. ([scriptblock]::Create($node.Extent.Text))}
$rows=@();$ping=Join-Path $env:SystemRoot 'System32\ping.exe'
foreach($stale in @($true,$false)){
 $process=Start-Process -FilePath $ping -ArgumentList @('-n','900','127.0.0.1') -WindowStyle Hidden -PassThru
 try{
  $null=$process.Handle
  $leftover=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
  if($stale){$leftover=[pscustomobject]@{ProcessId=$leftover.ProcessId;CreationDate=$leftover.CreationDate.AddSeconds(-1);ExecutablePath=$leftover.ExecutablePath;CommandLine=$leftover.CommandLine}}
  & ([scriptblock]::Create($stop[0].Body.Extent.Text.TrimStart('{').TrimEnd('}')))
  if($stale){Start-Sleep -Milliseconds 300}else{[void]$process.WaitForExit(5000)}
  $process.Refresh();$rows+=@{case=$(if($stale){'stale-identity'}else{'matching-identity'});passed=($process.HasExited -ne $stale)}
 }finally{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}
}
$older=Start-Process -FilePath $ping -ArgumentList @('-n','900','127.0.0.1') -WindowStyle Hidden -PassThru
$parent=$null
try{
 $null=$older.Handle;Start-Sleep -Milliseconds 30
 $parent=Start-Process -FilePath $ping -ArgumentList @('-n','900','127.0.0.1') -WindowStyle Hidden -PassThru;$null=$parent.Handle
 $processes=@([pscustomobject]@{ProcessId=$parent.Id;ParentProcessId=$PID;CreationDate=$parent.StartTime},[pscustomobject]@{ProcessId=$older.Id;ParentProcessId=$parent.Id;CreationDate=$older.StartTime})
 $owned=@($parent.Id)
 . ([scriptblock]::Create($children[0].Extent.Text))
 $rows+=@{case='older-child-with-reused-parent-pid';passed=($owned -notcontains $older.Id)}
}finally{foreach($process in @($older,$parent)){if($process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}}}
$rows|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $OutDir 'cleanup-identity.json') -Encoding UTF8
foreach($row in $rows){$(if($row.passed){'PASS '}else{'FAIL '})+$row.case}
exit [int](@($rows|Where-Object {-not $_.passed}).Count -gt 0)
