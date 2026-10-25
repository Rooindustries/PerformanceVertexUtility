using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record LaunchProfile(int SchemaVersion, string ProfileId, OperationOwner Owner, bool Enabled, string ReviewHash);
public sealed record LaunchProfileState(RunningProcess Launcher, string Status, string? SessionRoot, string? Message, int Attempts, DateTime UpdatedAtUtc);
public sealed record LaunchProfileEntry(string Root, LaunchProfile Profile, ProtectedSessionPreview Saved, LaunchProfileState? State)
{
    public string Title => Path.GetFileName(Saved.GamePath) + " via " + Path.GetFileName(Saved.Launcher.ExecutablePath);
}

public sealed partial class OptimizerService
{
    private const string ProfileMarker = "launch-profile.txt";
    private const int ProfileAttempts = 6;
    private static readonly TimeSpan ProfileRetry = TimeSpan.FromSeconds(10);
    private readonly SemaphoreSlim _profileGate = new(1, 1);
    private readonly Dictionary<string, string> _profileErrors = new(StringComparer.OrdinalIgnoreCase);
    public event Action? GameSessionsChanged;

    public void WatchGameSessions(CancellationToken stop) => _ = Task.Run(async () =>
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
        try
        {
            try { if (await RecoverStaleGameSessionsAsync().ConfigureAwait(false)) GameSessionsChanged?.Invoke(); }
            catch (Exception error) { AppLog.Write("games", "Game sessions couldn't be checked at startup: " + error.Message); }
            string? lastError = null;
            while (await timer.WaitForNextTickAsync(stop).ConfigureAwait(false))
                try { if (await RearmLaunchProfilesAsync().ConfigureAwait(false)) GameSessionsChanged?.Invoke(); lastError = null; }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    if (lastError != error.Message) AppLog.Write("profiles", "Saved launch settings couldn't be checked this time: " + error.Message);
                    lastError = error.Message;
                }
        }
        catch (OperationCanceledException) { }
    });

    public async Task<bool> RearmLaunchProfilesAsync()
    {
        var changed = false;
        foreach (var root in ProfileRoots())
        {
            try { changed |= await RearmAsync(root).ConfigureAwait(false); _profileErrors.Remove(root); }
            catch (Exception error)
            {
                if (_profileErrors.TryGetValue(root, out var last) && last == error.Message) continue;
                _profileErrors[root] = error.Message;
                AppLog.Write("profiles", "Saved launch settings in " + Path.GetFileName(root) + " were skipped: " + error.Message);
            }
        }
        return changed;
    }

    public Task<LaunchProfileEntry[]> ReadLaunchProfilesAsync() => Task.Run(() => ProfileRoots().Select(root =>
    {
        try { return ReadLaunchProfile(root); }
        catch (Exception) { return null; }
    }).OfType<LaunchProfileEntry>().ToArray());

    public void RequireNoLaunchProfile(ProtectedSessionPreview plan)
    {
        foreach (var root in ProfileRoots())
        {
            LaunchProfileEntry entry;
            try { entry = ReadLaunchProfile(root); }
            catch (Exception) { continue; }
            if (entry.Profile.Enabled && (string.Equals(entry.Saved.Launcher.ExecutablePath, plan.Launcher.ExecutablePath, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(Path.GetFileName(entry.Saved.GamePath), Path.GetFileName(plan.GamePath), StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("Saved launch settings already use " + entry.Title + ". Turn them off first.");
        }
    }

    public async Task<LaunchProfileEntry> SaveLaunchProfileAsync(GameSessionReview review)
    {
        var root = Path.Combine(await EnsureStorageAsync().ConfigureAwait(false), "launch-profile-" + review.Plan.OperationId);
        await _profileGate.WaitAsync().ConfigureAwait(false);
        try
        {
            RequireNoLaunchProfile(review.Plan);
            var bytes = await File.ReadAllBytesAsync(review.PreviewPath).ConfigureAwait(false);
            if (!string.Equals(OperationFiles.Hash(bytes), review.Hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed game settings changed. Preview them again.");
            Directory.CreateDirectory(root);
            await File.WriteAllBytesAsync(Path.Combine(root, "reviewed-preview.json"), bytes).ConfigureAwait(false);
            await File.WriteAllTextAsync(Path.Combine(Path.GetDirectoryName(review.SessionRoot)!, ProfileMarker), review.Plan.OperationId).ConfigureAwait(false);
            SaveProfileState(root, new(review.Plan.Launcher, "armed", review.SessionRoot, null, 0, DateTime.UtcNow));
            OperationFiles.Write(Path.Combine(root, "profile.json"), new LaunchProfile(1, review.Plan.OperationId, review.Plan.Owner, true, review.Hash));
            return ReadLaunchProfile(root);
        }
        finally { _profileGate.Release(); }
    }

    public async Task<string?> DisableLaunchProfileAsync(string root)
    {
        await _profileGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var entry = ReadLaunchProfile(root);
            OperationFiles.Write(Path.Combine(root, "profile.json"), entry.Profile with { Enabled = false });
            var problems = new List<string>();
            foreach (var session in (await ReadGameSessionsAsync().ConfigureAwait(false)).Where(session => session.ProfileId == entry.Profile.ProfileId && !GameSessionDisplay.Restored(session.Worker)))
            {
                try
                {
                    var result = session.Worker.HostRunning == true ? await StopGameSessionAsync(session.SessionRoot).ConfigureAwait(false) : await RecoverGameSessionAsync(session.SessionRoot).ConfigureAwait(false);
                    if (!GameSessionDisplay.Restored(result)) problems.Add(GameSessionDisplay.Title(result) + ": " + session);
                }
                catch (Exception error) { problems.Add(error.Message); }
            }
            if (problems.Count != 0) return string.Join("\n", problems);
            Directory.Delete(root, true);
            return null;
        }
        finally { _profileGate.Release(); }
    }

    public static string DescribeLaunchProfile(LaunchProfileEntry entry)
    {
        var launcher = Path.GetFileName(entry.Saved.Launcher.ExecutablePath);
        var state = entry.State;
        if (!entry.Profile.Enabled) return "Turned off, but a session still needs restoring. Pick it under Previous sessions and select Recover settings.";
        if (state is null) return "Waiting for " + launcher + " to open.";
        var running = Running(state.Launcher);
        return state.Status switch
        {
            "armed" when running && Live(state.SessionRoot) => "Ready. Start the game from " + launcher + " as usual.",
            "armed" when running => "Stopped until " + launcher + " opens again.",
            "retrying" when running => "Not on yet. Trying again: " + state.Message,
            "changed" when running => "Not turned on this time. " + state.Message + " Turn these off and set the game up again.",
            "failed" when running => "Not turned on this time. " + state.Message,
            "changed" or "failed" => "Waiting for " + launcher + " to open. Last time they didn't turn on: " + state.Message,
            _ => "Waiting for " + launcher + " to open.",
        };
    }

    public LaunchProfileEntry ReadLaunchProfile(string root)
    {
        root = Path.GetFullPath(root);
        if (!Path.GetFileName(root).StartsWith("launch-profile-", StringComparison.Ordinal) ||
            !string.Equals(Path.GetDirectoryName(root), Path.GetFullPath(_storage).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("These saved launch settings are outside this app's recovery folder.");
        var profile = OperationFiles.Read<LaunchProfile>(Path.Combine(root, "profile.json"));
        profile.Owner.Verify();
        if (profile.SchemaVersion != 1 || !Guid.TryParseExact(profile.ProfileId, "N", out _) || Path.GetFileName(root) != "launch-profile-" + profile.ProfileId)
            throw new InvalidDataException("These saved launch settings are damaged.");
        var saved = OperationFiles.Read<ProtectedSessionPreview>(Path.Combine(root, "reviewed-preview.json"), profile.ReviewHash);
        var state = Path.Combine(root, "state.json");
        return new(root, profile, saved, File.Exists(state) ? OperationFiles.Read<LaunchProfileState>(state) : null);
    }

    private string[] ProfileRoots() => Directory.Exists(_storage) ? Directory.GetDirectories(_storage, "launch-profile-*") : [];

    private async Task<bool> RearmAsync(string root)
    {
        var entry = ReadLaunchProfile(root);
        if (!entry.Profile.Enabled || (entry.State is { } current && Running(current.Launcher) ? current.Launcher : FindLauncher(entry.Saved)) is not { } launcher || !Due(entry.State, launcher)) return false;
        await _profileGate.WaitAsync().ConfigureAwait(false);
        try
        {
            entry = ReadLaunchProfile(root);
            if (!entry.Profile.Enabled || !Due(entry.State, launcher)) return false;
            var attempts = entry.State?.Launcher == launcher ? entry.State.Attempts + 1 : 1;
            try { SaveProfileState(root, await ArmProfileAsync(entry, launcher).ConfigureAwait(false)); }
            catch (Exception error) { SaveProfileState(root, new(launcher, attempts < ProfileAttempts ? "retrying" : "failed", null, error.Message, attempts, DateTime.UtcNow)); }
            return true;
        }
        finally { _profileGate.Release(); }
    }

    private static bool Due(LaunchProfileState? state, RunningProcess launcher)
        => state?.Launcher != launcher || state.Status == "retrying" && DateTime.UtcNow - state.UpdatedAtUtc >= ProfileRetry;

    private async Task<LaunchProfileState> ArmProfileAsync(LaunchProfileEntry entry, RunningProcess launcher)
    {
        var id = entry.Profile.ProfileId;
        foreach (var stale in (await ReadGameSessionsAsync().ConfigureAwait(false)).Where(session => session.ProfileId == id && !GameSessionDisplay.Restored(session.Worker) &&
            (session.Worker.HostRunning == false || session.Worker is { HostRunning: true, State: null })))
            if (!GameSessionDisplay.Restored(await (stale.Worker.HostRunning == true ? StopGameSessionAsync(stale.SessionRoot) : RecoverGameSessionAsync(stale.SessionRoot)).ConfigureAwait(false)))
                return Ended("failed", "A saved session couldn't be restored. Pick it under Previous sessions and select Recover settings.");
        var sessions = await ReadGameSessionsAsync().ConfigureAwait(false);
        if (sessions.FirstOrDefault(session => !GameSessionDisplay.Restored(session.Worker)) is { } outstanding)
        {
            if (outstanding.ProfileId == id && outstanding.Worker.HostRunning == true && outstanding.Worker.State?.Preview.Launcher == launcher)
                return new(launcher, "armed", outstanding.SessionRoot, null, 0, DateTime.UtcNow);
            throw new InvalidOperationException(outstanding.Worker.HostRunning == true ? "Another game session is still running. Stop it and these settings can turn on."
                : "Another game session needs restoring first. Pick it under Previous sessions.");
        }
        var review = await PreviewGameSessionAsync(launcher.ProcessId, entry.Saved.GamePath, entry.Saved.Controls, true).ConfigureAwait(false);
        var mismatch = review.Plan.Launcher == launcher ? ProtectedSessions.ProfileMismatch(entry.Saved, review.Plan) : ProtectedSessions.LauncherClosed;
        if (mismatch is not null)
        {
            Directory.Delete(Path.GetDirectoryName(review.PreviewPath)!, true);
            if (review.Plan.Launcher != launcher) throw new InvalidOperationException(mismatch);
            return Ended("changed", mismatch);
        }
        await File.WriteAllTextAsync(Path.Combine(Path.GetDirectoryName(review.SessionRoot)!, ProfileMarker), id).ConfigureAwait(false);
        await StartGameSessionAsync(review).ConfigureAwait(false);
        foreach (var old in sessions.Where(session => session.ProfileId == id && GameSessionDisplay.Restored(session.Worker)).Skip(2))
            try { await RecoverGameSessionAsync(old.SessionRoot).ConfigureAwait(false); Directory.Delete(Path.GetDirectoryName(old.SessionRoot)!, true); }
            catch (Exception error) { AppLog.Write("profiles", "Couldn't remove an old restored session: " + error.Message); }
        return new(launcher, "armed", review.SessionRoot, null, 0, DateTime.UtcNow);

        LaunchProfileState Ended(string status, string message) => new(launcher, status, null, message, ProfileAttempts, DateTime.UtcNow);
    }

    private static RunningProcess? FindLauncher(ProtectedSessionPreview saved)
    {
        RunningProcess? found = null;
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(saved.Launcher.ExecutablePath)))
        {
            using (process)
            {
                try
                {
                    using var target = new ProcessTarget(process.Id);
                    var identity = target.Identity();
                    if (!string.Equals(identity.ExecutablePath, saved.Launcher.ExecutablePath, StringComparison.OrdinalIgnoreCase) || target.UserSid() != saved.Owner.UserSid) continue;
                    if (found is null || long.Parse(identity.CreationTimeFileTimeUtc) < long.Parse(found.CreationTimeFileTimeUtc)) found = identity;
                }
                catch (Exception) { }
            }
        }
        return found;
    }

    private static bool Live(string? sessionRoot)
    {
        try { return sessionRoot is not null && new ProtectedSessions(_ => false).Status(sessionRoot).HostRunning == true; }
        catch (Exception) { return false; }
    }

    private static bool Running(RunningProcess identity)
    {
        try { using var target = new ProcessTarget(identity.ProcessId); return target.Identity() == identity; }
        catch (Exception) { return false; }
    }

    private static string? ProfileOf(string sessionRoot)
    {
        var marker = Path.Combine(Path.GetDirectoryName(sessionRoot)!, ProfileMarker);
        try { return File.Exists(marker) && File.ReadAllText(marker).Trim() is var id && Guid.TryParseExact(id, "N", out _) ? id : null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    private static void SaveProfileState(string root, LaunchProfileState state) => OperationFiles.Write(Path.Combine(root, "state.json"), state);
}
