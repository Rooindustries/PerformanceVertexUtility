using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using RooIndustries.Optimizer;

public sealed record MigrationFixture(string Work, string Local, string DataRoot, string Repo, string Probe);

public static class SetupMigrationBootstrap
{
    static SetupMigrationHive? hive;
    public static MigrationFixture Fixture = null!;
    public static string IdentityPath = "";

    [ModuleInitializer]
    public static void Initialize()
    {
        var descriptor = Path.Combine(AppContext.BaseDirectory, "setup-migration-fixture.json");
        if (!File.Exists(descriptor)) throw new InvalidDataException("Missing test-only descriptor.");
        Fixture = JsonSerializer.Deserialize<MigrationFixture>(File.ReadAllBytes(descriptor), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        if (!Directory.Exists(Fixture.Work) || !File.Exists(Path.Combine(Fixture.Work, "fixture-owner.txt")) || !Directory.Exists(Fixture.Local)) throw new InvalidDataException("Unowned test fixture.");
        using var process = Process.GetCurrentProcess();
        var identity = new { processId = process.Id, created = process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(), executable = Environment.ProcessPath, commandLine = Environment.CommandLine, descriptorHash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(descriptor))) };
        IdentityPath = Path.Combine(Fixture.Work, "identities", process.Id + "-" + identity.created + ".json");
        Directory.CreateDirectory(Path.GetDirectoryName(IdentityPath)!);
        File.WriteAllText(IdentityPath, JsonSerializer.Serialize(identity));
        hive = new SetupMigrationHive(Path.Combine(Fixture.Work, "hives", process.Id + "-" + identity.created + ".hive"), Fixture.Local);
        RuntimeEnvironment.Sanitize();
        RuntimeEnvironment.PinProfile();
        if (!string.Equals(BrandCompatibility.LocalDataRoot, Fixture.DataRoot, StringComparison.OrdinalIgnoreCase) || !DataFolder.Holds(Path.Combine(Fixture.DataRoot, "process-rules"))) throw new InvalidDataException("Fixture did not resolve the actual data root.");
        File.WriteAllText(IdentityPath + ".root.json", JsonSerializer.Serialize(new { local = RuntimeEnvironment.LocalAppData, root = BrandCompatibility.LocalDataRoot, holds = DataFolder.Holds(Path.Combine(Fixture.DataRoot, "process-rules")) }));
        if (Environment.GetCommandLineArgs().Contains("policy-secure") && File.Exists(Path.Combine(Fixture.Work, "pause.flag")))
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT", "copied");
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS", "30000");
        }
        if (Environment.GetCommandLineArgs().Contains("--fixture-seed"))
        {
            RuntimeEnvironment.Establish();
            var root = Path.Combine(Fixture.DataRoot, "process-rules");
            PolicyRootSecurity.Secure(root);
            Directory.CreateDirectory(Path.Combine(root, "rules"));
            var rule = new SavedProcessRule { SchemaVersion = 1, RuleId = "f1200000000000000000000000000000", Owner = OperationOwner.Current(), Revision = "f1200000000000000000000000000001", Name = "F12 fresh probe", Enabled = true, MatchMode = "path", ExecutablePath = Fixture.Probe, ExecutableHash = null, Controls = new() { ["cpuPriority"] = JsonSerializer.SerializeToElement("AboveNormal") }, CpuSelection = null };
            OperationFiles.Write(Path.Combine(root, "rules", rule.RuleId + ".json"), rule);
            OperationFiles.Write(Path.Combine(root, "worker-request.json"), new { schemaVersion = 1, repoRoot = Fixture.Repo, policyRoot = root, confirm = true });
            Console.WriteLine("SEEDED " + root);
            Environment.Exit(0);
        }
    }
}
