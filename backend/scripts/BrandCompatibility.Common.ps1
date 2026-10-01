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

function Test-RooIndustriesDataRootMarked([string]$Root) {
    $key=Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    return $null -ne $key -and $null -ne $key.GetValue([IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant())
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
    for($directory=[IO.Path]::GetDirectoryName($full);$directory;$directory=[IO.Path]::GetDirectoryName($directory)){
        $name=$directory.TrimEnd('\').ToUpperInvariant()
        if($null -eq $key.GetValue($name)){continue}
        $at=$key.GetValue($name+'|protected-at')
        return ($null -ne $at) -and ((Get-Item -LiteralPath $full -Force).CreationTimeUtc.ToFileTimeUtc() -gt [int64]$at)
    }
    return $false
}

function Get-RooIndustriesLocalDataRoot {
    param([string]$LocalData=[Environment]::GetFolderPath('LocalApplicationData'),[switch]$Protected)
    $legacy=Join-Path $LocalData $script:RooIndustriesLegacyIdentity.dataFolder
    $current=Join-Path $LocalData 'RooIndustriesOptimizationSuite'
    $root=if((Test-Path -LiteralPath $legacy -PathType Container) -and -not ((Test-RooIndustriesDataRootMarked $current) -and -not (Test-RooIndustriesDataRootMarked $legacy))){$legacy}else{$current}
    if($Protected){Assert-RooIndustriesProtectedFolder $root}
    return $root
}

$script:RooIndustriesCodeLoadingVariables=@('DOTNET_STARTUP_HOOKS','DOTNET_ADDITIONAL_DEPS','DOTNET_SHARED_STORE','CORECLR_ENABLE_PROFILING','CORECLR_PROFILER','CORECLR_PROFILER_PATH','CORECLR_PROFILER_PATH_32','CORECLR_PROFILER_PATH_64','CORECLR_PROFILER_PATH_ARM64','COR_ENABLE_PROFILING','COR_PROFILER','COR_PROFILER_PATH','COR_PROFILER_PATH_32','COR_PROFILER_PATH_64')

function New-RooIndustriesElevatedTaskAction {
    param([Parameter(Mandatory=$true)][string]$Executable,[string]$Arguments='',[Parameter(Mandatory=$true)][string]$WorkingDirectory)
    $system=[Environment]::GetFolderPath('System')
    $clear=($script:RooIndustriesCodeLoadingVariables|ForEach-Object {'set '+$_+'='}) -join '&'
    $command='"'+$clear+'&"'+$Executable+'" '+$Arguments+'"'
    return New-ScheduledTaskAction -Execute (Join-Path $system 'conhost.exe') -Argument ('--headless "'+(Join-Path $system 'cmd.exe')+'" /d /s /c '+$command) -WorkingDirectory $WorkingDirectory
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
