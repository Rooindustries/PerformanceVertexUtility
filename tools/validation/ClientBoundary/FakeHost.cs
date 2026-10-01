using System.Diagnostics;
using System.Text.Json;
using RooIndustries.Optimizer;

static class FakeHost
{
    public static void Run(string action)
    {
        var state = Environment.GetEnvironmentVariable("ROOTEST_BOUNDS_DIR") ?? throw new InvalidOperationException("The bounds fixture folder is missing.");
        var request = Console.In.ReadToEnd();
        File.AppendAllText(Path.Combine(state, "host-calls.log"), Environment.ProcessId + " " + action + "\n");
        if (File.Exists(Path.Combine(state, "host-hang")))
        {
            var ping = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "PING.EXE"), "-n 400 127.0.0.1") { UseShellExecute = false, CreateNoWindow = true };
            using var child = Process.Start(ping)!;
            File.WriteAllText(Path.Combine(state, "host-pids.txt"), Environment.ProcessId + " " + child.Id);
            Thread.Sleep(Timeout.Infinite);
        }
        if (File.Exists(Path.Combine(state, "host-slow"))) Thread.Sleep(int.Parse(File.ReadAllText(Path.Combine(state, "host-slow"))));
        string data;
        switch (action)
        {
            case "policy-run":
                data = JsonSerializer.Serialize(new PolicyHostState { SchemaVersion = 1, Owner = OperationOwner.Current(), Status = "stopped", Host = null, Instances = [], Errors = [], UpdatedAtUtc = DateTime.UtcNow }, OperationFiles.Json);
                break;
            case "tweak-preview":
                using (var document = JsonDocument.Parse(request)) File.Copy(Path.Combine(state, "plan.json"), document.RootElement.GetProperty("outputPath").GetString()!);
                data = File.ReadAllText(Path.Combine(state, "plan.json"));
                break;
            case "tweak-apply" or "tweak-restore":
                data = File.ReadAllText(Path.Combine(state, "apply-result.json"));
                break;
            default:
                data = "{}";
                break;
        }
        Console.WriteLine("{\"schemaVersion\":1,\"status\":\"completed\",\"data\":" + data + "}");
    }
}
