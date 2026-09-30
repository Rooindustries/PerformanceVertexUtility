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
    public sealed record LiveDataResult<T>(T? Value, string? Error, string? RecoveryPath = null, string? RecoveryGeneration = null);
    public sealed record NvidiaProfileRecovery(string ProfileId, string RollbackManifestPath, string ExportPath, string? Generation = null);
    public sealed record GameSessionEntry(string SessionRoot, ProtectedSessionStatus Worker);
    public static class LiveDataService
    {
        public static NvidiaProfileRecovery? NvidiaRecoveryFromApplyResult(string profileId, string? json, string? rollbackManifestPath, string? generation) => null;
    }

    public sealed class FakeLiveDataService
    {
        public ProcessInventory? Inventory { get; set; }
        public ProcessClassification? Classification { get; set; }
        public GameTuneSessionStatus? GameStatusModel { get; set; }
        public ProcessGovernorSessionStatus? GovernorStatusModel { get; set; }
        public string? LastError { get; set; }
        public string? OperationError { get; set; }
        public string? LatestProcessBackup { get; set; }
        public ProcessProfileRecovery? ProcessProfileRecovery { get; set; }
        public string? LastCleanupRollbackPath { get; set; }
        public string? CleanupRecoveryPath { get; set; }
        public string? ProcessPreviewText { get; set; }
        public string? ProcessApplyText { get; set; }
        public string? ProcessRestoreText { get; set; }
        public string? LastProcessRestorePath { get; private set; }
        public string? GameTuneText { get; set; }
        public string? GameTuneStatusText { get; set; }
        public string? GameTuneRestoreText { get; set; }
        public string? GameTuneResultError { get; set; }
        public string? GameTuneRestoreError { get; set; }
        public string? GameTuneStatusError { get; set; }
        public string? GovernorText { get; set; }
        public string? GovernorStatusText { get; set; }
        public string? GovernorRestoreText { get; set; }
        public string? GovernorResultError { get; set; }
        public string? GovernorRestoreError { get; set; }
        public string? GovernorStatusError { get; set; }
        public (string SessionId, string SessionPath, string BackupPath)? LastGameRestoreRequest { get; private set; }
        public (string SessionId, string SessionPath, string BackupPath)? LastGovernorRestoreRequest { get; private set; }
        public InstalledAppInventory? InstalledApps { get; set; }
        public DriverHardwareSummary? DriverHardware { get; set; }
        public string? NvidiaProbeText { get; set; }
        public string? NvidiaPreviewText { get; set; }
        public string? NvidiaApplyText { get; set; }
        public string? NvidiaRestoreText { get; set; }
        public string? NvidiaApplyError { get; set; }
        public string? NvidiaRestoreError { get; set; }
        public NvidiaProfileRecovery? NvidiaRecovery { get; set; }
        public NvidiaProfileRecovery? LastNvidiaRestoreRecovery { get; private set; }
        public bool ClearNvidiaRecoveryOnRestore { get; set; }
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
        public Task<GameTuneSessionStatus?> GetGameTuneSessionStatusAsync(CancellationToken cancellationToken = default) => Task.FromResult(GameStatusModel);
        public Task<ProcessGovernorSessionStatus?> GetProcessGovernorSessionStatusAsync(CancellationToken cancellationToken = default) => Task.FromResult(GovernorStatusModel);
        public string? FindLatestProcessProfileBackup() => LatestProcessBackup;
        public Task<LiveDataResult<string>> PreviewProcessProfileResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ProcessPreviewText, OperationError ?? (ProcessPreviewText is null ? LastError : null)));
        public Task<LiveDataResult<string>> ApplyProcessProfileResultAsync(CancellationToken cancellationToken = default)
        {
            var recovery = ProcessProfileRecovery.FromApply(ProcessApplyText);
            if (recovery is not null) ProcessProfileRecovery = recovery;
            return Task.FromResult(new LiveDataResult<string>(ProcessApplyText, OperationError ?? (ProcessApplyText is null ? LastError : null), recovery?.Path, recovery?.Generation));
        }
        public Task<LiveDataResult<string>> RestoreProcessProfileResultAsync(ProcessProfileRecovery recovery, CancellationToken cancellationToken = default)
        {
            LastProcessRestorePath = recovery.Path;
            var error = OperationError ?? (ProcessRestoreText is null ? LastError : null);
            var completed = error is null && recovery.RestoreCompleted(ProcessRestoreText) && ProcessProfileRecovery == recovery;
            if (completed) ProcessProfileRecovery = null;
            return Task.FromResult(new LiveDataResult<string>(ProcessRestoreText, error, completed ? null : recovery.Path, completed ? null : recovery.Generation));
        }
        public Task<LiveDataResult<string>> RunGameTuneSessionResultAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(GameTuneText, GameTuneResultError ?? (GameTuneText is null ? LastError : null)));
        public Task<LiveDataResult<string>> RestoreGameTuneSessionResultAsync(string sessionId, string sessionPath, string backupManifestPath, CancellationToken cancellationToken = default)
        {
            LastGameRestoreRequest = (sessionId, sessionPath, backupManifestPath);
            return Task.FromResult(new LiveDataResult<string>(GameTuneRestoreText, GameTuneRestoreError ?? (GameTuneRestoreText is null ? LastError : null)));
        }
        public Task<LiveDataResult<string>> GetGameTuneSessionStatusResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(GameTuneStatusText, GameTuneStatusError ?? (GameTuneStatusText is null ? LastError : null)));
        public Task<LiveDataResult<string>> RunProcessGovernorSessionResultAsync(bool confirmApply, int maxDurationSeconds, int pollIntervalSeconds, int sampleIntervalMilliseconds, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(GovernorText, GovernorResultError ?? (GovernorText is null ? LastError : null)));
        public Task<LiveDataResult<string>> RestoreProcessGovernorSessionResultAsync(string sessionId, string sessionPath, string backupManifestPath, CancellationToken cancellationToken = default)
        {
            LastGovernorRestoreRequest = (sessionId, sessionPath, backupManifestPath);
            return Task.FromResult(new LiveDataResult<string>(GovernorRestoreText, GovernorRestoreError ?? (GovernorRestoreText is null ? LastError : null)));
        }
        public Task<LiveDataResult<string>> GetProcessGovernorSessionStatusResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(GovernorStatusText, GovernorStatusError ?? (GovernorStatusText is null ? LastError : null)));
        public Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken cancellationToken = default, bool fresh = false) => Task.FromResult(DriverHardware);
        public Task<LiveDataResult<string>> ProbeNvidiaProfileResultAsync(string profileId, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaProbeText, OperationError ?? (NvidiaProbeText is null ? LastError : null)));
        public Task<LiveDataResult<string>> PreviewNvidiaProfileResultAsync(string profileId, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaPreviewText, OperationError ?? (NvidiaPreviewText is null ? LastError : null)));
        public Task<LiveDataResult<string>> ApplyNvidiaProfileResultAsync(string profileId, bool exportReviewed, bool userApproved, bool benchmarkEvidenceAttached, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(NvidiaApplyText, OperationError ?? NvidiaApplyError ?? (NvidiaApplyText is null ? LastError : null)));
        public Task<NvidiaProfileRecovery?> ReadNvidiaProfileRecoveryAsync(string profileId)
            => Task.FromResult(NvidiaRecovery?.ProfileId == profileId ? NvidiaRecovery : null);
        public Task<LiveDataResult<string>> RestoreNvidiaProfileResultAsync(NvidiaProfileRecovery recovery, bool userApproved, CancellationToken cancellationToken = default)
        {
            LastNvidiaRestoreRecovery = recovery;
            if (ClearNvidiaRecoveryOnRestore) NvidiaRecovery = null;
            return Task.FromResult(new LiveDataResult<string>(NvidiaRestoreText, OperationError ?? NvidiaRestoreError ?? (NvidiaRestoreText is null ? LastError : null)));
        }
        public Task<LiveDataResult<string>> PreviewStutterOptimizationResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(StutterPreviewText, OperationError ?? (StutterPreviewText is null ? LastError : null)));
        public Task<LiveDataResult<string>> CheckTimerResolutionResultAsync(bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(TimerText, OperationError ?? (TimerText is null ? LastError : null)));
        public Task<LiveDataResult<string>> CheckShaderCacheCleanupResultAsync(bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ShaderText, OperationError ?? (ShaderText is null ? LastError : null)));
        public Task<LiveDataResult<string>> RestoreShaderCacheCleanupResultAsync(string rollbackManifestPath, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ShaderRestoreText, OperationError ?? (ShaderRestoreText is null ? LastError : null)));
        public Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken cancellationToken = default, bool includeAllAppxUsers = false) => Task.FromResult(InstalledApps);
        public Task<OfficialUninstallPreview?> GetOfficialUninstallPreviewAsync(string appId, CancellationToken cancellationToken = default) => OfficialPreview(appId);
        public async Task<LiveDataResult<OfficialUninstallPreview>> GetOfficialUninstallPreviewResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await OfficialPreview(appId);
            return new(value, OperationError ?? (value is null ? LastError : null));
        }
        public Task<LeftoverScan?> GetLeftoverScanAsync(string appId, CancellationToken cancellationToken = default) => LeftoverScan(appId);
        public async Task<LiveDataResult<LeftoverScan>> GetLeftoverScanResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await LeftoverScan(appId);
            return new(value, OperationError ?? (value is null ? LastError : null));
        }
        public Task<CleanupManifest?> GetCleanupManifestAsync(string appId, CancellationToken cancellationToken = default) => CleanupManifest(appId);
        public async Task<LiveDataResult<CleanupManifest>> GetCleanupManifestResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await CleanupManifest(appId);
            return new(value, OperationError ?? (value is null ? LastError : null));
        }
        public Task<UninstallCleanupExecutionPlan?> GetUninstallCleanupExecutionPlanAsync(string appId, CancellationToken cancellationToken = default) => CleanupPlan(appId);
        public async Task<LiveDataResult<UninstallCleanupExecutionPlan>> GetUninstallCleanupExecutionPlanResultAsync(string appId, CancellationToken cancellationToken = default)
        {
            var value = await CleanupPlan(appId);
            return new(value, OperationError ?? (value is null ? LastError : null));
        }
        public Task<string?> RequestUninstallCleanupApplyTextAsync(string appId, bool officialApproved, bool cleanupApproved, bool realApproved, CancellationToken cancellationToken = default)
            => CleanupApply(appId, officialApproved, cleanupApproved, realApproved);
        public async Task<LiveDataResult<string>> RequestUninstallCleanupApplyResultAsync(string appId, bool officialApproved, bool cleanupApproved, bool realApproved, CancellationToken cancellationToken = default)
        {
            var value = await CleanupApply(appId, officialApproved, cleanupApproved, realApproved);
            return new(value, OperationError ?? (value is null ? LastError : null), realApproved ? CleanupRecoveryPath : null);
        }
        public Task<string?> RestoreUninstallCleanupTextAsync(string rollbackPath, CancellationToken cancellationToken = default) => CleanupRestore(rollbackPath);
        public async Task<LiveDataResult<string>> RestoreUninstallCleanupResultAsync(string rollbackPath, CancellationToken cancellationToken = default)
        {
            var value = await CleanupRestore(rollbackPath);
            return new(value, OperationError ?? (value is null ? LastError : null));
        }
        public void DiscardCleanupReview() => LastCleanupRollbackPath = null;
    }

    public sealed record CleanupBatchReview(CleanupBatchPreview Plan, string PreviewPath, string Hash, string JournalPath);
    public sealed record CleanupBatchSession(CleanupBatchReview Review, CleanupBatchJournal State);

    public sealed class FakeOptimizerService
    {
        public BulkRemovalSession? LastRemoval { get; set; }
        public (string Path, BulkRemovalJournal State)[] RemovalHistory { get; set; } = [];
        public Func<string, Task<OptimizerResult<BulkRemovalJournal>>> DismissRemoval { get; set; } = _ => throw new InvalidOperationException("Unexpected dismiss call.");
        public Func<string, Task<OptimizerResult<BulkRemovalJournal>>> ReconcileRemoval { get; set; } = _ => throw new InvalidOperationException("Unexpected reconcile call.");
        public List<string> Dismissed { get; } = new();
        public Task<BulkRemovalSession?> ReadLastRemovalAsync() => Task.FromResult(LastRemoval);
        public Task<(string Path, BulkRemovalJournal State)[]> ReadRemovalHistoryAsync() => Task.FromResult(RemovalHistory);
        public Task<CleanupBatchSession[]> ReadCleanupHistoryAsync() => Task.FromResult(Array.Empty<CleanupBatchSession>());
        public Task<RemovalCleanupReview?> ReadLastFileCleanupAsync() => Task.FromResult<RemovalCleanupReview?>(null);
        public Task<OptimizerResult<BulkRemovalJournal>> DismissRemovalAsync(string journal) { Dismissed.Add(journal); return DismissRemoval(journal); }
        public Task<OptimizerResult<BulkRemovalJournal>> ReconcileRemovalAsync(string journal) => ReconcileRemoval(journal);
        public Task<BulkRemovalReview> PreviewRemovalAsync(string[] appIds, bool includeAllAppxUsers = false) => throw new InvalidOperationException("Unexpected removal preview call.");
        public Task<OptimizerResult<BulkRemovalJournal>> ApplyRemovalAsync(BulkRemovalReview review, bool dependenciesReviewed, IProgress<BulkRemovalJournal> progress) => throw new InvalidOperationException("Unexpected removal call.");
        public Task<OptimizerResult<BulkRemovalJournal>> CancelRemovalAsync(string journal) => throw new InvalidOperationException("Unexpected cancel call.");
        public Task<LeftoverDiscoveryResult> DiscoverLeftoversAsync(string queueJournalPath, string appId, CancellationToken cancellationToken) => throw new InvalidOperationException("Unexpected leftover scan.");
        public Task<CleanupPart> PreviewDeepCleanupAsync(string queueJournalPath, string appId, string[] itemIds, bool acceptKeyRecreation) => throw new InvalidOperationException("Unexpected cleanup preview.");
        public Task<CleanupBatchReview> PreviewCleanupBatchAsync(CleanupPart[] applications) => throw new InvalidOperationException("Unexpected cleanup batch preview.");
        public Task<CleanupBatchJournal> ApplyCleanupBatchAsync(CleanupBatchReview review, string? cancellationId, IProgress<CleanupBatchJournal> progress) => throw new InvalidOperationException("Unexpected cleanup apply.");
        public Task<CleanupBatchCancellation> CancelCleanupBatchAsync(string journalPath) => throw new InvalidOperationException("Unexpected cleanup cancel.");
        public Task<CleanupBatchJournal> RestoreCleanupBatchAsync(string journalPath) => throw new InvalidOperationException("Unexpected cleanup restore.");
        public Task<OptimizerResult<FileCleanupResult>> RestoreRemovedFilesAsync(RemovalCleanupReview review) => throw new InvalidOperationException("Unexpected file restore.");
        public ProcessControlSnapshot? ProcessSnapshot { get; set; }
        public GameSessionEntry[] GameSessions { get; set; } = [];
        public TweakRecovery? WindowsRecovery { get; set; } = new(null, null, null);
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
        public Task<GameSessionEntry[]> ReadGameSessionsAsync() => Task.FromResult(GameSessions);
        public Task<TweakRecovery> ReadWindowsRecoveryAsync() => Task.FromResult(WindowsRecovery ?? throw new IOException("Controlled Windows recovery failure"));
    }
}

namespace RooIndustries.OptimizationSuite.ViewModels
{
    public sealed record CpuProcessChoice(int Id, string Name)
    {
        public override string ToString() => Name;
    }
}
