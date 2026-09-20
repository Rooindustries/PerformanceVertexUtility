using System;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class DriversProfilesViewModel : PageViewModelBase
{
    [ObservableProperty] private string? _machineModel;
    [ObservableProperty] private string? _machineOsCaption;
    [ObservableProperty] private string? _cpuName;
    [ObservableProperty] private string? _cpuCoreSummary;
    [ObservableProperty] private string? _primaryGpuName;
    [ObservableProperty] private string? _primaryGpuDriverSummary;
    [ObservableProperty] private bool _hasRecommendations;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCheckNvidiaAction))]
    [NotifyPropertyChangedFor(nameof(CanApproveNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanApplyNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanRestoreNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(NvidiaGateSummary))]
    private bool _hasNvidia;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCheckNvidiaAction))]
    [NotifyPropertyChangedFor(nameof(CanApproveNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanApplyNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanRestoreNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(NvidiaGateSummary))]
    private bool _hasNvidiaProfiles;
    [ObservableProperty] private string? _gpuNote;
    [ObservableProperty] private string _nvidiaProfileId = "base-profile";
    [ObservableProperty] private string _nvidiaProfileName = "Base profile";
    [ObservableProperty] private string _nvidiaActionTitle = "NVIDIA profile";
    [ObservableProperty] private string _nvidiaActionDetail = "Check NVIDIA Profile Inspector, review the profile, and confirm the requirements below.";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCheckNvidiaAction))]
    [NotifyPropertyChangedFor(nameof(CanApproveNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanApplyNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanRestoreNvidiaProfile))]
    private bool _nvidiaBusy;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NvidiaGateSummary))]
    [NotifyPropertyChangedFor(nameof(CanApplyNvidiaProfile))]
    private bool _nvidiaExportReviewed;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NvidiaGateSummary))]
    [NotifyPropertyChangedFor(nameof(CanApplyNvidiaProfile))]
    [NotifyPropertyChangedFor(nameof(CanRestoreNvidiaProfile))]
    private bool _nvidiaProfileApproved;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NvidiaGateSummary))]
    [NotifyPropertyChangedFor(nameof(CanApplyNvidiaProfile))]
    private bool _nvidiaBenchmarkReady;
    private Services.NvidiaProfileRecovery? _nvidiaRecovery;

    public ObservableCollection<GpuInfo> Gpus { get; } = new();
    public ObservableCollection<NetworkAdapterInfo> NetworkAdapters { get; } = new();
    public ObservableCollection<DriverRecommendation> Recommendations { get; } = new();
    public ObservableCollection<string> ManualGateWarnings { get; } = new();
    public ObservableCollection<NvidiaProfileEntry> NvidiaProfiles { get; } = new();
    public bool CanCheckNvidiaAction => HasNvidiaProfiles && !NvidiaBusy;
    public bool CanApproveNvidiaProfile => HasNvidia && HasNvidiaProfiles && !NvidiaBusy;
    public bool CanApplyNvidiaProfile => CanApproveNvidiaProfile && NvidiaExportReviewed && NvidiaProfileApproved && NvidiaBenchmarkReady;
    public bool CanRestoreNvidiaProfile => CanApproveNvidiaProfile && NvidiaProfileApproved && _nvidiaRecovery is not null;
    public string NvidiaGateSummary => !HasNvidiaProfiles
        ? "No NVIDIA profile catalog found."
        : !HasNvidia
            ? "An NVIDIA GPU is required to apply this profile."
            : NvidiaExportReviewed && NvidiaProfileApproved && NvidiaBenchmarkReady
                ? "Ready to apply " + NvidiaProfileName + "."
                : "Review export, exact profile approval, and benchmark evidence first.";

    protected override async Task LoadCoreAsync()
    {
        var hardware = await App.Live.GetDriverHardwareAsync();
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
        PrimaryGpuDriverSummary = primary is null ? null : $"Driver {primary.DriverVersion} / {primary.DriverDate}";

        NetworkAdapters.Clear();
        foreach (var n in hardware.NetworkAdapters ?? Enumerable.Empty<NetworkAdapterInfo>()) NetworkAdapters.Add(n);

        HasNvidia = Gpus.Any(IsNvidia);

        NvidiaProfiles.Clear();
        var profiles = await Data.GetNvidiaProfilesAsync();
        foreach (var p in profiles.Entries ?? Enumerable.Empty<NvidiaProfileEntry>()) NvidiaProfiles.Add(p);
        HasNvidiaProfiles = NvidiaProfiles.Count > 0;
        var firstProfile = NvidiaProfiles.FirstOrDefault();
        if (firstProfile is not null)
        {
            NvidiaProfileId = string.IsNullOrWhiteSpace(firstProfile.ProfileId) ? "base-profile" : firstProfile.ProfileId!;
            NvidiaProfileName = string.IsNullOrWhiteSpace(firstProfile.Name) ? NvidiaProfileId : firstProfile.Name!;
            NvidiaActionTitle = HasNvidia ? NvidiaProfileName + " is ready to review" : NvidiaProfileName + " is locked on this GPU";
            NvidiaActionDetail = HasNvidia
                ? "Preview the profile. Apply runs only after export, approval, and benchmark checks are selected."
                : "This PC is not on NVIDIA graphics. Roo Industries can inspect the path, but apply stays locked.";
            _nvidiaRecovery = await App.Live.ReadNvidiaProfileRecoveryAsync(NvidiaProfileId);
            OnPropertyChanged(nameof(CanRestoreNvidiaProfile));
        }

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

        if (!HasNvidia)
        {
            GpuNote = PrimaryGpuName is null
                ? "GPU profile tools apply to NVIDIA graphics only."
                : "Your graphics is " + PrimaryGpuName + ". NVIDIA profile apply stays locked here.";
        }
    }

    [RelayCommand]
    private async Task CheckNvidiaToolAsync()
    {
        if (!CanCheckNvidiaAction)
        {
            return;
        }

        NvidiaBusy = true;
        NvidiaActionTitle = "Checking NVIDIA Profile Inspector";
        NvidiaActionDetail = "Roo Industries is running the read-only tool check. It will not import a profile.";
        try
        {
            var response = await App.Live.ProbeNvidiaProfileResultAsync(NvidiaProfileId);
            if (response.Value is null)
            {
                NvidiaActionTitle = "Tool check not confirmed";
                NvidiaActionDetail = response.Error ?? "The NVIDIA tool check returned no result.";
                return;
            }
            NvidiaActionTitle = "Tool check finished";
            NvidiaActionDetail = SummarizeNvidiaAction(response.Value, "Read-only NVIDIA tool check finished. No profile was imported.");
        }
        finally
        {
            NvidiaBusy = false;
        }
    }

    [RelayCommand]
    private async Task PreviewNvidiaProfileAsync()
    {
        if (!CanCheckNvidiaAction)
        {
            return;
        }

        NvidiaBusy = true;
        NvidiaActionTitle = "Previewing " + NvidiaProfileName;
        NvidiaActionDetail = "Roo Industries is building the export and import plan without launching NVIDIA Profile Inspector.";
        try
        {
            var response = await App.Live.PreviewNvidiaProfileResultAsync(NvidiaProfileId);
            if (response.Value is null)
            {
                NvidiaActionTitle = "Profile plan not confirmed";
                NvidiaActionDetail = response.Error ?? "The NVIDIA profile preview returned no result.";
                return;
            }
            NvidiaActionTitle = "Profile plan ready";
            NvidiaActionDetail = SummarizeNvidiaAction(response.Value, "Profile preview is ready. No profile was imported.");
        }
        finally
        {
            NvidiaBusy = false;
        }
    }

    [RelayCommand]
    private async Task ApplyNvidiaProfileAsync()
    {
        if (!CanApplyNvidiaProfile)
        {
            return;
        }

        NvidiaBusy = true;
        var realApplyRequested = NvidiaExportReviewed && NvidiaProfileApproved && NvidiaBenchmarkReady;
        NvidiaActionTitle = realApplyRequested ? "Applying " + NvidiaProfileName : "Checking apply approvals";
        NvidiaActionDetail = realApplyRequested
            ? "Roo Industries will run NVIDIA Profile Inspector only if this PC, the tool path, and the profile approvals pass."
            : NvidiaGateSummary;
        try
        {
            var response = await App.Live.ApplyNvidiaProfileResultAsync(
                NvidiaProfileId,
                NvidiaExportReviewed,
                NvidiaProfileApproved,
                NvidiaBenchmarkReady);
            _nvidiaRecovery = await App.Live.ReadNvidiaProfileRecoveryAsync(NvidiaProfileId);
            OnPropertyChanged(nameof(CanRestoreNvidiaProfile));
            if (response.Value is null || response.Error is not null)
            {
                NvidiaActionTitle = "Apply not confirmed";
                NvidiaActionDetail = response.Error ?? "The NVIDIA apply returned no result.";
                return;
            }
            if (!NvidiaExecutorMatches(response.Value, "Apply", NvidiaProfileId, out var completed))
            {
                NvidiaActionTitle = "Apply not confirmed";
                NvidiaActionDetail = "The NVIDIA apply response did not match this profile or requested operation.";
                return;
            }
            NvidiaActionTitle = completed ? "Profile applied" : _nvidiaRecovery is not null ? "Apply needs attention" : "Apply held";
            NvidiaActionDetail = SummarizeNvidiaAction(response.Value, "Apply finished. No profile was imported.");
        }
        finally
        {
            NvidiaBusy = false;
        }
    }

    [RelayCommand]
    private async Task RestoreNvidiaProfileAsync()
    {
        if (!CanRestoreNvidiaProfile)
        {
            return;
        }

        var recovery = _nvidiaRecovery;
        if (recovery is null)
        {
            NvidiaActionTitle = "Restore unavailable";
            NvidiaActionDetail = "Apply this profile with a verified rollback export before restoring it.";
            return;
        }

        NvidiaBusy = true;
        NvidiaActionTitle = NvidiaProfileApproved ? "Restoring " + NvidiaProfileName : "Checking restore approvals";
        NvidiaActionDetail = NvidiaProfileApproved
            ? "Roo Industries will restore through NVIDIA Profile Inspector only if the rollback path and hardware checks pass."
            : "Approve the exact profile first. Restore stays locked until that approval is selected.";
        try
        {
            var response = await App.Live.RestoreNvidiaProfileResultAsync(recovery, NvidiaProfileApproved);
            _nvidiaRecovery = await App.Live.ReadNvidiaProfileRecoveryAsync(NvidiaProfileId);
            OnPropertyChanged(nameof(CanRestoreNvidiaProfile));
            if (response.Value is null || response.Error is not null)
            {
                NvidiaActionTitle = "Restore not confirmed";
                NvidiaActionDetail = response.Error ?? "The NVIDIA restore returned no result.";
                return;
            }
            if (!NvidiaExecutorMatches(response.Value, "Restore", NvidiaProfileId, out var completed) || !completed || _nvidiaRecovery is not null)
            {
                NvidiaActionTitle = "Restore not confirmed";
                NvidiaActionDetail = SummarizeNvidiaAction(response.Value, "The NVIDIA restore did not complete.");
                return;
            }
            NvidiaActionTitle = "Profile restored";
            NvidiaActionDetail = SummarizeNvidiaAction(response.Value, "Restore finished. No profile was imported.");
        }
        finally
        {
            NvidiaBusy = false;
        }
    }

    private static bool IsNvidia(GpuInfo g)
        => (g.Vendor?.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) ?? false)
           || (g.Name?.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase) ?? false);

    private static string? Clean(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        return name.Replace("(R)", string.Empty).Replace("(TM)", string.Empty).Replace("  ", " ").Trim();
    }

    private static string SummarizeNvidiaAction(string? json, string fallback)
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
            var operation = ExtractString(root, "operation") ?? string.Empty;
            var blocking = ExtractInt(root, "summary", "blockingGateCount");
            var next = ExtractString(root, "summary", "nextEngineeringStep");
            var noImport = ExtractBool(root, "summary", "noImportAttempted") || ExtractBool(root, "summary", "noAutoApply");
            var exportCreated = ExtractBool(root, "summary", "exportFileCreated");
            var realNvpiInvoked = ExtractBool(root, "summary", "realNvpiInvoked");
            var importCompleted = ExtractBool(root, "summary", "importCompleted");
            var importAttempted = ExtractBool(root, "summary", "importAttempted");
            var statusText = status switch
            {
                "success" => "Ready",
                "blocked" => "Held",
                "preview" => "Preview",
                "requires-elevation" => "Helper check needed",
                "cli-unsupported" => "Tool adapter needs work",
                "approval-or-input-required" => "Needs tool input",
                _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(status.Replace("-", " ")),
            };

            if (importCompleted && realNvpiInvoked)
            {
                return string.Equals(operation, "Restore", StringComparison.OrdinalIgnoreCase)
                    ? "Restored: NVIDIA Profile Inspector finished the restore import."
                    : "Applied: NVIDIA Profile Inspector finished the profile import.";
            }

            if (importAttempted && !importCompleted)
            {
                return "Stopped: NVIDIA Profile Inspector did not complete the profile import.";
            }

            if (blocking > 0)
            {
                return statusText + ": " + blocking.ToString(CultureInfo.InvariantCulture)
                    + " approval step" + (blocking == 1 ? "" : "s") + " still closed. No NVIDIA profile was imported.";
            }

            if (exportCreated)
            {
                return statusText + ": read-only export check created a temp profile export. No profile was imported.";
            }

            if (!string.IsNullOrWhiteSpace(next))
            {
                return statusText + ": " + next + " No profile was imported.";
            }

            return statusText + (noImport ? ": no profile was imported." : ": no profile import was requested.");
        }
        catch
        {
            return fallback;
        }
    }

    private static bool NvidiaExecutorMatches(string json, string operation, string profileId, out bool completed)
    {
        completed = false;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (ExtractString(root, "actionId") != "drivers.nvidiaNip.executor"
                || ExtractString(root, "operation") != operation
                || ExtractString(root, "profileId") != profileId
                || !TryExtractBool(root, out var dryRun, "dryRun")
                || dryRun) return false;
            var status = ExtractString(root, "status");
            if (status is not ("success" or "failed" or "blocked")) return false;
            completed = status == "success"
                && ExtractBool(root, "summary", "importCompleted");
            return true;
        }
        catch
        {
            return false;
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

    private static bool TryExtractBool(JsonElement root, out bool value, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
        {
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current))
            {
                value = false;
                return false;
            }
        }
        if (current.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            value = current.GetBoolean();
            return true;
        }
        value = false;
        return false;
    }
}
