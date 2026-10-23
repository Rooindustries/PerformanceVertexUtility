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
        var tips = Find(@"SOFTWARE\Policies\Microsoft\Windows\CloudContent", "DisableSoftLanding");
        var spotlight = Find(@"SOFTWARE\Policies\Microsoft\Windows\CloudContent", "DisableWindowsSpotlightFeatures");
        var off = diagnostic.Options.Single(option => option.Changes.Single().Dword == 0);
        var required = diagnostic.Options.SingleOrDefault(option => option.Changes.Single().Dword == 1);
        check(required is not null, "Windows diagnostic data has a Required diagnostic data choice");
        var address = off.Changes.Single().Address;
        var subset = catalog with { Settings = [diagnostic, tips, spotlight], Presets = [], Incompatible = null };
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
            model.ShowAdvanced = false;
            check(model.Rows.Any(row => row.Id == tips.Id) == !limitedHere && model.Rows.Any(row => row.Id == spotlight.Id) == !limitedHere,
                "Simple mode hides tips and spotlight only where Windows ignores them: " + edition);
        }
        var held = new Fixture(Path.Combine(root, "edition-held"), subset, 26100, "Core") { Missing = false };
        var tipsAddress = tips.Options.Single(option => option.Changes.Single().Dword == 1).Changes.Single().Address;
        var state = OperationFiles.Read<TweakFixture>(Path.Combine(root, "edition-held", "windows.json"));
        var parts = tipsAddress.KeyPath.Split('\\');
        for (var count = 1; count <= parts.Length; count++)
        {
            var key = @"\REGISTRY\MACHINE\" + string.Join('\\', parts.Take(count));
            state.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
        }
        state.Keys[(@"\REGISTRY\MACHINE\" + tipsAddress.KeyPath).ToUpperInvariant()].Values[tipsAddress.ValueName!.ToUpperInvariant()] = new(tipsAddress.ValueName, 4, BitConverter.GetBytes(1u));
        OperationFiles.Write(Path.Combine(root, "edition-held", "windows.json"), state);
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
    }
}
