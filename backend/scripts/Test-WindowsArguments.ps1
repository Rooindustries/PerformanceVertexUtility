$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BackendExecutor.Common.ps1')
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ValidationArgumentParser {
    [DllImport("shell32.dll", SetLastError = true)] private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr value);
    public static string[] Parse(string command) {
        int count; var block = CommandLineToArgvW(command, out count);
        if (block == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try { var values = new string[count]; for (int i = 0; i < count; i++) values[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(block, i * IntPtr.Size)); return values; }
        finally { LocalFree(block); }
    }
}
'@
$expected = @('program.exe', '', 'two words', 'C:\folder with spaces\', 'embedded"quote', 'backslash\"quote', 'plain')
$actual = [ValidationArgumentParser]::Parse((Join-RooWindowsArguments $expected))
if ($actual.Count -ne $expected.Count) { throw 'Windows argument count changed.' }
for ($i = 0; $i -lt $expected.Count; $i++) { if ($actual[$i] -cne $expected[$i]) { throw "Windows argument $i did not round-trip." } }
Write-Host 'PASS Windows parses empty arguments, spaces, quotes, and trailing backslashes without changing values'
$executor = Join-RooBackendExecutorCommandLine $expected[0] $expected[1..($expected.Count - 1)]
$actual = [ValidationArgumentParser]::Parse($executor)
for ($i = 0; $i -lt $expected.Count; $i++) { if ($actual[$i] -cne $expected[$i]) { throw "Executor argument $i changed." } }
Write-Host 'PASS Executor uses the same verified Windows argument encoding'
$wrong = '"program.exe" "C:\folder with spaces\" "next"'
$parsedWrong = [ValidationArgumentParser]::Parse($wrong)
if ($parsedWrong.Count -eq 3 -and $parsedWrong[1] -eq 'C:\folder with spaces\') { throw 'Negative control unexpectedly accepted broken trailing-backslash encoding.' }
Write-Host 'PASS Windows rejects the representative old quoting result for the intended reason'
