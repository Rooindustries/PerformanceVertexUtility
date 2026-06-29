using System.Collections.Generic;

namespace Roo.OptimizationSuite.Models;

public static class RiskLevels
{
    public const string Safe = "safe";
    public const string Low = "low";
    public const string Medium = "medium";
    public const string High = "high";
    public const string Protected = "protected";
    public const string Blocked = "blocked";
    public const string Advanced = "advanced";
}

public sealed class IssueModel
{
    public string? Code { get; set; }
    public string? Message { get; set; }
    public string? Severity { get; set; }
    public string? Source { get; set; }
    public string? Target { get; set; }
    public bool Blocking { get; set; }
    public string? RecommendedAction { get; set; }
}

public sealed class LogEntry
{
    public string? TimestampUtc { get; set; }
    public string? Level { get; set; }
    public string? Message { get; set; }
}

public sealed class RecommendedAction
{
    public string? ActionId { get; set; }
    public string? Label { get; set; }
    public string? Risk { get; set; }
    public bool RequiresElevation { get; set; }
    public bool DryRun { get; set; }
    public string? Reason { get; set; }

    public string DisplayStatus => (Risk ?? string.Empty).ToLowerInvariant() switch
    {
        "medium" => "Review First",
        "safe" or "low" => "Safe Check",
        "high" => "Needs Attention",
        _ => "Review",
    };
}

public sealed class ProviderStatus
{
    public string? ProviderId { get; set; }
    public string? State { get; set; }
    public string? Quality { get; set; }
    public List<string>? Outputs { get; set; }

    public string DisplayName => (ProviderId ?? string.Empty).ToLowerInvariant() switch
    {
        "built-in-windows" => "Windows Sensors",
        "hwinfo64" => "HWiNFO64 Sensors",
        "presentmon" => "PresentMon",
        _ => string.IsNullOrWhiteSpace(ProviderId) ? "Sensor" : ProviderId,
    };

    public string DisplayState => (State ?? string.Empty).ToLowerInvariant() switch
    {
        "available" => "Connected",
        "optional-not-detected" => "Not Connected",
        "missing" => "Not Connected",
        "disabled" => "Off",
        _ => string.IsNullOrWhiteSpace(State) ? "Unknown" : State.Replace('-', ' '),
    };

    public string DisplayDetail => (ProviderId ?? string.Empty).ToLowerInvariant() switch
    {
        "built-in-windows" => "Process count, RAM, VRAM, and Windows memory load.",
        "hwinfo64" => "Optional sensor detail for thermals, power, and stability checks.",
        "presentmon" => "Frame pacing and FPS capture when live testing is enabled.",
        _ => Outputs is { Count: > 0 } ? string.Join(", ", Outputs) : "Optional live data source.",
    };
}
