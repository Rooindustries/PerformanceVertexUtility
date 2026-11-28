param([ValidateSet('Seed','Snapshot','Compare','Kill','Settle')][string]$Mode,[string]$Path,[string]$Other,[string]$Test,[string]$Marker)
$ErrorActionPreference='Stop'
$repo=$PSScriptRoot
. (Join-Path $repo 'backend\scripts\OperationState.Common.ps1')
. (Join-Path $repo 'backend\scripts\BrandCompatibility.Common.ps1')
$data=Get-RooIndustriesLocalDataRoot -Protected
function State {
  $rows=@(Get-ChildItem -LiteralPath $data -Recurse -Force|Sort-Object FullName|ForEach-Object {
    $rel=$_.FullName.Substring($data.Length)
    if($_.PSIsContainer){'data D '+$rel}else{'data F '+$rel+' '+$_.Length+' '+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
  $rows+=@(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'|ForEach-Object {'uninstall '+$_.PSChildName}|Sort-Object)
  $rows+=@(Get-ChildItem 'HKCU:\Software'|ForEach-Object {'software '+$_.PSChildName}|Sort-Object)
  $m=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots')
  if($m){$rows+=@($m.GetValueNames()|ForEach-Object {'marker '+$_}|Sort-Object);$m.Dispose()}
  $rows+=@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'roo-industries-*' -Force|ForEach-Object {'temp '+$_.Name}|Sort-Object)
  return [string[]]$rows
}
switch($Mode){
 'Seed' {
  & (Join-Path $repo 'backend\scripts\Build-OptimizerHost.ps1')|Out-Null
  $input=Join-Path $env:RUNNER_TEMP 'seed-exclusions.json'
  Write-RooIndustriesOperationJson @{paths=@((Join-Path $env:USERPROFILE 'Documents\keep-this.txt'));registry=@()} $input
  $null=& (Join-Path $repo 'backend\scripts\Invoke-CleanupExclusions.ps1') -Action Save -InputPath $input -ConfirmApply
  Write-Host ('Seeded user exclusions in '+$data)
  [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall').Dispose()
 }
 'Snapshot' {$rows=State;[IO.File]::WriteAllLines($Path,$rows);Write-Host ('Snapshot '+$rows.Count+' entries')}
 'Settle' {
  $want=@([IO.File]::ReadAllLines($Path));$watch=[Diagnostics.Stopwatch]::StartNew()
  do {$now=State;$diff=@(Compare-Object $want $now);if($diff.Count -eq 0){break};Start-Sleep -Seconds 2} while($watch.Elapsed.TotalSeconds -lt 120)
  foreach($d in $diff){Write-Host ($d.SideIndicator+' '+$d.InputObject)}
  Write-Host ('RESULT '+$Marker+' '+$(if($diff.Count -eq 0){'IDENTICAL after '+[Math]::Round($watch.Elapsed.TotalSeconds,1)+' s'}else{'CHANGED ('+$diff.Count+' lines) after 120 s'}))
 }
 'Kill' {
  $psi=[Diagnostics.ProcessStartInfo]::new('powershell.exe',('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $repo ('backend\scripts\'+$Test))+'"'))
  $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.WorkingDirectory=$repo
  $p=[Diagnostics.Process]::Start($psi);$hit=$false
  while($null -ne ($line=$p.StandardOutput.ReadLine())){Write-Host $line;if($line -like ('*'+$Marker+'*')){$hit=$true;break}}
  & taskkill.exe /PID $p.Id /T /F
  $p.WaitForExit()
  Write-Host ('KILLED '+$Test+' at marker: '+$hit)
  if(-not $hit){throw 'Marker not reached'}
 }
}
