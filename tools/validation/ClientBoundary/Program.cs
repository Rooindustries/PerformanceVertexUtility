using System.Text.Json;
using System.Diagnostics;
using System.Reflection;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

if (args is ["--recovery-slot", var recoveryAction, var recoveryOutput, var recoveryRepo, var slotDirectory]) { await RecoverySlotChecks.Run(recoveryAction, recoveryOutput, recoveryRepo, slotDirectory); return; }
if (args is ["--settings-corruption", var settingsOutput]) { RecoverySlotChecks.Settings(settingsOutput); return; }
if (args is ["--review2-services", var reviewOutput, var recoveryDirectory]) { await Review2Checks.Run(reviewOutput, recoveryDirectory); return; }
if (args is ["--review2-restore-pending", var pendingOutput, var pendingDirectory]) { await Review2Checks.Run(pendingOutput, pendingDirectory, settings: false); return; }
if (args is [var hostDll, var hostAction, "-"] && Path.GetFileName(hostDll) == "Optimizer.Host.dll") { FakeHost.Run(hostAction); return; }
if (Path.GetFileName(System.Reflection.Assembly.GetEntryAssembly()?.Location) == "Optimizer.Host.dll") { await HostFixture.Run(args); return; }
if (args is [_, "--game-session-display"]) { GameSessionChecks.Display(); return; }
if (args is [var gameRepo, "--game-sessions"]) { await GameSessionChecks.Run(gameRepo); return; }
if (args is [var profileRepo, "--launch-profiles" or "--session-recovery"]) { await LaunchProfileChecks.Run(profileRepo, args[1] == "--session-recovery"); return; }
if (args is [_, "--background-priority"]) { PriorityChecks.Run(); return; }
if (args is [var boundsRepo, "--bounds", .. var boundsFilter]) { await BoundChecks.Run(boundsRepo, boundsFilter.FirstOrDefault()); return; }
if (args is [_, "--child-environment", var childScenario, var childMode]) { await ChildEnvironmentChecks.Run(childScenario, childMode); return; }

var repo = Path.GetFullPath(args[0]);
var fixture = Path.Combine(Path.GetTempPath(), "roo-industries-client-boundary-" + Guid.NewGuid().ToString("N"));
var previousRoot = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
string? recoveryRoot = null;
string? savedRollback = null;
string? fixtureOperations = null;
string? gateRoot = null;
LiveDataService? service = null;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    Console.WriteLine("PASS " + message);
}
string RealDataFolderState()
{
    var real = RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot;
    var entries = Directory.Exists(real)
        ? Directory.EnumerateFileSystemEntries(real, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal).Select(path => path + "|" + (Directory.Exists(path) ? "directory" : new FileInfo(path).Length + "|" + File.GetLastWriteTimeUtc(path).Ticks))
        : ["<missing>"];
    using var markers = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(RooIndustries.Optimizer.PolicyRootSecurity.MarkerKey);
    var values = markers is null ? ["<no marker key>"] : markers.GetValueNames().Where(name => !name.StartsWith(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(fixture), StringComparison.OrdinalIgnoreCase)).Order(StringComparer.Ordinal).Select(name => name + "=" + markers.GetValue(name));
    return string.Join("\n", entries.Concat(values));
}
var realBefore = RealDataFolderState();
try
{
    var scripts = Path.Combine(fixture, "backend", "scripts");
    Directory.CreateDirectory(scripts);
    Directory.CreateDirectory(Path.Combine(fixture, "backend", "samples"));
    Directory.CreateDirectory(Path.Combine(fixture, "backend", "profiles"));
    File.Copy(Path.Combine(repo, "backend", "profiles", "protected-processes.json"), Path.Combine(fixture, "backend", "profiles", "protected-processes.json"));
    Directory.CreateSymbolicLink(Path.Combine(fixture, "backend", "bin"), Path.Combine(repo, "backend", "bin"));
    foreach (var name in new[] { "Invoke-UninstallCleanupApplyPackage.ps1", "Restore-UninstallCleanupExecution.ps1", "UninstallCleanup.Common.ps1", "BrandCompatibility.Common.ps1", "UninstallOutcome.Common.ps1", "BulkUninstall.Common.ps1", "OperationState.Common.ps1", "AppxInventory.Common.ps1", "ProcessProfile.Common.ps1", "GovernorOwnership.Common.ps1" })
        File.Copy(Path.Combine(repo, "backend", "scripts", name), Path.Combine(scripts, name));
    File.WriteAllText(Path.Combine(scripts, "Invoke-CleanupExclusions.ps1"), "param([string]$Action,[string[]]$FileTarget)\n'{\"schemaVersion\":1,\"status\":\"completed\",\"data\":{\"allowed\":true}}'\n");
    File.WriteAllText(Path.Combine(scripts, "Preview-OfficialUninstall.ps1"), "param([string]$AppId)\nGet-Content -LiteralPath (Join-Path $PSScriptRoot 'official.json') -Raw -Encoding UTF8\n");
    File.WriteAllText(Path.Combine(scripts, "New-CleanupDeletionManifest.ps1"), "param([string]$AppId)\nGet-Content -LiteralPath (Join-Path $PSScriptRoot 'cleanup.json') -Raw -Encoding UTF8\n");
    var original = Path.Combine(fixture, "reviewed.txt");
    var later = Path.Combine(fixture, "unreviewed.txt");
    File.WriteAllText(original, "reviewed original");
    File.WriteAllText(later, "unreviewed original");
    const string appId = "fixture:client-boundary";
    var official = new { actionId = "apps.previewOfficialUninstall", commands = new[] { new { appId, blocked = false, @protected = false, reviewRequired = true, executable = (string?)null } }, errors = Array.Empty<object>() };
    File.WriteAllText(Path.Combine(scripts, "official.json"), JsonSerializer.Serialize(official));
    object Manifest(string target) => new { manifestId = "client-review", appId, items = new[] { new { itemId = "reviewed", type = "file", target, @protected = false } }, errors = Array.Empty<object>() };
    File.WriteAllText(Path.Combine(scripts, "cleanup.json"), JsonSerializer.Serialize(Manifest(original)));
    gateRoot = Directory.CreateDirectory(Path.Combine(fixture, "gate-root")).FullName;
    if (OperatingSystem.IsWindows() && RooIndustries.Optimizer.PolicyRootSecurity.Elevated())
        RooIndustries.Optimizer.PolicyRootSecurity.Secure(gateRoot, RooIndustries.Optimizer.DataFolder.Kind);
    File.WriteAllText(Path.Combine(gateRoot, "temp"), "a file where the temporary folder belongs");
    var gateMessage = DataFolderGate.Attempt(() => gateRoot, out var gateEnabled);
    Check(gateMessage is not null && !gateEnabled && gateMessage.Contains("temp", StringComparison.OrdinalIgnoreCase), "A file error while opening the data folder becomes a message for the user instead of an unhandled exception: " + gateMessage);
    var gateProblem = DataFolderGate.Attempt(() => throw new IOException("The disk is full."), out _);
    Check(gateProblem == "The disk is full.", "Every other failure of the data folder check is reported with its own message");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", fixture);
    var fixtureData = Directory.CreateDirectory(Path.Combine(fixture, "data")).FullName;
    fixtureOperations = Directory.CreateDirectory(Path.Combine(fixtureData, "operations")).FullName;
    service = new LiveDataService(new BackendLocator(), Path.Combine(fixtureData, "settings"), fixtureOperations);
    Check(await service.GetOfficialUninstallPreviewAsync(appId) is not null, "Client reads the reviewed removal route");
    Check(await service.GetCleanupManifestAsync(appId) is not null, "Client reads the reviewed cleanup list");
    // Change the discovery response after review; execution must still use the approved snapshot.
    File.WriteAllText(Path.Combine(scripts, "cleanup.json"), JsonSerializer.Serialize(Manifest(later)));
    var applyResult = await service.RequestUninstallCleanupApplyResultAsync(appId, true, true, true);
    savedRollback = applyResult.RecoveryPath;
    var json = applyResult.Value;
    Check(!string.IsNullOrWhiteSpace(json), "Client receives the real executor result" + (string.IsNullOrWhiteSpace(json) ? ": " + applyResult.Error : ""));
    using var applied = JsonDocument.Parse(json!);
    var status = applied.RootElement.GetProperty("status").GetString();
    if (status != "success") Console.WriteLine(json);
    Check(status == "success", "Client app identity, hashes and approvals satisfy the executor");
    Check(!File.Exists(original) && File.Exists(later), "Apply removes only the reviewed target after discovery changes");
    var rollback = applied.RootElement.GetProperty("rollback").GetProperty("rollbackManifestPath").GetString()!;
    recoveryRoot = Path.GetDirectoryName(rollback);
    Check(applyResult.RecoveryPath == rollback && File.Exists(rollback), "Client retains the durable recovery location");
    var restored = await service.RestoreUninstallCleanupTextAsync(rollback);
    using var restore = JsonDocument.Parse(restored!);
    Check(restore.RootElement.GetProperty("status").GetString() == "success" && File.ReadAllText(original) == "reviewed original", "Client restores the original bytes through the real restore command");
    service.DiscardCleanupReview();
    Check(await service.RequestUninstallCleanupApplyTextAsync(appId, true, true, true) is null && File.Exists(later), "Discarded approval cannot be reused to remove newly discovered files");

    var applyScript = Path.Combine(scripts, "Invoke-UninstallCleanupApplyPackage.ps1");
    File.WriteAllText(applyScript, "param([int]$TimeoutSeconds = 30)\n'{\"timeoutSeconds\":' + $TimeoutSeconds + '}'\n");
    var vendorRemover = Path.Combine(fixture, "Vendor Uninstall.exe");
    File.WriteAllText(vendorRemover, "fixture");
    var vendorRoute = new { actionId = "apps.previewOfficialUninstall", commands = new[] { new { appId, blocked = false, @protected = false, reviewRequired = true, executable = (string?)vendorRemover } }, errors = Array.Empty<object>() };
    File.WriteAllText(Path.Combine(scripts, "official.json"), JsonSerializer.Serialize(vendorRoute));
    File.WriteAllText(Path.Combine(scripts, "cleanup.json"), JsonSerializer.Serialize(Manifest(later)));
    Check(await service.GetOfficialUninstallPreviewAsync(appId) is not null && await service.GetCleanupManifestAsync(appId) is not null, "Client reads a reviewed route that runs the app's own remover");
    var vendorRun = await service.RequestUninstallCleanupApplyResultAsync(appId, true, true, false);
    Check(vendorRun.Value?.Contains("\"timeoutSeconds\":600", StringComparison.Ordinal) == true, "An interactive Leftover-tab remover gets a 600 second observation window: " + vendorRun.Value + vendorRun.Error);
    File.Copy(Path.Combine(repo, "backend", "scripts", "Invoke-UninstallCleanupApplyPackage.ps1"), applyScript, true);
    service.DiscardCleanupReview();

    var operationsRoot = Path.Combine(fixture, "operations");
    Directory.CreateDirectory(operationsRoot);
    var operations = new OptimizerService(new BackendLocator(), operationsRoot);
    var cpuJournal = Path.Combine(operationsRoot, "cpu.json");
    var cpuPointer = Path.Combine(operationsRoot, "cpu-active.txt");
    using var currentProcess = Process.GetCurrentProcess();
    var savedCpu = new CpuSetJournal { Status = "applied", Preview = new CpuSetPlan { Identity = new CpuProcessIdentity
    {
        ProcessId = currentProcess.Id,
        CreationTimeFileTimeUtc = currentProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
    } } };
    void SaveCpu()
    {
        File.WriteAllText(cpuJournal, JsonSerializer.Serialize(savedCpu));
        File.WriteAllText(cpuPointer, cpuJournal);
    }
    SaveCpu();
    Check(!await operations.ReleaseEndedCpuSessionAsync(cpuJournal) && File.Exists(cpuPointer), "A live process keeps its CPU recovery ticket");
    savedCpu.Preview.Identity.CreationTimeFileTimeUtc = "1";
    SaveCpu();
    Check(await operations.ReleaseEndedCpuSessionAsync(cpuJournal) && !File.Exists(cpuPointer) && File.Exists(cpuJournal), "A different creation identity releases only the old ticket and retains its history");
    savedCpu.Preview.Identity.CreationTimeFileTimeUtc = "";
    SaveCpu();
    var incompleteRejected = false;
    try { await operations.ReleaseEndedCpuSessionAsync(cpuJournal); }
    catch (InvalidDataException) { incompleteRejected = true; }
    Check(incompleteRejected && File.Exists(cpuPointer), "Incomplete process identity cannot discard recovery");
    var sleeperStart = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, CreateNoWindow = true };
    foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30" }) sleeperStart.ArgumentList.Add(argument);
    using var sleeper = Process.Start(sleeperStart)!;
    try
    {
        savedCpu.Preview.Identity.ProcessId = sleeper.Id;
        savedCpu.Preview.Identity.CreationTimeFileTimeUtc = sleeper.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();
        SaveCpu();
        sleeper.Kill();
        await sleeper.WaitForExitAsync();
        Check(await operations.ReleaseEndedCpuSessionAsync(cpuJournal) && !File.Exists(cpuPointer), "Verified process shutdown releases its CPU recovery ticket");
    }
    finally { if (!sleeper.HasExited) { sleeper.Kill(); await sleeper.WaitForExitAsync(); } }
    Check(RealDataFolderState() == realBefore, "The run left the real data folder and its protection markers exactly as it found them");
}
finally
{
    if (service is not null)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var lazy = typeof(LiveDataService).GetField("_operations", flags)?.GetValue(service);
        if (lazy?.GetType().GetProperty("IsValueCreated")?.GetValue(lazy) is true)
        {
            var created = lazy.GetType().GetProperty("Value")!.GetValue(lazy)!;
            (created.GetType().GetField("_storageLease", flags)?.GetValue(created) as IDisposable)?.Dispose();
        }
    }
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", previousRoot);
    recoveryRoot ??= savedRollback is { } savedPath ? Path.GetDirectoryName(savedPath) : null;
    if (recoveryRoot is not null && Directory.Exists(recoveryRoot)) Directory.Delete(recoveryRoot, true);
    var hostLink = Path.Combine(fixture, "backend", "bin");
    if (Directory.Exists(hostLink) && new DirectoryInfo(hostLink).LinkTarget is not null) Directory.Delete(hostLink, false);
    if (Directory.Exists(fixture)) Directory.Delete(fixture, true);
    foreach (var protectedRoot in new[] { fixtureOperations, gateRoot })
    {
        if (protectedRoot is null) continue;
        using var markers = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(RooIndustries.Optimizer.PolicyRootSecurity.MarkerKey, true);
        markers?.DeleteValue(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(protectedRoot), false);
        markers?.DeleteValue(RooIndustries.Optimizer.PolicyRootSecurity.MarkerName(protectedRoot) + RooIndustries.Optimizer.PolicyRootSecurity.ProtectedAtSuffix, false);
    }
}
