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
TweakCatalog TwoSettingCatalog()
{
    TweakDefinition Setting(string id, string name, string valueName) => new(
        id,
        name,
        "Apps",
        "Fixture",
        10240,
        26200,
        ["*"],
        "none",
        [
            new("on", "On", [new(new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", valueName), 1)]),
            new("off", "Off", [new(new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", valueName), 0)]),
        ],
        [new("Fixture", "fixture", "isolated UI validation")]);
    return new(1, "two-setting-fixture", [Setting("first", "First setting", "First"), Setting("second", "Second setting", "Second")], []);
}
if (args is ["--retained-profiles"])
{
    try { await RetainedProfileChecks.Run(root, TwoSettingCatalog(), Check); Console.WriteLine($"Completed {count} retained profile UI checks."); }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    return;
}
if (args is ["--presentation", var presentationRepo])
{
    var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(Path.GetFullPath(presentationRepo), "backend/catalogs/windows-tweaks.json"));
    ActionChecks.Run(catalog, Check);
    IconChecks.Run(presentationRepo, catalog, Check);
    Console.WriteLine($"Completed {count} presentation checks.");
    return;
}
if (args is ["--policy-editions", var policyRepo])
{
    try
    {
        await RetainedRequirementChecks.Run(root, OperationFiles.Read<TweakCatalog>(Path.Combine(policyRepo, "backend/catalogs/windows-tweaks.json")), Check);
        await PolicyProfileChecks.Run(root, OperationFiles.Read<TweakCatalog>(Path.Combine(policyRepo, "backend/catalogs/windows-tweaks.json")), Check);
        Console.WriteLine($"Completed {count} policy profile UI checks.");
    }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    return;
}
if (args is ["--freshness"])
{
    try { await FreshnessChecks.Run(root, Check); Console.WriteLine($"Completed {count} Windows settings UI checks."); }
    finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    return;
}
try
{
    AppliedStateChecks.Run(Check);
    await RetainedProfileChecks.Run(root, TwoSettingCatalog(), Check);
    if (args is [var catalogRepo])
    {
        var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(Path.GetFullPath(catalogRepo), "backend/catalogs/windows-tweaks.json"));
        await RetainedRequirementChecks.Run(root, catalog, Check);
        ActionChecks.Run(catalog, Check);
        await PolicyProfileChecks.Run(root, catalog, Check);
        IconChecks.Run(catalogRepo, catalog, Check);
        if (catalog.Presets.SingleOrDefault(preset => preset.Id == WindowsTweaksViewModel.FpsPresetId) is { } fpsPreset)
        {
            var shipped = new Fixture(Path.Combine(root, "shipped-fps-preset"), catalog) { Missing = false };
            var shippedModel = await Load(shipped);
            Check(shippedModel.HasFpsPreset, "The shipped catalog's FPS preset shows the preset button");
            shippedModel.FilterPresets("FSOS-X Dash · Hyper-V"); var hyperV = shippedModel.Presets.Select(preset => preset.Id).ToArray();
            shippedModel.FilterPresets("Virtualization-Based Security"); var vbs = shippedModel.Presets.Select(preset => preset.Id).ToArray();
            Check(ControlPlanning.HiddenPresets.All(id => catalog.Presets.Any(preset => preset.Id == id)) && !hyperV.Concat(vbs).Any(ControlPlanning.HiddenPresets.Contains) && hyperV.Length > 0,
                "Presets that always refuse to apply are hidden from the preset list while the rest stay: " + string.Join(", ", hyperV.Concat(vbs)));
            shippedModel.FilterPresets("");
            shippedModel.SelectFpsPresetCommand.Execute(null);
            var queued = shippedModel.Rows.Where(row => row.Selected.Id.Length > 0).Select(row => (row.Id, row.Selected.Id)).OrderBy(item => item.Item1).ToArray();
            var expected = fpsPreset.Selections.Select(item => (item.SettingId, item.OptionId)).OrderBy(item => item.Item1).ToArray();
            Check(queued.SequenceEqual(expected) && shipped.Applies == 0, "The shipped FPS preset queues exactly its measured tweaks and applies nothing");
        }
    }
    var fixture = new Fixture(Path.Combine(root, "missing")); var model = await Load(fixture);
    Check(model.Rows.Count == 1 && model.Rows[0].HasToggle && model.Rows[0].Choices.Length == 3, "Missing products retain every choice and an interactive toggle");
    model.ShowAdvanced = false;
    Check(model.Rows.Count == 0, "Simple mode hides a setting that cannot apply on this PC");
    model.ShowAdvanced = true;
    Check(model.Rows.Count == 1, "Advanced options show settings that cannot apply on this PC");
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null);
    Check(model.ApplyLabel == "Save choices" && !model.CanApply && fixture.Previews == 0, "A missing-product review offers saved choices with explicit confirmation and no Windows preview");
    model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Profiles.Single().Selections.Single() == new TweakSelection("setting", "on") && fixture.Windows.ReadState() is null && fixture.Applies == 0,
        "Saving unavailable choices persists intent without creating a Windows backup or running an apply");
    Check(model.Rows[0].Selected.Id == "on" && model.Rows[0].ToggleOn, "Reloading the page retains the saved toggle choice");
    var savedOnlyPreviews = fixture.Previews;
    model.ClearSelectionCommand.Execute(null); await model.ReviewCommand.ExecuteAsync(null);
    Check(!model.CanReview && !model.HasReview && fixture.Previews == savedOnlyPreviews && fixture.Choices.Read().Profiles.Length == 1,
        "Clearing a saved-only profile cannot route ordinary review into preference removal");
    await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Profiles.Length == 0 && fixture.Applies == 0 && model.Status == "Saved choices removed", "Saved-only restore removes preferences without a Windows restore call");

    fixture = new Fixture(Path.Combine(root, "apply-failure")) { Missing = false, FailApply = true }; model = await Load(fixture);
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Profiles.Length == 1 && fixture.Windows.ReadState() is null && model.Status == "Choices saved; Windows changes were not confirmed" && !model.CanApply,
        "A failed Windows apply retains the requested choices and never reports them applied");
    fixture.FailApply = false; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Length == 1, "The reviewed ready choice reaches the real file-backed transaction");
    var appliedPreviews = fixture.Previews;
    model.ClearSelectionCommand.Execute(null); await model.ReviewCommand.ExecuteAsync(null);
    Check(!model.CanReview && !model.HasReview && fixture.Previews == appliedPreviews && fixture.Windows.ReadState()?.Profiles.Length == 1 && model.CanRestore,
        "Clearing an applied profile cannot route ordinary review into Windows restore");
    var saved = fixture.Choices.Read(); fixture.FailApply = true;
    await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Choices.Read().Revision == saved.Revision && fixture.Windows.ReadState()?.Profiles.Length == 1,
        "Failed Windows restoration preserves both the applied profile and saved choices");
    fixture.FailApply = false;
    fixture.AfterApply = () => fixture.Choices.Save(fixture.Catalog, "another-window", [new("setting", "on")], fixture.Choices.Read().Revision);
    await model.ReviewRestoreCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Length == 0 && fixture.Choices.Read().Profiles.Length == 2 && model.Status == "Windows settings restored; saved choices need attention",
        "A concurrent preference change remains intact after a completed Windows restore and is reported separately");

    fixture = new Fixture(Path.Combine(root, "changed-by-windows")) { Missing = false }; model = await Load(fixture);
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    var enabled = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Enabled");
    var windowsFile = Path.Combine(root, "changed-by-windows", "windows.json"); var changed = OperationFiles.Read<TweakFixture>(windowsFile);
    changed.Keys[fixture.Windows.Read(enabled).NativeKey.ToUpperInvariant()].Values["ENABLED"] = new("Enabled", 4, BitConverter.GetBytes(5u));
    OperationFiles.Write(windowsFile, changed); model = await Load(fixture);
    await model.ReviewRestoreCommand.ExecuteAsync(null);
    Check(model.Status == "Windows already changed these settings" && model.Detail.Contains("\n" + model.Rows.Single(row => row.Id == "setting").Name, StringComparison.Ordinal) && !model.Detail.Contains("\nsetting", StringComparison.Ordinal),
        "Undo names a setting Windows changed afterwards by its shown name and says it stays as it is");
    model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Length == 0 && BitConverter.ToUInt32(fixture.Windows.Read(enabled).Value!.Bytes) == 5, "Undo finishes and keeps the value Windows set");

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

    fixture = new Fixture(Path.Combine(root, "partial-status")) { Missing = false };
    App.Operations = fixture; model = new WindowsTweaksViewModel();
    var statusHold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); fixture.BeforeStatus = () => statusHold.Task;
    var partialLoad = model.RefreshCommand.ExecuteAsync(null);
    var fullStatus = fixture.Engine.Detect();
    var pendingStatus = fullStatus with { Settings = fullStatus.Settings.Select(item => item with { Supported = false, Error = TweakEngine.FeaturesPending }).ToArray() };
    fixture.RaisePartial(pendingStatus, DataGeneration.Current - 1);
    Check(model.Busy && model.Rows[0].Current != "Checking…" && !model.Status.EndsWith("checking Windows features", StringComparison.Ordinal),
        "A partial Windows status read before a change is never shown");
    fixture.RaisePartial(pendingStatus, DataGeneration.Current);
    var partialPreviews = fixture.Previews;
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(model.Busy && !model.CanReview && !model.CanApply && !model.HasReview && fixture.Previews == partialPreviews && fixture.Applies == 0 && model.Rows[0].Current == "Checking…" && model.Status.EndsWith("checking Windows features", StringComparison.Ordinal),
        "A partial Windows status shows rows as checking and cannot be reviewed or applied");
    statusHold.SetResult(); await partialLoad;
    var loadedStatus = model.Status; var loadedCurrent = model.Rows[0].Current;
    model.Rows[0].ToggleOn = true; await model.ReviewCommand.ExecuteAsync(null);
    Check(!model.Busy && loadedCurrent != "Checking…" && !loadedStatus.Contains("checking", StringComparison.OrdinalIgnoreCase) && fixture.Previews == partialPreviews + 1 && model.HasReview,
        "Review becomes available only after the full Windows status replaces the partial one");

    fixture = new Fixture(Path.Combine(root, "action-review")) { Missing = false }; model = await Load(fixture);
    var defaultPreviews = fixture.Previews; await model.ReviewCommand.ExecuteAsync(null);
    Check(!model.CanReview && !model.HasReview && fixture.Previews == defaultPreviews,
        "An empty default profile has no ordinary review or implicit restore path");
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

    fixture = new Fixture(Path.Combine(root, "no-fps-preset")) { Missing = false }; model = await Load(fixture);
    model.SelectFpsPresetCommand.Execute(null);
    Check(!model.HasFpsPreset && model.Rows.All(row => row.Selected.Id.Length == 0), "Without an FPS preset in the catalog the preset button is hidden and does nothing");
    var fpsCatalog = TwoSettingCatalog() with { Presets = [new(WindowsTweaksViewModel.FpsPresetId, "Game FPS preset", [new("first", "on"), new("second", "off")])] };
    fixture = new Fixture(Path.Combine(root, "fps-preset"), fpsCatalog) { Missing = false }; model = await Load(fixture);
    Check(model.HasFpsPreset && model.Rows.All(row => row.Selected.Id.Length == 0) && fixture.Applies == 0, "A catalog with an FPS preset offers the preset button without selecting anything");
    model.SelectFpsPresetCommand.Execute(null);
    Check(model.Rows.Single(row => row.Id == "first").Selected.Id == "on" && model.Rows.Single(row => row.Id == "second").Selected.Id == "off" && !model.HasReview && !model.CanApply && fixture.Applies == 0 && fixture.Previews == 0,
        "The FPS preset queues its tweaks for review and applies nothing on its own");
    await model.ReviewCommand.ExecuteAsync(null);
    Check(model.HasReview && !model.CanApply && fixture.Applies == 0, "The preset still needs the normal check and confirmation before anything is applied");

    fixture = new Fixture(Path.Combine(root, "partial-profile"), TwoSettingCatalog()) { Missing = false };
    model = await Load(fixture);
    foreach (var row in model.Rows) row.Selected = row.Choices.Single(choice => choice.Id == "on");
    await model.ReviewCommand.ExecuteAsync(null); model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Single().Selections.Length == 2,
        "The two-setting fixture begins with both applied claims");
    var first = model.Rows.Single(row => row.Id == "first");
    var second = model.Rows.Single(row => row.Id == "second");
    first.Selected = first.Choices.Single(choice => choice.Id == "off");
    second.Selected = second.Choices[0];
    Check(second.ToggleOn && second.IsApplied && !second.HasPendingChange, "An applied setting with no queued choice still shows on");
    await model.ReviewCommand.ExecuteAsync(null);
    Check(fixture.LastPreviewSelections?.OrderBy(selection => selection.SettingId).SequenceEqual(new[]
        {
            new TweakSelection("first", "off"),
            new TweakSelection("second", "on"),
        }) == true,
        "Partial profile review keeps an existing applied claim behind Keep current");
    model.Approved = true; await model.ApplyCommand.ExecuteAsync(null);
    Check(fixture.Windows.ReadState()?.Profiles.Single().Selections.OrderBy(selection => selection.SettingId).SequenceEqual(new[]
        {
            new TweakSelection("first", "off"),
            new TweakSelection("second", "on"),
        }) == true && fixture.Choices.Read().Profiles.Single().Selections.SequenceEqual(new[] { new TweakSelection("first", "off") }),
        "Applying a partial edit preserves the Windows claim while saved choices keep only explicit intent");

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
    await HostOutputChecks.Run(Check);
    await FreshnessChecks.Run(root, Check);
    if (args is [var repo])
    {
        await SectionChecks.Run(root, Path.GetFullPath(repo), Check);
        await ReviewLabelChecks.Run(root, Path.GetFullPath(repo), Check);
    }
    Console.WriteLine($"Completed {count} Windows settings UI checks.");
}
finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
