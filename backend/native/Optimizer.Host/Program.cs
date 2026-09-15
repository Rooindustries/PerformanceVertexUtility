using System.Text.Json;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Text;
using Roo.Optimizer;

try
{
    if (args.Length < 2) throw new ArgumentException("Provide an action and request JSON path.");
    var action = args[0];
    var request = OperationFiles.Read<HostRequest>(args[1]);
    if (request.SchemaVersion != 1) throw new InvalidDataException("Unsupported optimizer request version.");
    var catalog = OperationFiles.Read<JsonElement>(Path.Combine(request.RepoRoot, "backend", "profiles", "protected-processes.json"));
    var names = catalog.GetProperty("protectedProcesses").EnumerateArray().SelectMany(item => item.GetProperty("names").EnumerateArray())
        .Select(name => new Regex("^" + Regex.Escape(name.GetString()!).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))).ToArray();
    bool Excluded(RunningProcess process) => names.Any(pattern => pattern.IsMatch(Path.GetFileName(process.ExecutablePath)));
    var engine = new ProcessControlEngine(Excluded);
    object data;
    switch (action)
    {
        case "process-status":
            using (var process = new ProcessTarget(request.ProcessId ?? throw new InvalidDataException("Process ID is required."))) data = process.Snapshot();
            break;
        case "process-preview":
            data = engine.Preview(request.ProcessId ?? throw new InvalidDataException("Process ID is required."), request.Controls ?? [], request.CpuSelection);
            OperationFiles.Write(Require(request.OutputPath, "output path"), (ProcessControlPreview)data);
            break;
        case "process-apply":
            RequireConfirmation(request);
            data = engine.Apply(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path"));
            break;
        case "process-restore":
            RequireConfirmation(request);
            data = engine.Restore(Require(request.JournalPath, "journal path"));
            break;
        case "rules-list":
            data = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root")).ReadRules().Select(pair => pair.Rule).ToArray();
            break;
        case "rule-save":
            RequireConfirmation(request);
            var store = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root"));
            var rule = request.Rule ?? throw new InvalidDataException("A rule is required.");
            store.Save(rule);
            data = store.ReadRules().Single(pair => pair.Rule.RuleId == rule.RuleId).Rule;
            break;
        case "rule-delete":
            RequireConfirmation(request);
            new ProcessPolicyStore(Require(request.PolicyRoot, "policy root")).Delete(Require(request.RuleId, "rule ID"));
            data = new { deletedRuleId = request.RuleId };
            break;
        case "policy-run":
            RequireConfirmation(request);
            using (var cancellation = new CancellationTokenSource())
            {
                Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
                data = new ProcessPolicyHost(new(Require(request.PolicyRoot, "policy root")), Excluded).Run(cancellation.Token,
                    request.DurationSeconds is { } seconds ? TimeSpan.FromSeconds(seconds) : null);
            }
            break;
        case "policy-stop":
            RequireConfirmation(request);
            var root = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root"));
            data = new { stopRequested = root.RequestStop() };
            break;
        case "policy-status":
            data = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root")).Status();
            break;
        case "cleanup-authority": data = Authority(request); break;
        case "cleanup-scan":
            data = new ApplicationCleanup(() => CleanupContextFor(request)).Scan(CancellationToken.None);
            break;
        case "cleanup-preview":
            data = new ApplicationCleanup(() => CleanupContextFor(request)).Preview(Require(request.OutputPath, "output path"),
                request.ItemIds ?? throw new InvalidDataException("Select leftover item IDs."), request.OwnershipReviewed == true, request.AcceptKeyRecreation == true);
            break;
        case "cleanup-apply":
            RequireConfirmation(request);
            data = new ApplicationCleanup(() => CleanupContextFor(request)).Apply(Require(request.PreviewPath, "preview path"),
                Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path"));
            break;
        case "cleanup-restore":
            RequireConfirmation(request);
            data = new ApplicationCleanup(() => CleanupContextFor(request)).Restore(Require(request.JournalPath, "journal path"));
            break;
        case "cleanup-batch-preview":
            data = CleanupBatch.Preview(Require(request.OutputPath, "output path"), request.CleanupOperations ?? throw new InvalidDataException("Application cleanup reviews are required."));
            break;
        case "cleanup-batch-apply":
            RequireConfirmation(request);
            data = Batch(request).Apply(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path"), request.CancellationId);
            break;
        case "cleanup-batch-cancel":
            RequireConfirmation(request);
            data = CleanupBatch.Cancel(Require(request.JournalPath, "journal path"));
            break;
        case "cleanup-batch-restore":
            RequireConfirmation(request);
            data = Batch(request).Restore(Require(request.JournalPath, "journal path"));
            break;
        default: throw new InvalidDataException("Unknown optimizer action.");
    }
    Console.WriteLine(JsonSerializer.Serialize(new { schemaVersion = 1, status = "completed", data }, OperationFiles.Json));
}
catch (Exception error)
{
    Console.WriteLine(JsonSerializer.Serialize(new { schemaVersion = 1, status = "failed", error = new { type = error.GetType().Name, message = error.Message } }, OperationFiles.Json));
    Environment.ExitCode = 1;
}

static string Require(string? value, string name) => string.IsNullOrWhiteSpace(value) ? throw new InvalidDataException("Missing " + name + ".") : value;
static void RequireConfirmation(HostRequest request) { if (request.Confirm != true) throw new InvalidDataException("This operation needs explicit confirmation."); }
static CleanupBatch Batch(HostRequest request) => new((source, appId) => new ApplicationCleanup(() => CleanupContextFor(request with { QueueJournalPath = source, AppId = appId })));

static CleanupAuthority Authority(HostRequest request)
{
    var result = RunScript(request.RepoRoot, "Get-CleanupAuthority.ps1", ["-QueueJournalPath", Require(request.QueueJournalPath, "removal queue journal"), "-AppId", Require(request.AppId, "app ID")]);
    return result.Deserialize<CleanupAuthority>(OperationFiles.Json) ?? throw new InvalidDataException("Cleanup authority was not returned.");
}

static CleanupContext CleanupContextFor(HostRequest request)
{
    var authority = Authority(request);
    authority.Verify(Require(request.AppId, "app ID"), authority.ProviderIdentityHash);
    var source = Path.GetFullPath(Require(request.QueueJournalPath, "queue journal"));
    var queue = OperationFiles.Read<JsonElement>(source);
    var entries = queue.GetProperty("plan").GetProperty("entries").EnumerateArray().Where(entry => entry.GetProperty("appId").GetString() == request.AppId).ToArray();
    if (entries.Length != 1 || !entries[0].TryGetProperty("appSnapshot", out var app)) throw new InvalidDataException("The completed queue has no unique saved application metadata.");
    var inventory = RunScript(request.RepoRoot, "Get-InstalledAppInventory.ps1", []);
    var complete = inventory.TryGetProperty("complete", out var known) && known.ValueKind == JsonValueKind.True;
    return new(source, authority, Application(app), inventory.GetProperty("apps").EnumerateArray().Select(Application).ToArray(), complete);
}

static CleanupApplication Application(JsonElement app)
{
    string? Text(string name) => app.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    return new()
    {
        AppId = Text("appId") ?? throw new InvalidDataException("Inventory app identity is missing."),
        DisplayName = Text("displayName") ?? throw new InvalidDataException("Inventory app name is missing."),
        Publisher = Text("publisher"), InstallLocation = Text("installLocation"), PackageFamilyName = Text("packageFamilyName"),
    };
}

static JsonElement RunScript(string repoRoot, string script, string[] arguments)
{
    static string Quote(string value) => "'" + value.Replace("'", "''") + "'";
    var command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & " + Quote(Path.Combine(repoRoot, "backend", "scripts", script));
    if (arguments.Length % 2 != 0) throw new InvalidDataException("Provider parameters must be name/value pairs.");
    for (var index = 0; index < arguments.Length; index += 2)
    {
        if (!Regex.IsMatch(arguments[index], "^-[A-Za-z]+$")) throw new InvalidDataException("Invalid provider parameter name.");
        command += " " + arguments[index] + " " + Quote(arguments[index + 1]);
    }
    var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"))
    {
        UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
    };
    foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(command)) }) start.ArgumentList.Add(arg);
    using var process = Process.Start(start) ?? throw new InvalidOperationException("The Windows provider did not start.");
    var output = process.StandardOutput.ReadToEndAsync();
    var errors = process.StandardError.ReadToEndAsync();
    if (!process.WaitForExit(60000)) { process.Kill(entireProcessTree: true); process.WaitForExit(); throw new TimeoutException("The Windows inventory provider did not finish."); }
    var text = output.GetAwaiter().GetResult();
    var stderr = errors.GetAwaiter().GetResult();
    if (process.ExitCode != 0) throw new InvalidOperationException(script + " failed with exit " + process.ExitCode + ": " + stderr);
    using var document = JsonDocument.Parse(text);
    return document.RootElement.Clone();
}

sealed record HostRequest
{
    public required int SchemaVersion { get; init; }
    public required string RepoRoot { get; init; }
    public int? ProcessId { get; init; }
    public Dictionary<string, JsonElement>? Controls { get; init; }
    public CpuSelection? CpuSelection { get; init; }
    public string? OutputPath { get; init; }
    public string? PreviewPath { get; init; }
    public string? ReviewHash { get; init; }
    public string? JournalPath { get; init; }
    public bool? Confirm { get; init; }
    public string? PolicyRoot { get; init; }
    public SavedProcessRule? Rule { get; init; }
    public string? RuleId { get; init; }
    public double? DurationSeconds { get; init; }
    public string? QueueJournalPath { get; init; }
    public string? AppId { get; init; }
    public string[]? ItemIds { get; init; }
    public bool? OwnershipReviewed { get; init; }
    public bool? AcceptKeyRecreation { get; init; }
    public CleanupPart[]? CleanupOperations { get; init; }
    public string? CancellationId { get; init; }
}
