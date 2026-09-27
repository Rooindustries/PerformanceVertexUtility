using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class PrivilegeChecks
{
    public static void Run(Action<bool, string> check)
    {
        PrivilegeRestoreFailure(check);
        PrivilegeSetupFailure(check);
        StartupScript(check);
    }

    static void PrivilegeRestoreFailure(Action<bool, string> check)
    {
        var preserved = false;
        PrivilegeScope.SimulateRestoreFailure = () => true;
        try { using (new PrivilegeScope("fixture", "SeIncreaseBasePriorityPrivilege")) throw new InvalidOperationException("original failure"); }
        catch (InvalidOperationException error) { preserved = error.Message == "original failure"; }
        finally { PrivilegeScope.SimulateRestoreFailure = null; }
        var io = 3;
        var status = NtSetInformationProcess(GetCurrentProcess(), 33, ref io, 4);
        io = 2;
        NtSetInformationProcess(GetCurrentProcess(), 33, ref io, 4);
        check(preserved, "A failed privilege restore keeps the original error");
        check(status < 0, "A failed privilege restore still leaves the privilege disabled");
    }

    static void PrivilegeSetupFailure(Action<bool, string> check)
    {
        Exception? observed = null;
        PrivilegeScope.SimulateRestoreFailure = () => true;
        PrivilegeScope.SimulateDisableFailure = () => true;
        try { using (new PrivilegeScope("fixture", "SeTimeZonePrivilege", "SeRooIndustriesMissingPrivilege")) { } }
        catch (Exception error) { observed = error; }
        finally { PrivilegeScope.SimulateRestoreFailure = null; PrivilegeScope.SimulateDisableFailure = null; }
        DisablePrivilege("SeTimeZonePrivilege");
        check(observed is Win32Exception { NativeErrorCode: 1313 } && observed.Message.Contains("could not be returned to its previous state", StringComparison.Ordinal), "A privilege setup failure keeps its Windows error code and reports the privilege left enabled");
    }

    static void StartupScript(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-startup-script-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            var assembly = Path.Combine(root, "Optimizer.Host.dll");
            var launcher = Path.Combine(root, "Optimizer.Host.exe");
            File.WriteAllText(assembly, "assembly");
            File.WriteAllText(launcher, "launcher");
            var bundled = TimerStartupControl.StartupScript(assembly, launcher, true, root);
            var framework = TimerStartupControl.StartupScript(assembly, launcher, false, root);
            check(bundled.Contains("Get-FileHash -LiteralPath '" + launcher + "'", StringComparison.Ordinal) && bundled.Contains(OperationFiles.HashFile(launcher), StringComparison.Ordinal), "Installed timer startup verifies the executable it launches");
            check(bundled.Contains("Get-FileHash -LiteralPath '" + assembly + "'", StringComparison.Ordinal) && framework.Contains("Get-FileHash -LiteralPath '" + assembly + "'", StringComparison.Ordinal), "Timer startup verifies the helper assembly in both layouts");
        }
        finally { Directory.Delete(root, true); }
    }

    static void DisablePrivilege(string name)
    {
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out var token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        using (token)
        {
            if (!LookupPrivilegeValue(null, name, out var luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var state = new TokenPrivilege { Count = 1, Luid = luid, Attributes = 0 };
            if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [StructLayout(LayoutKind.Sequential)] struct PrivilegeLuid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct TokenPrivilege { public uint Count; public PrivilegeLuid Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool LookupPrivilegeValue(string? system, string name, out PrivilegeLuid luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(SafeFileHandle token, bool disableAll, ref TokenPrivilege state, int length, IntPtr previous, IntPtr needed);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int length);
}
