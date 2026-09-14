using System.Text.Json;
using Roo.OptimizationSuite.Services;

var repo = Path.GetFullPath(args[0]);
var fixture = Path.Combine(Path.GetTempPath(), "roo-client-boundary-" + Guid.NewGuid().ToString("N"));
var previousRoot = Environment.GetEnvironmentVariable("ROO_BACKEND_ROOT");
string? recoveryRoot = null;
LiveDataService? service = null;
void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
    Console.WriteLine("PASS " + message);
}
try
{
    var scripts = Path.Combine(fixture, "backend", "scripts");
    Directory.CreateDirectory(scripts);
    Directory.CreateDirectory(Path.Combine(fixture, "backend", "samples"));
    foreach (var name in new[] { "Invoke-UninstallCleanupApplyPackage.ps1", "Restore-UninstallCleanupExecution.ps1", "UninstallCleanup.Common.ps1", "BackendExecutor.Common.ps1", "ProcessProfile.Common.ps1" })
        File.Copy(Path.Combine(repo, "backend", "scripts", name), Path.Combine(scripts, name));
    File.WriteAllText(Path.Combine(scripts, "Preview-OfficialUninstall.ps1"), "param([string]$AppId)\nGet-Content -LiteralPath (Join-Path $PSScriptRoot 'official.json') -Raw -Encoding UTF8\n");
    File.WriteAllText(Path.Combine(scripts, "New-CleanupDeletionManifest.ps1"), "param([string]$AppId)\nGet-Content -LiteralPath (Join-Path $PSScriptRoot 'cleanup.json') -Raw -Encoding UTF8\n");
    var original = Path.Combine(fixture, "reviewed.txt");
    var later = Path.Combine(fixture, "unreviewed.txt");
    File.WriteAllText(original, "reviewed original");
    File.WriteAllText(later, "unreviewed original");
    const string appId = "fixture:client-boundary";
    var official = new { actionId = "apps.previewOfficialUninstall", commands = new[] { new { appId, blocked = false, @protected = false, reviewRequired = true, executable = (string?)null } }, errors = Array.Empty<object>() };
    File.WriteAllText(Path.Combine(scripts, "official.json"), JsonSerializer.Serialize(official));
    object Manifest(string target) => new { manifestId = "client-review", appId, items = new[] { new { itemId = "reviewed", type = "file", target, @protected = false } }, errors = Array.Empty<object>() };
    File.WriteAllText(Path.Combine(scripts, "cleanup.json"), JsonSerializer.Serialize(Manifest(original)));
    Environment.SetEnvironmentVariable("ROO_BACKEND_ROOT", fixture);
    service = new LiveDataService(new BackendLocator());
    Check(await service.GetOfficialUninstallPreviewAsync(appId) is not null, "Client reads the reviewed removal route");
    Check(await service.GetCleanupManifestAsync(appId) is not null, "Client reads the reviewed cleanup list");
    // Change the discovery response after review; execution must still use the approved snapshot.
    File.WriteAllText(Path.Combine(scripts, "cleanup.json"), JsonSerializer.Serialize(Manifest(later)));
    var json = await service.RequestUninstallCleanupApplyTextAsync(appId, true, true, true);
    Check(!string.IsNullOrWhiteSpace(json), "Client receives the real executor result");
    using var applied = JsonDocument.Parse(json!);
    var status = applied.RootElement.GetProperty("status").GetString();
    if (status != "success") Console.WriteLine(json);
    Check(status == "success", "Client app identity, hashes and approvals satisfy the executor");
    Check(!File.Exists(original) && File.Exists(later), "Apply removes only the reviewed target after discovery changes");
    var rollback = applied.RootElement.GetProperty("rollback").GetProperty("rollbackManifestPath").GetString()!;
    recoveryRoot = Path.GetDirectoryName(rollback);
    Check(service.LastCleanupRollbackPath == rollback && File.Exists(rollback), "Client retains the durable recovery location");
    var restored = await service.RestoreUninstallCleanupTextAsync(rollback);
    using var restore = JsonDocument.Parse(restored!);
    Check(restore.RootElement.GetProperty("status").GetString() == "success" && File.ReadAllText(original) == "reviewed original", "Client restores the original bytes through the real restore command");
    service.DiscardCleanupReview();
    Check(await service.RequestUninstallCleanupApplyTextAsync(appId, true, true, true) is null && File.Exists(later), "Discarded approval cannot be reused to remove newly discovered files");
}
finally
{
    Environment.SetEnvironmentVariable("ROO_BACKEND_ROOT", previousRoot);
    recoveryRoot ??= service?.LastCleanupRollbackPath is { } savedPath ? Path.GetDirectoryName(savedPath) : null;
    if (recoveryRoot is not null && Directory.Exists(recoveryRoot)) Directory.Delete(recoveryRoot, true);
    if (Directory.Exists(fixture)) Directory.Delete(fixture, true);
}
