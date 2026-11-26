using System.ComponentModel;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;
using H = DataRootHarness;

sealed class DataRootPrivateHive : IDisposable
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] private static extern int RegLoadAppKeyW(string file, out IntPtr key, int access, int options, int reserved);
    [DllImport("advapi32.dll")] private static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
    [DllImport("advapi32.dll")] private static extern int RegCloseKey(IntPtr key);
    private static readonly IntPtr Machine = new(unchecked((int)0x80000002));
    private IntPtr _key;
    public DataRootPrivateHive(string path)
    {
        _ = RooIndustries.Optimizer.RuntimeEnvironment.LocalAppData;
        var code = RegLoadAppKeyW(path, out _key, 0xF003F, 1, 0);
        if (code != 0) throw new Win32Exception(code);
        code = RegOverridePredefKey(Machine, _key);
        if (code != 0) { RegCloseKey(_key); throw new Win32Exception(code); }
    }
    public void Dispose()
    {
        var code = RegOverridePredefKey(Machine, IntPtr.Zero);
        RegCloseKey(_key); _key = IntPtr.Zero;
        if (code != 0) throw new Win32Exception(code);
    }
}

static partial class DataFolderChecks
{
    public static void MarkedRootChild(string parent, string hive, bool acknowledge)
    {
        using var isolated = new DataRootPrivateHive(hive);
        var method = typeof(BrandCompatibility).GetMethod("DefaultDataRoot", BindingFlags.Static | BindingFlags.NonPublic)!;
        string root;
        try { root = (string)method.Invoke(null, [parent])!; }
        catch (TargetInvocationException error) { throw error.InnerException!; }
        PolicyRootSecurity.Secure(root, DataFolder.Kind);
        var notice = Path.Combine(root, "data-root-recovery.json");
        var text = File.Exists(notice) ? File.ReadAllText(notice) : null;
        if (acknowledge && H.Has(typeof(DataFolder), "RecoveryNotice") && H.Has(typeof(DataFolder), "AcknowledgeRecoveryNotice"))
        {
            var message = H.Api(typeof(DataFolder), "RecoveryNotice", root) as string;
            if (message is not null) H.Api(typeof(DataFolder), "AcknowledgeRecoveryNotice", root, message);
        }
        using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
        Console.WriteLine(JsonSerializer.Serialize(new { root, problem = PolicyRootSecurity.Problem(root, DataFolder.Kind), marker = markers?.GetValue(PolicyRootSecurity.MarkerName(root)), notice = text }, OperationFiles.Json));
    }

    private static void MarkedRootRecovery(Action<bool, string> check, string damage)
    {
        var id = H.Name("marked-" + damage);
        var parent = Path.Combine(H.Local, id);
        var root = Path.Combine(parent, "RooIndustriesOptimizationSuite");
        var hive = Path.Combine(parent, "machine.hive");
        TestFixtures.Own(parent);
        try
        {
            using (var isolated = new DataRootPrivateHive(hive))
            {
                PolicyRootSecurity.Secure(root, DataFolder.Kind);
                File.WriteAllText(Path.Combine(root, "old-history.json"), "untrusted history kept exactly");
            }
            if (damage == "missing") H.Delete(root);
            else if (damage == "reparse")
            {
                var target = Path.Combine(parent, "kept-target");
                Directory.Move(root, target);
                H.Junction(root, target);
            }
            else
            {
                var security = new DirectoryInfo(root).GetAccessControl();
                security.SetOwner(WindowsIdentity.GetCurrent().User!);
                security.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.Modify, AccessControlType.Allow));
                new DirectoryInfo(root).SetAccessControl(security);
            }
            var first = H.Child(["--marked-root-start", parent, hive]);
            Console.WriteLine("MEASURE firstStart " + first.Output);
            check(first.Exit == 0, "A fresh start repairs the " + damage + " marked data root instead of refusing forever");
            if (first.Exit != 0) return;
            using var result = JsonDocument.Parse(first.Output);
            var data = result.RootElement;
            check(data.GetProperty("root").GetString()!.Equals(root, StringComparison.OrdinalIgnoreCase) && data.GetProperty("problem").ValueKind == JsonValueKind.Null && data.GetProperty("marker").GetString() == WindowsIdentity.GetCurrent().User!.Value,
                "The same marked path is protected again and its SID marker is kept");
            check(data.GetProperty("notice").ValueKind == JsonValueKind.String && !File.Exists(Path.Combine(root, "old-history.json")), "The new root records a notice without trusting the earlier history");
            var aside = H.Aside(root);
            check(damage == "missing" ? aside.Length == 0 : aside.Length == 1 && H.Read(Path.Combine(aside[0], "old-history.json")) == "untrusted history kept exactly" && data.GetProperty("notice").GetString()!.Contains(aside[0].Replace("\\", "\\\\"), StringComparison.OrdinalIgnoreCase),
                "A missing folder starts fresh; a damaged folder stays on disk and its kept path is recorded");
            var acknowledge = H.Child(["--marked-root-start", parent, hive, "acknowledge"]);
            var again = H.Child(["--marked-root-start", parent, hive]);
            check(acknowledge.Exit == 0 && again.Exit == 0 && !File.Exists(Path.Combine(root, "data-root-recovery.json")), "Acknowledging the repair notice prevents it appearing at later starts");
            var changed = Directory.CreateDirectory(Path.Combine(parent, "changed-setting")).FullName;
            var refused = H.Child(["--marked-root-start", changed, hive]);
            check(refused.Exit != 0 && refused.Output.Contains("AppData folder setting changed", StringComparison.Ordinal), "A changed AppData parent still refuses and keeps the protected folder");
        }
        finally { H.Delete(parent); }
        check(!Directory.Exists(parent), "The isolated registry hive and repaired-root fixtures are removed");
    }

    private static void RefusedMarkedRoot(Action<bool, string> check, string scenario)
    {
        var parent = Path.Combine(H.Local, H.Name("marked-refused"));
        var root = Path.Combine(parent, "RooIndustriesOptimizationSuite");
        var hive = Path.Combine(parent, "machine.hive");
        Directory.CreateDirectory(parent);
        try
        {
            using (var isolated = new DataRootPrivateHive(hive))
            {
                PolicyRootSecurity.Secure(root, DataFolder.Kind);
                File.WriteAllText(Path.Combine(root, "history.json"), "keep these exact bytes");
                using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true)!;
                if (scenario == "other-sid") markers.SetValue(PolicyRootSecurity.MarkerName(root), "S-1-5-18", RegistryValueKind.String);
                else if (scenario == "other-parent")
                {
                    var second = Path.Combine(parent, "another", "RooIndustriesOptimizationSuite");
                    PolicyRootSecurity.Secure(second, DataFolder.Kind);
                    var acl = new DirectoryInfo(root).GetAccessControl();
                    acl.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.Modify, AccessControlType.Allow));
                    new DirectoryInfo(root).SetAccessControl(acl);
                }
                else markers.SetValue(PolicyRootSecurity.MarkerName(root) + "|repair", scenario == "malformed" ? "{" : JsonSerializer.Serialize(new { owner = "S-1-5-18", root, keptAt = root + ".untrusted-" + Guid.NewGuid().ToString("N"), phase = "prepared" }, OperationFiles.Json), RegistryValueKind.String);
            }
            var before = new DirectoryInfo(root).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
            var refused = H.Child(["--marked-root-start", parent, hive]);
            check(refused.Exit != 0, "A " + scenario + " repair or competing marker refuses before changing data");
            check(File.ReadAllText(Path.Combine(root, "history.json")) == "keep these exact bytes" && new DirectoryInfo(root).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All) == before && H.Aside(root).Length == 0, "The " + scenario + " refusal leaves the exact data and security intact");
        }
        finally { H.Delete(parent); }
        check(!Directory.Exists(parent), "The " + scenario + " marker fixture and private hive are removed");
    }

    private static void InterruptedMarkedRoot(Action<bool, string> check, string phase)
    {
        var parent = Path.Combine(H.Local, H.Name("marked-interrupted"));
        var root = Path.Combine(parent, "RooIndustriesOptimizationSuite");
        var hive = Path.Combine(parent, "machine.hive");
        var kept = root + ".untrusted-" + Guid.NewGuid().ToString("N");
        Directory.CreateDirectory(parent);
        try
        {
            using (var isolated = new DataRootPrivateHive(hive))
            {
                PolicyRootSecurity.Secure(root, DataFolder.Kind);
                File.WriteAllText(Path.Combine(root, "old-history.json"), "untrusted history kept exactly");
                using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey, true)!;
                markers.SetValue(PolicyRootSecurity.MarkerName(root) + "|repair", JsonSerializer.Serialize(new { owner = WindowsIdentity.GetCurrent().User!.Value, root, keptAt = kept, phase = "moved" }, OperationFiles.Json), RegistryValueKind.String);
                Directory.Move(root, kept);
                if (phase == "created") PolicyRootSecurity.Secure(root, DataFolder.Kind);
            }
            var restarted = H.Child(["--marked-root-start", parent, hive]);
            Console.WriteLine("MEASURE interrupted " + phase + " " + restarted.Output);
            check(restarted.Exit == 0 && File.Exists(Path.Combine(root, "data-root-recovery.json")) && File.ReadAllText(Path.Combine(root, "data-root-recovery.json")).Contains(kept.Replace("\\", "\\\\"), StringComparison.OrdinalIgnoreCase), "Restart after repair " + phase + " retains the exact kept path in its notice");
            check(H.Read(Path.Combine(kept, "old-history.json")) == "untrusted history kept exactly" && !File.Exists(Path.Combine(root, "old-history.json")), "Interrupted repair never adopts the kept history");
            using (var isolated = new DataRootPrivateHive(hive))
            using (var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey))
                check(markers?.GetValue(PolicyRootSecurity.MarkerName(root) + "|repair") is null, "The completed repair clears only its pending receipt");
        }
        finally { H.Delete(parent); }
        check(!Directory.Exists(parent), "The interrupted repair fixture and private registry hive are removed");
    }

    private static void RepairPathSwap(Action<bool, string> check)
    {
        var parent = Path.Combine(H.Local, H.Name("repair-path-swap"));
        var root = Path.Combine(parent, "RooIndustriesOptimizationSuite");
        var hive = Path.Combine(parent, "machine.hive");
        var swapped = Path.Combine(parent, "swapped-root");
        var victim = Path.Combine(parent, "unrelated-target");
        TestFixtures.Own(parent); Directory.CreateDirectory(victim);
        File.WriteAllText(Path.Combine(victim, "keep.txt"), "unrelated target bytes");
        var security = new DirectoryInfo(victim).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
        try
        {
            using (var isolated = new DataRootPrivateHive(hive)) PolicyRootSecurity.Secure(root, DataFolder.Kind);
            H.Delete(root);
            using var child = H.Start(["--marked-root-start", parent, hive], new() { ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT"] = "repair-created", ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"] = "3000" });
            try
            {
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (!Directory.Exists(root) && !child.HasExited && clock.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(10);
                var paused = Directory.Exists(root) && !child.HasExited;
                var moved = false;
                if (paused)
                {
                    Thread.Sleep(100);
                    try { Directory.Move(root, swapped); moved = true; }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Console.WriteLine("MEASURE repairRename " + error.GetType().Name + " hresult=" + error.HResult.ToString("X8") + " " + error.Message); }
                    if (moved) H.Junction(root, victim);
                }
                Console.WriteLine("MEASURE repairRace " + JsonSerializer.Serialize(new { paused, moved, root, swapped, victim }, OperationFiles.Json));
                check(paused && !moved, "The created repair root is held against a concurrent namespace swap before its notice write");
                var finished = child.WaitForExit(10000);
                if (finished) Console.WriteLine("MEASURE repairChild exit=" + child.ExitCode + " " + child.StandardOutput.ReadToEnd() + child.StandardError.ReadToEnd());
                check(finished && child.ExitCode == 0 && File.Exists(Path.Combine(root, "data-root-recovery.json")), "The held repair completes its own notice at the same protected root");
                check(!File.Exists(Path.Combine(victim, "data-root-recovery.json")) && File.ReadAllText(Path.Combine(victim, "keep.txt")) == "unrelated target bytes" && new DirectoryInfo(victim).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All) == security,
                    "A repair namespace race writes no privileged notice into the unrelated target and preserves its data and security");
            }
            finally { if (!child.HasExited) { child.Kill(true); child.WaitForExit(10000); } }
        }
        finally { H.Delete(parent); }
        check(!Directory.Exists(parent), "The repair namespace fixture and private registry hive are removed");
    }

    private static void CrashedMarkedRoot(Action<bool, string> check, string phase)
    {
        var parent = Path.Combine(H.Local, H.Name("marked-crash"));
        var root = Path.Combine(parent, "RooIndustriesOptimizationSuite");
        var hive = Path.Combine(parent, "machine.hive");
        Directory.CreateDirectory(parent);
        try
        {
            using (var isolated = new DataRootPrivateHive(hive))
            {
                PolicyRootSecurity.Secure(root, DataFolder.Kind);
                File.WriteAllText(Path.Combine(root, "history.json"), "the exact earlier history");
                var acl = new DirectoryInfo(root).GetAccessControl();
                acl.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.Modify, AccessControlType.Allow));
                new DirectoryInfo(root).SetAccessControl(acl);
            }
            using var child = H.Start(["--marked-root-start", parent, hive], new() { ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT"] = "repair-" + phase, ["ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"] = "30000" });
            var clock = System.Diagnostics.Stopwatch.StartNew();
            var paused = false;
            while (clock.Elapsed < TimeSpan.FromSeconds(20) && !child.HasExited)
            {
                paused = H.Aside(root).Length == 1 && (phase == "moved" ? !Directory.Exists(root) : Directory.Exists(root) && !File.Exists(Path.Combine(root, "data-root-recovery.json")));
                if (paused)
                {
                    Thread.Sleep(300);
                    paused = !child.HasExited && H.Aside(root).Length == 1 && (phase == "moved" ? !Directory.Exists(root) : Directory.Exists(root) && !File.Exists(Path.Combine(root, "data-root-recovery.json")));
                    if (paused) break;
                }
                Thread.Sleep(25);
            }
            check(paused && !child.HasExited, "The actual repair pauses after " + phase + " with its pending receipt durable");
            if (!child.HasExited) { child.Kill(true); child.WaitForExit(10000); }
            var kept = H.Aside(root).Single();
            var restarted = H.Child(["--marked-root-start", parent, hive]);
            check(restarted.Exit == 0 && File.ReadAllText(Path.Combine(root, "data-root-recovery.json")).Contains(kept.Replace("\\", "\\\\"), StringComparison.OrdinalIgnoreCase), "After killing the actual repair at " + phase + ", restart reports the exact kept path");
            check(File.ReadAllText(Path.Combine(kept, "history.json")) == "the exact earlier history" && !File.Exists(Path.Combine(root, "history.json")), "Crash recovery at " + phase + " preserves the earlier data without adopting it");
        }
        finally { H.Delete(parent); }
        check(!Directory.Exists(parent), "The killed repair fixture and private hive are removed");
    }
}
