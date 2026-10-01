using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.OptimizationSuite.Services;

static class ToolLauncherChecks
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetShellWindow();

    public static void Run(Action<bool, string> check, string fixture)
    {
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TOOL_LAUNCHER_SCENARIO") == "fallback") { UtilitiesFallback(check, fixture); return; }
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-tool-launcher-" + Guid.NewGuid().ToString("N"));
        var id = "fixture-" + Guid.NewGuid().ToString("N");
        var cacheRoot = Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "tool-cache");
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
            var userCopy = Path.Combine(root, "user-utilities", "Other", "Fixture", "SCEWIN64.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(userCopy)!);
            File.Copy(Path.Combine(fixture, "SCEWIN64.exe"), userCopy);
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", Path.Combine(root, "user-utilities"));
            check(service.Resolve(tool).FromArchive, "A user-writable Utilities copy is not launched when the shipped archive has the tool");
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", Path.Combine(root, "absent"));
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
        UtilitiesFallback(check, fixture);
    }

    private static void UtilitiesFallback(Action<bool, string> check, string fixture)
    {
        var probe = Path.Combine(fixture, "IntegrityProbe.exe");
        if (!File.Exists(probe)) throw new InvalidDataException("The fallback check requires the compiled integrity probe.");
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-utilities-" + Guid.NewGuid().ToString("N"));
        var utilities = Path.Combine(root, "Utilities Folder");
        var copy = Path.Combine(utilities, "Other", "Probe", "IntegrityProbe.exe");
        var report = Path.Combine(Path.GetDirectoryName(copy)!, "probe-report.txt");
        var evidence = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TOOL_LAUNCHER_EVIDENCE") is { Length: > 0 } named ? named : Path.Combine(fixture, "tool-launcher-evidence.txt");
        var oldRoot = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT");
        var tool = new ToolDefinition("probe-" + Guid.NewGuid().ToString("N"), "Integrity probe", "Token probe", "Diagnostics", "https://example.invalid/", "Utilities/Other/Probe/IntegrityProbe.exe", [], "open", null);
        using var policy = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System");
        var enableLua = policy?.GetValue("EnableLUA") is int lua ? lua : 1;
        var elevated = RooIndustries.Optimizer.PolicyRootSecurity.Elevated();
        var shell = GetShellWindow() != IntPtr.Zero;
        var lines = new List<string>
        {
            "Tool launcher fallback evidence " + DateTime.UtcNow.ToString("u"),
            "pc=" + Environment.MachineName + " user=" + Environment.UserName + " session=" + System.Diagnostics.Process.GetCurrentProcess().SessionId,
            "uac: EnableLUA=" + enableLua + " ConsentPromptBehaviorAdmin=" + (policy?.GetValue("ConsentPromptBehaviorAdmin") ?? "unset") + " FilterAdministratorToken=" + (policy?.GetValue("FilterAdministratorToken") ?? "unset"),
            "test host elevated=" + elevated + " explorer shell window present=" + shell
        };
        try
        {
            if (enableLua == 0 || !elevated)
            {
                var reason = enableLua == 0 ? "UAC is off (EnableLUA=0), so every process an administrator starts already has the full token and a normal-rights start cannot be told apart from an elevated one"
                    : "the test host is not elevated, so a child started without elevation cannot be told apart from a normal start";
                lines.Add("not meaningful on this PC: " + reason);
                Console.WriteLine("NOTE The Utilities fallback elevation check is not meaningful on this PC: " + reason);
            }
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
                File.Copy(probe, copy);
                Directory.CreateDirectory(Path.Combine(root, "package"));
                Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", utilities);
                var service = new ToolLauncherService(Path.Combine(root, "package"));
                lines.Add("route: " + service.Resolve(tool).Path + " (user-writable fallback folder, no shipped archive)");
                Exception? refused = null;
                try { service.OpenAsync(tool).GetAwaiter().GetResult(); } catch (InvalidOperationException error) { refused = error; }
                var until = DateTime.UtcNow.AddSeconds(shell ? 20 : 3);
                while (!File.Exists(report) && DateTime.UtcNow < until) Thread.Sleep(50);
                var text = File.Exists(report) ? File.ReadAllText(report).TrimEnd() : "";
                lines.Add(text.Length > 0 ? "probe report:" : "probe report: none (the probe never ran)");
                if (text.Length > 0) lines.Add(text);
                if (refused is not null) lines.Add("launcher refused: " + refused.Message);
                var expected = shell ? text.Contains("elevated=false") && !text.Contains("integrity=0x3") && !text.Contains("integrity=0x4") : text.Length == 0 && refused is not null;
                lines.Add("verdict: " + (expected ? "PASS" : "FAIL"));
                check(expected, shell ? "A tool started from the user-writable Utilities fallback runs without the app's elevated token" : "With no Windows shell to hand the start to, the launcher refuses instead of starting the user-writable tool elevated");
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", oldRoot);
            File.WriteAllLines(evidence, lines);
            for (var attempt = 0; attempt < 25 && Directory.Exists(root); attempt++)
            {
                try { Directory.Delete(root, recursive: true); } catch (IOException) { Thread.Sleep(200); } catch (UnauthorizedAccessException) { Thread.Sleep(200); }
            }
        }
        check(!Directory.Exists(root), "The fallback check removes its temporary Utilities folder");
    }
}
