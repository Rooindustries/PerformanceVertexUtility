#nullable enable
using System.Diagnostics;

namespace RooIndustries.Optimizer;

public sealed record RestartCommand(string FileName, string[] Arguments, bool Optional);

public static class SystemRestart
{
    public static RestartCommand[] Commands(string systemDirectory) =>
    [
        new(Path.Combine(systemDirectory, "bcdedit.exe"), ["/set", "{fwbootmgr}", "bootsequence", "{bootmgr}"], true),
        new(Path.Combine(systemDirectory, "shutdown.exe"), ["/r", "/t", "0"], false)
    ];

    public static void Restart(Action<RestartCommand, Exception>? skipped = null) => Restart(Environment.GetFolderPath(Environment.SpecialFolder.System), Run, skipped);

    public static void Restart(string systemDirectory, Action<RestartCommand> run, Action<RestartCommand, Exception>? skipped = null)
    {
        foreach (var command in Commands(systemDirectory))
        {
            try { run(command); }
            catch (Exception error) when (command.Optional) { skipped?.Invoke(command, error); }
        }
    }

    public static void Run(RestartCommand command)
    {
        var start = new ProcessStartInfo(command.FileName) { UseShellExecute = false, CreateNoWindow = true };
        RuntimeEnvironment.Apply(start);
        foreach (var argument in command.Arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException(Path.GetFileName(command.FileName) + " could not start.");
        if (!process.WaitForExit(15000))
        {
            try { process.Kill(); } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            throw new TimeoutException(Path.GetFileName(command.FileName) + " did not finish.");
        }
        if (process.ExitCode != 0) throw new InvalidOperationException(Path.GetFileName(command.FileName) + " returned " + process.ExitCode + ".");
    }
}
