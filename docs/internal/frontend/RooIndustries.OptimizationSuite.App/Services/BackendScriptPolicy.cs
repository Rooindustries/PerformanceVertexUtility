using System;
using System.IO;

namespace RooIndustries.OptimizationSuite.Services;

public static class BackendScriptPolicy
{
    private static readonly string[] RemoverScripts = ["Invoke-UninstallCleanupApplyPackage.ps1"];
    public static bool LaunchesRemovers(string scriptPath) => Array.Exists(RemoverScripts, name => string.Equals(name, Path.GetFileName(scriptPath), StringComparison.OrdinalIgnoreCase));
    public static TimeSpan? Timeout(string scriptPath) => LaunchesRemovers(scriptPath) ? null
        : string.Equals(Path.GetFileName(scriptPath), "Apply-ProcessProfile.ps1", StringComparison.OrdinalIgnoreCase) ? TimeSpan.FromMinutes(10)
        : TimeSpan.FromSeconds(45);
    public static bool StopWholeTree(string scriptPath) => !LaunchesRemovers(scriptPath);
}
