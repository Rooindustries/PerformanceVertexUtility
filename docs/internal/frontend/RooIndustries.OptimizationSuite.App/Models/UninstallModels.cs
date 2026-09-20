using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace RooIndustries.OptimizationSuite.Models;

public sealed class InstalledAppInventory
{
    public string? CapturedAtUtc { get; set; }
    public InstalledAppSummary? Summary { get; set; }
    public List<string>? Sources { get; set; }
    public List<InstalledApp>? Apps { get; set; }
    public bool? Complete { get; set; }
    public List<string>? Errors { get; set; }
}

public sealed class InstalledAppSummary
{
    public int AppCount { get; set; }
    public int NormalAppCount { get; set; }
    public int LauncherCount { get; set; }
    public int OverlayCount { get; set; }
    public int VendorToolCount { get; set; }
    public int ProtectedRuntimeCount { get; set; }
    public int StartupHeavyCount { get; set; }
    public long EstimatedSizeBytes { get; set; }
}

public sealed class InstalledApp
{
    public System.Text.Json.JsonElement? SourceIdentity { get; set; }
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public string? Publisher { get; set; }
    public string? Version { get; set; }
    public string? SourceType { get; set; }
    public string? PackageId { get; set; }
    public long? EstimatedSizeBytes { get; set; }
    public List<string>? Categories { get; set; }
    public string? Risk { get; set; }
    public bool Protected { get; set; }
    public List<string>? ProtectionReasons { get; set; }
    public string? StartupImpact { get; set; }
    public string? InstallLocation { get; set; }
    public string? UninstallString { get; set; }
    public string? QuietUninstallString { get; set; }

    private static readonly Dictionary<string, string> KnownPackages = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Microsoft.WindowsStore"] = "Microsoft Store",
        ["Microsoft.WindowsTerminal"] = "Windows Terminal",
        ["Microsoft.WindowsCalculator"] = "Calculator",
        ["Microsoft.WindowsNotepad"] = "Notepad",
        ["Microsoft.Paint"] = "Paint",
        ["Microsoft.ScreenSketch"] = "Snipping Tool",
        ["Microsoft.WindowsCamera"] = "Camera",
        ["Microsoft.Windows.Photos"] = "Photos",
        ["Microsoft.ZuneMusic"] = "Media Player",
        ["Microsoft.GamingApp"] = "Xbox",
        ["Microsoft.Copilot"] = "Microsoft Copilot",
        ["Microsoft.Windows.Ai.Copilot"] = "Windows Copilot",
        ["Microsoft.MicrosoftOfficeHub"] = "Microsoft 365 Copilot",
        ["Microsoft.WidgetsPlatformRuntime"] = "Windows Widgets",
        ["MicrosoftWindows.Client.WebExperience"] = "Windows Web Experience Pack",
        ["MicrosoftWindows.Client.CoreAI"] = "Windows AI components",
        ["Microsoft.XboxApp"] = "Xbox",
        ["SpotifyAB.SpotifyMusic"] = "Spotify",
        ["AppUp.IntelArcSoftware"] = "Intel Arc Software",
        ["AppUp.IntelConnectivityPerformanceSuite"] = "Intel Connectivity Suite",
    };

    private static readonly Regex GuidLike = new(
        @"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        RegexOptions.Compiled);
    private static readonly Regex DottedFamily = new(@"^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+$", RegexOptions.Compiled);
    private static readonly Regex InternalToken = new(@"^[a-z][a-z0-9]{1,8}$", RegexOptions.Compiled);

    public string FriendlyName => NormalizeName(DisplayName);
    public string AccountLabel => SourceType != "appx" ? "" : SourceIdentity is { } identity && identity.TryGetProperty("scope", out var scope) && scope.GetString() == "registered-user"
        ? "Windows account: " + (identity.TryGetProperty("userSid", out var sid) ? sid.GetString() : "Unknown") : "This Windows user";
    public string SelectionLabel => AccountLabel.Length == 0 ? FriendlyName : FriendlyName + " · " + AccountLabel;

    public override string ToString() => SelectionLabel;

    public bool IsListable => !string.IsNullOrWhiteSpace(DisplayName) && !IsRawEntry(DisplayName!);

    public string? SecondaryLabel
    {
        get
        {
            var pub = PublisherDisplay;
            if (!string.IsNullOrWhiteSpace(pub)
                && !GuidLike.IsMatch(pub!.Trim('{', '}'))
                && !Regex.IsMatch(pub!, @"^[a-z0-9]{12,}$"))
            {
                return SourceType == "appx" && !string.IsNullOrWhiteSpace(Version) ? pub + " · " + Version : pub;
            }

            return SourceLabel(SourceType);
        }
    }

    public string? PublisherDisplay
    {
        get
        {
            var p = Publisher;
            if (string.IsNullOrWhiteSpace(p)) return null;
            if (p.StartsWith("CN=", StringComparison.OrdinalIgnoreCase))
            {
                var rest = p.Substring(3);
                var comma = rest.IndexOf(',');
                return (comma > 0 ? rest.Substring(0, comma) : rest).Trim();
            }
            return p;
        }
    }

    private static string StripPackageSuffix(string name)
    {
        var underscore = name.IndexOf('_');
        return underscore > 0 ? name.Substring(0, underscore) : name;
    }

    private static string NormalizeName(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "Unknown app";
        var name = raw.Trim();
        return KnownPackages.TryGetValue(StripPackageSuffix(name), out var friendly) ? friendly : name;
    }

    private static bool IsRawEntry(string raw)
    {
        var name = raw.Trim();
        if (KnownPackages.ContainsKey(StripPackageSuffix(name))) return false;
        if (GuidLike.IsMatch(name.Trim('{', '}'))) return true;
        if (LooksLikePackageFamily(StripPackageSuffix(name))) return true;
        if (InternalToken.IsMatch(name)) return true;
        return false;
    }

    private static bool LooksLikePackageFamily(string name)
    {
        if (!DottedFamily.IsMatch(name)) return false;
        var dots = name.Count(c => c == '.');
        return dots >= 2 || name.Any(char.IsDigit) || Regex.IsMatch(name, @"\.[A-Z]");
    }

    private static string SourceLabel(string? source) => source switch
    {
        "registry" => "Installed program",
        "msi" => "Windows Installer",
        "appx" => "Store app",
        "winget" => "Winget",
        _ => "App",
    };
}

public sealed class AppClassificationResult
{
    public string? CapturedAtUtc { get; set; }
    public AppClassificationSummary? Summary { get; set; }
    public List<AppClassificationItem>? Apps { get; set; }
}

public sealed class AppClassificationSummary
{
    public int AppCount { get; set; }
    public int ProtectedCount { get; set; }
    public int BlockedByDefaultCount { get; set; }
}

public sealed class AppClassificationItem
{
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public string? Publisher { get; set; }
    public string? PrimaryClassification { get; set; }
    public string? Risk { get; set; }
    public bool Protected { get; set; }
    public bool BlockByDefault { get; set; }
    public List<string>? MatchedProtectedRuleIds { get; set; }
    public List<string>? ProtectionReasons { get; set; }
    public string? RecommendedAction { get; set; }
}

public sealed class UninstallQueue
{
    public string? QueueId { get; set; }
    public bool DryRun { get; set; }
    public string? Status { get; set; }
    public List<QueueApp>? SelectedApps { get; set; }
    public List<BlockedApp>? BlockedApps { get; set; }
    public UninstallPolicy? Policy { get; set; }
    public UninstallQueueSummary? Summary { get; set; }
}

public sealed class QueueApp
{
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public bool OfficialUninstallFirst { get; set; }
    public bool LeftoverScan { get; set; }
    public string? Risk { get; set; }
    public bool RequiresElevation { get; set; }
    public List<IssueModel>? Warnings { get; set; }
}

public sealed class BlockedApp
{
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public string? PrimaryClassification { get; set; }
    public string? Risk { get; set; }
    public bool Protected { get; set; }
    public string? Reason { get; set; }
}

public sealed class UninstallPolicy
{
    public bool ConfirmationRequired { get; set; }
    public bool RestorePointRequired { get; set; }
    public string? LeftoverDeletionDefault { get; set; }
    public bool ProtectedAppsBlocked { get; set; }
    public bool OfficialUninstallOnlyUntilConfirmed { get; set; }
    public bool ConfirmedExecutionEnabled { get; set; }
    public bool DryRunWritesState { get; set; }
}

public sealed class UninstallQueueSummary
{
    public int RequestedCount { get; set; }
    public int SelectedCount { get; set; }
    public int BlockedCount { get; set; }
    public int MissingCount { get; set; }
    public bool WillRunUninstallers { get; set; }
    public bool WillDeleteLeftovers { get; set; }
}

public sealed class OfficialUninstallPreview
{
    public bool DryRun { get; set; }
    public List<UninstallCommand>? Commands { get; set; }
    public List<IssueModel>? Errors { get; set; }
}

public sealed class UninstallCommand
{
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public string? CommandType { get; set; }
    public string? RawCommand { get; set; }
    public string? Executable { get; set; }
    public bool HasQuietCommand { get; set; }
    public bool RequiresElevation { get; set; }
    public bool Blocked { get; set; }
    public string? Risk { get; set; }
    public bool ExecutionAllowed { get; set; }
    public string? ExecutionMode { get; set; }
}

public sealed class LeftoverScan
{
    public string? ScanId { get; set; }
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public bool DryRun { get; set; }
    public LeftoverScanSummary? Summary { get; set; }
    public List<LeftoverItem>? Items { get; set; }
    public List<IssueModel>? Errors { get; set; }
}

public sealed class LeftoverScanSummary
{
    public int ItemCount { get; set; }
    public int DefaultSelectedCount { get; set; }
    public int ProtectedCount { get; set; }
    public long EstimatedRecoverableBytes { get; set; }
    public string? DeletionMode { get; set; }
}

public sealed class LeftoverItem
{
    public string? ItemId { get; set; }
    public string? Type { get; set; }
    public string? Target { get; set; }
    public List<string>? MatchedBy { get; set; }
    public string? Confidence { get; set; }
    public string? Risk { get; set; }
    public bool DefaultSelected { get; set; }
    public bool Protected { get; set; }
    public string? Reason { get; set; }
}

public sealed class CleanupManifest
{
    public string? ManifestId { get; set; }
    public string? AppId { get; set; }
    public string? DisplayName { get; set; }
    public bool DryRun { get; set; }
    public string? ExecutionMode { get; set; }
    public List<LeftoverItem>? Items { get; set; }
    public CleanupRollback? Rollback { get; set; }
    public CleanupManifestSummary? Summary { get; set; }
    public List<IssueModel>? Errors { get; set; }
}

public sealed class CleanupManifestSummary
{
    public int ItemCount { get; set; }
    public int ExcludedCount { get; set; }
    public int ProtectedCount { get; set; }
    public bool RequiresElevation { get; set; }
    public bool ConfirmationRequired { get; set; }
    public bool WillDeleteOnApply { get; set; }
    public bool WillEditRegistry { get; set; }
    public bool DryRunWritesState { get; set; }
}

public sealed class CleanupRollback
{
    [JsonPropertyName("backupRoot")] public string? BackupRoot { get; set; }
    [JsonPropertyName("rollbackActionId")] public string? RollbackActionId { get; set; }
    [JsonPropertyName("rollbackSupported")] public bool RollbackSupported { get; set; }
    [JsonPropertyName("restorePoint")] public CleanupRestorePoint? RestorePoint { get; set; }
    [JsonPropertyName("fileBackupRequirements")] public List<CleanupBackupRequirement>? FileBackupRequirements { get; set; }
    [JsonPropertyName("registryExportRequirements")] public List<CleanupBackupRequirement>? RegistryExportRequirements { get; set; }
    [JsonPropertyName("serviceStateBackupRequirements")] public List<CleanupBackupRequirement>? ServiceStateBackupRequirements { get; set; }
    [JsonPropertyName("scheduledTaskBackupRequirements")] public List<CleanupBackupRequirement>? ScheduledTaskBackupRequirements { get; set; }
    [JsonPropertyName("startupEntryBackupRequirements")] public List<CleanupBackupRequirement>? StartupEntryBackupRequirements { get; set; }
    [JsonPropertyName("manifestExportRequired")] public bool ManifestExportRequired { get; set; }
}

public sealed class CleanupRestorePoint
{
    [JsonPropertyName("requiredBeforeFutureApply")] public bool RequiredBeforeFutureApply { get; set; }
    [JsonPropertyName("created")] public bool Created { get; set; }
    [JsonPropertyName("previewOnly")] public bool PreviewOnly { get; set; }
}

public sealed class CleanupBackupRequirement
{
    [JsonPropertyName("itemId")] public string? ItemId { get; set; }
    [JsonPropertyName("type")] public string? Type { get; set; }
    [JsonPropertyName("target")] public string? Target { get; set; }
    [JsonPropertyName("mode")] public string? Mode { get; set; }
    [JsonPropertyName("required")] public bool Required { get; set; }
    [JsonPropertyName("completed")] public bool Completed { get; set; }
    [JsonPropertyName("previewOnly")] public bool PreviewOnly { get; set; }
}
