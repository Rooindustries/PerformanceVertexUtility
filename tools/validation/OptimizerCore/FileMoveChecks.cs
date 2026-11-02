using System.Diagnostics;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class FileMoveChecks
{
    static readonly string User = WindowsIdentity.GetCurrent().User!.Value;
    static readonly string IdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("file move fixture"));

    static CleanupAuthority Authority() => new()
    {
        AppId = "fixture:file-move", ProviderIdentityHash = IdentityHash, Owner = OperationOwner.Current(),
        RegistrationPresent = false, ProviderQueryComplete = true, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
    };

    public static void Run(Action<bool, string> check, TestVolume volume)
    {
        var root = TestFixtures.InheritingRoot("file-move");
        var far = TestFixtures.InheritingFolder(Path.Combine(volume.Root, "roo-industries-file-move-" + Guid.NewGuid().ToString("N")));
        try
        {
            SameDrive(check, root);
            ProtectedStore(check, root);
            OtherDrive(check, root, far);
            LowSpace(check, root, volume, far);
            BatchLowSpace(check, root, far);
            LockedLowSpace(check, far);
            RetryAfterConflict(check, root);
            RetryKeepsLaterChanges(check, root, far);
            CopyStoppedAfterRename(check, root, far);
            MoveOnlyLowSpace(check, volume, far);
            OneVolumeTwoLetters(check, root, volume, far);
            JunctionSwaps(check, root);
            StagingKept(check, root, far);
            BudgetAgrees(check, volume, far);
            InUseRefusesApp(check, root);
            Crashes(check, root, far);
            Thousand(check, root);
        }
        finally
        {
            foreach (var folder in new[] { root, far }.Where(Directory.Exists))
            {
                foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
                Directory.Delete(folder, true);
            }
        }
        check(!Directory.Exists(root) && !Directory.Exists(far), "Move validation removes its fixtures, undo copies and journals on both drives");
    }

    public static void Child(string[] args)
    {
        var authority = Authority();
        var engine = new FileCleanupEngine(() => authority);
        var result = args is ["apply", var review, var hash, var journal] ? engine.Apply(review, hash, journal)
            : args is ["restore", var restoreJournal] ? engine.Restore(restoreJournal) : throw new ArgumentException("Unknown file crash step.");
        Console.WriteLine("completed " + result.Status);
    }

    static void SameDrive(Action<bool, string> check, string root)
    {
        const long big = 256L << 20;
        var app = Tree(Path.Combine(root, "same"), "App", exotic: true, big);
        var plan = Review(Path.Combine(root, "same", "Undo"), app);
        var drive = Path.GetPathRoot(plan.Journal)!;
        var before = new DriveInfo(drive).AvailableFreeSpace;
        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
        var used = before - new DriveInfo(drive).AvailableFreeSpace;
        Console.WriteLine("Same-drive cleanup of a " + (big >> 20) + " MB tree changed free space on " + drive + " by " + (used >> 20) + " MB");
        check(applied.Status == "applied" && !Directory.Exists(app) && applied.Entries.All(entry => SameObject(entry.BackupPath, entry.Original)),
            "Same-drive leftovers move into the undo folder as the same files and folders instead of being copied");
        check(used < big / 2, "Cleaning " + (big >> 20) + " MB of same-drive leftovers takes no extra space on that drive (" + (used >> 20) + " MB used)");
        var restored = plan.Engine.Restore(plan.Journal);
        var problems = Mismatches(plan.Plan, _ => true);
        foreach (var problem in problems) Console.WriteLine("  " + problem);
        check(restored.Status == "restored" && problems.Length == 0 && applied.Entries.All(entry => !Path.Exists(entry.BackupPath)),
            "Restore moves the same files back with their data, alternate streams, permissions (inherited, inherited from another folder, explicit-only and protected), attributes and times");
    }

    static void ProtectedStore(Action<bool, string> check, string root)
    {
        var app = Tree(Path.Combine(root, "protected"), "App", exotic: true);
        var store = Path.Combine(root, "protected", "Undo");
        Directory.CreateDirectory(store);
        RefusalChecks.SetSecurity(store, "O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;OW)(A;OICI;0x1200a9;;;" + User + ")", 1 | 4);
        check(PolicyRootSecurity.Problem(store, OperationsFolder.Kind, deep: true) is null, "The undo folder fixture starts as protected as the app's recovery folder");
        var plan = Review(store, app);
        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
        var problem = PolicyRootSecurity.Problem(store, OperationsFolder.Kind, deep: true);
        check(applied.Status == "applied" && problem is null,
            "Leftovers moved into the protected recovery folder take its admin-only permissions, so the folder stays protected (" + (problem ?? "still protected") + ")");
        var restored = plan.Engine.Restore(plan.Journal);
        var problems = Mismatches(plan.Plan, _ => true);
        foreach (var item in problems) Console.WriteLine("  " + item);
        check(restored.Status == "restored" && problems.Length == 0, "Restore from the protected recovery folder gives every moved leftover its own permissions back");
    }

    static void OtherDrive(Action<bool, string> check, string root, string far)
    {
        var remote = Tree(Path.Combine(far, "other"), "App", exotic: false);
        var local = Tree(Path.Combine(root, "mixed"), "Local", exotic: false);
        var plan = Review(Path.Combine(root, "mixed", "Undo"), remote, local);
        bool Far(string path) => path.StartsWith(Path.GetPathRoot(far)!, StringComparison.OrdinalIgnoreCase);
        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
        check(applied.Status == "applied" && !Directory.Exists(remote) && !Directory.Exists(local) &&
            applied.Entries.Where(entry => Far(entry.Original.Path)).All(entry => entry.BackupHash is not null && !SameObject(entry.BackupPath, entry.Original)) &&
            applied.Entries.Where(entry => !Far(entry.Original.Path)).All(entry => SameObject(entry.BackupPath, entry.Original)),
            "One cleanup copies the leftovers on another drive and moves the ones on the undo folder's drive");
        var restored = plan.Engine.Restore(plan.Journal);
        var problems = Mismatches(plan.Plan, file => !Far(file.Path));
        foreach (var problem in problems) Console.WriteLine("  " + problem);
        check(restored.Status == "restored" && problems.Length == 0, "Restore brings back copied leftovers on the other drive and moved ones on this drive exactly");
    }

    static void LowSpace(Action<bool, string> check, string root, TestVolume volume, string far)
    {
        var free = new DriveInfo(volume.Root).AvailableFreeSpace;
        var app = Tree(Path.Combine(root, "low"), "App", exotic: false, free / 2);
        var plan = Review(Path.Combine(far, "low", "Undo"), app);
        string? refusal = null;
        FileCleanupJournal? result = null;
        try { result = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal); }
        catch (IOException error) { refusal = error.Message; }
        Console.WriteLine("Low-space cleanup: " + (refusal ?? result?.Status + " " + string.Join(" | ", result!.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Error))));
        var after = new DriveInfo(volume.Root).AvailableFreeSpace;
        check(refusal is not null && refusal.Contains("enough free space on " + volume.Root.TrimEnd('\\'), StringComparison.Ordinal) && refusal.Contains(Path.GetPathRoot(app)!.TrimEnd('\\'), StringComparison.Ordinal),
            "A cleanup whose undo copies don't fit on the undo folder's drive with room to spare is refused and says which drives and how much space");
        check(!File.Exists(plan.Journal) && !Directory.EnumerateFileSystemEntries(Path.GetDirectoryName(plan.Journal)!, "file-backup-*").Any() && Math.Abs(free - after) < 64L << 20 && Mismatches(plan.Plan, _ => true).Length == 0,
            "The refusal comes before any change: no journal, no copies, the drive's free space and every leftover untouched");

        var hook = typeof(FileCleanupEngine).GetField("CheckpointReached", BindingFlags.NonPublic | BindingFlags.Static);
        var pair = Path.Combine(root, "shrinking", "App");
        Directory.CreateDirectory(pair);
        foreach (var name in new[] { "first.bin", "second.bin" })
            using (var stream = new FileStream(Path.Combine(pair, name), FileMode.CreateNew)) stream.SetLength(100L << 20);
        var shrinking = Review(Path.Combine(far, "shrinking", "Undo"), pair);
        var filler = Path.Combine(far, "filler.bin");
        var filled = false;
        hook?.SetValue(null, (Action<int>)(point =>
        {
            if (point != 2) return;
            using var stream = new FileStream(filler, FileMode.CreateNew);
            stream.SetLength(new DriveInfo(volume.Root).AvailableFreeSpace - (1L << 30) - (150L << 20));
            filled = true;
        }));
        var stoppedError = "not refused";
        try { shrinking.Engine.Apply(shrinking.Review, shrinking.Hash, shrinking.Journal); }
        catch (CleanupSpaceException error) { stoppedError = error.Message; }
        finally { hook?.SetValue(null, null); }
        Console.WriteLine("Space that shrinks during the copies: " + stoppedError);
        check(hook is not null && filled, "The space-shrink scenario reached the point after the first copy (needs a GovernorTestHooks build)");
        check(stoppedError.Contains("enough free space", StringComparison.Ordinal) && !File.Exists(shrinking.Journal) &&
            !Directory.EnumerateFileSystemEntries(Path.GetDirectoryName(shrinking.Journal)!, "file-backup-*").Any() &&
            Mismatches(shrinking.Plan, _ => true).Length == 0 && new DriveInfo(volume.Root).AvailableFreeSpace >= 1L << 30,
            "When other programs eat the space during the copies, cleanup stops before the drive drops under its spare room, removes its copies and journal, and deletes nothing");
        File.Delete(filler);
    }

    static void BatchLowSpace(Action<bool, string> check, string root, string far)
    {
        var registryRoot = "Software\\RooIndustriesCleanupSpaceTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var owned = OwnedRegistryKey.Create(hive, registryRoot);
        var scope = Path.Combine(root, "batch");
        var operations = Path.Combine(far, "batch-operations");
        var contexts = new Dictionary<string, CleanupContext>();
        var free = new DriveInfo(Path.GetPathRoot(far)!).AvailableFreeSpace;
        foreach (var (name, size) in new[] { ("Roo Industries Space One", 0L), ("Roo Industries Space Two", free / 2) })
        {
            var source = Path.Combine(scope, name);
            Directory.CreateDirectory(source);
            File.WriteAllText(Path.Combine(source, "data.txt"), name + " file");
            if (size > 0) using (var stream = new FileStream(Path.Combine(source, "large.bin"), FileMode.CreateNew)) stream.SetLength(size);
            using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
            var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
            var authority = new CleanupAuthority
            {
                AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            contexts.Add(app.AppId, new CleanupContext(Path.Combine(scope, "queue.json"), authority, app, [], true));
        }
        var peers = contexts.Values.Select(context => context.Application).ToArray();
        foreach (var appId in contexts.Keys.ToArray()) contexts[appId] = contexts[appId] with { Peers = peers };
        ApplicationCleanup App(string source, string appId) => new(() => contexts[appId], [scope], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
        var parts = new List<CleanupPart>();
        foreach (var context in contexts.Values)
        {
            var engine = App(context.Source, context.Application.AppId);
            var path = Path.Combine(operations, context.Application.DisplayName, "review.json");
            engine.Preview(path, engine.Scan(CancellationToken.None).Candidates.Select(item => item.ItemId).ToArray(), true, true);
            parts.Add(new(path, OperationFiles.HashFile(path), Path.Combine(Path.GetDirectoryName(path)!, "journal.json")));
        }
        var batchPath = Path.Combine(operations, "batch-review.json");
        var journalPath = Path.Combine(operations, "batch-journal.json");
        CleanupBatch.Preview(batchPath, parts.ToArray());
        string? refusal = null;
        try { new CleanupBatch(App).Apply(batchPath, OperationFiles.HashFile(batchPath), journalPath); }
        catch (IOException error) { refusal = error.Message; }
        Console.WriteLine("Low-space batch: " + (refusal ?? "started"));
        using var one = hive.OpenSubKey(registryRoot + "\\Roo Industries Space One");
        check(refusal is not null && refusal.Contains("enough free space", StringComparison.Ordinal) && one?.GetValue("Original") as string == "Roo Industries Space One registry" &&
            contexts.Values.All(context => Directory.Exists(context.Application.InstallLocation)) && parts.All(part => !File.Exists(part.JournalPath)),
            "A batch whose undo copies don't fit is refused before the first app's registry keys or files change");
    }

    static void LockedLowSpace(Action<bool, string> check, string far)
    {
        var registryRoot = "Software\\RooIndustriesCleanupSpaceTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var owned = OwnedRegistryKey.Create(hive, registryRoot);
        const string name = "Roo Industries Locked Space";
        var scope = Path.Combine(far, "locked-space");
        var source = Path.Combine(scope, name);
        try
        {
            Directory.CreateDirectory(source);
            File.WriteAllText(Path.Combine(source, "data.txt"), name + " file");
            var large = Path.Combine(source, "large.bin");
            using (var stream = new FileStream(large, FileMode.CreateNew)) stream.SetLength(new DriveInfo(Path.GetPathRoot(far)!).AvailableFreeSpace / 2);
            var security = new FileSecurity();
            security.SetSecurityDescriptorSddlForm("D:PAI(A;;FA;;;SY)(A;;0x1301ff;;;OW)(A;;0x1301ff;;;" + User + ")", AccessControlSections.Access);
            new FileInfo(large).SetAccessControl(security);
            using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
            var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
            var authority = new CleanupAuthority
            {
                AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var context = new CleanupContext(Path.Combine(scope, "queue.json"), authority, app, [app], true);
            var engine = new ApplicationCleanup(() => context, [scope], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
            var review = Path.Combine(far, "locked-space-operations", "review.json");
            var preview = engine.Preview(review, engine.Scan(CancellationToken.None).Candidates.Select(item => item.ItemId).ToArray(), true, true);
            var journal = Path.Combine(Path.GetDirectoryName(review)!, "journal.json");
            string? refusal = null;
            ApplicationCleanupJournal? result = null;
            try { result = engine.Apply(review, OperationFiles.HashFile(review), journal); }
            catch (IOException error) { refusal = error.Message; }
            Console.WriteLine("Low-space cleanup of same-drive leftovers that must be copied: " + (refusal ?? result!.Status + " " + string.Join(" | ", result.Errors)));
            using var kept = hive.OpenSubKey(registryRoot + "\\" + name);
            check(preview.Registry is not null && preview.Files is not null && refusal is not null && refusal.Contains("enough free space on " + Path.GetPathRoot(far)!.TrimEnd('\\'), StringComparison.Ordinal),
                "A cleanup whose same-drive leftovers must be copied, because Windows won't let the app change their permissions, is refused when the copies don't fit");
            check(kept?.GetValue("Original") as string == name + " registry" && File.Exists(large) && !File.Exists(journal) && !File.Exists(preview.Files?.JournalPath),
                "That refusal comes before the app's registry keys or files change and leaves no half-done recovery record");
        }
        finally
        {
            if (Directory.Exists(scope))
            {
                foreach (var file in Directory.EnumerateFiles(scope, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
                Directory.Delete(scope, true);
            }
        }
    }

    static void RetryAfterConflict(Action<bool, string> check, string root)
    {
        var app = Path.Combine(root, "retry", "App");
        var file = Path.Combine(app, "settings.txt");
        Directory.CreateDirectory(app);
        File.WriteAllText(file, "original settings");
        var plan = Review(Path.Combine(root, "retry", "Undo"), app);
        // Steps: journal saved, deleting saved, file permissions swapped, file moved. Stop right after the move.
        var exit = RunChild(4, ["apply", plan.Review, plan.Hash, plan.Journal]);
        var stopped = OperationFiles.Read<FileCleanupJournal>(plan.Journal);
        var ready = exit == -1 && stopped.Status == "deleting" && !File.Exists(file) && Directory.Exists(app);
        check(ready, "The retry fixture stops while deleting, after moving the file and before its folder");
        if (!ready) return;
        File.WriteAllText(file, "another program's file");
        var blocked = plan.Engine.Restore(plan.Journal);
        check(blocked.Status == "needsReconciliation" && File.ReadAllText(file) == "another program's file", "Restore after a stopped cleanup keeps a file another program put at a leftover's path");
        File.Delete(file);
        var retried = plan.Engine.Restore(plan.Journal);
        var problems = Mismatches(plan.Plan, _ => true);
        foreach (var problem in problems) Console.WriteLine("  " + problem);
        if (retried.Status != "restored") Console.WriteLine("  retry " + retried.Status + " " + string.Join(" | ", retried.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Original.Path + ": " + entry.Error)));
        check(retried.Status == "restored" && problems.Length == 0 && retried.Entries.All(entry => !Path.Exists(entry.BackupPath)),
            "Once that file is gone, Restore again brings back the leftover it couldn't before instead of leaving it in the undo folder");
    }

    static void RetryKeepsLaterChanges(Action<bool, string> check, string root, string far)
    {
        var near = Tree(Path.Combine(root, "later"), "App", exotic: false);
        var remote = Tree(Path.Combine(far, "later"), "App", exotic: false);
        var blocked = Path.Combine(near, "Data", "settings.bin");
        var notes = Path.Combine(near, "readme.txt");
        var copied = Path.Combine(remote, "Data", "settings.bin");
        var plan = Review(Path.Combine(root, "later", "Undo"), near, remote);
        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
        FileCleanupJournal first;
        // Another program holds the undo copy of one moved file open, so the first restore can't move that one back.
        using (new FileStream(applied.Entries.Single(entry => entry.Original.Path == blocked).BackupPath, FileMode.Open, FileAccess.Read, FileShare.None))
            first = plan.Engine.Restore(plan.Journal);
        var ready = applied.Status == "applied" && first.Status == "needsReconciliation" && !File.Exists(blocked) &&
            first.Entries.Single(entry => entry.Original.Path == notes).Status == "restored" && first.Entries.Single(entry => entry.Original.Path == copied).Status == "restored";
        check(ready, "The later-change fixture restores everything except the one leftover whose undo copy another program holds open");
        if (!ready) return;
        // After that partial restore the user changes a moved-back file and a copied-back file.
        RefusalChecks.SetSecurity(notes, "D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + User + ")(A;;FR;;;WD)", 4);
        File.SetAttributes(notes, FileAttributes.Hidden);
        File.SetAttributes(copied, FileAttributes.Hidden | FileAttributes.ReadOnly);
        var notesChanged = Snapshot(notes);
        var copiedChanged = Snapshot(copied);
        FileCleanupJournal retried;
        // A restored file the user didn't change is open in another program during the retry; that isn't a change.
        using (new FileStream(Path.Combine(remote, "readme.txt"), FileMode.Open, FileAccess.Read, FileShare.None))
            retried = plan.Engine.Restore(plan.Journal);
        if (retried.Status != "restored") Console.WriteLine("  later-change retry " + retried.Status + " " + string.Join(" | ", retried.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Original.Path + ": " + entry.Error)));
        var notesNow = Snapshot(notes);
        var copiedNow = Snapshot(copied);
        check(retried.Status == "restored" && notesChanged.SameRestorableData(notesNow) && copiedChanged.SameRestorableData(copiedNow),
            "A retry for another leftover keeps the permissions and attributes the user changed on leftovers that were already back (" + string.Join(", ", plan.Plan.Files.Single(file => file.Path == notes).Differences(notesNow)) + " kept)");
        var left = retried.Entries.Where(entry => entry.LeftAsChanged is not null).Select(entry => entry.Original.Path).Order(StringComparer.OrdinalIgnoreCase).ToArray();
        check(left.SequenceEqual(new[] { copied, notes }.Order(StringComparer.OrdinalIgnoreCase)), "Restore says which already-restored leftovers it left as the user changed them (" + string.Join(", ", left) + ")");
        var others = Mismatches(plan.Plan, _ => false).Where(problem => !problem.StartsWith(notes + ":", StringComparison.OrdinalIgnoreCase) && !problem.StartsWith(copied + ":", StringComparison.OrdinalIgnoreCase)).ToArray();
        foreach (var problem in others) Console.WriteLine("  " + problem);
        check(others.Length == 0 && File.ReadAllBytes(blocked).SequenceEqual(new byte[] { 4, 3, 2, 1, 0 }), "The retry brings back the leftover that was blocked, and everything else matches its review");
    }

    static void CopyStoppedAfterRename(Action<bool, string> check, string root, string far)
    {
        var remote = Tree(Path.Combine(far, "renamed"), "App", exotic: false);
        var file = Path.Combine(remote, "Data", "settings.bin");
        // New files carry the archive flag; the reviewed file doesn't, so the flag a rename adds is the only difference.
        File.SetAttributes(file, FileAttributes.Normal);
        var plan = Review(Path.Combine(root, "renamed", "Undo"), remote);
        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
        var restored = plan.Engine.Restore(plan.Journal);
        var ready = applied.Status == "applied" && restored.Status == "restored" && (plan.Plan.Files.Single(item => item.Path == file).Attributes & (uint)FileAttributes.Archive) == 0;
        check(ready, "The stopped-after-rename fixture cleans and restores a copied file reviewed without the archive flag");
        if (!ready) return;
        // The state a restore leaves when it stops right after renaming its copy into place: the copy has its data and permissions,
        // Windows has added the archive flag, and the journal holds the copy's identity from just before the rename.
        File.SetAttributes(file, File.GetAttributes(file) | FileAttributes.Archive);
        var journal = OperationFiles.Read<FileCleanupJournal>(plan.Journal);
        var entry = journal.Entries.Single(item => item.Original.Path == file);
        entry.Status = "restoreIntent";
        entry.RestoredIdentity = Snapshot(file).Identity;
        journal.Status = "needsReconciliation";
        OperationFiles.Write(plan.Journal, journal);
        var retried = plan.Engine.Restore(plan.Journal);
        if (retried.Status != "restored") Console.WriteLine("  stopped-after-rename retry " + retried.Status + " " + string.Join(" | ", retried.Entries.Where(item => item.Error is not null).Select(item => item.Original.Path + ": " + item.Error)));
        var problems = Mismatches(plan.Plan, _ => false);
        foreach (var problem in problems) Console.WriteLine("  " + problem);
        check(retried.Status == "restored" && problems.Length == 0 && retried.Entries.Single(item => item.Original.Path == file).LeftAsChanged is null,
            "A restore stopped after its copy took the leftover's name finishes on retry: the copy is known as its own and gets its attributes and times back");
    }

    static void MoveOnlyLowSpace(Action<bool, string> check, TestVolume volume, string far)
    {
        var registryRoot = "Software\\RooIndustriesCleanupSpaceTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var owned = OwnedRegistryKey.Create(hive, registryRoot);
        const string name = "Roo Industries Move Space";
        var scope = Path.Combine(far, "move-space");
        var source = Path.Combine(scope, name);
        var filler = Path.Combine(far, "move-space-filler.bin");
        try
        {
            for (var folder = 0; folder < 20; folder++)
            {
                var directory = Path.Combine(source, "Folder " + folder);
                Directory.CreateDirectory(directory);
                for (var item = 0; item < 40; item++) File.WriteAllText(Path.Combine(directory, "file " + item + ".txt"), name + " " + folder + " " + item);
            }
            using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
            var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
            var authority = new CleanupAuthority
            {
                AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var context = new CleanupContext(Path.Combine(scope, "queue.json"), authority, app, [app], true);
            var engine = new ApplicationCleanup(() => context, [scope], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
            var review = Path.Combine(far, "move-space-operations", "review.json");
            var preview = engine.Preview(review, engine.Scan(CancellationToken.None).Candidates.Select(item => item.ItemId).ToArray(), true, true);
            var journal = Path.Combine(Path.GetDirectoryName(review)!, "journal.json");
            var record = new FileInfo(preview.Files!.PreviewPath).Length;
            // Leave less room than the file journal needs, so the drive can hold the small app and registry records but not the file journal.
            using (var stream = new FileStream(filler, FileMode.CreateNew)) stream.SetLength(new DriveInfo(volume.Root).AvailableFreeSpace - record / 2);
            string? refusal = null;
            ApplicationCleanupJournal? result = null;
            try { result = engine.Apply(review, OperationFiles.HashFile(review), journal); }
            catch (IOException error) { refusal = error.Message; }
            Console.WriteLine("Low-space cleanup whose leftovers all move (" + (record >> 10) + " KB review): " + (refusal ?? result!.Status + " " + string.Join(" | ", result.Errors)));
            using var kept = hive.OpenSubKey(registryRoot + "\\" + name);
            check(refusal is not null && refusal.Contains("enough free space on " + volume.Root.TrimEnd('\\') + " for this cleanup's recovery record", StringComparison.Ordinal),
                "A cleanup whose leftovers all move into the undo folder is still refused when the drive can't hold its recovery record and spare room");
            check(kept?.GetValue("Original") as string == name + " registry" && Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories).Count() == 800 && !File.Exists(journal) && !File.Exists(preview.Files.JournalPath),
                "That refusal comes before the app's registry keys change or any leftover moves");
        }
        finally
        {
            File.Delete(filler);
            if (Directory.Exists(scope)) Directory.Delete(scope, true);
            var operations = Path.Combine(far, "move-space-operations");
            if (Directory.Exists(operations)) Directory.Delete(operations, true);
        }
    }

    static void OneVolumeTwoLetters(Action<bool, string> check, string root, TestVolume volume, string far)
    {
        var registryRoot = "Software\\RooIndustriesCleanupSpaceTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var owned = OwnedRegistryKey.Create(hive, registryRoot);
        var aliased = Directory.CreateDirectory(Path.Combine(far, "second-letter")).FullName;
        var scope = Path.Combine(root, "letters");
        try
        {
            using var second = SubstDrive.Create(aliased);
            Letters(second);
        }
        finally
        {
            foreach (var folder in new[] { scope, aliased, Path.Combine(far, "letters-one"), Path.Combine(far, "letters-batch") }.Where(Directory.Exists)) Directory.Delete(folder, true);
        }

        void Letters(SubstDrive second)
        {
            var reserve = Math.Clamp(new DriveInfo(volume.Root).TotalSize / 20, 1L << 30, 10L << 30);
            // Each app's copies plus its check copy fit with the spare room left; both apps' copies don't.
            var size = (new DriveInfo(volume.Root).AvailableFreeSpace - reserve) * 2 / 5;
            var contexts = new Dictionary<string, CleanupContext>();
            foreach (var name in new[] { "Roo Industries Letter One", "Roo Industries Letter Two" })
            {
                var source = Path.Combine(scope, name);
                Directory.CreateDirectory(source);
                using (var stream = new FileStream(Path.Combine(source, "large.bin"), FileMode.CreateNew)) stream.SetLength(size);
                using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
                var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
                var authority = new CleanupAuthority
                {
                    AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                    ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
                };
                contexts.Add(app.AppId, new CleanupContext(Path.Combine(scope, "queue.json"), authority, app, [], true));
            }
            var peers = contexts.Values.Select(context => context.Application).ToArray();
            foreach (var appId in contexts.Keys.ToArray()) contexts[appId] = contexts[appId] with { Peers = peers };
            ApplicationCleanup App(string source, string appId) => new(() => contexts[appId], [scope], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
            var stores = new[] { Path.Combine(far, "letters-one"), Path.Combine(second.Root, "letters-two") };
            var parts = new List<CleanupPart>();
            foreach (var (context, store) in contexts.Values.Zip(stores))
            {
                var engine = App(context.Source, context.Application.AppId);
                var path = Path.Combine(store, "review.json");
                engine.Preview(path, engine.Scan(CancellationToken.None).Candidates.Select(item => item.ItemId).ToArray(), true, true);
                parts.Add(new(path, OperationFiles.HashFile(path), Path.Combine(store, "journal.json")));
            }
            var batchPath = Path.Combine(far, "letters-batch", "batch-review.json");
            var journalPath = Path.Combine(far, "letters-batch", "batch-journal.json");
            CleanupBatch.Preview(batchPath, parts.ToArray());
            string? refusal = null;
            CleanupBatchJournal? result = null;
            try { result = new CleanupBatch(App).Apply(batchPath, OperationFiles.HashFile(batchPath), journalPath); }
            catch (IOException error) { refusal = error.Message; }
            Console.WriteLine("Batch with undo folders on " + volume.Root.TrimEnd('\\') + " and " + second.Root.TrimEnd('\\') + " (one volume, " + (size >> 20) + " MB per app): " +
                (refusal ?? result!.Status + " " + string.Join(" | ", result.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Error))));
            var untouched = contexts.Values.All(context =>
            {
                using var key = hive.OpenSubKey(registryRoot + "\\" + context.Application.DisplayName);
                return key?.GetValue("Original") as string == context.Application.DisplayName + " registry" && File.Exists(Path.Combine(context.Application.InstallLocation!, "large.bin"));
            });
            check(refusal is not null && refusal.Contains("enough free space", StringComparison.Ordinal) && untouched && parts.All(part => !File.Exists(part.JournalPath)),
                "A batch whose undo folders reach one drive through two letters gets one space budget, and is refused before the first app's registry keys or files change");
        }
    }

    static void JunctionSwaps(Action<bool, string> check, string root)
    {
        var hook = typeof(FileCleanupEngine).GetField("CheckpointReached", BindingFlags.NonPublic | BindingFlags.Static);
        int swapped = 0, refused = 0, steps = 0;
        var outside = new List<string>();
        var unrecovered = new List<string>();
        for (var at = 1; at < 100 && hook is not null; at++)
        {
            var parent = Path.Combine(root, "swap", at.ToString());
            var app = Tree(parent, "App", exotic: false);
            var real = app + " real";
            var elsewhere = Directory.CreateDirectory(Path.Combine(parent, "Elsewhere")).FullName;
            var plan = Review(Path.Combine(parent, "Undo"), app);
            var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
            if (applied.Status != "applied") { check(false, "The junction-swap fixture applies (" + applied.Status + ")"); return; }
            var reached = false;
            var link = false;
            hook.SetValue(null, (Action<int>)(point =>
            {
                if (point != at) return;
                reached = true;
                if (!Directory.Exists(app)) return;
                // Another program swaps the leftover's folder for a junction to a folder outside the cleanup.
                try { Directory.Move(app, real); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { refused++; return; }
                link = Junction(app, elsewhere);
                swapped++;
            }));
            FileCleanupJournal swappedRun;
            try { swappedRun = new FileCleanupEngine(Authority).Restore(plan.Journal); }
            finally { hook.SetValue(null, null); }
            if (!reached) { steps = at - 1; Remove(parent); break; }
            if (Directory.EnumerateFileSystemEntries(elsewhere, "*", SearchOption.AllDirectories).Any()) outside.Add(at + ": " + string.Join(", ", Directory.EnumerateFileSystemEntries(elsewhere, "*", SearchOption.AllDirectories)));
            if (link) Directory.Delete(app);
            if (Directory.Exists(real)) Directory.Move(real, app);
            var finished = new FileCleanupEngine(Authority).Restore(plan.Journal);
            var problems = Mismatches(plan.Plan, _ => true);
            if (finished.Status != "restored" || problems.Length != 0)
                unrecovered.Add(at + ": " + finished.Status + " " + string.Join(" | ", problems.Concat(finished.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Original.Path + ": " + entry.Error))));
            Remove(parent);
        }
        foreach (var item in outside) Console.WriteLine("  restored outside the leftover's folder at step " + item);
        foreach (var item in unrecovered) Console.WriteLine("  not recovered after the swap at step " + item);
        Console.WriteLine("Junction swap at each of " + steps + " restore steps: " + swapped + " swaps went through, " + refused + " were blocked by held folders");
        check(hook is not null && steps > 0 && swapped > 0 && refused > 0, "The junction-swap sweep tries a swap at every restore step, and some steps hold the folders open (needs a GovernorTestHooks build)");
        check(outside.Count == 0, "Swapping a leftover's folder for a junction during restore never sends a restored file or folder outside the cleanup");
        check(unrecovered.Count == 0, "Once the folder is put back, Restore again brings back everything exactly");
    }

    static void Remove(string folder)
    {
        foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(folder, true);
    }

    static bool Junction(string link, string target)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "/d", "/c", "mklink", "/J", link, target }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("mklink did not start.");
        process.StandardOutput.ReadToEnd();
        process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0) throw new InvalidOperationException("mklink /J failed with " + process.ExitCode);
        return true;
    }

    static FileSnapshot Snapshot(string path)
    {
        using var lease = FileLease.Open(path);
        return lease.Capture();
    }

    // Each cleanup and restore step is stopped, then run again with nothing changed and after the user changes a leftover that's at its path
    // in each way a user would: its data, its permissions, its read-only flag, or replacing it with their own file.
    static readonly string[] UserChanges = ["none", "content", "permissions", "attributes", "replace"];

    static void Crashes(Action<bool, string> check, string root, string far)
    {
        foreach (var phase in new[] { "apply", "restore" })
        {
            var covered = 0;
            var changes = UserChanges.ToDictionary(change => change, _ => 0);
            var done = false;
            for (var at = 1; at < 200 && !done; at++)
            {
                foreach (var change in UserChanges)
                {
                    var label = phase + "-" + at + "-" + change;
                    var near = Tree(Path.Combine(root, "crash", label), "App", exotic: true);
                    var locked = FileLease.NormalizePath(Locked(Path.Combine(root, "crash", label)));
                    var remote = Tree(Path.Combine(far, "crash", label), "App", exotic: false);
                    var plan = Review(Path.Combine(root, "crash", label, "Undo"), near, locked, remote);
                    bool Moved(string path) => !path.StartsWith(Path.GetPathRoot(far)!, StringComparison.OrdinalIgnoreCase) && path != locked && !path.StartsWith(locked + "\\", StringComparison.OrdinalIgnoreCase);
                    if (phase == "restore")
                    {
                        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
                        if (applied.Status != "applied" || applied.Entries.Single(entry => entry.Original.Path == locked).BackupHash is null)
                        {
                            check(false, "Crash fixture " + label + " applies before its restore is interrupted, copying the folder whose permissions the app can't change (" + applied.Status + " " +
                                string.Join(" | ", applied.Entries.Where(entry => entry.Error is not null).Select(entry => entry.Original.Path + ": " + entry.Error)) + ")");
                            return;
                        }
                    }
                    var exit = RunChild(at, phase == "apply" ? ["apply", plan.Review, plan.Hash, plan.Journal] : ["restore", plan.Journal]);
                    if (exit != 0 && exit != -1) { check(false, "The " + phase + " child at step " + at + " ends only by finishing or by being killed (exit " + exit + ")"); return; }
                    if (exit == 0)
                    {
                        check(covered > 0, "Every " + phase + " step is interrupted at least once (needs a GovernorTestHooks build)");
                        Console.WriteLine("Interrupted " + phase + " at each of its " + covered + " steps; user changes after the stop: " + string.Join(", ", changes.Where(item => item.Key != "none").Select(item => item.Key + " " + item.Value)));
                        check(changes.Where(item => item.Key != "none").All(item => item.Value > 0), "Each kind of user change is tried after a stopped " + phase);
                        done = true;
                        break;
                    }
                    if (change == "none") covered++;
                    var journal = File.Exists(plan.Journal) ? OperationFiles.Read<FileCleanupJournal>(plan.Journal) : null;
                    var lost = plan.Plan.Files.Where(file => !Path.Exists(file.Path) && journal?.Entries.Any(entry => entry.Original.Path == file.Path && Path.Exists(entry.BackupPath)) != true).Select(file => file.Path).ToArray();
                    var target = change == "none" ? null : Target(plan.Plan, locked);
                    if (change != "none" && target is null) continue;
                    var made = target is null ? null : UserChange(target, change);
                    if (target is not null) changes[change]++;
                    var restored = journal is null ? null : plan.Engine.Restore(plan.Journal);
                    var entry = target is null ? null : restored?.Entries.Single(item => item.Original.Path == target);
                    var conflict = entry?.Error is not null;
                    var problems = Mismatches(plan.Plan, file => Moved(file.Path)).Where(problem =>
                        target is null || !problem.StartsWith(target + ": ", StringComparison.OrdinalIgnoreCase) &&
                        !((conflict || change == "replace") && plan.Plan.Files.Any(folder => folder.Directory && Within(target, folder.Path) && problem.StartsWith(folder.Path + ": ", StringComparison.OrdinalIgnoreCase) &&
                            problem[(folder.Path.Length + 2)..].Split(", ").All(difference => difference is "last-write time" or "attributes")))).ToArray();
                    var leftovers = (journal?.Entries ?? []).Where(item => Moved(item.Original.Path) && Path.Exists(item.BackupPath) && !(conflict && item.Original.Path == target)).Select(item => item.BackupPath)
                        .Concat(new[] { near, locked, remote }.SelectMany(folder => Directory.Exists(folder) ? Directory.EnumerateFiles(folder, ".roo-industries-restore-*", SearchOption.AllDirectories) : [])).ToArray();
                    foreach (var problem in problems.Concat(lost.Select(path => "lost " + path)).Concat(leftovers.Select(path => "left behind " + path))) Console.WriteLine("  " + label + " " + problem);
                    if (restored is not null && restored.Status != "restored") Console.WriteLine("  " + label + " " + restored.Status + " " + string.Join(" | ", restored.Entries.Where(item => item.Error is not null).Select(item => item.Original.Path + ": " + item.Error)));
                    check(lost.Length == 0 && problems.Length == 0 && leftovers.Length == 0 && (restored is null || restored.Status is "restored" or "preparing" || conflict && restored.Status == "needsReconciliation" && restored.Entries.Where(item => item.Error is not null).All(item => item.Original.Path == target || Within(target!, item.Original.Path))),
                        "After the " + phase + " is killed at step " + at + (target is null ? "" : " and the user changes a leftover's " + change) + ", Restore puts back everything cleanup took, exactly");
                    if (target is null) continue;
                    FileSnapshot? now = null;
                    try { now = Snapshot(target); } catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidDataException) { }
                    var kept = now is not null && now.Identity == made!.Identity && made.SameRestorableData(now);
                    var reported = entry is null || restored!.Status == "preparing" || entry.LeftAsChanged is not null || conflict;
                    if (!kept || !reported) Console.WriteLine("  " + label + " " + target + ": " + (now is null ? "missing" : string.Join(", ", made!.Differences(now))) + (reported ? "" : " (not reported)"));
                    check(kept && reported, "After the " + phase + " is killed at step " + at + ", a leftover whose " + change + " the user changed is left as they made it, and Restore says so");
                }
            }
        }
    }

    // A leftover file at its path after the stop, preferring one cleanup or restore left partway through.
    static string? Target(FileCleanupPreview plan, string skipped)
    {
        var present = new List<(FileSnapshot Reviewed, FileSnapshot Now)>();
        foreach (var file in plan.Files.Where(file => !file.Directory && !Within(file.Path, skipped)))
        {
            try { present.Add((file, Snapshot(file.Path))); }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidDataException) { }
        }
        return (present.FirstOrDefault(item => !item.Reviewed.SameObjectAndContent(item.Now)).Reviewed ?? present.FirstOrDefault().Reviewed)?.Path;
    }

    static FileSnapshot UserChange(string path, string change)
    {
        var attributes = File.GetAttributes(path);
        switch (change)
        {
            case "content":
                File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
                File.AppendAllText(path, " changed by the user");
                File.SetAttributes(path, attributes);
                break;
            case "permissions":
                RefusalChecks.SetSecurity(path, "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + User + ")(A;;FR;;;WD)", 4);
                break;
            case "attributes":
                File.SetAttributes(path, attributes ^ FileAttributes.ReadOnly);
                break;
            case "replace":
                File.SetAttributes(path, FileAttributes.Normal);
                File.Delete(path);
                File.WriteAllText(path, "the user's own file");
                break;
        }
        return Snapshot(path);
    }

    static bool Within(string path, string folder) => path.StartsWith(folder + "\\", StringComparison.OrdinalIgnoreCase);

    // A restore stopped after saving its staging copy's identity, before the copy took the leftover's name. Retrying finishes with that copy
    // when it's untouched; a staging file someone changed or replaced is kept and reported, not deleted.
    static void StagingKept(Action<bool, string> check, string root, string far)
    {
        foreach (var change in new[] { "none", "content", "replace" })
        {
            var remote = Tree(Path.Combine(far, "staging-" + change), "App", exotic: false);
            var file = Path.Combine(remote, "Data", "settings.bin");
            var plan = Review(Path.Combine(root, "staging-" + change, "Undo"), remote);
            var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
            var restored = plan.Engine.Restore(plan.Journal);
            var ready = applied.Status == "applied" && restored.Status == "restored";
            check(ready, "The staging fixture (" + change + ") cleans and restores a copied leftover");
            if (!ready) return;
            var journal = OperationFiles.Read<FileCleanupJournal>(plan.Journal);
            var entry = journal.Entries.Single(item => item.Original.Path == file);
            var staging = Path.Combine(Path.GetDirectoryName(file)!, ".roo-industries-restore-" + Path.GetFileName(entry.BackupPath)["file-backup-".Length..]);
            File.Move(file, staging);
            entry.Status = "restoreIntent";
            entry.RestoredIdentity = Snapshot(staging).Identity;
            entry.RestoreStagingPath = staging;
            // A real stop at this point comes before the folders above it got their times back.
            foreach (var folder in journal.Entries.Where(item => item.Original.Directory && Within(file, item.Original.Path))) folder.DirectoryMetadataRestored = false;
            journal.Status = "needsReconciliation";
            OperationFiles.Write(plan.Journal, journal);
            if (change == "content") File.AppendAllText(staging, " newer data");
            if (change == "replace") { File.Delete(staging); File.WriteAllText(staging, "another program's newer file"); }
            var made = Snapshot(staging);
            var retried = plan.Engine.Restore(plan.Journal);
            var error = retried.Entries.Single(item => item.Original.Path == file).Error;
            if (change == "none")
            {
                var problems = Mismatches(plan.Plan, _ => false);
                foreach (var problem in problems) Console.WriteLine("  staging " + problem);
                check(retried.Status == "restored" && problems.Length == 0 && !File.Exists(staging), "A restore stopped with its untouched staging copy finishes on retry with that copy");
                continue;
            }
            FileSnapshot? now = null;
            try { now = Snapshot(staging); } catch (Exception failure) when (failure is System.ComponentModel.Win32Exception or InvalidDataException) { }
            Console.WriteLine("Staging file " + change + " after a stop: " + retried.Status + " " + error);
            check(now is not null && now.Identity == made.Identity && made.SameRestorableData(now) && !File.Exists(file) && retried.Status == "needsReconciliation" && error is not null,
                "A staging file that was " + (change == "content" ? "changed" : "replaced") + " after a stopped restore is kept with its newer data and reported, not deleted");
        }
    }

    // The space check that runs before an app's registry part and the one cleanup makes itself use one journal budget, so when the first passes
    // the second can't refuse after the registry part has run.
    static void BudgetAgrees(Action<bool, string> check, TestVolume volume, string far)
    {
        var registryRoot = "Software\\RooIndustriesCleanupSpaceTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var owned = OwnedRegistryKey.Create(hive, registryRoot);
        const string name = "Roo Industries Budget";
        var scope = Path.Combine(far, "budget");
        var source = Path.Combine(scope, name);
        var operations = Path.Combine(far, "budget-operations");
        var filler = Path.Combine(far, "budget-filler.bin");
        try
        {
            for (var folder = 0; folder < 20; folder++)
            {
                var directory = Path.Combine(source, "Folder " + folder);
                Directory.CreateDirectory(directory);
                for (var item = 0; item < 40; item++) File.WriteAllText(Path.Combine(directory, "file " + item + ".txt"), name + " " + folder + " " + item);
            }
            using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
            var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
            var authority = new CleanupAuthority
            {
                AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var context = new CleanupContext(Path.Combine(scope, "queue.json"), authority, app, [app], true);
            var engine = new ApplicationCleanup(() => context, [scope], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
            var review = Path.Combine(operations, "review.json");
            var preview = engine.Preview(review, engine.Scan(CancellationToken.None).Candidates.Select(item => item.ItemId).ToArray(), true, true);
            var files = OperationFiles.Read<FileCleanupPreview>(preview.Files!.PreviewPath, preview.Files.ReviewHash);
            // Find the most filler the check before the registry part still accepts, then leave a little more room than that.
            var baseline = new DriveInfo(volume.Root).AvailableFreeSpace;
            using (File.Create(filler)) { }
            bool Accepted(long size)
            {
                using (var stream = new FileStream(filler, FileMode.Open)) stream.SetLength(size);
                try { FileCleanupEngine.RequireSpace([(files, preview.Files.JournalPath)]); return true; }
                catch (CleanupSpaceException) { return false; }
            }
            long low = 0, high = baseline;
            while (high - low > 4096) { var middle = low + (high - low) / 2; if (Accepted(middle)) low = middle; else high = middle; }
            var accepted = Accepted(Math.Max(0, low - (64L << 10)));
            var journal = Path.Combine(operations, "journal.json");
            var result = engine.Apply(review, OperationFiles.HashFile(review), journal);
            Console.WriteLine("Cleanup with " + ((baseline - low) >> 10) + " KB free beyond the check's limit plus 64 KB: " + result.Status + " " + string.Join(" | ", result.Errors));
            check(accepted && result.Status == "applied" && !Directory.Exists(source), "A cleanup the space check accepts before its registry part isn't refused for space by its own file step");
        }
        finally
        {
            File.Delete(filler);
            foreach (var folder in new[] { scope, operations }.Where(Directory.Exists)) Directory.Delete(folder, true);
        }
    }

    // An app with a file another program holds open is refused before anything changes, its registry keys included, and runs once the file is free.
    static void InUseRefusesApp(Action<bool, string> check, string root)
    {
        var registryRoot = "Software\\RooIndustriesCleanupInUseTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var owned = OwnedRegistryKey.Create(hive, registryRoot);
        var scope = Path.Combine(root, "in-use");
        var contexts = new Dictionary<string, CleanupContext>();
        foreach (var name in new[] { "Roo Industries Busy One", "Roo Industries Busy Two", "Roo Industries Busy Alone" })
        {
            var source = Path.Combine(scope, name);
            Directory.CreateDirectory(Path.Combine(source, "Data"));
            File.WriteAllText(Path.Combine(source, "readme.txt"), name + " readme");
            File.WriteAllText(Path.Combine(source, "Data", "settings.txt"), name + " settings");
            using (var key = hive.CreateSubKey(registryRoot + "\\" + name)) key.SetValue("Original", name + " registry");
            var app = new CleanupApplication { AppId = "fixture:" + name, DisplayName = name, Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
            var authority = new CleanupAuthority
            {
                AppId = app.AppId, ProviderIdentityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes(name)), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            contexts.Add(app.AppId, new CleanupContext(Path.Combine(scope, "queue.json"), authority, app, [], true));
        }
        var peers = contexts.Values.Select(context => context.Application).ToArray();
        foreach (var appId in contexts.Keys.ToArray()) contexts[appId] = contexts[appId] with { Peers = peers };
        ApplicationCleanup App(string source, string appId) => new(() => contexts[appId], [scope], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
        CleanupPart ReviewApp(CleanupContext context)
        {
            var engine = App(context.Source, context.Application.AppId);
            var path = Path.Combine(scope, "operations", context.Application.DisplayName, "review.json");
            engine.Preview(path, engine.Scan(CancellationToken.None).Candidates.Where(item => item.Target.Contains(context.Application.DisplayName, StringComparison.Ordinal)).Select(item => item.ItemId).ToArray(), true, true);
            return new(path, OperationFiles.HashFile(path), Path.Combine(Path.GetDirectoryName(path)!, "journal.json"));
        }
        bool Untouched(CleanupContext context)
        {
            using var key = hive.OpenSubKey(registryRoot + "\\" + context.Application.DisplayName);
            return key?.GetValue("Original") as string == context.Application.DisplayName + " registry" &&
                File.ReadAllText(Path.Combine(context.Application.InstallLocation!, "Data", "settings.txt")) == context.Application.DisplayName + " settings";
        }
        bool Gone(CleanupContext context)
        {
            using var key = hive.OpenSubKey(registryRoot + "\\" + context.Application.DisplayName);
            return key is null && !Directory.Exists(context.Application.InstallLocation);
        }
        try
        {
            var alone = contexts["fixture:Roo Industries Busy Alone"];
            var part = ReviewApp(alone);
            var plan = OperationFiles.Read<ApplicationCleanupPreview>(part.PreviewPath, part.ReviewHash);
            check(plan.Registry is not null && plan.Files is not null, "The in-use fixture's cleanup has a registry part and a file part");
            ApplicationCleanupJournal refused;
            using (Holder.Open(Path.Combine(alone.Application.InstallLocation!, "Data", "settings.txt")))
                refused = App(alone.Source, alone.Application.AppId).Apply(part.PreviewPath, part.ReviewHash, part.JournalPath);
            Console.WriteLine("Cleanup with a file open in another program: " + refused.Status + " " + string.Join(" | ", refused.Errors));
            check(refused.Status == "needsReconciliation" && refused.Errors.Any(error => error.Contains("is open in another program", StringComparison.Ordinal)) && Untouched(alone) &&
                !File.Exists(plan.Files!.JournalPath) && !ApplicationCleanup.HasRestorableOperation(refused),
                "An app with a file open in another program is refused before its registry keys or files change, and says which file");
            var resumed = App(alone.Source, alone.Application.AppId).Apply(part.PreviewPath, part.ReviewHash, part.JournalPath);
            check(resumed.Status == "applied" && Gone(alone), "Once the file is closed, running the cleanup again removes the app's registry keys and files");
            var back = App(alone.Source, alone.Application.AppId).Restore(part.JournalPath);
            check(back.Status == "restored" && Untouched(alone), "Restore brings that app's registry keys and files back");

            var one = contexts["fixture:Roo Industries Busy One"];
            var two = contexts["fixture:Roo Industries Busy Two"];
            var parts = new[] { ReviewApp(one), ReviewApp(two) };
            var batchPath = Path.Combine(scope, "operations", "batch-review.json");
            var batchJournal = Path.Combine(scope, "operations", "batch-journal.json");
            CleanupBatch.Preview(batchPath, parts);
            var batch = new CleanupBatch(App);
            CleanupBatchJournal stopped;
            using (Holder.Open(Path.Combine(two.Application.InstallLocation!, "Data", "settings.txt")))
                stopped = batch.Apply(batchPath, OperationFiles.HashFile(batchPath), batchJournal);
            Console.WriteLine("Batch with the second app's file open: " + stopped.Status + " " + string.Join(" | ", stopped.Entries.Select(entry => entry.Status + ":" + entry.Error)));
            check(stopped.Status == "needsReconciliation" && stopped.Entries[0].Status == "applied" && Gone(one) && stopped.Entries[1].Status == "needsReconciliation" && Untouched(two),
                "In a batch, the app with a file open in another program changes nothing, its registry keys included, after the apps before it finish");
            var finished = batch.Apply(batchPath, OperationFiles.HashFile(batchPath), batchJournal);
            check(finished.Status == "applied" && Gone(two), "Resuming the batch once the file is closed finishes that app");
            var restored = batch.Restore(batchJournal);
            check(restored.Status == "restored" && Untouched(one) && Untouched(two), "Restoring the batch brings both apps back");
        }
        finally { if (Directory.Exists(scope)) Remove(scope); }
    }

    // Holds a file open in another process, the way another program would, until disposed.
    sealed class Holder : IDisposable
    {
        readonly Process _process;
        Holder(Process process) => _process = process;

        public static Holder Open(string path)
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true };
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "dotnet") start.ArgumentList.Add(Assembly.GetEntryAssembly()!.Location);
            start.ArgumentList.Add("--file-hold");
            start.ArgumentList.Add(path);
            var process = Process.Start(start) ?? throw new InvalidOperationException("The file holder did not start.");
            if (process.StandardOutput.ReadLine() != "held") { process.Kill(); process.Dispose(); throw new InvalidOperationException("The file holder could not open " + path); }
            return new(process);
        }

        public static void Child(string path)
        {
            using var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            Console.WriteLine("held");
            Console.ReadLine();
        }

        public void Dispose()
        {
            _process.StandardInput.WriteLine();
            if (!_process.WaitForExit(30000)) _process.Kill();
            _process.Dispose();
        }
    }

    public static void HoldFile(string path) => Holder.Child(path);


    static void Thousand(Action<bool, string> check, string root)
    {
        var app = Path.Combine(root, "thousand", "App");
        for (var folder = 0; folder < 50; folder++)
        {
            var directory = Path.Combine(app, "Folder " + folder);
            Directory.CreateDirectory(directory);
            for (var file = 0; file < 20; file++) File.WriteAllBytes(Path.Combine(directory, "file " + file + ".dat"), Enumerable.Repeat((byte)(folder + file), 4096).ToArray());
        }
        var plan = Review(Path.Combine(root, "thousand", "Undo"), app);
        var store = Path.GetDirectoryName(plan.Journal)!;
        var writes = 0;
        var overflow = false;
        using var watcher = new FileSystemWatcher(store, "journal.json.*.tmp") { InternalBufferSize = 65536, NotifyFilter = NotifyFilters.FileName };
        watcher.Created += (_, _) => Interlocked.Increment(ref writes);
        watcher.Error += (_, _) => overflow = true;
        watcher.EnableRaisingEvents = true;
        var timer = Stopwatch.StartNew();
        var applied = plan.Engine.Apply(plan.Review, plan.Hash, plan.Journal);
        var applyTime = timer.Elapsed;
        Thread.Sleep(500);
        var applyWrites = writes;
        timer.Restart();
        var restored = plan.Engine.Restore(plan.Journal);
        var restoreTime = timer.Elapsed;
        Thread.Sleep(500);
        var restoreWrites = writes - applyWrites;
        Console.WriteLine("TIMING " + plan.Plan.Files.Length + " entries (1000 files): apply " + applyTime.TotalMilliseconds.ToString("0") + " ms with " + applyWrites +
            " journal writes, restore " + restoreTime.TotalMilliseconds.ToString("0") + " ms with " + restoreWrites + " journal writes" + (overflow ? " (watcher overflowed)" : ""));
        check(applied.Status == "applied" && restored.Status == "restored" && Mismatches(plan.Plan, _ => true).Length == 0, "A 1,000-file cleanup applies and restores exactly");
        check(!overflow && applyWrites <= 4 && restoreWrites <= 2, "A 1,000-file cleanup writes its journal a few times per run, not once or more per file");
    }

    static int RunChild(int at, string[] step)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath) == "dotnet") start.ArgumentList.Add(Assembly.GetEntryAssembly()!.Location);
        start.ArgumentList.Add("--file-crash");
        foreach (var argument in step) start.ArgumentList.Add(argument);
        start.Environment["ROO_INDUSTRIES_TEST_FILE_CRASH_AT"] = at.ToString();
        using var child = Process.Start(start) ?? throw new InvalidOperationException("The crash child did not start.");
        var output = child.StandardOutput.ReadToEndAsync();
        var errors = child.StandardError.ReadToEndAsync();
        if (!child.WaitForExit(120000)) { child.Kill(); throw new TimeoutException("The crash child did not finish."); }
        if (child.ExitCode != 0 && !string.IsNullOrWhiteSpace(errors.Result)) Console.WriteLine("  child " + step[0] + "@" + at + ": " + errors.Result.Trim().Split('\n')[0]);
        if (child.ExitCode != -1) Console.WriteLine("  child " + step[0] + "@" + at + " output: " + output.Result.Trim());
        return child.ExitCode == 0 && output.Result.Contains("completed", StringComparison.Ordinal) ? 0 : child.ExitCode == 0 ? -2 : child.ExitCode;
    }

    static (FileCleanupEngine Engine, string Review, string Hash, string Journal, FileCleanupPreview Plan) Review(string store, params string[] roots)
    {
        var authority = Authority();
        var engine = new FileCleanupEngine(() => authority);
        var plan = engine.Preview(authority.AppId, authority.ProviderIdentityHash, roots, true);
        Directory.CreateDirectory(store);
        var review = Path.Combine(store, "review.json");
        OperationFiles.Write(review, plan);
        return (engine, review, OperationFiles.HashFile(review), Path.Combine(store, "journal.json"), plan);
    }

    static string Tree(string parent, string name, bool exotic, long big = 0)
    {
        var app = Path.Combine(parent, name);
        var data = Path.Combine(app, "Data");
        Directory.CreateDirectory(data);
        var readme = Path.Combine(app, "readme.txt");
        File.WriteAllText(readme, "original λ readme", new UTF8Encoding(false));
        File.WriteAllBytes(readme + ":extra", [1, 2, 0, 4, 255]);
        File.WriteAllBytes(Path.Combine(data, "settings.bin"), [4, 3, 2, 1, 0]);
        Directory.CreateDirectory(Path.Combine(data, "Empty"));
        if (exotic)
        {
            var elsewhere = Path.Combine(parent, name + " elsewhere");
            Directory.CreateDirectory(elsewhere);
            RefusalChecks.SetSecurity(elsewhere, "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + User + ")(A;OICI;FR;;;WD)", 4);
            File.WriteAllText(Path.Combine(elsewhere, "moved-in.txt"), "inherited from another folder");
            File.Move(Path.Combine(elsewhere, "moved-in.txt"), Path.Combine(data, "moved-in.txt"));
            Directory.Delete(elsewhere);
            File.WriteAllText(Path.Combine(data, "explicit.txt"), "explicit only");
            RefusalChecks.SetSecurity(Path.Combine(data, "explicit.txt"), "D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + User + ")", 4);
            File.WriteAllText(Path.Combine(data, "protected.txt"), "protected");
            RefusalChecks.SetSecurity(Path.Combine(data, "protected.txt"), "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + User + ")", 4);
        }
        if (big > 0) using (var stream = new FileStream(Path.Combine(app, "big.bin"), FileMode.CreateNew)) stream.SetLength(big);
        File.SetAttributes(readme, FileAttributes.ReadOnly | FileAttributes.Hidden);
        return app;
    }

    static string Locked(string parent)
    {
        var folder = Path.Combine(parent, "Locked");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "inside.txt"), "inside a folder the app can't change permissions on");
        // The owner rights entry takes away the owner's built-in right to change permissions, so cleanup copies this folder instead of moving it.
        var security = new DirectorySecurity();
        security.SetSecurityDescriptorSddlForm("D:PAI(A;OICI;FA;;;SY)(A;;0x1301ff;;;OW)(A;OICI;0x1301ff;;;" + User + ")", AccessControlSections.Access);
        new DirectoryInfo(folder).SetAccessControl(security);
        return folder;
    }

    static bool SameObject(string path, FileSnapshot original)
    {
        try { using var lease = FileLease.Open(path); return lease.Capture().Identity == original.Identity; }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidDataException) { return false; }
    }

    static string[] Mismatches(FileCleanupPreview plan, Func<FileSnapshot, bool> sameObject)
    {
        var problems = new List<string>();
        foreach (var file in plan.Files)
        {
            try
            {
                using var lease = FileLease.Open(file.Path);
                var current = lease.Capture();
                var differences = file.Differences(current).ToList();
                if (sameObject(file) && current.Identity != file.Identity) differences.Add("identity");
                if (differences.Count != 0) problems.Add(file.Path + ": " + string.Join(", ", differences));
            }
            catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidDataException) { problems.Add(file.Path + ": " + error.Message); }
        }
        return problems.ToArray();
    }
}
