using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

class IntegrityProbe
{
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr buffer, int length, out int needed);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    static int Main()
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 8, out token)) return 210;
        var buffer = Marshal.AllocHGlobal(1024);
        try
        {
            int needed;
            if (!GetTokenInformation(token, 20, buffer, 4, out needed)) return 211;
            var elevated = Marshal.ReadInt32(buffer) != 0;
            if (!GetTokenInformation(token, 18, buffer, 4, out needed)) return 212;
            var type = Marshal.ReadInt32(buffer);
            if (!GetTokenInformation(token, 25, buffer, 1024, out needed)) return 213;
            var sid = Marshal.ReadIntPtr(buffer);
            var count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
            var rid = (uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
            var level = rid >= 0x4000 ? "System" : rid >= 0x3000 ? "High" : rid >= 0x2000 ? "Medium" : rid >= 0x1000 ? "Low" : "Untrusted";
            var report = new StringBuilder();
            report.AppendLine("elevated=" + (elevated ? "true" : "false"));
            report.AppendLine("integrity=0x" + rid.ToString("X4") + " (" + level + ")");
            report.AppendLine("elevationType=" + (type == 1 ? "Default" : type == 2 ? "Full" : type == 3 ? "Limited" : type.ToString()));
            report.AppendLine("user=" + WindowsIdentity.GetCurrent().Name);
            report.AppendLine("session=" + System.Diagnostics.Process.GetCurrentProcess().SessionId);
            var directory = AppDomain.CurrentDomain.BaseDirectory;
            var temporary = Path.Combine(directory, "probe-report.tmp");
            File.WriteAllText(temporary, report.ToString(), Encoding.ASCII);
            File.Move(temporary, Path.Combine(directory, "probe-report.txt"));
            return 0;
        }
        finally { Marshal.FreeHGlobal(buffer); CloseHandle(token); }
    }
}
