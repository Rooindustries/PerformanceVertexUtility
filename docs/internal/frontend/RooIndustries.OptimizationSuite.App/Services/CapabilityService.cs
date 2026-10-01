using System;
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

public sealed class CapabilityService
{
    private readonly BackendLocator _locator;

    private static readonly JsonSerializerOptions JsonOptions = JsonTolerance.CreateOptions();

    private static readonly Dictionary<string, string> PageNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Game Tune"] = "Process Controls",
        ["Clean Junk"] = "Clean Junk",
        ["Drivers & Settings"] = "Drivers & NVIDIA",
        ["Live Feel"] = "System Tweaks",
    };

    private static readonly Dictionary<string, string> ApplyStatusText = new(StringComparer.OrdinalIgnoreCase)
    {
        ["live"] = "Ready — can be applied and restored",
        ["fixture-proven"] = "Tested on a safe copy",
        ["allowlist-shim"] = "Runs the app's own tool",
        ["helper-contract"] = "Helper packaging pending",
        ["preview-only"] = "Review only — no changes yet",
        ["not-implemented"] = "Not wired up yet",
    };

    private static readonly Dictionary<string, string> ApplyDotState = new(StringComparer.OrdinalIgnoreCase)
    {
        ["live"] = "safe",
        ["fixture-proven"] = "low",
        ["allowlist-shim"] = "low",
        ["helper-contract"] = "protected",
        ["preview-only"] = "protected",
        ["not-implemented"] = "neutral",
    };

    private static readonly Dictionary<string, string> RestoreStatusText = new(StringComparer.OrdinalIgnoreCase)
    {
        ["live"] = "Reversible",
        ["fixture-proven"] = "Reversible",
        ["manifest-ready"] = "Restore plan ready",
        ["not-applicable"] = "No undo needed",
        ["not-implemented"] = "—",
    };

    private static readonly Dictionary<string, string> ReasonText = new(StringComparer.OrdinalIgnoreCase)
    {
        ["hardware-not-present"] = "Not available here — no matching hardware on this PC",
        ["tool-not-present"] = "Tool not installed at the expected path",
        ["not-safely-executable-yet"] = "Not routed yet — see next step",
        ["helper-packaging-pending"] = "Helper packaging pending",
    };

    public CapabilityService(BackendLocator locator)
    {
        _locator = locator;
    }

    public string? LastError { get; private set; }

    public async Task<IReadOnlyList<CapabilityRow>> GetCapabilitiesAsync()
    {
        CapabilityRegistryResponse? registry = null;

        if (_locator.ScriptsAvailable)
        {
            registry = await RunAsync<CapabilityRegistryResponse>(
                "Get-RooIndustriesCapabilityRegistry.ps1",
                string.Empty,
                CancellationToken.None).ConfigureAwait(false);
        }

        registry ??= await LoadSampleRegistryAsync().ConfigureAwait(false);
        return (registry.Capabilities ?? new List<RegistryCapability>())
            .Select(ProjectRow)
            .ToList();
    }

    public IReadOnlyList<CapabilityRow> ForPage(string page, IReadOnlyList<CapabilityRow> all)
        => all.Where(row => string.Equals(row.Page, page, StringComparison.OrdinalIgnoreCase)).ToList();

    public Task<CapabilityRouterResponse?> ExplainAsync(string capabilityId)
        => RouteAsync(capabilityId, "explain", confirm: false);

    public Task<CapabilityRouterResponse?> PreviewAsync(string capabilityId)
        => RouteAsync(capabilityId, "preview", confirm: false);

    public Task<CapabilityRouterResponse?> StatusAsync(string capabilityId)
        => RouteAsync(capabilityId, "status", confirm: false);

    public Task<CapabilityRouterResponse?> ApplyAsync(string capabilityId)
        => RouteAsync(capabilityId, "apply", confirm: true);

    public Task<CapabilityRouterResponse?> RestoreAsync(string capabilityId)
        => RouteAsync(capabilityId, "restore", confirm: true);

    private Task<CapabilityRouterResponse?> RouteAsync(string capabilityId, string action, bool confirm)
    {
        if (string.IsNullOrWhiteSpace(capabilityId) || !_locator.ScriptsAvailable)
        {
            return Task.FromResult<CapabilityRouterResponse?>(null);
        }

        var args = "-CapabilityId " + QuotePowerShellString(capabilityId) + " -Action " + action;
        if (confirm)
        {
            args += " -ConfirmApply";
        }

        return RunAsync<CapabilityRouterResponse>("Invoke-RooIndustriesCapability.ps1", args, CancellationToken.None);
    }

    private async Task<CapabilityRegistryResponse> LoadSampleRegistryAsync()
    {
        var dir = _locator.SamplesDirectory;
        if (dir is null)
        {
            throw new SampleDataException(
                "Backend sample directory could not be located. Set ROO_INDUSTRIES_BACKEND_ROOT to the repository root.");
        }

        var path = Path.Combine(dir, "capability-registry.sample.json");
        if (!File.Exists(path))
        {
            throw new SampleDataException("Sample file not found: capability-registry.sample.json");
        }

        try
        {
            await using var stream = File.OpenRead(path);
            var result = await JsonSerializer.DeserializeAsync<CapabilityRegistryResponse>(stream, JsonOptions)
                .ConfigureAwait(false);
            return result ?? throw new SampleDataException(
                "Sample file deserialized to null: capability-registry.sample.json");
        }
        catch (JsonException ex)
        {
            throw new SampleDataException("Sample file is not valid JSON: capability-registry.sample.json", ex);
        }
    }

    private async Task<T?> RunAsync<T>(string scriptFile, string extraArgs, CancellationToken ct) where T : class
    {
        var elapsed = Stopwatch.StartNew();
        T? result = null;
        try { return result = await RunCapabilityAsync<T>(scriptFile, extraArgs, ct).ConfigureAwait(false); }
        finally { AppLog.Timing(scriptFile, elapsed, result is null ? "failed" : "completed"); }
    }

    private async Task<T?> RunCapabilityAsync<T>(string scriptFile, string extraArgs, CancellationToken ct) where T : class
    {
        using var change = extraArgs.Contains("-ConfirmApply", StringComparison.Ordinal) ? DataGeneration.BeginChange() : null;
        var dir = _locator.ScriptsDirectory;
        if (dir is null)
        {
            LastError = "Repo root not resolved.";
            return null;
        }

        var scriptPath = Path.Combine(dir, scriptFile);
        if (!File.Exists(scriptPath))
        {
            LastError = "Script not found: " + scriptPath;
            return null;
        }

        try
        {
            var json = await RunScriptAsync(scriptPath, extraArgs, ct).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(json))
            {
                LastError = "Empty output from " + scriptFile;
                return null;
            }

            return JsonSerializer.Deserialize<T>(json, JsonOptions);
        }
        catch (Exception ex)
        {
            LastError = scriptFile + ": " + ex.GetType().Name + ": " + ex.Message;
            return null;
        }
    }

    private async Task<string?> RunScriptAsync(string scriptPath, string extraArgs, CancellationToken ct)
    {
        var tail = string.IsNullOrWhiteSpace(extraArgs) ? string.Empty : " " + extraArgs;
        var script = QuotePowerShellString(scriptPath);
        var arguments =
            $"-NoProfile -ExecutionPolicy Bypass -Command \"{RooIndustries.Optimizer.RuntimeEnvironment.PowerShellPrelude}[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & {script}{tail}\"";

        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = _locator.RepoRoot ?? Environment.CurrentDirectory,
        };
        RooIndustries.Optimizer.RuntimeEnvironment.Apply(psi);

        using var process = new Process { StartInfo = psi };
        if (!process.Start())
        {
            return null;
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));

        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            LastError = "Timed out running " + Path.GetFileName(scriptPath);
            return null;
        }

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            LastError = string.IsNullOrWhiteSpace(stderr)
                ? Path.GetFileName(scriptPath) + " exited with code " + process.ExitCode.ToString(System.Globalization.CultureInfo.InvariantCulture)
                : stderr.Trim();
            return null;
        }

        if (string.IsNullOrWhiteSpace(stdout) && !string.IsNullOrWhiteSpace(stderr))
        {
            LastError = stderr.Trim();
        }

        return stdout;
    }

    private static CapabilityRow ProjectRow(RegistryCapability capability)
    {
        var capabilityId = FirstNonBlank(capability.CapabilityId, "unknown-capability");
        var label = FirstNonBlank(capability.FrontendLabel, capability.DisplayName, capabilityId);
        var family = FirstNonBlank(capability.Family, "unknown");
        var page = ResolvePageName(capability.FrontendTab);
        var riskLevel = FirstNonBlank(capability.RiskLevel, "neutral").ToLowerInvariant();
        var machineAvailable = capability.ResolvedAvailability?.Available ?? false;
        var applyStatus = FirstNonBlank(capability.Apply?.Status, "not-implemented").ToLowerInvariant();
        var applyText = machineAvailable ? TextForApplyStatus(applyStatus) : "Not available here";
        var approvalText = capability.ApprovalRequired ? "Needs your go-ahead" : string.Empty;
        var restoreText = TextForRestoreStatus(capability.Restore?.Status);
        var reason = ReasonFor(capability, machineAvailable, applyStatus);
        var dotState = machineAvailable ? DotStateFor(applyStatus) : "neutral";

        return new CapabilityRow(
            capabilityId,
            label,
            family,
            page,
            riskLevel,
            machineAvailable,
            applyText,
            machineAvailable ? applyStatus : "unavailable",
            approvalText,
            restoreText,
            reason,
            dotState);
    }

    private static string ResolvePageName(string? frontendTab)
    {
        var key = Clean(frontendTab);
        if (key is not null && PageNames.TryGetValue(key, out var page))
        {
            return page;
        }

        return FirstNonBlank(frontendTab, "Dashboard");
    }

    private static string TextForApplyStatus(string status)
        => ApplyStatusText.TryGetValue(status, out var text) ? text : status.Replace('-', ' ');

    private static string TextForRestoreStatus(string? status)
    {
        var key = Clean(status);
        if (key is null)
        {
            return "—";
        }

        return RestoreStatusText.TryGetValue(key, out var text) ? text : key.Replace('-', ' ');
    }

    private static string DotStateFor(string status)
        => ApplyDotState.TryGetValue(status, out var dotState) ? dotState : "neutral";

    private static string ReasonFor(RegistryCapability capability, bool machineAvailable, string applyStatus)
    {
        if (!machineAvailable)
        {
            return TranslateReason(FirstNonBlank(
                capability.ResolvedAvailability?.UnavailableReason,
                capability.UnavailableReason,
                "not-available"));
        }

        var unavailableReason = Clean(capability.UnavailableReason);
        if (unavailableReason is not null)
        {
            return TranslateReason(unavailableReason);
        }

        if (IsStatusOnly(applyStatus))
        {
            return FirstNonBlank(capability.Apply?.Notes, TextForApplyStatus(applyStatus));
        }

        return string.Empty;
    }

    private static bool IsStatusOnly(string applyStatus)
        => applyStatus is "helper-contract" or "preview-only" or "not-implemented";

    private static string TranslateReason(string reason)
    {
        var clean = FirstNonBlank(reason, "not-available");
        if (clean.StartsWith("requires-admin-token", StringComparison.OrdinalIgnoreCase))
        {
            return "Needs administrator permission";
        }

        return ReasonText.TryGetValue(clean, out var text) ? text : clean.Replace('-', ' ');
    }

    private static string FirstNonBlank(params string?[] values)
    {
        foreach (var value in values)
        {
            var clean = Clean(value);
            if (clean is not null)
            {
                return clean;
            }
        }

        return string.Empty;
    }

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrWhiteSpace(clean) ? null : clean;
    }

    private static string QuotePowerShellString(string value)
        => "'" + value.Replace("'", "''") + "'";

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
        }
    }
}
