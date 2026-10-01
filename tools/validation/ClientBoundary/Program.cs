using System.Text.Json;
using System.Diagnostics;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

if (args is [var gameRepo, "--game-sessions"]) { await GameSessionChecks.Run(gameRepo); return; }

var repo = Path.GetFullPath(args[0]);
var fixture = Path.Combine(Path.GetTempPath(), "roo-industries-client-boundary-" + Guid.NewGuid().ToString("N"));
var previousRoot = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
string? recoveryRoot = null;
string? savedRollback = null;
LiveDataService? service = null;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    Console.WriteLine("PASS " + message);
}
try
{
    var scripts = Path.Combine(fixture, "backend", "scripts");
    Directory.CreateDirectory(scripts);
    Directory.CreateDirectory(Path.Combine(fixture, "backend", "samples"));
    foreach (var name in new[] { "Invoke-UninstallCleanupApplyPackage.ps1", "Restore-UninstallCleanupExecution.ps1", "UninstallCleanup.Common.ps1", "BrandCompatibility.Common.ps1", "UninstallOutcome.Common.ps1", "BulkUninstall.Common.ps1", "OperationState.Common.ps1", "AppxInventory.Common.ps1", "ProcessProfile.Common.ps1" })
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
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", fixture);
    service = new LiveDataService(new BackendLocator());
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
}
finally
{
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", previousRoot);
    recoveryRoot ??= savedRollback is { } savedPath ? Path.GetDirectoryName(savedPath) : null;
    if (recoveryRoot is not null && Directory.Exists(recoveryRoot)) Directory.Delete(recoveryRoot, true);
    if (Directory.Exists(fixture)) Directory.Delete(fixture, true);
}
