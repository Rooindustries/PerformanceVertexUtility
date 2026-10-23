using Microsoft.Win32;
using RooIndustries.Optimizer;

static class PublishedPathChecks
{
    public static void Run(Action<bool, string> check, string[] scenarios)
    {
        var cases = new Dictionary<string, Action>(StringComparer.Ordinal)
        {
            ["quoted"] = () => Quoted(check),
            ["registry-separators"] = () => RegistrySeparators(check),
            ["invalid-peer-space"] = () => InvalidPeer(check, "Vendor "),
            ["invalid-peer-colon"] = () => InvalidPeer(check, "Vendor:Component"),
            ["odd-entry"] = () => OddEntry(check),
        };
        foreach (var name in scenarios.Length == 0 ? cases.Keys.ToArray() : scenarios)
            if (cases.TryGetValue(name, out var run)) run(); else throw new ArgumentException("Unknown published-path scenario: " + name);
    }

    private static CleanupApplication Application(string path) => new()
    {
        AppId = "fixture:published-path", DisplayName = "Roo Industries Example", Publisher = "Fixture", InstallLocation = path, PackageFamilyName = null,
    };

    private static ApplicationCleanup Engine(string root, CleanupApplication application, CleanupApplication peer, string[] fileRoots, RegistryAddress[] registryRoots)
    {
        var authority = new CleanupAuthority { AppId = application.AppId, ProviderIdentityHash = new string('A', 64), Owner = OperationOwner.Current(), ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true };
        var context = new CleanupContext(Path.Combine(root, "queue.json"), authority, application, [peer], true);
        return new ApplicationCleanup(() => context, fileRoots, registryRoots);
    }

    private static void Quoted(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("published-quoted");
        try
        {
            var selected = Path.Combine(root, "Roo Industries Example");
            var owned = Path.Combine(selected, "Shared add-on");
            var scope = Path.Combine(root, "unrelated");
            var unrelated = Path.Combine(scope, "Roo Industries Example");
            Directory.CreateDirectory(owned); Directory.CreateDirectory(unrelated);
            File.WriteAllText(Path.Combine(unrelated, "settings.txt"), "fixture");
            var application = Application(selected);
            var peer = application with { AppId = "fixture:quoted-peer", DisplayName = "Independent quoted tool", InstallLocation = " \t\"" + owned + "\\\" \r\n" };
            var engine = Engine(root, application, peer, [scope], []);
            var scan = engine.Scan(CancellationToken.None);
            var shared = scan.Candidates.Single(item => item.Target == selected);
            var independent = scan.Candidates.Single(item => item.Target == unrelated);
            check(scan.Complete && shared.OwnershipComplete && shared.SharedOwners.Contains(peer.DisplayName), "A quoted, padded install path retains its folder's shared owner");
            check(independent.OwnershipComplete && independent.SharedOwners.Count == 0, "A quoted peer does not make unrelated file ownership incomplete");
            var review = engine.Preview(Path.Combine(root, "unrelated-review", "review.json"), [independent.ItemId], true, true);
            check(review.Files is not null && File.ReadAllText(Path.Combine(unrelated, "settings.txt")) == "fixture", "An unrelated folder remains previewable with the quoted app installed");
            var emptyPeer = peer with { InstallLocation = " \t\"  \" \r\n" };
            var emptyScan = new LeftoverDiscovery(application, [emptyPeer]).Scan(CancellationToken.None, [scope], []);
            check(emptyScan.Complete && emptyScan.Candidates.Any(item => item.Target == unrelated) && emptyScan.Candidates.All(item => item.OwnershipComplete), "A quoted empty install location has the same meaning as an absent published path");
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "Quoted-path checks remove their previews and fixtures");
    }

    private static void RegistrySeparators(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("published-registry");
        var keyPath = "Software\\RooIndustriesPublishedPathTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        OwnedRegistryKey? owned = null;
        try
        {
            owned = OwnedRegistryKey.Create(hive, keyPath);
            var peerRoot = Path.Combine(root, "Installed Peer"); Directory.CreateDirectory(peerRoot);
            var address = new RegistryAddress("CurrentUser", "Registry64", keyPath, "key", null);
            var application = Application(Path.Combine(root, "removed"));
            using var key = hive.CreateSubKey(keyPath + "\\Roo Industries Example");
            var index = 0;
            foreach (var peerPath in new[] { peerRoot, peerRoot.Replace('\\', '/') })
                foreach (var reference in new[] { peerRoot + "\\x.dll", peerRoot.Replace('\\', '/') + "/x.dll" })
                {
                    key.SetValue("OtherProduct", reference);
                    var peer = application with { AppId = "fixture:registry-peer", DisplayName = "Independent registry tool", InstallLocation = peerPath };
                    var engine = Engine(root, application, peer, [], [address]);
                    var candidate = engine.Scan(CancellationToken.None).Candidates.Single(item => item.Registry?.Kind == "key" && item.Registry.KeyPath.EndsWith("\\Roo Industries Example", StringComparison.Ordinal));
                    check(candidate.SharedOwners.Contains(peer.DisplayName), "Registry ownership retains either separator form (" + index + ")");
                    var refused = false;
                    try { engine.Preview(Path.Combine(root, "review-" + index, "review.json"), [candidate.ItemId], true, true); }
                    catch (InvalidDataException) { refused = true; }
                    check(refused && key.GetValue("OtherProduct") as string == reference, "Shared registry preview refuses deletion and preserves the path reference (" + index + ")");
                    index++;
                }
        }
        finally
        {
            owned?.Dispose();
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root) && hive.OpenSubKey(keyPath) is null, "Registry separator checks remove their keys and fixtures");
    }

    private static void InvalidPeer(Action<bool, string> check, string component)
    {
        var root = TestFixtures.InheritingRoot("published-invalid");
        try
        {
            var selected = Path.Combine(root, "Roo Industries Example"); Directory.CreateDirectory(selected);
            File.WriteAllText(Path.Combine(selected, "settings.txt"), "fixture");
            var application = Application(selected);
            var peer = application with { AppId = "fixture:invalid-peer", DisplayName = "Independent malformed tool", InstallLocation = Path.Combine(root, component, "App") };
            var engine = Engine(root, application, peer, [], []);
            var candidate = engine.Scan(CancellationToken.None).Candidates.Single(item => item.Target == selected);
            check(!candidate.OwnershipComplete && candidate.Evidence.Any(item => item.Contains(peer.DisplayName, StringComparison.Ordinal)), "An unsupported peer component stays unknown and names the blocking app: " + component);
            var refused = false;
            try { engine.Preview(Path.Combine(root, "review", "review.json"), [candidate.ItemId], true, true); }
            catch (InvalidDataException) { refused = true; }
            check(refused && File.ReadAllText(Path.Combine(selected, "settings.txt")) == "fixture", "An unsupported peer component refuses preview and preserves the selected folder");
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "Unsupported peer-path checks remove their fixtures");
    }

    private static void OddEntry(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("published-odd-entry");
        var scope = Path.Combine(root, "scope");
        var odd = @"\\?\" + Path.Combine(scope, "odd. ");
        var created = false;
        try
        {
            var selected = Path.Combine(scope, "Roo Industries Example"); Directory.CreateDirectory(selected);
            File.WriteAllText(Path.Combine(selected, "settings.txt"), "fixture");
            Directory.CreateDirectory(odd);
            created = true;
            var application = Application(Path.Combine(root, "absent"));
            var scan = new LeftoverDiscovery(application, []).Scan(CancellationToken.None, [scope], []);
            check(scan.Candidates.Any(item => item.Target == selected) && !scan.Complete && scan.Errors.Any(item => item.Contains("odd. ", StringComparison.Ordinal)), "One literal trailing-dot/space entry is reported without hiding the other folder candidates");
            using var lease = FileLease.Open(scope);
            var refused = false;
            try { _ = lease.Children(); } catch (InvalidDataException) { refused = true; }
            check(refused && File.ReadAllText(Path.Combine(selected, "settings.txt")) == "fixture", "Deletion-tree enumeration still refuses an ambiguous child name and preserves all data");
        }
        finally { if (created) Directory.Delete(odd); Directory.Delete(root, true); }
        check(!Directory.Exists(root), "Unusual directory-name checks remove the exact extended-path fixture");
    }
}
