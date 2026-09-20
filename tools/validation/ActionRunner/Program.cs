using RooIndustries.OptimizationSuite.Services;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("The action runner fixture requires Windows PowerShell.");
var root = Path.Combine(Path.GetTempPath(), "roo-industries-action-runner-" + Guid.NewGuid().ToString("N"));
var previous = Environment.GetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT");
try
{
    Directory.CreateDirectory(Path.Combine(root, "backend/samples"));
    var scripts = Path.Combine(root, "backend/scripts");
    Directory.CreateDirectory(scripts);
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", root);
    var service = new LiveDataService(new BackendLocator(), Path.Combine(root, "recovery"));
    var first = new ProcessProfileRecovery(Path.Combine(root, "backup-a.json"), "a");
    var second = new ProcessProfileRecovery(Path.Combine(root, "backup-b.json"), "b");
    service.ProcessProfileRecovery = first;
    var reopened = new LiveDataService(new BackendLocator(), Path.Combine(root, "recovery"));
    if (reopened.ProcessProfileRecovery != first) throw new InvalidOperationException("New service must reload the exact saved process recovery reference.");
    reopened.ProcessProfileRecovery = second;
    service.ClearProcessProfileRecovery(first.Path, first.Id);
    if (reopened.ProcessProfileRecovery != second) throw new InvalidOperationException("An older restore cannot clear a newer process recovery reference.");
    reopened.ClearProcessProfileRecovery(second.Path, second.Id);
    if (reopened.ProcessProfileRecovery is not null) throw new InvalidOperationException("Matching process recovery must clear after restore.");
    var script = Path.Combine(scripts, "fixture.ps1");
    await File.WriteAllTextAsync(script, "Write-Output '{\"status\":\"success\"}'; exit 7");
    var failed = await service.RunBackendScriptResultAsync("fixture.ps1");
    if (failed.Value?.Contains("success") != true || failed.Error?.Contains("code 7") != true || service.LastError != failed.Error)
        throw new InvalidOperationException("A failed command must preserve recovery output and its nonzero exit error.");
    if (await service.RunBackendScriptTextAsync("fixture.ps1") is not null)
        throw new InvalidOperationException("Text-only callers cannot receive failed output as successful data.");
    await File.WriteAllTextAsync(script, "Write-Output '{\"status\":\"success\"}'; exit 0");
    var success = await service.RunBackendScriptResultAsync("fixture.ps1");
    if (success.Value?.Contains("success") != true || success.Error is not null || service.LastError is not null)
        throw new InvalidOperationException("A successful command must clear the previous operation error.");
    Console.WriteLine("Passed native action runner checks: failed output, legacy caller, successful retry.");
}
finally
{
    Environment.SetEnvironmentVariable("ROO_INDUSTRIES_BACKEND_ROOT", previous);
    if (Directory.Exists(root)) Directory.Delete(root, true);
}
