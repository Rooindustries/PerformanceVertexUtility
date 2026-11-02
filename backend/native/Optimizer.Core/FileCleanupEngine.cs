#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class CleanupSpaceException(string message) : IOException(message);

// Every reviewed leftover held open with its undo copies made, so nothing else can change them before cleanup deletes them.
public sealed class FileCleanupHold : IDisposable
{
    internal FileCleanupHold(FileStream lease, string journalPath, FileCleanupJournal journal, bool resumed)
    {
        Lease = lease; JournalPath = journalPath; Journal = journal; Resumed = resumed;
    }

    internal FileStream Lease { get; }
    internal string JournalPath { get; }
    internal FileCleanupJournal Journal { get; }
    internal bool Resumed { get; }
    internal ulong Store { get; set; }
    internal Dictionary<string, FileLease> Held { get; } = new(StringComparer.OrdinalIgnoreCase);

    public void Dispose()
    {
        foreach (var source in Held.Values) source.Dispose();
        Held.Clear();
        Lease.Dispose();
    }
}

public sealed class FileCleanupEngine(Func<CleanupAuthority> currentAuthority)
{
    private const string BackupPrefix = "file-backup-";
    internal static Action<int>? CheckpointReached;
    private int _checkpoints;

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
        using var hold = Prepare(previewPath, reviewHash, journalPath);
        return Apply(hold);
    }

    // Holds every reviewed leftover, runs every check that can refuse the cleanup (changed since review, open in another program, rights,
    // free space) and makes the undo copies, all before anything is deleted, so a caller can do this before its other parts change anything.
    // A refusal leaves nothing behind, so the cleanup can run again from its review.
    public FileCleanupHold Prepare(string previewPath, string reviewHash, string journalPath)
    {
        var preview = OperationFiles.Read<FileCleanupPreview>(previewPath, reviewHash);
        ValidatePreview(preview);
        currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
        var directory = Path.GetDirectoryName(Path.GetFullPath(journalPath))!;
        if (preview.Roots.Any(root => Within(directory, root)) || string.Equals(Path.GetFullPath(previewPath), Path.GetFullPath(journalPath), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Recovery files and the journal must stay outside deletion targets and reviewed inputs.");
        var lease = OperationFiles.Lock(journalPath);
        try
        {
            if (File.Exists(journalPath))
            {
                var saved = ReadJournal(journalPath, reviewHash);
                if (!Unstarted(saved) || !Discard(saved, journalPath)) return new(lease, journalPath, saved, resumed: true);
            }
            var journal = new FileCleanupJournal
            {
                SchemaVersion = 1, Preview = preview, PreviewPath = Path.GetFullPath(previewPath), ReviewHash = reviewHash,
                Status = "preparing", UpdatedAtUtc = DateTime.UtcNow,
                Entries = preview.Files.Select(file => new FileBackupEntry
                {
                    Original = file, BackupPath = Path.Combine(directory, BackupPrefix + Guid.NewGuid().ToString("N")), Status = "pending",
                }).ToList(),
            };
            var hold = new FileCleanupHold(lease, journalPath, journal, resumed: false);
            try { Prepare(hold, directory); }
            catch { hold.Dispose(); throw; }
            return hold;
        }
        catch { lease.Dispose(); throw; }
    }

    private void Prepare(FileCleanupHold hold, string directory)
    {
        var (journal, journalPath, held) = (hold.Journal, hold.JournalPath, hold.Held);
        var preview = journal.Preview;
        hold.Store = StoreVolume(directory);
        foreach (var entry in journal.Entries)
        {
            var file = entry.Original;
            FileLease source;
            bool moved;
            try { source = Hold(file, hold.Store, out moved); }
            catch (Win32Exception error) when (error.NativeErrorCode == 32) { throw new IOException(file.Path + " is open in another program. Close it, then run cleanup again."); }
            held.Add(file.Path, source);
            entry.Moved = moved;
            if (!file.SameObjectAndContent(source.Capture())) throw new InvalidDataException("A file changed after review: " + file.Path);
            if (file.Directory)
            {
                var expected = preview.Files.Where(child => string.Equals(Path.GetDirectoryName(child.Path), file.Path, StringComparison.OrdinalIgnoreCase)).Select(child => child.Path).Order(StringComparer.OrdinalIgnoreCase);
                if (!source.Children().SequenceEqual(expected, StringComparer.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed directory gained or lost an entry.");
            }
        }
        var copies = journal.Entries.Where(entry => !entry.Moved).ToList();
        var cluster = Cluster(directory);
        var sizes = copies.Select(entry => Allocated(BackupBytes(entry.Original), cluster)).ToArray();
        var verify = copies.Count == 0 ? 0 : Allocated(copies.Max(entry => DataBytes(entry.Original)), cluster);
        var remaining = sizes.Sum();
        var record = JournalBytes(preview, journalPath, cluster);
        RequireFree(directory, remaining + verify + record, copies.Select(entry => entry.Original));
        if (journal.Entries.Any(entry => entry.Moved)) journal.Protection = StoreProtection(directory);
        Save(journalPath, journal);
        Checkpoint();
        try
        {
            for (var index = 0; index < copies.Count; index++)
            {
                var entry = copies[index];
                RequireFree(directory, remaining + verify + record, copies.Skip(index).Select(copy => copy.Original));
                remaining -= sizes[index];
                var source = held[entry.Original.Path];
                source.Backup(entry.BackupPath);
                entry.BackupHash = OperationFiles.HashFile(entry.BackupPath);
                VerifyBackup(entry, directory);
                if (!entry.Original.SameObjectAndContent(source.Capture())) throw new InvalidDataException("File contents or metadata changed during backup.");
                entry.Status = "backedUp";
                Checkpoint();
            }
        }
        catch (Exception error)
        {
            if (!Discard(journal, journalPath))
            {
                journal.Status = "needsReconciliation";
                journal.Entries.First(entry => entry.Status is "pending" or "backedUp").Error = error.Message;
                Save(journalPath, journal);
            }
            throw;
        }
    }

    public FileCleanupJournal Apply(FileCleanupHold hold)
    {
        var (journal, journalPath, held) = (hold.Journal, hold.JournalPath, hold.Held);
        if (hold.Resumed) return ReconcileApplied(journalPath, journal);
        var preview = journal.Preview;
        FileLease? storeFolder = null;
        try
        {
            currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
            if (journal.Entries.Any(entry => entry.Moved))
            {
                storeFolder = FileLease.OpenFolder(Path.GetDirectoryName(Path.GetFullPath(journalPath))!);
                if (storeFolder.ObjectIdentity.Volume != hold.Store) throw new InvalidDataException("The recovery folder moved to another drive during cleanup.");
            }
            journal.Status = "deleting";
            Save(journalPath, journal);
            Checkpoint();
            foreach (var entry in journal.Entries.OrderByDescending(entry => Depth(entry.Original.Path)))
            {
                var source = held[entry.Original.Path];
                if (entry.Original.Directory)
                {
                    source.Dispose(); held.Remove(entry.Original.Path);
                    source = entry.Moved ? FileLease.OpenForMove(entry.Original.Path) : FileLease.Open(entry.Original.Path, writable: true);
                    held.Add(entry.Original.Path, source);
                    if (source.Capture().Identity != entry.Original.Identity || source.Children().Length != 0)
                        throw new InvalidDataException("A directory was replaced or has unreviewed remaining entries.");
                }
                entry.Status = "deleteIntent";
                if (entry.Moved)
                {
                    source.ReplaceDacl(Protection(journal, entry.Original));
                    Checkpoint();
                    source.RenameInto(storeFolder!, Path.GetFileName(entry.BackupPath));
                }
                else source.MarkDelete();
                source.Dispose(); held.Remove(entry.Original.Path);
                entry.Status = "deleted";
                Checkpoint();
            }
            journal.Status = "applied";
            Save(journalPath, journal);
        }
        catch (Exception error)
        {
            journal.Status = "needsReconciliation";
            var active = journal.Entries.FirstOrDefault(entry => entry.Status is "deleteIntent" or "pending") ?? journal.Entries.First();
            active.Error = error.Message;
            if (journal.Entries.All(entry => entry.Status is "pending" or "backedUp"))
                foreach (var entry in journal.Entries.Where(entry => !entry.Moved))
                {
                    try { File.Delete(entry.BackupPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                    if (File.Exists(entry.BackupPath)) continue;
                    entry.BackupHash = null;
                    entry.Status = "pending";
                }
            Save(journalPath, journal);
        }
        finally { storeFolder?.Dispose(); }
        return journal;
    }

    // Cleanup stopped or was refused before it deleted anything, so the only things it made are undo copies.
    private static bool Unstarted(FileCleanupJournal journal)
        => journal.Status == "preparing" || journal.Status == "needsReconciliation" && journal.Entries.All(entry => entry.Status is "pending" or "backedUp");

    // Removes an unstarted cleanup's undo copies and then its journal. If a copy can't be removed, the journal stays to keep track of it.
    private static bool Discard(FileCleanupJournal journal, string journalPath)
    {
        foreach (var entry in journal.Entries.Where(entry => !entry.Moved))
        {
            try { File.Delete(entry.BackupPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            if (File.Exists(entry.BackupPath)) return false;
            entry.BackupHash = null;
            entry.Status = "pending";
        }
        if (File.Exists(journalPath)) File.Delete(journalPath);
        return true;
    }

    private static byte[] Protection(FileCleanupJournal journal, FileSnapshot original)
    {
        var protection = journal.Protection ?? throw new InvalidDataException("The journal doesn't have the undo folder's permissions.");
        return original.Directory ? protection.Directory : protection.File;
    }

    public FileCleanupJournal Restore(string journalPath)
    {
        using var lease = OperationFiles.Lock(journalPath);
        var journal = ReadJournal(journalPath);
        currentAuthority().Verify(journal.Preview.AppId, journal.Preview.ProviderIdentityHash);
        if (journal.Status == "deleting")
            foreach (var entry in journal.Entries.Where(entry => entry.Status is "pending" or "backedUp")) entry.Status = "deleteIntent";
        if (journal.Entries.All(entry => entry.Status is "pending" or "backedUp")) return journal;
        var conflicts = false;
        var directories = new Dictionary<string, FileIdentity>(StringComparer.OrdinalIgnoreCase);
        var staged = new List<(FileBackupEntry Entry, FileLease Staging)>();
        try
        {
            foreach (var entry in journal.Entries.Where(entry => entry.Status is "deleted" or "deleteIntent" or "restoreIntent" or "restored").OrderBy(entry => Depth(entry.Original.Path)))
            {
                try
                {
                    // A finished entry belongs to the user again; anything changed on it since is theirs.
                    if (Finished(entry)) { entry.LeftAsChanged = ChangedSinceRestore(entry) switch { true => LeftAsIs, false => null, null => entry.LeftAsChanged }; continue; }
                    entry.LeftAsChanged = null;
                    FileLease? existing = null;
                    try { existing = FileLease.Open(entry.Original.Path); }
                    catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
                    if (existing is not null)
                    {
                        using (existing) Reconcile(journal, entry, existing, directories);
                        entry.Status = "restored";
                        entry.Error = null;
                        continue;
                    }
                    if (entry.Moved) RestoreMovedEntry(journal, entry, directories);
                    else if (entry.Original.Directory)
                    {
                        if (entry.BackupHash is null || OperationFiles.HashFile(entry.BackupPath) != entry.BackupHash) throw new InvalidDataException("The file backup is missing or changed.");
                        entry.Status = "restoreIntent";
                        Save(journalPath, journal);
                        using var restored = FileLease.Create(entry.Original.Path, true);
                        restored.RestoreData(entry.BackupPath, entry.Original);
                        var snapshot = restored.Capture();
                        if (!entry.Original.SameRestorableData(snapshot)) throw new InvalidDataException("Restored directory data or permissions differ from the backup.");
                        directories[entry.Original.Path] = snapshot.Identity;
                        entry.RestoredIdentity = snapshot.Identity;
                        entry.DirectoryMetadataRestored = false;
                        Save(journalPath, journal);
                    }
                    else
                    {
                        if (entry.BackupHash is null || OperationFiles.HashFile(entry.BackupPath) != entry.BackupHash) throw new InvalidDataException("The file backup is missing or changed.");
                        staged.Add((entry, StageCopy(entry)));
                        Checkpoint();
                        continue;
                    }
                    entry.Status = "restored";
                    entry.Error = null;
                    Checkpoint();
                }
                catch (Exception error) { entry.Error = error.Message; conflicts = true; }
            }
            if (staged.Count != 0)
            {
                // Each copy's identity is saved before it takes the leftover's name, so a retry after a stop knows the file there is its own.
                Save(journalPath, journal);
                Checkpoint();
                foreach (var (entry, staging) in staged)
                {
                    try
                    {
                        PlaceCopy(entry, staging);
                        entry.Status = "restored";
                        entry.Error = null;
                        Checkpoint();
                    }
                    catch (Exception error) { entry.Error = error.Message; conflicts = true; }
                }
            }
        }
        finally { foreach (var (_, staging) in staged) staging.Dispose(); }
        foreach (var entry in journal.Entries.Where(entry => directories.ContainsKey(entry.Original.Path)).OrderByDescending(entry => Depth(entry.Original.Path)))
        {
            try
            {
                var identity = directories[entry.Original.Path];
                FileSnapshot found;
                using (var probe = FileLease.Open(entry.Original.Path)) found = probe.Capture();
                bool Ours(FileSnapshot snapshot) => Recorded(entry.Original, snapshot, entry.Moved, entry.Moved ? Protection(journal, entry.Original) : null);
                if (found.Identity == identity && !Ours(found))
                {
                    entry.LeftAsChanged = LeftAsIs;
                    entry.DirectoryMetadataRestored = true;
                    entry.Error = null;
                    continue;
                }
                // Only a moved folder still has the undo folder's permissions; anything else left to put back is its attributes and times.
                var differences = entry.Original.Differences(found);
                var timesOnly = differences.All(difference => difference is "attributes" or "creation time" or "last-write time");
                using var directory = differences.Length == 0 ? FileLease.Open(entry.Original.Path) : timesOnly ? FileLease.OpenForTimes(entry.Original.Path) : FileLease.OpenForMove(entry.Original.Path);
                var children = journal.Preview.Files.Where(file => string.Equals(Path.GetDirectoryName(file.Path), entry.Original.Path, StringComparison.OrdinalIgnoreCase)).Select(file => file.Path).Order(StringComparer.OrdinalIgnoreCase);
                var current = directory.Capture();
                if (current.Identity != identity || !directory.Children().SequenceEqual(children, StringComparer.OrdinalIgnoreCase) || !Ours(current))
                    throw new InvalidDataException("Directory contents changed during restoration; metadata was left unchanged.");
                if (journal.Entries.Any(child => child.Original.Path != entry.Original.Path && Within(child.Original.Path, entry.Original.Path) && (child.Status != "restored" || child.Error is not null)))
                    throw new InvalidDataException("A directory still has unresolved child data; its metadata was left unchanged.");
                if (!timesOnly) directory.RestoreMoved(entry.Original);
                else if (differences.Length != 0) directory.RestoreTimes(entry.Original);
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

    private const string LeftAsIs = "This was changed after cleanup, so it was left as is.";
    private const uint Archive = 0x20, Normal = 0x80;

    private static bool Finished(FileBackupEntry entry) => entry.Status == "restored" && entry.Error is null && (!entry.Original.Directory || entry.DirectoryMetadataRestored);

    // Null when the entry can't be read right now (another program has it open, or it denies reading), so nothing is claimed about it.
    private static bool? ChangedSinceRestore(FileBackupEntry entry)
    {
        try { using var probe = FileLease.Open(entry.Original.Path); return !entry.Original.SameRestorableData(probe.Capture()); }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { return true; }
        catch (InvalidDataException) { return true; }
        catch (Win32Exception) { return null; }
    }

    // Something is at the leftover's path. Restore finishes it only when it's in a state cleanup itself left it in. Anything else was changed
    // by the user or another program after cleanup and is left as it is.
    private static void Reconcile(FileCleanupJournal journal, FileBackupEntry entry, FileLease existing, Dictionary<string, FileIdentity> directories)
    {
        var original = entry.Original;
        var current = existing.Capture();
        if (current.Identity == original.Identity)
        {
            // The leftover itself: cleanup never deleted it, or an earlier restore moved it back before its own permissions went back on.
            var protection = entry.Moved ? Protection(journal, original) : null;
            if (!Recorded(original, current, entry.Moved, protection)) { entry.LeftAsChanged = LeftAsIs; return; }
            if (original.Directory) { directories[original.Path] = current.Identity; return; }
            if (original.SameRestorableData(current)) return;
            existing.Dispose();
            using var own = FileLease.OpenForMove(original.Path);
            var held = own.Capture();
            if (held.Identity != original.Identity || !Recorded(original, held, entry.Moved, protection)) throw new InvalidDataException("This file changed while it was being put back, so it was left as is.");
            own.RestoreMoved(original);
            if (!original.SameRestorableData(own.Capture())) throw new InvalidDataException("Restored file permissions differ from the backup.");
            return;
        }
        if (current.Identity == entry.RestoredIdentity)
        {
            // This restore's own copy, put in place before its attributes and times went back on.
            entry.RestoreStagingPath = null;
            if (!Recorded(original, current, !original.Directory, null)) { entry.LeftAsChanged = LeftAsIs; return; }
            if (original.Directory) directories[original.Path] = current.Identity;
            else if (!original.SameRestorableData(current)) { existing.Dispose(); FinishCopy(entry); }
            return;
        }
        if (original.Directory && entry.Status == "restoreIntent" && entry.RestoredIdentity is null && original.SameRestorableData(current))
        {
            // A folder this restore made just before it could save the folder's identity.
            entry.RestoredIdentity = current.Identity;
            directories[original.Path] = current.Identity;
            return;
        }
        if (original.SameRestorableData(current)) { if (original.Directory) entry.DirectoryMetadataRestored = true; return; }
        // The moved leftover isn't in the undo folder, so it was never moved or was put back, and someone replaced it since.
        if (entry.Moved && !Path.Exists(entry.BackupPath)) { entry.LeftAsChanged = LeftAsIs; return; }
        throw new InvalidDataException("New or changed data occupies the restore destination.");
    }

    // The states cleanup itself leaves an object in: the reviewed state; for a moved leftover, the undo folder's permissions it takes before
    // the move; and the archive flag Windows sets when it renames a file, which replaces a plain "normal" flag. A folder's last-write time
    // follows the entries moved in and out of it and goes back last.
    private static bool Recorded(FileSnapshot original, FileSnapshot current, bool renamed, byte[]? protection)
    {
        var differences = original.Differences(current).ToList();
        if (original.Directory) differences.Remove("last-write time");
        if (renamed && current.Attributes == ((original.Attributes & ~Normal) | Archive)) differences.Remove("attributes");
        if (protection is not null && HasProtection(original, current, protection)) differences.Remove("permissions");
        return differences.Count == 0;
    }

    // True when the object keeps its own owner and group and has exactly the undo folder's protected permission list, as cleanup set it.
    private static bool HasProtection(FileSnapshot original, FileSnapshot current, byte[] protection)
    {
        const ControlFlags inheritance = ControlFlags.DiscretionaryAclProtected | ControlFlags.DiscretionaryAclAutoInherited;
        var now = new RawSecurityDescriptor(current.Security, 0);
        var before = new RawSecurityDescriptor(original.Security, 0);
        var folder = new RawSecurityDescriptor(protection, 0);
        return now.Owner == before.Owner && now.Group == before.Group && (now.ControlFlags & inheritance) == (folder.ControlFlags & inheritance) && Acl(now).SequenceEqual(Acl(folder));
        static byte[] Acl(RawSecurityDescriptor descriptor)
        {
            if (descriptor.DiscretionaryAcl is null) return [];
            var bytes = new byte[descriptor.DiscretionaryAcl.BinaryLength];
            descriptor.DiscretionaryAcl.GetBinaryForm(bytes, 0);
            return bytes;
        }
    }

    private void RestoreMovedEntry(FileCleanupJournal journal, FileBackupEntry entry, Dictionary<string, FileIdentity> directories)
    {
        FileLease stored;
        try { stored = FileLease.OpenForMove(entry.BackupPath); }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { throw new InvalidDataException("The undo copy is missing."); }
        using (stored)
        {
            var copy = stored.Capture();
            if (copy.Identity != entry.Original.Identity || !Recorded(entry.Original, copy, true, Protection(journal, entry.Original)) || entry.Original.Directory && stored.Children().Length != 0)
                throw new InvalidDataException("The undo copy changed after cleanup.");
            // The destination folder and every folder above it stay open through the rename, so none of them can be swapped for a junction.
            using (var folder = FileLease.OpenFolder(Path.GetDirectoryName(entry.Original.Path)!))
            {
                Checkpoint();
                stored.RenameInto(folder, Path.GetFileName(entry.Original.Path));
            }
            Checkpoint();
            stored.RestoreMoved(entry.Original);
            if (entry.Original.Directory) directories[entry.Original.Path] = copy.Identity;
            else if (!entry.Original.SameRestorableData(stored.Capture())) throw new InvalidDataException("Restored file data or permissions differ from the backup.");
        }
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

    // Writes a copied leftover to its staging name beside the destination. Windows deletes a staging file the app stops with before it has
    // the leftover's name, so a staging file found later is this restore's only if it has the saved identity and exactly the reviewed data.
    // Anything else there is kept and reported.
    private static FileLease StageCopy(FileBackupEntry entry)
    {
        entry.RestoreStagingPath ??= Path.Combine(Path.GetDirectoryName(entry.Original.Path)!, ".roo-industries-restore-" + Path.GetFileName(entry.BackupPath)[BackupPrefix.Length..]);
        FileLease? found = null;
        try { found = FileLease.OpenForRename(entry.RestoreStagingPath); }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
        if (found is not null)
        {
            var kept = false;
            try
            {
                var snapshot = found.Capture();
                if (snapshot.Identity != entry.RestoredIdentity || !entry.Original.SameRestorableData(snapshot))
                    throw new InvalidDataException("Something Restore didn't make is at " + entry.RestoreStagingPath + ", so it was left as is and this file wasn't put back.");
                entry.Status = "restoreIntent";
                kept = true;
                return found;
            }
            finally { if (!kept) found.Dispose(); }
        }
        var staging = FileLease.CreateUnkept(entry.RestoreStagingPath);
        var done = false;
        try
        {
            staging.RestoreData(entry.BackupPath, entry.Original);
            var snapshot = staging.Capture();
            if (!entry.Original.SameRestorableData(snapshot)) throw new InvalidDataException("Restored file data or permissions differ from the backup.");
            entry.RestoredIdentity = snapshot.Identity;
            entry.Status = "restoreIntent";
            done = true;
            return staging;
        }
        finally { if (!done) staging.Dispose(); }
    }

    private void PlaceCopy(FileBackupEntry entry, FileLease staging)
    {
        if (staging.ObjectIdentity != entry.RestoredIdentity) throw new InvalidDataException("An unfinished restore file was replaced before it was put back.");
        staging.RenameToSibling(Path.GetFileName(entry.Original.Path));
        // Kept from here on: it has the leftover's name and its identity is saved.
        staging.Keep();
        Checkpoint();
        // Windows marks a renamed file for archiving, so the reviewed attributes and times go back on after the rename.
        staging.RestoreTimes(entry.Original);
        if (!entry.Original.SameRestorableData(staging.Capture())) throw new InvalidDataException("Restored file data or permissions differ from the backup.");
        entry.RestoreStagingPath = null;
    }

    // Finishes a copy that took the leftover's name before its attributes and times went back on.
    private static void FinishCopy(FileBackupEntry entry)
    {
        using var own = FileLease.OpenForTimes(entry.Original.Path);
        var current = own.Capture();
        if (current.Identity != entry.RestoredIdentity || !Recorded(entry.Original, current, true, null)) throw new InvalidDataException("This file changed while it was being put back, so it was left as is.");
        own.RestoreTimes(entry.Original);
        if (!entry.Original.SameRestorableData(own.Capture())) throw new InvalidDataException("Restored file data or permissions differ from the backup.");
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

    private static FileLease Hold(FileSnapshot file, ulong store, out bool moved)
    {
        var probe = MoveLease(file, store);
        moved = probe is not null;
        if (probe is not null && !file.Directory) return probe;
        probe?.Dispose();
        return FileLease.Open(file.Path, writable: !file.Directory);
    }

    private static FileLease? MoveLease(FileSnapshot file, ulong store)
    {
        if (file.Identity.Volume != store || new RawSecurityDescriptor(file.Security, 0).DiscretionaryAcl is null) return null;
        try { return FileLease.OpenForMove(file.Path); }
        catch (Win32Exception error) when (error.NativeErrorCode == 5) { return null; }
    }

    private static bool Copied(FileSnapshot file, ulong store)
    {
        // A missing or locked entry isn't counted here; Apply refuses it when it reopens every entry.
        try { using var probe = MoveLease(file, store); return probe is null; }
        catch (Exception error) when (error is Win32Exception or InvalidDataException) { return false; }
    }

    private static ulong StoreVolume(string directory)
    {
        using var store = FileLease.OpenFolder(Existing(directory));
        return store.ObjectIdentity.Volume;
    }

    private static string Existing(string directory)
    {
        while (!Directory.Exists(directory)) directory = Path.GetDirectoryName(directory) ?? throw new InvalidDataException("The recovery folder has no existing drive.");
        return directory;
    }

    // The root a volume is reached through: a drive letter or a subst drive.
    private static string VolumePath(string directory)
    {
        var path = new StringBuilder(32768);
        if (!GetVolumePathName(Existing(directory), path, (uint)path.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not find the drive of " + directory);
        return path.ToString();
    }

    private static FileStoreProtection StoreProtection(string directory)
    {
        return new(Probe(false), Probe(true));
        byte[] Probe(bool folder)
        {
            using var probe = FileLease.Create(Path.Combine(directory, "protection-probe-" + Guid.NewGuid().ToString("N")), folder);
            try
            {
                var inherited = new RawSecurityDescriptor(probe.Capture().Security, 0).DiscretionaryAcl ?? throw new InvalidDataException("The recovery folder gives new files no permissions.");
                var acl = new RawAcl(inherited.Revision, inherited.Count);
                foreach (GenericAce ace in inherited)
                {
                    var copy = ace.Copy();
                    copy.AceFlags &= ~AceFlags.Inherited;
                    acl.InsertAce(acl.Count, copy);
                }
                var descriptor = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclProtected, null, null, null, acl);
                var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
                return bytes;
            }
            finally { probe.MarkDelete(); }
        }
    }

    public static void RequireSpace(IEnumerable<(FileCleanupPreview Plan, string JournalPath)> parts)
    {
        // Recovery folders reached through different drive letters or subst drives share one budget when they are on one volume.
        foreach (var store in parts.Select(part => (part.Plan, part.JournalPath, Directory: Existing(Path.GetDirectoryName(Path.GetFullPath(part.JournalPath))!))).GroupBy(part => StoreVolume(part.Directory)))
        {
            var directory = store.First().Directory;
            var copies = store.SelectMany(part => part.Plan.Files.Where(file => Copied(file, store.Key))).ToArray();
            var cluster = Cluster(directory);
            RequireFree(directory, copies.Sum(file => Allocated(BackupBytes(file), cluster)) + (copies.Length == 0 ? 0 : Allocated(copies.Max(DataBytes), cluster)) +
                store.Sum(part => JournalBytes(part.Plan, part.JournalPath, cluster)), copies);
        }
    }

    // Room for a cleanup's journal at its largest, used by both the space check before an app's other parts run and the one cleanup makes
    // itself: every entry with an undo copy, its hash, a staging name, a restored identity, an error and a left-as-is note, plus the undo
    // folder's permissions at their largest. Each save writes the new journal beside the old one before replacing it, so both fit at once.
    private static long JournalBytes(FileCleanupPreview plan, string journalPath, long cluster)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(journalPath))!;
        var largest = new FileCleanupJournal
        {
            SchemaVersion = 1, PreviewPath = Path.GetFullPath(journalPath), ReviewHash = new string('0', 64), Preview = plan, Status = "needsReconciliation",
            UpdatedAtUtc = DateTime.MaxValue, Protection = new(new byte[ushort.MaxValue], new byte[ushort.MaxValue]),
            Entries = plan.Files.Select(file => new FileBackupEntry
            {
                Original = file, BackupPath = Path.Combine(directory, BackupPrefix + Guid.Empty.ToString("N")), Moved = true, BackupHash = new string('0', 64),
                Status = "restoreIntent", Error = new string('0', 1024) + file.Path, RestoredIdentity = file.Identity, DirectoryMetadataRestored = true, LeftAsChanged = LeftAsIs,
                RestoreStagingPath = Path.Combine(Path.GetDirectoryName(file.Path)!, ".roo-industries-restore-" + Guid.Empty.ToString("N")),
            }).ToList(),
        };
        return 2 * Allocated(JsonSerializer.SerializeToUtf8Bytes(largest, OperationFiles.Json).LongLength, cluster);
    }

    private static long BackupBytes(FileSnapshot file) => file.Streams.Sum(stream => 20 + (stream.Name == "::$DATA" ? 0 : 2L * stream.Name.Length) + stream.Length) + 1024;
    private static long DataBytes(FileSnapshot file) => file.Streams.Sum(stream => stream.Length);
    private static long Allocated(long bytes, long cluster) => (bytes + cluster - 1) / cluster * cluster + 1024;

    private static long Cluster(string directory)
    {
        var root = VolumePath(directory);
        if (!GetDiskFreeSpace(root, out var sectors, out var sectorBytes, out _, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the cluster size of " + root);
        return Math.Max(1L, (long)sectors * sectorBytes);
    }

    private static void RequireFree(string directory, long need, IEnumerable<FileSnapshot> copies)
    {
        directory = Existing(directory);
        var drive = VolumePath(directory).TrimEnd('\\');
        if (!GetDiskFreeSpaceEx(directory, out var available, out var total, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the free space on " + drive);
        var free = (long)Math.Min(available, long.MaxValue);
        var reserve = Math.Clamp((long)(total / 20), 1L << 30, 10L << 30);
        if (free >= need + reserve) return;
        var from = string.Join(", ", copies.Select(file => Path.GetPathRoot(file.Path)!.TrimEnd('\\')).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase));
        throw new CleanupSpaceException("There isn't enough free space on " + drive + (from.Length == 0 ? " for this cleanup's recovery record" : " to keep undo copies of the leftovers on " + from) +
            ". Cleanup needs " + Size(need) + " there and keeps " + Size(reserve) + " free for Windows, but " + drive + " has " + Size(free) + " free. Free up space on " + drive + " or pick fewer leftovers.");
    }

    private static string Size(long bytes) => bytes >= 1L << 30 ? (bytes / (double)(1L << 30)).ToString("0.0") + " GB" : Math.Max(1, (bytes + (1 << 20) - 1) >> 20) + " MB";

    [Conditional("GOVERNOR_TEST_HOOKS")]
    private void Checkpoint()
    {
        var reached = ++_checkpoints;
        CheckpointReached?.Invoke(reached);
        if (int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_FILE_CRASH_AT"), out var at) && reached == at) Process.GetCurrentProcess().Kill();
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
        if (journal.Entries.Any(entry => entry.Moved) && journal.Protection is not { File.Length: > 0, Directory.Length: > 0 })
            throw new InvalidDataException("The journal doesn't have the undo folder's permissions.");
        foreach (var entry in journal.Entries)
        {
            if (entry.Status is not ("pending" or "backedUp" or "deleteIntent" or "deleted" or "restoreIntent" or "restored"))
                throw new InvalidDataException("Unknown file recovery state.");
            var reviewed = original.Files.SingleOrDefault(file => file.Path == entry.Original.Path);
            if (reviewed is null || JsonSerializer.Serialize(reviewed, OperationFiles.Json) != JsonSerializer.Serialize(entry.Original, OperationFiles.Json))
                throw new InvalidDataException("A recovery entry changed its original file binding.");
            if (original.Roots.Any(root => Within(entry.BackupPath, root))) throw new InvalidDataException("Backup data overlaps a deletion target.");
            if (entry.Moved && !string.Equals(Path.GetDirectoryName(entry.BackupPath), Path.GetDirectoryName(Path.GetFullPath(path)), StringComparison.OrdinalIgnoreCase) ||
                !Path.GetFileName(entry.BackupPath).StartsWith(BackupPrefix, StringComparison.Ordinal) || !Guid.TryParseExact(Path.GetFileName(entry.BackupPath)[BackupPrefix.Length..], "N", out _))
                throw new InvalidDataException("An undo copy is outside its cleanup's recovery folder.");
            if (entry.RestoreStagingPath is not null && (!string.Equals(Path.GetDirectoryName(entry.RestoreStagingPath), Path.GetDirectoryName(entry.Original.Path), StringComparison.OrdinalIgnoreCase) ||
                !BrandCompatibility.IsRestoreStage(Path.GetFileName(entry.RestoreStagingPath))))
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
        var protectedRoots = new[] { Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.ProgramFiles,
            Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.CommonProgramFiles, Environment.SpecialFolder.CommonProgramFilesX86,
            Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.StartMenu,
            Environment.SpecialFolder.Programs, Environment.SpecialFolder.Startup, Environment.SpecialFolder.CommonStartMenu,
            Environment.SpecialFolder.CommonPrograms, Environment.SpecialFolder.CommonStartup }
            .Select(Environment.GetFolderPath).Where(root => !string.IsNullOrWhiteSpace(root)).ToList();
        var local = RuntimeEnvironment.LocalAppData;
        protectedRoots.AddRange([Path.GetTempPath().TrimEnd('\\'), RuntimeEnvironment.UserTemp, local, RuntimeEnvironment.RoamingAppData, Path.GetDirectoryName(local)!, Path.Combine(local, "Packages"),
            Path.Combine(RuntimeEnvironment.Profile, "AppData", "LocalLow")]);
        var roots = protectedRoots.SelectMany(root => new CleanupPath(root).Forms).ToArray();
        var windows = new CleanupPath(Environment.GetFolderPath(Environment.SpecialFolder.Windows)).Forms;
        var packages = new CleanupPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps")).Forms;
        return new CleanupPath(path).Forms.Any(form => roots.Any(root => CleanupPath.Within(root, form)) || windows.Concat(packages).Any(root => CleanupPath.Within(form, root)) ||
            CleanupPath.Within(form, Path.Combine(Path.GetPathRoot(form)!, "WindowsApps")));
    }

    private static bool Within(string path, string root) => string.Equals(path, root, StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    private static int Depth(string path) => path.Count(character => character == '\\');
    private static void Save(string path, FileCleanupJournal journal) { journal.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, journal); }

    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetDiskFreeSpace(string root, out uint sectorsPerCluster, out uint bytesPerSector, out uint freeClusters, out uint totalClusters);
    [DllImport("kernel32.dll", EntryPoint = "GetVolumePathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumePathName(string path, StringBuilder volume, uint length);
    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetDiskFreeSpaceEx(string directory, out ulong freeBytesAvailable, out ulong totalBytes, out ulong totalFreeBytes);
}
