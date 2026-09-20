using RooIndustries.OptimizationSuite.Services;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.Optimizer;
using System.Text.Json;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("The action runner fixture requires Windows PowerShell.");
var root = Path.Combine(Path.GetTempPath(), "roo-industries-action-runner-" + Guid.NewGuid().ToString("N"));
var previousBackend = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
var previousFixture = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_ACTION_FIXTURE_ROOT");
var previousRecovery = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY");
var previousSabotage = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_PROCESS_POINTER");
var previousNvidiaSabotage = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_NVIDIA_POINTER");
var previousNoChange = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_ACTION_PROCESS_NO_CHANGE");
var previousNvidiaMode = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE");
var checks = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    checks++;
    Console.WriteLine("PASS " + message);
}
async Task WaitFor(string path)
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    while (!File.Exists(path))
    {
        await Task.Delay(25, timeout.Token);
    }
}
int Counter(string name)
{
    var path = Path.Combine(root, name);
    return File.Exists(path) ? int.Parse(File.ReadAllText(path)) : 0;
}
try
{
    Directory.CreateDirectory(Path.Combine(root, "backend/samples"));
    var scripts = Path.Combine(root, "backend/scripts");
    var recoveryDirectory = Path.Combine(root, "recovery");
    Directory.CreateDirectory(scripts);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", root);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_FIXTURE_ROOT", root);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", recoveryDirectory);

    await File.WriteAllTextAsync(Path.Combine(scripts, "Apply-ProcessProfile.ps1"), FixtureScripts.ProcessApply);
    await File.WriteAllTextAsync(Path.Combine(scripts, "Restore-ProcessProfileBackup.ps1"), FixtureScripts.ProcessRestore);
    await File.WriteAllTextAsync(Path.Combine(scripts, "Invoke-NvidiaNipExecutor.ps1"), FixtureScripts.Nvidia);
    var service = new LiveDataService(new BackendLocator(), recoveryDirectory);
    var reopened = new LiveDataService(new BackendLocator(), recoveryDirectory);

    var generic = Path.Combine(scripts, "fixture.ps1");
    await File.WriteAllTextAsync(generic, "Write-Output '{\"status\":\"success\"}'; exit 7");
    var failed = await service.RunBackendScriptResultAsync("fixture.ps1");
    Check(failed.Value?.Contains("success") == true && failed.Error?.Contains("code 1") == true && service.LastError == failed.Error,
        "A failed command preserves its JSON output and exact nonzero exit error");
    Check(await service.RunBackendScriptTextAsync("fixture.ps1") is null,
        "Text-only callers cannot receive failed output as successful data");
    await File.WriteAllTextAsync(generic, "Write-Output '{\"status\":\"success\"}'; exit 0");
    var success = await service.RunBackendScriptResultAsync("fixture.ps1");
    Check(success.Value?.Contains("success") == true && success.Error is null && service.LastError is null,
        "A successful command clears the prior operation error");

    var firstApply = service.ApplyProcessProfileResultAsync();
    await WaitFor(Path.Combine(root, "process-apply-started"));
    var rejectedApply = await reopened.ApplyProcessProfileResultAsync();
    Check(rejectedApply.Value is null && rejectedApply.Error?.Contains("already in progress", StringComparison.OrdinalIgnoreCase) == true && Counter("process-apply-count.txt") == 1,
        "A second process apply loses the cross-instance lease without starting its script");
    File.WriteAllText(Path.Combine(root, "process-apply-release"), "release");
    var firstApplyResult = await firstApply;
    var firstProcess = service.ProcessProfileRecovery;
    Check(firstProcess is not null && firstProcess.Valid() && firstApplyResult.RecoveryPath == firstProcess.Path && reopened.ProcessProfileRecovery == firstProcess,
        "Process apply persists its verified recovery before releasing the operation lease");

    var secondApplyResult = await reopened.ApplyProcessProfileResultAsync();
    var secondProcess = service.ProcessProfileRecovery;
    Check(secondProcess is not null && secondProcess.Valid() && secondProcess != firstProcess && secondApplyResult.RecoveryPath == secondProcess.Path,
        "A later process apply replaces the pointer with its own verified artifact");
    var staleRestore = await service.RestoreProcessProfileResultAsync(firstProcess!);
    Check(staleRestore.Value is null && staleRestore.Error?.Contains("no longer current", StringComparison.OrdinalIgnoreCase) == true && Counter("process-restore-count.txt") == 0 && reopened.ProcessProfileRecovery == secondProcess,
        "An older process recovery cannot run or clear a newer pointer");

    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SLOW_PROCESS_RESTORE", "1");
    var restore = reopened.RestoreProcessProfileResultAsync(secondProcess!);
    await WaitFor(Path.Combine(root, "process-restore-started"));
    var applyDuringRestore = await service.ApplyProcessProfileResultAsync();
    Check(applyDuringRestore.Value is null && applyDuringRestore.Error?.Contains("already in progress", StringComparison.OrdinalIgnoreCase) == true && Counter("process-apply-count.txt") == 2,
        "Process apply cannot start while another instance is restoring");
    File.WriteAllText(Path.Combine(root, "process-restore-release"), "release");
    var restoreResult = await restore;
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SLOW_PROCESS_RESTORE", null);
    Check(restoreResult.Error is null && restoreResult.RecoveryPath is null && service.ProcessProfileRecovery is null,
        "Confirmed process restore clears its exact pointer before releasing the lease");
    await service.ApplyProcessProfileResultAsync();
    var thirdProcess = new LiveDataService(new BackendLocator(), recoveryDirectory).ProcessProfileRecovery;
    Check(thirdProcess is not null && thirdProcess.Valid() && thirdProcess != secondProcess,
        "A new service instance observes the process pointer from the later completed operation");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_PROCESS_NO_CHANGE", "1");
    var noChange = await service.ApplyProcessProfileResultAsync();
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_PROCESS_NO_CHANGE", null);
    Check(noChange.Error is null && service.ProcessProfileRecovery == thirdProcess,
        "A confirmed no-change process apply restores the prior durable generation and recovery pointer");

    var lockFailureDirectory = Path.Combine(root, "lock-open-failure");
    Directory.CreateDirectory(Path.Combine(lockFailureDirectory, "process-profile-operation.lock"));
    Directory.CreateDirectory(Path.Combine(lockFailureDirectory, "nvidia-profile-operation.lock"));
    var lockFailureService = new LiveDataService(new BackendLocator(), lockFailureDirectory);
    var processCountBeforeLockFailure = Counter("process-apply-count.txt");
    var nvidiaCountBeforeLockFailure = Counter("nvidia-apply-count.txt");
    var processLockFailure = await lockFailureService.ApplyProcessProfileResultAsync();
    var nvidiaLockFailure = await lockFailureService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Check(processLockFailure.Error?.Contains("lock could not be opened", StringComparison.OrdinalIgnoreCase) == true
            && nvidiaLockFailure.Error?.Contains("lock could not be opened", StringComparison.OrdinalIgnoreCase) == true
            && Counter("process-apply-count.txt") == processCountBeforeLockFailure
            && Counter("nvidia-apply-count.txt") == nvidiaCountBeforeLockFailure,
        "Lock path failures are reported distinctly from contention and dispatch no helper");

    var generationFailureDirectory = Path.Combine(root, "generation-write-failure");
    Directory.CreateDirectory(Path.Combine(generationFailureDirectory, "process-profile-operation-generation.json"));
    Directory.CreateDirectory(Path.Combine(generationFailureDirectory, "nvidia-profile-operation-generation.json"));
    var generationFailureService = new LiveDataService(new BackendLocator(), generationFailureDirectory);
    processCountBeforeLockFailure = Counter("process-apply-count.txt");
    nvidiaCountBeforeLockFailure = Counter("nvidia-apply-count.txt");
    var processGenerationFailure = await generationFailureService.ApplyProcessProfileResultAsync();
    var nvidiaGenerationFailure = await generationFailureService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Check(processGenerationFailure.Error?.Contains("generation could not be recorded", StringComparison.OrdinalIgnoreCase) == true
            && nvidiaGenerationFailure.Error?.Contains("generation could not be recorded", StringComparison.OrdinalIgnoreCase) == true
            && Counter("process-apply-count.txt") == processCountBeforeLockFailure
            && Counter("nvidia-apply-count.txt") == nvidiaCountBeforeLockFailure,
        "Generation persistence failures reject both actions before helper dispatch");

    var failedRecoveryDirectory = Path.Combine(root, "recovery-write-failure");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", failedRecoveryDirectory);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_PROCESS_POINTER", "1");
    var failedPersistenceService = new LiveDataService(new BackendLocator(), failedRecoveryDirectory);
    var failedPersistence = await failedPersistenceService.ApplyProcessProfileResultAsync();
    var failedProcessHandle = ProcessProfileRecovery.FromApply(failedPersistence.Value, failedPersistence.RecoveryGeneration);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_PROCESS_POINTER", null);
    Check(failedPersistence.Value is not null && failedPersistence.Error?.Contains("could not be saved", StringComparison.OrdinalIgnoreCase) == true
            && failedPersistence.RecoveryPath is not null && failedProcessHandle?.Path == failedPersistence.RecoveryPath
            && new LiveDataService(new BackendLocator(), failedRecoveryDirectory).ProcessProfileRecovery == failedProcessHandle,
        "Process persistence failure preserves the operation JSON, error, and verified in-window recovery path");
    Directory.Delete(Path.Combine(failedRecoveryDirectory, "process-profile-recovery.json"));
    var newerFailedDirectoryService = new LiveDataService(new BackendLocator(), failedRecoveryDirectory);
    await newerFailedDirectoryService.ApplyProcessProfileResultAsync();
    var newerFailedDirectoryProcess = newerFailedDirectoryService.ProcessProfileRecovery;
    var processRestoreCount = Counter("process-restore-count.txt");
    var rejectedFailedHandle = await failedPersistenceService.RestoreProcessProfileResultAsync(failedProcessHandle!);
    Check(newerFailedDirectoryProcess is not null && newerFailedDirectoryProcess != failedProcessHandle
            && rejectedFailedHandle.Error?.Contains("no longer current", StringComparison.OrdinalIgnoreCase) == true
            && Counter("process-restore-count.txt") == processRestoreCount,
        "A newer process operation invalidates an in-memory handle created after pointer persistence failed");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", recoveryDirectory);

    var firstNvidiaApply = service.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    await WaitFor(Path.Combine(root, "nvidia-apply-started"));
    var rejectedNvidiaApply = await reopened.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Check(rejectedNvidiaApply.Value is null && rejectedNvidiaApply.Error?.Contains("already in progress", StringComparison.OrdinalIgnoreCase) == true && Counter("nvidia-apply-count.txt") == 1,
        "A second NVIDIA apply loses the cross-instance lease without starting its script");
    File.WriteAllText(Path.Combine(root, "nvidia-apply-release"), "release");
    await firstNvidiaApply;
    var firstNvidia = await reopened.ReadNvidiaProfileRecoveryAsync("base-profile");
    Check(firstNvidia is not null && firstNvidia.RollbackManifestPath.StartsWith(recoveryDirectory, StringComparison.OrdinalIgnoreCase)
            && firstNvidia.ExportPath.StartsWith(recoveryDirectory, StringComparison.OrdinalIgnoreCase),
        "Injected recovery storage contains the NVIDIA artifacts and pointer from the completed apply");

    await reopened.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    var secondNvidia = await service.ReadNvidiaProfileRecoveryAsync("base-profile");
    Check(secondNvidia is not null && secondNvidia != firstNvidia,
        "A later NVIDIA apply replaces the pointer with its exact artifacts");
    var staleNvidiaRestore = await service.RestoreNvidiaProfileResultAsync(firstNvidia!, true);
    Check(staleNvidiaRestore.Value is null && staleNvidiaRestore.Error?.Contains("no longer current", StringComparison.OrdinalIgnoreCase) == true && Counter("nvidia-restore-count.txt") == 0
            && await reopened.ReadNvidiaProfileRecoveryAsync("base-profile") == secondNvidia,
        "An older NVIDIA recovery cannot run or clear a newer pointer");

    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SLOW_NVIDIA_RESTORE", "1");
    var nvidiaRestore = reopened.RestoreNvidiaProfileResultAsync(secondNvidia!, true);
    await WaitFor(Path.Combine(root, "nvidia-restore-started"));
    var nvidiaApplyDuringRestore = await service.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Check(nvidiaApplyDuringRestore.Value is null && nvidiaApplyDuringRestore.Error?.Contains("already in progress", StringComparison.OrdinalIgnoreCase) == true && Counter("nvidia-apply-count.txt") == 2,
        "NVIDIA apply cannot start while another instance is restoring");
    File.WriteAllText(Path.Combine(root, "nvidia-restore-release"), "release");
    var nvidiaRestoreResult = await nvidiaRestore;
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SLOW_NVIDIA_RESTORE", null);
    Check(nvidiaRestoreResult.Error is null && nvidiaRestoreResult.RecoveryPath is null && await service.ReadNvidiaProfileRecoveryAsync("base-profile") is null,
        "Confirmed NVIDIA restore clears its exact pointer before releasing the lease");
    await service.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    var thirdNvidia = await new LiveDataService(new BackendLocator(), recoveryDirectory).ReadNvidiaProfileRecoveryAsync("base-profile");
    Check(thirdNvidia is not null && thirdNvidia != secondNvidia,
        "A new service instance observes the NVIDIA pointer from the later completed operation");

    var failedNvidiaDirectory = Path.Combine(root, "nvidia-recovery-write-failure");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", failedNvidiaDirectory);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_NVIDIA_POINTER", "1");
    var failedNvidiaService = new LiveDataService(new BackendLocator(), failedNvidiaDirectory);
    var failedNvidiaPersistence = await failedNvidiaService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    var failedNvidiaHandle = await new LiveDataService(new BackendLocator(), failedNvidiaDirectory).ReadNvidiaProfileRecoveryAsync("base-profile");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_NVIDIA_POINTER", null);
    Check(failedNvidiaPersistence.Value is not null && failedNvidiaPersistence.Error?.Contains("could not be saved", StringComparison.OrdinalIgnoreCase) == true
            && failedNvidiaPersistence.RecoveryPath == failedNvidiaHandle?.RollbackManifestPath,
        "NVIDIA pointer persistence failure preserves the exact validated artifact across page service instances");
    Directory.Delete(Path.Combine(failedNvidiaDirectory, "nvidia-profile-recovery.json"));
    var newerFailedNvidiaService = new LiveDataService(new BackendLocator(), failedNvidiaDirectory);
    await newerFailedNvidiaService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    var newerFailedNvidia = await newerFailedNvidiaService.ReadNvidiaProfileRecoveryAsync("base-profile");
    var nvidiaRestoreCount = Counter("nvidia-restore-count.txt");
    var rejectedFailedNvidia = await failedNvidiaService.RestoreNvidiaProfileResultAsync(failedNvidiaHandle!, true);
    Check(newerFailedNvidia is not null && newerFailedNvidia != failedNvidiaHandle
            && rejectedFailedNvidia.Error?.Contains("no longer current", StringComparison.OrdinalIgnoreCase) == true
            && Counter("nvidia-restore-count.txt") == nvidiaRestoreCount,
        "A newer NVIDIA operation invalidates an in-memory handle created after pointer persistence failed");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", recoveryDirectory);

    var noImportDirectory = Path.Combine(root, "nvidia-no-import");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", noImportDirectory);
    var noImportService = new LiveDataService(new BackendLocator(), noImportDirectory);
    await noImportService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    var beforeNoImport = await noImportService.ReadNvidiaProfileRecoveryAsync("base-profile");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", "NoImport");
    await noImportService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", null);
    Check(beforeNoImport is not null && await noImportService.ReadNvidiaProfileRecoveryAsync("base-profile") == beforeNoImport,
        "Identity-bound explicit no-import evidence preserves the prior NVIDIA generation and recovery");

    var missingProofDirectory = Path.Combine(root, "nvidia-missing-no-import-proof");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", missingProofDirectory);
    var missingProofService = new LiveDataService(new BackendLocator(), missingProofDirectory);
    await missingProofService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", "MissingProof");
    await missingProofService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", null);
    Check(await missingProofService.ReadNvidiaProfileRecoveryAsync("base-profile") is null,
        "Missing no-import evidence leaves the newer NVIDIA generation unknown instead of reviving the prior pointer");

    var contradictoryProofDirectory = Path.Combine(root, "nvidia-contradictory-no-import-proof");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", contradictoryProofDirectory);
    var contradictoryProofService = new LiveDataService(new BackendLocator(), contradictoryProofDirectory);
    await contradictoryProofService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", "ContradictoryProof");
    await contradictoryProofService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", null);
    Check(await contradictoryProofService.ReadNvidiaProfileRecoveryAsync("base-profile") is null,
        "Contradictory manifest evidence leaves the newer NVIDIA generation unknown instead of reviving the prior pointer");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", recoveryDirectory);

    var independentDirectory = Path.Combine(root, "independent-generation");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", independentDirectory);
    var independentService = new LiveDataService(new BackendLocator(), independentDirectory);
    await independentService.ApplyProcessProfileResultAsync();
    var cachedProcess = independentService.ProcessProfileRecovery!;
    var externalProcessBackup = Path.Combine(root, "external-process-backup.json");
    await File.WriteAllTextAsync(externalProcessBackup, "{\"actionId\":\"performance.applyProfile\",\"backupId\":\"external-process\",\"profileId\":\"fixture-profile\",\"dryRun\":false,\"snapshots\":[{\"processId\":901}]}");
    var externalProcess = new ProcessProfileRecovery(externalProcessBackup, "external-process", "external-process-generation");
    OperationFiles.Write(Path.Combine(independentDirectory, "process-profile-operation-generation.json"), new RecoveryOperationGeneration(externalProcess.Generation!));
    OperationFiles.Write(Path.Combine(independentDirectory, "process-profile-recovery.json"), externalProcess);
    var independentProcessReader = new LiveDataService(new BackendLocator(), independentDirectory);
    var independentRestoreCount = Counter("process-restore-count.txt");
    var independentStaleProcess = await independentService.RestoreProcessProfileResultAsync(cachedProcess);
    Check(independentService.ProcessProfileRecovery == externalProcess && independentProcessReader.ProcessProfileRecovery == externalProcess
            && independentStaleProcess.Error?.Contains("no longer current", StringComparison.OrdinalIgnoreCase) == true
            && Counter("process-restore-count.txt") == independentRestoreCount,
        "A newer durable process generation outranks stale in-process caches across service instances");

    await independentService.ApplyNvidiaProfileResultAsync("base-profile", true, true, true);
    var cachedNvidia = (await independentService.ReadNvidiaProfileRecoveryAsync("base-profile"))!;
    var externalNvidiaRoot = Path.Combine(root, "external-nvidia");
    Directory.CreateDirectory(externalNvidiaRoot);
    var externalNvidiaExport = Path.Combine(externalNvidiaRoot, "before.nip");
    var externalNvidiaManifest = Path.Combine(externalNvidiaRoot, "rollback.json");
    await File.WriteAllTextAsync(externalNvidiaExport, "external NVIDIA export");
    await File.WriteAllTextAsync(externalNvidiaManifest, "{\"actionId\":\"drivers.nvidiaNip.rollbackManifest\",\"restoreActionId\":\"drivers.nvidiaNip.restoreProfile\",\"profileId\":\"base-profile\",\"rollbackSupported\":true,\"exportCompleted\":true,\"importAttempted\":true,\"exportPath\":" + JsonSerializer.Serialize(externalNvidiaExport) + "}");
    var externalNvidia = new NvidiaProfileRecovery("base-profile", externalNvidiaManifest, externalNvidiaExport, "external-nvidia-generation");
    OperationFiles.Write(Path.Combine(independentDirectory, "nvidia-profile-operation-generation.json"), new RecoveryOperationGeneration(externalNvidia.Generation!));
    OperationFiles.Write(Path.Combine(independentDirectory, "nvidia-profile-recovery.json"), externalNvidia);
    var independentNvidiaReader = new LiveDataService(new BackendLocator(), independentDirectory);
    var independentNvidiaRestoreCount = Counter("nvidia-restore-count.txt");
    var independentStaleNvidia = await independentService.RestoreNvidiaProfileResultAsync(cachedNvidia, true);
    Check(await independentService.ReadNvidiaProfileRecoveryAsync("base-profile") == externalNvidia
            && await independentNvidiaReader.ReadNvidiaProfileRecoveryAsync("base-profile") == externalNvidia
            && independentStaleNvidia.Error?.Contains("no longer current", StringComparison.OrdinalIgnoreCase) == true
            && Counter("nvidia-restore-count.txt") == independentNvidiaRestoreCount,
        "A newer durable NVIDIA generation outranks stale in-process caches across service instances");
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", recoveryDirectory);

    Console.WriteLine($"Passed {checks} native action runner checks.");
}
finally
{
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", previousBackend);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_FIXTURE_ROOT", previousFixture);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY", previousRecovery);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_PROCESS_POINTER", previousSabotage);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SABOTAGE_NVIDIA_POINTER", previousNvidiaSabotage);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_PROCESS_NO_CHANGE", previousNoChange);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_NVIDIA_MODE", previousNvidiaMode);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SLOW_PROCESS_RESTORE", null);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_ACTION_SLOW_NVIDIA_RESTORE", null);
    if (Directory.Exists(root)) Directory.Delete(root, true);
}

static class FixtureScripts
{
public const string ProcessApply = """
param([switch]$ConfirmApply)
$root = $env:ROO_INDUSTRIES_ACTION_FIXTURE_ROOT
$countPath = Join-Path $root 'process-apply-count.txt'
$count = if (Test-Path -LiteralPath $countPath) { [int](Get-Content -LiteralPath $countPath -Raw) + 1 } else { 1 }
Set-Content -LiteralPath $countPath -Value $count -Encoding ascii
if ($count -eq 1) {
    Set-Content -LiteralPath (Join-Path $root 'process-apply-started') -Value started -Encoding ascii
    $release = Join-Path $root 'process-apply-release'
    for ($index = 0; $index -lt 400 -and -not (Test-Path -LiteralPath $release); $index++) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path -LiteralPath $release)) { throw 'Timed out waiting for process apply release.' }
}
if ($env:ROO_INDUSTRIES_ACTION_PROCESS_NO_CHANGE -eq '1') {
    @{ actionId='performance.applyProfile'; dryRun=$false; status='success'; errors=@(); backup=$null; result=@{ status='success'; summary='no changes'; changedItems=@() } } | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
$backupId = 'process-backup-' + $count
$backupPath = Join-Path $root ($backupId + '.json')
@{ actionId='performance.applyProfile'; backupId=$backupId; profileId='fixture-profile'; dryRun=$false; snapshots=@(@{ processId=100+$count }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $backupPath -Encoding utf8
if ($env:ROO_INDUSTRIES_ACTION_SABOTAGE_PROCESS_POINTER -eq '1') {
    $pointer = Join-Path $env:ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY 'process-profile-recovery.json'
    New-Item -ItemType Directory -Path $pointer -Force | Out-Null
}
@{
    actionId='performance.applyProfile'; dryRun=$false; status='success'; errors=@()
    backup=@{ backupId=$backupId; location=$backupPath; rollbackSupported=$true }
    result=@{ status='success'; summary='fixture applied'; changedItems=@(@{ processId=100+$count }) }
} | ConvertTo-Json -Depth 10 -Compress
""";

public const string ProcessRestore = """
param([string]$BackupPath, [switch]$ConfirmApply)
$root = $env:ROO_INDUSTRIES_ACTION_FIXTURE_ROOT
$countPath = Join-Path $root 'process-restore-count.txt'
$count = if (Test-Path -LiteralPath $countPath) { [int](Get-Content -LiteralPath $countPath -Raw) + 1 } else { 1 }
Set-Content -LiteralPath $countPath -Value $count -Encoding ascii
if ($env:ROO_INDUSTRIES_ACTION_SLOW_PROCESS_RESTORE -eq '1') {
    Set-Content -LiteralPath (Join-Path $root 'process-restore-started') -Value started -Encoding ascii
    $release = Join-Path $root 'process-restore-release'
    for ($index = 0; $index -lt 400 -and -not (Test-Path -LiteralPath $release); $index++) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path -LiteralPath $release)) { throw 'Timed out waiting for process restore release.' }
}
$backup = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
@{
    actionId='performance.rollbackProfile'; dryRun=$false; status='success'; errors=@()
    backup=@{ backupId=$backup.backupId; location=$BackupPath; rollbackSupported=$true }
    result=@{ status='success'; summary='fixture restored'; changedItems=@(@{ processId=101 }) }
} | ConvertTo-Json -Depth 10 -Compress
""";

public const string Nvidia = """
param(
    [string]$Operation, [string]$ProfileId, [string]$ExecutorMode, [string]$ExportPath,
    [string]$RollbackManifestPath, [switch]$ConfirmApply, [switch]$UserApproved,
    [switch]$AllowRealNvpiExecution, [switch]$BenchmarkEvidenceAttached
)
$root = $env:ROO_INDUSTRIES_ACTION_FIXTURE_ROOT
if ($Operation -eq 'Apply') {
    $countPath = Join-Path $root 'nvidia-apply-count.txt'
    $count = if (Test-Path -LiteralPath $countPath) { [int](Get-Content -LiteralPath $countPath -Raw) + 1 } else { 1 }
    Set-Content -LiteralPath $countPath -Value $count -Encoding ascii
    if ($count -eq 1) {
        Set-Content -LiteralPath (Join-Path $root 'nvidia-apply-started') -Value started -Encoding ascii
        $release = Join-Path $root 'nvidia-apply-release'
        for ($index = 0; $index -lt 400 -and -not (Test-Path -LiteralPath $release); $index++) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-Path -LiteralPath $release)) { throw 'Timed out waiting for NVIDIA apply release.' }
    }
    if ($env:ROO_INDUSTRIES_ACTION_NVIDIA_MODE -eq 'NoImport') {
        @{
            actionId='drivers.nvidiaNip.executor'; operation='Apply'; profileId=$ProfileId; dryRun=$true; status='blocked'
            rollbackManifestPath=$null; gates=@(@{ gateId='fixture-block'; blocking=$true }); errors=@()
            summary=@{ blockingGateCount=1; exportAttempted=$false; exportCompleted=$false; importAttempted=$false; importCompleted=$false }
        } | ConvertTo-Json -Depth 10 -Compress
        exit 0
    }
    if ($env:ROO_INDUSTRIES_ACTION_NVIDIA_MODE -eq 'MissingProof') {
        @{
            actionId='drivers.nvidiaNip.executor'; operation='Apply'; profileId=$ProfileId; dryRun=$true; status='blocked'
            rollbackManifestPath=$null; gates=@(@{ gateId='fixture-block'; blocking=$true }); errors=@()
            summary=@{ blockingGateCount=1; exportAttempted=$false; exportCompleted=$false; importCompleted=$false }
        } | ConvertTo-Json -Depth 10 -Compress
        exit 0
    }
    if ($env:ROO_INDUSTRIES_ACTION_NVIDIA_MODE -eq 'ContradictoryProof') {
        New-Item -ItemType Directory -Path (Split-Path $RollbackManifestPath -Parent) -Force | Out-Null
        @{ actionId='drivers.nvidiaNip.rollbackManifest'; restoreActionId='drivers.nvidiaNip.restoreProfile'; profileId='wrong-profile'; rollbackSupported=$true; exportCompleted=$true; importAttempted=$true; importCompleted=$false; exportPath=$ExportPath } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RollbackManifestPath -Encoding utf8
        @{
            actionId='drivers.nvidiaNip.executor'; operation='Apply'; profileId=$ProfileId; dryRun=$false; status='failed'
            rollbackManifestPath=$RollbackManifestPath; gates=@(); errors=@()
            summary=@{ blockingGateCount=0; exportAttempted=$true; exportCompleted=$true; importAttempted=$false; importCompleted=$false }
        } | ConvertTo-Json -Depth 10 -Compress
        exit 0
    }
    New-Item -ItemType Directory -Path (Split-Path $ExportPath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $ExportPath -Value ('fixture NVIDIA export ' + $count) -Encoding utf8
    @{
        actionId='drivers.nvidiaNip.rollbackManifest'; restoreActionId='drivers.nvidiaNip.restoreProfile'
        profileId=$ProfileId; rollbackSupported=$true; exportCompleted=$true; importAttempted=$true
        importCompleted=$true; exportPath=$ExportPath
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RollbackManifestPath -Encoding utf8
    if ($env:ROO_INDUSTRIES_ACTION_SABOTAGE_NVIDIA_POINTER -eq '1') {
        $pointer = Join-Path $env:ROO_INDUSTRIES_ACTION_RECOVERY_DIRECTORY 'nvidia-profile-recovery.json'
        New-Item -ItemType Directory -Path $pointer -Force | Out-Null
    }
    @{
        actionId='drivers.nvidiaNip.executor'; operation='Apply'; profileId=$ProfileId; dryRun=$false; status='success'
        rollbackManifestPath=$RollbackManifestPath; rollbackManifest=@{ exportPath=$ExportPath }
        gates=@(); errors=@(); summary=@{ blockingGateCount=0; exportAttempted=$true; exportCompleted=$true; importAttempted=$true; importCompleted=$true }
    } | ConvertTo-Json -Depth 10 -Compress
    exit 0
}
$countPath = Join-Path $root 'nvidia-restore-count.txt'
$count = if (Test-Path -LiteralPath $countPath) { [int](Get-Content -LiteralPath $countPath -Raw) + 1 } else { 1 }
Set-Content -LiteralPath $countPath -Value $count -Encoding ascii
if ($env:ROO_INDUSTRIES_ACTION_SLOW_NVIDIA_RESTORE -eq '1') {
    Set-Content -LiteralPath (Join-Path $root 'nvidia-restore-started') -Value started -Encoding ascii
    $release = Join-Path $root 'nvidia-restore-release'
    for ($index = 0; $index -lt 400 -and -not (Test-Path -LiteralPath $release); $index++) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path -LiteralPath $release)) { throw 'Timed out waiting for NVIDIA restore release.' }
}
@{
    actionId='drivers.nvidiaNip.executor'; operation='Restore'; profileId=$ProfileId; dryRun=$false; status='success'
    rollbackManifestPath=$RollbackManifestPath; gates=@(); errors=@()
    summary=@{ blockingGateCount=0; exportAttempted=$false; importAttempted=$true; importCompleted=$true }
} | ConvertTo-Json -Depth 10 -Compress
""";
}
