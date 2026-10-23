using System.Diagnostics;
using System.Reflection;
using RooIndustries.OptimizationSuite;
using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

static class ProcessUndoChecks
{
    public static async Task RunAsync(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-process-undo-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var probe = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "PING.EXE"), "-n 400 127.0.0.1") { UseShellExecute = false, CreateNoWindow = true })
            ?? throw new InvalidOperationException("The fixture did not start.");
        try
        {
            var engine = new ProcessControlEngine(identity => identity.ProcessId != probe.Id);
            using (var target = new ProcessTarget(probe.Id)) App.Operations.ProcessSnapshot = target.Snapshot();
            App.Operations.Review = desired =>
            {
                var directory = Path.Combine(root, Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(directory);
                var preview = Path.Combine(directory, "preview.json");
                var plan = engine.Preview(probe.Id, desired);
                OperationFiles.Write(preview, plan);
                return new(plan, preview, OperationFiles.HashFile(preview), Path.Combine(directory, "journal.json"));
            };
            App.Operations.Applies = review => engine.Apply(review.PreviewPath, review.Hash, review.JournalPath);
            App.Operations.Restores = journal => engine.Restore(journal);
            var page = new ProcessControlsViewModel();
            async Task Review(string priority)
            {
                var control = page.Controls.Single(row => row.Name == "cpuPriority");
                control.Selected = control.Options.Single(option => option.Value?.GetString() == priority);
                await page.PreviewCommand.ExecuteAsync(null);
            }
            page.SelectedProcess = new CpuProcessChoice(probe.Id, "Undo fixture");
            await (Task)typeof(ProcessControlsViewModel).GetField("_readTask", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(page)!;
            await Review("BelowNormal");
            await page.ApplyCommand.ExecuteAsync(null);
            probe.Refresh();
            check(probe.PriorityClass == ProcessPriorityClass.BelowNormal && page.CanRestore && !page.CanEdit,
                "Apply once lowers the fixture's CPU priority and the Processes page waits for Undo" + " | got: " + probe.PriorityClass + " | " + page.Status);
            probe.PriorityClass = ProcessPriorityClass.Idle;
            await page.RestoreCommand.ExecuteAsync(null);
            probe.Refresh();
            check(probe.PriorityClass == ProcessPriorityClass.Idle && !page.CanRestore && page.CanEdit && App.Operations.ProcessPointer is null
                    && page.Status == ProcessControlEngine.LeftAsSet && page.Detail == "CPU priority: left as another program set it",
                "Undo after another program changed the CPU priority keeps its value, says which setting it left and unlocks the page" + " | got: " + page.Status + " | " + page.Detail);
            await Review("AboveNormal");
            check(page.CanApply, "A new Apply once review can be applied after that Undo");
        }
        finally
        {
            App.Operations.Review = null; App.Operations.Applies = null; App.Operations.Restores = null; App.Operations.ProcessSnapshot = null; App.Operations.ProcessPointer = null;
            if (!probe.HasExited) { probe.Kill(); probe.WaitForExit(); }
            Directory.Delete(root, true);
        }
    }
}
