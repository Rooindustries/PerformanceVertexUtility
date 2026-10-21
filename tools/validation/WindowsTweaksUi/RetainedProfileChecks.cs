using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class RetainedProfileChecks
{
    public static async Task Run(string root, TweakCatalog catalog, Action<bool, string> check)
    {
        foreach (var scenario in new[] { "adapter-switch", "registry-error", "service-transition", "restart", "checking", "timeout", "unobserved" })
        foreach (var keepCurrent in new[] { true, false })
        {
            var label = scenario + (keepCurrent ? " with Keep current" : " with a saved choice");
            var service = new ControlAddress("service", "RooIndustriesUiModelFixture", "running");
            var second = catalog.Settings.Single(setting => setting.Id == "second");
            var registry = second.Options.Single(option => option.Id == "on").Changes.Single().Address;
            var controls = scenario is not ("registry-error" or "adapter-switch");
            var subset = controls ? catalog with { Settings = catalog.Settings.Select(setting => setting.Id != second.Id ? setting : setting with
            {
                Options = [new("on", "Running", [], Controls: [new(service, ControlValues.From(true))]), new("off", "Stopped", [], Controls: [new(service, ControlValues.From(false))])],
            }).ToArray() } : catalog;
            var directory = Path.Combine(root, "retained-" + scenario + (keepCurrent ? "-keep" : "-saved"));
            var fixture = new Fixture(directory, subset) { Missing = false };
            var path = Path.Combine(directory, "windows.json");
            if (controls)
            {
                var data = OperationFiles.Read<TweakFixture>(path);
                data.Controls[service.Key] = new(service, "service:fixture:running", "fixture-binding", ControlValues.From(false), "Fixture service");
                OperationFiles.Write(path, data);
            }
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
            foreach (var row in model.Rows) row.Selected = row.Choices.Single(choice => choice.Id == "on");
            await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            var applied = fixture.Windows.ReadState()!;
            check(applied.Profiles.Single().Selections.Length == 2, "The " + scenario + " fixture starts with both applied claims");
            fixture.TransformStatus = inspection => inspection with { Settings = inspection.Settings.Where(status => scenario != "unobserved" || status.Id != second.Id).Select(status => status.Id != second.Id ? status : scenario == "restart"
                ? status with { Controls = status.Controls!.Select(control => control with { RestartPending = true }).ToArray() }
                : status with { Supported = false, ConfiguredChoices = [], AvailableChoices = [], Error = scenario switch
                {
                    "registry-error" => "A setting changed while being read.",
                    "adapter-switch" => "No devices expose this setting.",
                    "service-transition" => "The service is transitioning. Try again after it settles: " + service.Target,
                    "checking" => TweakEngine.FeaturesPending,
                    _ => TweakEngine.FeaturesTimedOut,
                } }).ToArray() };
            model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
            var firstRow = model.Rows.Single(row => row.Id == "first");
            var secondRow = model.Rows.Single(row => row.Id == second.Id);
            firstRow.Selected = firstRow.Choices.Single(choice => choice.Id == "off");
            if (keepCurrent) secondRow.Selected = secondRow.Choices[0];
            check(!secondRow.CanApplyChoice("on"), "The retained row cannot offer a fresh apply during " + scenario);
            var before = OperationFiles.HashFile(path);
            await model.ReviewCommand.ExecuteAsync(null);
            check(fixture.LastPreviewSelections?.OrderBy(selection => selection.SettingId).SequenceEqual(new[] { new TweakSelection("first", "off"), new TweakSelection("second", "on") }) == true,
                "Partial review retains the applied choice during " + scenario);
            check(model.HasReview && model.Changes.All(change => change.Name != secondRow.Name) && OperationFiles.HashFile(path) == before && !model.Detail.Contains("requirements pending", StringComparison.Ordinal),
                "Review never restores or defers the retained choice or writes fixture state during " + label);
            model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            var updated = fixture.Windows.ReadState()!;
            check(updated.Profiles.Single().Selections.Contains(new("second", "on")) && (controls
                ? updated.Controls!.Single().Original.Same(applied.Controls!.Single().Original) && fixture.Windows.ReadControl(service).Value.GetBoolean()
                : updated.Held.Single(item => item.Original.Address == registry).Original.Same(applied.Held.Single(item => item.Original.Address == registry).Original) && fixture.Windows.Read(registry).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u))),
                "Applying the other edit preserves the retained value and exact original backup during " + scenario);
            await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(fixture.Windows.ReadState()!.Profiles.Length == 0 && (controls ? !fixture.Windows.ReadControl(service).Value.GetBoolean() : fixture.Windows.Read(registry).Value is null),
                "Explicit undo restores the retained choice's original value after " + scenario);
        }
    }
}
