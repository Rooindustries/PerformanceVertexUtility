using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using RooIndustries.OptimizationSuite.ViewModels;
using RooIndustries.Optimizer;

var repo = Path.GetFullPath(args[0]);
var folder = Path.Combine(repo, "tools", "validation", "TweakReads");
var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(repo, "backend", "catalogs", "windows-tweaks.json"));
catalog.Validate();
var known = OperationFiles.Read<KnownStates>(Path.Combine(folder, "known-states.json"));
var allowlist = OperationFiles.Read<ReadAllowlist>(args.Length > 1 ? Path.GetFullPath(args[1]) : Path.Combine(folder, "allowlist.json"));
var definitions = catalog.Settings.ToDictionary(item => item.Id);
foreach (var state in known.Registry) if (!definitions.ContainsKey(state.SettingId)) throw new InvalidDataException("Known state names an unknown setting: " + state.SettingId);
foreach (var entry in known.Controls) if ((entry.Read is null) == (entry.Error is null)) throw new InvalidDataException("A known control state needs exactly one read or error: " + entry.Address.Key);
var owner = new OperationOwner("FIXTURE-PC", "S-1-5-21-111111111-222222222-333333333-1001");
TweakContext[] contexts = [new(owner, "fixture:reads", 26200, "Core"), new(owner, "fixture:reads", 26200, "Professional"), new(owner, "fixture:reads", 26200, "Enterprise"), new(owner, "fixture:reads", 19045, "Professional")];
var walked = 0;
var unplanned = new SortedSet<string>(StringComparer.Ordinal);
var windowsOnly = new SortedSet<string>(StringComparer.Ordinal);
var address = new RegistryAddress("CurrentUser", "Registry64", @"Software\RooIndustriesReadWalkFixture", "value", "Choice");
var service = new ControlAddress("service", "RooIndustriesReadWalkFixture", "startup");
var fixtureRow = new TweakDefinition("fixture.read", "Fixture", "Fixture", "Fixture", 10240, 26200, ["*"], "none",
    [new("on", "On", [new(address, 1)]), new("off", "Off", [new(address, 0)])], [new("Roo Industries", "fixture", "read walk negative control")]);
var fixtureService = fixtureRow with { Id = "fixture.service", Options = [new("manual", "Manual", [], Controls: [new(service, ControlValues.From(3))]), new("disabled", "Disabled", [], Controls: [new(service, ControlValues.From(4))])] };
KnownValue Fixture(uint type, object data) => new(address, type, ControlValues.From(data));
var negative = new KnownStates(1, [new("fixture.read", "number", "fixture", [Fixture(4, 2)]), new("fixture.read", "text", "fixture", [Fixture(1, "1")]), new("fixture.read", "same", "fixture", [Fixture(4, 1)])],
    [new(service, "stock", "fixture", Error: "The service could not be read.")]);
var caught = new SortedDictionary<string, string>(StringComparer.Ordinal);
foreach (var row in new[] { fixtureRow, fixtureService }) Walk(catalog with { Settings = [row] }, row, negative, caught);
if (!caught.Keys.SequenceEqual(["fixture.read number", "fixture.read text", "fixture.service stock"]) || !caught["fixture.read number"].StartsWith("Custom value: 2", StringComparison.Ordinal))
    throw new InvalidOperationException("The read walk missed a known state that reads wrong: " + string.Join("; ", caught.Select(pair => pair.Key + " " + pair.Value)));
var split = definitions["windows.d564e4921d5ee555"];
var splitAddress = split.Options[0].Changes[0].Address;
caught.Clear();
Walk(catalog, split, new(1, [new(split.Id, "next-number", "fixture", [new(splitAddress, 4, ControlValues.From(3670017))]), new(split.Id, "as-text", "fixture", [new(splitAddress, 1, ControlValues.From("3670016"))])], []), caught);
if (!caught.Keys.SequenceEqual([split.Id + " as-text", split.Id + " next-number"]))
    throw new InvalidOperationException("A value next to a Windows default read as that default: " + string.Join("; ", caught.Select(pair => pair.Key + " " + pair.Value)));
var usb = definitions["windows.83d4b1b8f7a55f84"];
var usbAddress = usb.Options[0].Changes[0].Address;
var usbPaths = new[] { "0000", ReadStore.Device }.SelectMany(hub => new[] { "0000", ReadStore.Device }.Select(port => usbAddress with { KeyPath = usbAddress.KeyPath + "\\" + hub + "\\" + port + "\\Device Parameters" })).ToArray();
caught.Clear();
Walk(catalog, usb, new(1, [new(usb.Id, "all-five", "fixture", usbPaths.Select(path => new KnownValue(path, 4, ControlValues.From(5))).ToArray())], []), caught);
if (!caught.Keys.SequenceEqual([usb.Id + " all-five"]) || !caught[usb.Id + " all-five"].StartsWith("Custom value: 5", StringComparison.Ordinal))
    throw new InvalidOperationException("Every device set to one unknown value must read as that custom value: " + string.Join("; ", caught.Select(pair => pair.Key + " " + pair.Value)));
walked = 0; unplanned.Clear();
var offenders = new SortedDictionary<string, string>(StringComparer.Ordinal);
foreach (var definition in catalog.Settings) Walk(catalog, definition, known, offenders);
void Walk(TweakCatalog source, TweakDefinition definition, KnownStates known, SortedDictionary<string, string> offenders)
{
    var single = source with { Settings = [definition], Presets = [], Incompatible = null };
    var addresses = definition.Options.SelectMany(option => option.Controls ?? []).Select(control => control.Address).Distinct().ToArray();
    if (!OperatingSystem.IsWindows() && addresses.Any(address => address.Kind is "file-acl" or "file-ownership")) { windowsOnly.Add(definition.Id); return; }
    var reads = addresses.ToDictionary(address => address, address => known.Controls.Where(entry => entry.Address == address).ToArray());
    if (reads.Values.Any(entries => entries.Length == 0))
    {
        offenders[definition.Id + " unread"] = "no known Windows read for " + string.Join(", ", reads.Where(pair => pair.Value.Length == 0).Select(pair => pair.Key.Key));
        return;
    }
    var states = new List<(string Name, KnownValue[] Values, Dictionary<ControlAddress, KnownControlRead> Controls)>();
    var controlStates = reads.Values.SelectMany(entries => entries).Select(entry => entry.State).Distinct(StringComparer.Ordinal).DefaultIfEmpty("absent").ToArray();
    foreach (var name in controlStates)
        states.Add((name, [], reads.ToDictionary(pair => pair.Key, pair => pair.Value.FirstOrDefault(entry => entry.State == name) ?? pair.Value[0])));
    foreach (var recorded in known.Registry.Where(item => item.SettingId == definition.Id))
        states.Add((recorded.State, recorded.Values, states[0].Controls));
    var baseline = states.Find(item => item.Name == "windows-default" && item.Values.Length > 0);
    if (baseline.Name is null) baseline = states[0];
    var background = known.Controls.GroupBy(entry => entry.Address).ToDictionary(group => group.Key, group => group.First());
    var versions = contexts.Any(context => context.WindowsBuild >= definition.MinimumBuild && context.WindowsBuild <= definition.MaximumBuild) ? contexts.ToList() : [.. contexts, contexts[1] with { WindowsBuild = definition.MaximumBuild }];
    foreach (var option in definition.Options.Where(option => !versions.Any(context => TweakEngine.SupportsWindows(definition, option, context))))
        foreach (var gate in option.Availability ?? [])
            if (contexts[1] with { WindowsBuild = Math.Min(gate.MaximumBuild, definition.MaximumBuild), Edition = gate.Editions[0].TrimEnd('*') is { Length: > 0 } edition ? edition : "Professional" } is var gated && TweakEngine.SupportsWindows(definition, option, gated)) { versions.Add(gated); break; }
    foreach (var context in versions)
    {
        foreach (var (name, values, controls) in states)
        {
            var store = new ReadStore(context, values, controls, background);
            if (Problem(single, definition, store, null) is { } problem) offenders.TryAdd(definition.Id + " " + name, problem + " on " + context.Edition + " " + context.WindowsBuild);
            walked++;
        }
        var before = Status(single, new ReadStore(context, baseline.Values, baseline.Controls, background));
        foreach (var option in definition.Options.Where(option => TweakEngine.SupportsWindows(definition, option, context)))
        {
            var store = new ReadStore(context, baseline.Values, baseline.Controls, background);
            TweakPlan plan;
            try { plan = new TweakEngine(single, store).Preview("read-walk", [new(definition.Id, option.Id)]); }
            catch (Exception error) when (error is InvalidDataException or IOException or InvalidOperationException)
            {
                if (before.Error is not null || before.AvailableChoices?.Contains(option.Id) != true) unplanned.Add(definition.Id + " " + option.Id + " (" + error.Message + ")");
                else offenders.TryAdd(definition.Id + " " + option.Id, "the app refuses this choice from the known state, which reads fine and offers it: " + error.Message + " on " + context.Edition + " " + context.WindowsBuild);
                continue;
            }
            store.Apply(plan);
            if (Problem(single, definition, store, option.Id) is { } problem) offenders.TryAdd(definition.Id + " " + option.Id, problem + " on " + context.Edition + " " + context.WindowsBuild);
            walked++;
        }
    }
}
TweakSettingStatus Status(TweakCatalog single, ReadStore store) => new TweakEngine(single, store).Detect().Settings.Single();
string? Problem(TweakCatalog single, TweakDefinition definition, ReadStore store, string? optionId)
{
    var inspection = new TweakEngine(single, store).Detect();
    var status = inspection.Settings.Single();
    var row = new WindowsTweakRow(definition, definitions.ContainsKey(definition.Id) ? definitions : single.Settings.ToDictionary(item => item.Id), _ => { });
    row.Observe(status, inspection.Context);
    if (row.CouldNotCheck) return "Couldn't check: " + status.Error;
    if (row.Current is "Not read" or "Unknown value" || row.Current.StartsWith("Custom value", StringComparison.Ordinal)) return row.Current + " for " + store.Describe(status);
    if (optionId is not null && !status.ConfiguredChoices.Contains(optionId)) return "reads as " + row.Current + " after choosing " + optionId;
    return null;
}
if (allowlist.Rows.Any(item => string.IsNullOrWhiteSpace(item.Cause))) throw new InvalidDataException("Every allowlisted row needs its cause.");
var allowed = allowlist.Rows.ToDictionary(item => item.SettingId + " " + item.State, StringComparer.Ordinal);
var failures = 0;
foreach (var (key, problem) in offenders.Where(pair => !allowed.ContainsKey(pair.Key))) { failures++; Console.WriteLine("FAIL " + key + " :: " + problem); }
foreach (var choice in unplanned) Console.WriteLine("SKIP " + choice + " :: the known state can't read this row or doesn't offer this choice, so the app refuses to plan it");
foreach (var id in windowsOnly) Console.WriteLine("SKIP " + id + " :: file permissions need the Windows security APIs; this row is walked when the check runs on Windows");
foreach (var key in allowed.Keys.Where(key => !offenders.ContainsKey(key) && !windowsOnly.Contains(key[..key.IndexOf(' ')])).Order(StringComparer.Ordinal)) { failures++; Console.WriteLine("FAIL " + key + " :: reads correctly now; remove it from the allowlist"); }
Console.WriteLine("Walked " + catalog.Settings.Length + " settings and " + walked + " known states in " + contexts.Length + " Windows versions: " + offenders.Count + " read wrong, " + offenders.Keys.Count(allowed.ContainsKey) + " of them allowlisted, " + failures + " failures.");
return failures == 0 ? 0 : 1;

sealed record KnownValue([property: JsonRequired] RegistryAddress Address, [property: JsonRequired] uint Type, [property: JsonRequired] JsonElement Data)
{
    public RegistryValueData Value => new(Address.ValueName!, Type, Type switch
    {
        4 => BitConverter.GetBytes(Data.GetUInt32()),
        11 => BitConverter.GetBytes(Data.GetUInt64()),
        1 or 2 => Encoding.Unicode.GetBytes(Data.GetString() + "\0"),
        _ => Convert.FromHexString(Data.GetString()!),
    });
}
sealed record KnownRegistryState([property: JsonRequired] string SettingId, [property: JsonRequired] string State, [property: JsonRequired] string Source, [property: JsonRequired] KnownValue[] Values);
sealed record KnownControlRead([property: JsonRequired] ControlAddress Address, [property: JsonRequired] string State, [property: JsonRequired] string Source, TweakControlRead? Read = null, string? Error = null);
sealed record KnownStates([property: JsonRequired] int SchemaVersion, [property: JsonRequired] KnownRegistryState[] Registry, [property: JsonRequired] KnownControlRead[] Controls);
sealed record ReadAllowance([property: JsonRequired] string SettingId, [property: JsonRequired] string State, [property: JsonRequired] string Cause);
sealed record ReadAllowlist([property: JsonRequired] int SchemaVersion, [property: JsonRequired] ReadAllowance[] Rows);

sealed class ReadStore : ITweakStore
{
    public const string Device = "{11111111-2222-3333-4444-555555555555}";
    private readonly Dictionary<string, RegistryValueData> _values = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, KnownControlRead> _controls = new(StringComparer.Ordinal);
    public TweakContext Context { get; }
    public ReadStore(TweakContext context, KnownValue[] values, Dictionary<ControlAddress, KnownControlRead> controls, Dictionary<ControlAddress, KnownControlRead>? background = null)
    {
        Context = context;
        foreach (var value in values) _values[Key(value.Address)] = value.Value;
        foreach (var (address, read) in background ?? []) { _controls.TryAdd(address.Key, read); if (read.Read is { } observed) _controls.TryAdd(observed.Address.Key, read); }
        foreach (var (address, read) in controls) { _controls[address.Key] = read; if (read.Read is { } observed) _controls[observed.Address.Key] = read; }
    }
    private static string Key(RegistryAddress address) => address.Hive + "|" + address.View + "|" + address.KeyPath + "|" + address.ValueName;
    public TweakState? ReadState() => null;
    public TweakRead Read(RegistryAddress address) => new()
    {
        Address = address, KeyExists = true, MissingKeys = [],
        NativeKey = (address.Hive == "CurrentUser" ? @"\REGISTRY\USER\" + Context.Owner.UserSid : address.Hive == "Users" ? @"\REGISTRY\USER" : @"\REGISTRY\MACHINE") + "\\" + address.KeyPath,
        Value = address.ValueName switch
        {
            "DriverDesc" when !_values.ContainsKey(Key(address)) => new("DriverDesc", 1, Encoding.Unicode.GetBytes("Fixture Ethernet Adapter\0")),
            "NetCfgInstanceId" when !_values.ContainsKey(Key(address)) => new("NetCfgInstanceId", 1, Encoding.Unicode.GetBytes(Device + "\0")),
            _ => _values.GetValueOrDefault(Key(address)),
        },
    };
    public TweakAssignment[] Resolve(TweakAssignment assignment) =>
        RegistrySelections.Resolve(TweakHardwareValues.Resolve(assignment, () => 16777216u, name => "\"C:\\Program Files\\Fixture\\menu.exe\" " + name), _ => ["0000", Device], Read, () => [RegistrySelections.NormalizeInterface(Device)]);
    public void CheckRequirement(string requirement) { }
    public TweakControlRead ReadControl(ControlAddress address) => _controls.TryGetValue(address.Key, out var known)
        ? known.Read ?? throw new InvalidDataException(known.Error) : throw new FileNotFoundException("No known Windows read: " + address.Key);
    public TweakState Commit(TweakPlan plan, string reviewHash) => throw new InvalidOperationException("The read walk never applies.");
    public void Apply(TweakPlan plan)
    {
        foreach (var change in plan.Changes)
            if (change.After is null) _values.Remove(Key(change.Before.Address)); else _values[Key(change.Before.Address)] = change.After;
        foreach (var change in plan.Controls?.Changes ?? [])
            foreach (var key in _controls.Where(pair => pair.Value.Read?.Address == change.Before.Address).Select(pair => pair.Key).Append(change.Before.Address.Key).ToArray())
                _controls[key] = new(change.Before.Address, "chosen", "read walk", change.Before with { Value = change.After });
    }
    public string Describe(TweakSettingStatus status) => string.Join(", ", status.Observations.Select(read => read.Address.ValueName + "=" + Text(read.Value))
        .Concat((status.Controls ?? []).Select(read => read.Address.Property + "=" + (read.Value.GetRawText() is { Length: > 120 } raw ? raw[..120] + "..." : read.Value.GetRawText()))));
    private static string Text(RegistryValueData? value) => value is null ? "absent" : value.Type switch
    {
        4 when value.Bytes.Length == 4 => "REG_DWORD " + BitConverter.ToUInt32(value.Bytes),
        1 or 2 => "REG_SZ \"" + Encoding.Unicode.GetString(value.Bytes).TrimEnd('\0') + "\"",
        _ => "type " + value.Type + " " + Convert.ToHexString(value.Bytes),
    };
}
