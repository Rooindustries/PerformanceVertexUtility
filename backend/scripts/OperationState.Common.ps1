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
        Move-RooIndustriesReplacement $temporary $full
    } finally { if ([IO.File]::Exists($full) -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Move-RooIndustriesReplacement {
    param([Parameter(Mandatory=$true)][string]$Temporary, [Parameter(Mandatory=$true)][string]$Path)
    if (-not ('RooIndustriesAtomicReplace' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class RooIndustriesAtomicReplace {
    const int DeleteAccess = 0x110000;
    const int RenameInfoEx = 22;
    const byte ReplacePosix = 3;
    const int UnsupportedHere = 87;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(
        string name, int access, FileShare share, IntPtr security, FileMode mode, int flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, byte[] information, int length);
    public static void Move(string temporary, string path) {
        FileInfo current = new FileInfo(path);
        if (current.Exists) File.SetCreationTimeUtc(temporary, current.CreationTimeUtc);
        FileShare share = FileShare.ReadWrite | FileShare.Delete;
        IntPtr none = IntPtr.Zero;
        using (SafeFileHandle file = CreateFileW(temporary, DeleteAccess, share, none, FileMode.Open, 0, none)) {
            if (file.IsInvalid) Fail();
            byte[] name = Encoding.Unicode.GetBytes(path);
            int offset = IntPtr.Size == 8 ? 20 : 12;
            byte[] rename = new byte[offset + name.Length + 8];
            rename[0] = ReplacePosix;
            BitConverter.GetBytes(name.Length).CopyTo(rename, offset - 4);
            name.CopyTo(rename, offset);
            if (SetFileInformationByHandle(file, RenameInfoEx, rename, rename.Length)) return;
            if (Marshal.GetLastWin32Error() != UnsupportedHere) Fail();
        }
        try {
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        } catch (IOException error) {
            int code = error.HResult & 0xffff;
            if ((code != 1176 && code != 1177) || File.Exists(path)) throw;
            File.Move(temporary, path);
        }
    }
    static void Fail() { Marshal.ThrowExceptionForHR(Marshal.GetHRForLastWin32Error()); }
}
'@
    }
    [RooIndustriesAtomicReplace]::Move([IO.Path]::GetFullPath($Temporary), [IO.Path]::GetFullPath($Path))
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
