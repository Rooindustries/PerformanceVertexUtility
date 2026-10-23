using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record UpdateState(string Status, string Notes = "", bool Busy = false, bool Ready = false, bool CanDownload = false,
    string Banner = "", string BannerKind = "", bool Installing = false, bool Refused = false)
{
    public string BannerMessage => Refused ? Status : Notes;
    public bool Waiting => Refused && Status == InstallGate.ChangeRunning;
    public bool CanInstall => Ready && !Busy && !Waiting;
}

public sealed class InstallGate(Func<Task<GameSessionEntry[]>> sessions, Func<Task<LiveDataResult<string>>> gameTune, Func<bool> timer, Func<(string Drive, long Free)> space)
{
    public const string Blocked = "Stop your game session and turn off the timer setting first. The update can't install while they run.";
    public const string ChangeRunning = "A change is still running. You can install the update once it finishes.";

    public async Task<string?> ReasonAsync()
    {
        if (RunningChanges.Any) return ChangeRunning;
        var (drive, free) = space();
        if (UpdateFeed.InstallDriveSpaceReason(drive, free) is { } spaceReason) return spaceReason;
        try { return await ActiveSettingsAsync() ? Blocked : null; }
        catch (Exception error) { return "Couldn't install the update. " + error.Message; }
    }

    private async Task<bool> ActiveSettingsAsync()
    {
        var entries = await sessions();
        if (entries.Any(entry => entry.Worker.HostRunning == true)) return true;
        if (entries.Any(entry => entry.Worker.HostRunning is null || entry.Worker.Error is not null))
            throw new InvalidDataException("Couldn't confirm that all game sessions have stopped. Check Games and Undo changes first.");
        var game = await gameTune();
        if (game.Error is not null || game.Value is null) throw new InvalidDataException("Couldn't read the game priority session. Check Games first.");
        using var data = JsonDocument.Parse(game.Value);
        if (data.RootElement.GetProperty("active").GetBoolean()) return true;
        try { return await Task.Run(timer); }
        catch (Exception error)
        {
            AppLog.Write("update", "Couldn't read the timer setting; treating it as stopped: " + error.Message);
            return false;
        }
    }

    public static bool TimerOn() => TimerControl.Read(new ControlAddress("timer", "system", "half-millisecond")).Value.GetBoolean();
}
