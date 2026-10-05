param([Parameter(Mandatory=$true)][string]$Installer,[Parameter(Mandatory=$true)][string]$OutDir,[ValidateRange(1,3600)][int]$TimeoutSeconds=900)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot '..\LoadTimes\CleanupOwnership.Common.ps1')
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
$setup=$null;$owned=$null;$failure=$null
$clock=[Diagnostics.Stopwatch]::StartNew()
$result=[ordered]@{installer=$Installer;exit=$null;status='failed';completed=$false;process=$null;timeoutSeconds=$TimeoutSeconds;elapsedMilliseconds=0;error='';temporaryFolders=@();setupFolderLeft=$false}
try {
    $setup=Start-Process -FilePath $Installer -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="'+$log+'"') -PassThru
    $handle=$setup.Handle
    $owned=New-OwnedProcess $setup
    $result.process=if($owned){$owned.Identity}else{[pscustomobject]@{pid=$setup.Id;creationTimeFileTimeUtc=[RooValidationOwnership.Native]::Created($handle).ToString();imagePath=[RooValidationOwnership.Native]::Image($handle)}}
    while(-not $setup.WaitForExit(0)){
        if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){$result.status='timeout';throw ('Installer exceeded '+$TimeoutSeconds+' seconds')}
        foreach($root in $roots){foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'is-*.tmp' -Force -ErrorAction SilentlyContinue)){if(-not $before.ContainsKey($dir.FullName) -and -not $seen.Contains($dir.FullName)){try {$seen[$dir.FullName]=Describe $dir.FullName} catch {}}}}
        $folder=Join-Path $app 'setup'
        if((Test-Path -LiteralPath $folder) -and -not $seen.Contains($folder)){try {$seen[$folder]=Describe $folder} catch {}}
        [void]$setup.WaitForExit(100)
    }
    $setup.Refresh()
    $result.exit=$setup.ExitCode
    if($result.exit -isnot [int]){throw 'Installer completion has no native exit code'}
    if($result.exit -ne 0){throw ('Installer exited '+$result.exit)}
    $result.status='completed';$result.completed=$true
} catch {
    $failure=$_;$result.completed=$false;$result.error=$_.Exception.Message
    if($owned){try{Stop-OwnedProcess $owned}catch{$result.error+='; exact process cleanup failed: '+$_.Exception.Message}}
} finally {
    if($setup){
        try{if($setup.WaitForExit(0)){$setup.Refresh();$result.exit=$setup.ExitCode}}catch{$result.completed=$false;$result.status='failed';$result.error+='; native exit unavailable: '+$_.Exception.Message;$failure=$_}
        $setup.Dispose()
    }
    $result.elapsedMilliseconds=$clock.ElapsedMilliseconds
    $result.temporaryFolders=@($seen.Values)
    $result.setupFolderLeft=Test-Path -LiteralPath (Join-Path $app 'setup')
    $result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'setup-temp-acl.json') -Encoding UTF8
}
$result|ConvertTo-Json -Depth 6
if($failure -or -not $result.completed -or $result.status -cne 'completed' -or $result.exit -isnot [int] -or $result.exit -ne 0){Write-Output ('FAIL installer '+$result.status+' :: '+$result.error);if($failure){throw $failure};throw 'Installer completion was not confirmed'}
$global:LASTEXITCODE=$result.exit
Write-Output ('PASS installer completed with native exit 0; pid '+$result.process.pid+'; ACL evidence '+(Join-Path $OutDir 'setup-temp-acl.json'))
