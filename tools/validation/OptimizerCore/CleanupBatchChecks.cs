using Microsoft.Win32;
using Roo.Optimizer;

static class CleanupBatchChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-cleanup-batch-" + Guid.NewGuid().ToString("N"));
        var registryRoot = "Software\\RooCleanupBatchTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        var contexts = new Dictionary<string, CleanupContext>();
        var plans = new List<ApplicationCleanupPreview>();
        var parts = new List<CleanupPart>();
        var batchPath = Path.Combine(root, "operations", "batch-review.json");
        var journalPath = Path.Combine(root, "operations", "batch-journal.json");
        ApplicationCleanup App(string source, string appId) => new(() => contexts[appId], [root], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
        try
        {
            foreach (var name in new[] { "Roo Batch One", "Roo Batch Two" })
            {
                var source = Path.Combine(root, name);
                Directory.CreateDirectory(source);
                File.WriteAllText(Path.Combine(source, "data.txt"), name + " file");
                using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
                var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo", InstallLocation = source, PackageFamilyName = null };
                var authority = new CleanupAuthority
                {
                    AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(System.Text.Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                    ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
                };
                var context = new CleanupContext(Path.Combine(root, name + "-queue.json"), authority, app, [], true);
                contexts.Add(app.AppId, context);
                var engine = App(context.Source, app.AppId);
                var scan = engine.Scan(CancellationToken.None);
                var path = Path.Combine(root, "operations", name, "review.json");
                var plan = engine.Preview(path, scan.Candidates.Select(item => item.ItemId).ToArray(), true, true);
                plans.Add(plan);
                parts.Add(new(path, OperationFiles.HashFile(path), Path.Combine(Path.GetDirectoryName(path)!, "journal.json")));
            }
            var preview = CleanupBatch.Preview(batchPath, parts.ToArray());
            var hash = OperationFiles.HashFile(batchPath);
            var cancelFirst = true;
            var engineBatch = new CleanupBatch((source, appId) =>
            {
                if (cancelFirst) { cancelFirst = false; CleanupBatch.Cancel(journalPath); }
                return App(source, appId);
            });
            var stopped = engineBatch.Apply(batchPath, hash, journalPath);
            check(stopped.Status == "stopped" && stopped.Entries[0].Status == "applied" && stopped.Entries[1].Status == "pending" &&
                !Directory.Exists(Path.Combine(root, "Roo Batch One")) && Directory.Exists(Path.Combine(root, "Roo Batch Two")), "Batch cancellation finishes the current app and preserves the unstarted app's leftovers");
            var newer = CleanupBatch.Cancel(journalPath);
            var staleResume = engineBatch.Apply(batchPath, hash, journalPath, stopped.CancellationId);
            check(staleResume.Status == "stopped" && staleResume.CancellationId == newer.CancellationId && Directory.Exists(Path.Combine(root, "Roo Batch Two")), "An old resume token cannot clear a newer cancellation request");
            var second = contexts[plans[1].AppId];
            contexts[plans[1].AppId] = second with { Authority = second.Authority with { RemoverRunning = true } };
            var blocked = engineBatch.Apply(batchPath, hash, journalPath, newer.CancellationId);
            check(blocked.Status == "needsReconciliation" && blocked.Entries[0].Status == "applied" && blocked.Entries[1].Status == "needsReconciliation" && Directory.Exists(second.Application.InstallLocation), "Resuming a batch rechecks each app's independent remover lifetime before dispatch");
            contexts[plans[1].AppId] = second;
            engineBatch = new CleanupBatch(App);
            var applied = engineBatch.Apply(batchPath, hash, journalPath);
            if (applied.Status != "applied") Console.WriteLine(string.Join("\n", applied.Entries.Select(entry => entry.Error)));
            check(applied.Status == "applied" && contexts.Values.All(context => !Directory.Exists(context.Application.InstallLocation)), "A recreated batch coordinator resumes reviewed cleanup without losing completed app state");
            foreach (var context in contexts.Values)
            {
                using var key = hive.OpenSubKey(registryRoot + "\\" + context.Application.DisplayName);
                check(key is null, "Completed batch cleanup removed the selected app's registry data: " + context.Application.DisplayName);
            }
            var restored = engineBatch.Restore(journalPath);
            check(restored.Status == "restored", "Batch recovery restores both application operations");
            foreach (var context in contexts.Values)
            {
                using var key = hive.OpenSubKey(registryRoot + "\\" + context.Application.DisplayName);
                check(key?.GetValue("Original") as string == context.Application.DisplayName + " registry" &&
                    File.ReadAllText(Path.Combine(context.Application.InstallLocation!, "data.txt")) == context.Application.DisplayName + " file", "Independent original file and registry values survive batch recovery: " + context.Application.DisplayName);
            }
            check(engineBatch.Apply(batchPath, hash, journalPath).Status == "restored", "Restoration permanently ends the batch's deletion phase");
        }
        finally
        {
            foreach (var plan in plans)
                if (plan.Registry is { } part) hive.DeleteSubKeyTree(OperationFiles.Read<RegistryCleanupPreview>(part.PreviewPath).Receipt.KeyPath, false);
            hive.DeleteSubKeyTree(registryRoot, false);
            using (var parent = hive.OpenSubKey("Software\\RooCleanupBatchTests"))
                if (parent is not null && parent.SubKeyCount == 0 && parent.ValueCount == 0) hive.DeleteSubKey("Software\\RooCleanupBatchTests", false);
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Batch validation removes its cancellation markers, receipts and data fixtures");
    }
}
