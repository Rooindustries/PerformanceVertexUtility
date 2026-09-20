using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record LiveDataResult<T>(T? Value, string? Error, string? RecoveryPath = null, string? RecoveryGeneration = null);
public sealed record NvidiaProfileRecovery(string ProfileId, string RollbackManifestPath, string ExportPath, string? Generation = null);

public sealed class LiveDataService
{
    private readonly BackendLocator _locator;
    private readonly string _recoveryDirectory;
    private readonly string _recoveryKey;
    private static readonly ConcurrentDictionary<string, ProcessProfileRecovery> VolatileProcessRecovery = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, NvidiaProfileRecovery> VolatileNvidiaRecovery = new(StringComparer.OrdinalIgnoreCase);
    private string ProcessRecoveryPath => Path.Combine(_recoveryDirectory, "process-profile-recovery.json");
    private string ProcessOperationPath => Path.Combine(_recoveryDirectory, "process-profile-operation");
    private string ProcessGenerationPath => Path.Combine(_recoveryDirectory, "process-profile-operation-generation.json");
    private string NvidiaOperationPath => Path.Combine(_recoveryDirectory, "nvidia-profile-operation");
    private string NvidiaGenerationPath => Path.Combine(_recoveryDirectory, "nvidia-profile-operation-generation.json");
    public ProcessProfileRecovery? ProcessProfileRecovery
    {
        get
        {
            var generation = ReadGeneration(ProcessGenerationPath);
            if (VolatileProcessRecovery.TryGetValue(_recoveryKey, out var current)
                && current.Valid() && SameGeneration(current.Generation, generation)) return current;
            try
            {
                var recovery = RooIndustries.Optimizer.OperationFiles.Read<ProcessProfileRecovery>(ProcessRecoveryPath);
                return recovery.Valid() && SameGeneration(recovery.Generation, generation) ? recovery : null;
            }
            catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or UnauthorizedAccessException) { return null; }
        }
    }
    private sealed record ReviewedCleanupInput(string AppId, string Json, int Generation);
    private sealed record PreparedCleanupInputs(
        string DirectoryPath,
        string OfficialPreviewPath,
        string CleanupManifestPath,
        string OfficialSha256,
        string CleanupSha256);
    private ReviewedCleanupInput? _officialReview;
    private ReviewedCleanupInput? _cleanupReview;
    private int _cleanupReviewGeneration;

    public void DiscardCleanupReview()
    {
        Interlocked.Increment(ref _cleanupReviewGeneration);
        _officialReview = null;
        _cleanupReview = null;
    }

    private static readonly JsonSerializerOptions JsonOptions = JsonTolerance.CreateOptions();

    public LiveDataService(BackendLocator locator, string? recoveryDirectory = null)
    {
        _locator = locator;
        _recoveryDirectory = recoveryDirectory ?? Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "settings");
        _recoveryKey = Path.GetFullPath(_recoveryDirectory);
    }

    public string? ScriptsDirectory => _locator.RepoRoot is null
        ? null
        : Path.Combine(_locator.RepoRoot, "backend", "scripts");

    public bool ScriptsAvailable => ScriptsDirectory is not null && Directory.Exists(ScriptsDirectory);

    public string? LastError { get; private set; }
    public string? RepoRoot => _locator.RepoRoot;

    public Task<ProcessInventory?> GetProcessInventoryAsync(CancellationToken ct = default)
        => RunAsync<ProcessInventory>("Get-ProcessInventory.ps1", ct);

    public Task<ProcessClassification?> GetProcessClassificationAsync(CancellationToken ct = default)
        => RunAsync<ProcessClassification>("Get-ProcessClassification.ps1", ct);

    public Task<LiveDataResult<string>> PreviewProcessProfileResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Preview-ProcessProfile.ps1", ct);

    public async Task<LiveDataResult<string>> ApplyProcessProfileResultAsync(CancellationToken ct = default)
    {
        using var operation = TryOperationLease(ProcessOperationPath, "process profile", out var leaseError);
        if (operation is null) return new(null, leaseError);
        var previousGeneration = ReadGeneration(ProcessGenerationPath);
        var generation = Guid.NewGuid().ToString("N");
        if (!TryWriteGeneration(ProcessGenerationPath, generation, "process profile", out var generationError))
            return new(null, generationError);
        var result = await RunBackendScriptResultAsync("Apply-ProcessProfile.ps1", ct, "-ConfirmApply").ConfigureAwait(false);
        var recovery = ProcessProfileRecovery.FromApply(result.Value, generation);
        if (recovery is null)
        {
            if (result.Error is null && ProcessApplyNoChange(result.Value))
            {
                try { RestoreGeneration(ProcessGenerationPath, previousGeneration); }
                catch (Exception error)
                {
                    return result with { Error = "The no-change process action completed, but its operation generation could not be restored: " + error.Message };
                }
            }
            return result;
        }
        VolatileProcessRecovery[_recoveryKey] = recovery;
        try
        {
            RooIndustries.Optimizer.OperationFiles.Write(ProcessRecoveryPath, recovery);
            return result with { RecoveryPath = recovery.Path, RecoveryGeneration = recovery.Generation };
        }
        catch (Exception error)
        {
            return result with
            {
                Error = AppendError(result.Error, "The process backup exists, but its recovery reference could not be saved: " + error.Message),
                RecoveryPath = recovery.Path,
                RecoveryGeneration = recovery.Generation,
            };
        }
    }

    public async Task<LiveDataResult<string>> RestoreProcessProfileResultAsync(ProcessProfileRecovery recovery, CancellationToken ct = default)
    {
        using var operation = TryOperationLease(ProcessOperationPath, "process profile", out var leaseError);
        if (operation is null) return new(null, leaseError);
        var current = ProcessProfileRecovery;
        if (!recovery.Valid() || current != recovery)
            return new(null, "The selected process recovery is no longer current.");
        if (!TryWriteGeneration(ProcessGenerationPath, recovery.Generation!, "process profile", out var generationError))
            return new(null, generationError);
        var result = await RunBackendScriptResultAsync(
            "Restore-ProcessProfileBackup.ps1",
            ct,
            "-BackupPath " + QuotePowerShell(recovery.Path) + " -ConfirmApply").ConfigureAwait(false);
        if (result.Error is null && recovery.RestoreCompleted(result.Value))
        {
            try
            {
                ClearProcessRecovery(recovery);
                return result;
            }
            catch (Exception error)
            {
                return result with
                {
                    Error = "The process restore completed, but its saved recovery reference could not be cleared: " + error.Message,
                    RecoveryPath = recovery.Path,
                    RecoveryGeneration = recovery.Generation,
                };
            }
        }
        return result with { RecoveryPath = recovery.Path, RecoveryGeneration = recovery.Generation };
    }

    public Task<LiveDataResult<string>> RunGameTuneSessionResultAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, CancellationToken ct = default)
    {
        var args = "-MaxDurationSeconds " + maxDurationSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                   " -PollIntervalSeconds " + pollIntervalSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (confirmApply)
        {
            args += " -ConfirmApply";
        }

        return RunBackendScriptResultAsync("Start-GameTuneSession.ps1", ct, args);
    }

    public Task<LiveDataResult<string>> RestoreGameTuneSessionResultAsync(
        string sessionId,
        string sessionPath,
        string backupManifestPath,
        CancellationToken ct = default)
        => RunBackendScriptResultAsync(
            "Stop-GameTuneSession.ps1",
            ct,
            "-SessionId " + QuotePowerShell(sessionId)
                + " -SessionPath " + QuotePowerShell(sessionPath)
                + " -BackupPath " + QuotePowerShell(backupManifestPath)
                + " -ConfirmApply");

    public Task<LiveDataResult<string>> GetGameTuneSessionStatusResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Get-GameTuneSessionStatus.ps1", ct);

    public Task<GameTuneSessionStatus?> GetGameTuneSessionStatusAsync(CancellationToken ct = default)
        => RunAsync<GameTuneSessionStatus>("Get-GameTuneSessionStatus.ps1", ct);

    public Task<LiveDataResult<string>> RunProcessGovernorSessionResultAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, int sampleIntervalMilliseconds, CancellationToken ct = default)
    {
        var args = "-MaxDurationSeconds " + maxDurationSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                   " -PollIntervalSeconds " + pollIntervalSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                   " -SampleIntervalMilliseconds " + sampleIntervalMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (confirmApply)
        {
            args += " -ConfirmApply";
        }

        return RunBackendScriptResultAsync("Start-ProcessGovernorSession.ps1", ct, args);
    }

    public Task<LiveDataResult<string>> RestoreProcessGovernorSessionResultAsync(
        string sessionId,
        string sessionPath,
        string backupManifestPath,
        CancellationToken ct = default)
        => RunBackendScriptResultAsync(
            "Stop-ProcessGovernorSession.ps1",
            ct,
            "-SessionId " + QuotePowerShell(sessionId)
                + " -SessionPath " + QuotePowerShell(sessionPath)
                + " -BackupPath " + QuotePowerShell(backupManifestPath)
                + " -ConfirmApply");

    public Task<LiveDataResult<string>> GetProcessGovernorSessionStatusResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Get-ProcessGovernorSessionStatus.ps1", ct);

    public Task<ProcessGovernorSessionStatus?> GetProcessGovernorSessionStatusAsync(CancellationToken ct = default)
        => RunAsync<ProcessGovernorSessionStatus>("Get-ProcessGovernorSessionStatus.ps1", ct);

    public Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken ct = default)
        => RunAsync<DriverHardwareSummary>("Get-DriverHardwareSummary.ps1", ct);

    public Task<LiveDataResult<string>> PreviewNvidiaProfileResultAsync(string profileId, CancellationToken ct = default)
        => RunBackendScriptResultAsync("Preview-NvidiaNipProfile.ps1", ct, "-ProfileId " + QuotePowerShell(profileId));

    public Task<LiveDataResult<string>> ProbeNvidiaProfileResultAsync(string profileId, CancellationToken ct = default)
        => RunBackendScriptResultAsync("Invoke-NvidiaNipCapabilityProbe.ps1", ct,
            "-ProfileId " + QuotePowerShell(profileId) + " -AllowReadOnlyNvpiProbe");

    public async Task<LiveDataResult<string>> ApplyNvidiaProfileResultAsync(
        string profileId,
        bool exportReviewed,
        bool userApproved,
        bool benchmarkEvidenceAttached,
        CancellationToken ct = default)
    {
        using var operation = TryOperationLease(NvidiaOperationPath, "NVIDIA profile", out var leaseError);
        if (operation is null) return new(null, leaseError);
        var realApplyApproved = exportReviewed && userApproved && benchmarkEvidenceAttached;
        var previousGeneration = ReadGeneration(NvidiaGenerationPath);
        string? generation = null;
        if (realApplyApproved)
        {
            generation = Guid.NewGuid().ToString("N");
            if (!TryWriteGeneration(NvidiaGenerationPath, generation, "NVIDIA profile", out var generationError))
                return new(null, generationError);
        }
        string? recoveryRoot = null;
        string? exportPath = null;
        string? rollbackManifestPath = null;
        if (realApplyApproved)
        {
            recoveryRoot = Path.Combine(_recoveryDirectory, "nvidia-profile-recovery", Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(recoveryRoot);
            exportPath = Path.Combine(recoveryRoot, "before.nip");
            rollbackManifestPath = Path.Combine(recoveryRoot, "rollback.json");
        }
        var args = "-Operation Apply -ProfileId " + QuotePowerShell(profileId)
            + " -ExecutorMode " + (realApplyApproved ? "Real" : "Preview")
            + " -ConfirmApply";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        if (benchmarkEvidenceAttached)
        {
            args += " -BenchmarkEvidenceAttached";
        }

        if (realApplyApproved)
        {
            args += " -AllowRealNvpiExecution"
                + " -ExportPath " + QuotePowerShell(exportPath!)
                + " -RollbackManifestPath " + QuotePowerShell(rollbackManifestPath!);
        }

        var result = await RunBackendScriptResultAsync("Invoke-NvidiaNipExecutor.ps1", ct, args).ConfigureAwait(false);
        var recovery = realApplyApproved ? ReadNvidiaRecoveryFromApply(profileId, rollbackManifestPath!, exportPath!, generation!) : null;
        if (realApplyApproved && recovery is null && NvidiaApplyNoImport(result.Value, profileId, rollbackManifestPath!, exportPath!))
        {
            try { RestoreGeneration(NvidiaGenerationPath, previousGeneration); }
            catch (Exception error)
            {
                return result with { Error = AppendError(result.Error, "The no-import NVIDIA action completed, but its operation generation could not be restored: " + error.Message) };
            }
        }
        if (recovery is not null)
        {
            VolatileNvidiaRecovery[_recoveryKey] = recovery;
            try { SaveNvidiaRecovery(recovery); }
            catch (Exception error)
            {
                return result with
                {
                    Error = AppendError(result.Error, "The NVIDIA rollback export exists, but its recovery reference could not be saved: " + error.Message),
                    RecoveryPath = recovery.RollbackManifestPath,
                    RecoveryGeneration = recovery.Generation,
                };
            }
        }
        return result with { RecoveryPath = recovery?.RollbackManifestPath, RecoveryGeneration = recovery?.Generation };
    }

    public Task<NvidiaProfileRecovery?> ReadNvidiaProfileRecoveryAsync(string profileId)
    {
        var generation = ReadGeneration(NvidiaGenerationPath);
        if (VolatileNvidiaRecovery.TryGetValue(_recoveryKey, out var volatileRecovery)
            && ValidateNvidiaRecovery(volatileRecovery, profileId)
            && SameGeneration(volatileRecovery.Generation, generation)) return Task.FromResult<NvidiaProfileRecovery?>(volatileRecovery);
        var path = NvidiaRecoveryIndexPath;
        if (!File.Exists(path)) return Task.FromResult<NvidiaProfileRecovery?>(null);
        try
        {
            var recovery = RooIndustries.Optimizer.OperationFiles.Read<NvidiaProfileRecovery>(path);
            return Task.FromResult(ValidateNvidiaRecovery(recovery, profileId)
                && SameGeneration(recovery.Generation, generation) ? recovery : null);
        }
        catch
        {
            return Task.FromResult<NvidiaProfileRecovery?>(null);
        }
    }

    public static NvidiaProfileRecovery? NvidiaRecoveryFromApplyResult(string profileId, string? json, string? rollbackManifestPath, string? generation)
    {
        if (string.IsNullOrWhiteSpace(json) || string.IsNullOrWhiteSpace(rollbackManifestPath)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (NvidiaString(root, "actionId") != "drivers.nvidiaNip.executor"
                || NvidiaString(root, "operation") != "Apply"
                || NvidiaString(root, "profileId") != profileId
                || !PathsEqual(NvidiaString(root, "rollbackManifestPath"), rollbackManifestPath)) return null;
            var exportPath = NvidiaString(root, "rollbackManifest", "exportPath");
            var recovery = string.IsNullOrWhiteSpace(exportPath) ? null : new NvidiaProfileRecovery(profileId, rollbackManifestPath, exportPath, generation);
            return ValidateNvidiaRecovery(recovery, profileId) ? recovery : null;
        }
        catch { return null; }
    }

    public async Task<LiveDataResult<string>> RestoreNvidiaProfileResultAsync(NvidiaProfileRecovery recovery, bool userApproved, CancellationToken ct = default)
    {
        using var operation = TryOperationLease(NvidiaOperationPath, "NVIDIA profile", out var leaseError);
        if (operation is null) return new(null, leaseError);
        var current = await ReadNvidiaProfileRecoveryAsync(recovery.ProfileId).ConfigureAwait(false);
        if (!ValidateNvidiaRecovery(recovery, recovery.ProfileId) || current != recovery)
            return new(null, "The selected NVIDIA recovery is no longer current.");
        if (!TryWriteGeneration(NvidiaGenerationPath, recovery.Generation!, "NVIDIA profile", out var generationError))
            return new(null, generationError);
        var args = "-Operation Restore -ProfileId " + QuotePowerShell(recovery.ProfileId)
            + " -ExecutorMode " + (userApproved ? "Real" : "Preview")
            + " -ExportPath " + QuotePowerShell(recovery.ExportPath)
            + " -RollbackManifestPath " + QuotePowerShell(recovery.RollbackManifestPath)
            + " -ConfirmApply";
        if (userApproved)
        {
            args += " -UserApproved -AllowRealNvpiExecution";
        }

        var result = await RunBackendScriptResultAsync("Invoke-NvidiaNipExecutor.ps1", ct, args).ConfigureAwait(false);
        if (result.Error is null && NvidiaRestoreCompleted(result.Value, recovery))
        {
            try
            {
                ClearNvidiaRecovery(recovery);
                return result;
            }
            catch (Exception error)
            {
                return result with
                {
                    Error = "The NVIDIA restore completed, but its saved recovery reference could not be cleared: " + error.Message,
                    RecoveryPath = recovery.RollbackManifestPath,
                    RecoveryGeneration = recovery.Generation,
                };
            }
        }
        return result with { RecoveryPath = recovery.RollbackManifestPath, RecoveryGeneration = recovery.Generation };
    }

    public Task<LiveDataResult<string>> PreviewStutterOptimizationResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Preview-StutterOptimization.ps1", ct, "-OptimizationId all");

    public Task<LiveDataResult<string>> CheckTimerResolutionResultAsync(bool userApproved, CancellationToken ct = default)
    {
        var args = "-OptimizationId timer-resolution -ConfirmApply -AllowRealSystemExecution";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        return RunBackendScriptResultAsync("Invoke-StutterOptimization.ps1", ct, args);
    }

    public Task<LiveDataResult<string>> CheckShaderCacheCleanupResultAsync(bool userApproved, CancellationToken ct = default)
    {
        var args = "-OptimizationId shader-cache-cleanup -ConfirmApply -AllowRealSystemExecution";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        return RunBackendScriptResultAsync("Invoke-StutterOptimization.ps1", ct, args);
    }

    public Task<LiveDataResult<string>> RestoreShaderCacheCleanupResultAsync(string rollbackManifestPath, CancellationToken ct = default)
        => RunBackendScriptResultAsync(
            "Restore-StutterOptimization.ps1",
            ct,
            "-RollbackManifestPath " + QuotePowerShell(rollbackManifestPath) + " -ConfirmApply -AllowDisposableFixtureApply");

    public Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken ct = default, bool includeAllAppxUsers = false)
        => RunAsync<InstalledAppInventory>("Get-InstalledAppInventory.ps1", ct, includeAllAppxUsers ? "-IncludeAllAppxUsers" : "");

    public Task<LiveDataResult<LeftoverScan>> GetLeftoverScanResultAsync(string appId, CancellationToken ct = default)
        => RunResultAsync<LeftoverScan>("Preview-LeftoverScan.ps1", ct, "-AppId " + QuotePowerShell(appId));
    public async Task<LeftoverScan?> GetLeftoverScanAsync(string appId, CancellationToken ct = default)
        => (await GetLeftoverScanResultAsync(appId, ct)).Value;

    public async Task<LiveDataResult<OfficialUninstallPreview>> GetOfficialUninstallPreviewResultAsync(string appId, CancellationToken ct = default)
    {
        var generation = _cleanupReviewGeneration;
        var text = await RunBackendScriptResultAsync("Preview-OfficialUninstall.ps1", ct, "-AppId " + QuotePowerShell(appId));
        var result = DeserializeResult<OfficialUninstallPreview>(text);
        if (result.Value is not null && text.Value is not null && generation == _cleanupReviewGeneration) _officialReview = new(appId, text.Value, generation);
        return result;
    }
    public async Task<OfficialUninstallPreview?> GetOfficialUninstallPreviewAsync(string appId, CancellationToken ct = default)
        => (await GetOfficialUninstallPreviewResultAsync(appId, ct)).Value;

    public async Task<LiveDataResult<CleanupManifest>> GetCleanupManifestResultAsync(string appId, CancellationToken ct = default)
    {
        var generation = _cleanupReviewGeneration;
        var text = await RunBackendScriptResultAsync("New-CleanupDeletionManifest.ps1", ct, "-AppId " + QuotePowerShell(appId));
        var result = DeserializeResult<CleanupManifest>(text);
        if (result.Value is not null && text.Value is not null && generation == _cleanupReviewGeneration) _cleanupReview = new(appId, text.Value, generation);
        return result;
    }
    public async Task<CleanupManifest?> GetCleanupManifestAsync(string appId, CancellationToken ct = default)
        => (await GetCleanupManifestResultAsync(appId, ct)).Value;

    public Task<LiveDataResult<UninstallCleanupExecutionPlan>> GetUninstallCleanupExecutionPlanResultAsync(string appId, CancellationToken ct = default)
        => RunResultAsync<UninstallCleanupExecutionPlan>("New-UninstallCleanupExecutionPlan.ps1", ct, "-AppId " + QuotePowerShell(appId));
    public async Task<UninstallCleanupExecutionPlan?> GetUninstallCleanupExecutionPlanAsync(string appId, CancellationToken ct = default)
        => (await GetUninstallCleanupExecutionPlanResultAsync(appId, ct)).Value;

    public async Task<LiveDataResult<string>> RequestUninstallCleanupApplyResultAsync(
        string appId,
        bool officialUninstallCommandApproved,
        bool cleanupDeletionManifestApproved,
        bool realCleanupApproved,
        CancellationToken ct = default)
    {
        PreparedCleanupInputs? inputs = null;
        string? rollbackPath = null;
        try
        {
            var prepared = await PrepareUninstallCleanupInputsAsync(appId, ct).ConfigureAwait(false);
            inputs = prepared.Value;
            if (inputs is null)
            {
                return new(null, prepared.Error ?? "The reviewed cleanup inputs are unavailable.");
            }

            var cleanupTargets = ReadCleanupTargets(inputs.CleanupManifestPath);
            var officialExecutable = ReadOfficialExecutable(inputs.OfficialPreviewPath);
            var runRoot = realCleanupApproved
                ? Path.Combine(
                    RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot,
                    "cleanup-runs",
                    Path.GetFileName(inputs.DirectoryPath))
                : Path.Combine(inputs.DirectoryPath, "preview-run");
            Directory.CreateDirectory(runRoot);

            if (realCleanupApproved)
            {
                rollbackPath = Path.Combine(runRoot, "rollback-manifest.json");
            }
            var officialHash = inputs.OfficialSha256;
            var cleanupHash = inputs.CleanupSha256;
            var args = "-ApprovedAppId " + QuotePowerShell(appId) +
                " -OfficialPreviewSha256 " + QuotePowerShell(officialHash) +
                " -CleanupManifestSha256 " + QuotePowerShell(cleanupHash) +
                " -OfficialPreviewPath " + QuotePowerShell(inputs.OfficialPreviewPath) +
                " -CleanupManifestPath " + QuotePowerShell(inputs.CleanupManifestPath) +
                " -ExecutorMode " + (realCleanupApproved ? "Real" : "Preview") +
                " -ExactTargetAllowlist " + QuotePowerShellArray(cleanupTargets) +
                " -BackupRoot " + QuotePowerShell(Path.Combine(runRoot, "backup")) +
                " -RollbackManifestPath " + QuotePowerShell(Path.Combine(runRoot, "rollback-manifest.json"));

            if (!string.IsNullOrWhiteSpace(officialExecutable))
            {
                args += " -AllowedOfficialExecutablePath " + QuotePowerShell(officialExecutable);
                args += " -OfficialRunnerWorkingDirectory " + QuotePowerShell(runRoot);
            }

            if (officialUninstallCommandApproved)
            {
                args += " -OfficialUninstallCommandApproved -ManualReviewApproved";
            }

            if (cleanupDeletionManifestApproved)
            {
                args += " -CleanupDeletionManifestApproved";
            }

            if (realCleanupApproved)
            {
                args += " -ConfirmApply -UserApproved -AllowRealSystemExecution";
            }

            var result = await RunBackendScriptResultAsync("Invoke-UninstallCleanupApplyPackage.ps1", ct, args).ConfigureAwait(false);
            return result with { RecoveryPath = rollbackPath };
        }
        catch (Exception error)
        {
            var operationError = "Invoke-UninstallCleanupApplyPackage.ps1: " + error.GetType().Name + ": " + error.Message;
            LastError = operationError;
            return new(null, operationError, rollbackPath);
        }
        finally
        {
            if (inputs is not null) TryDeleteDirectory(inputs.DirectoryPath);
        }
    }
    public async Task<string?> RequestUninstallCleanupApplyTextAsync(
        string appId,
        bool officialUninstallCommandApproved,
        bool cleanupDeletionManifestApproved,
        bool realCleanupApproved,
        CancellationToken ct = default)
        => (await RequestUninstallCleanupApplyResultAsync(appId, officialUninstallCommandApproved, cleanupDeletionManifestApproved, realCleanupApproved, ct)).Value;

    public Task<LiveDataResult<string>> RestoreUninstallCleanupResultAsync(string rollbackManifestPath, CancellationToken ct = default)
        => RunBackendScriptResultAsync(
            "Restore-UninstallCleanupExecution.ps1",
            ct,
            "-RollbackManifestPath " + QuotePowerShell(rollbackManifestPath) + " -ConfirmApply -AllowDisposableFixtureApply -AllowRealSystemExecution -UserApproved");
    public async Task<string?> RestoreUninstallCleanupTextAsync(string rollbackManifestPath, CancellationToken ct = default)
        => (await RestoreUninstallCleanupResultAsync(rollbackManifestPath, ct)).Value;

    public async Task<LiveDataResult<string>> RunBackendScriptResultAsync(string scriptFile, CancellationToken ct = default, string extraArgs = "")
    {
        var dir = ScriptsDirectory;
        if (dir is null)
        {
            var error = "Repo root not resolved (RepoRoot=" + (RepoRoot ?? "null") + ")";
            LastError = error;
            return new(null, error);
        }

        var scriptPath = Path.Combine(dir, scriptFile);
        if (!File.Exists(scriptPath))
        {
            var error = "Script not found: " + scriptPath;
            LastError = error;
            return new(null, error);
        }

        try
        {
            var result = await RunScriptResultAsync(scriptPath, extraArgs, ct).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(result.Value))
            {
                var error = result.Error ?? "Empty output from " + scriptFile;
                LastError = error;
                return new(null, error);
            }
            LastError = result.Error;
            return result;
        }
        catch (Exception ex)
        {
            var error = scriptFile + ": " + ex.GetType().Name + ": " + ex.Message;
            LastError = error;
            return new(null, error);
        }
    }
    public async Task<string?> RunBackendScriptTextAsync(string scriptFile, CancellationToken ct = default, string extraArgs = "")
    {
        var result = await RunBackendScriptResultAsync(scriptFile, ct, extraArgs);
        return result.Error is null ? result.Value : null;
    }

    public Task<ProcessProfileEnvelope?> GetProcessProfilePreviewAsync(CancellationToken ct = default)
        => RunAsync<ProcessProfileEnvelope>("Preview-ProcessProfile.ps1", ct);

    public Task<AppClassificationResult?> GetAppClassificationAsync(CancellationToken ct = default)
        => RunAsync<AppClassificationResult>("Get-AppClassification.ps1", ct);

    public Task<NvidiaNipPreview?> GetNvidiaNipPreviewAsync(CancellationToken ct = default)
        => RunAsync<NvidiaNipPreview>("Preview-NvidiaNipProfile.ps1", ct);

    public Task<StutterOptimizationPreview?> GetStutterOptimizationPreviewAsync(CancellationToken ct = default)
        => RunAsync<StutterOptimizationPreview>("Preview-StutterOptimization.ps1", ct);

    private async Task<LiveDataResult<T>> RunResultAsync<T>(string scriptFile, CancellationToken ct, string extraArgs = "") where T : class
    {
        var text = await RunBackendScriptResultAsync(scriptFile, ct, extraArgs).ConfigureAwait(false);
        if (text.Value is null || text.Error is not null) return new(null, text.Error);
        try
        {
            var value = JsonSerializer.Deserialize<T>(text.Value, JsonOptions);
            if (value is not null) return new(value, null);
            var error = "No data returned from " + scriptFile;
            LastError = error;
            return new(null, error);
        }
        catch (Exception ex)
        {
            var error = scriptFile + ": " + ex.GetType().Name + ": " + ex.Message;
            LastError = error;
            return new(null, error);
        }
    }
    private async Task<T?> RunAsync<T>(string scriptFile, CancellationToken ct, string extraArgs = "") where T : class
        => (await RunResultAsync<T>(scriptFile, ct, extraArgs)).Value;

    private LiveDataResult<T> DeserializeResult<T>(LiveDataResult<string> text) where T : class
    {
        if (text.Value is null || text.Error is not null) return new(null, text.Error);
        try
        {
            var value = JsonSerializer.Deserialize<T>(text.Value, JsonOptions);
            if (value is not null) return new(value, null);
            const string error = "The backend returned no operation data.";
            LastError = error;
            return new(null, error);
        }
        catch (Exception error)
        {
            var message = error.GetType().Name + ": " + error.Message;
            LastError = message;
            return new(null, message);
        }
    }

    private string NvidiaRecoveryIndexPath => Path.Combine(_recoveryDirectory, "nvidia-profile-recovery.json");

    private static FileStream? TryOperationLease(string path, string kind, out string? operationError)
    {
        try
        {
            var lease = RooIndustries.Optimizer.OperationFiles.Lock(path);
            operationError = null;
            return lease;
        }
        catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33)
        {
            operationError = "Another " + kind + " action is already in progress.";
            return null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            operationError = "The " + kind + " action lock could not be opened: " + error.Message;
            return null;
        }
    }

    private static string AppendError(string? current, string error)
        => string.IsNullOrWhiteSpace(current) ? error : current + Environment.NewLine + error;

    private static string? ReadGeneration(string path)
    {
        try { return RooIndustries.Optimizer.OperationFiles.Read<RecoveryOperationGeneration>(path).Id; }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or UnauthorizedAccessException) { return null; }
    }

    private static bool SameGeneration(string? recoveryGeneration, string? currentGeneration)
        => !string.IsNullOrWhiteSpace(recoveryGeneration)
            && !string.IsNullOrWhiteSpace(currentGeneration)
            && string.Equals(recoveryGeneration, currentGeneration, StringComparison.Ordinal);

    private static bool TryWriteGeneration(string path, string generation, string kind, out string? operationError)
    {
        try
        {
            RooIndustries.Optimizer.OperationFiles.Write(path, new RecoveryOperationGeneration(generation));
            operationError = null;
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            operationError = "The " + kind + " operation generation could not be recorded before dispatch: " + error.Message;
            return false;
        }
    }

    private static void RestoreGeneration(string path, string? generation)
    {
        if (generation is null)
        {
            if (File.Exists(path)) File.Delete(path);
            return;
        }
        RooIndustries.Optimizer.OperationFiles.Write(path, new RecoveryOperationGeneration(generation));
    }

    private static bool ProcessApplyNoChange(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            return NvidiaString(root, "actionId") == "performance.applyProfile"
                && NvidiaBool(root, "dryRun") == false
                && NvidiaString(root, "status") == "success"
                && NvidiaString(root, "result", "status") == "success"
                && root.TryGetProperty("result", out var result)
                && result.TryGetProperty("changedItems", out var changed)
                && changed.ValueKind == JsonValueKind.Array
                && changed.GetArrayLength() == 0
                && root.TryGetProperty("errors", out var errors)
                && errors.ValueKind == JsonValueKind.Array
                && !errors.EnumerateArray().Any(error => NvidiaBool(error, "blocking") == true);
        }
        catch { return false; }
    }

    private static bool NvidiaApplyNoImport(string? json, string profileId, string rollbackManifestPath, string exportPath)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (NvidiaString(root, "actionId") != "drivers.nvidiaNip.executor"
                || NvidiaString(root, "operation") != "Apply"
                || NvidiaString(root, "profileId") != profileId
                || NvidiaString(root, "status") is not ("blocked" or "failed")
                || !TryNvidiaInt(root, out var reportedBlocking, "summary", "blockingGateCount")
                || reportedBlocking != NvidiaBlockingGates(root)
                || NvidiaBool(root, "summary", "importAttempted") != false
                || NvidiaBool(root, "summary", "importCompleted") != false
                || NvidiaBool(root, "summary", "exportAttempted") is not { } exportAttempted
                || !root.TryGetProperty("errors", out var errors) || errors.ValueKind != JsonValueKind.Array) return false;
            if (!File.Exists(rollbackManifestPath)) return !exportAttempted;
            using var manifestDocument = JsonDocument.Parse(File.ReadAllText(rollbackManifestPath));
            var manifest = manifestDocument.RootElement;
            return NvidiaString(manifest, "actionId") == "drivers.nvidiaNip.rollbackManifest"
                && NvidiaString(manifest, "restoreActionId") == "drivers.nvidiaNip.restoreProfile"
                && NvidiaString(manifest, "profileId") == profileId
                && PathsEqual(NvidiaString(manifest, "exportPath"), exportPath)
                && NvidiaBool(manifest, "importAttempted") == false
                && NvidiaBool(manifest, "importCompleted") == false;
        }
        catch { return false; }
    }

    private void ClearProcessRecovery(ProcessProfileRecovery recovery)
    {
        if (ProcessProfileRecovery == recovery && File.Exists(ProcessRecoveryPath)) File.Delete(ProcessRecoveryPath);
        if (File.Exists(ProcessGenerationPath)) File.Delete(ProcessGenerationPath);
        if (VolatileProcessRecovery.TryGetValue(_recoveryKey, out var current) && current == recovery)
            VolatileProcessRecovery.TryRemove(_recoveryKey, out _);
    }

    private static NvidiaProfileRecovery? ReadNvidiaRecoveryFromApply(string profileId, string rollbackManifestPath, string exportPath, string generation)
    {
        var recovery = new NvidiaProfileRecovery(profileId, rollbackManifestPath, exportPath, generation);
        return ValidateNvidiaRecovery(recovery, profileId) ? recovery : null;
    }

    private static bool ValidateNvidiaRecovery(NvidiaProfileRecovery? recovery, string profileId)
    {
        if (recovery is null || recovery.ProfileId != profileId || string.IsNullOrWhiteSpace(recovery.Generation)
            || !File.Exists(recovery.RollbackManifestPath) || !File.Exists(recovery.ExportPath)) return false;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(recovery.RollbackManifestPath));
            var manifest = doc.RootElement;
            return NvidiaString(manifest, "actionId") == "drivers.nvidiaNip.rollbackManifest"
                && NvidiaString(manifest, "restoreActionId") == "drivers.nvidiaNip.restoreProfile"
                && NvidiaString(manifest, "profileId") == profileId
                && NvidiaBool(manifest, "rollbackSupported") == true
                && NvidiaBool(manifest, "exportCompleted") == true
                && NvidiaBool(manifest, "importAttempted") == true
                && PathsEqual(NvidiaString(manifest, "exportPath"), recovery.ExportPath);
        }
        catch
        {
            return false;
        }
    }

    private static bool NvidiaRestoreCompleted(string? json, NvidiaProfileRecovery recovery)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!TryNvidiaInt(root, out var reportedBlocking, "summary", "blockingGateCount")) return false;
            var actualBlocking = NvidiaBlockingGates(root);
            var importAttempted = NvidiaBool(root, "summary", "importAttempted");
            var importCompleted = NvidiaBool(root, "summary", "importCompleted");
            return NvidiaString(root, "actionId") == "drivers.nvidiaNip.executor"
                && NvidiaString(root, "operation") == "Restore"
                && NvidiaString(root, "profileId") == recovery.ProfileId
                && NvidiaBool(root, "dryRun") == false
                && NvidiaString(root, "status") == "success"
                && reportedBlocking == 0
                && actualBlocking == 0
                && NvidiaErrorCount(root) == 0
                && importAttempted == true
                && importCompleted == true
                && NvidiaBool(root, "summary", "exportAttempted") == false
                && PathsEqual(NvidiaString(root, "rollbackManifestPath"), recovery.RollbackManifestPath);
        }
        catch
        {
            return false;
        }
    }

    private void SaveNvidiaRecovery(NvidiaProfileRecovery recovery)
    {
        var path = NvidiaRecoveryIndexPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        RooIndustries.Optimizer.OperationFiles.Write(path, recovery);
    }

    private void ClearNvidiaRecovery(NvidiaProfileRecovery recovery)
    {
        var path = NvidiaRecoveryIndexPath;
        if (File.Exists(path)) File.Delete(path);
        if (File.Exists(NvidiaGenerationPath)) File.Delete(NvidiaGenerationPath);
        if (VolatileNvidiaRecovery.TryGetValue(_recoveryKey, out var current) && current == recovery)
            VolatileNvidiaRecovery.TryRemove(_recoveryKey, out _);
    }

    private static string? NvidiaString(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current)) return null;
        return current.ValueKind == JsonValueKind.String ? current.GetString() : null;
    }

    private static bool? NvidiaBool(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current)) return null;
        return current.ValueKind is JsonValueKind.True or JsonValueKind.False ? current.GetBoolean() : null;
    }

    private static bool TryNvidiaInt(JsonElement root, out int value, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                value = 0;
                return false;
            }
        }
        value = 0;
        return current.ValueKind == JsonValueKind.Number && current.TryGetInt32(out value);
    }

    private static int NvidiaBlockingGates(JsonElement root)
        => root.TryGetProperty("gates", out var gates) && gates.ValueKind == JsonValueKind.Array
            ? gates.EnumerateArray().Count(gate => NvidiaBool(gate, "blocking") == true)
            : -1;

    private static int NvidiaErrorCount(JsonElement root)
        => root.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array
            ? errors.GetArrayLength()
            : -1;

    private static bool PathsEqual(string? first, string second)
    {
        if (string.IsNullOrWhiteSpace(first)) return false;
        try { return string.Equals(Path.GetFullPath(first), Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    private static string QuotePowerShell(string value)
        => "'" + value.Replace("'", "''") + "'";

    private static string QuotePowerShellArray(string[] values)
    {
        if (values.Length == 0)
        {
            return "@()";
        }

        return "@(" + string.Join(",", values.Select(QuotePowerShell)) + ")";
    }

    private static string[] ReadCleanupTargets(string cleanupManifestPath)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(cleanupManifestPath));
            if (!doc.RootElement.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array)
            {
                return Array.Empty<string>();
            }

            return items.EnumerateArray()
                .Where(item =>
                    (!item.TryGetProperty("protected", out var p) || p.ValueKind != JsonValueKind.True) &&
                    item.TryGetProperty("type", out var type) &&
                    type.ValueKind == JsonValueKind.String &&
                    (string.Equals(type.GetString(), "file", StringComparison.OrdinalIgnoreCase) ||
                     string.Equals(type.GetString(), "folder", StringComparison.OrdinalIgnoreCase)) &&
                    item.TryGetProperty("target", out var target) &&
                    target.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(target.GetString()))
                .Select(item => item.GetProperty("target").GetString()!)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private static string? ReadOfficialExecutable(string officialPreviewPath)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(officialPreviewPath));
            if (!doc.RootElement.TryGetProperty("commands", out var commands) || commands.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            foreach (var command in commands.EnumerateArray())
            {
                if (command.TryGetProperty("blocked", out var blocked) && blocked.ValueKind == JsonValueKind.True)
                {
                    continue;
                }

                if (command.TryGetProperty("executable", out var executable)
                    && executable.ValueKind == JsonValueKind.String
                    && !string.IsNullOrWhiteSpace(executable.GetString()))
                {
                    return executable.GetString();
                }
            }
        }
        catch
        {
        }

        return null;
    }

    private async Task<LiveDataResult<PreparedCleanupInputs>> PrepareUninstallCleanupInputsAsync(string appId, CancellationToken ct)
    {
        var official = _officialReview;
        var cleanup = _cleanupReview;
        var generation = _cleanupReviewGeneration;
        if (official?.AppId != appId || cleanup?.AppId != appId || official.Generation != generation || cleanup.Generation != generation)
        {
            var error = "Review this app's removal route and cleanup list before applying.";
            LastError = error;
            return new(null, error);
        }
        var dir = Path.Combine(Path.GetTempPath(), "RooIndustriesOptimizationSuite", "cleanup-inputs", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var officialPath = Path.Combine(dir, "official-preview.json");
        var manifestPath = Path.Combine(dir, "cleanup-manifest.json");
        try
        {
            await File.WriteAllTextAsync(officialPath, official.Json, new UTF8Encoding(false), ct).ConfigureAwait(false);
            await File.WriteAllTextAsync(manifestPath, cleanup.Json, new UTF8Encoding(false), ct).ConfigureAwait(false);
        }
        catch
        {
            TryDeleteDirectory(dir);
            throw;
        }

        if (generation != _cleanupReviewGeneration)
        {
            TryDeleteDirectory(dir);
            var error = "The selected app changed; review its inputs again.";
            LastError = error;
            return new(null, error);
        }
        var officialHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(official.Json)));
        var cleanupHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(cleanup.Json)));
        return new(new(dir, officialPath, manifestPath, officialHash, cleanupHash), null);
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
        }
    }

    private async Task<LiveDataResult<string>> RunScriptResultAsync(string scriptPath, string extraArgs, CancellationToken ct)
    {
        var tail = string.IsNullOrWhiteSpace(extraArgs) ? string.Empty : " " + extraArgs;
        var arguments =
            $"-NoProfile -ExecutionPolicy Bypass -Command \"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '{scriptPath}'{tail}\"";

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = _locator.RepoRoot ?? Environment.CurrentDirectory,
        };

        using var process = new Process { StartInfo = psi };
        if (!process.Start())
        {
            return new(null, "Could not start " + Path.GetFileName(scriptPath));
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));

        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            return new(null, "Timed out running " + Path.GetFileName(scriptPath));
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            var detail = string.IsNullOrWhiteSpace(stderr) ? "" : ": " + stderr.Trim();
            return new(stdout, Path.GetFileName(scriptPath) + " exited with code " + process.ExitCode + detail);
        }
        if (string.IsNullOrWhiteSpace(stdout) && !string.IsNullOrWhiteSpace(stderr))
        {
            return new(null, stderr.Trim());
        }

        return new(stdout, null);
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
        }
    }
}
