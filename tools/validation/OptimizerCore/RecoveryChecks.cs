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
        ReplaceRace(check);
        PrivilegeRestoreFailure(check);
        StartupScript(check);
    }

    static void Permissions(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-recovery-" + Guid.NewGuid().ToString("N"));
        var source = Path.Combine(root, "App");
        var inherited = Path.Combine(source, "Shared");
        var explicitOnly = Path.Combine(inherited, "explicit.txt");
        var systemFile = Path.Combine(source, "system.txt");
        var strict = Path.Combine(source, "Strict");
        var strictChild = Path.Combine(strict, "data.bin");
        var operations = Path.Combine(root, "Operations");
        var user = WindowsIdentity.GetCurrent().User!.Value;
        try
        {
            Directory.CreateDirectory(inherited);
            Directory.CreateDirectory(strict);
            Directory.CreateDirectory(operations);
            var shared = new DirectoryInfo(inherited);
            var sharedAcl = shared.GetAccessControl();
            sharedAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.Modify, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            shared.SetAccessControl(sharedAcl);
            File.WriteAllText(explicitOnly, "explicit");
            SetSecurity(explicitOnly, 4, "D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + user + ")");
            File.WriteAllText(systemFile, "system");
            File.WriteAllBytes(strictChild, [1, 2, 3]);
            using (PrivilegeScope.FilePolicy())
            {
                SetSecurity(systemFile, 1, "O:SY");
                SetSecurity(strict, 5, "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;0x1301bf;;;BA)(A;OICI;0x1301bf;;;" + user + ")");
            }
            var targets = new[] { source, inherited, explicitOnly, systemFile, strict, strictChild };
            var before = targets.ToDictionary(path => path, Sddl);
            check(!before[explicitOnly].Contains("BU", StringComparison.Ordinal) && !before[explicitOnly].Contains(":AI", StringComparison.Ordinal) && before[inherited].Contains("D:AI", StringComparison.Ordinal), "The recovery fixture has an explicit-only file inside a folder with inheritable Users access");
            check(before[systemFile].StartsWith("O:SY", StringComparison.Ordinal) && before[strict].StartsWith("O:SY", StringComparison.Ordinal), "The recovery fixture has SYSTEM-owned file and folder entries");
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
            check(applied.Status == "applied" && !Directory.Exists(source), "Cleanup backs up and removes explicit-only, SYSTEM-owned and strict-folder entries");
            var restored = engine.Restore(journalPath);
            if (restored.Status != "restored") Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(restored, OperationFiles.Json));
            check(restored.Status == "restored", "Recovery completes for explicit-only, SYSTEM-owned and strict-folder entries");
            var changed = targets.Where(path => !Path.Exists(path) || Sddl(path) != before[path]).Select(path => Path.GetRelativePath(root, path) + " " + (Path.Exists(path) ? Sddl(path) : "missing")).ToArray();
            if (changed.Length != 0) Console.WriteLine("Permission differences: " + string.Join(" | ", changed));
            check(Sddl(explicitOnly) == before[explicitOnly], "An explicit-only file keeps exactly its own permissions after its folder is restored");
            check(Sddl(systemFile) == before[systemFile], "A SYSTEM-owned file is restored with its SYSTEM owner");
            check(Sddl(strict) == before[strict] && Sddl(strictChild) == before[strictChild], "A SYSTEM-owned folder that denies administrators permission changes is restored exactly");
            check(changed.Length == 0, "Every restored entry matches its captured permissions");
        }
        finally
        {
            if (Directory.Exists(root))
            {
                using (PrivilegeScope.FilePolicy())
                    foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories).Append(root))
                        try { SetSecurity(path, 5, "O:" + user + "D:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + user + ")"); } catch (Win32Exception) { }
                Directory.Delete(root, true);
            }
        }
        check(!Directory.Exists(root), "Recovery permission validation removes its fixture");
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
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var absent = OperationFiles.Absent(missing);
            check(absent && clock.ElapsedMilliseconds < 5, "An expected-missing file is reported absent without waiting");
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
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr process, int informationClass, ref int information, int length);
}
