# Durable operation files shared by the CPU Set and uninstall queue executors.
function Assert-RooIndustriesDistinctOperationPaths {
    param([string[]]$Paths)
    $seen=@{}
    foreach($path in $Paths){
        if([string]::IsNullOrWhiteSpace($path)){continue}
        $full=[IO.Path]::GetFullPath($path)
        if($seen.ContainsKey($full)){throw 'Reviewed inputs, output files and journals must use separate paths.'}
        $seen[$full]=$true
    }
}

function Open-RooIndustriesReplaceLock {
    param([Parameter(Mandatory=$true)][string]$Full)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { return [IO.FileStream]::new($Full + '.replace.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose) }
        catch {
            $failure = $_.Exception
            if ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            if ($failure -is [UnauthorizedAccessException]) { return $null }
            if (-not ($failure -is [IO.IOException] -and (($failure.HResult -band 0xffff) -eq 32 -or ($failure.HResult -band 0xffff) -eq 33)) -or $clock.Elapsed.TotalSeconds -ge 30) { throw }
            Start-Sleep -Milliseconds 2
        }
    }
}

function Get-RooIndustriesOperationLeftovers {
    param([Parameter(Mandatory=$true)][string]$Full)
    $name = [IO.Path]::GetFileName($Full)
    @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Full)) -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name.Length -ge $name.Length + 37 -and $_.Name.StartsWith($name + '.', [StringComparison]::OrdinalIgnoreCase) -and $_.Name.Substring($name.Length + 1) -match '^[0-9a-f]{32}\.(tmp|bak|writing)$'
    } | ForEach-Object { $_.FullName })
}

function Restore-RooIndustriesOrphanedOperation {
    param([Parameter(Mandatory=$true)][string]$Full)
    if ([IO.File]::Exists($Full)) { return }
    $backups = @(Get-RooIndustriesOperationLeftovers $Full | Where-Object { $_.EndsWith('.bak', [StringComparison]::OrdinalIgnoreCase) })
    if ($backups.Count -eq 1) { [IO.File]::Move($backups[0], $Full) }
    elseif ($backups.Count -gt 1) { throw ('Several interrupted saves left backups of ' + [IO.Path]::GetFileName($Full) + '. Review them before continuing.') }
}

function Test-RooIndustriesOperationFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.File]::Exists($full)) { return $true }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))) { return $false }
    $guard = Open-RooIndustriesReplaceLock $full
    try { Restore-RooIndustriesOrphanedOperation $full; return [IO.File]::Exists($full) } finally { if ($guard) { $guard.Dispose() } }
}

function Write-RooIndustriesOperationJson {
    param([Parameter(Mandatory=$true)]$Value, [Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 32))
    $guard = Open-RooIndustriesReplaceLock $full
    try {
        Restore-RooIndustriesOrphanedOperation $full
        if ([IO.File]::Exists($full)) { foreach ($leftover in Get-RooIndustriesOperationLeftovers $full) { try { [IO.File]::Delete($leftover) } catch { } } }
        $operation = $full + '.' + [guid]::NewGuid().ToString('N')
        $temporary = $operation + '.tmp'
        $backup = $operation + '.bak'
        $hook = Get-Variable -Name RooIndustriesSimulateReplaceFailure -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        try {
            $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            if ([IO.File]::Exists($full)) {
                try {
                    if ($hook) { & $hook $full $backup }
                    [IO.File]::Replace($temporary,$full,$backup)
                } catch {
                    if (-not [IO.File]::Exists($full) -and [IO.File]::Exists($backup)) { [IO.File]::Move($backup,$full) }
                    throw
                }
                try { [IO.File]::Delete($backup) } catch { }
            }
            else { [IO.File]::Move($temporary,$full) }
        } finally { if ([IO.File]::Exists($temporary)) { try { [IO.File]::Delete($temporary) } catch { } } }
    } finally { if ($guard) { $guard.Dispose() } }
}

function Read-RooIndustriesOperationJson {
    param([Parameter(Mandatory=$true)][string]$Path, [string]$ExpectedSha256 = '')
    $full = [IO.Path]::GetFullPath($Path)
    $bytes = $null
    for ($attempt = 0; $null -eq $bytes; $attempt++) {
        try {
            $stream = [IO.FileStream]::new($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $buffer = [IO.MemoryStream]::new(); $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $stream.Dispose() }
        }
        catch {
            $failure = $_.Exception
            if ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            if ($attempt -ge 40) { throw }
            if ($failure -is [IO.FileNotFoundException]) { if (-not (Test-RooIndustriesOperationFile $full)) { throw } }
            elseif ($failure -is [IO.IOException] -and ($failure.HResult -band 0xffff) -eq 32) { Start-Sleep -Milliseconds 25 }
            else { throw }
        }
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    if ($ExpectedSha256 -and $digest -ne $ExpectedSha256) { throw 'Reviewed input bytes changed; create and review a fresh preview.' }
    $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)
    return [pscustomobject]@{ sha256=$digest; data=($text | ConvertFrom-Json) }
}

function Lock-RooIndustriesOperation {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    return [IO.FileStream]::new($full+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
}

function Get-RooIndustriesOperationOwner {
    return [pscustomobject]@{ machine=$env:COMPUTERNAME; userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
}

function Assert-RooIndustriesOperationOwner {
    param($Owner)
    $current = Get-RooIndustriesOperationOwner
    if ($null -eq $Owner -or $Owner.machine -ine $current.machine -or $Owner.userSid -cne $current.userSid) {
        throw 'Operation belongs to a different computer or Windows user.'
    }
}
