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
        var tipsPolicy = tips.Options.Single(option => option.Changes is [{ Dword: 1 }]).Id;
        var switches = new[] { "SubscribedContent-338389Enabled", "SoftLandingEnabled" };
        var personal = tips.Options.SingleOrDefault(option => option.Changes.Length == switches.Length && option.Changes.All(change => change is { Dword: 0, Address.Hive: "CurrentUser" } &&
            string.Equals(change.Address.KeyPath, @"SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", StringComparison.OrdinalIgnoreCase) && switches.Contains(change.Address.ValueName, StringComparer.OrdinalIgnoreCase)));
        check(personal is not null, "Windows tips has a choice that turns this user's Settings switches off");
        var remove = tips.Options.Single(option => option.Changes is [{ Dword: null }]).Id;
        var homeReset = tips.Options.SingleOrDefault(option => option.Replaces == remove && option.Changes.Length == switches.Length + 1 && option.Changes.All(change => change.Address.ValueName == "SoftLandingEnabled" ? change is { Dword: 1 } : change is { Dword: null, Value: null }))?.Id;
        check(homeReset is not null, "Windows tips has a Use Windows default for Home and Pro that removes the policy and puts this user's Settings switches back as a new profile has them");
        var off = diagnostic.Options.Single(option => option.Changes is [{ Dword: 0 }]);
        var required = diagnostic.Options.SingleOrDefault(option => option.Changes is [{ Dword: 1 }]);
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
            foreach (var definition in new[] { spotlight })
            {
                var row = model.Rows.Single(item => item.Id == definition.Id);
                var on = definition.Options.Single(option => option.Changes is [{ Dword: 1 }]).Id;
                check(row.UnavailableHere == limitedHere && !row.CanRetry && row.Current == (limitedHere ? "Not available here" : "No override") && row.CanApplyChoice(on) == !limitedHere &&
                    row.Detail == (limitedHere ? "This Windows edition or version doesn't use this setting. You can keep a saved choice for a matching installation." : ""),
                    row.Name + " reads Not available here only where Windows ignores it: " + edition);
            }
            var tipsRow = model.Rows.Single(item => item.Id == tips.Id);
            check(tipsRow.Scope == (limitedHere ? "This user" : "Entire PC"), tipsRow.Name + " names the scope of the choice this Windows edition can use: " + edition);
            check(!tipsRow.UnavailableHere && !tipsRow.CanRetry && tipsRow.Current == "No override" && tipsRow.Detail == "" && tipsRow.Action.Id == (limitedHere ? personal?.Id : tipsPolicy) &&
                tipsRow.CanApplyChoice(tipsPolicy) == !limitedHere && (personal is not null && tipsRow.CanApplyChoice(personal.Id)) == limitedHere,
                tipsRow.Name + " starts on the way to turn tips off that Windows honors here: " + edition);
            check(tipsRow.PickerChoices.Select(choice => choice.Id).SequenceEqual(limitedHere ? [homeReset!, personal!.Id] : [remove, tipsPolicy]) && tipsRow.PickerChoices.Count(choice => choice.Name == "Use Windows default") == 1,
                tipsRow.Name + " lists one Use Windows default and only the choices this Windows edition can use: " + edition + ": " + string.Join(", ", tipsRow.PickerChoices.Select(choice => choice.Name)));
            var diagnosticRow = model.Rows.Single(item => item.Id == diagnostic.Id);
            check(!diagnosticRow.UnavailableHere && diagnosticRow.Current == "No override" && diagnosticRow.CanApplyChoice(required!.Id) && diagnosticRow.CanApplyChoice(off.Id) == !limitedHere &&
                diagnosticRow.ActionChoices.Any(choice => choice.Id == required.Id && choice.Name == "Required diagnostic data"),
                "Windows diagnostic data offers Off only where Windows honors it and Required diagnostic data everywhere: " + edition);
            check(diagnosticRow.PickerChoices.SequenceEqual(diagnosticRow.ActionChoices), "Windows diagnostic data keeps every choice in its list, since Required diagnostic data is offered on every edition: " + edition);
            if (limitedHere)
            {
                tipsRow.Selected = tipsRow.Choices.Single(choice => choice.Id == tipsPolicy);
                check(tipsRow.PickerChoices.Contains(tipsRow.Action) && tipsRow.Action.Id == tipsPolicy, tipsRow.Name + " keeps a choice saved for a matching installation in its list: " + edition);
                tipsRow.Selected = tipsRow.Choices[0];
            }
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
            check(model.Rows.Any(row => row.Id == spotlight.Id) == (!limitedHere && !spotlight.Advanced),
                spotlight.Name + " follows edition availability and catalog visibility in simple mode: " + edition);
            check(model.Rows.Any(row => row.Id == tips.Id) == !tips.Advanced, tips.Name + " follows catalog visibility in simple mode on every edition: " + edition);
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
        foreach (var edition in new[] { "Core", "Enterprise" })
        {
            var unread = new WindowsTweakRow(tips, catalog.Settings.ToDictionary(setting => setting.Id), _ => { });
            unread.Observe(new TweakSettingStatus(tips.Id, tips.Name, false, [], [], "Windows could not read this setting."), new(new("FIXTURE-PC", "S-1-5-21-1-2-3-1001"), "fixture:unread", 26100, edition));
            check(unread.PickerChoices.Select(choice => choice.Id).SequenceEqual(edition == "Core" ? [homeReset!, personal!.Id] : [remove, tipsPolicy]),
                tips.Name + " lists only the choices this Windows edition can use even when the read fails: " + edition + ": " + string.Join(", ", unread.PickerChoices.Select(choice => choice.Name)));
            check(unread.Action.Id == (edition == "Core" ? personal!.Id : tipsPolicy) && unread.Scope == (edition == "Core" ? "This user" : "Entire PC"),
                tips.Name + " starts on the choice and scope this Windows edition can use even when the read fails: " + edition + ": " + unread.Action.Name + " · " + unread.Scope);
        }
        var held = new Fixture(Path.Combine(root, "edition-held"), subset, 26100, "Core") { Missing = false };
        var tipsAddress = tips.Options.Single(option => option.Id == tipsPolicy).Changes.Single().Address;
        Hold(Path.Combine(root, "edition-held"), tipsAddress, 1);
        var heldModel = await Load(held); heldModel.ShowAdvanced = true;
        var heldRow = heldModel.Rows.Single(item => item.Id == tips.Id);
        check(!heldRow.UnavailableHere && heldRow.Current.StartsWith("Custom value", StringComparison.Ordinal) && heldRow.CanApplyChoice(homeReset!), "Home keeps an existing tips override visible with Use Windows default available");
        heldRow.Selected = heldRow.Choices.Single(choice => choice.Id == homeReset);
        await heldModel.ReviewCommand.ExecuteAsync(null); heldModel.Approved = true; await heldModel.ApplyCommand.ExecuteAsync(null);
        bool HeldSwitches(uint? softLanding) => personal!.Changes.All(change => held.Windows.Read(change.Address).Value is var data &&
            (change.Address.ValueName == "SoftLandingEnabled" && softLanding is { } number ? data is { Type: 4 } && data.Bytes.SequenceEqual(BitConverter.GetBytes(number)) : data is null));
        check(held.Windows.Read(tipsAddress).Value is null && HeldSwitches(1) && heldModel.Rows.Single(item => item.Id == tips.Id) is { UnavailableHere: false, Current: "Use Windows default" },
            "Home can clear an existing tips override; this user's switches are left as a new profile has them and the row reads Use Windows default");
        await heldModel.ReviewRestoreCommand.ExecuteAsync(null); heldModel.Approved = true; await heldModel.ApplyCommand.ExecuteAsync(null);
        check(held.Windows.Read(tipsAddress).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)) && HeldSwitches(null) && held.Windows.ReadState()!.Profiles.Length == 0, "Undo puts the exact earlier tips override back on Home and removes the switch values it wrote");
        var personalAddresses = personal!.Changes.Select(change => change.Address).ToArray();
        var owners = personalAddresses.Select(target => catalog.Settings.Single(setting => setting.Id != tips.Id && setting.Options.All(option => option.Changes is [{ Address: var only }] && only.Hive == target.Hive &&
            string.Equals(only.KeyPath, target.KeyPath, StringComparison.OrdinalIgnoreCase) && string.Equals(only.ValueName, target.ValueName, StringComparison.OrdinalIgnoreCase)))).ToArray();
        void SeedSwitches(string folder, params uint[] values)
        {
            var state = OperationFiles.Read<TweakFixture>(Path.Combine(folder, "windows.json"));
            var prefix = @"\REGISTRY\USER\" + state.Context.Owner.UserSid + @"\";
            var parts = personalAddresses[0].KeyPath.Split('\\');
            for (var count = 2; count <= parts.Length; count++) state.Keys.TryAdd((prefix + string.Join('\\', parts.Take(count))).ToUpperInvariant(), new(prefix + string.Join('\\', parts.Take(count)), "fixture", []));
            for (var slot = 0; slot < personalAddresses.Length; slot++)
                state.Keys[(prefix + personalAddresses[slot].KeyPath).ToUpperInvariant()].Values[personalAddresses[slot].ValueName!.ToUpperInvariant()] = new(personalAddresses[slot].ValueName!, 4, BitConverter.GetBytes(values[slot % values.Length]));
            OperationFiles.Write(Path.Combine(folder, "windows.json"), state);
        }
        bool Reset(Fixture fixture) => personalAddresses.All(target => fixture.Windows.Read(target).Value is var data && (target.ValueName == "SoftLandingEnabled" ? data is { Type: 4 } && data.Bytes.SequenceEqual(BitConverter.GetBytes(1u)) : data is null));
        void ResetLines(WindowsTweaksViewModel model, string step) => check(model.Changes.Count == owners.Length && owners.Select((owner, slot) => model.Changes.Count(line => line.Name == (WindowsTweakPresentation.For(owner).Name ?? owner.Name) && line.Before == "Off (0)" &&
            line.After == (personalAddresses[slot].ValueName == "SoftLandingEnabled" ? "On (1)" : "No override") && line.Target == "This user") == 1).All(found => found),
            tips.Name + " " + step + " review puts each Settings switch back as a new profile has it: " + string.Join(" | ", model.Changes.Select(line => line.Name + ": " + line.Before + " → " + line.After + " · " + line.Target)));
        bool Switches(Fixture fixture, uint? value) => personalAddresses.All(target => fixture.Windows.Read(target).Value is var data && (value is null ? data is null : data is { Type: 4 } && data.Bytes.SequenceEqual(BitConverter.GetBytes(value.Value))));
        void Lines(WindowsTweaksViewModel model, string from, string to, string step) => check(model.Changes.Count == owners.Length && owners.All(owner => model.Changes.Count(line =>
            line.Name == (WindowsTweakPresentation.For(owner).Name ?? owner.Name) && line.Before == from && line.After == to && line.Target == "This user") == 1),
            tips.Name + " " + step + " review names each Settings switch for this user: " + string.Join(" | ", model.Changes.Select(line => line.Name + ": " + line.Before + " → " + line.After + " · " + line.Target)));
        foreach (var (edition, seeded) in new[] { ("Professional", false), ("Core", true) })
        {
            var folder = Path.Combine(root, "edition-tips-" + edition);
            var fixture = new Fixture(folder, subset with { Settings = [.. subset.Settings, .. owners] }, 26100, edition) { Missing = false };
            if (seeded) SeedSwitches(folder, 1);
            bool Present(uint? value) => Switches(fixture, value);
            var original = seeded ? 1u : (uint?)null;
            var before = seeded ? "On (1)" : "No override";
            var model = await Load(fixture); model.ShowAdvanced = true;
            var row = model.Rows.Single(item => item.Id == tips.Id);
            check(!row.UnavailableHere && row.Current == (seeded ? "Windows default" : "No override") && row.Action.Id == personal.Id && !row.ToggleOn, row.Name + " shows the per-user choice ready to switch on: " + edition);
            row.ToggleOn = true;
            check(row.Selected.Id == personal.Id && row.CanApplySelected, row.Name + " queues the per-user choice when switched on: " + edition);
            await model.ReviewCommand.ExecuteAsync(null); Lines(model, before, "Off (0)", "apply on " + edition);
            model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            row = model.Rows.Single(item => item.Id == tips.Id);
            check(Present(0) && fixture.Windows.Read(tipsAddress).Value is null && row is { Current: "On for this user", ToggleOn: true, HasPendingChange: false, StateLabel: "On" } && row.AppliedChoice?.Id == personal.Id,
                row.Name + " turns this user's Settings switches off and reads On for this user: " + edition);
            row.ToggleOn = false;
            check(row.Selected.Id == homeReset && row.StateLabel == "Will turn off", row.Name + " queues Use Windows default when switched off: " + edition);
            await model.ReviewCommand.ExecuteAsync(null); ResetLines(model, "switch-off on " + edition);
            model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            row = model.Rows.Single(item => item.Id == tips.Id);
            check(Reset(fixture) && !row.IsApplied && row.Current == "Use Windows default", row.Name + " switched off puts this user's Settings switches back as Windows keeps them: " + edition);
            row.Selected = row.Choices.Single(choice => choice.Id == personal.Id);
            await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(Present(0), row.Name + " applies again after being switched off: " + edition);
            await model.ReviewRestoreCommand.ExecuteAsync(null); Lines(model, "Off (0)", before, "Undo on " + edition);
            model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(Present(original) && fixture.Windows.ReadState()!.Profiles.Length == 0 && model.Rows.Single(item => item.Id == tips.Id) is { IsApplied: false, ToggleOn: false },
                "Undo puts the exact earlier Settings switches back: " + edition);
        }
        {
            var folder = Path.Combine(root, "edition-tips-Enterprise-seeded");
            var seededEnterprise = new Fixture(folder, subset with { Settings = [.. subset.Settings, .. owners] }, 26100, "Enterprise") { Missing = false };
            SeedSwitches(folder, 1);
            var enterprise = await Load(seededEnterprise);
            enterprise.ShowAdvanced = true;
            check(enterprise.Rows.Single(item => item.Id == tips.Id) is { UnavailableHere: false, Current: "No override" } enterpriseRow && enterpriseRow.Action.Id == tipsPolicy,
                "Enterprise ignores this user's Settings switches, which only Home and Pro use, and reads No override with the policy choice ready");
        }
        {
            var folder = Path.Combine(root, "edition-tips-Enterprise-damaged");
            var damaged = new Fixture(folder, subset with { Settings = [.. subset.Settings, .. owners] }, 26100, "Enterprise") { Missing = false };
            SeedSwitches(folder, 1);
            var state = OperationFiles.Read<TweakFixture>(Path.Combine(folder, "windows.json"));
            var target = personalAddresses.Single(address => address.ValueName == "SoftLandingEnabled");
            state.Keys[(@"\REGISTRY\USER\" + state.Context.Owner.UserSid + @"\" + target.KeyPath).ToUpperInvariant()].Values[target.ValueName!.ToUpperInvariant()] = new(target.ValueName!, 4, [1, 0, 0]);
            OperationFiles.Write(Path.Combine(folder, "windows.json"), state);
            var enterprise = await Load(damaged); enterprise.ShowAdvanced = true;
            check(enterprise.Rows.Single(item => item.Id == tips.Id) is { CouldNotCheck: false, CanRetry: false, UnavailableHere: false, Current: "No override" } row && row.Action.Id == tipsPolicy,
                "A damaged per-user tips switch, which Enterprise doesn't use, doesn't make the policy row Couldn't check on Enterprise");
        }
        foreach (var edition in new[] { "Core", "Professional" })
        {
            var folder = Path.Combine(root, "edition-tips-off-" + edition);
            var fixture = new Fixture(folder, subset with { Settings = [.. subset.Settings, .. owners] }, 26100, edition) { Missing = false };
            SeedSwitches(folder, 0);
            var model = await Load(fixture); model.ShowAdvanced = true;
            var row = model.Rows.Single(item => item.Id == tips.Id);
            check(row is { Current: "On for this user", ToggleOn: true, IsApplied: true } && row.AppliedChoice?.Id == personal.Id,
                row.Name + " reads On for this user when this user already turned tips off in Settings: " + edition);
            row.ToggleOn = false;
            check(row.Selected.Id == homeReset && row.StateLabel == "Will turn off", row.Name + " queues Use Windows default when tips were turned off outside the app: " + edition);
            await model.ReviewCommand.ExecuteAsync(null); ResetLines(model, "switch-off after Settings on " + edition);
            model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            row = model.Rows.Single(item => item.Id == tips.Id);
            check(Reset(fixture) && fixture.Windows.Read(tipsAddress).Value is null && row is { Current: "Use Windows default", ToggleOn: false, IsApplied: false },
                row.Name + " switched off turns tips back on for this user after they were turned off in Settings: " + edition);
            await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(Switches(fixture, 0) && fixture.Windows.ReadState()!.Profiles.Length == 0, "Undo puts this user's own Settings switches back off: " + edition);
        }
        {
            var folder = Path.Combine(root, "edition-tips-mixed");
            var fixture = new Fixture(folder, subset with { Settings = [.. subset.Settings, .. owners] }, 26100, "Core") { Missing = false };
            SeedSwitches(folder, personalAddresses.Select(target => string.Equals(target.ValueName, "SubscribedContent-338389Enabled", StringComparison.OrdinalIgnoreCase) ? 0u : 1u).ToArray());
            var model = await Load(fixture); model.ShowAdvanced = true;
            check(model.Rows.Single(item => item.Id == tips.Id) is { Current: "Custom value", IsApplied: false }, "Windows tips reads Custom value, not Use Windows default, when only one Settings switch is off on Home");
        }
        var updates = new[] { "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "TargetReleaseVersion" }.Select(name => Find(@"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate", name)).ToArray();
        foreach (var (edition, build, honored) in new[] { ("Core", 26100, false), ("CloudEdition", 26100, false), ("Professional", 26100, true), ("Enterprise", 26100, true), ("Professional", 14392, false) })
        {
            var model = await Load(new Fixture(Path.Combine(root, "edition-updates-" + edition + "-" + build), catalog with { Settings = updates, Presets = [], Incompatible = null }, build, edition) { Missing = false });
            model.ShowAdvanced = true;
            foreach (var definition in updates)
            {
                var row = model.Rows.Single(item => item.Id == definition.Id);
                var policy = definition.Options.Single(option => option.Changes is [{ Dword: not null }]).Id;
                check(row.UnavailableHere == !honored && !row.CanRetry && row.Current == (honored ? "No override" : "Not available here") && row.CanApplyChoice(policy) == honored,
                    row.Name + " reads Not available here, without Retry, only where Windows Update client policies don't work: " + edition + " build " + build + ": " + row.Current);
            }
        }
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
            check(applied.Windows.Read(address).Value is null && applied.Windows.Read(settingsAddress).Value is null, "Applying the switched-off rows removes both values: " + edition);
            check(new[] { diagnostic, settingsDiagnostic }.All(definition => appliedModel.Rows.Single(item => item.Id == definition.Id) is { IsApplied: false, Current: "No override" } row
                && row.Selected.Id == definition.Options.Single(option => option.Changes.Single().Dword is null).Id),
                "Both rows then read No override with the saved Use Windows default choice loaded: " + edition);
            await appliedModel.ReviewRestoreCommand.ExecuteAsync(null); appliedModel.Approved = true; await appliedModel.ApplyCommand.ExecuteAsync(null);
            check(applied.Windows.Read(address).Value is { Type: 4 } restored && restored.Bytes.SequenceEqual(BitConverter.GetBytes(1u))
                && applied.Windows.Read(settingsAddress).Value is { Type: 4 } restoredSettings && restoredSettings.Bytes.SequenceEqual(BitConverter.GetBytes(3u))
                && appliedModel.Rows.Single(item => item.Id == diagnostic.Id) is { ToggleOn: true, AppliedChoice.Name: "Required diagnostic data" }
                && appliedModel.Rows.Single(item => item.Id == settingsDiagnostic.Id) is { ToggleOn: true, AppliedChoice.Name: "Allow Telemetry: 3" },
                "Undo puts back the exact earlier values and both rows read on again: " + edition);
        }
    }
}
