using System.Text.Json;
using RooIndustries.Optimizer;

static class ReplaceFaultChecks
{
    private sealed record Snapshot(int Generation, string Marker);

    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-replace-fault-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "host.json");
        try
        {
            OperationFiles.Write(path, new Snapshot(1, "original"));
            Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_REPLACE_FAULT", "1177");
            Exception? failure = null;
            try { OperationFiles.Write(path, new Snapshot(2, "replacement")); }
            catch (Exception error) { failure = error; }
            finally { Environment.SetEnvironmentVariable("ROO_INDUSTRIES_TEST_REPLACE_FAULT", null); }
            check(failure is null && File.Exists(path) && OperationFiles.Read<Snapshot>(path).Generation == 2, "A replace that fails after it removed the old file still publishes the new generation: " + failure?.Message);
            check(!Directory.GetFiles(root, "*.tmp").Any(), "That replace leaves no temporary file behind");
            File.Delete(path);
            var orphan = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(orphan, JsonSerializer.Serialize(new Snapshot(3, "orphan"), OperationFiles.Json));
            File.SetLastWriteTimeUtc(orphan, DateTime.UtcNow.AddSeconds(-30));
            Snapshot? recovered = null; Exception? lost = null;
            try { recovered = OperationFiles.Read<Snapshot>(path); } catch (Exception error) { lost = error; }
            check(recovered?.Generation == 3 && File.Exists(path) && !File.Exists(orphan), "A complete new generation left under its temporary name while the file is missing is recovered by the next read: " + lost?.Message);
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The replace fault fixture removes its directory");
    }
}
