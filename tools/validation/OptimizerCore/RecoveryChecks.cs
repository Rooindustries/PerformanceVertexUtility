using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class RecoveryChecks
{
    public static void Run(Action<bool, string> check)
    {
        Permissions(check);
        InterruptedCleanup(check);
        RegistryPermissions(check);
        ReplaceRace(check);
        PrivilegeRestoreFailure(check);
        PrivilegeSetupFailure(check);
        StartupScript(check);
    }

    static void Permissions(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-recovery-" + Guid.NewGuid().ToString("N"));
        var parent = Path.Combine(root, "Shared parent");
        var source = Path.Combine(parent, "App");
        var inherited = Path.Combine(source, "Shared");
        var explicitOnly = Path.Combine(inherited, "explicit.txt");
        var ordinary = Path.Combine(inherited, "ordinary.txt");
        var systemFile = Path.Combine(source, "system.txt");
        var strict = Path.Combine(source, "Strict");
        var strictChild = Path.Combine(strict, "data.bin");
        var pinned = Path.Combine(source, "Pinned");
        var pinnedFile = Path.Combine(pinned, "pinned.txt");
        var operations = Path.Combine(root, "Operations");
        var user = WindowsIdentity.GetCurrent().User!.Value;
        try
        {
            Directory.CreateDirectory(parent);
            Directory.CreateDirectory(operations);
            var parentInfo = new DirectoryInfo(parent);
            var parentAcl = parentInfo.GetAccessControl();
            parentAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.Modify, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            parentAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-3-0"), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.InheritOnly, AccessControlType.Allow));
            parentInfo.SetAccessControl(parentAcl);
            Directory.CreateDirectory(inherited);
            Directory.CreateDirectory(strict);
            Directory.CreateDirectory(pinned);
            var shared = new DirectoryInfo(inherited);
            var sharedAcl = shared.GetAccessControl();
            sharedAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-4"), FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            shared.SetAccessControl(sharedAcl);
            File.WriteAllText(explicitOnly, "explicit");
            SetSecurity(explicitOnly, 4, "D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + user + ")");
            File.WriteAllText(ordinary, "ordinary");
            var aged = Path.Combine(inherited, "aged.txt");
            File.WriteAllText(aged, "aged");
            File.SetLastWriteTimeUtc(aged, new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc));
            File.SetAttributes(aged, FileAttributes.ReadOnly | FileAttributes.Archive);
            var agedBefore = (File.GetLastWriteTimeUtc(aged), File.GetAttributes(aged));
            File.WriteAllText(systemFile, "system");
            var pinnedInfo = new DirectoryInfo(pinned);
            var pinnedAcl = pinnedInfo.GetAccessControl();
            pinnedAcl.SetAccessRuleProtection(true, true);
            pinnedInfo.SetAccessControl(pinnedAcl);
            File.WriteAllText(pinnedFile, "pinned");
            var pinnedFileInfo = new FileInfo(pinnedFile);
            var pinnedFileAcl = pinnedFileInfo.GetAccessControl();
            pinnedFileAcl.SetAccessRuleProtection(true, true);
            pinnedFileInfo.SetAccessControl(pinnedFileAcl);
            using (PrivilegeScope.FilePolicy())
            {
                SetSecurity(systemFile, 1, "O:SY");
                SetSecurity(strict, 5, "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;0x1301bf;;;BA)(A;OICI;0x1301bf;;;" + user + ")");
            }
            File.WriteAllBytes(strictChild, [1, 2, 3]);
            var targets = new[] { source, inherited, explicitOnly, ordinary, systemFile, strict, strictChild, pinned, pinnedFile };
            var before = targets.ToDictionary(path => path, Sddl);
            check(!before[explicitOnly].Contains("BU", StringComparison.Ordinal) && !before[explicitOnly].Contains(":AI", StringComparison.Ordinal) && before[inherited].Contains("D:AI", StringComparison.Ordinal), "The recovery fixture has an explicit-only file inside a folder with inheritable access");
            check(before[source].Contains(";BU)", StringComparison.Ordinal) && before[ordinary].Contains("ID;", StringComparison.Ordinal) && !Sddl(operations).Contains(";BU)", StringComparison.Ordinal), "The recovery fixture inherits Users access that its journal folder does not have");
            check(before[systemFile].StartsWith("O:SY", StringComparison.Ordinal) && before[strict].StartsWith("O:SY", StringComparison.Ordinal), "The recovery fixture has SYSTEM-owned file and folder entries");
            check(before[pinned].Contains("D:PAI", StringComparison.Ordinal) && before[pinnedFile].Contains("D:PAI", StringComparison.Ordinal), "The recovery fixture has protected auto-inherited folder and file entries");
            var identityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("recovery fixture"));
            var authority = new CleanupAuthority
            {
                AppId = "fixture:recovery", ProviderIdentityHash = identityHash, Owner = OperationOwner.Current(),
                RegistrationPresent = false, ProviderQueryComplete = true, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var engine = new FileCleanupEngine(() => authority);
            var preview = engine.Preview(authority.AppId, identityHash, [source], true);
            var reviewPath = Path.Combine(operations, "review.json");
            var journalPath = Path.Combine(operations, "journal.json");
            OperationFiles.Write(reviewPath, preview);
            var applied = engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), journalPath);
            if (applied.Status != "applied") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(applied, OperationFiles.Json));
            check(applied.Status == "applied" && !Directory.Exists(source), "Cleanup verifies backups whose inherited access differs from the journal folder");
            var restored = engine.Restore(journalPath);
            if (restored.Status != "restored") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(restored, OperationFiles.Json));
            check(restored.Status == "restored", "Recovery completes for explicit-only, inherited, protected, SYSTEM-owned and strict-folder entries");
            var changed = targets.Where(path => !Path.Exists(path) || Sddl(path) != before[path]).Select(path => Path.GetRelativePath(root, path) + " " + (Path.Exists(path) ? Sddl(path) : "missing")).ToArray();
            if (changed.Length != 0) Console.WriteLine("Permission differences: " + string.Join(" | ", changed));
            check(Sddl(explicitOnly) == before[explicitOnly], "An explicit-only file keeps exactly its own permissions after its folder is restored");
            check(Sddl(source) == before[source] && Sddl(ordinary) == before[ordinary], "Inherited access from the original parent is restored exactly");
            check(Sddl(systemFile) == before[systemFile], "A SYSTEM-owned file is restored with its SYSTEM owner");
            check(Sddl(strict) == before[strict] && Sddl(strictChild) == before[strictChild], "A SYSTEM-owned folder that denies administrators permission changes is restored exactly");
            check(Sddl(pinned) == before[pinned] && Sddl(pinnedFile) == before[pinnedFile], "Protected auto-inherited entries are restored exactly");
            check(changed.Length == 0, "Every restored entry matches its captured permissions");
            check(File.GetLastWriteTimeUtc(aged) == agedBefore.Item1 && File.GetAttributes(aged) == agedBefore.Item2, "A read-only child keeps its original attributes and write time after its folder is restored");
        }
        finally
        {
            if (Directory.Exists(root))
            {
                using (PrivilegeScope.FilePolicy())
                    foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories).Append(root))
                        try { SetSecurity(path, 5, "O:" + user + "D:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + user + ")"); } catch (Win32Exception) { }
                foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
                Directory.Delete(root, true);
            }
        }
        check(!Directory.Exists(root), "Recovery permission validation removes its fixture");
    }

    static void InterruptedCleanup(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-interrupted-" + Guid.NewGuid().ToString("N"));
        var source = Path.Combine(root, "App");
        var folder = Path.Combine(source, "Sub");
        var removed = Path.Combine(folder, "removed.txt");
        var kept = Path.Combine(source, "kept.txt");
        var operations = Path.Combine(root, "Operations");
        try
        {
            Directory.CreateDirectory(folder);
            Directory.CreateDirectory(operations);
            File.WriteAllText(removed, "removed original");
            File.WriteAllText(kept, "kept original");
            File.SetLastWriteTimeUtc(kept, new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc));
            var identityHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("interrupted fixture"));
            var authority = new CleanupAuthority
            {
                AppId = "fixture:interrupted", ProviderIdentityHash = identityHash, Owner = OperationOwner.Current(),
                RegistrationPresent = false, ProviderQueryComplete = true, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var engine = new FileCleanupEngine(() => authority);
            var reviewPath = Path.Combine(operations, "review.json");
            var journalPath = Path.Combine(operations, "journal.json");
            OperationFiles.Write(reviewPath, engine.Preview(authority.AppId, identityHash, [source], true));
            check(engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), journalPath).Status == "applied", "The interrupted-cleanup fixture is removed");
            Directory.CreateDirectory(source);
            File.WriteAllText(kept, "edited by the user");
            var editedAt = DateTime.UtcNow.AddMinutes(-1);
            File.SetLastWriteTimeUtc(kept, editedAt);
            var journal = OperationFiles.Read<FileCleanupJournal>(journalPath);
            foreach (var entry in journal.Entries.Where(entry => entry.Original.Path == source || entry.Original.Path == kept)) entry.Status = "backedUp";
            journal.Status = "needsReconciliation";
            OperationFiles.Write(journalPath, journal);
            engine.Restore(journalPath);
            check(File.ReadAllText(kept) == "edited by the user" && File.GetLastWriteTimeUtc(kept) == editedAt, "Recovery leaves a never-deleted, later-edited sibling's content and write time untouched");
            check(File.ReadAllText(removed) == "removed original" && Directory.Exists(folder), "Recovery still recreates the deleted folder beside the never-deleted sibling");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        check(!Directory.Exists(root), "Interrupted-cleanup validation removes its fixture");
    }

    static void RegistryPermissions(Action<bool, string> check)
    {
        var name = "Software\\RooIndustriesCleanupTests\\" + Guid.NewGuid().ToString("N");
        var files = Path.Combine(Path.GetTempPath(), "roo-industries-registry-recovery-" + Guid.NewGuid().ToString("N"));
        using var hive = Microsoft.Win32.RegistryKey.OpenBaseKey(Microsoft.Win32.RegistryHive.CurrentUser, Microsoft.Win32.RegistryView.Registry64);
        Directory.CreateDirectory(files);
        try
        {
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
            var providerHash = OperationFiles.Hash(Encoding.UTF8.GetBytes("registry recovery fixture"));
            var authority = new CleanupAuthority
            {
                AppId = "fixture:registry-recovery", ProviderIdentityHash = providerHash, Owner = OperationOwner.Current(),
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
            check(reason.Contains("could not reproduce", StringComparison.Ordinal), "Registry cleanup explains that recovery could not be reproduced");
        }
        finally
        {
            hive.DeleteSubKeyTree(name, throwOnMissingSubKey: false);
            using (var parent = hive.OpenSubKey("Software\\RooIndustriesCleanupTests"))
                if (parent is not null && parent.SubKeyCount == 0 && parent.ValueCount == 0) hive.DeleteSubKey("Software\\RooIndustriesCleanupTests", throwOnMissingSubKey: false);
            Directory.Delete(files, true);
        }
    }

    static void ReplaceRace(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-replace-race-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "state.json");
        try
        {
            OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = 0 });
            var stop = DateTime.UtcNow.AddSeconds(3);
            var writes = 0; var reads = 0; var failures = 0; var falseAbsent = 0; var failure = "";
            var writer = Task.Run(() => { var value = 0; while (DateTime.UtcNow < stop) { OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = ++value }); writes++; } });
            var reader = Task.Run(() =>
            {
                while (DateTime.UtcNow < stop)
                {
                    try { OperationFiles.Read<Dictionary<string, int>>(path); OperationFiles.HashFile(path); if (OperationFiles.Absent(path)) falseAbsent++; reads++; }
                    catch (Exception error) { failures++; failure = error.GetType().Name + ": " + error.Message; }
                }
            });
            Task.WaitAll(writer, reader);
            Console.WriteLine($"Replace race: writes={writes} reads={reads} failures={failures} falseAbsent={falseAbsent} {failure}");
            check(writes > 100 && reads > 100 && failures == 0 && falseAbsent == 0, "Readers never fail or see a missing file while a writer atomically replaces it");
            var missing = Path.Combine(root, "missing.json");
            OperationFiles.Absent(missing);
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var absent = OperationFiles.Absent(missing);
            check(absent && clock.ElapsedMilliseconds < 25, "An expected-missing file is reported absent without waiting");
            Directory.CreateDirectory(Path.Combine(root, "folder.json"));
            check(!OperationFiles.Absent(Path.Combine(root, "folder.json")), "A folder at an operation file path is not reported as a missing file");
            var stale = path + "." + Guid.NewGuid().ToString("N") + ".writing";
            File.WriteAllText(stale, "");
            File.SetLastWriteTimeUtc(stale, DateTime.UtcNow.AddMinutes(-5));
            OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = -1 });
            check(!File.Exists(stale), "A later write removes a marker left by an interrupted write");
            var young = path + "." + Guid.NewGuid().ToString("N") + ".writing";
            File.WriteAllText(young, "");
            File.SetLastWriteTimeUtc(young, DateTime.UtcNow.AddSeconds(-30));
            OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = -2 });
            check(File.Exists(young), "A write keeps a marker younger than one minute");
            File.Delete(young);
            OperationFiles.SimulateReplaceFailure = (target, backup) => { File.Move(target, backup); throw new IOException("Simulated replace failure 1176.", unchecked((int)0x80070498)); };
            var replaceFailed = false;
            try { OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = -3 }); } catch (IOException) { replaceFailed = true; }
            finally { OperationFiles.SimulateReplaceFailure = null; }
            check(replaceFailed && OperationFiles.Read<Dictionary<string, int>>(path)["value"] == -2 && !Directory.EnumerateFiles(root, "state.json.*").Any(), "A failed replace keeps the previous file and leaves no backup behind");
            var orphan = path + "." + Guid.NewGuid().ToString("N") + ".bak";
            File.Move(path, orphan);
            File.SetLastWriteTimeUtc(orphan, DateTime.UtcNow.AddMinutes(-5));
            var failedClosed = false;
            try { OperationFiles.Read<Dictionary<string, int>>(path); } catch (InvalidDataException) { failedClosed = true; }
            check(failedClosed && !OperationFiles.Absent(path), "A file lost mid-replace fails closed instead of reading as absent");
            File.Move(orphan, path);
        }
        finally { Directory.Delete(root, true); }
    }

    static void PrivilegeRestoreFailure(Action<bool, string> check)
    {
        var preserved = false;
        PrivilegeScope.SimulateRestoreFailure = () => true;
        try { using (new PrivilegeScope("fixture", "SeIncreaseBasePriorityPrivilege")) throw new InvalidOperationException("original failure"); }
        catch (InvalidOperationException error) { preserved = error.Message == "original failure"; }
        finally { PrivilegeScope.SimulateRestoreFailure = null; }
        var io = 3;
        var status = NtSetInformationProcess(GetCurrentProcess(), 33, ref io, 4);
        io = 2;
        NtSetInformationProcess(GetCurrentProcess(), 33, ref io, 4);
        check(preserved, "A failed privilege restore keeps the original error");
        check(status < 0, "A failed privilege restore still leaves the privilege disabled");
    }

    static void PrivilegeSetupFailure(Action<bool, string> check)
    {
        Exception? observed = null;
        PrivilegeScope.SimulateRestoreFailure = () => true;
        PrivilegeScope.SimulateDisableFailure = () => true;
        try { using (new PrivilegeScope("fixture", "SeTimeZonePrivilege", "SeRooIndustriesMissingPrivilege")) { } }
        catch (Exception error) { observed = error; }
        finally { PrivilegeScope.SimulateRestoreFailure = null; PrivilegeScope.SimulateDisableFailure = null; }
        check(observed is InvalidOperationException && observed.InnerException is Win32Exception && observed.Message.Contains("could not be returned to its previous state", StringComparison.Ordinal), "A privilege setup failure reports both the original error and a privilege left enabled");
    }

    static void StartupScript(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-startup-script-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            var assembly = Path.Combine(root, "Optimizer.Host.dll");
            var launcher = Path.Combine(root, "Optimizer.Host.exe");
            File.WriteAllText(assembly, "assembly");
            File.WriteAllText(launcher, "launcher");
            var bundled = TimerStartupControl.StartupScript(assembly, launcher, true, root);
            var framework = TimerStartupControl.StartupScript(assembly, launcher, false, root);
            check(bundled.Contains("Get-FileHash -LiteralPath '" + launcher + "'", StringComparison.Ordinal) && bundled.Contains(OperationFiles.HashFile(launcher), StringComparison.Ordinal), "Installed timer startup verifies the executable it launches");
            check(bundled.Contains("Get-FileHash -LiteralPath '" + assembly + "'", StringComparison.Ordinal) && framework.Contains("Get-FileHash -LiteralPath '" + assembly + "'", StringComparison.Ordinal), "Timer startup verifies the helper assembly in both layouts");
        }
        finally { Directory.Delete(root, true); }
    }

    static string Sddl(string path)
    {
        using var handle = Open(path, 0x20000);
        GetKernelObjectSecurity(handle, 7, null, 0, out var needed);
        var bytes = new byte[needed];
        if (!GetKernelObjectSecurity(handle, 7, bytes, needed, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!ConvertSecurityDescriptorToStringSecurityDescriptor(bytes, 1, 7, out var text, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Marshal.PtrToStringUni(text) ?? ""; } finally { LocalFree(text); }
    }

    static void SetSecurity(string path, uint information, string sddl)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out var descriptor, out var size)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var bytes = new byte[size];
            Marshal.Copy(descriptor, bytes, 0, (int)size);
            using var handle = Open(path, 0x20000 | 0x40000 | 0x80000);
            if (!SetKernelObjectSecurity(handle, information, bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { LocalFree(descriptor); }
    }

    static SafeFileHandle Open(string path, uint access)
    {
        var handle = CreateFile(path, access, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), path);
        return handle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetKernelObjectSecurity(SafeHandle handle, uint information, [Out] byte[]? descriptor, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetKernelObjectSecurity(SafeHandle handle, uint information, byte[] descriptor);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(byte[] descriptor, uint revision, uint information, out IntPtr text, out uint length);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll")] static extern int RegSetKeySecurity(Microsoft.Win32.SafeHandles.SafeRegistryHandle key, uint information, byte[] descriptor);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int length);
}
