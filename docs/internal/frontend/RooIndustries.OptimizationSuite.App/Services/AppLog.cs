using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;

namespace RooIndustries.OptimizationSuite.Services;

public static class AppLog
{
    private const long MaxBytes = 2_000_000;
    private static readonly object Gate = new();
    private static bool _enabled;

    public const string MissingFiles = "Some app files are missing. Extract the full app folder again, then reopen the app.";
    public const string Failed = "Something went wrong. Details were saved to the app log (Settings, Open logs folder).";
    public const string TimedOut = "This took too long and was stopped. Try again. If you were changing something, check Undo changes first.";

    private static readonly Lazy<BugRedactor> Redactor = new(BugRedactor.Current);

    public static string Folder => Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "logs");
    public static string FilePath => Path.Combine(Folder, "app.log");

    public static string Explain(string source, string? detail, string fallback)
    {
        detail = PowerShellErrors(detail);
        Write(source, detail);
        var line = (detail ?? "").Split('\n').Select(value => value.Trim()).FirstOrDefault(value => value.Length > 0) ?? "";
        var script = line.IndexOf(".ps1 : ", StringComparison.OrdinalIgnoreCase);
        if (script >= 0) line = line[(script + 7)..].Trim();
        var command = line.IndexOf(" : ", StringComparison.Ordinal);
        if (command > 0 && !line[..command].Contains(' ')) line = line[(command + 3)..].Trim();
        return line.Length is 0 or > 240 || line.StartsWith('#') || line.StartsWith('<') || line.Contains("Exception", StringComparison.Ordinal) || line.Contains(":\\", StringComparison.Ordinal) ? fallback : line;
    }

    // A script that fails on purpose prints its issues as JSON on standard output: their messages are the cause to log.
    public static string ScriptIssues(string? output)
    {
        if (string.IsNullOrWhiteSpace(output)) return "no output";
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(output);
            if (document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object && document.RootElement.TryGetProperty("errors", out var errors) && errors.ValueKind == System.Text.Json.JsonValueKind.Array)
            {
                var messages = errors.EnumerateArray().Select(issue => issue.ValueKind == System.Text.Json.JsonValueKind.Object && issue.TryGetProperty("message", out var message) ? message.ToString() : "")
                    .Where(message => message.Length > 0).ToArray();
                if (messages.Length != 0) return string.Join("; ", messages);
            }
        }
        catch (System.Text.Json.JsonException) { }
        var text = output.Trim();
        return text.Length <= 2000 ? text : "..." + text[^2000..];
    }

    // Windows PowerShell writes errors to a redirected error stream as a CLIXML block: read the text inside it.
    private static string? PowerShellErrors(string? detail)
    {
        if (detail is null || !detail.TrimStart().StartsWith("#< CLIXML", StringComparison.Ordinal)) return detail;
        return string.Concat(Regex.Matches(detail, "<S S=\"Error\">(.*?)</S>", RegexOptions.Singleline).Select(match =>
            Regex.Replace(WebUtility.HtmlDecode(match.Groups[1].Value), "_x([0-9A-Fa-f]{4})_", code => ((char)Convert.ToInt32(code.Groups[1].Value, 16)).ToString())));
    }

    public static void Timing(string call, System.Diagnostics.Stopwatch elapsed, string outcome)
    {
        if (call is "process-status" or "protected-session-status" && outcome == "completed" && elapsed.ElapsedMilliseconds < 1000) return;
        Write("timing", call + " " + elapsed.ElapsedMilliseconds + " ms " + outcome);
    }

    public static bool Enable() { Volatile.Write(ref _enabled, true); return true; }

    public static Action<string, string?>? Observer { get; set; }

    public static void Write(string source, string? detail)
    {
        Observer?.Invoke(source, detail);
        if (string.IsNullOrWhiteSpace(detail) || !Volatile.Read(ref _enabled)) return;
        try
        {
            var text = Redactor.Value.Redact(detail);
            lock (Gate)
            {
                Directory.CreateDirectory(Folder);
                var file = new FileInfo(FilePath);
                if (file.Exists && file.Length > MaxBytes) File.Move(FilePath, FilePath + ".old", overwrite: true);
                File.AppendAllText(FilePath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture) + " [" + source + "] " + text.Trim() + Environment.NewLine);
            }
        }
        catch
        {
        }
    }
}
