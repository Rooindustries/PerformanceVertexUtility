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
        public static Services.BugReportService BugReports { get; set; } = null!;
        public static string VersionText => "0.10.0-beta fixture";
    }
}

namespace RooIndustries.OptimizationSuite.Services
{
    public sealed class SampleDataService
    {
        public Task<DriverRecommendationCatalog> GetDriverRecommendationsAsync() => Task.FromResult(new DriverRecommendationCatalog());
        public NvidiaProfileCatalog NvidiaProfiles { get; set; } = new();
        public Task<NvidiaProfileCatalog> GetNvidiaProfilesAsync() => Task.FromResult(NvidiaProfiles);
    }
    public sealed record ProcessControlReview(ProcessControlPreview Plan, string PreviewPath, string Hash, string JournalPath);
    public sealed record PolicyWorkerRegistration(string TaskName, bool Registered, bool Enabled, bool RunAtLogon, bool RestartEveryMinute, bool Paused, int Rules, int EnabledRules,
        bool Secured, string? SecurityProblem, string? RulesError, PolicyWorkerStatus Worker);
    public sealed record GovernorSnapshot(PolicySummary Summary, PolicyWorkerStatus Worker, SavedProcessRule[] Rules, Dictionary<string, ProcessControlJournal> Journals,
        GovernorTaskState? ScheduledTask = null, IReadOnlySet<string>? Exited = null, IReadOnlySet<string>? Unapplied = null, IReadOnlySet<string>? RunningImages = null, IReadOnlyDictionary<string, bool?>? PathRulesRunning = null);
    public sealed record LiveDataResult<T>(T? Value, string? Error, string? RecoveryPath = null, string? RecoveryGeneration = null) { public bool Stale { get; init; } }
    public sealed record NvidiaProfileRecovery(string ProfileId, string RollbackManifestPath, string ExportPath, string? Generation = null);
    public sealed record GameSessionEntry(string SessionRoot, ProtectedSessionStatus Worker, string? ProfileId = null);
    public sealed record GameSessionReview(ProtectedSessionPreview Plan, string PreviewPath, string Hash, string SessionRoot);
    public sealed record LaunchProfileEntry(string Root, ProtectedSessionPreview Saved)
    {
        public string Title => Path.GetFileName(Saved.GamePath) + " via " + Path.GetFileName(Saved.Launcher.ExecutablePath);
    }
    public static class ServiceSteps
    {
        public static Func<string, Task>? Pause { get; set; }
        public static List<string> Written { get; } = new();
        public static async Task<T> Then<T>(string helper, Func<T> write, Action? prepare = null)
        {
            if (Pause is not { } pause) { prepare?.Invoke(); return write(); }
            await pause(helper + " starts");
            prepare?.Invoke();
            using (DataGeneration.BeginChange()) await pause(helper);
            await pause(helper + " returned");
            var result = write();
            Written.Add(helper);
            return result;
        }
    }

    public static class OptimizerService
    {
        public static Task<T?> ReadJournalAsync<T>(string path) => throw new InvalidOperationException("Unexpected journal read.");
        public static string DescribeLaunchProfile(LaunchProfileEntry entry) => "Waiting for " + Path.GetFileName(entry.Saved.Launcher.ExecutablePath) + " to open.";
    }

    public static class LiveDataService
    {
        public static NvidiaProfileRecovery? NvidiaRecoveryFromApplyResult(string profileId, string? json, string? rollbackManifestPath, string? generation) => null;
    }

    public sealed class FakeLiveDataService
    {
        public Task<LiveDataResult<string>> RunBackendScriptResultAsync(string script) => Task.FromResult(new LiveDataResult<string>("{}", null));
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
        public GameTuneReview? GameTuneReviewModel { get; set; }
        public GameTuneReview? LastGameTuneStartReview { get; private set; }
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
        public Task<LiveDataResult<ProcessClassification>> GetProcessClassificationResultAsync(CancellationToken cancellationToken = default, bool fresh = false, bool allowStale = false, bool background = false)
            => Task.FromResult(new LiveDataResult<ProcessClassification>(Classification, Classification?.Processes is null ? LastError : null));
        public Task<GameTuneSessionStatus?> GetGameTuneSessionStatusAsync(CancellationToken cancellationToken = default) => Task.FromResult(GameStatusModel);
        public Task<ProcessGovernorSessionStatus?> GetProcessGovernorSessionStatusAsync(CancellationToken cancellationToken = default) => Task.FromResult(GovernorStatusModel);
        public string? FindLatestProcessProfileBackup() => LatestProcessBackup;
        public bool ProcessProfileRestorePending => ProcessProfileRecovery is not null;
        public bool ProcessProfileApplyFinishing => false;
        public bool TakeProcessApplyRecoveredNotice() => false;
        public bool ProcessRecoverySetAside { get; set; }
        public bool TakeProcessRecoverySetAsideNotice()
        {
            var notice = ProcessRecoverySetAside;
            ProcessRecoverySetAside = false;
            return notice;
        }
        public string? BackgroundPlacementText { get; set; }
        public string? LastProcessPreset { get; private set; }
        public Task<LiveDataResult<string>> GetBackgroundPlacementResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(BackgroundPlacementText, BackgroundPlacementText is null ? LastError : null));
        public Task<LiveDataResult<string>> PreviewProcessProfileResultAsync(CancellationToken cancellationToken = default, string preset = "lower")
        {
            LastProcessPreset = preset;
            return Task.FromResult(new LiveDataResult<string>(ProcessPreviewText, OperationError ?? (ProcessPreviewText is null ? LastError : null)));
        }
        public Task<LiveDataResult<string>> ApplyProcessProfileResultAsync(CancellationToken cancellationToken = default, string preset = "lower")
        {
            LastProcessPreset = preset;
            return ServiceSteps.Then("background priorities", () =>
            {
                var recovery = ProcessProfileRecovery.FromApply(ProcessApplyText);
                if (recovery is not null) ProcessProfileRecovery = recovery;
                return new LiveDataResult<string>(ProcessApplyText, OperationError ?? (ProcessApplyText is null ? LastError : null), recovery?.Path, recovery?.Generation);
            });
        }
        public Task<LiveDataResult<string>> RestoreProcessProfileResultAsync(ProcessProfileRecovery recovery, CancellationToken cancellationToken = default)
        {
            LastProcessRestorePath = recovery.Path;
            return ServiceSteps.Then("background restore", () =>
            {
                var error = OperationError ?? (ProcessRestoreText is null ? LastError : null);
                var completed = error is null && recovery.RestoreCompleted(ProcessRestoreText) && ProcessProfileRecovery == recovery;
                if (completed) ProcessProfileRecovery = null;
                return new LiveDataResult<string>(ProcessRestoreText, error, completed ? null : recovery.Path, completed ? null : recovery.Generation);
            });
        }
        public Task<(LiveDataResult<string> Result, GameTuneReview? Review)> ReviewGameTuneSessionResultAsync(int maxDurationSeconds, int pollIntervalSeconds, CancellationToken cancellationToken = default)
            => Task.FromResult((new LiveDataResult<string>(GameTuneText, GameTuneResultError ?? (GameTuneText is null ? LastError : null)), GameTuneReviewModel));
        public Task<LiveDataResult<string>> StartGameTuneSessionResultAsync(GameTuneReview review, int maxDurationSeconds, int pollIntervalSeconds, CancellationToken cancellationToken = default)
        {
            LastGameTuneStartReview = review;
            return Task.FromResult(new LiveDataResult<string>(GameTuneText, GameTuneResultError ?? (GameTuneText is null ? LastError : null)));
        }
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
        public NvidiaProfileRecovery? NvidiaApplyRecovery { get; set; }
        public Task<LiveDataResult<string>> ApplyNvidiaProfileResultAsync(string profileId, bool exportReviewed, bool userApproved, bool benchmarkEvidenceAttached, CancellationToken cancellationToken = default)
            => ServiceSteps.Then("NVIDIA profile", () =>
            {
                if (NvidiaApplyRecovery is { } saved) NvidiaRecovery = saved;
                return new LiveDataResult<string>(NvidiaApplyText, OperationError ?? NvidiaApplyError ?? (NvidiaApplyText is null ? LastError : null));
            });
        public Task<NvidiaProfileRecovery?> ReadNvidiaProfileRecoveryAsync(string profileId)
            => Task.FromResult(NvidiaRecovery?.ProfileId == profileId ? NvidiaRecovery : null);
        public Task<LiveDataResult<string>> RestoreNvidiaProfileResultAsync(NvidiaProfileRecovery recovery, bool userApproved, CancellationToken cancellationToken = default)
        {
            LastNvidiaRestoreRecovery = recovery;
            return ServiceSteps.Then("NVIDIA restore", () =>
            {
                if (ClearNvidiaRecoveryOnRestore) NvidiaRecovery = null;
                return new LiveDataResult<string>(NvidiaRestoreText, OperationError ?? NvidiaRestoreError ?? (NvidiaRestoreText is null ? LastError : null));
            });
        }
        public Task<LiveDataResult<string>> PreviewStutterOptimizationResultAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(StutterPreviewText, OperationError ?? (StutterPreviewText is null ? LastError : null)));
        public Task<LiveDataResult<string>> CheckTimerResolutionResultAsync(bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(TimerText, OperationError ?? (TimerText is null ? LastError : null)));
        public Task<LiveDataResult<string>> CheckShaderCacheCleanupResultAsync(bool userApproved, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ShaderText, OperationError ?? (ShaderText is null ? LastError : null)));
        public Task<LiveDataResult<string>> RestoreShaderCacheCleanupResultAsync(string rollbackManifestPath, CancellationToken cancellationToken = default)
            => Task.FromResult(new LiveDataResult<string>(ShaderRestoreText, OperationError ?? (ShaderRestoreText is null ? LastError : null)));
        public Func<Task>? BeforeInstalledApps { get; set; }
        public Func<Task>? AfterInstalledApps { get; set; }
        public async Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken cancellationToken = default, bool includeAllAppxUsers = false, bool fresh = false)
        {
            if (BeforeInstalledApps is { } hold) await hold();
            var apps = InstalledApps;
            if (AfterInstalledApps is { } after) await after();
            return apps;
        }
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
        public string? CleanupRunsRoot { get; set; }
        public TimeSpan CleanupRecoveryDelay { get; set; }
        public async Task<string?> FindCleanupRecoveryAsync(string appId, CancellationToken cancellationToken = default)
        {
            if (CleanupRecoveryDelay > TimeSpan.Zero) await Task.Delay(CleanupRecoveryDelay, cancellationToken);
            return CleanupRunsRoot is null ? null : CleanupRecoveries.Find(CleanupRunsRoot, appId);
        }
        public Task<IReadOnlyList<CleanupRecovery>> FindCleanupRecoveriesAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(CleanupRunsRoot is null ? (IReadOnlyList<CleanupRecovery>)[] : CleanupRecoveries.All(CleanupRunsRoot));
        public void MarkCleanupRestored(string rollbackManifestPath) => CleanupRecoveries.MarkRestored(rollbackManifestPath);
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
        public RemovalCleanupReview? FileRestore { get; set; }
        public Task<RemovalCleanupReview?> ReadLastFileCleanupAsync() => Task.FromResult(FileRestore);
        public Task<OptimizerResult<BulkRemovalJournal>> DismissRemovalAsync(string journal) { Dismissed.Add(journal); return DismissRemoval(journal); }
        public Task<OptimizerResult<BulkRemovalJournal>> ReconcileRemovalAsync(string journal) => ReconcileRemoval(journal);
        public Task<BulkRemovalReview> PreviewRemovalAsync(string[] appIds, bool includeAllAppxUsers = false) => throw new InvalidOperationException("Unexpected removal preview call.");
        public string? RemovalPointer { get; set; }
        public Task<OptimizerResult<BulkRemovalJournal>> ApplyRemovalAsync(BulkRemovalReview review, bool dependenciesReviewed, IProgress<BulkRemovalJournal> progress)
            => ServiceSteps.Pause is null ? throw new InvalidOperationException("Unexpected removal call.")
                : ServiceSteps.Then("removal", () => new OptimizerResult<BulkRemovalJournal> { Status = "success" }, () => RemovalPointer = review.JournalPath);
        public Task<OptimizerResult<BulkRemovalJournal>> CancelRemovalAsync(string journal) => throw new InvalidOperationException("Unexpected cancel call.");
        public Task<LeftoverDiscoveryResult> DiscoverLeftoversAsync(string queueJournalPath, string appId, CancellationToken cancellationToken) => throw new InvalidOperationException("Unexpected leftover scan.");
        public Task<CleanupPart> PreviewDeepCleanupAsync(string queueJournalPath, string appId, string[] itemIds, bool acceptKeyRecreation) => throw new InvalidOperationException("Unexpected cleanup preview.");
        public Task<CleanupBatchReview> PreviewCleanupBatchAsync(CleanupPart[] applications) => throw new InvalidOperationException("Unexpected cleanup batch preview.");
        public Task<CleanupBatchJournal> ApplyCleanupBatchAsync(CleanupBatchReview review, string? cancellationId, IProgress<CleanupBatchJournal> progress) => throw new InvalidOperationException("Unexpected cleanup apply.");
        public Task<CleanupBatchCancellation> CancelCleanupBatchAsync(string journalPath) => throw new InvalidOperationException("Unexpected cleanup cancel.");
        public Task<CleanupBatchJournal> RestoreCleanupBatchAsync(string journalPath) => throw new InvalidOperationException("Unexpected cleanup restore.");
        public Task<OptimizerResult<FileCleanupResult>> RestoreRemovedFilesAsync(RemovalCleanupReview review)
            => ServiceSteps.Then("earlier files restore", () =>
            {
                if (FileRestore != review) throw new InvalidOperationException("Unexpected file restore.");
                FileRestore = null;
                return new OptimizerResult<FileCleanupResult> { Status = "success" };
            });
        public string? CpuPointer { get; set; }
        public Task<OptimizerResult<CpuSetSnapshot>> ReadCpuSetsAsync(int processId, CancellationToken cancellationToken = default) => throw new InvalidOperationException("Unexpected CPU read.");
        public Task<CpuSetReview> PreviewCpuSetsAsync(int processId, uint[] ids, bool resetDefault) => throw new InvalidOperationException("Unexpected CPU preview.");
        public Task<bool> ReleaseEndedCpuSessionAsync(string journal) => Task.FromResult(false);
        public Task<OptimizerResult<CpuSetJournal>> ApplyCpuSetsAsync(CpuSetReview review)
        {
            CpuPointer = review.JournalPath;
            return ServiceSteps.Then("CPU selection", () => new OptimizerResult<CpuSetJournal> { Status = "success", Changed = true, RestoreAvailable = true });
        }
        public Task<OptimizerResult<CpuSetJournal>> RestoreCpuSetsAsync(string journal)
            => ServiceSteps.Then("CPU restore", () =>
            {
                if (CpuPointer != journal) throw new InvalidOperationException("Unexpected CPU restore.");
                CpuPointer = null;
                return new OptimizerResult<CpuSetJournal> { Status = "restored" };
            });
        public ProcessControlSnapshot? ProcessSnapshot { get; set; }
        public GameSessionEntry[] GameSessions { get; set; } = [];
        public TweakRecovery? WindowsRecovery { get; set; } = new(null, null, null);
        public string? FindLastJournal(string kind) => null;
        public Func<int, ProcessControlSnapshot>? ProcessReads { get; set; }
        public TaskCompletionSource? ProcessReadGate { get; set; }
        public Task<ProcessControlSnapshot> ReadProcessControlsAsync(int processId)
            => ProcessReadGate is { } gate ? GatedRead(gate.Task, processId) : Task.FromResult(ProcessRead(processId));
        private ProcessControlSnapshot ProcessRead(int processId) => ProcessReads?.Invoke(processId) ?? ProcessSnapshot ?? throw new InvalidOperationException("Process snapshot fixture is missing.");
        private async Task<ProcessControlSnapshot> GatedRead(Task gate, int processId) { await gate; return ProcessRead(processId); }
        public Func<Dictionary<string, JsonElement>, ProcessControlReview>? Review { get; set; }
        public Task<ProcessControlReview> PreviewControlsAsync(int processId, Dictionary<string, JsonElement> controls, CpuSelection? selection)
            => Review is { } review ? Task.FromResult(review(controls)) : throw new InvalidOperationException("Unexpected preview call.");
        public string? ProcessPointer { get; set; }
        public ProcessControlJournal? ControlsJournal { get; set; }
        public Task<ProcessControlJournal> ApplyControlsAsync(ProcessControlReview review)
        {
            if (ControlsJournal is not { } journal) throw new InvalidOperationException("Unexpected apply call.");
            ProcessPointer = review.JournalPath;
            return ServiceSteps.Then("process controls", () => journal);
        }
        public Task<ProcessControlJournal> RestoreControlsAsync(string journalPath)
            => ServiceSteps.Then("process controls restore", () =>
            {
                if (ProcessPointer != journalPath || ControlsJournal is not { } journal) throw new InvalidOperationException("Unexpected restore call.");
                ProcessPointer = null;
                journal.Status = "restored";
                return journal;
            });
        public Task<SavedProcessRule[]> ReadRulesAsync() => Task.FromResult(Array.Empty<SavedProcessRule>());
        public Task<PolicyWorkerStatus> ReadPolicyStatusAsync() => Task.FromResult(new PolicyWorkerStatus(null, false, null));
        public Action<SavedProcessRule>? RuleSaved { get; set; }
        public Task<SavedProcessRule> SaveRuleAsync(SavedProcessRule rule) => ServiceSteps.Then("rule save", () => { RuleSaved?.Invoke(rule); return rule; });
        public List<string> DeletedRules { get; } = new();
        public Action<string>? RuleDeleted { get; set; }
        public Task<JsonElement> DeleteRuleAsync(string ruleId) => ServiceSteps.Then("rule delete", () => { DeletedRules.Add(ruleId); RuleDeleted?.Invoke(ruleId); return JsonSerializer.SerializeToElement(new { }); });
        public Exception? PolicyWorkerError { get; set; }
        public Task<PolicyWorkerRegistration> PolicyWorkerAsync(string action)
            => ServiceSteps.Then("governor " + action, () => PolicyWorkerError is { } failure ? throw failure : new PolicyWorkerRegistration("fixture", false, false, false, false, false, 0, 0, false, "missing", null, new PolicyWorkerStatus(null, false, null)));
        public GovernorSnapshot Governor { get; set; } = new(new PolicySummary(false, "missing", false, 0, 0, null), new PolicyWorkerStatus(null, false, null), [], new());
        public Exception? GovernorError { get; set; }
        public Func<Task<GovernorSnapshot>>? GovernorRead { get; set; }
        public Task<GovernorSnapshot> ReadGovernorAsync() => GovernorRead is { } read ? read() : GovernorError is { } error ? Task.FromException<GovernorSnapshot>(error) : Task.FromResult(Governor);
        public Func<Task<PolicyHostState>> RetryRestore { get; set; } = () => throw new InvalidOperationException("Unexpected governor restore retry.");
        public int RetryCalls { get; private set; }
        public Task<PolicyHostState> RetryGovernorRestoreAsync() { RetryCalls++; return RetryRestore(); }
        public Task<GameSessionEntry[]> ReadGameSessionsAsync() => Task.FromResult(GameSessions);
        public Func<Dictionary<string, JsonElement>, GameSessionReview>? GameReview { get; set; }
        public bool? GameReviewScope { get; set; }
        public Task<GameSessionReview> PreviewGameSessionAsync(int launcherId, string gamePath, Dictionary<string, JsonElement> controls, bool acceptLauncherScope)
        {
            if (GameReview is not { } review) throw new InvalidOperationException("Unexpected game session preview.");
            GameReviewScope = acceptLauncherScope;
            return Task.FromResult(review(controls));
        }
        public void RequireNoLaunchProfile(ProtectedSessionPreview plan) { }
        public List<GameSessionReview> StartedSessions { get; } = new();
        public Task<ProtectedSessionStatus> StartGameSessionAsync(GameSessionReview review)
        {
            if (GameReview is null) throw new InvalidOperationException("Unexpected game session start.");
            StartedSessions.Add(review);
            return Task.FromResult(new ProtectedSessionStatus(null, true, null));
        }
        public List<GameSessionReview> SavedLaunchProfiles { get; } = new();
        public Task<LaunchProfileEntry> SaveLaunchProfileAsync(GameSessionReview review)
        {
            SavedLaunchProfiles.Add(review);
            return Task.FromResult(new LaunchProfileEntry(review.SessionRoot, review.Plan));
        }
        public LaunchProfileEntry[] LaunchProfiles { get; set; } = [];
        public Task<LaunchProfileEntry[]> ReadLaunchProfilesAsync() => Task.FromResult(LaunchProfiles);
        public Task<string?> DisableLaunchProfileAsync(string root) => throw new InvalidOperationException("Unexpected saved launch settings turn-off.");
        public Task<ProtectedSessionStatus> ReadGameSessionAsync(string sessionRoot) => Task.FromResult(GameSessions.FirstOrDefault(entry => entry.SessionRoot == sessionRoot)?.Worker ?? new ProtectedSessionStatus(null, null, "No fixture session."));
        public Task<ProtectedSessionStatus> StopGameSessionAsync(string sessionRoot) => throw new InvalidOperationException("Unexpected game session stop.");
        public Task<ProtectedSessionStatus> RecoverGameSessionAsync(string sessionRoot) => throw new InvalidOperationException("Unexpected game session recovery.");
        public Func<string, string, ProtectedSessionStatus>? GameSwitch { get; set; }
        public Task<ProtectedSessionStatus> SwitchGameCoresAsync(string sessionRoot, string affinityMask)
            => GameSwitch is { } change ? Task.FromResult(change(sessionRoot, affinityMask)) : throw new InvalidOperationException("Unexpected core switch.");
        public Task<TweakRecovery> ReadWindowsRecoveryAsync(bool fresh = false) => Task.FromResult(WindowsRecovery ?? throw new IOException("Controlled Windows recovery failure"));
        public static readonly TweakContext WindowsContext = new(new("fixture-pc", "fixture-user"), "fixture-store", 26200, "Professional");
        public Task<TweakCatalogResult> ReadWindowsTweakCatalogAsync(bool fresh = false) => Task.FromException<TweakCatalogResult>(new IOException("Controlled Windows catalog read failure"));
        public Task<TweakChoiceFile> ReadWindowsChoicesAsync() => Task.FromException<TweakChoiceFile>(new IOException("Controlled saved choices read failure"));
        public Task<TweakInspection> ReadWindowsTweaksAsync(bool fresh = false, bool streamed = true) => Task.FromException<TweakInspection>(new IOException("Controlled Windows settings read failure"));
        public event Action<TweakInspection, long>? WindowsTweaksPartial { add { } remove { } }
        public (TweakInspection Inspection, long Generation)? PendingWindowsTweaks => null;
        public Task<WindowsTweakReview> PreviewWindowsTweaksAsync(string profileId, TweakSelection[] selections) => throw new InvalidOperationException("Unexpected Windows settings preview.");
        public Task<WindowsTweakReview> PreviewOwnershipAsync(string path) => throw new InvalidOperationException("Unexpected ownership preview.");
        public Task<JsonElement> RecoverWindowsTweaksAsync(string hash) => throw new InvalidOperationException("Unexpected Windows settings recovery.");
        public Task<TweakChoiceFile> SaveWindowsChoicesAsync(TweakCatalog catalog, string profileId, TweakSelection[] selections, string? revision)
            => ServiceSteps.Then(selections.Length == 0 ? "remove saved choices" : "save choices", () => new TweakChoiceFile(1, WindowsContext.Owner, "fixture-revision", []));
        public Task<TweakApplyResult> ApplyWindowsTweaksAsync(WindowsTweakReview review, bool accepted)
            => ServiceSteps.Then("Windows helper", () => new TweakApplyResult(new TweakState { SchemaVersion = 1, Context = WindowsContext, Revision = "fixture-revision", Profiles = [], Held = [], CreatedKeys = [], History = [], Notices = [] }, true, false));
    }

    public sealed record WindowsTweakReview(TweakPlan Plan, string Path, string Hash);
}
