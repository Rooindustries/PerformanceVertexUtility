#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class CleanupSpaceException(string message) : IOException(message);

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
                Original = file, BackupPath = Path.Combine(directory, BackupPrefix + Guid.NewGuid().ToString("N")), Status = "pending",
            }).ToList(),
        };
        var held = new Dictionary<string, FileLease>(StringComparer.OrdinalIgnoreCase);
        FileLease? storeFolder = null;
        try
        {
            var store = StoreVolume(directory);
            foreach (var entry in journal.Entries)
            {
                var file = entry.Original;
                var source = Hold(file, store, out var moved);
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
            // The journal grows as entries finish and is written beside its previous copy, so its room is kept even when every leftover moves.
            var record = Allocated(2 * JsonSerializer.SerializeToUtf8Bytes(journal, OperationFiles.Json).LongLength, cluster);
            RequireFree(directory, remaining + verify + record, copies.Select(entry => entry.Original));
            var protection = journal.Entries.Any(entry => entry.Moved) ? StoreProtection(directory) : default;
            Save(journalPath, journal);
            Checkpoint();
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
            currentAuthority().Verify(preview.AppId, preview.ProviderIdentityHash);
            if (journal.Entries.Any(entry => entry.Moved))
            {
                storeFolder = FileLease.OpenFolder(directory);
                if (storeFolder.ObjectIdentity.Volume != store) throw new InvalidDataException("The recovery folder moved to another drive during cleanup.");
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
                    source.ReplaceDacl(entry.Original.Directory ? protection.Directory! : protection.File!);
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
        catch (Exception error) when (error is not CleanupSpaceException || File.Exists(journalPath))
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
        finally
        {
            foreach (var source in held.Values) source.Dispose();
            storeFolder?.Dispose();
        }
        return journal;
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
        var directories = new Dictionary<string, (FileIdentity Identity, bool Own)>(StringComparer.OrdinalIgnoreCase);
        var staged = new List<(FileBackupEntry Entry, FileLease Staging)>();
        try
        {
            foreach (var entry in journal.Entries.Where(entry => entry.Status is "deleted" or "deleteIntent" or "restoreIntent" or "restored").OrderBy(entry => Depth(entry.Original.Path)))
            {
                try
                {
                    // A finished entry belongs to the user again; anything changed on it since is theirs.
                    if (Finished(entry)) { entry.LeftAsChanged = ChangedSinceRestore(entry) ? LeftAsIs : null; continue; }
                    FileLease? existing = null;
                    try { existing = FileLease.Open(entry.Original.Path); }
                    catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { }
                    if (existing is not null)
                    {
                        using (existing)
                        {
                            var current = existing.Capture();
                            if (current.Identity == entry.Original.Identity)
                            {
                                if (DataChanged(entry.Original, current) || !entry.Moved && !entry.Original.SameRestorableData(current with { LastWriteTime = entry.Original.LastWriteTime }))
                                    throw new InvalidDataException("New or changed data occupies the restore destination.");
                                if (entry.Original.Directory) directories[entry.Original.Path] = (current.Identity, true);
                                else if (!entry.Original.SameRestorableData(current))
                                {
                                    existing.Dispose();
                                    using var own = FileLease.OpenForMove(entry.Original.Path);
                                    if (own.ObjectIdentity != entry.Original.Identity) throw new InvalidDataException("New or changed data occupies the restore destination.");
                                    own.RestoreMoved(entry.Original);
                                    if (!entry.Original.SameRestorableData(own.Capture())) throw new InvalidDataException("Restored file permissions differ from the backup.");
                                }
                            }
                            else if (!entry.Original.Directory && entry.RestoredIdentity == current.Identity)
                            {
                                // This restore's own copy, renamed into place before its attributes and times went back on.
                                if (ContentChanged(entry.Original, current)) throw new InvalidDataException("New or changed data occupies the restore destination.");
                                existing.Dispose();
                                FinishCopy(entry, current);
                            }
                            else
                            {
                                var unfinishedDirectory = entry.Original.Directory && !entry.DirectoryMetadataRestored && entry.RestoredIdentity == current.Identity;
                                var compared = unfinishedDirectory ? current with { LastWriteTime = entry.Original.LastWriteTime } : current;
                                if (!entry.Original.SameRestorableData(compared)) throw new InvalidDataException("New or changed data occupies the restore destination.");
                                if (unfinishedDirectory || entry.Original.Directory && entry.Status == "restoreIntent" && entry.RestoredIdentity is null)
                                {
                                    entry.RestoredIdentity = current.Identity;
                                    directories[entry.Original.Path] = (current.Identity, false);
                                }
                                else if (entry.Original.Directory) entry.DirectoryMetadataRestored = true;
                            }
                        }
                        entry.Status = "restored";
                        entry.Error = null;
                        continue;
                    }
                    if (entry.Moved) RestoreMovedEntry(entry, directories);
                    else if (entry.Original.Directory)
                    {
                        if (entry.BackupHash is null || OperationFiles.HashFile(entry.BackupPath) != entry.BackupHash) throw new InvalidDataException("The file backup is missing or changed.");
                        entry.Status = "restoreIntent";
                        Save(journalPath, journal);
                        using var restored = FileLease.Create(entry.Original.Path, true);
                        restored.RestoreData(entry.BackupPath, entry.Original);
                        var snapshot = restored.Capture();
                        if (!entry.Original.SameRestorableData(snapshot)) throw new InvalidDataException("Restored directory data or permissions differ from the backup.");
                        directories[entry.Original.Path] = (snapshot.Identity, false);
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
                var (identity, own) = directories[entry.Original.Path];
                string[] differences;
                using (var probe = FileLease.Open(entry.Original.Path)) differences = entry.Original.Differences(probe.Capture());
                var timesOnly = differences.All(difference => difference is "attributes" or "creation time" or "last-write time");
                using var directory = differences.Length == 0 ? FileLease.Open(entry.Original.Path) : timesOnly ? FileLease.OpenForTimes(entry.Original.Path)
                    : own ? FileLease.OpenForMove(entry.Original.Path) : FileLease.OpenForRestore(entry.Original.Path);
                var children = journal.Preview.Files.Where(file => string.Equals(Path.GetDirectoryName(file.Path), entry.Original.Path, StringComparison.OrdinalIgnoreCase)).Select(file => file.Path).Order(StringComparer.OrdinalIgnoreCase);
                if (directory.Capture().Identity != identity || !directory.Children().SequenceEqual(children, StringComparer.OrdinalIgnoreCase))
                    throw new InvalidDataException("Directory contents changed during restoration; metadata was left unchanged.");
                if (journal.Entries.Any(child => child.Original.Path != entry.Original.Path && Within(child.Original.Path, entry.Original.Path) && (child.Status != "restored" || child.Error is not null)))
                    throw new InvalidDataException("A directory still has unresolved child data; its metadata was left unchanged.");
                if (!timesOnly) { if (own) directory.RestoreMoved(entry.Original); else directory.RestoreMetadata(entry.Original); }
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

    private const string LeftAsIs = "This changed after it was put back, so it was left as is.";

    private static bool Finished(FileBackupEntry entry) => entry.Status == "restored" && entry.Error is null && (!entry.Original.Directory || entry.DirectoryMetadataRestored);

    private static bool ChangedSinceRestore(FileBackupEntry entry)
    {
        try { using var probe = FileLease.Open(entry.Original.Path); return !entry.Original.SameRestorableData(probe.Capture()); }
        catch (Exception error) when (error is Win32Exception or InvalidDataException) { return true; }
    }

    private void RestoreMovedEntry(FileBackupEntry entry, Dictionary<string, (FileIdentity Identity, bool Own)> directories)
    {
        FileLease stored;
        try { stored = FileLease.OpenForMove(entry.BackupPath); }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { throw new InvalidDataException("The undo copy is missing."); }
        using (stored)
        {
            var copy = stored.Capture();
            if (copy.Identity != entry.Original.Identity || DataChanged(entry.Original, copy) || entry.Original.Directory && stored.Children().Length != 0)
                throw new InvalidDataException("The undo copy changed after cleanup.");
            // The destination folder and every folder above it stay open through the rename, so none of them can be swapped for a junction.
            using (var folder = FileLease.OpenFolder(Path.GetDirectoryName(entry.Original.Path)!))
            {
                Checkpoint();
                stored.RenameInto(folder, Path.GetFileName(entry.Original.Path));
            }
            Checkpoint();
            stored.RestoreMoved(entry.Original);
            if (entry.Original.Directory) directories[entry.Original.Path] = (copy.Identity, true);
            else if (!entry.Original.SameRestorableData(stored.Capture())) throw new InvalidDataException("Restored file data or permissions differ from the backup.");
        }
    }

    private static bool DataChanged(FileSnapshot original, FileSnapshot current)
        => original.Differences(current).Except(original.Directory ? ["permissions", "attributes", "last-write time"] : ["permissions", "attributes"]).Any();

    private static bool ContentChanged(FileSnapshot original, FileSnapshot current)
        => original.Differences(current).Except(["permissions", "attributes", "creation time", "last-write time"]).Any();

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

    // Writes a copied leftover to its staging name beside the destination. The staging name comes from the undo copy's own name,
    // so a staging file found there is this cleanup's: a complete one is kept and an unfinished one is replaced.
    // The staging lease stays open until the rename, so a copy whose restored permissions don't let the app reopen it still goes back.
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
                if (snapshot.Directory) throw new InvalidDataException("A folder occupies this restore's staging name.");
                if (entry.Original.SameRestorableData(snapshot))
                {
                    entry.RestoredIdentity = snapshot.Identity;
                    entry.Status = "restoreIntent";
                    kept = true;
                    return found;
                }
                found.MarkDelete();
            }
            finally { if (!kept) found.Dispose(); }
        }
        var staging = FileLease.Create(entry.RestoreStagingPath, false);
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
        finally
        {
            if (!done)
            {
                try { staging.MarkDelete(); }
                finally { staging.Dispose(); }
            }
        }
    }

    private void PlaceCopy(FileBackupEntry entry, FileLease staging)
    {
        if (staging.ObjectIdentity != entry.RestoredIdentity) throw new InvalidDataException("An unfinished restore file was replaced before it was put back.");
        staging.RenameToSibling(Path.GetFileName(entry.Original.Path));
        Checkpoint();
        // Windows marks a renamed file for archiving, so the reviewed attributes and times go back on after the rename.
        staging.RestoreTimes(entry.Original);
        if (!entry.Original.SameRestorableData(staging.Capture())) throw new InvalidDataException("Restored file data or permissions differ from the backup.");
        entry.RestoreStagingPath = null;
    }

    // Finishes a copy that took the leftover's name before its metadata went back on, asking only for the rights that needs.
    private static void FinishCopy(FileBackupEntry entry, FileSnapshot current)
    {
        entry.RestoreStagingPath = null;
        if (entry.Original.SameRestorableData(current)) return;
        var permissions = entry.Original.Differences(current).Contains("permissions");
        using var own = permissions ? FileLease.OpenForRestore(entry.Original.Path) : FileLease.OpenForTimes(entry.Original.Path);
        if (own.ObjectIdentity != entry.RestoredIdentity) throw new InvalidDataException("New or changed data occupies the restore destination.");
        if (permissions) own.RestoreMetadata(entry.Original);
        else own.RestoreTimes(entry.Original);
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

    // The folder a volume is reached through: a drive letter, a subst drive or a mounted folder.
    private static string VolumePath(string directory)
    {
        var path = new StringBuilder(32768);
        if (!GetVolumePathName(Existing(directory), path, (uint)path.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not find the drive of " + directory);
        return path.ToString();
    }

    private static (byte[] File, byte[] Directory) StoreProtection(string directory)
    {
        return (Probe(false), Probe(true));
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
        // Recovery folders reached through different letters, subst drives or mounted folders share one budget when they are on one volume.
        foreach (var store in parts.Select(part => (part.Plan, Directory: Existing(Path.GetDirectoryName(Path.GetFullPath(part.JournalPath))!))).GroupBy(part => StoreVolume(part.Directory)))
        {
            var directory = store.First().Directory;
            var copies = store.SelectMany(part => part.Plan.Files.Where(file => Copied(file, store.Key))).ToArray();
            var cluster = Cluster(directory);
            RequireFree(directory, copies.Sum(file => Allocated(BackupBytes(file), cluster)) + (copies.Length == 0 ? 0 : Allocated(copies.Max(DataBytes), cluster)) +
                store.Sum(part => Allocated(4 * JsonSerializer.SerializeToUtf8Bytes(part.Plan, OperationFiles.Json).LongLength, cluster)), copies);
        }
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
