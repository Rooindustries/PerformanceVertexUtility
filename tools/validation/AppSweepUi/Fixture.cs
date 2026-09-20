using System.Text.Json;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite
{
    public static class App
    {
        public static Services.FakeLiveDataService Live { get; } = new();
        public static Services.FakeOptimizerService Operations { get; } = new();
        public static Services.SampleDataService Data { get; } = new();
    }
}

namespace RooIndustries.OptimizationSuite.Services
{
    public sealed class SampleDataService;
    public sealed record ProcessControlReview(ProcessControlPreview Plan, string PreviewPath, string Hash, string JournalPath);
    public sealed record PolicyWorkerRegistration(string TaskName, bool Registered, bool RunAtLogon, PolicyWorkerStatus Worker);

    public sealed class FakeLiveDataService
    {
        public ProcessInventory? Inventory { get; set; }
        public ProcessClassification? Classification { get; set; }
        public string? LastError { get; set; }
        public Task<ProcessInventory?> GetProcessInventoryAsync(CancellationToken cancellationToken = default) => Task.FromResult(Inventory);
        public Task<ProcessClassification?> GetProcessClassificationAsync(CancellationToken cancellationToken = default) => Task.FromResult(Classification);
    }

    public sealed class FakeOptimizerService
    {
        public ProcessControlSnapshot? ProcessSnapshot { get; set; }
        public string? FindLastJournal(string kind) => null;
        public Task<ProcessControlSnapshot> ReadProcessControlsAsync(int processId)
            => Task.FromResult(ProcessSnapshot ?? throw new InvalidOperationException("Process snapshot fixture is missing."));
        public Task<ProcessControlReview> PreviewControlsAsync(int processId, Dictionary<string, JsonElement> controls, CpuSelection? selection)
            => throw new InvalidOperationException("Unexpected preview call.");
        public Task<ProcessControlJournal> ApplyControlsAsync(ProcessControlReview review)
            => throw new InvalidOperationException("Unexpected apply call.");
        public Task<ProcessControlJournal> RestoreControlsAsync(string journalPath)
            => throw new InvalidOperationException("Unexpected restore call.");
        public Task<SavedProcessRule[]> ReadRulesAsync() => Task.FromResult(Array.Empty<SavedProcessRule>());
        public Task<PolicyWorkerStatus> ReadPolicyStatusAsync() => Task.FromResult(new PolicyWorkerStatus(null, false, null));
        public Task<SavedProcessRule> SaveRuleAsync(SavedProcessRule rule) => Task.FromResult(rule);
        public Task<JsonElement> DeleteRuleAsync(string ruleId) => Task.FromResult(JsonSerializer.SerializeToElement(new { }));
        public Task<PolicyWorkerRegistration> PolicyWorkerAsync(string action)
            => Task.FromResult(new PolicyWorkerRegistration("fixture", false, false, new PolicyWorkerStatus(null, false, null)));
    }
}

namespace RooIndustries.OptimizationSuite.ViewModels
{
    public sealed record CpuProcessChoice(int Id, string Name)
    {
        public override string ToString() => Name;
    }
}
