using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class RetainedRequirementChecks
{
    public static async Task Run(string root, TweakCatalog catalog, Action<bool, string> check)
    {
        var remote = catalog.Settings.Single(setting => setting.Id == "windows.ca21070803421d26");
        var extensions = catalog.Settings.Single(setting => setting.Id == "explorer.file-extensions");
        var allowed = remote.Options.Single(option => option.Changes.Single().Dword == 0);
        var address = allowed.Changes.Single().Address;
        var directory = Path.Combine(root, "retained-remote-session");
        var fixture = new Fixture(directory, catalog with { Settings = [remote, extensions], Presets = [], Incompatible = null }, 26100) { Missing = false };
        var path = Path.Combine(directory, "windows.json"); var data = OperationFiles.Read<TweakFixture>(path);
        var parts = address.KeyPath.Split('\\');
        for (var count = 1; count <= parts.Length; count++)
        {
            var key = @"\REGISTRY\MACHINE\" + string.Join('\\', parts.Take(count));
            data.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
        }
        data.Keys[(@"\REGISTRY\MACHINE\" + address.KeyPath).ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = new(address.ValueName, 4, BitConverter.GetBytes(1u));
        OperationFiles.Write(path, data);
        App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
        model.Rows.Single(row => row.Id == remote.Id).Selected = model.Rows.Single(row => row.Id == remote.Id).Choices.Single(choice => choice.Id == allowed.Id);
        model.Rows.Single(row => row.Id == extensions.Id).Selected = model.Rows.Single(row => row.Id == extensions.Id).Choices.Single(choice => choice.Id == "show");
        await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
        check(fixture.Windows.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)) && fixture.Windows.ReadState()!.Profiles.Single().Selections.Length == 2,
            "The remote-session fixture begins with RDP allowed and both applied claims");
        data = OperationFiles.Read<TweakFixture>(path); OperationFiles.Write(path, data with { RemoteSession = true });
        model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
        var remoteRow = model.Rows.Single(row => row.Id == remote.Id); remoteRow.Selected = remoteRow.Choices[0];
        var extensionRow = model.Rows.Single(row => row.Id == extensions.Id); extensionRow.Selected = extensionRow.Choices.Single(choice => choice.Id == "hide");
        var before = OperationFiles.HashFile(path);
        await model.ReviewCommand.ExecuteAsync(null);
        check(fixture.LastPreviewSelections?.Contains(new(remote.Id, allowed.Id)) == true && model.ApplyLabel == "Save choices" && model.Changes.Count == 0,
            "Editing another setting over RDP retains the local-session choice and refuses the review");
        model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
        check(fixture.Applies == 1 && OperationFiles.HashFile(path) == before && fixture.Windows.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)),
            "A refused remote-session edit preserves the allowed RDP value and exact backup state");
        data = OperationFiles.Read<TweakFixture>(path); OperationFiles.Write(path, data with { RemoteSession = false });
        await model.RefreshCommand.ExecuteAsync(null);
        remoteRow = model.Rows.Single(row => row.Id == remote.Id); remoteRow.Selected = remoteRow.Choices[0];
        extensionRow = model.Rows.Single(row => row.Id == extensions.Id); extensionRow.Selected = extensionRow.Choices.Single(choice => choice.Id == "hide");
        await model.ReviewCommand.ExecuteAsync(null);
        check(model.HasReview && model.Changes.All(change => change.Name != remoteRow.Name), "Returning to a local session reviews only the requested other change");
        model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
        await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
        check(fixture.Windows.ReadState()!.Profiles.Length == 0 && fixture.Windows.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)),
            "Explicit local undo restores the exact original RDP denial value");
    }
}
