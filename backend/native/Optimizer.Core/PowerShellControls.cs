#nullable enable
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

static class PowerShellControls
{
    public static TweakControlRead Read(ControlAddress address) => Invoke(new { action = "read", address }).Deserialize<TweakControlRead>(OperationFiles.Json)
        ?? throw new InvalidDataException("Windows control response was empty.");
    public static void Write(TweakControlRead before, JsonElement after) => Invoke(new { action = "write", address = before.Address, before, after });
    internal static JsonElement Invoke(object request)
    {
        var assembly = typeof(PowerShellControls).Assembly;
        using var resource = assembly.GetManifestResourceStream("Optimizer.Core.WindowsControls.ps1") ?? throw new FileNotFoundException("The Windows control helper is missing.");
        using var reader = new StreamReader(resource);
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes("$source=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ROO_INDUSTRIES_CONTROL_HELPER)); & ([ScriptBlock]::Create($source))")) }) start.ArgumentList.Add(argument);
        using var map = assembly.GetManifestResourceStream("Optimizer.Core.WindowsMitigations.json") ?? throw new FileNotFoundException("The mitigation field map is missing.");
        using var mapReader = new StreamReader(map);
        start.Environment["ROO_INDUSTRIES_MITIGATIONS"] = mapReader.ReadToEnd();
        start.Environment["ROO_INDUSTRIES_CONTROL_HELPER"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(reader.ReadToEnd()));
        start.Environment["ROO_INDUSTRIES_CONTROL_REQUEST"] = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(request, OperationFiles.Json));
        using var process = Process.Start(start) ?? throw new IOException("Could not start the Windows control helper.");
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(120000)) { process.Kill(entireProcessTree: true); process.WaitForExit(); throw new IOException("The Windows control helper timed out after 120 seconds."); }
        Task.WaitAll(output, error);
        if (process.ExitCode != 0) throw new IOException("Windows control helper exited " + process.ExitCode + ": " + error.Result.Trim() + " " + output.Result.Trim());
        var result = OperationFiles.Deserialize<JsonElement>(Encoding.UTF8.GetBytes(output.Result));
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("error", out var failure)) throw new InvalidOperationException(failure.GetString());
        return result;
    }
}
