using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Threading;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record ProcessControlReview(ProcessControlPreview Plan, string PreviewPath, string Hash, string JournalPath);
public sealed record PolicyWorkerRegistration(string TaskName, bool Registered, bool Enabled, bool RunAtLogon, bool RestartEveryMinute, bool Paused, int Rules, int EnabledRules,
    bool Secured, string? SecurityProblem, string? RulesError, PolicyWorkerStatus Worker);
public sealed record GovernorSnapshot(PolicySummary Summary, PolicyWorkerStatus Worker, SavedProcessRule[] Rules, Dictionary<string, ProcessControlJournal> Journals);
public sealed record CleanupBatchReview(CleanupBatchPreview Plan, string PreviewPath, string Hash, string JournalPath);
public sealed record CleanupBatchSession(CleanupBatchReview Review, CleanupBatchJournal State);

public sealed partial class OptimizerService
{
    public string PolicyRoot => Path.Combine(Path.GetDirectoryName(_storage)!, "process-rules");

    public Task<ProcessControlSnapshot> ReadProcessControlsAsync(int processId)
        => RunCoreAsync<ProcessControlSnapshot>("process-status", new() { ["processId"] = processId });

    public async Task<ProcessControlReview> PreviewControlsAsync(int processId, Dictionary<string, JsonElement> controls, CpuSelection? selection)
    {
        var directory = await NewOperationDirectoryAsync("process");
        var path = Path.Combine(directory, "preview.json");
        var preview = await RunCoreAsync<ProcessControlPreview>("process-preview", new()
        {
            ["processId"] = processId, ["controls"] = controls, ["cpuSelection"] = selection, ["outputPath"] = path,
        });
        return new(preview, path, Hash(path), Path.Combine(directory, "journal.json"));
    }

    public async Task<ProcessControlJournal> ApplyControlsAsync(ProcessControlReview review)
    {
        await RememberAsync("process", review.JournalPath);
        return await RunCoreAsync<ProcessControlJournal>("process-apply", new()
        {
            ["previewPath"] = review.PreviewPath, ["reviewHash"] = review.Hash, ["journalPath"] = review.JournalPath, ["policyRoot"] = PolicyRoot, ["confirm"] = true,
        });
    }

    public async Task<ProcessControlJournal> RestoreControlsAsync(string journalPath)
    {
        var result = await RunCoreAsync<ProcessControlJournal>("process-restore", new() { ["journalPath"] = journalPath, ["policyRoot"] = PolicyRoot, ["confirm"] = true });
        if (result.Status is "restored" or "expired" && FindLastJournal("process") == journalPath) Forget("process");
        return result;
    }

    public Task<SavedProcessRule[]> ReadRulesAsync() => RunCoreAsync<SavedProcessRule[]>("rules-list", new() { ["policyRoot"] = PolicyRoot });
    public Task<PolicyWorkerStatus> ReadPolicyStatusAsync() => Task.Run(() => new ProcessPolicyStore(PolicyRoot).Status());
    public Task<GovernorSnapshot> ReadGovernorAsync() => Task.Run(() =>
    {
        var store = new ProcessPolicyStore(PolicyRoot);
        var summary = store.Summary(deep: false);
        PolicyWorkerStatus worker;
        try { worker = store.Status(); }
        catch (Exception error) { worker = new(null, null, error.Message); }
        var rules = summary.RulesError is null ? store.ReadRules().Select(pair => pair.Rule).ToArray() : [];
        var journals = new Dictionary<string, ProcessControlJournal>(StringComparer.OrdinalIgnoreCase);
        foreach (var instance in worker.State?.Instances.Where(instance => instance.Status is "active" or "applying" or "conflict") ?? [])
        {
            try { if (File.Exists(instance.JournalPath)) journals[instance.JournalPath] = OperationFiles.Read<ProcessControlJournal>(instance.JournalPath); }
            catch (IOException) { }
            catch (InvalidDataException) { }
            catch (JsonException) { }
        }
        return new GovernorSnapshot(summary, worker, rules, journals);
    });
    public Task<SavedProcessRule> SaveRuleAsync(SavedProcessRule rule)
        => RunCoreAsync<SavedProcessRule>("rule-save", new() { ["policyRoot"] = PolicyRoot, ["rule"] = rule, ["confirm"] = true });
    public Task<JsonElement> DeleteRuleAsync(string ruleId)
        => RunCoreAsync<JsonElement>("rule-delete", new() { ["policyRoot"] = PolicyRoot, ["ruleId"] = ruleId, ["confirm"] = true });

    public async Task<PolicyWorkerRegistration> PolicyWorkerAsync(string action)
    {
        string[] allowed = ["Status", "Sync", "Pause", "Resume", "Remove"];
        if (Array.IndexOf(allowed, action) < 0) throw new ArgumentException("Unknown policy worker action.", nameof(action));
        var result = await RunAsync<PolicyWorkerRegistration>("Invoke-ProcessPolicyWorker.ps1",
            "-Action " + action + " -PolicyRoot " + Quote(PolicyRoot) + (action == "Status" ? "" : " -ConfirmApply"), waitForRemoval: true);
        return RequireData(result);
    }

    public Task<LeftoverDiscoveryResult> DiscoverLeftoversAsync(string queueJournalPath, string appId, CancellationToken cancellationToken)
        => RunCoreAsync<LeftoverDiscoveryResult>("cleanup-scan", new() { ["queueJournalPath"] = queueJournalPath, ["appId"] = appId }, cancellationToken);

    public async Task<CleanupPart> PreviewDeepCleanupAsync(string queueJournalPath, string appId, string[] itemIds, bool acceptKeyRecreation)
    {
        var directory = await NewOperationDirectoryAsync("cleanup");
        var path = Path.Combine(directory, "preview.json");
        await RunCoreAsync<ApplicationCleanupPreview>("cleanup-preview", new()
        {
            ["queueJournalPath"] = queueJournalPath, ["appId"] = appId, ["itemIds"] = itemIds, ["outputPath"] = path,
            ["ownershipReviewed"] = true, ["acceptKeyRecreation"] = acceptKeyRecreation,
        });
        return new(path, Hash(path), Path.Combine(directory, "journal.json"));
    }

    public async Task<CleanupBatchReview> PreviewCleanupBatchAsync(CleanupPart[] applications)
    {
        var directory = await NewOperationDirectoryAsync("cleanup-batch");
        var path = Path.Combine(directory, "preview.json");
        var plan = await RunCoreAsync<CleanupBatchPreview>("cleanup-batch-preview", new() { ["cleanupOperations"] = applications, ["outputPath"] = path });
        return new(plan, path, Hash(path), Path.Combine(directory, "journal.json"));
    }

    public async Task<CleanupBatchJournal> ApplyCleanupBatchAsync(CleanupBatchReview review, string? cancellationId, IProgress<CleanupBatchJournal> progress)
    {
        var operation = RunCoreAsync<CleanupBatchJournal>("cleanup-batch-apply", new()
        {
            ["previewPath"] = review.PreviewPath, ["reviewHash"] = review.Hash, ["journalPath"] = review.JournalPath, ["cancellationId"] = cancellationId, ["confirm"] = true,
        });
        Exception? observationError = null;
        while (!operation.IsCompleted)
        {
            if (File.Exists(review.JournalPath))
            {
                try { progress.Report(await Task.Run(() => CleanupBatch.ReadJournal(review.JournalPath))); observationError = null; }
                catch (Exception error) { observationError = error; }
            }
            await Task.WhenAny(operation, Task.Delay(500));
        }
        var result = await operation;
        if (observationError is not null) result = await Task.Run(() => CleanupBatch.ReadJournal(review.JournalPath));
        progress.Report(result);
        return result;
    }

    public Task<CleanupBatchCancellation> CancelCleanupBatchAsync(string journalPath)
        => RunCoreAsync<CleanupBatchCancellation>("cleanup-batch-cancel", new() { ["journalPath"] = journalPath, ["confirm"] = true });

    public Task<CleanupBatchJournal> RestoreCleanupBatchAsync(string journalPath)
        => RunCoreAsync<CleanupBatchJournal>("cleanup-batch-restore", new() { ["journalPath"] = journalPath, ["confirm"] = true });

    public Task<CleanupBatchSession[]> ReadCleanupHistoryAsync() => Task.Run(() =>
    {
        if (!Directory.Exists(_storage)) return Array.Empty<CleanupBatchSession>();
        return Directory.EnumerateDirectories(_storage, "cleanup-batch-*").Select(directory => Path.Combine(directory, "journal.json"))
            .Where(File.Exists).Select(path =>
            {
                var journal = CleanupBatch.ReadJournal(path);
                return new CleanupBatchSession(new(journal.Preview, journal.PreviewPath, journal.ReviewHash, path), journal);
            }).OrderByDescending(session => session.State.UpdatedAtUtc).ToArray();
    });

    public async Task<(string Path, Models.BulkRemovalJournal State)[]> ReadRemovalHistoryAsync()
    {
        if (!Directory.Exists(_storage)) return Array.Empty<(string, Models.BulkRemovalJournal)>();
        var result = new List<(string, Models.BulkRemovalJournal)>();
        foreach (var path in Directory.EnumerateDirectories(_storage, "removal-*").Select(directory => Path.Combine(directory, "journal.json")).Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc))
        {
            var journal = await ReadJournalAsync<Models.BulkRemovalJournal>(path) ?? throw new InvalidDataException("A saved removal journal is empty: " + path);
            result.Add((path, journal));
        }
        return result.ToArray();
    }

    private async Task<T> RunCoreAsync<T>(string action, Dictionary<string, object?> request, CancellationToken cancellationToken = default, TimeSpan? timeout = null, Action<ReadOnlyMemory<byte>>? partial = null)
    {
        var elapsed = Stopwatch.StartNew();
        var outcome = "failed";
        try
        {
            var result = await RunHostAsync<T>(action, request, cancellationToken, timeout, partial).ConfigureAwait(false);
            outcome = "completed";
            return result;
        }
        catch (TimeoutException) { outcome = "timed out"; throw; }
        catch (OperationCanceledException) { outcome = "cancelled"; throw; }
        finally { AppLog.Timing(action, elapsed, outcome); }
    }

    private async Task<T> RunHostAsync<T>(string action, Dictionary<string, object?> request, CancellationToken cancellationToken, TimeSpan? timeout, Action<ReadOnlyMemory<byte>>? partial)
    {
        var confirmed = request.TryGetValue("confirm", out var confirm) && confirm is true;
        if (confirmed && action != "operations-secure") await EnsureStorageAsync().ConfigureAwait(false);
        using var change = confirmed ? DataGeneration.BeginChange() : null;
        var root = _locator.RepoRoot ?? throw new InvalidOperationException(AppLog.MissingFiles);
        var host = Path.Combine(root, "backend", "bin", "optimizer", "Optimizer.Host.dll");
        if (!File.Exists(host))
        {
            AppLog.Write("helper", "Missing " + host);
            throw new FileNotFoundException(AppLog.MissingFiles, host);
        }
        var dotnet = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_DOTNET_EXE");
        var hostDirectory = Path.GetDirectoryName(host)!;
        var bundled = string.IsNullOrWhiteSpace(dotnet) && File.Exists(Path.Combine(hostDirectory, "hostpolicy.dll"));
        if (bundled) dotnet = Path.Combine(hostDirectory, "Optimizer.Host.exe");
        else if (string.IsNullOrWhiteSpace(dotnet))
        {
            var userRuntime = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet", "dotnet.exe");
            dotnet = File.Exists(userRuntime) ? userRuntime : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "dotnet", "dotnet.exe");
        }
        if (!File.Exists(dotnet))
        {
            AppLog.Write("helper", "Missing " + dotnet);
            throw new FileNotFoundException(bundled ? "Some app files are missing. Reinstall the app." : "This app needs the Microsoft .NET 8 Desktop Runtime. Install it from Microsoft, then reopen the app.", dotnet);
        }
        request["schemaVersion"] = 1;
        request["repoRoot"] = root;
        var payload = JsonSerializer.SerializeToUtf8Bytes(request, OperationFiles.Json);
        var start = new ProcessStartInfo(dotnet)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = root,
        };
        start.Environment["ROO_INDUSTRIES_UI_EXE"] = Environment.ProcessPath;
        foreach (var argument in bundled ? new[] { action, "-" } : new[] { host, action, "-" }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("The optimizer helper did not start.");
        try
        {
            await process.StandardInput.BaseStream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
            process.StandardInput.Close();
        }
        catch
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            throw;
        }
        var output = ReadAllAsync(process.StandardOutput.BaseStream, partial);
        var errors = process.StandardError.ReadToEndAsync();
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeout is { } duration) limit.CancelAfter(duration);
        try { await process.WaitForExitAsync(limit.Token).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync().ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested) throw;
            AppLog.Write("helper", action + " timed out.");
            throw new TimeoutException(AppLog.TimedOut);
        }
        var text = await output.ConfigureAwait(false);
        var stderr = await errors.ConfigureAwait(false);
        if (text.Span.Trim(" \t\r\n"u8).IsEmpty)
        {
            AppLog.Write("helper", action + " exited with code " + process.ExitCode);
            throw new InvalidOperationException(AppLog.Explain("helper", stderr, AppLog.Failed));
        }
        using var document = JsonDocument.Parse(text);
        var result = document.RootElement;
        if (process.ExitCode != 0 || result.GetProperty("status").GetString() != "completed")
        {
            var message = result.TryGetProperty("error", out var error) ? error.GetProperty("message").GetString() : null;
            AppLog.Write("helper", action + " failed: " + (message ?? Encoding.UTF8.GetString(text.Span)));
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? AppLog.Failed : message);
        }
        return result.GetProperty("data").Deserialize<T>(OperationFiles.Json) ?? throw new InvalidDataException("The optimizer helper returned no operation data.");
    }

    private static async Task<ReadOnlyMemory<byte>> ReadAllAsync(Stream stream, Action<ReadOnlyMemory<byte>>? partial)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        var start = 0;
        var scanned = 0;
        for (int read; (read = await stream.ReadAsync(chunk).ConfigureAwait(false)) > 0;)
        {
            buffer.Write(chunk, 0, read);
            while (partial is not null)
            {
                var pending = new ReadOnlyMemory<byte>(buffer.GetBuffer(), start, checked((int)buffer.Length) - start);
                var trimmed = pending.Span.StartsWith("\uFEFF"u8) ? 3 : 0;
                if (!pending.Span[trimmed..].StartsWith(PartialPrefix)) break;
                var end = pending.Span[scanned..].IndexOf((byte)'\n');
                if (end < 0) { scanned = pending.Length; break; }
                end += scanned;
                var line = pending[(trimmed + PartialPrefix.Length)..end];
                try { partial(line.ToArray()); } catch (Exception error) { AppLog.Write("helper", "Partial result ignored: " + error.Message); }
                start += end + 1; scanned = 0;
            }
        }
        var bytes = new ReadOnlyMemory<byte>(buffer.GetBuffer(), start, checked((int)buffer.Length) - start);
        if (bytes.Span.StartsWith("\uFEFF"u8)) bytes = bytes[3..];
        return partial is not null && bytes.Span.StartsWith(PartialPrefix) ? ReadOnlyMemory<byte>.Empty : bytes;
    }
    private static ReadOnlySpan<byte> PartialPrefix => "ROO-PARTIAL "u8;
}
