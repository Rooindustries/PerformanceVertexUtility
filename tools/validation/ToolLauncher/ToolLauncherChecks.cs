using System.IO.Compression;
using System.Text.Json;
using RooIndustries.OptimizationSuite.Services;

static class ToolLauncherChecks
{
    public static void Run(Action<bool, string> check, string fixture)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-tool-launcher-" + Guid.NewGuid().ToString("N"));
        var id = "fixture-" + Guid.NewGuid().ToString("N");
        var cacheRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RooIndustriesOptimizationSuite", "tools");
        var cache = Path.Combine(cacheRoot, id);
        var oldRoot = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT");
        var relative = "Utilities/Other/Fixture/SCEWIN64.exe";
        var tool = new ToolDefinition(id, "File fixture", "File-only CLI", "Diagnostics", "https://example.invalid/", relative, [], "open", null);
        var authority = Path.Combine(fixture, "fixture-authority.txt");
        if (!File.Exists(authority) || File.ReadAllText(authority) != "roo-industries-firmware-cli-fixture/v1") throw new InvalidDataException("Tool launch requires the disposable CLI fixture.");
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "vendor"));
            Directory.CreateDirectory(Path.Combine(root, "modules"));
            File.WriteAllText(Path.Combine(root, "modules", "tool-launchers.json"), JsonSerializer.Serialize(new { tools = new[] { tool } }));
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", Path.Combine(root, "absent"));
            var service = new ToolLauncherService(root);
            check(service.ReadAsync().GetAwaiter().GetResult().Single().Name == "File fixture", "Tool launcher reads the named tool from its package catalog");
            check(service.Resolve(tool).Action == "Get", "A missing tool offers its download page rather than pretending to be installed");
            var archive = Path.Combine(root, "vendor", "Utilities.zip");
            void Bundle(bool invalid)
            {
                File.Delete(archive);
                using var zip = ZipFile.Open(archive, ZipArchiveMode.Create);
                zip.CreateEntryFromFile(Path.Combine(fixture, "SCEWIN64.exe"), relative);
                zip.CreateEntryFromFile(authority, "Utilities/Other/Fixture/fixture-authority.txt");
                using var writer = new StreamWriter(zip.CreateEntry(invalid ? "Utilities/Other/Fixture/../../../../escaped.txt" : "Utilities/Other/Fixture/dependency.txt").Open());
                writer.Write("fixture dependency");
            }
            Bundle(true);
            var rejected = false;
            try { service.OpenAsync(tool).GetAwaiter().GetResult(); } catch (InvalidDataException) { rejected = true; }
            check(rejected && !Directory.Exists(cache), "A malformed archive cannot escape its folder or publish a partially extracted tool");
            Bundle(false);
            check(service.Resolve(tool with { ArchivePath = "Utilities/absent.exe" }).Action == "Get", "A missing archive entry is not advertised as an available bundled tool");
            check(service.Resolve(tool).FromArchive && service.Resolve(tool with { BundleAction = "install" }).Action == "Install", "Bundled executables distinguish opening a tool from starting an installer");
            service.OpenAsync(tool).GetAwaiter().GetResult();
            var calls = Path.Combine(cache, "Utilities", "Other", "Fixture", "calls.log");
            var until = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(calls) && DateTime.UtcNow < until) Thread.Sleep(50);
            check(File.Exists(calls) && File.Exists(Path.Combine(cache, "Utilities", "Other", "Fixture", "dependency.txt")), "Open launches the disposable executable with its companion files after extraction completes");
            check(!service.Resolve(tool).FromArchive && service.Resolve(tool).Action == "Open", "A completely extracted portable tool is reused without a download");
            Thread.Sleep(150);
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", oldRoot);
            if (Directory.Exists(cache)) Directory.Delete(cache, recursive: true);
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
        check(!Directory.Exists(cache) && !Directory.Exists(root), "Tool launcher verification removes its executable, cache and package fixture");
    }
}
