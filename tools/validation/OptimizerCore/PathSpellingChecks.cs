using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using RooIndustries.Optimizer;

static class PathSpellingChecks
{
    const string App = "Roo Industries Spelling";
    const string Peer = "Independent spelling tool";
    const string Refusal = "This leftover is protected, shared or has incomplete ownership evidence: ";

    public static void Run(Action<bool, string> check)
    {
        var root = TestFixtures.InheritingRoot("path-spelling");
        var registryRoot = "Software\\RooIndustriesPathSpellingTests-" + Guid.NewGuid().ToString("N");
        using var hive = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        var reviews = new List<ApplicationCleanupPreview>();
        try
        {
            var apps = Directory.CreateDirectory(Path.Combine(root, "Long Spelling Apps")).FullName;
            var install = Directory.CreateDirectory(Path.Combine(apps, App)).FullName;
            var peer = Directory.CreateDirectory(Path.Combine(apps, "Peer Spelling Tool")).FullName;
            var settings = Path.Combine(install, "settings.txt");
            File.WriteAllText(settings, "fixture");
            var appsShort = Alias(apps, "LONGSP~1");
            var installShort = Alias(install, "ROOSPE~1");
            var peerShort = Alias(peer, "PEERSP~1");
            if (appsShort is not null && installShort is not null && peerShort is not null)
            {
                var authority = new CleanupAuthority
                {
                    AppId = "fixture:path-spelling", ProviderIdentityHash = new string('C', 64), Owner = OperationOwner.Current(),
                    ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
                };
                var application = new CleanupApplication { AppId = authority.AppId, DisplayName = App, Publisher = "Fixture", InstallLocation = install, PackageFamilyName = null };
                CleanupApplication PeerAt(string location) => application with { AppId = "fixture:spelling-peer", DisplayName = Peer, InstallLocation = location };
                var queue = Path.Combine(root, "queue.json");

                (LeftoverCandidate[] Found, LeftoverCandidate Key, bool Refused, bool Intact) Case(string name, string? peerLocation, Action<RegistryKey> write)
                {
                    var scope = registryRoot + "\\" + name;
                    using (var created = hive.CreateSubKey(scope + "\\" + App)) write(created);
                    var before = Snapshot(hive, scope + "\\" + App);
                    var context = new CleanupContext(queue, authority, application, peerLocation is null ? [] : [PeerAt(peerLocation)], true);
                    var engine = new ApplicationCleanup(() => context, [], [new("CurrentUser", "Registry64", scope, "key", null)]);
                    var found = engine.Scan(CancellationToken.None).Candidates;
                    var key = found.Single(item => item.Kind == "registryKey");
                    var refused = false;
                    try { engine.Preview(Path.Combine(root, "review-" + name, "review.json"), [key.ItemId], true, true); }
                    catch (InvalidDataException) { refused = true; }
                    return (found, key, refused, Snapshot(hive, scope + "\\" + App) == before);
                }

                var dll = Path.Combine(peer, "peer.dll");
                var shared = new (string Name, string Peer, Action<RegistryKey> Write)[]
                {
                    ("short-peer-long-value", peerShort, key => key.SetValue("Plugin", "\"" + dll + "\"")),
                    ("long-peer-short-value", peer, key => key.SetValue("Plugin", Path.Combine(peerShort, "peer.dll"))),
                    ("long-peer-mixed-value", peer, key => key.SetValue("Plugin", "\"" + Path.Combine(appsShort, Path.GetFileName(peer), "peer.dll") + "\" --run")),
                    ("doubled-separators", peer, key => key.SetValue("Plugin", dll.Replace("\\", "\\\\"))),
                    ("semicolon-after", peer, key => key.SetValue("Paths", peer + ";C:\\Other Spelling\\bin")),
                    ("semicolon-before", peer, key => key.SetValue("Paths", "C:\\Other Spelling\\bin;" + Path.Combine(peer, "bin"))),
                    ("comma-list", peer, key => key.SetValue("Paths", "C:\\Other Spelling\\bin," + peer)),
                    ("quoted-list-with-spaces", peer, key => key.SetValue("Paths", "\"C:\\Other Spelling\\bin\"; \"" + peerShort + "\"")),
                    ("multi-string", peer, key => key.SetValue("Paths", new[] { "C:\\Other Spelling\\bin", "plugins=" + peer + ";extra" }, RegistryValueKind.MultiString)),
                    ("quoted-short-peer-trailing-separators", "\"" + peerShort.ToUpperInvariant() + "\\\\\"", key => key.SetValue("Plugin", dll.ToLowerInvariant())),
                    ("missing-peer-through-short-parent", Path.Combine(appsShort, "Missing Spelling Peer"), key => key.SetValue("Plugin", Path.Combine(apps, "Missing Spelling Peer", "peer.dll"))),
                };
                foreach (var item in shared)
                {
                    var result = Case(item.Name, item.Peer, item.Write);
                    Console.WriteLine("MEASURE pathSpelling " + JsonSerializer.Serialize(new { Scenario = item.Name, result.Key.SharedOwners, result.Refused, result.Intact }));
                    check(result.Key.SharedOwners.Contains(Peer) && result.Refused && result.Intact, item.Name + ": the key keeps its shared owner, whole-key preview is refused and its values stay intact");
                }

                var distinct = Case("prefix-only", peer, key =>
                {
                    key.SetValue("Old", "\"" + peer + "-Old\\peer.dll\"");
                    key.SetValue("Joined", peer + "Extra\\peer.dll");
                    key.SetValue("Comma", "\"" + peer + ", Inc\\peer.dll\"");
                    key.SetValue("ShortPrefix", peerShort + "X\\peer.dll");
                });
                check(distinct.Key.SharedOwners.Count == 0 && !distinct.Refused && distinct.Intact,
                    "Paths that only share the peer's prefix, including a folder name with a comma, are not shared and the key stays previewable: " + string.Join(", ", distinct.Key.SharedOwners));

                var named = Case("app-short-value", null, key => key.SetValue("Launcher", "\"" + Path.Combine(installShort, "app.exe") + "\" --start"));
                check(named.Found.Any(item => item.Kind == "registryValue" && item.Registry?.ValueName == "Launcher" && item.SharedOwners.Count == 0),
                    "A value that names the removed app through its short path is offered as that app's leftover");

                var pluginPeer = PeerAt(Path.Combine(installShort, "Plugins", "Missing Spelling Plugin"));
                var fileContext = new CleanupContext(queue, authority, application, [pluginPeer], true);
                var fileEngine = new ApplicationCleanup(() => fileContext, [], []);
                var folder = fileEngine.Scan(CancellationToken.None).Candidates.Single(item => item.Target == install);
                var folderRefused = false;
                try { fileEngine.Preview(Path.Combine(root, "review-folder", "review.json"), [folder.ItemId], true, true); }
                catch (InvalidDataException) { folderRefused = true; }
                check(folder.SharedOwners.Contains(Peer) && folderRefused && File.ReadAllText(settings) == "fixture",
                    "A peer recorded at a missing folder inside the app folder's short path keeps the folder shared and refuses its preview");

                var appearScope = registryRoot + "\\appear";
                var appearKey = appearScope + "\\" + App;
                using (var key = hive.CreateSubKey(appearKey)) key.SetValue("Plugin", "\"" + Path.Combine(install, "Shared Plugin", "plugin.dll") + "\"");
                var appearBefore = Snapshot(hive, appearKey);
                var appearContext = new CleanupContext(queue, authority, application, [], true);
                var appearEngine = new ApplicationCleanup(() => appearContext, [], [new("CurrentUser", "Registry64", appearScope, "key", null)]);
                var selection = appearEngine.Scan(CancellationToken.None).Candidates.Where(item => item.Kind == "registryKey" || item.Target == install).Select(item => item.ItemId).ToArray();
                var reviewPath = Path.Combine(root, "review-appear", "review.json");
                reviews.Add(appearEngine.Preview(reviewPath, selection, true, true));
                appearContext = appearContext with { Peers = [PeerAt(Path.Combine(installShort, "Shared Plugin"))] };
                var applied = appearEngine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), Path.Combine(root, "review-appear", "journal.json"));
                check(selection.Length == 2 && applied.Status == "needsReconciliation" && Snapshot(hive, appearKey) == appearBefore && File.ReadAllText(settings) == "fixture",
                    "A peer that appears through a short path after review stops cleanup before any registry or file deletion");
                var again = false;
                try { appearEngine.Preview(Path.Combine(root, "review-appear-again", "review.json"), selection, true, true); }
                catch (InvalidDataException) { again = true; }
                check(again && Snapshot(hive, appearKey) == appearBefore, "A fresh review with that peer installed refuses both the key and the folder");

                var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                var windowsFolder = new[] { "Windows NT", "Windows Defender", "Windows Mail", "Windows Photo Viewer" }.Select(name => Path.Combine(programFiles, name)).FirstOrDefault(Directory.Exists);
                var windowsShort = windowsFolder is null ? null : ShortPath(windowsFolder);
                if (windowsShort is null || string.Equals(windowsShort, windowsFolder, StringComparison.OrdinalIgnoreCase)) Console.WriteLine("SKIP No Windows folder under Program Files has an 8.3 alias on this volume");
                else
                {
                    var windowsScope = registryRoot + "\\windows-owned";
                    using (var created = hive.CreateSubKey(windowsScope + "\\Settings")) created.SetValue("Tool", "\"" + Path.Combine(windowsShort, "tool.exe") + "\"");
                    var owned = new LeftoverDiscovery(application with { InstallLocation = windowsShort }, []).Scan(CancellationToken.None, [], [new("CurrentUser", "Registry64", windowsScope, "key", null)]);
                    check(owned.Candidates.Length == 0 && LeftoverDiscovery.MicrosoftOwnedPath(Path.Combine(windowsShort, "Roo Industries Example")),
                        "An app installed in a Windows-owned folder given by its 8.3 alias offers neither that folder nor values that name it");
                }

            }
            else Console.WriteLine("SKIP Shared-owner spelling fixtures have no available 8.3 aliases");
            ProtectedRoots(check, root);
            RealRoots(check);
            ChangingAncestors(check, root, hive, registryRoot, reviews);
            RetargetedPeer(check, root, hive, registryRoot, reviews);
        }
        finally
        {
            foreach (var review in reviews)
                if (review.Registry is { } part) hive.DeleteSubKeyTree(OperationFiles.Read<RegistryCleanupPreview>(part.PreviewPath).Receipt.KeyPath, false);
            hive.DeleteSubKeyTree(registryRoot, false);
            Directory.Delete(root, true);
        }
        using (var left = hive.OpenSubKey(registryRoot))
            check(!Directory.Exists(root) && left is null, "Path spelling checks remove their folders, aliases and registry keys");
    }

    static void ChangingAncestors(Action<bool, string> check, string root, RegistryKey hive, string registryRoot, List<ApplicationCleanupPreview> reviews)
    {
        var modes = new[] { "network", "cycle" };
        var probe = Path.Combine(root, "Changing Link Capability");
        try { Directory.CreateSymbolicLink(probe, root); }
        catch (Exception error) when (error is UnauthorizedAccessException ||
            error is IOException && (error.HResult & 0xFFFF) is 1 or 50 or 1314)
        {
            foreach (var mode in modes) Console.WriteLine("SKIP " + mode + ": an unsafe ancestor observed after an absent peer keeps the app's folder, key and value from cleanup at review, Apply and the final check (cannot create symbolic links, error " + (error.HResult & 0xFFFF) + ")");
            return;
        }
        Directory.Delete(probe);
        foreach (var mode in modes)
        {
            var target = Directory.CreateDirectory(Path.Combine(root, "Changing App " + mode)).FullName;
            var data = Path.Combine(target, "settings.txt");
            var parent = Directory.CreateDirectory(Path.Combine(root, "Changing Parent " + mode)).FullName;
            var peerPath = Path.Combine(parent, "Missing Peer");
            var scope = registryRoot + "\\changing-" + mode;
            var keyPath = scope + "\\Changing App " + mode;
            var launchers = scope + "\\Launchers";
            void Seed()
            {
                File.WriteAllText(data, "fixture");
                using (var key = hive.CreateSubKey(keyPath)) key.SetValue("Setting", "fixture");
                using (var key = hive.CreateSubKey(launchers)) key.SetValue("Changing App", "\"" + Path.Combine(target, "app.exe") + "\"");
            }
            Seed();
            string State() => (File.Exists(data) ? File.ReadAllText(data) : "missing") + "|" + Snapshot(hive, keyPath) + "|" + Snapshot(hive, launchers);
            var before = State();
            var link = mode == "network" ? @"\\192.0.2.139\ChangingAncestorFixture" : parent;
            var linked = false; var absences = 0; var calls = 0; var raceFrom = int.MaxValue;
            Action<int>? onCall = null;
            var observed = new List<NativeFiles.PathWalk>();
            var expected = mode == "network" ? NativeFiles.PathWalk.OffComputer : NativeFiles.PathWalk.Unknown;
            try
            {
                CleanupPath.AfterResolveForTest = (path, walk) =>
                {
                    if (string.Equals(path, peerPath, StringComparison.OrdinalIgnoreCase) && walk == NativeFiles.PathWalk.Absent && calls >= raceFrom)
                    {
                        absences++;
                        Directory.Delete(parent);
                        Directory.CreateSymbolicLink(parent, link);
                        linked = true;
                    }
                    else if (string.Equals(path, parent, StringComparison.OrdinalIgnoreCase) && linked)
                    {
                        observed.Add(walk);
                        Directory.Delete(parent); Directory.CreateDirectory(parent); linked = false;
                    }
                };
                var application = new CleanupApplication { AppId = "fixture:changing-" + mode, DisplayName = "Changing App " + mode, Publisher = "Fixture", InstallLocation = target, PackageFamilyName = null };
                var peer = application with { AppId = "fixture:changing-peer", DisplayName = "Independent changing tool", InstallLocation = peerPath };
                var authority = new CleanupAuthority
                {
                    AppId = application.AppId, ProviderIdentityHash = new string('E', 64), Owner = OperationOwner.Current(),
                    ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
                };
                var context = new CleanupContext(Path.Combine(root, "changing-queue.json"), authority, application, [peer], true);
                var engine = new ApplicationCleanup(() => { calls++; onCall?.Invoke(calls); return context; }, [], [new("CurrentUser", "Registry64", scope, "key", null)]);

                (T Result, int Races) Race<T>(int from, Func<T> action, Action<int>? at = null)
                {
                    calls = 0; raceFrom = from; onCall = at; absences = 0; observed.Clear();
                    try { var result = action(); return (result, observed.Count == absences && observed.All(value => value == expected) ? absences : -1); }
                    finally { raceFrom = int.MaxValue; onCall = null; }
                }
                T Unsafe<T>(Func<T> action)
                {
                    Directory.Delete(parent); Directory.CreateSymbolicLink(parent, link);
                    try { return action(); }
                    finally { Directory.Delete(parent); Directory.CreateDirectory(parent); }
                }
                (string Review, string Hash, ApplicationCleanupPreview Plan) Review(string name, params LeftoverCandidate[] items)
                {
                    var review = Path.Combine(root, "changing-" + mode + "-" + name, "review.json");
                    Seed();
                    var plan = engine.Preview(review, items.Select(item => item.ItemId).ToArray(), true, true);
                    reviews.Add(plan);
                    return (review, OperationFiles.HashFile(review), plan);
                }
                ApplicationCleanupJournal Apply((string Review, string Hash, ApplicationCleanupPreview Plan) review) =>
                    engine.Apply(review.Review, review.Hash, Path.Combine(Path.GetDirectoryName(review.Review)!, "journal.json"));
                ApplicationCleanupJournal? Restore(string journal)
                {
                    try { return engine.Restore(journal); }
                    catch (InvalidDataException) { return null; }
                }
                string? Refused(LeftoverCandidate item)
                {
                    try { engine.Preview(Path.Combine(root, "changing-" + mode + "-refused", "review.json"), [item.ItemId], true, true); return null; }
                    catch (InvalidDataException error) { return error.Message; }
                }
                bool ReceiptAbsent(ApplicationCleanupPreview plan)
                {
                    using var receipt = hive.OpenSubKey(OperationFiles.Read<RegistryCleanupPreview>(plan.Registry!.PreviewPath).Receipt.KeyPath);
                    return receipt is null;
                }
                void Measure(string scenario, object result) => Console.WriteLine("MEASURE changingAncestor " + JsonSerializer.Serialize(new { Mode = mode, Scenario = scenario, Result = result }));

                var clean = engine.Scan(CancellationToken.None).Candidates;
                var folder = clean.Single(item => item.Target == target);
                var key = clean.Single(item => item.Kind == "registryKey");
                var value = clean.Single(item => item.Kind == "registryValue");
                check(clean.Length == 3 && clean.All(item => item.OwnershipComplete && item.SharedOwners.Count == 0),
                    mode + ": with the peer's parent unchanged, the app's folder, key and launcher value are offered as its own");

                var scanned = Race(1, () => engine.Scan(CancellationToken.None).Candidates);
                var named = "Ownership could not be checked for installed app: " + peer.DisplayName;
                var refusals = new[] { folder, key, value }.Select(item => Race(1, () => Refused(item))).ToArray();
                Measure("review", new { scanned.Races, Incomplete = scanned.Result.Select(item => item.Kind + "=" + !item.OwnershipComplete).ToArray(), Refusals = refusals.Select(item => item.Result).ToArray() });
                check(scanned.Races > 0 && scanned.Result.Length == 3 && scanned.Result.All(item => !item.OwnershipComplete && item.Evidence.Contains(named)),
                    mode + ": an unsafe ancestor observed after an absent peer leaves the app's folder, key and value with incomplete ownership that names the peer");
                check(refusals.All(item => item.Races > 0) && refusals.Select(item => item.Result).SequenceEqual(new[] { folder, key, value }.Select(item => Refusal + item.Target)),
                    mode + ": that race refuses the folder, key and value previews for incomplete ownership");

                var registry = Review("registry", key, value);
                var files = Review("files", folder);
                var registryApply = Race(1, () => Apply(registry));
                var fileApply = Race(1, () => Apply(files));
                Measure("apply", new { Registry = new { registryApply.Races, registryApply.Result.Status, registryApply.Result.Errors }, Files = new { fileApply.Races, fileApply.Result.Status, fileApply.Result.Errors } });
                check(registryApply.Races > 0 && registryApply.Result.Status == "needsReconciliation" && registryApply.Result.Errors.SequenceEqual([Refusal + key.Target]) &&
                    !File.Exists(registry.Plan.Registry!.JournalPath) && State() == before,
                    mode + ": the race after review stops the registry cleanup at Apply before any backup or deletion");
                check(fileApply.Races > 0 && fileApply.Result.Status == "needsReconciliation" && fileApply.Result.Errors.SequenceEqual([Refusal + folder.Target]) &&
                    !File.Exists(files.Plan.Files!.JournalPath) && File.ReadAllText(data) == "fixture",
                    mode + ": the race after review stops the file cleanup at Apply before any backup or deletion");

                var finalRegistry = Review("final-registry", key, value);
                var finalFiles = Review("final-files", folder);
                var registryFinal = Race(3, () => Apply(finalRegistry));
                var registryJournal = OperationFiles.Read<RegistryCleanupJournal>(finalRegistry.Plan.Registry!.JournalPath);
                var fileFinal = Race(3, () => Apply(finalFiles));
                var fileJournal = OperationFiles.Read<FileCleanupJournal>(finalFiles.Plan.Files!.JournalPath);
                Measure("finalCheck", new { Registry = new { registryFinal.Races, registryFinal.Result.Status, Part = registryJournal.Status, registryJournal.Error, Backup = File.Exists(registryJournal.BackupPath) },
                    Files = new { fileFinal.Races, fileFinal.Result.Status, Part = fileJournal.Status, Entries = fileJournal.Entries.Select(entry => entry.Status + ":" + entry.Error).ToArray() } });
                check(registryFinal.Races == 1 && registryFinal.Result.Status == "needsReconciliation" && registryJournal.Status == "needsReconciliation" &&
                    registryJournal.Error == Refusal + key.Target && File.Exists(registryJournal.BackupPath) && ReceiptAbsent(finalRegistry.Plan) && State() == before,
                    mode + ": the race at the final check after the registry backup keeps the key and value and commits nothing");
                check(fileFinal.Races == 1 && fileFinal.Result.Status == "needsReconciliation" && fileJournal.Status == "needsReconciliation" &&
                    fileJournal.Entries.All(entry => entry.Status == "pending") && fileJournal.Entries.Any(entry => entry.Error == Refusal + folder.Target) && File.ReadAllText(data) == "fixture",
                    mode + ": the race at the final check after the file backup keeps the folder");

                var restoreReview = Review("restore", key, value, folder);
                var restoreJournal = Path.Combine(Path.GetDirectoryName(restoreReview.Review)!, "journal.json");
                var applied = Apply(restoreReview);
                var removed = State();
                var restore = Unsafe(() => (Journal: engine.Restore(restoreJournal), Candidates: engine.Scan(CancellationToken.None).Candidates));
                Measure("restore", new { Applied = applied.Status, applied.Errors, Restored = restore.Journal.Status, RestoreErrors = restore.Journal.Errors, Incomplete = restore.Candidates.Count(item => !item.OwnershipComplete) });
                check(applied.Status == "applied" && removed == "missing|missing|",
                    mode + ": with the peer's parent unchanged, one cleanup of the key, value and folder still applies");
                check(restore.Journal.Status == "restored" && State() == before && restore.Candidates.Length == 3 && restore.Candidates.All(item => !item.OwnershipComplete),
                    mode + ": Restore brings back the key, value and folder while the peer's folder can't be checked");

                var crashReview = Review("crash", key, value);
                var crashJournal = Path.Combine(Path.GetDirectoryName(crashReview.Review)!, "journal.json");
                byte[]? appSaved = null, partSaved = null;
                Race(int.MaxValue, () => Apply(crashReview), call =>
                {
                    if (call != 3) return;
                    appSaved = File.ReadAllBytes(crashJournal); partSaved = File.ReadAllBytes(crashReview.Plan.Registry!.JournalPath);
                    throw new IOException("Simulated crash before the registry commit.");
                });
                File.WriteAllBytes(crashJournal, appSaved!); File.WriteAllBytes(crashReview.Plan.Registry!.JournalPath, partSaved!);
                var crash = Unsafe(() => (Again: Apply(crashReview), Restored: Restore(crashJournal)));
                Measure("crashBeforeCommit", new { Again = crash.Again.Status, crash.Again.Errors, Restored = crash.Restored?.Status, RegistryStatus = crash.Restored?.RegistryStatus });
                check(crash.Again.Status == "needsReconciliation" && crash.Again.Errors.SequenceEqual([Refusal + key.Target]) && ReceiptAbsent(crashReview.Plan) &&
                    crash.Restored?.Status == "restored" && crash.Restored.RegistryStatus == "notCommitted" && State() == before,
                    mode + ": after a crash before the registry commit, Apply again refuses while the peer's folder can't be checked and Restore finds nothing removed");

                var committedReview = Review("committed", key, value);
                var committedJournal = Path.Combine(Path.GetDirectoryName(committedReview.Review)!, "journal.json");
                byte[]? beforeCommit = null;
                var first = Race(int.MaxValue, () => Apply(committedReview), call => { if (call == 3) beforeCommit = File.ReadAllBytes(committedJournal); });
                var gone = State();
                File.WriteAllBytes(committedJournal, beforeCommit!);
                var committed = Unsafe(() => (Again: Apply(committedReview), After: State(), Restored: engine.Restore(committedJournal)));
                Measure("crashAfterCommit", new { First = first.Result.Status, Again = committed.Again.Status, AgainErrors = committed.Again.Errors, Restored = committed.Restored.Status, RestoreErrors = committed.Restored.Errors });
                check(first.Result.Status == "applied" && gone == "fixture|missing|" && committed.Again.Status == "applied" && committed.Again.Errors.Count == 0 && committed.After == gone,
                    mode + ": after a crash right after the registry commit, Apply again finishes without removing anything new while the peer's folder can't be checked");
                check(committed.Restored.Status == "restored" && State() == before, mode + ": Restore then brings the key and value back");
            }
            finally
            {
                CleanupPath.AfterResolveForTest = null;
                if (linked) { Directory.Delete(parent); Directory.CreateDirectory(parent); }
            }
        }
    }

    static void RetargetedPeer(Action<bool, string> check, string root, RegistryKey hive, string registryRoot, List<ApplicationCleanupPreview> reviews)
    {
        var target = Directory.CreateDirectory(Path.Combine(root, "Retarget App")).FullName;
        var elsewhere = Directory.CreateDirectory(Path.Combine(root, "Retarget Elsewhere")).FullName;
        var shared = Directory.CreateDirectory(Path.Combine(root, "Retarget Shared")).FullName;
        var link = Path.Combine(root, "Retarget Peer");
        var scope = registryRoot + "\\retarget";
        var keyPath = scope + "\\Retarget App";
        using (var created = hive.CreateSubKey(keyPath)) created.SetValue("Plugin", "\"" + Path.Combine(shared, "plugin.dll") + "\"");
        var before = Snapshot(hive, keyPath);
        AliasOwnershipChecks.Junction(link, elsewhere);
        try
        {
            var application = new CleanupApplication { AppId = "fixture:retarget-registry", DisplayName = "Retarget App", Publisher = "Fixture", InstallLocation = target, PackageFamilyName = null };
            var peer = application with { AppId = "fixture:retarget-registry-peer", DisplayName = "Independent retarget tool", InstallLocation = link };
            var authority = new CleanupAuthority
            {
                AppId = application.AppId, ProviderIdentityHash = new string('F', 64), Owner = OperationOwner.Current(),
                ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
            };
            var context = new CleanupContext(Path.Combine(root, "retarget-queue.json"), authority, application, [peer], true);
            var engine = new ApplicationCleanup(() => context, [], [new("CurrentUser", "Registry64", scope, "key", null)]);
            var key = engine.Scan(CancellationToken.None).Candidates.Single(item => item.Kind == "registryKey");
            var reviewPath = Path.Combine(root, "retarget-registry", "review.json");
            var review = engine.Preview(reviewPath, [key.ItemId], true, true);
            reviews.Add(review);
            Directory.Delete(link); AliasOwnershipChecks.Junction(link, shared);
            var rescanned = engine.Scan(CancellationToken.None).Candidates.Single(item => item.Kind == "registryKey");
            var result = engine.Apply(reviewPath, OperationFiles.HashFile(reviewPath), Path.Combine(root, "retarget-registry", "journal.json"));
            Console.WriteLine("MEASURE retargetedPeer " + JsonSerializer.Serialize(new { Reviewed = key.SharedOwners, Rescanned = rescanned.SharedOwners, result.Status, result.Errors }));
            check(key.SharedOwners.Count == 0 && rescanned.SharedOwners.Contains(peer.DisplayName) && result.Status == "needsReconciliation" && result.Errors.SequenceEqual([Refusal + key.Target]) &&
                !File.Exists(review.Registry!.JournalPath) && Snapshot(hive, keyPath) == before,
                "A peer junction retargeted after review to a folder the key's values name stops the registry cleanup before any backup or deletion");
        }
        finally { if (Directory.Exists(link)) Directory.Delete(link); }
    }

    static void ProtectedRoots(Action<bool, string> check, string root)
    {
        var parent = Directory.CreateDirectory(Path.Combine(root, "Protected Spelling Parent")).FullName;
        var temp = Directory.CreateDirectory(Path.Combine(parent, "Protected Spelling Temp")).FullName;
        File.WriteAllText(Path.Combine(temp, "keep.txt"), "fixture");
        var ordinary = Directory.CreateDirectory(Path.Combine(root, "Ordinary Spelling App")).FullName;
        File.WriteAllText(Path.Combine(ordinary, "data.txt"), "fixture");
        var parentShort = Alias(parent, "PROTEC~1");
        var tempAlias = Alias(temp, "PROTTEMP", force: true);
        var ordinaryShort = Alias(ordinary, "ORDINA~1");
        if (parentShort is null || tempAlias is null || ordinaryShort is null)
        {
            Console.WriteLine("SKIP Protected-root spelling fixtures have no available 8.3 aliases");
            return;
        }
        var tempShort = Path.Combine(parent, Path.GetFileName(tempAlias));
        foreach (var (name, tmp, paths) in new[] { ("long-temp-short-candidates", temp, new[] { tempShort, parentShort, ordinaryShort }), ("short-temp-long-candidates", tempShort, new[] { temp, parent, ordinary }) })
        {
            using var result = JsonDocument.Parse(Probe(check, name, tmp, paths));
            var outcomes = result.RootElement.GetProperty("Outcomes").EnumerateArray().Select(item => item.GetString()!).ToArray();
            Console.WriteLine("MEASURE protectedSpelling " + JsonSerializer.Serialize(new { Scenario = name, Outcomes = outcomes }));
            check(string.Equals(Path.GetFullPath(result.RootElement.GetProperty("Temp").GetString()!).TrimEnd('\\'), Path.GetFullPath(tmp), StringComparison.OrdinalIgnoreCase), name + ": the probe's temp folder is the disposable protected root");
            check(outcomes[0].StartsWith("refused: A shared system", StringComparison.Ordinal), name + ": the protected temp folder is refused before its files are read, however it is spelled");
            check(outcomes[1].StartsWith("refused: A shared system", StringComparison.Ordinal), name + ": a folder that contains the protected temp folder is refused before its files are read");
            check(outcomes[2] == "previewed 2", name + ": an ordinary disposable app folder stays previewable through either spelling");
        }
        check(File.Exists(Path.Combine(temp, "keep.txt")) && File.Exists(Path.Combine(ordinary, "data.txt")), "Protected-root probes change no fixture data");
    }

    public static void ProtectedProbe(string[] paths)
    {
        var authority = new CleanupAuthority
        {
            AppId = "fixture:protected-spelling", ProviderIdentityHash = new string('D', 64), Owner = OperationOwner.Current(),
            ProviderQueryComplete = true, RegistrationPresent = false, RebootPending = false, RemoverRunning = false, RemovalResolved = true,
        };
        var engine = new FileCleanupEngine(() => authority);
        string Outcome(string path)
        {
            try { return "previewed " + engine.Preview(authority.AppId, authority.ProviderIdentityHash, [path], true).Files.Length; }
            catch (InvalidDataException error) { return "refused: " + error.Message; }
        }
        Console.WriteLine(JsonSerializer.Serialize(new { Temp = Path.GetTempPath(), Outcomes = paths.Select(Outcome).ToArray() }));
    }

    static string Probe(Action<bool, string> check, string name, string temp, string[] paths)
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Probe executable is unavailable.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        start.ArgumentList.Add("--path-spelling-probe");
        foreach (var path in paths) start.ArgumentList.Add(path);
        start.Environment["TMP"] = temp;
        start.Environment["TEMP"] = temp;
        using var child = Process.Start(start)!;
        var output = child.StandardOutput.ReadToEndAsync();
        var errors = child.StandardError.ReadToEndAsync();
        var exited = child.WaitForExit(30000);
        if (!exited) { child.Kill(true); child.WaitForExit(); }
        check(exited && child.ExitCode == 0, name + ": the protected-root probe finishes: " + errors.GetAwaiter().GetResult());
        return output.GetAwaiter().GetResult();
    }

    static void RealRoots(Action<bool, string> check)
    {
        foreach (var folder in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.CommonProgramFiles })
        {
            var real = Environment.GetFolderPath(folder);
            var brief = ShortPath(real);
            if (brief is null || string.Equals(brief, real, StringComparison.OrdinalIgnoreCase)) { Console.WriteLine("SKIP " + folder + " has no 8.3 alias on this volume"); continue; }
            check(FileCleanupEngine.IsProtectedPath(brief), "The 8.3 alias of the real " + folder + " folder stays a protected cleanup root");
        }
        var localLow = Path.Combine(RooIndustries.Optimizer.RuntimeEnvironment.Profile, "AppData", "LocalLow");
        check(FileCleanupEngine.IsProtectedPath(localLow) && !FileCleanupEngine.IsProtectedPath(Path.Combine(localLow, "Roo Industries Example")),
            "LocalLow itself is a protected cleanup root while an app folder inside it stays eligible");
    }

    static string? Alias(string path, string name, bool force = false)
    {
        var brief = ShortPath(path);
        if (force || brief is null || string.Equals(Path.GetFileName(brief), Path.GetFileName(path), StringComparison.OrdinalIgnoreCase))
        {
            using var handle = CreateFile(path, 0x10000000, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            PrivilegeScope privilege;
            try
            {
                privilege = new PrivilegeScope("Assign a disposable 8.3 alias", "SeRestorePrivilege");
            }
            catch (System.ComponentModel.Win32Exception error) when (error.NativeErrorCode is 5 or 1300 or 1314)
            {
                Console.WriteLine("SKIP Disposable 8.3 alias assignment needs an unavailable privilege (error " + error.NativeErrorCode + ")");
                return null;
            }
            using (privilege)
            {
                if (handle.IsInvalid || !SetFileShortName(handle, name))
                {
                    Console.WriteLine("SKIP Disposable 8.3 alias assignment failed (error " + Marshal.GetLastWin32Error() + ")");
                    return null;
                }
            }
        }
        brief = ShortPath(path);
        var leaf = Path.GetFileName(brief);
        return leaf is not null && !string.Equals(leaf, Path.GetFileName(path), StringComparison.OrdinalIgnoreCase) &&
            (force ? string.Equals(leaf, name, StringComparison.OrdinalIgnoreCase) : leaf.Contains('~')) ? brief : null;
    }

    static string? ShortPath(string path)
    {
        var buffer = new StringBuilder(32768);
        var length = GetShortPathName(path, buffer, (uint)buffer.Capacity);
        return length == 0 || length >= buffer.Capacity ? null : buffer.ToString();
    }

    static string Snapshot(RegistryKey hive, string path)
    {
        using var key = hive.OpenSubKey(path);
        if (key is null) return "missing";
        return string.Join("|", key.GetValueNames().Order(StringComparer.Ordinal).Select(name => name + "=" + key.GetValueKind(name) + ":" +
            (key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) switch { string[] list => string.Join("\0", list), var value => Convert.ToString(value) })));
    }

    [DllImport("kernel32.dll", EntryPoint = "GetShortPathNameW", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetShortPathName(string path, StringBuilder name, uint length);
    [DllImport("kernel32.dll", EntryPoint = "SetFileShortNameW", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SetFileShortName(SafeFileHandle file, string name);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
