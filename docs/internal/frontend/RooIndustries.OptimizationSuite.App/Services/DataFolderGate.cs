using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public static class DataFolderGate
{
    public static bool Open(BackendLocator locator)
    {
        RuntimeEnvironment.Sanitize();
        if (!PolicyRootSecurity.Elevated()) return AppLog.Enable();
        try { DataFolder.Require(); return AppLog.Enable(); }
        catch (UnauthorizedAccessException) { }
        string problem;
        try
        {
            Task.Run(() => new OptimizerService(locator).SecureDataFolderAsync()).GetAwaiter().GetResult();
            DataFolder.Require();
            return AppLog.Enable();
        }
        catch (Exception error) { problem = error.Message; }
        MessageBox(IntPtr.Zero, "Roo Industries could not protect its data folder, so it closed without reading it.\n\n" + problem, "Roo Industries Optimization Suite", 0x10);
        Environment.Exit(1);
        return false;
    }

    [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr owner, string text, string caption, uint type);
}
