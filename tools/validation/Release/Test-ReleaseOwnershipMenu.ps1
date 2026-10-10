param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$checks=New-Object System.Collections.Generic.List[object]
function Check([bool]$Passed,[string]$Name,[string]$Detail=''){
    $checks.Add([pscustomobject]@{passed=$Passed;check=$Name;detail=$Detail})
    $(if($Passed){'PASS '}else{'FAIL '})+$Name+' :: '+$Detail
}
$install=Join-Path $OutDir 'Roo Industries fixture install'
$hostFolder=Join-Path $install 'backend\bin\optimizer'
$catalogFolder=Join-Path $install 'backend\catalogs'
New-Item -ItemType Directory -Path $catalogFolder -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $Source 'backend\profiles') -Destination (Join-Path $install 'backend') -Recurse
$catalog=Get-Content -LiteralPath (Join-Path $Source 'backend\catalogs\windows-tweaks.json') -Raw|ConvertFrom-Json
$ids=@('windows.13b6c0d8fb231462','windows.c26219e8cf004354')
$catalog.settings=@($catalog.settings|Where-Object {$_.id -in $ids})
$catalog.presets=@()
$catalog.incompatible=@()
[IO.File]::WriteAllText((Join-Path $catalogFolder 'windows-tweaks.json'),($catalog|ConvertTo-Json -Depth 64),[Text.UTF8Encoding]::new($false))
$ui=Join-Path $install 'app\RooIndustries.OptimizationSuite.App.exe'
New-Item -ItemType Directory -Path (Split-Path $ui) -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $ui
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$programSource=Join-Path $Source 'backend\native\Optimizer.Host\Program.cs'
$program=[IO.File]::ReadAllText($programSource)
$seam='request.FixturePath is null ? new RegistryTweakStore() :'
if([regex]::Matches($program,[regex]::Escape($seam)).Count -ne 1){throw 'The Host fixture state seam changed.'}
$statePath='Software\RooIndustriesTweakTests\'+[Guid]::NewGuid().ToString('N')+'\Recovery'
$program=$program.Replace($seam,('request.FixturePath is null ? new RegistryTweakStore(new RegistryAddress("CurrentUser", "Registry64", @"'+$statePath+'", "value", "State")) :'))
$fixtureProgram=Join-Path $OutDir 'FixtureProgram.cs'
[IO.File]::WriteAllText($fixtureProgram,$program,[Text.UTF8Encoding]::new($false))
& $dotnet publish (Join-Path $Source 'tools\validation\Release\ReleaseHostFixture\ReleaseHostFixture.csproj') -c Release -r win-x64 --self-contained true -p:RooIndustriesRelease=true -p:EnableWindowsTargeting=true ('-p:FixtureProgram='+$fixtureProgram) -o $hostFolder
if($LASTEXITCODE -ne 0){throw 'The release Host fixture build failed.'}
$local=Join-Path $OutDir 'local'
New-Item -ItemType Directory -Path $local|Out-Null
[IO.File]::WriteAllText((Join-Path $OutDir 'fixture-owner.txt'),[Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText((Join-Path $hostFolder 'release-host-fixture.json'),(@{work=$OutDir;local=$local}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
foreach($mode in @('present','writable','linked','missing')){
    $originalAcl=$null
    if($mode -eq 'writable'){
        $originalAcl=Get-Acl -LiteralPath $ui;$changed=Get-Acl -LiteralPath $ui
        $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'Modify','Allow'))
        Set-Acl -LiteralPath $ui -AclObject $changed
    }
    if($mode -eq 'linked'){
        Move-Item -LiteralPath $ui -Destination ($ui+'.held')
        New-Item -ItemType SymbolicLink -Path $ui -Target ($ui+'.held')|Out-Null
    }
    if($mode -eq 'missing'){Move-Item -LiteralPath $ui -Destination ($ui+'.held')}
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $hostFolder 'Optimizer.Host.exe'),'tweak-status -')
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($name in @($start.EnvironmentVariables.Keys)){if($name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'){$start.EnvironmentVariables.Remove($name)}}
    $start.EnvironmentVariables['ROO_INDUSTRIES_UI_EXE']=Join-Path $OutDir 'untrusted-user-override.exe'
    $child=[Diagnostics.Process]::Start($start)
    try {
        $output=$child.StandardOutput.ReadToEndAsync();$errorLog=$child.StandardError.ReadToEndAsync()
        $child.StandardInput.WriteLine((@{schemaVersion=1;repoRoot=$install}|ConvertTo-Json -Compress));$child.StandardInput.Close()
        if(-not $child.WaitForExit(60000)){$child.Kill();throw 'The ownership menu Host check timed out.'}
        $response=$output.Result|ConvertFrom-Json
        $rows=@($response.data.settings|Where-Object {$_.id -in $ids})
        foreach($id in $ids){
            $row=@($rows|Where-Object {$_.id -ceq $id})
            $ok=$child.ExitCode -eq 0 -and $response.status -ceq 'completed' -and $row.Count -eq 1
            if($mode -eq 'present'){$ok=$ok -and $null -eq $row[0].error -and $row[0].supported -eq $true}
            else {$ok=$ok -and [string]$row[0].error -match '(desktop app|missing|damaged|install|protected)'}
            Check $ok ('Release ownership setting '+$id+' is '+$(if($mode -eq 'present'){'readable in its installed layout'}else{'refused when the app executable is '+$mode})) $(if($row.Count -eq 1){[string]$row[0].error}else{'No matching setting: '+[string]$response.error.message})
        }
        $rows|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutDir ($mode+'-settings.json')) -Encoding UTF8
    } finally {
        $child.Dispose()
        if($originalAcl){Set-Acl -LiteralPath $ui -AclObject $originalAcl}
        if($mode -eq 'linked'){
            $link=Get-Item -LiteralPath $ui -Force
            if(-not($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [string]$link.Target -cne ($ui+'.held')){throw 'The own fixture link changed; retained.'}
            Remove-Item -LiteralPath $ui
            Move-Item -LiteralPath ($ui+'.held') -Destination $ui
        }
    }
}
Move-Item -LiteralPath ($ui+'.held') -Destination $ui
$passed=@($checks|Where-Object {-not $_.passed}).Count -eq 0
[pscustomobject]@{passed=$passed;checks=$checks.ToArray();source=$Source;install=$install;hostProgramSha256=(Get-FileHash -LiteralPath $programSource).Hash;fixtureProgramSha256=(Get-FileHash -LiteralPath $fixtureProgram).Hash;isolatedStatePath=$statePath}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
exit [int](-not $passed)
