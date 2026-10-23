using RooIndustries.Optimizer;

static class PolicyEditionChecks
{
    public static void Run(string root, TweakCatalog catalog, Action<bool, string> check, Action<Action, string> reject)
    {
        var definition = catalog.Settings.Single(setting => setting.Id == "windows.a8268996c3eb9072");
        var blocked = definition.Options.Single(option => option.Changes.Single().Dword == 1);
        var remove = definition.Options.Single(option => option.Changes.Single().Dword is null);
        var address = blocked.Changes.Single().Address;
        var selected = new TweakSelection(definition.Id, blocked.Id);
        var subset = catalog with { Settings = [definition], Presets = [], Incompatible = null };
        void Seed(string path, uint value)
        {
            var fixture = OperationFiles.Read<TweakFixture>(path);
            var parts = address.KeyPath.Split('\\');
            for (var count = 1; count <= parts.Length; count++)
            {
                var key = @"\REGISTRY\MACHINE\" + string.Join('\\', parts.Take(count));
                fixture.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
            }
            fixture.Keys[(@"\REGISTRY\MACHINE\" + address.KeyPath).ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = new(address.ValueName, 4, BitConverter.GetBytes(value));
            OperationFiles.Write(path, fixture);
        }
        TweakApplyResult Apply(TweakEngine engine, TweakPlan plan)
        {
            var review = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(review, plan);
            var result = engine.Apply(review, OperationFiles.HashFile(review));
            check(engine.Apply(review, OperationFiles.HashFile(review)).Replayed, "Policy edition fixture apply can be replayed without a second change");
            return result;
        }
        foreach (var edition in new[] { "Professional", "Core", "CoreN", "CoreCountrySpecific", "CoreSingleLanguage", "ProfessionalN", "ProfessionalEducation", "ProfessionalEducationN", "ProfessionalWorkstation", "ProfessionalWorkstationN", "ProfessionalSingleLanguage", "Enterprise", "EnterpriseS", "EnterpriseN", "EnterpriseSN", "EnterpriseEval", "EnterpriseNEval", "EnterpriseSEval", "EnterpriseSNEval", "EnterpriseG", "EnterpriseGN", "Education", "EducationN", "IoTEnterprise", "IoTEnterpriseS", "ServerRdsh", "ServerStandard", "ServerDatacenter", "ServerStandardEval", "ServerDatacenterEval" })
        {
            var build = edition.StartsWith("Server") && edition != "ServerRdsh" ? 20348 : 26100;
            var path = Path.Combine(root, "consumer-" + edition + ".json"); var store = FileTweakStore.Create(path, build, edition); Seed(path, 1);
            var engine = new TweakEngine(subset, store); var status = engine.Detect().Settings.Single();
            var supported = edition.StartsWith("Enterprise") || edition.StartsWith("Education") || edition.StartsWith("IoTEnterprise") || edition.StartsWith("Server");
            check(status.Supported && status.Error is null && status.AvailableChoices!.Contains(remove.Id), "Consumer override removal stays available on " + edition);
            check(status.AvailableChoices!.Contains(blocked.Id) == supported, "Consumer blocking follows the registry policy's edition support on " + edition);
            check(status.ConfiguredChoices.Contains(blocked.Id) == supported && status.Observations.Single().Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)), "Stored consumer blocking is an applicable current choice only on supported editions: " + edition);
            if (supported) continue;
            var before = OperationFiles.HashFile(path);
            reject(() => engine.Preview("consumer", [selected]), "Explicit consumer blocking is refused on " + edition);
            check(OperationFiles.HashFile(path) == before, "An unavailable policy preview leaves the fixture untouched on " + edition);
            Apply(engine, engine.Preview("consumer", [new(definition.Id, remove.Id)]));
            check(store.Read(address).Value is null && engine.Detect().Settings.Single().ConfiguredChoices.SequenceEqual(new[] { remove.Id }), "A pre-existing blocked override can be removed on " + edition);
            Apply(engine, engine.Preview("consumer", []));
            check(store.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)), "Undo removal restores the exact prior consumer override on " + edition);
            Seed(path, 0);
            check(engine.Detect().Settings.Single().ConfiguredChoices.Length == 0, "An unrelated consumer policy value is not reported as Blocked on " + edition);
        }
        foreach (var build in new[] { 20348, 26100 })
        {
            var path = Path.Combine(root, "consumer-azure-" + build + ".json"); var store = FileTweakStore.Create(path, build, "ServerTurbine"); Seed(path, 0);
            var engine = new TweakEngine(subset, store);
            check(engine.Detect().Settings.Single().AvailableChoices!.Contains(blocked.Id), "Windows Server Azure Edition retains consumer blocking at build " + build);
            Apply(engine, engine.Preview("azure", [selected]));
            check(store.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(1u)), "Windows Server Azure Edition can apply its supported policy choice at build " + build);
            Apply(engine, engine.Preview("azure", []));
            check(store.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)), "Windows Server Azure Edition restores the exact original policy value at build " + build);
        }
        var proPath = Path.Combine(root, "consumer-profiles.json"); var proStore = FileTweakStore.Create(proPath, 26100, "Professional"); Seed(proPath, 0);
        var old = subset with { Settings = [definition with { Options = definition.Options.Select(option => option with { Availability = [new(10240, 26200, ["*"])] }).ToArray() }] };
        Apply(new(old, proStore), new TweakEngine(old, proStore).Preview("old-profile", [selected]));
        var current = new TweakEngine(subset, proStore);
        check(current.Detect().Settings.Single().ConfiguredChoices.Length == 0, "A profile applied with an old catalog cannot make an ignored policy look applicable");
        var singleton = catalog.Presets.First(preset => preset.Selections.SequenceEqual(new[] { selected }));
        check(catalog.Presets.Where(preset => preset.Id is "wpd.all-settings" or "wpd.recommended").All(preset => preset.AvailableOnly), "Existing available-only WPD presets retain their original filtering behavior");
        var beforeSingleton = OperationFiles.HashFile(proPath);
        reject(() => new TweakEngine(subset with { Presets = [singleton] }, proStore).PreviewPreset("old-profile", singleton.Id), "An entirely unavailable preset refuses instead of restoring an existing profile");
        check(OperationFiles.HashFile(proPath) == beforeSingleton, "An entirely unavailable preset preserves the old profile and override");
        Apply(current, current.Preview("old-profile", []));
        check(proStore.ReadState()!.Profiles.Length == 0 && proStore.Read(address).Value!.Bytes.SequenceEqual(BitConverter.GetBytes(0u)), "A profile from the old catalog still restores its exact original policy value");
        var choices = new TweakChoiceStore(Path.Combine(root, "consumer-saved.json"));
        var saved = choices.Save(catalog, "saved", [selected], null);
        var beforeSaved = OperationFiles.HashFile(proPath);
        reject(() => current.Preview("saved", saved.Profiles.Single().Selections), "Saved consumer blocking cannot bypass edition support when applied");
        check(choices.Read().Profiles.Single().Selections.SequenceEqual(new[] { selected }) && OperationFiles.HashFile(proPath) == beforeSaved, "Unavailable saved choices remain saved without changing Windows");
        check(choices.Save(catalog, "saved", [], saved.Revision).Profiles.Length == 0, "An unavailable saved choice can still be removed");
        var mixed = catalog.Presets.Single(preset => preset.Id == "gaming.consumer-features.35.disabled");
        var definitions = mixed.Selections.Select(selection => catalog.Resolve(selection).Definition).ToArray();
        var sibling = catalog.Resolve(mixed.Selections.First(selection => selection != selected)).Option.Changes.Single().Address;
        foreach (var (edition, unreadable) in new[] { ("Professional", sibling), ("Enterprise", sibling), ("Enterprise", address) })
        {
            var path = Path.Combine(root, "consumer-required-read-" + edition + "-" + (unreadable == address ? "consumer" : "sibling") + ".json");
            FileTweakStore.Create(path, 26100, edition);
            var engine = new TweakEngine(catalog with { Settings = definitions, Presets = [mixed], Incompatible = null }, new UnreadablePolicyStore(path, unreadable));
            var before = OperationFiles.HashFile(path);
            reject(() => engine.PreviewPreset("required", mixed.Id), "A strict source preset refuses an unreadable required " + (unreadable == address ? "consumer policy" : "sibling") + " on " + edition);
            check(OperationFiles.HashFile(path) == before, "A required read failure preserves all fixture values and recovery data on " + edition);
        }
        check(!mixed.AvailableOnly && !singleton.AvailableOnly, "Source presets skip only the constrained choice and keep their other choices required");
        foreach (var edition in new[] { "Professional", "Enterprise" })
        {
            var store = FileTweakStore.Create(Path.Combine(root, "consumer-preset-" + edition + ".json"), 26100, edition);
            var engine = new TweakEngine(catalog with { Settings = definitions, Presets = [mixed], Incompatible = null }, store);
            var plan = engine.PreviewPreset("mixed", mixed.Id);
            var skipped = edition == "Enterprise" ? [] : mixed.Selections.Where(selection => selection.SettingId is "windows.a8268996c3eb9072" or "windows.d09ccd0fee309f49" or "windows.9ba2fc5ad6c98df6").ToArray();
            var expected = mixed.Selections.Except(skipped).OrderBy(selection => selection.SettingId);
            check(plan.Selections.SequenceEqual(expected) && plan.Skipped.SequenceEqual(skipped.Select(selection => catalog.Resolve(selection).Definition.Name)),
                "The source preset keeps its required choices and reports all edition-limited choices as skipped on " + edition);
            Apply(engine, plan); Apply(engine, engine.Preview("mixed", []));
            check(store.ReadState()!.Profiles.Length == 0 && OperationFiles.Read<TweakFixture>(Path.Combine(root, "consumer-preset-" + edition + ".json")).Keys.Count == 0, "The edition-filtered source preset restores all fixture values and keys on " + edition);
        }
        var strict = catalog.Presets.Single(preset => preset.Id == "explorer-details");
        var strictEngine = new TweakEngine(catalog with { Settings = strict.Selections.Select(selection => catalog.Resolve(selection).Definition).ToArray(), Presets = [strict], Incompatible = null }, FileTweakStore.Create(Path.Combine(root, "consumer-unrelated.json"), 26100, "Professional"));
        check(!strict.AvailableOnly && strictEngine.PreviewPreset("strict", strict.Id).Selections.Length == strict.Selections.Length, "Unrelated strict presets retain every choice on Pro");
    }

    sealed class UnreadablePolicyStore(string path, RegistryAddress unreadable) : FileTweakStore(path), ITweakStore
    {
        public new TweakRead Read(RegistryAddress address) => address == unreadable ? throw new IOException("The required registry value could not be read.") : base.Read(address);
    }
}
