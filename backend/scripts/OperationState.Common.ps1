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
    $temporary = $full + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 32))
    $settled = $false
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        try {
            if ([IO.File]::Exists($full)) { [IO.File]::Replace($temporary,$full,[System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($temporary,$full) }
        } catch {
            $failure = $_.Exception
            if ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
            if ($failure -isnot [IO.IOException] -or ($failure.HResult -band 0xffff) -notin 1176,1177 -or [IO.File]::Exists($full) -or -not [IO.File]::Exists($temporary)) { throw }
            [IO.File]::Move($temporary,$full)
        }
        $settled = $true
    } finally { if (($settled -or [IO.File]::Exists($full)) -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
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
                $pending = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($full)) -Filter ([IO.Path]::GetFileName($full) + '.*.tmp') -File -ErrorAction SilentlyContinue | Where-Object { ([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalSeconds -lt 5 })
                if ($attempt -ge 2 -and $pending.Count -eq 0) { throw }
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
