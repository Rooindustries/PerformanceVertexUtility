param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutDir|Out-Null
$work=Join-Path $OutDir ('fixture-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
$rows=[Collections.Generic.List[object]]::new()
function Check([bool]$Passed,[string]$Name,[string]$Detail=''){$rows.Add(@{passed=$Passed;check=$Name;detail=$Detail});$(if($Passed){'PASS '}else{'FAIL '})+$Name}
function Compile([string]$Script,[string]$OutputName){
    $arguments=@('/Q','/DAppVersion=0.10.0-beta','/DAppNumericVersion=0.10.0.0',('/DGovernorSetupHash='+$setupHash),('/DGovernorSetupCommonHash='+$commonHash),('/DSourceDir='+$stage),('/DOutputDir='+$work),('/DOutputName='+$OutputName),$Script)
    $text=(& $iscc @arguments 2>&1|Out-String);$code=$LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $OutDir ($OutputName+'-compile.log')),$text,[Text.UTF8Encoding]::new($false))
    Check ($code -eq 0 -and $text -notmatch '(?im)^Error') ($OutputName+' compiles with the real Inno compiler and zero errors') $text
    if($code -ne 0){throw 'The compiled setup proof failed to build'}
}
try {
    $iscc=@((Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'))|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
    if(-not$iscc){throw 'Inno Setup 6 was not found'}
    [IO.File]::WriteAllText((Join-Path $OutDir 'compiler.txt'),$iscc+"`n"+(Get-Item -LiteralPath $iscc).VersionInfo.FileVersion)
    $folders=Join-Path $work 'folders';New-Item -ItemType Directory -Path $folders|Out-Null
    'private setup AppData fixture'|Set-Content -LiteralPath (Join-Path $work 'fixture-owner.txt')
    $folders|Set-Content -LiteralPath (Join-Path $work 'fixture-folders.txt')
    New-Item -ItemType Directory -Path (Join-Path $folders 'redir\Local'),(Join-Path $folders 'redir\Roaming')|Out-Null
    Add-Type -Path (Join-Path $Source 'tools\validation\RedirectedFolders\Fixture.cs')
    $stage=Join-Path $work 'payload';New-Item -ItemType Directory -Path (Join-Path $stage 'backend\scripts'),(Join-Path $stage 'assets\brand\roo-industries')|Out-Null
    Copy-Item -LiteralPath (Join-Path $Source 'assets\brand\roo-industries\favicon.ico') -Destination (Join-Path $stage 'assets\brand\roo-industries\favicon.ico')
    Copy-Item -LiteralPath (Join-Path $Source 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt')
    [IO.File]::WriteAllText((Join-Path $stage 'proof-payload.txt'),'replacement payload')
    $recorder=@'
param([string]$Action)
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'),$Action+"`r`n")
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $stage 'backend\scripts\Invoke-GovernorSetup.ps1'),$recorder)

    [IO.File]::WriteAllText((Join-Path $stage 'backend\scripts\BrandCompatibility.Common.ps1'),'private Inno action recorder')
    $setupHash=(Get-FileHash (Join-Path $stage 'backend\scripts\Invoke-GovernorSetup.ps1')).Hash
    $commonHash=(Get-FileHash (Join-Path $stage 'backend\scripts\BrandCompatibility.Common.ps1')).Hash
    $installerPath=Join-Path $Source 'tools\release\RooIndustries.OptimizationSuite.iss'
    $helperPath=Join-Path $Source 'tools\release\SetupProcess.iss'
    $installer=[IO.File]::ReadAllText($installerPath);$helper=[IO.File]::ReadAllText($helperPath)
    Compile $installerPath 'ProductInstallerCompileOnly'
    $code=$installer.Substring($installer.IndexOf('[Code]')+6)
    $code=$code.Replace('function InitializeSetup(): Boolean;','function ProductInitializeSetup(): Boolean;').Replace('procedure DeinitializeSetup();','procedure ProductDeinitializeSetup();')
    $code=$code.Replace('#include "SetupProcess.iss"',('#include "'+$helperPath+'"'))
    $prepareStart=$code.IndexOf('function PrepareToInstall(var NeedsRestart: Boolean): String;')
    $prepareEnd=$code.IndexOf('procedure CurStepChanged(', $prepareStart)
    $prepare=$code.Substring($prepareStart,$prepareEnd-$prepareStart)
    $prepare=[regex]::Replace($prepare,'(?m)^(\s*)Result := ([^\r\n]+);','$0'+"`n"+'$1ProofResult := Result;')
    $prepare=$prepare.Replace('    exit;','    ProofReturned := True;'+"`n"+'    exit;')
    $prepare=[regex]::Replace($prepare,'\r?\nend;\s*$',"`n"+'  ProofReturned := True;'+"`n"+'end;'+"`n")
    $code=$code.Substring(0,$prepareStart)+$prepare+$code.Substring($prepareEnd)
    $code=$code.Replace('#include "'+$helperPath+'"','#include "'+$helperPath+'"'+"`n"+'var ProofResult: String; ProofReturned: Boolean;')
    $wrapper=@'
var
  ProofWork: String;
  ProofFixtureKey, ProofUserKey: THandle;
function ProofLoad(Path: String; var Key: THandle; Access, Options, Reserved: DWORD): Longint; external 'RegLoadAppKeyW@advapi32.dll stdcall';
function ProofOpen(Key: THandle; Sub: String; Options, Access: DWORD; var ResultKey: THandle): Longint; external 'RegOpenKeyExW@advapi32.dll stdcall';
function ProofOverride(Key, NewKey: THandle): Longint; external 'RegOverridePredefKey@advapi32.dll stdcall';
function ProofClose(Key: THandle): Longint; external 'RegCloseKey@advapi32.dll stdcall';
function InitializeSetup(): Boolean;
begin
  ProofWork := ExpandConstant('{param:proofwork}');
  if (ProofWork = '') or (CompareText(ExpandConstant('{param:DIR}'), ProofWork + '\app') <> 0) then RaiseException('Proof install path differs');
  if ProofLoad(ExpandConstant('{param:proofhive}'), ProofFixtureKey, $F003F, 0, 0) <> 0 then RaiseException('Proof hive failed');
  if ProofOpen(ProofFixtureKey, ExpandConstant('{param:proofsid}'), 0, $F003F, ProofUserKey) <> 0 then RaiseException('Proof SID failed');
  if ProofOverride(HKCU, ProofUserKey) <> 0 then RaiseException('Proof override failed');
  Result := ProductInitializeSetup();
end;
procedure DeinitializeSetup();
var
  Calls: AnsiString;
begin
  SaveStringToFile(ProofWork + '\prepare.txt', 'returned=' + IntToStr(Ord(ProofReturned)) + #13#10 + 'result=' + ProofResult + #13#10 + 'suspended=' + IntToStr(Ord(GovernorSuspended)) + #13#10 + 'refusal=' + SetupFolderRefusal, False);
  if SetupFolder <> '' then
  begin
    LoadStringFromFile(SetupFolder + '\calls.txt', Calls);
    SaveStringToFile(ProofWork + '\calls.txt', String(Calls), False);
  end;
  ProductDeinitializeSetup();
  ProofOverride(HKCU, 0);
  ProofClose(ProofUserKey);
  ProofClose(ProofFixtureKey);
end;
'@
    if(-not$helper.Contains('SetupFolderRefusal')){$wrapper='var SetupFolderRefusal: String;'+"`n"+$wrapper}
    $fixture=@"
#define AppName "Roo Industries setup event proof"
#define AppExe "RooIndustries.OptimizationSuite.App.exe"
[Setup]
AppId={{7EA5E869-74C9-4947-9A3D-F7756C407C71}
AppName={#AppName}
AppVersion=0
DefaultDirName={tmp}\unused-proof
Uninstallable=no
PrivilegesRequired=admin
DisableProgramGroupPage=yes
DisableDirPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=SetupEventProof
[Files]
Source: "{#SourceDir}\backend\scripts\Invoke-GovernorSetup.ps1"; Flags: dontcopy
Source: "{#SourceDir}\backend\scripts\BrandCompatibility.Common.ps1"; Flags: dontcopy
Source: "{#SourceDir}\proof-payload.txt"; DestDir: "{app}"; Flags: ignoreversion
[Code]
$code
$wrapper
"@
    $fixturePath=Join-Path $work 'SetupEventProof.iss';[IO.File]::WriteAllText($fixturePath,$fixture,[Text.UTF8Encoding]::new($false))
    Compile $fixturePath 'SetupEventProof'
    foreach($case in @('reparse-parent','unc','valid')){
        try{[FolderFixture]::Begin($work,$(if($case -eq 'valid'){'redirect-string'}else{$case}),'setup');$sid=[FolderFixture]::Sid}finally{[FolderFixture]::End()}
        $hive=Join-Path $work ($(if($case -eq 'valid'){'redirect-string'}else{$case})+'-setup-users.hive')
        $caseRoot=Join-Path $work $case;$app=Join-Path $caseRoot 'app';New-Item -ItemType Directory -Path $app|Out-Null
        $file=Join-Path $app 'proof-payload.txt';[IO.File]::WriteAllText($file,'original payload')
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $work 'SetupEventProof.exe'),('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="'+$app+'" /proofwork="'+$caseRoot+'" /proofhive="'+$hive+'" /proofsid='+$sid+' /LOG="'+(Join-Path $OutDir ($case+'-inno.log'))+'"'))
        $start.UseShellExecute=$false;$child=[Diagnostics.Process]::Start($start)
        try{if(-not$child.WaitForExit(30000)){$child.Kill();throw 'The native setup event proof timed out'};$exit=$child.ExitCode}finally{$child.Dispose()}
        $report=[IO.File]::ReadAllText((Join-Path $caseRoot 'prepare.txt'));$calls=[IO.File]::ReadAllText((Join-Path $caseRoot 'calls.txt'));$payload=[IO.File]::ReadAllText($file)
        [IO.File]::WriteAllText((Join-Path $OutDir ($case+'-report.txt')),$report+"`nexit="+$exit+"`ncalls="+$calls+"`npayload="+$payload,[Text.UTF8Encoding]::new($false))
        if($case -eq 'valid'){
            Check ($exit -eq 0 -and $report -match '(?m)^returned=1' -and $report -match '(?m)^result=\r?$' -and $report -match '(?m)^suspended=1' -and $calls -match '(?m)^Suspend\r?$') 'Valid AppData reaches the real Suspend and marks GovernorSuspended' $report
            Check ($payload -ceq 'replacement payload' -and $calls -match '(?m)^Resume\r?$') 'Valid AppData installs the fixture payload and resumes after install' $calls
        }else{
            Check ($exit -ne 0 -and $report -match '(?m)^returned=1' -and $report -match "(?m)^result=The app needs this Windows user's AppData folder.* No files were changed\.") ($case+' PrepareToInstall returns the refusal and stops installation') $report
            Check ($payload -ceq 'original payload' -and $report -match '(?m)^suspended=0' -and $calls -eq '') ($case+' keeps the existing file and never suspends or resumes') ($payload+' '+$calls)
        }
    }
} finally {
    [FolderFixture]::End()
    $rows|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
Check (-not(Test-Path -LiteralPath $work)) 'The compiled private installer and hive fixtures are removed'
$rows|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
if(@($rows|Where-Object {-not $_.passed}).Count){exit 1}
