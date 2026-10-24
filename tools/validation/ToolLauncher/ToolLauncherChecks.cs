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
        var cacheRoot = Path.Combine(Path.GetTempPath(), "roo-industries-tool-cache-" + Guid.NewGuid().ToString("N"));
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
            var service = new ToolLauncherService(root, cacheRoot, () => RooIndustries.Optimizer.OperationsFolder.Ensure(cacheRoot));
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
            if (Directory.Exists(cacheRoot)) Directory.Delete(cacheRoot, recursive: true);
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            using var markers = Registry.LocalMachine.OpenSubKey(RooIndustries.Optimizer.PolicyRootSecurity.MarkerKey, true);
            markers?.DeleteValue(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(cacheRoot), false);
            markers?.DeleteValue(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(cacheRoot) + RooIndustries.Optimizer.PolicyRootSecurity.ProtectedAtSuffix, false);
        }
        check(!Directory.Exists(cacheRoot) && !Directory.Exists(root), "Tool launcher verification removes its executable, cache and package fixture");
        PlainErrors(check);
        UtilitiesFallback(check, fixture);
    }

    private static void PlainErrors(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-tool-words-" + Guid.NewGuid().ToString("N"));
        var cacheRoot = Path.Combine(root, "cache");
        var oldRoot = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT");
        var tool = new ToolDefinition("fixture-" + Guid.NewGuid().ToString("N"), "Fixture Tool", "Plain words fixture", "Diagnostics", "https://example.invalid/", "Utilities/Other/Fixture/Broken.exe", [], "open", null);
        var archive = Path.Combine(root, "vendor", "Utilities.zip");
        Exception Failure(Func<Task> action)
        {
            try { action().GetAwaiter().GetResult(); }
            catch (Exception error) { return error; }
            throw new InvalidOperationException("The fixture failure did not happen.");
        }
        void Plain(string shown, Exception error, string expected, string label)
        {
            var raw = error.Message.Length > 0 && shown.Contains(error.Message, StringComparison.Ordinal);
            check(shown == expected && !raw && !shown.Contains("Exception", StringComparison.Ordinal) && !shown.Contains(":\\", StringComparison.Ordinal)
                && !shown.Contains(tool.Id, StringComparison.Ordinal) && !shown.Contains("Utilities.zip", StringComparison.Ordinal),
                label + " (" + error.GetType().Name + ") shows \"" + shown + "\" instead of the raw error");
        }
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "vendor"));
            Directory.CreateDirectory(Path.Combine(root, "modules"));
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", Path.Combine(root, "absent"));
            var service = new ToolLauncherService(root, cacheRoot, () => RooIndustries.Optimizer.OperationsFolder.Ensure(cacheRoot));

            var missing = Failure(() => service.ReadAsync());
            Plain(ToolLauncherService.ExplainList(missing), missing, ToolLauncherService.MissingFiles, "A missing tool list");
            File.WriteAllText(Path.Combine(root, "modules", "tool-launchers.json"), "{ \"tools\": [ { \"id\": ");
            var damagedList = Failure(() => service.ReadAsync());
            Plain(ToolLauncherService.ExplainList(damagedList), damagedList, "The tool list is damaged. Reinstall the app to fix it.", "A damaged tool list");

            File.WriteAllText(archive, "not a zip archive");
            var damagedPack = Failure(() => Task.Run(() => service.Resolve(tool)));
            Plain(ToolLauncherService.ExplainList(damagedPack), damagedPack, "The tool list is damaged. Reinstall the app to fix it.", "A damaged tool pack while the list loads");
            Plain(ToolLauncherService.Explain(tool, damagedPack), damagedPack, "The app's copy of Fixture Tool is damaged. Reinstall the app to fix it.", "A damaged tool pack when a tool opens");

            File.Delete(archive);
            var link = Failure(() => service.OpenAsync(tool with { Website = "http://example.invalid/" }));
            Plain(ToolLauncherService.Explain(tool, link), link, "Fixture Tool's download link is broken. Update the app to fix it.", "A tool with a broken download link");

            using (var zip = ZipFile.Open(archive, ZipArchiveMode.Create))
            using (var writer = new StreamWriter(zip.CreateEntry(tool.ArchivePath).Open())) writer.Write("not a program");
            var locked = new ToolLauncherService(root, cacheRoot, () => throw new UnauthorizedAccessException(RooIndustries.Optimizer.DataFolder.NotProtected + " (Access to the path 'C:\\ProgramData\\fixture' is denied.)"));
            var admin = Failure(() => locked.OpenAsync(tool));
            Plain(ToolLauncherService.Explain(tool, admin), admin, "Fixture Tool needs admin rights. Reopen the app as an administrator, then try again.", "A tool the app can't unpack without admin rights");

            var broken = Failure(() => service.OpenAsync(tool));
            check(broken is System.ComponentModel.Win32Exception, "A damaged tool file fails to start (" + broken.GetType().Name + ": " + broken.Message + ")");
            Plain(ToolLauncherService.Explain(tool, broken), broken, "The app's copy of Fixture Tool is damaged. Reinstall the app to fix it.", "A damaged tool file");

            var blocked = new System.ComponentModel.Win32Exception(225);
            Plain(ToolLauncherService.Explain(tool, blocked), blocked, "Your antivirus or Windows Security blocked Fixture Tool. Allow it there, then try again.", "A tool blocked by antivirus");
            var elevation = new System.ComponentModel.Win32Exception(740);
            Plain(ToolLauncherService.Explain(tool, elevation), elevation, "Fixture Tool needs admin rights. Reopen the app as an administrator, then try again.", "A tool that needs admin rights");
            var noShell = new InvalidOperationException(RooIndustries.Optimizer.RuntimeEnvironment.ExplorerNotRunning);
            Plain(ToolLauncherService.Explain(tool, noShell), noShell, "Windows Explorer isn't running. Sign in to Windows, then try again.", "A tool opened while Windows Explorer isn't running");
            var noExplorer = new InvalidOperationException("Windows Explorer did not start.");
            Plain(ToolLauncherService.Explain(tool, noExplorer), noExplorer, "Couldn't open Fixture Tool. Details are in the app log (Settings, Open logs folder).", "Windows Explorer failing to start");
            var unknown = new NotSupportedException("Fixture raw failure text");
            Plain(ToolLauncherService.Explain(tool, unknown), unknown, "Couldn't open Fixture Tool. Details are in the app log (Settings, Open logs folder).", "Any other tool failure");
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", oldRoot);
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            using var markers = Registry.LocalMachine.OpenSubKey(RooIndustries.Optimizer.PolicyRootSecurity.MarkerKey, true);
            markers?.DeleteValue(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(cacheRoot), false);
            markers?.DeleteValue(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(cacheRoot) + RooIndustries.Optimizer.PolicyRootSecurity.ProtectedAtSuffix, false);
        }
        check(!Directory.Exists(root), "The plain error check removes its tool pack, cache and package fixture");
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
                var service = new ToolLauncherService(Path.Combine(root, "package"), Path.Combine(root, "tool-cache"));
                lines.Add("route: " + service.Resolve(tool).Path + " (user-writable fallback folder, no shipped archive)");
                Exception? refused = null;
                try { service.OpenAsync(tool).GetAwaiter().GetResult(); } catch (InvalidOperationException error) { refused = error; }
                var until = DateTime.UtcNow.AddSeconds(shell ? 20 : 3);
                while (!File.Exists(report) && DateTime.UtcNow < until) Thread.Sleep(50);
                var text = File.Exists(report) ? File.ReadAllText(report).TrimEnd() : "";
                lines.Add(text.Length > 0 ? "probe report:" : "probe report: none (the probe never ran)");
                if (text.Length > 0) lines.Add(text);
                if (refused is not null) lines.Add("launcher refused: " + refused.Message);
                if (shell && text.Contains("elevated=true") && text.Contains("elevationType=Default"))
                {
                    const string unsplit = "the signed-in user's token is never split (elevationType=Default, for example the built-in Administrator with FilterAdministratorToken=0), so the Windows shell has no normal-rights token to hand the tool";
                    lines.Add("not meaningful on this PC: " + unsplit);
                    Console.WriteLine("NOTE The Utilities fallback elevation check is not meaningful on this PC: " + unsplit);
                }
                else
                {
                    var expected = shell ? text.Contains("elevated=false") && !text.Contains("integrity=0x3") && !text.Contains("integrity=0x4") : text.Length == 0 && refused is not null;
                    lines.Add("verdict: " + (expected ? "PASS" : "FAIL"));
                    check(expected, shell ? "A tool started from the user-writable Utilities fallback runs without the app's elevated token" : "With no Windows shell to hand the start to, the launcher refuses instead of starting the user-writable tool elevated");
                }
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT", oldRoot);
            File.WriteAllLines(evidence, lines);
            foreach (var line in lines) Console.WriteLine("NOTE " + line);
            for (var attempt = 0; attempt < 25 && Directory.Exists(root); attempt++)
            {
                try { Directory.Delete(root, recursive: true); } catch (IOException) { Thread.Sleep(200); } catch (UnauthorizedAccessException) { Thread.Sleep(200); }
            }
        }
        check(!Directory.Exists(root), "The fallback check removes its temporary Utilities folder");
    }
}
