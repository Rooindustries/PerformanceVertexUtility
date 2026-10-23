using System.Text;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class TypeTwinChecks
{
    static string Writes(TweakOption option) => option.Changes.Single() switch
    {
        { Value: { Type: 1 } value } => "REG_SZ " + Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0'),
        { Value: { } value } => "type " + value.Type + " " + Convert.ToHexString(value.Bytes),
        { Dword: { } number } => "REG_DWORD " + number,
        _ => "removal",
    };
    public static async Task Run(string root, TweakCatalog catalog, Action<bool, string> check)
    {
        foreach (var (settingId, olderId) in new[] { ("windows.c55fa4621a954e21", "choice-95a6ed84299d0109"), ("windows.8c7a398b0e1a5c1d", "choice-c55db10b623ad078") })
        {
            var setting = catalog.Settings.Single(item => item.Id == settingId);
            var older = setting.Options.Single(option => option.Id == olderId);
            var address = older.Changes.Single().Address;
            var fixture = new Fixture(Path.Combine(root, "twins-" + settingId), catalog with { Settings = [setting], Presets = [], Incompatible = null }) { Missing = false };
            var plan = fixture.Engine.Preview("my-settings", [new(settingId, olderId)]);
            var file = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(file, plan); fixture.Engine.Apply(file, OperationFiles.HashFile(file));
            App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null);
            var row = model.Rows.Single(item => item.Id == settingId);
            var picked = setting.Options.Single(option => option.Id == row.Selected.Id);
            check(Writes(picked).StartsWith("REG_SZ ", StringComparison.Ordinal) && Writes(picked).EndsWith(" " + Writes(older).Split(' ')[^1], StringComparison.Ordinal),
                setting.Name + ": a saved " + older.Name + " from an older app loads as " + row.Selected.Name + ", which writes the text Windows keeps (" + Writes(picked) + ")");
            check(row.Choices.Skip(1).Select(choice => Writes(setting.Options.Single(option => option.Id == choice.Id))).Distinct().Count() == row.Choices.Length - 1,
                setting.Name + ": the row lists each written value once (" + string.Join(", ", row.Choices.Skip(1).Select(choice => choice.Name)) + ")");
            await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(fixture.Windows.Read(address).Value is { Type: 1 } text && Writes(picked) == "REG_SZ " + Encoding.Unicode.GetString(text.Bytes).TrimEnd('\0'),
                setting.Name + ": reviewing that saved choice again writes the text Windows keeps");
            row = model.Rows.Single(item => item.Id == settingId);
            check(row.Current == row.Selected.Name || row.Current == picked.Name, setting.Name + ": the row reads as one choice afterwards (" + row.Current + ")");
            await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
            check(fixture.Windows.Read(address).Value is null && fixture.Windows.ReadState()?.Profiles.Length is null or 0, setting.Name + ": Undo removes the value the older app's profile added");
        }
    }
}
