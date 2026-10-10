param([string]$Scratch,[string]$Scenario,[string]$Common,[string]$Fixture)
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Utility,Microsoft.PowerShell.Management -ErrorAction Stop
[Reflection.Assembly]::LoadFrom($Fixture)|Out-Null
. $Common
Get-RooIndustriesDataRootMarkerName $Scratch|Out-Null
if($Scenario -eq 'empty-poison'){foreach($name in @('USERPROFILE','LOCALAPPDATA','APPDATA','HOMEDRIVE','HOMEPATH')){[Environment]::SetEnvironmentVariable($name,'')}}
if($Scenario -eq 'system-poison'){ [Environment]::SetEnvironmentVariable('SystemRoot','C:\RooIndustriesF10MissingWindows')}
[FolderFixture]::Begin($Scratch,$Scenario,'powershell')
$refused=$false;$message='';$local=$null;$roaming=$null;$root=$null;$temp=$null
try {
    . $Common
    $local=Get-RooIndustriesLocalAppData
    $roaming=Expand-RooIndustriesUserVariables '%APPDATA%'
    $temp=Expand-RooIndustriesUserVariables '%TEMP%'
    if($Scenario -like 'other-*'){
        $scriptFile=Join-Path (Split-Path $Common -Parent) 'Invoke-GovernorSetup.ps1'
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($scriptFile,[ref]$tokens,[ref]$errors)
        $names=@('Get-GovernorProblem','Test-GovernorAction','Test-GovernorPayload','Test-GovernorDotNet','Get-GovernorArguments','Resolve-PathText','Test-StartsWith','Get-Sid','Test-GovernorRootMarker','Get-RawRegistryValue','Get-UserLocalFolder')
        foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){if($node.Name -in $names){Invoke-Expression $node.Extent.Text}}
        $full=$true;$me=[FolderFixture]::Sid;$nativeSystem=[Environment]::SystemDirectory;$appRootPath=$Scratch;$systemDirectories=@([Environment]::SystemDirectory)
        $root=Join-Path ([FolderFixture]::Folders) ('other-root\'+$Scenario+'\process-rules')
        if($Scenario -in @('other-default','other-loaded','other-percent')){
            $profilePath=Join-Path ([FolderFixture]::Folders) $(if($Scenario -eq 'other-percent'){'other%profile'}else{'other-profile'});$data=Join-Path $profilePath 'AppData\Local';[IO.Directory]::CreateDirectory($data)|Out-Null
            if($Scenario -eq 'other-loaded'){$data=Join-Path ([FolderFixture]::Folders) 'other-loaded\Local';[IO.Directory]::CreateDirectory($data)|Out-Null}
            $profileKey=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+[FolderFixture]::OtherSid);$profileKey.SetValue('ProfileImagePath',$profilePath);$profileKey.Dispose()
            $userKey=[Microsoft.Win32.Registry]::Users.CreateSubKey([FolderFixture]::OtherSid+'\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders');$userKey.SetValue('Local AppData',$data);$userKey.Dispose()
            $root=Join-Path $data 'process-rules'
        }
        [FolderFixture]::Protect($root)
        $other=[FolderFixture]::OtherSid;$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots',$true)
        if($Scenario -notin @('other-unmarked','other-default','other-loaded','other-percent')){$key.SetValue((Get-RooIndustriesDataRootMarkerName $root),$(if($Scenario -eq 'other-mismatch'){$me}else{$other}))}
        $parts=@('Roo Industries process rules',$other,$root)
        $task=@{taskPath='\';taskName='RooIndustriesOptimizationSuite.ProcessRules.01234567890123456789';runLevel='Highest';userId=$(if($Scenario -eq 'other-principal'){$me}else{$other});actionCount=1;execute=($Scratch+'\backend\bin\optimizer\Optimizer.Host.exe');arguments=('policy-run "'+$root+'\worker-request.json"')}
        $taskLocal=if($Scenario -in @('other-default','other-loaded','other-percent')){(Get-UserLocalFolder $other)+'\'}else{''}
        $problem=Get-GovernorProblem $task $parts $root $taskLocal
        if($problem){throw $problem}
    }
    elseif($Scenario -eq 'short-path'){
        $owned=Join-Path $local 'RooIndustriesOptimizationSuite';[FolderFixture]::Protect($owned)
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots',$true);$key.SetValue((Get-RooIndustriesDataRootMarkerName $owned),[FolderFixture]::Sid)
        $root=Get-RooIndustriesLocalDataRoot -Protected
        if((Get-RooIndustriesDataRootMarkerName $root) -ne (Get-RooIndustriesDataRootMarkerName $owned)){throw 'Short marker differs'}
    }
    elseif($Scenario -eq 'redirect-protected'){
        $owned=Join-Path $local 'RooIndustriesOptimizationSuite';[FolderFixture]::Protect($owned)
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots',$true);$key.SetValue((Get-RooIndustriesDataRootMarkerName $owned),[FolderFixture]::Sid)
        $root=Get-RooIndustriesLocalDataRoot -Protected
    }
    elseif($Scenario -in @('protected-move','marker-missing','marker-damaged','marker-other-sid','marker-ambiguous')){$root=Get-RooIndustriesLocalDataRoot}else{$root=Get-RooIndustriesLocalDataRoot -LocalData (Join-Path ([FolderFixture]::Folders) 'redir\Local')}
} catch {$refused=$true;$message=$_.Exception.Message}
$expected=$Scenario -in @('install-root','short-system','reparse-parent','missing','relative','empty','unknown','unknown-absolute','system-poison','unc','dword','drive-root','windows','protected-move','marker-missing','marker-damaged','marker-other-sid','marker-ambiguous','other-mismatch','other-unmarked','other-principal')
$expectedMessage=if($Scenario -in @('protected-move','marker-ambiguous')){'folder setting changed'}elseif($Scenario -eq 'marker-missing'){'missing or damaged'}elseif($Scenario -eq 'marker-damaged'){'not protected'}elseif($Scenario -eq 'marker-other-sid'){'marker belongs'}elseif($Scenario -in @('other-mismatch','other-unmarked')){'outside the profile'}elseif($Scenario -eq 'other-principal'){'does not run as the user'}else{'AppData folder settings'}
$kept=$Scenario -ne 'protected-move' -or (-not [IO.Directory]::Exists((Join-Path ([FolderFixture]::Local) 'RooIndustriesOptimizationSuite')) -and [IO.File]::ReadAllText((Join-Path ([FolderFixture]::Folders) 'old\Local\RooIndustriesOptimizationSuite\keep.txt')) -eq 'Keep original protected data')
$passed=$kept -and ($refused -eq $expected) -and (-not $refused -or $message.Contains($expectedMessage)) -and ($refused -or ($local -eq [FolderFixture]::Local -and $roaming -eq [FolderFixture]::Roaming -and $temp -eq (Join-Path ([FolderFixture]::Profile) 'AppData\Local\Temp')))
$fallback=$null;$fallbackPassed=$null
if($Scenario -in @('single-percent','single-percent-expand','unknown-absolute')){
    $scriptFile=Join-Path (Split-Path $Common -Parent) 'Invoke-GovernorSetup.ps1'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($scriptFile,[ref]$tokens,[ref]$errors)
    $names=@('Get-UserLocalFolder','Get-RawRegistryValue','Resolve-PathText','Test-StartsWith')
    foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){if($node.Name -in $names){Invoke-Expression $node.Extent.Text}}
    $nativeSystem=[Environment]::SystemDirectory;$full=$false;$AppRoot=$Scratch
    $reg=Join-Path $nativeSystem 'reg.exe'
    Set-Item -LiteralPath ('Function:\'+$reg) -Value {
        param([string]$Verb,[string]$Key,[string]$Flag,[string]$Name)
        $mapped=$Key.Replace('HKLM\','Registry::HKEY_LOCAL_MACHINE\').Replace('HKU\','Registry::HKEY_USERS\')
        $item=Get-Item -LiteralPath $mapped -ErrorAction SilentlyContinue
        $global:LASTEXITCODE=1
        if(-not $item){return}
        if(-not $Name){$global:LASTEXITCODE=0;return $Key}
        $value=$item.GetValue($Name,$null,'DoNotExpandEnvironmentNames')
        if($null -eq $value){return}
        $kind=if($item.GetValueKind($Name) -eq 'ExpandString'){'REG_EXPAND_SZ'}else{'REG_SZ'}
        $global:LASTEXITCODE=0
        return ('    '+$Name+'    '+$kind+'    '+$value)
    }
    try {$fallback=Get-UserLocalFolder ([FolderFixture]::Sid)}finally{Remove-Item -LiteralPath ('Function:\'+$reg)}
    $fallbackPassed=if($expected){-not $fallback}else{$fallback -eq [FolderFixture]::Local}
    $passed=$passed -and $fallbackPassed
}
$row=@{poisonAfterStartup=($Scenario -in @('empty-poison','system-poison'));host='powershell';scenario=$Scenario;localAppData=$local;roamingAppData=$roaming;profile=[FolderFixture]::Profile;dataRoot=$root;temp=$temp;refused=$refused;message=$message;kept=$kept;fallbackLocal=$fallback;fallbackPassed=$fallbackPassed;passed=$passed}
[FolderFixture]::End()
if($Scenario -eq 'system-poison'){[Environment]::SetEnvironmentVariable('SystemRoot',[Environment]::GetFolderPath('Windows'))}
$row|ConvertTo-Json -Compress
if(-not $passed){exit 1}
