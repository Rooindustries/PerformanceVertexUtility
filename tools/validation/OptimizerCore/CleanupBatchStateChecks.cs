using RooIndustries.Optimizer;

static class CleanupBatchStateChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-cleanup-state-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            CleanupBatchJournal State(string status, params (string EntryStatus, bool RecoveryExists)[] entries)
            {
                var parts = new List<CleanupBatchPart>();
                var stateEntries = new List<CleanupBatchEntry>();
                for (var index = 0; index < entries.Length; index++)
                {
                    var operationId = "operation-" + index;
                    var recoveryPath = Path.Combine(root, status + "-recovery-" + index + ".json");
                    if (entries[index].RecoveryExists) File.WriteAllText(recoveryPath, "{}");
                    var preview = new ApplicationCleanupPreview
                    {
                        SchemaVersion = 1,
                        Owner = new OperationOwner("fixture", "fixture"),
                        OperationId = operationId,
                        Source = "fixture",
                        AppId = "fixture:" + index,
                        DisplayName = "Fixture " + index,
                        ProviderIdentityHash = "provider",
                        InventoryHash = "inventory",
                        Selection = [],
                        Registry = null,
                        Files = null,
                    };
                    parts.Add(new(preview, new CleanupPart("preview-" + index, "hash-" + index, recoveryPath)));
                    stateEntries.Add(new CleanupBatchEntry { OperationId = operationId, Status = entries[index].EntryStatus });
                }
                return new CleanupBatchJournal
                {
                    SchemaVersion = 1,
                    PreviewPath = "batch-preview",
                    ReviewHash = "batch-hash",
                    Preview = new CleanupBatchPreview
                    {
                        SchemaVersion = 1,
                        BatchId = Guid.NewGuid().ToString("N"),
                        Owner = new OperationOwner("fixture", "fixture"),
                        Parts = parts.ToArray(),
                    },
                    RestoreStarted = status is "restoring" or "restored" or "partiallyRestored",
                    Status = status,
                    Entries = stateEntries,
                    UpdatedAtUtc = DateTime.UtcNow,
                };
            }

            check(!CleanupBatch.HasRestorableEntries(State("prepared", ("pending", true))),
                "A prepared all-pending cleanup is not recoverable even if an unrelated journal path exists");
            check(!CleanupBatch.HasRestorableEntries(State("applied", ("applied", false))),
                "An attempted cleanup without its application recovery journal is not recoverable");
            check(CleanupBatch.HasRestorableEntries(State("applied", ("applied", true))),
                "An applied cleanup with its application recovery journal is recoverable");
            check(CleanupBatch.HasRestorableEntries(State("stopped", ("applied", true), ("pending", false))),
                "A stopped batch can restore the attempted application without treating the pending app as changed");
            check(CleanupBatch.HasRestorableEntries(State("needsReconciliation", ("needsReconciliation", true))),
                "A failed attempted cleanup retains recovery when its journal exists");
            check(CleanupBatch.HasRestorableEntries(State("partiallyRestored", ("restored", true), ("applied", true))),
                "A partially restored batch remains recoverable while an applied entry remains");
            check(!CleanupBatch.HasRestorableEntries(State("restored", ("restored", true))),
                "An already restored batch does not offer another restore");

            if (OperatingSystem.IsWindows()) VerifyPreparedRestoreRejection(check, root);
            else Console.WriteLine("WINDOWS-PENDING Prepared restore mutation guard requires native Windows ownership verification.");
        }
        finally
        {
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Cleanup batch state checks remove their file fixtures");
    }

    private static void VerifyPreparedRestoreRejection(Action<bool, string> check, string root)
    {
        var owner = OperationOwner.Current();
        var operationId = Guid.NewGuid().ToString("N");
        var appPreviewPath = Path.Combine(root, "native-app-preview.json");
        var appPreview = new ApplicationCleanupPreview
        {
            SchemaVersion = 1,
            Owner = owner,
            OperationId = operationId,
            Source = "fixture",
            AppId = "fixture:prepared",
            DisplayName = "Prepared Fixture",
            ProviderIdentityHash = "provider",
            InventoryHash = "inventory",
            Selection = [],
            Registry = null,
            Files = null,
        };
        OperationFiles.Write(appPreviewPath, appPreview);
        var applicationJournalPath = Path.Combine(root, "native-app-journal.json");
        var batchPreviewPath = Path.Combine(root, "native-batch-preview.json");
        var batchPreview = new CleanupBatchPreview
        {
            SchemaVersion = 1,
            BatchId = Guid.NewGuid().ToString("N"),
            Owner = owner,
            Parts = [new(appPreview, new(appPreviewPath, OperationFiles.HashFile(appPreviewPath), applicationJournalPath))],
        };
        OperationFiles.Write(batchPreviewPath, batchPreview);
        var batchJournalPath = Path.Combine(root, "native-batch-journal.json");
        var journal = new CleanupBatchJournal
        {
            SchemaVersion = 1,
            PreviewPath = batchPreviewPath,
            ReviewHash = OperationFiles.HashFile(batchPreviewPath),
            Preview = batchPreview,
            RestoreStarted = false,
            Status = "prepared",
            Entries = [new() { OperationId = operationId, Status = "pending" }],
            UpdatedAtUtc = DateTime.UtcNow,
        };
        OperationFiles.Write(batchJournalPath, journal);
        var before = File.ReadAllBytes(batchJournalPath);
        var dispatched = false;
        var rejected = false;
        var engine = new CleanupBatch((_, _) => { dispatched = true; throw new InvalidOperationException("Cleanup batch state check dispatched application cleanup."); });
        try
        {
            engine.Restore(batchJournalPath);
        }
        catch (InvalidDataException error)
        {
            rejected = error.Message.Contains("no attempted cleanup", StringComparison.OrdinalIgnoreCase);
        }
        var after = CleanupBatch.ReadJournal(batchJournalPath);
        check(rejected && !dispatched && !after.RestoreStarted && after.Status == "prepared" && before.SequenceEqual(File.ReadAllBytes(batchJournalPath)),
            "A prepared all-pending batch is rejected before restore state or application dispatch changes");

        journal.RestoreStarted = true;
        journal.Status = "restored";
        journal.Entries[0].Status = "restored";
        OperationFiles.Write(batchJournalPath, journal);
        before = File.ReadAllBytes(batchJournalPath);
        dispatched = false;
        var repeated = engine.Restore(batchJournalPath);
        check(!dispatched && repeated.Status == "restored" && before.SequenceEqual(File.ReadAllBytes(batchJournalPath)),
            "An already restored batch remains an unchanged idempotent backend result");
    }
}
