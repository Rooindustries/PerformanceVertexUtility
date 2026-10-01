#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public readonly record struct SkipDecision(string Reason, bool Keep = true);

public sealed record ProtectedFolder(string Label, string Restart, string Busy, string NotAdministrator, bool KeepUntrusted, string[] ShallowNames,
    Func<string, Action?>? Quiesce = null, Func<string, bool, SkipDecision?>? Skip = null, Func<string, (string Source, string Destination)[]>? Companions = null)
{
    public static readonly ProtectedFolder Rules = new("saved rules folder", "save your rules again", "Stop the Roo Industries Governor before protecting its saved rules folder.",
        PolicyRootSecurity.NotAdministrator, false, ["rules", "governor.json", "worker-request.json", "host.json"]);
}

public sealed record MigrationProgress(string Phase, long Files, long Bytes);

public sealed record MigrationReport(bool Migrated, long Files, long Bytes, string[] NotCarried, int Dropped, string? KeptAt);

public sealed class EarlierVersionException(string message) : InvalidOperationException(message) { }

public static class EarlierVersion
{
    public const string Line = "This backup was saved by an older version of the app, before its data folder was protected.";
    public const string Refusal = Line + " The app cannot check that nobody changed it, so it needs your confirmation first.";
}

public static class PolicyRootSecurity
{
    public const string NotAdministrator = "Saved rules need administrator rights. Open the app as an administrator and try again.";
    public const string MarkerKey = @"SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots";
    private static readonly SecurityIdentifier Administrators = new(WellKnownSidType.BuiltinAdministratorsSid, null);
    private static readonly SecurityIdentifier LocalSystem = new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier OwnerRights = new("S-1-3-4");
    private const int GenericAll = 0x10000000, GenericWrite = 0x40000000;
    private const FileSystemRights WriteRights = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.WriteAttributes | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
    private const int StrayLimit = 200;
    private const int CopyBuffer = 1 << 18;
    private static readonly JsonSerializerOptions ManifestJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static event Action<MigrationProgress>? Progress;
    public static MigrationReport? LastReport { get; private set; }

    public static bool Secure(string root, string? userSid = null) => Secure(root, ProtectedFolder.Rules, userSid);

    public static bool Secure(string root, ProtectedFolder kind, string? userSid = null)
    {
        root = Normalize(root);
        var parent = Path.GetDirectoryName(root) ?? throw new InvalidDataException("The " + kind.Label + " needs a parent folder.");
        var name = Path.GetFileName(root);
        RequireElevated(kind);
        using var identity = WindowsIdentity.GetCurrent();
        var user = userSid is null ? identity.User ?? throw new InvalidOperationException("The current Windows user SID is unavailable.") : new SecurityIdentifier(userSid);
        var local = Canonical(user == identity.User ? RuntimeEnvironment.LocalAppData : Path.Combine(ProfilePath(user), "AppData", "Local"));
        if (!Canonical(root).StartsWith(local + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new UnauthorizedAccessException("The " + kind.Label + " must be inside the Windows user's local app data.");
        var marker = MarkerName(root);
        using var mutex = new Mutex(false, MutexName(marker));
        var held = false;
        var waited = Stopwatch.StartNew();
        while (!held && waited.Elapsed < TimeSpan.FromMinutes(30))
        {
            try { held = mutex.WaitOne(1000); }
            catch (AbandonedMutexException) { held = true; }
            if (!held) Progress?.Invoke(new("waiting", 0, 0));
        }
        if (!held) throw new IOException("Another app is protecting the " + kind.Label + ". Try again in a moment.");
        try
        {
            LastReport = null;
            if (Directory.Exists(parent) && Adopt(root, parent, name, kind, user)) { Mark(marker, user); Tidy(root, parent, name, kind); return false; }
            if (Directory.Exists(root) && new DirectoryInfo(root).Attributes.HasFlag(FileAttributes.ReparsePoint) && !Marked(marker))
                Directory.Move(root, Path.Combine(parent, name + ".untrusted-" + Guid.NewGuid().ToString("N")));
            if (!Directory.Exists(root))
            {
                Directory.CreateDirectory(parent);
                CreateSecured(root, user, kind);
                Mark(marker, user);
                Tidy(root, parent, name, kind);
                return false;
            }
            if (Problem(root, kind) is null) { Mark(marker, user); Tidy(root, parent, name, kind); return false; }
            if (Marked(marker))
                throw new UnauthorizedAccessException("The " + kind.Label + " was changed without administrator rights after it was protected, so it is not trusted. Delete " + root + " and " + kind.Restart + ".");
            if (!kind.KeepUntrusted) RequireMigratable(root, kind);
            var resume = kind.Quiesce?.Invoke(root);
            try
            {
                Migrate(root, parent, name, user, kind);
                Mark(marker, user);
                Tidy(root, parent, name, kind);
            }
            catch (Exception error)
            {
                try { resume?.Invoke(); }
                catch (Exception resumeError) { throw new AggregateException(error.Message + " " + resumeError.Message, error, resumeError); }
                throw;
            }
            resume?.Invoke();
            return true;
        }
        finally { mutex.ReleaseMutex(); }
    }

    public static string MutexName(string marker) => @"Global\RooIndustriesGovernorSecure-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(marker)))[..32];

    private sealed record Manifest(string Id, string Source, string? Legacy, string Started, long Files = 0);

    private static Manifest? ReadManifest(string folder, string file)
    {
        try
        {
            var bytes = NativeFiles.ReadBounded(folder, file, 1 << 16, out _);
            return bytes is null || bytes.Length == 0 ? null : JsonSerializer.Deserialize<Manifest>(bytes, ManifestJson);
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { return null; }
    }

    private static void WriteManifest(string folder, string file, Manifest manifest)
    {
        var path = Path.Combine(folder, file);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(manifest, ManifestJson));
        File.Move(temporary, path, true);
    }

    private static bool SamePath(string left, string right) => string.Equals(Canonical(left), Canonical(right), StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<string> Siblings(string parent, string name, string kind)
        => Directory.Exists(parent) ? Directory.EnumerateDirectories(parent, name + "." + kind + "-*").OrderByDescending(path => Directory.GetLastWriteTimeUtc(path)) : [];

    private static bool Adopt(string root, string parent, string name, ProtectedFolder kind, SecurityIdentifier user)
    {
        foreach (var candidate in Siblings(parent, name, "secure").ToArray())
        {
            if (Problem(candidate, kind) is not null) continue;
            var building = ReadManifest(candidate, ".migrating");
            if (building is null || File.Exists(Path.Combine(candidate, ".migrated")) || !SamePath(building.Source, root)) continue;
            if (building.Legacy is null || !Directory.Exists(building.Legacy)) { if (Directory.Exists(root)) continue; }
            try
            {
                var run = new Run();
                if (building.Legacy is not null && Directory.Exists(building.Legacy)) { Finish(candidate, building.Legacy, kind, user, run); Retire(building.Legacy, run, parent, name); }
                else Seal(candidate, run, building, null);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        foreach (var candidate in Siblings(parent, name, "secure").OrderByDescending(path => Completed(path)).ToArray())
        {
            if (Problem(candidate, kind) is not null || File.Exists(Path.Combine(candidate, ".migrating")) && !File.Exists(Path.Combine(candidate, ".migrated"))) continue;
            try
            {
                if (!Directory.Exists(root)) { Directory.Move(candidate, root); return true; }
                if (Problem(root, kind) is null) return false;
                if (ReadManifest(candidate, ".migrated") is null) continue;
                Fold(candidate, root, parent, name, kind, user);
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return false;
    }

    public static bool MigrationInFlight(string parent, string name)
    {
        if (!Directory.Exists(parent)) return false;
        var root = Path.Combine(parent, name);
        foreach (var candidate in Siblings(parent, name, "secure"))
        {
            try
            {
                if ((ReadManifest(candidate, ".migrating") ?? ReadManifest(candidate, ".migrated")) is { } manifest && SamePath(manifest.Source, root) && OwnedByAdministrators(candidate) && WriterOf(candidate) is null) return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return false;
    }

    private static DateTime Completed(string folder)
    {
        var done = Path.Combine(folder, ".migrated");
        return File.Exists(done) ? File.GetLastWriteTimeUtc(done) : Directory.GetLastWriteTimeUtc(folder);
    }

    private sealed class Run
    {
        public long Files, Bytes;
        public readonly List<string> NotCarried = [];
        public int Dropped;
        public readonly HashSet<string> Kept = new(StringComparer.OrdinalIgnoreCase);
        public readonly Dictionary<string, (long Length, long Ticks)> Copied = new(StringComparer.OrdinalIgnoreCase);
        public readonly HashSet<string> Retire = new(StringComparer.OrdinalIgnoreCase);
        public readonly List<string> DroppedFolders = [];
        public string Phase = "copying";
        public bool Retires(string relative) => Retire.Contains(relative) || DroppedFolders.Any(folder => relative.StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
        private long _last;
        public void Tick(bool force = false)
        {
            var now = Environment.TickCount64;
            if (!force && now - _last < 500) return;
            _last = now;
            PolicyRootSecurity.Progress?.Invoke(new(Phase, Files, Bytes));
        }
        public void Reset() { Kept.Clear(); Copied.Clear(); Retire.Clear(); DroppedFolders.Clear(); }
    }

    private static void Pause(string at)
    {
#if GOVERNOR_TEST_HOOKS
        if (string.Equals(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_AT") ?? "detached", at, StringComparison.OrdinalIgnoreCase) &&
            int.TryParse(Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_MIGRATION_PAUSE_MS"), out var pause) && pause > 0) Thread.Sleep(Math.Min(pause, 30000));
#endif
    }

    private static void Migrate(string root, string parent, string name, SecurityIdentifier user, ProtectedFolder kind)
    {
        var run = new Run();
        string temporary;
        string legacy;
        var building = Siblings(parent, name, "secure").Select(path => (Path: path, Manifest: ReadManifest(path, ".migrating"))).FirstOrDefault(item =>
            item.Manifest is not null && SamePath(item.Manifest.Source, root) && !File.Exists(Path.Combine(item.Path, ".migrated")) && Problem(item.Path, kind) is null);
        if (building.Manifest?.Legacy is { } frozen && Directory.Exists(frozen))
        {
            temporary = building.Path; legacy = frozen;
            Finish(temporary, legacy, kind, user, run);
        }
        else
        {
            temporary = building.Path ?? Path.Combine(parent, name + ".secure-" + Guid.NewGuid().ToString("N"));
            legacy = Path.Combine(parent, name + ".legacy-" + Guid.NewGuid().ToString("N"));
            var manifest = building.Manifest ?? new(Guid.NewGuid().ToString("N"), root, null, DateTime.UtcNow.ToString("o"));
            if (building.Path is null) { CreateSecured(temporary, user, kind); WriteManifest(temporary, ".migrating", manifest); }
            run.Phase = "copying";
            Sync(root, temporary, kind, user, run, final: false, merge: false);
            Pause("copied");
            run.Phase = "switching";
            run.Tick(true);
            WriteManifest(temporary, ".migrating", manifest with { Legacy = legacy });
            for (var attempt = 1; ; attempt++)
            {
                try { Directory.Move(root, legacy); break; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    if (attempt >= 5 || !kind.KeepUntrusted) { WriteManifest(temporary, ".migrating", manifest); throw new IOException(kind.Busy + " " + error.Message, error); }
                    Thread.Sleep(200 * attempt);
                    run.Phase = "copying";
                    Sync(root, temporary, kind, user, run, final: false, merge: false);
                }
            }
            Pause("detached");
            Finish(temporary, legacy, kind, user, run);
        }
        Pause("sealed");
        var strays = new List<string>();
        for (var attempt = 0; ; attempt++)
        {
            try { Directory.Move(temporary, root); break; }
            catch (IOException) when (Directory.Exists(root) && attempt < StrayLimit)
            {
                var stray = Path.Combine(parent, name + ".stray-" + Guid.NewGuid().ToString("N"));
                MoveAway(root, stray); strays.Add(stray);
            }
        }
        Pause("attached");
        var notCarried = run.NotCarried.ToList();
        foreach (var stray in strays)
        {
            var folded = new Run { Phase = "merging" };
            Sync(stray, root, kind, user, folded, final: true, merge: true);
            notCarried.AddRange(folded.NotCarried);
            var leftover = Retire(stray, folded, parent, name);
            if (leftover is not null) notCarried.Add("kept: " + leftover);
        }
        foreach (var (source, destination) in kind.Companions?.Invoke(root) ?? [])
        {
            try
            {
                if (!Directory.Exists(source) || new DirectoryInfo(source).Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                Directory.CreateDirectory(destination);
                var companion = new Run { Phase = "merging" };
                Sync(source, destination, kind, user, companion, final: true, merge: true);
                notCarried.AddRange(companion.NotCarried);
            }
            catch (Exception error) when (Recoverable(error)) { notCarried.Add(source + " (" + error.Message + ")"); }
        }
        var kept = Retire(legacy, run, parent, name);
        LastReport = new(true, run.Files, run.Bytes, notCarried.ToArray(), run.Dropped, kept);
        WriteLog(root, LastReport);
    }

    private static void MoveAway(string from, string to)
    {
        for (var attempt = 1; ; attempt++)
        {
            try { Directory.Move(from, to); return; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (attempt >= 60) throw new IOException("Another program kept " + from + " open while it was being protected. Close it and open the app again; the saved data is kept and is picked up on the next start.", error);
                Thread.Sleep(100);
            }
        }
    }

    private static void Fold(string complete, string root, string parent, string name, ProtectedFolder kind, SecurityIdentifier user)
    {
        var strays = new List<string>();
        for (var attempt = 0; ; attempt++)
        {
            var stray = Path.Combine(parent, name + ".stray-" + Guid.NewGuid().ToString("N"));
            MoveAway(root, stray); strays.Add(stray);
            try { Directory.Move(complete, root); break; }
            catch (IOException) when (Directory.Exists(root) && attempt < StrayLimit) { }
        }
        foreach (var stray in strays)
        {
            var folded = new Run { Phase = "merging" };
            Sync(stray, root, kind, user, folded, final: true, merge: true);
            Retire(stray, folded, parent, name);
        }
    }

    private static void WriteLog(string root, MigrationReport report)
    {
        try
        {
            var logs = Path.Combine(root, "logs");
            Directory.CreateDirectory(logs);
            var lines = new List<string> { "Data folder protected " + DateTime.UtcNow.ToString("o"), "Carried " + report.Files + " files (" + report.Bytes + " bytes), dropped " + report.Dropped + " temporary entries." };
            lines.AddRange(report.NotCarried.Select(item => "Not carried over: " + item));
            if (report.KeptAt is not null) lines.Add("Entries that were not carried over are kept at " + report.KeptAt);
            File.WriteAllLines(Path.Combine(logs, "data-folder-migration.log"), lines);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private static void Finish(string temporary, string legacy, ProtectedFolder kind, SecurityIdentifier user, Run run)
    {
        run.Phase = "finishing";
        run.Reset();
        Sync(legacy, temporary, kind, user, run, final: true, merge: false);
        var manifest = ReadManifest(temporary, ".migrating");
        Seal(temporary, run, manifest, legacy);
        if (Problem(temporary, kind) is { } copied) throw new UnauthorizedAccessException("The protected copy of the " + kind.Label + " is not protected: " + copied);
    }

    private static void Seal(string temporary, Run run, Manifest? manifest, string? legacy)
    {
        if (legacy is not null)
            foreach (var stale in Directory.EnumerateFileSystemEntries(temporary, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0 }).OrderByDescending(path => path.Length).ToArray())
            {
                var relative = Path.GetRelativePath(temporary, stale);
                if (relative is ".migrated" or ".migrating" || run.Kept.Contains(relative) || !Path.Exists(stale)) continue;
                if (Directory.Exists(stale)) Directory.Delete(stale, true); else { File.SetAttributes(stale, FileAttributes.Normal); File.Delete(stale); }
            }
        WriteManifest(temporary, ".migrated", (manifest ?? new(Guid.NewGuid().ToString("N"), "", null, DateTime.UtcNow.ToString("o"))) with { Legacy = legacy, Files = run.Files });
        var building = Path.Combine(temporary, ".migrating");
        if (File.Exists(building)) File.Delete(building);
    }

    private static bool Recoverable(Exception error) => error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or Win32Exception or InvalidOperationException;

    private static void RequireSpace(Exception error)
    {
        if ((error.HResult & 0xFFFF) is 0x70 or 0x27) throw new IOException("There is not enough free disk space to protect the app's data folder. Free some space, then open the app again.", error);
    }

    private static void Sync(string source, string destination, ProtectedFolder kind, SecurityIdentifier user, Run run, bool final, bool merge)
    {
        using var sourceHandle = NativeFiles.OpenDirectory(source);
        var sourceInfo = NativeFiles.Info(sourceHandle);
        if (sourceInfo.IsLink || !sourceInfo.IsDirectory) throw new UnauthorizedAccessException("The " + kind.Label + " changed into a link while it was copied.");
        var sourceFinal = (NativeFiles.FinalPath(sourceHandle) ?? throw new IOException("The " + kind.Label + " path could not be read.")).TrimEnd(Path.DirectorySeparatorChar);
        void Skip(string relative, string reason)
        {
            if (!kind.KeepUntrusted) throw new UnauthorizedAccessException("The " + kind.Label + " changed while it was copied, so it is not trusted.");
            run.NotCarried.Add(relative + " (" + reason + ")");
        }
        var pending = new Stack<(string Folder, string Relative)>();
        pending.Push((source, ""));
        while (pending.Count > 0)
        {
            var (folder, parentRelative) = pending.Pop();
            List<FileSystemInfo> entries;
            try { entries = new DirectoryInfo(folder).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false }).ToList(); }
            catch (Exception error) when (Recoverable(error))
            {
                RequireSpace(error);
                Skip(parentRelative.Length == 0 ? "." : parentRelative, "its entries could not be listed");
                if (parentRelative.Length > 0 && run.Kept.Remove(parentRelative))
                {
                    run.Retire.Remove(parentRelative);
                    try { Directory.Delete(Path.Combine(destination, parentRelative)); } catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
                }
                continue;
            }
            foreach (var entry in entries)
            {
                var relative = parentRelative.Length == 0 ? entry.Name : parentRelative + Path.DirectorySeparatorChar + entry.Name;
                var isFolder = entry is DirectoryInfo;
                try
                {
                    if (kind.Skip?.Invoke(relative, isFolder) is { } decision)
                    {
                        if (decision.Keep) Skip(relative, decision.Reason); else { run.Dropped++; run.Retire.Add(relative); if (isFolder) run.DroppedFolders.Add(relative); }
                        continue;
                    }
                    if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) { Skip(relative, "it is a link"); continue; }
                    if (isFolder)
                    {
                        if (CarryFolder(entry.FullName, relative, destination, sourceFinal, kind, run, Skip)) pending.Push((entry.FullName, relative));
                        continue;
                    }
                    if (entry.Name.EndsWith(".lock", StringComparison.OrdinalIgnoreCase) || entry.Name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase) && !OnlyCopy(entry)) { run.Dropped++; run.Retire.Add(relative); continue; }
                    CarryFile(entry.FullName, relative, destination, sourceFinal, kind, run, final, merge, Skip);
                }
                catch (Exception error) when (Recoverable(error) && kind.KeepUntrusted)
                {
                    RequireSpace(error);
                    if (final) { run.Kept.Remove(relative); run.Copied.Remove(relative); run.Retire.Remove(relative); Skip(relative, "it could not be read (" + error.Message + ")"); }
                }
                run.Tick();
            }
        }
        run.Tick(true);
    }

    private static bool OnlyCopy(FileSystemInfo entry)
    {
        var match = System.Text.RegularExpressions.Regex.Match(entry.Name, @"^(?<target>.+)\.[0-9a-fA-F]{32}\.tmp$");
        return match.Success && !Path.Exists(Path.Combine(Path.GetDirectoryName(entry.FullName)!, match.Groups["target"].Value));
    }

    private static bool CarryFolder(string path, string relative, string destination, string sourceFinal, ProtectedFolder kind, Run run, Action<string, string> skip)
    {
        using var handle = NativeFiles.OpenDirectory(path);
        var info = NativeFiles.Info(handle);
        if (info.IsLink || !info.IsDirectory || !NativeFiles.Inside(NativeFiles.FinalPath(handle), sourceFinal)) { skip(relative, "it changed into a link while it was copied"); return false; }
        if (!Trusted(NativeFiles.Owner(handle))) { skip(relative, "it was not created with administrator rights"); return false; }
        var target = Path.Combine(destination, relative);
        Directory.CreateDirectory(target);
        if (NativeFiles.SecurityDescriptor(handle) is { } descriptor)
        {
            var source = new DirectorySecurity();
            source.SetSecurityDescriptorBinaryForm(descriptor);
            PreserveProtection(source, target);
        }
        var folderAttributes = info.Attributes & (FileAttributes.Hidden | FileAttributes.System | FileAttributes.NotContentIndexed);
        if (folderAttributes != 0) File.SetAttributes(target, folderAttributes | FileAttributes.Directory & 0);
        run.Kept.Add(relative);
        run.Retire.Add(relative);
        return true;
    }

    private static void CarryFile(string path, string relative, string destination, string sourceFinal, ProtectedFolder kind, Run run, bool final, bool merge, Action<string, string> skip)
    {
        var listed = new FileInfo(path).Attributes;
        if ((listed & NativeFiles.Placeholder) != 0) { skip(relative, "it is stored in the cloud"); return; }
        if ((listed & FileAttributes.Encrypted) != 0) { skip(relative, "it is encrypted"); return; }
        if ((listed & FileAttributes.SparseFile) != 0) { skip(relative, "it is a sparse file"); return; }
        using var handle = NativeFiles.OpenFile(path);
        var info = NativeFiles.Info(handle);
        var reason = info.IsLink || info.IsDirectory ? "it changed while it was copied"
            : (info.Attributes & (NativeFiles.Placeholder | FileAttributes.Encrypted | FileAttributes.SparseFile | FileAttributes.Device)) != 0 ? "it is not a plain file"
            : !NativeFiles.Inside(NativeFiles.FinalPath(handle), sourceFinal) ? "it resolves outside the folder"
            : info.Links != 1 ? "it has more than one hard link"
            : !Trusted(NativeFiles.Owner(handle)) ? "it was not created with administrator rights"
            : NativeFiles.HasExtraStreams(handle) ? "it has alternate data streams"
            : NativeFiles.HasExtendedAttributes(handle) ? "it has extended attributes" : null;
        if (reason is not null) { skip(relative, reason); return; }
        var target = Path.Combine(destination, relative);
        if (merge && File.Exists(target)) { skip(relative, "a file with this name already exists in the protected folder"); return; }
        var existing = new FileInfo(target);
        if (existing.Exists && existing.Length == info.Length && existing.LastWriteTimeUtc.ToFileTimeUtc() == info.LastWriteTicks)
        {
            run.Files++; run.Kept.Add(relative); run.Retire.Add(relative); run.Copied[relative] = (info.Length, info.LastWriteTicks);
            return;
        }
        if (existing.Exists) File.SetAttributes(target, FileAttributes.Normal);
        using (var output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
        using (var input = new FileStream(handle, FileAccess.Read, 1 << 16))
        {
            var buffer = new byte[CopyBuffer];
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                output.Write(buffer, 0, read);
                run.Bytes += read;
                run.Tick();
            }
        }
        File.SetLastWriteTimeUtc(target, DateTime.FromFileTimeUtc(info.LastWriteTicks));
        File.SetAttributes(target, info.Attributes & NativeFiles.Preserved);
        run.Files++; run.Kept.Add(relative); run.Retire.Add(relative); run.Copied[relative] = (info.Length, info.LastWriteTicks);
    }

    private static string? Retire(string legacy, Run run, string parent, string name)
    {
        try
        {
            using var rootHandle = NativeFiles.OpenDirectory(legacy);
            var rootInfo = NativeFiles.Info(rootHandle);
            var rootFinal = NativeFiles.FinalPath(rootHandle)?.TrimEnd(Path.DirectorySeparatorChar);
            if (rootInfo.IsLink || rootFinal is null) return Keep(legacy, parent, name);
            var folders = new List<(string Path, string Relative)>();
            var pending = new Stack<(string Folder, string Relative)>();
            pending.Push((legacy, ""));
            while (pending.Count > 0)
            {
                var (folder, parentRelative) = pending.Pop();
                List<FileSystemInfo> entries;
                try { entries = new DirectoryInfo(folder).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false }).ToList(); }
                catch (Exception error) when (Recoverable(error)) { continue; }
                foreach (var entry in entries)
                {
                    var relative = parentRelative.Length == 0 ? entry.Name : parentRelative + Path.DirectorySeparatorChar + entry.Name;
                    if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                    if (entry is DirectoryInfo) { folders.Add((entry.FullName, relative)); pending.Push((entry.FullName, relative)); continue; }
                    if (run.Retires(relative) && (!run.Copied.TryGetValue(relative, out var copied) || Same(entry.FullName, rootFinal, copied))) Remove(entry.FullName, rootFinal, directory: false);
                }
            }
            foreach (var (path, relative) in folders.OrderByDescending(item => item.Path.Length))
                if (run.Retires(relative)) Remove(path, rootFinal, directory: true);
            if (!Directory.EnumerateFileSystemEntries(legacy).Any())
            {
                try { Directory.Delete(legacy, false); return null; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception error) when (Recoverable(error)) { }
        return Keep(legacy, parent, name);
    }

    private static string? Keep(string legacy, string parent, string name)
    {
        var kept = Path.Combine(parent, name + ".untrusted-" + Guid.NewGuid().ToString("N"));
        try { Directory.Move(legacy, kept); return kept; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return legacy; }
    }

    private static bool Same(string path, string rootFinal, (long Length, long Ticks) copied)
    {
        try
        {
            using var handle = NativeFiles.OpenFile(path);
            var info = NativeFiles.Info(handle);
            return !info.IsLink && !info.IsDirectory && info.Length == copied.Length && info.LastWriteTicks == copied.Ticks && NativeFiles.Inside(NativeFiles.FinalPath(handle), rootFinal);
        }
        catch (Exception error) when (Recoverable(error)) { return false; }
    }

    private static void Remove(string path, string rootFinal, bool directory)
    {
        try
        {
            using var handle = NativeFiles.OpenEntry(path, forDelete: true);
            var info = NativeFiles.Info(handle);
            if (info.IsLink || info.IsDirectory != directory || !NativeFiles.Inside(NativeFiles.FinalPath(handle), rootFinal)) return;
            NativeFiles.DeleteHandle(handle);
        }
        catch (Exception error) when (Recoverable(error)) { }
    }

    private static void Tidy(string root, string parent, string name, ProtectedFolder kind)
    {
        if (!Directory.Exists(parent) || Problem(root, kind, deep: false) is not null) return;
        foreach (var candidate in Siblings(parent, name, "secure").ToArray())
        {
            var building = ReadManifest(candidate, ".migrating");
            if (building is null || File.Exists(Path.Combine(candidate, ".migrated")) || !SamePath(building.Source, root) || Problem(candidate, kind) is not null) continue;
            try { Directory.Delete(candidate, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        if (ReadManifest(root, ".migrated")?.Legacy is { } legacy && Directory.Exists(legacy) && Path.GetDirectoryName(Normalize(legacy)) is { } legacyParent && SamePath(legacyParent, parent) &&
            Path.GetFileName(legacy).StartsWith(name + ".legacy-", StringComparison.OrdinalIgnoreCase)) RetireCopied(legacy, root, kind, parent, name);
    }

    private static void RetireCopied(string legacy, string root, ProtectedFolder kind, string parent, string name)
    {
        var run = new Run();
        var pending = new Stack<(string Folder, string Relative)>();
        pending.Push((legacy, ""));
        try
        {
            while (pending.Count > 0)
            {
                var (folder, parentRelative) = pending.Pop();
                foreach (var entry in new DirectoryInfo(folder).EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false }).ToList())
                {
                    var relative = parentRelative.Length == 0 ? entry.Name : parentRelative + Path.DirectorySeparatorChar + entry.Name;
                    if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                    if (kind.Skip?.Invoke(relative, entry is DirectoryInfo) is { } decision)
                    {
                        if (!decision.Keep) { run.Retire.Add(relative); if (entry is DirectoryInfo) run.DroppedFolders.Add(relative); }
                        continue;
                    }
                    if (entry is DirectoryInfo)
                    {
                        if (Directory.Exists(Path.Combine(root, relative))) { run.Retire.Add(relative); pending.Push((entry.FullName, relative)); }
                        continue;
                    }
                    if (entry.Name.EndsWith(".lock", StringComparison.OrdinalIgnoreCase) || entry.Name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase) && !OnlyCopy(entry)) { run.Retire.Add(relative); continue; }
                    var target = new FileInfo(Path.Combine(root, relative));
                    var source = (FileInfo)entry;
                    if (target.Exists && target.Length == source.Length && target.LastWriteTimeUtc == source.LastWriteTimeUtc)
                    {
                        run.Retire.Add(relative);
                        run.Copied[relative] = (source.Length, source.LastWriteTimeUtc.ToFileTimeUtc());
                    }
                }
            }
        }
        catch (Exception error) when (Recoverable(error)) { }
        Retire(legacy, run, parent, name);
    }

    public static void RequireSecured(string root) => RequireSecured(root, ProtectedFolder.Rules);

    public static void RequireSecured(string root, ProtectedFolder kind, bool deep = true)
    {
        if (Problem(root, kind, deep) is { } problem) throw new UnauthorizedAccessException("The " + kind.Label + " is not protected (" + problem + "). Open the app as an administrator to repair it.");
    }

    public static string? Problem(string root, bool deep = true) => Problem(root, ProtectedFolder.Rules, deep);

    public static string? Problem(string root, ProtectedFolder kind, bool deep = true)
    {
        var directory = new DirectoryInfo(Normalize(root));
        if (!directory.Exists) return "missing";
        if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) return "the folder is a link";
        var security = directory.GetAccessControl();
        if (!security.AreAccessRulesProtected) return "the folder inherits permissions";
        if (!Trusted(security.GetOwner(typeof(SecurityIdentifier)))) return "the folder owner is not Administrators";
        if (Writers(security) is { } writer) return writer + " can change the folder";
        if (!Limited(security, OwnerRights)) return "the folder does not limit owner rights";
        foreach (var entry in Entries(directory, kind, deep))
        {
            try
            {
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) return entry.Name + " is a link";
                using var handle = NativeFiles.OpenEntry(entry.FullName, forDelete: false);
                if (NativeFiles.Info(handle).IsLink) return entry.Name + " is a link";
                FileSystemSecurity child = entry is DirectoryInfo ? new DirectorySecurity() : new FileSecurity();
                child.SetSecurityDescriptorBinaryForm(NativeFiles.SecurityDescriptor(handle) ?? throw new IOException("The permissions of " + entry.Name + " could not be read."));
                if (!Trusted(child.GetOwner(typeof(SecurityIdentifier))) && !Limited(child, OwnerRights)) return entry.Name + " has an untrusted owner";
                if (Writers(child) is { } childWriter) return childWriter + " can change " + entry.Name;
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch (UnauthorizedAccessException) when (!File.Exists(entry.FullName) && !Directory.Exists(entry.FullName)) { }
        }
        return null;
    }

    private static IEnumerable<FileSystemInfo> Entries(DirectoryInfo directory, ProtectedFolder kind, bool deep)
    {
        var top = directory.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false });
        if (!deep)
        {
            foreach (var entry in top.Where(entry => kind.ShallowNames.Contains(entry.Name, StringComparer.OrdinalIgnoreCase)))
            {
                yield return entry;
                if (entry is DirectoryInfo folder && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    foreach (var child in folder.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0 })) yield return child;
            }
            yield break;
        }
        var pending = new Stack<IEnumerable<FileSystemInfo>>();
        pending.Push(top);
        while (pending.Count > 0)
            foreach (var entry in pending.Pop())
            {
                yield return entry;
                if (entry is DirectoryInfo folder && !entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    pending.Push(folder.EnumerateFileSystemInfos("*", new EnumerationOptions { AttributesToSkip = 0, IgnoreInaccessible = false }));
            }
    }

    public static string Normalize(string path) => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);

    public static string CanonicalPath(string path) => Canonical(path);

    private static string Canonical(string path)
    {
        var existing = Normalize(path);
        var rest = "";
        while (!Directory.Exists(existing) && Path.GetDirectoryName(existing) is { } parent) { rest = Path.Combine(Path.GetFileName(existing), rest); existing = parent; }
        var buffer = new StringBuilder(1024);
        var length = GetLongPathName(existing, buffer, (uint)buffer.Capacity);
        var longPath = length == 0 || length >= buffer.Capacity ? existing : buffer.ToString();
        return Normalize(rest.Length == 0 ? longPath : Path.Combine(longPath, rest));
    }

    [DllImport("kernel32.dll", EntryPoint = "GetLongPathNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint length);

    public static string MarkerName(string root) => Canonical(root).ToUpperInvariant();

    public static bool Marked(string marker)
    {
        using var key = Registry.LocalMachine.OpenSubKey(MarkerKey);
        return key?.GetValue(marker) is not null;
    }

    private static void Mark(string marker, SecurityIdentifier user)
    {
        using var key = Registry.LocalMachine.CreateSubKey(MarkerKey, true);
        if (key.GetValue(marker + ProtectedAtSuffix) is null) key.SetValue(marker + ProtectedAtSuffix, DateTime.UtcNow.ToFileTimeUtc(), RegistryValueKind.QWord);
        if (key.GetValue(marker) is null) key.SetValue(marker, user.Value, RegistryValueKind.String);
    }

    public static void RepairMarker(string root)
    {
        var marker = MarkerName(root);
        using var key = Registry.LocalMachine.OpenSubKey(MarkerKey, true);
        if (key?.GetValue(marker) is not null && key.GetValue(marker + ProtectedAtSuffix) is null) key.SetValue(marker + ProtectedAtSuffix, DateTime.UtcNow.ToFileTimeUtc(), RegistryValueKind.QWord);
    }

    public const string ProtectedAtSuffix = "|protected-at";

    public static DateTime? ProtectedAt(string root)
    {
        using var key = Registry.LocalMachine.OpenSubKey(MarkerKey);
        return key?.GetValue(MarkerName(root) + ProtectedAtSuffix) is long time ? DateTime.FromFileTimeUtc(time) : null;
    }

    public static bool WrittenAfterProtection(string file)
    {
        var full = Normalize(file);
        DateTime? latest = null;
        for (var directory = Path.GetDirectoryName(full); directory is not null; directory = Path.GetDirectoryName(directory))
        {
            if (!Marked(MarkerName(directory))) continue;
            if (ProtectedAt(directory) is not { } at) return false;
            if (latest is null || at > latest) latest = at;
        }
        return latest is { } protectedAt && File.Exists(full) && File.GetCreationTimeUtc(full) > protectedAt;
    }

    public static bool SavedBeforeProtection(string file)
    {
        var full = Normalize(file);
        if (!File.Exists(full)) return false;
        for (var directory = Path.GetDirectoryName(full); directory is not null; directory = Path.GetDirectoryName(directory))
            if (Marked(MarkerName(directory))) return !WrittenAfterProtection(file);
        return false;
    }

    public static void RequireWrittenAfterProtection(string file, string message)
    {
        if (!WrittenAfterProtection(file)) throw new InvalidDataException(message);
    }

    public static void RequireConfirmedEarlierVersion(string file, bool confirmed)
    {
        if (!confirmed && SavedBeforeProtection(file)) throw new EarlierVersionException(EarlierVersion.Refusal);
    }

    private static string ProfilePath(SecurityIdentifier user)
    {
        using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + user.Value);
        return key?.GetValue("ProfileImagePath") is string path ? Environment.ExpandEnvironmentVariables(path) : throw new InvalidDataException("That Windows user has no profile on this PC.");
    }

    public static bool Elevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static bool SplitToken()
    {
#if GOVERNOR_TEST_HOOKS
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_SPLIT_TOKEN") is { Length: > 0 } forced) return forced == "1";
#endif
        if (!OpenProcessToken(GetCurrentProcess(), 0x8, out var token)) return false;
        try
        {
            var buffer = Marshal.AllocHGlobal(4);
            try { return GetTokenInformation(token, 18, buffer, 4, out _) && Marshal.ReadInt32(buffer) == 2; }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { CloseHandle(token); }
    }

    public static bool OwnedByAdministrators(string folder) => Trusted(new DirectoryInfo(Normalize(folder)).GetAccessControl().GetOwner(typeof(SecurityIdentifier)));

    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr information, int length, out int returned);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    private static void RequireElevated(ProtectedFolder kind)
    {
        if (!Elevated()) throw new UnauthorizedAccessException(kind.NotAdministrator);
    }

    private static void CreateSecured(string path, SecurityIdentifier user, ProtectedFolder kind)
    {
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(true, false);
        const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(LocalSystem, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(Administrators, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(OwnerRights, FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize, inherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).Create(security);
        if (Problem(path, kind) is { } problem) throw new UnauthorizedAccessException("The " + kind.Label + " could not be protected (" + problem + ").");
    }

    public static string? WriterOf(string directory) => Writers(new DirectoryInfo(Normalize(directory)).GetAccessControl());

    private static void PreserveProtection(DirectorySecurity source, string target)
    {
        if (!source.AreAccessRulesProtected || !Trusted(source.GetOwner(typeof(SecurityIdentifier))) || Writers(source) is not null || !Limited(source, OwnerRights)) return;
        var security = new DirectorySecurity();
        security.SetOwner(Administrators);
        security.SetAccessRuleProtection(true, false);
        foreach (FileSystemAccessRule rule in source.GetAccessRules(true, false, typeof(SecurityIdentifier))) security.AddAccessRule(rule);
        new DirectoryInfo(target).SetAccessControl(security);
    }

    private static void RequireMigratable(string root, ProtectedFolder kind)
    {
        var directory = new DirectoryInfo(root);
        foreach (var entry in new FileSystemInfo[] { directory }.Concat(directory.EnumerateFileSystemInfos("*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false })))
        {
            if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new UnauthorizedAccessException("The " + kind.Label + " contains a link (" + entry.FullName + "), so it is not trusted. Delete " + root + " and " + kind.Restart + ".");
            if (!Trusted((entry is DirectoryInfo folder ? (FileSystemSecurity)folder.GetAccessControl() : ((FileInfo)entry).GetAccessControl()).GetOwner(typeof(SecurityIdentifier))))
                throw new UnauthorizedAccessException("The " + kind.Label + " has files the app did not write with administrator rights (" + entry.FullName + "). Delete " + root + " and " + kind.Restart + ".");
        }
    }

    private static bool Trusted(IdentityReference? owner) => owner is SecurityIdentifier sid && (sid == Administrators || sid == LocalSystem);

    private static string? Writers(FileSystemSecurity security)
    {
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow || Trusted(rule.IdentityReference)) continue;
            if ((rule.FileSystemRights & WriteRights) != 0 || ((int)rule.FileSystemRights & (GenericAll | GenericWrite)) != 0) return rule.IdentityReference.Value;
        }
        return null;
    }

    private static bool Limited(FileSystemSecurity security, SecurityIdentifier sid)
    {
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
            if (rule.AccessControlType == AccessControlType.Allow && rule.IdentityReference == sid) return true;
        return false;
    }
}

public sealed class PolicyRootLease : IDisposable
{
    private readonly SafeFileHandle _handle;
    private readonly string _opened;
    private PolicyRootLease(SafeFileHandle handle) { _handle = handle; _opened = FinalPath(handle) ?? throw new IOException("The protected folder path could not be read."); }

    internal static SafeFileHandle OpenDirectory(string path)
    {
        var handle = CreateFile(PolicyRootSecurity.Normalize(path), 0x1 | 0x20000 | 0x100000, 0x1 | 0x2, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw new IOException("The protected folder could not be opened: " + new Win32Exception(error).Message);
    }

    public static PolicyRootLease Acquire(string root) => Acquire(root, ProtectedFolder.Rules, deep: true);

    public static PolicyRootLease Acquire(string root, ProtectedFolder kind, bool deep)
    {
        root = PolicyRootSecurity.Normalize(root);
        var handle = OpenDirectory(root);
        PolicyRootLease lease;
        try { lease = new PolicyRootLease(handle); }
        catch { handle.Dispose(); throw; }
        try
        {
            PolicyRootSecurity.RequireSecured(root, kind, deep);
            if (lease.Moved) throw new UnauthorizedAccessException("The " + kind.Label + " moved while it was checked.");
        }
        catch { lease.Dispose(); throw; }
        return lease;
    }

    public bool Moved => !string.Equals(FinalPath(_handle), _opened, StringComparison.OrdinalIgnoreCase);

    internal static string? FinalPath(SafeFileHandle handle) => NativeFiles.FinalPath(handle);

    public void Dispose() => _handle.Dispose();

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
