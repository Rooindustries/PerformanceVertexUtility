using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record BugSpec(string Key, string Label, string Value);
public sealed record BugReport(string Version, IReadOnlyList<BugSpec> Specs, string? Contact, string Description);
public sealed record BugAttachment(string FilePath, long Bytes)
{
    public string FileName => Path.GetFileName(FilePath);
}
public sealed record BugSendResult(bool Sent, int? StatusCode = null, TimeSpan? RetryAfter = null, string? Error = null);
public enum BugSendStatus { Sent, NotConfigured, NeedsDetails, Throttled, RateLimited, Offline, Rejected }
public sealed record BugSendOutcome(BugSendStatus Status, TimeSpan Wait = default);

public interface IBugReportSender
{
    Task<BugSendResult> SendAsync(string webhookUrl, string payloadJson, string zipPath, CancellationToken cancellationToken);
}

public sealed class BugRedactor
{
    private readonly (Regex Pattern, string Replacement)[] _rules;

    public BugRedactor(string? profilePath, string? userName, string? machineName)
    {
        var rules = new List<(Regex, string)>();
        var profile = profilePath?.TrimEnd('\\', '/');
        if (!string.IsNullOrWhiteSpace(profile))
        {
            foreach (var form in new[] { profile, profile.Replace("\\", "\\\\"), profile.Replace('\\', '/') }.Distinct())
                rules.Add((new Regex(Regex.Escape(form), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "%USERPROFILE%"));
        }
        foreach (var (value, replacement) in new[] { (machineName?.Trim(), "<pc-name>"), (userName?.Trim(), "<user>") })
        {
            if (value is not { Length: >= 2 }) continue;
            rules.Add((Word(value), replacement));
            var escaped = JsonEncodedText.Encode(value).ToString();
            if (escaped != value) rules.Add((Word(escaped), replacement));
        }
        rules.Add((OtherProfiles, "<user>"));
        rules.Add((new Regex(@"S-1-5-21(-\d+){3,4}", RegexOptions.CultureInvariant), "<sid>"));
        _rules = rules.ToArray();
    }

    public static BugRedactor Current() => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.UserName, Environment.MachineName);

    public string Redact(string text)
    {
        foreach (var (pattern, replacement) in _rules) text = pattern.Replace(text, replacement);
        return text;
    }

    private static readonly Regex OtherProfiles = new(@"(?<=\b[A-Za-z]:(?:\\{1,2}|/)Users(?:\\{1,2}|/))(?!(?:Public|Default|Default User|All Users)(?:[\\/""]|$))[^\\/""'\s]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static Regex Word(string value)
        => new(@"(?<![\p{L}\p{N}_])" + Regex.Escape(value) + @"(?![\p{L}\p{N}_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

public sealed class DiscordWebhookSender : IBugReportSender
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(5) };

    public async Task<BugSendResult> SendAsync(string webhookUrl, string payloadJson, string zipPath, CancellationToken cancellationToken)
    {
        using var content = new MultipartFormDataContent();
        content.Add(new StringContent(payloadJson, Encoding.UTF8, "application/json"), "payload_json");
        await using var stream = new FileStream(zipPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        var file = new StreamContent(stream);
        file.Headers.ContentType = new MediaTypeHeaderValue("application/zip");
        content.Add(file, "files[0]", Path.GetFileName(zipPath));
        using var response = await Client.PostAsync(webhookUrl, content, cancellationToken);
        if (response.IsSuccessStatusCode) return new(true, (int)response.StatusCode);
        var retry = response.Headers.RetryAfter?.Delta is { } delta ? TimeSpan.FromSeconds(Math.Clamp(delta.TotalSeconds, 0, 3600)) : (TimeSpan?)null;
        if ((int)response.StatusCode == 429 && retry is null)
        {
            try
            {
                using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
                if (document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("retry_after", out var seconds)
                    && seconds.ValueKind == JsonValueKind.Number && seconds.TryGetDouble(out var value)) retry = TimeSpan.FromSeconds(Math.Clamp(value, 0, 3600));
            }
            catch (JsonException)
            {
            }
        }
        return new(false, (int)response.StatusCode, retry);
    }
}

public sealed class BugReportService
{
    public const long MaxZipBytes = 8_000_000;
    public const int EmbedTotalLimit = 6000;
    public const int DescriptionLimit = 4096;
    public const int FieldValueLimit = 1024;
    public const string WebhookResource = "RooIndustries.BugReportWebhook";
    public static readonly TimeSpan SendInterval = TimeSpan.FromSeconds(60);
    private const long LogBudgetBytes = 7_000_000;
    private const int MinimumDescription = 500;
    private static readonly JsonSerializerOptions ReadableJson = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly string? _webhookUrl;
    private readonly IBugReportSender _sender;
    private readonly string _reportFolder;
    private readonly string _logFolder;
    private readonly BugRedactor _redactor;
    private readonly Func<DateTime> _now;
    private DateTime _nextSendUtc = DateTime.MinValue;

    public BugReportService(string? webhookUrl, IBugReportSender sender, string reportFolder, string logFolder, BugRedactor redactor, Func<DateTime>? now = null)
    {
        _webhookUrl = webhookUrl?.Trim();
        _sender = sender;
        _reportFolder = reportFolder;
        _logFolder = logFolder;
        _redactor = redactor;
        _now = now ?? (() => DateTime.UtcNow);
    }

    public bool OnlineAvailable => IsWebhookUrl(_webhookUrl);
    public string ReportFolder => _reportFolder;

    public TimeSpan WaitBeforeSend
    {
        get
        {
            var wait = _nextSendUtc - _now();
            return wait > TimeSpan.Zero ? wait : TimeSpan.Zero;
        }
    }

    public static bool IsWebhookUrl(string? url)
        => Uri.TryCreate(url, UriKind.Absolute, out var uri)
           && uri.Scheme == Uri.UriSchemeHttps
           && (uri.Host is "discord.com" or "discordapp.com" or "ptb.discord.com" or "canary.discord.com")
           && uri.AbsolutePath.StartsWith("/api/webhooks/", StringComparison.Ordinal);

    public static string? ReadWebhook(Assembly assembly)
    {
        using var stream = assembly.GetManifestResourceStream(WebhookResource);
        if (stream is null) return null;
        using var reader = new StreamReader(stream);
        return ParseWebhook(reader.ReadToEnd());
    }

    public static string? ParseWebhook(string? text)
    {
        var line = text?.TrimStart('\uFEFF').Split('\n')[0].Trim();
        return line is not null && line.StartsWith("url=", StringComparison.Ordinal) && line.Length > 4 ? line[4..].Trim() : null;
    }

    public static bool CanSubmit(string? description, BugAttachment? attachment)
        => !string.IsNullOrWhiteSpace(description) && attachment is not null && File.Exists(attachment.FilePath);

    public static string Truncate(string? text, int max)
    {
        text ??= "";
        if (text.Length <= max) return text;
        if (max <= 3) return text[..Math.Max(max, 0)];
        var cut = max - 3;
        if (char.IsHighSurrogate(text[cut - 1])) cut--;
        return text[..cut] + "...";
    }

    public static string TweakSummaryJson(IEnumerable<string> appliedProfiles, bool? pendingRecovery, string? pendingPhase, IEnumerable<string?> lastErrors)
        => JsonSerializer.Serialize(new
        {
            schemaVersion = 1,
            appliedProfiles = appliedProfiles.ToArray(),
            pendingRecovery,
            pendingPhase,
            lastErrors = lastErrors.Where(error => !string.IsNullOrWhiteSpace(error)).Select(error => Truncate(error, 2000)).ToArray(),
        }, ReadableJson);

    public static string BuildPayload(BugReport report, string fileName)
    {
        var title = Truncate("Bug report: Performance Vertex Utility " + report.Version, 256);
        var source = report.Specs.Select(spec => (Name: Truncate(Fallback(spec.Label, spec.Key), 256), Value: Fallback(spec.Value, "Unknown")))
            .Append((Name: "Discord or email", Value: Fallback(report.Contact, "Not given")))
            .Take(25)
            .ToList();
        var cap = FieldValueLimit;
        var fields = source.Select(field => (field.Name, Value: Truncate(field.Value, cap))).ToList();
        while (title.Length + fields.Sum(field => field.Name.Length + field.Value.Length) > EmbedTotalLimit - MinimumDescription && cap > 32)
        {
            cap /= 2;
            fields = source.Select(field => (field.Name, Value: Truncate(field.Value, cap))).ToList();
        }
        var budget = Math.Min(DescriptionLimit, EmbedTotalLimit - title.Length - fields.Sum(field => field.Name.Length + field.Value.Length));
        var description = Truncate(Fallback(report.Description, "No description"), Math.Max(budget, 0));

        var payload = new JsonObject
        {
            ["allowed_mentions"] = new JsonObject { ["parse"] = new JsonArray() },
            ["embeds"] = new JsonArray(new JsonObject
            {
                ["title"] = title,
                ["description"] = description,
                ["color"] = 0x2F80ED,
                ["fields"] = new JsonArray(fields.Select(field => (JsonNode)new JsonObject { ["name"] = field.Name, ["value"] = field.Value, ["inline"] = false }).ToArray()),
            }),
            ["attachments"] = new JsonArray(new JsonObject { ["id"] = 0, ["filename"] = fileName }),
        };
        return payload.ToJsonString();
    }

    public BugAttachment CreateAttachment(IReadOnlyList<BugSpec> specs, string tweakSummaryJson, long maxBytes = MaxZipBytes)
    {
        var folder = Path.Combine(_reportFolder, "outgoing");
        Directory.CreateDirectory(folder);
        foreach (var old in Directory.EnumerateFiles(folder, "*.zip")) File.Delete(old);
        var path = Path.Combine(folder, "roo-industries-bug-report-" + _now().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + ".zip");
        var budget = LogBudgetBytes;
        while (true)
        {
            WriteZip(path, specs, tweakSummaryJson, budget);
            var size = new FileInfo(path).Length;
            if (size <= maxBytes) return new BugAttachment(path, size);
            if (budget < 1024)
            {
                File.Delete(path);
                throw new InvalidDataException("The log bundle could not be made small enough.");
            }
            budget /= 2;
        }
    }

    public async Task<BugSendOutcome> SendAsync(BugReport report, BugAttachment? attachment, CancellationToken cancellationToken = default)
    {
        if (!OnlineAvailable) return new(BugSendStatus.NotConfigured);
        if (attachment is null || !CanSubmit(report.Description, attachment)) return new(BugSendStatus.NeedsDetails);
        var wait = WaitBeforeSend;
        if (wait > TimeSpan.Zero) return new(BugSendStatus.Throttled, wait);

        _nextSendUtc = _now() + SendInterval;
        BugAttachment ready = attachment;
        BugAttachment current;
        try
        {
            current = await Task.Run(() => RefreshSpecs(ready, report.Specs), cancellationToken);
        }
        catch
        {
            _nextSendUtc = DateTime.MinValue;
            throw;
        }
        var payload = BuildPayload(report with { Description = _redactor.Redact(report.Description), Specs = report.Specs.Select(spec => spec with { Value = _redactor.Redact(spec.Value) }).ToArray() }, current.FileName);
        BugSendResult result;
        try
        {
            result = await _sender.SendAsync(_webhookUrl!, payload, current.FilePath, cancellationToken);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException)
        {
            result = new(false, Error: error.GetType().Name + ": " + error.Message);
        }

        if (result.Sent)
        {
            AppLog.Write("bug-report", "Report sent.");
            try { File.Delete(current.FilePath); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { AppLog.Write("bug-report", error.Message); }
            return new(BugSendStatus.Sent);
        }
        AppLog.Write("bug-report", "Report not sent: " + (result.StatusCode?.ToString(CultureInfo.InvariantCulture) ?? result.Error ?? "unknown"));
        if (result.StatusCode == 429)
        {
            var retry = _now() + (result.RetryAfter ?? SendInterval);
            if (retry > _nextSendUtc) _nextSendUtc = retry;
            return new(BugSendStatus.RateLimited, WaitBeforeSend);
        }
        if (result.StatusCode is null)
        {
            _nextSendUtc = DateTime.MinValue;
            return new(BugSendStatus.Offline);
        }
        return new(BugSendStatus.Rejected);
    }

    public string SaveReport(BugReport report, BugAttachment attachment)
    {
        if (!CanSubmit(report.Description, attachment)) throw new InvalidOperationException("Describe what went wrong and attach logs first.");
        var folder = Path.Combine(_reportFolder, "saved");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, Path.GetFileNameWithoutExtension(attachment.FileName) + "-saved-" + _now().ToString("HHmmss", CultureInfo.InvariantCulture) + ".zip");
        File.Copy(attachment.FilePath, path, overwrite: true);
        using (var zip = ZipFile.Open(path, ZipArchiveMode.Update))
        {
            zip.GetEntry("specs.json")?.Delete();
            zip.GetEntry("report.txt")?.Delete();
            Add(zip, "specs.json", SpecsJson(report.Specs));
            Add(zip, "report.txt", ReportText(report));
        }
        return path;
    }

    private BugAttachment RefreshSpecs(BugAttachment attachment, IReadOnlyList<BugSpec> specs)
    {
        using (var zip = ZipFile.Open(attachment.FilePath, ZipArchiveMode.Update))
        {
            zip.GetEntry("specs.json")?.Delete();
            Add(zip, "specs.json", SpecsJson(specs));
        }
        return attachment with { Bytes = new FileInfo(attachment.FilePath).Length };
    }

    private void WriteZip(string path, IReadOnlyList<BugSpec> specs, string tweakSummaryJson, long budget)
    {
        using var stream = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.None);
        using var zip = new ZipArchive(stream, ZipArchiveMode.Create);
        Add(zip, "specs.json", SpecsJson(specs));
        Add(zip, "tweak-state.json", _redactor.Redact(tweakSummaryJson));
        var remaining = budget;
        var logs = Directory.Exists(_logFolder)
            ? new DirectoryInfo(_logFolder).GetFiles().OrderBy(file => file.Name == "app.log" ? 0 : 1).ThenByDescending(file => file.LastWriteTimeUtc).ToArray()
            : Array.Empty<FileInfo>();
        foreach (var log in logs)
        {
            if (remaining <= 0) break;
            var bytes = Encoding.UTF8.GetBytes(_redactor.Redact(ReadTail(log.FullName, remaining)));
            if (bytes.LongLength > remaining) bytes = bytes[^(int)remaining..];
            var entry = zip.CreateEntry("logs/" + log.Name, CompressionLevel.Optimal);
            using (var output = entry.Open()) output.Write(bytes, 0, bytes.Length);
            remaining -= bytes.LongLength;
        }
    }

    private string SpecsJson(IReadOnlyList<BugSpec> specs)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var spec in specs) values[spec.Key] = spec.Value;
        return _redactor.Redact(JsonSerializer.Serialize(new { schemaVersion = 1, specs = values }, ReadableJson));
    }

    private string ReportText(BugReport report)
    {
        var text = new StringBuilder();
        text.AppendLine("Performance Vertex Utility " + report.Version);
        text.AppendLine("Discord or email: " + Fallback(report.Contact, "Not given"));
        text.AppendLine();
        foreach (var spec in report.Specs) text.AppendLine(spec.Label + ": " + _redactor.Redact(spec.Value));
        text.AppendLine();
        text.AppendLine("What went wrong:");
        text.AppendLine(_redactor.Redact(report.Description.Trim()));
        return text.ToString();
    }

    private static string ReadTail(string path, long maxBytes)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var trimmed = stream.Length > maxBytes;
        if (trimmed) stream.Seek(-maxBytes, SeekOrigin.End);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var text = reader.ReadToEnd();
        if (!trimmed) return text;
        var newline = text.IndexOf('\n');
        return newline >= 0 && newline < text.Length - 1 ? text[(newline + 1)..] : text;
    }

    private static void Add(ZipArchive zip, string name, string text)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
        using var output = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        output.Write(text);
    }

    private static string Fallback(string? value, string fallback) => string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
}
