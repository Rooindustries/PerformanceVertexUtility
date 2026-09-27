using Microsoft.Win32;
using RooIndustries.Optimizer;

static class DiscoveryChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-discovery-" + Guid.NewGuid().ToString("N"));
        var registryRoot = "Software\\RooIndustriesDiscoveryTests\\" + Guid.NewGuid().ToString("N");
        var local = Path.Combine(root, "Local");
        var programs = Path.Combine(root, "Programs");
        var install = Path.Combine(programs, "Roo Industries Example");
        var other = Path.Combine(install, "Shared add-on");
        var independent = Path.Combine(programs, "Independent tool");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        Directory.CreateDirectory(other);
        Directory.CreateDirectory(Path.Combine(local, "Roo Industries Example"));
        Directory.CreateDirectory(Path.Combine(local, "Roo Industries Example Backup"));
        try
        {
            using (var app = hive.CreateSubKey(registryRoot + "\\Roo Industries Example"))
            {
                app.SetValue("InstallPath", install);
                app.SetValue("BothPrograms", "\"" + Path.Combine(install, "main.exe") + "\" \"" + Path.Combine(other, "addon.exe") + "\"");
                using var child = app.CreateSubKey("Shared component");
                child.SetValue("OtherProductOnly", independent);
            }
            using (var unrelated = hive.CreateSubKey(registryRoot + "\\Unrelated"))
            {
                unrelated.SetValue("Command", "\"" + Path.Combine(install, "main.exe") + "\" --open");
                unrelated.SetValue("PrefixOnly", "\"" + install + "-Other\\main.exe\"");
            }
            var application = new CleanupApplication { AppId = "fixture:discovery", DisplayName = "Roo Industries Example", Publisher = "Roo Industries", InstallLocation = install, PackageFamilyName = null };
            var peer = new CleanupApplication { AppId = "fixture:other", DisplayName = "Independent add-on", Publisher = "Roo Industries", InstallLocation = other, PackageFamilyName = null };
            var independentPeer = peer with { AppId = "fixture:independent", DisplayName = "Independent tool", InstallLocation = independent };
            var scan = new LeftoverDiscovery(application, [peer, independentPeer]).Scan(CancellationToken.None, [local, programs],
                [new("CurrentUser", "Registry64", registryRoot, "key", null), new("CurrentUser", "Registry32", registryRoot, "key", null)]);
            if (!scan.Complete) Console.WriteLine(string.Join("\n", scan.Errors));
            check(scan.Complete, "Bounded discovery reports complete coverage only after all configured scopes were read");
            check(scan.Candidates.Any(item => item.Target == Path.Combine(local, "Roo Industries Example")) && !scan.Candidates.Any(item => item.Target == Path.Combine(local, "Roo Industries Example Backup")), "File discovery uses product-name boundaries instead of matching arbitrary name prefixes");
            check(scan.Candidates.Single(item => item.Target == install).SharedOwners.Contains(peer.DisplayName), "An installation-path match retains a conflicting nested app owner");
            check(scan.Candidates.Any(item => item.Registry?.ValueName == "Command") && !scan.Candidates.Any(item => item.Registry?.ValueName == "PrefixOnly"), "Registry path references match complete path boundaries");
            check(scan.Candidates.Single(item => item.Registry?.Kind == "key" && item.Registry.KeyPath.EndsWith("\\Roo Industries Example")).SharedOwners.Contains(peer.DisplayName), "A favorable key-name match retains shared-owner evidence from its values");
            check(scan.Candidates.Single(item => item.Registry?.Kind == "key" && item.Registry.KeyPath.EndsWith("\\Roo Industries Example")).SharedOwners.Contains(independentPeer.DisplayName), "Whole-key review retains another product's references even when that value does not mention the removed app");
            check(scan.Candidates.Select(item => item.ItemId).Distinct().Count() == scan.Candidates.Length && scan.Candidates.Count(item => item.Registry?.ValueName == "Command") == 1, "Shared-view registry candidates are deduplicated by physical identity");
        }
        finally
        {
            hive.DeleteSubKeyTree(registryRoot, false);
            using (var parent = hive.OpenSubKey("Software\\RooIndustriesDiscoveryTests"))
                if (parent is not null && parent.SubKeyCount == 0 && parent.ValueCount == 0) hive.DeleteSubKey("Software\\RooIndustriesDiscoveryTests", false);
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root) && hive.OpenSubKey(registryRoot) is null, "Discovery validation leaves no file or registry fixtures");
        ProductBoundaries(check);
    }

    private static void ProductBoundaries(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-discovery-names-" + Guid.NewGuid().ToString("N"));
        var registryRoot = "Software\\RooIndustriesDiscoveryTests\\" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        foreach (var name in new[] { "Notepad++", "Notepad", "7Zip", "ATT Connect" }) Directory.CreateDirectory(Path.Combine(root, name));
        try
        {
            foreach (var path in new[] { "Notepad++", "Notepad", "Microsoft\\Notepad", "Microsoft\\Edge", "Policies\\Notepad++", "Edge", "Tools\\Microsoft", "7-Zip", "ATT Connect", "Policies\\Notepad", "Classes\\Folder", "Folder" })
                hive.CreateSubKey(registryRoot + "\\" + path).Dispose();
            RegistryAddress[] scopes = [new("CurrentUser", "Registry64", registryRoot, "key", null), new("CurrentUser", "Registry32", registryRoot, "key", null)];
            CleanupApplication Product(string id, string name, string? publisher, string? family = null) => new() { AppId = id, DisplayName = name, Publisher = publisher, InstallLocation = null, PackageFamilyName = family };
            var windowsNotepad = Product("appx:notepad", "Notepad", "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US", "Microsoft.WindowsNotepad_8wekyb3d8bbwe");
            var notepadPlus = Product("registry:notepad++", "Notepad++ (64-bit x64)", "Notepad++ Team");
            LeftoverCandidate[] Scan(CleanupApplication app, params CleanupApplication[] peers) => new LeftoverDiscovery(app, peers).Scan(CancellationToken.None, [root], scopes).Candidates;
            string[] Keys(IEnumerable<LeftoverCandidate> items) => items.Where(item => item.Kind == "registryKey").Select(item => item.Registry!.KeyPath[(registryRoot.Length + 1)..]).Order().ToArray();
            string[] Folders(IEnumerable<LeftoverCandidate> items) => items.Where(item => item.Kind == "folder" && item.Target.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)).Select(item => Path.GetFileName(item.Target)).Order().ToArray();
            var plus = Scan(notepadPlus, windowsNotepad);
            check(Keys(plus).SequenceEqual(["Notepad++"]) && Folders(plus).SequenceEqual(["Notepad++"]),
                "Notepad++ matches only its own key and folder, never Notepad or Microsoft\\Notepad: " + string.Join(", ", Keys(plus).Concat(Folders(plus))));
            check(plus.All(item => item.SharedOwners.Count == 0), "Windows Notepad is not recorded as a co-owner of Notepad++ leftovers");
            var notepad = Scan(windowsNotepad, notepadPlus);
            check(Keys(notepad).SequenceEqual(["Notepad"]) && Folders(notepad).SequenceEqual(["Notepad"]),
                "A Microsoft-published Notepad is never offered the shared Microsoft key and never matches Notepad++: " + string.Join(", ", Keys(notepad).Concat(Folders(notepad))));
            var microsoftEdge = Scan(Product("registry:microsoft-edge", "Edge", "Microsoft Corporation"));
            check(Keys(microsoftEdge).SequenceEqual(["Edge"]), "A Microsoft-published desktop app is never offered keys under a Microsoft root: " + string.Join(", ", Keys(microsoftEdge)));
            var microsoftData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "RooIndustriesDiscovery" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(microsoftData);
            try
            {
                using (var progIds = hive.CreateSubKey(registryRoot + "\\ProgIds")) progIds.SetValue("Open", "\"" + Path.Combine(microsoftData, "app.exe") + "\" \"%1\"");
                var installed = new LeftoverDiscovery(Product("registry:microsoft-data", "Roo Industries Microsoft Data", "Roo Industries") with { InstallLocation = microsoftData }, []).Scan(CancellationToken.None, [root], scopes).Candidates;
                check(!installed.Any(item => item.Target.StartsWith(microsoftData, StringComparison.OrdinalIgnoreCase)), "An install location under a Microsoft-owned folder is never offered as a leftover: " + string.Join(", ", installed.Select(item => item.Target)));
                check(!installed.Any(item => item.Kind == "registryValue"), "Registry values pointing into a Microsoft-owned install location are never offered: " + string.Join(", ", installed.Select(item => item.Target)));
            }
            finally { Directory.Delete(microsoftData, true); }
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var drive = Path.GetPathRoot(local)!;
            string[] owned = [Path.Combine(local, "Packages", "Microsoft.GamingApp_8wekyb3d8bbwe", "LocalState"), Path.Combine(local, "Packages", "Microsoft.Windows.Photos_cw5n1h2txyewy"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "ModifiableWindowsApps", "Game"), Path.Combine(drive, "XboxGames", "Game"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "LocalLow", "Microsoft", "CryptnetUrlCache")];
            check(owned.All(LeftoverDiscovery.MicrosoftOwnedPath), "Microsoft package data, ModifiableWindowsApps, XboxGames and LocalLow\\Microsoft are Windows-owned: " + string.Join(", ", owned.Where(path => !LeftoverDiscovery.MicrosoftOwnedPath(path))));
            check(!LeftoverDiscovery.MicrosoftOwnedPath(Path.Combine(local, "Packages", "Vendor.App_abcdefghjk123")) && !LeftoverDiscovery.MicrosoftOwnedPath(Path.Combine(drive, "Games", "XboxGames")), "Third-party package data and similarly named folders elsewhere stay eligible");
            var edge = Scan(Product("registry:edge", "Edge", "Edge Labs"));
            check(Keys(edge).SequenceEqual(["Edge"]), "A short third-party name never offers the Microsoft key it shares: " + string.Join(", ", Keys(edge)));
            var folder = Scan(Product("registry:folder", "Folder", "Folder Tools"));
            check(Keys(folder).SequenceEqual(["Folder"]), "A Windows-owned class key is never offered even when its name matches: " + string.Join(", ", Keys(folder)));
            var tools = Scan(Product("registry:tools", "Tools", "Tool Makers")).Single(item => item.Kind == "registryKey");
            check(tools.SharedOwners.Contains("Windows"), "A matched key holding a Microsoft subtree stays shared with Windows and cannot be selected");
            var zip = Scan(Product("registry:7zip", "7-Zip 24.08 (x64)", "Igor Pavlov"));
            check(Keys(zip).SequenceEqual(["7-Zip"]) && Folders(zip).SequenceEqual(["7Zip"]), "Separator punctuation still matches the same product: " + string.Join(", ", Keys(zip).Concat(Folders(zip))));
            var att = Scan(Product("registry:att", "AT&T Connect", "AT&T"));
            check(att.Length == 0, "An ampersand is significant, so AT&T Connect does not match ATT Connect: " + string.Join(", ", att.Select(item => item.Target)));
            var sharp = Scan(Product("registry:sharp", "Notepad#", "Sharp Tools"));
            check(sharp.Length == 0, "A hash is significant, so Notepad# does not match Notepad: " + string.Join(", ", sharp.Select(item => item.Target)));
        }
        finally
        {
            hive.DeleteSubKeyTree(registryRoot, false);
            using (var parent = hive.OpenSubKey("Software\\RooIndustriesDiscoveryTests"))
                if (parent is not null && parent.SubKeyCount == 0 && parent.ValueCount == 0) hive.DeleteSubKey("Software\\RooIndustriesDiscoveryTests", false);
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root) && hive.OpenSubKey(registryRoot) is null, "Product-boundary validation leaves no file or registry fixtures");
    }
}
