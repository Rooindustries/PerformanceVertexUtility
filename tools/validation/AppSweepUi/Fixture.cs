using System.Text.Json;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite
{
    public static class App
    {
        public static Services.FakeLiveDataService Live { get; } = new();
        public static Services.FakeOptimizerService Operations { get; } = new();
        public static Services.SampleDataService Data { get; } = new();
    }
}

namespace RooIndustries.OptimizationSuite.Services
{
    public sealed class SampleDataService
    {
        public Task<DriverRecommendationCatalog> GetDriverRecommendationsAsync() => Task.FromResult(new DriverRecommendationCatalog());
        public Task<NvidiaProfileCatalog> GetNvidiaProfilesAsync() => Task.FromResult(new NvidiaProfileCatalog());
    }
    public sealed record ProcessControlReview(ProcessControlPreview Plan, string PreviewPath, string Hash, string JournalPath);
    public sealed record PolicyWorkerRegistration(string TaskName, bool Registered, bool RunAtLogon, PolicyWorkerStatus Worker);
    public sealed record LiveDataResult<T>(T? Value, string? Error, string? RecoveryPath = null);

    public sealed class FakeLiveDataService
    {
        public ProcessInventory? Inventory { get; set; }
        public ProcessClassification? Classification { get; set; }
        public string? LastError { get; set; }
        public string? LatestProcessBackup { get; set; }
        public string? LastCleanupRollbackPath { get; set; }
        public string? CleanupRecoveryPath { get; set; }
        public string? ProcessPreviewText { get; set; }
        public string? ProcessApplyText { get; set; }
        public string? ProcessRestoreText { get; set; }
        public string? LastProcessRestorePath { get; private set; }
        public InstalledAppInventory? InstalledApps { get; set; }
        public DriverHardwareSummary? DriverHardware { get; set; }
        public string? NvidiaProbeText { get; set; }
        public string? NvidiaPreviewText { get; set; }
        public string? NvidiaApplyText { get; set; }
        public string? NvidiaRestoreText { get; set; }
        public string? StutterPreviewText { get; set; }
        public string? TimerText { get; set; }
        public string? ShaderText { get; set; }
        public string? ShaderRestoreText { get; set; }
        public Func<string, Task<OfficialUninstallPreview?>> OfficialPreview { get; set; } = _ => Task.FromResult<OfficialUninstallPreview?>(null);
        public Func<string, Task<LeftoverScan?>> LeftoverScan { get; set; } = _ => Task.FromResult<LeftoverScan?>(null);
        public Func<string, Task<CleanupManifest?>> CleanupManifest { get; set; } = _ => Task.FromResult<CleanupManifest?>(null);
        public Func<string, Task<UninstallCleanupExecutionPlan?>> CleanupPlan { get; set; } = _ => Task.FromResult<UninstallCleanupExecutionPlan?>(null);
        public Func<string, bool, bool, bool, Task<string?>> CleanupApply { get; set; } = (_, _, _, _) => Task.FromResult<string?>(null);
        public Func<string, Task<string?>> CleanupRestore { get; set; } = _ => Task.FromResult<string?>(null);
        public Task<ProcessInventory?> GetProcessInventoryAsync(CancellationToken cancellationToken = default) => Task.FromResult(Inventory);
        public Task<ProcessClassification?> GetProcessClassificationAsync(CancellationToken cancellationToken = default) => Task.FromResult(Classification);
        public string? FindLatestProcessProfileBackup() => LatestProcessBackup;
        public Task<string?> PreviewProcessProfileTextAsync(CancellationToken cancellationToken = default) => Task.FromResult(ProcessPreviewText);
        public Task<LiveDataResult<string>> PreviewProcessProfileResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ProcessPreviewText, ProcessPreviewText is null ? LastError : null));
        public Task<string?> ApplyProcessProfileTextAsync(CancellationToken cancellationToken = default) => Task.FromResult(ProcessApplyText);
        public Task<LiveDataResult<string>> ApplyProcessProfileResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ProcessApplyText, ProcessApplyText is null ? LastError : null));
        public Task<string?> RestoreProcessProfileTextAsync(string backupPath, CancellationToken cancellationToken = default)
        {
            LastProcessRestorePath = backupPath;
            return Task.FromResult(ProcessRestoreText);
        }
        public Task<LiveDataResult<string>> RestoreProcessProfileResultAsync(string backupPath, CancellationToken cancellationToken = default)
        {
            LastProcessRestorePath = backupPath;
            return Task.FromResult(new LiveDataResult<string>(ProcessRestoreText, ProcessRestoreText is null ? LastError : null));
        }
        public Task<string?> RunGameTuneSessionTextAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
        public Task<string?> RestoreGameTuneSessionTextAsync(CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
        public Task<string?> GetGameTuneSessionStatusTextAsync(CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
        public Task<string?> RunProcessGovernorSessionTextAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, int sampleIntervalMilliseconds, CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
        public Task<string?> RestoreProcessGovernorSessionTextAsync(CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
        public Task<string?> GetProcessGovernorSessionStatusTextAsync(CancellationToken cancellationToken = default) => Task.FromResult<string?>(null);
        public Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken cancellationToken = default) => Task.FromResult(DriverHardware);
        public Task<LiveDataResult<string>> ProbeNvidiaProfileResultAsync(string profileId, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaProbeText, NvidiaProbeText is null ? LastError : null));
        public Task<LiveDataResult<string>> PreviewNvidiaProfileResultAsync(string profileId, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaPreviewText, NvidiaPreviewText is null ? LastError : null));
        public Task<LiveDataResult<string>> ApplyNvidiaProfileResultAsync(string profileId, bool exportReviewed, bool userApproved, bool benchmarkEvidenceAttached, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaApplyText, NvidiaApplyText is null ? LastError : null));
        public Task<LiveDataResult<string>> RestoreNvidiaProfileResultAsync(string profileId, bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaRestoreText, NvidiaRestoreText is null ? LastError : null));
        public Task<LiveDataResult<string>> PreviewStutterOptimizationResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(StutterPreviewText, StutterPreviewText is null ? LastError : null));
        public Task<LiveDataResult<string>> CheckTimerResolutionResultAsync(bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(TimerText, TimerText is null ? LastError : null));
        public Task<LiveDataResult<string>> CheckShaderCacheCleanupResultAsync(bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ShaderText, ShaderText is null ? LastError : null));
        public Task<LiveDataResult<string>> RestoreShaderCacheCleanupResultAsync(string rollbackManifestPath, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ShaderRestoreText, ShaderRestoreText is null ? LastError : null));
        public Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken cancellationToken = default, bool includeAllAppxUsers = false) => Task.FromResult(InstalledApps);
        public Task<OfficialUninstallPreview?> GetOfficialUninstallPreviewAsync(string appId, CancellationToken cancellationToken = default) => OfficialPreview(appId);
        public async Task<LiveDataResult<OfficialUninstallPreview>> GetOfficialUninstallPreviewResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await OfficialPreview(appId);
            return new(value, value is null ? LastError : null);
        }
        public Task<LeftoverScan?> GetLeftoverScanAsync(string appId, CancellationToken cancellationToken = default) => LeftoverScan(appId);
        public async Task<LiveDataResult<LeftoverScan>> GetLeftoverScanResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await LeftoverScan(appId);
            return new(value, value is null ? LastError : null);
        }
        public Task<CleanupManifest?> GetCleanupManifestAsync(string appId, CancellationToken cancellationToken = default) => CleanupManifest(appId);
        public async Task<LiveDataResult<CleanupManifest>> GetCleanupManifestResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await CleanupManifest(appId);
            return new(value, value is null ? LastError : null);
        }
        public Task<UninstallCleanupExecutionPlan?> GetUninstallCleanupExecutionPlanAsync(string appId, CancellationToken cancellationToken = default) => CleanupPlan(appId);
        public async Task<LiveDataResult<UninstallCleanupExecutionPlan>> GetUninstallCleanupExecutionPlanResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await CleanupPlan(appId);
            return new(value, value is null ? LastError : null);
        }
        public Task<string?> RequestUninstallCleanupApplyTextAsync(string appId, bool officialApproved, bool cleanupApproved, bool realApproved, CancellationToken cancellationToken = default)
            => CleanupApply(appId, officialApproved, cleanupApproved, realApproved);
        public async Task<LiveDataResult<string>> RequestUninstallCleanupApplyResultAsync(string appId, bool officialApproved, bool cleanupApproved, bool realApproved, CancellationToken cancellationToken = default)
        {
            var value = await CleanupApply(appId, officialApproved, cleanupApproved, realApproved);
            return new(value, value is null ? LastError : null, realApproved ? CleanupRecoveryPath : null);
        }
        public Task<string?> RestoreUninstallCleanupTextAsync(string rollbackPath, CancellationToken cancellationToken = default) => CleanupRestore(rollbackPath);
        public async Task<LiveDataResult<string>> RestoreUninstallCleanupResultAsync(string rollbackPath, CancellationToken cancellationToken = default)
        {
            var value = await CleanupRestore(rollbackPath);
            return new(value, value is null ? LastError : null);
        }
        public void DiscardCleanupReview() => LastCleanupRollbackPath = null;
    }

    public sealed class FakeOptimizerService
    {
        public ProcessControlSnapshot? ProcessSnapshot { get; set; }
        public string? FindLastJournal(string kind) => null;
        public Task<ProcessControlSnapshot> ReadProcessControlsAsync(int processId)
            => Task.FromResult(ProcessSnapshot ?? throw new InvalidOperationException("Process snapshot fixture is missing."));
        public Task<ProcessControlReview> PreviewControlsAsync(int processId, Dictionary<string, JsonElement> controls, CpuSelection? selection)
            => throw new InvalidOperationException("Unexpected preview call.");
        public Task<ProcessControlJournal> ApplyControlsAsync(ProcessControlReview review)
            => throw new InvalidOperationException("Unexpected apply call.");
        public Task<ProcessControlJournal> RestoreControlsAsync(string journalPath)
            => throw new InvalidOperationException("Unexpected restore call.");
        public Task<SavedProcessRule[]> ReadRulesAsync() => Task.FromResult(Array.Empty<SavedProcessRule>());
        public Task<PolicyWorkerStatus> ReadPolicyStatusAsync() => Task.FromResult(new PolicyWorkerStatus(null, false, null));
        public Task<SavedProcessRule> SaveRuleAsync(SavedProcessRule rule) => Task.FromResult(rule);
        public Task<JsonElement> DeleteRuleAsync(string ruleId) => Task.FromResult(JsonSerializer.SerializeToElement(new { }));
        public Task<PolicyWorkerRegistration> PolicyWorkerAsync(string action)
            => Task.FromResult(new PolicyWorkerRegistration("fixture", false, false, new PolicyWorkerStatus(null, false, null)));
    }
}

namespace RooIndustries.OptimizationSuite.ViewModels
{
    public sealed record CpuProcessChoice(int Id, string Name)
    {
        public override string ToString() => Name;
    }
}
