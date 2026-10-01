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
    private static readonly ConcurrentDictionary<int, Process> Active = new();
    static PowerShellControls() => AppDomain.CurrentDomain.ProcessExit += (_, _) =>
    {
        foreach (var process in Active.Values)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (Exception) { }
        }
    };
    private const string ResultPrefix = "ROO-CONTROL ";
    internal static Func<object, Process> Launcher { get; set; } = Start;
    public static TweakControlRead Read(ControlAddress address) => Parse(Invoke(new { action = "read", address }));
    public static void Write(TweakControlRead before, JsonElement after) => Invoke(new { action = "write", address = before.Address, before, after });
    internal static JsonElement Invoke(object request)
    {
        using var process = Launcher(request);
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(120000)) { process.Kill(entireProcessTree: true); process.WaitForExit(); throw new IOException("The Windows control helper timed out after 120 seconds."); }
        Task.WaitAll(output, error);
        if (process.ExitCode != 0) throw new IOException("Windows control helper exited " + process.ExitCode + ": " + error.Result.Trim() + " " + output.Result.Trim());
        return Result(output.Result);
    }
    public static Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)> ReadMany(IReadOnlyList<ControlAddress> addresses)
    {
        var groups = addresses.Distinct().GroupBy(address => address.Kind switch
        {
            "network-adapter" or "teredo" or "device-power" => 0,
            "firewall-profile" or "firewall-blocklist" or "defender" => 1,
            _ => 2,
        }).Select(group => group.ToList()).ToArray();
        var parts = Task.WhenAll(groups.Select(group => Task.Factory.StartNew(() => ReadGroup(group), CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default))).GetAwaiter().GetResult();
        var results = new Dictionary<ControlAddress, (TweakControlRead? Read, Exception? Error)>();
        foreach (var part in parts) foreach (var (address, result) in part) results[address] = result;
        return results;
    }
    private static Dictionary<ControlAddress, (TweakControlRead?, Exception?)> ReadGroup(List<ControlAddress> addresses)
    {
        var results = new Dictionary<ControlAddress, (TweakControlRead?, Exception?)>();
        var remaining = addresses;
        while (remaining.Count > 0)
        {
            var batch = new List<ControlAddress>();
            foreach (var address in remaining)
            {
                if (batch.Count > 0 && Encoded(new { action = "read-batch", addresses = batch.Append(address) }).Length > 24000) break;
                batch.Add(address);
            }
            remaining = remaining.Skip(ReadBatch(batch, results)).ToList();
        }
        return results;
    }
    private static int ReadBatch(List<ControlAddress> batch, Dictionary<ControlAddress, (TweakControlRead?, Exception?)> results)
    {
        Process process;
        try { process = Launcher(new { action = "read-batch", addresses = batch }); }
        catch (Exception error) { results[batch[0]] = (null, error); return 1; }
        using (process)
        {
            process.StandardInput.Close();
            var lines = new BlockingCollection<string>();
            var reader = Task.Factory.StartNew(() =>
            {
                try { foreach (var line in RawLines(process.StandardOutput)) lines.Add(line); }
                finally { lines.CompleteAdding(); }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            var errors = process.StandardError.ReadToEndAsync();
            var done = 0; var stray = new StringBuilder(); var budget = Stopwatch.StartNew();
            while (done < batch.Count)
            {
                var left = ReadTimeout - budget.Elapsed;
                if (!lines.TryTake(out var line, left > TimeSpan.Zero ? left : TimeSpan.Zero))
                {
                    if (lines.IsCompleted) break;
                    Stop(process, reader);
                    results[batch[done]] = (null, new IOException("The Windows control helper timed out after 120 seconds."));
                    return done + 1;
                }
                var marker = ResultPrefix + done.ToString(System.Globalization.CultureInfo.InvariantCulture) + " ";
                var at = line.IndexOf(marker, StringComparison.Ordinal);
                if (at < 0) { stray.Append(line); continue; }
                stray.Append(line, 0, at);
                try { results[batch[done]] = (Parse(Result(stray + line[(at + marker.Length)..].TrimEnd('\r', '\n'))), null); }
                catch (JsonException) when (stray.Length == 0) { results[batch[done]] = ReadSingle(batch[done]); }
                catch (Exception error) { results[batch[done]] = (null, error); }
                done++; budget.Restart();
                if (stray.Length > 0) { Stop(process, reader); return done; }
            }
            if (!process.WaitForExit(ReadTimeout))
            {
                Stop(process, reader);
                if (done < batch.Count) { results[batch[done]] = (null, new IOException("The Windows control helper timed out after 120 seconds.")); return done + 1; }
                return done;
            }
            if (done == batch.Count)
            {
                _ = reader.ContinueWith(task => task.Exception, TaskScheduler.Default);
                _ = errors.ContinueWith(task => task.Exception, TaskScheduler.Default);
                return done;
            }
            try { reader.Wait(); } catch (AggregateException) { }
            results[batch[done]] = ReadSingle(batch[done]);
            return done + 1;
        }
    }
    private static IEnumerable<string> RawLines(StreamReader reader)
    {
        var buffer = new char[4096]; var line = new StringBuilder();
        for (int read; (read = reader.Read(buffer, 0, buffer.Length)) > 0;)
        {
            for (var index = 0; index < read; index++)
            {
                line.Append(buffer[index]);
                if (buffer[index] != '\n') continue;
                yield return line.ToString();
                line.Clear();
            }
        }
        if (line.Length > 0) yield return line.ToString();
    }
    private static (TweakControlRead?, Exception?) ReadSingle(ControlAddress address)
    {
        try { return (Read(address), null); }
        catch (Exception error) { return (null, error); }
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
        RuntimeEnvironment.Apply(start);
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(RuntimeEnvironment.PowerShellPrelude + "$packed=New-Object IO.MemoryStream(,[Convert]::FromBase64String($env:ROO_INDUSTRIES_CONTROL_HELPER)); $source=(New-Object IO.StreamReader((New-Object IO.Compression.GZipStream($packed,[IO.Compression.CompressionMode]::Decompress)),[Text.Encoding]::UTF8)).ReadToEnd(); & ([ScriptBlock]::Create($source))")) }) start.ArgumentList.Add(argument);
        start.Environment["ROO_INDUSTRIES_CONTROL_HELPER"] = Convert.ToBase64String(packed.ToArray());
        start.Environment["ROO_INDUSTRIES_CONTROL_REQUEST"] = Encoded(request);
        Process process;
        lock (PrivilegeScope.Gate) process = Process.Start(start) ?? throw new IOException("Could not start the Windows control helper.");
        var id = process.Id;
        Active[id] = process;
        process.EnableRaisingEvents = true;
        process.Exited += (_, _) => Active.TryRemove(new(id, process));
        if (process.HasExited) Active.TryRemove(new(id, process));
        return process;
    }
}
