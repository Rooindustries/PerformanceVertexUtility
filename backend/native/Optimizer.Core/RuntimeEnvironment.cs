#nullable enable
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

public static class RuntimeEnvironment
{
    public static readonly string[] CodeLoading =
    [
        "DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "DOTNET_SHARED_STORE",
        "CORECLR_ENABLE_PROFILING", "CORECLR_PROFILER", "CORECLR_PROFILER_PATH", "CORECLR_PROFILER_PATH_32", "CORECLR_PROFILER_PATH_64",
        "CORECLR_PROFILER_PATH_ARM64", "COR_ENABLE_PROFILING", "COR_PROFILER", "COR_PROFILER_PATH", "COR_PROFILER_PATH_32", "COR_PROFILER_PATH_64",
    ];

    public static readonly string[] ProductOverrides =
    [
        "ROO_INDUSTRIES_BACKEND_ROOT", "ROO_INDUSTRIES_DOTNET_EXE", "ROO_INDUSTRIES_PYTHON_EXE", "ROO_INDUSTRIES_UTILITIES_ROOT",
        "ROO_BACKEND_ROOT", "ROO_DOTNET_EXE", "ROO_PYTHON_EXE", "ROO_UTILITIES_ROOT",
    ];

#if ROO_RELEASE
    public static readonly bool Release = true;
#else
    public static readonly bool Release = false;
#endif

    private static readonly string[] MachineNames = ["OS", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION"];
    private static readonly string[] DeveloperPrefixes = ["ROO_", "ROOTEST_"];
    private static readonly string[] DeveloperNames = ["DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_ROOT_X86", "DOTNET_ROOT_ARM64", "DOTNET_ROOT(x86)"];
    private static string? _protectedTemp;

    private static string ModulePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules") + ";" +
        Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "Modules");

    public static string PowerShellPrelude => "$env:PSModulePath='" + ModulePath.Replace("'", "''") + "'; ";

    public static Dictionary<string, string> ChildEnvironment()
    {
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var system = Environment.SystemDirectory;
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var commonFiles = Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles);
        var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        var profileDrive = Path.GetPathRoot(profile)!.TrimEnd('\\');
        var temp = ProtectedTemp(windows);
        var child = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SystemRoot"] = windows, ["windir"] = windows, ["SystemDrive"] = Path.GetPathRoot(windows)!.TrimEnd('\\'), ["ComSpec"] = Path.Combine(system, "cmd.exe"),
            ["PATH"] = string.Join(';', system, windows, Path.Combine(system, "Wbem"), Path.Combine(system, "WindowsPowerShell", "v1.0")),
            ["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC",
            ["TEMP"] = temp, ["TMP"] = temp, ["PSModulePath"] = ModulePath,
            ["ProgramFiles"] = programFiles, ["ProgramW6432"] = programFiles, ["ProgramFiles(x86)"] = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            ["CommonProgramFiles"] = commonFiles, ["CommonProgramW6432"] = commonFiles, ["CommonProgramFiles(x86)"] = Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFilesX86),
            ["ProgramData"] = programData, ["ALLUSERSPROFILE"] = programData, ["PUBLIC"] = PublicFolder() ?? Path.Combine(Path.GetDirectoryName(profile)!, "Public"),
            ["USERPROFILE"] = profile, ["HOMEDRIVE"] = profileDrive, ["HOMEPATH"] = profile[profileDrive.Length..],
            ["LOCALAPPDATA"] = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), ["APPDATA"] = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            ["USERNAME"] = Environment.UserName, ["USERDOMAIN"] = UserDomain(), ["COMPUTERNAME"] = Environment.MachineName,
            ["OS"] = "Windows_NT", ["DriverData"] = Path.Combine(system, "Drivers", "DriverData"),
            ["NUMBER_OF_PROCESSORS"] = Environment.ProcessorCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["PROCESSOR_ARCHITECTURE"] = RuntimeInformation.OSArchitecture switch { Architecture.Arm64 => "ARM64", Architecture.X86 => "x86", _ => "AMD64" },
        };
        try
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = machine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment");
            foreach (var name in MachineNames)
                if (key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string { Length: > 0 } value) child[name] = value;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        if (!Release)
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
                if (entry.Key is string name && entry.Value is string value && (DeveloperPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) || DeveloperNames.Contains(name, StringComparer.OrdinalIgnoreCase)))
                    child[name] = value;
        return child;
    }

    public static void Apply(ProcessStartInfo start)
    {
        start.Environment.Clear();
        foreach (var (name, value) in ChildEnvironment()) start.Environment[name] = value;
    }

    private static string ProtectedTemp(string windows)
    {
        var cached = _protectedTemp;
        if (cached is not null && Directory.Exists(cached)) return cached;
        try
        {
            var root = DataFolder.Root;
            var folder = Path.Combine(root, "temp");
            if (Directory.Exists(folder) && !new DirectoryInfo(folder).Attributes.HasFlag(FileAttributes.ReparsePoint) && DataFolder.Secured(root)) return _protectedTemp = folder;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or System.Security.SecurityException) { }
        return Path.Combine(windows, "Temp");
    }

    private static string UserDomain()
    {
        try { return Environment.UserDomainName; }
        catch (InvalidOperationException) { return Environment.MachineName; }
    }

    private static string? PublicFolder()
    {
        if (SHGetKnownFolderPath(new Guid("DFDF76A2-C82A-4D63-906A-5644AC457385"), 0, IntPtr.Zero, out var path) != 0) return null;
        try { return Marshal.PtrToStringUni(path); }
        finally { Marshal.FreeCoTaskMem(path); }
    }

    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid folder, uint flags, IntPtr token, out IntPtr path);

    public static void Sanitize()
    {
        foreach (var name in CodeLoading) Environment.SetEnvironmentVariable(name, null);
        if (Release) foreach (var name in ProductOverrides) Environment.SetEnvironmentVariable(name, null);
    }

    public static void RequireClean()
    {
        var present = CodeLoading.Where(name => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable(name))).ToArray();
        if (present.Length > 0) throw new InvalidOperationException("Roo Industries will not run with these .NET settings in its environment: " + string.Join(", ", present) + ". Remove them and sign in again.");
    }
}
