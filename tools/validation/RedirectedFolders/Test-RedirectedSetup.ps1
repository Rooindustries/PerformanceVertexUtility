param([string]$Repo,[string]$Scratch,[string]$Phase='after',[string[]]$Scenario=@())
$ErrorActionPreference='Stop';Import-Module Microsoft.PowerShell.Utility,Microsoft.PowerShell.Management
if($env:COMPUTERNAME -ne 'CS2-GEN4'){throw 'Wrong machine'}
if(-not(Test-Path -LiteralPath (Join-Path $Scratch 'fixture-owner.txt'))){throw 'Unowned scratch'}
$acl=Get-Acl -LiteralPath $Scratch
if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'The fixture scratch must have protected administrator ownership.'}
foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ([int64]$rule.FileSystemRights -band 0x500D0156) -ne 0){throw 'The fixture scratch permits an untrusted writer.'}}
if(@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -eq 'S-1-3-4' -and $_.AccessControlType -eq 'Allow'}).Count -eq 0){throw 'The fixture scratch must limit implicit owner rights.'}
[Reflection.Assembly]::LoadFrom((Join-Path $Scratch 'FolderFixture.dll'))|Out-Null
$iscc='C:\Users\serviroo\AppData\Local\Programs\Inno Setup 6\ISCC.exe'
& $iscc /Q ('/DOutputDir='+$Scratch) (Join-Path $Repo 'tools\release\SetupProcess.Test.iss')
if($LASTEXITCODE){throw 'Inno compile failed'}
$rows=New-Object System.Collections.Generic.List[object]
foreach($case in @('install-root','download-local','short-system','short-path','clean','poison','unset','relative-poison','redirect','redirect-poison','redirect-string','profile-expand','absent','guid-only','reparse-parent','missing','relative','empty','unknown','system-poison','unc','dword','drive-root','windows','environment','volatile','roaming-unc','single-percent','single-percent-expand','unknown-absolute')){
    if($Scenario.Count -and $case -notin $Scenario){continue}
    [FolderFixture]::Begin($Scratch,$case,'setup');$sid=[FolderFixture]::Sid;$local=[FolderFixture]::Local;$roaming=[FolderFixture]::Roaming;$profile=[FolderFixture]::Profile;[FolderFixture]::End()
    $work=Join-Path $Scratch ('setup-'+$case);[IO.Directory]::CreateDirectory($work)|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $work 'setup-temp'))|Out-Null
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=Join-Path $Scratch 'SetupProcessCheck.exe'
    if($case -eq 'download-local'){Copy-Item -LiteralPath $start.FileName -Destination (Join-Path $local 'SetupProcessCheck.exe') -Force;$start.FileName=Join-Path $local 'SetupProcessCheck.exe'};$start.UseShellExecute=$false
    $temp=Join-Path $work 'setup-temp';if($case -eq 'install-root'){$temp=Join-Path $local 'setup';[IO.Directory]::CreateDirectory($temp)|Out-Null}
    $start.Arguments='/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /work="'+$work+'" /folderfixture="'+(Join-Path $Scratch ($case+'-setup-users.hive'))+'" /fixturesid='+$sid+' /foldertemp="'+$temp+'"'
    if($case -in @('poison','redirect-poison','profile-expand','relative-poison')){
        $start.EnvironmentVariables['USERPROFILE']=Join-Path $Scratch 'poison\profile';$start.EnvironmentVariables['LOCALAPPDATA']=Join-Path $Scratch 'poison\local';$start.EnvironmentVariables['APPDATA']=Join-Path $Scratch 'poison\roaming';$start.EnvironmentVariables['HOMEDRIVE']='Q:';$start.EnvironmentVariables['HOMEPATH']='\poison-home'
    }
    $childCase=$case -in @('clean','poison','redirect','redirect-poison','single-percent','single-percent-expand')
    if($childCase){$start.Arguments+=' /folderchild=1'}
    $p=[Diagnostics.Process]::Start($start);if(-not $p.WaitForExit(30000)){throw 'Setup fixture timed out'}
    $text=Get-Content -LiteralPath (Join-Path $work 'folder-report.txt') -Raw;$refused=$text -match 'refused=1';$seen=@{}
    if(-not $refused){foreach($entry in [IO.File]::ReadAllText((Join-Path $work 'folder-block.txt')).Split([char]0)){$split=$entry.IndexOf('=');if($split -gt 0){$seen[$entry.Substring(0,$split)]=$entry.Substring($split+1)}}}
    $expect=$case -in @('install-root','short-system','reparse-parent','missing','relative','empty','unknown','unknown-absolute','system-poison','unc','dword','drive-root','windows')
    $passed=$refused -eq $expect -and ($refused -or ($seen['LOCALAPPDATA'] -eq $local -and $seen['APPDATA'] -eq $roaming -and $seen['USERPROFILE'] -eq $profile -and @('DOTNET_EnableDiagnostics','COMPlus_EnableDiagnostics','DOTNET_EnableDiagnostics_IPC','COMPlus_EnableDiagnostics_IPC','DOTNET_EnableDiagnostics_Debugger','COMPlus_EnableDiagnostics_Debugger','DOTNET_EnableDiagnostics_Profiler','COMPlus_EnableDiagnostics_Profiler'|Where-Object {$seen[$_] -ne '0'}).Count -eq 0))
    $bits=$null
    if($childCase -and -not $refused){
        $child=@{};foreach($line in Get-Content -LiteralPath (Join-Path $work 'folder-child.txt')){$split=$line.IndexOf('=');if($split -gt 0){$child[$line.Substring(0,$split)]=$line.Substring($split+1)}}
        $bits=(Get-Content -LiteralPath (Join-Path $work 'folder-bits.txt') -Raw).Trim()
        $passed=$passed -and $text.Contains('folder child=1 exit=7') -and $bits -eq '64' -and $child['USERPROFILE'] -eq $profile -and $child['LOCALAPPDATA'] -eq $local -and $child['APPDATA'] -eq $roaming
    }
    $rows.Add(@{host='setup';scenario=$case;localAppData=$seen['LOCALAPPDATA'];roamingAppData=$seen['APPDATA'];profile=$seen['USERPROFILE'];temp=$seen['TEMP'];refused=$refused;message=$text.Trim();architecture=$seen['PROCESSOR_ARCHITECTURE'];childBits=$bits;passed=$passed})
}
$rows|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content -LiteralPath (Join-Path $Scratch ($Phase+'-setup.jsonl')) -Encoding UTF8
'RESULT setup '+$Phase+' passed='+@($rows|Where-Object passed).Count+'/'+$rows.Count
