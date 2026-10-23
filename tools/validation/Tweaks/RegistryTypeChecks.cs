using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RooIndustries.Optimizer;

static class RegistryTypeChecks
{
    public static void Run(string files, string repo, TweakCatalog catalog, Action<bool, string> check, Action<Action, string> reject)
    {
        var root = RegistryTweakChecks.Root;
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using (var existing = hive.OpenSubKey(root)) if (existing is not null) throw new InvalidDataException("The native fixture already exists; it will not be reused.");
        var parentExisted = false;
        using (var parent = hive.OpenSubKey(@"Software\RooIndustriesTweakTests")) parentExisted = parent is not null;
        var recovery = new RegistryAddress("CurrentUser", "Registry64", root + @"\Recovery", "value", "State");
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(repo, "backend", "catalogs", "windows-value-types.json")));
        byte[]? State() { using var key = hive.OpenSubKey(recovery.KeyPath); return key?.GetValue("State") as byte[]; }
        try
        {
            var index = 0;
            foreach (var entry in document.RootElement.GetProperty("values").EnumerateArray())
            {
                var (hiveName, path, name, type, windows) = (entry.GetProperty("hive").GetString(), entry.GetProperty("keyPath").GetString()!, entry.GetProperty("valueName").GetString()!, entry.GetProperty("type").GetString()!, entry.GetProperty("windowsValue").GetString()!);
                bool Listed(RegistryAddress address) => address.Hive == hiveName && address.KeyPath.Equals(path, StringComparison.OrdinalIgnoreCase) && string.Equals(address.ValueName, name, StringComparison.OrdinalIgnoreCase);
                var definition = catalog.Settings.Single(setting => setting.Options.Any(option => option.Changes.Any(change => Listed(change.Address))));
                var fixture = root + @"\Stock" + index++ + @"\" + path;
                var row = definition with { Options = definition.Options.Select(option => option with { Changes = option.Changes.Select(change => Listed(change.Address) ? change with { Address = change.Address with { Hive = "CurrentUser", KeyPath = fixture } } : change).ToArray() }).ToArray() };
                if (row.Options.Any(option => option.Controls is { Length: > 0 } || option.Changes.Any(change => change.Address.Hive != "CurrentUser" || !change.Address.KeyPath.StartsWith(root + @"\", StringComparison.Ordinal))))
                    throw new InvalidDataException(definition.Name + " also changes a target outside the fixture; it will not be applied.");
                var devices = row.Options.SelectMany(option => option.Changes).Any(change => change.Selector is not null);
                string[] targets = devices ? [.. Enumerable.Range(0, 3).Select(device => fixture + @"\Device" + device + @"\Instance\Device Parameters")] : [fixture];
                string[] start = devices ? ["Binary:" + windows, "absent", "DWord:0"] : ["String:" + windows];
                string Describe(string key)
                {
                    using var opened = hive.OpenSubKey(key);
                    if (opened?.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not { } data) return "absent";
                    return opened.GetValueKind(name) + ":" + (data is byte[] bytes ? Convert.ToHexString(bytes) : Convert.ToString(data, System.Globalization.CultureInfo.InvariantCulture));
                }
                void Set(string key, string state)
                {
                    using var created = hive.CreateSubKey(key);
                    var (kind, data) = (state.Split(':')[0], state.Contains(':') ? state[(state.IndexOf(':') + 1)..] : "");
                    if (kind == "absent") created.DeleteValue(name, false);
                    else if (kind == "String") created.SetValue(name, data, RegistryValueKind.String);
                    else if (kind == "Binary") created.SetValue(name, Convert.FromHexString(data), RegistryValueKind.Binary);
                    else created.SetValue(name, unchecked((int)uint.Parse(data, System.Globalization.CultureInfo.InvariantCulture)), RegistryValueKind.DWord);
                }
                void Seed(string[] states) { for (var device = 0; device < targets.Length; device++) Set(targets[device], states[device]); }
                string[] Now() => targets.Select(Describe).ToArray();
                string Writes(TweakOption option) => option.Changes.Single() switch
                {
                    { Value: { Type: 1 } value } => "String:" + Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0'),
                    { Value: { Type: 3 } value } => "Binary:" + Convert.ToHexString(value.Bytes),
                    { Dword: { } number } => "DWord:" + number,
                    var other => throw new InvalidDataException("Unexpected write for " + other.Address.ValueName),
                };
                TweakEngine Engine(TweakDefinition setting) => new(catalog with { Settings = [setting], Presets = [], Incompatible = null }, new RegistryTweakStore(recovery));
                (string Path, string Hash, TweakPlan Plan) Preview(TweakEngine with, string id, TweakSelection[] selected)
                {
                    var plan = with.Preview(id, selected); var file = Path.Combine(files, plan.OperationId + ".json");
                    OperationFiles.Write(file, plan); return (file, OperationFiles.HashFile(file), plan);
                }
                void Apply(TweakEngine with, string id, TweakSelection[] selected) { var plan = Preview(with, id, selected); with.Apply(plan.Path, plan.Hash); }
                TweakSelection[] Pick(TweakOption option) => [new(row.Id, option.Id)];
                var kind = type == "REG_SZ" ? "String:" : "Binary:";
                var label = definition.Name + " (" + name + ")";
                Seed(start);

                foreach (var option in row.Options)
                {
                    var writes = Writes(option);
                    Apply(Engine(row), "choice", Pick(option));
                    check(writes.StartsWith(kind, StringComparison.Ordinal) && Now().All(state => state == writes), label + ": " + option.Name + " writes the " + type + " Windows keeps (" + string.Join(", ", Now()) + ")");
                    Apply(Engine(row), "choice", []);
                    check(Now().SequenceEqual(start), label + ": Undo after " + option.Name + " puts back " + string.Join(", ", start));
                }

                foreach (var hidden in row.Options.Where(option => option.SameAs is not null))
                    check(Writes(hidden) == Writes(row.Options.Single(option => option.Id == hidden.SameAs)), label + ": hidden " + hidden.Name + " writes exactly what its visible twin writes, so saved choices that picked it keep working");
                var first = row.Options.First(option => option.SameAs is null);
                Seed([.. targets.Select(_ => "DWord:0")]);
                Apply(Engine(row), "older", Pick(first));
                check(Now().All(state => state == Writes(first)), label + ": " + first.Name + " replaces a number an older app wrote with " + type);
                Apply(Engine(row), "older", []);
                check(Now().All(state => state == "DWord:0"), label + ": Undo puts the older app's REG_DWORD 0 back exactly");
                Seed(start);

                var legacy = row with { Options = row.Options.Select(option => option with { Changes = option.Changes.Select(change => change.Value is { } value
                    ? change with { Value = null, Dword = value.Type == 1 ? uint.Parse(Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0'), System.Globalization.CultureInfo.InvariantCulture) : value.Bytes.Single() } : change).ToArray() }).ToArray() };
                Apply(Engine(legacy), "legacy", Pick(first));
                check(Now().All(state => state.StartsWith("DWord:", StringComparison.Ordinal)), label + ": the older catalog's " + first.Name + " wrote a number");
                Apply(Engine(row), "legacy", []);
                check(Now().SequenceEqual(start), label + ": after an update and restart, Undo of the older app's profile puts back " + string.Join(", ", start));
                Apply(Engine(legacy), "saved", Pick(first));
                Apply(Engine(row), "saved", Pick(first));
                check(Now().All(state => state == Writes(first)), label + ": reviewing the older app's saved choice again after an update writes " + type);
                Apply(Engine(row), "saved", []);
                check(Now().SequenceEqual(start) && Engine(row).Detect().State?.Profiles.Length is null or 0, label + ": Undo of that profile puts back Windows' values and leaves no profile behind");

                var fault = Preview(Engine(row), "fault", Pick(row.Options.First(option => start.Any(state => state != Writes(option)))));
                var before = State();
                reject(() => new RegistryTweakStore(recovery).Commit(fault.Plan with { Changes = [.. fault.Plan.Changes, fault.Plan.Changes[0] with { After = new(name, 4, [1]) }] }, fault.Hash),
                    label + ": a " + type + " write followed by a failing write in the same transaction is rejected");
                check(Now().SequenceEqual(start) && (State() ?? []).SequenceEqual(before ?? []), label + ": the rolled-back write leaves Windows' values and the recovery record unchanged");
            }
        }
        finally { RegistryTweakChecks.Remove(hive, parentExisted, check); }
    }
}
