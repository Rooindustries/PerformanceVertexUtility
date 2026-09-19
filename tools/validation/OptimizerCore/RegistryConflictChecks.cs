using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class RegistryConflictChecks
{
    [DllImport("advapi32.dll", EntryPoint = "RegCreateKeyExW", CharSet = CharSet.Unicode)]
    static extern int CreateKey(SafeRegistryHandle parent, string name, uint reserved, string? @class, uint options, uint access,
        IntPtr security, out SafeRegistryHandle key, out uint disposition);
    [DllImport("advapi32.dll", EntryPoint = "RegSetValueExW", CharSet = CharSet.Unicode)]
    static extern int SetValue(SafeRegistryHandle key, string name, uint reserved, uint type, byte[] data, uint length);
    [DllImport("advapi32.dll", EntryPoint = "RegOpenKeyExW", CharSet = CharSet.Unicode)]
    static extern int OpenKey(SafeRegistryHandle parent, string name, uint options, uint access, out SafeRegistryHandle key);
    [DllImport("ntdll.dll")] static extern int NtDeleteKey(SafeRegistryHandle key);

    private static void DeleteLink(SafeRegistryHandle parent, string path)
    {
        var status = OpenKey(parent, path, 8, 0x10101, out var key);
        if (status == 2) { key?.Dispose(); return; }
        if (status != 0) throw new Win32Exception(status, "Opening the disposable registry link for removal failed.");
        using (key)
        {
            var result = NtDeleteKey(key);
            if (result < 0) throw new InvalidOperationException("Removing the disposable link failed with NTSTATUS 0x" + unchecked((uint)result).ToString("X8"));
        }
    }

    public static void Run(Action<bool, string> check)
    {
        var keyPath = "Software\\RooIndustriesRegistryConflict-" + Guid.NewGuid().ToString("N");
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-registry-conflicts-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var machine64 = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var machine32 = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32);
        var linkCreated = false;
        try
        {
            var authority = new CleanupAuthority
            {
                AppId = "fixture:registry-conflicts", ProviderIdentityHash = new string('D', 64), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var engine = new RegistryCleanupEngine(() => authority);
            using (user.CreateSubKey(keyPath)) { }
            var receipt = new RegistryAddress("CurrentUser", "Registry64", keyPath + "\\Receipt", "key", null);
            using (var key = machine64.CreateSubKey(keyPath)) key.SetValue("Architecture", "64-bit sentinel");
            using (var key = machine32.CreateSubKey(keyPath)) key.SetValue("Architecture", "32-bit sentinel");
            var target64 = new RegistryAddress("LocalMachine", "Registry64", keyPath, "key", null);
            var target32 = target64 with { View = "Registry32" };
            check(RegistryNative.Capture(target64).Node!.NativeName != RegistryNative.Capture(target32).Node!.NativeName, "Same-name HKLM32 and HKLM64 keys retain independent native identities");
            var preview = engine.Preview(authority.AppId, authority.ProviderIdentityHash, [target64, target32], receipt, true, true);
            var path = Path.Combine(root, "views-preview.json");
            var journal = Path.Combine(root, "views-journal.json");
            OperationFiles.Write(path, preview);
            var applied = engine.Apply(path, OperationFiles.HashFile(path), journal);
            if (applied.Status != "applied")
            {
                Console.WriteLine(applied.Error);
                foreach (var captured in preview.Targets)
                {
                    using var diagnostic = RegistryTransaction.Begin();
                    RegistryNative.DeleteReviewed(captured, diagnostic);
                    try { RegistryNative.RestoreReviewed(captured, diagnostic); }
                    catch (InvalidDataException)
                    {
                        var observed = RegistryNative.Capture(captured.Address, diagnostic);
                        Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { expected = captured.Node, actual = observed.Node }, OperationFiles.Json));
                    }
                }
            }
            using (var left64 = machine64.OpenSubKey(keyPath))
            using (var left32 = machine32.OpenSubKey(keyPath))
                check(applied.Status == "applied" && left64 is null && left32 is null, "Transactional cleanup deletes only the two explicitly reviewed registry views");
            check(engine.Restore(journal).Status == "restored", "Both registry views pass recovery verification");
            using (var restored64 = machine64.OpenSubKey(keyPath))
            using (var restored32 = machine32.OpenSubKey(keyPath))
                check(restored64!.GetValue("Architecture") as string == "64-bit sentinel" && restored32!.GetValue("Architecture") as string == "32-bit sentinel", "Independent Windows reads verify each view's original sentinel after restore");

            using (var outside = user.CreateSubKey(keyPath + "\\Outside")) outside.SetValue("Keep", "outside link target");
            using (var child = user.CreateSubKey(keyPath + "\\Outside\\Child")) child.SetValue("Keep", "nested outside target");
            var status = CreateKey(user.Handle, keyPath + "\\Link", 0, null, 2, 0xf003f | 0x100, IntPtr.Zero, out var link, out _);
            if (status != 0) throw new Win32Exception(status, "Creating the disposable registry link failed.");
            linkCreated = true;
            using (link)
            {
                var target = Encoding.Unicode.GetBytes("\\REGISTRY\\USER\\" + OperationOwner.Current().UserSid + "\\" + keyPath + "\\Outside");
                status = SetValue(link, "SymbolicLinkValue", 0, 6, target, (uint)target.Length);
                if (status != 0) throw new Win32Exception(status, "Setting the disposable registry link target failed.");
            }
            using (var followed = user.OpenSubKey(keyPath + "\\Link"))
                check(followed?.GetValue("Keep") as string == "outside link target", "The registry-link fixture actually resolves to its independent target");
            var rejected = false;
            try { RegistryNative.Capture(new("CurrentUser", "Registry64", keyPath + "\\Link", "key", null)); }
            catch (InvalidDataException error) when (error.Message.Contains("links")) { rejected = true; }
            check(rejected, "Registry capture rejects the link source before following its destination");
            rejected = false;
            try { RegistryNative.Capture(new("CurrentUser", "Registry64", keyPath + "\\Link\\Child", "key", null)); }
            catch (InvalidDataException error) when (error.Message.Contains("links")) { rejected = true; }
            check(rejected, "A registry link in an ancestor cannot redirect a descendant capture");
            var application = new CleanupApplication { AppId = authority.AppId, DisplayName = keyPath.Split('\\')[^1], Publisher = null, InstallLocation = root, PackageFamilyName = null };
            var scan = new LeftoverDiscovery(application, []).Scan(CancellationToken.None, [], [new("CurrentUser", "Registry64", keyPath, "key", null)]);
            check(!scan.Complete && scan.Candidates.Single(item => item.Registry?.KeyPath == keyPath).OwnershipComplete == false,
                "Retained-parent discovery reports linked subtrees as incomplete ownership evidence");
            rejected = false;
            try { RegistryNative.Capture(new("CurrentUser", "Registry64", keyPath, "key", null)); }
            catch (InvalidDataException error) when (error.Message.Contains("links")) { rejected = true; }
            using (var outside = user.OpenSubKey(keyPath + "\\Outside"))
                check(rejected && outside!.GetValue("Keep") as string == "outside link target", "A linked descendant blocks whole-tree cleanup while its target remains unchanged");
            DeleteLink(user.Handle, keyPath + "\\Link");
            linkCreated = false;
            using (var outside = user.OpenSubKey(keyPath + "\\Outside"))
                check(outside?.GetValue("Keep") as string == "outside link target", "Fixture link removal deletes the link source and preserves its target");
        }
        finally
        {
            var cleanupErrors = new List<Exception>();
            foreach (var cleanup in new Action[]
            {
                () => { if (linkCreated) DeleteLink(user.Handle, keyPath + "\\Link"); },
                () => user.DeleteSubKeyTree(keyPath, false),
                () => machine64.DeleteSubKeyTree(keyPath, false),
                () => machine32.DeleteSubKeyTree(keyPath, false),
                () => Directory.Delete(root, true),
            })
                try { cleanup(); } catch (Exception error) { cleanupErrors.Add(error); }
            if (cleanupErrors.Count != 0) throw new AggregateException("Registry fixture cleanup was incomplete.", cleanupErrors);
        }
        check(!Directory.Exists(root), "Registry conflict validation removes both-view keys, link and recovery files");
    }
}
