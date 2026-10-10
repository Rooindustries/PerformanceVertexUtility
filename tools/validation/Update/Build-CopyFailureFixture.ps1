param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Stage,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$text=[IO.File]::ReadAllText((Join-Path $Source 'tools\release\RooIndustries.OptimizationSuite.iss'))
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
[IO.File]::WriteAllText($script,$text,$utf8)
Copy-Item (Join-Path $Source 'tools\release\SetupProcess.iss') $OutRoot
$iscc=Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe';if(-not(Test-Path $iscc)){$iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'}
$hash=(Get-FileHash (Join-Path $Stage 'backend\scripts\Invoke-GovernorSetup.ps1')).Hash
$commonHash=(Get-FileHash (Join-Path $Stage 'backend\scripts\BrandCompatibility.Common.ps1')).Hash
& $iscc /Q '/DAppVersion=0.11.1-beta' '/DAppNumericVersion=0.11.1.0' ('/DGovernorSetupHash='+$hash) ('/DGovernorSetupCommonHash='+$commonHash) ('/DSourceDir='+$Stage) ('/DOutputDir='+$OutRoot) '/DOutputName=RooIndustries-OptimizationSuite-0.11.1-beta-setup' $script
if($LASTEXITCODE -ne 0){throw 'Copy-failure fixture compilation failed'}
$exe=Join-Path $OutRoot 'RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe'
@{path=$exe;size=(Get-Item $exe).Length;sha256=(Get-FileHash $exe).Hash;failureMode='After three copied files, silent only, executable destination is a directory';sourceScriptHash=(Get-FileHash $script).Hash}|ConvertTo-Json|Set-Content (Join-Path $OutRoot 'fixture.json')
