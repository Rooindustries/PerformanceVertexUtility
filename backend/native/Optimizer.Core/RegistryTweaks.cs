#nullable enable
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class RegistryTweakStore : ITweakStore
{
    private readonly RegistryAddress _stateAddress;
    public TweakContext Context { get; }
    public RegistryTweakStore(RegistryAddress? fixtureState = null)
    {
        var owner = OperationOwner.Current();
        _stateAddress = fixtureState ?? new("LocalMachine", "Registry64", @"Software\RooIndustriesOptimizationSuite\Tweaks\" + owner.UserSid, "value", "State");
        if (fixtureState is not null && (fixtureState.Hive != "CurrentUser" || fixtureState.View != "Registry64" || fixtureState.Kind != "value" || fixtureState.ValueName != "State" ||
            !System.Text.RegularExpressions.Regex.IsMatch(fixtureState.KeyPath, @"^Software\\RooIndustriesTweakTests\\[a-f0-9]{32}\\Recovery$", System.Text.RegularExpressions.RegexOptions.CultureInvariant)))
            throw new InvalidDataException("Registry test recovery must remain inside its isolated test root.");
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var version = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion") ?? throw new InvalidOperationException("Windows version is unavailable.");
        if (!int.TryParse(version.GetValue("CurrentBuildNumber") as string, out var build) || version.GetValue("EditionID") is not string edition)
            throw new InvalidDataException("Windows build and edition are required.");
        Context = new(owner, "windows-registry:" + OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(_stateAddress, OperationFiles.Json)), build, edition);
    }
    public TweakRead Read(RegistryAddress address) { TweakRead.ValidateAddress(address); return RegistryNative.ReadTweak(address); }
    public TweakState? ReadState() => Decode(RegistryNative.ReadTweak(_stateAddress).Value);
    private TweakState? Decode(RegistryValueData? value)
    {
        if (value is null) return null;
        if (value.Type != 3) throw new InvalidDataException("The tweak recovery store has an unexpected registry type.");
        var result = OperationFiles.Deserialize<TweakState>(value.Bytes);
        TweakEngine.ValidateState(result, Context);
        return result;
    }
    public TweakState Commit(TweakPlan plan, string reviewHash)
    {
        Context.Owner.Verify();
        if (plan.Context != Context) throw new InvalidDataException("The review belongs to another store.");
        using var transaction = RegistryTransaction.Begin();
        var saved = RegistryNative.ReadTweak(_stateAddress, transaction);
        var previous = Decode(saved.Value);
        if (previous?.Revision != plan.BeforeRevision) throw new InvalidDataException("A newer profile change has already been saved.");
        foreach (var expected in plan.Expected)
            if (!RegistryNative.ReadTweak(expected.Address, transaction).Same(expected)) throw new InvalidDataException("A Windows setting changed after review.");
        var next = TweakEngine.NextState(plan, reviewHash, previous);
        var created = next.CreatedKeys.ToList();
        foreach (var change in plan.Changes)
            created.AddRange(RegistryNative.SetTweak(change.Before.Address, change.Before.NativeKey, change.After, transaction));
        var notices = new List<string>();
        foreach (var key in created.OrderByDescending(item => item.NativeKey.Length).ToArray())
        {
            if (next.Held.Any(item => TweakRead.IsInside(item.Original.NativeKey, key.NativeKey))) continue;
            if (!RegistryNative.RemoveTweakKey(key, transaction)) notices.Add("Kept registry key with other data or changed permissions: " + key.Address.KeyPath);
            created.Remove(key);
        }
        next.CreatedKeys = created.ToArray(); next.Notices = notices.ToArray();
        RegistryNative.SetTweak(_stateAddress, saved.NativeKey, new("State", 3, TweakEngine.SerializeState(next)), transaction);
        foreach (var change in plan.Changes)
            if (!TweakRead.SameValue(RegistryNative.ReadTweak(change.Before.Address, transaction).Value, change.After)) throw new InvalidOperationException("Registry readback differs from the reviewed value.");
        transaction.Commit();
        return next;
    }
}

public static partial class RegistryNative
{
    internal static TweakRead ReadTweak(RegistryAddress address, RegistryTransaction? transaction = null)
    {
        address.Validate();
        var missing = new List<string>();
        var parts = address.KeyPath.Split('\\');
        string? native = null;
        using var root = OpenRoot(address.Hive);
        SafeRegistryHandle? current = null;
        try
        {
            for (var index = 0; index < parts.Length; index++)
            {
                if (missing.Count == 0)
                {
                    var next = OpenChild(current ?? root, parts[index], Query | Enumerate | ReadControl, address.View, transaction);
                    current?.Dispose(); current = next;
                    if (current is not null) { RejectLink(current); native = NativeName(current); continue; }
                }
                if (native is null) throw new InvalidDataException("The registry Software root is missing.");
                native += "\\" + parts[index];
                missing.Add(string.Join('\\', parts.Take(index + 1)));
            }
            return new() { Address = address, NativeKey = native!, KeyExists = current is not null, Value = current is null ? null : ReadValue(current, address.ValueName!), MissingKeys = missing.ToArray() };
        }
        finally { current?.Dispose(); }
    }
    internal static TweakCreatedKey[] SetTweak(RegistryAddress address, string nativeName, RegistryValueData? value, RegistryTransaction transaction)
    {
        address.Validate();
        if (address.Kind != "value" || value is not null && (!value.Recoverable || !string.Equals(value.Name, address.ValueName, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("The registry value cannot be written exactly.");
        var created = new List<TweakCreatedKey>();
        using var root = OpenRoot(address.Hive);
        SafeRegistryHandle? current = null;
        try
        {
            var parts = address.KeyPath.Split('\\');
            for (var index = 0; index < parts.Length; index++)
            {
                var parent = current ?? root;
                var expected = NativeName(parent) + "\\" + parts[index];
                var next = OpenChild(parent, parts[index], Change, address.View, transaction);
                if (next is null && value is not null)
                {
                    Check(RegCreateKeyTransacted(parent, parts[index], 0, null, 0, Change | ViewFlag(address.View), IntPtr.Zero,
                        out next, out var disposition, transaction, IntPtr.Zero), "RegCreateKeyTransacted(tweak)");
                    VerifyName(next, expected);
                    if (disposition == 1) created.Add(new(address with { KeyPath = string.Join('\\', parts.Take(index + 1)), Kind = "key", ValueName = null }, expected,
                        TweakMetadata(next)));
                }
                current?.Dispose(); current = next;
                if (current is null) return created.ToArray();
                RejectLink(current);
            }
            VerifyName(current!, nativeName);
            if (value is null)
            {
                var result = RegDeleteValue(current!, address.ValueName!);
                if (result != 2) Check(result, "RegDeleteValue(tweak)");
            }
            else WriteValue(current!, value);
            return created.ToArray();
        }
        finally { current?.Dispose(); }
    }
    private static string TweakMetadata(SafeRegistryHandle key) => OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { Class = ReadInfo(key).Class, Security = ReadSecurity(key) }, OperationFiles.Json));
    internal static bool RemoveTweakKey(TweakCreatedKey created, RegistryTransaction transaction)
    {
        created.Address.Validate();
        if (created.Address.Kind != "key") throw new InvalidDataException("Created-key recovery requires a key identity.");
        try { created.Address.RequireDeletionScope(); }
        catch (InvalidDataException) { return false; }
        using (var key = Open(created.Address, Change, transaction))
        {
            if (key is null) return true;
            RejectLink(key); VerifyName(key, created.NativeKey);
            uint capacity = 256;
            Check(RegQueryInfoKey(key, new System.Text.StringBuilder(256), ref capacity, IntPtr.Zero, out var subkeys, out _, out _, out var values, out _, out _, out _, out _), "RegQueryInfoKey(tweak cleanup)");
            if (subkeys != 0 || values != 0 || TweakMetadata(key) != created.MetadataHash) return false;
        }
        var separator = created.Address.KeyPath.LastIndexOf('\\');
        var parentAddress = created.Address with { KeyPath = created.Address.KeyPath[..separator] };
        using var parent = Open(parentAddress, Change, transaction) ?? throw new InvalidDataException("The created registry key's parent disappeared.");
        VerifyName(parent, created.NativeKey[..created.NativeKey.LastIndexOf('\\')]);
        Check(RegDeleteKeyTransacted(parent, created.Address.KeyPath[(separator + 1)..], ViewFlag(created.Address.View), 0, transaction, IntPtr.Zero), "RegDeleteKeyTransacted(tweak cleanup)");
        return true;
    }
}
