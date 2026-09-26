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

function Write-RooIndustriesOperationJson {
    param([Parameter(Mandatory=$true)]$Value, [Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    foreach ($stale in @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($full)) -Filter ([IO.Path]::GetFileName($full) + '.*') -File -ErrorAction SilentlyContinue)) {
        if ($stale.Name.Length -le [IO.Path]::GetFileName($full).Length + 1) { continue }
        $suffix = $stale.Name.Substring([IO.Path]::GetFileName($full).Length + 1)
        if ($suffix -match '^[0-9a-f]{32}\.(tmp|writing)$' -and ([DateTime]::UtcNow - $stale.LastWriteTimeUtc).TotalMinutes -ge 1) {
            try { [IO.File]::Delete($stale.FullName) } catch { }
        }
    }
    $operation = $full + '.' + [guid]::NewGuid().ToString('N')
    $temporary = $operation + '.tmp'
    $marker = $operation + '.writing'
    $backup = $operation + '.bak'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 32))
    try {
        [IO.FileStream]::new($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None).Dispose()
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($full)) {
            try {
                if ($script:RooIndustriesSimulateReplaceFailure) { & $script:RooIndustriesSimulateReplaceFailure $full $backup }
                [IO.File]::Replace($temporary,$full,$backup)
            } catch {
                if (-not [IO.File]::Exists($full) -and [IO.File]::Exists($backup)) { [IO.File]::Move($backup,$full) }
                throw
            }
            [IO.File]::Delete($backup)
        }
        else { [IO.File]::Move($temporary,$full) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }; if ([IO.File]::Exists($marker)) { [IO.File]::Delete($marker) } }
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
            if ($failure -is [IO.FileNotFoundException]) {
                $pending = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($full)) -Filter ([IO.Path]::GetFileName($full) + '.*') -File -ErrorAction SilentlyContinue | Where-Object { ($_.Name.EndsWith('.tmp') -or $_.Name.EndsWith('.writing') -or $_.Name.EndsWith('.bak')) -and ([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalSeconds -lt 5 })
                if ($attempt -ge 10 -and $pending.Count -eq 0 -and -not [IO.File]::Exists($full)) { throw }
                Start-Sleep -Milliseconds 5
            } elseif ($failure -is [IO.IOException] -and ($failure.HResult -band 0xffff) -eq 32) { Start-Sleep -Milliseconds 25 }
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
