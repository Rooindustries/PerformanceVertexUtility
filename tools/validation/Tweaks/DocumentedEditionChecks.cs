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
            var limitedOption = definition.Options.Single(option => option.Changes is [{ } change] && change.Dword == value);
            var remove = definition.Options.Single(option => option.Changes is [{ Dword: null, Value: null, Token: null, Bits: null, Formula: null }]);
            var equivalent = required ? definition.Options.SingleOrDefault(option => option.Changes is [{ Dword: 1 }]) : null;
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
        var personal = new (string Name, string ValueName, string[] Switches)[]
        {
            ("Windows tips off", "DisableSoftLanding", ["SubscribedContent-338389Enabled", "SoftLandingEnabled"]),
        };
        const string delivery = @"SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager";
        RegistryValueData? Text(string valueName, string text) => new(valueName, 1, System.Text.Encoding.Unicode.GetBytes(text + "\0"));
        RegistryValueData? Number(string valueName, uint number) => new(valueName, 4, BitConverter.GetBytes(number));
        void Put(string path, RegistryAddress address, RegistryValueData? data)
        {
            var fixture = OperationFiles.Read<TweakFixture>(path);
            var prefix = @"\REGISTRY\USER\" + fixture.Context.Owner.UserSid + @"\";
            var parts = address.KeyPath.Split('\\');
            for (var count = 2; count <= parts.Length; count++)
            {
                var key = prefix + string.Join('\\', parts.Take(count));
                fixture.Keys.TryAdd(key.ToUpperInvariant(), new(key, "fixture", []));
            }
            var values = fixture.Keys[(prefix + address.KeyPath).ToUpperInvariant()].Values;
            if (data is null) values.Remove(address.ValueName!.ToUpperInvariant()); else values[address.ValueName!.ToUpperInvariant()] = data;
            OperationFiles.Write(path, fixture);
        }
        for (var index = 0; index < personal.Length; index++)
        {
            var (name, valueName, switches) = personal[index];
            var definition = catalog.Settings.Single(setting => setting.Options.Any(option => option.Changes is [{ Dword: 1 } change] && change.Address.Hive == "LocalMachine" &&
                string.Equals(change.Address.KeyPath, @"SOFTWARE\Policies\Microsoft\Windows\CloudContent", StringComparison.OrdinalIgnoreCase) && string.Equals(change.Address.ValueName, valueName, StringComparison.OrdinalIgnoreCase)));
            var policy = definition.Options.Single(option => option.Changes is [{ Dword: 1 }]);
            var user = definition.Options.SingleOrDefault(option => option.Changes.Length == switches.Length && option.Controls is null or [] && option.Changes.All(change => change is { Dword: 0, Value: null, Token: null, Bits: null, Selector: null, Formula: null }
                && change.Address is { Hive: "CurrentUser", View: "Registry64", Kind: "value" } && string.Equals(change.Address.KeyPath, delivery, StringComparison.OrdinalIgnoreCase))
                && option.Changes.Select(change => change.Address.ValueName!).Order(StringComparer.OrdinalIgnoreCase).SequenceEqual(switches.Order(StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase));
            check(user is not null, name + " has a choice that turns this user's Windows Settings switches off: " + string.Join(", ", switches));
            check(user!.Replaces == policy.Id, name + ": the per-user choice replaces the policy choice where Windows ignores the policy");
            var addresses = user.Changes.Select(change => change.Address).ToArray();
            var policyAddress = policy.Changes.Single().Address;
            var remover = definition.Options.Single(option => option.Changes is [{ Dword: null, Value: null } removed] && removed.Address == policyAddress);
            var homeReset = definition.Options.SingleOrDefault(option => option.Replaces == remover.Id);
            check(homeReset is not null && homeReset.Availability!.SelectMany(gate => gate.Editions).Order().SequenceEqual(user.Availability!.SelectMany(gate => gate.Editions).Order()) &&
                homeReset.Changes.Select(change => change.Address).ToHashSet().SetEquals([policyAddress, .. user.Changes.Select(change => change.Address)]) && homeReset.Changes.All(change => string.Equals(change.Address.ValueName, "SoftLandingEnabled", StringComparison.OrdinalIgnoreCase) ? change is { Dword: 1, Value: null } : change is { Dword: null, Value: null, Token: null, Bits: null }),
                name + ": Home and Pro get a Use Windows default that clears the policy and this user's switches");
            var choice = new TweakSelection(definition.Id, user.Id);
            var subset = catalog with { Settings = [definition], Presets = [], Incompatible = null };
            foreach (var edition in Editions)
            {
                var build = edition.StartsWith("Server", StringComparison.Ordinal) && edition != "ServerRdsh" ? 20348 : 26100;
                var path = Path.Combine(root, "personal-" + index + "-" + edition + ".json"); var store = FileTweakStore.Create(path, build, edition);
                var engine = new TweakEngine(subset, store); var status = engine.Detect().Settings.Single();
                var policyHere = new[] { "Enterprise", "Education", "IoTEnterprise", "Server" }.Any(family => edition.StartsWith(family, StringComparison.Ordinal));
                check(status.Supported && status.Error is null && status.AvailableChoices!.Contains(user.Id) == !policyHere && status.AvailableChoices!.Contains(policy.Id) == policyHere,
                    name + ": exactly one way to turn it off is offered on " + edition);
                check(status.Observations.Select(read => read.Address).ToHashSet().SetEquals(policyHere ? [policyAddress] : [policyAddress, .. addresses]),
                    name + ": the row reads only the values its choices on " + edition + " use");
                check(status.AvailableChoices!.Contains(remover.Id) && status.AvailableChoices!.Contains(homeReset!.Id) == !policyHere,
                    name + ": the Use Windows default that also clears this user's switches is offered exactly where the per-user choice is, on " + edition);
                if (policyHere)
                {
                    var before = OperationFiles.HashFile(path);
                    reject(() => engine.Preview("personal", [choice]), name + ": the per-user choice is refused where the policy works, on " + edition);
                    check(OperationFiles.HashFile(path) == before, name + ": a refused per-user preview leaves Windows untouched on " + edition);
                    continue;
                }
                Apply(engine, engine.Preview("personal", [choice]));
                check(addresses.All(address => Dword(store, address) == 0) && store.Read(policyAddress).Value is null && engine.Detect().Settings.Single().ConfiguredChoices.Contains(user.Id),
                    name + ": the per-user switches turn off and read back on " + edition);
                Apply(engine, engine.Preview("personal", []));
                check(addresses.All(address => store.Read(address).Value is null) && store.ReadState()!.Profiles.Length == 0 && OperationFiles.Read<TweakFixture>(path).Keys.Count == 0,
                    name + ": Undo removes the per-user values and the keys it created on " + edition);
            }
            foreach (var edition in new[] { "Core", "Professional" })
            {
                var path = Path.Combine(root, "personal-" + index + "-" + edition + "-already-off.json"); var store = FileTweakStore.Create(path, 26100, edition);
                foreach (var address in addresses) Put(path, address, Number(address.ValueName!, 0));
                var engine = new TweakEngine(subset, store);
                check(engine.Detect().Settings.Single().ConfiguredChoices.Contains(user.Id), name + " reads as on when this user turned tips off in Settings, on " + edition);
                var reset = new TweakSelection(definition.Id, homeReset!.Id);
                Apply(engine, engine.Preview("personal", [reset]));
                check(addresses.All(address => string.Equals(address.ValueName, "SoftLandingEnabled", StringComparison.OrdinalIgnoreCase) ? Dword(store, address) == 1 : store.Read(address).Value is null) && store.Read(policyAddress).Value is null
                    && !engine.Detect().Settings.Single().ConfiguredChoices.Contains(user.Id), name + ": Use Windows default puts this user's switches back as a new profile has them after Settings turned them off, on " + edition);
                Apply(engine, engine.Preview("personal", []));
                check(addresses.All(address => Dword(store, address) == 0 && store.Read(address).Value!.Type == 4) && store.ReadState()!.Profiles.Length == 0,
                    name + ": Undo puts this user's own switches back off exactly, on " + edition);
            }
            var originals = new (string Label, Func<string, RegistryValueData?>[] Values)[]
            {
                ("both on", [item => Number(item, 1), item => Number(item, 1)]),
                ("one missing", [_ => null, item => Number(item, 1)]),
                ("already off", [item => Number(item, 0), item => Number(item, 0)]),
                ("other values and types", [item => Text(item, "1"), item => Number(item, 2)]),
            };
            foreach (var edition in new[] { "Core", "Professional" })
                foreach (var (label, values) in originals)
                {
                    var path = Path.Combine(root, "personal-" + index + "-" + edition + "-" + label.Replace(' ', '-') + ".json"); var store = FileTweakStore.Create(path, 26100, edition);
                    var seeded = addresses.Select((address, slot) => values[slot % values.Length](address.ValueName!)).ToArray();
                    for (var slot = 0; slot < addresses.Length; slot++) Put(path, addresses[slot], seeded[slot]);
                    var keys = OperationFiles.Read<TweakFixture>(path).Keys.Count;
                    var engine = new TweakEngine(subset, store);
                    Apply(engine, engine.Preview("personal", [choice]));
                    check(addresses.All(address => Dword(store, address) == 0), name + " turns the switches off from " + label + " on " + edition);
                    Apply(engine, engine.Preview("personal", []));
                    check(addresses.Select((address, slot) => TweakRead.SameValue(store.Read(address).Value, seeded[slot])).All(same => same) && store.ReadState()!.Profiles.Length == 0 && OperationFiles.Read<TweakFixture>(path).Keys.Count == keys,
                        name + ": Undo restores the exact values and types from " + label + " on " + edition);
                }
            {
                var path = Path.Combine(root, "personal-" + index + "-changed.json"); var store = FileTweakStore.Create(path, 26100, "Professional");
                var engine = new TweakEngine(subset, store);
                Apply(engine, engine.Preview("personal", [choice]));
                Put(path, addresses[0], Number(addresses[0].ValueName!, 1));
                var undo = engine.Preview("personal", []);
                check(undo.LeftAsChanged.Contains(definition.Id), name + ": Undo names the setting when the Settings switch was turned back on after apply");
                Apply(engine, undo);
                check(Dword(store, addresses[0]) == 1 && addresses.Skip(1).All(address => store.Read(address).Value is null) && store.ReadState()!.Profiles.Length == 0,
                    name + ": Undo keeps the switch the user turned back on and restores the others");
            }
            {
                var path = Path.Combine(root, "personal-" + index + "-upgraded.json"); var store = FileTweakStore.Create(path, 26100, "Professional");
                foreach (var address in addresses) Put(path, address, Number(address.ValueName!, 1));
                var pro = new TweakEngine(subset, store);
                Apply(pro, pro.Preview("personal", [choice]));
                var fixture = OperationFiles.Read<TweakFixture>(path);
                OperationFiles.Write(path, fixture with { Context = fixture.Context with { Edition = "Enterprise" } });
                var upgraded = new FileTweakStore(path); var engine = new TweakEngine(subset, upgraded);
                check(engine.Detect().Settings.Single() is var upgradedStatus && !upgradedStatus.ConfiguredChoices.Contains(user.Id) && upgradedStatus.Observations.All(read => read.Address == policyAddress),
                    name + ": after an upgrade to Enterprise the per-user choice no longer reads as applied and its switches don't count toward the row");
                Apply(engine, engine.Preview("personal", []));
                check(addresses.All(address => Dword(upgraded, address) == 1) && upgraded.ReadState()!.Profiles.Length == 0, name + ": Undo after an upgrade to Enterprise restores the exact switches");
            }
            foreach (var address in addresses)
            {
                var row = catalog.Settings.Single(setting => setting.Id != definition.Id && setting.Options.Any(option => option.Changes is [{ Address: var other }] && other.Hive == "CurrentUser" &&
                    string.Equals(other.KeyPath, delivery, StringComparison.OrdinalIgnoreCase) && string.Equals(other.ValueName, address.ValueName, StringComparison.OrdinalIgnoreCase)));
                var on = new TweakSelection(row.Id, row.Options.Single(option => option.Changes is [{ Dword: 1 }]).Id);
                var off = new TweakSelection(row.Id, row.Options.Single(option => option.Changes is [{ Dword: 0 }]).Id);
                var pair = catalog with { Settings = [definition, row], Presets = [], Incompatible = null };
                var path = Path.Combine(root, "personal-" + index + "-shared-" + address.ValueName + ".json"); var store = FileTweakStore.Create(path, 26100, "Professional");
                var engine = new TweakEngine(pair, store);
                Apply(engine, engine.Preview("other", [on]));
                var before = OperationFiles.HashFile(path);
                reject(() => engine.Preview("personal", [choice]), name + " is refused while another profile sets " + row.Name + " on");
                reject(() => engine.Preview("other", [on, choice]), name + " is refused together with " + row.Name + " on in one profile");
                var refusal = "";
                try { engine.Preview("other", [on, choice]); } catch (InvalidDataException error) { refusal = error.Message; }
                check(refusal.Contains(definition.Name, StringComparison.Ordinal) && refusal.Contains(row.Name, StringComparison.Ordinal) && !refusal.Contains(definition.Id, StringComparison.Ordinal) && !refusal.Contains(row.Id, StringComparison.Ordinal),
                    name + " names both settings when one profile sets " + row.Name + " differently: " + refusal);
                check(OperationFiles.HashFile(path) == before, name + ": refused conflicts with " + row.Name + " leave Windows untouched");
                Apply(engine, engine.Preview("other", [off, choice]));
                check(addresses.All(item => Dword(store, item) == 0), name + " and " + row.Name + " off apply together");
                Apply(engine, engine.Preview("other", []));
                check(addresses.All(item => store.Read(item).Value is null) && store.ReadState()!.Profiles.Length == 0, name + " and " + row.Name + " restore every shared value once");
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
