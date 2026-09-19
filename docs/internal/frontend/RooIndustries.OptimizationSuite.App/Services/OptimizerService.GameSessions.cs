using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record GameSessionReview(ProtectedSessionPreview Plan, string PreviewPath, string Hash, string SessionRoot);
public sealed record GameSessionOperation(string SessionRoot, string TaskName, ProtectedSessionStatus Worker);
public sealed record GameSessionEntry(string SessionRoot, ProtectedSessionStatus Worker)
{
    public override string ToString() => Worker.State is { } state
        ? Path.GetFileNameWithoutExtension(state.Preview.GamePath) + " · " + state.UpdatedAtUtc.ToLocalTime().ToString("g")
        : Path.GetFileName(Path.GetDirectoryName(SessionRoot)) + " · state unavailable";
}

public sealed partial class OptimizerService
{
    public async Task<GameSessionReview> PreviewGameSessionAsync(int launcherId, string gamePath, Dictionary<string, JsonElement> controls, bool acceptLauncherScope)
    {
        var directory = NewOperationDirectory("game-session");
        var path = Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<ProtectedSessionPreview>("protected-session-preview", new()
        {
            ["processId"] = launcherId, ["gamePath"] = gamePath, ["controls"] = controls,
            ["acceptLauncherScope"] = acceptLauncherScope, ["outputPath"] = path,
        });
        return new(plan, path, Hash(path), Path.Combine(directory, "session"));
    }

    public async Task<ProtectedSessionStatus> StartGameSessionAsync(GameSessionReview review)
    {
        ValidateGameSessionRoot(review.SessionRoot);
        if (!string.Equals(Hash(review.PreviewPath), review.Hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed game settings changed. Preview them again.");
        var status = await GameSessionActionAsync("Start", review.SessionRoot, " -PreviewPath " + Quote(review.PreviewPath) + " -ReviewHash " + Quote(review.Hash));
        if (status.State?.Preview.OperationId != review.Plan.OperationId || status.HostRunning != true)
            throw new InvalidDataException("The backend did not start the reviewed game session. Inspect its recovery state before retrying.");
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
        var entries = new List<GameSessionEntry>();
        foreach (var directory in Directory.EnumerateDirectories(_storage, "game-session-*").OrderByDescending(Directory.GetLastWriteTimeUtc))
        {
            var root = Path.Combine(directory, "session");
            if (!Directory.Exists(root)) continue;
            try { entries.Add(new(root, await ReadGameSessionAsync(root))); }
            catch (Exception error) { entries.Add(new(root, new(null, null, error.Message))); }
        }
        return entries.ToArray();
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
        var result = await RunAsync<GameSessionOperation>("Invoke-ProtectedGameSession.ps1",
            "-Action " + action + " -SessionRoot " + Quote(sessionRoot) + arguments + " -ConfirmApply", waitForRemoval: true);
        var operation = RequireData(result);
        if (result.Status != "completed" || operation.Worker is null || string.IsNullOrWhiteSpace(operation.SessionRoot) ||
            !string.Equals(Path.GetFullPath(operation.SessionRoot), Path.GetFullPath(sessionRoot), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The backend returned a different or incomplete game session.");
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
