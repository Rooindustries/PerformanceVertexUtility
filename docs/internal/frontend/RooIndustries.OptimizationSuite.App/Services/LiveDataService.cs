using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record LiveDataResult<T>(T? Value, string? Error, string? RecoveryPath = null, string? RecoveryGeneration = null)
{
    public bool Stale { get; init; }
}
public sealed record NvidiaProfileRecovery(string ProfileId, string RollbackManifestPath, string ExportPath, string? Generation = null);

public sealed class LiveDataService
{
    private readonly BackendLocator _locator;
    private readonly string _recoveryDirectory;
    private readonly string _recoveryKey;
    private int _processRecoverySetAside;
    private static readonly ConcurrentDictionary<string, ProcessProfileRecovery> VolatileProcessRecovery = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, NvidiaProfileRecovery> VolatileNvidiaRecovery = new(StringComparer.OrdinalIgnoreCase);
    private string ProcessRecoveryPath => Path.Combine(_recoveryDirectory, "process-profile-recovery.json");
    private string ProcessOperationPath => Path.Combine(_recoveryDirectory, "process-profile-operation");
    private string ProcessGenerationPath => Path.Combine(_recoveryDirectory, "process-profile-operation-generation.json");
    private string ProcessApplyPath => Path.Combine(_recoveryDirectory, "process-profile-apply.json");
    private string ProcessBackupPath(string generation) => Path.Combine(_recoveryDirectory, "process-profile-backups", generation, "backup.json");
    private string NvidiaOperationPath => Path.Combine(_recoveryDirectory, "nvidia-profile-operation");
    private string NvidiaGenerationPath => Path.Combine(_recoveryDirectory, "nvidia-profile-operation-generation.json");
    private int _processApplyRecovered;
    public bool TakeProcessRecoverySetAsideNotice() => Interlocked.Exchange(ref _processRecoverySetAside, 0) != 0;
    public bool TakeProcessApplyRecoveredNotice() => Interlocked.Exchange(ref _processApplyRecovered, 0) != 0;
    public bool ProcessProfileRestorePending => File.Exists(ProcessRecoveryPath) || File.Exists(ProcessApplyPath) || VolatileProcessRecovery.ContainsKey(_recoveryKey);
    public bool ProcessProfileApplyFinishing => File.Exists(ProcessApplyPath) && !File.Exists(ProcessRecoveryPath) && !VolatileProcessRecovery.ContainsKey(_recoveryKey);
    public ProcessProfileRecovery? ProcessProfileRecovery
    {
        get
        {
            using var operation = TryOperationLease(ProcessOperationPath, "process profile", out _);
            try
            {
                var recovery = ReadProcessRecovery(discardInvalid: operation is not null);
                if (recovery is not null || operation is null || !File.Exists(ProcessApplyPath)) return recovery;
                var settled = SettleProcessApply(TimeSpan.Zero);
                if (settled.Error is not null) AppLog.Write("backend", settled.Error);
                if (settled.Recovery is not null) Interlocked.Exchange(ref _processApplyRecovered, 1);
                return settled.Recovery;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                AppLog.Write("backend", "The process recovery could not be read: " + error.Message);
                return null;
            }
        }
    }

    private ProcessProfileRecovery? ReadProcessRecovery(bool discardInvalid)
    {
        string? generation;
        try { generation = RooIndustries.Optimizer.OperationFiles.Read<RecoveryOperationGeneration>(ProcessGenerationPath).Id; }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException or JsonException or InvalidDataException or InvalidOperationException) { generation = null; }
        VolatileProcessRecovery.TryGetValue(_recoveryKey, out var current);
        var validCurrent = current is not null && current.ValidationError() is null && SameGeneration(current.Generation, generation);
        ProcessProfileRecovery? saved = null;
        string? invalid = null;
        try
        {
            saved = RooIndustries.Optimizer.OperationFiles.Read<ProcessProfileRecovery>(ProcessRecoveryPath);
            invalid = saved.ValidationError();
            if (invalid is null && !SameGeneration(saved.Generation, generation)) invalid = "The process recovery belongs to an older operation generation.";
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { }
        catch (Exception error) when (error is JsonException or InvalidDataException or InvalidOperationException) { invalid = "The process recovery reference is invalid: " + error.Message; }
        if (discardInvalid)
        {
            if (invalid is not null)
            {
                var archive = ProcessRecoveryPath + ".invalid-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssfffffffZ") + "-" + Guid.NewGuid().ToString("N");
                File.Move(ProcessRecoveryPath, archive);
                if (!validCurrent) Interlocked.Exchange(ref _processRecoverySetAside, 1);
                AppLog.Write("backend", invalid + " Kept the old reference at " + archive);
            }
            if (current is not null && !validCurrent) VolatileProcessRecovery.TryRemove(_recoveryKey, out _);
        }
        return validCurrent ? current : invalid is null ? saved : null;
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
    private readonly Lazy<OptimizerService> _operations;

    private readonly string? _operationsRoot;

    public LiveDataService(BackendLocator locator, string? recoveryDirectory = null, string? operationsRoot = null)
    {
        _locator = locator;
        _operationsRoot = operationsRoot;
        _operations = new(() => new OptimizerService(locator, operationsRoot));
        _recoveryDirectory = recoveryDirectory ?? Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "settings");
        _recoveryKey = Path.GetFullPath(_recoveryDirectory);
    }

    public string? ScriptsDirectory => _locator.RepoRoot is null
        ? null
        : Path.Combine(_locator.RepoRoot, "backend", "scripts");

    public bool ScriptsAvailable => ScriptsDirectory is not null && Directory.Exists(ScriptsDirectory);

    private string? _lastError;
    public string? LastError
    {
        get => _lastError;
        private set
        {
            _lastError = value;
            if (value is not (AppLog.Failed or AppLog.MissingFiles or AppLog.TimedOut)) AppLog.Write("backend", value);
        }
    }
    public string? RepoRoot => _locator.RepoRoot;

    private readonly SharedReads _shared = new();
    private static readonly TimeSpan LiveAge = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan HardwareAge = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ProcessSettle = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan AppsAge = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan StaleAge = TimeSpan.FromMinutes(5);
    private static readonly AsyncLocal<BackgroundPriority?> Background = new();
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, BackgroundPriority> _backgroundReads = new(StringComparer.Ordinal);

    public async Task<ProcessInventory?> GetProcessInventoryAsync(CancellationToken ct = default)
        => (await GetProcessInventoryResultAsync(ct)).Value;
    public Task<LiveDataResult<ProcessInventory>> GetProcessInventoryResultAsync(CancellationToken ct = default, bool fresh = false)
        => SharedResultAsync<ProcessInventory>("inventory", fresh ? TimeSpan.Zero : LiveAge, "Get-ProcessInventory.ps1", ct, inventory => inventory.Summary is not null && inventory.Processes is not null, settle: ProcessSettle);

    public async Task<ProcessClassification?> GetProcessClassificationAsync(CancellationToken ct = default)
        => (await GetProcessClassificationResultAsync(ct)).Value;
    public Task<LiveDataResult<ProcessClassification>> GetProcessClassificationResultAsync(CancellationToken ct = default, bool fresh = false, bool allowStale = false, bool background = false)
        => SharedResultAsync<ProcessClassification>("classification", fresh ? TimeSpan.Zero : allowStale ? StaleAge : LiveAge, "Get-ProcessClassification.ps1", ct, classification => classification.Processes is { Count: > 0 }, background: background, settle: ProcessSettle);

    private async Task<LiveDataResult<T>> SharedResultAsync<T>(string key, TimeSpan maxAge, string scriptFile, CancellationToken ct, Func<T, bool> complete, string extraArgs = "", bool background = false, TimeSpan settle = default) where T : class
    {
        if (ct.CanBeCanceled) return await RunResultAsync<T>(scriptFile, ct, extraArgs);
        if (!background && _backgroundReads.TryGetValue(key, out var running)) running.Raise();
        var priority = background ? new BackgroundPriority() : null;
        if (priority is not null) _backgroundReads[key] = priority;
        (LiveDataResult<T>? value, TimeSpan age) read;
        try
        {
            read = await _shared.ReadAsync(key, maxAge, () => { Background.Value = priority; return RunResultAsync<T>(scriptFile, CancellationToken.None, extraArgs); },
                result => result.Value is not null && result.Error is null && complete(result.Value), settle);
        }
        finally { if (priority is not null) _backgroundReads.TryRemove(new(key, priority)); }
        var (value, age) = read;
        var result = value ?? new LiveDataResult<T>(null, AppLog.Failed);
        if (result.Error is not null) LastError = result.Error;
        return age > LiveAge && result.Value is not null ? result with { Stale = true } : result;
    }

    public Task<LiveDataResult<string>> GetBackgroundPlacementResultAsync(CancellationToken ct = default)
        => RunBackendScriptResultAsync("Get-BackgroundPlacement.ps1", ct);

    public Task<LiveDataResult<string>> PreviewProcessProfileResultAsync(CancellationToken ct = default, string preset = "lower")
        => RunBackendScriptResultAsync("Preview-ProcessProfile.ps1", ct, "-Preset " + preset);

    private static Task<IDisposable> EnterGovernorGateAsync()
    {
        var entered = new TaskCompletionSource<IDisposable>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new ManualResetEventSlim();
        var owner = new Thread(() =>
        {
            IDisposable gate;
            var clock = Stopwatch.StartNew();
            while (true)
            {
                try { gate = RooIndustries.Optimizer.ProcessPolicyStore.Gate(); break; }
                catch (UnauthorizedAccessException) when (clock.Elapsed < TimeSpan.FromSeconds(30)) { Thread.Sleep(100); }
                catch (UnauthorizedAccessException) { entered.TrySetException(new TimeoutException("Another rule or game session change is still running. Try again in a moment.")); return; }
                catch (Exception error) { entered.TrySetException(error); return; }
            }
            entered.TrySetResult(new GateRelease(release));
            release.Wait();
            gate.Dispose();
            release.Dispose();
        }) { IsBackground = true, Name = "Governor gate" };
        owner.Start();
        return entered.Task;
    }

    private sealed class GateRelease(ManualResetEventSlim release) : IDisposable
    {
        private int _released;
        public void Dispose() { if (Interlocked.Exchange(ref _released, 1) == 0) release.Set(); }
    }

    public async Task<LiveDataResult<string>> ApplyProcessProfileResultAsync(CancellationToken ct = default, string preset = "lower")
    {
        using var operation = TryOperationLease(ProcessOperationPath, "process profile", out var leaseError);
        if (operation is null) return new(null, leaseError);
        try
        {
            if (ReadProcessRecovery(discardInvalid: true) is not null || File.Exists(ProcessRecoveryPath))
                return new(null, "Restore the last change first");
            if (File.Exists(ProcessApplyPath))
            {
                if (SettleProcessApply(TimeSpan.Zero).Recovery is not null) return new(null, "Restore the last change first");
                if (File.Exists(ProcessApplyPath)) return new(null, "The last apply is still finishing. Try again in a moment.");
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new(null, "The last process recovery could not be checked: " + error.Message);
        }
        IDisposable gate;
        try { gate = await EnterGovernorGateAsync().ConfigureAwait(false); }
        catch (Exception error) { return new(null, error.Message); }
        using var governorGate = gate;
        var previousGeneration = ReadGeneration(ProcessGenerationPath);
        var generation = Guid.NewGuid().ToString("N");
        if (!TryWriteGeneration(ProcessGenerationPath, generation, "process profile", out var generationError))
            return new(null, generationError);
        try { RooIndustries.Optimizer.OperationFiles.Write(ProcessApplyPath, new ProcessProfileApplyJournal(ProcessBackupPath(generation), generation)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new(null, "The process apply journal could not be saved before dispatch: " + error.Message);
        }
        var result = await RunBackendScriptResultAsync(
            "Apply-ProcessProfile.ps1",
            ct,
            "-ConfirmApply -Preset " + preset + " -RecoveryJournal " + QuotePowerShell(ProcessApplyPath)).ConfigureAwait(false);
        (ProcessProfileRecovery? Recovery, string? Error) settled;
        try { settled = SettleProcessApply(TimeSpan.FromSeconds(15)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            settled = (null, "The process apply could not be checked for a restore point: " + error.Message);
        }
        if (settled.Recovery is null)
        {
            if (settled.Error is null && File.Exists(ProcessApplyPath)) settled.Error = "The apply is still finishing. Restore will be offered once it's done.";
            if (settled.Error is not null) return result with { Error = AppendError(result.Error, settled.Error) };
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
        return result with
        {
            Error = settled.Error is null ? result.Error : AppendError(result.Error, settled.Error),
            RecoveryPath = settled.Recovery.Path,
            RecoveryGeneration = settled.Recovery.Generation,
        };
    }

    public async Task<LiveDataResult<string>> RestoreProcessProfileResultAsync(ProcessProfileRecovery recovery, CancellationToken ct = default)
    {
        try { await EarlierVersionConsent.RequireAsync(recovery.Path).ConfigureAwait(false); }
        catch (RooIndustries.Optimizer.EarlierVersionException error) { return new(null, error.Message); }
        using var operation = TryOperationLease(ProcessOperationPath, "process profile", out var leaseError);
        if (operation is null) return new(null, leaseError);
        ProcessProfileRecovery? current;
        try { current = ReadProcessRecovery(discardInvalid: false); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return new(null, "The process recovery could not be read: " + error.Message); }
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

    public async Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken ct = default, bool fresh = false)
        => (await GetDriverHardwareResultAsync(ct, fresh)).Value;
    public Task<LiveDataResult<DriverHardwareSummary>> GetDriverHardwareResultAsync(CancellationToken ct = default, bool fresh = false)
        => SharedResultAsync<DriverHardwareSummary>("hardware", fresh ? TimeSpan.Zero : HardwareAge, "Get-DriverHardwareSummary.ps1", ct, hardware => hardware.Machine is not null && hardware.Memory is not null && hardware.Cpu is not null && hardware.Gpus is { Count: > 0 });

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
        try { await EarlierVersionConsent.RequireAsync(recovery.RollbackManifestPath).ConfigureAwait(false); }
        catch (RooIndustries.Optimizer.EarlierVersionException error) { return new(null, error.Message); }
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

    public async Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken ct = default, bool includeAllAppxUsers = false, bool fresh = false, bool background = false)
        => (await SharedResultAsync<InstalledAppInventory>("apps:" + includeAllAppxUsers, fresh ? TimeSpan.FromSeconds(2) : AppsAge, "Get-InstalledAppInventory.ps1", ct, apps => apps.Apps is { Count: > 0 } && apps.Complete != false, includeAllAppxUsers ? "-IncludeAllAppxUsers" : "", background)).Value;

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
                    await _operations.Value.EnsureStorageAsync().ConfigureAwait(false),
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
            if (_operationsRoot is not null) args += " -DataRoot " + QuotePowerShell(Path.GetDirectoryName(Path.GetFullPath(_operationsRoot))!);

            if (!string.IsNullOrWhiteSpace(officialExecutable))
            {
                args += " -AllowedOfficialExecutablePath " + QuotePowerShell(officialExecutable);
                args += " -OfficialRunnerWorkingDirectory " + QuotePowerShell(runRoot);
                args += " -TimeoutSeconds 600";
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

    public async Task<LiveDataResult<string>> RestoreUninstallCleanupResultAsync(string rollbackManifestPath, CancellationToken ct = default)
    {
        var runs = Path.Combine(await _operations.Value.EnsureStorageAsync().ConfigureAwait(false), "cleanup-runs") + Path.DirectorySeparatorChar;
        try
        {
            if (!Path.GetFullPath(rollbackManifestPath).StartsWith(runs, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException(RooIndustries.Optimizer.OperationsFolder.EarlierBackup(rollbackManifestPath));
            RooIndustries.Optimizer.PolicyRootSecurity.RequireWrittenAfterProtection(rollbackManifestPath, RooIndustries.Optimizer.OperationsFolder.EarlierBackup(rollbackManifestPath));
        }
        catch (InvalidDataException error)
        {
            LastError = error.Message;
            return new(null, error.Message);
        }
        return await RunBackendScriptResultAsync(
            "Restore-UninstallCleanupExecution.ps1",
            ct,
            "-RollbackManifestPath " + QuotePowerShell(rollbackManifestPath) + " -ConfirmApply -AllowDisposableFixtureApply -AllowRealSystemExecution -UserApproved").ConfigureAwait(false);
    }
    public async Task<string?> RestoreUninstallCleanupTextAsync(string rollbackManifestPath, CancellationToken ct = default)
        => (await RestoreUninstallCleanupResultAsync(rollbackManifestPath, ct)).Value;

    public async Task<string?> FindCleanupRecoveryAsync(string appId, CancellationToken ct = default)
    {
        var runs = Path.Combine(await _operations.Value.EnsureStorageAsync().ConfigureAwait(false), "cleanup-runs");
        return await Task.Run(() => CleanupRecoveries.Find(runs, appId, RooIndustries.Optimizer.PolicyRootSecurity.WrittenAfterProtection), ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<CleanupRecovery>> FindCleanupRecoveriesAsync(CancellationToken ct = default)
    {
        var runs = Path.Combine(await _operations.Value.EnsureStorageAsync().ConfigureAwait(false), "cleanup-runs");
        return await Task.Run(() => CleanupRecoveries.All(runs, RooIndustries.Optimizer.PolicyRootSecurity.WrittenAfterProtection), ct).ConfigureAwait(false);
    }

    public void MarkCleanupRestored(string rollbackManifestPath) => CleanupRecoveries.MarkRestored(rollbackManifestPath);

    public async Task<LiveDataResult<string>> RunBackendScriptResultAsync(string scriptFile, CancellationToken ct = default, string extraArgs = "")
    {
        var dir = ScriptsDirectory;
        if (dir is null)
        {
            AppLog.Write("backend", "Repo root not resolved.");
            var error = AppLog.MissingFiles;
            LastError = error;
            return new(null, error);
        }

        var scriptPath = Path.Combine(dir, scriptFile);
        if (!File.Exists(scriptPath))
        {
            AppLog.Write("backend", "Script not found: " + scriptPath);
            var error = AppLog.MissingFiles;
            LastError = error;
            return new(null, error);
        }

        try
        {
            var result = await RunScriptResultAsync(scriptPath, extraArgs, ct).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(result.Value))
            {
                if (result.Error is null) AppLog.Write("backend", "Empty output from " + scriptFile);
                var error = result.Error ?? AppLog.Failed;
                LastError = error;
                return new(null, error);
            }
            LastError = result.Error;
            return result;
        }
        catch (Exception ex)
        {
            AppLog.Write("backend", scriptFile + ": " + ex);
            var error = AppLog.Failed;
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
            AppLog.Write("backend", "No data returned from " + scriptFile);
            var error = AppLog.Failed;
            LastError = error;
            return new(null, error);
        }
        catch (Exception ex)
        {
            AppLog.Write("backend", scriptFile + ": " + ex);
            var error = AppLog.Failed;
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
            AppLog.Write("backend", "The backend returned no operation data.");
            const string error = AppLog.Failed;
            LastError = error;
            return new(null, error);
        }
        catch (Exception error)
        {
            AppLog.Write("backend", error.ToString());
            const string message = AppLog.Failed;
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
        if (ReadProcessRecovery(discardInvalid: false) == recovery && File.Exists(ProcessRecoveryPath)) File.Delete(ProcessRecoveryPath);
        if (File.Exists(ProcessApplyPath))
        {
            try { if (PathsEqual(RooIndustries.Optimizer.OperationFiles.Read<ProcessProfileApplyJournal>(ProcessApplyPath).Path, recovery.Path)) File.Delete(ProcessApplyPath); }
            catch (Exception error) when (error is JsonException or InvalidDataException or InvalidOperationException) { }
        }
        if (File.Exists(ProcessGenerationPath)) File.Delete(ProcessGenerationPath);
        if (VolatileProcessRecovery.TryGetValue(_recoveryKey, out var current) && current == recovery)
            VolatileProcessRecovery.TryRemove(_recoveryKey, out _);
    }

    private (ProcessProfileRecovery? Recovery, string? Error) SettleProcessApply(TimeSpan wait)
    {
        if (!File.Exists(ProcessApplyPath)) return (null, null);
        using var journalLock = TryProcessApplyLock(wait);
        if (journalLock is null) return (null, null);
        ProcessProfileApplyJournal journal;
        try { journal = RooIndustries.Optimizer.OperationFiles.Read<ProcessProfileApplyJournal>(ProcessApplyPath); }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return (null, null); }
        catch (Exception error) when (error is JsonException or InvalidDataException or InvalidOperationException)
        {
            return SetProcessApplyAside("The process apply journal is invalid: " + error.Message);
        }
        if (!Guid.TryParseExact(journal.Generation, "N", out _) || !PathsEqual(journal.Path, ProcessBackupPath(journal.Generation)))
            return SetProcessApplyAside("The process apply journal names a backup outside its folder.");
        if (!File.Exists(journal.Path))
        {
            var folder = Path.GetDirectoryName(journal.Path)!;
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
            File.Delete(ProcessApplyPath);
            return (null, null);
        }
        ProcessProfileRecovery recovery;
        try { recovery = ProcessProfileRecovery.FromBackup(journal.Path, journal.Generation); }
        catch (JsonException error) { return SetProcessApplyAside("The process backup contains invalid JSON: " + error.Message); }
        if (recovery.ValidationError() is { } invalid) return SetProcessApplyAside(invalid);
        if (File.Exists(ProcessRecoveryPath))
        {
            ProcessProfileRecovery? saved = null;
            try { saved = RooIndustries.Optimizer.OperationFiles.Read<ProcessProfileRecovery>(ProcessRecoveryPath); }
            catch (Exception error) when (error is JsonException or InvalidDataException or InvalidOperationException) { }
            if (PathsEqual(saved?.Path, journal.Path)) File.Delete(ProcessApplyPath);
            return (null, null);
        }
        if (!TryWriteGeneration(ProcessGenerationPath, journal.Generation, "process profile", out var generationError)) return (null, generationError);
        VolatileProcessRecovery[_recoveryKey] = recovery;
        try { RooIndustries.Optimizer.OperationFiles.Write(ProcessRecoveryPath, recovery); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return (recovery, "The process backup exists, but its recovery reference could not be saved: " + error.Message);
        }
        File.Delete(ProcessApplyPath);
        return (recovery, null);
    }

    private (ProcessProfileRecovery? Recovery, string? Error) SetProcessApplyAside(string reason)
    {
        var archive = ProcessApplyPath + ".invalid-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssfffffffZ") + "-" + Guid.NewGuid().ToString("N");
        File.Move(ProcessApplyPath, archive);
        Interlocked.Exchange(ref _processRecoverySetAside, 1);
        AppLog.Write("backend", reason + " Kept the old journal at " + archive);
        return (null, null);
    }

    private FileStream? TryProcessApplyLock(TimeSpan wait)
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            try { return RooIndustries.Optimizer.OperationFiles.Lock(ProcessApplyPath); }
            catch (Exception error) when (ProcessApplyRunning(error) && clock.Elapsed < wait) { Thread.Sleep(100); }
            catch (Exception error) when (ProcessApplyRunning(error)) { return null; }
        }
    }

    private static bool ProcessApplyRunning(Exception error)
        => error is UnauthorizedAccessException || error is IOException && (error.HResult & 0xffff) is 32 or 33;

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
        var dir = Path.Combine(await _operations.Value.EnsureStorageAsync().ConfigureAwait(false), "cleanup-inputs-" + Guid.NewGuid().ToString("N"));
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
        var elapsed = Stopwatch.StartNew();
        var outcome = "failed";
        try
        {
            var result = await RunScriptCoreAsync(scriptPath, extraArgs, ct).ConfigureAwait(false);
            outcome = result.Error is null ? "completed" : result.Error == AppLog.TimedOut ? "timed out" : "failed";
            return result;
        }
        finally { AppLog.Timing(Path.GetFileName(scriptPath), elapsed, outcome); }
    }

    private async Task<LiveDataResult<string>> RunScriptCoreAsync(string scriptPath, string extraArgs, CancellationToken ct)
    {
        using var change = extraArgs.Contains("-ConfirmApply", StringComparison.Ordinal) ? DataGeneration.BeginChange() : null;
        var tail = string.IsNullOrWhiteSpace(extraArgs) ? string.Empty : " " + extraArgs;
        var arguments =
            $"-NoProfile -ExecutionPolicy Bypass -Command \"{RooIndustries.Optimizer.RuntimeEnvironment.PowerShellPrelude}[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '{scriptPath}'{tail}\"";

        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = _locator.RepoRoot ?? Environment.CurrentDirectory,
        };
        RooIndustries.Optimizer.RuntimeEnvironment.Apply(psi);

        using var process = new Process { StartInfo = psi };
        if (!process.Start())
        {
            AppLog.Write("backend", "Could not start " + Path.GetFileName(scriptPath));
            return new(null, AppLog.Failed);
        }
        Background.Value?.Register(process);

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (BackendScriptPolicy.Timeout(scriptPath) is { } limit) timeout.CancelAfter(limit);

        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process, BackendScriptPolicy.StopWholeTree(scriptPath));
            AppLog.Write("backend", "Timed out running " + Path.GetFileName(scriptPath));
            return new(null, AppLog.TimedOut);
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            AppLog.Write("backend", Path.GetFileName(scriptPath) + " exited with code " + process.ExitCode);
            var plain = AppLog.Explain("backend", stderr, "");
            var code = " (code " + process.ExitCode + ")";
            return new(stdout, plain.Length == 0 ? "Something went wrong" + code + ". Details were saved to the app log (Settings, Open logs folder)." : plain + code);
        }
        if (string.IsNullOrWhiteSpace(stdout) && !string.IsNullOrWhiteSpace(stderr))
        {
            AppLog.Write("backend", Path.GetFileName(scriptPath) + " wrote only errors.");
            return new(null, AppLog.Explain("backend", stderr, AppLog.Failed));
        }

        return new(stdout, null);
    }

    private static void TryKill(Process process, bool entireTree = true)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: entireTree);
            }
        }
        catch
        {
        }
    }
}
