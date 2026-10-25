using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using RooIndustries.Optimizer;

string? root = null;
try
{
    RuntimeEnvironment.RequireClean();
    RuntimeEnvironment.Establish();
    if (args.Length != 2 || args[0] is not ("run" or "watch")) throw new ArgumentException("Provide run/watch and a request file.");
    using var requestLease = OperationsFolder.LeaseContaining(args[1]);
    var request = OperationFiles.Read<SessionRequest>(args[1]);
    if (request.SchemaVersion != 1 || !request.Confirm || !Path.IsPathFullyQualified(request.SessionRoot)) throw new InvalidDataException("Incomplete confirmed session request.");
    root = Path.GetFullPath(request.SessionRoot);
    using var protectedRoot = OperationsFolder.LeaseContaining(root);
    var catalog = OperationFiles.Read<JsonElement>(Path.Combine(request.RepoRoot, "backend", "profiles", "protected-processes.json"));
    var excluded = catalog.GetProperty("protectedProcesses").EnumerateArray().SelectMany(item => item.GetProperty("names").EnumerateArray())
        .Select(name => new Regex("^" + Regex.Escape(name.GetString()!).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))).ToArray();
    var engine = new ProtectedSessions(process => excluded.Any(pattern => pattern.IsMatch(Path.GetFileName(process.ExecutablePath))));
    if (args[0] == "watch") engine.Watch(root, request.OperationId ?? throw new InvalidDataException("Missing session identity."));
    else if (File.Exists(Path.Combine(root, "session.json")))
    {
        if (engine.Status(root) is { HostRunning: false, State: { } stale })
        {
            var recovered = engine.Recover(root, stale.Preview.OperationId);
            OperationFiles.Write(Path.Combine(root, "recovery-result.json"), recovered);
            if (!ProtectedSessions.IsRestored(recovered)) Environment.ExitCode = 1;
            else RemoveTask(root);
        }
    }
    else
    {
        var result = engine.Run(request.PreviewPath ?? throw new InvalidDataException("Missing preview."), request.ReviewHash ?? throw new InvalidDataException("Missing review hash."), root,
            (directory, operationId) =>
            {
                var path = Path.Combine(directory, "watch-request.json");
                OperationFiles.Write(path, request with { OperationId = operationId });
                var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
                RuntimeEnvironment.Apply(start);
                start.ArgumentList.Add("watch"); start.ArgumentList.Add(path);
                using var watcher = Process.Start(start) ?? throw new InvalidOperationException("The recovery watcher did not start.");
            }, CancellationToken.None);
        OperationFiles.Write(Path.Combine(root, "worker-result.json"), result);
        if (result.Status == "recoveryRequired") Environment.ExitCode = 1;
    }
}
catch (Exception error)
{
    if (root is not null) OperationFiles.Write(Path.Combine(root, args.FirstOrDefault() == "watch" ? "watch-error.json" : "worker-error.json"), new { error = error.Message, type = error.GetType().Name, hresult = $"0x{error.HResult:X8}", detail = error.ToString() });
    else Console.Error.WriteLine(error.Message);
    if (root is not null && args.FirstOrDefault() == "run" && !File.Exists(Path.Combine(root, "session.json"))) RemoveTask(root);
    Environment.ExitCode = 1;
}

static void RemoveTask(string root)
{
    var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe")) { UseShellExecute = false, CreateNoWindow = true };
    RuntimeEnvironment.Apply(start);
    foreach (var argument in new[] { "/Delete", "/TN", "Roo Industries Protected Session " + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root.ToLowerInvariant())))[..16], "/F" }) start.ArgumentList.Add(argument);
    using var schtasks = Process.Start(start);
    schtasks?.WaitForExit(30000);
}

sealed record SessionRequest
{
    public required int SchemaVersion { get; init; }
    public required string RepoRoot { get; init; }
    public required string SessionRoot { get; init; }
    public required bool Confirm { get; init; }
    public string? PreviewPath { get; init; }
    public string? ReviewHash { get; init; }
    public string? OperationId { get; init; }
}
