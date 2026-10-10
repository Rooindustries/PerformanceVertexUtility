using System.Text;
using System.Text.Json;
using RooIndustries.Optimizer;
using H = DataRootHarness;

static partial class DataFolderChecks
{
    private static void InflightScript(Action<bool, string> check)
    {
        var id = H.Name("inflight-script");
        var parent = Path.Combine(H.Local, id);
        var legacy = Path.Combine(parent, BrandCompatibility.LegacyDataFolder);
        var temporary = legacy + ".secure-" + Guid.NewGuid().ToString("N");
        Directory.CreateDirectory(parent);
        try
        {
            using var isolated = new DataRootPrivateHive(Path.Combine(parent, "machine.hive"));
            PolicyRootSecurity.Secure(temporary, DataFolder.Kind);
            File.WriteAllText(Path.Combine(temporary, ".migrating"), JsonSerializer.Serialize(new { id = Guid.NewGuid().ToString("N"), source = legacy, started = DateTime.UtcNow.ToString("O") }));
            check(PolicyRootSecurity.MigrationInFlight(parent, BrandCompatibility.LegacyDataFolder) && BrandCompatibility.DataRoot(parent) == legacy, "C# keeps returning the legacy path while its protected migration is in flight");
            var source = new DirectoryInfo(AppContext.BaseDirectory);
            while (source is not null && !File.Exists(Path.Combine(source.FullName, "backend", "scripts", "BrandCompatibility.Common.ps1"))) source = source.Parent;
            var common = Path.Combine(source!.FullName, "backend", "scripts", "BrandCompatibility.Common.ps1");
            var script = "$ErrorActionPreference='Stop';. " + H.Quote(common) + ";Get-RooIndustriesLocalDataRoot -LocalData " + H.Quote(parent);
            var result = H.Run(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"), "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(script)));
            Console.WriteLine("MEASURE scriptMigration " + result.Output);
            check(result.Exit != 0 && result.Output.Contains("Roo Industries is preparing your saved settings. Try again in a moment.", StringComparison.Ordinal), "The PowerShell twin refuses to create a partial current root during migration");
            check(!Directory.Exists(Path.Combine(parent, "RooIndustriesOptimizationSuite")), "No partial current data root was created during the migration");
        }
        finally { H.Delete(parent); }
        check(!Directory.Exists(parent), "The in-flight migration fixture and private markers were removed");
    }
}
