#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed record TweakFixtureKey(string NativeKey, string Metadata, Dictionary<string, RegistryValueData> Values);
public sealed record TweakFixture
{
    public required string Format { get; init; }
    public required TweakContext Context { get; init; }
    public required TweakState? State { get; set; }
    public required Dictionary<string, TweakFixtureKey> Keys { get; init; }
    public required int Writes { get; set; }
    public uint? InstalledMemoryKiB { get; init; }
    public int? OfficeMajor { get; init; }
    public int? EdgeMajor { get; init; }
    public int? EdgeProfileMajor { get; init; }
    public bool RemoteSession { get; init; }
    public string? MenuExecutable { get; init; }
    public string[] PrimaryInterfaces { get; init; } = [];
    public Dictionary<string, TweakControlRead> Controls { get; init; } = [];
}

public class FileTweakStore : ITweakStore
{
    private readonly string _path;
    public TweakContext Context { get; }
    public FileTweakStore(string path)
    {
        _path = Path.GetFullPath(path);
        var fixture = Load();
        Context = fixture.Context;
        if (Context.StoreId != "fixture:" + _path) throw new InvalidDataException("The fixture belongs to another file.");
        Context.Owner.Verify();
    }
    public static FileTweakStore Create(string path, int build = 26200, string edition = "Professional")
    {
        path = Path.GetFullPath(path);
        using var guard = OperationFiles.Lock(path);
        if (File.Exists(path)) throw new InvalidDataException("The fixture already exists.");
        OperationFiles.Write(path, new TweakFixture { Format = "RooIndustriesTweakFixture/v1", Context = new(OperationOwner.Current(), "fixture:" + path, build, edition), State = null, Keys = [], Writes = 0 });
        return new(path);
    }
    private TweakFixture Load()
    {
        var result = OperationFiles.Read<TweakFixture>(_path);
        if (result.Format != "RooIndustriesTweakFixture/v1" || result.Keys is null || result.Context is null) throw new InvalidDataException("Not a tweak fixture.");
        return result;
    }
    public TweakState? ReadState() => Load().State;
    public void CheckRequirement(string requirement)
    {
        var fixture = Load();
        if (requirement.StartsWith("edge", StringComparison.Ordinal) || requirement == "legacy-edge") { TweakProducts.CheckEdge(requirement, requirement.StartsWith("edge-profile:", StringComparison.Ordinal) ? fixture.EdgeProfileMajor : fixture.EdgeMajor); return; }
        if (requirement == "local-session") { if (fixture.RemoteSession) throw new InvalidDataException("The fixture is a remote session."); return; }
        if (requirement == "office16") { if (fixture.OfficeMajor != 16) throw new InvalidDataException("Office16 is not installed in the fixture."); return; }
        if (requirement != "office" || Load().OfficeMajor is not (> 0 and < 100)) throw new InvalidDataException("The fixture does not provide the required Office identity.");
    }
    public TweakRead Read(RegistryAddress address)
    {
        TweakRead.ValidateAddress(address); var fixture = Load();
        if (address.KeyPath.Contains("{office-major-version}", StringComparison.Ordinal))
        {
            CheckRequirement("office"); address = address with { KeyPath = address.KeyPath.Replace("{office-major-version}", fixture.OfficeMajor!.Value.ToString(), StringComparison.Ordinal) };
        }
        return Read(fixture, address);
    }
    public TweakAssignment[] Resolve(TweakAssignment assignment)
    {
        var fixture = Load();
        string[] Children(RegistryAddress address)
        {
            var prefix = Native(Context, address, address.KeyPath) + "\\";
            return fixture.Keys.Values.Where(key => key.NativeKey.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                .Select(key => key.NativeKey[prefix.Length..].Split('\\')[0]).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        }
        return RegistrySelections.Resolve(TweakHardwareValues.Resolve(assignment, () => fixture.InstalledMemoryKiB ?? throw new InvalidDataException("Fixture physical memory is missing."), name => "\"" + (fixture.MenuExecutable ?? throw new InvalidDataException("Fixture menu executable is missing.")) + "\" " + name), Children, address => Read(fixture, address), () => fixture.PrimaryInterfaces);
    }
    public TweakControlRead ReadControl(ControlAddress address) => Load().Controls.GetValueOrDefault(address.Key) ?? throw new FileNotFoundException("Fixture control is unavailable: " + address.Target);
    private static string Native(TweakContext context, RegistryAddress address, string path) =>
        (address.Hive == "CurrentUser" ? "\\REGISTRY\\USER\\" + context.Owner.UserSid : address.Hive == "Users" ? "\\REGISTRY\\USER" : "\\REGISTRY\\MACHINE") + "\\" +
        (address.View == "Registry32" && address.Hive == "LocalMachine" ? path.Replace("Software\\", "Software\\WOW6432Node\\", StringComparison.OrdinalIgnoreCase) : path);
    private static TweakRead Read(TweakFixture fixture, RegistryAddress address)
    {
        var native = Native(fixture.Context, address, address.KeyPath);
        fixture.Keys.TryGetValue(native.ToUpperInvariant(), out var key);
        var missing = new List<string>();
        var parts = address.KeyPath.Split('\\');
        for (var count = parts.Length == 1 ? 1 : 2; count <= parts.Length; count++)
        {
            var path = string.Join('\\', parts.Take(count));
            if (!fixture.Keys.ContainsKey(Native(fixture.Context, address, path).ToUpperInvariant())) missing.Add(path);
        }
        return new() { Address = address, NativeKey = native, KeyExists = key is not null,
            Value = key?.Values.GetValueOrDefault(address.ValueName!.ToUpperInvariant()), MissingKeys = missing.ToArray() };
    }
    protected virtual void BeforeCommit(TweakFixture fixture) { }
    protected virtual void AfterCommit() { }
    public TweakState Commit(TweakPlan plan, string reviewHash)
    {
        using var guard = OperationFiles.Lock(_path);
        var fixture = Load();
        if (fixture.State?.Revision != plan.BeforeRevision || fixture.Context != plan.Context) throw new InvalidDataException("The fixture changed after review.");
        foreach (var expected in plan.Expected)
            if (!Read(fixture, expected.Address).Same(expected)) throw new InvalidDataException("A fixture setting changed after review.");
        foreach (var expected in plan.Controls?.Owned ?? [])
            if (!fixture.Controls.TryGetValue(expected.Address.Key, out var current) || !current.Same(expected)) throw new InvalidDataException("A fixture control changed after review.");
        plan.Controls?.CheckReleased(address => fixture.Controls.GetValueOrDefault(address.Key) ?? new(address, "", "", default));
        foreach (var change in plan.Controls?.Changes ?? [])
            { fixture.Controls[change.Before.Address.Key] = change.Before with { Value = change.After }; fixture.Writes++; }
        var next = TweakEngine.NextState(plan, reviewHash, fixture.State);
        var created = next.CreatedKeys.ToList();
        foreach (var change in plan.Changes)
        {
            var address = change.Before.Address;
            if (change.After is not null)
            {
                foreach (var path in Read(fixture, address).MissingKeys)
                {
                    var native = Native(Context, address, path);
                    fixture.Keys.Add(native.ToUpperInvariant(), new(native, "inherited", []));
                    created.Add(new(address with { Kind = "key", ValueName = null, KeyPath = path }, native, "inherited"));
                }
                fixture.Keys[change.Before.NativeKey.ToUpperInvariant()].Values[address.ValueName!.ToUpperInvariant()] = change.After;
            }
            else if (fixture.Keys.TryGetValue(change.Before.NativeKey.ToUpperInvariant(), out var key)) key.Values.Remove(address.ValueName!.ToUpperInvariant());
            fixture.Writes++;
        }
        var notices = new List<string>();
        foreach (var key in created.OrderByDescending(item => item.NativeKey.Length).ToArray())
        {
            if (next.Held.Any(item => TweakRead.IsInside(item.Original.NativeKey, key.NativeKey))) continue;
            if (fixture.Keys.TryGetValue(key.NativeKey.ToUpperInvariant(), out var actual))
            {
                if (actual.Values.Count == 0 && actual.Metadata == key.MetadataHash && !fixture.Keys.Values.Any(child => child.NativeKey.StartsWith(key.NativeKey + "\\", StringComparison.OrdinalIgnoreCase)))
                    fixture.Keys.Remove(key.NativeKey.ToUpperInvariant());
                else notices.Add("Kept registry key with other data or changed permissions: " + key.Address.KeyPath);
            }
            created.Remove(key);
        }
        next.CreatedKeys = created.ToArray(); next.Notices = notices.ToArray(); fixture.State = next;
        _ = TweakEngine.SerializeState(next);
        BeforeCommit(fixture);
        OperationFiles.Write(_path, fixture);
        AfterCommit();
        return next;
    }
}
