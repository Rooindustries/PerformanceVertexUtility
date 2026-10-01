param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Exe = 'C:\Program Files\Roo Industries\Optimization Suite\app\RooIndustries.OptimizationSuite.App.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$script:LogPath = Join-Path $OutDir 'permissions.log'
$script:Failures = 0
function Log([string]$m) { [IO.File]::AppendAllText($script:LogPath, (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff') + 'Z ' + $m + "`r`n") }
function Check([bool]$ok, [string]$name, [string]$detail) { if (-not $ok) { $script:Failures++ }; Log ($(if ($ok) { 'PASS ' } else { 'FAIL ' }) + $name + ' :: ' + $detail) }
$trusted = @('S-1-5-32-544', 'S-1-5-18')
$writeMask = 0x500D0156
$created = New-Object System.Collections.Generic.List[string]
try {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $markers = Get-Item -LiteralPath 'HKLM:\SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots' -ErrorAction SilentlyContinue
    $current = Join-Path $local 'RooIndustriesOptimizationSuite'; $legacy = Join-Path $local ('RooIndustriesOptimizationSuite' -replace 'Industries','')
    $root = if ((Test-Path -LiteralPath $legacy -PathType Container) -and -not ($markers -and $null -ne $markers.GetValue($current.ToUpperInvariant()) -and $null -eq $markers.GetValue($legacy.ToUpperInvariant()))) { $legacy } else { $current }
    Log ("data root=$root user=$user marked=" + [bool]($markers -and $null -ne $markers.GetValue($root.ToUpperInvariant())))
    $names = [ordered]@{ root = ''; operations = 'operations'; timer = 'operations\windows-timer'; firmware = 'firmware'; tools = 'tools'; settings = 'settings'; rules = 'process-rules'; logs = 'logs' }
    $paths = [ordered]@{}
    foreach ($key in $names.Keys) {
        $path = if ($names[$key]) { Join-Path $root $names[$key] } else { $root }
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null; $created.Add($path); Log "created $path for the check" }
        $paths[$key] = $path
    }
    $timerState = Join-Path $local 'RooIndustriesOptimizationSuite.Timer'
    $timerStateExists = Test-Path -LiteralPath $timerState
    if ($timerStateExists) { $paths['timerState'] = $timerState } else { Log ('SKIPPED the sign-in timer state folder checks :: ' + $timerState + ' does not exist; it appears only after the sign-in timer has run on this PC') }
    $report = [ordered]@{}
    foreach ($key in $paths.Keys) {
        $acl = Get-Acl -LiteralPath $paths[$key]
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
            $name = try { $_.IdentityReference.Translate([Security.Principal.NTAccount]).Value } catch { $_.IdentityReference.Value }
            [ordered]@{ sid = $_.IdentityReference.Value; name = $name; rights = [string]$_.FileSystemRights; type = [string]$_.AccessControlType; inherited = $_.IsInherited; inheritance = [string]$_.InheritanceFlags; propagation = [string]$_.PropagationFlags }
        })
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $report[$key] = [ordered]@{ path = $paths[$key]; owner = $owner; ownerName = $acl.Owner; protected = $acl.AreAccessRulesProtected; rules = $rules; icacls = @(& icacls.exe $paths[$key] 2>&1 | ForEach-Object { [string]$_ }) }
        $writers = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and $trusted -notcontains $_.IdentityReference.Value -and (([int64]$_.FileSystemRights -band $writeMask) -ne 0) } | ForEach-Object { $_.IdentityReference.Value })
        $reads = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq $user -and (([int64]$_.FileSystemRights -band 1) -ne 0) }).Count -gt 0
        if ($key -eq 'timerState') {
            $info = Get-Item -LiteralPath $paths[$key] -Force
            $inside = ([IO.Path]::GetFullPath($paths[$key]).TrimEnd('\') + '\').StartsWith([IO.Path]::GetFullPath($root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
            Check (-not $info.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -and $info.PSIsContainer -and -not $inside) 'the sign-in timer state folder is a plain folder outside the protected data folder' ("path=" + $paths[$key] + " attributes=" + $info.Attributes + " insideDataRoot=$inside")
            Check ($owner -eq $user -and @($writers | Where-Object { $_ -ne $user }).Count -eq 0 -and $writers -contains $user) 'the sign-in timer state folder is owned by the signed-in user, who is the only one besides Administrators and SYSTEM that can write it' ("owner=$owner writers=" + ($writers -join ','))
        } else {
            Check ($trusted -contains $owner -and $writers.Count -eq 0 -and $reads) "$key is owned by Administrators or SYSTEM, only they can write, and the signed-in user can read" ("owner=$owner protected=" + $acl.AreAccessRulesProtected + " writers=" + ($writers -join ',') + " userRead=$reads")
        }
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'permissions.json') -Encoding UTF8

    $results = Join-Path $env:TEMP ('roo-industries-standard-token-' + [Guid]::NewGuid().ToString('N') + '.json')
    $inner = Join-Path $env:TEMP 'roo-industries-standard-token.ps1'
    $targets = ($paths.Keys | ForEach-Object { "'" + $_ + "'='" + $paths[$_].Replace("'", "''") + "'" }) -join ';'
    $log = (Join-Path $paths['logs'] 'app.log').Replace("'", "''")
    @"
`$ErrorActionPreference='Stop'
`$out=[ordered]@{groups=@(whoami /groups | Select-String 'S-1-5-32-544' | ForEach-Object { [string]`$_ })}
`$targets=[ordered]@{$targets}
foreach(`$key in `$targets.Keys){
  `$file=Join-Path `$targets[`$key] ('roo-industries-standard-probe-'+[Guid]::NewGuid().ToString('N')+'.txt')
  try { Set-Content -LiteralPath `$file -Value 'standard token probe' -ErrorAction Stop; `$out[`$key]='WROTE '+`$file } catch { `$out[`$key]='DENIED '+`$_.Exception.Message }
  try { `$out[`$key+'List']='LISTED '+@(Get-ChildItem -LiteralPath `$targets[`$key] -Force -ErrorAction Stop).Count } catch { `$out[`$key+'List']='LIST FAILED '+`$_.Exception.Message }
}
try { `$out['logRead']='READ '+@(Get-Content -LiteralPath '$log' -TotalCount 1 -ErrorAction Stop).Count } catch { `$out['logRead']='FAILED '+`$_.Exception.Message }
`$out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$results' -Encoding UTF8
"@ | Set-Content -LiteralPath $inner -Encoding UTF8
    & runas.exe /trustlevel:0x20000 ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $inner + '"')
    Log ('runas exit=' + $LASTEXITCODE)
    for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath $results); $i++) { Start-Sleep 1 }
    Start-Sleep 1
    $standard = Get-Content -LiteralPath $results -Raw | ConvertFrom-Json
    Copy-Item -LiteralPath $results -Destination (Join-Path $OutDir 'standard-token.json')
    Check ((@($standard.groups) -join ' ') -match 'deny only') 'runas /trustlevel:0x20000 gave a standard token (Administrators deny-only)' (@($standard.groups) -join ' ')
    foreach ($key in $paths.Keys) {
        $value = [string]$standard.$key
        if ($key -eq 'timerState') {
            Check ($value -like 'WROTE *') 'a standard token can write the sign-in timer state folder, the only user-writable place' $value
            if ($value -like 'WROTE *') { Remove-Item -LiteralPath $value.Substring(6) -Force }
        } else {
            Check ($value -like 'DENIED *' -and $value -match 'denied') "a standard token is denied writing into $key" $value
            if ($value -like 'WROTE *') { Remove-Item -LiteralPath $value.Substring(6) -Force }
        }
        $listed = [string]$standard.($key + 'List')
        Check ($listed -like 'LISTED *') "a standard token can read (list) $key" $listed
    }
    Check ([string]$standard.logRead -like 'READ *') 'a standard token can read the app log' ([string]$standard.logRead)
    Remove-Item -LiteralPath $results, $inner -Force -ErrorAction SilentlyContinue
} catch { $script:Failures++; Log ('FATAL ' + ($_ | Out-String)) }
finally {
    foreach ($path in $created) { Remove-Item -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue }
    Log ('RESULT failures=' + $script:Failures)
    'x' | Set-Content (Join-Path $OutDir 'permissions.done')
}
