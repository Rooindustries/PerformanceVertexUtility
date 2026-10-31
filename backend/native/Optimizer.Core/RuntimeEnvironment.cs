#nullable enable
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

public static class RuntimeEnvironment
{
    public const string ExplorerNotRunning = "Windows Explorer is not running. Sign in to Windows, then try again.";

    public static readonly string[] ClearPrefixes = ["DOTNET_", "COMPlus_", "CORECLR_", "COR_", "COREHOST_"];

    public static readonly string[] DevelopmentCodeLoading =
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

    public static readonly string[] DevelopmentClearOnly =
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

    private static readonly string[] MachineNames = ["OS", "NUMBER_OF_PROCESSORS", "PROCESSOR_IDENTIFIER", "PROCESSOR_LEVEL", "PROCESSOR_REVISION"];
    private static readonly string[] DeveloperPrefixes = [BrandCompatibility.LegacyEnvironmentPrefix];
    private static readonly string[] DeveloperNames = ["DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_ROOT_X86", "DOTNET_ROOT_ARM64", "DOTNET_ROOT(x86)"];
    private static string? _protectedTemp;

    private static string ModulePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules") + ";" +
        Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "Modules");

    // Windows PowerShell writes progress (such as "Preparing modules for first use") to a redirected error stream as a
    // CLIXML block. Nothing here shows progress, so it stays out of the stream the app reads errors from.
    public static string PowerShellPrelude => "$ProgressPreference='SilentlyContinue'; $env:PSModulePath='" + ModulePath.Replace("'", "''") + "'; "
#if ROO_INDUSTRIES_TEST_HOOKS
        + (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_MODULES") is { Length: > 0 } modules
            ? "Import-Module " + string.Join(",", modules.Split(';').Select(module => "'" + module.Replace("'", "''") + "'")) + "; $global:PSModuleAutoLoadingPreference='None'; $env:PSModulePath='" +
                (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_MODULE_PATH") ?? Path.Combine(Path.GetTempPath(), "roo-industries-no-modules-" + Guid.NewGuid().ToString("N"))).Replace("'", "''") + "'; " : "")
#endif
        ;

    // Runs a script so that its terminating error reaches the caller as the plain message on the error stream. Windows
    // PowerShell would write it as a CLIXML block, wrapped at the console width, and the app could only say something went wrong.
    public static string PowerShellCall(string invocation) => "try{" + invocation + "}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}";

    private static readonly Lazy<string> TokenProfile = new(() =>
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        var size = 32768;
        var buffer = new System.Text.StringBuilder(size);
        if (!GetUserProfileDirectory(identity.Token, buffer, ref size)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        var profile = buffer.ToString();
        if (!Path.IsPathFullyQualified(profile) || !Directory.Exists(profile)) throw new InvalidOperationException("The app could not read this Windows user's profile folder.");
        return profile;
    });
    private static readonly Lazy<string> Local = new(() => UserFolder(System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value, Profile, false));
    private static readonly Lazy<string> Roaming = new(() => UserFolder(System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value, Profile, true));
    public static string Profile => TokenProfile.Value;
    public static string LocalAppData => Local.Value;
    public static string RoamingAppData => Roaming.Value;
    public static string UserTemp => Path.Combine(Profile, "AppData", "Local", "Temp");

    [DllImport("userenv.dll", EntryPoint = "GetUserProfileDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetUserProfileDirectory(IntPtr token, System.Text.StringBuilder buffer, ref int size);

    internal static string UserFolder(string sid, string profile, bool roaming)
    {
        using var users = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var hive = users.OpenSubKey(sid) ?? throw new InvalidOperationException("The app could not read that Windows user's folder settings.");
        using var key = hive.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders");
        var name = roaming ? "AppData" : "Local AppData";
        var value = key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
        string path;
        if (value is null) path = Path.Combine(profile, "AppData", roaming ? "Roaming" : "Local");
        else if (value is string raw && key!.GetValueKind(name) is RegistryValueKind.String or RegistryValueKind.ExpandString)
            path = raw.Replace("%USERPROFILE%", profile, StringComparison.OrdinalIgnoreCase);
        else throw FolderSettingsProblem();
        if (path.Length == 0 || path.Count(character => character == '%') > 1 || path.Any(character => character < ' ' || "<>\"|?*".Contains(character)) || path.StartsWith(@"\\?\") || path.StartsWith(@"\\.\")) throw FolderSettingsProblem();
        if (roaming && path.StartsWith(@"\\"))
        {
            var parts = path.TrimEnd('\\')[2..].Split('\\');
            if (parts.Length < 2 || parts.Any(part => part.Length == 0 || part is "." or ".." || part.Contains(':'))) throw FolderSettingsProblem();
            return path.TrimEnd('\\');
        }
        if (path.Length < 4 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\' || path[3..].Contains(':') || !Path.IsPathFullyQualified(path) || path.TrimEnd('\\')[3..].Split('\\').Any(part => part.Length == 0 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' '))) throw FolderSettingsProblem();
        path = Path.GetFullPath(path).TrimEnd('\\');
        if (!roaming)
        {
            if (new DriveInfo(Path.GetPathRoot(path)!).DriveType != DriveType.Fixed || !Directory.Exists(path)) throw FolderSettingsProblem();
            for (var directory = new DirectoryInfo(path); directory is not null; directory = directory.Parent)
                if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw FolderSettingsProblem();
            var canonical = PolicyRootSecurity.CanonicalPath(path);
            foreach (var system in new[] { Environment.GetFolderPath(Environment.SpecialFolder.Windows), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), InstallFolder() })
            {
                if (string.IsNullOrWhiteSpace(system)) continue;
                var blocked = PolicyRootSecurity.CanonicalPath(system);
                if (string.Equals(canonical, blocked, StringComparison.OrdinalIgnoreCase) || canonical.StartsWith(blocked + "\\", StringComparison.OrdinalIgnoreCase)) throw FolderSettingsProblem();
            }
        }
        return path;
    }

    private static string InstallFolder()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        var optimizer = directory.Name.Equals("session", StringComparison.OrdinalIgnoreCase) ? directory.Parent : directory;
        if (optimizer?.Name.Equals("optimizer", StringComparison.OrdinalIgnoreCase) == true && optimizer.Parent?.Name.Equals("bin", StringComparison.OrdinalIgnoreCase) == true && optimizer.Parent.Parent?.Name.Equals("backend", StringComparison.OrdinalIgnoreCase) == true)
            return optimizer.Parent.Parent.Parent!.FullName;
        return directory.Name.Equals("app", StringComparison.OrdinalIgnoreCase) ? directory.Parent!.FullName : directory.FullName;
    }

    public static string OwnershipReviewExecutable()
    {
        var root = InstallFolder();
        var folder = Path.Combine(root, "app");
        var ui = Path.Combine(folder, "RooIndustries.OptimizationSuite.App.exe");
        try
        {
            if (PolicyRootSecurity.AdministratorOnlyEntry(root, true) && PolicyRootSecurity.AdministratorOnlyEntry(folder, true) && PolicyRootSecurity.AdministratorOnlyEntry(ui, false)) return ui;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        if (!Release && BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_UI_EXE") is { } development && Path.IsPathFullyQualified(development) && development.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(development)) return development;
        throw new InvalidDataException("The ownership-review app is missing, damaged, or outside a protected install folder. Install the app again.");
    }

    private static InvalidOperationException FolderSettingsProblem() => new("The app could not use this Windows user's AppData folder settings. Choose an existing local folder on a fixed drive outside Windows and the app's install folder.");

    public static Dictionary<string, string> ChildEnvironment() => Build(null);

    private static Dictionary<string, string> Build(string? userTemp)
    {
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        var system = Environment.SystemDirectory;
        var profile = Profile;
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var commonFiles = Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles);
        var profileDrive = Path.GetPathRoot(profile)!.TrimEnd('\\');
        var systemDrive = Path.GetPathRoot(windows)!.TrimEnd('\\');
        var programData = ProfileListFolder("ProgramData", systemDrive) ?? Path.Combine(systemDrive + "\\", "ProgramData");
        var temp = userTemp ?? ProtectedTemp(windows);
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
            ["LOCALAPPDATA"] = LocalAppData, ["APPDATA"] = RoamingAppData,
            ["USERNAME"] = Environment.UserName, ["USERDOMAIN"] = UserDomain(), ["COMPUTERNAME"] = Environment.MachineName,
            ["OS"] = "Windows_NT", ["DriverData"] = Path.Combine(system, "Drivers", "DriverData"),
            ["NUMBER_OF_PROCESSORS"] = Environment.ProcessorCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["PROCESSOR_ARCHITECTURE"] = RuntimeInformation.ProcessArchitecture switch { Architecture.Arm64 => "ARM64", Architecture.Arm => "ARM", Architecture.X86 => "x86", _ => "AMD64" },
        };
        try
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = machine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment");
            foreach (var name in MachineNames)
                if (key?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is string { Length: > 0 } value) child[name] = value;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
        foreach (var name in Pinned) child[name] = "0";
        if (!Release)
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
                if (entry.Key is string name && entry.Value is string value && (DeveloperPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) || DeveloperNames.Contains(name, StringComparer.OrdinalIgnoreCase)))
                    child[name] = value;
#if ROO_INDUSTRIES_TEST_HOOKS
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            if (entry.Key is string name && entry.Value is string value && name.StartsWith("ROO_INDUSTRIES_TEST_", StringComparison.OrdinalIgnoreCase))
                child[name] = value;
#endif
        return child;
    }

    public static void Apply(ProcessStartInfo start)
    {
        start.Environment.Clear();
        foreach (var (name, value) in ChildEnvironment()) start.Environment[name] = value;
    }

    private static readonly Lazy<Dictionary<string, string>> UserVariables = new(() => Build(UserTemp));
    private static readonly Regex Percent = new("%([^%]+)%", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    public static string ExpandUserVariables(string text)
        => Percent.Replace(text, match => UserVariables.Value.TryGetValue(match.Groups[1].Value, out var value) ? value : match.Value);

    public static void PinProfile()
    {
        var profile = Profile;
        var drive = Path.GetPathRoot(profile)!.TrimEnd('\\');
        Environment.SetEnvironmentVariable("USERPROFILE", profile);
        Environment.SetEnvironmentVariable("HOMEDRIVE", drive);
        Environment.SetEnvironmentVariable("HOMEPATH", profile[drive.Length..]);
        Environment.SetEnvironmentVariable("LOCALAPPDATA", LocalAppData);
        Environment.SetEnvironmentVariable("APPDATA", RoamingAppData);
    }

    public static void Establish()
    {
        PinProfile();
        var block = ChildEnvironment();
        bool Kept(string name) => block.ContainsKey(name) || Pinned.Contains(name, StringComparer.OrdinalIgnoreCase) && Environment.GetEnvironmentVariable(name) == "0";
        foreach (var name in Environment.GetEnvironmentVariables().Keys.Cast<string>().Where(name => !Kept(name)).ToArray()) Clear(name);
        foreach (var (name, value) in block)
            if (value.Length > 0) Environment.SetEnvironmentVariable(name, value);
    }

    private static void Clear(string name)
    {
        try { Environment.SetEnvironmentVariable(name, null); }
        catch (ArgumentException) { }
    }

    private static string[] Prefixed()
        => Environment.GetEnvironmentVariables().Keys.Cast<string>().Where(name => ClearPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))).ToArray();

    public static void OpenInExplorer(string target, bool select = false)
    {
        if (GetShellWindow() == IntPtr.Zero) throw new InvalidOperationException(ExplorerNotRunning);
        if (select)
        {
            if (!Path.IsPathFullyQualified(target)) throw new InvalidOperationException("The selected file needs a full path.");
            target = Path.GetFullPath(target);
        }
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = false };
        Apply(start);
        if (select) start.ArgumentList.Add("/select,");
        start.ArgumentList.Add(target);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Windows Explorer did not start.");
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetShellWindow();

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
        // A standard user can create files in Windows\Temp but not read them back, so its scripts (Add-Type compiles there) use the user's own temp,
        // made again if the user moved TEMP elsewhere and removed it.
        if (PolicyRootSecurity.Elevated()) return Path.Combine(windows, "Temp");
        Directory.CreateDirectory(UserTemp);
        return UserTemp;
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
            return path.Count(character => character == '%') > 1 || !Path.IsPathFullyQualified(path) ? null : path;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return null; }
    }

    public static void Sanitize()
    {
        foreach (var name in Release ? Prefixed() : DevelopmentCodeLoading.Concat(DevelopmentClearOnly)) Clear(name);
        foreach (var name in Pinned) Environment.SetEnvironmentVariable(name, "0");
        if (Release) foreach (var name in ProductOverrides) Environment.SetEnvironmentVariable(name, null);
    }

    public static void RequireClean()
    {
        bool Set(string name) => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable(name));
        bool BadPin(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value && value != "0";
        var present = Release
            ? Prefixed().Where(name => !(Pinned.Contains(name, StringComparer.OrdinalIgnoreCase) && Environment.GetEnvironmentVariable(name) == "0"))
            : DevelopmentCodeLoading.Concat(DevelopmentClearOnly.Where(name => !DeveloperNames.Contains(name, StringComparer.OrdinalIgnoreCase))).Concat(Pinned.Where(BadPin)).Where(Set);
        var names = present.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
        if (names.Length > 0) throw new InvalidOperationException("The app will not run with these .NET settings in its environment: " + string.Join(", ", names) + ". Remove them and sign in again.");
    }
}
