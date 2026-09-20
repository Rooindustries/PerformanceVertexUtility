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
TweakRecovery Pending(Fixture fixture, string phase, bool committed)
{
    var plan = fixture.Engine.Preview("pending-profile", [new("setting", "on")]) with
    {
        Controls = new ControlPlan([], [], []),
    };
    var state = committed ? new TweakState
    {
        SchemaVersion = 1,
        Context = plan.Context,
        Revision = "pending-revision",
        Profiles = [],
        Held = [],
        CreatedKeys = [],
        History = [new TweakHistory(plan.OperationId, "pending-hash", plan.ProfileId, DateTime.UtcNow, [], [])],
        Notices = [],
        Controls = [],
    } : null;
    return new(state, new ControlJournal(plan, "pending-hash", 0, phase), "pending-hash");
}
try
{
    if (args is [var catalogRepo])
    {
        var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(Path.GetFullPath(catalogRepo), "backend/catalogs/windows-tweaks.json"));
        ActionChecks.Run(catalog, Check);
    }
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

    fixture = new Fixture(Path.Combine(root, "action-review")) { Missing = false }; model = await Load(fixture);
    var actionRow = model.Rows.Single();
    actionRow.ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true;
    Check(model.HasReview && model.CanApply, "A selected action reaches a confirmed review before the stale-action check");
    actionRow.Action = actionRow.ActionChoices.Single(choice => choice.Id == "off");
    Check(actionRow.Selected.Id == "off" && !model.HasReview && !model.CanApply && model.Status == "Selection changed" && fixture.Applies == 0,
        "Changing the queued action invalidates the prior review without applying either choice");
    await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; actionRow.ToggleOn = false;
    Check(actionRow.Selected.Id.Length == 0 && !model.HasReview && !model.Approved && !model.CanApply && model.Status == "Selection changed" && fixture.Applies == 0,
        "Switching a reviewed action off clears intent and approval without applying or restoring Windows");
    actionRow.ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; model.ClearSelectionCommand.Execute(null);
    Check(!model.HasReview && !model.Approved && !model.CanApply && model.Status == "Nothing selected" && fixture.Applies == 0,
        "Clear selection removes a prior review, approval and ready status without applying settings");
    actionRow.ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; model.ProfileId = "renamed-profile";
    Check(!model.HasReview && !model.Approved && !model.CanApply && model.Status == "Profile name changed" && fixture.Applies == 0,
        "Changing the profile name removes a prior review, approval and ready status without applying settings");
    actionRow.ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; model.SelectedPreset = model.Presets.Single();
    Check(actionRow.Selected.Id == "off" && !model.HasReview && !model.Approved && !model.CanApply && model.Status == "1 preset choice added" && fixture.Applies == 0,
        "Adding a preset replaces a prior review, approval and ready status without applying settings");

    fixture.Choices.Save(fixture.Catalog, "my-settings", [new("setting", "off")], null); model = await Load(fixture);
    Check(model.Rows.Single().Action.Id == "off" && model.Rows.Single().ToggleOn && !model.CanApply && fixture.Applies == 0,
        "A saved Off choice reloads as the explicit pending action and still requires a new review");

    fixture = new Fixture(Path.Combine(root, "profile-review")) { Missing = false };
    fixture.Choices.Save(fixture.Catalog, "saved-off", [new("setting", "off")], null); model = await Load(fixture);
    model.Rows.Single().ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true;
    model.SelectedProfile = model.Profiles.Single(profile => profile.Id == "saved-off");
    Check(model.Rows.Single().Selected.Id == "off" && !model.HasReview && !model.Approved && !model.CanApply && model.Status == "Profile loaded" && fixture.Applies == 0,
        "Loading a profile replaces a prior review, approval and ready status without applying settings");

    fixture = new Fixture(Path.Combine(root, "pending-recovery")) { Missing = false };
    fixture.Choices.Save(fixture.Catalog, "my-settings", [new("setting", "on")], null);
    fixture.Choices.Save(fixture.Catalog, "alternate", [new("setting", "off")], fixture.Choices.Read().Revision);
    fixture.Recovery = Pending(fixture, "applying", false);
    model = await Load(fixture);
    Check(model.HasPendingRecovery && !model.CanEdit && model.CanRefresh && model.CanReviewRecovery && !model.CanReview
            && model.Status == "Windows settings recovery needs review",
        "An applying recovery is the page status and blocks new settings while refresh and recovery review stay available");
    var selectedBefore = model.Rows.Single().Selected.Id;
    model.ClearSelectionCommand.Execute(null);
    model.SelectedPreset = model.Presets.Single();
    model.SelectedProfile = model.Profiles.Single(profile => profile.Id == "alternate");
    await model.ReviewOwnershipAsync(@"C:\Fixture");
    Check(model.Rows.Single().Selected.Id == selectedBefore && model.ProfileId == "my-settings" && fixture.OwnershipPreviews == 0
            && model.Status == "Windows settings recovery needs review",
        "Clear, preset, profile, and ownership entry points cannot replace pending recovery state");
    var reads = fixture.RecoveryReads;
    await model.RefreshCommand.ExecuteAsync(null);
    Check(fixture.RecoveryReads == reads + 1 && model.Status == "Windows settings recovery needs review",
        "Refresh remains reachable and preserves the authoritative pending recovery status");
    model.ReviewRecoveryCommand.Execute(null);
    Check(model.HasReview && model.CanApproveReview && !model.CanEdit && model.Status == "Review recovery of the interrupted operation",
        "Explicit recovery review remains reachable while ordinary edits stay blocked");
    model.Approved = true;
    Check(model.CanApply, "A reviewed pending recovery can reach its explicit confirmed apply gate");

    fixture = new Fixture(Path.Combine(root, "pending-restart")) { Missing = false };
    fixture.Recovery = Pending(fixture, "awaiting-restart", true);
    model = await Load(fixture);
    Check(model.HasPendingRecovery && model.CheckingRestart && !model.CanEdit && model.CanRefresh && model.CanReviewRecovery
            && model.Status == "Restart required to finish Windows settings recovery",
        "Awaiting-restart recovery stays visible and keeps refresh and recovery review available");

    fixture = new Fixture(Path.Combine(root, "no-pending")) { Missing = false };
    model = await Load(fixture);
    Check(!model.HasPendingRecovery && model.CanEdit && model.CanRefresh && !model.CanReviewRecovery && model.Status == "1 settings",
        "A healthy no-pending state restores ordinary editing without exposing recovery review");
    if (args is [var repo]) await SectionChecks.Run(root, Path.GetFullPath(repo), Check);
    Console.WriteLine($"Completed {count} Windows settings UI checks.");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
