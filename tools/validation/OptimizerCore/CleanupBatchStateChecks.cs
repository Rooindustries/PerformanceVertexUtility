using RooIndustries.Optimizer;

static class CleanupBatchStateChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("cleanup-state");
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

            ApplicationCleanupJournal ApplicationState(string status, bool restoreStarted, string? fileStatus, bool recoveryExists)
            {
                var recoveryPath = Path.Combine(root, "application-" + status + "-recovery.json");
                if (recoveryExists) File.WriteAllText(recoveryPath, "{}");
                var preview = new ApplicationCleanupPreview
                {
                    SchemaVersion = 1,
                    Owner = new OperationOwner("fixture", "fixture"),
                    OperationId = Guid.NewGuid().ToString("N"),
                    Source = "fixture",
                    AppId = "fixture:application",
                    DisplayName = "Application Fixture",
                    ProviderIdentityHash = new string('A', 64),
                    InventoryHash = new string('B', 64),
                    Selection = [new LeftoverCandidate
                    {
                        ItemId = "fixture-item",
                        Kind = "file",
                        Target = Path.Combine(root, "fixture-item"),
                        Exists = true,
                        Evidence = [],
                        SharedOwners = [],
                        Protected = false,
                        UserData = false,
                    }],
                    Registry = null,
                    Files = new("application-preview", "application-hash", recoveryPath),
                };
                return new ApplicationCleanupJournal
                {
                    SchemaVersion = 1,
                    PreviewPath = "application-preview",
                    ReviewHash = "application-hash",
                    Preview = preview,
                    Status = status,
                    RestoreStarted = restoreStarted,
                    FileStatus = fileStatus,
                    Errors = [],
                    UpdatedAtUtc = DateTime.UtcNow,
                };
            }

            check(!ApplicationCleanup.HasRestorableOperation(ApplicationState("prepared", false, null, true)),
                "A prepared single-app cleanup is not recoverable even if an unrelated child path exists");
            check(!ApplicationCleanup.HasRestorableOperation(ApplicationState("applied", false, "applied", false)),
                "A single-app cleanup without its child recovery journal is not recoverable");
            check(ApplicationCleanup.HasRestorableOperation(ApplicationState("applied", false, "applied", true)),
                "An applied single-app cleanup with its child journal is recoverable");
            check(!ApplicationCleanup.HasRestorableOperation(ApplicationState("restored", true, "restored", true)),
                "An already restored single-app cleanup does not offer another restore");

            if (OperatingSystem.IsWindows())
            {
                VerifyPreparedRestoreRejection(check, root);
                VerifyApplicationRestoreState(check, root);
            }
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

        foreach (var contradiction in new[]
        {
            (Status: "restored", RestoreStarted: false, EntryStatus: "restored"),
            (Status: "applied", RestoreStarted: true, EntryStatus: "applied"),
        })
        {
            journal.Status = contradiction.Status;
            journal.RestoreStarted = contradiction.RestoreStarted;
            journal.Entries[0].Status = contradiction.EntryStatus;
            OperationFiles.Write(batchJournalPath, journal);
            before = File.ReadAllBytes(batchJournalPath);
            rejected = false;
            try { CleanupBatch.ReadJournal(batchJournalPath); }
            catch (InvalidDataException error) { rejected = error.Message.Contains("contradicts", StringComparison.OrdinalIgnoreCase); }
            check(rejected && before.SequenceEqual(File.ReadAllBytes(batchJournalPath)),
                "Contradictory batch restore phase is rejected without changing its journal: " + contradiction.Status);
        }
    }

    private static void VerifyApplicationRestoreState(Action<bool, string> check, string root)
    {
        var owner = OperationOwner.Current();
        var childJournalPath = Path.Combine(root, "single-child-journal.json");
        var previewPath = Path.Combine(root, "single-preview.json");
        var preview = new ApplicationCleanupPreview
        {
            SchemaVersion = 1,
            Owner = owner,
            OperationId = Guid.NewGuid().ToString("N"),
            Source = "fixture",
            AppId = "fixture:single-prepared",
            DisplayName = "Single Prepared Fixture",
            ProviderIdentityHash = new string('A', 64),
            InventoryHash = new string('B', 64),
            Selection = [new LeftoverCandidate
            {
                ItemId = "single-item",
                Kind = "file",
                Target = Path.Combine(root, "single-item"),
                Exists = true,
                Evidence = [],
                SharedOwners = [],
                Protected = false,
                UserData = false,
            }],
            Registry = null,
            Files = new("single-child-preview", "single-child-hash", childJournalPath),
        };
        OperationFiles.Write(previewPath, preview);
        var journalPath = Path.Combine(root, "single-journal.json");
        var journal = new ApplicationCleanupJournal
        {
            SchemaVersion = 1,
            PreviewPath = previewPath,
            ReviewHash = OperationFiles.HashFile(previewPath),
            Preview = preview,
            Status = "prepared",
            RestoreStarted = false,
            Errors = [],
            UpdatedAtUtc = DateTime.UtcNow,
        };
        OperationFiles.Write(journalPath, journal);
        var before = File.ReadAllBytes(journalPath);
        var dispatched = false;
        var engine = new ApplicationCleanup(() =>
        {
            dispatched = true;
            throw new InvalidOperationException("Single-app cleanup state check reached context dispatch.");
        });
        var rejected = false;
        try { engine.Restore(journalPath); }
        catch (InvalidDataException error) { rejected = error.Message.Contains("no attempted operation", StringComparison.OrdinalIgnoreCase); }
        check(rejected && !dispatched && before.SequenceEqual(File.ReadAllBytes(journalPath)),
            "Direct prepared single-app restore is rejected before state or context dispatch changes");

        foreach (var contradiction in new[]
        {
            (Status: "restored", RestoreStarted: false),
            (Status: "applied", RestoreStarted: true),
        })
        {
            journal.Status = contradiction.Status;
            journal.RestoreStarted = contradiction.RestoreStarted;
            journal.FileStatus = contradiction.Status;
            OperationFiles.Write(journalPath, journal);
            before = File.ReadAllBytes(journalPath);
            rejected = false;
            try { engine.Restore(journalPath); }
            catch (InvalidDataException error) { rejected = error.Message.Contains("contradicts", StringComparison.OrdinalIgnoreCase); }
            check(rejected && !dispatched && before.SequenceEqual(File.ReadAllBytes(journalPath)),
                "Contradictory single-app restore phase is rejected without changing its journal: " + contradiction.Status);
        }
    }
}
