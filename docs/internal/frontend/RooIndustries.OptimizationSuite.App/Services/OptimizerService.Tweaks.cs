using System;
using System.Collections.Generic;
using System.IO;
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
        => Task.Run(() => _windowsChoices.Save(catalog, profileId, selections, revision));
    public Task<TweakCatalogResult> ReadWindowsTweakCatalogAsync() => RunCoreAsync<TweakCatalogResult>("tweak-catalog", new());
    public Task<TweakRecovery> ReadWindowsRecoveryAsync() => RunCoreAsync<TweakRecovery>("tweak-recovery", new());
    public Task<System.Text.Json.JsonElement> RecoverWindowsTweaksAsync(string reviewHash) => RunCoreAsync<System.Text.Json.JsonElement>("tweak-recover", new() { ["reviewHash"] = reviewHash, ["confirm"] = true });
    public Task<TweakInspection> ReadWindowsTweaksAsync() => RunCoreAsync<TweakInspection>("tweak-status", new());
    public async Task<WindowsTweakReview> PreviewWindowsTweaksAsync(string profileId, TweakSelection[] selections)
    {
        var directory = NewOperationDirectory("windows-settings");
        var path = System.IO.Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<TweakPlan>("tweak-preview", new() { ["profileId"] = profileId, ["selections"] = selections, ["outputPath"] = path });
        if (plan.ProfileId != profileId) throw new InvalidDataException("The backend returned a review for a different profile.");
        return new(plan, path, Hash(path));
    }
    public Task<TweakApplyResult> ApplyWindowsTweaksAsync(WindowsTweakReview review, bool acceptDataLoss = false)
    {
        if (!string.Equals(Hash(review.Path), review.Hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed settings changed. Review them again.");
        return RunCoreAsync<TweakApplyResult>(review.Plan.Selections.Length == 0 ? "tweak-restore" : "tweak-apply",
            new() { ["previewPath"] = review.Path, ["reviewHash"] = review.Hash, ["confirm"] = true, ["acceptDataLoss"] = acceptDataLoss });
    }
    public Task<TweakCatalogResult> ImportWindowsSettingsAsync(string path) => RunCoreAsync<TweakCatalogResult>("tweak-custom-import", new() { ["customSettingsPath"] = path, ["confirm"] = true });
    public async Task<WindowsTweakReview> PreviewOwnershipAsync(string selectedPath)
    {
        var directory = NewOperationDirectory("file-permissions"); var path = Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<TweakPlan>("tweak-ownership-preview", new() { ["selectedFilePath"] = selectedPath, ["outputPath"] = path });
        return new(plan, path, Hash(path));
    }
    public Task<WindowsRestorePoint[]> ReadRestorePointsAsync() => RunCoreAsync<WindowsRestorePoint[]>("restore-point-list", new());
    public async Task<WindowsRestorePointReview> PreviewRestorePointAsync(bool allowFresh)
    {
        var directory = NewOperationDirectory("restore-point"); var path = Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<RestorePointPreview>("restore-point-preview", new() { ["allowFreshRestorePoint"] = allowFresh, ["outputPath"] = path });
        return new(plan, path, Hash(path), Path.Combine(directory, "journal.json"));
    }
    public Task<RestorePointResult> CreateRestorePointAsync(WindowsRestorePointReview review) => RunCoreAsync<RestorePointResult>("restore-point-create", new() { ["previewPath"] = review.Path, ["reviewHash"] = review.Hash, ["journalPath"] = review.JournalPath, ["confirm"] = true });
}
