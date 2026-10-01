#nullable enable
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

public static class RuntimeEnvironment
{
    public static readonly string[] CodeLoading =
    [
        "DOTNET_STARTUP_HOOKS", "DOTNET_ADDITIONAL_DEPS", "DOTNET_SHARED_STORE", "CORECLR_ENABLE_PROFILING",
        "CORECLR_PROFILER", "CORECLR_PROFILER_PATH", "CORECLR_PROFILER_PATH_32", "CORECLR_PROFILER_PATH_64",
        "CORECLR_PROFILER_PATH_ARM64", "COR_ENABLE_PROFILING", "COR_PROFILER", "COR_PROFILER_PATH",
        "COR_PROFILER_PATH_32", "COR_PROFILER_PATH_64", "CORECLR_PROFILER_PATH_ARM32", "CORECLR_ENABLE_NOTIFICATION_PROFILERS",
        "CORECLR_NOTIFICATION_PROFILERS", "CORECLR_NOTIFICATION_PROFILERS_32", "CORECLR_NOTIFICATION_PROFILERS_64", "CORECLR_NOTIFICATION_PROFILERS_ARM32",
        "CORECLR_NOTIFICATION_PROFILERS_ARM64", "DOTNET_DiagnosticPorts", "COMPlus_DiagnosticPorts", "DOTNET_DefaultDiagnosticPortSuspend",
        "COMPlus_DefaultDiagnosticPortSuspend", "DOTNET_GCName", "COMPlus_GCName", "DOTNET_GCPath",
        "COMPlus_GCPath", "DOTNET_JitName", "COMPlus_JitName", "DOTNET_JitPath",
        "COMPlus_JitPath", "DOTNET_AltJit", "COMPlus_AltJit", "DOTNET_AltJitName",
        "COMPlus_AltJitName", "DOTNET_AltJitNgen", "COMPlus_AltJitNgen", "DOTNET_AltJitExcludeAssemblies",
        "COMPlus_AltJitExcludeAssemblies", "DOTNET_EnableEventPipe", "COMPlus_EnableEventPipe", "DOTNET_EventPipeOutputPath",
        "COMPlus_EventPipeOutputPath", "DOTNET_EventPipeConfig", "COMPlus_EventPipeConfig", "DOTNET_DbgEnableMiniDump",
        "COMPlus_DbgEnableMiniDump", "DOTNET_DbgMiniDumpName", "COMPlus_DbgMiniDumpName", "DOTNET_DbgMiniDumpType",
        "COMPlus_DbgMiniDumpType", "DOTNET_DbgTransportProxyAddress", "COMPlus_DbgTransportProxyAddress", "DOTNET_StressLog",
        "COMPlus_StressLog", "DOTNET_StressLogFilename", "COMPlus_StressLogFilename", "DOTNET_ReadyToRunLogFile",
        "COMPlus_ReadyToRunLogFile", "DOTNET_JitStdOutFile", "COMPlus_JitStdOutFile", "DOTNET_PerfMapEnabled",
        "COMPlus_PerfMapEnabled", "DOTNET_PerfMapJitDumpPath", "COMPlus_PerfMapJitDumpPath", "DOTNET_MODIFIABLE_ASSEMBLIES",
        "COMPlus_MODIFIABLE_ASSEMBLIES", "DOTNET_ZapBBInstrDir", "COMPlus_ZapBBInstrDir",
    ];

    public static readonly string[] ClearOnly =
    [
        "COREHOST_TRACE", "COREHOST_TRACEFILE", "COREHOST_TRACE_VERBOSITY", "DOTNET_ROOT",
        "DOTNET_ROOT(x86)", "DOTNET_ROOT_X64", "DOTNET_ROOT_X86", "DOTNET_ROOT_ARM64",
        "DOTNET_ROOT_ARM", "DOTNET_BUNDLE_EXTRACT_BASE_DIR", "COMPLUS_INSTALLROOT", "COMPLUS_VERSION",
    ];

    public static readonly string[] Pinned =
    [
        "DOTNET_EnableDiagnostics", "COMPlus_EnableDiagnostics", "DOTNET_EnableDiagnostics_IPC", "COMPlus_EnableDiagnostics_IPC",
        "DOTNET_EnableDiagnostics_Debugger", "COMPlus_EnableDiagnostics_Debugger", "DOTNET_EnableDiagnostics_Profiler", "COMPlus_EnableDiagnostics_Profiler",
    ];

    public static readonly string[] ProductOverrides =
    [
        "ROO_INDUSTRIES_BACKEND_ROOT", "ROO_INDUSTRIES_DOTNET_EXE", "ROO_INDUSTRIES_PYTHON_EXE", "ROO_INDUSTRIES_UTILITIES_ROOT",
        .. new[] { "BACKEND_ROOT", "DOTNET_EXE", "PYTHON_EXE", "UTILITIES_ROOT" }.Select(name => BrandCompatibility.LegacyEnvironmentPrefix + name),
    ];

#if ROO_INDUSTRIES_RELEASE
    public static readonly bool Release = true;
#else
    public static readonly bool Release = false;
#endif

    private static readonly string[] MachineNames = ["OS", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION"];
    private static readonly string[] DeveloperPrefixes = [BrandCompatibility.LegacyEnvironmentPrefix];
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
        var profileDrive = Path.GetPathRoot(profile)!.TrimEnd('\\');
        var systemDrive = Path.GetPathRoot(windows)!.TrimEnd('\\');
        var programData = ProfileListFolder("ProgramData", systemDrive) ?? Path.Combine(systemDrive + "\\", "ProgramData");
        var temp = ProtectedTemp(windows);
        var child = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SystemRoot"] = windows, ["windir"] = windows, ["SystemDrive"] = systemDrive, ["ComSpec"] = Path.Combine(system, "cmd.exe"),
            ["PATH"] = string.Join(';', system, windows, Path.Combine(system, "Wbem"), Path.Combine(system, "WindowsPowerShell", "v1.0")),
            ["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC",
            ["TEMP"] = temp, ["TMP"] = temp, ["PSModulePath"] = ModulePath,
            ["ProgramFiles"] = programFiles, ["ProgramW6432"] = programFiles, ["ProgramFiles(x86)"] = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            ["CommonProgramFiles"] = commonFiles, ["CommonProgramW6432"] = commonFiles, ["CommonProgramFiles(x86)"] = Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFilesX86),
            ["ProgramData"] = programData, ["ALLUSERSPROFILE"] = programData, ["PUBLIC"] = ProfileListFolder("Public", systemDrive) ?? Path.Combine(Path.GetDirectoryName(profile)!, "Public"),
            ["USERPROFILE"] = profile, ["HOMEDRIVE"] = profileDrive, ["HOMEPATH"] = profile[profileDrive.Length..],
            ["LOCALAPPDATA"] = Path.Combine(profile, "AppData", "Local"), ["APPDATA"] = Path.Combine(profile, "AppData", "Roaming"),
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

    public static void OpenInExplorer(string target)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = false };
        Apply(start);
        start.ArgumentList.Add(target);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Windows Explorer did not start.");
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
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException or ArgumentException or System.ComponentModel.Win32Exception or System.Security.SecurityException) { }
        return Path.Combine(windows, "Temp");
    }

    private static string UserDomain()
    {
        try { return Environment.UserDomainName; }
        catch (InvalidOperationException) { return Environment.MachineName; }
    }

    private static string? ProfileListFolder(string name, string systemDrive)
    {
        try
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList");
            if (key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not string { Length: > 0 } raw) return null;
            var path = raw.Replace("%SystemDrive%", systemDrive, StringComparison.OrdinalIgnoreCase);
            return path.Contains('%') || !Path.IsPathFullyQualified(path) ? null : path;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return null; }
    }

    public static void Sanitize()
    {
        foreach (var name in CodeLoading.Concat(ClearOnly)) Environment.SetEnvironmentVariable(name, null);
        foreach (var name in Pinned) Environment.SetEnvironmentVariable(name, "0");
        if (Release) foreach (var name in ProductOverrides) Environment.SetEnvironmentVariable(name, null);
    }

    public static void RequireClean()
    {
        var present = CodeLoading.Concat(Pinned.Where(name => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value && value != "0")).Where(name => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable(name))).ToArray();
        if (present.Length > 0) throw new InvalidOperationException("Roo Industries will not run with these .NET settings in its environment: " + string.Join(", ", present) + ". Remove them and sign in again.");
    }
}
