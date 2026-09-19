using System.Runtime.InteropServices;
using RooIndustries.Optimizer;

static class BrandCompatibilityChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-brand-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var oldEnvironment = Environment.GetEnvironmentVariable("ROO_BACKEND_ROOT");
        var newEnvironment = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
        try
        {
            check(BrandCompatibility.DataRoot(root) == Path.Combine(root, "RooIndustriesOptimizationSuite"), "Fresh installations use the full product data directory");
            var legacy = Path.Combine(root, "RooOptimizationSuite"); Directory.CreateDirectory(legacy);
            var recovery = Path.Combine(legacy, "operations", "session", "preview.json"); Directory.CreateDirectory(Path.GetDirectoryName(recovery)!);
            File.WriteAllText(recovery, "identity-bound recovery bytes");
            var hash = OperationFiles.HashFile(recovery);
            check(BrandCompatibility.DataRoot(root) == legacy && OperationFiles.HashFile(recovery) == hash, "Existing recovery paths and bytes remain in place after the rename");
            Directory.CreateDirectory(Path.Combine(root, "RooIndustriesOptimizationSuite"));
            check(BrandCompatibility.DataRoot(root) == legacy && File.Exists(recovery), "A new empty directory cannot hide an existing installation's recovery data");
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", null);
            Environment.SetEnvironmentVariable("ROO_BACKEND_ROOT", "legacy-fixture");
            check(BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_BACKEND_ROOT") == "legacy-fixture", "Existing launchers can still supply their backend location");
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", "current-fixture");
            check(BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_BACKEND_ROOT") == "current-fixture", "An explicit current environment value takes precedence");
            check(BrandCompatibility.LegacyTheme == "roo-blue", "The former saved theme identifier is recognized");
            check(BrandCompatibility.IsRestoreStage(".roo-restore-0123") && BrandCompatibility.IsRestoreStage(".roo-industries-restore-0123") && !BrandCompatibility.IsRestoreStage("unrelated-file"), "Recovery accepts both owned staging formats and rejects unrelated names");
            var protectedRootRejected = false;
            try { new RegistryAddress("CurrentUser", "Registry64", "Software\\RooOptimizationSuite", "key", null).RequireDeletionScope(); }
            catch (InvalidDataException) { protectedRootRejected = true; }
            check(protectedRootRejected, "The earlier product registry container stays protected without registry writes");
            check(BrandCompatibility.ProcessMutexPrefix == "Local\\RooProcessControls-" && BrandCompatibility.LaunchMutexPrefix == "Global\\RooLaunchPriorities-" && BrandCompatibility.LauncherLeasePrefix == "roo-protected-launcher-", "Concurrent old and new controllers retain the same exclusion identities");
            var operation = Guid.NewGuid().ToString("N");
            var oldJob = CreateJobObject(IntPtr.Zero, "Global\\RooProtectedSession-" + operation);
            if (oldJob == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                using var reopened = ProcessJob.Open(operation);
                check(reopened is not null && reopened.ReadAffinity() == 0, "A new recovery controller can open an existing legacy job");
            }
            finally { CloseHandle(oldJob); }
            check(ProcessJob.Open(operation) is null, "The disposable legacy job disappears after all handles close");
        }
        finally
        {
            Environment.SetEnvironmentVariable("ROO_BACKEND_ROOT", oldEnvironment);
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", newEnvironment);
            Directory.Delete(root, true);
        }
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
}
