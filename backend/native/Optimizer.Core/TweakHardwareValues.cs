#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace RooIndustries.Optimizer;

public static class TweakHardwareValues
{
    public static uint InstalledMemoryKiB()
    {
        if (!GetPhysicallyInstalledSystemMemory(out var kib)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Installed physical memory could not be read.");
        if (kib == 0 || kib > uint.MaxValue) throw new InvalidDataException("Installed memory cannot be represented by this DWORD setting.");
        return (uint)kib;
    }
    public static TweakAssignment Resolve(TweakAssignment assignment, Func<uint> memory, Func<string, string>? command = null)
    {
        if (assignment.Formula is null) return assignment;
        if (assignment.Formula.StartsWith("menu-", StringComparison.Ordinal)) return assignment with { Formula = null, Value = new(assignment.Address.ValueName!, 1, Encoding.Unicode.GetBytes((command ?? MenuCommand)(assignment.Formula) + "\0")) };
        if (assignment.Formula != "installed-memory-kib") throw new InvalidDataException("Unknown hardware-derived setting value.");
        return assignment with { Dword = memory(), Formula = null };
    }
    public static string MenuCommand(string name)
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        if (name == "menu-power") return "\"" + Path.Combine(system, "control.exe") + "\" powercfg.cpl";
        if (name == "menu-startup") return "\"" + Path.Combine(system, "msconfig.exe") + "\"";
        if (name != "menu-ownership") throw new InvalidDataException("Unknown desktop menu action.");
        var ui = RuntimeEnvironment.OwnershipReviewExecutable();
        return "\"" + ui + "\" --ownership-review \"%1\"";
    }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetPhysicallyInstalledSystemMemory(out ulong memoryKiB);
}
