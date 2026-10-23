#nullable enable
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed class RegistryTweakStore : ITweakStore
{
    private readonly RegistryAddress _stateAddress;
    private readonly IControlStore _controls;
    private readonly DismServicing? _fixtureDism;
    public TweakContext Context { get; }
    public RegistryTweakStore(RegistryAddress? fixtureState = null, IControlStore? fixtureControls = null, DismServicing? fixtureDism = null)
    {
        var owner = OperationOwner.Current();
#if ROO_INDUSTRIES_TEST_HOOKS
        if (fixtureState is null && Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_TWEAK_RECOVERY") is { Length: > 0 } testRecovery) fixtureState = new("CurrentUser", "Registry64", testRecovery, "value", "State");
#endif
        _stateAddress = fixtureState ?? new("LocalMachine", "Registry64", @"Software\RooIndustriesOptimizationSuite\Tweaks\" + owner.UserSid, "value", "State");
        if (fixtureState is not null && (fixtureState.Hive != "CurrentUser" || fixtureState.View != "Registry64" || fixtureState.Kind != "value" || fixtureState.ValueName != "State" ||
            !System.Text.RegularExpressions.Regex.IsMatch(fixtureState.KeyPath, @"^Software\\RooIndustriesTweakTests\\[a-f0-9]{32}\\Recovery$", System.Text.RegularExpressions.RegexOptions.CultureInvariant)))
            throw new InvalidDataException("Registry test recovery must remain inside its isolated test root.");
        if ((fixtureControls is not null || fixtureDism is not null) && fixtureState is null) throw new InvalidDataException("Test Windows controls require an isolated test recovery store.");
        _controls = fixtureControls ?? new WindowsControlStore();
        _fixtureDism = fixtureDism;
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var version = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion") ?? throw new InvalidOperationException("Windows version is unavailable.");
        if (!int.TryParse(version.GetValue("CurrentBuildNumber") as string, out var build) || version.GetValue("EditionID") is not string edition)
            throw new InvalidDataException("Windows build and edition are required.");
        Context = new(owner, "windows-registry:" + OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(_stateAddress, OperationFiles.Json)), build, edition);
    }
    public TweakAssignment[] Resolve(TweakAssignment assignment) => RegistrySelections.Resolve(TweakHardwareValues.Resolve(assignment, TweakHardwareValues.InstalledMemoryKiB), RegistrySelections.Children, Read, RegistrySelections.PrimaryInterfaces);
    public TweakControlRead ReadControl(ControlAddress address) => _controls.Read(address);
    public Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> ReadControls(IReadOnlyCollection<ControlAddress> addresses)
    {
        if (_controls is WindowsControlStore native) return native.ReadMany(addresses);
        var results = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
        foreach (var address in addresses.Distinct())
        {
            try { results[address] = (_controls.Read(address), null); }
            catch (Exception error) { results[address] = (null, error); }
        }
        return results;
    }
    public Task<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>> ReadControlsAsync(IReadOnlyCollection<ControlAddress> addresses)
    {
#if ROO_INDUSTRIES_TEST_HOOKS
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_FEATURE_HANG") is { Length: > 0 } flag && File.Exists(flag) && addresses.Any(address => address.Kind == "windows-features"))
        {
            var hold = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "PING.EXE"), "-n 400 127.0.0.1") { UseShellExecute = false, CreateNoWindow = true };
            RuntimeEnvironment.Apply(hold);
            using var holder = System.Diagnostics.Process.Start(hold);
            return new TaskCompletionSource<Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>>().Task;
        }
#endif
        return Task.Factory.StartNew(() => ReadControls(addresses), CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }
    public void CheckRequirement(string requirement)
    {
        if (requirement != "office") { TweakProducts.Check(requirement); return; }
        _ = OfficeMajor();
    }
    private static int OfficeMajor()
    {
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        string? candidate = null;
        foreach (var path in new[] { @"SOFTWARE\Microsoft\Office\ClickToRun\Configuration", @"SOFTWARE\Microsoft\Office\Common\InstallRoot" })
        {
            using var key = machine.OpenSubKey(path);
            if (key?.GetValue("VersionToReport") is string version && !string.IsNullOrEmpty(version)) { candidate = version.Split('.')[0]; break; }
            if (key?.GetValue("Path") is string location && !string.IsNullOrEmpty(location))
            {
                var position = location.LastIndexOf(@"\Office", StringComparison.Ordinal);
                candidate = position >= 0 && location.Length >= position + 9 ? location.Substring(position + 7, 2) : ""; break;
            }
        }
        if (!int.TryParse(candidate, out var major) || major is < 1 or > 99) throw new InvalidDataException("A supported Microsoft Office installation could not be identified.");
        using var user = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64);
        using var common = user.OpenSubKey(OperationOwner.Current().UserSid + @"\SOFTWARE\Microsoft\Office\" + major + @".0\Common");
        if (common is null) throw new InvalidDataException("Microsoft Office has no settings for the current Windows user.");
        return major;
    }
    public TweakRead Read(RegistryAddress address)
    {
        TweakRead.ValidateAddress(address);
        if (address.KeyPath.Contains("{office-major-version}", StringComparison.Ordinal)) address = address with { KeyPath = address.KeyPath.Replace("{office-major-version}", OfficeMajor().ToString(), StringComparison.Ordinal) };
        return RegistryNative.ReadTweak(address);
    }
    private RegistryAddress PendingAddress => _stateAddress with { ValueName = "Pending" };
    public TweakState? ReadState()
    {
        var state = Decode(RegistryNative.ReadTweak(_stateAddress).Value);
        var pending = ReadPending();
        if (pending is not null && (pending.Phase != "awaiting-restart" || state?.History.Any(item => item.OperationId == pending.Plan.OperationId) != true))
            throw new InvalidDataException("A Windows settings operation was interrupted. Recover the incomplete changes before continuing.");
        return state;
    }
    private ControlJournal? ReadPending()
    {
        var value = RegistryNative.ReadTweak(PendingAddress).Value;
        if (value is null) return null;
        if (value.Type != 3) throw new InvalidDataException("Windows control recovery has an unexpected registry type.");
        var journal = OperationFiles.Deserialize<ControlJournal>(value.Bytes);
        if (journal.Plan.Context.Owner != Context.Owner || journal.Plan.Context.StoreId != Context.StoreId || journal.Plan.Controls is null ||
            journal.Attempted < 0 || journal.Attempted > journal.Plan.Controls.Changes.Length || journal.Phase is not ("applying" or "awaiting-restart")) throw new InvalidDataException("Windows control recovery is incomplete or belongs to another store.");
        return journal;
    }
    private void WritePending(ControlJournal? journal)
    {
        using var transaction = RegistryTransaction.Begin();
        var before = RegistryNative.ReadTweak(PendingAddress, transaction);
        var bytes = journal is null ? null : JsonSerializer.SerializeToUtf8Bytes(journal, OperationFiles.Json);
        if (bytes?.Length > 8 * 1024 * 1024) throw new InvalidDataException("The Windows control recovery record exceeds its size limit.");
        RegistryNative.SetTweak(PendingAddress, before.NativeKey, bytes is null ? null : new("Pending", 3, bytes), transaction);
        transaction.Commit();
    }
    private Mutex Guard()
    {
        var mutex = new Mutex(false, "Global\\RooIndustriesWindowsSettings-" + Context.StoreId.Split(':')[1]);
        try { if (!mutex.WaitOne(0)) { mutex.Dispose(); throw new IOException("Another Windows settings operation is in progress."); } }
        catch (AbandonedMutexException) { }
        return mutex;
    }
    public TweakRecovery Recovery()
    {
        var pending = ReadPending();
        return new(Decode(RegistryNative.ReadTweak(_stateAddress).Value), pending, pending is null ? null : OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(pending, OperationFiles.Json)));
    }
    public bool Recover(string reviewHash)
    {
        using var guard = Guard();
        try
        {
            var journal = ReadPending();
            if (journal is null) return false;
            if (!string.Equals(reviewHash, OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(journal, OperationFiles.Json)), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The interrupted operation changed after review.");
            var state = Decode(RegistryNative.ReadTweak(_stateAddress).Value);
            var notices = new List<string>();
            if (journal.Phase == "awaiting-restart" && state?.History.Any(item => item.OperationId == journal.Plan.OperationId) == true)
            {
                if (SameBoot(journal.Boot)) throw new InvalidDataException(RestartAgain);
                var undone = new List<string>(); var removed = new List<string>(); var restoreUndone = new List<string>(); var unexpected = new List<string>(); var unfinished = new List<string>();
                var reconciled = new List<(TweakControlRead Read, string[] Features)>();
                foreach (var change in journal.Plan.Controls!.Changes.Where(change => change.Before.Address.Kind == "windows-features"))
                {
                    var observed = ReadControl(change.Before.Address);
                    if (observed.RestartPending) throw new InvalidDataException(RestartAgain);
                    if (observed.Id != change.Before.Id || observed.Value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Windows feature state does not match the accepted changes after restart.");
                    var claimed = state.Profiles.SelectMany(profile => profile.Controls ?? []).Where(claim => claim.Target.Id == change.Before.Id)
                        .SelectMany(claim => claim.Desired.EnumerateObject()).Select(feature => feature.Name).ToHashSet(StringComparer.Ordinal);
                    var held = (state.Controls ?? []).SingleOrDefault(item => item.Original.Id == change.Before.Id);
                    var baseline = held?.RestoreValue ?? held?.Original.Value;
                    string[] Accepted(string name)
                    {
                        var wanted = change.After.GetProperty(name).GetString()!;
                        return claimed.Contains(name) && change.Before.Value.TryGetProperty(name, out var prior) && prior.GetString() != wanted &&
                            baseline is { ValueKind: JsonValueKind.Object } original && original.TryGetProperty(name, out var saved) && ControlValues.Equal(prior, saved)
                            ? [wanted, prior.GetString()!] : [wanted];
                    }
                    var changed = WindowsFeatures.Changed(change);
                    var missing = WindowsFeatures.ReadStates(changed.Where(name => !observed.Value.TryGetProperty(name, out _)).ToArray(), _fixtureDism);
                    var release = new List<string>();
                    foreach (var name in changed)
                    {
                        var wanted = change.After.GetProperty(name).GetString();
                        var was = change.Before.Value.TryGetProperty(name, out var prior) ? prior.GetString() : null;
                        var accepted = Accepted(name);
                        if (!observed.Value.TryGetProperty(name, out var now))
                        {
                            if (missing[name] is 0 or 6) { removed.Add(name); if (claimed.Contains(name)) release.Add(name); }
                            else unfinished.Add(name);
                        }
                        else if (accepted.Contains(now.GetString(), StringComparer.Ordinal))
                        {
                            if (now.GetString() != wanted) { undone.Add(name + " " + was); release.Add(name); }
                        }
                        else if (now.GetString() == was && !claimed.Contains(name)) restoreUndone.Add(name + " is " + was + " again (originally " + wanted + ")");
                        else unexpected.Add(name + " is " + now.GetString() + "; set it to " + string.Join(" or ", accepted));
                    }
                    reconciled.Add((observed, release.ToArray()));
                }
                var problems = new List<string>();
                if (unfinished.Count > 0) problems.Add("Windows hasn't finished changing these features: " + string.Join(", ", unfinished) + ". Restart Windows or finish them in Turn Windows features on or off, then check restart completion again.");
                if (restoreUndone.Count > 0) problems.Add("Windows undid the restore of these features when it restarted: " + string.Join("; ", restoreUndone) + ". Set them back to their original in Turn Windows features on or off, restart Windows, then check restart completion again.");
                if (unexpected.Count > 0) problems.Add("Windows left these features in a state this app didn't set: " + string.Join("; ", unexpected) + ". Change them in Turn Windows features on or off, restart Windows, then check restart completion again.");
                if (problems.Count > 0) throw new InvalidDataException(string.Join(" ", problems));
                foreach (var (observed, features) in reconciled) state = WindowsFeatures.Reconcile(state, observed, features);
                if (undone.Count > 0) notices.Add(FeaturesUndone + string.Join(", ", undone) + ".");
                if (removed.Count > 0) notices.Add(FeaturesRemoved + string.Join(", ", removed) + ".");
            }
            else ControlExecution.Rollback(journal.Plan.Controls!, journal.Attempted, _controls);
            using var transaction = RegistryTransaction.Begin();
            if (state is not null)
            {
                state.Notices = state.Notices.Where(note => note != RestartNotice && note != "Restart Windows to finish the feature changes, then check restart completion in Windows settings.").Concat(notices).ToArray();
                var saved = RegistryNative.ReadTweak(_stateAddress, transaction);
                RegistryNative.SetTweak(_stateAddress, saved.NativeKey, new("State", 3, TweakEngine.SerializeState(state)), transaction);
            }
            var pendingRead = RegistryNative.ReadTweak(PendingAddress, transaction);
            RegistryNative.SetTweak(PendingAddress, pendingRead.NativeKey, null, transaction);
            transaction.Commit(); return true;
        }
        finally { guard.ReleaseMutex(); }
    }
    public const string FeaturesUndone = "Windows undid these feature changes when it restarted, so they're back to how they were: ";
    public const string FeaturesRemoved = "Windows no longer lists these features after the restart, so there's nothing to undo: ";
    public const string RestartNotice = "Restart Windows (choose Restart, not Shut down) to finish the feature changes, then check restart completion in Windows settings.";
    public const string RestartAgain = "Windows hasn't restarted since the feature changes. Choose Restart, not Shut down, then check them again. With Fast Startup on, Shut down keeps the same session.";
    public static string? CurrentBoot()
    {
        try
        {
            using var guard = new Mutex(false, @"Global\RooIndustriesBootMarker");
            bool owned;
            try { owned = guard.WaitOne(TimeSpan.FromSeconds(10)); } catch (AbandonedMutexException) { owned = true; }
            if (!owned) return null;
            try
            {
                using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
                using var product = machine.CreateSubKey(@"SOFTWARE\RooIndustriesOptimizationSuite", RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryOptions.None);
                using var marker = product.CreateSubKey("BootMarker", RegistryKeyPermissionCheck.ReadWriteSubTree, RegistryOptions.Volatile);
                if (marker.GetValue("Id") is string existing && Guid.TryParseExact(existing, "N", out _)) return "boot:" + existing;
                var id = Guid.NewGuid().ToString("N");
                marker.SetValue("Id", id, RegistryValueKind.String);
                return "boot:" + id;
            }
            finally { guard.ReleaseMutex(); }
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or IOException or ApplicationException) { return null; }
    }
    public static bool SameBoot(string? recorded, string? current = null)
    {
        if (recorded is null) return false;
        var now = current ?? CurrentBoot();
        return now is null || string.Equals(recorded, now, StringComparison.Ordinal);
    }
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
        using var guard = Guard();
        try
        {
            if (ReadPending() is not null) throw new InvalidDataException("Recover the incomplete Windows settings operation first.");
            if (plan.Controls is not { Changes.Length: > 0 }) return CommitRegistry(plan, reviewHash);
            Context.Owner.Verify();
            if (plan.Context != Context || ReadState()?.Revision != plan.BeforeRevision) throw new InvalidDataException("Settings changed after review.");
            foreach (var expected in plan.Expected)
                if (!Read(expected.Address).Same(expected)) throw new InvalidDataException("A registry setting changed after review.");
            var boot = CurrentBoot();
            var journal = new ControlJournal(plan, reviewHash, 0);
            WritePending(journal);
            try
            {
                var pending = ControlExecution.Apply(plan.Controls, _controls, attempted => { journal = journal with { Attempted = attempted }; WritePending(journal); });
                if (pending) { journal = journal with { Phase = "awaiting-restart", Boot = boot }; WritePending(journal); }
                return CommitRegistry(plan, reviewHash, pending);
            }
            catch (Exception failure)
            {
                var state = Decode(RegistryNative.ReadTweak(_stateAddress).Value);
                if (state?.History.Any(item => item.OperationId == plan.OperationId && item.ReviewHash == reviewHash) == true) return state;
                try { ControlExecution.Rollback(plan.Controls, journal.Attempted, _controls); WritePending(null); }
                catch (Exception recovery) { throw new InvalidOperationException(failure.Message + " Recovery remains pending: " + recovery.Message, failure); }
                throw;
            }
        }
        finally { guard.ReleaseMutex(); }
    }
    private TweakState CommitRegistry(TweakPlan plan, string reviewHash, bool restartPending = false)
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
            bool removed;
            try { removed = RegistryNative.RemoveTweakKey(key, transaction); }
            catch (Exception error) when (error is InvalidDataException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { removed = false; }
            if (!removed) notices.Add("Kept registry key with other data or changed permissions: " + key.Address.KeyPath);
            created.Remove(key);
        }
        if (restartPending) notices.Add(RestartNotice);
        next.CreatedKeys = created.ToArray(); next.Notices = notices.ToArray();
        RegistryNative.SetTweak(_stateAddress, saved.NativeKey, new("State", 3, TweakEngine.SerializeState(next)), transaction);
        foreach (var change in plan.Changes)
            if (!TweakRead.SameValue(RegistryNative.ReadTweak(change.Before.Address, transaction).Value, change.After)) throw new InvalidOperationException("Registry readback differs from the reviewed value.");
        foreach (var expected in plan.Controls?.Owned ?? [])
        {
            var observed = ReadControl(expected.Address);
            var desired = plan.Controls!.Changes.SingleOrDefault(change => change.Before.Id == expected.Id)?.After ?? expected.Value;
            if (observed.Id != expected.Id || observed.Binding != expected.Binding || !ControlValues.Equal(observed.Value, desired))
                throw new InvalidDataException("A Windows control changed before recovery state was committed.");
        }
        plan.Controls?.CheckReleased(ReadControl);
        var pending = RegistryNative.ReadTweak(PendingAddress, transaction);
        if (!restartPending && pending.Value is not null) RegistryNative.SetTweak(PendingAddress, pending.NativeKey, null, transaction);
        transaction.Commit();
        return next;
    }
}

public static partial class RegistryNative
{
    private static SafeRegistryHandle OpenTweakRoot(string hive)
    {
        if (hive != "Users") return OpenRoot(hive);
        Check(RegOpenKeyEx(new SafeRegistryHandle(new IntPtr(unchecked((int)0x80000003)), false), "", 0, Query | Enumerate, out var key), "RegOpenKeyEx(HKU)");
        return key;
    }
    private static void RejectTweakLink(SafeRegistryHandle key)
    {
        if (ReadValue(key, "SymbolicLinkValue")?.Type == 6) throw new InvalidDataException("This registry link has no verified target mapping.");
    }
    private static string TweakRootName(string hive, SafeRegistryHandle root) => hive switch { "LocalMachine" => @"\REGISTRY\MACHINE", "Users" => @"\REGISTRY\USER", _ => NativeName(root) };
    private static RegistryAddress ResolveTweakAddress(RegistryAddress address, RegistryTransaction? transaction)
    {
        if (address.Hive == "CurrentUser" && TweakRead.IsInside(address.KeyPath, @"Software\Classes"))
            return address with { Hive = "Users", KeyPath = OperationOwner.Current().UserSid + "_Classes" + address.KeyPath[@"Software\Classes".Length..] };
        if (address.Hive != "LocalMachine" || !address.KeyPath.StartsWith("SYSTEM\\CurrentControlSet\\", StringComparison.OrdinalIgnoreCase)) return address;
        var selected = ReadTweak(new("LocalMachine", "Registry64", @"SYSTEM\Select", "value", "Current"), transaction).Value;
        if (selected is not { Type: 4 } || selected.Bytes.Length != 4) throw new InvalidDataException("The active Windows control set is unavailable.");
        var number = BitConverter.ToUInt32(selected.Bytes);
        if (number is 0 or > 999) throw new InvalidDataException("The active Windows control set is invalid.");
        return address with { KeyPath = @"SYSTEM\ControlSet" + number.ToString("D3") + address.KeyPath[@"SYSTEM\CurrentControlSet".Length..] };
    }
    internal static TweakRead ReadTweak(RegistryAddress address, RegistryTransaction? transaction = null)
    {
        TweakRead.ValidateSyntax(address);
        var requested = address; address = ResolveTweakAddress(address, transaction);
        var missing = new List<string>();
        var parts = address.KeyPath.Split('\\');
        using var root = OpenTweakRoot(address.Hive);
        string? native = TweakRootName(address.Hive, root);
        SafeRegistryHandle? current = null;
        try
        {
            for (var index = 0; index < parts.Length; index++)
            {
                if (missing.Count == 0)
                {
                    var next = OpenChild(current ?? root, parts[index], Query | Enumerate | ReadControl, address.View, transaction);
                    current?.Dispose(); current = next;
                    if (current is not null) { RejectTweakLink(current); native = NativeName(current); continue; }
                }
                if (native is null) throw new InvalidDataException("The registry Software root is missing.");
                native += "\\" + parts[index];
                missing.Add(string.Join('\\', parts.Take(index + 1)));
            }
            return new() { Address = requested, NativeKey = native!, KeyExists = current is not null, Value = current is null ? null : ReadValue(current, address.ValueName!), MissingKeys = missing.ToArray() };
        }
        finally { current?.Dispose(); }
    }
    internal static TweakCreatedKey[] SetTweak(RegistryAddress address, string nativeName, RegistryValueData? value, RegistryTransaction transaction)
    {
        TweakRead.ValidateSyntax(address);
        if (address.Kind != "value" || value is not null && (!value.Recoverable || !string.Equals(value.Name, address.ValueName, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("The registry value cannot be written exactly.");
        address = ResolveTweakAddress(address, transaction);
        var created = new List<TweakCreatedKey>();
        using var root = OpenTweakRoot(address.Hive);
        SafeRegistryHandle? current = null;
        try
        {
            var parts = address.KeyPath.Split('\\');
            for (var index = 0; index < parts.Length; index++)
            {
                var parent = current ?? root;
                var expected = (current is null ? TweakRootName(address.Hive, root) : NativeName(current)) + "\\" + parts[index];
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
                RejectTweakLink(current);
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
    private static SafeRegistryHandle? OpenTweakPath(RegistryAddress address, uint access, RegistryTransaction transaction)
    {
        TweakRead.ValidateSyntax(address);
        using var root = OpenTweakRoot(address.Hive);
        SafeRegistryHandle? current = null;
        try
        {
            foreach (var part in address.KeyPath.Split('\\'))
            {
                var next = OpenChild(current ?? root, part, access, address.View, transaction);
                current?.Dispose(); current = next;
                if (current is null) return null;
                RejectTweakLink(current);
            }
            var result = current; current = null; return result;
        }
        finally { current?.Dispose(); }
    }
    private static string TweakMetadata(SafeRegistryHandle key) => OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { Class = ReadInfo(key).Class, Security = ReadSecurity(key) }, OperationFiles.Json));
    internal static bool RemoveTweakKey(TweakCreatedKey created, RegistryTransaction transaction)
    {
        TweakRead.ValidateSyntax(created.Address);
        if (created.Address.Kind != "key") throw new InvalidDataException("Created-key recovery requires a key identity.");
        if (!created.Address.KeyPath.Contains('\\')) return false;
        using (var key = OpenTweakPath(created.Address, Change, transaction))
        {
            if (key is null) return true;
            RejectTweakLink(key); VerifyName(key, created.NativeKey);
            uint capacity = 256;
            Check(RegQueryInfoKey(key, new System.Text.StringBuilder(256), ref capacity, IntPtr.Zero, out var subkeys, out _, out _, out var values, out _, out _, out _, out _), "RegQueryInfoKey(tweak cleanup)");
            if (subkeys != 0 || values != 0 || TweakMetadata(key) != created.MetadataHash) return false;
        }
        var separator = created.Address.KeyPath.LastIndexOf('\\');
        var parentAddress = created.Address with { KeyPath = created.Address.KeyPath[..separator] };
        using var parent = OpenTweakPath(parentAddress, Change, transaction) ?? throw new InvalidDataException("The created registry key's parent disappeared.");
        VerifyName(parent, created.NativeKey[..created.NativeKey.LastIndexOf('\\')]);
        Check(RegDeleteKeyTransacted(parent, created.Address.KeyPath[(separator + 1)..], ViewFlag(created.Address.View), 0, transaction, IntPtr.Zero), "RegDeleteKeyTransacted(tweak cleanup)");
        return true;
    }
}
