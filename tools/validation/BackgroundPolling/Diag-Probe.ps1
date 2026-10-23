param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class DiagWin {
  delegate bool Enum(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(Enum cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static string[] Of(uint target) { var r = new List<string>(); EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == target) { var s = new StringBuilder(256); GetWindowText(h, s, 256); r.Add(h + " visible=" + IsWindowVisible(h) + " title=" + s); } return true; }, IntPtr.Zero); return r.ToArray(); }
}
'@
$dir = Join-Path $OutRoot 'diag'; [IO.Directory]::CreateDirectory($dir) | Out-Null
$log = [Collections.Generic.List[string]]::new()
$self = Get-Process -Id $PID
$log.Add('self session=' + $self.SessionId + ' interactive=' + [Environment]::UserInteractive + ' fg=' + [DiagWin]::GetForegroundWindow())
$exe = Join-Path $dir 'PollingFocusProbe.exe'
Add-Type -OutputAssembly $exe -OutputType WindowsApplication -ReferencedAssemblies System.Windows.Forms -TypeDefinition 'using System.Windows.Forms; public static class PollingFocusProbe { [System.STAThread] public static void Main(string[] args) { Application.Run(new Form { Text = "Background polling probe", WindowState = FormWindowState.Maximized }); } }'
foreach ($candidate in @($exe, (Join-Path $env:SystemRoot 'System32\charmap.exe'))) {
  $p = Start-Process $candidate -PassThru
  for ($i = 0; $i -lt 8; $i++) { Start-Sleep -Milliseconds 750; $p.Refresh(); $log.Add((Split-Path $candidate -Leaf) + ' t=' + $i + ' exited=' + $p.HasExited + ' exit=' + $(if ($p.HasExited) { $p.ExitCode } else { '' }) + ' session=' + $(try { $p.SessionId } catch { '?' }) + ' main=' + $p.MainWindowHandle + ' windows=' + ([DiagWin]::Of([uint32]$p.Id) -join ' ; ')) }
  if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
}
[IO.File]::WriteAllLines((Join-Path $dir 'diag.txt'), $log)
$log | ForEach-Object { Write-Output $_ }
