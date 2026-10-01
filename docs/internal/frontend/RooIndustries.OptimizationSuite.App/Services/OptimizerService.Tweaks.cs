using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record WindowsTweakReview(TweakPlan Plan, string Path, string Hash);
public sealed record WindowsRestorePointReview(RestorePointPreview Plan, string Path, string Hash, string JournalPath);

public sealed partial class OptimizerService
{
    private readonly TweakChoiceStore _windowsChoices = new(Path.Combine(BrandCompatibility.LocalDataRoot, "settings", "windows-choices.json"));
    public Task<TweakChoiceFile> ReadWindowsChoicesAsync() => Task.Run(_windowsChoices.Read);
    public Task<TweakChoiceFile> SaveWindowsChoicesAsync(TweakCatalog catalog, string profileId, TweakSelection[] selections, string? revision)
        => Task.Run(() => { using var change = DataGeneration.BeginChange(); return _windowsChoices.Save(catalog, profileId, selections, revision); });
    private readonly SharedReads _tweakReads = new();
    private static readonly TimeSpan TweakStateAge = TimeSpan.FromSeconds(60);
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, BackgroundPriority> _backgroundTweakReads = new(StringComparer.Ordinal);
    private async Task<T?> TweakReadAsync<T>(string key, TimeSpan maxAge, bool background, Func<Task<T>> read, Func<T, bool>? good = null) where T : class
    {
        if (!background && _backgroundTweakReads.TryGetValue(key, out var running)) running.Raise();
        var priority = background ? new BackgroundPriority() : null;
        if (priority is not null) _backgroundTweakReads[key] = priority;
        try { return await _tweakReads.GetAsync(key, maxAge, () => { HostPriority.Value = priority; return read(); }, good).ConfigureAwait(false); }
        finally { if (priority is not null) _backgroundTweakReads.TryRemove(new(key, priority)); }
    }
    public async Task<TweakCatalogResult> ReadWindowsTweakCatalogAsync(bool fresh = false, bool background = false)
        => (await TweakReadAsync("catalog", fresh ? TimeSpan.Zero : TimeSpan.FromMinutes(30), background, () => RunCoreAsync<TweakCatalogResult>("tweak-catalog", new(), timeout: TimeSpan.FromMinutes(2))))!;
    public async Task<TweakRecovery> ReadWindowsRecoveryAsync(bool fresh = false, bool background = false)
        => (await TweakReadAsync("recovery", fresh ? TimeSpan.Zero : TweakStateAge, background, () => RunCoreAsync<TweakRecovery>("tweak-recovery", new(), timeout: TimeSpan.FromMinutes(2))))!;
    public event Action<TweakInspection, long>? WindowsTweaksPartial;
    private sealed record PartialTweaks(TweakInspection Inspection, long Generation);
    private PartialTweaks? _pendingTweaks;
    public (TweakInspection Inspection, long Generation)? PendingWindowsTweaks => Volatile.Read(ref _pendingTweaks) is { } pending && DataGeneration.IsCurrent(pending.Generation) ? (pending.Inspection, pending.Generation) : null;
    public void PrefetchWindowsTweaks()
    {
        foreach (var read in new Task[] { ReadWindowsTweakCatalogAsync(background: true), ReadWindowsRecoveryAsync(background: true), ReadWindowsTweaksAsync(background: true) })
            _ = read.ContinueWith(task => task.Exception, TaskScheduler.Default);
    }
    private async Task<TweakInspection> ReadStatusAsync(bool streamed)
    {
        var generation = DataGeneration.Snapshot();
        PartialTweaks? mine = null;
        try
        {
            return await RunCoreAsync<TweakInspection>("tweak-status", new() { ["partialStatus"] = streamed }, timeout: TimeSpan.FromMinutes(10), partial: !streamed ? null : bytes =>
            {
                if (!DataGeneration.IsCurrent(generation)) return;
                using var document = JsonDocument.Parse(bytes);
                var inspection = document.RootElement.GetProperty("data").Deserialize<TweakInspection>(OperationFiles.Json) ?? throw new InvalidDataException("The partial status is empty.");
                mine = new(inspection, generation);
                Volatile.Write(ref _pendingTweaks, mine);
                WindowsTweaksPartial?.Invoke(inspection, generation);
            }).ConfigureAwait(false);
        }
        finally { if (mine is not null) Interlocked.CompareExchange(ref _pendingTweaks, null, mine); }
    }
    public Task<System.Text.Json.JsonElement> RecoverWindowsTweaksAsync(string reviewHash) => RunCoreAsync<System.Text.Json.JsonElement>("tweak-recover", new() { ["reviewHash"] = reviewHash, ["confirm"] = true });
    public async Task<TweakInspection> ReadWindowsTweaksAsync(bool fresh = false, bool background = false, bool streamed = true)
        => (await TweakReadAsync("status", fresh ? TimeSpan.Zero : TweakStateAge, background, () => ReadStatusAsync(streamed), inspection => !TweakEngine.HasTransientErrors(inspection)))!;
    public async Task<WindowsTweakReview> PreviewWindowsTweaksAsync(string profileId, TweakSelection[] selections)
    {
        var directory = await NewOperationDirectoryAsync("windows-settings");
        var path = System.IO.Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<TweakPlan>("tweak-preview", new() { ["profileId"] = profileId, ["selections"] = selections, ["outputPath"] = path }, timeout: TweakPreviewTimeout);
        if (plan.ProfileId != profileId) throw new InvalidDataException("The review did not match your choices. Review them again.");
        return new(plan, path, Hash(path));
    }
    public TimeSpan TweakPreviewTimeout { get; set; } = TimeSpan.FromMinutes(3);
    public TimeSpan TweakApplyTimeout { get; set; } = TimeSpan.FromMinutes(10);
    private static bool RecoverableByJournal(TweakPlan plan) => plan.Controls is null || plan.Controls.Changes.All(change => change.Before.Address.Kind is "service" or "scheduled-task");
    public Task<TweakApplyResult> ApplyWindowsTweaksAsync(WindowsTweakReview review, bool acceptDataLoss = false)
    {
        if (!string.Equals(Hash(review.Path), review.Hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed settings changed. Review them again.");
        return RunCoreAsync<TweakApplyResult>(review.Plan.Selections.Length == 0 ? "tweak-restore" : "tweak-apply",
            new() { ["previewPath"] = review.Path, ["reviewHash"] = review.Hash, ["confirm"] = true, ["acceptDataLoss"] = acceptDataLoss }, timeout: RecoverableByJournal(review.Plan) ? TweakApplyTimeout : null);
    }
    public Task<TweakCatalogResult> ImportWindowsSettingsAsync(string path) => RunCoreAsync<TweakCatalogResult>("tweak-custom-import", new() { ["customSettingsPath"] = path, ["confirm"] = true });
    public async Task<WindowsTweakReview> PreviewOwnershipAsync(string selectedPath)
    {
        using var change = DataGeneration.BeginChange();
        var directory = await NewOperationDirectoryAsync("file-permissions"); var path = Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<TweakPlan>("tweak-ownership-preview", new() { ["selectedFilePath"] = selectedPath, ["outputPath"] = path });
        return new(plan, path, Hash(path));
    }
    public Task<WindowsRestorePoint[]> ReadRestorePointsAsync() => RunCoreAsync<WindowsRestorePoint[]>("restore-point-list", new());
    public async Task<WindowsRestorePointReview> PreviewRestorePointAsync(bool allowFresh)
    {
        var directory = await NewOperationDirectoryAsync("restore-point"); var path = Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<RestorePointPreview>("restore-point-preview", new() { ["allowFreshRestorePoint"] = allowFresh, ["outputPath"] = path });
        return new(plan, path, Hash(path), Path.Combine(directory, "journal.json"));
    }
    public Task<RestorePointResult> CreateRestorePointAsync(WindowsRestorePointReview review) => RunCoreAsync<RestorePointResult>("restore-point-create", new() { ["previewPath"] = review.Path, ["reviewHash"] = review.Hash, ["journalPath"] = review.JournalPath, ["confirm"] = true });
}
