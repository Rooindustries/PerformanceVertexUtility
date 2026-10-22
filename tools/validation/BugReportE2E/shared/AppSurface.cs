using RooIndustries.OptimizationSuite.Services;
namespace RooIndustries.OptimizationSuite;
public sealed record FixtureLiveResult(string? Value, string? Error);
public sealed class FixtureLive
{
    public string? LastError { get; set; } = @"C:\Users\" + @"Zqx Bob O'Neil\AppData\prior.log";
    public Task<FixtureLiveResult> RunBackendScriptResultAsync(string script)
    {
        if (script != "Get-BugReportSpecs.ps1") throw new InvalidOperationException("Unexpected backend entry");
        return Task.FromResult(new FixtureLiveResult("{\"windows\":\"Fixture Windows\",\"cpu\":\"Fixture CPU\"}", null));
    }
}
public sealed class FixtureOperations
{
    public Task<RooIndustries.Optimizer.TweakRecovery> ReadWindowsRecoveryAsync()
        => Task.FromException<RooIndustries.Optimizer.TweakRecovery>(new IOException(@"C:\Users\" + @"Zqx Bob O'Neil\AppData\recovery.log"));
}
public partial class App
{
    public static FixtureLive Live { get; } = new();
    public static FixtureOperations Operations { get; } = new();
    public static BugReportService BugReports { get; set; } = null!;
    public static string VersionText => "0.10.0-beta fixture";
}
