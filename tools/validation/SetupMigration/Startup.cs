using System.Diagnostics;
using System.Text.Json;
using RooIndustries.Optimizer;
using RooIndustries.OptimizationSuite.Services;

var work = Path.GetFullPath(args[0]);
var descriptor = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(work, "setup-migration-fixture.json"))).RootElement;
var local = descriptor.GetProperty("local").GetString()!;
using var hive = new SetupMigrationHive(Path.Combine(work, "hives", "startup-" + Environment.ProcessId + ".hive"), local);
var result = DataFolderGate.Open(new BackendLocator(work, descriptor.GetProperty("repo").GetString()!));
Console.WriteLine(JsonSerializer.Serialize(new { opened = result, root = DataFolder.Root, secured = DataFolder.Secured(DataFolder.Root), marker = PolicyRootSecurity.Marked(PolicyRootSecurity.MarkerName(DataFolder.Root)), deepProblem = PolicyRootSecurity.Problem(DataFolder.Root, DataFolder.Kind) }));

namespace RooIndustries.OptimizationSuite.Services
{
    public sealed record BackendLocator(string Work, string Root);
    public sealed class PreparingWindow : IDisposable
    {
        public PreparingWindow(TimeSpan delay) { }
        public void Report(string text) { }
        public void Dispose() { }
    }
    public static class AppLog { public static bool Enable() => true; }
    public sealed class OptimizerService(BackendLocator locator)
    {
        public async Task SecureDataFolderAsync(Action<string> progress)
        {
            var start = new ProcessStartInfo(Path.Combine(locator.Root, "backend", "bin", "optimizer", "Optimizer.Host.exe")) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("data-secure"); start.ArgumentList.Add("-");
            RuntimeEnvironment.Apply(start);
            using var child = Process.Start(start)!;
            await child.StandardInput.WriteAsync(JsonSerializer.Serialize(new { schemaVersion = 1, repoRoot = locator.Root, confirm = true })); child.StandardInput.Close();
            var output = child.StandardOutput.ReadToEndAsync(); var error = child.StandardError.ReadToEndAsync();
            await child.WaitForExitAsync();
            var text = await output; var errors = await error;
            File.WriteAllText(Path.Combine(locator.Work, "startup-host-output.json"), text);
            File.WriteAllText(Path.Combine(locator.Work, "startup-host-error.txt"), errors);
            if (child.ExitCode != 0) throw new InvalidOperationException(text + errors);
        }
    }
}
