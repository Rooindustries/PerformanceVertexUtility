using System;
using System.Linq;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Models;

public static class GameSessionDisplay
{
    public static bool Restored(ProtectedSessionStatus status) => status.HostRunning == false && status.Error is null && status.State is { } state &&
        state.Status is "stopped" or "stoppedWithErrors" && state.RegistryStatus == "restored" && state.JobStatus == "cleared" &&
        state.Games.All(game => game.Fields.All(field => field.JournalPath is null || field.Status is "restored" or "expired"));

    public static bool CoresMatch(ProtectedSessionStatus status, string mask)
    {
        if (status.HostRunning != true || status.Error is not null || status.State is not { } state || DateTime.UtcNow - state.UpdatedAtUtc > TimeSpan.FromSeconds(15)) return false;
        var desired = System.Text.Json.JsonSerializer.SerializeToElement(new AffinityState(state.Preview.OriginalAffinity.Group, mask), OperationFiles.Json);
        var games = state.Games.Where(game => !game.Exited).ToArray();
        return ProcessTarget.ParseMask(state.DesiredAffinity.Mask) == ProcessTarget.ParseMask(mask) && games.Length > 0 && games.All(game =>
        {
            var fields = game.Fields.Where(field => field.Name == "affinity").ToArray();
            return fields.Length == 1 && fields[0].Status == "applied" && fields[0].Observed is { Known: true, Error: null, Value: not null } read &&
                ProcessTarget.Equivalent("affinity", read.Require(), desired);
        });
    }

    public static string Title(ProtectedSessionStatus status, string? pendingAffinity = null)
    {
        var state = status.State;
        if (state is null) return "Session state unavailable";
        if (status.HostRunning is null || status.Error is not null) return "Session needs attention";
        if (Restored(status)) return state.Games.Any(game => !game.Exited && game.Fields.Any(field => field.Status == "restartRequired"))
            ? "Stopped · restart the game to clear launch priorities" : "Stopped · original settings restored";
        if (status.HostRunning != true) return "Recovery required";
        if (DateTime.UtcNow - state.UpdatedAtUtc > TimeSpan.FromSeconds(15) || state.Preview.Controls.Count == 0 || state.Errors.Count != 0 ||
            state.RegistryStatus != "applied" || state.JobStatus != "applied") return "Session needs attention";
        var games = state.Games.Where(game => !game.Exited).ToArray();
        if (pendingAffinity is not null && !CoresMatch(status, pendingAffinity))
            return games.Length == 0 ? "Core selection pending · launch the game normally" : "Core switch pending · waiting for readback";
        if (games.Length == 0) return state.Status == "armed" ? "Ready · launch the game normally" : "Preparing the session";
        var applied = state.Preview.Controls.All(control => games.All(game =>
        {
            var fields = game.Fields.Where(field => field.Name == control.Key).ToArray();
            if (fields.Length != 1 || fields[0].Status != "applied" || fields[0].Observed is not { Known: true, Error: null, Value: not null } observed) return false;
            var desired = control.Key == "affinity" ? System.Text.Json.JsonSerializer.SerializeToElement(state.DesiredAffinity, OperationFiles.Json) : control.Value;
            return ProcessTarget.Equivalent(control.Key, observed.Require(), desired);
        }));
        return state.Status == "active" && applied ? "Active · requested controls verified" : "Partially applied · check each control";
    }
}
