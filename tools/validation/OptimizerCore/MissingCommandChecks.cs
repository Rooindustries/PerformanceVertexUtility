using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class MissingCommandChecks
{
    static string Hidden(string modules) => "Import-Module Microsoft.PowerShell.Utility; $global:PSModuleAutoLoadingPreference='None'; $env:PSModulePath='" + modules.Replace("'", "''") + "'\n";
    const string Defender = """
function Get-MpPreference {[pscustomobject]@{SubmitSamplesConsent=[int][IO.File]::ReadAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER)}}
function Set-MpPreference {param([int]$SubmitSamplesConsent) [IO.File]::WriteAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER,[string]$SubmitSamplesConsent)}

""";
    const string LoadFailure = "The Defender provider dependency could not be loaded.";
    const string Parent = @"Software\RooIndustriesTweakTests";

    static Func<object, Process> Launcher(string providers, string consent, string modules)
    {
        string helper;
        using (var resource = typeof(PowerShellControls).Assembly.GetManifestResourceStream("Optimizer.Core.WindowsControls.ps1") ?? throw new FileNotFoundException("The Windows control helper is missing."))
        using (var reader = new StreamReader(resource)) helper = reader.ReadToEnd();
        using var packed = new MemoryStream();
        using (var gzip = new GZipStream(packed, CompressionLevel.Optimal, leaveOpen: true)) gzip.Write(Encoding.UTF8.GetBytes(Hidden(modules) + providers + helper));
        var encoded = Convert.ToBase64String(packed.ToArray());
        return request =>
        {
            var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"))
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            };
            foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(RuntimeEnvironment.PowerShellPrelude + "$packed=New-Object IO.MemoryStream(,[Convert]::FromBase64String($env:ROO_INDUSTRIES_CONTROL_HELPER)); $source=(New-Object IO.StreamReader((New-Object IO.Compression.GZipStream($packed,[IO.Compression.CompressionMode]::Decompress)),[Text.Encoding]::UTF8)).ReadToEnd(); & ([ScriptBlock]::Create($source))")) }) start.ArgumentList.Add(argument);
            start.Environment["ROO_INDUSTRIES_CONTROL_HELPER"] = encoded;
            start.Environment["ROO_INDUSTRIES_CONTROL_REQUEST"] = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(request, OperationFiles.Json));
            start.Environment["ROO_INDUSTRIES_FIXTURE_DEFENDER"] = consent;
            return Process.Start(start) ?? throw new IOException("Could not start the Windows control helper.");
        };
    }

    static string Unavailable(string feature) => feature + " is not available with this Windows version.";

    static string Error(Action action)
    {
        try { action(); return "no error"; }
        catch (Exception error) { return error.Message; }
    }

    public static void Run(Action<bool, string> check)
    {
        var original = PowerShellControls.Launcher;
        var folder = Directory.CreateTempSubdirectory("roo-industries-missing-commands-");
        var consent = Path.Combine(folder.FullName, "consent.txt");
        var root = Parent + @"\" + Guid.NewGuid().ToString("N");
        bool parentExisted;
        using (var existing = Registry.CurrentUser.OpenSubKey(Parent)) parentExisted = existing is not null;
        try
        {
            File.WriteAllText(consent, "1");
            var modules = Path.Combine(folder.FullName, "modules"); var none = Path.Combine(folder.FullName, "no-modules");
            Directory.CreateDirectory(Path.Combine(modules, "BrokenDefender"));
            File.WriteAllText(Path.Combine(modules, "BrokenDefender", "BrokenDefender.psd1"), "@{RootModule='BrokenDefender.psm1';ModuleVersion='1.0';FunctionsToExport=@('Get-MpPreference','Set-MpPreference')}");
            File.WriteAllText(Path.Combine(modules, "BrokenDefender", "BrokenDefender.psm1"), "throw '" + LoadFailure + "'\n" + Defender);
            var hidden = Launcher("", consent, none); var present = Launcher(Defender, consent, none); var broken = Launcher("", consent, modules);
            var defender = new ControlAddress("defender", "system", "SubmitSamplesConsent");
            var mitigations = new ControlAddress("mitigations", "system", "policy");
            PowerShellControls.Launcher = hidden;
            (string Feature, ControlAddress Address)[] rows =
            [
                ("Windows Firewall", new("firewall-profile", "Public", "enabled")), ("Microsoft Defender Antivirus", defender),
                ("Device power management", new("device-power", "non-network", "enabled")), ("Encrypted DNS", new("dns-over-https", "203.0.113.253", "configuration")),
                ("Teredo", new("teredo", "system", "type")), ("Memory compression", new("memory", "system", "compression")), ("Reserved storage", new("reserved-storage", "system", "enabled")),
                ("Network adapter configuration", new("network-adapter", "primary", "ipv6-binding")), ("Exploit protection", mitigations),
            ];
            var reads = new WindowsControlStore().ReadMany(rows.Select(row => row.Address).ToArray());
            var wrong = rows.Where(row => reads[row.Address].Error?.Message != Unavailable(row.Feature)).Select(row => row.Feature + ": " + (reads[row.Address].Error?.Message ?? "read")).ToArray();
            check(wrong.Length == 0, "Every command-backed Windows setting, exploit protection included, reads as not available when its PowerShell commands are missing: " + string.Join(" | ", wrong));
            PowerShellControls.Launcher = broken;
            var maps = new ControlAddress("defender", "system", "MAPSReporting");
            var loading = new WindowsControlStore().ReadMany([defender, maps]);
            string Failure(ControlAddress address) => loading[address].Error?.Message ?? "read";
            check(Failure(defender) != Unavailable("Microsoft Defender Antivirus") && Failure(defender).Contains(LoadFailure, StringComparison.Ordinal) && Failure(maps) == Failure(defender),
                "Every Defender read reports the load error, not not available, when Defender's module is installed but fails to load: " + Failure(defender) + " | " + Failure(maps));
            PowerShellControls.Launcher = hidden;

            TweakDefinition Setting(string id, ControlAddress address, JsonElement desired, bool patch = false) => new(id, id, "Fixture", "Fixture", 10240, int.MaxValue, ["*"], "none",
                [new("set", "Set", [], Controls: [new(address, desired, patch)])], [new("Roo Industries", "fixture", "missing PowerShell commands")]);
            var store = new RegistryTweakStore(new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State"));
            var engine = new TweakEngine(new TweakCatalog(1, "missing-commands", [
                Setting("defender", defender, ControlValues.From(2)),
                Setting("mitigations", mitigations, JsonDocument.Parse("""{"Aslr.BottomUp":"ON","Aslr.OverrideBottomUp":false}""").RootElement, true)], []), store);
            string Review(TweakPlan plan) { var path = Path.Combine(folder.FullName, plan.OperationId + ".json"); OperationFiles.Write(path, plan); return path; }
            bool Untouched(string value) => File.ReadAllText(consent) == value && store.Recovery().Pending is null;

            var detected = engine.Detect().Settings.ToDictionary(setting => setting.Id);
            check(detected["defender"] is { Supported: false } found && found.Error == Unavailable("Microsoft Defender Antivirus") && detected["mitigations"].Error == Unavailable("Exploit protection"),
                "The Windows tweaks page gets the not-available reason for the Defender and exploit protection rows: " + detected["defender"].Error + " | " + detected["mitigations"].Error);
            var exploit = Error(() => engine.Preview("exploit", [new("mitigations", "set")]));
            check(exploit == Unavailable("Exploit protection") && store.ReadState() is null && Untouched("1"), "Reviewing an exploit protection change without its readback command stops as not available before anything is written: " + exploit);

            PowerShellControls.Launcher = present;
            var apply = Review(engine.Preview("defender-fixture", [new("defender", "set")]));
            PowerShellControls.Launcher = hidden;
            var refusedApply = Error(() => engine.Apply(apply, OperationFiles.HashFile(apply)));
            check(refusedApply == Unavailable("Microsoft Defender Antivirus") && store.ReadState() is null && Untouched("1"),
                "Applying a reviewed Defender choice after Defender's commands went missing stops as not available before any journal or write: " + refusedApply);
            PowerShellControls.Launcher = broken;
            var unloaded = engine.Detect().Settings.Single(setting => setting.Id == "defender").Error ?? "read";
            var failedApply = Error(() => engine.Apply(apply, OperationFiles.HashFile(apply)));
            check(unloaded.Contains(LoadFailure, StringComparison.Ordinal) && failedApply.Contains(LoadFailure, StringComparison.Ordinal) && store.ReadState() is null && Untouched("1"),
                "With Defender's module failing to load, the page gets the load error and a reviewed Defender apply stops with it before any journal or write: " + unloaded + " | " + failedApply);

            PowerShellControls.Launcher = present;
            apply = Review(engine.Preview("defender-fixture", [new("defender", "set")]));
            engine.Apply(apply, OperationFiles.HashFile(apply));
            check(File.ReadAllText(consent) == "2" && store.ReadState()?.Profiles.Any(profile => profile.Id == "defender-fixture") == true, "A PC with Defender's commands still applies the Defender row");
            var undo = Review(engine.Preview("defender-fixture", []));
            PowerShellControls.Launcher = hidden;
            var refusedUndo = Error(() => engine.Apply(undo, OperationFiles.HashFile(undo)));
            var refusedReview = Error(() => engine.Preview("defender-fixture", []));
            check(refusedUndo == Unavailable("Microsoft Defender Antivirus") && refusedReview == refusedUndo && Untouched("2") && store.ReadState()?.Profiles.Any(profile => profile.Id == "defender-fixture") == true,
                "Undoing the Defender row without Defender's commands stops as not available before any journal or write and keeps the saved profile: " + refusedUndo + " | " + refusedReview);

            PowerShellControls.Launcher = present;
            engine.Apply(undo, OperationFiles.HashFile(undo));
            check(File.ReadAllText(consent) == "1" && store.ReadState()?.Profiles.Length == 0 && store.Recovery().Pending is null, "The same reviewed undo finishes once Defender's commands are back");
        }
        finally
        {
            PowerShellControls.Launcher = original;
            Registry.CurrentUser.DeleteSubKeyTree(root, false);
            if (!parentExisted)
                try { Registry.CurrentUser.DeleteSubKey(Parent, false); }
                catch (InvalidOperationException) { }
            folder.Delete(true);
        }
    }
}
