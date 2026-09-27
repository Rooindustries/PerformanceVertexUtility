using RooIndustries.Optimizer;

static class ReplaceRaceChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-replace-race-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "state.json");
        try
        {
            Directory.CreateDirectory(root);
            OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = 0 });
            var stop = DateTime.UtcNow.AddSeconds(3);
            var writes = 0; var writeFailures = 0; var reads = 0; var readFailures = 0; var failure = "";
            var reader = Task.Run(() =>
            {
                while (DateTime.UtcNow < stop)
                {
                    try { OperationFiles.Read<Dictionary<string, int>>(path); OperationFiles.HashFile(path); reads++; }
                    catch (IOException) { readFailures++; }
                }
            });
            var writer = Task.Run(() =>
            {
                var value = 0;
                while (DateTime.UtcNow < stop)
                {
                    try { OperationFiles.Write(path, new Dictionary<string, int> { ["value"] = ++value }); writes++; }
                    catch (Exception error) { writeFailures++; failure = error.GetType().Name + ": " + error.Message; }
                }
            });
            Task.WaitAll(reader, writer);
            Console.WriteLine($"Replace race: writes={writes} writeFailures={writeFailures} reads={reads} readFailures={readFailures} {failure}");
            check(writes > 100 && reads > 100 && writeFailures == 0, "A C# reader never makes a concurrent atomic replace fail");
        }
        finally { Directory.Delete(root, true); }
    }
}
