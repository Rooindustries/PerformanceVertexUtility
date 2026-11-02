using System.Text;
using RooIndustries.Optimizer;

static class FileChecks
{
    public static void Run(Action<bool, string> check, TestVolume volume)
    {
        var root = TestFixtures.InheritingRoot("file-core");
        var far = TestFixtures.InheritingFolder(Path.Combine(volume.Root, "roo-industries-file-core-" + Guid.NewGuid().ToString("N")));
        var source = Path.Combine(root, "Application files");
        var operations = Path.Combine(root, "Operations");
        Directory.CreateDirectory(Path.Combine(source, "Settings"));
        Directory.CreateDirectory(operations);
        var text = Path.Combine(source, "read only.txt");
        var settings = Path.Combine(source, "Settings", "data.bin");
        var sentinel = Path.Combine(root, "sentinel.txt");
        File.WriteAllText(text, "original λ settings", new UTF8Encoding(false));
        File.WriteAllBytes(text + ":extra", [1, 2, 0, 4, 255]);
        File.WriteAllBytes(settings, [4, 3, 2, 1, 0]);
        File.WriteAllText(sentinel, "unrelated");
        File.SetAttributes(text, FileAttributes.ReadOnly);
        var originalText = File.ReadAllBytes(text);
        var originalSettings = File.ReadAllBytes(settings);
        var originalStreams = File.ReadAllBytes(text + ":extra");
        var identityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("independent file fixture"));
        var authority = new CleanupAuthority
        {
            AppId = "fixture:files", ProviderIdentityHash = identityHash, Owner = OperationOwner.Current(),
            RegistrationPresent = false, ProviderQueryComplete = true, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
        };
        try
        {
            var engine = new FileCleanupEngine(() => authority);
            var preview = engine.Preview(authority.AppId, identityHash, [source], true);
            check(preview.Files.Length == 4 && preview.Files.Single(file => file.Path == text).Streams.Length == 2, "Handle-based preview captures the exact directory tree and alternate stream");
            var reviewPath = Path.Combine(operations, "review.json");
            var journalPath = Path.Combine(operations, "journal.json");
            OperationFiles.Write(reviewPath, preview);
            var applied = engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), journalPath);
            if (applied.Status != "applied") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(applied, OperationFiles.Json));
            check(applied.Status == "applied" && !Directory.Exists(source) && File.ReadAllText(sentinel) == "unrelated", "Verified backups precede deletion of exactly the reviewed file objects");
            var restored = engine.Restore(journalPath);
            if (restored.Status != "restored") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(restored, OperationFiles.Json));
            check(restored.Status == "restored" && File.ReadAllBytes(text).SequenceEqual(originalText) && File.ReadAllBytes(text + ":extra").SequenceEqual(originalStreams) && File.ReadAllBytes(settings).SequenceEqual(originalSettings), "File restoration returns main data and alternate-stream bytes independently");
            check((File.GetAttributes(text) & FileAttributes.ReadOnly) != 0 && File.ReadAllText(sentinel) == "unrelated", "Read-only metadata and unrelated sibling data survive file recovery");
            File.SetAttributes(text, FileAttributes.Normal);
            File.WriteAllText(text, "new user data");
            var repeated = engine.Restore(journalPath);
            check(File.ReadAllText(text) == "new user data" && repeated.Entries.Single(entry => entry.Original.Path == text).LeftAsChanged is not null &&
                repeated.Entries.Where(entry => entry.Original.Path != text).All(entry => entry.LeftAsChanged is null && entry.Error is null),
                "Repeated file restore preserves newer destination data and says it left that file as is");

            foreach (var (drive, parent) in new[] { ("same drive", root), ("other drive", far) })
            {
                var partialRoot = Path.Combine(parent, "Partial recovery");
                Directory.CreateDirectory(partialRoot);
                File.WriteAllText(Path.Combine(partialRoot, "first.txt"), "first original");
                File.WriteAllText(Path.Combine(partialRoot, "second.txt"), "second original");
                var partialPreview = engine.Preview(authority.AppId, identityHash, [partialRoot], true);
                var partialPath = Path.Combine(operations, drive + " partial-preview.json");
                var partialJournal = Path.Combine(operations, drive + " partial-journal.json");
                OperationFiles.Write(partialPath, partialPreview);
                var partial = engine.Apply(partialPath, OperationFiles.HashFile(partialPath), partialJournal);
                if (partial.Status != "applied") Console.WriteLine(drive + " partial apply: " + partial.Status + " " + string.Join(" | ", partial.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Original.Path + ": " + entry.Error)));
                check(partial.Status == "applied", drive + ": partial-recovery fixture starts from a verified deletion with complete undo copies");
                var broken = partial.Entries.Single(entry => entry.Original.Path.EndsWith("second.txt"));
                var saved = File.ReadAllBytes(broken.BackupPath);
                File.WriteAllBytes(broken.BackupPath, [1, 2, 3]);
                var interrupted = engine.Restore(partialJournal);
                check(interrupted.Status == "needsReconciliation" && File.ReadAllText(Path.Combine(partialRoot, "first.txt")) == "first original" && !File.Exists(Path.Combine(partialRoot, "second.txt")),
                    drive + ": a corrupt later undo copy preserves completed restoration and reports the incomplete directory");
                File.WriteAllBytes(broken.BackupPath, saved);
                File.SetLastWriteTimeUtc(broken.BackupPath, DateTime.FromFileTimeUtc(broken.Original.LastWriteTime));
                var resumed = engine.Restore(partialJournal);
                if (resumed.Status != "restored") Console.WriteLine(string.Join("\n", resumed.Entries.Select(entry => entry.Error)));
                check(resumed.Status == "restored" && File.ReadAllText(Path.Combine(partialRoot, "second.txt")) == "second original" && resumed.Entries.Single(entry => entry.Original.Directory).DirectoryMetadataRestored,
                    drive + ": retry uses the recorded directory identity and finalizes metadata after all child data is restored");
            }

            var checkpointRoot = Path.Combine(far, "Creation checkpoint");
            Directory.CreateDirectory(checkpointRoot);
            File.WriteAllText(Path.Combine(checkpointRoot, "data.txt"), "checkpoint data");
            var checkpointPreview = engine.Preview(authority.AppId, identityHash, [checkpointRoot], true);
            var checkpointPath = Path.Combine(operations, "checkpoint-preview.json");
            var checkpointJournal = Path.Combine(operations, "checkpoint-journal.json");
            OperationFiles.Write(checkpointPath, checkpointPreview);
            var checkpoint = engine.Apply(checkpointPath, OperationFiles.HashFile(checkpointPath), checkpointJournal);
            check(checkpoint.Status == "applied", "Creation-checkpoint fixture has a complete verified backup");
            var directoryEntry = checkpoint.Entries.Single(entry => entry.Original.Directory);
            directoryEntry.Status = "restoreIntent";
            OperationFiles.Write(checkpointJournal, checkpoint);
            using (var created = FileLease.Create(checkpointRoot, true)) created.RestoreData(directoryEntry.BackupPath, directoryEntry.Original);
            check(directoryEntry.RestoredIdentity is null, "The interrupted checkpoint preserves missing directory identity evidence");
            var checkpointResult = engine.Restore(checkpointJournal);
            using (var recovered = FileLease.Open(checkpointRoot))
                check(checkpointResult.Status == "restored" && directoryEntry.Original.SameRestorableData(recovered.Capture()) && File.ReadAllText(Path.Combine(checkpointRoot, "data.txt")) == "checkpoint data",
                    "Recovery after directory creation verifies existing backup-equivalent data before completing children and metadata");
        }
        finally
        {
            foreach (var folder in new[] { root, far }.Where(Directory.Exists))
            {
                foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
                Directory.Delete(folder, true);
            }
        }
        check(!Directory.Exists(root) && !Directory.Exists(far), "File validation removes its reviewed, backup and mirror fixtures");
    }
}
