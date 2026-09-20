using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record ProcessProfileRecovery(string Path, string Id);
public sealed record LiveDataResult<T>(T? Value, string? Error, string? RecoveryPath = null);

public sealed class LiveDataService
{
    private readonly BackendLocator _locator;
    private readonly string _recoveryDirectory;
    private string ProcessRecoveryPath => Path.Combine(_recoveryDirectory, "process-profile-recovery.json");
    public ProcessProfileRecovery? ProcessProfileRecovery
    {
        get
        {
            try { return RooIndustries.Optimizer.OperationFiles.Read<ProcessProfileRecovery>(ProcessRecoveryPath); }
            catch (Exception error) when (error is IOException or JsonException or InvalidOperationException) { return null; }
        }
        set
        {
            if (value is null) throw new ArgumentNullException(nameof(value));
            using var lease = RooIndustries.Optimizer.OperationFiles.Lock(ProcessRecoveryPath);
            RooIndustries.Optimizer.OperationFiles.Write(ProcessRecoveryPath, value);
        }
    }
    public void ClearProcessProfileRecovery(string path, string id)
    {
        using var lease = RooIndustries.Optimizer.OperationFiles.Lock(ProcessRecoveryPath);
        if (ProcessProfileRecovery == new ProcessProfileRecovery(path, id)) File.Delete(ProcessRecoveryPath);
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
    public async Task<string?> PreviewProcessProfileTextAsync(CancellationToken ct = default)
        => (await PreviewProcessProfileResultAsync(ct)).Value;

    public Task<LiveDataResult<string>> ApplyProcessProfileResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Apply-ProcessProfile.ps1", ct, "-ConfirmApply");
    public async Task<string?> ApplyProcessProfileTextAsync(CancellationToken ct = default)
        => (await ApplyProcessProfileResultAsync(ct)).Value;

    public Task<LiveDataResult<string>> RestoreProcessProfileResultAsync(string backupPath, CancellationToken ct = default)
        => RunBackendScriptResultAsync("Restore-ProcessProfileBackup.ps1", ct, "-BackupPath " + QuotePowerShell(backupPath) + " -ConfirmApply");
    public async Task<string?> RestoreProcessProfileTextAsync(string backupPath, CancellationToken ct = default)
        => (await RestoreProcessProfileResultAsync(backupPath, ct)).Value;

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
    public async Task<string?> RunGameTuneSessionTextAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, CancellationToken ct = default)
        => (await RunGameTuneSessionResultAsync(confirmApply, maxDurationSeconds, pollIntervalSeconds, ct)).Value;

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
    public async Task<string?> GetGameTuneSessionStatusTextAsync(CancellationToken ct = default)
        => (await GetGameTuneSessionStatusResultAsync(ct)).Value;

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
    public async Task<string?> RunProcessGovernorSessionTextAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, int sampleIntervalMilliseconds, CancellationToken ct = default)
        => (await RunProcessGovernorSessionResultAsync(confirmApply, maxDurationSeconds, pollIntervalSeconds, sampleIntervalMilliseconds, ct)).Value;

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
    public async Task<string?> GetProcessGovernorSessionStatusTextAsync(CancellationToken ct = default)
        => (await GetProcessGovernorSessionStatusResultAsync(ct)).Value;

    public Task<ProcessGovernorSessionStatus?> GetProcessGovernorSessionStatusAsync(CancellationToken ct = default)
        => RunAsync<ProcessGovernorSessionStatus>("Get-ProcessGovernorSessionStatus.ps1", ct);

    public Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken ct = default)
        => RunAsync<DriverHardwareSummary>("Get-DriverHardwareSummary.ps1", ct);

    public Task<LiveDataResult<string>> PreviewNvidiaProfileResultAsync(string profileId, CancellationToken ct = default)
        => RunBackendScriptResultAsync("Preview-NvidiaNipProfile.ps1", ct, "-ProfileId " + QuotePowerShell(profileId));
    public async Task<string?> PreviewNvidiaProfileTextAsync(string profileId, CancellationToken ct = default)
        => (await PreviewNvidiaProfileResultAsync(profileId, ct)).Value;

    public Task<LiveDataResult<string>> ProbeNvidiaProfileResultAsync(string profileId, CancellationToken ct = default)
        => RunBackendScriptResultAsync("Invoke-NvidiaNipCapabilityProbe.ps1", ct,
            "-ProfileId " + QuotePowerShell(profileId) + " -AllowReadOnlyNvpiProbe");
    public async Task<string?> ProbeNvidiaProfileTextAsync(string profileId, CancellationToken ct = default)
        => (await ProbeNvidiaProfileResultAsync(profileId, ct)).Value;

    public Task<LiveDataResult<string>> ApplyNvidiaProfileResultAsync(
        string profileId,
        bool exportReviewed,
        bool userApproved,
        bool benchmarkEvidenceAttached,
        CancellationToken ct = default)
    {
        var realApplyApproved = exportReviewed && userApproved && benchmarkEvidenceAttached;
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
            args += " -AllowRealNvpiExecution";
        }

        return RunBackendScriptResultAsync("Invoke-NvidiaNipExecutor.ps1", ct, args);
    }
    public async Task<string?> ApplyNvidiaProfileTextAsync(
        string profileId,
        bool exportReviewed,
        bool userApproved,
        bool benchmarkEvidenceAttached,
        CancellationToken ct = default)
        => (await ApplyNvidiaProfileResultAsync(profileId, exportReviewed, userApproved, benchmarkEvidenceAttached, ct)).Value;

    public Task<LiveDataResult<string>> RestoreNvidiaProfileResultAsync(string profileId, bool userApproved, CancellationToken ct = default)
    {
        var args = "-Operation Restore -ProfileId " + QuotePowerShell(profileId)
            + " -ExecutorMode " + (userApproved ? "Real" : "Preview")
            + " -ConfirmApply";
        if (userApproved)
        {
            args += " -UserApproved -AllowRealNvpiExecution";
        }

        return RunBackendScriptResultAsync("Invoke-NvidiaNipExecutor.ps1", ct, args);
    }
    public async Task<string?> RestoreNvidiaProfileTextAsync(string profileId, bool userApproved, CancellationToken ct = default)
        => (await RestoreNvidiaProfileResultAsync(profileId, userApproved, ct)).Value;

    public Task<LiveDataResult<string>> PreviewStutterOptimizationResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Preview-StutterOptimization.ps1", ct, "-OptimizationId all");
    public async Task<string?> PreviewStutterOptimizationTextAsync(CancellationToken ct = default)
        => (await PreviewStutterOptimizationResultAsync(ct)).Value;

    public Task<LiveDataResult<string>> CheckTimerResolutionResultAsync(bool userApproved, CancellationToken ct = default)
    {
        var args = "-OptimizationId timer-resolution -ConfirmApply -AllowRealSystemExecution";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        return RunBackendScriptResultAsync("Invoke-StutterOptimization.ps1", ct, args);
    }
    public async Task<string?> CheckTimerResolutionTextAsync(bool userApproved, CancellationToken ct = default)
        => (await CheckTimerResolutionResultAsync(userApproved, ct)).Value;

    public Task<LiveDataResult<string>> CheckShaderCacheCleanupResultAsync(bool userApproved, CancellationToken ct = default)
    {
        var args = "-OptimizationId shader-cache-cleanup -ConfirmApply -AllowRealSystemExecution";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        return RunBackendScriptResultAsync("Invoke-StutterOptimization.ps1", ct, args);
    }
    public async Task<string?> CheckShaderCacheCleanupTextAsync(bool userApproved, CancellationToken ct = default)
        => (await CheckShaderCacheCleanupResultAsync(userApproved, ct)).Value;

    public Task<LiveDataResult<string>> RestoreShaderCacheCleanupResultAsync(string rollbackManifestPath, CancellationToken ct = default)
        => RunBackendScriptResultAsync(
            "Restore-StutterOptimization.ps1",
            ct,
            "-RollbackManifestPath " + QuotePowerShell(rollbackManifestPath) + " -ConfirmApply -AllowDisposableFixtureApply");
    public async Task<string?> RestoreShaderCacheCleanupTextAsync(string rollbackManifestPath, CancellationToken ct = default)
        => (await RestoreShaderCacheCleanupResultAsync(rollbackManifestPath, ct)).Value;

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
