using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Roo.Optimizer;

static class ReferenceGovernor
{
    public const string Sha256 = "EA338D4C47F61BB3AA107A26DE3614D112F19DA9438291B3A8212F21BB01D495";

    public static Process Start(string executable, string directory, string targetName)
    {
        if (OperationFiles.HashFile(executable) != Sha256) throw new InvalidDataException("Use the verified Process Lasso 18.3.0.34 governor.");
        var config = Path.Combine(directory, "reference-config");
        var logs = Path.Combine(directory, "reference-logs");
        Directory.CreateDirectory(config);
        Directory.CreateDirectory(logs);
        var ini = Path.Combine(config, "prolasso.ini");
        File.WriteAllText(ini, "", Encoding.Unicode);
        foreach (var (section, key, value) in new[]
        {
            ("OutOfControlProcessRestraint", "OocOn", "False"),
            ("Performance", "ManageOnlyCurrentUser", "True"),
            ("Performance", "ForcedMode", "False"),
            ("ForegroundBoosting", "BoostForegroundThread", "False"),
            ("ForegroundBoosting", "BoostForegroundProcess", "False"),
            ("Performance", "UpdateSpeedCore", "500"),
            ("Advanced", "AutomaticUpdate", "False"),
            ("MemoryManagement", "TrimAllProcessesAtThisIntervalInMs", "0"),
            ("ProcessDefaults", "DefaultPriorities", targetName + ",below normal"),
        })
        {
            if (!WritePrivateProfileString(section, key, value, ini)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var read = new StringBuilder(2048);
            GetPrivateProfileString(section, key, "", read, (uint)read.Capacity, ini);
            if (read.ToString() != value) throw new InvalidDataException("Reference configuration readback failed for " + key + ".");
        }
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(executable),
            Arguments = "/ConfigFolder=" + ShortDirectory(config) + " /LogFolder=" + ShortDirectory(logs),
        };
        return Process.Start(start) ?? throw new InvalidOperationException("The reference governor did not start.");
    }

    public static void VerifyIsolation(Process? reference)
    {
        if (reference?.HasExited == true) throw new InvalidOperationException("The reference governor exited during measurement.");
        var processes = Process.GetProcessesByName("ProcessGovernor");
        try
        {
            if (processes.Length != (reference is null ? 0 : 1) || reference is not null && processes[0].Id != reference.Id)
                throw new InvalidOperationException("A competing governor invalidated the isolated comparison.");
        }
        finally { foreach (var process in processes) process.Dispose(); }
    }

    public static void Stop(Process? process)
    {
        if (process is null) return;
        using (process)
        {
            if (!process.HasExited) process.Kill();
            if (!process.WaitForExit(10000)) throw new TimeoutException("The owned reference governor did not exit.");
        }
    }

    static string ShortDirectory(string path)
    {
        var result = new StringBuilder(1024);
        var length = GetShortPathName(path, result, (uint)result.Capacity);
        if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length >= result.Capacity || result.ToString().Any(char.IsWhiteSpace))
            throw new InvalidOperationException("The verified reference launch requires a space-free short configuration path.");
        return result.ToString().TrimEnd('\\') + "\\";
    }

    [DllImport("kernel32.dll", EntryPoint = "WritePrivateProfileStringW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WritePrivateProfileString(string section, string key, string value, string path);
    [DllImport("kernel32.dll", EntryPoint = "GetPrivateProfileStringW", CharSet = CharSet.Unicode)]
    static extern uint GetPrivateProfileString(string section, string key, string fallback, StringBuilder result, uint size, string path);
    [DllImport("kernel32.dll", EntryPoint = "GetShortPathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetShortPathName(string path, StringBuilder result, uint size);
}
