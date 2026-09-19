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

public sealed class LiveDataService
{
    private readonly BackendLocator _locator;
    private sealed record ReviewedCleanupInput(string AppId, string Json, int Generation);
    private ReviewedCleanupInput? _officialReview;
    private ReviewedCleanupInput? _cleanupReview;
    private int _cleanupReviewGeneration;
    public string? LastCleanupRollbackPath { get; private set; }

    public void DiscardCleanupReview()
    {
        Interlocked.Increment(ref _cleanupReviewGeneration);
        _officialReview = null;
        _cleanupReview = null;
        LastCleanupRollbackPath = null;
    }

    private static readonly JsonSerializerOptions JsonOptions = JsonTolerance.CreateOptions();

    public LiveDataService(BackendLocator locator)
    {
        _locator = locator;
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

    public Task<string?> PreviewProcessProfileTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Preview-ProcessProfile.ps1", ct);

    public Task<string?> ApplyProcessProfileTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Apply-ProcessProfile.ps1", ct, "-ConfirmApply");

    public Task<string?> RestoreProcessProfileTextAsync(string backupPath, CancellationToken ct = default)
        => RunBackendScriptTextAsync("Restore-ProcessProfileBackup.ps1", ct, "-BackupPath " + QuotePowerShell(backupPath) + " -ConfirmApply");

    public Task<string?> RunGameTuneSessionTextAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, CancellationToken ct = default)
    {
        var args = "-MaxDurationSeconds " + maxDurationSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                   " -PollIntervalSeconds " + pollIntervalSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (confirmApply)
        {
            args += " -ConfirmApply";
        }

        return RunBackendScriptTextAsync("Start-GameTuneSession.ps1", ct, args);
    }

    public Task<string?> RestoreGameTuneSessionTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Stop-GameTuneSession.ps1", ct, "-ConfirmApply");

    public Task<string?> GetGameTuneSessionStatusTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Get-GameTuneSessionStatus.ps1", ct);

    public Task<GameTuneSessionStatus?> GetGameTuneSessionStatusAsync(CancellationToken ct = default)
        => RunAsync<GameTuneSessionStatus>("Get-GameTuneSessionStatus.ps1", ct);

    public Task<string?> RunProcessGovernorSessionTextAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, int sampleIntervalMilliseconds, CancellationToken ct = default)
    {
        var args = "-MaxDurationSeconds " + maxDurationSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                   " -PollIntervalSeconds " + pollIntervalSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture) +
                   " -SampleIntervalMilliseconds " + sampleIntervalMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (confirmApply)
        {
            args += " -ConfirmApply";
        }

        return RunBackendScriptTextAsync("Start-ProcessGovernorSession.ps1", ct, args);
    }

    public Task<string?> RestoreProcessGovernorSessionTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Stop-ProcessGovernorSession.ps1", ct, "-ConfirmApply");

    public Task<string?> GetProcessGovernorSessionStatusTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Get-ProcessGovernorSessionStatus.ps1", ct);

    public Task<ProcessGovernorSessionStatus?> GetProcessGovernorSessionStatusAsync(CancellationToken ct = default)
        => RunAsync<ProcessGovernorSessionStatus>("Get-ProcessGovernorSessionStatus.ps1", ct);

    public Task<GameTuneRestorePreview?> GetGameTuneRestorePreviewAsync(CancellationToken ct = default)
        => RunAsync<GameTuneRestorePreview>("Stop-GameTuneSession.ps1", ct);

    public Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken ct = default)
        => RunAsync<DriverHardwareSummary>("Get-DriverHardwareSummary.ps1", ct);

    public Task<string?> PreviewNvidiaProfileTextAsync(string profileId, CancellationToken ct = default)
        => RunBackendScriptTextAsync("Preview-NvidiaNipProfile.ps1", ct, "-ProfileId " + QuotePowerShell(profileId));

    public Task<string?> ProbeNvidiaProfileTextAsync(string profileId, CancellationToken ct = default)
        => RunBackendScriptTextAsync("Invoke-NvidiaNipCapabilityProbe.ps1", ct,
            "-ProfileId " + QuotePowerShell(profileId) + " -AllowReadOnlyNvpiProbe");

    public Task<string?> ApplyNvidiaProfileTextAsync(
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

        return RunBackendScriptTextAsync("Invoke-NvidiaNipExecutor.ps1", ct, args);
    }

    public Task<string?> RestoreNvidiaProfileTextAsync(string profileId, bool userApproved, CancellationToken ct = default)
    {
        var args = "-Operation Restore -ProfileId " + QuotePowerShell(profileId)
            + " -ExecutorMode " + (userApproved ? "Real" : "Preview")
            + " -ConfirmApply";
        if (userApproved)
        {
            args += " -UserApproved -AllowRealNvpiExecution";
        }

        return RunBackendScriptTextAsync("Invoke-NvidiaNipExecutor.ps1", ct, args);
    }

    public Task<string?> PreviewStutterOptimizationTextAsync(CancellationToken ct = default)
        => RunBackendScriptTextAsync("Preview-StutterOptimization.ps1", ct, "-OptimizationId all");

    public Task<string?> CheckTimerResolutionTextAsync(bool userApproved, CancellationToken ct = default)
    {
        var args = "-OptimizationId timer-resolution -ConfirmApply -AllowRealSystemExecution";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        return RunBackendScriptTextAsync("Invoke-StutterOptimization.ps1", ct, args);
    }

    public Task<string?> CheckShaderCacheCleanupTextAsync(bool userApproved, CancellationToken ct = default)
    {
        var args = "-OptimizationId shader-cache-cleanup -ConfirmApply -AllowRealSystemExecution";
        if (userApproved)
        {
            args += " -UserApproved";
        }

        return RunBackendScriptTextAsync("Invoke-StutterOptimization.ps1", ct, args);
    }

    public Task<string?> RestoreShaderCacheCleanupTextAsync(string rollbackManifestPath, CancellationToken ct = default)
        => RunBackendScriptTextAsync(
            "Restore-StutterOptimization.ps1",
            ct,
            "-RollbackManifestPath " + QuotePowerShell(rollbackManifestPath) + " -ConfirmApply -AllowDisposableFixtureApply");

    public Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken ct = default)
        => RunAsync<InstalledAppInventory>("Get-InstalledAppInventory.ps1", ct);

    public Task<LeftoverScan?> GetLeftoverScanAsync(string appId, CancellationToken ct = default)
        => RunAsync<LeftoverScan>("Preview-LeftoverScan.ps1", ct, "-AppId " + QuotePowerShell(appId));

    public async Task<OfficialUninstallPreview?> GetOfficialUninstallPreviewAsync(string appId, CancellationToken ct = default)
    {
        var generation = _cleanupReviewGeneration;
        var json = await RunBackendScriptTextAsync("Preview-OfficialUninstall.ps1", ct, "-AppId " + QuotePowerShell(appId));
        if (string.IsNullOrWhiteSpace(json)) return null;
        var result = JsonSerializer.Deserialize<OfficialUninstallPreview>(json, JsonOptions);
        if (generation == _cleanupReviewGeneration) _officialReview = new(appId, json, generation);
        return result;
    }

    public async Task<CleanupManifest?> GetCleanupManifestAsync(string appId, CancellationToken ct = default)
    {
        var generation = _cleanupReviewGeneration;
        var json = await RunBackendScriptTextAsync("New-CleanupDeletionManifest.ps1", ct, "-AppId " + QuotePowerShell(appId));
        if (string.IsNullOrWhiteSpace(json)) return null;
        var result = JsonSerializer.Deserialize<CleanupManifest>(json, JsonOptions);
        if (generation == _cleanupReviewGeneration) _cleanupReview = new(appId, json, generation);
        return result;
    }

    public Task<UninstallCleanupExecutionPlan?> GetUninstallCleanupExecutionPlanAsync(string appId, CancellationToken ct = default)
        => RunAsync<UninstallCleanupExecutionPlan>("New-UninstallCleanupExecutionPlan.ps1", ct, "-AppId " + QuotePowerShell(appId));

    public async Task<string?> RequestUninstallCleanupApplyTextAsync(
        string appId,
        bool officialUninstallCommandApproved,
        bool cleanupDeletionManifestApproved,
        bool realCleanupApproved,
        CancellationToken ct = default)
    {
        var inputs = await PrepareUninstallCleanupInputsAsync(appId, ct).ConfigureAwait(false);
        if (inputs is null)
        {
            return null;
        }

        try
        {
            var cleanupTargets = ReadCleanupTargets(inputs.Value.CleanupManifestPath);
            var officialExecutable = ReadOfficialExecutable(inputs.Value.OfficialPreviewPath);
            var runRoot = realCleanupApproved
                ? Path.Combine(
                    RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot,
                    "cleanup-runs",
                    Path.GetFileName(inputs.Value.DirectoryPath))
                : Path.Combine(inputs.Value.DirectoryPath, "preview-run");
            Directory.CreateDirectory(runRoot);

            if (realCleanupApproved) LastCleanupRollbackPath = Path.Combine(runRoot, "rollback-manifest.json");
            var officialHash = inputs.Value.OfficialSha256;
            var cleanupHash = inputs.Value.CleanupSha256;
            var args = "-ApprovedAppId " + QuotePowerShell(appId) +
                " -OfficialPreviewSha256 " + QuotePowerShell(officialHash) +
                " -CleanupManifestSha256 " + QuotePowerShell(cleanupHash) +
                " -OfficialPreviewPath " + QuotePowerShell(inputs.Value.OfficialPreviewPath) +
                " -CleanupManifestPath " + QuotePowerShell(inputs.Value.CleanupManifestPath) +
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

            return await RunBackendScriptTextAsync("Invoke-UninstallCleanupApplyPackage.ps1", ct, args).ConfigureAwait(false);
        }
        finally
        {
            TryDeleteDirectory(inputs.Value.DirectoryPath);
        }
    }

    public Task<string?> RestoreUninstallCleanupTextAsync(string rollbackManifestPath, CancellationToken ct = default)
        => RunBackendScriptTextAsync(
            "Restore-UninstallCleanupExecution.ps1",
            ct,
            "-RollbackManifestPath " + QuotePowerShell(rollbackManifestPath) + " -ConfirmApply -AllowDisposableFixtureApply -AllowRealSystemExecution -UserApproved");

    public string? FindLatestProcessProfileBackup()
    {
        var root = _locator.RepoRoot;
        if (root is null)
        {
            return null;
        }

        var backupRoot = Path.Combine(root, "backend", "state", "process-profile-backups");
        if (!Directory.Exists(backupRoot))
        {
            return null;
        }

        return Directory.EnumerateFiles(backupRoot, "backup.json", SearchOption.AllDirectories)
            .Select(path => new FileInfo(path))
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .Select(file => file.FullName)
            .FirstOrDefault();
    }

    public async Task<string?> RunBackendScriptTextAsync(string scriptFile, CancellationToken ct = default, string extraArgs = "")
    {
        var dir = ScriptsDirectory;
        if (dir is null)
        {
            LastError = "Repo root not resolved (RepoRoot=" + (RepoRoot ?? "null") + ")";
            return null;
        }

        var scriptPath = Path.Combine(dir, scriptFile);
        if (!File.Exists(scriptPath))
        {
            LastError = "Script not found: " + scriptPath;
            return null;
        }

        try
        {
            return await RunScriptAsync(scriptPath, extraArgs, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            LastError = scriptFile + ": " + ex.GetType().Name + ": " + ex.Message;
            return null;
        }
    }

    public Task<ProcessProfileEnvelope?> GetProcessProfilePreviewAsync(CancellationToken ct = default)
        => RunAsync<ProcessProfileEnvelope>("Preview-ProcessProfile.ps1", ct);

    public Task<AppClassificationResult?> GetAppClassificationAsync(CancellationToken ct = default)
        => RunAsync<AppClassificationResult>("Get-AppClassification.ps1", ct);

    public Task<NvidiaNipPreview?> GetNvidiaNipPreviewAsync(CancellationToken ct = default)
        => RunAsync<NvidiaNipPreview>("Preview-NvidiaNipProfile.ps1", ct);

    public Task<StutterOptimizationPreview?> GetStutterOptimizationPreviewAsync(CancellationToken ct = default)
        => RunAsync<StutterOptimizationPreview>("Preview-StutterOptimization.ps1", ct);

    private async Task<T?> RunAsync<T>(string scriptFile, CancellationToken ct, string extraArgs = "") where T : class
    {
        var dir = ScriptsDirectory;
        if (dir is null)
        {
            LastError = "Repo root not resolved (RepoRoot=" + (RepoRoot ?? "null") + ")";
            return null;
        }

        var scriptPath = Path.Combine(dir, scriptFile);
        if (!File.Exists(scriptPath))
        {
            LastError = "Script not found: " + scriptPath;
            return null;
        }

        try
        {
            var json = await RunScriptAsync(scriptPath, extraArgs, ct).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(json))
            {
                LastError = "Empty output from " + scriptFile;
                return null;
            }

            return JsonSerializer.Deserialize<T>(json, JsonOptions);
        }
        catch (Exception ex)
        {
            LastError = scriptFile + ": " + ex.GetType().Name + ": " + ex.Message;
            return null;
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

    private async Task<(string DirectoryPath, string OfficialPreviewPath, string CleanupManifestPath, string OfficialSha256, string CleanupSha256)?> PrepareUninstallCleanupInputsAsync(string appId, CancellationToken ct)
    {
        var official = _officialReview;
        var cleanup = _cleanupReview;
        var generation = _cleanupReviewGeneration;
        if (official?.AppId != appId || cleanup?.AppId != appId || official.Generation != generation || cleanup.Generation != generation)
        {
            LastError = "Review this app's removal route and cleanup list before applying.";
            return null;
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
            LastError = "The selected app changed; review its inputs again.";
            return null;
        }
        var officialHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(official.Json)));
        var cleanupHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(cleanup.Json)));
        return (dir, officialPath, manifestPath, officialHash, cleanupHash);
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

    private async Task<string?> RunScriptAsync(string scriptPath, string extraArgs, CancellationToken ct)
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
            return null;
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
            LastError = "Timed out running " + Path.GetFileName(scriptPath);
            return null;
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(stdout) && !string.IsNullOrWhiteSpace(stderr))
        {
            LastError = stderr.Trim();
        }

        return stdout;
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
