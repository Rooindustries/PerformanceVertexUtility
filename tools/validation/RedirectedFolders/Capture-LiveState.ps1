param([string]$Out)
$ErrorActionPreference='Stop';$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Hash([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','')}finally{$sha.Dispose()}}
$values=@{}
foreach($path in @('Registry::HKEY_USERS',('Registry::HKEY_USERS\'+$sid+'\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'),('Registry::HKEY_USERS\'+$sid+'\Environment'),('Registry::HKEY_USERS\'+$sid+'\Volatile Environment'),'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots')){
 if($path -eq 'Registry::HKEY_USERS'){$text=@(Get-ChildItem -LiteralPath $path|ForEach-Object PSChildName|Sort-Object) -join '|'}else{$key=Get-Item -LiteralPath $path -ErrorAction SilentlyContinue;$text=if($key){@($key.GetValueNames()|Sort-Object|ForEach-Object {$_+'='+$key.GetValue($_,$null,'DoNotExpandEnvironmentNames')+';'+$key.GetValueKind($_)}) -join '|'}else{'absent'}}
 $values[$path]=Hash $text
}
$tasks=@(Get-ScheduledTask -TaskName '*OptimizationSuite.ProcessRules.*','RooIndustriesOptimizationSuite.GovernorSetupWatchdog' -ErrorAction SilentlyContinue|ForEach-Object {($_|ConvertTo-Json -Depth 6 -Compress)}) -join '|';$values['tasks']=Hash $tasks
$values['missing-poison-exists']=[string](Test-Path -LiteralPath 'C:\RooIndustriesF10Missing');$values['missing-windows-exists']=[string](Test-Path -LiteralPath 'C:\RooIndustriesF10MissingWindows')
$values|ConvertTo-Json|Set-Content -LiteralPath $Out -Encoding UTF8
