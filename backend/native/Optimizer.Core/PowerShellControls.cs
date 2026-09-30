#nullable enable
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace RooIndustries.Optimizer;

static class PowerShellControls
{
    private static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(120);
    private const string ResultPrefix = "ROO-CONTROL ";
    public static TweakControlRead Read(ControlAddress address) => Parse(Invoke(new { action = "read", address }));
    public static void Write(TweakControlRead before, JsonElement after) => Invoke(new { action = "write", address = before.Address, before, after });
    internal static JsonElement Invoke(object request)
    {
        using var process = Start(request);
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(120000)) { process.Kill(entireProcessTree: true); process.WaitForExit(); throw new IOException("The Windows control helper timed out after 120 seconds."); }
        Task.WaitAll(output, error);
        if (process.ExitCode != 0) throw new IOException("Windows control helper exited " + process.ExitCode + ": " + error.Result.Trim() + " " + output.Result.Trim());
        return Result(output.Result);
    }
    public static Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> ReadMany(IReadOnlyList<ControlAddress> addresses)
    {
        var results = new Dictionary<ControlAddress, (TweakControlRead?, Exception?)>();
        var remaining = addresses.Distinct().ToList();
        while (remaining.Count > 0)
        {
            var batch = new List<ControlAddress>();
            foreach (var address in remaining)
            {
                if (batch.Count > 0 && Encoded(new { action = "read-batch", addresses = batch.Append(address) }).Length > 24000) break;
                batch.Add(address);
            }
            var done = ReadBatch(batch, results);
            remaining = remaining.Skip(done).ToList();
        }
        return results;
    }
    private static int ReadBatch(List<ControlAddress> batch, Dictionary<ControlAddress, (TweakControlRead?, Exception?)> results)
    {
        Process process;
        try { process = Start(new { action = "read-batch", addresses = batch }); }
        catch (Exception error) { results[batch[0]] = (null, error); return 1; }
        using (process)
        {
            process.StandardInput.Close();
            var lines = new BlockingCollection<string>();
            var reader = Task.Run(() =>
            {
                try { for (string? line; (line = process.StandardOutput.ReadLine()) is not null;) lines.Add(line); }
                finally { lines.CompleteAdding(); }
            });
            var errors = process.StandardError.ReadToEndAsync();
            var done = 0; var stray = new StringBuilder();
            while (done < batch.Count)
            {
                if (!lines.TryTake(out var line, ReadTimeout))
                {
                    if (lines.IsCompleted) break;
                    Stop(process, reader);
                    results[batch[done]] = (null, new IOException("The Windows control helper timed out after 120 seconds."));
                    return done + 1;
                }
                var json = Payload(line, done);
                if (json is null) { stray.Append(line).Append(Environment.NewLine); continue; }
                try { results[batch[done]] = (Parse(Result(stray + json)), null); }
                catch (Exception error) { results[batch[done]] = (null, error); }
                stray.Clear(); done++;
            }
            if (!process.WaitForExit(ReadTimeout))
            {
                Stop(process, reader);
                if (done < batch.Count) { results[batch[done]] = (null, new IOException("The Windows control helper timed out after 120 seconds.")); return done + 1; }
                return done;
            }
            reader.Wait();
            if (done == batch.Count) return done;
            try
            {
                errors.Wait();
                if (process.ExitCode != 0) throw new IOException("Windows control helper exited " + process.ExitCode + ": " + errors.Result.Trim() + " " + stray.ToString().Trim());
                results[batch[done]] = (Parse(Result(stray.ToString())), null);
            }
            catch (Exception error) { results[batch[done]] = (null, error); }
            return done + 1;
        }
    }
    private static string? Payload(string line, int expected)
    {
        if (!line.StartsWith(ResultPrefix, StringComparison.Ordinal)) return null;
        var space = line.IndexOf(' ', ResultPrefix.Length);
        if (space < 0 || !int.TryParse(line.AsSpan(ResultPrefix.Length, space - ResultPrefix.Length), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var index) || index != expected) return null;
        return line[(space + 1)..];
    }
    private static void Stop(Process process, Task reader)
    {
        try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        process.WaitForExit();
        try { reader.Wait(TimeSpan.FromSeconds(10)); } catch (AggregateException) { }
    }
    private static TweakControlRead Parse(JsonElement result) => result.Deserialize<TweakControlRead>(OperationFiles.Json)
        ?? throw new InvalidDataException("Windows control response was empty.");
    private static JsonElement Result(string output)
    {
        var result = OperationFiles.Deserialize<JsonElement>(Encoding.UTF8.GetBytes(output));
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("error", out var failure)) throw new InvalidOperationException(failure.GetString());
        return result;
    }
    private static string Encoded(object request) => Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(request, OperationFiles.Json));
    private static Process Start(object request)
    {
        var assembly = typeof(PowerShellControls).Assembly;
        using var resource = assembly.GetManifestResourceStream("Optimizer.Core.WindowsControls.ps1") ?? throw new FileNotFoundException("The Windows control helper is missing.");
        using var packed = new MemoryStream();
        using (var gzip = new GZipStream(packed, CompressionLevel.Optimal, leaveOpen: true)) resource.CopyTo(gzip);
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes("$packed=New-Object IO.MemoryStream(,[Convert]::FromBase64String($env:ROO_INDUSTRIES_CONTROL_HELPER)); $source=(New-Object IO.StreamReader((New-Object IO.Compression.GZipStream($packed,[IO.Compression.CompressionMode]::Decompress)),[Text.Encoding]::UTF8)).ReadToEnd(); & ([ScriptBlock]::Create($source))")) }) start.ArgumentList.Add(argument);
        start.Environment["ROO_INDUSTRIES_CONTROL_HELPER"] = Convert.ToBase64String(packed.ToArray());
        start.Environment["ROO_INDUSTRIES_CONTROL_REQUEST"] = Encoded(request);
        return Process.Start(start) ?? throw new IOException("Could not start the Windows control helper.");
    }
}
