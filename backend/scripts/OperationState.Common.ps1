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
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($full)) { [IO.File]::Replace($temporary,$full,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$full) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Read-RooIndustriesOperationJson {
    param([Parameter(Mandatory=$true)][string]$Path, [string]$ExpectedSha256 = '')
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
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
