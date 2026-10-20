using System.Text.Json;
using System.Text.Json.Nodes;
using RooIndustries.Optimizer;

static class CatalogIntegrationChecks
{
    public static void Run(string root, TweakCatalog catalog, Action<bool, string> check, Action<Action, string> reject)
    {
        var document = JsonDocument.Parse("""
        {"switches":{
          "extensions":{"Type":"Registry","Header":"File extensions","Params":{"Section":"User","Path":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced","Name":"HideFileExt","ValueOn":"1","ValueOff":"0","ValueKind":"DWord"}},
          "policy":{"Type":"Gp","Header":"Fixture policy","Params":{"Section":"User","Path":"Software\\RooIndustriesConstructorFixture","Name":"Policy","ValueOff":"0"}},
          "service":{"Type":"Service","Params":{"Name":"FixtureService","DefaultStartup":"3","DefaultRun":"false"}},
          "task":{"Type":"Scheduler","Header":"Fixture task","Params":{"Path":"Fixture","Name":"Task"}}
        }}
        """);
        var definitions = CustomTweaks.ParseConstructor(document.RootElement); var merged = CustomTweaks.Merge(catalog, definitions);
        check(definitions.Length == 4 && merged.Presets.Length == catalog.Presets.Length + 8, "All four constructor types produce explicit on/off presets");
        var shared = merged.Presets.Where(preset => preset.Name.StartsWith("File extensions ·")).ToArray();
        check(shared.Length == 2 && shared.All(preset => preset.Selections.Single().SettingId == "explorer.file-extensions"), "Imported controls reuse the existing atomic setting instead of duplicating it");
        var malformed = JsonNode.Parse(document.RootElement.GetRawText())!;
        malformed["switches"]!["extensions"]!["Params"]!["Script"] = "unreviewed";
        reject(() => CustomTweaks.ParseConstructor(JsonSerializer.SerializeToElement(malformed)), "Unknown constructor parameters cannot become hidden commands");
        foreach (var edition in new[] { "ProfessionalEducation", "ProfessionalEducationN", "ProfessionalWorkstationN", "EnterpriseSN" })
        {
            var editionStore = FileTweakStore.Create(Path.Combine(root, "edition-" + edition + ".json"), 26200, edition);
            var settings = catalog.Settings.Where(setting => setting.Id is "privacy.activity-feed" or "windows.953a30d8b6c2c8a5").ToArray();
            var statuses = new TweakEngine(catalog with { Settings = settings, Presets = [], Incompatible = null }, editionStore).Detect().Settings;
            check(settings.Length == 2 && statuses.All(status => status.Supported && status.AvailableChoices is { Length: > 0 }), "Group Policy privacy and driver settings are available on " + edition + " like on Pro");
        }
        var path = Path.Combine(root, "product-gates.json"); var store = FileTweakStore.Create(path);
        var fixture = OperationFiles.Read<TweakFixture>(path); OperationFiles.Write(path, fixture with { EdgeMajor = 87 });
        var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesProductFixture", "value", "Choice");
        TweakDefinition Setting(string id, string? requirement) => new(id, id, "Fixture", "Fixture", 10240, 26200, ["*"], "none",
            [new("on", "On", [new(address with { ValueName = id }, 1)], Availability: [new(10240, 26200, ["*"], requirement is null ? null : [requirement])])], [new("Roo Industries", "fixture", "product applicability")]);
        var scoped = new TweakCatalog(1, "gates", [Setting("legacy", "edge:77:87"), Setting("modern", "edge:99:999"), Setting("always", null)],
            [new("available", "Available settings", [new("modern", "on"), new("always", "on")], true)]);
        var engine = new TweakEngine(scoped, store); var detected = engine.Detect();
        check(detected.Settings.Single(item => item.Id == "legacy").Supported && !detected.Settings.Single(item => item.Id == "modern").Supported, "Browser-version gates distinguish Edge87 from a newer policy requirement");
        reject(() => engine.Preview("unsupported", [new("modern", "on")]), "A favorable Windows version cannot override an unsupported browser version");
        var available = engine.PreviewPreset("available", "available");
        check(available.Selections.Length == 1 && available.Skipped.SequenceEqual(new[] { "modern" }), "Available-only presets report unsupported settings they omit");
        var review = Path.Combine(root, available.OperationId + ".json"); OperationFiles.Write(review, available);
        OperationFiles.Write(path, OperationFiles.Read<TweakFixture>(path) with { EdgeMajor = 120 });
        reject(() => engine.Apply(review, OperationFiles.HashFile(review)), "A preset's changed product applicability requires a new review");
        check(OperationFiles.Read<TweakFixture>(path).Writes == 0, "An applicability change leaves settings and recovery state untouched");
        reject(() => TweakProducts.CheckEdge("edge:77:87", null), "Missing browser-version evidence is not a supported default");
        reject(() => TweakProducts.CheckEdge("edge:77:87", 88), "A policy's maximum browser version is enforced");
        var expired = scoped with { Settings = [scoped.Settings[2] with { Options = [scoped.Settings[2].Options[0] with { ValidUntilUtc = new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc) }] }], Presets = [] };
        reject(() => new TweakEngine(expired, store).Preview("expired", [new("always", "on")]), "A retired provider choice cannot be applied after its expiry");
        path = Path.Combine(root, "recall-warning.json"); store = FileTweakStore.Create(path);
        var recall = Setting("recall", null) with { Options = [new("off", "Off", [new(new("CurrentUser", "Registry64", @"SOFTWARE\Policies\Microsoft\Windows\WindowsAI", "value", "DisableAIDataAnalysis"), 1)])] };
        engine = new(new(1, "recall", [recall], []), store);
        var loss = engine.Preview("recall", [new("recall", "off")]); review = Path.Combine(root, loss.OperationId + ".json"); OperationFiles.Write(review, loss);
        check(loss.DataLoss.Length == 1, "Recall data-loss warning is derived from the actual target even without catalog annotations");
        reject(() => engine.Apply(review, OperationFiles.HashFile(review)), "Ordinary apply confirmation cannot omit the data-loss acknowledgement");
        check(OperationFiles.Read<TweakFixture>(path).Writes == 0, "Unacknowledged data effects do not mutate fixture settings");
        engine.Apply(review, OperationFiles.HashFile(review), acceptDataLoss: true);
        var restore = engine.Preview("recall", []);
        check(restore.DataLoss.Single().Contains("cannot be restored"), "Restoring policy values cannot claim restoration of previously deleted data");
        var before = new WindowsRestorePoint(7, "Existing point", DateTime.UtcNow.AddHours(-1));
        var requested = new WindowsRestorePoint(8, "Requested point", DateTime.UtcNow);
        check(!RestorePoints.Verify([before], [before], "Requested point", 7, true).Created, "A successful API return with an existing point does not prove a new backup");
        check(!RestorePoints.Verify([before], [before, requested], "Requested point", 8, false).Created, "An unfinished restore-point operation cannot count as a verified backup");
        check(RestorePoints.Verify([before], [before, requested], "Requested point", 8, true).Created, "Restore-point success requires matching new identity and completed creation");
    }
}
