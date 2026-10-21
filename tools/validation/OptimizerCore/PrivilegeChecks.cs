using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class PrivilegeChecks
{
    internal static void WithoutPrivileges(Action action, params string[] names)
    {
        var previous = new List<(string Name, bool Enabled)>();
        try
        {
            foreach (var name in names) previous.Add((name, SetPrivilege(name, false)));
            action();
        }
        finally { foreach (var saved in previous.AsEnumerable().Reverse()) SetPrivilege(saved.Name, saved.Enabled); }
    }

    public static void Run(Action<bool, string> check)
    {
        PrivilegeRestoreFailure(check);
        PrivilegeSetupFailure(check);
        StartupScript(check);
    }

    static void PrivilegeRestoreFailure(Action<bool, string> check)
    {
        var initial = SetPrivilege("SeIncreaseBasePriorityPrivilege", false);
        var preserved = false;
        PrivilegeScope.SimulateRestoreFailure = () => true;
        try { using (new PrivilegeScope("fixture", "SeIncreaseBasePriorityPrivilege")) throw new InvalidOperationException("original failure"); }
        catch (InvalidOperationException error) { preserved = error.Message == "original failure"; }
        finally { PrivilegeScope.SimulateRestoreFailure = null; }
        var io = 3;
        var status = NtSetInformationProcess(GetCurrentProcess(), 33, ref io, 4);
        io = 2;
        NtSetInformationProcess(GetCurrentProcess(), 33, ref io, 4);
        SetPrivilege("SeIncreaseBasePriorityPrivilege", initial);
        check(preserved, "A failed privilege restore keeps the original error");
        check(status < 0, "A failed privilege restore still leaves the privilege disabled");
        check(PrivilegeEnabled("SeIncreaseBasePriorityPrivilege") == initial, "The restore-failure check returns the privilege to its starting state");
    }

    static void PrivilegeSetupFailure(Action<bool, string> check)
    {
        var initial = SetPrivilege("SeTimeZonePrivilege", false);
        Exception? observed = null;
        PrivilegeScope.SimulateRestoreFailure = () => true;
        PrivilegeScope.SimulateDisableFailure = () => true;
        try { using (new PrivilegeScope("fixture", "SeTimeZonePrivilege", "SeRooIndustriesMissingPrivilege")) { } }
        catch (Exception error) { observed = error; }
        finally { PrivilegeScope.SimulateRestoreFailure = null; PrivilegeScope.SimulateDisableFailure = null; }
        SetPrivilege("SeTimeZonePrivilege", initial);
        check(PrivilegeEnabled("SeTimeZonePrivilege") == initial, "The setup-failure check returns the privilege to its starting state");
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

    static bool PrivilegeEnabled(string name)
    {
        var previous = SetPrivilege(name, false);
        SetPrivilege(name, previous);
        return previous;
    }

    static bool SetPrivilege(string name, bool enabled)
    {
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out var token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        using (token)
        {
            if (!LookupPrivilegeValue(null, name, out var luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var state = new TokenPrivilege { Count = 1, Luid = luid, Attributes = enabled ? 2u : 0u };
            if (!AdjustTokenPrivileges(token, false, ref state, Marshal.SizeOf<TokenPrivilege>(), out var previous, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (Marshal.GetLastWin32Error() == 1300) throw new Win32Exception(1300, name + " is not held by this token.");
            return previous.Count == 0 ? enabled : (previous.Attributes & 2) != 0;
        }
    }

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [StructLayout(LayoutKind.Sequential)] struct PrivilegeLuid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct TokenPrivilege { public uint Count; public PrivilegeLuid Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool LookupPrivilegeValue(string? system, string name, out PrivilegeLuid luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(SafeFileHandle token, bool disableAll, ref TokenPrivilege state, int length, out TokenPrivilege previous, out int needed);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int length);
}
