#nullable enable
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

    public static string PowerShellPrelude => "$env:PSModulePath='" + (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules") + ";" +
        Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "Modules")).Replace("'", "''") + "'; ";

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
