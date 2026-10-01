param([string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent } else { Join-Path ([IO.Path]::GetTempPath()) 'roo-industries-governor-ui2' }
$dotnet = if ($DotNetPath) { $DotNetPath } else { Join-Path $env:USERPROFILE '.dotnet\dotnet.exe' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    'SKIP governor task checks: the real governor registration needs an administrator shell'
    return
}
$project = Join-Path $root 'tools\validation\AppSweepUi\AppSweepUi.csproj'
& $dotnet build $project --configuration Release -nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'AppSweepUi build failed' }

$scripts = Join-Path $root 'backend\scripts'
. (Join-Path $scripts 'BrandCompatibility.Common.ps1')
. (Join-Path $scripts 'OperationState.Common.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-governor-task-' + [guid]::NewGuid().ToString('N'))
$PolicyRoot = [IO.Path]::GetFullPath((Join-Path $scratch 'process-rules'))
[IO.Directory]::CreateDirectory($PolicyRoot) | Out-Null
$owner = [pscustomobject]@{ userSid = $identity.User.Value }
$worker = Get-Content -Raw -LiteralPath (Join-Path $scripts 'Invoke-ProcessPolicyWorker.ps1')
function Get-Code([string]$Pattern, [string]$Label) {
    $code = [regex]::Match($worker, $Pattern).Value
    if (-not $code) { throw "The governor $Label code was not found in Invoke-ProcessPolicyWorker.ps1" }
    return $code
}
Invoke-Expression (Get-Code '(?ms)^\$hash=\[Security\.Cryptography\.SHA256\]::Create\(\).*?^\$taskName=[^\r\n]*' 'task naming')
Invoke-Expression (Get-Code '(?m)^\$description=[^\r\n]*' 'task description')
Invoke-Expression (Get-Code '(?ms)^function Register-Governor.*?^}' 'registration')
$currentName = $taskName
$currentDescription = $description
$legacyName = $script:RooIndustriesLegacyIdentity.policyTask + $suffix
$legacyDescription = $script:RooIndustriesLegacyIdentity.policyDescription + $owner.userSid + ' | ' + $PolicyRoot
$strayName = 'RooIndustriesOptimizationSuite.ProcessRules.FFFFFFFFFFFFFFFFFFFF'
$repoRoot = $root
$requestPath = Join-Path $PolicyRoot 'worker-request.json'
$HostDirectory = $scratch
$DotNetPath = Join-Path ([Environment]::GetFolderPath('System')) 'whoami.exe'
$hostArgs = @()

function Read-Task([string]$Name, [string]$Registered, [string]$Enabled, [string]$Repeats) {
    & $dotnet run --no-build --project $project --configuration Release -- governor-task $PolicyRoot $Name $Registered $Enabled $Repeats
    if ($LASTEXITCODE -ne 0) { throw "Task read check failed for $Name registered=$Registered enabled=$Enabled repeats=$Repeats" }
}
function Register-As([string]$Name, [string]$Text, [switch]$Disabled) {
    $script:taskName = $Name
    $script:description = $Text
    Register-Governor -Disabled:$Disabled
}
function Remove-Task([string]$Name) {
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $Name -Confirm:$false }
}

try {
    Read-Task $currentName False False False
    Register-As $currentName $currentDescription
    Read-Task $currentName True True True
    Register-As $currentName $currentDescription -Disabled
    Read-Task $currentName True False True
    $action = (Get-ScheduledTask -TaskName $currentName).Actions
    $principal = New-ScheduledTaskPrincipal -UserId $owner.userSid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $owner.userSid
    $logon.Repetition = (New-ScheduledTaskTrigger -Once -At ([DateTime]::Now) -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition
    Register-ScheduledTask -TaskName $currentName -Description $currentDescription -Action $action -Principal $principal -Settings $settings -Trigger @($logon) -Force | Out-Null
    Read-Task $currentName True True False
    Remove-Task $currentName

    Register-As $legacyName $legacyDescription
    Read-Task $legacyName True True True
    Register-As $currentName $currentDescription
    Read-Task $currentName Unknown False False
    Remove-Task $currentName
    Remove-Task $legacyName

    Register-As $strayName $currentDescription
    Read-Task $strayName True True True
    Register-As $strayName 'Roo Industries process rules | another owner'
    Read-Task $currentName False False False
    Remove-Task $strayName
    Read-Task $currentName False False False
    'Governor task checks passed for ' + $currentName
}
finally {
    Remove-Task $currentName
    Remove-Task $legacyName
    Remove-Task $strayName
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
