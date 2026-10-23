using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class EditionLimitedChecks
{
    public static async Task Run(string root, TweakCatalog catalog, Action<bool, string> check)
    {
        TweakDefinition Find(string keyPath, string valueName) => catalog.Settings.Single(setting => setting.Options.Any(option => option.Changes is [{ Dword: not null } change] && change.Address.Hive == "LocalMachine" &&
            string.Equals(change.Address.KeyPath, keyPath, StringComparison.OrdinalIgnoreCase) && string.Equals(change.Address.ValueName, valueName, StringComparison.OrdinalIgnoreCase)));
        var diagnostic = Find(@"SOFTWARE\Policies\Microsoft\Windows\DataCollection", "AllowTelemetry");
        var settingsDiagnostic = Find(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection", "AllowTelemetry");
        var tips = Find(@"SOFTWARE\Policies\Microsoft\Windows\CloudContent", "DisableSoftLanding");
        var spotlight = Find(@"SOFTWARE\Policies\Microsoft\Windows\CloudContent", "DisableWindowsSpotlightFeatures");
        var off = diagnostic.Options.Single(option => option.Changes.Single().Dword == 0);
        var required = diagnostic.Options.SingleOrDefault(option => option.Changes.Single().Dword == 1);
        check(required is not null, "Windows diagnostic data has a Required diagnostic data choice");
        var address = off.Changes.Single().Address;
        var subset = catalog with { Settings = [diagnostic, settingsDiagnostic, tips, spotlight], Presets = [], Incompatible = null };
        async Task<WindowsTweaksViewModel> Load(Fixture fixture)
        {
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null); return model;
        }
        foreach (var edition in new[] { "Core", "Professional", "Enterprise" })
        {
            var limitedHere = edition != "Enterprise";
            var model = await Load(new Fixture(Path.Combine(root, "edition-" + edition), subset, 26100, edition) { Missing = false });
            model.ShowAdvanced = true;
            foreach (var definition in new[] { tips, spotlight })
            {
                var row = model.Rows.Single(item => item.Id == definition.Id);
                var on = definition.Options.Single(option => option.Changes.Single().Dword == 1).Id;
                check(row.UnavailableHere == limitedHere && !row.CanRetry && row.Current == (limitedHere ? "Not available here" : "No override") && row.CanApplyChoice(on) == !limitedHere &&
                    row.Detail == (limitedHere ? "This Windows edition or version doesn't use this setting. You can keep a saved choice for a matching installation." : ""),
                    row.Name + " reads Not available here only where Windows ignores it: " + edition);
            }
            var diagnosticRow = model.Rows.Single(item => item.Id == diagnostic.Id);
            check(!diagnosticRow.UnavailableHere && diagnosticRow.Current == "No override" && diagnosticRow.CanApplyChoice(required!.Id) && diagnosticRow.CanApplyChoice(off.Id) == !limitedHere &&
                diagnosticRow.ActionChoices.Any(choice => choice.Id == required.Id && choice.Name == "Required diagnostic data"),
                "Windows diagnostic data offers Off only where Windows honors it and Required diagnostic data everywhere: " + edition);
            foreach (var definition in new[] { diagnostic, settingsDiagnostic })
            {
                var row = model.Rows.Single(item => item.Id == definition.Id);
                var zero = definition.Options.Single(option => option.Changes.Single().Dword == 0).Id;
                var one = definition.Options.Single(option => option.Changes.Single().Dword == 1).Id;
                check(row.Action.Id == (limitedHere ? one : zero) && row.CanApplyChoice(row.Action.Id), row.Name + " starts its switch on a choice this PC can use: " + edition);
                row.ToggleOn = true;
                check(row.Selected.Id == (limitedHere ? one : zero) && row.CanApplySelected, row.Name + " queues that choice when switched on: " + edition);
                row.ToggleOn = false;
            }
            model.ShowAdvanced = false;
            foreach (var definition in new[] { tips, spotlight })
                check(model.Rows.Any(row => row.Id == definition.Id) == (!limitedHere && !definition.Advanced),
                    definition.Name + " follows edition availability and catalog visibility in simple mode: " + edition);
        }
        void Hold(string folder, RegistryAddress target, uint value)
        {
            var state = OperationFiles.Read<TweakFixture>(Path.Combine(folder, "windows.json"));
            var parts = target.KeyPath.Split('\\');
            for (var count = 1; count <= parts.Length; count++)
            {
                var key = @"\REGISTRY\MACHINE\" + string.Join('\\', parts.Take(count));
                state.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
            }
            state.Keys[(@"\REGISTRY\MACHINE\" + target.KeyPath).ToUpperInvariant()].Values[target.ValueName!.ToUpperInvariant()] = new(target.ValueName, 4, BitConverter.GetBytes(value));
            OperationFiles.Write(Path.Combine(folder, "windows.json"), state);
        }
        var held = new Fixture(Path.Combine(root, "edition-held"), subset, 26100, "Core") { Missing = false };
        var tipsAddress = tips.Options.Single(option => option.Changes.Single().Dword == 1).Changes.Single().Address;
        Hold(Path.Combine(root, "edition-held"), tipsAddress, 1);
        var heldModel = await Load(held); heldModel.ShowAdvanced = true;
        var heldRow = heldModel.Rows.Single(item => item.Id == tips.Id);
        var remove = tips.Options.Single(option => option.Changes.Single().Dword is null).Id;
        check(!heldRow.UnavailableHere && heldRow.Current == "Custom value: 1" && heldRow.CanApplyChoice(remove), "Home keeps an existing tips override visible with Use Windows default available");
        heldRow.Selected = heldRow.Choices.Single(choice => choice.Id == remove);
        await heldModel.ReviewCommand.ExecuteAsync(null); heldModel.Approved = true; await heldModel.ApplyCommand.ExecuteAsync(null);
        check(held.Windows.Read(tipsAddress).Value is null && heldModel.Rows.Single(item => item.Id == tips.Id).Current == "Not available here", "Home can clear an existing tips override, and the row then reads Not available here");
        await heldModel.ReviewRestoreCommand.ExecuteAsync(null); heldModel.Approved = true; await heldModel.ApplyCommand.ExecuteAsync(null);
        check(held.Windows.Read(tipsAddress).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)) && held.Windows.ReadState()!.Profiles.Length == 0, "Undo puts the exact earlier tips override back on Home");
        var pro = new Fixture(Path.Combine(root, "edition-required"), subset, 26100, "Professional") { Missing = false };
        var proModel = await Load(pro); proModel.ShowAdvanced = true;
        var proRow = proModel.Rows.Single(item => item.Id == diagnostic.Id);
        proRow.Selected = proRow.Choices.Single(choice => choice.Id == required!.Id);
        await proModel.ReviewCommand.ExecuteAsync(null); proModel.Approved = true; await proModel.ApplyCommand.ExecuteAsync(null);
        check(pro.Windows.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)) && proModel.Rows.Single(item => item.Id == diagnostic.Id).Current == "Required diagnostic data",
            "Pro applies Required diagnostic data and reads it back");
        await proModel.ReviewRestoreCommand.ExecuteAsync(null); proModel.Approved = true; await proModel.ApplyCommand.ExecuteAsync(null);
        check(pro.Windows.Read(address).Value is null && pro.Windows.ReadState()!.Profiles.Length == 0 && proModel.Rows.Single(item => item.Id == diagnostic.Id).Current == "No override",
            "Undo removes Required diagnostic data again on Pro");

        var settingsAddress = settingsDiagnostic.Options.Single(option => option.Changes.Single().Dword == 3).Changes.Single().Address;
        foreach (var edition in new[] { "Core", "Professional", "Enterprise" })
        {
            var folder = Path.Combine(root, "edition-applied-" + edition);
            var applied = new Fixture(folder, subset, 26100, edition) { Missing = false };
            Hold(folder, address, 1); Hold(folder, settingsAddress, 3);
            var appliedModel = await Load(applied); appliedModel.ShowAdvanced = true;
            foreach (var (definition, value) in new[] { (diagnostic, 1u), (settingsDiagnostic, 3u) })
            {
                var row = appliedModel.Rows.Single(item => item.Id == definition.Id);
                var chosen = definition.Options.Single(option => option.Changes.Single().Dword == value).Id;
                var reset = definition.Options.Single(option => option.Changes.Single().Dword is null).Id;
                check(row.ToggleOn && row.AppliedChoice?.Id == chosen && row.Action.Id == chosen && row.Selected.Id.Length == 0 && !row.HasPendingChange && row.StateLabel == "On",
                    row.Name + " shows the value Windows already has, " + row.Action.Name + ", as on: " + edition);
                row.ToggleOn = false;
                check(row.Selected.Id == reset && row.CanApplySelected && row.StateLabel == "Will turn off" && row.Action.Id == chosen,
                    row.Name + " queues Use Windows default when switched off: " + edition);
            }
            await appliedModel.ReviewCommand.ExecuteAsync(null); appliedModel.Approved = true; await appliedModel.ApplyCommand.ExecuteAsync(null);
            check(applied.Windows.Read(address).Value is null && applied.Windows.Read(settingsAddress).Value is null
                && new[] { diagnostic, settingsDiagnostic }.All(definition => appliedModel.Rows.Single(item => item.Id == definition.Id) is { ToggleOn: false, IsApplied: false, Current: "No override" }),
                "Applying the switched-off rows removes both values and the rows read off: " + edition);
            await appliedModel.ReviewRestoreCommand.ExecuteAsync(null); appliedModel.Approved = true; await appliedModel.ApplyCommand.ExecuteAsync(null);
            check(applied.Windows.Read(address).Value is { Type: 4 } restored && restored.Bytes.SequenceEqual(BitConverter.GetBytes(1u))
                && applied.Windows.Read(settingsAddress).Value is { Type: 4 } restoredSettings && restoredSettings.Bytes.SequenceEqual(BitConverter.GetBytes(3u))
                && appliedModel.Rows.Single(item => item.Id == diagnostic.Id).AppliedChoice?.Name == "Required diagnostic data"
                && appliedModel.Rows.Single(item => item.Id == settingsDiagnostic.Id).AppliedChoice?.Name == "Allow Telemetry: 3",
                "Undo puts back the exact earlier values and both rows read on again: " + edition);
        }
    }
}
