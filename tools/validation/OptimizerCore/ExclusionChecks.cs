using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class ExclusionChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("exclusions");
        var registryRoot = "Software\\RooIndustriesExclusionTests\\" + Guid.NewGuid().ToString("N");
        var source = Path.Combine(root, "Roo Industries Exclusion Example");
        var keyPath = registryRoot + "\\Roo Industries Exclusion Example";
        var keyAddress = new RegistryAddress("CurrentUser", "Registry64", keyPath, "key", null);
        Directory.CreateDirectory(source);
        var file = Path.Combine(source, "settings.txt");
        File.WriteAllText(file, "independent file sentinel");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        OwnedRegistryKey? owned = null;
        ApplicationCleanupPreview? preview = null;
        void Reject(Action action, string message)
        {
            var rejected = false;
            try { action(); } catch (InvalidDataException) { rejected = true; } catch (JsonException) { rejected = true; }
            check(rejected, message);
        }
        try
        {
            owned = OwnedRegistryKey.Create(hive, registryRoot);
            using (var key = hive.CreateSubKey(keyPath))
            {
                key.SetValue("", "default sentinel");
                key.SetValue("Named", "named sentinel");
            }
            var paths = new CleanupExclusions { Paths = [file], Registry = [] };
            var matcher = new CleanupExclusionMatcher(paths);
            check(matcher.Match(file.ToUpperInvariant(), false) is not null && matcher.Match(source, true) is not null,
                "An excluded file protects itself and a selected containing directory");
            check(matcher.Match(source + " Other", true) is null, "A similar path prefix is not an excluded descendant");
            matcher = new(new() { Paths = [Path.Combine(source, "future", "settings.txt")], Registry = [] });
            check(matcher.Match(source, true) is not null, "A future excluded path protects its existing containing folder");
            var shortPath = new StringBuilder(32768);
            var shortLength = GetShortPathName(file, shortPath, (uint)shortPath.Capacity);
            if (shortLength != 0 && !string.Equals(file, shortPath.ToString(), StringComparison.OrdinalIgnoreCase))
                check(new CleanupExclusionMatcher(paths).Match(shortPath.ToString(), false) is not null, "An alternate DOS path cannot bypass a canonical file exclusion");
            else Console.WriteLine("UNAVAILABLE Alternate DOS name: this volume did not supply a distinct short path");
            using (var held = FileLease.Open(file, writable: true))
                check(new CleanupExclusionMatcher(paths).Match(file, false) is not null, "Exclusion checks coexist with retained cleanup deletion handles");

            var valueAddress = keyAddress with { Kind = "value", ValueName = "" };
            var registry = new CleanupExclusions { Paths = [], Registry = [valueAddress] };
            matcher = new(registry);
            check(matcher.Match(valueAddress) is not null && matcher.Match(keyAddress) is not null,
                "An excluded default value protects that value and whole-key deletion");
            check(matcher.Match(valueAddress with { ValueName = "Named" }) is null, "An excluded default value does not exclude a different value");
            check(matcher.Match(valueAddress with { View = "Registry32" }) is not null,
                "The shared current-user registry view cannot bypass an exclusion");
            check(matcher.Match(valueAddress with { Hive = "LocalMachine" }) is null, "An exclusion does not confuse current-user and machine registry identities");
            matcher = new(new() { Paths = [], Registry = [valueAddress with { ValueName = "Named" }] });
            check(matcher.Match(valueAddress with { ValueName = "named" }) is not null && matcher.Match(valueAddress with { ValueName = "NamedMore" }) is null,
                "Named registry exclusions match case-insensitively without consuming a neighboring value");
            if (Environment.Is64BitOperatingSystem)
            {
                matcher = new(new() { Paths = [], Registry = [keyAddress with { Hive = "LocalMachine" }] });
                check(matcher.Match(keyAddress with { Hive = "LocalMachine", View = "Registry32" }) is null,
                    "Separate machine registry views retain distinct exclusion identities");
            }
            matcher = new(new() { Paths = [], Registry = [keyAddress with { KeyPath = keyPath + "\\Future" }] });
            check(matcher.Match(keyAddress) is not null, "A future excluded registry child protects its containing whole key");

            var storePath = Path.Combine(root, "policy.json");
            var store = new CleanupExclusionStore(storePath);
            check(store.Read().Revision is null, "An absent exclusion document is explicitly distinguishable from a saved empty policy");
            var first = store.Save(paths, null);
            Reject(() => store.Save(CleanupExclusions.Empty, null), "A stale policy editor cannot overwrite existing exclusions");
            var second = store.Save(registry, first.Revision);
            check(second.Revision != first.Revision && store.Read().Exclusions.Registry.Single().ValueName == "", "Exclusions persist exact default-value identity with a new revision");
            using (var barrier = new Barrier(2))
            {
                var writers = new[] { paths, CleanupExclusions.Empty }.Select(proposed => Task.Run(() =>
                {
                    barrier.SignalAndWait();
                    try { store.Save(proposed, second.Revision); return true; }
                    catch (IOException) { return false; }
                })).ToArray();
                Task.WaitAll(writers);
                var winner = store.Read();
                check(writers.Count(writer => writer.Result) == 1 && winner.Revision != second.Revision &&
                    (winner.Exclusions.Paths.SequenceEqual(paths.Paths) || winner.Exclusions.Paths.Length == 0) && winner.Exclusions.Registry.Length == 0,
                    "Concurrent exclusion editors commit one complete revision without losing the winner's data");
            }
            var bytes = File.ReadAllBytes(storePath);
            File.WriteAllText(storePath, "{\"schemaVersion\":1}");
            Reject(() => store.Read(), "Incomplete policy data cannot become an empty exclusion list");
            File.WriteAllBytes(storePath, bytes);
            var saved = OperationFiles.Read<CleanupExclusionDocument>(storePath);
            OperationFiles.Write(storePath, saved with { Owner = saved.Owner with { Machine = "another-computer" } });
            Reject(() => store.Read(), "Another machine's exclusions cannot be adopted silently");
            File.WriteAllBytes(storePath, bytes);
            Reject(() => new CleanupExclusions { Paths = ["relative\\path"], Registry = [] }.Validate(), "Relative file exclusions are rejected");
            Reject(() => new CleanupExclusions { Paths = [file, file.ToUpperInvariant()], Registry = [] }.Validate(), "Duplicate file exclusions are rejected without case ambiguity");
            Reject(() => new CleanupExclusions { Paths = [], Registry = [valueAddress with { ValueName = null }] }.Validate(), "A missing value name is not the default registry value");

            var authority = new CleanupAuthority
            {
                AppId = "fixture:exclusions", ProviderIdentityHash = new string('E', 64), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var app = new CleanupApplication { AppId = authority.AppId, DisplayName = "Roo Industries Exclusion Example", Publisher = "Roo Industries", InstallLocation = source, PackageFamilyName = null };
            var context = new CleanupContext(Path.Combine(root, "queue.json"), authority, app, [], true);
            var policy = paths;
            var policyUnavailable = false;
            var engine = new ApplicationCleanup(() => context, [root], [new("CurrentUser", "Registry64", registryRoot, "key", null)],
                () => policyUnavailable ? throw new InvalidDataException("Fixture policy unreadable") : policy);
            var scan = engine.Scan(CancellationToken.None);
            var folder = scan.Candidates.Single(item => item.Target == source);
            check(folder.Protected && folder.Evidence.Any(reason => reason.StartsWith("Excluded path:")), "Discovery exposes the exclusion and disables a folder containing protected data");
            var reviewPath = Path.Combine(root, "operation", "preview.json");
            var journalPath = Path.Combine(root, "operation", "journal.json");
            Reject(() => engine.Preview(reviewPath, [folder.ItemId], true, true), "Manual ownership approval cannot override a cleanup exclusion");
            policy = registry;
            scan = engine.Scan(CancellationToken.None);
            check(scan.Candidates.Single(item => item.Registry == keyAddress).Protected, "Discovery protects a whole key containing an excluded value");
            policy = CleanupExclusions.Empty;
            scan = engine.Scan(CancellationToken.None);
            preview = engine.Preview(reviewPath, scan.Candidates.Select(item => item.ItemId).ToArray(), true, true);
            var hash = OperationFiles.HashFile(reviewPath);
            policy = paths;
            var denied = engine.Apply(reviewPath, hash, journalPath);
            using (var key = hive.OpenSubKey(keyPath))
                check(denied.Status == "needsReconciliation" && File.ReadAllText(file) == "independent file sentinel" && key?.GetValue("") as string == "default sentinel",
                    "An exclusion added after review blocks both file and registry deletion before dispatch");
            policy = new()
            {
                Paths = [Path.Combine(root, "Unrelated retained folder")],
                Registry = [keyAddress with { KeyPath = registryRoot + "\\Unrelated retained key" }],
            };
            var applied = engine.Apply(reviewPath, hash, journalPath);
            if (applied.Status != "applied") Console.WriteLine(string.Join("\n", applied.Errors));
            using (var key = hive.OpenSubKey(keyPath))
                check(applied.Status == "applied" && !Directory.Exists(source) && key is null, "Removing the exclusion permits only the previously reviewed fixture targets");
            policyUnavailable = true;
            var restored = engine.Restore(journalPath);
            using (var key = hive.OpenSubKey(keyPath))
                check(restored.Status == "restored" && File.ReadAllText(file) == "independent file sentinel" && key?.GetValue("Named") as string == "named sentinel",
                    "Recovery remains available when the exclusion policy can no longer be read");
        }
        finally
        {
            if (preview?.Registry is { } part) hive.DeleteSubKeyTree(OperationFiles.Read<RegistryCleanupPreview>(part.PreviewPath).Receipt.KeyPath, false);
            owned?.Dispose();
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Exclusion validation removes its owned files, registry data and receipts");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetShortPathName(string path, StringBuilder shortPath, uint size);
}
