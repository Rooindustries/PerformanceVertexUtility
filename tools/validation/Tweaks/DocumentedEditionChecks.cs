using RooIndustries.Optimizer;

static class DocumentedEditionChecks
{
    static readonly string[] Editions = ["Core", "CoreN", "CoreCountrySpecific", "CoreSingleLanguage", "Professional", "ProfessionalN", "ProfessionalEducation", "ProfessionalWorkstation", "CloudEdition",
        "Enterprise", "EnterpriseS", "EnterpriseEval", "EnterpriseG", "Education", "EducationN", "IoTEnterprise", "IoTEnterpriseS", "ServerRdsh", "ServerStandard", "ServerDatacenter", "ServerTurbine"];

    public static void Run(string root, TweakCatalog catalog, Action<bool, string> check, Action<Action, string> reject)
    {
        var limited = new (string Name, string KeyPath, string ValueName, uint Value, bool Required)[]
        {
            ("Diagnostic data off", @"SOFTWARE\Policies\Microsoft\Windows\DataCollection", "AllowTelemetry", 0, true),
            ("Diagnostic data off in the Settings value", @"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection", "AllowTelemetry", 0, true),
            ("Windows tips off", @"SOFTWARE\Policies\Microsoft\Windows\CloudContent", "DisableSoftLanding", 1, false),
            ("Windows spotlight off", @"SOFTWARE\Policies\Microsoft\Windows\CloudContent", "DisableWindowsSpotlightFeatures", 1, false),
        };
        void Seed(string path, RegistryAddress address, uint value)
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
        uint? Dword(FileTweakStore store, RegistryAddress address) => store.Read(address).Value is { Type: 4 } data ? BitConverter.ToUInt32(data.Bytes) : null;
        void Apply(TweakEngine engine, TweakPlan plan)
        {
            var review = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(review, plan);
            engine.Apply(review, OperationFiles.HashFile(review));
            check(engine.Apply(review, OperationFiles.HashFile(review)).Replayed, "A documented edition fixture apply can be replayed without a second change");
        }
        var gated = new HashSet<TweakSelection>();
        for (var index = 0; index < limited.Length; index++)
        {
            var (name, keyPath, valueName, value, required) = limited[index];
            bool Same(TweakAssignment change) => change.Address.Hive == "LocalMachine" && string.Equals(change.Address.KeyPath, keyPath, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(change.Address.ValueName, valueName, StringComparison.OrdinalIgnoreCase);
            var definitions = catalog.Settings.Where(setting => setting.Options.Any(option => option.Changes is [var change] && Same(change) && change.Dword == value)).ToArray();
            check(definitions.Length == 1, name + " has exactly one catalog setting");
            var definition = definitions[0];
            var limitedOption = definition.Options.Single(option => option.Changes.Single().Dword == value);
            var remove = definition.Options.Single(option => option.Changes.Single() is { Dword: null, Value: null, Token: null, Bits: null, Formula: null });
            var equivalent = required ? definition.Options.SingleOrDefault(option => option.Changes.Single().Dword == 1) : null;
            check(!required || equivalent is { Name: "Required diagnostic data" }, name + " has a Required diagnostic data choice for the editions that ignore it");
            var address = limitedOption.Changes.Single().Address;
            var selected = new TweakSelection(definition.Id, limitedOption.Id);
            gated.Add(selected);
            var subset = catalog with { Settings = [definition], Presets = [], Incompatible = null };
            foreach (var edition in Editions)
            {
                var build = edition.StartsWith("Server", StringComparison.Ordinal) && edition != "ServerRdsh" ? 20348 : 26100;
                var path = Path.Combine(root, "documented-" + index + "-" + edition + ".json"); var store = FileTweakStore.Create(path, build, edition);
                var engine = new TweakEngine(subset, store); var status = engine.Detect().Settings.Single();
                var supported = new[] { "Enterprise", "Education", "IoTEnterprise", "Server" }.Any(family => edition.StartsWith(family, StringComparison.Ordinal));
                check(status.Supported && status.Error is null && status.AvailableChoices!.Contains(remove.Id), name + ": removing the override stays available on " + edition);
                check(status.AvailableChoices!.Contains(limitedOption.Id) == supported, name + " is offered only where Windows honors it: " + edition);
                if (equivalent is not null) check(status.AvailableChoices!.Contains(equivalent.Id), "Required diagnostic data is offered on " + edition);
                if (!supported)
                {
                    var before = OperationFiles.HashFile(path);
                    reject(() => engine.Preview("documented", [selected]), name + " is refused on " + edition);
                    check(OperationFiles.HashFile(path) == before, "A refused " + name + " preview leaves Windows untouched on " + edition);
                }
                if ((supported ? limitedOption : equivalent) is not { } choice) continue;
                Apply(engine, engine.Preview("documented", [new(definition.Id, choice.Id)]));
                check(Dword(store, address) == choice.Changes.Single().Dword && engine.Detect().Settings.Single().ConfiguredChoices.SequenceEqual(new[] { choice.Id }), name + ": " + choice.Name + " applies and reads back on " + edition);
                Apply(engine, engine.Preview("documented", []));
                check(store.Read(address).Value is null && store.ReadState()!.Profiles.Length == 0, name + ": undo removes " + choice.Name + " again on " + edition);
            }
            foreach (var edition in new[] { "Core", "Professional" })
            {
                var path = Path.Combine(root, "documented-" + index + "-old-" + edition + ".json"); var store = FileTweakStore.Create(path, 26100, edition);
                var original = value == 0 ? 3u : 0u;
                Seed(path, address, original);
                var old = subset with { Settings = [definition with { Options = definition.Options.Select(option => option with { Availability = [new(10240, 26200, ["*"])] }).ToArray() }] };
                var oldEngine = new TweakEngine(old, store);
                Apply(oldEngine, oldEngine.Preview("old-profile", [selected]));
                check(Dword(store, address) == value, name + " was applied on " + edition + " by a catalog from before this update");
                var current = new TweakEngine(subset, store); var status = current.Detect().Settings.Single();
                check(!status.ConfiguredChoices.Contains(limitedOption.Id) && status.AvailableChoices!.Contains(remove.Id), name + " applied before this update no longer reads as an applicable choice on " + edition);
                Apply(current, current.Preview("old-profile", []));
                check(Dword(store, address) == original && store.ReadState()!.Profiles.Length == 0, "Undo restores the exact value from before " + name + " was applied on " + edition);
            }
        }
        foreach (var preset in catalog.Presets.Where(preset => !preset.AvailableOnly && preset.Selections.Any(gated.Contains)))
            check(preset.Selections.Where(gated.Contains).All(selection => preset.OptionalSelections?.Contains(selection) == true), preset.Id + " skips its edition-limited choices where Windows ignores them");
        foreach (var presetId in new[] { "oosu.u001.336.apply", "wpd.allowtelemetry.8.apply" })
        {
            var preset = catalog.Presets.Single(item => item.Id == presetId);
            var definitions = preset.Selections.Select(selection => catalog.Resolve(selection).Definition).Distinct().ToArray();
            foreach (var edition in new[] { "Core", "Professional", "Enterprise" })
            {
                var path = Path.Combine(root, "documented-preset-" + presetId + "-" + edition + ".json"); var store = FileTweakStore.Create(path, 26100, edition);
                var engine = new TweakEngine(catalog with { Settings = definitions, Presets = [preset], Incompatible = null }, store);
                var skipped = edition == "Enterprise" ? [] : preset.Selections.Where(gated.Contains).ToArray();
                if (skipped.Length == preset.Selections.Length)
                {
                    var before = OperationFiles.HashFile(path);
                    reject(() => engine.PreviewPreset("preset", preset.Id), preset.Id + " refuses on " + edition + " when every choice is edition-limited");
                    check(OperationFiles.HashFile(path) == before, preset.Id + " leaves Windows untouched when refused on " + edition);
                    continue;
                }
                var plan = engine.PreviewPreset("preset", preset.Id);
                var expected = preset.Selections.Except(skipped).OrderBy(selection => selection.SettingId, StringComparer.Ordinal);
                check(plan.Selections.OrderBy(selection => selection.SettingId, StringComparer.Ordinal).SequenceEqual(expected) &&
                    plan.Skipped.Order(StringComparer.Ordinal).SequenceEqual(skipped.Select(selection => catalog.Resolve(selection).Definition.Name).Distinct().Order(StringComparer.Ordinal)),
                    preset.Id + " keeps its other choices and reports only the edition-limited ones as skipped on " + edition);
                Apply(engine, plan); Apply(engine, engine.Preview("preset", []));
                check(store.ReadState()!.Profiles.Length == 0 && OperationFiles.Read<TweakFixture>(path).Keys.Count == 0, preset.Id + " restores every fixture value and key on " + edition);
            }
        }
    }
}
