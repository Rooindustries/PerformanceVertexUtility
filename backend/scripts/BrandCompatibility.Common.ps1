$script:RooIndustriesLegacyIdentity = @{
    policyTask = 'RooOptimizationSuite.ProcessRules.'
    policyDescription = 'Roo process rules | '
    gameTask = 'Roo Protected Session '
    gameDescription = 'Roo protected game session | '
    dataFolder = 'RooOptimizationSuite'
}

function Find-RooIndustriesCompatibleTask {
    param([string]$Name,[string]$LegacyName,[string]$Description,[string]$LegacyDescription)
    $found=@(Get-ScheduledTask -TaskName $Name,$LegacyName -ErrorAction SilentlyContinue)
    if($found.Count -gt 1){throw 'Both current and legacy worker tasks exist. Stop and reconcile the existing workers before starting another.'}
    if($found.Count -eq 0){return $null}
    $task=$found[0]
    $expected=if($task.TaskName -ceq $Name){$Description}else{$LegacyDescription}
    if($task.Description -cne $expected){throw 'The worker task belongs to another user or state folder.'}
    return $task
}

function Get-RooIndustriesDataRootMarkerName([string]$Path) {
    if(-not ('RooIndustries.LongPathName' -as [type])){Add-Type -Namespace RooIndustries -Name LongPathName -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", EntryPoint = "GetLongPathNameW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] public static extern uint Expand(string shortPath, System.Text.StringBuilder longPath, uint length);'}
    $existing=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if($existing -match '^[A-Za-z]:$'){return $existing.ToUpperInvariant()}
    $rest=''
    while(-not [IO.Directory]::Exists($existing)){
        $parent=[IO.Path]::GetDirectoryName($existing)
        if(-not $parent){break}
        $rest=[IO.Path]::Combine([IO.Path]::GetFileName($existing),$rest)
        $existing=$parent
    }
    $buffer=New-Object System.Text.StringBuilder 1024
    $length=[RooIndustries.LongPathName]::Expand($existing,$buffer,1024)
    $long=if($length -eq 0 -or $length -ge 1024){$existing}else{$buffer.ToString()}
    return [IO.Path]::GetFullPath($(if($rest.Length -eq 0){$long}else{[IO.Path]::Combine($long,$rest)})).TrimEnd('\').ToUpperInvariant()
}

function Test-RooIndustriesDataRootMarked([string]$Root) {
    $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    return $null -ne $key -and $key.GetValue((Get-RooIndustriesDataRootMarkerName $Root),$null,'DoNotExpandEnvironmentNames') -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Assert-RooIndustriesProtectedFolder([string]$Path) {
    if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){return}
    $trusted=@('S-1-5-32-544','S-1-5-18')
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $problem=if(-not $item -or -not $item.PSIsContainer){'missing'}elseif($item.Attributes -band [IO.FileAttributes]::ReparsePoint){'it is a link'}else{
        $acl=$item.GetAccessControl()
        if(-not $acl.AreAccessRulesProtected){'it inherits permissions'}
        elseif($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value){'it is not owned by Administrators'}
        elseif(@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq 'S-1-3-4'}).Count -eq 0){'it does not limit owner rights'}
        elseif(-not (Test-RooIndustriesDataRootMarked $Path)){'the app never protected it'}
        else{
            $writers=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.AccessControlType -eq 'Allow' -and $trusted -notcontains $_.IdentityReference.Value -and (([int64]$_.FileSystemRights -band 0x500D0156) -ne 0)})
            if($writers.Count -gt 0){$writers[0].IdentityReference.Value+' can change it'}else{''}
        }
    }
    if($problem){throw ("The app's data folder is not protected ("+$problem+"). Open the app as an administrator, then try again.")}
}

function Test-RooIndustriesWrittenAfterProtection([string]$Path) {
    $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    if(-not $key -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    $full=[IO.Path]::GetFullPath($Path)
    $latest=$null
    for($directory=[IO.Path]::GetDirectoryName($full);$directory;$directory=[IO.Path]::GetDirectoryName($directory)){
        $name=Get-RooIndustriesDataRootMarkerName $directory
        if($null -eq $key.GetValue($name)){continue}
        $at=$key.GetValue($name+'|protected-at')
        if($null -eq $at){return $false}
        if($null -eq $latest -or [int64]$at -gt $latest){$latest=[int64]$at}
    }
    return ($null -ne $latest) -and ((Get-Item -LiteralPath $full -Force).CreationTimeUtc.ToFileTimeUtc() -gt $latest)
}

function Get-RooIndustriesUserFolder {
    param([switch]$Roaming,[string]$Sid=([Security.Principal.WindowsIdentity]::GetCurrent().User.Value),[string]$Profile=([Environment]::GetFolderPath('UserProfile')))
    $problem="Roo Industries could not use this Windows user's AppData folder settings. Choose an existing local folder on a fixed drive outside Windows and the app's install folder."
    if($Profile -notmatch '^[A-Za-z]:\\' -or -not [IO.Directory]::Exists($Profile)){throw $problem}
    $hive=Get-Item -LiteralPath ('Registry::HKEY_USERS\'+$Sid) -ErrorAction SilentlyContinue
    if(-not $hive){throw "Roo Industries could not read that Windows user's folder settings."}
    $key=Get-Item -LiteralPath ('Registry::HKEY_USERS\'+$Sid+'\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders') -ErrorAction SilentlyContinue
    $name=if($Roaming){'AppData'}else{'Local AppData'}
    $raw=if($key){$key.GetValue($name,$null,'DoNotExpandEnvironmentNames')}else{$null}
    if($null -eq $raw){$path=[IO.Path]::Combine($Profile,'AppData',$(if($Roaming){'Roaming'}else{'Local'}))}
    else {
        if($raw -isnot [string] -or $key.GetValueKind($name) -notin @('String','ExpandString')){throw $problem}
        $path=[regex]::Replace($raw,'%USERPROFILE%',[Text.RegularExpressions.MatchEvaluator]{param($match) $Profile},[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if(-not $path -or $path -match '%.*%|[<>"|?*\x00-\x1F]' -or $path.StartsWith('\\?\') -or $path.StartsWith('\\.\')){throw $problem}
    if($Roaming -and $path.StartsWith('\\')){
        $parts=@($path.Substring(2).TrimEnd('\') -split '\\')
        if($parts.Count -lt 2 -or @($parts|Where-Object {-not $_ -or $_ -in @('.','..') -or $_.Contains(':')}).Count){throw $problem}
        return $path.TrimEnd('\')
    }
    if($path -notmatch '^[A-Za-z]:\\.+' -or $path.Substring(3).Contains(':') -or $path.TrimEnd('\').Substring(3) -match '(^|\\)\.{1,2}(\\|$)|\\{2}|[. ](\\|$)'){throw $problem}
    $path=[IO.Path]::GetFullPath($path).TrimEnd('\')
    if(-not $Roaming){
        if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($path))).DriveType -ne 'Fixed' -or -not [IO.Directory]::Exists($path)){throw $problem}
        for($directory=[IO.DirectoryInfo]::new($path);$null -ne $directory;$directory=$directory.Parent){if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw $problem}}
        foreach($blocked in @([Environment]::GetFolderPath('Windows'),[Environment]::GetFolderPath('ProgramFiles'),[Environment]::GetFolderPath('ProgramFilesX86'),(Split-Path (Split-Path $script:RooIndustriesScriptsRoot -Parent) -Parent))){
            if($blocked){$blocked=[IO.Path]::GetFullPath($blocked)}
            if($blocked -and ($path -ieq $blocked.TrimEnd('\') -or $path.StartsWith($blocked.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){throw $problem}
        }
    }
    return $path
}

function Get-RooIndustriesLocalAppData {return Get-RooIndustriesUserFolder}
function Get-RooIndustriesRoamingAppData {return Get-RooIndustriesUserFolder -Roaming}

function Expand-RooIndustriesUserVariables([string]$Text) {
    $profile=[Environment]::GetFolderPath('UserProfile')
    $values=@{USERPROFILE=$profile;LOCALAPPDATA=(Get-RooIndustriesLocalAppData);APPDATA=(Get-RooIndustriesRoamingAppData);TEMP=([IO.Path]::Combine($profile,'AppData','Local','Temp'));TMP=([IO.Path]::Combine($profile,'AppData','Local','Temp'));SystemRoot=([Environment]::GetFolderPath('Windows'));windir=([Environment]::GetFolderPath('Windows'));SystemDrive=([IO.Path]::GetPathRoot([Environment]::GetFolderPath('Windows')).TrimEnd('\'));ProgramFiles=([Environment]::GetFolderPath('ProgramFiles'));'ProgramFiles(x86)'=([Environment]::GetFolderPath('ProgramFilesX86'));ProgramData=([Environment]::GetFolderPath('CommonApplicationData'))}
    return [regex]::Replace($Text,'%([^%]+)%',[Text.RegularExpressions.MatchEvaluator]{param($match) if($values.ContainsKey($match.Groups[1].Value)){$values[$match.Groups[1].Value]}else{$match.Value}})
}

function Get-RooIndustriesLocalDataRoot {
    param([string]$LocalData=(Get-RooIndustriesLocalAppData),[switch]$Protected)
    if(-not $PSBoundParameters.ContainsKey('LocalData')){
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
        $roots=@(if($key){$key.GetValueNames()|Where-Object {-not $_.Contains('|') -and (Split-Path $_ -Leaf) -in @('RooOptimizationSuite','RooIndustriesOptimizationSuite') -and $key.GetValue($_,$null,'DoNotExpandEnvironmentNames') -eq $sid}})
        foreach($leaf in @('RooOptimizationSuite','RooIndustriesOptimizationSuite')){
            $owner=if($key){$key.GetValue((Get-RooIndustriesDataRootMarkerName (Join-Path $LocalData $leaf)),$null,'DoNotExpandEnvironmentNames')}else{$null}
            if($null -ne $owner -and $owner -cne $sid){throw 'The protected data folder marker belongs to another Windows user.'}
        }
        $parent=Get-RooIndustriesDataRootMarkerName $LocalData
        foreach($marked in $roots){
            if((Get-RooIndustriesDataRootMarkerName (Split-Path $marked -Parent)) -ine $parent){throw "This Windows user's AppData folder setting changed or names several protected folders. Roo Industries kept the existing data. Restore the folder setting before opening the app again."}
            if(-not (Test-Path -LiteralPath $marked -PathType Container)){throw 'Roo Industries kept the existing protected data folder because it is missing or damaged. Restore that folder before opening the app again.'}
            Assert-RooIndustriesProtectedFolder $marked
        }
    }
    $legacy=Join-Path $LocalData $script:RooIndustriesLegacyIdentity.dataFolder
    $current=Join-Path $LocalData 'RooIndustriesOptimizationSuite'
    $root=if((Test-Path -LiteralPath $legacy -PathType Container) -and -not ((Test-RooIndustriesDataRootMarked $current) -and -not (Test-RooIndustriesDataRootMarked $legacy))){$legacy}else{$current}
    if($Protected){Assert-RooIndustriesProtectedFolder $root}
    return $root
}

$script:RooIndustriesClearedPrefixes=@('DOTNET_','COMPlus_','CORECLR_','COR_','COREHOST_')
$script:RooIndustriesPinnedVariables=@('DOTNET_EnableDiagnostics','COMPlus_EnableDiagnostics','DOTNET_EnableDiagnostics_IPC','COMPlus_EnableDiagnostics_IPC','DOTNET_EnableDiagnostics_Debugger','COMPlus_EnableDiagnostics_Debugger','DOTNET_EnableDiagnostics_Profiler','COMPlus_EnableDiagnostics_Profiler')

$script:RooIndustriesScriptsRoot=$PSScriptRoot

function Get-RooIndustriesLaunchProblem([string]$Text,[switch]$Bare) {
    if([string]::IsNullOrEmpty($Text)){return 'is empty'}
    if($Text -match '["?^*<>|\r\n]'){return 'contains a character that cannot be passed to the clean launcher'}
    if($Bare -and $Text -match '[&(),;=!%]'){return 'contains a character that needs quoting, but has no space for the console host to quote it by'}
    return $null
}

function New-RooIndustriesElevatedTaskAction {
    param([Parameter(Mandatory=$true)][string]$Executable,[string[]]$ArgumentList=@(),[Parameter(Mandatory=$true)][string]$WorkingDirectory)
    $system=[Environment]::GetFolderPath('System')
    $windows=[Environment]::GetFolderPath('Windows')
    if($null -ne ($problem=Get-RooIndustriesLaunchProblem $windows -Bare:(-not $windows.Contains(' ')))){throw ('Cannot register the elevated task because the Windows folder '+$problem+'.')}
    $launcher=Join-Path $script:RooIndustriesScriptsRoot 'Start-RooIndustriesHelper.cmd'
    if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw 'Roo Industries files are missing or damaged. Install the app again.'}
    $parts=@($Executable)+@($ArgumentList)
    if($parts.Count -gt 4){throw 'The clean launcher starts a program with at most three arguments.'}
    foreach($part in $parts){if($null -ne ($problem=Get-RooIndustriesLaunchProblem $part)){throw ('Cannot register the elevated task because "'+$part+'" '+$problem+'.')}}
    if($null -ne ($problem=Get-RooIndustriesLaunchProblem $launcher -Bare:(-not $launcher.Contains(' ')))){throw ('Cannot register the elevated task because the install folder "'+$launcher+'" '+$problem+'.')}
    if(([regex]::Matches($windows+$launcher+($parts -join ''),'%')).Count -gt 1){throw 'Cannot register the elevated task because its paths contain more than one % character, which the command interpreter could expand later.'}
    $payload=' ?'+($parts -join '?')
    return New-ScheduledTaskAction -Execute (Join-Path $system 'conhost.exe') -Argument ('--headless "'+(Join-Path $system 'cmd.exe')+'" /d /e:on /v:off /c set "SystemRoot='+$windows+'"&call "'+$launcher+'" "'+$payload+'"') -WorkingDirectory $WorkingDirectory
}

function Get-RooIndustriesDevelopmentDotNet {
    param([Parameter(Mandatory=$true)][string]$HostDirectory)
    $options=$null
    try {$options=(Get-Content -LiteralPath (Join-Path $HostDirectory 'Optimizer.Host.runtimeconfig.json') -Raw -ErrorAction Stop|ConvertFrom-Json).runtimeOptions} catch {}
    if(-not $options -or (-not $options.framework -and -not $options.frameworks)){throw 'Roo Industries files are missing or damaged. Install the app again.'}
    $candidate=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
    if(Test-Path -LiteralPath $candidate){return $candidate}
    return (Get-Command dotnet.exe -ErrorAction Stop).Source
}
