using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class PolicyProfileChecks
{
    public static async Task Run(string root, TweakCatalog catalog, Action<bool, string> check)
    {
        var consumer = catalog.Settings.Single(setting => setting.Id == "windows.a8268996c3eb9072");
        var extensions = catalog.Settings.Single(setting => setting.Id == "explorer.file-extensions");
        var blocked = new TweakSelection(consumer.Id, consumer.Options.Single(option => option.Changes.Single().Dword == 1).Id);
        var address = consumer.Options.Single(option => option.Id == blocked.OptionId).Changes.Single().Address;
        foreach (var partial in new[] { true, false })
        {
            var directory = Path.Combine(root, partial ? "policy-partial" : "policy-single");
            var subset = catalog with { Settings = partial ? [consumer, extensions] : [consumer], Presets = [], Incompatible = null };
            var fixture = new Fixture(directory, subset, 26100) { Missing = false };
            var path = Path.Combine(directory, "windows.json"); var state = OperationFiles.Read<TweakFixture>(path);
            var parts = address.KeyPath.Split('\\');
            for (var count = 1; count <= parts.Length; count++)
            {
                var key = @"\REGISTRY\MACHINE\" + string.Join('\\', parts.Take(count));
                state.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
            }
            state.Keys[(@"\REGISTRY\MACHINE\" + address.KeyPath).ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = new(address.ValueName, 4, BitConverter.GetBytes(0u));
            OperationFiles.Write(path, state);
            var old = subset with { Settings = subset.Settings.Select(setting => setting.Id == consumer.Id ? setting with { Options = setting.Options.Select(option => option with { Availability = [new(10240, 26200, ["*"])] }).ToArray() } : setting).ToArray() };
            var oldEngine = new TweakEngine(old, fixture.Windows); var plan = oldEngine.Preview("my-settings", [blocked]);
            var reviewPath = Path.Combine(directory, "old-review.json"); OperationFiles.Write(reviewPath, plan); oldEngine.Apply(reviewPath, OperationFiles.HashFile(reviewPath));
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
            var row = model.Rows.Single(item => item.Id == consumer.Id);
            check(!row.CanApplyChoice(blocked.OptionId) && row.AppliedChoice is null && row.Current == "Custom value: 1", "Pro 26100 shows an old blocked override as a custom value rather than an applicable current choice");
            if (partial)
            {
                var extensionRow = model.Rows.Single(item => item.Id == extensions.Id);
                extensionRow.Selected = extensionRow.Choices.Single(choice => choice.Id == "show");
            }
            var before = OperationFiles.HashFile(path);
            await model.ReviewCommand.ExecuteAsync(null);
            if (partial)
            {
                check(fixture.LastPreviewSelections?.SequenceEqual(new[] { new TweakSelection(extensions.Id, "show") }) == true && model.Changes.Count == 2 && model.Changes.Any(change => change.Name == row.Name) && !model.Approved,
                    "A supported profile edit excludes an unavailable retained choice and shows its original-value restoration in the approval preview");
                check(OperationFiles.HashFile(path) == before, "Reviewing a partial old profile changes no fixture values or recovery data");
                model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
                check(fixture.Applies == 1 && fixture.Windows.ReadState()!.Profiles.Single().Selections.SequenceEqual(new[] { new TweakSelection(extensions.Id, "show") }) && fixture.Windows.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)),
                    "An approved partial edit applies its supported choice and restores the obsolete policy claim exactly as reviewed");
                check(fixture.Choices.Read().Profiles.Single().Selections.Contains(blocked), "The unavailable consumer choice stays saved for a supported Windows edition");
            }
            else
            {
                check(fixture.Previews == 0 && model.Changes.Count == 0 && model.Status == "Save the selected choices", "An entirely unavailable old profile offers save-only without an implicit restore preview");
                model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
                check(fixture.Applies == 0 && OperationFiles.HashFile(path) == before && fixture.Choices.Read().Profiles.Single().Selections.Contains(blocked), "Saving an unavailable old choice preserves its active claim, original backup and current override");
            }
            await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(fixture.Windows.ReadState()!.Profiles.Length == 0 && fixture.Windows.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)), "Explicit restore still returns the old profile to its exact original policy value");
        }
    }
}
