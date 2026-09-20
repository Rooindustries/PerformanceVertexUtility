using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Helpers;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class MonitoringViewModel : PageViewModelBase
{
    [ObservableProperty] private string _subtitle = "Timer settings, shader cache review, and performance readings.";
    [ObservableProperty] private string _stutterActionTitle = "Timer and shader cache";
    [ObservableProperty] private string _stutterActionDetail = "Review the settings before running a temporary timer change or checking the shader cache.";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRunStutterAction))]
    [NotifyPropertyChangedFor(nameof(CanRunTimerSession))]
    [NotifyPropertyChangedFor(nameof(CanPrepareShaderCache))]
    [NotifyPropertyChangedFor(nameof(CanRestoreShaderCache))]
    private bool _stutterBusy;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StutterGateSummary))]
    [NotifyPropertyChangedFor(nameof(CanRunTimerSession))]
    private bool _latencySessionApproved;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StutterGateSummary))]
    [NotifyPropertyChangedFor(nameof(CanPrepareShaderCache))]
    private bool _shaderCacheApproved;
    [ObservableProperty] private string _shaderRestoreHint = "Restore becomes available after a cache backup is saved.";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanRestoreShaderCache))]
    private bool _shaderRestoreAvailable;

    private string? _lastShaderRollbackPath;

    public ObservableCollection<MetricTile> LiveTiles { get; } = new();
    public ObservableCollection<MetricTile> PendingTiles { get; } = new();
    public ObservableCollection<StatusLine> Sensors { get; } = new();
    public bool CanRunStutterAction => !StutterBusy;
    public bool CanRunTimerSession => !StutterBusy && LatencySessionApproved;
    public bool CanPrepareShaderCache => !StutterBusy && ShaderCacheApproved;
    public bool CanRestoreShaderCache => !StutterBusy && ShaderRestoreAvailable;
    public string StutterGateSummary => LatencySessionApproved && ShaderCacheApproved
            ? "Ready: timer and cache cleanup are approved."
            : "Select the action you want to allow.";

    protected override async Task LoadCoreAsync()
    {
        var inventory = await App.Live.GetProcessInventoryAsync();
        var hardware = await App.Live.GetDriverHardwareAsync();
        var summary = inventory?.Summary;
        if (summary is null)
        {
            ErrorMessage = "We couldn't read this PC yet. Close and reopen to try again.";
            return;
        }

        var total = hardware?.Memory?.TotalPhysicalBytes ?? 0;
        var percent = MemoryUsage.UsedPercent(total, summary.AvailableMemoryBytes);
        var used = percent is not null ? Format.Bytes(total - summary.AvailableMemoryBytes!.Value) : "Unavailable";
        var usedPct = percent is not null ? percent + "% of physical memory" : "physical memory reading missing";
        var gpu = hardware?.Gpus?.Count > 0 ? hardware.Gpus[0].Name : "graphics";

        LiveTiles.Clear();
        LiveTiles.Add(new MetricTile("Processes", summary.ProcessCount.ToString(CultureInfo.InvariantCulture),
            summary.BackgroundProcessCount + " background"));
        LiveTiles.Add(new MetricTile("Available memory", summary.AvailableMemoryBytes is >= 0 ? Format.Bytes(summary.AvailableMemoryBytes.Value) : "Unavailable", "available now"));
        LiveTiles.Add(new MetricTile("Memory in use", used, usedPct));
        LiveTiles.Add(new MetricTile("Committed memory", Format.Bytes(summary.CommitUsedBytes), "commit charge"));

        PendingTiles.Clear();
        PendingTiles.Add(new MetricTile("Average FPS", "Unavailable", "frame capture not connected"));
        PendingTiles.Add(new MetricTile("1% Low", "Unavailable", "frame capture not connected"));
        PendingTiles.Add(new MetricTile("Frame time", "Unavailable", "frame capture not connected"));
        PendingTiles.Add(new MetricTile("GPU usage", "Unavailable", CleanDevice(gpu)));

        Sensors.Clear();
        Sensors.Add(new StatusLine("Windows counters", "Connected", "safe"));
        Sensors.Add(new StatusLine("Frame capture (PresentMon)", "Not connected", "neutral"));
        Sensors.Add(new StatusLine("HWiNFO64 sensors", "Not connected", "neutral"));
    }

    [RelayCommand]
    private async Task CheckStutterPlanAsync()
    {
        if (!CanRunStutterAction)
        {
            return;
        }

        StutterBusy = true;
        StutterActionTitle = "Checking timer and cache settings";
        StutterActionDetail = "Roo Industries is reading the plan. No timer, power, cache, or service setting changes from this.";
        try
        {
            var response = await App.Live.PreviewStutterOptimizationResultAsync();
            if (response.Value is null)
            {
                StutterActionTitle = "Settings review not confirmed";
                StutterActionDetail = response.Error ?? "The timer and cache review returned no result.";
                return;
            }
            StutterActionTitle = "Settings reviewed";
            StutterActionDetail = SummarizeStutterAction(response.Value, "Roo Industries checked the timer and cache settings. Nothing changed.");
        }
        finally
        {
            StutterBusy = false;
        }
    }

    [RelayCommand]
    private async Task RunTimerSessionAsync()
    {
        if (!CanRunTimerSession)
        {
            return;
        }

        StutterBusy = true;
        StutterActionTitle = "Running latency session";
        StutterActionDetail = LatencySessionApproved
            ? "Roo Industries is asking Windows for a short timer session. It restores when the helper exits."
            : "Approval is still missing, so Roo Industries will stop before changing the timer.";
        try
        {
            var response = await App.Live.CheckTimerResolutionResultAsync(LatencySessionApproved);
            if (response.Value is null)
            {
                StutterActionTitle = "Latency session not confirmed";
                StutterActionDetail = response.Error ?? "The latency session returned no result.";
                return;
            }
            StutterActionTitle = "Latency session finished";
            StutterActionDetail = SummarizeStutterAction(response.Value, "Latency session finished. Nothing stayed changed.");
        }
        finally
        {
            StutterBusy = false;
        }
    }

    [RelayCommand]
    private async Task PrepareShaderCacheAsync()
    {
        if (!CanPrepareShaderCache)
        {
            return;
        }

        StutterBusy = true;
        StutterActionTitle = "Preparing cache cleanup";
        StutterActionDetail = ShaderCacheApproved
            ? "Roo Industries is checking the shader-cache plan, backup path, and restore path."
            : "Approval is still missing, so Roo Industries will stop before touching cache files.";
        try
        {
            var response = await App.Live.CheckShaderCacheCleanupResultAsync(ShaderCacheApproved);
            if (response.Value is null)
            {
                StutterActionTitle = "Cache cleanup not confirmed";
                StutterActionDetail = response.Error ?? "The cache cleanup check returned no result.";
                return;
            }
            _lastShaderRollbackPath = ExtractStringFromJson(response.Value, "rollback", "rollbackManifestPath")
                ?? ExtractStringFromJson(response.Value, "capabilities", "rollbackManifestPath");
            ShaderRestoreAvailable = !string.IsNullOrWhiteSpace(_lastShaderRollbackPath);
            ShaderRestoreHint = ShaderRestoreAvailable ? "Cache rollback is ready." : "No cache rollback file was written.";
            StutterActionTitle = "Cache cleanup checked";
            StutterActionDetail = SummarizeStutterAction(response.Value, "Cache cleanup checked. Nothing changed.");
        }
        finally
        {
            StutterBusy = false;
        }
    }

    [RelayCommand]
    private async Task RestoreShaderCacheAsync()
    {
        if (!CanRestoreShaderCache)
        {
            return;
        }

        if (string.IsNullOrWhiteSpace(_lastShaderRollbackPath))
        {
            StutterActionTitle = "No cache restore yet";
            StutterActionDetail = "Roo Industries only restores shader cache after a cleanup run writes a rollback file.";
            ShaderRestoreAvailable = false;
            ShaderRestoreHint = "No rollback file yet.";
            return;
        }

        StutterBusy = true;
        StutterActionTitle = "Restoring shader cache";
        StutterActionDetail = "Roo Industries is reading the rollback file and putting cache files back.";
        try
        {
            var response = await App.Live.RestoreShaderCacheCleanupResultAsync(_lastShaderRollbackPath);
            if (response.Value is null)
            {
                StutterActionTitle = "Cache restore not confirmed";
                StutterActionDetail = response.Error ?? "The cache restore returned no result.";
                ShaderRestoreHint = "The existing rollback remains available.";
                return;
            }
            StutterActionTitle = "Cache restore checked";
            StutterActionDetail = SummarizeStutterAction(response.Value, "Cache restore checked.");
            ShaderRestoreHint = "Restore path checked.";
        }
        finally
        {
            StutterBusy = false;
        }
    }

    private static string? ExtractStringFromJson(string? json, params string[] path)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            return ExtractString(doc.RootElement, path);
        }
        catch
        {
            return null;
        }
    }

    private static string CleanDevice(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "graphics";
        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("  ", " ").Trim();
    }

    private static string SummarizeStutterAction(string? json, string fallback)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return fallback;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var status = ExtractString(root, "status") ?? "preview";
            var actionId = ExtractString(root, "actionId") ?? string.Empty;
            var optimizationId = ExtractString(root, "optimizationId") ?? string.Empty;
            var executionMode = ExtractString(root, "executionMode") ?? string.Empty;
            var contractCount = ExtractInt(root, "summary", "contractCount");
            var readyCount = ExtractInt(root, "summary", "controlledExecutorReadyCount");
            var blocking = ExtractInt(root, "summary", "blockingGateCount");
            var willChangeSystem = ExtractBool(root, "summary", "willChangeSystem");
            var timerRestored = ExtractBool(root, "capabilities", "timerRestoreProved");
            var statusText = status switch
            {
                "success" => "Ready",
                "blocked" => "Held",
                "preview" => "Preview",
                _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(status.Replace("-", " ")),
            };

            if (actionId == "performance.stutterOptimization.realExecutor" && optimizationId == "timer-resolution")
            {
                if (status == "success")
                {
                    return timerRestored
                        ? "Ran: latency session completed and restored on exit."
                        : "Ran: latency session completed. Restore proof was not returned.";
                }

                if (blocking > 0)
                {
                    return "Held: approve the short timer run first. Nothing changed.";
                }
            }

            if (actionId == "performance.stutterOptimization.realExecutor" && optimizationId == "shader-cache-cleanup")
            {
                if (status == "success" || executionMode == "real-path-readiness-preview")
                {
                    return "Ready: cache cleanup path checked. No real cache files were deleted.";
                }

                if (blocking > 0)
                {
                    return "Held: approve shader-cache cleanup first. Nothing changed.";
                }
            }

            if (contractCount > 0)
            {
                return statusText + ": " + contractCount.ToString(CultureInfo.InvariantCulture)
                    + " fixes checked, " + readyCount.ToString(CultureInfo.InvariantCulture)
                    + " controlled paths ready. Nothing changed.";
            }

            if (blocking > 0)
            {
                return statusText + ": " + blocking.ToString(CultureInfo.InvariantCulture)
                    + " approval step" + (blocking == 1 ? "" : "s") + " still closed. Nothing changed.";
            }

            return statusText + (willChangeSystem ? ": system change requested." : ": nothing changed.");
        }
        catch
        {
            return fallback;
        }
    }

    private static string? ExtractString(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return null;
            }
        }

        return current.ValueKind == JsonValueKind.String ? current.GetString() : current.ToString();
    }

    private static int ExtractInt(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return 0;
            }
        }

        return current.ValueKind == JsonValueKind.Number && current.TryGetInt32(out var value) ? value : 0;
    }

    private static bool ExtractBool(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                return false;
            }
        }

        return current.ValueKind == JsonValueKind.True;
    }
}
