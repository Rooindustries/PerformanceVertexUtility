using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class DeniedReleaseChecks
{
    public static async Task Run(string root, TweakCatalog catalog, Action<bool, string> check, string repo)
    {
        var consumer = catalog.Settings.Single(setting => setting.Id == "windows.a8268996c3eb9072");
        var extensions = catalog.Settings.Single(setting => setting.Id == "explorer.file-extensions");
        foreach (var scenario in new[] { "registry-denied", "control-denied", "registry-unauthorized", "control-transition", "control-reader-missing", "control-missing", "unknown-option", "control-adapter-missing", "control-adapter-batch-missing", "control-blocker-changed", "control-timer-changed", "control-helper-denied" })
        {
            var controls = scenario.StartsWith("control", StringComparison.Ordinal);
            var knownChanged = scenario is "control-adapter-missing" or "control-adapter-batch-missing" or "control-blocker-changed" or "control-timer-changed";
            var service = scenario.Contains("adapter", StringComparison.Ordinal) ? new ControlAddress("network-adapter", "interfaces:11111111-2222-3333-4444-555555555555", "ipv6-binding") : new ControlAddress("service", "RooIndustriesUiModelFixture", "running");
            var definition = controls ? new TweakDefinition("edition-control", "Edition control", "Windows", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "Running", [], [new(10240, 26200, ["Enterprise"])], [new(service, ControlValues.From(true))])], [new("Fixture", "fixture", "isolated control validation")]) : consumer;
            var option = definition.Options.Single(item => controls || item.Changes.Single().Dword == 1);
            var address = controls ? null : option.Changes.Single().Address;
            var oldOption = option with { Id = scenario == "unknown-option" ? "previous-choice" : option.Id, Availability = [new(10240, 26200, ["*"])] };
            var subset = catalog with { Settings = [definition, extensions], Presets = [], Incompatible = null };
            var directory = Path.Combine(root, "release-" + scenario); var fixture = new Fixture(directory, subset, 26100) { Missing = false };
            var path = Path.Combine(directory, "windows.json"); var data = OperationFiles.Read<TweakFixture>(path);
            if (controls) data.Controls[service.Key] = new(service, "service:fixture:running", "fixture-binding", service.Kind == "network-adapter" ? ControlValues.From(new Dictionary<string, bool> { ["11111111-2222-3333-4444-555555555555"] = false }) : ControlValues.From(false));
            else
            {
                var parts = address!.KeyPath.Split('\\');
                for (var count = 1; count <= parts.Length; count++)
                {
                    var key = @"\REGISTRY\MACHINE\" + string.Join('\\', parts.Take(count)); data.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
                }
                data.Keys[(@"\REGISTRY\MACHINE\" + address.KeyPath).ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = new(address.ValueName, 4, BitConverter.GetBytes(0u));
            }
            OperationFiles.Write(path, data);
            var old = subset with { Settings = [definition with { Options = [oldOption] }, extensions] };
            var oldEngine = new TweakEngine(old, fixture.Windows); var plan = oldEngine.Preview("my-settings", knownChanged ? [new(definition.Id, oldOption.Id), new(extensions.Id, "show")] : [new(definition.Id, oldOption.Id)]);
            var review = Path.Combine(directory, "old.json"); OperationFiles.Write(review, plan); oldEngine.Apply(review, OperationFiles.HashFile(review));
            bool ControlEnabled() { var value = fixture.Windows.ReadControl(service).Value; return service.Kind == "network-adapter" ? value.EnumerateObject().All(item => item.Value.GetBoolean()) : value.GetBoolean(); }
            check(controls ? ControlEnabled() : fixture.Windows.Read(address!).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)), "The obsolete " + scenario + " fixture starts with its applied value and original backup");
            if (scenario == "control-missing") { data = OperationFiles.Read<TweakFixture>(path); data.Controls.Remove(service.Key); OperationFiles.Write(path, data); }
            var nativeFailure = scenario.Contains("adapter", StringComparison.Ordinal) ? await MissingAdapter(repo, service, scenario.Contains("batch", StringComparison.Ordinal)) : null;
            Exception Failure() => scenario switch
            {
                "registry-denied" => new RegistryApiException("RegOpenKeyEx", 5),
                "registry-unauthorized" => new UnauthorizedAccessException("Access to the registry key is denied."),
                "control-transition" => new InvalidDataException("The service is transitioning. Try again after it settles: " + service.Target),
                "control-reader-missing" => new Win32Exception(2, "The reader dependency could not be found."),
                "control-missing" => new Win32Exception(1060),
                "control-adapter-missing" or "control-adapter-batch-missing" => nativeFailure!,
                "control-blocker-changed" => HelperFailure("{\"error\":\"Download-folder permissions changed outside this profile.\",\"resourceChanged\":true}"),
                "control-timer-changed" => HelperFailure("{\"error\":\"The timer startup task or its script changed and was left intact.\",\"resourceChanged\":true}"),
                "control-helper-denied" => HelperFailure("{\"error\":\"Access is denied.\"}"),
                _ => new Win32Exception(5),
            };
            if (controls) fixture.ControlReadError = target => target == service ? Failure() : null;
            else if (scenario != "unknown-option") fixture.RegistryReadError = target => target == address ? Failure() : null;
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
            var oldRow = model.Rows.Single(row => row.Id == definition.Id); oldRow.Selected = oldRow.Choices[0];
            var other = model.Rows.Single(row => row.Id == extensions.Id); other.Selected = other.Choices.Single(choice => choice.Id == (knownChanged ? "hide" : "show"));
            var before = OperationFiles.HashFile(path);
            await model.ReviewCommand.ExecuteAsync(null);
            check(model.ApplyLabel == "Save choices" && model.Changes.Count == 0, "A partial edit refuses automatic release during " + scenario);
            model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(fixture.Applies == 0 && OperationFiles.HashFile(path) == before && fixture.Windows.ReadState()!.Profiles.Single().Selections.Contains(new(definition.Id, oldOption.Id)), "Saving the other choice preserves the entire original Windows backup during " + scenario);
            if (scenario is "control-missing" or "unknown-option" || knownChanged)
            {
                if (knownChanged) check(fixture.Engine.Preview("my-settings", []).LeftAsChanged.Contains(definition.Id), "Explicit restore reports the confirmed changed target: " + scenario);
                await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
                check(fixture.Windows.ReadState()!.Profiles.Length == 0 && (controls ? fixture.Windows.ReadState()!.Controls!.Length == 0 : fixture.Windows.Read(address!).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u))), "Explicit restore handles a removed control or renamed option without getting stuck: " + scenario);
                if (knownChanged) check(!fixture.Windows.Read(extensions.Options.Single(item => item.Id == "show").Changes.Single().Address).KeyExists, "A confirmed changed target does not block exact undo of the other profile settings: " + scenario);
                continue;
            }
            var refused = false;
            try { fixture.Engine.Preview("my-settings", []); } catch (Exception error) when (error is Win32Exception or UnauthorizedAccessException or InvalidDataException or InvalidOperationException) { refused = true; }
            check(refused && OperationFiles.HashFile(path) == before, "Explicit restore also preserves the backup when the target is unreadable: " + scenario);
            fixture.RegistryReadError = null; fixture.ControlReadError = null;
            await model.RefreshCommand.ExecuteAsync(null);
            oldRow = model.Rows.Single(row => row.Id == definition.Id); oldRow.Selected = oldRow.Choices[0];
            other = model.Rows.Single(row => row.Id == extensions.Id); other.Selected = other.Choices.Single(choice => choice.Id == "show");
            await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(controls ? !ControlEnabled() : fixture.Windows.Read(address!).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)), "A readable partial edit restores the exact original obsolete value: " + scenario);
            await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(fixture.Windows.ReadState()!.Profiles.Length == 0, "The edited profile still has a complete explicit undo after " + scenario);
        }
    }
    private static Exception HelperFailure(string output)
    {
        var type = typeof(TweakEngine).Assembly.GetType("RooIndustries.Optimizer.PowerShellControls", throwOnError: true)!;
        try { type.GetMethod("Result", BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, [output]); }
        catch (TargetInvocationException error) when (error.InnerException is { } inner) { return inner; }
        throw new InvalidOperationException("Expected a helper failure.");
    }
    private static async Task<Exception> MissingAdapter(string repo, ControlAddress address, bool batch)
    {
        var source = Path.GetFullPath(Path.Combine(repo, "backend/native/Optimizer.Core/WindowsControls.ps1"));
        var request = batch ? JsonSerializer.SerializeToUtf8Bytes(new { action = "read-batch", addresses = new[] { address } }, OperationFiles.Json) : JsonSerializer.SerializeToUtf8Bytes(new { action = "read", address }, OperationFiles.Json);
        var script = "function Get-NetAdapter { param([switch]$IncludeHidden) }; & '" + source.Replace("'", "''", StringComparison.Ordinal) + "'";
        var start = new ProcessStartInfo(OperatingSystem.IsWindows() ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe") : "pwsh") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var item in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) }) start.ArgumentList.Add(item);
        start.Environment["ROO_INDUSTRIES_CONTROL_REQUEST"] = Convert.ToBase64String(request);
        using var process = Process.Start(start) ?? throw new IOException("Could not start the fixture control helper.");
        var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync(); var text = (await output).Trim();
        if (process.ExitCode != 0) throw new IOException(await errors);
        const string prefix = "ROO_INDUSTRIES_CONTROL 0 ";
        if (batch) { if (!text.StartsWith(prefix, StringComparison.Ordinal)) throw new InvalidDataException(text); text = text[prefix.Length..]; }
        return HelperFailure(text);
    }
}
