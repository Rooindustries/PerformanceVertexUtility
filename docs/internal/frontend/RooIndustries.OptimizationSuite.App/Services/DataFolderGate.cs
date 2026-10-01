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
        string problem;
        try { return Opened(Protected(locator)); }
        catch (Exception error) { problem = error.Message; }
        MessageBox(IntPtr.Zero, "Roo Industries could not open its data folder, so it closed without reading it.\n\n" + problem, "Roo Industries Optimization Suite", 0x10);
        Environment.Exit(1);
        return false;
    }

    private static string Protected(BackendLocator locator)
    {
        try { return DataFolder.Require(); }
        catch (UnauthorizedAccessException) { }
        using var preparing = new PreparingWindow(TimeSpan.FromSeconds(1));
        Task.Run(() => new OptimizerService(locator).SecureDataFolderAsync(preparing.Report)).GetAwaiter().GetResult();
        return DataFolder.Require();
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
