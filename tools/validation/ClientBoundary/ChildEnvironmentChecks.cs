using System.Text;
using RooIndustries.OptimizationSuite.Services;

static class ChildEnvironmentChecks
{
    public static readonly string[] Scenarios = ["app-host", "app-script", "app-live-script"];

    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
        Console.WriteLine("PASS " + message);
    }

    public static async Task Run(string scenario, string mode)
    {
        switch (scenario)
        {
            case "app-host": await AppHost(mode); break;
            case "app-script": await Script(mode, "Invoke-ProcessCpuSets.ps1", "The app's script runner", async (backend, service) =>
            {
                var result = await service.ReadCpuSetsAsync(Environment.ProcessId);
                Check(result.Status == "success" && result.Errors.Count == 0, "The app accepted the script's JSON answer through OptimizerService.RunScriptAsync");
            }); break;
            case "app-live-script": await Script(mode, "Show-ChildEnvironment.ps1", "The app's live-data script runner", async (backend, service) =>
            {
                var result = await new LiveDataService(backend).RunBackendScriptResultAsync("Show-ChildEnvironment.ps1");
                Check(result.Error is null && result.Value?.Trim() == "child-environment-ok", "The app accepted the script's text answer through LiveDataService.RunScriptCoreAsync: " + result.Value + result.Error);
            }); break;
            default: throw new ArgumentException("Unknown child-environment scenario " + scenario);
        }
    }

    static string Temporary(string label) => Path.Combine(Path.GetTempPath(), "roo-industries-child-env-" + label + "-" + Guid.NewGuid().ToString("N"));

    static List<string> Verify(ChildEnv env, ChildObservation seen, string image, IEnumerable<KeyValuePair<string, string?>>? product = null, params string[] tolerated)
    {
        var failures = env.Verify(seen, product ?? [], tolerated);
        if (ChildEnv.ImageFailure(seen, image) is { } wrong) failures.Add(wrong);
        if (seen.ProcessId == Environment.ProcessId) failures.Add("the report came from the test process itself");
        return failures;
    }

    static async Task Script(string mode, string name, string label, Func<BackendLocator, OptimizerService, Task> call)
    {
        var root = Temporary("script");
        var scripts = Path.Combine(root, "backend", "scripts");
        Directory.CreateDirectory(Path.Combine(root, "backend", "samples"));
        Directory.CreateDirectory(scripts);
        try
        {
            var dump = "env-" + Path.GetFileNameWithoutExtension(name) + ".txt";
            var answer = name switch
            {
                "Invoke-ProcessCpuSets.ps1" => "param([string]$Action,[int]$TargetProcessId)\n{0}'{\"status\":\"success\",\"changed\":false,\"restoreAvailable\":false,\"data\":null,\"errors\":[]}'\n",
                "Show-ChildEnvironment.ps1" => "{0}'child-environment-ok'\n",
                _ => throw new ArgumentException("Unknown child-environment script " + name),
            };
            File.WriteAllText(Path.Combine(scripts, name), answer.Replace("{0}", ChildEnv.DumpScript("(Join-Path $PSScriptRoot '" + dump + "')")));
            var overrides = new Dictionary<string, string> { ["ROO_INDUSTRIES_BACKEND_ROOT"] = root };
            await ChildEnv.RunAsync(Check, mode, overrides, async env =>
            {
                var started = DateTime.UtcNow.AddSeconds(-1);
                var backend = new BackendLocator();
                Check(backend.RepoRoot == root, "The app locates the fixture backend root");
                await call(backend, new OptimizerService(backend, Path.Combine(root, "operations")));
                var seen = ChildEnv.ReadDump(Path.Combine(scripts, dump), started, "the script's own report");
                ChildEnv.Report(Check, label + " child", env, seen, Verify(env, seen, ChildEnv.PowerShell, null, ChildEnv.PowerShellAdds));
            });
        }
        finally { Directory.Delete(root, true); }
        Check(!Directory.Exists(root), "The scenario leaves no files behind");
    }

    static async Task AppHost(string mode)
    {
        var root = Temporary("app-host");
        var hostDirectory = Path.Combine(root, "backend", "bin", "optimizer");
        Directory.CreateDirectory(Path.Combine(root, "backend", "samples"));
        Directory.CreateDirectory(hostDirectory);
        try
        {
            foreach (var file in Directory.GetFiles(AppContext.BaseDirectory, "*.dll").Where(file => Path.GetFileName(file) != "ClientBoundary.dll")) File.Copy(file, Path.Combine(hostDirectory, Path.GetFileName(file)));
            File.Copy(Path.Combine(AppContext.BaseDirectory, "ClientBoundary.dll"), Path.Combine(hostDirectory, "Optimizer.Host.dll"));
            File.Copy(Path.Combine(AppContext.BaseDirectory, "ClientBoundary.runtimeconfig.json"), Path.Combine(hostDirectory, "Optimizer.Host.runtimeconfig.json"));
            var muxer = ChildEnv.DotNetMuxer();
            var overrides = new Dictionary<string, string> { ["ROO_INDUSTRIES_BACKEND_ROOT"] = root, ["ROO_INDUSTRIES_DOTNET_EXE"] = muxer };
            await ChildEnv.RunAsync(Check, mode, overrides, async env =>
            {
                var started = DateTime.UtcNow.AddSeconds(-1);
                var backend = new BackendLocator();
                Check(backend.RepoRoot == root, "The app locates the fixture backend root");
                var rules = await new OptimizerService(backend, Path.Combine(root, "operations")).ReadRulesAsync();
                Check(rules.Length == 0, "The app accepted the Host fixture's JSON answer through OptimizerService.RunHostAsync");
                var seen = ChildEnv.ReadDump(Path.Combine(hostDirectory, "host-env.txt"), started, "the Host fixture's own report");
                var failures = Verify(env, seen, muxer, [new("ROO_INDUSTRIES_UI_EXE", Environment.ProcessPath)]);
                if (seen.Meta.GetValueOrDefault("ARGS") != "rules-list|-") failures.Add("the Host was started with arguments '" + seen.Meta.GetValueOrDefault("ARGS") + "'");
                if (!string.Equals(seen.Meta.GetValueOrDefault("ENTRY"), Path.Combine(hostDirectory, "Optimizer.Host.dll"), StringComparison.OrdinalIgnoreCase)) failures.Add("the Host assembly started is '" + seen.Meta.GetValueOrDefault("ENTRY") + "'");
                ChildEnv.Report(Check, "App to Host child", env, seen, failures);
            });
        }
        finally { Directory.Delete(root, true); }
        Check(!Directory.Exists(root), "The scenario leaves no files behind");
    }
}

static class HostFixture
{
    public static async Task Run(string[] args)
    {
        using var input = new MemoryStream();
        await Console.OpenStandardInput().CopyToAsync(input);
        var report = new List<string>
        {
            "#IMAGE=" + Environment.ProcessPath, "#PID=" + Environment.ProcessId, "#ARGS=" + string.Join("|", args),
            "#ENTRY=" + System.Reflection.Assembly.GetEntryAssembly()!.Location, "#REQUEST=" + Encoding.UTF8.GetString(input.ToArray()).Replace("\r", "").Replace("\n", " "),
        };
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) report.Add(entry.Key + "=" + entry.Value);
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory, "host-env.txt"), report, new UTF8Encoding(false));
        Console.Out.WriteLine("{\"schemaVersion\":1,\"status\":\"completed\",\"data\":[]}");
    }
}
