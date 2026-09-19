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
    }
}
