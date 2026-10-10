param([string]$Repo,[string]$Scratch,[string]$Phase='after',[string[]]$Scenario=@())
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ne 'CS2-GEN4'){throw 'Wrong machine'}
if(-not(Test-Path -LiteralPath (Join-Path $Scratch 'fixture-owner.txt'))){throw 'Unowned scratch'}
$acl=Get-Acl -LiteralPath $Scratch
if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'The fixture scratch must have protected administrator ownership.'}
foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ([int64]$rule.FileSystemRights -band 0x500D0156) -ne 0){throw 'The fixture scratch permits an untrusted writer.'}}
if(@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -eq 'S-1-3-4' -and $_.AccessControlType -eq 'Allow'}).Count -eq 0){throw 'The fixture scratch must limit implicit owner rights.'}
$source=Join-Path $Repo 'tools\validation\RedirectedFolders'
$dotnet=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet\dotnet.exe'
$csc=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:library ('/out:'+(Join-Path $Scratch 'FolderFixture.dll')) (Join-Path $source 'Fixture.cs')
if($LASTEXITCODE -ne 0){throw 'Fixture compile failed'}
& $dotnet build (Join-Path $source 'RedirectedFolders.csproj') --nologo -v:q
if($LASTEXITCODE -ne 0){throw 'Harness compile failed'}
$cases=@('clean','empty-poison','launcher-poison','poison','missing-poison','unset','relative-poison','cache-poison','redirect','redirect-protected','redirect-poison','redirect-string','profile-expand','absent','guid-only','reparse-parent','missing','relative','empty','unknown','system-poison','unc','dword','drive-root','windows','environment','volatile','roaming-unc','protected-move','marker-missing','marker-damaged','marker-other-sid','marker-ambiguous','short-path','other-marker','other-default','other-loaded','other-mismatch','other-unmarked','other-principal')
$cases+=@('single-percent','single-percent-expand','unknown-absolute','other-percent','machine-percent','machine-unknown')
if($Scenario.Count){$cases=@($cases|Where-Object {$_ -in $Scenario})}
$outputFile=Join-Path $Scratch ($Phase+'.jsonl')
[IO.File]::WriteAllText($outputFile,'')
$rows=New-Object System.Collections.Generic.List[object]
foreach($case in $cases){foreach($hostKind in @('core','powershell')){
    if($case -in @('launcher-poison','machine-percent','machine-unknown') -and $hostKind -eq 'powershell'){continue}
    $start=New-Object Diagnostics.ProcessStartInfo;$start.WorkingDirectory=$Scratch;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    if($hostKind -eq 'core'){$start.FileName=$dotnet;$start.Arguments='"'+(Join-Path $source 'bin\Debug\net8.0-windows\RedirectedFolders.dll')+'" "'+$Scratch+'" '+$case}
    else{$start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $source 'Invoke-RedirectedFolderChild.ps1')+'" -Scratch "'+$Scratch+'" -Scenario '+$case+' -Common "'+(Join-Path $Repo 'backend\scripts\BrandCompatibility.Common.ps1')+'" -Fixture "'+(Join-Path $Scratch 'FolderFixture.dll')+'"'}
    if($case -in @('poison','missing-poison','relative-poison','cache-poison','redirect-poison','profile-expand','system-poison','launcher-poison')){
        $profile=Join-Path $Scratch 'poison\profile';if($case -in @('missing-poison','launcher-poison')){$profile='C:\RooIndustriesF10Missing\profile'};if($case -eq 'relative-poison'){$profile='relative\profile'}
        $start.EnvironmentVariables['USERPROFILE']=$profile;$start.EnvironmentVariables['LOCALAPPDATA']=Join-Path $Scratch 'poison\local';$start.EnvironmentVariables['APPDATA']=Join-Path $Scratch 'poison\roaming';$start.EnvironmentVariables['HOMEDRIVE']='Q:';$start.EnvironmentVariables['HOMEPATH']='\poison-home'
        if($case -eq 'system-poison' -and $hostKind -eq 'core'){$start.EnvironmentVariables['SystemRoot']='C:\RooIndustriesF10MissingWindows'}
    }
    if($case -eq 'empty-poison' -and $hostKind -eq 'core'){foreach($name in @('USERPROFILE','LOCALAPPDATA','APPDATA','HOMEDRIVE','HOMEPATH')){$start.EnvironmentVariables[$name]=''}}
    if($case -eq 'unset'){foreach($name in @('USERPROFILE','LOCALAPPDATA','APPDATA','HOMEDRIVE','HOMEPATH')){$start.EnvironmentVariables.Remove($name)}}
    $p=[Diagnostics.Process]::Start($start);$out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit();
    $row=@($out -split "`n"|Where-Object {$_ -match '^\{'}|ForEach-Object {$_|ConvertFrom-Json})[-1]
    if(-not $row){throw ('No row: '+$case+' '+$hostKind+' '+$err)};$rows.Add($row);$row|ConvertTo-Json -Compress|Add-Content -LiteralPath $outputFile -Encoding UTF8
}}
$rows|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content -LiteralPath (Join-Path $Scratch ($Phase+'.jsonl')) -Encoding UTF8
'RESULT '+$Phase+' passed='+@($rows|Where-Object passed).Count+'/'+$rows.Count
