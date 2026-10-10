using System;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class SampleDataService
{
    private readonly BackendLocator _locator;

    private static readonly JsonSerializerOptions JsonOptions = JsonTolerance.CreateOptions();

    public SampleDataService(BackendLocator locator)
    {
        _locator = locator;
    }

    public bool SamplesAvailable => _locator.SamplesAvailable;
    public string? SamplesDirectory => _locator.SamplesDirectory;
    public string? CatalogsDirectory => _locator.CatalogsDirectory;

    public Task<ProductBackendStatus> GetProductStatusAsync() => LoadAsync<ProductBackendStatus>("product-backend-status.sample.json");
    public Task<DashboardStatus> GetDashboardAsync() => LoadAsync<DashboardStatus>("dashboard-backend-status.sample.json");
    public Task<ProcessInventory> GetProcessInventoryAsync() => LoadAsync<ProcessInventory>("process-inventory.sample.json");
    public Task<ProcessClassification> GetProcessClassificationAsync() => LoadAsync<ProcessClassification>("process-classification.sample.json");
    public Task<ProcessProfileEnvelope> GetProcessProfilePreviewAsync() => LoadAsync<ProcessProfileEnvelope>("process-profile-preview.sample.json");
    public Task<GameTuneSessionStatus> GetGameTuneSessionStatusAsync() => LoadAsync<GameTuneSessionStatus>("game-tune-session-status.sample.json");
    public Task<GameTuneRestorePreview> GetGameTuneRestorePreviewAsync() => LoadAsync<GameTuneRestorePreview>("game-tune-session-restore-preview.sample.json");
    public Task<ProcessGovernorSessionStatus> GetProcessGovernorSessionStatusAsync() => LoadAsync<ProcessGovernorSessionStatus>("process-governor-session-status.sample.json");
    public Task<InstalledAppInventory> GetInstalledAppsAsync() => LoadAsync<InstalledAppInventory>("installed-app-inventory.sample.json");
    public Task<AppClassificationResult> GetAppClassificationAsync() => LoadAsync<AppClassificationResult>("app-classification.sample.json");
    public Task<UninstallQueue> GetUninstallQueueAsync() => LoadAsync<UninstallQueue>("uninstall-queue.sample.json");
    public Task<OfficialUninstallPreview> GetOfficialUninstallPreviewAsync() => LoadAsync<OfficialUninstallPreview>("official-uninstall-preview.sample.json");
    public Task<LeftoverScan> GetLeftoverScanAsync() => LoadAsync<LeftoverScan>("leftover-scan-preview.sample.json");
    public Task<CleanupManifest> GetCleanupManifestAsync() => LoadAsync<CleanupManifest>("cleanup-deletion-manifest.sample.json");
    public Task<UninstallCleanupExecutionPlan> GetUninstallCleanupExecutionPlanAsync() => LoadAsync<UninstallCleanupExecutionPlan>("uninstall-cleanup-execution-plan.sample.json");
    public Task<DriverHardwareSummary> GetDriverHardwareAsync() => LoadAsync<DriverHardwareSummary>("driver-hardware-summary.sample.json");
    public Task<DriverRecommendationCatalog> GetDriverRecommendationsAsync() => LoadAsync<DriverRecommendationCatalog>("driver-recommendation-catalog.sample.json");
    public Task<NvidiaProfileCatalog> GetNvidiaProfilesAsync() => LoadAsync<NvidiaProfileCatalog>("nvidia-profile-catalog.sample.json");
    public Task<NvidiaNipPreview> GetNvidiaNipPreviewAsync() => LoadAsync<NvidiaNipPreview>("nvidia-nip-preview.sample.json");
    public Task<TelemetrySnapshot> GetTelemetryAsync() => LoadAsync<TelemetrySnapshot>("telemetry-snapshot.sample.json");
    public Task<StutterOptimizationPreview> GetStutterOptimizationPreviewAsync() => LoadAsync<StutterOptimizationPreview>("stutter-optimization-preview.sample.json");
    public Task<StutterOptimizationRanking> GetStutterOptimizationRankingAsync() => LoadCatalogAsync<StutterOptimizationRanking>("stutter-optimization-ranking.json");
    public Task<ReportSummary> GetReportSummaryAsync() => LoadAsync<ReportSummary>("report-summary.sample.json");

    private async Task<T> LoadAsync<T>(string sampleFileName)
    {
        var dir = _locator.SamplesDirectory;
        if (dir is null)
        {
            throw new SampleDataException(AppLog.MissingFiles);
        }

        var path = Path.Combine(dir, sampleFileName);
        if (!File.Exists(path))
        {
            AppLog.Write("data", "Missing " + path);
            throw new SampleDataException(AppLog.MissingFiles);
        }

        try
        {
            await using var stream = File.OpenRead(path);
            var result = await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions).ConfigureAwait(false);
            return result ?? throw new SampleDataException($"Sample file deserialized to null: {sampleFileName}");
        }
        catch (JsonException ex)
        {
            throw new SampleDataException($"Sample file is not valid JSON: {sampleFileName}", ex);
        }
    }

    private async Task<T> LoadCatalogAsync<T>(string catalogFileName)
    {
        var dir = _locator.CatalogsDirectory;
        if (dir is null)
        {
            throw new SampleDataException(AppLog.MissingFiles);
        }

        var path = Path.Combine(dir, catalogFileName);
        if (!File.Exists(path))
        {
            AppLog.Write("data", "Missing " + path);
            throw new SampleDataException(AppLog.MissingFiles);
        }

        try
        {
            await using var stream = File.OpenRead(path);
            var result = await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions).ConfigureAwait(false);
            return result ?? throw new SampleDataException($"Catalog file deserialized to null: {catalogFileName}");
        }
        catch (JsonException ex)
        {
            throw new SampleDataException($"Catalog file is not valid JSON: {catalogFileName}", ex);
        }
    }
}

public sealed class SampleDataException : Exception
{
    public SampleDataException(string message, Exception? inner = null) : base(message, inner)
    {
    }
}
