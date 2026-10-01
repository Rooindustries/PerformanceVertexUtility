#nullable enable
namespace RooIndustries.Optimizer;

public static class BrandCompatibility
{
    public const string LegacyDataFolder = "RooOptimizationSuite";
    public const string LegacyPolicyTaskPrefix = "RooOptimizationSuite.ProcessRules.";
    public const string LegacyPolicyTaskDescription = "Roo process rules | ";
    public const string LegacyTheme = "roo-blue";
    public const string LegacyRestorePrefix = ".roo-restore-";
    public const string LegacyRegistryRoot = "Software\\RooOptimizationSuite";
    public const string ProcessMutexPrefix = "Local\\RooProcessControls-";
    public const string LaunchMutexPrefix = "Global\\RooLaunchPriorities-";
    public const string LauncherLeasePrefix = "roo-protected-launcher-";
    public const string LegacyJobPrefix = "Global\\RooProtectedSession-";
    public const string LegacyEnvironmentPrefix = "ROO_";

    private static readonly Lazy<string> Local = new(() => DataRoot(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)));
    public static string LocalDataRoot => Local.Value;

    public static string DataRoot(string localAppData)
    {
        var legacy = Path.Combine(localAppData, LegacyDataFolder);
        var current = Path.Combine(localAppData, "RooIndustriesOptimizationSuite");
        if (!Directory.Exists(legacy)) return current;
        return OperatingSystem.IsWindows() && PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(current)) && !PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(legacy)) ? current : legacy;
    }

    public static string? EnvironmentValue(string name)
    {
        if (!name.StartsWith("ROO_INDUSTRIES_", StringComparison.Ordinal)) throw new ArgumentException("Use the full product environment prefix.", nameof(name));
        var current = Environment.GetEnvironmentVariable(name);
        if (current is not null) return current;
        var legacy = Environment.GetEnvironmentVariable("ROO_" + name[15..]);
        if (legacy is not null) Environment.SetEnvironmentVariable(name, legacy);
        return legacy;
    }

    public static bool IsRestoreStage(string name) => name.StartsWith(".roo-industries-restore-", StringComparison.Ordinal) || name.StartsWith(LegacyRestorePrefix, StringComparison.Ordinal);
}
