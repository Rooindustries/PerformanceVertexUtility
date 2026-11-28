using System.Diagnostics;
using RooIndustries.Optimizer;

static class KilledWriterChecks
{
    private sealed record Generation(int Number, int Check);

    public static void Child(string path)
    {
        for (var number = 1; ; number++)
        {
            OperationFiles.Write(path, new Generation(number, number));
            if (number == 1) Console.WriteLine("ready");
        }
    }

    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-killed-writer-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "state.json");
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("No writer executable.");
        var random = new Random();
        int kills = 0, unreadable = 0, samples = 0, absent = 0;
        var failure = "";
        try
        {
            Directory.CreateDirectory(root);
            OperationFiles.Write(path, new Generation(0, 0));
            var stop = DateTime.UtcNow.AddSeconds(3);
            var writer = Task.Run(() =>
            {
                for (var number = 1; DateTime.UtcNow < stop; number++) OperationFiles.Write(path, new Generation(number, number));
            });
            while (!writer.IsCompleted) { samples++; if (!File.Exists(path)) absent++; }
            writer.Wait();
            for (var attempt = 0; attempt < 100; attempt++)
            {
                var start = new ProcessStartInfo(executable) { RedirectStandardOutput = true, UseShellExecute = false };
                start.ArgumentList.Add("--killed-writer-child");
                start.ArgumentList.Add(path);
                using var child = Process.Start(start) ?? throw new InvalidOperationException("No writer started.");
                try
                {
                    if (child.StandardOutput.ReadLine() != "ready") throw new InvalidOperationException("The writer never started.");
                    Thread.Sleep(random.Next(1, 60));
                }
                finally { child.Kill(); child.WaitForExit(); }
                kills++;
                try
                {
                    var saved = OperationFiles.Read<Generation>(path);
                    if (saved.Check != saved.Number) throw new InvalidDataException("The saved generation is mixed.");
                }
                catch (Exception error) { unreadable++; failure = error.GetType().Name + ": " + error.Message; }
            }
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine($"Killed writer: samples={samples} absent={absent} kills={kills} unreadable={unreadable} {failure}");
        check(samples > 1000 && absent == 0, "A file being replaced is never missing, even for an instant");
        check(kills == 100 && unreadable == 0, "A writer killed at any point of a replace leaves a whole readable generation");
    }
}
