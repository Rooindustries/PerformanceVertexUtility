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
    // Undo copies Windows deletes when they close, so a refusal, or a stop before the journal records them, leaves none behind.
    internal List<FileLease> Copies { get; } = new();

    public void Dispose()
    {
        foreach (var source in Held.Values) source.Dispose();
        foreach (var copy in Copies) copy.Dispose();
        Held.Clear();
        Copies.Clear();
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
    // Nothing it does outlasts a refusal or a stop: the copies are unkept and the journal isn't written yet, so the cleanup can run again from its review.
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
                if (!Unstarted(saved)) return new(lease, journalPath, saved, resumed: true);
                // An earlier run stopped before deleting anything. The undo copies it kept go first, and one it can't remove refuses this run
                // before any other part of the cleanup changes anything.
                var kept = Settle(saved);
                if (kept.Length != 0) { Save(journalPath, saved); throw new IOException(string.Join(" ", kept)); }
                File.Delete(journalPath);
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
            // Each leftover is held with the access deleting it needs, so one another program has open without letting it be deleted is
            // refused here rather than after the app's other parts have run.
            try { source = Hold(file, hold.Store, preview.Roots.First(root => Within(file.Path, root)), out moved); }
            catch (Win32Exception error) when (error.NativeErrorCode == 32) { throw new IOException(file.Path + " is open in another program. Close it, then run cleanup again."); }
            held.Add(file.Path, source);
            entry.Moved = moved;
            if (!file.SameObjectAndContent(source.Capture())) throw new InvalidDataException("A file changed after review: " + file.Path);
            if (file.Directory)
            {
                var expected = preview.Files.Where(child => string.Equals(Path.GetDirectoryName(child.Path), file.Path, StringComparison.OrdinalIgnoreCase)).Select(child => child.Path).Order(StringComparer.OrdinalIgnoreCase);
                if (!source.Children().SequenceEqual(expected, StringComparer.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed folder " + file.Path + " gained or lost an entry.");
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
        Checkpoint();
        for (var index = 0; index < copies.Count; index++)
        {
            var entry = copies[index];
            RequireFree(directory, remaining + verify + record, copies.Skip(index).Select(copy => copy.Original));
            remaining -= sizes[index];
            var source = held[entry.Original.Path];
            // Unkept until Apply has saved its identity and hash in the journal, so a stop before then leaves no copy that nothing records.
            var copy = FileLease.CreateUnkept(entry.BackupPath);
            hold.Copies.Add(copy);
            entry.BackupHash = source.Backup(copy);
            entry.BackupIdentity = copy.ObjectIdentity;
            VerifyBackup(entry, copy, directory);
            if (!entry.Original.SameObjectAndContent(source.Capture())) throw new InvalidDataException("A file changed while its undo copy was made: " + entry.Original.Path);
            entry.Status = "backedUp";
            Checkpoint();
        }
    }

    public FileCleanupJournal Apply(FileCleanupHold hold)
    {
        var (journal, journalPath, held) = (hold.Journal, hold.JournalPath, hold.Held);
        if (hold.Resumed) return ReconcileApplied(journalPath, journal);
        var preview = journal.Preview;
        currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
        using var storeFolder = journal.Entries.Any(entry => entry.Moved) ? FileLease.OpenFolder(Path.GetDirectoryName(Path.GetFullPath(journalPath))!) : null;
        if (storeFolder is not null && storeFolder.ObjectIdentity.Volume != hold.Store) throw new InvalidDataException("The recovery folder moved to another drive during cleanup.");
        // The journal's first write records every undo copy's identity and hash and the undo folder's permissions, before cleanup keeps a
        // copy or changes a leftover, so recovery only ever acts on what it records.
        journal.Status = "deleting";
        Save(journalPath, journal);
        Checkpoint();
        try
        {
            foreach (var copy in hold.Copies) copy.Keep();
            Checkpoint();
            foreach (var entry in journal.Entries.OrderByDescending(entry => Depth(entry.Original.Path)))
            {
                var source = held[entry.Original.Path];
                if (entry.Original.Directory && source.Children().Length != 0) throw new InvalidDataException(entry.Original.Path + " has entries that weren't reviewed, so it was left in place.");
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
        }
        catch (Exception error)
        {
            journal.Status = "needsReconciliation";
            var active = journal.Entries.FirstOrDefault(entry => entry.Status == "deleteIntent") ?? journal.Entries.First();
            active.Error = Named(active.Original.Path, error.Message);
            if (journal.Entries.All(entry => entry.Status is "pending" or "backedUp"))
            {
                // Nothing was deleted, so the undo copies it kept are its only change; with them removed the cleanup never started.
                foreach (var copy in hold.Copies) copy.Dispose();
                hold.Copies.Clear();
                if (Settle(journal).Length == 0) journal.Status = "notStarted";
            }
        }
        finally
        {
            foreach (var copy in hold.Copies) copy.Dispose();
            hold.Copies.Clear();
        }
        Save(journalPath, journal);
        return journal;
    }

    // Cleanup stopped or was refused before it deleted anything, so the only things it may have left are the undo copies it recorded.
    private static bool Unstarted(FileCleanupJournal journal)
        => journal.Status == "notStarted" || journal.Status == "needsReconciliation" && journal.Entries.All(entry => entry.Status is "pending" or "backedUp");

    // Removes the undo copies a cleanup that deleted nothing kept, each only while it's still exactly the copy cleanup made. Anything else
    // there is left as is. Returns what it left, each naming its path.
    private static string[] Settle(FileCleanupJournal journal)
    {
        var kept = new List<string>();
        foreach (var entry in journal.Entries.Where(entry => entry.BackupIdentity is not null))
        {
            var problem = RemoveCopy(entry);
            if (problem is not null) { entry.Error = problem; kept.Add(problem); continue; }
            entry.BackupIdentity = null;
            entry.BackupHash = null;
            entry.Status = "pending";
        }
        return kept.ToArray();
    }

    private static string? RemoveCopy(FileBackupEntry entry)
    {
        FileLease copy;
        try { copy = FileLease.Open(entry.BackupPath, writable: true); }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { return null; }
        catch (Win32Exception error) when (error.NativeErrorCode == 32) { return "The undo copy " + entry.BackupPath + " is open in another program, so it wasn't removed. Close it, then try again."; }
        catch (Exception error) when (error is Win32Exception or InvalidDataException) { return "The undo copy " + entry.BackupPath + " couldn't be checked, so it was left as is: " + error.Message; }
        using (copy)
        {
            if (copy.ObjectIdentity != entry.BackupIdentity || copy.HashData() != entry.BackupHash)
                return entry.BackupPath + " changed after cleanup made it as an undo copy, so it was left as is.";
            copy.MarkDelete();
            return null;
        }
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
        if (Unstarted(journal))
        {
            // Cleanup never deleted anything, so nothing needs putting back; only the undo copies it kept are removed.
            journal.Status = Settle(journal).Length == 0 ? "notStarted" : "needsReconciliation";
            Save(journalPath, journal);
            return journal;
        }
        if (journal.Status == "deleting")
            foreach (var entry in journal.Entries.Where(entry => entry.Status is "pending" or "backedUp")) entry.Status = "deleteIntent";
        var work = journal.Entries.Where(entry => entry.Status is "deleted" or "deleteIntent" or "restoreIntent" or "restored").ToArray();
        if (work.Length == 0) return journal;
        if (Mark(journal, work))
        {
            Save(journalPath, journal);
            Checkpoint();
        }
        var conflicts = false;
        var directories = new Dictionary<string, FileIdentity>(StringComparer.OrdinalIgnoreCase);
        // Level by level, so each leftover's folder is back before it is.
        foreach (var level in work.GroupBy(entry => Depth(entry.Original.Path)).OrderBy(level => level.Key))
        {
            var made = new List<(FileBackupEntry Entry, FileLease Copy)>();
            try
            {
                foreach (var entry in level)
                {
                    try
                    {
                        // A finished entry belongs to the user again; anything changed on it since is theirs.
                        if (Finished(entry)) { entry.LeftAsChanged = ChangedSinceRestore(entry) switch { true => LeftAsIs, false => null, null => entry.LeftAsChanged }; continue; }
                        entry.LeftAsChanged = null;
                        FileLease? existing = null;
                        try { existing = FileLease.Open(entry.Original.Path); }
                        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
                        if (existing is not null) using (existing) Reconcile(journal, entry, existing, directories);
                        else if (entry.Moved) RestoreMovedEntry(journal, entry, directories);
                        else
                        {
                            if (entry.BackupHash is null || OperationFiles.HashFile(entry.BackupPath) != entry.BackupHash) throw new InvalidDataException("Its undo copy is missing or changed, so it wasn't put back.");
                            made.Add((entry, entry.Original.Directory ? MakeFolder(entry) : StageCopy(entry)));
                            Checkpoint();
                            continue;
                        }
                        entry.Status = "restored";
                        entry.Error = null;
                        Checkpoint();
                    }
                    catch (Exception error) { entry.Error = Named(entry.Original.Path, Plain(error)); conflicts = true; }
                }
                if (made.Count == 0) continue;
                // Each copy's identity is saved before it's kept under the leftover's name, so a retry after a stop knows the one there as its own.
                Save(journalPath, journal);
                Checkpoint();
                foreach (var (entry, copy) in made)
                {
                    try
                    {
                        if (entry.Original.Directory)
                        {
                            copy.Keep();
                            directories[entry.Original.Path] = entry.RestoredIdentity!;
                        }
                        else PlaceCopy(entry, copy);
                        entry.Status = "restored";
                        entry.Error = null;
                        Checkpoint();
                    }
                    catch (Exception error) { entry.Error = Named(entry.Original.Path, Plain(error)); conflicts = true; }
                }
            }
            finally { foreach (var (_, copy) in made) copy.Dispose(); }
        }
        foreach (var entry in journal.Entries.Where(entry => directories.ContainsKey(entry.Original.Path)).OrderByDescending(entry => Depth(entry.Original.Path)))
        {
            try
            {
                var identity = directories[entry.Original.Path];
                FileSnapshot found;
                using (var probe = FileLease.Open(entry.Original.Path)) found = probe.Capture();
                if (found.Identity == identity && !Recorded(journal, entry, found))
                {
                    entry.LeftAsChanged = LeftAsIs;
                    entry.DirectoryMetadataRestored = true;
                    entry.Error = null;
                    continue;
                }
                // Only a moved folder still has the undo folder's permissions; anything else left to put back is its attributes and times.
                var differences = entry.Original.Differences(found);
                var timesOnly = differences.All(difference => difference is "attributes" or "creation time" or "last-write time");
                if (!timesOnly && !entry.PermissionsBack) throw new IOException(Unchecked);
                using var directory = differences.Length == 0 ? FileLease.Open(entry.Original.Path) : timesOnly ? FileLease.OpenForTimes(entry.Original.Path) : FileLease.OpenForMove(entry.Original.Path);
                var children = journal.Preview.Files.Where(file => string.Equals(Path.GetDirectoryName(file.Path), entry.Original.Path, StringComparison.OrdinalIgnoreCase)).Select(file => file.Path).Order(StringComparer.OrdinalIgnoreCase);
                var current = directory.Capture();
                if (journal.Entries.Any(child => child.Original.Path != entry.Original.Path && Within(child.Original.Path, entry.Original.Path) && (child.Status != "restored" || child.Error is not null)))
                    throw new InvalidDataException("Something inside the folder wasn't put back, so its attributes, times and permissions were left as they are.");
                if (current.Identity != identity || !directory.Children().SequenceEqual(children, StringComparer.OrdinalIgnoreCase) || !Recorded(journal, entry, current))
                    throw new InvalidDataException("The folder changed while it was being put back, so its attributes, times and permissions were left as they are.");
                if (!timesOnly) directory.RestoreMoved(entry.Original, () => Checkpoint());
                else if (differences.Length != 0) directory.RestoreTimes(entry.Original);
                if (!entry.Original.SameRestorableData(directory.Capture())) throw new InvalidDataException("Restored directory metadata differs from the backup.");
                entry.DirectoryMetadataRestored = true;
                entry.Error = null;
                Checkpoint();
            }
            catch (Exception error) { entry.Error = Named(entry.Original.Path, Plain(error)); conflicts = true; }
        }
        journal.Status = conflicts ? "needsReconciliation" : "restored";
        Save(journalPath, journal);
        return journal;
    }

    private const string LeftAsIs = "This was changed after cleanup, so it was left as is.";
    private const string Unchecked = "Restore couldn't check this before it started, so it wasn't changed. Press Restore again.";
    private const uint Archive = 0x20, Normal = 0x80;

    private static bool Finished(FileBackupEntry entry) => entry.Status == "restored" && entry.Error is null && (!entry.Original.Directory || entry.DirectoryMetadataRestored);

    // An error that names the leftover it's about, so the cleanup page can say which one.
    private static string Named(string path, string message) => message.Contains(path, StringComparison.OrdinalIgnoreCase) ? message : path + ": " + message;

    // Windows' own message for a file another program has open is a raw status code, so that one is said in plain words.
    private static string Plain(Exception error) => error is Win32Exception { NativeErrorCode: 32 }
        ? "It or its undo copy is open in another program, so it wasn't put back. Close it, then restore again." : error.Message;

    // Before Restore moves anything back or puts any permissions back, the journal records which leftovers it may do that to. After a stop,
    // the archive flag those writes add and the first of the two permission writes are accepted as Restore's own on those leftovers alone.
    private static bool Mark(FileCleanupJournal journal, FileBackupEntry[] work)
    {
        var marked = false;
        foreach (var entry in work.Where(entry => entry.Moved && !Finished(entry)))
        {
            FileSnapshot? found = null;
            try { using var probe = FileLease.Open(entry.Original.Path); found = probe.Capture(); }
            catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
            catch (Exception error) when (error is Win32Exception or InvalidDataException) { continue; }
            if (found is null)
            {
                marked |= !entry.PermissionsBack;
                entry.PermissionsBack = true;
            }
            else if (!entry.PermissionsBack && found.Identity == entry.Original.Identity && !entry.Original.SameRestorableData(found) && Recorded(journal, entry, found))
            {
                entry.PermissionsBack = true;
                marked = true;
            }
        }
        return marked;
    }

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
    private void Reconcile(FileCleanupJournal journal, FileBackupEntry entry, FileLease existing, Dictionary<string, FileIdentity> directories)
    {
        var original = entry.Original;
        var current = existing.Capture();
        if (current.Identity == original.Identity)
        {
            // The leftover itself: cleanup never deleted it, or an earlier restore moved it back before its own permissions went back on.
            if (!Recorded(journal, entry, current)) { entry.LeftAsChanged = LeftAsIs; return; }
            if (original.Directory) { directories[original.Path] = current.Identity; return; }
            if (original.SameRestorableData(current)) return;
            if (!entry.PermissionsBack) throw new IOException(Unchecked);
            existing.Dispose();
            using var own = FileLease.OpenForMove(original.Path);
            var held = own.Capture();
            if (held.Identity != original.Identity || !Recorded(journal, entry, held)) throw new InvalidDataException("This file changed while it was being put back, so it was left as is.");
            own.RestoreMoved(original, () => Checkpoint());
            if (!original.SameRestorableData(own.Capture())) throw new InvalidDataException("Restored file permissions differ from the backup.");
            return;
        }
        if (current.Identity == entry.RestoredIdentity)
        {
            // This restore's own copy, kept under the leftover's name before its attributes and times went back on.
            entry.RestoreStagingPath = null;
            if (!Recorded(original, current, !original.Directory, null)) { entry.LeftAsChanged = LeftAsIs; return; }
            if (original.Directory) directories[original.Path] = current.Identity;
            else if (!original.SameRestorableData(current)) { existing.Dispose(); FinishCopy(entry); }
            return;
        }
        if (original.SameRestorableData(current)) { if (original.Directory) entry.DirectoryMetadataRestored = true; return; }
        // The moved leftover isn't in the undo folder, so it was never moved or was put back, and someone replaced it since.
        if (entry.Moved && !Path.Exists(entry.BackupPath)) { entry.LeftAsChanged = LeftAsIs; return; }
        throw new InvalidDataException("Something else is there now, so it was left as is and the leftover wasn't put back.");
    }

    // The states cleanup itself leaves a leftover in, each accepted only where the journal shows cleanup could have made it: the reviewed
    // state; for a leftover set to move, the undo folder's permissions it takes just before the move; once Restore has recorded it may put
    // a leftover's permissions back, the first of the two writes that restore inherited permissions; and the archive flag Windows sets,
    // replacing a plain "normal" flag, when a renamed copy takes its place or cleanup changes a leftover's permissions. A folder's last-write
    // time follows the entries moved in and out of it and goes back last.
    private static bool Recorded(FileCleanupJournal journal, FileBackupEntry entry, FileSnapshot current)
        => Recorded(entry.Original, current, false, entry.Moved ? Protection(journal, entry.Original) : null, entry.PermissionsBack);

    private static bool Recorded(FileSnapshot original, FileSnapshot current, bool renamed, byte[]? protection, bool restoring = false)
    {
        var differences = original.Differences(current).ToList();
        if (original.Directory) differences.Remove("last-write time");
        var held = protection is not null && SameDacl(original, current, new RawSecurityDescriptor(protection, 0));
        if (held || restoring && Halfway(original, current)) differences.Remove("permissions");
        if ((renamed || held || restoring) && current.Attributes == ((original.Attributes & ~Normal) | Archive)) differences.Remove("attributes");
        return differences.Count == 0;
    }

    // The permissions between the two writes that restore inherited ones: the leftover's own list, not yet marked inherited.
    private static bool Halfway(FileSnapshot original, FileSnapshot current)
    {
        var before = new RawSecurityDescriptor(original.Security, 0);
        if ((before.ControlFlags & ControlFlags.DiscretionaryAclAutoInherited) == 0) return false;
        var written = new RawSecurityDescriptor(before.ControlFlags & ~ControlFlags.DiscretionaryAclAutoInherited, null, null, null, before.DiscretionaryAcl);
        return SameDacl(original, current, written);
    }

    // True when the object keeps its own owner and group and has exactly this permission list and inheritance, as cleanup set it.
    private static bool SameDacl(FileSnapshot original, FileSnapshot current, RawSecurityDescriptor expected)
    {
        const ControlFlags inheritance = ControlFlags.DiscretionaryAclProtected | ControlFlags.DiscretionaryAclAutoInherited;
        var now = new RawSecurityDescriptor(current.Security, 0);
        var before = new RawSecurityDescriptor(original.Security, 0);
        return now.Owner == before.Owner && now.Group == before.Group && (now.ControlFlags & inheritance) == (expected.ControlFlags & inheritance) && Acl(now).SequenceEqual(Acl(expected));
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
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { throw new InvalidDataException("Its undo copy is missing, so it wasn't put back."); }
        using (stored)
        {
            var copy = stored.Capture();
            if (copy.Identity != entry.Original.Identity || !Recorded(entry.Original, copy, true, Protection(journal, entry.Original)) || entry.Original.Directory && stored.Children().Length != 0)
                throw new InvalidDataException("Its undo copy changed after cleanup, so it wasn't put back.");
            if (!entry.PermissionsBack) throw new IOException(Unchecked);
            // The destination folder and every folder above it stay open through the rename, so none of them can be swapped for a junction.
            using (var folder = FileLease.OpenFolder(Path.GetDirectoryName(entry.Original.Path)!))
            {
                Checkpoint();
                stored.RenameInto(folder, Path.GetFileName(entry.Original.Path));
            }
            Checkpoint();
            stored.RestoreMoved(entry.Original, () => Checkpoint());
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

    // Makes a copied folder unkept at its own path, so Windows removes it if Restore stops before the journal has its identity.
    private static FileLease MakeFolder(FileBackupEntry entry)
    {
        var folder = FileLease.CreateUnkept(entry.Original.Path, directory: true);
        var done = false;
        try
        {
            folder.RestoreData(entry.BackupPath, entry.Original);
            var snapshot = folder.Capture();
            if (!entry.Original.SameRestorableData(snapshot)) throw new InvalidDataException("Restored directory data or permissions differ from the backup.");
            entry.RestoredIdentity = snapshot.Identity;
            entry.DirectoryMetadataRestored = false;
            entry.Status = "restoreIntent";
            done = true;
            return folder;
        }
        finally { if (!done) folder.Dispose(); }
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

    private static void VerifyBackup(FileBackupEntry entry, FileLease copy, string directory)
    {
        var path = Path.Combine(directory, "verify-" + Guid.NewGuid().ToString("N"));
        using var restored = FileLease.Create(path, entry.Original.Directory);
        try
        {
            restored.RestoreData(copy, entry.Original);
            var readback = restored.Capture();
            var differences = entry.Original.Differences(readback);
            if (differences.Length != 0) throw new InvalidDataException("Backup verification differs in " + string.Join(", ", differences) + ".");
        }
        finally { restored.MarkDelete(); }
    }

    private static FileLease Hold(FileSnapshot file, ulong store, string root, out bool moved)
    {
        var lease = MoveLease(file, store, root);
        moved = lease is not null;
        return lease ?? FileLease.Open(file.Path, writable: true, within: root);
    }

    private static FileLease? MoveLease(FileSnapshot file, ulong store, string? root = null)
    {
        if (file.Identity.Volume != store || new RawSecurityDescriptor(file.Security, 0).DiscretionaryAcl is null) return null;
        try { return FileLease.OpenForMove(file.Path, root); }
        catch (Win32Exception error) when (error.NativeErrorCode == 5) { return null; }
    }


    private static bool Copied(FileSnapshot file, ulong store)
    {
        // A missing or locked entry isn't counted here; cleanup refuses it when it holds every entry.
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
    // itself: every entry with an undo copy, its hash and identity, a staging name, a restored identity, an error, a left-as-is note and
    // Restore's records, plus the undo folder's permissions at their largest. Each save writes the new journal beside the old one before replacing it, so both fit at once.
    private static long JournalBytes(FileCleanupPreview plan, string journalPath, long cluster)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(journalPath))!;
        var largest = new FileCleanupJournal
        {
            SchemaVersion = 1, PreviewPath = Path.GetFullPath(journalPath), ReviewHash = new string('0', 64), Preview = plan, Status = "needsReconciliation",
            UpdatedAtUtc = DateTime.MaxValue, Protection = new(new byte[ushort.MaxValue], new byte[ushort.MaxValue]),
            Entries = plan.Files.Select(file => new FileBackupEntry
            {
                Original = file, BackupPath = Path.Combine(directory, BackupPrefix + Guid.Empty.ToString("N")), Moved = true, BackupHash = new string('0', 64), BackupIdentity = file.Identity,
                Status = "restoreIntent", Error = new string('0', 1024) + file.Path, RestoredIdentity = file.Identity, DirectoryMetadataRestored = true, LeftAsChanged = LeftAsIs,
                PermissionsBack = true,
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
