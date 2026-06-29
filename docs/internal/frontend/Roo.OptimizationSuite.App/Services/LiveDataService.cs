using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Roo.OptimizationSuite.Models;

namespace Roo.OptimizationSuite.Services;

public sealed class LiveDataService
{
    private readonly BackendLocator _locator;

    private static readonly JsonSerializerOptions JsonOptions = JsonTolerance.CreateOptions();

    public LiveDataService(BackendLocator locator)
    {
        _locator = locator;
    }

    public string? ScriptsDirectory => _locator.RepoRoot is null
        ? null
        : Path.Combine(_locator.RepoRoot, "backend", "scripts");

    public bool ScriptsAvailable => ScriptsDirectory is not null && Directory.Exists(ScriptsDirectory);

    public string? LastError { get; private set; }
    public string? RepoRoot => _locator.RepoRoot;

    public Task<ProcessInventory?> GetProcessInventoryAsync(CancellationToken ct = default)
        => RunAsync<ProcessInventory>("Get-ProcessInventory.ps1", ct);

    public Task<ProcessClassification?> GetProcessClassificationAsync(CancellationToken ct = default)
        => RunAsync<ProcessClassification>("Get-ProcessClassification.ps1", ct);

    public Task<DriverHardwareSummary?> GetDriverHardwareAsync(CancellationToken ct = default)
        => RunAsync<DriverHardwareSummary>("Get-DriverHardwareSummary.ps1", ct);

    public Task<InstalledAppInventory?> GetInstalledAppsAsync(CancellationToken ct = default)
        => RunAsync<InstalledAppInventory>("Get-InstalledAppInventory.ps1", ct);

    public Task<LeftoverScan?> GetLeftoverScanAsync(string appId, CancellationToken ct = default)
        => RunAsync<LeftoverScan>("Preview-LeftoverScan.ps1", ct, "-AppId '" + appId.Replace("'", "''") + "'");

    private async Task<T?> RunAsync<T>(string scriptFile, CancellationToken ct, string extraArgs = "") where T : class
    {
        var dir = ScriptsDirectory;
        if (dir is null)
        {
            LastError = "Repo root not resolved (RepoRoot=" + (RepoRoot ?? "null") + ")";
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
        var arguments =
            $"-NoProfile -ExecutionPolicy Bypass -Command \"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '{scriptPath}'{tail}\"";

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = _locator.RepoRoot ?? Environment.CurrentDirectory,
        };

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
        if (string.IsNullOrWhiteSpace(stdout) && !string.IsNullOrWhiteSpace(stderr))
        {
            LastError = stderr.Trim();
        }

        return stdout;
    }

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
