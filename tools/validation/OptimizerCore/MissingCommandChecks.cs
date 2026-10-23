using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class MissingCommandChecks
{
    static string Hidden(string modules) => "Import-Module Microsoft.PowerShell.Utility,CimCmdlets; $global:PSModuleAutoLoadingPreference='None'; $env:PSModulePath='" + modules.Replace("'", "''") + "'\n";
    const string Provider = """
function Get-CimInstance {
 param([string]$Namespace,[string]$ClassName,[string]$Filter)
 $fixture=[IO.File]::ReadAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER)|ConvertFrom-Json
 if($ClassName -ceq 'Win32_Service' -and $Filter -ceq "Name='WinDefend'"){if($fixture.service){[pscustomobject]@{Name='WinDefend';State=[string]$fixture.service}};return}
 if($Namespace -cne 'root/Microsoft/Windows/Defender' -or $ClassName -cne 'MSFT_MpPreference'){throw ('Unexpected CIM read: '+$Namespace+' '+$ClassName+' '+$Filter)}
 if($fixture.provider){throw [string]$fixture.provider}
 [pscustomobject]@{SubmitSamplesConsent=[byte]$fixture.consent}
}
function Invoke-CimMethod {
 param([string]$Namespace,[string]$ClassName,[string]$MethodName,[hashtable]$Arguments)
 $fixture=[IO.File]::ReadAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER)|ConvertFrom-Json
 if($Namespace -cne 'root/Microsoft/Windows/Defender' -or $ClassName -cne 'MSFT_MpPreference' -or $MethodName -cne 'Set' -or @($Arguments.Keys).Count -ne 1 -or $Arguments['SubmitSamplesConsent'] -isnot [byte]){throw ('Unexpected CIM call: '+$Namespace+' '+$ClassName+'.'+$MethodName)}
 $fixture.calls=[int]$fixture.calls+1;$fixture.consent=[int]$Arguments['SubmitSamplesConsent']
 [IO.File]::WriteAllText($env:ROO_INDUSTRIES_FIXTURE_DEFENDER,($fixture|ConvertTo-Json -Compress))
 [pscustomobject]@{ReturnValue=$(if($fixture.empty){$null}else{[uint32]0})}
}

""";
    const string LoadFailure = "The Defender provider dependency could not be loaded.";
    const string MitigationLoadFailure = "The ProcessMitigations provider dependency could not be loaded.";
    const string NotInstalled = "Microsoft Defender Antivirus is not installed.";
    const string Stopped = "Microsoft Defender Antivirus is not available with its service stopped. Windows stops it when another antivirus takes over.";
    const string Parent = @"Software\RooIndustriesTweakTests";

    static Func<object, Process> Launcher(string providers, string state, string modules)
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
            start.Environment["ROO_INDUSTRIES_FIXTURE_DEFENDER"] = state;
            return Process.Start(start) ?? throw new IOException("Could not start the Windows control helper.");
        };
    }

    static string Unavailable(string feature) => feature + " is not available with this Windows version.";

    static string Error(Action action)
    {
        try { action(); return "no error"; }
        catch (Exception error) { return error.Message; }
    }

    static string BrokenModule(string folder, string name, string thrown, params string[] commands)
    {
        var modules = Path.Combine(folder, name.ToLowerInvariant() + "-modules");
        Directory.CreateDirectory(Path.Combine(modules, name));
        File.WriteAllText(Path.Combine(modules, name, name + ".psd1"), "@{RootModule='" + name + ".psm1';ModuleVersion='1.0';FunctionsToExport=@(" + string.Join(",", commands.Select(command => "'" + command + "'")) + ")}");
        File.WriteAllText(Path.Combine(modules, name, name + ".psm1"), "throw '" + thrown + "'\n");
        return modules;
    }

    public static void Run(Action<bool, string> check)
    {
        var original = PowerShellControls.Launcher;
        var folder = Directory.CreateTempSubdirectory("roo-industries-missing-commands-");
        var state = Path.Combine(folder.FullName, "defender.json");
        var root = Parent + @"\" + Guid.NewGuid().ToString("N");
        bool parentExisted;
        using (var existing = Registry.CurrentUser.OpenSubKey(Parent)) parentExisted = existing is not null;
        try
        {
            void Defender(string? provider, string? service, int consent, int calls = 0, bool empty = false) => File.WriteAllText(state, JsonSerializer.Serialize(new { consent, provider, service, calls, empty }));
            JsonElement Saved() => JsonDocument.Parse(File.ReadAllText(state)).RootElement;
            Defender(null, "Running", 1);
            var none = Path.Combine(folder.FullName, "no-modules");
            var modules = BrokenModule(folder.FullName, "BrokenDefender", LoadFailure, "Get-MpPreference", "Set-MpPreference");
            var hidden = Launcher("", state, none); var hiddenDefender = Launcher(Provider, state, none); var brokenDefender = Launcher(Provider, state, modules);
            var defender = new ControlAddress("defender", "system", "SubmitSamplesConsent");
            var mitigations = new ControlAddress("mitigations", "system", "policy");
            PowerShellControls.Launcher = Launcher("", state, BrokenModule(folder.FullName, "BrokenMitigations", MitigationLoadFailure, "Get-ProcessMitigation"));
            var unloadedStore = new RegistryTweakStore(new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State"));
            var unloadedEngine = new TweakEngine(new TweakCatalog(1, "unloaded-mitigations", [Setting("mitigations", mitigations, JsonDocument.Parse("""{"Aslr.BottomUp":"ON","Aslr.OverrideBottomUp":false}""").RootElement, true)], []), unloadedStore);
            string Unloaded() => unloadedEngine.Detect().Settings.Single(setting => setting.Id == "mitigations").Error ?? "read";
            var (firstRead, retryRead) = (Unloaded(), Unloaded());
            var unloadedReview = Error(() => unloadedEngine.Preview("exploit-unloaded", [new("mitigations", "set")]));
            check(firstRead.Contains(MitigationLoadFailure, StringComparison.Ordinal) && retryRead == firstRead && unloadedReview.Contains(MitigationLoadFailure, StringComparison.Ordinal)
                && unloadedStore.ReadState() is null && unloadedStore.Recovery().Pending is null,
                "Exploit protection whose module is installed but fails to load reads the load error on every retry and refuses a review before anything is saved or written: " + firstRead + " | " + retryRead + " | " + unloadedReview);
            PowerShellControls.Launcher = hidden;
            (string Feature, ControlAddress Address)[] rows =
            [
                ("Windows Firewall", new("firewall-profile", "Public", "enabled")),
                ("Device power management", new("device-power", "non-network", "enabled")), ("Encrypted DNS", new("dns-over-https", "203.0.113.253", "configuration")),
                ("Teredo", new("teredo", "system", "type")), ("Memory compression", new("memory", "system", "compression")), ("Reserved storage", new("reserved-storage", "system", "enabled")),
                ("Network adapter configuration", new("network-adapter", "primary", "ipv6-binding")), ("Exploit protection", mitigations),
            ];
            var reads = new WindowsControlStore().ReadMany(rows.Select(row => row.Address).ToArray());
            var wrong = rows.Where(row => reads[row.Address].Error?.Message != Unavailable(row.Feature)).Select(row => row.Feature + ": " + (reads[row.Address].Error?.Message ?? "read")).ToArray();
            check(wrong.Length == 0, "Every command-backed Windows setting, exploit protection included, reads as not available when its PowerShell commands are missing: " + string.Join(" | ", wrong));

            TweakDefinition Setting(string id, ControlAddress address, JsonElement desired, bool patch = false) => new(id, id, "Fixture", "Fixture", 10240, int.MaxValue, ["*"], "none",
                [new("set", "Set", [], Controls: [new(address, desired, patch)])], [new("Roo Industries", "fixture", "missing PowerShell commands")]);
            var store = new RegistryTweakStore(new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State"));
            var engine = new TweakEngine(new TweakCatalog(1, "missing-commands", [
                Setting("defender", defender, ControlValues.From(2)),
                Setting("mitigations", mitigations, JsonDocument.Parse("""{"Aslr.BottomUp":"ON","Aslr.OverrideBottomUp":false}""").RootElement, true)], []), store);
            string Review(TweakPlan plan) { var path = Path.Combine(folder.FullName, plan.OperationId + ".json"); OperationFiles.Write(path, plan); return path; }
            bool Untouched(int value) => Saved().GetProperty("consent").GetInt32() == value && Saved().GetProperty("calls").GetInt32() == 0 && store.Recovery().Pending is null;
            bool Applied() => store.ReadState()?.Profiles.Any(profile => profile.Id == "defender-fixture") == true;

            PowerShellControls.Launcher = hiddenDefender;
            var detected = engine.Detect().Settings.ToDictionary(setting => setting.Id);
            check(detected["defender"] is { Supported: true, Error: null, Controls: [{ } read] } && read.Value.GetInt32() == 1 && detected["mitigations"].Error == Unavailable("Exploit protection"),
                "Without Defender's PowerShell commands the Windows tweaks page reads the Defender row's real value from Windows' Defender provider: " + detected["defender"].Error + " | " + detected["mitigations"].Error);
            var exploit = Error(() => engine.Preview("exploit", [new("mitigations", "set")]));
            check(exploit == Unavailable("Exploit protection") && store.ReadState() is null && Untouched(1), "Reviewing an exploit protection change without its readback command stops as not available before anything is written: " + exploit);

            var apply = Review(engine.Preview("defender-fixture", [new("defender", "set")]));
            PowerShellControls.Launcher = brokenDefender;
            var appliedError = Error(() => engine.Apply(apply, OperationFiles.HashFile(apply)));
            check(appliedError == "no error" && Saved().GetProperty("consent").GetInt32() == 2 && Saved().GetProperty("calls").GetInt32() == 1 && Applied() && store.Recovery().Pending is null,
                "A Defender choice reviewed without Defender's commands applies through Windows' Defender provider while Defender's module fails to load: " + appliedError);
            var undo = Review(engine.Preview("defender-fixture", []));
            PowerShellControls.Launcher = hiddenDefender;
            var undoneError = Error(() => engine.Apply(undo, OperationFiles.HashFile(undo)));
            check(undoneError == "no error" && Saved().GetProperty("consent").GetInt32() == 1 && Saved().GetProperty("calls").GetInt32() == 2 && store.ReadState()?.Profiles.Length == 0 && store.Recovery().Pending is null,
                "Undo puts the Defender row's original value back through Windows' Defender provider without Defender's commands: " + undoneError);

            Defender(null, "Running", 1);
            apply = Review(engine.Preview("defender-fixture", [new("defender", "set")]));
            Defender("Invalid namespace", null, 1);
            var removed = engine.Detect().Settings.Single(setting => setting.Id == "defender");
            var removedReview = Error(() => engine.Preview("defender-fixture", [new("defender", "set")]));
            var removedApply = Error(() => engine.Apply(apply, OperationFiles.HashFile(apply)));
            check(removed is { Supported: false, Error: NotInstalled } && removedReview == NotInstalled && removedApply == NotInstalled && Untouched(1) && !Applied(),
                "A PC whose Defender is removed reads the Defender row as not installed and refuses a review or a reviewed apply before any journal or write: " + removed.Error + " | " + removedReview + " | " + removedApply);

            Defender(null, "Running", 1);
            apply = Review(engine.Preview("defender-fixture", [new("defender", "set")]));
            engine.Apply(apply, OperationFiles.HashFile(apply));
            undo = Review(engine.Preview("defender-fixture", []));
            Defender("Operation failed with the following error: 0x800106ba", "Stopped", 2, 1);
            var stopped = engine.Detect().Settings.Single(setting => setting.Id == "defender").Error;
            var stoppedUndo = Error(() => engine.Apply(undo, OperationFiles.HashFile(undo)));
            check(stopped == Stopped && stoppedUndo == Stopped && Saved().GetProperty("consent").GetInt32() == 2 && Saved().GetProperty("calls").GetInt32() == 1 && Applied() && store.Recovery().Pending is null,
                "With Defender's service stopped, the Defender row reads not available and a reviewed undo stops before any journal or write, keeping the saved profile: " + stopped + " | " + stoppedUndo);
            Defender(null, "Running", 2, 1);
            engine.Apply(undo, OperationFiles.HashFile(undo));
            check(Saved().GetProperty("consent").GetInt32() == 1 && store.ReadState()?.Profiles.Length == 0 && store.Recovery().Pending is null, "The same reviewed undo finishes once Defender's service runs again");

            Defender(null, "Running", 1, empty: true);
            apply = Review(engine.Preview("defender-fixture", [new("defender", "set")]));
            var emptyApply = Error(() => engine.Apply(apply, OperationFiles.HashFile(apply)));
            var emptyApplied = Saved().GetProperty("consent").GetInt32() == 2 && Applied();
            var emptyUndo = Error(() => { var path = Review(engine.Preview("defender-fixture", [])); engine.Apply(path, OperationFiles.HashFile(path)); });
            check(emptyApply == "no error" && emptyApplied && emptyUndo == "no error" && Saved().GetProperty("consent").GetInt32() == 1 && Saved().GetProperty("calls").GetInt32() == 2 && store.ReadState()?.Profiles.Length == 0 && store.Recovery().Pending is null,
                "A Defender change whose provider result has an empty return value applies and undoes once Windows reads the new value back: " + emptyApply + " | " + emptyUndo);
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

    static string WindowsPowerShell(string command)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; " + command }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("Could not start Windows PowerShell.");
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(120000)) { process.Kill(true); throw new IOException("Windows PowerShell timed out: " + command); }
        if (process.ExitCode != 0) throw new IOException("Windows PowerShell failed: " + command + ": " + errors.Result.Trim());
        return output.Result.Trim();
    }

    public static void RunReal(Action<bool, string> check, string repo, string evidence)
    {
        var original = PowerShellControls.Launcher;
        int Consent() => int.Parse(WindowsPowerShell("[int](Get-MpPreference).SubmitSamplesConsent"), System.Globalization.CultureInfo.InvariantCulture);
        var log = new List<object>();
        var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend", "catalogs", "windows-tweaks.json"));
        var rows = catalog.Settings.Where(row => row.Options.Any(option => option.Controls?.Any(control => control.Address.Kind == "defender") == true)).ToArray();
        var first = Consent();
        var root = Parent + @"\" + Guid.NewGuid().ToString("N");
        bool parentExisted;
        using (var existing = Registry.CurrentUser.OpenSubKey(Parent)) parentExisted = existing is not null;
        var folder = Directory.CreateTempSubdirectory("roo-industries-security-rows-");
        try
        {
            check(rows.Length > 0, "The catalog has Defender rows to apply and undo");
            var broken = BrokenModule(folder.FullName, "BrokenDefender", LoadFailure, "Get-MpPreference", "Set-MpPreference");
            var import = WindowsPowerShell("$env:PSModulePath='" + broken.Replace("'", "''") + "'; try { Import-Module BrokenDefender; 'loaded' } catch { $_.Exception.Message }");
            check(import.Contains(LoadFailure, StringComparison.Ordinal), "The failing-to-load fixture's Defender commands really fail to import: " + import);
            (string Commands, Func<object, Process> Launcher)[] states =
            [
                ("missing", Launcher("", "", Path.Combine(folder.FullName, "no-modules"))),
                ("failing to load", Launcher("", "", broken)),
            ];
            foreach (var (commands, launcher) in states)
            foreach (var row in rows)
            {
                var store = new RegistryTweakStore(new("CurrentUser", "Registry64", root + @"\Recovery", "value", "State"));
                var engine = new TweakEngine(catalog with { Settings = [row], Presets = [], Incompatible = null }, store);
                string Review(TweakPlan plan) { var path = Path.Combine(folder.FullName, plan.OperationId + ".json"); OperationFiles.Write(path, plan); return path; }
                PowerShellControls.Launcher = launcher;
                var before = Consent();
                var status = engine.Detect().Settings.Single();
                var read = status.Controls?.SingleOrDefault(control => control.Address.Kind == "defender");
                check(status.Error is null && read?.Value.GetInt32() == before,
                    row.Name + " with Defender's PowerShell commands " + commands + " reads this PC's real value " + before + ": " + (status.Error ?? read?.Value.ToString() ?? "no read"));
                var choice = row.Options.First(option => option.Controls!.Single(control => control.Address.Kind == "defender").Value.GetInt32() != before);
                var target = choice.Controls!.Single(control => control.Address.Kind == "defender").Value.GetInt32();
                var apply = Review(engine.Preview("security-rows", [new(row.Id, choice.Id)]));
                engine.Apply(apply, OperationFiles.HashFile(apply));
                var applied = Consent();
                check(applied == target, row.Name + " with Defender's PowerShell commands " + commands + " applies " + choice.Name + ": Get-MpPreference reads " + applied + ", expected " + target);
                var undo = Review(engine.Preview("security-rows", []));
                engine.Apply(undo, OperationFiles.HashFile(undo));
                var restored = Consent();
                check(restored == before && store.ReadState()?.Profiles.Length == 0 && store.Recovery().Pending is null,
                    row.Name + " with Defender's PowerShell commands " + commands + " undoes back to " + before + ": Get-MpPreference reads " + restored);
                log.Add(new { commands, row = row.Id, before, choice = choice.Id, applied, restored });
            }
        }
        finally
        {
            PowerShellControls.Launcher = original;
            try
            {
                var last = Consent();
                if (last != first) WindowsPowerShell("Set-MpPreference -SubmitSamplesConsent " + first);
                log.Add(new { first, last, final = Consent() });
                File.WriteAllText(evidence, JsonSerializer.Serialize(log, new JsonSerializerOptions { WriteIndented = true }));
            }
            finally
            {
                Registry.CurrentUser.DeleteSubKeyTree(root, false);
                if (!parentExisted)
                    try { Registry.CurrentUser.DeleteSubKey(Parent, false); }
                    catch (InvalidOperationException) { }
                folder.Delete(true);
            }
        }
        check(log.Count == 2 * rows.Length + 1, "Every Defender row applied and undid with its commands missing and failing to load, and the PC's own value is back: " + evidence);
    }
}
