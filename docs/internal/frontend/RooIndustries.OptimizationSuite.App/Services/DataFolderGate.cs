using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public static class DataFolderGate
{
    public static bool Open(BackendLocator locator)
    {
        RooIndustries.Optimizer.RuntimeEnvironment.Sanitize();
        if (!PolicyRootSecurity.Elevated()) return AppLog.Enable();
        try { return Opened(DataFolder.Require()); }
        catch (UnauthorizedAccessException) { }
        string problem;
        try
        {
            Task.Run(() => new OptimizerService(locator).SecureDataFolderAsync()).GetAwaiter().GetResult();
            return Opened(DataFolder.Require());
        }
        catch (Exception error) { problem = error.Message; }
        MessageBox(IntPtr.Zero, "Roo Industries could not protect its data folder, so it closed without reading it.\n\n" + problem, "Roo Industries Optimization Suite", 0x10);
        Environment.Exit(1);
        return false;
    }

    private static bool Opened(string root)
    {
        var temporary = Directory.CreateDirectory(Path.Combine(root, "temp"));
        foreach (var entry in temporary.EnumerateFileSystemInfos().Where(entry => entry.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-1)))
        {
            try { if (entry is DirectoryInfo folder) folder.Delete(true); else entry.Delete(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        Environment.SetEnvironmentVariable("TEMP", temporary.FullName);
        Environment.SetEnvironmentVariable("TMP", temporary.FullName);
        return AppLog.Enable();
    }

    [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr owner, string text, string caption, uint type);
}
