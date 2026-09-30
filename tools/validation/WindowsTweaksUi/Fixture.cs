using System.Text.Json;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite
{
    public static class App
    {
        public static Services.Fixture Operations { get; set; } = null!;
    }
}
namespace RooIndustries.OptimizationSuite.Services
{
    public sealed record WindowsTweakReview(TweakPlan Plan, string Path, string Hash);
    public sealed class Fixture
    {
        public TweakCatalog Catalog { get; }
        public TweakChoiceStore Choices { get; }
        public FileTweakStore Windows { get; }
        public TweakEngine Engine { get; }
        public bool Missing { get; set; } = true;
        public bool FailRead { get; set; }
        public bool FailApply { get; set; }
        public TweakRecovery? Recovery { get; set; }
        public int Applies { get; private set; }
        public int Previews { get; private set; }
        public int RecoveryReads { get; private set; }
        public int OwnershipPreviews { get; private set; }
        public TweakSelection[]? LastPreviewSelections { get; private set; }
        public Func<Task>? BeforePreview { get; set; }
        public Action? AfterApply { get; set; }
        private readonly string _root;
        public Fixture(string root, TweakCatalog? catalog = null)
        {
            _root = root; Directory.CreateDirectory(root);
            var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesUiModelFixture", "value", "Enabled");
            var setting = new TweakDefinition("setting", "Office setting", "Apps", "Fixture", 10240, 26200, ["*"], "none",
                [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Fixture", "fixture", "isolated UI validation")]);
            Catalog = catalog ?? new(1, "fixture", [setting], [new("fixture-preset", "Fixture preset", [new("setting", "off")])]);
            Choices = new(Path.Combine(root, "choices.json")); Windows = FileTweakStore.Create(Path.Combine(root, "windows.json"));
            if (catalog is not null)
            {
                var path = Path.Combine(root, "windows.json");
                OperationFiles.Write(path, OperationFiles.Read<TweakFixture>(path) with { EdgeMajor = 150, EdgeProfileMajor = 150, OfficeMajor = 16 });
            }
            Engine = new(Catalog, Windows);
        }
        public Task<TweakCatalogResult> ReadWindowsTweakCatalogAsync(bool fresh = false) => Task.FromResult(new TweakCatalogResult(Catalog, Catalog.Digest));
        public Task<TweakChoiceFile> ReadWindowsChoicesAsync() => Task.FromResult(Choices.Read());
        public Task<TweakChoiceFile> SaveWindowsChoicesAsync(TweakCatalog catalog, string id, TweakSelection[] selections, string? revision) => Task.FromResult(Choices.Save(catalog, id, selections, revision));
        public Task<TweakRecovery> ReadWindowsRecoveryAsync(bool fresh = false)
        {
            RecoveryReads++;
            return FailRead
                ? Task.FromException<TweakRecovery>(new IOException("Controlled recovery read failure"))
                : Task.FromResult(Recovery ?? new TweakRecovery(Windows.ReadState(), null, null));
        }
        public event Action<TweakInspection, long>? WindowsTweaksPartial;
        public (TweakInspection Inspection, long Generation)? PendingWindowsTweaks { get; private set; }
        public Func<Task>? BeforeStatus { get; set; }
        public void RaisePartial(TweakInspection partial, long generation) { PendingWindowsTweaks = (partial, generation); WindowsTweaksPartial?.Invoke(partial, generation); }
        public async Task<TweakInspection> ReadWindowsTweaksAsync(bool fresh = false, bool streamed = true)
        {
            if (BeforeStatus is not null) await BeforeStatus();
            PendingWindowsTweaks = null;
            var inspection = Engine.Detect();
            return Missing ? inspection with { Settings = [new("setting", "Office setting", false, [], [], "A supported Microsoft Office installation could not be identified.", [])] } : inspection;
        }
        public async Task<WindowsTweakReview> PreviewWindowsTweaksAsync(string id, TweakSelection[] selections)
        {
            Previews++;
            LastPreviewSelections = selections;
            if (BeforePreview is not null) await BeforePreview();
            var plan = Engine.Preview(id, selections); var path = Path.Combine(_root, plan.OperationId + ".json"); OperationFiles.Write(path, plan);
            return new(plan, path, OperationFiles.HashFile(path));
        }
        public Task<TweakApplyResult> ApplyWindowsTweaksAsync(WindowsTweakReview review, bool accepted)
        {
            Applies++;
            if (FailApply) throw new IOException("Controlled native apply failure");
            var result = Engine.Apply(review.Path, review.Hash, accepted); AfterApply?.Invoke(); return Task.FromResult(result);
        }
        public Task<JsonElement> RecoverWindowsTweaksAsync(string hash) => throw new InvalidOperationException("Unexpected recovery call");
        public Task<WindowsTweakReview> PreviewOwnershipAsync(string path)
        {
            OwnershipPreviews++;
            throw new InvalidOperationException("Unexpected ownership call");
        }
    }
}
