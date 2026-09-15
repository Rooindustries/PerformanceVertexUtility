#nullable enable
using System.ComponentModel;
using System.Text.Json;

namespace Roo.Optimizer;

public sealed class FileCleanupEngine(Func<CleanupAuthority> currentAuthority)
{
    public FileCleanupPreview Preview(string appId, string providerIdentityHash, string[] roots, bool ownershipReviewed)
    {
        currentAuthority().Verify(appId, providerIdentityHash);
        if (!ownershipReviewed) throw new InvalidDataException("File ownership must be reviewed before creating a cleanup plan.");
        roots = roots.Select(FileLease.NormalizePath).ToArray();
        ValidateRoots(roots);
        var files = CaptureTree(roots);
        return new()
        {
            SchemaVersion = 1, OperationId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(),
            AppId = appId, ProviderIdentityHash = providerIdentityHash, Roots = roots, Files = files,
        };
    }

    public FileCleanupJournal Apply(string previewPath, string reviewHash, string journalPath)
    {
        var preview = OperationFiles.Read<FileCleanupPreview>(previewPath, reviewHash);
        ValidatePreview(preview);
        currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
        var directory = Path.GetDirectoryName(Path.GetFullPath(journalPath))!;
        if (preview.Roots.Any(root => Within(directory, root)) || string.Equals(Path.GetFullPath(previewPath), Path.GetFullPath(journalPath), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Recovery files and the journal must stay outside deletion targets and reviewed inputs.");
        using var lease = OperationFiles.Lock(journalPath);
        if (File.Exists(journalPath)) return ReconcileApplied(journalPath, ReadJournal(journalPath, reviewHash));
        var journal = new FileCleanupJournal
        {
            SchemaVersion = 1, Preview = preview, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash,
            Status = "preparing", UpdatedAtUtc = DateTime.UtcNow,
            Entries = preview.Files.Select(file => new FileBackupEntry
            {
                Original = file, BackupPath = Path.Combine(directory, "file-backup-" + Guid.NewGuid().ToString("N")), Status = "pending",
            }).ToList(),
        };
        var held = new Dictionary<string, FileLease>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var file in preview.Files)
            {
                var source = FileLease.Open(file.Path, writable: !file.Directory);
                held.Add(file.Path, source);
                if (!file.SameObjectAndContent(source.Capture())) throw new InvalidDataException("A file changed after review: " + file.Path);
                if (file.Directory)
                {
                    var expected = preview.Files.Where(child => string.Equals(Path.GetDirectoryName(child.Path), file.Path, StringComparison.OrdinalIgnoreCase)).Select(child => child.Path).Order(StringComparer.OrdinalIgnoreCase);
                    if (!source.Children().SequenceEqual(expected, StringComparer.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed directory gained or lost an entry.");
                }
            }
            Save(journalPath, journal);
            foreach (var entry in journal.Entries)
            {
                var source = held[entry.Original.Path];
                source.Backup(entry.BackupPath);
                entry.BackupHash = OperationFiles.HashFile(entry.BackupPath);
                VerifyBackup(entry, directory);
                if (!entry.Original.SameObjectAndContent(source.Capture())) throw new InvalidDataException("File contents or metadata changed during backup.");
                entry.Status = "backedUp";
                Save(journalPath, journal);
            }
            currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
            journal.Status = "deleting";
            Save(journalPath, journal);
            foreach (var entry in journal.Entries.OrderByDescending(entry => Depth(entry.Original.Path)))
            {
                var source = held[entry.Original.Path];
                if (entry.Original.Directory)
                {
                    source.Dispose(); held.Remove(entry.Original.Path);
                    source = FileLease.Open(entry.Original.Path, writable: true);
                    held.Add(entry.Original.Path, source);
                    if (source.Capture().Identity != entry.Original.Identity || source.Children().Length != 0)
                        throw new InvalidDataException("A directory was replaced or has unreviewed remaining entries.");
                }
                entry.Status = "deleteIntent";
                Save(journalPath, journal);
                source.MarkDelete();
                source.Dispose(); held.Remove(entry.Original.Path);
                entry.Status = "deleted";
                Save(journalPath, journal);
            }
            journal.Status = "applied";
            Save(journalPath, journal);
        }
        catch (Exception error)
        {
            journal.Status = "needsReconciliation";
            var active = journal.Entries.FirstOrDefault(entry => entry.Status is "deleteIntent" or "pending") ?? journal.Entries.First();
            active.Error = error.Message;
            Save(journalPath, journal);
        }
        finally { foreach (var source in held.Values) source.Dispose(); }
        return journal;
    }

    public FileCleanupJournal Restore(string journalPath)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var journal = ReadJournal(journalPath);
        currentAuthority().Verify(journal.Preview.AppId, journal.Preview.ProviderIdentityHash);
        var conflicts = false;
        var createdDirectories = new Dictionary<string, FileIdentity>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in journal.Entries.Where(entry => entry.Status is "deleted" or "deleteIntent" or "restoreIntent" or "restored").OrderBy(entry => Depth(entry.Original.Path)))
        {
            try
            {
                if (entry.BackupHash is null || OperationFiles.HashFile(entry.BackupPath) != entry.BackupHash) throw new InvalidDataException("The file backup is missing or changed.");
                FileLease? existing = null;
                try { existing = FileLease.Open(entry.Original.Path); }
                catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
                if (existing is not null)
                {
                    using (existing)
                    {
                        var current = existing.Capture();
                        var unfinishedDirectory = entry.Original.Directory && !entry.DirectoryMetadataRestored && entry.RestoredIdentity == current.Identity;
                        var compared = unfinishedDirectory ? current with { LastWriteTime = entry.Original.LastWriteTime } : current;
                        if (!entry.Original.SameRestorableData(compared)) throw new InvalidDataException("New or changed data occupies the restore destination.");
                        if (unfinishedDirectory || entry.Original.Directory && entry.Status == "restoreIntent" && entry.RestoredIdentity is null)
                        {
                            entry.RestoredIdentity = current.Identity;
                            createdDirectories.Add(entry.Original.Path, current.Identity);
                        }
                    }
                    entry.Status = "restored";
                    entry.Error = null;
                    Save(journalPath, journal);
                    continue;
                }
                entry.Status = "restoreIntent";
                Save(journalPath, journal);
                if (entry.Original.Directory)
                {
                    using var restored = FileLease.Create(entry.Original.Path, true);
                    restored.RestoreData(entry.BackupPath, entry.Original);
                    var snapshot = restored.Capture();
                    if (!entry.Original.SameRestorableData(snapshot)) throw new InvalidDataException("Restored directory data or permissions differ from the backup.");
                    createdDirectories.Add(entry.Original.Path, snapshot.Identity);
                    entry.RestoredIdentity = snapshot.Identity;
                    entry.DirectoryMetadataRestored = false;
                    Save(journalPath, journal);
                }
                else RestoreFile(entry, journalPath, journal);
                entry.Status = "restored";
                entry.Error = null;
                Save(journalPath, journal);
            }
            catch (Exception error) { entry.Error = error.Message; conflicts = true; Save(journalPath, journal); }
        }
        foreach (var entry in journal.Entries.Where(entry => createdDirectories.ContainsKey(entry.Original.Path)).OrderByDescending(entry => Depth(entry.Original.Path)))
        {
            try
            {
                using var directory = FileLease.OpenForRestore(entry.Original.Path);
                var children = journal.Preview.Files.Where(file => string.Equals(Path.GetDirectoryName(file.Path), entry.Original.Path, StringComparison.OrdinalIgnoreCase)).Select(file => file.Path).Order(StringComparer.OrdinalIgnoreCase);
                if (directory.Capture().Identity != createdDirectories[entry.Original.Path] || !directory.Children().SequenceEqual(children, StringComparer.OrdinalIgnoreCase))
                    throw new InvalidDataException("Directory contents changed during restoration; metadata was left unchanged.");
                if (journal.Entries.Any(child => child.Original.Path != entry.Original.Path && Within(child.Original.Path, entry.Original.Path) && (child.Status != "restored" || child.Error is not null)))
                    throw new InvalidDataException("A directory still has unresolved child data; its metadata was left unchanged.");
                directory.RestoreMetadata(entry.Original);
                if (!entry.Original.SameRestorableData(directory.Capture())) throw new InvalidDataException("Restored directory metadata differs from the backup.");
                entry.DirectoryMetadataRestored = true;
                entry.Error = null;
            }
            catch (Exception error) { entry.Error = error.Message; conflicts = true; }
        }
        journal.Status = conflicts ? "needsReconciliation" : "restored";
        Save(journalPath, journal);
        return journal;
    }

    private static FileCleanupJournal ReconcileApplied(string path, FileCleanupJournal journal)
    {
        if (journal.Status != "applied") return journal;
        foreach (var entry in journal.Entries)
        {
            try
            {
                using var present = FileLease.Open(entry.Original.Path);
                entry.Error = "Data exists again at a deleted path. It will not be removed again.";
                journal.Status = "needsReconciliation";
            }
            catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
            catch (Exception error) { entry.Error = error.Message; journal.Status = "needsReconciliation"; }
        }
        Save(path, journal);
        return journal;
    }

    private static void RestoreFile(FileBackupEntry entry, string journalPath, FileCleanupJournal journal)
    {
        entry.RestoreStagingPath ??= Path.Combine(Path.GetDirectoryName(entry.Original.Path)!, ".roo-restore-" + Guid.NewGuid().ToString("N"));
        Save(journalPath, journal);
        FileLease? staging = null;
        var created = false;
        var renamed = false;
        try
        {
            try { staging = FileLease.Open(entry.RestoreStagingPath, writable: true); }
            catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3)
            {
                staging = FileLease.Create(entry.RestoreStagingPath, false);
                created = true;
            }
            if (created) staging.RestoreData(entry.BackupPath, entry.Original);
            if (!entry.Original.SameRestorableData(staging.Capture())) throw new InvalidDataException("An unfinished restore file needs review before retrying.");
            staging.RenameToSibling(Path.GetFileName(entry.Original.Path));
            renamed = true;
            entry.RestoreStagingPath = null;
        }
        finally
        {
            if (staging is not null)
            {
                try { if (created && !renamed) staging.MarkDelete(); }
                finally { staging.Dispose(); }
            }
        }
    }

    private static void VerifyBackup(FileBackupEntry entry, string directory)
    {
        var path = Path.Combine(directory, "verify-" + Guid.NewGuid().ToString("N"));
        using var restored = FileLease.Create(path, entry.Original.Directory);
        try
        {
            restored.RestoreData(entry.BackupPath, entry.Original);
            var readback = restored.Capture();
            var differences = entry.Original.Differences(readback);
            if (differences.Length != 0) throw new InvalidDataException("Backup verification differs in " + string.Join(", ", differences) + ".");
        }
        finally { restored.MarkDelete(); }
    }

    private static FileSnapshot[] CaptureTree(string[] roots)
    {
        var files = new List<FileSnapshot>();
        var pending = new Queue<string>(roots);
        while (pending.TryDequeue(out var path))
        {
            if (files.Count >= 100000 || Depth(path) > 128) throw new InvalidDataException("File cleanup review exceeded its entry or depth limit.");
            using var source = FileLease.Open(path);
            var snapshot = source.Capture();
            files.Add(snapshot);
            if (snapshot.Directory) foreach (var child in source.Children()) pending.Enqueue(child);
        }
        if (files.Select(file => file.Identity).Distinct().Count() != files.Count) throw new InvalidDataException("File selections alias the same underlying objects.");
        return files.OrderBy(file => Depth(file.Path)).ThenBy(file => file.Path, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static FileCleanupJournal ReadJournal(string path, string? expectedReviewHash = null)
    {
        var journal = OperationFiles.Read<FileCleanupJournal>(path);
        ValidatePreview(journal.Preview);
        if (journal.SchemaVersion != 1 || (expectedReviewHash is not null && journal.ReviewHash != expectedReviewHash)) throw new InvalidDataException("The file journal belongs to another review.");
        var original = OperationFiles.Read<FileCleanupPreview>(journal.PreviewPath, journal.ReviewHash);
        if (JsonSerializer.Serialize(original, OperationFiles.Json) != JsonSerializer.Serialize(journal.Preview, OperationFiles.Json) || journal.Entries.Count != original.Files.Length)
            throw new InvalidDataException("The recovery journal does not match the reviewed files.");
        foreach (var entry in journal.Entries)
        {
            if (entry.Status is not ("pending" or "backedUp" or "deleteIntent" or "deleted" or "restoreIntent" or "restored"))
                throw new InvalidDataException("Unknown file recovery state.");
            var reviewed = original.Files.SingleOrDefault(file => file.Path == entry.Original.Path);
            if (reviewed is null || JsonSerializer.Serialize(reviewed, OperationFiles.Json) != JsonSerializer.Serialize(entry.Original, OperationFiles.Json))
                throw new InvalidDataException("A recovery entry changed its original file binding.");
            if (original.Roots.Any(root => Within(entry.BackupPath, root))) throw new InvalidDataException("Backup data overlaps a deletion target.");
            if (entry.RestoreStagingPath is not null && (!string.Equals(Path.GetDirectoryName(entry.RestoreStagingPath), Path.GetDirectoryName(entry.Original.Path), StringComparison.OrdinalIgnoreCase) ||
                !Path.GetFileName(entry.RestoreStagingPath).StartsWith(".roo-restore-", StringComparison.Ordinal)))
                throw new InvalidDataException("Restore staging path is outside its bound destination parent.");
        }
        return journal;
    }

    private static void ValidatePreview(FileCleanupPreview preview)
    {
        if (preview.SchemaVersion != 1 || !Guid.TryParseExact(preview.OperationId, "N", out _) || preview.ProviderIdentityHash is not { Length: 64 } ||
            string.IsNullOrWhiteSpace(preview.AppId) || preview.Files is not { Length: > 0 }) throw new InvalidDataException("The file cleanup review is incomplete.");
        preview.Owner.Verify();
        ValidateRoots(preview.Roots);
        if (preview.Files.Select(file => file.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != preview.Files.Length) throw new InvalidDataException("Duplicate reviewed file path.");
        foreach (var file in preview.Files)
        {
            if (FileLease.NormalizePath(file.Path) != file.Path || !preview.Roots.Any(root => Within(file.Path, root)) || file.SecurityCoverage != 7 || file.Security is not { Length: > 0 } || file.Identity.Id.Length != 32)
                throw new InvalidDataException("Reviewed file identity, scope or recovery coverage is incomplete.");
        }
    }

    private static void ValidateRoots(string[] roots)
    {
        if (roots.Length == 0) throw new InvalidDataException("Select file or directory targets.");
        for (var index = 0; index < roots.Length; index++)
        {
            var root = FileLease.NormalizePath(roots[index]);
            if (IsProtectedPath(root)) throw new InvalidDataException("A shared system, package payload or user-data root cannot be removed as an app leftover.");
            if (roots.Take(index).Any(other => Within(root, other) || Within(other, root))) throw new InvalidDataException("Selected file roots overlap.");
        }
    }

    internal static bool IsProtectedPath(string path)
    {
        var protectedRoots = new[] { Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.ProgramFiles,
            Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.CommonProgramFiles, Environment.SpecialFolder.CommonProgramFilesX86,
            Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.StartMenu,
            Environment.SpecialFolder.Programs, Environment.SpecialFolder.Startup, Environment.SpecialFolder.CommonStartMenu,
            Environment.SpecialFolder.CommonPrograms, Environment.SpecialFolder.CommonStartup }
            .Select(Environment.GetFolderPath).Where(root => !string.IsNullOrWhiteSpace(root)).ToList();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        protectedRoots.AddRange([Path.GetTempPath().TrimEnd('\\'), Path.GetDirectoryName(local)!, Path.Combine(local, "Packages")]);
        if (protectedRoots.Contains(path, StringComparer.OrdinalIgnoreCase) || Within(path, Environment.GetFolderPath(Environment.SpecialFolder.Windows))) return true;
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return Within(path, Path.Combine(programFiles, "WindowsApps")) || Within(path, Path.Combine(Path.GetPathRoot(path)!, "WindowsApps"));
    }

    private static bool Within(string path, string root) => string.Equals(path, root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    private static int Depth(string path) => path.Count(character => character == '\\');
    private static void Save(string path, FileCleanupJournal journal) { journal.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, journal); }
}
