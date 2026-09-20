using RooIndustries.Optimizer;

static class SavedChoiceChecks
{
    public static void Run(string root, TweakCatalog catalog, Action<bool, string> check, Action<Action, string> reject)
    {
        var path = Path.Combine(root, "saved-choices.json"); var choices = new TweakChoiceStore(path);
        var initial = choices.Read();
        var unavailable = catalog.Settings.First(setting => setting.Requirements?.Contains("office") == true);
        var selected = new TweakSelection(unavailable.Id, unavailable.Options[0].Id);
        var fixturePath = Path.Combine(root, "choice-windows.json"); var windows = FileTweakStore.Create(fixturePath);
        var before = OperationFiles.HashFile(fixturePath);
        var saved = choices.Save(catalog, "office", [selected], initial.Revision);
        check(saved.Profiles.Single().Selections.SequenceEqual(new[] { selected }) && OperationFiles.HashFile(fixturePath) == before, "A choice for a missing component is saved without claiming or changing Windows state");
        check(windows.ReadState() is null, "Saved choices alone never become a Windows recovery backup");
        var other = choices.Save(catalog, "explorer", [new("explorer.file-extensions", "show")], saved.Revision);
        var hash = OperationFiles.HashFile(path);
        reject(() => choices.Save(catalog, "office", [], saved.Revision), "A stale choice writer cannot overwrite another window's profile");
        check(OperationFiles.HashFile(path) == hash, "Rejected choice writes preserve every saved profile");
        reject(() => choices.Save(catalog, "bad", [new("unknown", "on")], other.Revision), "Saved choice profiles cannot inject unknown setting IDs");
        reject(() => choices.Save(catalog, "bad", [new("explorer.file-extensions", "show"), new("explorer.file-extensions", "hide")], other.Revision), "Conflicting saved choices are rejected before persistence");
        var remaining = choices.Save(catalog, "office", [], other.Revision);
        check(remaining.Profiles.Single().Id == "explorer", "Removing one saved profile preserves another profile");
        OperationFiles.Write(path, remaining with { Owner = remaining.Owner with { UserSid = remaining.Owner.UserSid + "-100" } });
        reject(() => choices.Read(), "Saved choices from another Windows user are rejected");
        OperationFiles.Write(path, remaining);
        choices.Save(catalog, "explorer", [], remaining.Revision);
        check(!File.Exists(path) && choices.Read().Profiles.Length == 0, "Removing the last saved profile leaves no phantom choice file");
    }
}
