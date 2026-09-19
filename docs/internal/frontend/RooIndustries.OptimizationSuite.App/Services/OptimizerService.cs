using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Models;

namespace RooIndustries.OptimizationSuite.Services;

public sealed partial class OptimizerService
{
    private readonly BackendLocator _locator;
    private readonly string _storage;
    private static readonly JsonSerializerOptions Json = JsonTolerance.CreateOptions();

    public OptimizerService(BackendLocator locator, string? storageDirectory = null)
    {
        _locator = locator;
        _storage = storageDirectory ?? Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "operations");
    }

    public Task<OptimizerResult<CpuSetSnapshot>> ReadCpuSetsAsync(int processId, CancellationToken cancellationToken = default)
        => RunAsync<CpuSetSnapshot>("Invoke-ProcessCpuSets.ps1", $"-Action Status -TargetProcessId {processId}", cancellationToken);

    public async Task<CpuSetReview> PreviewCpuSetsAsync(int processId, uint[] ids, bool resetDefault)
    {
        var directory = NewOperationDirectory("cpu");
        var preview = Path.Combine(directory, "preview.json");
        var request = new { schemaVersion = 1, targetProcessId = processId, cpuSetIds = ids, resetDefault, outputPath = preview };
        var result = await RequestAsync<CpuSetPlan>("CpuSets", "Preview", request, directory);
        return new CpuSetReview(RequireData(result), preview, Hash(preview), Path.Combine(directory, "journal.json"));
    }

    public async Task<OptimizerResult<CpuSetJournal>> ApplyCpuSetsAsync(CpuSetReview review)
    {
        Remember("cpu", review.JournalPath);
        return await RequestAsync<CpuSetJournal>("CpuSets", "Apply", new
        {
            schemaVersion = 1, inputPath = review.PreviewPath, reviewSha256 = review.Hash, journalPath = review.JournalPath,
        }, Path.GetDirectoryName(review.JournalPath)!, confirm: true);
    }

    public async Task<OptimizerResult<CpuSetJournal>> RestoreCpuSetsAsync(string journal)
    {
        var result = await RunAsync<CpuSetJournal>("Invoke-ProcessCpuSets.ps1", "-Action Restore -JournalPath " + Quote(journal) + " -ConfirmApply");
        if (result.Status == "restored") Forget("cpu");
        return result;
    }

    public async Task<bool> ReleaseEndedCpuSessionAsync(string journal)
    {
        var saved = await ReadJournalAsync<CpuSetJournal>(journal) ?? throw new InvalidDataException("Saved CPU controls are empty.");
        var identity = saved.Preview.Identity;
        if (identity.ProcessId <= 0 || !long.TryParse(identity.CreationTimeFileTimeUtc, out var created) || created <= 0)
            throw new InvalidDataException("Saved process identity is incomplete.");
        bool ended;
        try
        {
            using var process = Process.GetProcessById(identity.ProcessId);
            ended = process.HasExited || process.StartTime.ToUniversalTime().ToFileTimeUtc() != created;
        }
        catch (ArgumentException) { ended = true; }
        if (ended && string.Equals(FindLastJournal("cpu"), journal, StringComparison.OrdinalIgnoreCase)) Forget("cpu");
        return ended;
    }

    public async Task<BulkRemovalReview> PreviewRemovalAsync(string[] appIds, bool includeAllAppxUsers = false)
    {
        var directory = NewOperationDirectory("removal");
        var preview = Path.Combine(directory, "preview.json");
        var result = await RequestAsync<BulkRemovalPlan>("BulkUninstall", "Preview", new { schemaVersion = 1, appIds, includeAllAppxUsers, outputPath = preview }, directory);
        return new BulkRemovalReview(RequireData(result), preview, Hash(preview), Path.Combine(directory, "journal.json"));
    }

    public async Task<OptimizerResult<BulkRemovalJournal>> ApplyRemovalAsync(BulkRemovalReview review, bool dependenciesReviewed, IProgress<BulkRemovalJournal> progress)
    {
        Remember("removal", review.JournalPath);
        var operation = RequestAsync<BulkRemovalJournal>("BulkUninstall", "Apply", new
        {
            schemaVersion = 1, inputPath = review.PreviewPath, reviewSha256 = review.Hash,
            journalPath = review.JournalPath, manualReviewApproved = dependenciesReviewed,
        }, Path.GetDirectoryName(review.JournalPath)!, confirm: true, waitForRemoval: true);
        while (!operation.IsCompleted)
        {
            if (File.Exists(review.JournalPath))
            {
                var state = await ReadJournalAsync<BulkRemovalJournal>(review.JournalPath);
                if (state is not null) progress.Report(state);
            }
            await Task.WhenAny(operation, Task.Delay(500));
        }
        var result = await operation;
        if (result.Data is not null) progress.Report(result.Data);
        return result;
    }

    public Task<OptimizerResult<BulkRemovalJournal>> CancelRemovalAsync(string journal)
        => RunAsync<BulkRemovalJournal>("Invoke-BulkUninstall.ps1", "-Action Cancel -JournalPath " + Quote(journal) + " -ConfirmApply");

    public Task<OptimizerResult<BulkRemovalJournal>> ReconcileRemovalAsync(string journal)
        => RunAsync<BulkRemovalJournal>("Invoke-BulkUninstall.ps1", "-Action Reconcile -JournalPath " + Quote(journal) + " -ConfirmApply");

    public async Task<BulkRemovalSession?> ReadLastRemovalAsync()
    {
        var journal = FindLastJournal("removal");
        if (journal is null) return null;
        var state = await ReadJournalAsync<BulkRemovalJournal>(journal) ?? throw new InvalidDataException("Saved removal state is empty.");
        var preview = Path.Combine(Path.GetDirectoryName(journal)!, "preview.json");
        return new BulkRemovalSession(new BulkRemovalReview(state.Plan, preview, Hash(preview), journal), state);
    }

    public Task<OptimizerResult<LeftoverScan>> ScanRemovedAppAsync(string journal, string appId)
        => RunAsync<LeftoverScan>("Invoke-RemovalLeftovers.ps1", "-Action Scan -QueueJournalPath " + Quote(journal) + " -AppId " + Quote(appId));

    public async Task<RemovalCleanupReview> PreviewRemovedFilesAsync(string journal, string appId, string[] itemIds)
    {
        var path = Path.Combine(NewOperationDirectory("files"), "review.json");
        var args = "-Action Preview -QueueJournalPath " + Quote(journal) + " -AppId " + Quote(appId)
            + " -ItemId @(" + string.Join(",", itemIds.Select(Quote)) + ") -OutputPath " + Quote(path);
        var result = await RunAsync<RemovalCleanupPlan>("Invoke-RemovalLeftovers.ps1", args);
        return new RemovalCleanupReview(RequireData(result), path, Hash(path), journal);
    }

    public async Task<OptimizerResult<FileCleanupResult>> ApplyRemovedFilesAsync(RemovalCleanupReview review, bool reviewed)
    {
        WritePointer(Path.Combine(_storage, "files-active.json"), JsonSerializer.Serialize(review));
        return await RunAsync<FileCleanupResult>("Invoke-RemovalLeftovers.ps1", CleanupArguments("Apply", review) + (reviewed ? " -ManualReviewApproved" : ""), waitForRemoval: true);
    }

    public async Task<OptimizerResult<FileCleanupResult>> RestoreRemovedFilesAsync(RemovalCleanupReview review)
    {
        var result = await RunAsync<FileCleanupResult>("Invoke-RemovalLeftovers.ps1", CleanupArguments("Restore", review), waitForRemoval: true);
        if (result.Status == "success") File.Delete(Path.Combine(_storage, "files-active.json"));
        return result;
    }

    public Task<RemovalCleanupReview?> ReadLastFileCleanupAsync()
    {
        var path = Path.Combine(_storage, "files-active.json");
        return File.Exists(path) ? ReadJournalAsync<RemovalCleanupReview>(path) : Task.FromResult<RemovalCleanupReview?>(null);
    }

    private static string CleanupArguments(string action, RemovalCleanupReview review)
        => "-Action " + action + " -QueueJournalPath " + Quote(review.QueueJournalPath) + " -AppId " + Quote(review.Plan.AppId)
           + " -ReviewPath " + Quote(review.Path) + " -ReviewSha256 " + Quote(review.Hash) + " -ConfirmApply";

    public string? FindLastJournal(string kind)
    {
        var pointer = Path.Combine(_storage, kind + "-active.txt");
        if (!File.Exists(pointer)) return null;
        var path = File.ReadAllText(pointer);
        var prefix = Path.GetFullPath(_storage) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(path).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Saved operation is outside the recovery folder.");
        return File.Exists(path) ? path : null;
    }

    public static async Task<T?> ReadJournalAsync<T>(string path)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return await JsonSerializer.DeserializeAsync<T>(stream, Json);
    }

    private string NewOperationDirectory(string kind)
    {
        var path = Path.Combine(_storage, kind + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private void Remember(string kind, string journal) => WritePointer(Path.Combine(_storage, kind + "-active.txt"), journal);
    private static void WritePointer(string path, string value)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, value, new UTF8Encoding(false));
            File.Move(temporary, path, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }
    private void Forget(string kind) => File.Delete(Path.Combine(_storage, kind + "-active.txt"));
    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
    private static string Quote(string value) => "'" + value.Replace("'", "''") + "'";
    private static T RequireData<T>(OptimizerResult<T> result) => result.Data ?? throw new InvalidDataException("The backend returned no operation details.");

    private async Task<OptimizerResult<T>> RequestAsync<T>(string feature, string action, object request, string directory, bool confirm = false, bool waitForRemoval = false)
    {
        var path = Path.Combine(directory, "request-" + Guid.NewGuid().ToString("N") + ".json");
        await File.WriteAllTextAsync(path, JsonSerializer.Serialize(request), new UTF8Encoding(false));
        try
        {
            var arguments = "-Feature " + feature + " -Action " + action + " -RequestPath " + Quote(path) + (confirm ? " -ConfirmApply" : "");
            return await RunAsync<T>("Invoke-OptimizerRequest.ps1", arguments, waitForRemoval: waitForRemoval);
        }
        finally { File.Delete(path); }
    }

    private async Task<OptimizerResult<T>> RunAsync<T>(string script, string arguments, CancellationToken cancellationToken = default, bool waitForRemoval = false)
    {
        var scriptPath = Path.Combine(_locator.ScriptsDirectory ?? throw new InvalidOperationException("The backend folder is unavailable."), script);
        var command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & " + Quote(scriptPath) + " " + arguments;
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = _locator.RepoRoot!,
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(command)) }) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new InvalidOperationException("The backend process did not start.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (!waitForRemoval) timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) when (!waitForRemoval)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new TimeoutException("The backend did not respond. Check the saved operation before retrying.");
        }
        var text = await output;
        var stderr = await error;
        if (string.IsNullOrWhiteSpace(text)) throw new InvalidOperationException(string.IsNullOrWhiteSpace(stderr) ? "The backend returned no response." : stderr.Trim());
        var result = JsonSerializer.Deserialize<OptimizerResult<T>>(text, Json) ?? throw new InvalidDataException("The backend response could not be read.");
        if (result.Status == "failed") throw new InvalidOperationException(string.Join(Environment.NewLine, result.Errors.Select(issue => issue.Message)));
        return result;
    }
}
