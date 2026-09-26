#ifndef AppVersion
  #error Build the installer with tools\scripts\Build-Release.ps1
#endif

#define AppName "Roo Industries Optimization Suite"
#define AppExe "RooIndustries.OptimizationSuite.App.exe"

[Setup]
AppId={{746C4DD8-B7BA-48CD-9FFA-0C378F19368A}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Roo Industries
AppCopyright=Roo Industries
VersionInfoVersion={#AppNumericVersion}
VersionInfoProductVersion={#AppNumericVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup
DefaultDirName={autopf}\Roo Industries\Optimization Suite
DefaultGroupName=Roo Industries
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile={#SourceDir}\assets\brand\roo-industries\favicon.ico
UninstallDisplayIcon={app}\app\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[InstallDelete]
Type: filesandordirs; Name: "{app}\app"
Type: filesandordirs; Name: "{app}\backend\bin\optimizer"
Type: files; Name: "{app}\backend\bin\RooIndustriesProcessGovernor.exe"
Type: filesandordirs; Name: "{app}\backend\scripts"
Type: filesandordirs; Name: "{app}\backend\catalogs"
Type: filesandordirs; Name: "{app}\backend\native"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\app\{#AppExe}"; WorkingDir: "{app}\app"
Name: "{group}\Beta tester guide"; Filename: "{app}\README-BETA.txt"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\app\{#AppExe}"; WorkingDir: "{app}\app"; Tasks: desktopicon

[Run]
Filename: "{app}\README-BETA.txt"; Description: "Read the beta tester guide"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\app\{#AppExe}"; Description: "Open {#AppName}"; Flags: postinstall shellexec skipifsilent nowait unchecked

[UninstallDelete]
Type: files; Name: "{app}\backend\bin\RooIndustriesProcessGovernor.exe"
Type: dirifempty; Name: "{app}\backend\bin"
Type: dirifempty; Name: "{app}\backend"
Type: dirifempty; Name: "{app}"
Type: dirifempty; Name: "{autopf}\Roo Industries"
