using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using RooIndustries.Optimizer;

static class RegistryRefusalChecks
{
    public static void Run(Action<bool, string> check)
    {
        var name = "Software\\RooIndustriesCleanupTests\\" + Guid.NewGuid().ToString("N");
        var files = Path.Combine(Path.GetTempPath(), "roo-industries-registry-refusal-" + Guid.NewGuid().ToString("N"));
        using var hive = Microsoft.Win32.RegistryKey.OpenBaseKey(Microsoft.Win32.RegistryHive.CurrentUser, Microsoft.Win32.RegistryView.Registry64);
        Directory.CreateDirectory(files);
        OwnedRegistryKey? owned = null;
        try
        {
            owned = OwnedRegistryKey.Create(hive, name);
            using (hive.CreateSubKey(name + "\\Receipts")) { }
            using (var app = hive.CreateSubKey(name + "\\App"))
            {
                var security = app.GetAccessControl();
                security.AddAccessRule(new RegistryAccessRule(new SecurityIdentifier("S-1-5-32-545"), RegistryRights.ReadKey, InheritanceFlags.ContainerInherit, PropagationFlags.None, AccessControlType.Allow));
                app.SetAccessControl(security);
                app.SetValue("Kind", "app");
                using (var ordinary = app.CreateSubKey("Ordinary")) ordinary.SetValue("Kind", "ordinary");
                using (var created = app.CreateSubKey("Explicit")) created.SetValue("Kind", "explicit");
                using var pinned = app.OpenSubKey("Explicit", Microsoft.Win32.RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryRights.ReadKey | RegistryRights.ChangePermissions) ?? throw new InvalidDataException("Missing registry fixture key.");
                if (!ConvertStringSecurityDescriptorToSecurityDescriptor("D:(A;CI;KA;;;SY)(A;CI;KA;;;BA)(A;CI;KA;;;" + WindowsIdentity.GetCurrent().User!.Value + ")", 1, out var descriptor, out var size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                try
                {
                    var bytes = new byte[size];
                    Marshal.Copy(descriptor, bytes, 0, (int)size);
                    var status = RegSetKeySecurity(pinned.Handle, 4, bytes);
                    if (status != 0) throw new Win32Exception(status);
                }
                finally { LocalFree(descriptor); }
            }
            var keys = new[] { name + "\\App", name + "\\App\\Ordinary", name + "\\App\\Explicit" };
            string KeySddl(string path) { using var key = hive.OpenSubKey(path) ?? throw new InvalidDataException("Missing registry fixture key."); return key.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.Owner | AccessControlSections.Group | AccessControlSections.Access); }
            var before = keys.ToDictionary(path => path, KeySddl);
            check(before[keys[0]].Contains("D:AI", StringComparison.Ordinal) && !before[keys[2]].Contains(";BU)", StringComparison.Ordinal) && !before[keys[2]].Contains(":AI", StringComparison.Ordinal), "The registry fixture has an explicit-only key under a key with inheritable access");
            var providerHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("registry refusal fixture"));
            var authority = new CleanupAuthority
            {
                AppId = "fixture:registry-refusal", ProviderIdentityHash = providerHash, Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var engine = new RegistryCleanupEngine(() => authority);
            var target = new RegistryAddress("CurrentUser", "Registry64", name + "\\App", "key", null);
            var receipt = new RegistryAddress("CurrentUser", "Registry64", name + "\\Receipts\\" + Guid.NewGuid().ToString("N"), "key", null);
            var reviewPath = Path.Combine(files, "review.json");
            var journalPath = Path.Combine(files, "journal.json");
            OperationFiles.Write(reviewPath, engine.Preview(authority.AppId, providerHash, [target], receipt, true, true));
            var refused = false;
            var reason = "";
            try
            {
                var result = engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), journalPath);
                refused = result.Status != "applied";
                reason = result.Error ?? result.Status;
            }
            catch (Exception error) when (error is InvalidDataException or InvalidOperationException) { refused = true; reason = error.Message; }
            Console.WriteLine("Registry refusal: " + (reason.Length > 300 ? reason[..300] : reason));
            string? Kind(string path) { using var key = hive.OpenSubKey(path); return key?.GetValue("Kind") as string; }
            check(refused && keys.All(path => KeySddl(path) == before[path]) && Kind(keys[0]) == "app" && Kind(keys[1]) == "ordinary" && Kind(keys[2]) == "explicit", "Registry cleanup refuses a mixed-inheritance tree it cannot restore exactly and leaves its keys, values and permissions untouched");
            check(reason.Contains("did not reproduce the captured data and permissions", StringComparison.Ordinal), "Registry cleanup explains that recovery could not reproduce the permissions");
        }
        finally
        {
            owned?.Dispose();
            Directory.Delete(files, true);
        }
    }


    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(Microsoft.Win32.SafeHandles.SafeRegistryHandle key, uint information, byte[] descriptor);
}
