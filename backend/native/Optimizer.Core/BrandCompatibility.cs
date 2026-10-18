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

    private static readonly Lazy<string> Local = new(() => DefaultDataRoot(RuntimeEnvironment.LocalAppData));
    public static string LocalDataRoot => Local.Value;

    private static string DefaultDataRoot(string localAppData)
    {
        using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
        using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
        var roots = (key?.GetValueNames() ?? []).Where(name => !name.Contains('|') &&
            (string.Equals(Path.GetFileName(name), LegacyDataFolder, StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetFileName(name), "RooIndustriesOptimizationSuite", StringComparison.OrdinalIgnoreCase)) &&
            key!.GetValue(name, null, Microsoft.Win32.RegistryValueOptions.DoNotExpandEnvironmentNames) is string sid && sid == identity.User!.Value).ToArray();
        foreach (var leaf in new[] { LegacyDataFolder, "RooIndustriesOptimizationSuite" })
            if (key?.GetValue(PolicyRootSecurity.MarkerName(Path.Combine(localAppData, leaf))) is { } owner && !string.Equals(owner as string, identity.User!.Value, StringComparison.Ordinal))
                throw new InvalidOperationException("The protected data folder marker belongs to another Windows user.");
        var parent = PolicyRootSecurity.CanonicalPath(localAppData);
        if (roots.Any(root => !Path.IsPathFullyQualified(root) || !string.Equals(PolicyRootSecurity.CanonicalPath(Path.GetDirectoryName(root)!), parent, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("This Windows user's AppData folder setting changed or names several protected folders. The app kept the existing data. Restore the folder setting before opening the app again.");
        foreach (var root in roots)
            if (!Directory.Exists(root) || PolicyRootSecurity.Problem(root, DataFolder.Kind, deep: false) is not null || PolicyRootSecurity.HasPendingDataRootRepair(root))
                PolicyRootSecurity.RepairMarkedDataRoot(root);
        return DataRoot(localAppData);
    }

    public static string DataRoot(string localAppData)
    {
        var legacy = Path.Combine(localAppData, LegacyDataFolder);
        var current = Path.Combine(localAppData, "RooIndustriesOptimizationSuite");
        if (!Directory.Exists(legacy)) return Migrating(localAppData, legacy) ? legacy : current;
        return OperatingSystem.IsWindows() && PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(current)) && !PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(legacy)) ? current : legacy;
    }

    private static bool Migrating(string localAppData, string legacy)
        => OperatingSystem.IsWindows() && PolicyRootSecurity.MigrationInFlight(localAppData, Path.GetFileName(legacy));

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
