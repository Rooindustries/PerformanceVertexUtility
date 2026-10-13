param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Stage,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'Build-CopyFailureFixture' $OutRoot
Ensure-HarnessOutputDirectory $OutRoot

[IO.Directory]::CreateDirectory((Get-HarnessLongPath $OutRoot))|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$text=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'tools\release\RooIndustries.OptimizationSuite.iss')))
$text=$text.Replace('Flags: ignoreversion recursesubdirs createallsubdirs','Flags: ignoreversion recursesubdirs createallsubdirs; AfterInstall: FailSilentCopy')
$text=$text.Replace('  SetupFolder: String;','  SetupFolder: String;' + "`n  FixtureCopies: Integer;")
$text+=@'

procedure FailSilentCopy();
begin
  FixtureCopies := FixtureCopies + 1;
  if WizardSilent and (FixtureCopies = 3) then
  begin
    if FileExists(ExpandConstant('{app}\app\{#AppExe}')) then
      RaiseException('Fixture did not reach the missing-executable state');
    Log('OTA fixture: copied three files after InstallDelete; app executable is missing.');
    if not CreateDir(ExpandConstant('{app}\app\{#AppExe}')) then
      RaiseException('Fixture could not block the executable destination');
    Log('OTA fixture: a directory at the executable destination forces a real copy failure.');
  end;
end;
'@
$script=Join-Path $OutRoot 'RooIndustries.OptimizationSuite.iss'
New-HarnessText $script $text 'installer-fixture'|Out-Null
Copy-HarnessFile (Join-Path $Source 'tools\release\SetupProcess.iss') (Join-Path $OutRoot 'SetupProcess.iss')|Out-Null
$iscc=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe';if(-not(Test-HarnessPath $iscc)){$iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'}
$hash=(Get-HarnessFileSha256 (Join-Path $Stage 'backend\scripts\Invoke-GovernorSetup.ps1'))
$commonHash=(Get-HarnessFileSha256 (Join-Path $Stage 'backend\scripts\BrandCompatibility.Common.ps1'))
$version=(Get-HarnessItem (Join-Path $Stage 'app\RooIndustries.OptimizationSuite.App.exe')).VersionInfo.ProductVersion.Trim()
if($version -notmatch '^(\d+\.\d+\.\d+)(?:-|\+|$)'){throw 'Copy-failure stage ProductVersion is invalid'}
$numericVersion=$Matches[1]+'.0'
$name='RooIndustries-OptimizationSuite-'+$version+'-setup'
$arguments=@('/Q',('/DAppVersion='+$version),('/DAppNumericVersion='+$numericVersion),('/DGovernorSetupHash='+$hash),('/DGovernorSetupCommonHash='+$commonHash),('/DSourceDir='+$Stage),('/DOutputDir='+$OutRoot),('/DOutputName='+$name),$script)|ForEach-Object {'"'+$_+'"'}
Invoke-HarnessProcess $iscc ($arguments -join ' ') 'copy-failure-build'|Out-Null
$exe=Join-Path $OutRoot ($name+'.exe')
Write-HarnessResult $OutRoot 'fixture.json' @{path=$exe;size=(Get-HarnessItem $exe).Length;sha256=(Get-HarnessFileSha256 $exe);failureMode='After three copied files, silent only, executable destination is a directory';sourceScriptHash=(Get-HarnessFileSha256 $script)}|Out-Null
Complete-HarnessInvocation 'pass' -Cleanup|Out-Null
