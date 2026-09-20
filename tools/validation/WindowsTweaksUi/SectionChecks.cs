using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class SectionChecks
{
    public static async Task Run(string root, string repo, Action<bool, string> check)
    {
        var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend/catalogs/windows-tweaks.json"));
        var fixture = new Fixture(Path.Combine(root, "sections"), catalog) { Missing = false };
        App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
        check(model.Rows.Count == catalog.Settings.Length && model.Rows.Select(row => row.Id).Distinct().Count() == catalog.Settings.Length,
            "All catalog settings remain present exactly once in the all-tweaks view");
        var seen = new HashSet<string>(); var allOptions = new Dictionary<string, string[]>();
        foreach (var section in model.Sections.Skip(1))
        {
            model.SelectedSection = section;
            check(model.Rows.All(row => row.SectionId == section.Id) && model.Rows.Count == section.Count, section.Name + " shows only its own settings and an accurate count");
            foreach (var row in model.Rows) { if (!seen.Add(row.Id)) throw new InvalidOperationException("A setting appears in multiple sections"); allOptions[row.Id] = row.Choices.Skip(1).Select(choice => choice.Id).ToArray(); }
        }
        check(seen.SetEquals(catalog.Settings.Select(setting => setting.Id)) && catalog.Settings.All(setting => allOptions[setting.Id].SequenceEqual(setting.Options.Select(option => option.Id))),
            "Section membership preserves every original setting and option identity");
        model.SelectedSection = model.Sections.Single(section => section.Id == "network");
        check(model.Rows.Any(row => row.Id == "windows.06086057572c648a") && model.Rows.Any(row => row.Id == "windows.2dbe283afcf3f9a2"),
            "Network includes traffic scheduling and usage tracking formerly filed under System and Services");
        check(model.Rows.All(row => row.Description.Length > 0 && !row.Description.Contains('\\') && !row.Description.Contains("DWORD", StringComparison.OrdinalIgnoreCase)),
            "Every network row has visible purpose copy without registry implementation text");
        var network = model.Rows.Single(row => row.Id == "windows.06086057572c648a"); network.Selected = network.Choices[1];
        model.SelectedSection = model.Sections.Single(section => section.Id == "debloat");
        var debloat = model.Rows.First(row => row.Available && row.Definition.Options[0].Changes is { Length: > 0 }); debloat.Selected = debloat.Choices[1];
        check(model.Sections.Single(section => section.Id == "network").SelectedCount == 1 && model.SelectedSection.SelectedCount == 1 && model.SelectionText == "2 selected",
            "Selections survive navigation and category badges distinguish selection from applied state");
        await model.ReviewCommand.ExecuteAsync(null);
        check(model.HasReview && model.Changes.Count >= 2 && model.Changes.All(change => !change.Target.Contains('\\') && !change.Target.Contains("LocalMachine", StringComparison.Ordinal)),
            "Cross-section review includes both choices while presenting scope instead of registry paths: " + model.Status + " " + model.Detail);
        model.Approved = true; model.SelectedSection = model.Sections.Single(section => section.Id == "network");
        check(model.CanApply && network.Selected.Id == network.Choices[1].Id, "Changing sections preserves an already reviewed selection");
        network.Selected = null!;
        check(model.CanApply && network.Selected.Id == network.Choices[1].Id && model.SelectionText == "2 selected",
            "A recycled choice control cannot clear its selection or approval through a transient null binding");
        model.FindSetting("timer");
        check(model.SelectedSection.Id == "all" && model.Rows.Any(row => row.Name.Contains("timer", StringComparison.OrdinalIgnoreCase)),
            "Existing links can still find settings across every section");
        model.Search = "camera";
        var legacy = model.Rows.Single(row => row.Id == "windows.27dceacfb5f3bad8"); legacy.Alternatives[0].OpenCommand.Execute(null);
        check(model.Rows.Count == 1 && model.Rows[0].Id == "windows.3b7506aee9968d0e" && model.SelectedSection.Id == model.Rows[0].SectionId,
            "A current-policy link selects its target section and exact existing setting");
        model.SelectedSection = model.Sections.Single(section => section.Id == "network"); model.Source = "Gaming toggles";
        check(model.Rows.Count > 0 && model.Rows.All(row => row.Definition.Sources.Any(source => source.Product == "Gaming toggles")),
            "Source filters continue to work inside a section");
        check(fixture.Applies == 0 && fixture.Windows.ReadState() is null, "Navigation and review never apply settings or create a backup");
    }
}
