using System.Text;
using RooIndustries.Optimizer;

static class OperationFileChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-operation-file-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(root, "state.json");
        var original = new Snapshot(1, "original", Enumerable.Range(0, 128).ToArray());
        var replacement = new Snapshot(2, "replacement", Enumerable.Range(128, 128).ToArray());
        try
        {
            OperationFiles.Write(path, original);
            using (var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
            {
                OperationFiles.Write(path, replacement);
                var fresh = OperationFiles.Read<Snapshot>(path);
                check(fresh.Generation == 2 && fresh.Marker == "replacement" && fresh.Items.SequenceEqual(replacement.Items),
                    "Concurrent state replacement publishes the complete new generation");
                using var text = new StreamReader(reader, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, leaveOpen: true);
                var old = System.Text.Json.JsonSerializer.Deserialize<Snapshot>(text.ReadToEnd(), OperationFiles.Json)!;
                check(old.Generation == 1 && old.Marker == "original" && old.Items.SequenceEqual(original.Items),
                    "An existing shared reader retains the complete previous generation");
                check(!Directory.GetFiles(root, "*.tmp").Any(), "Atomic replacement leaves no temporary file behind");
            }
            OperationFiles.Write(path, original);
            check(OperationFiles.Read<Snapshot>(path).Generation == 1, "Subsequent writes remain reusable after the shared reader closes");
            using (var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                var rejected = false;
                try { OperationFiles.Write(path, replacement); }
                catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { rejected = true; }
                check(rejected, "A reader that forbids replacement produces a sharing violation");
                var preserved = OperationFiles.Read<Snapshot>(path);
                check(preserved.Generation == 1 && preserved.Marker == "original" && preserved.Items.SequenceEqual(original.Items),
                    "A rejected replacement preserves the complete original generation");
                check(!Directory.GetFiles(root, "*.tmp").Any(), "A rejected replacement removes its temporary file");
            }
            OperationFiles.Write(path, replacement);
            check(OperationFiles.Read<Snapshot>(path).Generation == 2, "A failed replacement can be retried after the reader closes");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        check(!Directory.Exists(root), "The operation-file fixture removes its directory");
    }
    private sealed record Snapshot(int Generation, string Marker, int[] Items);
}
