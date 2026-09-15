using Microsoft.Win32;
using Roo.Optimizer;

static class ApplicationCleanupChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-application-cleanup-" + Guid.NewGuid().ToString("N"));
        var registryRoot = "Software\\RooApplicationCleanupTests\\" + Guid.NewGuid().ToString("N");
        var registryPath = registryRoot + "\\Roo Composite Example";
        var source = Path.Combine(root, "Roo Composite Example");
        Directory.CreateDirectory(source);
        File.WriteAllText(Path.Combine(source, "settings.txt"), "original settings");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using (var key = hive.CreateSubKey(registryPath)) { key.SetValue("Setting", "original registry"); }
        ApplicationCleanupPreview? preview = null;
        try
        {
            var authority = new CleanupAuthority
            {
                AppId = "fixture:composite", ProviderIdentityHash = new string('B', 64), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var application = new CleanupApplication { AppId = authority.AppId, DisplayName = "Roo Composite Example", Publisher = "Roo", InstallLocation = source, PackageFamilyName = null };
            var context = new CleanupContext(Path.Combine(root, "queue.json"), authority, application, [], true);
            var engine = new ApplicationCleanup(() => context, [root], [new("CurrentUser", "Registry64", registryRoot, "key", null)]);
            var scan = engine.Scan(CancellationToken.None);
            var selected = scan.Candidates.Select(item => item.ItemId).ToArray();
            var reviewPath = Path.Combine(root, "operation", "review.json");
            var journalPath = Path.Combine(root, "operation", "journal.json");
            context = context with { Peers = [application with { AppId = "fixture:another", DisplayName = "Another owner", InstallLocation = Path.Combine(source, "shared") }] };
            var rejected = false;
            try { engine.Preview(reviewPath, selected, true, true); } catch (InvalidDataException) { rejected = true; }
            check(rejected && Directory.Exists(source), "A general ownership checkbox cannot authorize a known shared file target");
            context = context with { Peers = [], InventoryComplete = false };
            rejected = false;
            try { engine.Preview(reviewPath, selected, true, true); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Incomplete peer inventory independently blocks cleanup despite confirmed registration absence");
            context = context with { InventoryComplete = true };
            preview = engine.Preview(reviewPath, selected, true, true);
            var hash = OperationFiles.HashFile(reviewPath);
            context = context with { Peers = [application with { AppId = "fixture:new-owner", DisplayName = "New owner" }] };
            var changed = engine.Apply(reviewPath, hash, journalPath);
            using (var unchanged = hive.OpenSubKey(registryPath))
                check(changed.Status == "needsReconciliation" && unchanged?.GetValue("Setting") as string == "original registry" && Directory.Exists(source), "Ownership changes after review prevent both registry and file dispatch");
            context = context with { Peers = [] };
            var applied = engine.Apply(reviewPath, hash, journalPath);
            if (applied.Status != "applied") Console.WriteLine(string.Join("\n", applied.Errors));
            using (var removed = hive.OpenSubKey(registryPath))
                check(applied.Status == "applied" && removed is null && !Directory.Exists(source), "One reviewed application cleanup executes both registry and files with durable part journals");
            var restored = engine.Restore(journalPath);
            if (restored.Status != "restored") Console.WriteLine(string.Join("\n", restored.Errors));
            using (var key = hive.OpenSubKey(registryPath))
                check(restored.Status == "restored" && key?.GetValue("Setting") as string == "original registry" && File.ReadAllText(Path.Combine(source, "settings.txt")) == "original settings", "Combined recovery restores independent original file and registry data");
            check(engine.Apply(reviewPath, hash, journalPath).Status == "restored" && Directory.Exists(source), "A duplicate apply cannot restart deletion after restoration begins");
        }
        finally
        {
            if (preview?.Registry is { } part)
            {
                var registry = OperationFiles.Read<RegistryCleanupPreview>(part.PreviewPath);
                hive.DeleteSubKeyTree(registry.Receipt.KeyPath, false);
            }
            hive.DeleteSubKeyTree(registryRoot, false);
            using (var parent = hive.OpenSubKey("Software\\RooApplicationCleanupTests"))
                if (parent is not null && parent.SubKeyCount == 0 && parent.ValueCount == 0) hive.DeleteSubKey("Software\\RooApplicationCleanupTests", false);
            Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Combined cleanup validation removes all owned files, registry data and commit receipts");
    }
}
