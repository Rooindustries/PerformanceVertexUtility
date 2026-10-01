param([Parameter(Mandatory=$true)][string]$Installer,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir|Out-Null
$app='C:\Program Files\Roo Industries\Optimization Suite'
$roots=@([IO.Path]::GetTempPath(),(Join-Path $env:SystemRoot 'SystemTemp'),(Join-Path $env:SystemRoot 'Temp'))|Where-Object {Test-Path -LiteralPath $_}
$before=@{};foreach($root in $roots){foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'is-*.tmp' -Force -ErrorAction SilentlyContinue)){$before[$dir.FullName]=$true}}
$seen=[ordered]@{}
function Describe([string]$Path){
    $acl=Get-Acl -LiteralPath $Path
    $writers=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('S-1-5-32-544','S-1-5-18') -and (([int64]$_.FileSystemRights -band 0x500D0156) -ne 0)}|ForEach-Object {$_.IdentityReference.Value+':'+$_.FileSystemRights})
    [ordered]@{path=$Path;owner=$acl.Owner;protected=$acl.AreAccessRulesProtected;nonAdminWriters=$writers;icacls=@(& icacls.exe $Path 2>&1|ForEach-Object {[string]$_});files=@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue|ForEach-Object Name)}
}
$log=Join-Path $OutDir 'setup.log'
$setup=Start-Process -FilePath $Installer -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+$log+'"') -PassThru
while(-not $setup.HasExited){
    foreach($root in $roots){foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'is-*.tmp' -Force -ErrorAction SilentlyContinue)){if(-not $before.ContainsKey($dir.FullName) -and -not $seen.Contains($dir.FullName)){try {$seen[$dir.FullName]=Describe $dir.FullName} catch {}}}}
    $folder=Join-Path $app 'setup'
    if((Test-Path -LiteralPath $folder) -and -not $seen.Contains($folder)){try {$seen[$folder]=Describe $folder} catch {}}
    Start-Sleep -Milliseconds 100
}
$result=[ordered]@{installer=$Installer;exit=$setup.ExitCode;temporaryFolders=@($seen.Values);setupFolderLeft=(Test-Path -LiteralPath (Join-Path $app 'setup'))}
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'setup-temp-acl.json') -Encoding UTF8
$result|ConvertTo-Json -Depth 6
