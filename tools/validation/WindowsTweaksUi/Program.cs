using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

var root = Path.Combine(Path.GetTempPath(), "roo-industries-tweak-ui-" + Guid.NewGuid().ToString("N"));
var count = 0;
void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); count++; Console.WriteLine("PASS " + message); }
async Task<WindowsTweaksViewModel> Load(Fixture fixture)
{
    App.Operations = fixture; var model = new WindowsTweaksViewModel(); await model.RefreshCommand.ExecuteAsync(null); return model;
}
try
{
    var fixture = new Fixture(Path.Combine(root, "missing")); var model = await Load(fixture);
    Check(model.Rows.Count == 1 && model.Rows[0].HasToggle && model.Rows[0].Choices.Length == 3, "Missing products retain every choice and an interactive toggle");
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null);
    Check(model.ApplyLabel == "Save choices" && !model.CanApply && fixture.Previews == 0, "A missing-product review offers saved choices with explicit confirmation and no Windows preview");
    model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Profiles.Single().Selections.Single() == new TweakSelection("setting", "on") && fixture.Windows.ReadState() is null && fixture.Applies == 0,
        "Saving unavailable choices persists intent without creating a Windows backup or running an apply");
    Check(model.Rows[0].Selected.Id == "on" && model.Rows[0].ToggleOn, "Reloading the page retains the saved toggle choice");
    await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Profiles.Length == 0 && fixture.Applies == 0 && model.Status == "Saved choices removed", "Saved-only restore removes preferences without a Windows restore call");

    fixture = new Fixture(Path.Combine(root, "apply-failure")) { Missing = false, FailApply = true }; model = await Load(fixture);
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Profiles.Length == 1 && fixture.Windows.ReadState() is null && model.Status == "Choices saved; Windows changes were not confirmed" && !model.CanApply,
        "A failed Windows apply retains the requested choices and never reports them applied");
    fixture.FailApply = false; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Length == 1, "The reviewed ready choice reaches the real file-backed transaction");
    var saved = fixture.Choices.Read(); fixture.FailApply = true;
    await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Revision == saved.Revision && fixture.Windows.ReadState()?.Profiles.Length == 1,
        "Failed Windows restoration preserves both the applied profile and saved choices");
    fixture.FailApply = false;
    fixture.AfterApply = () => fixture.Choices.Save(fixture.Catalog, "another-window", [new("setting", "on")], fixture.Choices.Read().Revision);
    await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Length == 0 && fixture.Choices.Read().Profiles.Length == 2 && model.Status == "Windows settings restored; saved choices need attention",
        "A concurrent preference change remains intact after a completed Windows restore and is reported separately");

    fixture = new Fixture(Path.Combine(root, "unknown")) { FailRead = true };
    fixture.Choices.Save(fixture.Catalog, "my-settings", [new("setting", "on")], null); model = await Load(fixture);
    Check(model.Rows.Count == 1 && !model.CanRestore && model.Rows[0].Selected.Id == "on", "An unreadable Windows state preserves saved choices without claiming an empty restore state");
    model.ClearSelectionCommand.Execute(null);
    Check(!model.CanReview, "An empty selection cannot initiate restore when Windows state is unknown");
    model.Rows[0].ToggleOn = true;
    Check(model.CanReview, "An unreadable Windows state still permits selecting a preference without applying it");

    fixture = new Fixture(Path.Combine(root, "stale")) { Missing = false }; model = await Load(fixture); model.Rows[0].ToggleOn = true;
    var pause = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); fixture.BeforePreview = () => pause.Task;
    var review = model.ReviewCommand.ExecuteAsync(null); model.Rows[0].Selected = model.Rows[0].Choices[0]; pause.SetResult(); await review;
    model.Approved = true;
    Check(!model.HasReview && !model.CanApply && fixture.Applies == 0, "Changing selection while a review is loading invalidates the old response");
    if (args is [var repo]) await SectionChecks.Run(root, Path.GetFullPath(repo), Check);
    Console.WriteLine($"Completed {count} Windows settings UI checks.");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
