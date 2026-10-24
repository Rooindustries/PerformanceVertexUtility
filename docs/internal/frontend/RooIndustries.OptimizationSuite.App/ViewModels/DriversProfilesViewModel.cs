using System;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Services;

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
    [ObservableProperty] private string _driverDownloadHint = AnyMakerHint;
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
    [ObservableProperty] private string _nvidiaProfileId = "framesync";
    [ObservableProperty] private string _nvidiaProfileName = "FrameSync";
    private bool _nvidiaActionShown;
    private long _nvidiaActionGeneration = -1;
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

    public const string ReadFailed = "Hit Retry to try again. Still stuck? Let us know in Report a bug.";
    private const string AnyMakerHint = "Download it from your graphics card maker's website.";
    private static readonly string[] PlaceholderMachineNames =
    [
        "To Be Filled By O.E.M.", "System manufacturer", "System Product Name",
        "Default string", "Not Applicable", "Not Specified", "O.E.M.", "OEM",
    ];

    protected override async Task LoadCoreAsync()
    {
        try
        {
            await LoadHardwareAsync();
        }
        catch (Exception error)
        {
            AppLog.Write(nameof(DriversProfilesViewModel), error.ToString());
            ErrorMessage = ReadFailed;
        }
    }

    private async Task LoadHardwareAsync()
    {
        var hardware = await App.Live.GetDriverHardwareAsync(fresh: Fresh && !Quiet);
        if (hardware?.Machine is null)
        {
            ErrorMessage = ReadFailed;
            return;
        }

        MachineModel = MachineName(hardware.Machine);
        MachineOsCaption = WindowsName(hardware.Machine.OsCaption);
        CpuName = Clean(hardware.Cpu?.Name);
        CpuCoreSummary = hardware.Cpu is { Cores: > 0, LogicalProcessors: > 0 } cpu ? $"{cpu.Cores} cores, {cpu.LogicalProcessors} threads" : null;

        Gpus.Clear();
        foreach (var g in hardware.Gpus ?? Enumerable.Empty<GpuInfo>()) Gpus.Add(g);
        var primary = Gpus.FirstOrDefault(IsNvidia) ?? Gpus.FirstOrDefault(IsAmd) ?? Gpus.FirstOrDefault();
        PrimaryGpuName = Clean(primary?.Name);
        PrimaryGpuDriverSummary = primary is null ? null : DriverSummary(primary);
        DriverDownloadHint = primary is null ? AnyMakerHint
            : IsNvidia(primary) ? "Open Tools and pick NVIDIA App & Driver."
            : IsAmd(primary) ? "Open Tools and pick AMD Software: Adrenalin Edition."
            : IsMaker(primary, "Intel") ? "Download it from Intel's website."
            : AnyMakerHint;

        NetworkAdapters.Clear();
        foreach (var n in hardware.NetworkAdapters ?? Enumerable.Empty<NetworkAdapterInfo>())
            NetworkAdapters.Add(new NetworkAdapterInfo { Name = Clean(n.Name), Vendor = n.Vendor, DriverVersion = n.DriverVersion, Protected = n.Protected, Reason = n.Reason });

        HasNvidia = Gpus.Any(IsNvidia);

        NvidiaProfiles.Clear();
        var profiles = await Data.GetNvidiaProfilesAsync();
        foreach (var p in profiles.Entries ?? Enumerable.Empty<NvidiaProfileEntry>()) NvidiaProfiles.Add(p);
        HasNvidiaProfiles = NvidiaProfiles.Count > 0;
        var firstProfile = NvidiaProfiles.FirstOrDefault();
        if (firstProfile is not null)
        {
            NvidiaProfileId = string.IsNullOrWhiteSpace(firstProfile.ProfileId) ? "framesync" : firstProfile.ProfileId!;
            NvidiaProfileName = string.IsNullOrWhiteSpace(firstProfile.Name) ? NvidiaProfileId : firstProfile.Name!;
            if (_nvidiaActionShown && !DataGeneration.IsCurrent(_nvidiaActionGeneration) && !DataGeneration.Changing) _nvidiaActionShown = false;
            if (!_nvidiaActionShown)
            {
                NvidiaActionTitle = HasNvidia ? NvidiaProfileName + " is ready to review" : NvidiaProfileName + " is locked on this GPU";
                NvidiaActionDetail = HasNvidia
                    ? "Preview the profile. Apply runs only after export, approval, and benchmark checks are selected."
                    : "This PC is not on NVIDIA graphics. The app can inspect the path, but apply stays locked.";
            }
            _nvidiaRecovery = await App.Live.ReadNvidiaProfileRecoveryAsync(NvidiaProfileId);
            OnPropertyChanged(nameof(CanRestoreNvidiaProfile));
        }

        Recommendations.Clear();
        HasRecommendations = false;
        ManualGateWarnings.Clear();

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

        NvidiaBusy = true; _nvidiaActionShown = true;
        NvidiaActionTitle = "Checking NVIDIA Profile Inspector";
        NvidiaActionDetail = "Running the read-only tool check. It will not import a profile.";
        try
        {
            var response = await App.Live.ProbeNvidiaProfileResultAsync(NvidiaProfileId);
            if (response.Value is null || response.Error is not null)
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
            NvidiaBusy = false; _nvidiaActionGeneration = DataGeneration.Snapshot();
        }
    }

    [RelayCommand]
    private async Task PreviewNvidiaProfileAsync()
    {
        if (!CanCheckNvidiaAction)
        {
            return;
        }

        NvidiaBusy = true; _nvidiaActionShown = true;
        NvidiaActionTitle = "Previewing " + NvidiaProfileName;
        NvidiaActionDetail = "Building the export and import plan without launching NVIDIA Profile Inspector.";
        try
        {
            var response = await App.Live.PreviewNvidiaProfileResultAsync(NvidiaProfileId);
            if (response.Value is null || response.Error is not null)
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
            NvidiaBusy = false; _nvidiaActionGeneration = DataGeneration.Snapshot();
        }
    }

    [RelayCommand]
    private async Task ApplyNvidiaProfileAsync()
    {
        if (!CanApplyNvidiaProfile)
        {
            return;
        }

        NvidiaBusy = true; _nvidiaActionShown = true;
        var realApplyRequested = NvidiaExportReviewed && NvidiaProfileApproved && NvidiaBenchmarkReady;
        NvidiaActionTitle = realApplyRequested ? "Applying " + NvidiaProfileName : "Checking apply approvals";
        NvidiaActionDetail = realApplyRequested
            ? "The app will run NVIDIA Profile Inspector only if this PC, the tool path, and the profile approvals pass."
            : NvidiaGateSummary;
        try
        {
            using var running = RunningChanges.Begin();
            var response = await App.Live.ApplyNvidiaProfileResultAsync(
                NvidiaProfileId,
                NvidiaExportReviewed,
                NvidiaProfileApproved,
                NvidiaBenchmarkReady);
            _nvidiaRecovery = await App.Live.ReadNvidiaProfileRecoveryAsync(NvidiaProfileId)
                ?? Services.LiveDataService.NvidiaRecoveryFromApplyResult(NvidiaProfileId, response.Value, response.RecoveryPath, response.RecoveryGeneration);
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
        catch (InvalidOperationException error) when (error.Message == RunningChanges.Installing)
        {
            NvidiaActionTitle = "Apply not confirmed";
            NvidiaActionDetail = error.Message;
        }
        finally
        {
            NvidiaBusy = false; _nvidiaActionGeneration = DataGeneration.Snapshot();
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

        NvidiaBusy = true; _nvidiaActionShown = true;
        NvidiaActionTitle = NvidiaProfileApproved ? "Restoring " + NvidiaProfileName : "Checking restore approvals";
        NvidiaActionDetail = NvidiaProfileApproved
            ? "The app will restore through NVIDIA Profile Inspector only if the rollback path and hardware checks pass."
            : "Approve the exact profile first. Restore stays locked until that approval is selected.";
        try
        {
            using var running = RunningChanges.Begin();
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
        catch (InvalidOperationException error) when (error.Message == RunningChanges.Installing)
        {
            NvidiaActionTitle = "Restore not confirmed";
            NvidiaActionDetail = error.Message;
        }
        finally
        {
            NvidiaBusy = false; _nvidiaActionGeneration = DataGeneration.Snapshot();
        }
    }

    private static bool IsNvidia(GpuInfo g) => IsMaker(g, "NVIDIA");

    private static bool IsAmd(GpuInfo g) => IsMaker(g, "AMD") || IsMaker(g, "Radeon");

    private static bool IsMaker(GpuInfo g, string maker)
        => (g.Vendor?.Contains(maker, StringComparison.OrdinalIgnoreCase) ?? false)
           || (g.Name?.Contains(maker, StringComparison.OrdinalIgnoreCase) ?? false);

    private static string? MachineName(MachineInfo machine)
    {
        var parts = new[] { machine.Manufacturer, machine.Model }
            .Select(part => part?.Trim())
            .OfType<string>()
            .Where(part => part.Length > 0)
            .ToArray();
        var named = parts.Where(part => !PlaceholderMachineNames.Contains(part, StringComparer.OrdinalIgnoreCase)).ToArray();
        return named.Length > 0 ? string.Join(" ", named) : parts.Length > 0 ? "Custom-built PC" : null;
    }

    private static string? WindowsName(string? caption)
    {
        var name = caption?.Trim();
        return name is not null && name.StartsWith("Microsoft ", StringComparison.OrdinalIgnoreCase) ? name["Microsoft ".Length..] : name;
    }

    private static string? DriverSummary(GpuInfo gpu)
    {
        var version = IsNvidia(gpu) ? NvidiaDriverVersion(gpu.DriverVersion) : gpu.DriverVersion?.Trim();
        var released = DateTime.TryParseExact(gpu.DriverDate, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? date.ToString("d MMM yyyy", CultureInfo.CurrentCulture)
            : null;
        if (string.IsNullOrEmpty(version)) return released is null ? null : "Driver from " + released;
        return released is null ? "Driver " + version : "Driver " + version + " · " + released;
    }

    private static string? NvidiaDriverVersion(string? windowsVersion)
    {
        var parts = windowsVersion?.Trim().Split('.');
        if (parts is not { Length: 4 } || parts[3].Length != 4 || !parts.All(part => part.Length > 0 && part.All(char.IsAsciiDigit)))
            return windowsVersion?.Trim();
        var digits = parts[2][^1] + parts[3];
        return digits[..3] + "." + digits[3..];
    }

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
                || !TryExtractInt(root, out var reportedBlocking, "summary", "blockingGateCount")
                || !TryExtractBool(root, out var importAttempted, "summary", "importAttempted")
                || !TryExtractBool(root, out var importCompleted, "summary", "importCompleted")) return false;
            var status = ExtractString(root, "status");
            if (status is not ("success" or "failed" or "blocked")) return false;
            var actualBlocking = BlockingGateCount(root);
            var errors = ErrorCount(root);
            if (actualBlocking < 0 || errors < 0 || reportedBlocking != actualBlocking
                || importCompleted && !importAttempted
                || status == "blocked" && (!dryRun || actualBlocking == 0 || importCompleted)
                || (status is "success" or "failed") && dryRun
                || status == "success" && (actualBlocking != 0 || errors != 0 || !importAttempted || !importCompleted)
                || status == "failed" && importCompleted) return false;
            if (operation == "Apply"
                && (!TryExtractBool(root, out var exportCompleted, "summary", "exportCompleted")
                    || importAttempted && !exportCompleted)) return false;
            if (operation == "Restore"
                && (!TryExtractBool(root, out var exportAttempted, "summary", "exportAttempted") || exportAttempted)) return false;
            completed = status == "success";
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

    private static bool TryExtractInt(JsonElement root, out int value, params string[] path)
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

    private static int BlockingGateCount(JsonElement root)
        => root.TryGetProperty("gates", out var gates) && gates.ValueKind == JsonValueKind.Array
            ? gates.EnumerateArray().Count(gate => ExtractBool(gate, "blocking"))
            : -1;

    private static int ErrorCount(JsonElement root)
        => root.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array
            ? errors.GetArrayLength()
            : -1;
}
