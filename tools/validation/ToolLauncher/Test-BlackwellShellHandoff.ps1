param([Parameter(Mandatory)][string]$Evidence,[string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[Parameter(Mandatory)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne $ExpectedMachine){throw 'This check is authorized only on Blackwell'}
if(-not([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An elevated desktop parent is required'}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
if(-not$DotNetPath){$DotNetPath=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet\dotnet.exe'}
if(-not(Test-Path -LiteralPath $DotNetPath)){throw 'The explicitly selected SDK is missing'}
if(Test-Path -LiteralPath $Evidence){throw 'Evidence already exists; preserve it and select a fresh path'}
[IO.Directory]::CreateDirectory($Evidence)|Out-Null
$fixture=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AppData\Local\Temp\roo-blackwell-shell-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $fixture){throw 'Fixture already exists'}
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',$true)
if(-not$key){throw 'Explorer Advanced key missing; no key was created'}
$original=Get-OwnedRegistryField $key 'SeparateProcess';$sddl=$key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access,Owner,Group')
$intent=$null;$copies=[Collections.Generic.List[object]]::new();$owned=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new();$failure=$null;$restored=$false;$removed=$false
$result=[ordered]@{machine=$env:COMPUTERNAME;fixture=$fixture;originalSeparateProcess=$original;checks=@();settingRestored=$false;fixtureRemoved=$false;passed=$false;error='';https='No URL opened; the exact shared OpenInExplorer function is exercised with a probe exe, as authorized by lead';tempEvidenceLevel='harness'}
function Save-Result {$result.checks=@($rows);$result.settingRestored=$restored;$result.fixtureRemoved=$removed;$result|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $Evidence 'shell-handoff.json') -Encoding UTF8}
Save-Result
function Native-Check([string]$Mode,[string]$Label) {
    $dir=Join-Path $fixture ($Label+'\Utilities\Other\Probe');[IO.Directory]::CreateDirectory($dir)|Out-Null
    $probe=Join-Path $dir 'IntegrityProbe.exe';$copy=Copy-OwnedProbe (Join-Path $fixture 'compiled-probe.exe') $probe;$copies.Add($copy.Identity);$copy.Identity|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Evidence ($Label+'-file-receipt.json')) -Encoding UTF8;$copy.Dispose()
    $json=Join-Path $Evidence ($Label+'.json')
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue';try{$output=@(& $DotNetPath (Join-Path $root 'tools\validation\Release\BlackwellHarness\bin\Release\net8.0-windows\BlackwellHarness.dll') $Mode $probe $json 2>&1|ForEach-Object {[string]$_});$code=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
    $output|Set-Content -LiteralPath (Join-Path $Evidence ($Label+'.log')) -Encoding UTF8
    if(Test-Path -LiteralPath $json){$row=Get-Content -Raw -LiteralPath $json|ConvertFrom-Json;$row|Add-Member -NotePropertyName label -NotePropertyValue $Label;$row|Add-Member -NotePropertyName separateProcess -NotePropertyValue (Get-OwnedRegistryField $key 'SeparateProcess');$rows.Add($row)
        $p=Get-Process -Id $row.probe.pid -ErrorAction SilentlyContinue
        if($p){$native=New-OwnedProcess $p;if($native -and $native.Identity.creationTimeFileTimeUtc -ceq $row.probe.creationTimeFileTimeUtc -and $native.Identity.imagePath -ieq [RooIndustriesValidationOwnership.Native]::Canonical($probe)){$owned.Add($native);[void]$p.WaitForExit(5000)}}
        if($Mode -ne 'temp' -and $row.probe.integrity -in 'High','System'){throw ('HIGH TOKEN: '+$Label+' '+$row.probe.integrity+'; retained '+$json)}
    }
    if($code -ne 0 -or -not(Test-Path -LiteralPath $json)){throw ('Native '+$Label+' failed with exit '+$code)}
    Write-Output ('PASS '+$Label+' native '+$row.probe.integrity+' parent '+$row.probe.parent.pid+' session '+$row.probe.session)
}
try {
    & $DotNetPath build (Join-Path $root 'tools\validation\Release\BlackwellHarness\BlackwellHarness.csproj') -c Release /p:RooIndustriesRelease=true > (Join-Path $Evidence 'build-harness.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'Harness build failed'}
    $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 ('/out:'+(Join-Path $fixture 'compiled-probe.exe')) (Join-Path $root 'tools\validation\Release\BlackwellHarness\NativeProbe.cs') > (Join-Path $Evidence 'build-probe.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'Native probe build failed'}
    foreach($variant in 'as-is','separate-process'){
        if($variant -ceq 'separate-process'){$intent=New-OwnedRegistryFieldIntent $key 'SeparateProcess' 1 ([Microsoft.Win32.RegistryValueKind]::DWord);$key.SetValue('SeparateProcess',1,[Microsoft.Win32.RegistryValueKind]::DWord);$key.Flush();if((Get-OwnedRegistryField $key 'SeparateProcess') -cne $intent.after){throw 'SeparateProcess write did not match intent'}}
        $existing=@();$exit=0;try{$existing=@(& (Join-Path $root 'tools\scripts\Test-ToolLauncher.ps1') -Scenario Fallback -DotNetPath $DotNetPath -EvidencePath (Join-Path $Evidence ($variant+'-existing-fallback.txt')) 2>&1|ForEach-Object {[string]$_});$exit=$LASTEXITCODE}catch{$existing+=($_|Out-String);$exit=1}
        $existing|Where-Object {$_ -notmatch '^NOTE user='}|ForEach-Object {$_ -replace ' user=[^ ]+',' user=<redacted>'}|Set-Content -LiteralPath (Join-Path $Evidence ($variant+'-existing-fallback.log')) -Encoding UTF8
        $text=Get-Content -Raw -LiteralPath (Join-Path $Evidence ($variant+'-existing-fallback.txt'))
        if($text -match 'integrity=0x[34]'){throw ('HIGH TOKEN: existing '+$variant+' fallback probe')}
        if($exit -ne 0 -or $text -notmatch 'integrity=0x2000 \(Medium\)' -or $text -notmatch 'elevated=false' -or $text -notmatch 'verdict: PASS'){throw ('Existing Utilities fallback did not prove a Medium native probe: '+$variant)}
        Native-Check 'fallback' ($variant+'-native-fallback')
    }
    Restore-OwnedRegistryField $intent;$intent=$null
    if((Get-OwnedRegistryField $key 'SeparateProcess') -cne $original){throw 'SeparateProcess restoration differs before direct case'}
    Native-Check 'direct' 'direct-open-in-explorer'
    Native-Check 'temp' 'disk-cleanup-temp-harness'
    $result.passed=$true
} catch {$failure=$_;$result.error=$_.Exception.Message;$result.passed=$false}
finally {
    try {Restore-OwnedRegistryField $intent;$restored=(Get-OwnedRegistryField $key 'SeparateProcess') -ceq $original -and $key.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access,Owner,Group') -ceq $sddl;if(-not$restored){throw 'Explorer setting or descriptor differs'}} catch {$result.error+='; restore: '+$_.Exception.Message;$result.passed=$false;$failure=$_}
    foreach($p in $owned){try{Stop-OwnedProcess $p;$p.process.Dispose()}catch{$result.error+='; exact process cleanup: '+$_.Exception.Message;$result.passed=$false;$failure=$_}}
    foreach($copy in $copies){try{$held=Open-OwnedProbe $copy;Remove-OwnedProbe $held}catch{$result.error+='; exact probe cleanup: '+$_.Exception.Message;$result.passed=$false;$failure=$_}}
    try {
        $unknown=@(Get-ChildItem -LiteralPath $fixture -File -Recurse -Force|Where-Object {$_.Name -notin 'compiled-probe.exe','probe-report.json','probe-report.json.tmp','probe-error.txt'})
        if($unknown.Count){throw 'Unknown fixture files retained'}
        if(@(Get-ChildItem -LiteralPath $fixture -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Reparse fixture retained'}
        Remove-Item -LiteralPath $fixture -Recurse -Force;$removed=-not(Test-Path -LiteralPath $fixture)
    }catch{$result.error+='; fixture cleanup: '+$_.Exception.Message;$result.passed=$false;$failure=$_}
    $key.Dispose();Save-Result
}
if($failure){Write-Output ('FAIL '+$result.error);throw $failure}
Write-Output ('PASS F3 and F6 native harness, original Explorer setting restored, zero fixture leftovers; '+(Join-Path $Evidence 'shell-handoff.json'))
