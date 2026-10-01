#nullable enable
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

    public static string PowerShellPrelude => "$env:PSModulePath='" + (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules") + ";" +
        Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "Modules")).Replace("'", "''") + "'; ";

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
