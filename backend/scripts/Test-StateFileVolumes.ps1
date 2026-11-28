param([string]$DotNetPath = $env:ROO_INDUSTRIES_DOTNET_EXE)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
if ([string]::IsNullOrWhiteSpace($DotNetPath)) { $DotNetPath = (Get-Command dotnet.exe -ErrorAction Stop).Source }
$env:DOTNET_ROOT = Split-Path $DotNetPath -Parent
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$project = Join-Path $repo 'tools\validation\OptimizerCore\OptimizerCore.csproj'
$root = Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-state-volumes-' + [Guid]::NewGuid().ToString('N'))
$failures = 0
$disks = New-Object System.Collections.Generic.List[string]
$share = $null
function Check([bool]$Ok, [string]$Message) {
    if ($Ok) { Write-Output "PASS $Message" } else { $script:failures++; Write-Output "FAIL $Message" }
}
function Security([string]$Path) { (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm('Owner,Access') }
function Invoke-DiskPart([string[]]$Lines) {
    $script = Join-Path $root ('diskpart-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($script, $Lines)
    $output = diskpart /s $script
    if ($LASTEXITCODE) { throw ('diskpart failed: ' + ($output -join ' ')) }
}
function Mount-Volume([string]$FileSystem) {
    $vhd = Join-Path $root ($FileSystem + '.vhdx')
    $letter = [char[]](70..90) | Where-Object { -not (Test-Path ([string]$_ + ':\')) } | Select-Object -First 1
    $disks.Add($vhd) | Out-Null
    $create = 'create vdisk file="' + $vhd + '" maximum=256 type=expandable'
    $format = 'format fs=' + $FileSystem + ' quick label=pvustate'
    $select = 'select vdisk file="' + $vhd + '"'
    Invoke-DiskPart @($create, $select, 'attach vdisk', 'create partition primary', $format, "assign letter=$letter")
    return [string]$letter + ':\state'
}
function Test-Writers([string]$Label, [string]$Directory, [bool]$KeepsPermissions) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory 'ps-state.json'
    Write-RooIndustriesOperationJson @{ number = 1 } $path
    $created = [IO.File]::GetCreationTimeUtc($path)
    $security = Security $path
    Start-Sleep -Milliseconds 1100
    Write-RooIndustriesOperationJson @{ number = 2 } $path
    $kept = [IO.File]::GetCreationTimeUtc($path) -eq $created
    $replaced = (Read-RooIndustriesOperationJson $path).data.number -eq 2
    Check ($replaced -and $kept) "${Label}: the PowerShell writer replaces a saved file and keeps its creation time"
    if ($KeepsPermissions) {
        Check ((Security $path) -eq $security) "${Label}: the PowerShell rewrite keeps the file's owner and permissions"
    }
    $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $reader = [IO.FileStream]::new($path, 'Open', 'Read', $sharing)
    try { Write-RooIndustriesOperationJson @{ number = 3 } $path } finally { $reader.Dispose() }
    $latest = (Read-RooIndustriesOperationJson $path).data.number -eq 3
    Check $latest "${Label}: a PowerShell rewrite succeeds while a reader holds the file"
    $permissions = if ($KeepsPermissions) { 'keeps-permissions' } else { 'any-permissions' }
    $arguments = @('--state-volume', (Join-Path $Directory 'cs'), $Label, $permissions)
    & $DotNetPath run --project $project --configuration Release -- @arguments
    if ($LASTEXITCODE) { $script:failures++ }
    $left = @(Get-ChildItem -LiteralPath $Directory -Recurse -Filter '*.tmp').Count
    Check ($left -eq 0) "${Label}: no temporary file is left behind"
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Test-Writers 'NTFS' (Join-Path $root 'ntfs') $true
    Test-Writers 'FAT32' (Mount-Volume 'fat32') $false
    Test-Writers 'exFAT' (Mount-Volume 'exfat') $false
    $share = 'pvu-state-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $shared = Join-Path $root 'share'
    New-Item -ItemType Directory -Path $shared | Out-Null
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    New-SmbShare -Name $share -Path $shared -FullAccess $user | Out-Null
    Test-Writers 'Network share' ("\\localhost\$share\state") $false
} finally {
    if ($share) { Remove-SmbShare -Name $share -Force }
    foreach ($vhd in $disks) { Invoke-DiskPart @(('select vdisk file="' + $vhd + '"'), 'detach vdisk') }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Check (-not (Test-Path -LiteralPath $root)) 'The volume fixtures are removed'
if ($failures) { exit 1 }
