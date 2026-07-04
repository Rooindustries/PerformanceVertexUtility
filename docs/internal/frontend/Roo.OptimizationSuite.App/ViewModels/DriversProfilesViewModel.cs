using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.ViewModels;

public partial class DriversProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string? _machineModel;
    [ObservableProperty] private string? _machineOsCaption;
    [ObservableProperty] private string? _cpuName;
    [ObservableProperty] private string? _cpuCoreSummary;
    [ObservableProperty] private string? _primaryGpuName;
    [ObservableProperty] private string? _primaryGpuDriverSummary;
    [ObservableProperty] private bool _hasRecommendations;
    [ObservableProperty] private bool _hasNvidia;
    [ObservableProperty] private string? _gpuNote;
    [ObservableProperty] private string _nvidiaReadyState = "Ready — needs your go-ahead";
    [ObservableProperty] private string _nvidiaReadyStateLevel = "protected";
    [ObservableProperty] private bool _exportRequiredFirst;
    [ObservableProperty] private bool _nvidiaGpuDetected;
    [ObservableProperty][NotifyPropertyChangedFor(nameof(ApplyEnabled))] private bool _exportCompleted;
    [ObservableProperty] private string? _nvidiaHardwareLine;
    [ObservableProperty] private string _exportStepLabel = "Export current settings first";
    [ObservableProperty] private string _applyStepLabel = "Apply FrameSync profile";
    [ObservableProperty] private string? _applyCaption;
    [ObservableProperty] private string? _driverPathNote;

    private bool _importLaunchAllowed;

    public ObservableCollection<GpuInfo> Gpus { get; } = new();
    public ObservableCollection<NetworkAdapterInfo> NetworkAdapters { get; } = new();
    public ObservableCollection<DriverRecommendation> Recommendations { get; } = new();
    public ObservableCollection<string> ManualGateWarnings { get; } = new();
    public ObservableCollection<NvidiaProfileEntry> NvidiaProfiles { get; } = new();
    public bool ApplyEnabled => ExportCompleted && _importLaunchAllowed;

    protected override async Task LoadCoreAsync()
    {
        var liveHardware = await App.Live.GetDriverHardwareAsync();
        var hardware = liveHardware ?? await TryLoadSample(Data.GetDriverHardwareAsync);
        var usingSampleHardware = liveHardware is null;
        if (hardware?.Machine is null)
        {
            ErrorMessage = "We couldn't read your hardware yet. Close and reopen to try again.";
            return;
        }

        MachineModel = string.Join(" ", new[] { hardware.Machine.Manufacturer, hardware.Machine.Model }
            .Where(x => !string.IsNullOrWhiteSpace(x)));
        MachineOsCaption = hardware.Machine.OsCaption;
        CpuName = Clean(hardware.Cpu?.Name);
        CpuCoreSummary = hardware.Cpu is null ? null : $"{hardware.Cpu.Cores} cores / {hardware.Cpu.LogicalProcessors} threads";

        Gpus.Clear();
        foreach (var g in hardware.Gpus ?? Enumerable.Empty<GpuInfo>()) Gpus.Add(g);
        var primary = Gpus.FirstOrDefault(g => IsNvidia(g)) ?? Gpus.FirstOrDefault();
        PrimaryGpuName = Clean(primary?.Name);
        PrimaryGpuDriverSummary = primary is null ? null : $"Driver {primary.DriverVersion}  ·  {primary.DriverDate}";

        NetworkAdapters.Clear();
        foreach (var n in hardware.NetworkAdapters ?? Enumerable.Empty<NetworkAdapterInfo>()) NetworkAdapters.Add(n);

        HasNvidia = Gpus.Any(IsNvidia);

        var catalog = await Data.GetDriverRecommendationsAsync();
        var pnps = Gpus.Select(g => g.PnpDeviceId).Where(p => !string.IsNullOrWhiteSpace(p)).Cast<string>().ToList();
        var matched = (catalog.Recommendations ?? Enumerable.Empty<DriverRecommendation>())
            .Where(r => r.HardwareMatches?.Any(m => pnps.Any(p => p.StartsWith(m, StringComparison.OrdinalIgnoreCase))) ?? false)
            .ToList();
        Recommendations.Clear();
        foreach (var r in matched) Recommendations.Add(r);
        HasRecommendations = Recommendations.Count > 0;

        ManualGateWarnings.Clear();
        foreach (var w in catalog.ManualInstallGate?.Warnings ?? Enumerable.Empty<string>()) ManualGateWarnings.Add(w);
        DriverPathNote = "No driver installs on its own. DDU and NVCleanstall stay guided and manual.";

        NvidiaProfiles.Clear();
        var nvidiaPreview = await App.Live.GetNvidiaNipPreviewAsync() ?? await TryLoadSample(Data.GetNvidiaNipPreviewAsync);
        if (HasNvidia)
        {
            var profiles = await Data.GetNvidiaProfilesAsync();
            foreach (var p in profiles.Entries ?? Enumerable.Empty<NvidiaProfileEntry>()) NvidiaProfiles.Add(p);
            GpuNote = null;
        }
        else
        {
            GpuNote = PrimaryGpuName is null
                ? "GPU profile tools apply to NVIDIA graphics only."
                : "Your graphics is " + PrimaryGpuName + ". NVIDIA profile tools don't apply here.";
        }

        BuildNvidiaReadiness(nvidiaPreview, usingSampleHardware);
    }

    private void BuildNvidiaReadiness(NvidiaNipPreview? preview, bool usingSampleHardware)
    {
        var previewDetected = preview?.HardwareGate?.NvidiaGpuPresent == true;
        NvidiaGpuDetected = HasNvidia || (usingSampleHardware && previewDetected);
        ExportRequiredFirst = preview?.Summary?.ExportBeforeImportRequired == true;
        _importLaunchAllowed = preview?.Commands?.ImportCandidateProfile?.LaunchAllowedNow == true;
        OnPropertyChanged(nameof(ApplyEnabled));

        NvidiaHardwareLine = NvidiaGpuDetected ? "NVIDIA GPU detected" : "NVIDIA GPU not detected";
        if (preview?.Summary is { AutoApplyAllowed: false, BlockingGateCount: > 0 })
        {
            NvidiaReadyState = "Ready — needs your go-ahead";
            NvidiaReadyStateLevel = "protected";
        }
        else
        {
            NvidiaReadyState = "Ready to review";
            NvidiaReadyStateLevel = "low";
        }

        ExportStepLabel = "Export current settings first";
        var profileName = preview?.Profile?.Name;
        ApplyStepLabel = string.IsNullOrWhiteSpace(profileName) ? "Apply FrameSync profile" : "Apply " + profileName + " profile";
        ApplyCaption = "Available after export and your approval. Benchmark check recommended.";
    }

    private static bool IsNvidia(GpuInfo g)
        => (g.Vendor?.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) ?? false)
           || (g.Name?.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) ?? false);

    private static string? Clean(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("  ", " ").Trim();
    }

    private static async Task<T?> TryLoadSample<T>(System.Func<Task<T>> load) where T : class
    {
        try
        {
            return await load().ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }
}
