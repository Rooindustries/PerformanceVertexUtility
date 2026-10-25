using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record GameSessionReview(ProtectedSessionPreview Plan, string PreviewPath, string Hash, string SessionRoot);
public sealed record GameSessionOperation(string SessionRoot, string TaskName, ProtectedSessionStatus Worker);
public sealed record GameSessionEntry(string SessionRoot, ProtectedSessionStatus Worker, string? ProfileId = null)
{
    public override string ToString() => (Worker.State is { } state
        ? Path.GetFileNameWithoutExtension(state.Preview.GamePath) + " · " + state.UpdatedAtUtc.ToLocalTime().ToString("g")
        : Path.GetFileName(Path.GetDirectoryName(SessionRoot)) + (Worker.HostRunning == true ? " · preparing" : GameSessionDisplay.Restored(Worker) ? " · didn't start" : " · state unavailable"))
        + (ProfileId is null ? "" : " · saved settings");
}

public sealed partial class OptimizerService
{
    public async Task<GameSessionReview> PreviewGameSessionAsync(int launcherId, string gamePath, Dictionary<string, JsonElement> controls, bool acceptLauncherScope)
    {
        var directory = await NewOperationDirectoryAsync("game-session");
        var path = Path.Combine(directory, "preview.json");
        try
        {
            var plan = await RunCoreAsync<ProtectedSessionPreview>("protected-session-preview", new()
            {
                ["processId"] = launcherId, ["gamePath"] = gamePath, ["controls"] = controls,
                ["acceptLauncherScope"] = acceptLauncherScope, ["outputPath"] = path,
            });
            return new(plan, path, Hash(path), Path.Combine(directory, "session"));
        }
        catch { Directory.Delete(directory, true); throw; }
    }

    public async Task<ProtectedSessionStatus> StartGameSessionAsync(GameSessionReview review)
    {
        ValidateGameSessionRoot(review.SessionRoot);
        if (!string.Equals(Hash(review.PreviewPath), review.Hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed game settings changed. Preview them again.");
        ProtectedSessionStatus status;
        try { status = await GameSessionActionAsync("Start", review.SessionRoot, " -PreviewPath " + Quote(review.PreviewPath) + " -ReviewHash " + Quote(review.Hash)); }
        catch when (!Directory.Exists(review.SessionRoot))
        {
            try { Directory.Delete(Path.GetDirectoryName(review.SessionRoot)!, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { AppLog.Write("games", "A review that didn't start couldn't be removed: " + error.Message); }
            throw;
        }
        if (status.State?.Preview.OperationId != review.Plan.OperationId || status.HostRunning != true)
            throw new InvalidDataException("The game session did not start. Check Undo changes before trying again.");
        return status;
    }

    public Task<ProtectedSessionStatus> ReadGameSessionAsync(string sessionRoot)
    {
        ValidateGameSessionRoot(sessionRoot);
        return RunCoreAsync<ProtectedSessionStatus>("protected-session-status", new() { ["sessionRoot"] = sessionRoot });
    }

    public async Task<GameSessionEntry[]> ReadGameSessionsAsync()
    {
        if (!Directory.Exists(_storage)) return [];
        var roots = Directory.EnumerateDirectories(_storage, "game-session-*").OrderByDescending(Directory.GetLastWriteTimeUtc)
            .Select(directory => Path.Combine(directory, "session")).Where(Directory.Exists).ToArray();
        using var slots = new SemaphoreSlim(4);
        return await Task.WhenAll(roots.Select(async root =>
        {
            await slots.WaitAsync().ConfigureAwait(false);
            try { return new GameSessionEntry(root, await ReadGameSessionAsync(root).ConfigureAwait(false), ProfileOf(root)); }
            catch (Exception error) { return new GameSessionEntry(root, new(null, null, error.Message), ProfileOf(root)); }
            finally { slots.Release(); }
        }));
    }

    public async Task<bool> RecoverStaleGameSessionsAsync()
    {
        var stale = await Task.Run(() => Directory.Exists(_storage) ? Directory.EnumerateDirectories(_storage, "game-session-*").Select(directory => Path.Combine(directory, "session")).Where(root =>
        {
            try { return File.Exists(Path.Combine(root, "session.json")) && new ProtectedSessions(_ => false).Status(root) is { HostRunning: false, State: not null } status && !GameSessionDisplay.Restored(status) && !PolicyRootSecurity.SavedBeforeProtection(Path.Combine(root, "session.json")); }
            catch (Exception) { return false; }
        }).ToArray() : []).ConfigureAwait(false);
        foreach (var root in stale)
            try { await RecoverGameSessionAsync(root).ConfigureAwait(false); }
            catch (Exception error) { AppLog.Write("games", "A game session that stopped unexpectedly couldn't be restored automatically: " + error.Message); }
        return stale.Length != 0;
    }

    public async Task<GameSessionEntry[]> RecoverAndReadGameSessionsAsync()
    {
        await RecoverStaleGameSessionsAsync().ConfigureAwait(false);
        return await ReadGameSessionsAsync().ConfigureAwait(false);
    }

    public Task<ProtectedSessionStatus> StopGameSessionAsync(string sessionRoot)
        => GameSessionActionAsync("Stop", sessionRoot);

    public Task<ProtectedSessionStatus> RecoverGameSessionAsync(string sessionRoot)
        => GameSessionActionAsync("Recover", sessionRoot);

    public Task<ProtectedSessionStatus> SwitchGameCoresAsync(string sessionRoot, string affinityMask)
        => GameSessionActionAsync("Affinity", sessionRoot, " -AffinityMask " + Quote(affinityMask));

    private async Task<ProtectedSessionStatus> GameSessionActionAsync(string action, string sessionRoot, string arguments = "")
    {
        ValidateGameSessionRoot(sessionRoot);
        if (action is "Stop" or "Recover" && await EarlierVersionConsent.RequireAsync(Path.Combine(sessionRoot, "session.json"))) arguments += " -AcceptEarlierVersion";
        var result = await RunAsync<GameSessionOperation>("Invoke-ProtectedGameSession.ps1",
            "-Action " + action + " -SessionRoot " + Quote(sessionRoot) + arguments + " -ConfirmApply", waitForRemoval: true);
        var operation = RequireData(result);
        if (result.Status != "completed" || operation.Worker is null || string.IsNullOrWhiteSpace(operation.SessionRoot) ||
            !string.Equals(Path.GetFullPath(operation.SessionRoot), Path.GetFullPath(sessionRoot), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The game session could not be confirmed. Check Undo changes before trying again.");
        return operation.Worker;
    }

    private void ValidateGameSessionRoot(string sessionRoot)
    {
        var full = Path.GetFullPath(sessionRoot);
        var directory = Path.GetDirectoryName(full);
        if (!string.Equals(Path.GetFileName(full), "session", StringComparison.Ordinal) || directory is null ||
            !Path.GetFileName(directory).StartsWith("game-session-", StringComparison.Ordinal) ||
            !string.Equals(Path.GetDirectoryName(directory), Path.GetFullPath(_storage).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The game session is outside this app's recovery folder.");
    }
}
