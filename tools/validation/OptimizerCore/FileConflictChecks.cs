using System.ComponentModel;
using System.Runtime.InteropServices;
using RooIndustries.Optimizer;

static class FileConflictChecks
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLink(string link, string existing, IntPtr security);

    public static void Run(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("file-conflicts");
        Directory.CreateDirectory(root);
        var authority = new CleanupAuthority
        {
            AppId = "fixture:file-conflicts", ProviderIdentityHash = new string('C', 64), Owner = OperationOwner.Current(),
            ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
        };
        var engine = new FileCleanupEngine(() => authority);
        var directoryLinks = new List<string>();
        try
        {
            var outside = Path.Combine(root, "outside-link-target");
            Directory.CreateDirectory(outside);
            File.WriteAllText(Path.Combine(outside, "sentinel.txt"), "outside data");
            var directoryLink = Path.Combine(root, "directory-link");
            TestFixtures.Symlink(directoryLink, outside);
            directoryLinks.Add(directoryLink);
            foreach (var target in new[] { directoryLink, Path.Combine(directoryLink, "sentinel.txt") })
            {
                var blocked = false;
                try { engine.Preview(authority.AppId, authority.ProviderIdentityHash, [target], true); }
                catch (InvalidDataException error) when (error.Message.Contains("Reparse")) { blocked = true; }
                check(blocked && File.ReadAllText(Path.Combine(outside, "sentinel.txt")) == "outside data", "A directory reparse point cannot redirect root or ancestor capture");
            }
            var linkedTree = Path.Combine(root, "tree-with-link");
            Directory.CreateDirectory(linkedTree);
            var descendant = Path.Combine(linkedTree, "redirect");
            TestFixtures.Symlink(descendant, outside);
            directoryLinks.Add(descendant);
            var treeBlocked = false;
            try { engine.Preview(authority.AppId, authority.ProviderIdentityHash, [linkedTree], true); }
            catch (InvalidDataException error) when (error.Message.Contains("Reparse")) { treeBlocked = true; }
            check(treeBlocked && File.ReadAllText(Path.Combine(outside, "sentinel.txt")) == "outside data", "A reparse descendant prevents recursive cleanup without touching its destination");
            var shared = Path.Combine(root, "shared.bin");
            var link = Path.Combine(root, "hard-link.bin");
            File.WriteAllBytes(shared, [1, 2, 3, 4]);
            if (!CreateHardLink(link, shared, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var rejected = false;
            try { engine.Preview(authority.AppId, authority.ProviderIdentityHash, [link], true); }
            catch (InvalidDataException error) when (error.Message.Contains("Hard-linked")) { rejected = true; }
            check(rejected && File.ReadAllBytes(shared).SequenceEqual(new byte[] { 1, 2, 3, 4 }) && File.Exists(link), "Hard-link ownership ambiguity is rejected without changing either file name");
            File.Delete(link);

            var busy = Path.Combine(root, "active-writer.bin");
            File.WriteAllBytes(busy, [7, 8, 9]);
            using (var writer = new FileStream(busy, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
            {
                rejected = false;
                try { engine.Preview(authority.AppId, authority.ProviderIdentityHash, [busy], true); }
                catch (Win32Exception error) when (error.NativeErrorCode == 32) { rejected = true; }
                check(rejected && writer.Length == 3, "An existing writable handle prevents capture rather than being treated as a stable file");
            }

            var replaced = Path.Combine(root, "replaced.bin");
            var original = Path.Combine(root, "original-retained.bin");
            File.WriteAllBytes(replaced, [4, 5, 6]);
            var preview = engine.Preview(authority.AppId, authority.ProviderIdentityHash, [replaced], true);
            var path = Path.Combine(root, "replacement-review.json");
            OperationFiles.Write(path, preview);
            File.Move(replaced, original);
            File.Copy(original, replaced);
            var result = engine.Apply(path, OperationFiles.HashFile(path), Path.Combine(root, "replacement-journal.json"));
            check(result.Status == "needsReconciliation" && File.Exists(original) && File.ReadAllBytes(replaced).SequenceEqual(new byte[] { 4, 5, 6 }), "A replacement with identical bytes cannot reuse the reviewed file identity");

            var directory = Path.Combine(root, "new-child");
            Directory.CreateDirectory(directory);
            var approved = Path.Combine(directory, "approved.txt");
            var inserted = Path.Combine(directory, "unreviewed.txt");
            File.WriteAllText(approved, "approved original");
            var armed = false;
            var calls = 0;
            var racing = new FileCleanupEngine(() =>
            {
                if (armed && ++calls == 2) File.WriteAllText(inserted, "independent writer");
                return authority;
            });
            preview = racing.Preview(authority.AppId, authority.ProviderIdentityHash, [directory], true);
            path = Path.Combine(root, "new-child-review.json");
            var journal = Path.Combine(root, "new-child-journal.json");
            OperationFiles.Write(path, preview);
            armed = true;
            result = racing.Apply(path, OperationFiles.HashFile(path), journal);
            check(result.Status == "needsReconciliation" && !File.Exists(approved) && File.ReadAllText(inserted) == "independent writer", "A child inserted after backup survives while only the reviewed file is deleted");
            var restored = racing.Restore(journal);
            check(restored.Status == "restored" && File.ReadAllText(approved) == "approved original" && File.ReadAllText(inserted) == "independent writer", "Partial cleanup recovery preserves an unreviewed child and restores the deleted file");
        }
        finally
        {
            foreach (var link in directoryLinks) Directory.Delete(link);
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "File-conflict fixtures leave no links, files, backups or journals");
    }
}
