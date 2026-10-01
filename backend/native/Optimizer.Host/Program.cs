using System.Text.Json;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Text;
using RooIndustries.Optimizer;

try
{
    if (args is ["--timer-worker", var timerLaunch]) { TimerControl.RunWorker(timerLaunch); return; }
    if (args is ["--timer-autostart", var timerRoot]) { TimerControl.RunAutostart(timerRoot); return; }
    RuntimeEnvironment.RequireClean();
    if (args.Length < 2) throw new ArgumentException("Provide an action and request JSON path.");
    var action = args[0];
    var fromInput = args[1] == "-";
    using var requestLease = !fromInput && action is "protected-session-run" or "protected-session-watch" ? OperationsFolder.LeaseContaining(args[1]) : null;
    var requestBytes = fromInput ? ReadInput() : File.ReadAllBytes(args[1]);
    var request = OperationFiles.Deserialize<HostRequest>(requestBytes);
    if (!fromInput && (action is "rule-save" or "rule-delete" or "policy-pause" or "policy-secure" or "policy-adopt" or "policy-stop" or "operations-secure" or "data-secure" || action == "policy-run" && request.DurationSeconds is not null))
        throw new InvalidDataException("Governor and recovery-folder requests must be passed on standard input.");
    if (args.Length > 2 && !string.Equals(Path.GetFullPath(request.RepoRoot), Path.GetFullPath(args[2]), StringComparison.OrdinalIgnoreCase))
        throw new InvalidDataException("Request repository differs from the selected application backend.");
    if (request.SchemaVersion != 1) throw new InvalidDataException("Unsupported optimizer request version.");
    if (request.Progress == true && action is "data-secure" or "operations-secure" or "policy-secure")
    {
        var progressOptions = new JsonSerializerOptions(OperationFiles.Json) { WriteIndented = false };
        PolicyRootSecurity.Progress += progress =>
        {
            lock (Console.Out) { Console.Out.WriteLine("ROO_INDUSTRIES_PARTIAL " + JsonSerializer.Serialize(new { schemaVersion = 1, status = "partial", data = progress }, progressOptions)); Console.Out.Flush(); }
        };
    }
    var catalog = OperationFiles.Read<JsonElement>(Path.Combine(request.RepoRoot, "backend", "profiles", "protected-processes.json"));
    var names = catalog.GetProperty("protectedProcesses").EnumerateArray().SelectMany(item => item.GetProperty("names").EnumerateArray())
        .Select(name => new Regex("^" + Regex.Escape(name.GetString()!).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))).ToArray();
    bool Excluded(RunningProcess process) => names.Any(pattern => pattern.IsMatch(Path.GetFileName(process.ExecutablePath)));
    void RequireEarlierReceipts()
    {
        if (request.FixturePath is not null) return;
        var downloads = Path.Combine(OperationsFolder.DefaultRoot, "download-blockers");
        foreach (var receipt in new[] { Path.Combine(OperationsFolder.DefaultRoot, "ultimate-plan.json") }.Concat(Directory.Exists(downloads) ? Directory.EnumerateFiles(downloads, "*.json") : []))
            PolicyRootSecurity.RequireConfirmedEarlierVersion(receipt, request.AcceptEarlierVersion == true);
    }
    var engine = new ProcessControlEngine(Excluded);
    object data;
    switch (action)
    {
        case "tweak-catalog":
            var tweakCatalog = ReadTweakCatalog(request.RepoRoot);
            data = new { catalog = tweakCatalog, hash = tweakCatalog.Digest };
            break;
        case "restore-point-list": data = RestorePoints.List(); break;
        case "restore-point-preview":
            data = RestorePoints.Preview(request.AllowFreshRestorePoint == true); WriteNewTweakPreview(Require(request.OutputPath, "output path"), data); break;
        case "restore-point-create":
            RequireConfirmation(request);
            data = RestorePoints.Create(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path")); break;
        case "tweak-fixture-create":
            RequireConfirmation(request);
            data = FileTweakStore.Create(Require(request.FixturePath, "fixture path")).Context;
            break;
        case "tweak-custom-import":
            RequireConfirmation(request);
            var imported = CustomTweaks.Import(ReadTweakCatalog(request.RepoRoot, custom: false), Require(request.CustomSettingsPath, "constructor file"));
            data = new { catalog = imported, hash = imported.Digest }; break;
        case "tweak-ownership-preview":
            var ownershipPath = Require(request.SelectedFilePath, "selected file or folder");
            var ownershipCatalog = CustomTweaks.AddOwnership(ReadTweakCatalog(request.RepoRoot, custom: false), ownershipPath);
            var ownershipTarget = "selected:" + FileLease.NormalizePath(ownershipPath);
            var ownershipSetting = ownershipCatalog.Settings.Single(setting => setting.Options.Any(option => (option.Controls ?? []).Any(control => control.Address.Kind == "file-ownership" && control.Address.Target == ownershipTarget)));
            var ownershipRead = FileAccessControl.Read(new("file-ownership", ownershipTarget, "permissions"));
            data = new TweakEngine(ownershipCatalog, new RegistryTweakStore()).Preview("file-permissions-" + ownershipRead.Id[..16].ToLowerInvariant(), [new(ownershipSetting.Id, ownershipSetting.Options[0].Id)]);
            WriteNewTweakPreview(Require(request.OutputPath, "output path"), data); break;
        case "tweak-recovery":
            data = new RegistryTweakStore().Recovery();
            break;
        case "tweak-recover":
            RequireConfirmation(request);
            RequireEarlierReceipts();
            data = new { recovered = new RegistryTweakStore().Recover(Require(request.ReviewHash, "recovery review hash")) };
            break;
        case "tweak-status":
            var partialOptions = new JsonSerializerOptions(OperationFiles.Json) { WriteIndented = false };
            data = Tweaks(request).Detect(request.PartialStatus == true ? inspection =>
            {
                Console.Out.WriteLine("ROO_INDUSTRIES_PARTIAL " + JsonSerializer.Serialize(new { schemaVersion = 1, status = "partial", data = inspection }, partialOptions));
                Console.Out.Flush();
            } : null);
            break;
        case "tweak-preview":
            if (request.Selections is not null && request.PresetId is not null) throw new InvalidDataException("Provide selections or a preset, not both.");
            var previewEngine = Tweaks(request);
            data = request.PresetId is null ? previewEngine.Preview(Require(request.ProfileId, "profile ID"), request.Selections ?? throw new InvalidDataException("Explicit selections are required; an empty array restores a profile."))
                : previewEngine.PreviewPreset(Require(request.ProfileId, "profile ID"), request.PresetId);
            WriteNewTweakPreview(Require(request.OutputPath, "output path"), data);
            break;
        case "tweak-apply":
        case "tweak-restore":
            RequireConfirmation(request);
            var tweakPreview = Require(request.PreviewPath, "preview path");
            var tweakHash = Require(request.ReviewHash, "review hash");
            if (action == "tweak-restore" && OperationFiles.Read<TweakPlan>(tweakPreview, tweakHash).Selections.Length != 0)
                throw new InvalidDataException("Restore requires a reviewed empty selection for the profile.");
            if (action == "tweak-restore") RequireEarlierReceipts();
            var tweakApplied = Tweaks(request).Apply(tweakPreview, tweakHash, request.AcceptDataLoss == true);
            if (action == "tweak-restore" && request.FixturePath is null) CustomTweaks.PruneOwnership(tweakApplied.State);
            data = tweakApplied;
            break;
        case "protected-session-preview":
            if (request.Controls is not null && request.ControlsPath is not null) throw new InvalidDataException("Provide inline controls or a controls file, not both.");
            var sessionControls = request.Controls ?? OperationFiles.Read<Dictionary<string, JsonElement>>(Require(request.ControlsPath, "controls file"));
            var sessionLauncher = request.ProcessId ?? throw new InvalidDataException("Launcher process ID is required.");
            var governor = new ProcessPolicyStore(request.PolicyRoot ?? ProcessPolicyStore.RootFor(request.OutputPath));
            governor.RequireUnownedLaunch(Path.GetFullPath(Require(request.GamePath, "game executable")), sessionControls.Keys);
            using (var launcherProcess = new ProcessTarget(sessionLauncher)) governor.RequireUnowned(launcherProcess.Identity(), sessionControls.Keys);
            data = new ProtectedSessions(Excluded).Preview(sessionLauncher, Require(request.GamePath, "game executable"), sessionControls, request.AcceptLauncherScope == true);
            OperationFiles.Write(Require(request.OutputPath, "output path"), (ProtectedSessionPreview)data);
            break;
        case "protected-session-check":
            data = new ProtectedSessions(Excluded).Check(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"));
            break;
        case "protected-session-run":
            RequireConfirmation(request);
            using (OperationsFolder.LeaseContaining(Require(request.SessionRoot, "session directory")))
            using (var cancellation = new CancellationTokenSource())
            {
                Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
                data = new ProtectedSessions(Excluded).Run(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"),
                    Require(request.SessionRoot, "session directory"), (root, operationId) => StartProtectedWatch(request.RepoRoot, root, operationId), cancellation.Token,
                    request.DurationSeconds is { } seconds ? TimeSpan.FromSeconds(seconds) : null);
            }
            break;
        case "protected-session-status":
            data = new ProtectedSessions(Excluded).Status(Require(request.SessionRoot, "session directory"));
            break;
        case "protected-session-stop":
        case "protected-session-affinity":
            RequireConfirmation(request);
            new ProtectedSessions(Excluded).Command(Require(request.SessionRoot, "session directory"), action == "protected-session-stop" ? "stop" : "affinity", request.Affinity);
            data = new { requested = true };
            break;
        case "protected-session-recover":
            RequireConfirmation(request);
            PolicyRootSecurity.RequireConfirmedEarlierVersion(Path.Combine(Require(request.SessionRoot, "session directory"), "session.json"), request.AcceptEarlierVersion == true);
            data = new ProtectedSessions(Excluded).Recover(Require(request.SessionRoot, "session directory"), Require(request.OperationId, "session identity"));
            break;
        case "protected-session-watch":
            RequireConfirmation(request);
            using (OperationsFolder.LeaseContaining(Require(request.SessionRoot, "session directory")))
                new ProtectedSessions(Excluded).Watch(Require(request.SessionRoot, "session directory"), Require(request.OperationId, "session identity"));
            data = new { recovered = true };
            break;
        case "process-status":
            using (var process = new ProcessTarget(request.ProcessId ?? throw new InvalidDataException("Process ID is required."))) data = process.Snapshot();
            break;
        case "process-preview":
            data = engine.Preview(request.ProcessId ?? throw new InvalidDataException("Process ID is required."), request.Controls ?? [], request.CpuSelection);
            OperationFiles.Write(Require(request.OutputPath, "output path"), (ProcessControlPreview)data);
            break;
        case "process-apply":
            RequireConfirmation(request);
            var reviewed = OperationFiles.Read<ProcessControlPreview>(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"));
            using (ProcessPolicyStore.Gate())
            {
                new ProcessPolicyStore(request.PolicyRoot ?? ProcessPolicyStore.DefaultRoot).RequireUnowned(reviewed.Identity, reviewed.Desired.Keys);
                data = engine.Apply(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path"));
            }
            break;
        case "process-restore":
            RequireConfirmation(request);
            PolicyRootSecurity.RequireConfirmedEarlierVersion(Require(request.JournalPath, "journal path"), request.AcceptEarlierVersion == true);
            var recorded = OperationFiles.Read<ProcessControlJournal>(Require(request.JournalPath, "journal path"));
            new ProcessPolicyStore(request.PolicyRoot ?? ProcessPolicyStore.DefaultRoot).RequireUnownedRestore(recorded.Preview.Identity, recorded.Changes.Select(change => change.Name));
            data = engine.Restore(Require(request.JournalPath, "journal path"));
            break;
        case "rules-list":
            data = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root")).ReadRules().Select(pair => pair.Rule).ToArray();
            break;
        case "rule-save":
            RequireConfirmation(request);
            var store = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root"));
            var rule = request.Rule ?? throw new InvalidDataException("A rule is required.");
            store.Save(rule, Require(request.RepoRoot, "repository root"));
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
                var policyRoot = Path.GetFullPath(Require(request.PolicyRoot, "policy root"));
                var resident = request.DurationSeconds is null;
                if (resident && !string.Equals(Path.GetDirectoryName(Path.GetFullPath(args[1])), policyRoot, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The governor request must be stored in its protected rules folder.");
                if (resident) ProcessPolicyAdoption.Adopt(policyRoot);
                data = new ProcessPolicyHost(new(policyRoot), Excluded).Run(cancellation.Token,
                    request.DurationSeconds is { } seconds ? TimeSpan.FromSeconds(seconds) : null,
                    () => { if (resident && !File.ReadAllBytes(args[1]).AsSpan().SequenceEqual(requestBytes)) throw new InvalidDataException("The governor request changed before its rules folder was locked."); });
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
        case "policy-summary":
            data = new ProcessPolicyStore(Require(request.PolicyRoot, "policy root")).Summary();
            break;
        case "policy-secure":
            RequireConfirmation(request);
            var securedRoot = Require(request.PolicyRoot, "policy root");
            if (request.UserSid is null) DataFolder.EnsureFor(securedRoot);
            data = new { migrated = PolicyRootSecurity.Secure(securedRoot, request.UserSid), report = PolicyRootSecurity.LastReport };
            if (request.UserSid is null) ProcessPolicyAdoption.Adopt(securedRoot);
            break;
        case "policy-adopt":
            RequireConfirmation(request);
            data = new { adopted = ProcessPolicyAdoption.Adopt(Require(request.PolicyRoot, "policy root")) };
            break;
        case "operations-secure":
            RequireConfirmation(request);
            var operationsRoot = Require(request.OperationsRoot, "recovery folder");
            data = new { migrated = OperationsFolder.Secure(operationsRoot), root = OperationsFolder.Ensure(operationsRoot), report = PolicyRootSecurity.LastReport };
            break;
        case "data-secure":
            RequireConfirmation(request);
            data = new { root = DataFolder.Ensure(), report = PolicyRootSecurity.LastReport };
            break;
        case "policy-pause":
            RequireConfirmation(request);
            new ProcessPolicyStore(Require(request.PolicyRoot, "policy root")).SetPaused(request.Paused ?? throw new InvalidDataException("Choose whether the governor is paused."), Require(request.RepoRoot, "repository root"));
            data = new { paused = request.Paused };
            break;
        case "cleanup-authority": data = Authority(request); break;
        case "cleanup-exclusions-status":
            data = new CleanupExclusionStore(CleanupExclusionStore.DefaultPath).Read();
            break;
        case "cleanup-exclusions-save":
            RequireConfirmation(request);
            data = new CleanupExclusionStore(CleanupExclusionStore.DefaultPath).Save(
                request.Exclusions ?? throw new InvalidDataException("An explicit exclusion list is required."), request.ExpectedRevision);
            break;
        case "cleanup-exclusions-check":
            var exclusions = new CleanupExclusionMatcher(new CleanupExclusionStore(CleanupExclusionStore.DefaultPath).Read().Exclusions);
            foreach (var path in request.FileTargets ?? throw new InvalidDataException("Explicit file targets are required."))
                if (exclusions.Match(path, directory: true) is { } reason) throw new InvalidDataException(reason);
            data = new { allowed = true };
            break;
        case "cleanup-scan":
            data = Cleanup(request).Scan(CancellationToken.None);
            break;
        case "cleanup-preview":
            data = Cleanup(request).Preview(Require(request.OutputPath, "output path"),
                request.ItemIds ?? throw new InvalidDataException("Select leftover item IDs."), request.OwnershipReviewed == true, request.AcceptKeyRecreation == true);
            break;
        case "cleanup-apply":
            RequireConfirmation(request);
            data = Cleanup(request).Apply(Require(request.PreviewPath, "preview path"),
                Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path"));
            break;
        case "cleanup-restore":
            RequireConfirmation(request);
            PolicyRootSecurity.RequireWrittenAfterProtection(Require(request.JournalPath, "journal path"), OperationsFolder.EarlierBackup(request.JournalPath!));
            data = Cleanup(request).Restore(Require(request.JournalPath, "journal path"));
            break;
        case "cleanup-batch-preview":
            data = CleanupBatch.Preview(Require(request.OutputPath, "output path"), request.CleanupOperations ?? throw new InvalidDataException("Application cleanup reviews are required."));
            break;
        case "cleanup-batch-apply":
            RequireConfirmation(request);
            PolicyRootSecurity.RequireConfirmedEarlierVersion(Require(request.JournalPath, "journal path"), request.AcceptEarlierVersion == true);
            data = Batch(request).Apply(Require(request.PreviewPath, "preview path"), Require(request.ReviewHash, "review hash"), Require(request.JournalPath, "journal path"), request.CancellationId);
            break;
        case "cleanup-batch-cancel":
            RequireConfirmation(request);
            data = CleanupBatch.Cancel(Require(request.JournalPath, "journal path"));
            break;
        case "cleanup-batch-restore":
            RequireConfirmation(request);
            PolicyRootSecurity.RequireWrittenAfterProtection(Require(request.JournalPath, "journal path"), OperationsFolder.EarlierBackup(request.JournalPath!));
            data = Batch(request).Restore(Require(request.JournalPath, "journal path"), request.RestoreAppIds);
            break;
        default: throw new InvalidDataException("Unknown optimizer action.");
    }
    if (action != "protected-session-watch") Console.WriteLine(JsonSerializer.Serialize(new { schemaVersion = 1, status = "completed", data }, OperationFiles.Json));
}
catch (Exception error)
{
    if (args.FirstOrDefault() != "protected-session-watch") Console.WriteLine(JsonSerializer.Serialize(new { schemaVersion = 1, status = "failed", error = new { type = error.GetType().Name, message = error.Message } }, OperationFiles.Json));
    Environment.ExitCode = 1;
}

static TweakCatalog ReadTweakCatalog(string root, bool custom = true)
{
    var catalog = OperationFiles.Read<TweakCatalog>(Path.Combine(root, "backend", "catalogs", "windows-tweaks.json"));
    catalog.Validate();
    return custom ? CustomTweaks.Merge(catalog) : catalog;
}
static TweakEngine Tweaks(HostRequest request) => new(ReadTweakCatalog(request.RepoRoot),
    request.FixturePath is null ? new RegistryTweakStore() : new FileTweakStore(request.FixturePath));
static void WriteNewTweakPreview(string path, object plan)
{
    path = Path.GetFullPath(path);
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try { OperationFiles.Write(temporary, plan); File.Move(temporary, path); }
    finally { File.Delete(temporary); }
}

static void StartProtectedWatch(string repoRoot, string root, string operationId)
{
    var path = Path.Combine(root, "watch-request.json");
    OperationFiles.Write(path, new { schemaVersion = 1, repoRoot, sessionRoot = root, operationId, confirm = true });
    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
    if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase))
        start.ArgumentList.Add(System.Reflection.Assembly.GetEntryAssembly()!.Location);
    start.ArgumentList.Add("protected-session-watch"); start.ArgumentList.Add(path);
    using var watcher = Process.Start(start) ?? throw new InvalidOperationException("The recovery watcher did not start.");
}

static byte[] ReadInput()
{
    using var input = Console.OpenStandardInput();
    using var buffer = new MemoryStream();
    input.CopyTo(buffer);
    var bytes = buffer.ToArray();
    return bytes is [0xEF, 0xBB, 0xBF, ..] ? bytes[3..] : bytes;
}

static string Require(string? value, string name) => string.IsNullOrWhiteSpace(value) ? throw new InvalidDataException("Missing " + name + ".") : value;
static void RequireConfirmation(HostRequest request) { if (request.Confirm != true) throw new InvalidDataException("This operation needs explicit confirmation."); }
static ApplicationCleanup Cleanup(HostRequest request) => new(() => CleanupContextFor(request),
    currentExclusions: () => new CleanupExclusionStore(CleanupExclusionStore.DefaultPath).Read().Exclusions);
static CleanupBatch Batch(HostRequest request) => new((source, appId) => Cleanup(request with { QueueJournalPath = source, AppId = appId }));

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
    var entries = queue.GetProperty("plan").GetProperty("entries").EnumerateArray().ToArray();
    var selected = entries.Where(entry => entry.GetProperty("appId").GetString() == request.AppId).ToArray();
    if (selected.Length != 1 || !selected[0].TryGetProperty("appSnapshot", out var app)) throw new InvalidDataException("The completed queue has no unique saved application metadata.");
    var snapshots = entries.Select(entry =>
    {
        if (!entry.TryGetProperty("appSnapshot", out var snapshot)) throw new InvalidDataException("Removal queue ownership metadata is incomplete.");
        var application = Application(snapshot);
        if (application.AppId != entry.GetProperty("appId").GetString()) throw new InvalidDataException("Saved ownership metadata belongs to another queue entry.");
        return application;
    }).ToArray();
    var inventory = RunScript(request.RepoRoot, "Get-InstalledAppInventory.ps1", []);
    var complete = inventory.TryGetProperty("complete", out var known) && known.ValueKind == JsonValueKind.True;
    var peers = inventory.GetProperty("apps").EnumerateArray().Select(Application).Concat(snapshots).Distinct().ToArray();
    return new(source, authority, Application(app), peers, complete);
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
    var command = RuntimeEnvironment.PowerShellPrelude + "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & " + Quote(Path.Combine(repoRoot, "backend", "scripts", script));
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
    public string? FixturePath { get; init; }
    public string? CustomSettingsPath { get; init; }
    public string? SelectedFilePath { get; init; }
    public bool? AllowFreshRestorePoint { get; init; }
    public bool? PartialStatus { get; init; }
    public string? ProfileId { get; init; }
    public string? PresetId { get; init; }
    public TweakSelection[]? Selections { get; init; }
    public int? ProcessId { get; init; }
    public string? GamePath { get; init; }
    public string? ControlsPath { get; init; }
    public string? SessionRoot { get; init; }
    public string? OperationId { get; init; }
    public bool? AcceptLauncherScope { get; init; }
    public AffinityState? Affinity { get; init; }
    public Dictionary<string, JsonElement>? Controls { get; init; }
    public CpuSelection? CpuSelection { get; init; }
    public string? OutputPath { get; init; }
    public string? PreviewPath { get; init; }
    public string? ReviewHash { get; init; }
    public string? JournalPath { get; init; }
    public bool? Confirm { get; init; }
    public bool? AcceptDataLoss { get; init; }
    public bool? AcceptEarlierVersion { get; init; }
    public bool? Progress { get; init; }
    public string? PolicyRoot { get; init; }
    public string? OperationsRoot { get; init; }
    public SavedProcessRule? Rule { get; init; }
    public string? RuleId { get; init; }
    public double? DurationSeconds { get; init; }
    public bool? Paused { get; init; }
    public string? UserSid { get; init; }
    public string? QueueJournalPath { get; init; }
    public string? AppId { get; init; }
    public string[]? ItemIds { get; init; }
    public bool? OwnershipReviewed { get; init; }
    public bool? AcceptKeyRecreation { get; init; }
    public CleanupPart[]? CleanupOperations { get; init; }
    public string? CancellationId { get; init; }
    public CleanupExclusions? Exclusions { get; init; }
    public string? ExpectedRevision { get; init; }
    public string[]? FileTargets { get; init; }
    public string[]? RestoreAppIds { get; init; }
}
