using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.ViewModels;

static class BulkRemovalChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        App.Live.InstalledApps = new InstalledAppInventory
        {
            Apps = [new() { AppId = "registry:editor", DisplayName = "Roo Industries Fixture Editor", SourceType = "registry" }, new() { AppId = "registry:player", DisplayName = "Roo Industries Fixture Player", SourceType = "registry" }],
            Complete = true,
        };
        App.Live.LastError = null;
        BulkRemovalJournal Journal(string status, params (string AppId, string State, bool Absent)[] entries) => new()
        {
            Status = status,
            Plan = new() { QueueId = "queue-" + status, Entries = entries.Select(entry => new BulkRemovalEntry { EntryId = entry.AppId, AppId = entry.AppId, DisplayName = entry.AppId == "registry:editor" ? "Roo Industries Fixture Editor" : "Roo Industries Fixture Player" }).ToList() },
            Entries = entries.Select(entry => new BulkRemovalEntryState { AppId = entry.AppId, State = entry.State, RegistrationAbsent = entry.Absent }).ToList(),
        };
        BulkRemovalSession Session(BulkRemovalJournal journal) => new(new(journal.Plan, "preview.json", "hash", journal.Status + "-journal.json"), journal);
        async Task<BulkRemovalViewModel> Start()
        {
            var model = new BulkRemovalViewModel();
            await model.InitializeAsync();
            return model;
        }
        var failed = Journal("needs-reconciliation", ("registry:editor", "needs-reconciliation", false), ("registry:player", "pending", false));
        App.Operations.LastRemoval = Session(failed); App.Operations.RemovalHistory = [(failed.Status + "-journal.json", failed)];
        App.Operations.ReconcileRemoval = _ => Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = failed.Status, Data = failed });
        var model = await Start();
        check(!model.CanSelect && model.CanReconcile && model.CanStartOver && model.Status == "Removal needs checking.", "A failed removal list reloaded at startup offers Start over next to Check state");
        await model.ReconcileCommand.ExecuteAsync(null);
        check(!model.CanSelect && model.CanStartOver, "When checking state cannot resolve a failed removal, Start over still gives a way out");
        model = await Start();
        check(model.CanStartOver && App.Operations.Dismissed.Count == 0, "Reopening the app never clears a failed list without the user choosing Start over");

        App.Operations.DismissRemoval = _ => throw new InvalidOperationException("This removal is still running. Let it finish, then start over.");
        await model.StartOverCommand.ExecuteAsync(null);
        check(!model.CanSelect && model.CanStartOver && model.ReviewRows.Count == 2 && model.Status == "Couldn't clear this list yet." && model.Detail.Contains("still running", StringComparison.Ordinal),
            "A list that is genuinely still running stays in place and explains why");

        var release = new TaskCompletionSource<OptimizerResult<BulkRemovalJournal>>();
        App.Operations.DismissRemoval = _ => release.Task;
        var pending = model.StartOverCommand.ExecuteAsync(null);
        check(model.Busy && !model.CanStartOver && !model.CanSelect, "Start over cannot be pressed again while it is working");
        await model.StartOverCommand.ExecuteAsync(null);
        check(App.Operations.Dismissed.Count == 2, "A second press during Start over sends nothing");
        App.Operations.LastRemoval = null;
        release.SetResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = failed });
        await pending;
        check(model.CanSelect && !model.CanStartOver && !model.CanReconcile && model.ReviewRows.Count == 0 && model.Apps.Count == 2 && model.ApplyLabel == "Remove selected apps" && model.Status == "Pick the apps to remove.",
            "Start over unlocks the app list, clears the failed list and shows every installed app again");
        model.SetSelection([model.Apps[0]]);
        check(model.CanPreview && model.SelectionSummary == "1 selected", "After starting over, the failed app can be picked again to retry");
        model = await Start();
        check(model.CanSelect && !model.CanStartOver && model.ReviewRows.Count == 0, "A cleared list does not come back after reopening the app");

        var partial = Journal("needs-reconciliation", ("registry:editor", "removed", true), ("registry:player", "needs-reconciliation", false));
        App.Operations.LastRemoval = Session(partial); App.Operations.RemovalHistory = [(partial.Status + "-journal.json", partial)];
        App.Operations.DismissRemoval = _ => { App.Operations.LastRemoval = null; return Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = partial }); };
        model = await Start();
        await model.StartOverCommand.ExecuteAsync(null);
        check(model.CanSelect && model.HasRemovedApps && model.RemovedApps.Single().Id == "registry:editor", "Starting over a partly finished list keeps the finished app ready for leftover review");
        check(!model.Detail.Contains("can't tell", StringComparison.Ordinal), "Starting over a list with no interrupted launch shows no launch warning");

        var interrupted = Journal("running", ("registry:editor", "dispatching", false), ("registry:player", "pending", false));
        App.Operations.LastRemoval = Session(interrupted); App.Operations.RemovalHistory = [(interrupted.Status + "-journal.json", interrupted)];
        App.Operations.DismissRemoval = _ => { App.Operations.LastRemoval = null; return Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = interrupted }); };
        model = await Start();
        await model.StartOverCommand.ExecuteAsync(null);
        check(model.CanSelect && model.Detail.Contains("can't tell whether it ran", StringComparison.Ordinal), "Starting over a list interrupted while a remover was starting warns that the launch could not be verified");

        var rechecked = Journal("needs-reconciliation", ("registry:editor", "needs-reconciliation", false), ("registry:player", "pending", false));
        rechecked.Entries[0].LaunchUnconfirmed = true;
        App.Operations.LastRemoval = Session(rechecked); App.Operations.RemovalHistory = [(rechecked.Status + "-journal.json", rechecked)];
        App.Operations.DismissRemoval = _ => { App.Operations.LastRemoval = null; return Task.FromResult(new OptimizerResult<BulkRemovalJournal> { Status = "dismissed", Data = rechecked }); };
        model = await Start();
        await model.StartOverCommand.ExecuteAsync(null);
        check(model.CanSelect && model.Detail.Contains("can't tell whether it ran", StringComparison.Ordinal), "The unconfirmed-launch warning survives Check state before Start over");

        foreach (var status in new[] { "running", "canceled", "ready", "reboot-required" })
        {
            App.Operations.LastRemoval = Session(Journal(status, ("registry:editor", status == "running" ? "running" : "pending", false)));
            model = await Start();
            check(!model.CanSelect && model.CanStartOver, "A saved " + status + " list offers Start over and lets the backend decide whether it is safe");
        }
        App.Operations.LastRemoval = Session(Journal("cleanup-review-required", ("registry:editor", "removed", true)));
        model = await Start();
        check(model.CanSelect && !model.CanStartOver, "A finished list keeps the app list usable without an extra Start over step");
        App.Operations.LastRemoval = null; App.Operations.RemovalHistory = [];
    }
}
